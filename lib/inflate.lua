-- lib/inflate.lua -- raw DEFLATE (RFC 1951) decoder, pure Lua + FFI byte buffers
--
-- Mirrors the two inbound modes of Protocol::internalRecvData (protocol.cpp:274-325), which runs a
-- single `inflateInit2(&z, -15)` stream per connection:
--
--   PER_PACKET : inflate(Z_FINISH) over the whole decrypted payload; success requires
--                Z_STREAM_END *and* >0 bytes out. Implemented by inflate.once(str).
--   STREAM     : the 4-byte sync footer "\0\0\255\255" is appended when not already present
--                (InputMessage::addCompressionFooter) and inflate(Z_SYNC_FLUSH) is called on a
--                stream that is NEVER reset between packets. Implemented by
--                inflate.new():inflateSyncFlush(chunk).
--
-- The STREAM object therefore keeps, across calls: the 32 KiB sliding window, the bit position and
-- any partially consumed input byte, and -- if a chunk ever ends mid-block -- the current block
-- state (Huffman tables / remaining stored-block length). A short chunk is handled by rolling the
-- bit reader back to the last symbol boundary and waiting for more input.
--
-- No `goto`, no bitwise operators on values that could go negative: the bit accumulator is a plain
-- Lua number kept below 2^24 and shifted with exact integer divides, so bit.band's signedness trap
-- never applies here.

local ffi = require('ffi')

local M = {}

local sbyte, ssub, min = string.byte, string.sub, math.min
local floor = math.floor

local WINDOW = 32768
local SYNC   = "\0\0\255\255"

local POW2 = {}
for i = 0, 32 do POW2[i] = 2 ^ i end

-- unique sentinel: "the decoder ran out of input at a resumable point"
local UNDERFLOW = setmetatable({}, { __tostring = function() return "inflate: needs more input" end })

--------------------------------------------------------------------------------------------
-- RFC 1951 constant tables
--------------------------------------------------------------------------------------------

-- length codes 257..285 -> index 1..29
local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
                67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT  = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
                4, 4, 4, 4, 5, 5, 5, 5, 0 }
-- distance codes 0..29 -> index 1..30
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
                1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DEXT  = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
                9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
-- order in which the code-length code lengths are stored
local CLORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

--------------------------------------------------------------------------------------------
-- Huffman tables
--------------------------------------------------------------------------------------------
-- Two decoding paths share one structure:
--   fast[idx] (idx = next 9 stream bits, LSB-first) = sym*16 + codeLength, 0 when the code is
--       longer than 9 bits. Covers the overwhelming majority of symbols in one table lookup.
--   count[]/symbol[] drive the canonical bit-at-a-time fallback (puff.c's decode()), used for
--       codes of 10..15 bits and whenever fewer than 9 bits are available (end of input).

local function buildHuff(lens, nsyms)
    local count = {}
    for i = 0, 15 do count[i] = 0 end
    for i = 0, nsyms - 1 do
        local L = lens[i]
        count[L] = count[L] + 1
    end
    count[0] = 0

    local left = 1
    for L = 1, 15 do
        left = left * 2 - count[L]
        if left < 0 then error("inflate: over-subscribed Huffman code", 0) end
    end

    local offs = { [1] = 0 }
    for L = 1, 15 do offs[L + 1] = offs[L] + count[L] end
    local symbol = {}
    for i = 0, nsyms - 1 do
        local L = lens[i]
        if L ~= 0 then
            symbol[offs[L]] = i
            offs[L] = offs[L] + 1
        end
    end

    local fast = {}
    for i = 0, 511 do fast[i] = 0 end
    local code, idx = 0, 0
    for L = 1, 15 do
        local c = count[L]
        for _ = 1, c do
            local sym = symbol[idx]
            idx = idx + 1
            if L <= 9 then
                -- the stream delivers a canonical code MSB-first, the accumulator LSB-first,
                -- so the table index is the bit-reversed code; higher bits are don't-care.
                local rev, cc = 0, code
                for _ = 1, L do
                    rev = rev * 2 + (cc % 2)
                    cc = floor(cc / 2)
                end
                local entry = sym * 16 + L
                for j = rev, 511, POW2[L] do fast[j] = entry end
            end
            code = code + 1
        end
        code = code * 2
    end

    return { count = count, symbol = symbol, fast = fast }
end

local FIXLIT, FIXDIST
do
    local l = {}
    for i = 0, 143 do l[i] = 8 end
    for i = 144, 255 do l[i] = 9 end
    for i = 256, 279 do l[i] = 7 end
    for i = 280, 287 do l[i] = 8 end
    FIXLIT = buildHuff(l, 288)
    local d = {}
    for i = 0, 29 do d[i] = 5 end
    d[30], d[31] = 5, 5          -- zlib builds 32 codes; 30/31 are invalid symbols if they appear
    FIXDIST = buildHuff(d, 32)
end

--------------------------------------------------------------------------------------------
-- bit reader
--------------------------------------------------------------------------------------------

local function fill(s, n)
    local bitbuf, bitcnt, pos = s.bitbuf, s.bitcnt, s.pos
    local buf, buflen = s.buf, s.buflen
    while bitcnt < n do
        if pos > buflen then
            s.bitbuf, s.bitcnt, s.pos = bitbuf, bitcnt, pos
            error(UNDERFLOW, 0)
        end
        bitbuf = bitbuf + sbyte(buf, pos) * POW2[bitcnt]
        pos = pos + 1
        bitcnt = bitcnt + 8
    end
    s.bitbuf, s.bitcnt, s.pos = bitbuf, bitcnt, pos
end

-- n <= 16 always (largest single request is a stored-block LEN/NLEN u16), so the accumulator
-- never exceeds 23 bits and stays exactly representable.
local function getbits(s, n)
    if n == 0 then return 0 end
    if s.bitcnt < n then fill(s, n) end
    local bb = s.bitbuf
    local v = bb % POW2[n]
    s.bitbuf = (bb - v) / POW2[n]
    s.bitcnt = s.bitcnt - n
    return v
end

local function decode(s, h)
    -- fast path only when 9 bits are certainly available (otherwise filling would underflow on a
    -- code that is actually shorter than 9 bits)
    if s.bitcnt + (s.buflen - s.pos + 1) * 8 >= 9 then
        if s.bitcnt < 9 then fill(s, 9) end
        local bb = s.bitbuf
        local e = h.fast[bb % 512]
        if e ~= 0 then
            local L = e % 16
            s.bitbuf = floor(bb / POW2[L])
            s.bitcnt = s.bitcnt - L
            return (e - L) / 16
        end
    end
    -- canonical bit-at-a-time fallback
    local count, symbol = h.count, h.symbol
    local code, first, index = 0, 0, 0
    for L = 1, 15 do
        code = code + getbits(s, 1)
        local cnt = count[L]
        if code - first < cnt then return symbol[index + (code - first)] end
        index = index + cnt
        first = (first + cnt) * 2
        code = code * 2
    end
    error("inflate: invalid Huffman code", 0)
end

--------------------------------------------------------------------------------------------
-- output buffer (FFI byte array; the 32 KiB history is prefixed so back-references just work)
--------------------------------------------------------------------------------------------

local function ensureCap(s, need)
    local want = s.olen + need
    if want <= s.ocap then return end
    local cap = s.ocap
    if cap < 1024 then cap = 1024 end
    while cap < want do cap = cap * 2 end
    local nb = ffi.new("uint8_t[?]", cap)
    ffi.copy(nb, s.obuf, s.olen)
    s.obuf, s.ocap = nb, cap
end

--------------------------------------------------------------------------------------------
-- block decoder
--------------------------------------------------------------------------------------------

local function snapshot(s)
    s.spos, s.sbitbuf, s.sbitcnt = s.pos, s.bitbuf, s.bitcnt
end

local function readDynamic(s)
    local hlit  = getbits(s, 5) + 257
    local hdist = getbits(s, 5) + 1
    local hclen = getbits(s, 4) + 4
    if hlit > 286 or hdist > 30 then error("inflate: too many length or distance codes", 0) end

    local cl = {}
    for i = 0, 18 do cl[i] = 0 end
    for i = 1, hclen do cl[CLORDER[i]] = getbits(s, 3) end
    local clh = buildHuff(cl, 19)

    local lens = {}
    local i = 0
    while i < hlit + hdist do
        local sym = decode(s, clh)
        if sym < 16 then
            lens[i] = sym
            i = i + 1
        else
            local rep, val
            if sym == 16 then
                if i == 0 then error("inflate: repeat with no previous length", 0) end
                val = lens[i - 1]
                rep = 3 + getbits(s, 2)
            elseif sym == 17 then
                val = 0
                rep = 3 + getbits(s, 3)
            else
                val = 0
                rep = 11 + getbits(s, 7)
            end
            if i + rep > hlit + hdist then error("inflate: too many lengths", 0) end
            for _ = 1, rep do
                lens[i] = val
                i = i + 1
            end
        end
    end
    if lens[256] == 0 then error("inflate: no end-of-block code", 0) end

    local litlens = {}
    for j = 0, hlit - 1 do litlens[j] = lens[j] end
    local distlens = {}
    for j = 0, hdist - 1 do distlens[j] = lens[hlit + j] end

    s.lit = buildHuff(litlens, hlit)
    s.dist = buildHuff(distlens, hdist)
end

-- Decode as much as the currently buffered input allows. Returns normally when it needs more
-- input (with the snapshot pointing at a resumable position) or when the final block is done.
local function run(s)
    while not s.done do
        local mode = s.mode

        if mode == 'idle' then
            snapshot(s)
            if s.bitcnt == 0 and s.pos > s.buflen then return end   -- nothing buffered at all
            local final = getbits(s, 1)
            local btype = getbits(s, 2)
            s.final = (final == 1)
            if btype == 0 then
                -- stored: discard the remaining bits of the current byte
                local d = s.bitcnt % 8
                if d > 0 then
                    s.bitbuf = floor(s.bitbuf / POW2[d])
                    s.bitcnt = s.bitcnt - d
                end
                local len  = getbits(s, 16)
                local nlen = getbits(s, 16)
                if len + nlen ~= 65535 then error("inflate: stored block length mismatch", 0) end
                s.mode, s.left = 'stored', len
            elseif btype == 1 then
                s.lit, s.dist = FIXLIT, FIXDIST
                s.mode = 'codes'
            elseif btype == 2 then
                readDynamic(s)
                s.mode = 'codes'
            else
                error("inflate: invalid block type 3", 0)
            end
            snapshot(s)

        elseif mode == 'stored' then
            local left = s.left
            while left > 0 do
                local b
                if s.bitcnt >= 8 then
                    b = s.bitbuf % 256
                    s.bitbuf = floor(s.bitbuf / 256)
                    s.bitcnt = s.bitcnt - 8
                elseif s.pos <= s.buflen then
                    b = sbyte(s.buf, s.pos)
                    s.pos = s.pos + 1
                else
                    s.left = left
                    snapshot(s)
                    return                      -- resumable: mode stays 'stored'
                end
                ensureCap(s, 1)
                s.obuf[s.olen] = b
                s.olen = s.olen + 1
                left = left - 1
            end
            s.left = 0
            s.mode = 'idle'
            if s.final then s.done = true end
            snapshot(s)

        else -- 'codes'
            local lit, dist = s.lit, s.dist
            while true do
                snapshot(s)                     -- roll back here if the symbol is incomplete
                local sym = decode(s, lit)
                if sym < 256 then
                    ensureCap(s, 1)
                    s.obuf[s.olen] = sym
                    s.olen = s.olen + 1
                elseif sym == 256 then
                    s.mode = 'idle'
                    if s.final then s.done = true end
                    snapshot(s)
                    break
                else
                    local li = sym - 256
                    if li > 29 then error("inflate: invalid length symbol " .. sym, 0) end
                    local len = LBASE[li] + getbits(s, LEXT[li])
                    local dsym = decode(s, dist)
                    if dsym > 29 then error("inflate: invalid distance symbol " .. dsym, 0) end
                    local d = DBASE[dsym + 1] + getbits(s, DEXT[dsym + 1])
                    if d > s.olen then error("inflate: distance too far back", 0) end
                    -- every read for this symbol is done; nothing was written yet, so an
                    -- UNDERFLOW above rolls back cleanly
                    ensureCap(s, len)
                    local ob = s.obuf
                    local src = s.olen - d
                    local dst = s.olen
                    for k = 0, len - 1 do ob[dst + k] = ob[src + k] end
                    s.olen = dst + len
                end
            end
        end
    end
end

local function newState()
    return {
        buf = "", buflen = 0, pos = 1,
        bitbuf = 0, bitcnt = 0,
        spos = 1, sbitbuf = 0, sbitcnt = 0,
        mode = 'idle', final = false, done = false, left = 0,
        lit = nil, dist = nil,
        obuf = nil, ocap = 0, olen = 0, ostart = 0,
        hist = "",
    }
end

local function drive(s)
    local ok, err = pcall(run, s)
    if not ok then
        if err == UNDERFLOW then
            -- rewind to the last complete symbol / block boundary and wait for more input
            s.pos, s.bitbuf, s.bitcnt = s.spos, s.sbitbuf, s.sbitcnt
            return true
        end
        error(err, 0)
    end
    return false
end

--------------------------------------------------------------------------------------------
-- STREAM mode
--------------------------------------------------------------------------------------------

local Stream = {}
Stream.__index = Stream

--- Persistent raw-inflate stream. Never reset between packets, exactly like the C++ Protocol's
--- single m_zstream in COMPRESSION_MODE_STREAM.
function M.new()
    return setmetatable({ s = newState() }, Stream)
end

--- Feed raw DEFLATE bytes WITHOUT appending the sync footer: decode everything currently
--- available and keep partial state (bit position, open block, Huffman tables, window) for the
--- next call. A chunk may stop anywhere -- even in the middle of a match -- and the decoder
--- resumes exactly where it left off. inflateSyncFlush() is this plus the footer rule.
function Stream:inflateChunk(chunk)
    chunk = chunk or ""
    if type(chunk) ~= 'string' then error("inflate: chunk must be a string", 2) end

    local s = self.s
    if s.pos > s.buflen then
        s.buf = chunk
    else
        s.buf = ssub(s.buf, s.pos) .. chunk
    end
    s.pos, s.buflen = 1, #s.buf
    snapshot(s)

    -- prime the output buffer with the sliding window so back-references resolve inside it
    local hist = s.hist
    local hl = #hist
    s.ocap = hl + 65536
    s.obuf = ffi.new("uint8_t[?]", s.ocap)
    if hl > 0 then ffi.copy(s.obuf, hist, hl) end
    s.olen, s.ostart = hl, hl

    drive(s)

    local out = ffi.string(s.obuf + s.ostart, s.olen - s.ostart)
    local hn = min(s.olen, WINDOW)
    s.hist = ffi.string(s.obuf + (s.olen - hn), hn)
    s.obuf, s.ocap, s.olen, s.ostart = nil, 0, 0, 0

    -- drop fully consumed input; bits already pulled into the accumulator stay there
    s.buf = ssub(s.buf, s.pos)
    s.pos, s.buflen = 1, #s.buf
    snapshot(s)

    return out
end

--- zlib Z_SYNC_FLUSH semantics on a never-reset stream.
--- Appends the "\0\0\255\255" sync footer when the chunk does not already end with it
--- (InputMessage::addCompressionFooter), decodes everything currently available and returns the
--- bytes produced by THIS call. Partial state (bit position, block state, 32 KiB window) is kept.
function Stream:inflateSyncFlush(chunk)
    chunk = chunk or ""
    if type(chunk) ~= 'string' then error("inflate: chunk must be a string", 2) end
    if #chunk < 4 or ssub(chunk, -4) ~= SYNC then
        chunk = chunk .. SYNC
    end
    return self:inflateChunk(chunk)
end

--- Drop all stream state (window, bit position, block state). The transport must NOT call this
--- between packets in STREAM mode -- the C++ never resets the zstream there.
function Stream:reset()
    self.s = newState()
end

--------------------------------------------------------------------------------------------
-- PER_PACKET mode
--------------------------------------------------------------------------------------------

--- inflate(Z_FINISH) over a whole raw-DEFLATE buffer.
--- @return string|nil  the decompressed bytes, or nil when the buffer is not a complete raw
---                     DEFLATE stream (no Z_STREAM_END) or produced 0 bytes -- exactly the
---                     condition Protocol::internalRecvData uses to reject PER_PACKET mode.
function M.once(str)
    if type(str) ~= 'string' then error("inflate.once: expected string", 2) end
    local s = newState()
    s.buf, s.buflen, s.pos = str, #str, 1
    s.ocap = 65536
    if #str * 8 > s.ocap then s.ocap = #str * 8 end
    s.obuf = ffi.new("uint8_t[?]", s.ocap)

    local ok, err = pcall(run, s)
    if not ok then
        if err == UNDERFLOW then return nil end
        return nil, tostring(err)
    end
    if not s.done then return nil end        -- never reached Z_STREAM_END
    if s.olen == 0 then return nil end       -- zlib produced nothing -> not PER_PACKET
    return ffi.string(s.obuf, s.olen)
end

M.SYNC_FOOTER = SYNC
M.WINDOW_SIZE = WINDOW

return M
