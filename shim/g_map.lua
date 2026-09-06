--[[============================================================================
shim/g_map.lua -- `g_map` (work item S1, PLAN sec.1.21, api-game.md sec.2).

Eight symbols, and they carry the whole bot:

    getTile                 37 T1 call sites   -- NIL for an undescribed tile, and vBot branches on it
    getTiles                16 T1 call sites   -- HOT: served from the registry's per-floor index
    getSpectators*          35 indirect sites  -- the C++ tile scan, so the order is deterministic
    getSpectatorsByPattern                     -- bot/world.lua:743, verbatim port
    isSightClear                               -- game/state.lua:915, verbatim port
    getMinimapColor          8 T1 call sites   -- the 210..213 "stairs yellow" band
    findEveryPath           19 findPath + 4 getPath + 5 autoWalk funnel here

TWO CONTRACTS THAT MUST NOT DRIFT (PLAN sec.6.4)
------------------------------------------------
1. `findEveryPath` is called through `mods/game_bot/functions/map.lua:80-113`, which has
   already NORMALISED the params: every boolean became `0` / `1`, `maxDistanceFrom` became
   the STRING `"x,y,z,dist"`, and `findPath` injected `destination` as the STRING `"x,y,z"`.
   bot/path.lua's `truthy()` already accepts 0 / "0" / "" as false, so the flags pass
   through untouched -- but the two STRING params must be decoded back into the
   `{pos, range}` / table shapes bot/path.lua reads.  Anything else silently produces an
   empty field and a spurious "no path".
2. The result is the C++ `{ ["x,y,z"] = {totalCost, distance, dirFromPrev, "prevX,prevY,prevZ"} }`
   map, because `functions/map.lua:116-140 translateAllPathsToPath` walks `node[3]`/`node[4]`
   and `findPath` compares `node[1]`.  `bot/path.lua`'s `Field:toStringMap()` produces
   exactly that shape and is used unchanged.

SPECTATOR ORDER (api-game.md sec.2.2)
-------------------------------------
`Map::getSpectatorsInRangeEx` (map.cpp:651-692) walks z -> y -> x and appends each tile's
creatures TOP OF STACK FIRST (`Tile::appendSpectators`, tile.cpp:477, iterates in reverse),
deduplicating on id.  `bot/world.lua:686 spectators` iterates `pairs(state.creatures)` --
hash order -- so "the first spectator" is nondeterministic there.  This module reproduces the
C++ tile scan instead, which is both exact and deterministic; the two produce the same SET
(a creature with a position is on a described tile) and test/shim_game_suite.lua asserts that.
============================================================================]]

local objects  = require('shim.object')
local posmod   = require('shim.position')
local pathmod  = require('bot.path')
local worldmod = require('bot.world')

local M = {}

local floor = math.floor

-- ---------------------------------------------------------------------------
-- findEveryPath param normalisation (functions/map.lua:80-113 -> bot/path.lua)
-- ---------------------------------------------------------------------------
-- "x,y,z,dist" -> { {x,y,z}, dist }   (also accepts the pre-normalised table forms)
local function decodeMaxDistanceFrom(v)
    if type(v) == 'table' then
        if #v == 2 and type(v[1]) == 'table' then return v end
        if #v == 4 then return { { x = v[1], y = v[2], z = v[3] }, v[4] } end
        if v.pos then return { v.pos, v.range } end
        return nil
    end
    if type(v) ~= 'string' then return nil end
    local x, y, z, d = v:match('^%s*(-?%d+)%s*,%s*(-?%d+)%s*,%s*(-?%d+)%s*,%s*(-?%d+)%s*$')
    if not x then return nil end
    return { { x = tonumber(x), y = tonumber(y), z = tonumber(z) }, tonumber(d) }
end

local function normaliseParams(params)
    if type(params) ~= 'table' then return {} end
    local p = {}
    for k, v in pairs(params) do p[k] = v end
    if p.destination ~= nil and type(p.destination) ~= 'table' then
        p.destination = posmod.parse(tostring(p.destination))
    end
    if p.maxDistanceFrom ~= nil then
        p.maxDistanceFrom = decodeMaxDistanceFrom(p.maxDistanceFrom)
    end
    -- `precision`, `marginMin`/`marginMax` (and the minMargin/maxMargin aliases) are read as
    -- VALUES by bot/path.lua; the vBot wrapper never stringifies them, but a config file can
    -- hand a string through, so coerce defensively.
    local numKeys = { 'precision', 'marginMin', 'marginMax', 'minMargin', 'maxMargin',
                      'maxComplexity' }
    for i = 1, #numKeys do
        local k = numKeys[i]
        if type(p[k]) == 'string' then p[k] = tonumber(p[k]) end
    end
    return p
end
M._normaliseParams = normaliseParams

-- ---------------------------------------------------------------------------
-- M.new(LC, reg [, opts]) -> g_map
--   opts.world / opts.path  inject the shared bot/world + bot/path instances (Track B reuse)
--   opts.minimap            a lib/minimap.lua reader; defaults to LC.minimap
--   opts.gMinimap           a shim/g_minimap instance for the getMinimapColor fallback
-- ---------------------------------------------------------------------------
function M.new(LC, reg, opts)
    opts = opts or {}
    local st = LC.state
    local g = {}

    -- lazily built so a shim booted before the bot layer still works, and so an injected
    -- Track-B world/path is honoured when there is one (PLAN I10 keeps them exclusive).
    local world, pathfinder
    local function W()
        if not world then
            world = opts.world or (LC.bot and LC.bot.world)
                    or worldmod.new({ state = st, items = LC.items, log = LC.log,
                                      minimap = opts.minimap or LC.minimap },
                                    { known = opts.minimap or LC.minimap })
        end
        return world
    end
    local function P()
        if not pathfinder then
            pathfinder = opts.path or (LC.bot and LC.bot.path)
                         or pathmod.new({ state = st, items = LC.items, log = LC.log,
                                          minimap = opts.minimap or LC.minimap }, W())
        end
        return pathfinder
    end
    g._world = W
    g._path  = P

    -- =======================================================================
    -- tiles
    -- =======================================================================
    -- Extra arguments are silently tolerated (invariant I4): `g_map.getTile(pos, distance)`
    -- is a real call site (functions/map.lua:251) against `Map::getTile(Position)`.
    function g.getTile(pos, _ignored)
        return reg:tile(pos)
    end

    function g.getThing(pos, stackPos)
        local th = st:getThing(pos, stackPos)
        if not th then return nil end
        if th.kind == 'creature' then return reg:creature(th.creatureId) end
        return reg:item(th, { kind = 'tile', pos = pos })
    end

    -- Map::getTiles(floor).  Served from reg.floors, which the registry maintains
    -- incrementally; `floor` nil or -1 means every floor, ascending.  Row-major (y, then x)
    -- within a floor so two identical states always produce an identical array -- the
    -- determinism the tick test asserts.
    local function floorTiles(z)
        reg:_syncFloors()
        local gen = reg.floorDirty[z] or 0
        if reg.floorGen[z] == gen and reg.floorList[z] then return reg.floorList[z] end
        local f = reg.floors[z]
        local keys = {}
        if f then
            for key, p in pairs(f) do keys[#keys + 1] = { key = key, x = p.x, y = p.y } end
            table.sort(keys, function(a, b)
                if a.y ~= b.y then return a.y < b.y end
                return a.x < b.x
            end)
        end
        local out = {}
        for i = 1, #keys do
            local t = reg:tileByKey(keys[i].key)
            if t then out[#out + 1] = t end
        end
        reg.floorList[z] = out
        reg.floorGen[z]  = gen
        return out
    end
    g._floorTiles = floorTiles

    function g.getTiles(z)
        if type(z) ~= 'number' or z < 0 then
            local all = {}
            local zs = {}
            reg:_syncFloors()
            for fz in pairs(reg.floors) do zs[#zs + 1] = fz end
            table.sort(zs)
            for i = 1, #zs do
                local list = floorTiles(zs[i])
                for j = 1, #list do all[#all + 1] = list[j] end
            end
            return all
        end
        -- Return the cached array itself only after copying: vBot does
        -- `table.remove(tiles, i)` in a couple of places and must not corrupt the index.
        local src = floorTiles(floor(z))
        local out = {}
        for i = 1, #src do out[i] = src[i] end
        return out
    end

    -- =======================================================================
    -- spectators (map.cpp:651-692 verbatim)
    -- =======================================================================
    local function awareZSpan(centerZ, multiFloor)
        if not multiFloor then return centerZ, centerZ end
        local cz = (st.central and st.central.z)
                   or (st.player and st.player.pos and st.player.pos.z) or centerZ
        local z0, z1 = st.firstAwareFloor(cz), st.lastAwareFloor(cz)
        if z0 > z1 then z0, z1 = z1, z0 end
        return z0, z1
    end

    function g.getSpectatorsInRangeEx(centerPos, multiFloor, minX, maxX, minY, maxY)
        local out, seen = {}, {}
        if not posmod.is(centerPos) then return out end
        local z0, z1 = awareZSpan(centerPos.z, multiFloor == true)
        local map = st.map
        for z = z0, z1 do
            local zs = ',' .. z
            for y = centerPos.y - minY, centerPos.y + maxY do
                local ys = ',' .. y .. zs
                for x = centerPos.x - minX, centerPos.x + maxX do
                    -- the "x,y,z" key game/state.lua documents; built inline so the hot
                    -- spectator scan allocates one string per tile instead of a table too
                    local tile = map[x .. ys]
                    if tile then
                        local things = tile.things
                        -- Tile::appendSpectators walks the array in REVERSE (top first)
                        for i = #things, 1, -1 do
                            local th = things[i]
                            if th.kind == 'creature' and th.creatureId and not seen[th.creatureId] then
                                local c = reg:creature(th.creatureId)
                                if c then
                                    seen[th.creatureId] = true
                                    out[#out + 1] = c
                                end
                            end
                        end
                    end
                end
            end
        end
        return out
    end

    -- map.h:166 -- the AWARE RANGE rectangle around centerPos.
    function g.getSpectators(centerPos, multiFloor)
        local a = st.world.awareRange
        return g.getSpectatorsInRangeEx(centerPos, multiFloor, a.left, a.right, a.top, a.bottom)
    end

    -- map.h:173 -- the "safe" rectangle (one tile inside the aware range).
    function g.getSightSpectators(centerPos, multiFloor)
        local a = st.world.awareRange
        return g.getSpectatorsInRangeEx(centerPos, multiFloor,
                                        a.left - 1, a.right - 2, a.top - 1, a.bottom - 2)
    end

    -- map.h:176 -- a symmetric xRange/yRange box.
    function g.getSpectatorsInRange(centerPos, multiFloor, xRange, yRange)
        return g.getSpectatorsInRangeEx(centerPos, multiFloor, xRange, xRange, yRange, yRange)
    end

    -- bot/world.lua:743 is the verbatim port (odd grid, `0/-` off, `1/+` on, `NnEeSsWw`
    -- direction cells, direction 8 disables every letter cell).
    function g.getSpectatorsByPattern(centerPos, pattern, direction)
        local recs = W():spectatorsByPattern(centerPos, pattern, direction)
        local out = {}
        for i = 1, #recs do
            local c = reg:creatureRec(recs[i])
            if c then out[#out + 1] = c end
        end
        return out
    end

    function g.getCreatureById(id)
        return reg:creature(id)
    end

    -- =======================================================================
    -- sight / colour
    -- =======================================================================
    function g.isSightClear(fromPos, toPos)
        if not (posmod.is(fromPos) and posmod.is(toPos)) then return false end
        return st:isSightClear(fromPos, toPos) == true
    end

    function g.isLookPossible(pos)
        return st:isLookPossible(pos) == true
    end

    -- Map::getMinimapColor (map.cpp:1168-1179): the tile's colour byte, and ONLY when that is
    -- 0 the persisted minimap.  Tile::getMinimapColorByte never returns 0 for a tile we hold
    -- (its "no colour" is 255), so the fallback only fires on a tile we do not have -- which
    -- is exactly the case the 210..213 stairs tests care about.
    function g.getMinimapColor(pos)
        if not posmod.is(pos) then return 0 end
        local mm = opts.gMinimap
        if mm then
            return st:getMinimapColor(pos, function(p) return mm.getColor(p) end)
        end
        return st:getMinimapColor(pos, function(p)
            local _, c = W():knownAt(p)
            return c
        end)
    end

    -- =======================================================================
    -- pathfinding
    -- =======================================================================
    -- Returns the C++ string-keyed field: { ["x,y,z"] = {total, dist, dir, "prev"} }.
    function g.findEveryPath(start, maxDistance, params)
        if not posmod.is(start) then return {} end
        local p = normaliseParams(params)
        local F = P():findEveryPath(start, maxDistance, p)
        return F:toStringMap()
    end

    -- Map::findPath is never called by vBot (it goes exclusively through findEveryPath), but
    -- it is bound on the real client, so keep it working rather than absent.
    function g.findPath(startPos, destPos, maxDist, params)
        local dirs = P():getPath(startPos, destPos, maxDist, normaliseParams(params))
        return dirs
    end

    -- =======================================================================
    -- misc accessors (0 T1 call sites, trivially real)
    -- =======================================================================
    function g.getCentralPosition()
        local c = st.central or (st.player and st.player.pos)
        return c and posmod.copy(c) or nil
    end

    function g.setCentralPosition(pos)
        return st:setCentralPosition(pos)
    end

    function g.isAwareOfPosition(pos)
        return st:isAwareOf(pos) == true
    end

    function g.getAwareRange()
        local a = st.world.awareRange
        return { left = a.left, top = a.top, right = a.right, bottom = a.bottom }
    end

    function g.getFirstAwareFloor()
        local c = st.central or (st.player and st.player.pos)
        return st.firstAwareFloor(c and c.z or 7)
    end

    function g.getLastAwareFloor()
        local c = st.central or (st.player and st.player.pos)
        return st.lastAwareFloor(c and c.z or 7)
    end

    function g.getSize()
        return { width = 65536, height = 65536 }
    end

    -- findItemsById / OTBM / zones / ghost mode: never called by vBot, and any answer we
    -- invented would be wrong.  Loud, callable, inert.
    setmetatable(g, { __index = function(_, k)
        reg:report('g_map.' .. tostring(k), 'not implemented (0 vBot call sites)')
        return function() return nil end
    end })

    return g
end

return M
