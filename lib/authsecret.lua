-- lib/authsecret.lua -- symmetric encryption at rest for the hub's stored game-account and proxy
-- passwords (PANEL.md: `accounts.json` password(enc), `proxies.json` pass(enc)).
--
-- ============================================================================================
-- CONSTRUCTION  (read this before trusting it with anything)
-- ============================================================================================
--
-- Master secret
--   `secret.key` in the hub data dir: 32 raw random bytes from sys.randomBytes (the OS CSPRNG),
--   created on first run, mode 0600 on POSIX.  It is NEVER derived from a passphrase and never
--   leaves the process except to be written to that file.
--
-- Sub-key derivation (HKDF-Expand with a single-block info, RFC 5869 style)
--   Kenc = HMAC-SHA256(master, "luaclient/authsecret/v1/enc\x01")
--   Kmac = HMAC-SHA256(master, "luaclient/authsecret/v1/mac\x01")
--   Two independent 256-bit keys, so the cipher and the MAC never share key material.
--
-- Record encryption  (encrypt-then-MAC, the composition that is generically secure)
--   nonce = 12 fresh random bytes per record (sys.randomBytes)
--   ct    = plaintext XOR ChaCha20(Kenc, nonce, counter = 1)          -- RFC 8439 section 2.4
--   tag   = HMAC-SHA256(Kmac, "sbx1" || nonce || u32be(#aad) || aad || ct)   -- 32 bytes, full
--   record = "sbx$1$" .. b64url(nonce) .. "$" .. b64url(ct) .. "$" .. b64url(tag)
--
--   The MAC covers the version label, the nonce, the length-prefixed associated data and the
--   ciphertext, so none of them can be swapped between records or shifted against each other.
--   Decryption verifies the tag with a constant-time compare BEFORE producing any plaintext, and
--   returns nil, err on any mismatch.  b64url output is unpadded, so a record contains no '=' and
--   no '$' and is safe inside JSON, a URL or a shell word.
--
-- Associated data
--   encrypt(pt, aad) / decrypt(rec, aad).  The caller should bind a record to its slot -- e.g.
--   aad = "account:" .. id .. ":password" -- so a ciphertext copied from one row into another
--   fails to authenticate.  aad defaults to "".
--
-- ============================================================================================
-- LIMITS -- stated plainly
-- ============================================================================================
--  * This protects the JSON files AT REST against someone who reads them without also reading
--    `secret.key`.  It does not protect against anyone who can read the hub's data directory or
--    its process memory: the hub must be able to decrypt these passwords to log characters in
--    (PANEL.md says so), so the key sits next to the ciphertext.  Encrypting the files is a
--    backup/accident/screenshot mitigation, not a defence against host compromise.
--  * Not a standard AEAD.  ChaCha20 + HMAC-SHA256 encrypt-then-MAC is a sound composition, but
--    it is NOT ChaCha20-Poly1305 and produces no compatible ciphertext; nothing else will read
--    these records.
--  * Nonces are random, not counters.  With 96-bit nonces the birthday bound is ~2^48 records
--    before a repeat becomes likely -- irrelevant at this scale, but it does mean security rests
--    on sys.randomBytes actually being the OS CSPRNG.  A nonce repeat under the same key would
--    expose the XOR of two plaintexts.
--  * No constant-time guarantee below the Lua level.  The tag compare accumulates instead of
--    returning early, but a tracing JIT, the GC and the CPU caches make real constant time
--    unattainable in pure Lua.  Plaintexts and keys live in immutable Lua strings that cannot be
--    wiped and may be copied by the collector.
--  * File permissions are enforced on POSIX only (chmod 0600 via FFI).  On Windows the file
--    inherits the data directory's ACL -- keep the hub's data dir out of shared locations.
--  * The "1" in the record is a version for the whole suite (KDF + cipher + MAC + encoding).  A
--    future v2 can be added next to it; decrypt() rejects anything it does not know.
--
-- ============================================================================================
-- API
-- ============================================================================================
--   authsecret.open(path)          -> box | nil, err   -- load `path`, creating it if absent
--   authsecret.load(path)          -> box | nil, err   -- load, error if absent
--   authsecret.create(path)        -> box | nil, err   -- create, error if it already exists
--   authsecret.fromKey(master32)   -> box              -- for tests / an externally managed key
--   box:encrypt(plaintext [, aad]) -> record string
--   box:decrypt(record [, aad])    -> plaintext | nil, err
--   box:isRecord(s)                -> boolean          -- looks like one of our records
--   box:rewrap(record, aad, newAad) -> record | nil, err
--   authsecret.chacha20(key32, nonce12, counter, data) -> keystream-XORed data (RFC 8439 2.4)
--   authsecret.chacha20Block(key32, nonce12, counter)  -> the raw 64-byte block (RFC 8439 2.3)
--
-- The ChaCha20 core is checked against the RFC 8439 section 2.3.2 block vector and the section
-- 2.4.2 encryption vector, both of which were independently reproduced with `openssl enc
-- -chacha20` before being frozen into test/cryptosuite.lua.

local sha2   = require('lib.sha2')
local hmac   = require('lib.hmac')
local base64 = require('lib.base64')
local sys    = require('lib.sys')
local bit    = require('bit')

local band, bxor, rol, tobit, rshift = bit.band, bit.bxor, bit.rol, bit.tobit, bit.rshift
local sbyte, schar, ssub, srep, sformat = string.byte, string.char, string.sub, string.rep, string.format
local concat, floor = table.concat, math.floor

local M = {}

M.VERSION     = '1'
M.PREFIX      = 'sbx$1$'
M.KEY_SIZE    = 32
M.NONCE_SIZE  = 12
M.TAG_SIZE    = 32

-- ============================================================== ChaCha20 core
-- RFC 8439.  State is 16 signed int32 words; additions fold back with bit.tobit, rotations use
-- bit.rol (which is a true 32-bit rotate on the signed representation).

local C0, C1, C2, C3 = tobit(0x61707865), tobit(0x3320646e), tobit(0x79622d32), tobit(0x6b206574)

--- Little-endian 32-bit word at 1-based offset o.
local function le32(s, o)
  local a, b, c, d = sbyte(s, o, o + 3)
  return tobit(a + b * 0x100 + c * 0x10000 + d * 0x1000000)
end

local function putLe32(x)
  return schar(band(x, 0xff), band(rshift(x, 8), 0xff),
               band(rshift(x, 16), 0xff), band(rshift(x, 24), 0xff))
end

--- One ChaCha20 block: returns 64 bytes.  `counter` is a plain Lua number 0..2^32-1.
local function block(k, n, counter, out)
  local x0,  x1,  x2,  x3  = C0, C1, C2, C3
  local x4,  x5,  x6,  x7  = k[1], k[2], k[3], k[4]
  local x8,  x9,  x10, x11 = k[5], k[6], k[7], k[8]
  local x12                = tobit(counter)
  local x13, x14, x15      = n[1], n[2], n[3]

  local s0,  s1,  s2,  s3  = x0,  x1,  x2,  x3
  local s4,  s5,  s6,  s7  = x4,  x5,  x6,  x7
  local s8,  s9,  s10, s11 = x8,  x9,  x10, x11
  local s12, s13, s14, s15 = x12, x13, x14, x15

  for _ = 1, 10 do
    -- column round
    x0 = tobit(x0 + x4);   x12 = rol(bxor(x12, x0), 16)
    x8 = tobit(x8 + x12);  x4  = rol(bxor(x4,  x8), 12)
    x0 = tobit(x0 + x4);   x12 = rol(bxor(x12, x0), 8)
    x8 = tobit(x8 + x12);  x4  = rol(bxor(x4,  x8), 7)

    x1 = tobit(x1 + x5);   x13 = rol(bxor(x13, x1), 16)
    x9 = tobit(x9 + x13);  x5  = rol(bxor(x5,  x9), 12)
    x1 = tobit(x1 + x5);   x13 = rol(bxor(x13, x1), 8)
    x9 = tobit(x9 + x13);  x5  = rol(bxor(x5,  x9), 7)

    x2  = tobit(x2 + x6);  x14 = rol(bxor(x14, x2), 16)
    x10 = tobit(x10 + x14); x6 = rol(bxor(x6, x10), 12)
    x2  = tobit(x2 + x6);  x14 = rol(bxor(x14, x2), 8)
    x10 = tobit(x10 + x14); x6 = rol(bxor(x6, x10), 7)

    x3  = tobit(x3 + x7);  x15 = rol(bxor(x15, x3), 16)
    x11 = tobit(x11 + x15); x7 = rol(bxor(x7, x11), 12)
    x3  = tobit(x3 + x7);  x15 = rol(bxor(x15, x3), 8)
    x11 = tobit(x11 + x15); x7 = rol(bxor(x7, x11), 7)

    -- diagonal round
    x0  = tobit(x0 + x5);  x15 = rol(bxor(x15, x0), 16)
    x10 = tobit(x10 + x15); x5 = rol(bxor(x5, x10), 12)
    x0  = tobit(x0 + x5);  x15 = rol(bxor(x15, x0), 8)
    x10 = tobit(x10 + x15); x5 = rol(bxor(x5, x10), 7)

    x1  = tobit(x1 + x6);  x12 = rol(bxor(x12, x1), 16)
    x11 = tobit(x11 + x12); x6 = rol(bxor(x6, x11), 12)
    x1  = tobit(x1 + x6);  x12 = rol(bxor(x12, x1), 8)
    x11 = tobit(x11 + x12); x6 = rol(bxor(x6, x11), 7)

    x2 = tobit(x2 + x7);   x13 = rol(bxor(x13, x2), 16)
    x8 = tobit(x8 + x13);  x7  = rol(bxor(x7,  x8), 12)
    x2 = tobit(x2 + x7);   x13 = rol(bxor(x13, x2), 8)
    x8 = tobit(x8 + x13);  x7  = rol(bxor(x7,  x8), 7)

    x3 = tobit(x3 + x4);   x14 = rol(bxor(x14, x3), 16)
    x9 = tobit(x9 + x14);  x4  = rol(bxor(x4,  x9), 12)
    x3 = tobit(x3 + x4);   x14 = rol(bxor(x14, x3), 8)
    x9 = tobit(x9 + x14);  x4  = rol(bxor(x4,  x9), 7)
  end

  out[1]  = tobit(x0  + s0);  out[2]  = tobit(x1  + s1)
  out[3]  = tobit(x2  + s2);  out[4]  = tobit(x3  + s3)
  out[5]  = tobit(x4  + s4);  out[6]  = tobit(x5  + s5)
  out[7]  = tobit(x6  + s6);  out[8]  = tobit(x7  + s7)
  out[9]  = tobit(x8  + s8);  out[10] = tobit(x9  + s9)
  out[11] = tobit(x10 + s10); out[12] = tobit(x11 + s11)
  out[13] = tobit(x12 + s12); out[14] = tobit(x13 + s13)
  out[15] = tobit(x14 + s14); out[16] = tobit(x15 + s15)
  return out
end

local function keyWords(key)
  if type(key) ~= 'string' or #key ~= 32 then error('chacha20: key must be 32 bytes', 3) end
  local k = {}
  for i = 1, 8 do k[i] = le32(key, (i - 1) * 4 + 1) end
  return k
end

local function nonceWords(nonce)
  if type(nonce) ~= 'string' or #nonce ~= 12 then error('chacha20: nonce must be 12 bytes', 3) end
  return { le32(nonce, 1), le32(nonce, 5), le32(nonce, 9) }
end

--- Raw 64-byte keystream block (RFC 8439 section 2.3).
function M.chacha20Block(key, nonce, counter)
  local o = block(keyWords(key), nonceWords(nonce), counter or 0, {})
  local t = {}
  for i = 1, 16 do t[i] = putLe32(o[i]) end
  return concat(t)
end

--- ChaCha20 encryption / decryption (RFC 8439 section 2.4): data XOR keystream.
function M.chacha20(key, nonce, counter, data)
  if type(data) ~= 'string' then error('chacha20: data must be a string', 2) end
  local k, n = keyWords(key), nonceWords(nonce)
  counter = counter or 1
  local len = #data
  local out, oi = {}, 0
  local ks = {}
  local pos = 1
  while pos <= len do
    block(k, n, counter % 0x100000000, ks)
    counter = counter + 1
    local chunk = {}
    local nb = len - pos + 1
    if nb > 64 then nb = 64 end
    for i = 1, nb do
      local w  = ks[floor((i - 1) / 4) + 1]
      local sh = ((i - 1) % 4) * 8
      chunk[i] = schar(bxor(sbyte(data, pos + i - 1), band(rshift(w, sh), 0xff)))
    end
    oi = oi + 1
    out[oi] = concat(chunk)
    pos = pos + nb
  end
  return concat(out)
end

-- ============================================================ key file access
local chmod600
do
  local ok, ffi = pcall(require, 'ffi')
  if ok and ffi.os ~= 'Windows' then
    pcall(ffi.cdef, 'int chmod(const char *path, unsigned int mode);')
    chmod600 = function(path)
      local good = pcall(function() return ffi.C.chmod(path, 384) end)   -- 0600
      return good
    end
  else
    chmod600 = function() return false end
  end
end

local function readFile(path)
  local f, err = io.open(path, 'rb')
  if not f then return nil, err or ('cannot open ' .. tostring(path)) end
  local data = f:read('*a')
  f:close()
  return data
end

--- Create `path` with 0600 BEFORE any secret byte is written to it, then write the key.
local function writeKeyFile(path, key)
  local f, err = io.open(path, 'wb')
  if not f then return nil, 'cannot create ' .. tostring(path) .. ': ' .. tostring(err) end
  f:close()
  chmod600(path)                       -- tighten while the file is still empty
  f, err = io.open(path, 'wb')
  if not f then return nil, 'cannot write ' .. tostring(path) .. ': ' .. tostring(err) end
  f:write(key)
  f:close()
  chmod600(path)
  return true
end

-- =================================================================== the box
local Box = {}
Box.__index = Box

--- Build a box from a 32-byte master secret.
function M.fromKey(master)
  if type(master) ~= 'string' or #master ~= M.KEY_SIZE then
    error('authsecret: master secret must be exactly 32 bytes', 2)
  end
  return setmetatable({
    kenc = hmac.sha256(master, 'luaclient/authsecret/v1/enc\1'),
    kmac = hmac.sha256(master, 'luaclient/authsecret/v1/mac\1'),
  }, Box)
end

function M.load(path)
  local data, err = readFile(path)
  if not data then return nil, err end
  if #data ~= M.KEY_SIZE then
    return nil, sformat('%s: master secret must be exactly %d bytes, found %d',
                        tostring(path), M.KEY_SIZE, #data)
  end
  return M.fromKey(data)
end

function M.create(path)
  local f = io.open(path, 'rb')
  if f then f:close(); return nil, tostring(path) .. ' already exists' end
  local key = sys.randomBytes(M.KEY_SIZE)
  local ok, err = writeKeyFile(path, key)
  if not ok then return nil, err end
  return M.fromKey(key)
end

--- Load `path`, generating a fresh master secret if it is not there yet.
--- Second return value is true when a new key was created.
function M.open(path)
  local f = io.open(path, 'rb')
  if f then
    f:close()
    local box, err = M.load(path)
    if not box then return nil, err end
    return box, false
  end
  local box, err = M.create(path)
  if not box then return nil, err end
  return box, true
end

local function macInput(nonce, aad, ct)
  local n = #aad
  return concat{
    'sbx1', nonce,
    schar(band(rshift(n, 24), 0xff), band(rshift(n, 16), 0xff),
          band(rshift(n, 8), 0xff),  band(n, 0xff)),
    aad, ct,
  }
end

--- Encrypt `plaintext`, binding it to `aad`.  Returns the record string.
function Box:encrypt(plaintext, aad)
  if type(plaintext) ~= 'string' then error('authsecret: plaintext must be a string', 2) end
  aad = aad or ''
  if type(aad) ~= 'string' then error('authsecret: aad must be a string', 2) end
  local nonce = sys.randomBytes(M.NONCE_SIZE)
  local ct    = M.chacha20(self.kenc, nonce, 1, plaintext)
  local tag   = hmac.sha256(self.kmac, macInput(nonce, aad, ct))
  return M.PREFIX .. base64.urlencode(nonce) .. '$' ..
                     base64.urlencode(ct)    .. '$' ..
                     base64.urlencode(tag)
end

function Box:isRecord(s)
  return type(s) == 'string' and ssub(s, 1, 4) == 'sbx$'
end

--- Decrypt.  Returns nil, err for anything that is not an authentic record for this key+aad.
function Box:decrypt(record, aad)
  aad = aad or ''
  if type(record) ~= 'string' then return nil, 'authsecret: record must be a string' end
  local ver, nB64, cB64, tB64 = record:match('^sbx%$([^%$]+)%$([^%$]*)%$([^%$]*)%$([^%$]*)$')
  if not ver then return nil, 'authsecret: malformed record' end
  if ver ~= M.VERSION then return nil, 'authsecret: unsupported record version ' .. ver end

  local nonce = base64.urldecode(nB64)
  local ct    = base64.urldecode(cB64)
  local tag   = base64.urldecode(tB64)
  if not (nonce and ct and tag) then return nil, 'authsecret: bad base64 in record' end
  if #nonce ~= M.NONCE_SIZE then return nil, 'authsecret: bad nonce length' end
  if #tag ~= M.TAG_SIZE then return nil, 'authsecret: bad tag length' end

  local want = hmac.sha256(self.kmac, macInput(nonce, aad, ct))
  if not hmac.equals(want, tag) then
    return nil, 'authsecret: authentication failed'      -- wrong key, wrong aad, or tampering
  end
  return M.chacha20(self.kenc, nonce, 1, ct)
end

--- Re-encrypt an existing record under a different aad (e.g. after a record id changed).
function Box:rewrap(record, aad, newAad)
  local pt, err = self:decrypt(record, aad)
  if not pt then return nil, err end
  return self:encrypt(pt, newAad)
end

--- Diagnostics only: never returns key material.
function Box:fingerprint()
  return sha2.tohex(hmac.sha256(self.kmac, 'luaclient/authsecret/v1/fingerprint')):sub(1, 16)
end

return M
