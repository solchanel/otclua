-- lib/sha1.lua -- SHA-1 (RFC 3174 / FIPS 180-4) in pure Lua, no FFI, no C.
--
-- SHA-1 is here for exactly ONE reason: RFC 6455 section 4.2.2 defines the WebSocket
-- handshake as base64(SHA1(key .. GUID)).  That use is a fixed, public, non-secret
-- transformation -- it is NOT a security primitive and SHA-1 must not be used for
-- anything else in this repo (passwords go through lib/pbkdf2.lua, integrity through
-- lib/sha2.lua / lib/hmac.lua).
--
-- API -- deliberately shaped like lib/sha2.lua so the two are interchangeable:
--   sha1.sha1(s)     -> raw 20-byte string        sha1.sha1hex(s) -> 40 lowercase hex chars
--   sha1.new()       -> streaming digest object
--        d:update(s)     -> d    (chainable, any number of calls, any chunk sizes)
--        d:digest()      -> raw  (non-destructive: d may be updated further afterwards)
--        d:hexdigest()   -> hex
--        d:digestWords() -> {5 signed-int32 words}
--        d:clone()       -> independent copy of the state
--        d:reset()       -> back to the initial vector
--   sha1.tohex(raw)  -> lowercase hex of an arbitrary byte string
--   sha1.BLOCK = 64, sha1.SIZE = 20
--
-- Low-level entry points (same contract as lib/sha2.lua):
--   sha1.iv()          -> fresh 5-word state table
--   sha1.compress(H,w) -- H: 5 words, mutated in place.  w: at least 16 words holding one
--                         big-endian 512-bit block; w[17..80] are OVERWRITTEN with the
--                         message schedule, so pass a scratch table you own.
--
-- Representation: every 32-bit word is a SIGNED int32 as produced by the `bit` library
-- (bit.tobit), exactly as in lib/sha2.lua.  The round sum has five signed int32 terms, so
-- |sum| < 5 * 2^31 ~= 2^33.4 -- far inside the 2^53 exact range of a double, so folding it
-- back with bit.tobit loses nothing.  Nothing is normalised with % 0x100000000 except where
-- an unsigned value is genuinely needed (hex formatting, the length encoding).
--
-- Correctness: the RFC 3174 section 7.3 vectors ("abc", the 448-bit message, 1,000,000 x 'a',
-- and the 10-times-repeated 64-char message) plus a length sweep cross-checked against
-- Python's hashlib -- see test/wssuite.lua.

local bit = require('bit')
local band, bxor, bor, bnot = bit.band, bit.bxor, bit.bor, bit.bnot
local rol, rshift, tobit    = bit.rol, bit.rshift, bit.tobit
local sbyte, schar, srep, ssub = string.byte, string.char, string.rep, string.sub
local sformat, concat, floor   = string.format, table.concat, math.floor

local M = {}

M.BLOCK = 64
M.SIZE  = 20

-- ------------------------------------------------------------------ constants
local K1, K2, K3, K4 = tobit(0x5a827999), tobit(0x6ed9eba1),
                       tobit(0x8f1bbcdc), tobit(0xca62c1d6)

local IV = { 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0 }
for i = 1, 5 do IV[i] = tobit(IV[i]) end

function M.iv() local t = IV; return { t[1], t[2], t[3], t[4], t[5] } end

-- -------------------------------------------------------------- compression
--- One 512-bit block.  H is mutated in place; w[1..16] must hold the block, w[17..80]
--- are scratch.
local function compress(H, w)
  for t = 17, 80 do
    w[t] = rol(bxor(bxor(w[t - 3], w[t - 8]), bxor(w[t - 14], w[t - 16])), 1)
  end

  local a, b, c, d, e = H[1], H[2], H[3], H[4], H[5]

  -- rounds 0..19   f = (b AND c) OR ((NOT b) AND d)  ==  d XOR (b AND (c XOR d))
  for t = 1, 20 do
    local tmp = tobit(rol(a, 5) + bxor(d, band(b, bxor(c, d))) + e + K1 + w[t])
    e = d; d = c; c = rol(b, 30); b = a; a = tmp
  end
  -- rounds 20..39  f = b XOR c XOR d
  for t = 21, 40 do
    local tmp = tobit(rol(a, 5) + bxor(bxor(b, c), d) + e + K2 + w[t])
    e = d; d = c; c = rol(b, 30); b = a; a = tmp
  end
  -- rounds 40..59  f = (b AND c) OR (b AND d) OR (c AND d)
  for t = 41, 60 do
    local tmp = tobit(rol(a, 5) + bor(band(b, c), band(d, bor(b, c))) + e + K3 + w[t])
    e = d; d = c; c = rol(b, 30); b = a; a = tmp
  end
  -- rounds 60..79  f = b XOR c XOR d
  for t = 61, 80 do
    local tmp = tobit(rol(a, 5) + bxor(bxor(b, c), d) + e + K4 + w[t])
    e = d; d = c; c = rol(b, 30); b = a; a = tmp
  end

  H[1] = tobit(H[1] + a); H[2] = tobit(H[2] + b); H[3] = tobit(H[3] + c)
  H[4] = tobit(H[4] + d); H[5] = tobit(H[5] + e)
end
M.compress = compress

--- Load 64 bytes at 1-based offset o of s into w[1..16], big-endian.
local function loadBlock(w, s, o)
  for i = 0, 15 do
    local b1, b2, b3, b4 = sbyte(s, o + i * 4, o + i * 4 + 3)
    w[i + 1] = tobit(b1 * 0x1000000 + b2 * 0x10000 + b3 * 0x100 + b4)
  end
end

local function wordsToBytes(words, n)
  local t = {}
  for i = 1, n do
    local v = words[i]
    t[i] = schar(band(rshift(v, 24), 0xff), band(rshift(v, 16), 0xff),
                 band(rshift(v, 8), 0xff),  band(v, 0xff))
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

local function newDigest(H, len)
  return setmetatable({ H = H, len = len or 0, tail = '', w = {} }, D)
end

function M.new() return newDigest(M.iv(), 0) end

function D:reset()
  self.H, self.len, self.tail = M.iv(), 0, ''
  return self
end

function D:clone()
  local H = self.H
  local d = newDigest({ H[1], H[2], H[3], H[4], H[5] }, self.len)
  d.tail = self.tail
  return d
end

function D:update(s)
  if type(s) ~= 'string' then
    error('sha1: update() expects a string, got ' .. type(s), 2)
  end
  local n = #s
  if n == 0 then return self end
  self.len = self.len + n

  local tail = self.tail
  if #tail > 0 then s = tail .. s; n = #s end

  local H, w = self.H, self.w
  local i = 1
  while n - i >= 63 do                 -- at least 64 bytes remain from position i
    loadBlock(w, s, i)
    compress(H, w)
    i = i + 64
  end
  self.tail = (i > n) and '' or ssub(s, i)
  return self
end

--- Final state as 5 words, WITHOUT touching this object (so update() may continue).
function D:digestWords()
  local H = self.H
  local F = { H[1], H[2], H[3], H[4], H[5] }
  local len = self.len
  local pad = (55 - len) % 64                            -- (len + 1 + pad) % 64 == 56
  local hi  = floor(len / 0x20000000) % 0x100000000      -- (len * 8) >> 32
  local lo  = (len * 8) % 0x100000000
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

function D:digest()    return wordsToBytes(self:digestWords(), 5) end
function D:hexdigest() return M.tohex(self:digest()) end

-- ------------------------------------------------------------------ one-shot
function M.sha1(s)    return M.new():update(s):digest() end
function M.sha1hex(s) return M.new():update(s):hexdigest() end

return M
