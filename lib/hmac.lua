-- lib/hmac.lua -- HMAC-SHA256 (RFC 2104 / FIPS 198-1) on top of lib/sha2.lua.
--
--   HMAC(K, m) = H( (K0 xor opad) || H( (K0 xor ipad) || m ) )
--   K0 = K padded with zeros to 64 bytes, or SHA-256(K) zero-padded when #K > 64.
--   A zero-length key is legal (K0 = 64 zero bytes).
--
-- API
--   hmac.sha256(key, msg)     -> raw 32-byte tag
--   hmac.sha256hex(key, msg)  -> 64 hex chars
--   hmac.new(key)             -> streaming context
--        c:update(s) -> c ; c:digest() -> raw ; c:hexdigest() ; c:reset() -> c
--        c.innerH / c.outerH  -- 8-word SHA-256 states after absorbing the ipad/opad block.
--                                lib/pbkdf2.lua copies these to run its inner loop without
--                                touching a single string.  Do not mutate them.
--   hmac.equals(a, b)         -> boolean, comparison in time independent of WHERE the two
--                                equal-length strings differ (lengths are compared openly).
--
-- Verified against RFC 4231 test cases 1-7 and cross-checked against Python's hmac module -- see
-- test/cryptosuite.lua.  Cases 1-7 cover keys shorter than, equal to and longer than the 64-byte
-- block (cases 6 and 7 use a 131-byte key, which forces the hash-the-key path).

local sha2 = require('lib.sha2')
local bit  = require('bit')
local bxor, bor, band = bit.bxor, bit.bor, bit.band
local sbyte, schar, srep, concat = string.byte, string.char, string.rep, table.concat

local M = {}

local BLOCK = 64

local IPAD, OPAD = {}, {}
for i = 0, 255 do IPAD[i] = schar(bxor(i, 0x36)); OPAD[i] = schar(bxor(i, 0x5c)) end

local IPAD0 = srep(schar(0x36), BLOCK)      -- all-zero key xor ipad
local OPAD0 = srep(schar(0x5c), BLOCK)

local C = {}
C.__index = C

--- Build the two padded key blocks for `key`.
local function padBlocks(key)
  if #key > BLOCK then key = sha2.sha256(key) end
  local n = #key
  if n == 0 then return IPAD0, OPAD0 end
  local a, b = {}, {}
  for i = 1, n do
    local c = sbyte(key, i)
    a[i] = IPAD[c]; b[i] = OPAD[c]
  end
  if n < BLOCK then
    a[n + 1] = srep(schar(0x36), BLOCK - n)
    b[n + 1] = srep(schar(0x5c), BLOCK - n)
  end
  return concat(a), concat(b)
end

--- Streaming HMAC-SHA256 context.  Creating one costs two SHA-256 compressions; reset() is free.
function M.new(key)
  if type(key) ~= 'string' then error('hmac.new: key must be a string', 2) end
  local ib, ob = padBlocks(key)
  local innerH = sha2.new256():update(ib).H     -- state after exactly one block
  local outerH = sha2.new256():update(ob).H
  local self = setmetatable({ innerH = innerH, outerH = outerH }, C)
  return self:reset()
end

function C:reset()
  local h = self.innerH
  self.d = sha2.resume256({ h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8] }, BLOCK)
  return self
end

function C:update(s) self.d:update(s); return self end

--- Non-destructive: the context may keep absorbing data afterwards.
function C:digest()
  local h = self.outerH
  local outer = sha2.resume256({ h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8] }, BLOCK)
  return outer:update(self.d:digest()):digest()
end

function C:hexdigest() return sha2.tohex(self:digest()) end

-- ------------------------------------------------------------------ one-shot
function M.sha256(key, msg)
  return M.new(key):update(msg):digest()
end

function M.sha256hex(key, msg)
  return sha2.tohex(M.sha256(key, msg))
end

-- ------------------------------------------------- constant-time comparison
--- True when `a` and `b` are byte-identical.  The loop always runs over the whole string and
--- accumulates differences instead of returning early, so the running time does not depend on
--- the position of the first mismatching byte.  A length mismatch returns immediately: in this
--- codebase the compared values are fixed-size digests, so their length is not a secret.
--- (Caveat, stated honestly: this is "constant time" only at the level of the Lua source.  A
--- tracing JIT, the GC and the CPU's caches make true constant time unattainable in pure Lua.)
function M.equals(a, b)
  if type(a) ~= 'string' or type(b) ~= 'string' then return false end
  if #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do
    diff = bor(diff, bxor(sbyte(a, i), sbyte(b, i)))
  end
  return band(diff, 0xff) == 0
end

M.BLOCK = BLOCK

return M
