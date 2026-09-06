--[[============================================================================
bot/world.lua -- queries over game state for the bot layer (work item F2).

Everything here is BEHAVIOUR ported from the C++ client, with file:line citations into
D:/Claude/otclient_mehah1530/otclient/src/.  The authority for each rule is
docs/vbot/pathfinding.md (Corrections section overrides the body) and
docs/vbot/attackbot.md sections 2.1-2.3.

Public surface (BOT.md "bot/world.lua"):

    local w = world.new(client)              -- client = _G.LC
    w:spectators(pos, multifloor)            -- creatures around a position
    w:monsters(pos, range)                   -- monsters within a Chebyshev range
    w:players(pos, range)                    -- players (local player excluded)
    w:distance(a, b)   world.distance(a, b)  -- Chebyshev, the game's distance
    w:isSightClear(from, to)                 -- Map::isSightClear (map.cpp:1181-1225)
    w:countInArea(centerPos, pattern, dir)   -- monsters inside a spell pattern
    w:tileWalkable(pos, opts) -> bool, why   -- the documented walkability predicate

Pathfinder support (used by bot/path.lua, all first-class behaviour):

    w:classifyForPath(pos, allowOnlyVisibleTiles)
        -> wasSeen, hasCreature, notWalkable, notPathable, mapColor, speed
    w:knownAt(pos) -> flags, colorByte, speedByte   -- the persisted minimap, work item M
    w:isFloorChangeTile(pos, avoidIds) -> bool, why
    w:groundSpeed(tile) / w:minimapColor(tile) / w:elevationCount(tile)
    w:getTopUseThing(tile)

ITEM METADATA DEPENDENCY (work item F1)
--------------------------------------
Every movement decision needs the appearance flags listed in docs/vbot/gaps.md P0-1.  This
module reads them through the accessors that gaps.md specifies on `proto/items.lua`:

    items.isGround isGroundBorder isOnBottom isOnTop isNotWalkable isNotPathable
    items.isBlockProjectile isForceUse isSplash
    items.groundSpeed items.minimapColor items.elevation items.lensHelp

`assets/items1530.bin` is still at v1 (only the 7 protocol bits), so those accessors may not
exist yet.  Rather than stub them, this module resolves them ONCE in `world.new`, reports the
level in `w.itemDataLevel` ('full' | 'degraded') and logs a single warning in degraded mode.
Degraded fallbacks reproduce exactly what `state:walkableAt` can already decide today
(game/state.lua:512-537): the ground is "things[1] is an item", nothing blocks, ground speed
is 100, minimap colour is 0.  Nothing silently invents a flag value.

NO PER-TILE MEMOISATION
-----------------------
docs/vbot/pathfinding.md VERIFIER rejects the memoised `tile._f`/`tile._rev` design: luaclient
tiles carry no revision counter, so `f.rev == tile._rev` is `nil == nil` forever and the first
scan of a tile would be cached permanently.  Tiles hold at most 11 things, and the pathfinder
classifies each tile exactly once per search, so we simply rescan.
============================================================================]]

local bit = require('bit')

local floor, abs, sqrt = math.floor, math.abs, math.sqrt

local world = {}
world.__index = world

-- ---------------------------------------------------------------------------
-- direction constants (Otc::Direction, src/client/const.h:158-169)
-- ---------------------------------------------------------------------------
world.NORTH, world.EAST, world.SOUTH, world.WEST = 0, 1, 2, 3
world.NORTHEAST, world.SOUTHEAST, world.SOUTHWEST, world.NORTHWEST = 4, 5, 6, 7
world.INVALID_DIR = 8

-- Position::getDirectionFromPositions reduces, for adjacent tiles, to this 3x3 table
-- (docs/vbot/pathfinding.md VERIFIER "VERIFIED EXACT: the DIR lookup table").
-- DIR[dx][dy]
local DIR = { [-1] = { [-1] = 7, [0] = 3, [1] = 6 },
              [ 0] = { [-1] = 0,          [1] = 2 },
              [ 1] = { [-1] = 4, [0] = 1, [1] = 5 } }
world.DIR = DIR

-- dir -> {dx, dy}
local DELTA = {
    [0] = {  0, -1 },   -- North
    [1] = {  1,  0 },   -- East
    [2] = {  0,  1 },   -- South
    [3] = { -1,  0 },   -- West
    [4] = {  1, -1 },   -- NorthEast
    [5] = {  1,  1 },   -- SouthEast
    [6] = { -1,  1 },   -- SouthWest
    [7] = { -1, -1 },   -- NorthWest
}
world.DELTA = DELTA

function world.isDiagonal(dir) return dir ~= nil and dir >= 4 and dir <= 7 end

-- direction between two ADJACENT positions; nil when they are not adjacent / identical
function world.directionBetween(from, to)
    if not (from and to) then return nil end
    local dx, dy = to.x - from.x, to.y - from.y
    if dx < -1 or dx > 1 or dy < -1 or dy > 1 then return nil end
    local row = DIR[dx]
    return row and row[dy] or nil
end

-- Chebyshev distance -- getDistanceBetween / distanceFromPlayer in vBot are both
-- max(|dx|,|dy|) and both ignore z (docs/vbot/cavebot.md Additions, executor.lua:123-125).
local function chebyshev(a, b)
    if not (a and b) then return math.huge end
    local dx, dy = a.x - b.x, a.y - b.y
    if dx < 0 then dx = -dx end
    if dy < 0 then dy = -dy end
    return (dx > dy) and dx or dy
end
world.chebyshev = chebyshev

local function manhattan(a, b)
    if not (a and b) then return math.huge end
    return abs(a.x - b.x) + abs(a.y - b.y)
end
world.manhattan = manhattan

-- BOT.md spells this `world.distance(a, b)`; instances also want `w:distance(a, b)`.
-- A world instance never carries an `.x` field, so the two are told apart safely.
function world.distance(a, b, c)
    if c ~= nil and type(a) == 'table' and a.x == nil then a, b = b, c end
    return chebyshev(a, b)
end

local function samePos(a, b)
    return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end
world.samePos = samePos

-- ---------------------------------------------------------------------------
-- item-flag accessors (docs/vbot/gaps.md P0-1)
-- ---------------------------------------------------------------------------
local FALSE0  = function() return false end
local ZERO    = function() return 0 end
local TRUE0   = function() return true end

local REQUIRED = {
    'isGround', 'isGroundBorder', 'isOnBottom', 'isOnTop', 'isNotWalkable', 'isNotPathable',
    'isBlockProjectile', 'isForceUse', 'isSplash',
    'groundSpeed', 'minimapColor', 'elevation', 'lensHelp',
}

--- Wrap a resolved accessor in the id guard game/state.lua applies to every one of its
--- own calls (state.lua:626-641).  REVIEW FIX: proto/items.lua defines every accessor
--- unconditionally and RAISES for an unloaded table or an out-of-range id
--- (proto/items.lua:447-457), and an error escaping world:classifyForPath propagates out
--- of the CaveBot macro, which bot/init.lua then retries every 10 ms forever.
--- This is exactly game/state.lua:632's `exact and type(id) == 'number' and id >= 1 and
--- id <= items.MAX_ID` test, which is the complete precondition proto/items.lua's checkId
--- enforces -- so no pcall is needed and the pathfinder's hot loop keeps its speed.
local function guard(fn, dflt, maxId)
    return function(id, ...)
        if type(id) ~= 'number' or id < 1 or id ~= floor(id) then return dflt end
        if maxId and maxId > 0 and id > maxId then return dflt end
        return fn(id, ...)
    end
end

local GUARD_DEFAULT = {
    isGround = true, isGroundBorder = false, isOnBottom = false, isOnTop = false,
    isNotWalkable = false, isNotPathable = false, isBlockProjectile = false,
    isForceUse = false, isSplash = false,
    groundSpeed = 100, minimapColor = 0, elevation = 0, lensHelp = 0,
}

local function resolveItems(items_)
    local api, missing = {}, {}
    -- REVIEW FIX: `type(fn) == 'function'` is true even when the item table was never
    -- loaded, so world.new used to report itemDataLevel = 'full' and every classifier
    -- raised on the first call.  An unloaded table means NO metadata at all.
    local loaded = (items_ ~= nil) and (items_.loaded ~= false)
    local maxId = loaded and tonumber(items_ and items_.MAX_ID) or nil
    for i = 1, #REQUIRED do
        local name = REQUIRED[i]
        local fn = loaded and items_ and items_[name] or nil
        if type(fn) == 'function' then
            api[name] = guard(fn, GUARD_DEFAULT[name], maxId)
        else
            missing[#missing + 1] = name
        end
    end
    -- Degraded fallbacks == exactly what game/state.lua:512-537 can already decide.
    api.isGround          = api.isGround          or TRUE0   -- "things[1] is an item" heuristic
    api.isGroundBorder    = api.isGroundBorder    or FALSE0
    api.isOnBottom        = api.isOnBottom        or FALSE0
    api.isOnTop           = api.isOnTop           or FALSE0
    api.isNotWalkable     = api.isNotWalkable     or FALSE0
    api.isNotPathable     = api.isNotPathable     or FALSE0
    api.isBlockProjectile = api.isBlockProjectile or FALSE0   -- fail-open, as vBot does
    api.isForceUse        = api.isForceUse        or FALSE0
    api.isSplash          = api.isSplash          or FALSE0
    -- 100, not 0: with no item table we do not KNOW the ground speed, and 0 would make every
    -- step free.  A real v2 table reporting bank.waypoints == 0 is passed through verbatim
    -- (docs/vbot/pathfinding.md VERIFIER) -- this fallback only covers "no data at all".
    api.groundSpeed       = api.groundSpeed       or function() return 100 end
    api.minimapColor      = api.minimapColor      or ZERO
    api.elevation         = api.elevation         or ZERO
    api.lensHelp          = api.lensHelp          or ZERO
    return api, missing
end

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
-- world.new(client [, opts])
--   client.state   game/state.lua instance (required)
--   client.items   proto/items.lua      (optional; falls back to require)
--   client.log     lib/log.lua          (optional)
--   opts.known     a MinimapTile-equivalent store with :get(pos) -> flags, color, speedByte
--                  (docs/vbot/pathfinding.md section 5).  Absent => every unaware tile reads
--                  as the C++ "nulltile" {flags=0, color=255, speed=10}.
function world.new(client, opts)
    opts = opts or {}
    local self = setmetatable({}, world)
    self.client = client
    self.state  = client and client.state
    self.log    = client and client.log
    if not self.state then error('world.new: client.state is required', 2) end

    local items = (client and client.items)
    if items == nil then
        local ok, mod = pcall(require, 'proto.items')
        items = ok and mod or nil
    end
    self.items = items
    local api, missing = resolveItems(items)
    self.f = api
    self.missingItemApi = missing
    self.itemDataLevel = (#missing == 0) and 'full' or 'degraded'
    if self.itemDataLevel == 'degraded' and self.log and self.log.warn then
        self.log.warn('bot/world: item metadata is degraded (assets/items1530.bin v1); '
            .. 'missing proto.items accessors: %s. Walls, fields, ground speed and minimap '
            .. 'colour are invisible to the pathfinder until work item F1 lands.',
            table.concat(missing, ', '))
    end

    -- Work item M: knowledge of the world OUTSIDE the aware area.  `opts.known` is anything
    -- with `:get(pos) -> flags, colorByte, speedByte`; lib/minimap.lua (the reader for the
    -- reference client's profiles/minimap.otmm) is the real one, and main.lua threads it in
    -- through bot/init.lua.  `client.minimap` is picked up automatically so a world built
    -- without opts (bot/path.lua, bot/walker.lua, ...) still sees it.
    self.known = opts.known
    if self.known == nil and client then self.known = client.minimap end
    self.knownFailed = false
    return self
end

-- Minimap "nulltile" (src/client/minimap.h:41-45, minimap.cpp:52): flags 0, colour 255,
-- speed byte 10 -> getSpeed() == 100.
world.KNOWN_WAS_SEEN, world.KNOWN_NOT_PATHABLE = 1, 2
world.KNOWN_NOT_WALKABLE, world.KNOWN_EMPTY    = 4, 8

-- Fails OPEN and fails ONCE.  classifyForPath is called tens of thousands of times per
-- search from inside a CaveBot macro, and an error escaping it is retried every 10 ms
-- forever by bot/init.lua -- so a minimap source that raises is reported once and then
-- ignored for the rest of the session, exactly as if no minimap had been loaded.
function world:knownAt(pos)
    local k = self.known
    if not k or self.knownFailed then return 0, 255, 10 end
    local ok, f, c, s = pcall(k.get, k, pos)
    if not ok then
        self.knownFailed = true
        if self.log and self.log.warn then
            self.log.warn('bot/world: the minimap source raised (%s); pathing falls back to '
                .. 'the aware area only', tostring(f))
        end
        return 0, 255, 10
    end
    return f or 0, c or 255, s or 10
end

-- ---------------------------------------------------------------------------
-- creature predicates
-- ---------------------------------------------------------------------------
-- Creature::isInvisible() = outfit.isEffect() && auxId == 13.  ProtocolGame::getOutfit sets
-- that combination ONLY for lookType == 0 && lookTypeEx == 0 (protocolgameparse.cpp:4165-4176),
-- so on the wire the predicate is exactly this -- docs/vbot/pathfinding.md VERIFIER.
function world.isInvisible(c)
    if not c then return false end
    if c.invisible ~= nil then return c.invisible end
    local o = c.outfit
    if not o then return false end
    return o.lookType == 0 and (o.lookTypeEx or 0) == 0
end

-- Creature::canBeSeen() = !isInvisible() || isPlayer()   (creature.h:156)
function world.canBeSeen(c)
    if not c then return true end
    if c.isPlayer then return true end
    return not world.isInvisible(c)
end

-- Creature::isPassable() -- m_passable defaults FALSE (creature.h:359): an unknown creature blocks.
local function isPassable(c) return c ~= nil and c.passable == true end
world.isPassable = isPassable

-- ---------------------------------------------------------------------------
-- tile scans.  Only ITEMS contribute movement bits: Tile::setThingFlag early-returns for
-- non-items (tile.cpp:996) BEFORE the block that sets NOT_WALKABLE / NOT_PATHABLE /
-- BLOCK_PROJECTTILE and increments m_elevation.
-- ---------------------------------------------------------------------------

-- Tile::getGround (tile.cpp:537): things[0] if it actually carries the GROUND flag.
function world:getGround(tile)
    if not tile then return nil end
    local t = tile.things and tile.things[1]
    if t and t.kind == 'item' and t.id and self.f.isGround(t.id) then return t end
    return nil
end

-- Tile::getGroundSpeed (tile.cpp:563-568): the ground item's bank.waypoints VERBATIM
-- (including 0), or 100 when there is no ground item at all.
-- docs/vbot/pathfinding.md VERIFIER rejects substituting 100 for a 0 speed.
function world:groundSpeed(tile)
    local g = self:getGround(tile)
    if not g then return 100 end
    return self.f.groundSpeed(g.id) or 0
end

function world:notWalkable(tile)
    local things = tile and tile.things
    if not things then return false end
    local isNotWalkable = self.f.isNotWalkable
    for i = 1, #things do
        local t = things[i]
        if t.kind == 'item' and t.id and isNotWalkable(t.id) then return true end
    end
    return false
end

function world:notPathable(tile)
    local things = tile and tile.things
    if not things then return false end
    local isNotPathable = self.f.isNotPathable
    for i = 1, #things do
        local t = things[i]
        if t.kind == 'item' and t.id and isNotPathable(t.id) then return true end
    end
    return false
end

-- Tile::isLookPossible (tile.h:81) == (m_thingTypeFlag & BLOCK_PROJECTTILE) == 0
function world:blocksProjectile(tile)
    local things = tile and tile.things
    if not things then return false end
    local blocked = self.f.isBlockProjectile
    for i = 1, #things do
        local t = things[i]
        if t.kind == 'item' and t.id and blocked(t.id) then return true end
    end
    return false
end

-- Tile::m_elevation is a COUNTER (tile.cpp:1011-1012); the ELEVATION tile bit is never set.
function world:elevationCount(tile)
    local things = tile and tile.things
    if not things then return 0 end
    local elev, n = self.f.elevation, 0
    for i = 1, #things do
        local t = things[i]
        if t.kind == 'item' and t.id and (elev(t.id) or 0) > 0 then n = n + 1 end
    end
    return n
end

-- Thing::isCommon (thing.h:67) = not ground, not groundBorder, not onTop, not onBottom.
function world:isCommonItem(id)
    local f = self.f
    return not (f.isGround(id) or f.isGroundBorder(id) or f.isOnTop(id) or f.isOnBottom(id))
end

-- Tile::getMinimapColorByte (tile.cpp:571-584): reverse scan, skip creatures and "common"
-- items, first non-zero automap colour, else 255.
function world:minimapColor(tile)
    local things = tile and tile.things
    if not things then return 255 end
    local colorOf = self.f.minimapColor
    for i = #things, 1, -1 do
        local t = things[i]
        if t.kind == 'item' and t.id and not self:isCommonItem(t.id) then
            local c = colorOf(t.id) or 0
            if c ~= 0 then return c end
        end
    end
    return 255
end

-- Map::getMinimapColor (map.cpp:1168-1178): the tile's colour byte, and ONLY when that is 0
-- does it fall back to the persisted minimap.  Tile::getMinimapColorByte never returns 0
-- (its "no colour" answer is 255), so for an existing tile the fallback is unreachable --
-- docs/vbot/pathfinding.md VERIFIER.
function world:mapColorAt(pos)
    local tile = self.state:tile(pos)
    local color = 0
    if tile then color = self:minimapColor(tile) end
    if color == 0 then
        local _, c = self:knownAt(pos)
        color = c
    end
    return color
end

-- Tile::hasBlockingCreature (tile.cpp:838-844): a creature that is not passable and is not
-- the local player.  NOTE: unlike isWalkable this does NOT test canBeSeen().
function world:hasBlockingCreature(tile)
    local things = tile and tile.things
    if not things then return false end
    local st = self.state
    local myId = st.player and st.player.id
    for i = 1, #things do
        local t = things[i]
        if t.kind == 'creature' and t.creatureId ~= myId then
            if not isPassable(st.creatures[t.creatureId]) then return true end
        end
    end
    return false
end

-- Tile::isWalkable (tile.cpp:708-724)
function world:isWalkable(tile, ignoreCreatures)
    if not tile then return false end
    if not self:getGround(tile) then return false end
    if self:notWalkable(tile) then return false end
    if not ignoreCreatures then
        local things, st = tile.things, self.state
        for i = 1, #things do
            local t = things[i]
            if t.kind == 'creature' then
                local c = st.creatures[t.creatureId]
                if not isPassable(c) and world.canBeSeen(c) then return false end
            end
        end
    end
    return true
end

-- Tile::isPathable (tile.h:77)
function world:isPathable(tile)
    return not self:notPathable(tile)
end

-- Tile::getTopUseThing (tile.cpp:599-616) -- what looting and the floor-change guard read.
-- (1) first thing that isForceUse OR (not ground, not groundBorder, not onBottom, not onTop,
--     not creature, not splash);
-- (2) else scan BACKWARDS from the top down to index 1 (0-based) for the first non-splash,
--     non-creature thing;
-- (3) else things[0].
function world:getTopUseThing(tile)
    local things = tile and tile.things
    if not things or #things == 0 then return nil end
    local f = self.f
    for i = 1, #things do
        local t = things[i]
        if t.kind == 'item' and t.id then
            if f.isForceUse(t.id)
               or not (f.isGround(t.id) or f.isGroundBorder(t.id) or f.isOnBottom(t.id)
                       or f.isOnTop(t.id) or f.isSplash(t.id)) then
                return t
            end
        end
    end
    for i = #things, 2, -1 do
        local t = things[i]
        if t.kind == 'item' and t.id and not f.isSplash(t.id) then return t end
    end
    return things[1]
end

-- ---------------------------------------------------------------------------
-- BOT.md: world.tileWalkable(pos, opts) -- the documented predicate (flags + creatures +
-- fields).  Returns bool plus a reason string.
--   opts.ignoreCreatures    creatures never block
--   opts.ignoreNonPathable  magic fields (avoid, not unpass) never block -- what every vBot
--                           call passes as "ignore fields"
-- ---------------------------------------------------------------------------
function world:tileWalkable(pos, opts)
    opts = opts or {}
    local tile = self.state:tile(pos)
    if not tile then return false, 'unknown-tile' end
    if not self:getGround(tile) then return false, 'no-ground' end
    if self:notWalkable(tile) then return false, 'not-walkable' end
    if not opts.ignoreNonPathable and self:notPathable(tile) then return false, 'not-pathable' end
    if not opts.ignoreCreatures then
        local things, st = tile.things, self.state
        for i = 1, #things do
            local t = things[i]
            if t.kind == 'creature' then
                local c = st.creatures[t.creatureId]
                if not isPassable(c) and world.canBeSeen(c) then return false, 'creature' end
            end
        end
    end
    return true, 'ok'
end

-- ---------------------------------------------------------------------------
-- Map::findEveryPath's per-neighbour classification (map.cpp:1400-1424), lifted out so
-- bot/path.lua stays a pure search.  Returns SIX values and allocates nothing.
--
--   defaults (map.cpp:1400-1405):
--     wasSeen=false hasCreature=false isNotWalkable=true isNotPathable=true color=0 speed=1000
--   aware branch (1406-1414): a MISSING tile keeps the defaults (unlike variant B!)
--   minimap branch (1415-1424), skipped when allowOnlyVisibleTiles:
--     blocked (not walkable OR not pathable) IMPLIES wasSeen (1421-1422); speed = byte * 10
--
-- The minimap branch reads `self.known` (work item M) -- normally the lib/minimap.lua reader
-- over the reference client's profiles/minimap.otmm.  The LIVE MAP ALWAYS WINS: the minimap
-- is consulted only when state:isAwareOf(pos) is false, so a tile the server has described
-- classifies exactly as it did before this fallback existed, even when the two disagree.
-- With no minimap loaded, knownAt answers the null tile (0, 255, 10) and every outside tile
-- is `not wasSeen` -- i.e. blocked unless allowUnseen, which is the pre-work-item-M behaviour.
-- ---------------------------------------------------------------------------
function world:classifyForPath(pos, allowOnlyVisibleTiles)
    local wasSeen, hasCreature = false, false
    local notWalk, notPath = true, true
    local color, speed = 0, 1000

    if self.state:isAwareOf(pos) then
        local tile = self.state:tile(pos)
        if tile then
            wasSeen     = true
            hasCreature = self:hasBlockingCreature(tile)
            notWalk     = not self:isWalkable(tile, true)   -- ignoreCreatures = TRUE
            notPath     = not self:isPathable(tile)
            color       = self:minimapColor(tile)
            speed       = self:groundSpeed(tile)
        end
    elseif not allowOnlyVisibleTiles then
        local f, c, sByte = self:knownAt(pos)
        wasSeen = bit.band(f, world.KNOWN_WAS_SEEN)     ~= 0
        notWalk = bit.band(f, world.KNOWN_NOT_WALKABLE) ~= 0
        notPath = bit.band(f, world.KNOWN_NOT_PATHABLE) ~= 0
        color   = c
        if notWalk or notPath then wasSeen = true end
        speed   = sByte * 10
    end

    return wasSeen, hasCreature, notWalk, notPath, color, speed
end

-- ---------------------------------------------------------------------------
-- Floor-change classifier (cavebot/walking.lua:116-166, docs/vbot/cavebot.md 3.4).
-- Fails OPEN: any internal error must never stop the bot walking.
-- ---------------------------------------------------------------------------
local FLOOR_CHANGE_LENSHELP = { [1104] = true, [1105] = true }  -- stairs up / stairs down only
world.FLOOR_CHANGE_LENSHELP = FLOOR_CHANGE_LENSHELP
-- 1100 ladders, 1101 sewer grates, 1102 rope spots, 1106 shovel spots are DELIBERATELY
-- excluded (walking.lua:96-100): standing on them is harmless, they need a use().

function world:itemChangesFloor(id, isGroundSlot)
    if not id then return false end
    if FLOOR_CHANGE_LENSHELP[self.f.lensHelp(id) or 0] then return true end
    if isGroundSlot and self.f.isNotPathable(id) then return true end
    return false
end

local function idListHas(list, id)
    if not list or not id then return false end
    for i = 1, #list do if list[i] == id then return true end end
    return false
end
world.idListHas = idListHas

-- Parse the cfg's avoidTileIds CSV once.  Accepts a string or a ready-made array.
function world.parseIdList(v)
    if type(v) == 'table' then return v end
    local out = {}
    if type(v) ~= 'string' then return out end
    for n in v:gmatch('%-?%d+') do out[#out + 1] = tonumber(n) end
    return out
end

function world:isFloorChangeTile(pos, avoidIds)
    local ok, bad, why = pcall(function()
        local tile = self.state:tile(pos)
        if not tile then return false end          -- unseen: trust the pathfinder's stairs rule

        local color = self:mapColorAt(pos)
        if color >= 210 and color <= 213 and not self:isPathable(tile) then
            return true, 'stairs (yellow, not pathable)'
        end

        local g = self:getGround(tile)             -- GROUND flag, not "things[1]" -- VERIFIER
        if g and self:itemChangesFloor(g.id, true) then
            return true, 'floor-change ground id ' .. tostring(g.id)
        end

        local top = self:getTopUseThing(tile)
        if top and top ~= g and top.kind == 'item' and self:itemChangesFloor(top.id, false) then
            return true, 'floor-change item id ' .. tostring(top.id)
        end

        if avoidIds and #avoidIds > 0 then
            if (g and idListHas(avoidIds, g.id)) or (top and idListHas(avoidIds, top.id)) then
                return true, 'listed avoidTileId'
            end
        end
        return false
    end)
    if not ok then return false, nil end           -- fail open
    return bad and true or false, why
end

-- CaveBot.wouldStepChangeFloor(pos, dir) (walking.lua:172-183)
function world:wouldStepChangeFloor(pos, dir, avoidIds)
    local d = DELTA[dir]
    if not d then return false end
    return self:isFloorChangeTile({ x = pos.x + d[1], y = pos.y + d[2], z = pos.z }, avoidIds)
end

-- antilost's "recovery tile": yellow (210-213) OR its top-use id is in the ladder / rope
-- lists (antilost.lua:80-103).
function world:isRecoveryTile(pos, ladderIds, ropeIds)
    local tile = self.state:tile(pos)
    if not tile then return false end
    local color = self:mapColorAt(pos)
    if color >= 210 and color <= 213 then return true, 'yellow' end
    local top = self:getTopUseThing(tile)
    if top and top.kind == 'item' then
        if idListHas(ladderIds, top.id) then return true, 'ladder' end
        if idListHas(ropeIds, top.id)   then return true, 'rope' end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Map::isSightClear (map.cpp:1181-1225), verbatim.  Fails OPEN on tiles we do not hold and
-- (in degraded item mode) on the projectile flag, exactly like vBot's own helper.
-- ---------------------------------------------------------------------------
function world:isSightClear(fromPos, toPos)
    if not (fromPos and toPos) then return true end
    if fromPos.x == toPos.x and fromPos.y == toPos.y and fromPos.z == toPos.z then return true end

    local start, dest
    if fromPos.z > toPos.z then start, dest = toPos, fromPos else start, dest = fromPos, toPos end
    local sx, sy, sz = start.x, start.y, start.z
    local dx, dy = dest.x, dest.y

    local mx = (sx < dx) and 1 or ((sx == dx) and 0 or -1)
    local my = (sy < dy) and 1 or ((sy == dy) and 0 or -1)

    local A = dy - sy
    local B = sx - dx
    local C = -(A * dx + B * dy)

    local guard = 0
    while sx ~= dx or sy ~= dy do
        guard = guard + 1
        if guard > 4096 then break end
        local mh = abs(A * (sx + mx) + B * sy          + C)
        local mv = abs(A * sx        + B * (sy + my)   + C)
        local mc = abs(A * (sx + mx) + B * (sy + my)   + C)
        if sy ~= dy and (sx == dx or mh > mv or mh > mc) then sy = sy + my end
        if sx ~= dx and (sy == dy or mv > mh or mv > mc) then sx = sx + mx end
        local tile = self.state:tile({ x = sx, y = sy, z = sz })
        if tile and self:blocksProjectile(tile) then return false end
    end

    -- floor climb: any tile with things on it blocks (map.cpp:1216-1222)
    while sz ~= dest.z do
        local tile = self.state:tile({ x = sx, y = sy, z = sz })
        if tile and tile.things and #tile.things > 0 then return false end
        sz = sz + 1
    end
    return true
end

-- ---------------------------------------------------------------------------
-- spectators
-- ---------------------------------------------------------------------------
--- REVIEW FIX: Map::getSpectatorsInRangeEx (src/client/map.cpp:658-668) derives the z span
--- from `getFirstAwareFloor()` / `getLastAwareFloor()`, and both read `m_centralPosition.z`
--- (map.cpp:815-829) -- NOT the query centre's z.  Taking it from the query centre made a
--- multi-floor spectator query centred off the player's floor return a different creature
--- set entirely.  The C++ minZRange/maxZRange are uint8_t and wrap when the centre is
--- above the first aware floor; we clamp deliberately instead.
local function awareFloors(st, z, multifloor)
    if not multifloor then return z, z end
    local cz = (st.central and st.central.z)
               or (st.player and st.player.pos and st.player.pos.z) or z
    local z0, z1 = st.firstAwareFloor(cz), st.lastAwareFloor(cz)
    if z0 > z1 then z0, z1 = z1, z0 end          -- the uint8_t wrap, clamped
    return z0, z1
end

-- spectatorsInAwareRange (functions/map.lua:8-37): the aware rectangle around `pos`;
-- multifloor spans firstAwareFloor..lastAwareFloor.  Deduplicated by creature id.
function world:spectators(pos, multifloor)
    local st = self.state
    pos = pos or (st.player and st.player.pos)
    local out = {}
    if not pos then return out end
    local a = st.world.awareRange
    local z0, z1 = awareFloors(st, pos.z, multifloor == true)
    local x0, x1 = pos.x - a.left, pos.x + a.right
    local y0, y1 = pos.y - a.top,  pos.y + a.bottom
    for _, c in pairs(st.creatures) do
        local p = c.pos
        if p and p.z >= z0 and p.z <= z1
           and p.x >= x0 and p.x <= x1 and p.y >= y0 and p.y <= y1 then
            out[#out + 1] = c
        end
    end
    return out
end

-- Map::getSpectatorsByPattern (map.cpp:1475-1540), per docs/vbot/attackbot.md 2.1.
local gridCache = {}
local function parseGrid(gridStr)
    local g = gridCache[gridStr]
    if g then return g end
    local cells, width, height, lineLen = {}, 0, 0, 0
    for i = 1, #gridStr do
        local ch = gridStr:sub(i, i)
        if ch == '0' or ch == '-' then
            cells[#cells + 1] = false; lineLen = lineLen + 1
        elseif ch == '1' or ch == '+' then
            cells[#cells + 1] = true;  lineLen = lineLen + 1
        elseif ch:match('[NnEeSsWw]') then
            cells[#cells + 1] = ch:upper(); lineLen = lineLen + 1
        else
            if lineLen > 1 then
                if width == 0 then width = lineLen end
                if width ~= lineLen then return nil end     -- ragged
                height = height + 1; lineLen = 0
            elseif lineLen == 1 then
                lineLen = 0
            end
        end
    end
    if lineLen > 0 then
        if width == 0 then width = lineLen end
        if width ~= lineLen then return nil end
        height = height + 1
    end
    if width % 2 ~= 1 or height % 2 ~= 1 then return nil end -- both dims must be ODD
    g = { cells = cells, w = width, h = height }
    gridCache[gridStr] = g
    return g
end
world._parseGrid = parseGrid

local LETTER = { [0] = 'N', [1] = 'E', [2] = 'S', [3] = 'W' }

function world:spectatorsByPattern(centre, gridStr, direction)
    local out = {}
    local g = parseGrid(gridStr)
    if not g or not centre then return out end
    local letter = LETTER[direction]         -- direction 8 (invalid) disables every letter cell
    local st = self.state
    local seen, p = {}, 0
    local hy, hx = floor(g.h / 2), floor(g.w / 2)
    for y = centre.y - hy, centre.y + hy do
        for x = centre.x - hx, centre.x + hx do
            p = p + 1
            local cell = g.cells[p]
            local on = (cell == true) or (type(cell) == 'string' and cell == letter)
            if on then
                local tile = st:tile({ x = x, y = y, z = centre.z })
                if tile then
                    local things = tile.things
                    for i = 1, #things do
                        local t = things[i]
                        if t.kind == 'creature' and t.creatureId and not seen[t.creatureId] then
                            local c = st.creatures[t.creatureId]
                            if c then seen[t.creatureId] = true; out[#out + 1] = c end
                        end
                    end
                end
            end
        end
    end
    return out
end

--- REVIEW FIX: game/state.lua sets isMonster for types 1/3/4, but vBot's
--- getMonstersInArea excludes summons on every branch (`spec:getType() < 3`,
--- AB:2559/2571) -- and bot/world.lua:countInArea is the helper BOT.md tells new code to
--- use.  Pass opts.includeSummons to get the loose form back.
local function isMonster(c, includeSummons)
    if c.isMonster ~= true then return false end
    if includeSummons then return true end
    return c.type == nil or c.type < 3
end
local function isPlayerC(c) return c.isPlayer == true end

function world:monsters(pos, range)
    local st = self.state
    pos = pos or (st.player and st.player.pos)
    local out = {}
    if not pos then return out end
    range = range or 10
    for _, c in pairs(st.creatures) do
        if isMonster(c) and c.pos and c.pos.z == pos.z and chebyshev(c.pos, pos) <= range then
            out[#out + 1] = c
        end
    end
    return out
end

function world:players(pos, range)
    local st = self.state
    pos = pos or (st.player and st.player.pos)
    local out = {}
    if not pos then return out end
    range = range or 10
    local myId = st.player and st.player.id
    for _, c in pairs(st.creatures) do
        if isPlayerC(c) and c.id ~= myId and c.pos and c.pos.z == pos.z
           and chebyshev(c.pos, pos) <= range then
            out[#out + 1] = c
        end
    end
    return out
end

function world:npcs(pos, range)
    local st = self.state
    pos = pos or (st.player and st.player.pos)
    local out = {}
    if not pos then return out end
    range = range or 10
    for _, c in pairs(st.creatures) do
        if c.isNpc and c.pos and c.pos.z == pos.z and chebyshev(c.pos, pos) <= range then
            out[#out + 1] = c
        end
    end
    return out
end

-- BOT.md: world.countInArea(centerPos, pattern, dir) -- monsters inside a spell pattern.
-- docs/vbot/attackbot.md 2.2 AREA path: exclude the local player, require isMonster, and
-- (optionally) an inclusive HP window, a lowercase name whitelist and a sight check.
function world:countInArea(centerPos, pattern, dir, opts)
    opts = opts or {}
    local st = self.state
    local myId = st.player and st.player.id
    local specs = self:spectatorsByPattern(centerPos, pattern, dir == nil and 8 or dir)
    local minHp = opts.minHp or 0
    local maxHp = opts.maxHp or 100
    local names = opts.names
    local sightFrom = opts.sightFrom
    local n = 0
    for i = 1, #specs do
        local c = specs[i]
        local hp = c.healthPercent or 100
        if c.id ~= myId and isMonster(c, opts.includeSummons)
           and hp >= minHp and hp <= maxHp then
            local nameOk = true
            if names and #names > 0 then
                nameOk = false
                local low = (c.name or ''):lower()
                for j = 1, #names do
                    if names[j] == low then nameOk = true; break end
                end
            end
            if nameOk and (not sightFrom or self:isSightClear(sightFrom, c.pos)) then
                n = n + 1
            end
        end
    end
    return n
end

return world
