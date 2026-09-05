-- lib/buffer.lua -- little-endian byte reader/writer (InputMessage/OutputMessage semantics)
--
-- Mirrors src/framework/net/inputmessage.cpp / outputmessage.cpp of the mehah 1530 fork, but on
-- plain Lua strings. Everything is LITTLE-ENDIAN (stdext::readULE16/32/64).
--
-- POSITION CONVENTION: R:pos() returns a 0-BASED byte offset (== number of bytes consumed so far);
-- R:setPos(p) takes the same 0-based offset. Round-tripping pos()/setPos() is always safe.
--
-- u64 CAVEAT: R:u64() combines two u32 into a Lua double. Values above 2^53 lose low-order bits
-- silently (the double cannot represent them). For identifiers that must stay exact (market
-- offer ids, etc.) use R:u64hex(), which returns the exact value as a 16-char uppercase hex
-- string ("%08X%08X" of hi,lo) without ever going through a double.
--
-- Over-read raises a descriptive error naming the byte offset.

local M = {}

local sbyte, schar, ssub, srep = string.byte, string.char, string.sub, string.rep
local sformat, concat, floor = string.format, table.concat, math.floor

--==========================================================================================
-- Reader
--==========================================================================================

local Reader = {}
Reader.__index = Reader

--- @param str string  the raw bytes to read from
function M.reader(str)
    if type(str) ~= 'string' then
        error("buffer.reader: expected string, got " .. type(str), 2)
    end
    return setmetatable({ s = str, p = 1, n = #str }, Reader)
end

-- level 3: blame the caller of the R:xxx() method
local function overread(r, need, what)
    error(sformat(
        "buffer.reader: over-read of %d byte(s) for %s at offset %d (size %d, remaining %d)",
        need, what, r.p - 1, r.n, r.n - r.p + 1), 3)
end

function Reader:u8()
    local p = self.p
    if p > self.n then overread(self, 1, 'u8') end
    self.p = p + 1
    return sbyte(self.s, p)
end

function Reader:u16()
    local p = self.p
    if p + 1 > self.n then overread(self, 2, 'u16') end
    self.p = p + 2
    local a, b = sbyte(self.s, p, p + 1)
    return a + b * 256
end

function Reader:u32()
    local p = self.p
    if p + 3 > self.n then overread(self, 4, 'u32') end
    self.p = p + 4
    local a, b, c, d = sbyte(self.s, p, p + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

-- Two u32 combined into a double. Exact for values < 2^53; see the caveat at the top of the file.
function Reader:u64()
    local p = self.p
    if p + 7 > self.n then overread(self, 8, 'u64') end
    self.p = p + 8
    local a, b, c, d, e, f, g, h = sbyte(self.s, p, p + 7)
    local lo = a + b * 256 + c * 65536 + d * 16777216
    local hi = e + f * 256 + g * 65536 + h * 16777216
    return lo + hi * 4294967296
end

-- Exact 64-bit value as a 16-char uppercase hex string (big-endian text form). No precision loss.
function Reader:u64hex()
    local p = self.p
    if p + 7 > self.n then overread(self, 8, 'u64hex') end
    self.p = p + 8
    local a, b, c, d, e, f, g, h = sbyte(self.s, p, p + 7)
    local lo = a + b * 256 + c * 65536 + d * 16777216
    local hi = e + f * 256 + g * 65536 + h * 16777216
    return sformat("%08X%08X", hi, lo)
end

function Reader:i8()
    local v = self:u8()
    if v >= 128 then v = v - 256 end
    return v
end

function Reader:i16()
    local v = self:u16()
    if v >= 32768 then v = v - 65536 end
    return v
end

function Reader:i32()
    local v = self:u32()
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end

--- InputMessage::getDouble (inputmessage.cpp:101-106):
---   const uint8_t precision = getU8();
---   const int32_t v = getU32() - INT_MAX;      // unsigned wrap, then reinterpreted as int32
---   return (v / std::pow(10.f, precision));    // pow(float,integral) -> double, so full double div
function Reader:double()
    local precision = self:u8()
    local u = self:u32()
    local v = (u - 2147483647) % 4294967296          -- uint32 wraparound
    if v >= 2147483648 then v = v - 4294967296 end   -- reinterpret as int32_t
    return v / (10 ^ precision)
end

--- @param n number bytes to read
function Reader:bytes(n)
    if n < 0 then error("buffer.reader: negative length " .. tostring(n), 2) end
    local p = self.p
    if p + n - 1 > self.n then overread(self, n, 'bytes') end
    self.p = p + n
    return ssub(self.s, p, p + n - 1)
end

-- getString(): u16 length + raw bytes (inputmessage.cpp:92-99)
function Reader:string()
    local len = self:u16()
    local p = self.p
    if p + len - 1 > self.n then overread(self, len, 'string body') end
    self.p = p + len
    return ssub(self.s, p, p + len - 1)
end

function Reader:peek8()
    local p = self.p
    if p > self.n then overread(self, 1, 'peek8') end
    return sbyte(self.s, p)
end

function Reader:peek16()
    local p = self.p
    if p + 1 > self.n then overread(self, 2, 'peek16') end
    local a, b = sbyte(self.s, p, p + 1)
    return a + b * 256
end

function Reader:skip(n)
    if n < 0 then error("buffer.reader: negative skip " .. tostring(n), 2) end
    if self.p + n - 1 > self.n then overread(self, n, 'skip') end
    self.p = self.p + n
end

function Reader:pos() return self.p - 1 end                 -- 0-based offset

function Reader:setPos(p)
    if type(p) ~= 'number' or p < 0 or p > self.n then
        error(sformat("buffer.reader: setPos(%s) out of range 0..%d", tostring(p), self.n), 2)
    end
    self.p = p + 1
end

function Reader:remaining() return self.n - self.p + 1 end
function Reader:size()      return self.n end
function Reader:eof()       return self.p > self.n end
function Reader:data()      return self.s end

-- everything not yet consumed (does not advance)
function Reader:rest() return ssub(self.s, self.p) end

--==========================================================================================
-- Writer
--==========================================================================================

local Writer = {}
Writer.__index = Writer

function M.writer()
    return setmetatable({ t = {}, k = 0, len = 0 }, Writer)
end

local function put(w, s)
    local k = w.k + 1
    w.k = k
    w.t[k] = s
    w.len = w.len + #s
    return w
end

function Writer:u8(v)
    v = floor(v) % 256
    return put(self, schar(v))
end

function Writer:u16(v)
    v = floor(v) % 65536
    return put(self, schar(v % 256, floor(v / 256)))
end

function Writer:u32(v)
    v = floor(v) % 4294967296
    return put(self, schar(v % 256, floor(v / 256) % 256, floor(v / 65536) % 256, floor(v / 16777216)))
end

function Writer:u64(v)
    v = floor(v)
    local lo = v % 4294967296
    local hi = floor(v / 4294967296) % 4294967296
    return put(self, schar(lo % 256, floor(lo / 256) % 256, floor(lo / 65536) % 256, floor(lo / 16777216),
                           hi % 256, floor(hi / 256) % 256, floor(hi / 65536) % 256, floor(hi / 16777216)))
end

function Writer:i8(v)  return self:u8(v % 256) end
function Writer:i16(v) return self:u16(v % 65536) end
function Writer:i32(v) return self:u32(v % 4294967296) end

--- Inverse of Reader:double() -- the 5-byte OutputMessage form: u8 precision, then
--- u32 (round(value * 10^precision) + INT_MAX) wrapped into uint32.
--- Added for test fixtures / senders that must emit the InputMessage::getDouble shape.
function Writer:double(value, precision)
    precision = precision or 2
    self:u8(precision)
    local scaled = floor(value * (10 ^ precision) + 0.5)
    return self:u32((scaled + 2147483647) % 4294967296)
end

function Writer:bytes(s)
    if type(s) ~= 'string' then error("buffer.writer:bytes expected string, got " .. type(s), 2) end
    return put(self, s)
end

-- addString(): u16 length + raw bytes
function Writer:string(s)
    s = s or ""
    if #s > 65535 then
        error(sformat("buffer.writer:string too long (%d bytes, max 65535)", #s), 2)
    end
    self:u16(#s)
    return put(self, s)
end

function Writer:pad(n, byte)
    if n < 0 then error("buffer.writer:pad negative length " .. tostring(n), 2) end
    if n == 0 then return self end
    return put(self, srep(schar((byte or 0) % 256), n))
end

function Writer:size() return self.len end

function Writer:data()
    if self.k > 1 then
        local s = concat(self.t)
        self.t = { s }
        self.k = 1
        return s
    end
    return self.t[1] or ""
end

function Writer:reset()
    self.t, self.k, self.len = {}, 0, 0
    return self
end

return M
