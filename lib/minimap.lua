--[[============================================================================
lib/minimap.lua -- reader for the reference client's persisted minimap (OTMM v1).

The live client only knows tiles the server has described (the aware area).  Everything
outside it is remembered on disk, in `profiles/minimap.otmm`, and that file is what
`Map::findEveryPath` consults for every neighbour outside the aware range
(src/client/map.cpp:1406-1424).  Without it a cavebot waypoint more than a screen away has
no path at all -- docs/live-findings.md, bug 3.

This module is a READ-ONLY parser.  It never opens the file for writing, never keeps a file
handle open (the reference client publishes with an atomic rename, and any open handle on
Windows makes that rename fail), and never touches the bytes on disk in any way.

The wire format, the framing rules, the fail-soft resynchronisation and the per-tile merge
are all ported from `src/client/minimap.cpp` / `minimap.h`; docs/minimap.md carries the
byte-level description and the citations.

    local minimap = require('lib.minimap')

    local mm, err = minimap.load('D:/.../profiles/minimap.otmm')
    mm:tile(32366, 32242, 6)   --> { color=, speed=, walkable=, pathable=, seen=, ... } | nil
    mm:get({x=,y=,z=})         --> flags, colorByte, speedByte   (bot/world.lua `known` API)
    mm:stats()                 --> { blocks=, loadMs=, ... }

The module-level `minimap.load` / `minimap.tile` / `minimap.stats` operate on the most
recently loaded instance, so the three names BOT.md asks for work without threading an
object around.  Every instance method also accepts the instance as the first argument, so
`minimap.tile(mm, x, y, z)` and `mm:tile(x, y, z)` are the same call.

LAZY BY BLOCK
-------------
`load()` reads the file once, walks the framing WITHOUT inflating anything, and records the
byte offset of every block.  The user's real 6.9 MB / 11,420-block file indexes in 5 ms and
costs 8.9 MB of Lua heap; inflating all of it would cost 556 ms and 140 MB, which is why
this is lazy.  A block is inflated the first time a tile inside it is asked for and then
kept in a two-generation cache (default 192 blocks, so at most 2 * 192 * 12288 = 4.7 MB of
decompressed tiles), because a pathfinding search touches a handful of 64x64 blocks and
revisits them thousands of times.
============================================================================]]

local ok_inflate, inflate = pcall(require, 'lib.inflate')

local sbyte, srep, ssub = string.byte, string.rep, string.sub
local floor = math.floor

local M = {}

-- ---------------------------------------------------------------------------
-- format constants (minimap.h:26-31, minimap.cpp:65-70)
-- ---------------------------------------------------------------------------
local MMBLOCK_SIZE      = 64          -- minimap.h:26
local TILES_PER_BLOCK   = MMBLOCK_SIZE * MMBLOCK_SIZE          -- 4096
local TILE_BYTES        = 3           -- MinimapTile{u8 flags; u8 color; u8 speed}, #pragma pack(1)
local OTMM_BLOCK_SIZE   = TILES_PER_BLOCK * TILE_BYTES         -- 12288
local OTMM_BLOCK_HEADER = 7           -- u16 x, u16 y, u8 z, u16 len
local OTMM_END_MARKER   = 5           -- u16 0xFFFF, u16 0xFFFF, u8 0xFF
local OTMM_MIN_HEADER   = 12          -- u32 signature, u16 dataStart, u16 version, u32 flags
local OTMM_MIN_DEFLATE  = 8           -- smallest stream zlib will ever emit
local OTMM_SIGNATURE    = 0x4D4D544F  -- "OTMM" little-endian
local OTMM_VERSION      = 1
local MAP_MAX_Z         = 15          -- g_gameConfig.getMapMaxZ()
-- zlib compressBound(n) = n + (n>>12) + (n>>14) + (n>>25) + 13  ->  12288 + 3 + 0 + 0 + 13
local MAX_COMPRESSED    = OTMM_BLOCK_SIZE + floor(OTMM_BLOCK_SIZE / 4096)
                        + floor(OTMM_BLOCK_SIZE / 16384) + 13   -- 12304
-- getBlockIndex: (y/64) * (65536/64) + (x/64)   (minimap.h:161)
local BLOCKS_PER_ROW    = 65536 / MMBLOCK_SIZE                  -- 1024

M.MMBLOCK_SIZE    = MMBLOCK_SIZE
M.OTMM_BLOCK_SIZE = OTMM_BLOCK_SIZE
M.OTMM_SIGNATURE  = OTMM_SIGNATURE
M.OTMM_VERSION    = OTMM_VERSION
M.MAX_COMPRESSED  = MAX_COMPRESSED
M.MAP_MAX_Z       = MAP_MAX_Z

-- MinimapTileFlags (minimap.h:32-38)
M.WAS_SEEN     = 1
M.NOT_PATHABLE = 2
M.NOT_WALKABLE = 4
M.EMPTY        = 8

-- the default-constructed MinimapTile (minimap.h:42-45): flags 0, colour 255, speed byte 10
M.NULL_FLAGS, M.NULL_COLOR, M.NULL_SPEED = 0, 255, 10

-- one all-default block, exported so a caller can tell "nothing known here" from a real block
local NULL_BLOCK = srep(string.char(M.NULL_FLAGS, M.NULL_COLOR, M.NULL_SPEED), TILES_PER_BLOCK)

local DEFAULT_CACHE_BLOCKS = 192

-- ---------------------------------------------------------------------------
-- little-endian readers over a Lua string; `p` is a 0-BASED offset, as in the C++
-- ---------------------------------------------------------------------------
local function u16(d, p)
    local a, b = sbyte(d, p + 1, p + 2)
    if not b then return nil end
    return a + b * 256
end

local function u32(d, p)
    local a, b, c, e = sbyte(d, p + 1, p + 4)
    if not e then return nil end
    return a + b * 256 + c * 65536 + e * 16777216
end

-- minimap.cpp:80-83
local function isEndMarker(d, p)
    local a, b, c, e, f = sbyte(d, p + 1, p + 5)
    return a == 255 and b == 255 and c == 255 and e == 255 and f == 255
end

-- minimap.cpp:88-101: two bytes that rule out essentially every false positive before an inflate.
local function looksLikeZlibStream(cmf, flg)
    if not flg then return false end
    if (cmf % 16) ~= 8 then return false end                -- CM must be deflate
    if floor(cmf / 16) > 7 then return false end            -- CINFO: window <= 32K
    if floor(flg / 32) % 2 == 1 then return false end       -- FDICT must be clear
    return (cmf * 256 + flg) % 31 == 0                      -- the header check value
end

-- minimap.cpp:102-121.  Block positions are always block-aligned and floors bounded, which is
-- the ONLY thing that makes a desynced framing recognisable: Position::isValid() rejects
-- exactly one triple out of 2^40 and treats arbitrary garbage as a legitimate header.
local function looksLikeBlockHeader(d, size, off)
    if off + OTMM_BLOCK_HEADER > size then return false end
    local x = u16(d, off)
    if x % MMBLOCK_SIZE ~= 0 then return false end          -- cheapest reject first
    local y = u16(d, off + 2)
    if y % MMBLOCK_SIZE ~= 0 then return false end
    local z = sbyte(d, off + 5)             -- 1-based off+5 == the 0-based off+4 z byte
    if z > MAP_MAX_Z then return false end
    local len = u16(d, off + 5)             -- u16 takes a 0-BASED offset: the len field
    if len < OTMM_MIN_DEFLATE or len > MAX_COMPRESSED then return false end
    if off + OTMM_BLOCK_HEADER + len > size then return false end
    local cmf, flg = sbyte(d, off + OTMM_BLOCK_HEADER + 1, off + OTMM_BLOCK_HEADER + 2)
    return looksLikeZlibStream(cmf, flg)
end

-- minimap.cpp:126-134.  Each scan resumes where the previous stopped and the caller's cursor
-- only moves forward, so the total cost stays linear in the file size.
local function findNextFrame(d, size, off)
    while off + OTMM_END_MARKER <= size do
        if isEndMarker(d, off) or looksLikeBlockHeader(d, size, off) then return off end
        off = off + 1
    end
    return size
end

-- ---------------------------------------------------------------------------
-- instance
-- ---------------------------------------------------------------------------
local Minimap = {}
Minimap.__index = Minimap
M._Minimap = Minimap

local function blockIndexOf(x, y)
    return floor(y / MMBLOCK_SIZE) * BLOCKS_PER_ROW + floor(x / MMBLOCK_SIZE)
end
M.blockIndexOf = blockIndexOf

--- Fold a later copy of a block into the one already decoded, per `Minimap::mergeOtmmBlock`
--- (minimap.cpp:591-649).  A block index seen for the first time is adopted wholesale; a
--- repeat (the salvage tail of a file written by the pre-fix writer can hold one) is merged
--- tile by tile: what we already hold and that carries WasSeen always wins, otherwise the
--- stored tile is taken when it is a real observation or when it at least carries a colour
--- and we hold nothing but the 255 "never filled in" default.
local function mergeBlock(mine, stored)
    local out = {}
    local n = 0
    local i = 1
    while i <= OTMM_BLOCK_SIZE do
        local mf, mc, ms = sbyte(mine, i, i + 2)
        local take = false
        if mf % 2 == 0 then                                     -- mine has no WasSeen
            local sf, sc = sbyte(stored, i, i + 1)
            if sf % 2 == 1 then                                 -- stored is a real observation
                take = true
            elseif mc == 255 and sc ~= 255 then                 -- fill in a colour we never had
                take = true
            end
        end
        n = n + 1
        if take then
            out[n] = ssub(stored, i, i + 2)
        else
            out[n] = string.char(mf, mc, ms)
        end
        i = i + 3
    end
    return table.concat(out)
end

--- Inflate one stored block.  Returns the 12288-byte tile payload, or nil when the payload is
--- unusable (`uncompress` failure or a short result -- minimap.cpp:717-726).
local function inflateAt(d, off)
    if not ok_inflate then return nil, 'lib.inflate is unavailable (LuaJIT/FFI required)' end
    local len = u16(d, off + 5)
    -- the payload is a zlib stream: 2 header bytes, raw DEFLATE, 4 adler32 bytes.  lib.inflate
    -- is a RAW inflate, so the two header bytes are skipped; it stops at the end of the deflate
    -- stream, so the adler tail is simply unread input.
    local first = off + OTMM_BLOCK_HEADER + 2
    local raw = ssub(d, first + 1, off + OTMM_BLOCK_HEADER + len)
    local out = inflate.once(raw)
    if not out or #out ~= OTMM_BLOCK_SIZE then return nil end
    return out
end

--- Walk the body and record where every block lives, WITHOUT inflating any of them.
--- The walk is fail-soft exactly like `Minimap::readOtmm` (minimap.cpp:695-770): a block whose
--- payload is unusable costs that block, a break in the framing costs only the bytes up to the
--- next recognisable header, and a stale tail behind the sentinel is scanned for salvage.
local function indexFile(self)
    local d, size = self.data, #self.data
    local st = self.st

    local pos = self.dataStart
    while true do
        if pos + OTMM_END_MARKER > size then
            st.blocksDamaged = st.blocksDamaged + 1
            st.bytesSkipped  = st.bytesSkipped + (size - pos)
            break
        end
        if isEndMarker(d, pos) then
            st.sawEndMarker = true
            pos = pos + OTMM_END_MARKER
            break
        end
        if looksLikeBlockHeader(d, size, pos) then
            self:_record(pos)
            pos = pos + OTMM_BLOCK_HEADER + u16(d, pos + 5)
        else
            st.blocksDamaged = st.blocksDamaged + 1
            local nxt = findNextFrame(d, size, pos + 1)
            st.bytesSkipped = st.bytesSkipped + (nxt - pos)
            if nxt >= size then break end
            st.resyncs = st.resyncs + 1
            pos = nxt
        end
    end

    -- A pre-fix writer rewrote the target in place without truncating it, so a shorter save
    -- could leave a longer one's tail behind the sentinel.  Those bytes can still hold real
    -- blocks; they only ever fill gaps (see mergeBlock), never overwrite what we already have.
    if st.sawEndMarker and pos < size then
        st.trailingBytes = size - pos
        local scan = pos
        while scan + OTMM_END_MARKER <= size do
            scan = findNextFrame(d, size, scan)
            if scan + OTMM_END_MARKER > size or isEndMarker(d, scan) then break end
            -- Unlike the main walk this one VERIFIES the payload before trusting the declared
            -- length, exactly as minimap.cpp:757-767 does: past the sentinel there is no
            -- framing to trust, so a header that does not inflate advances by ONE byte and the
            -- scan starts again rather than jumping over whatever really follows.
            if inflateAt(d, scan) then
                self:_record(scan, true)
                scan = scan + OTMM_BLOCK_HEADER + u16(d, scan + 5)
            else
                scan = scan + 1
            end
        end
    end
end

function Minimap:_record(off, salvaged)
    local d = self.data
    local x, y, z = u16(d, off), u16(d, off + 2), sbyte(d, off + 5)
    local idx = blockIndexOf(x, y)
    local per = self.blocks[z]
    if not per then per = {}; self.blocks[z] = per end

    local st = self.st
    if salvaged then st.blocksSalvaged = st.blocksSalvaged + 1
    else st.blocksOk = st.blocksOk + 1 end

    local have = per[idx]
    if have == nil then
        per[idx] = off
        st.blocks = st.blocks + 1
        st.floors[z] = (st.floors[z] or 0) + 1
    elseif type(have) == 'number' then
        per[idx] = { have, off }                  -- a duplicate: merged on first use
        st.duplicates = st.duplicates + 1
    else
        have[#have + 1] = off
        st.duplicates = st.duplicates + 1
    end
end

--- The decoded 12288-byte payload for one block, or nil when the file has no such block.
--- Two-generation cache: when `hot` fills up it becomes `cold` and a fresh `hot` is started,
--- so eviction is O(1) and anything used in the last two generations survives.
function Minimap:_block(z, idx)
    local key = z * 1048576 + idx
    local hit = self.hot[key]
    if hit ~= nil then
        if hit == false then return nil end
        return hit
    end
    hit = self.cold[key]
    if hit ~= nil then
        self.hot[key] = hit
        self.hotN = self.hotN + 1
        if hit == false then return nil end
        return hit
    end

    local per = self.blocks[z]
    local off = per and per[idx]
    local decoded
    if off == nil then
        decoded = false
    elseif type(off) == 'number' then
        decoded = inflateAt(self.data, off) or false
        self.st.inflated = self.st.inflated + 1
        if decoded == false then self.st.blocksUnusable = self.st.blocksUnusable + 1 end
    else
        for i = 1, #off do
            local part = inflateAt(self.data, off[i])
            self.st.inflated = self.st.inflated + 1
            if not part then
                self.st.blocksUnusable = self.st.blocksUnusable + 1
            elseif not decoded then
                decoded = part
            else
                decoded = mergeBlock(decoded, part)
                self.st.merged = self.st.merged + 1
            end
        end
        decoded = decoded or false
    end

    if self.hotN >= self.cacheBlocks then
        self.cold, self.hot, self.hotN = self.hot, {}, 0
    end
    self.hot[key] = decoded
    self.hotN = self.hotN + 1
    return decoded ~= false and decoded or nil
end

--- Raw tile bytes: flags, colour, speed byte -- or nil when no block covers the position.
--- `Minimap::getTile` answers a default MinimapTile there; the caller decides what that means,
--- which is why this returns nil rather than inventing 0/255/10.
function Minimap:raw(x, y, z)
    if not (x and y and z) or z < 0 or z > MAP_MAX_Z then return nil end
    if x < 0 or y < 0 or x > 65535 or y > 65535 then return nil end
    local b = self:_block(z, blockIndexOf(x, y))
    if not b then return nil end
    -- getTileIndex: ((y % 64) * 64) + (x % 64)   (minimap.h:60)
    local i = ((y % MMBLOCK_SIZE) * MMBLOCK_SIZE + (x % MMBLOCK_SIZE)) * TILE_BYTES + 1
    local f, c, s = sbyte(b, i, i + 2)
    return f, c, s
end

--- bot/world.lua's `known` interface: flags, colour byte, speed BYTE (not speed*10).
--- Returning nothing at all is the "no such block" answer, which world:knownAt turns into the
--- reference client's null tile (0, 255, 10).
function Minimap:get(pos)
    if type(pos) ~= 'table' then return nil end
    return self:raw(pos.x, pos.y, pos.z)
end

--- The documented tile record, or nil when nothing on disk covers the position.
function Minimap:tile(x, y, z)
    local f, c, s = self:raw(x, y, z)
    if f == nil then return nil end
    local notPath = floor(f / M.NOT_PATHABLE) % 2 == 1
    local notWalk = floor(f / M.NOT_WALKABLE) % 2 == 1
    return {
        color    = c,
        speed    = s * 10,                     -- MinimapTile::getSpeed() (minimap.h:47)
        walkable = not notWalk,
        pathable = not notPath,
        seen     = (f % 2) == 1,
        empty    = floor(f / M.EMPTY) % 2 == 1,
        flags    = f,
        speedByte = s,
        -- map.cpp:1428-1430, preserved verbatim: yellow AND not-pathable is a real floor
        -- change.  Yellow alone is NOT enough -- staircases are drawn over several yellow
        -- tiles of which only one changes floor, and blocking every one of them made the
        -- stairs unreachable.  The anti-lost logic depends on exactly this band.
        stairs   = notPath and c >= 210 and c <= 213,
    }
end

--- Does this file hold ANY knowledge about the 64x64 block containing the position?
function Minimap:hasBlock(x, y, z)
    local per = self.blocks[z]
    return (per and per[blockIndexOf(x, y)]) ~= nil
end

function Minimap:blockCount() return self.st.blocks end

function Minimap:stats()
    local s = self.st
    return {
        path          = self.path,
        fileSize      = s.fileSize,
        dataStart     = self.dataStart,
        version       = self.version,
        blocks        = s.blocks,              -- distinct (z, blockIndex) pairs indexed
        blocksOk      = s.blocksOk,            -- headers accepted on the main walk
        blocksSalvaged = s.blocksSalvaged,     -- headers accepted in the stale tail
        blocksDamaged = s.blocksDamaged,
        blocksUnusable = s.blocksUnusable,     -- inflated on demand and failed
        duplicates    = s.duplicates,
        resyncs       = s.resyncs,
        bytesSkipped  = s.bytesSkipped,
        trailingBytes = s.trailingBytes,
        sawEndMarker  = s.sawEndMarker,
        damaged       = (s.blocksDamaged > 0 or s.resyncs > 0 or s.trailingBytes > 0
                         or not s.sawEndMarker),
        floors        = s.floors,
        loadMs        = s.loadMs,
        inflated      = s.inflated,            -- blocks decompressed so far (lazy)
        merged        = s.merged,
        cachedBlocks  = self.hotN,
        cacheBlocks   = self.cacheBlocks,
        tiles         = s.blocks * TILES_PER_BLOCK,
        -- resident bytes: the file image we keep plus the decompressed cache ceiling
        residentBytes = s.fileSize,
        cacheCeilingBytes = self.cacheBlocks * 2 * OTMM_BLOCK_SIZE,
    }
end

--- Count the tiles carrying WasSeen.  Inflates EVERY block, so it is a diagnostic, not a
--- hot-path call; `stats().tiles` is the cheap upper bound.
function Minimap:seenTiles()
    local total = 0
    for z = 0, MAP_MAX_Z do
        local per = self.blocks[z]
        if per then
            for idx in pairs(per) do
                local b = self:_block(z, idx)
                if b then
                    for i = 1, OTMM_BLOCK_SIZE, TILE_BYTES do
                        if sbyte(b, i) % 2 == 1 then total = total + 1 end
                    end
                end
            end
        end
    end
    return total
end

--- Inflate every indexed block (used to measure the worst case; not needed to path).
function Minimap:preload()
    local n = 0
    for z = 0, MAP_MAX_Z do
        local per = self.blocks[z]
        if per then
            for idx in pairs(per) do
                if self:_block(z, idx) then n = n + 1 end
            end
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- loading
-- ---------------------------------------------------------------------------
local function newStats(size)
    return { fileSize = size, blocks = 0, blocksOk = 0, blocksSalvaged = 0, blocksDamaged = 0,
             blocksUnusable = 0, duplicates = 0, resyncs = 0, bytesSkipped = 0,
             trailingBytes = 0, sawEndMarker = false, floors = {}, loadMs = 0,
             inflated = 0, merged = 0 }
end

--- Parse an in-memory OTMM image.  Same contract as `load`, without the io.
--- opts.cacheBlocks -- decompressed blocks kept hot (default 192).
function M.parse(bytes, opts, srcName)
    if type(bytes) ~= 'string' then return nil, 'minimap: expected a string' end
    opts = opts or {}

    local t0 = os.clock()
    local size = #bytes
    if size < OTMM_MIN_HEADER or u32(bytes, 0) ~= OTMM_SIGNATURE then
        return nil, ('minimap: %s is not an OTMM file (%d bytes)')
                    :format(tostring(srcName or '<memory>'), size)
    end
    local start   = u16(bytes, 4)
    local version = u16(bytes, 6)
    if version ~= OTMM_VERSION then
        return nil, ('minimap: %s has unsupported OTMM version %d')
                    :format(tostring(srcName or '<memory>'), version)
    end
    if start < OTMM_MIN_HEADER or start > size then
        return nil, ('minimap: %s declares a data start of %d outside a %d byte file')
                    :format(tostring(srcName or '<memory>'), start, size)
    end

    local self = setmetatable({
        path      = srcName,
        data      = bytes,
        dataStart = start,
        version   = version,
        flags     = u32(bytes, 8),
        blocks    = {},                        -- [z][blockIndex] = offset | {offset, ...}
        hot       = {}, cold = {}, hotN = 0,
        cacheBlocks = tonumber(opts.cacheBlocks) or DEFAULT_CACHE_BLOCKS,
        st        = newStats(size),
    }, Minimap)
    if self.cacheBlocks < 1 then self.cacheBlocks = 1 end

    indexFile(self)
    self.st.loadMs = (os.clock() - t0) * 1000
    return self
end

--- Read an OTMM file and index it.  READ-ONLY: the file is opened 'rb', slurped and closed
--- immediately, so no handle is ever held on the reference client's live minimap.
function M.load(path, opts)
    if type(path) ~= 'string' or path == '' then return nil, 'minimap.load: a path is required' end
    local f, err = io.open(path, 'rb')
    if not f then return nil, ('minimap: cannot read %s (%s)'):format(path, tostring(err)) end
    local bytes = f:read('*a')
    f:close()
    if not bytes then return nil, ('minimap: %s is unreadable'):format(path) end

    local mm, perr = M.parse(bytes, opts, path)
    if not mm then return nil, perr end
    M.default = mm
    return mm
end

--- The candidate paths for the reference client's own file, in the order main.lua tries them.
function M.defaultPaths(scriptDir)
    local out = {}
    if scriptDir and #scriptDir > 0 then
        out[#out + 1] = scriptDir .. '/../../otclient_mehah1530/otclient/profiles/minimap.otmm'
    end
    out[#out + 1] = 'D:/Claude/otclient_mehah1530/otclient/profiles/minimap.otmm'
    out[#out + 1] = '/mnt/d/Claude/otclient_mehah1530/otclient/profiles/minimap.otmm'
    return out
end

--- First existing candidate, or nil.
function M.findDefault(scriptDir)
    for _, c in ipairs(M.defaultPaths(scriptDir)) do
        local f = io.open(c, 'rb')
        if f then f:close(); return (c:gsub('\\', '/')) end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- module-level facade over the most recently loaded instance.
-- Every one also accepts an explicit instance as the first argument.
-- ---------------------------------------------------------------------------
local function pick(a, ...)
    if type(a) == 'table' and getmetatable(a) == Minimap then return a, ... end
    return M.default, a, ...
end

function M.tile(a, b, c, d)
    local mm, x, y, z = pick(a, b, c, d)
    if not mm then return nil end
    return mm:tile(x, y, z)
end

function M.get(a, b)
    local mm, pos = pick(a, b)
    if not mm then return nil end
    return mm:get(pos)
end

function M.stats(a)
    local mm = pick(a)
    if not mm then return nil end
    return mm:stats()
end

function M.blockCount(a)
    local mm = pick(a)
    if not mm then return 0 end
    return mm:blockCount()
end

M.available = ok_inflate
M.NULL_BLOCK = NULL_BLOCK

-- ---------------------------------------------------------------------------
-- fixture builder -- used by test/botsuite.lua so no test ever needs the user's 6.9 MB file.
-- `tiles` is a callback (x, y, z) -> flags, color, speedByte (nil = leave the null tile).
-- Requires a deflate-capable writer, so it emits STORED deflate blocks, which every zlib
-- reader (and lib.inflate) accepts.
-- ---------------------------------------------------------------------------
local function adler32(s)
    local a, b = 1, 0
    for i = 1, #s do
        a = (a + sbyte(s, i)) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end

local function le16(n) return string.char(n % 256, floor(n / 256) % 256) end
local function le32(n)
    return string.char(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256,
                       floor(n / 16777216) % 256)
end

--- Wrap `payload` in a zlib container whose deflate body is entirely STORED blocks.
local function zlibStore(payload)
    local out = { string.char(0x78, 0x01) }         -- CMF/FLG: deflate, 32K window, (0x7801 % 31 == 0)
    local n, i = #payload, 1
    if n == 0 then
        out[#out + 1] = string.char(0x01) .. le16(0) .. le16(65535)
    end
    while i <= n do
        local chunk = ssub(payload, i, i + 65534)
        i = i + #chunk
        out[#out + 1] = string.char(i > n and 0x01 or 0x00)
        out[#out + 1] = le16(#chunk) .. le16(65535 - #chunk)
        out[#out + 1] = chunk
    end
    out[#out + 1] = le32(adler32(payload)):reverse()   -- adler32 is stored BIG-endian
    return table.concat(out)
end
M._zlibStore = zlibStore

--- Build an OTMM v1 image in memory.  `blocks` is an array of
--- { x =, y =, z =, tiles = function(x, y, z) -> flags, color, speedByte }
--- where x/y are any position inside the wanted 64x64 block.
function M.buildFile(blocks)
    local out = { 'OTMM' }
    local desc = 'OTMM 1.0'
    local start = 4 + 2 + 2 + 4 + 2 + #desc
    out[#out + 1] = le16(start)
    out[#out + 1] = le16(OTMM_VERSION)
    out[#out + 1] = le32(0)
    out[#out + 1] = le16(#desc) .. desc

    for _, b in ipairs(blocks) do
        local bx = floor(b.x / MMBLOCK_SIZE) * MMBLOCK_SIZE
        local by = floor(b.y / MMBLOCK_SIZE) * MMBLOCK_SIZE
        local parts = {}
        for ty = 0, MMBLOCK_SIZE - 1 do
            for tx = 0, MMBLOCK_SIZE - 1 do
                local f, c, s
                if b.tiles then f, c, s = b.tiles(bx + tx, by + ty, b.z) end
                parts[#parts + 1] = string.char(f or M.NULL_FLAGS, c or M.NULL_COLOR,
                                                s or M.NULL_SPEED)
            end
        end
        local payload = table.concat(parts)
        assert(#payload == OTMM_BLOCK_SIZE, 'fixture block is the wrong size')
        local comp = zlibStore(payload)
        assert(#comp <= MAX_COMPRESSED,
               'fixture block does not fit a u16 length; use a real deflate')
        out[#out + 1] = le16(bx) .. le16(by) .. string.char(b.z) .. le16(#comp) .. comp
    end

    out[#out + 1] = string.char(255, 255, 255, 255, 255)      -- the invalid-Position sentinel
    return table.concat(out)
end

return M
