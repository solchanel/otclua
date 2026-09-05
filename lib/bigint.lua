-- lib/bigint.lua -- fixed-width unsigned big integers for RSA (16-bit limbs, little-endian)
--
-- A "num" is a plain Lua table with array entries [1]..[n] (limb 1 = least significant, each limb
-- in [0, 65536)) plus the field `n` = limb count.
--
-- Why 16-bit limbs: every intermediate product a*b fits in 2^32 and the Montgomery accumulator
-- t[j] + a*b + carry stays below 2^33 -- exactly representable as a double. With 24- or 32-bit
-- limbs the products would exceed the 2^53 exact range of a double and silently lose low bits
-- (the same trap docs/login-http-and-packet.md flags for the FNV-1a hash). No bit.* ops are used
-- here at all, so the "bit.band returns a signed number" trap cannot bite either.
--
-- Modular arithmetic uses Montgomery multiplication (CIOS), which needs an ODD modulus -- always
-- true for an RSA modulus.

local M = {}

local floor  = math.floor
local sbyte  = string.byte
local schar  = string.char
local concat = table.concat

local B     = 65536         -- limb radix
local LOGB  = 16

--==========================================================================================
-- construction / conversion
--==========================================================================================

function M.zero(n)
    local t = { n = n }
    for i = 1, n do t[i] = 0 end
    return t
end

function M.one(n)
    local t = M.zero(n)
    t[1] = 1
    return t
end

function M.copy(a, n)
    n = n or a.n
    local t = { n = n }
    for i = 1, n do t[i] = a[i] or 0 end
    return t
end

--- Re-express `a` with exactly `n` limbs. Errors if `a` does not fit.
function M.resize(a, n)
    for i = n + 1, a.n do
        if a[i] ~= 0 then error("bigint.resize: value does not fit in " .. n .. " limbs", 2) end
    end
    return M.copy(a, n)
end

--- Parse a decimal string (the form Crypt::rsaSetPublicKey / BN_dec2bn accept).
function M.fromDecimal(s)
    if type(s) ~= 'string' then error("bigint.fromDecimal: expected string", 2) end
    s = s:gsub("%s", "")
    if s == "" or s:find("%D") then error("bigint.fromDecimal: not a decimal string", 2) end
    local acc, len = { 0 }, 1
    for i = 1, #s do
        local carry = sbyte(s, i) - 48
        for j = 1, len do
            local v = acc[j] * 10 + carry
            acc[j] = v % B
            carry = floor(v / B)
        end
        while carry > 0 do
            len = len + 1
            acc[len] = carry % B
            carry = floor(carry / B)
        end
    end
    while len > 1 and acc[len] == 0 do acc[len] = nil; len = len - 1 end
    acc.n = len
    return acc
end

--- Parse big-endian bytes (RSA_NO_PADDING interpretation).
function M.fromBytes(s)
    if type(s) ~= 'string' then error("bigint.fromBytes: expected string", 2) end
    local t, k = {}, 0
    local i = #s
    while i >= 1 do
        local lo = sbyte(s, i)
        local hi = (i - 1 >= 1) and sbyte(s, i - 1) or 0
        k = k + 1
        t[k] = lo + hi * 256
        i = i - 2
    end
    if k == 0 then k = 1; t[1] = 0 end
    while k > 1 and t[k] == 0 do t[k] = nil; k = k - 1 end
    t.n = k
    return t
end

--- Emit exactly `len` big-endian bytes, left-zero-padded (RSA output form).
function M.toBytes(a, len)
    local out = {}
    for i = 1, len do out[i] = 0 end
    for i = 1, a.n do
        local v = a[i]
        local lo = v % 256
        local hi = floor(v / 256)
        local pl = len - 2 * i + 2      -- byte holding the low half of limb i
        local ph = len - 2 * i + 1      -- byte holding the high half of limb i
        if pl >= 1 then out[pl] = lo
        elseif lo ~= 0 then error("bigint.toBytes: value does not fit in " .. len .. " bytes", 2) end
        if ph >= 1 then out[ph] = hi
        elseif hi ~= 0 then error("bigint.toBytes: value does not fit in " .. len .. " bytes", 2) end
    end
    local parts, p = {}, 0
    for i = 1, len, 64 do
        local last = i + 63
        if last > len then last = len end
        p = p + 1
        parts[p] = schar(unpack(out, i, last))
    end
    return concat(parts)
end

--- Decimal rendering (test/debug helper; O(digits * limbs)).
function M.toDecimal(a)
    local work, len = {}, a.n
    for i = 1, len do work[i] = a[i] end
    while len > 1 and work[len] == 0 do len = len - 1 end
    if len == 1 and work[1] == 0 then return "0" end
    local digits, d = {}, 0
    while not (len == 1 and work[1] == 0) do
        local rem = 0
        for i = len, 1, -1 do
            local cur = rem * B + work[i]
            work[i] = floor(cur / 10)
            rem = cur % 10
        end
        d = d + 1
        digits[d] = rem
        while len > 1 and work[len] == 0 do len = len - 1 end
    end
    local out = {}
    for i = d, 1, -1 do out[#out + 1] = digits[i] end
    return table.concat(out)
end

--==========================================================================================
-- comparison / in-place primitives (operands must already have the same limb count)
--==========================================================================================

--- @return number -1, 0 or 1
function M.cmp(a, b, n)
    n = n or a.n
    for i = n, 1, -1 do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return (x < y) and -1 or 1 end
    end
    return 0
end

function M.isZero(a, n)
    n = n or a.n
    for i = 1, n do if a[i] ~= 0 then return false end end
    return true
end

--- a -= b (assumes a >= b), n limbs, in place.
local function subInPlace(a, b, n)
    local borrow = 0
    for i = 1, n do
        local v = a[i] - b[i] - borrow
        if v < 0 then v = v + B; borrow = 1 else borrow = 0 end
        a[i] = v
    end
    return borrow
end
M.subInPlace = subInPlace

--- x = 2x mod m, in place. Requires 0 <= x < m and m odd/positive with n limbs.
local function dblMod(x, m, n)
    local carry = 0
    for i = 1, n do
        local v = x[i] * 2 + carry
        if v >= B then x[i] = v - B; carry = 1 else x[i] = v; carry = 0 end
    end
    if carry == 1 then
        -- 2x = 2^(16n) + low ; since m < 2^(16n) the subtraction borrow cancels the carry.
        subInPlace(x, m, n)
    elseif M.cmp(x, m, n) >= 0 then
        subInPlace(x, m, n)
    end
end

--==========================================================================================
-- Montgomery context
--==========================================================================================

local Mont = {}
Mont.__index = Mont

--- Build a Montgomery context for an odd modulus.
function M.mont(m)
    local n = m.n
    while n > 1 and m[n] == 0 do n = n - 1 end
    m = M.copy(m, n)
    if m[1] % 2 == 0 then error("bigint.mont: modulus must be odd", 2) end
    if n == 1 and m[1] <= 1 then error("bigint.mont: modulus must be > 1", 2) end

    -- n0inv = -m[1]^-1 mod 2^16, via Newton/Hensel lifting (inv is correct mod 2^(2^k)).
    local m0 = m[1]
    local inv = 1
    for _ = 1, 5 do
        inv = (inv * ((2 - m0 * inv) % B)) % B
    end
    local n0inv = (B - inv) % B

    local ctx = setmetatable({ n = n, m = m, n0inv = n0inv }, Mont)

    -- r2 = 2^(2*16n) mod m, by 32n successive doublings starting from 1.
    local x = M.one(n)
    if M.cmp(x, m, n) >= 0 then subInPlace(x, m, n) end
    for _ = 1, 2 * LOGB * n do dblMod(x, m, n) end
    ctx.r2 = x
    ctx.mont1 = nil
    return ctx
end

--- Montgomery product: returns a*b*R^-1 mod m, where R = 2^(16n). Operands must be < m.
function Mont:mul(a, b)
    local n, m, n0inv = self.n, self.m, self.n0inv
    local t = {}
    for i = 1, n + 2 do t[i] = 0 end

    for i = 1, n do
        local ai = a[i]
        local C = 0
        -- t += a[i] * b
        for j = 1, n do
            local s = t[j] + ai * b[j] + C
            local lo = s % B
            t[j] = lo
            C = (s - lo) / B
        end
        local s = t[n + 1] + C
        local lo = s % B
        t[n + 1] = lo
        t[n + 2] = t[n + 2] + (s - lo) / B

        -- t += (t[1] * n0inv mod 2^16) * m   -> makes t[1] zero
        local mm = (t[1] * n0inv) % B
        C = 0
        for j = 1, n do
            local s2 = t[j] + mm * m[j] + C
            local lo2 = s2 % B
            t[j] = lo2
            C = (s2 - lo2) / B
        end
        s = t[n + 1] + C
        lo = s % B
        t[n + 1] = lo
        t[n + 2] = t[n + 2] + (s - lo) / B

        -- t >>= 16 (one limb)
        for j = 1, n + 1 do t[j] = t[j + 1] end
        t[n + 2] = 0
    end

    -- t is now < 2m and occupies n+1 limbs; conditional subtract.
    local res = { n = n }
    for i = 1, n do res[i] = t[i] end
    if t[n + 1] ~= 0 or M.cmp(res, m, n) >= 0 then
        subInPlace(res, m, n)
    end
    return res
end

--- Convert to Montgomery form: a -> a*R mod m.
function Mont:toMont(a)
    return self:mul(a, self.r2)
end

--- Convert out of Montgomery form: aR -> a.
function Mont:fromMont(a)
    local one = M.zero(self.n)
    one[1] = 1
    return self:mul(a, one)
end

--- base^e mod m. `e` is a non-negative Lua integer (< 2^53). Square-and-multiply, MSB first.
function Mont:powmod(base, e)
    local n = self.n
    e = floor(e)
    if e < 0 then error("bigint: negative exponent", 2) end
    local a = M.copy(base, n)
    if M.cmp(a, self.m, n) >= 0 then error("bigint.powmod: base >= modulus", 2) end
    if e == 0 then return M.one(n) end

    -- collect the exponent bits, MSB first
    local bits, nb = {}, 0
    local x = e
    while x > 0 do
        nb = nb + 1
        bits[nb] = x % 2
        x = floor(x / 2)
    end

    local aM = self:toMont(a)
    local r = aM
    for i = nb - 1, 1, -1 do
        r = self:mul(r, r)
        if bits[i] == 1 then r = self:mul(r, aM) end
    end
    return self:fromMont(r)
end

M.LIMB_BITS = LOGB

return M
