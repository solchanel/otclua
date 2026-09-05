-- lib/xtea.lua -- XTEA/32 in ECB mode, little-endian words (protocol.cpp:340-420)
--
--   delta = 0x9E3779B9 ; 32 rounds ; encrypt sum starts at 0 ; decrypt sum starts at delta<<5
--   = 0xC6EF3720 (write the literal: `bit.band(DELTA*32, 0xFFFFFFFF)` is BOTH inexact -- the
--   product 84941944608 is computed as a double -- and signed. See docs/framing-crypto.md
--   VERIFIER correction #5).
--
-- Each 8-byte block: L = b0|b1<<8|b2<<16|b3<<24, R = b4..b7, written back little-endian.
-- The C++ applies one round across all blocks before advancing `sum`; blocks are independent, so
-- running 32 rounds per block is byte-identical.
--
-- LuaJIT arithmetic notes:
--  * bit.band/bxor/lshift return a SIGNED 32-bit number. Every value that leaves a bit.* call and
--    is then used as an unsigned integer is normalised with `% 0x100000000` (Lua's `%` is floored,
--    so it always yields a non-negative result).
--  * `x + y` where x is a signed bit.* result and y is unsigned is still correct mod 2^32, so the
--    normalisation is deferred to the end of each expression -- magnitudes stay well inside the
--    2^53 exact range of a double.
--  * `>>5` must be a LOGICAL shift: bit.rshift is logical, bit.arshift is not. We use rshift.

local bit = require('bit')
local band, bxor, lshift, rshift = bit.band, bit.bxor, bit.lshift, bit.rshift
local sbyte, schar, concat, floor = string.byte, string.char, table.concat, math.floor

local M = {}

local DELTA = 0x9E3779B9
local M32   = 0x100000000
local DEC_SUM0 = 0xC6EF3720          -- delta << 5

-- The round constants depend only on the key, never on the data, so precompute all 32 of them.
-- encrypt: A[i] = sum      + k[(sum & 3) + 1]
--          B[i] = next_sum + k[((next_sum >> 11) & 3) + 1]
local function encSchedule(k)
    local A, B = {}, {}
    local sum = 0
    for i = 1, 32 do
        local nsum = (sum + DELTA) % M32
        A[i] = (sum  + k[band(sum, 3) + 1]) % M32
        B[i] = (nsum + k[band(rshift(nsum, 11), 3) + 1]) % M32
        sum = nsum
    end
    return A, B
end

-- decrypt: C[i] = sum      + k[((sum >> 11) & 3) + 1]
--          D[i] = next_sum + k[(next_sum & 3) + 1]
local function decSchedule(k)
    local C, D = {}, {}
    local sum = DEC_SUM0
    for i = 1, 32 do
        local nsum = (sum - DELTA) % M32
        C[i] = (sum  + k[band(rshift(sum, 11), 3) + 1]) % M32
        D[i] = (nsum + k[band(nsum, 3) + 1]) % M32
        sum = nsum
    end
    return C, D
end

local function checkKey(key)
    if type(key) ~= 'table' then error("xtea: key must be a table of 4 u32", 3) end
    local k = {}
    for i = 1, 4 do
        local v = key[i]
        if type(v) ~= 'number' then error("xtea: key[" .. i .. "] is not a number", 3) end
        k[i] = floor(v) % M32
    end
    return k
end

local function checkData(s, what)
    if type(s) ~= 'string' then error("xtea: " .. what .. " must be a string", 3) end
    if #s % 8 ~= 0 then
        error(string.format("xtea: %s length %d is not a multiple of 8", what, #s), 3)
    end
end

--- @param key table {u32,u32,u32,u32}
--- @param s string  length must be a multiple of 8
function M.encrypt(key, s)
    local k = checkKey(key)
    checkData(s, 'plaintext')
    local n = #s
    if n == 0 then return "" end
    local A, B = encSchedule(k)
    local out, o = {}, 0
    for i = 1, n, 8 do
        local b1, b2, b3, b4, b5, b6, b7, b8 = sbyte(s, i, i + 7)
        local L = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        local R = b5 + b6 * 256 + b7 * 65536 + b8 * 16777216
        for r = 1, 32 do
            L = (L + bxor((bxor(lshift(R, 4), rshift(R, 5)) + R) % M32, A[r])) % M32
            R = (R + bxor((bxor(lshift(L, 4), rshift(L, 5)) + L) % M32, B[r])) % M32
        end
        o = o + 1
        out[o] = schar(L % 256, floor(L / 256) % 256, floor(L / 65536) % 256, floor(L / 16777216),
                       R % 256, floor(R / 256) % 256, floor(R / 65536) % 256, floor(R / 16777216))
    end
    return concat(out)
end

--- @param key table {u32,u32,u32,u32}
--- @param s string  length must be a multiple of 8
function M.decrypt(key, s)
    local k = checkKey(key)
    checkData(s, 'ciphertext')
    local n = #s
    if n == 0 then return "" end
    local C, D = decSchedule(k)
    local out, o = {}, 0
    for i = 1, n, 8 do
        local b1, b2, b3, b4, b5, b6, b7, b8 = sbyte(s, i, i + 7)
        local L = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        local R = b5 + b6 * 256 + b7 * 65536 + b8 * 16777216
        for r = 1, 32 do
            R = (R - bxor((bxor(lshift(L, 4), rshift(L, 5)) + L) % M32, C[r])) % M32
            L = (L - bxor((bxor(lshift(R, 4), rshift(R, 5)) + R) % M32, D[r])) % M32
        end
        o = o + 1
        out[o] = schar(L % 256, floor(L / 256) % 256, floor(L / 65536) % 256, floor(L / 16777216),
                       R % 256, floor(R / 256) % 256, floor(R / 65536) % 256, floor(R / 16777216))
    end
    return concat(out)
end

M.DELTA = DELTA

return M
