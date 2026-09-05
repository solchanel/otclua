-- lib/pbkdf2.lua -- PBKDF2-HMAC-SHA256 (RFC 8018 section 5.2) plus the password-hash string
-- format PANEL.md specifies.
--
-- API
--   pbkdf2.derive(password, salt, iterations, dkLen) -> raw dkLen-byte string
--   pbkdf2.deriveHex(password, salt, iterations, dkLen) -> hex
--
--   pbkdf2.hash(password [, opts]) -> 'pbkdf2$sha256$<iter>$<salt_b64>$<hash_b64>'
--        opts = { iterations = pbkdf2.DEFAULT_ITERATIONS, saltLen = 16, dkLen = 32 }
--        The salt comes from sys.randomBytes (the OS CSPRNG); both fields are standard
--        base64 with padding.
--   pbkdf2.verify(password, stored) -> boolean [, err]
--        Re-derives with the stored parameters and compares in constant time.  Returns
--        false plus a message for a malformed or unsupported stored string -- never an error,
--        so a corrupt users.json line cannot crash the login path.
--   pbkdf2.params(stored) -> { iterations=, saltLen=, dkLen=, prf='sha256' } | nil, err
--   pbkdf2.needsRehash(stored [, opts]) -> boolean   (stored below the current cost/param set)
--
-- COST.  PANEL.md asks for >= 200,000 iterations and DEFAULT_ITERATIONS is exactly that.  One
-- iteration is two SHA-256 compressions; measured on the two target machines with dkLen = 32:
--
--     iterations |  Windows (LuaJIT 2.1.1781602682) | Debian/WSL (LuaJIT 2.1.1737090214)
--        100,000 |            124 ms                |            127 ms
--        200,000 |            248 ms                |            252 ms
--        250,000 |            309 ms                |            316 ms
--
-- 200k therefore lands just inside the ~300 ms budget on both, with no reduction needed.  It is
-- a per-login cost paid once, on a single-threaded hub, so raising it further trades login
-- latency (and a DoS surface on the login endpoint) for brute-force resistance.  The count is
-- stored inside every hash, so old hashes keep verifying after a change and needsRehash() flags
-- them for upgrade at the next successful login.
--
-- SPEED.  After the first block, the whole derivation is 32-byte-in/32-byte-out HMAC applied to
-- itself, so the inner loop never touches a Lua string: the two SHA-256 states behind the
-- ipad/opad blocks are computed once, and each iteration is exactly two sha2.compress() calls on
-- a 16-word scratch table.  That is the minimum work PBKDF2 allows.
--
-- Verified against the RFC 7914 section 11 PBKDF2-HMAC-SHA256 vectors (passwd/salt/1/64 and
-- Password/NaCl/80000/64), the RFC 6070 input set re-computed for SHA-256, and Python's
-- hashlib.pbkdf2_hmac on random inputs -- see test/cryptosuite.lua.

local sha2   = require('lib.sha2')
local hmac   = require('lib.hmac')
local base64 = require('lib.base64')
local bit    = require('bit')
local bxor, band, rshift, tobit = bit.bxor, bit.band, bit.rshift, bit.tobit
local schar, sformat, smatch, concat = string.char, string.format, string.match, table.concat

local M = {}

M.DEFAULT_ITERATIONS = 200000
M.DEFAULT_SALT_LEN   = 16
M.DEFAULT_DK_LEN     = 32
M.MAX_ITERATIONS     = 5000000        -- refuse absurd values parsed out of a stored string

local BLOCK_BITLEN = tobit(768)       -- (64 pad block + 32 message bytes) * 8
local MSB          = tobit(0x80000000)

local function copy8(h)
  return { h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8] }
end

--- HMAC of a 32-byte message given as 8 words, starting from a state that has already absorbed
--- the 64-byte pad block.  The whole thing is one compression: 32 message bytes + 0x80 + zeros +
--- the 64-bit length fit in a single 512-bit block.
local function absorb32(H, words, w)
  w[1] = words[1]; w[2] = words[2]; w[3] = words[3]; w[4] = words[4]
  w[5] = words[5]; w[6] = words[6]; w[7] = words[7]; w[8] = words[8]
  w[9] = MSB
  w[10] = 0; w[11] = 0; w[12] = 0; w[13] = 0; w[14] = 0; w[15] = 0
  w[16] = BLOCK_BITLEN
  sha2.compress(H, w)
end

--- PBKDF2-HMAC-SHA256.  Returns exactly dkLen bytes.
function M.derive(password, salt, iterations, dkLen)
  if type(password) ~= 'string' then error('pbkdf2.derive: password must be a string', 2) end
  if type(salt) ~= 'string'     then error('pbkdf2.derive: salt must be a string', 2) end
  iterations = tonumber(iterations) or 0
  dkLen      = tonumber(dkLen) or 32
  if iterations < 1 then error('pbkdf2.derive: iterations must be >= 1', 2) end
  if dkLen < 1 then error('pbkdf2.derive: dkLen must be >= 1', 2) end
  if dkLen > 0xFFFFFFFF * 32 then error('pbkdf2.derive: derived key too long', 2) end

  local ctx    = hmac.new(password)
  local innerH = ctx.innerH
  local outerH = ctx.outerH

  local blocks = math.ceil(dkLen / 32)
  local out    = {}
  local w      = {}                     -- 64-word scratch shared by every compression
  local T      = {}

  for b = 1, blocks do
    -- U1 = HMAC(P, S || INT_32_BE(b)); the salt is arbitrary length, so use the streaming path.
    local inner = sha2.resume256(copy8(innerH), 64)
    inner:update(salt)
    inner:update(schar(band(rshift(b, 24), 0xff), band(rshift(b, 16), 0xff),
                       band(rshift(b, 8), 0xff),  band(b, 0xff)))
    local u = inner:digestWords()
    local outer = copy8(outerH)
    absorb32(outer, u, w)
    u = outer                            -- U1, as 8 words

    T[1] = u[1]; T[2] = u[2]; T[3] = u[3]; T[4] = u[4]
    T[5] = u[5]; T[6] = u[6]; T[7] = u[7]; T[8] = u[8]

    for _ = 2, iterations do
      local hi = copy8(innerH)
      absorb32(hi, u, w)
      local ho = copy8(outerH)
      absorb32(ho, hi, w)
      u = ho
      T[1] = bxor(T[1], u[1]); T[2] = bxor(T[2], u[2])
      T[3] = bxor(T[3], u[3]); T[4] = bxor(T[4], u[4])
      T[5] = bxor(T[5], u[5]); T[6] = bxor(T[6], u[6])
      T[7] = bxor(T[7], u[7]); T[8] = bxor(T[8], u[8])
    end

    out[b] = sha2.wordsToBytes(T, 8)
  end

  return concat(out):sub(1, dkLen)
end

function M.deriveHex(password, salt, iterations, dkLen)
  return sha2.tohex(M.derive(password, salt, iterations, dkLen))
end

-- ------------------------------------------------------- stored hash strings
--- 'pbkdf2$sha256$<iterations>$<salt_b64>$<hash_b64>'
function M.hash(password, opts)
  opts = opts or {}
  local iterations = tonumber(opts.iterations) or M.DEFAULT_ITERATIONS
  local saltLen    = tonumber(opts.saltLen)    or M.DEFAULT_SALT_LEN
  local dkLen      = tonumber(opts.dkLen)      or M.DEFAULT_DK_LEN
  if iterations < 1 or iterations > M.MAX_ITERATIONS then
    error('pbkdf2.hash: iterations out of range', 2)
  end
  if saltLen < 8 then error('pbkdf2.hash: saltLen must be >= 8', 2) end

  local salt = opts.salt
  if salt == nil then
    salt = require('lib.sys').randomBytes(saltLen)
  elseif type(salt) ~= 'string' then
    error('pbkdf2.hash: salt must be a string', 2)
  end

  local dk = M.derive(password, salt, iterations, dkLen)
  return sformat('pbkdf2$sha256$%d$%s$%s', iterations, base64.encode(salt), base64.encode(dk))
end

--- Split a stored string.  Returns saltRaw, dkRaw, iterations, or nil, err.
local function parse(stored)
  if type(stored) ~= 'string' then return nil, 'stored hash is not a string' end
  local scheme, prf, iter, saltB64, hashB64 =
    smatch(stored, '^([^%$]+)%$([^%$]+)%$([^%$]+)%$([^%$]*)%$([^%$]*)$')
  if not scheme then return nil, 'stored hash is malformed' end
  if scheme ~= 'pbkdf2' then return nil, 'unsupported scheme ' .. scheme end
  if prf ~= 'sha256' then return nil, 'unsupported prf ' .. prf end
  local n = tonumber(iter)
  if not n or n ~= math.floor(n) or n < 1 or n > M.MAX_ITERATIONS then
    return nil, 'bad iteration count'
  end
  local salt, e1 = base64.decode(saltB64)
  if not salt then return nil, 'bad salt: ' .. tostring(e1) end
  local dk, e2 = base64.decode(hashB64)
  if not dk then return nil, 'bad hash: ' .. tostring(e2) end
  if #salt < 1 then return nil, 'empty salt' end
  if #dk < 16 then return nil, 'derived key too short' end
  return salt, dk, n
end

function M.params(stored)
  local salt, dk, n = parse(stored)
  if not salt then return nil, dk end
  return { prf = 'sha256', iterations = n, saltLen = #salt, dkLen = #dk }
end

--- Constant-time verification.  Never raises.
function M.verify(password, stored)
  if type(password) ~= 'string' then return false, 'password must be a string' end
  local salt, dk, n = parse(stored)
  if not salt then return false, dk end
  local ok, calc = pcall(M.derive, password, salt, n, #dk)
  if not ok then return false, 'derivation failed' end
  return hmac.equals(calc, dk)
end

--- True when the stored hash was produced with weaker parameters than the current defaults
--- (or than `opts`), i.e. it should be re-hashed the next time the password is known.
function M.needsRehash(stored, opts)
  opts = opts or {}
  local p = M.params(stored)
  if not p then return true end
  return p.iterations < (tonumber(opts.iterations) or M.DEFAULT_ITERATIONS)
      or p.saltLen    < (tonumber(opts.saltLen)    or M.DEFAULT_SALT_LEN)
      or p.dkLen      < (tonumber(opts.dkLen)      or M.DEFAULT_DK_LEN)
end

return M
