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
--        *** NOT for the login endpoint: it returns instantly for an unparsable stored string.
--        Use verifyOrDummy() there -- see TIMING below. ***
--   pbkdf2.verifyOrDummy(password, stored) -> boolean
--        Same answer, constant cost: an absent/corrupt `stored` burns a real derivation first.
--   pbkdf2.dummyStored() -> the stand-in stored string verifyOrDummy() burns against
--   pbkdf2.params(stored) -> { iterations=, saltLen=, dkLen=, prf='sha256' } | nil, err
--   pbkdf2.needsRehash(stored [, opts]) -> boolean   (stored below the current cost/param set)
--
-- COST.  PANEL.md asks for >= 200,000 iterations and DEFAULT_ITERATIONS is exactly that.  One
-- iteration is two SHA-256 compressions.  Measured 2026-09-06 with dkLen = 32, best of 3 runs,
-- on the two target machines this repo is developed against -- a desktop Zen-class x86-64 host
-- (Windows 11) and Debian under WSL2 on the SAME host.  Run-to-run spread is roughly 5-15%, so
-- treat these as the shape of the curve, not as a contract; test/cryptosuite.lua's
-- "pbkdf2 / cost" note prints the live figure with sys.os and jit.version on every run, and
-- that live figure is the one to size a deployment from.
--
--     iterations |  Windows (LuaJIT 2.1.1781602682) | Debian/WSL (LuaJIT 2.1.1737090214)
--        100,000 |            136 ms                |            126 ms
--        200,000 |            273 ms                |            250 ms
--        250,000 |            341 ms                |            312 ms
--        800,000 |           1090 ms                |            994 ms
--
-- 200k is therefore the largest round number inside the ~300 ms budget on both; 250k is already
-- over it on Windows (341 ms), so do not read the 250k row as headroom.  It is a per-login cost
-- paid once, on a single-threaded hub, so raising it further trades login latency (and a DoS
-- surface on the login endpoint) for brute-force resistance.  The count is stored inside every
-- hash, so old hashes keep verifying after a change and needsRehash() flags them for upgrade at
-- the next successful login.
--
-- MAX_ITERATIONS is deliberately only 4x the default.  parse() accepts the iteration count out
-- of a *stored string*, and verify() then runs it synchronously with no way to yield (derive()
-- is a tight loop, not a coroutine).  On PANEL.md's single-threaded hub that is whole-process
-- stall time: at the old 5,000,000 ceiling one hand-edited or hostile users.json row froze the
-- hub -- every worker's telemetry and every panel socket -- for ~6.9 s per login attempt.  At
-- 800,000 the worst case a data file can dictate is ~1.1 s.
--
-- The hub must additionally serialise logins behind a queue with a concurrency of 1 and a short
-- cap on queued attempts, because even the honest 273 ms is uninterruptible.  If a yielding
-- variant is ever needed, add M.deriveStep(state) that returns after N iterations so the caller
-- can coroutine.yield between chunks; do not raise MAX_ITERATIONS instead.
--
-- TIMING (login-path requirement).  verify() costs ~273 ms for a parsable stored string and
-- ~0 ms for one it cannot parse.  The natural hub line `pbkdf2.verify(pw, user and user.pwhash
-- or '')` therefore leaks account existence by response time alone (measured ratio ~550,000x),
-- which is exactly what per-account rate limiting cannot fix.  The login endpoint MUST call
-- verifyOrDummy() and MUST NOT branch on account existence before it.
--
-- HAZARDS -- Lua-level facts about password material that cannot be fixed here, only worked
-- around by the operator (lib/hmac.lua and lib/authsecret.lua point at this block):
--   * Passwords and derived keys are LuaJIT strings.  Every string is INTERNED in a global hash
--     table, so a password is not merely alive until the next GC: it is reachable from a table
--     anyone walking a core dump or a swapped-out page can enumerate, and an identical password
--     submitted later hits the same interned object.
--   * There is no secure erase.  `s = nil` plus collectgarbage() frees the object without
--     zeroing it, and the allocator need not return the page to the OS.
--   * Every step multiplies copies that likewise cannot be scrubbed: hmac.padBlocks builds two
--     64-byte derivatives of the password, base64.decode builds a table of 3-byte fragments of
--     the salt and derived key, and `..` in authsecret's macInput copies the plaintext again.
--   * Therefore a core dump, a swap file or a hibernation image of the hub process must be
--     treated as containing every password handled since boot.  Disable core dumps for the hub
--     (RLIMIT_CORE 0 on Linux; no local dump collection on Windows).
--   * Never pass a password through an environment variable: /proc/PID/environ is readable, and
--     sys.getEnv reads the same process environment.
--   * Never call log.hex on, or log any value derived from, a password.  PANEL.md forwards log
--     lines to every connected panel session as `log` events.
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
M.MIN_SALT_LEN       = 8              -- the same floor on the way in AND on the way out
-- Ceiling on the iteration count parsed out of a STORED string.  Kept at a small multiple of
-- the default so a data file cannot dictate seconds of synchronous work -- see the COST block.
M.MAX_ITERATIONS     = 4 * M.DEFAULT_ITERATIONS   -- 800,000, ~1.1 s worst case

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
  -- parse() demands integers on the way out; hold hash() to the same standard on the way in,
  -- so the '%d' below can never record a different number than derive() actually ran.
  if iterations ~= math.floor(iterations) then
    error('pbkdf2.hash: iterations must be an integer', 2)
  end
  if saltLen ~= math.floor(saltLen) or dkLen ~= math.floor(dkLen) then
    error('pbkdf2.hash: saltLen and dkLen must be integers', 2)
  end

  -- ONE length floor for both paths.  An explicit opts.salt used to skip this entirely, so
  -- hash(pw, {salt=''}) minted an unsalted credential that parse() then refused to verify.
  local salt = opts.salt
  if salt == nil then
    if saltLen < M.MIN_SALT_LEN then
      error(sformat('pbkdf2.hash: saltLen must be >= %d', M.MIN_SALT_LEN), 2)
    end
    salt = require('lib.sys').randomBytes(saltLen)
  elseif type(salt) ~= 'string' then
    error('pbkdf2.hash: salt must be a string', 2)
  elseif #salt < M.MIN_SALT_LEN then
    error(sformat('pbkdf2.hash: salt must be at least %d bytes', M.MIN_SALT_LEN), 2)
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
  if #salt < M.MIN_SALT_LEN then return nil, 'salt too short' end
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

--- The stand-in `stored` string verifyOrDummy() burns a derivation against when the real one is
--- missing or unparsable.  It is built by string formatting only -- NOT by hashing anything -- so
--- requiring this module costs nothing, and it deliberately is not the hash of any password: the
--- comparison must always fail.  The iteration count tracks DEFAULT_ITERATIONS so the burn keeps
--- costing exactly what a freshly created account's verify costs.
local DUMMY_SALT = base64.encode('luaclient/pbkdf2/dummy-salt/v1')
local DUMMY_DK   = base64.encode(('\0'):rep(M.DEFAULT_DK_LEN))
function M.dummyStored()
  return sformat('pbkdf2$sha256$%d$%s$%s', M.DEFAULT_ITERATIONS, DUMMY_SALT, DUMMY_DK)
end

--- Equal-cost verification for the LOGIN PATH.  Use this, never verify(), wherever `stored` may
--- be absent because the account does not exist: verify() returns in ~0 ms for an unparsable
--- string and ~273 ms for a real one, which tells an unauthenticated caller which usernames
--- exist from response time alone.  Callers must not branch on account existence before this.
--- Returns a bare boolean -- there is no diagnostic, because a diagnostic would leak the same
--- distinction the burn exists to hide.
function M.verifyOrDummy(password, stored)
  if type(password) ~= 'string' then return false end
  if type(stored) ~= 'string' or not parse(stored) then
    M.verify(password, M.dummyStored())          -- burn the same time, discard the result
    return false
  end
  return (M.verify(password, stored)) and true or false
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
