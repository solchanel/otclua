-- lib/sha2.lua -- SHA-256 and SHA-224 (FIPS 180-4) in pure Lua, no FFI, no C.
--
-- API
--   sha2.sha256(s)        -> raw 32-byte string          sha2.sha256hex(s) -> 64 hex chars
--   sha2.sha224(s)        -> raw 28-byte string          sha2.sha224hex(s) -> 56 hex chars
--   sha2.new256() / sha2.new224() -> streaming digest object
--        d:update(s) -> d      (chainable, any number of calls, any chunk sizes)
--        d:digest()  -> raw    (non-destructive: d may be updated further afterwards)
--        d:hexdigest() -> hex
--        d:digestWords() -> {8 signed-int32 words}   (256 only; used by hmac/pbkdf2)
--        d:clone()   -> independent copy of the state
--        d:reset()   -> back to the initial vector
--   sha2.tohex(raw)       -> lowercase hex of an arbitrary byte string
--   sha2.BLOCK = 64, sha2.SIZE256 = 32, sha2.SIZE224 = 28
--
-- Low-level entry points (documented because lib/hmac.lua and lib/pbkdf2.lua use them; they are
-- the reason PBKDF2 can run its inner loop with zero string allocation):
--   sha2.iv256() / sha2.iv224()   -> fresh 8-word state table
--   sha2.compress(H, w)           -- H: 8 words, mutated in place.  w: at least 16 words holding
--                                    one big-endian 512-bit block; w[17..64] are OVERWRITTEN with
--                                    the message schedule, so pass a scratch table you own.
--   sha2.resume256(H, byteCount)  -> digest object continuing from an existing state that has
--                                    already absorbed `byteCount` bytes (a whole number of blocks)
--   sha2.wordsToBytes(words, n)   -> raw string of the first n words, big-endian
--
-- Representation: every 32-bit word is a SIGNED int32 as produced by the `bit` library
-- (bit.tobit).  Additions are done on doubles and folded back with bit.tobit -- five signed
-- 32-bit terms sum to at most ~2^33.4, far inside the 2^53 exact range of a double, so no
-- precision is lost.  Nothing here is normalised with % 0x100000000 except where an unsigned
-- value is actually needed (hex formatting), per the project's LuaJIT arithmetic rules.
--
-- Correctness: verified against the NIST/FIPS 180-4 vectors ("", "abc", the 448-bit and 896-bit
-- messages, 1,000,000 x 'a') and against Python's hashlib at every length from 0 to 129 plus the
-- padding boundaries 55/56/63/64/119/120 -- see test/cryptosuite.lua.

local bit = require('bit')
local band, bxor, bnot   = bit.band, bit.bxor, bit.bnot
local ror, rshift, tobit = bit.ror, bit.rshift, bit.tobit
local sbyte, schar, srep, ssub = string.byte, string.char, string.rep, string.sub
local sformat, concat, floor   = string.format, table.concat, math.floor

local M = {}

M.BLOCK    = 64
M.SIZE256  = 32
M.SIZE224  = 28

-- ------------------------------------------------------------------ constants
-- First 32 bits of the fractional parts of the cube roots of the first 64 primes.
local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
for i = 1, 64 do K[i] = tobit(K[i]) end

local IV256 = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
local IV224 = { 0xc1059ed8, 0x367cd507, 0x3070dd17, 0xf70e5939,
                0xffc00b31, 0x68581511, 0x64f98fa7, 0xbefa4fa4 }
for i = 1, 8 do IV256[i] = tobit(IV256[i]); IV224[i] = tobit(IV224[i]) end

function M.iv256() local t = IV256; return { t[1],t[2],t[3],t[4],t[5],t[6],t[7],t[8] } end
function M.iv224() local t = IV224; return { t[1],t[2],t[3],t[4],t[5],t[6],t[7],t[8] } end

-- --------------------------------------------------------------- compression
--- One 512-bit block.  `H` (8 words) is updated in place; `w[1..16]` is the block and
--- `w[17..64]` is clobbered with the expanded schedule.
local function compress(H, w)
  for i = 17, 64 do
    local x, y = w[i - 15], w[i - 2]
    local s0 = bxor(ror(x, 7),  ror(x, 18), rshift(x, 3))
    local s1 = bxor(ror(y, 17), ror(y, 19), rshift(y, 10))
    w[i] = tobit(s0 + s1 + w[i - 16] + w[i - 7])
  end

  local a, b, c, d = H[1], H[2], H[3], H[4]
  local e, f, g, h = H[5], H[6], H[7], H[8]

  for i = 1, 64 do
    local S1  = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
    local ch  = bxor(band(e, f), band(bnot(e), g))
    local t1  = tobit(h + S1 + ch + K[i] + w[i])
    local S0  = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
    local maj = bxor(band(a, b), band(a, c), band(b, c))
    h = g; g = f; f = e
    e = tobit(d + t1)
    d = c; c = b; b = a
    a = tobit(t1 + S0 + maj)
  end

  H[1] = tobit(H[1] + a); H[2] = tobit(H[2] + b)
  H[3] = tobit(H[3] + c); H[4] = tobit(H[4] + d)
  H[5] = tobit(H[5] + e); H[6] = tobit(H[6] + f)
  H[7] = tobit(H[7] + g); H[8] = tobit(H[8] + h)
end
M.compress = compress

--- Load 64 bytes of `s` starting at 1-based `o` into w[1..16], big-endian.
local function loadBlock(w, s, o)
  for i = 1, 16 do
    local b1, b2, b3, b4 = sbyte(s, o, o + 3)
    w[i] = tobit(b1 * 0x1000000 + b2 * 0x10000 + b3 * 0x100 + b4)
    o = o + 4
  end
end

--- Big-endian bytes of the first `n` words.
local function wordsToBytes(words, n)
  local t = {}
  for i = 1, n do
    local x = words[i]
    t[i] = schar(band(rshift(x, 24), 0xff), band(rshift(x, 16), 0xff),
                 band(rshift(x, 8),  0xff), band(x, 0xff))
  end
  return concat(t)
end
M.wordsToBytes = wordsToBytes

local HEX = {}
for i = 0, 255 do HEX[i] = sformat('%02x', i) end

function M.tohex(s)
  local n = #s
  local t = {}
  for i = 1, n do t[i] = HEX[sbyte(s, i)] end
  return concat(t)
end

-- ------------------------------------------------------------ digest object
local D = {}
D.__index = D

local function newDigest(H, len, size)
  return setmetatable({ H = H, len = len or 0, tail = '', size = size, w = {} }, D)
end

function M.new256() return newDigest(M.iv256(), 0, 32) end
function M.new224() return newDigest(M.iv224(), 0, 28) end

--- Continue from a state that has already absorbed `byteCount` bytes (a multiple of 64).
--- `H` is taken over by the object, not copied.
function M.resume256(H, byteCount)
  return newDigest(H, byteCount or 0, 32)
end

function D:reset()
  self.H    = (self.size == 28) and M.iv224() or M.iv256()
  self.len  = 0
  self.tail = ''
  return self
end

function D:clone()
  local H = self.H
  local d = newDigest({ H[1],H[2],H[3],H[4],H[5],H[6],H[7],H[8] }, self.len, self.size)
  d.tail = self.tail
  return d
end

function D:update(s)
  if type(s) ~= 'string' then
    error('sha2: update() expects a string, got ' .. type(s), 2)
  end
  local n = #s
  if n == 0 then return self end
  self.len = self.len + n

  local tail = self.tail
  if #tail > 0 then s = tail .. s; n = #s end

  local H, w = self.H, self.w
  local i = 1
  while n - i >= 63 do            -- at least 64 bytes remain from position i
    loadBlock(w, s, i)
    compress(H, w)
    i = i + 64
  end
  self.tail = (i > n) and '' or ssub(s, i)
  return self
end

--- Final state as 8 words, WITHOUT touching this object (so update() may continue).
function D:digestWords()
  local H = self.H
  local F = { H[1],H[2],H[3],H[4],H[5],H[6],H[7],H[8] }
  local len  = self.len
  local pad  = (55 - len) % 64                     -- so that (len + 1 + pad) % 64 == 56
  local hi   = floor(len / 0x20000000) % 0x100000000   -- (len*8) >> 32
  local lo   = (len * 8) % 0x100000000
  local last = self.tail .. '\128' .. srep('\0', pad) ..
               schar(band(rshift(tobit(hi), 24), 0xff), band(rshift(tobit(hi), 16), 0xff),
                     band(rshift(tobit(hi), 8), 0xff),  band(tobit(hi), 0xff),
                     band(rshift(tobit(lo), 24), 0xff), band(rshift(tobit(lo), 16), 0xff),
                     band(rshift(tobit(lo), 8), 0xff),  band(tobit(lo), 0xff))
  local w = {}
  for o = 1, #last, 64 do
    loadBlock(w, last, o)
    compress(F, w)
  end
  return F
end

function D:digest()
  return wordsToBytes(self:digestWords(), (self.size == 28) and 7 or 8):sub(1, self.size)
end

function D:hexdigest() return M.tohex(self:digest()) end

-- ------------------------------------------------------------------ one-shot
function M.sha256(s)    return M.new256():update(s):digest() end
function M.sha256hex(s) return M.new256():update(s):hexdigest() end
function M.sha224(s)    return M.new224():update(s):digest() end
function M.sha224hex(s) return M.new224():update(s):hexdigest() end

return M
