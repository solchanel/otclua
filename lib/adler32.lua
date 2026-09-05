-- lib/adler32.lua -- zlib adler32 seeded with adler32(0, Z_NULL, 0) == 1
--
-- stdext::computeChecksum (src/framework/stdext/math.cpp:39-44) is exactly RFC-1950 Adler-32:
--   A = 1; B = 0; for each byte b: A = (A + b) % 65521; B = (B + A) % 65521
--   result = (B << 16) | A            (written little-endian by writeULE32)
--
-- The result is returned as an UNSIGNED Lua number in [0, 2^32) -- computed as B*65536 + A rather
-- than bit.bor(bit.lshift(B,16), A), because bit.* would hand back a signed 32-bit value.
--
-- NOTE: the 1530 client never actually emits an Adler-32 on the game connection (sequenced packets
-- win over the checksum branch in Protocol::send). This module exists for the legacy/verification
-- paths and for test/selftest.lua.

local M = {}

local sbyte = string.byte
local BASE  = 65521
local NMAX  = 5552          -- largest n such that 255*n*(n+1)/2 + (n+1)*(BASE-1) <= 2^32-1

--- @param s string
--- @param init number|nil  starting checksum (default 1, i.e. adler32(0, Z_NULL, 0))
--- @return number u32
function M.sum(s, init)
    if type(s) ~= 'string' then error("adler32.sum: expected string, got " .. type(s), 2) end
    init = init or 1
    local A = init % 65536
    local B = math.floor(init / 65536) % 65536
    local n = #s
    local i = 1
    while i <= n do
        local last = i + NMAX - 1
        if last > n then last = n end
        -- 16 bytes at a time: string.byte multi-return amortises the call overhead.
        local j = i
        while j + 15 <= last do
            local c1, c2, c3, c4, c5, c6, c7, c8,
                  c9, c10, c11, c12, c13, c14, c15, c16 = sbyte(s, j, j + 15)
            A = A + c1;  B = B + A
            A = A + c2;  B = B + A
            A = A + c3;  B = B + A
            A = A + c4;  B = B + A
            A = A + c5;  B = B + A
            A = A + c6;  B = B + A
            A = A + c7;  B = B + A
            A = A + c8;  B = B + A
            A = A + c9;  B = B + A
            A = A + c10; B = B + A
            A = A + c11; B = B + A
            A = A + c12; B = B + A
            A = A + c13; B = B + A
            A = A + c14; B = B + A
            A = A + c15; B = B + A
            A = A + c16; B = B + A
            j = j + 16
        end
        while j <= last do
            A = A + sbyte(s, j); B = B + A
            j = j + 1
        end
        A = A % BASE
        B = B % BASE
        i = last + 1
    end
    return B * 65536 + A
end

return M
