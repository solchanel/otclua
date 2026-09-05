-- game/state.lua -- the game state model (API.md "game/state.lua").
--
-- Mirrors the C++ Map/Tile/Creature/LocalPlayer bookkeeping that a headless client actually
-- needs.  Byte-level truth lives in docs/*.md; the behavioural rules replicated here are:
--
--   * Tile::addThing stack semantics (tile.cpp:323-375), INCLUDING the 11-thing trim that
--     docs/map-parsing.md's Corrections section makes authoritative:
--         const uint8_t size = m_things.size();      -- PRE-insert count
--         ... m_things.insert(m_things.begin() + stackPos, thing);
--         if (size > getTileMaxThings())             -- getTileMaxThings() == 10
--             removeThing(m_things[getTileMaxThings()]);
--     So the trim fires when the 12th thing arrives (pre-insert size 11 > 10) and it deletes
--     the thing at 0-based index 10 -- the tile therefore saturates at 11 things, and past
--     that point "wire stackpos" != "tile array index" for the C++ client too.  We reproduce
--     the C++ index exactly so later stackpos-addressed packets (0x6B/0x6C/0x6D) hit the same
--     thing the real client would hit.
--   * stackPos < 0 or == 255 -> auto-detect by stack priority; stackPos == -2 -> append
--     (tile.cpp:332-340); stackPos > size -> clamped to size.
--   * Map::addThing pre-filters (map.cpp:186-194): an item with id 0 is dropped; effects and
--     missiles never occupy a stack index.
--
-- STACKPOS CONVENTION: 0-based everywhere in this module, exactly like the wire and like the
-- C++ Tile.  Lua array indices are stackPos+1 internally; callers never see that.
--
-- Tile key: the string "x,y,z" that API.md documents.  state.tileKey(pos) / state.parseKey(k)
-- are exported so other modules never hand-roll it.  A packed integer key is also available
-- as state.packKey(pos) for callers that want a numeric id (exact: (x*65536+y)*16+z < 2^37).

local bit   = require('bit')
local items = require('proto.items')
local band, bor = bit.band, bit.bor

local state = {}
state.__index = state

-- data/setup.otml:16 `max-things: 10` -> g_gameConfig.getTileMaxThings()
local TILE_MAX_THINGS = 10

-- Thing::getStackPriority (thing.cpp:54-77)
local PRIO_GROUND        = 0
local PRIO_GROUND_BORDER = 1
local PRIO_ON_BOTTOM     = 2
local PRIO_ON_TOP        = 3
local PRIO_CREATURE      = 4
local PRIO_COMMON_ITEM   = 5

state.TILE_MAX_THINGS = TILE_MAX_THINGS
state.STACK_PRIORITY = {
    ground = PRIO_GROUND, groundBorder = PRIO_GROUND_BORDER, onBottom = PRIO_ON_BOTTOM,
    onTop = PRIO_ON_TOP, creature = PRIO_CREATURE, item = PRIO_COMMON_ITEM,
}

-- ---------------------------------------------------------------------------
-- keys
-- ---------------------------------------------------------------------------
local function tileKey(pos)
    return pos.x .. ',' .. pos.y .. ',' .. pos.z
end

local function parseKey(key)
    local x, y, z = key:match('^(-?%d+),(-?%d+),(-?%d+)$')
    if not x then return nil end
    return { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
end

-- exact in a double: (65535*65536+65535)*16+15 = 68719476735 < 2^53
local function packKey(pos)
    return (pos.x * 65536 + pos.y) * 16 + pos.z
end

state.tileKey  = tileKey
state.parseKey = parseKey
state.packKey  = packKey

local function samePos(a, b)
    return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end
state.samePos = samePos

local function copyPos(p)
    return { x = p.x, y = p.y, z = p.z }
end
state.copyPos = copyPos

-- items1530.bin v2 carries FLAGS2 (GROUND/GROUND_BORDER/ON_BOTTOM/ON_TOP), so
-- Thing::getStackPriority (thing.cpp:54-77) is now exact for items.  A caller may still
-- pin thing.stackPriority explicitly; creatures are always PRIO_CREATURE(4).
--
-- LEGACY FALLBACK: when the item table has not been loaded (proto/items.lua reports
-- items.loaded == false -- e.g. a unit test that builds a state by hand), we keep the v1
-- heuristic: every item is a common item, except the one at 0-based index 0 of a described
-- tile, which the server always writes as the ground.  Without that an auto-placed creature
-- would sort BELOW the ground.
local function itemPriority(id)
    if items.loaded and type(id) == 'number' and id >= 1 and id <= items.MAX_ID then
        return items.stackPriority(id)
    end
    return nil
end

local function stackPriorityOf(thing)
    if type(thing.stackPriority) == 'number' then return thing.stackPriority end
    if thing.kind == 'creature' then return PRIO_CREATURE end
    return itemPriority(thing.id) or PRIO_COMMON_ITEM
end
state.stackPriorityOf = stackPriorityOf

-- Same thing, but knowing WHERE on the tile it already sits (only the legacy fallback
-- cares -- with flags loaded the index is irrelevant).
local function priorityAt(things, idx0, thing)
    if type(thing.stackPriority) == 'number' then return thing.stackPriority end
    if thing.kind == 'creature' then return PRIO_CREATURE end
    local p = itemPriority(thing.id)
    if p then return p end
    if idx0 == 0 then return PRIO_GROUND end
    return PRIO_COMMON_ITEM
end

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
local function newPlayer()
    return {
        id = 0, name = nil, pos = nil,
        health = 0, maxHealth = 0, mana = 0, maxMana = 0,
        level = 0, levelPercent = 0, exp = 0,
        magicLevel = 0, baseMagicLevel = 0, magicLevelPercent = 0,
        soul = 0, stamina = 0, capacity = 0, maxCapacity = 0,
        speed = 0, baseSpeed = 0,
        -- proto/parser.lua S[0xA2] writes statesLo/statesHigh; declare exactly those names
        -- (the 0xA0 PlayerState mask is a u64 at >=1405, split into two u32 halves).
        states = 0, statesLo = 0, statesHigh = 0,
        skills = {},          -- [skillId] = {level=, baseLevel=, percent=}
        inventory = {},       -- [slot] = item
        direction = 0,
        outfit = nil, vocation = 0, blessings = 0,
        isDead = false,
        -- walk model (docs/state-events.md §17); the walker owns these, we just hold them
        serverPos = nil, preWalks = {}, walkLockUntil = 0,
        waitingForServerWalk = false, lastWalkTime = 0,
    }
end

function state.new()
    local self = setmetatable({}, state)
    self:reset()
    return self
end

function state:reset()
    self.player     = newPlayer()
    self.creatures  = {}   -- [id] = creature
    self.map        = {}   -- ["x,y,z"] = tile
    self.containers = {}   -- [id] = container
    self.channels   = {}   -- [id] = name
    -- MUTATE world and world.awareRange IN PLACE.  proto/parser.lua aliases the awareRange
    -- table (`self.aware = state.world.awareRange`), so replacing it here would leave the
    -- parser sizing every later map packet with the PRE-reset range while state reported the
    -- 8/6/9/7 default -- an unrecoverable desync on the first packet after a relogin.
    local w = self.world
    if not w then
        w = {}
        self.world = w
    end
    w.name, w.worldTime, w.light = nil, nil, nil
    local a = w.awareRange
    if a then
        -- Map::resetAwareRange defaults (map.cpp:78); opcode 0x33 overwrites, and a
        -- logout/relogin RESETS back to these (docs/map-parsing.md Additions).
        a.left, a.top, a.right, a.bottom = 8, 6, 9, 7
    else
        w.awareRange = { left = 8, top = 6, right = 9, bottom = 7 }
    end
    self.central   = nil
    self.tileCount = 0
    return self
end

-- ---------------------------------------------------------------------------
-- tiles
-- ---------------------------------------------------------------------------
function state:tile(pos)
    return self.map[tileKey(pos)]
end

function state:setTile(pos, tile)
    local key = tileKey(pos)
    if self.map[key] == nil and tile ~= nil then
        self.tileCount = self.tileCount + 1
    elseif self.map[key] ~= nil and tile == nil then
        self.tileCount = self.tileCount - 1
    end
    if tile then
        tile.pos    = tile.pos or copyPos(pos)
        tile.things = tile.things or {}
        tile._flags = nil          -- derived-flag cache (see "tile derived queries")
    end
    self.map[key] = tile
    return tile
end

-- Map::cleanTile -- drop everything the server no longer describes.
function state:cleanTile(pos)
    local key = tileKey(pos)
    local tile = self.map[key]
    if not tile then return false end
    for i = 1, #tile.things do
        local t = tile.things[i]
        if t.kind == 'creature' and t.creatureId then
            local c = self.creatures[t.creatureId]
            if c and samePos(c.pos, pos) then c.pos = nil end
        end
    end
    self.map[key] = nil
    self.tileCount = self.tileCount - 1
    return true
end

function state:getOrCreateTile(pos)
    local key = tileKey(pos)
    local tile = self.map[key]
    if not tile then
        tile = { pos = copyPos(pos), things = {} }
        self.map[key] = tile
        self.tileCount = self.tileCount + 1
    end
    return tile
end

-- ---------------------------------------------------------------------------
-- Tile::addThing  (tile.cpp:323-375)
--   pos       {x,y,z}
--   stackPos  0-based; nil / <0 / 255 -> auto-detect, -2 -> append, >size -> size
--   thing     {kind='item'|'creature'|'effect'|'missile', id=, count=, tier=, creatureId=, ...}
-- returns: the 0-based index the thing ended up at, or nil when it was filtered out.
-- ---------------------------------------------------------------------------
function state:addThing(pos, stackPos, thing)
    if type(thing) ~= 'table' then
        error('state:addThing: thing must be a table', 2)
    end

    -- Map::addThing / Tile::addThing pre-filters
    if thing.kind == 'effect' or thing.kind == 'missile' then
        -- effects live in a separate list and never occupy a stack index; missiles are
        -- attached to the floor, not to a tile (map.cpp:186-194, tile.cpp effect branch).
        return nil
    end
    if thing.kind ~= 'creature' and (thing.id == 0 or thing.id == nil) then
        return nil    -- map.cpp:186 `if (thing->isItem() && thing->getId() == 0) return;`
    end

    local tile   = self:getOrCreateTile(pos)
    local things = tile.things
    local size   = #things          -- PRE-insert count -- the trim below keys off THIS

    local sp = stackPos
    if sp == nil then sp = -1 end

    if sp < 0 or sp == 255 then
        local priority = stackPriorityOf(thing)
        local append
        if sp == -2 then
            append = true
        else
            append = (priority <= PRIO_ON_TOP)
            -- "newer protocols does not store creatures in reverse order" (cv >= 854)
            if priority == PRIO_CREATURE then append = not append end
        end
        local idx = 0
        while idx < size do
            local otherPriority = priorityAt(things, idx, things[idx + 1])
            if (append and otherPriority > priority) or ((not append) and otherPriority >= priority) then
                break
            end
            idx = idx + 1
        end
        sp = idx
    elseif sp > size then
        sp = size
    end

    table.insert(things, sp + 1, thing)
    tile._flags = nil               -- the derived-flag cache is stale now

    -- creature bookkeeping: the creature is now on this tile
    if thing.kind == 'creature' and thing.creatureId then
        local c = self.creatures[thing.creatureId]
        if not c then
            c = { id = thing.creatureId }
            self.creatures[thing.creatureId] = c
        end
        c.pos = copyPos(pos)
    end

    -- ---- the 11-thing trim (docs/map-parsing.md Corrections, tile.cpp:364-365) ----
    -- `size` is the PRE-insert count, so this fires only from the 12th thing onward, and
    -- it deletes 0-based index 10 (which is the 11th slot), leaving 11 things behind.
    if size > TILE_MAX_THINGS then
        self:_removeAt(tile, TILE_MAX_THINGS)
        -- The trim may have deleted the thing we just inserted (that happens exactly when it
        -- landed at 0-based index 10).  Recompute AUTHORITATIVELY: start from nil and only
        -- report an index when the thing actually survived, so we never hand the caller a
        -- stackpos that now addresses somebody else.
        local found
        for i = 1, #things do
            if things[i] == thing then found = i - 1 break end
        end
        sp = found
    end

    return sp
end

-- internal: erase 0-based index `idx` from `tile`, keeping creature bookkeeping honest
function state:_removeAt(tile, idx)
    local thing = tile.things[idx + 1]
    if thing == nil then return nil end
    table.remove(tile.things, idx + 1)
    tile._flags = nil               -- the derived-flag cache is stale now
    if thing.kind == 'creature' and thing.creatureId then
        local c = self.creatures[thing.creatureId]
        -- only clear the position if the creature was still believed to be HERE; a move that
        -- adds first and removes second must not wipe the new position.
        if c and samePos(c.pos, tile.pos) then c.pos = nil end
    end
    return thing
end

-- Tile::removeThing by stack index (0-based).  Returns the removed thing or nil.
function state:removeThing(pos, stackPos)
    local tile = self.map[tileKey(pos)]
    if not tile then return nil end
    if type(stackPos) ~= 'number' or stackPos < 0 then return nil end
    return self:_removeAt(tile, stackPos)
end

-- Tile::getThing (0-based).  Returns nil for an unknown tile or an out-of-range index --
-- never raises, because the C++ getThing(pos, 255) path is reachable in release builds.
function state:getThing(pos, stackPos)
    local tile = self.map[tileKey(pos)]
    if not tile then return nil end
    if type(stackPos) ~= 'number' then return nil end
    return tile.things[stackPos + 1]
end

function state:thingCount(pos)
    local tile = self.map[tileKey(pos)]
    return tile and #tile.things or 0
end

-- 0-based index of a creature id on a tile, or nil
function state:creatureStackPos(pos, creatureId)
    local tile = self.map[tileKey(pos)]
    if not tile then return nil end
    for i = 1, #tile.things do
        local t = tile.things[i]
        if t.kind == 'creature' and t.creatureId == creatureId then return i - 1 end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- aware range / central position  (Map::setCentralPosition -> removeUnawareThings)
-- ---------------------------------------------------------------------------
-- docs/opcode-map.md:89 lists 72 GameKeepUnawareTiles in the "NEVER enabled" set, so the C++
-- Map::setCentralPosition ALWAYS calls removeUnawareThings() (map.cpp:549-614), which drops
-- every tile outside the aware range on each central-position change.  Without this a
-- long-running headless session grows self.map without bound AND keeps answering
-- state:tile()/state:walkableAt() from tiles the real client has already forgotten.
--
-- data/setup.otml: max-z 15, sea-floor 7, aware-underground-floor-range 2.
local MAP_MAX_Z            = 15
local MAP_SEA_FLOOR        = 7
local MAP_AWARE_UNDER_RANGE = 2
state.MAP_MAX_Z = MAP_MAX_Z

-- Map::getFirstAwareFloor / getLastAwareFloor (map.cpp:815-829)
local function firstAwareFloor(cz)
    if cz <= MAP_SEA_FLOOR then return 0 end
    return cz - MAP_AWARE_UNDER_RANGE
end
local function lastAwareFloor(cz)
    if cz <= MAP_SEA_FLOOR then return MAP_SEA_FLOOR end
    local v = cz + MAP_AWARE_UNDER_RANGE
    return (v < MAP_MAX_Z) and v or MAP_MAX_Z
end
state.firstAwareFloor = firstAwareFloor
state.lastAwareFloor  = lastAwareFloor

-- Map::isAwareOfPosition (map.cpp:776-798) -- project `pos` onto the central floor with
-- Position::coveredUp/coveredDown (x,y shift by 1 per z step, map.cpp/position.cpp:49-72),
-- then test the rectangle.  `central` defaults to the local player's position.
function state:isAwareOf(pos, central)
    central = central or self.central or (self.player and self.player.pos)
    if not (central and pos) then return false end
    local cz = central.z
    if pos.z < firstAwareFloor(cz) or pos.z > lastAwareFloor(cz) then return false end

    local x, y, z = pos.x, pos.y, pos.z
    local guard = 0
    while z ~= cz do
        guard = guard + 1
        if guard > MAP_MAX_Z + 1 then break end
        if z > cz then
            -- coveredUp: x+1, y+1, z-1 (refused, and the C++ breaks, at the 65535 edge)
            if x >= 65535 or y >= 65535 or z - 1 < 0 then break end
            x, y, z = x + 1, y + 1, z - 1
        else
            -- coveredDown: x-1, y-1, z+1 (refused at the 0 edge)
            if x <= 0 or y <= 0 or z + 1 > MAP_MAX_Z then break end
            x, y, z = x - 1, y - 1, z + 1
        end
    end
    if z ~= cz then return false end          -- isInRange returns false when the z differs

    local a = self.world.awareRange
    return x >= central.x - a.left and x <= central.x + a.right
       and y >= central.y - a.top  and y <= central.y + a.bottom
end

-- Map::setCentralPosition: record the new centre and evict everything we are no longer aware
-- of.  Returns the number of tiles removed.  Calling it with the position we already hold is
-- a no-op, exactly like the C++ early return.
function state:setCentralPosition(pos)
    if not pos then return 0 end
    if samePos(self.central, pos) then return 0 end
    self.central = copyPos(pos)

    local doomed
    for key, tile in pairs(self.map) do
        local p = tile.pos or parseKey(key)
        if p and not self:isAwareOf(p, self.central) then
            doomed = doomed or {}
            doomed[#doomed + 1] = p
        end
    end
    if not doomed then return 0 end
    for i = 1, #doomed do self:cleanTile(doomed[i]) end

    -- creatures we are no longer aware of lose their tile binding too (removeUnawareThings
    -- calls Map::removeThing on them); cleanTile already did that for described tiles, this
    -- catches creatures whose tile was never in self.map.
    for _, c in pairs(self.creatures) do
        if c.pos and not self:isAwareOf(c.pos, self.central) then c.pos = nil end
    end
    return #doomed
end

-- ---------------------------------------------------------------------------
-- creatures
-- ---------------------------------------------------------------------------
function state:getCreature(id)
    return self.creatures[id]
end

-- Register / merge a creature record.  Fields follow API.md.
function state:addCreature(creature)
    if type(creature) ~= 'table' or type(creature.id) ~= 'number' then
        error('state:addCreature: creature.id must be a number', 2)
    end
    local c = self.creatures[creature.id]
    if not c then
        c = { id = creature.id }
        self.creatures[creature.id] = c
    end
    for k, v in pairs(creature) do
        if k == 'pos' and v then c.pos = copyPos(v) else c[k] = v end
    end
    if c.isPlayer == nil and c.type ~= nil then
        -- Proto::CreatureType 0 player, 1 monster, 2 npc, 3 own summon, 4 summon, 5 hidden
        c.isPlayer  = (c.type == 0)
        c.isMonster = (c.type == 1 or c.type == 3 or c.type == 4)
        c.isNpc     = (c.type == 2)
    end
    return c
end

-- Drop a creature entirely (0x6C DeleteOnMap for a creature / out of aware range).
function state:removeCreature(id)
    local c = self.creatures[id]
    if not c then return false end
    if c.pos then
        local sp = self:creatureStackPos(c.pos, id)
        if sp then self:removeThing(c.pos, sp) end
    end
    self.creatures[id] = nil
    return true
end

-- 0x6D MoveCreature: remove the creature thing from `fromPos` (at `fromStackPos` when the
-- wire gave us one) and re-add it at `toPos`.  Keeps state.creatures[id].pos in step with the
-- tile arrays -- this is the "its tile must be updated on move" invariant.
function state:moveCreature(id, fromPos, fromStackPos, toPos)
    local c = self.creatures[id]
    local thing
    local src = fromPos or (c and c.pos)
    if src then
        local sp = fromStackPos
        if type(sp) ~= 'number' or sp < 0 or sp == 255 then
            sp = self:creatureStackPos(src, id)
        else
            local at = self:getThing(src, sp)
            if not (at and at.kind == 'creature' and at.creatureId == id) then
                sp = self:creatureStackPos(src, id)   -- wire stackpos stale; fall back to search
            end
        end
        if sp then thing = self:removeThing(src, sp) end
    end
    if not thing then
        thing = { kind = 'creature', creatureId = id, id = 0x63 }
    end
    if not c then
        c = { id = id }
        self.creatures[id] = c
    end
    local at = self:addThing(toPos, -1, thing)   -- auto-detect: creature priority
    c.pos = copyPos(toPos)
    if c.id == self.player.id then
        self.player.pos = copyPos(toPos)
    end
    return at
end

-- ---------------------------------------------------------------------------
-- walkableAt -- LEGACY (v1) API, deliberately frozen
-- ---------------------------------------------------------------------------
-- SUPERSEDED by state:isWalkable(pos, ignoreCreatures) below, which is exact now that
-- assets/items1530.bin v2 carries FLAGS2.  walkableAt is kept, unchanged, because its
-- four-value reason-string contract ('unknown-tile' / 'no-ground' / 'creature' /
-- 'items-unknown') is public API that existing callers and tests depend on; it still
-- never inspects item flags, so it still reports a wall as walkable.  NEW CODE MUST USE
-- state:isWalkable.
--
-- Tile::isWalkable (tile.cpp) is:
--     if (m_thingTypeFlag & NOT_WALKABLE || !getGround()) return false;
--     for each creature on the tile: if (!passable && canBeSeen) return false;
--     return true;
--
-- WHAT WE CANNOT KNOW WITHOUT FULL ThingType DATA
-- -----------------------------------------------
-- The NOT_WALKABLE half needs the appearance flag `unpass` (plus `isGround`, to identify the
-- ground item at all).  assets/items1530.bin, per API.md, carries only these bits:
--     CUMULATIVE WEAROUT EXPIRE CONTAINER CLASSIFY PODIUM DECOKIT
-- None of them is a movement flag.  So this helper CANNOT see:
--     * a blocking item on the tile (wall, closed door, parcel, tree, ...)  -> reported walkable
--     * `isGround` -- we infer "has ground" from "the tile has at least one item at stack
--       index 0", which is true for every tile the server describes (the ground item is
--       always the first thing written in a tile description) but is a heuristic, not a flag
--     * blockPathfind / isNotPathable, elevation, and the ground speed used for step timing
-- What it CAN decide exactly:
--     * unknown tile (never described, or cleanTile'd)                       -> false
--     * a creature standing there whose 0x92 CreatureUnpass said unpassable  -> false
-- The second return value names the reason, and is one of exactly four strings:
--     'unknown-tile'   -> false, definite: the tile was never described (or was cleaned)
--     'no-ground'      -> false, definite: nothing, or no item, at stack index 0
--     'creature'       -> false, definite: a non-passable creature stands there
--     'items-unknown'  -> true,  BUT item blocking was not checked (see above)
-- So: 'items-unknown' means "probably walkable" and every other value is a definite refusal.
-- A path finder must treat 'items-unknown' as walkable and the rest as blocked.
function state:walkableAt(pos, ignoreCreatures)
    local tile = self.map[tileKey(pos)]
    if not tile then return false, 'unknown-tile' end
    local things = tile.things
    if #things == 0 then return false, 'no-ground' end
    local ground = things[1]
    if ground.kind ~= 'item' then return false, 'no-ground' end
    if not ignoreCreatures then
        for i = 1, #things do
            local t = things[i]
            if t.kind == 'creature' then
                local c = t.creatureId and self.creatures[t.creatureId]
                -- Creature::isPassable defaults to FALSE in the C++ (unpass = true until
                -- 0x92 says otherwise), so an unknown creature blocks.
                if not (c and c.passable) then
                    return false, 'creature'
                end
            end
        end
    end
    return true, 'items-unknown'
end

-- ===========================================================================
-- tile derived queries  (docs/vbot/gaps.md P0-3, docs/vbot/pathfinding.md sec.4.2)
-- ===========================================================================
-- `Tile::m_thingTypeFlag` (tile.cpp:920-1012) folded into one cached bitmask per tile,
-- recomputed lazily and invalidated by every add/remove/clean.  The cache lives on the
-- tile table as `_flags` (bitmask), `_ground` (the ground thing or false) and
-- `_elevation` (the C++ m_elevation counter).
--
-- Rules ported verbatim, with their C++ line numbers:
--   * tile.cpp:996 `if (!thing->isItem()) return;` -- creatures contribute ONLY
--     HAS_CREATURE; they never set NOT_WALKABLE / NOT_PATHABLE / BLOCK_PROJECTILE /
--     FULL_GROUND.
--   * FULL_GROUND is set by ANY item on the tile carrying `fullbank`, not just by the
--     ground item.
--   * there is no HAS_GROUND bit in C++; `Tile::getGround()` (tile.cpp:537) is live and is
--     `things[0]` *only if that thing carries the GROUND flag*.  We cache the answer, which
--     is the same thing.
--   * `m_elevation` (tile.cpp:1011) counts items whose ThingType hasElevation() -- the FLAG,
--     not `elevation > 0`; proto/items.lua carries it as FLAGS5 ELEVATION.
--
-- WITHOUT THE ITEM TABLE (`items.loaded == false`) this degrades to the v1 heuristic:
-- an item at index 0 counts as the ground and no item ever blocks.  `state:tileFlagsExact()`
-- reports whether the answers are flag-backed.
local TF = {
    NOT_WALKABLE     = 1,
    NOT_PATHABLE     = 2,
    BLOCK_PROJECTILE = 4,
    HAS_CREATURE     = 8,
    HAS_GROUND       = 16,
    FULL_GROUND      = 32,
    HAS_COMMON       = 64,
    IGNORE_LOOK      = 128,
}
state.TF = TF

function state:tileFlagsExact()
    return items.loaded == true
end

function state:_recomputeTileFlags(tile)
    local f, ground, elevation = 0, false, 0
    local things = tile.things
    local exact = items.loaded
    for i = 1, #things do
        local t = things[i]
        if t.kind == 'creature' then
            f = bor(f, TF.HAS_CREATURE)
        else
            local id = t.id
            local ok = exact and type(id) == 'number' and id >= 1 and id <= items.MAX_ID
            if ok then
                local f2 = items.flags2(id)
                if band(f2, 0x10) ~= 0 then f = bor(f, TF.NOT_WALKABLE) end
                if band(f2, 0x20) ~= 0 then f = bor(f, TF.NOT_PATHABLE) end
                if band(f2, 0x80) ~= 0 then f = bor(f, TF.BLOCK_PROJECTILE) end
                if band(f2, 0x0F) == 0 then f = bor(f, TF.HAS_COMMON) end
                if i == 1 and band(f2, 0x01) ~= 0 then
                    ground = t
                    f = bor(f, TF.HAS_GROUND)
                end
                local f4 = items.flags4(id)
                if band(f4, 0x02) ~= 0 then f = bor(f, TF.FULL_GROUND) end
                if band(f4, 0x04) ~= 0 then f = bor(f, TF.IGNORE_LOOK) end
                if items.hasElevation(id) then elevation = elevation + 1 end
            else
                -- legacy fallback: index 0 is the ground, nothing blocks
                if i == 1 then
                    ground = t
                    f = bor(f, TF.HAS_GROUND)
                else
                    f = bor(f, TF.HAS_COMMON)
                end
            end
        end
    end
    tile._flags     = f
    tile._ground    = ground
    tile._elevation = elevation
    return f
end

-- Force a recompute.  Only needed by code that mutates tile.things behind state's back.
function state:invalidateTile(pos)
    local t = self.map[tileKey(pos)]
    if t then t._flags = nil end
    return t ~= nil
end

-- The folded bitmask of a tile, or nil when the tile is unknown.
function state:tileFlags(pos)
    local t = self.map[tileKey(pos)]
    if not t then return nil end
    return t._flags or self:_recomputeTileFlags(t)
end

local function tileOf(self, pos)
    local t = self.map[tileKey(pos)]
    if t and not t._flags then self:_recomputeTileFlags(t) end
    return t
end

-- Creature::canBeSeen() = !isInvisible() || isPlayer()  (creature.h:152,156).
-- Outfit::isEffect() && auxId == 13 is set by ProtocolGame::getOutfit ONLY in the
-- lookType == 0 && lookTypeEx == 0 case, so on the wire that IS the predicate.
local function creatureCanBeSeen(c)
    if not c then return true end            -- never seen a 0x8E for it: assume visible
    if c.isPlayer then return true end
    local o = c.outfit
    if o and o.lookType == 0 and (o.lookTypeEx or 0) == 0 then return false end
    return true
end
state.creatureCanBeSeen = creatureCanBeSeen

-- Tile::isWalkable (tile.cpp:708-725).
--   if (m_thingTypeFlag & NOT_WALKABLE || !getGround()) return false;
--   if (!ignoreCreatures) for each creature: if (!isPassable() && canBeSeen()) return false;
-- NOTE the deliberate asymmetry with hasBlockingCreature: isWalkable checks canBeSeen() but
-- does NOT exclude the local player (so your own tile is not walkable), while
-- hasBlockingCreature excludes the local player but does NOT check canBeSeen().
-- Second return value is a reason string: 'unknown-tile' | 'item' | 'no-ground' | 'creature'.
function state:isWalkable(pos, ignoreCreatures)
    local t = tileOf(self, pos)
    if not t then return false, 'unknown-tile' end
    local f = t._flags
    if band(f, TF.NOT_WALKABLE) ~= 0 then return false, 'item' end
    if band(f, TF.HAS_GROUND) == 0 then return false, 'no-ground' end
    if not ignoreCreatures and band(f, TF.HAS_CREATURE) ~= 0 then
        local things = t.things
        for i = 1, #things do
            local th = things[i]
            if th.kind == 'creature' then
                local c = th.creatureId and self.creatures[th.creatureId]
                -- Creature::m_passable defaults to FALSE (creature.h:359): unknown blocks.
                if not (c and c.passable) and creatureCanBeSeen(c) then
                    return false, 'creature'
                end
            end
        end
    end
    return true
end

-- Tile::isPathable (tile.h:77).  An unknown tile is NOT pathable.
function state:isPathable(pos)
    local f = self:tileFlags(pos)
    return f ~= nil and band(f, TF.NOT_PATHABLE) == 0
end

-- Tile::isLookPossible (tile.h:81) -- nothing on the tile carries `unsight`.
function state:isLookPossible(pos)
    local f = self:tileFlags(pos)
    return f ~= nil and band(f, TF.BLOCK_PROJECTILE) == 0
end

-- Tile::hasCreatures() -- ANY creature, the local player included.
function state:hasCreatures(pos)
    local f = self:tileFlags(pos)
    return f ~= nil and band(f, TF.HAS_CREATURE) ~= 0
end
state.hasCreature = state.hasCreatures

-- Tile::hasBlockingCreature (tile.cpp:838-844): a non-passable creature that is NOT the
-- local player.  No canBeSeen() test here -- that is isWalkable's job, not this one's.
function state:hasBlockingCreature(pos)
    local t = self.map[tileKey(pos)]
    if not t then return false end
    local myId = self.player and self.player.id
    local things = t.things
    for i = 1, #things do
        local th = things[i]
        if th.kind == 'creature' and th.creatureId ~= myId then
            local c = th.creatureId and self.creatures[th.creatureId]
            if not (c and c.passable) then return true end
        end
    end
    return false
end

-- Tile::hasElevation(n) (tile.h:129) -- m_elevation >= n.
function state:hasElevation(pos, n)
    local t = tileOf(self, pos)
    if not t then return false end
    return t._elevation >= (n or 1)
end

function state:elevation(pos)
    local t = tileOf(self, pos)
    return t and t._elevation or 0
end

-- Tile::getGround (tile.cpp:537): things[0], but only when it carries the GROUND flag.
function state:getGround(pos)
    local t = tileOf(self, pos)
    if not t then return nil end
    return t._ground or nil
end

-- Tile::getGroundSpeed (tile.cpp:562-569):
--     if (const auto& ground = getGround()) return ground->getGroundSpeed();
--     return 100;
-- The 100 is the NO-GROUND fallback ONLY.  A ground item whose `bank` has no `waypoints`
-- has speed 0 and this returns 0 verbatim -- do not substitute.  (Creature::getStepDuration
-- has its own, different, 150 substitution for a zero result; that belongs to the walker.)
function state:getGroundSpeed(pos)
    local g = self:getGround(pos)
    if not g then return 100 end
    local id = g.id
    if not (items.loaded and type(id) == 'number' and id >= 1 and id <= items.MAX_ID) then
        return 100
    end
    return items.groundSpeed(id)
end

-- Tile::getMinimapColorByte (tile.cpp:571-586):
--     if (m_minimapColor != 0) return m_minimapColor;   -- per-tile override
--     for (thing : reverse(m_things)) { if creature or isCommon: skip;
--                                       c = getMinimapColor(); if c != 0 return c; }
--     return 255;
-- Returns nil for an unknown tile -- see state:getMinimapColor for the Map:: wrapper.
function state:getMinimapColorByte(pos)
    local t = tileOf(self, pos)
    if not t then return nil end
    if t._minimapColor and t._minimapColor ~= 0 then return t._minimapColor end
    local things = t.things
    for i = #things, 1, -1 do
        local th = things[i]
        if th.kind ~= 'creature' then
            local id = th.id
            if items.loaded and type(id) == 'number' and id >= 1 and id <= items.MAX_ID then
                if not items.isCommon(id) then
                    local c = items.minimapColor(id)
                    if c ~= 0 then return c end
                end
            end
        end
    end
    return 255
end

-- Map::getMinimapColor (map.cpp:1168-1179):
--     int color = 0; if (tile) color = tile->getMinimapColorByte();
--     if (color == 0) color = g_minimap.getTile(pos).color;
-- `minimapFallback(pos)` stands in for g_minimap; a nil fallback yields the raw 0, and the
-- future game/minimap.lua plugs itself in here.  Note getMinimapColorByte NEVER returns 0
-- for an existing tile (255 is its "no colour"), so the fallback only fires on a tile we
-- do not have.
function state:getMinimapColor(pos, minimapFallback)
    local c = self:getMinimapColorByte(pos) or 0
    if c == 0 and minimapFallback then c = minimapFallback(pos) or 0 end
    return c
end

-- Tile::getTopUseThing (tile.cpp:600-617).  THIS is what looting uses to find the corpse
-- (targetbot/looting.lua:174,313).
--   1. first thing with isForceUse() || (isCommon() && !isSplash())
--   2. else scan BACKWARDS from the top down to index 1 (0-based), first non-splash
--      non-creature
--   3. else things[0]
-- C++ does not creature-guard the forceuse test; we must, because a creature thing has no
-- item id to look up.  No creature appearance carries forceuse, so the two agree.
function state:getTopUseThing(pos)
    local t = self.map[tileKey(pos)]
    if not t or #t.things == 0 then return nil end
    local things = t.things
    local usable = items.loaded
    for i = 1, #things do
        local th = things[i]
        if th.kind ~= 'creature' and usable
           and type(th.id) == 'number' and th.id >= 1 and th.id <= items.MAX_ID then
            if items.isForceUse(th.id)
               or (items.isCommon(th.id) and not items.isSplash(th.id)) then
                return th
            end
        end
    end
    for i = #things, 2, -1 do
        local th = things[i]
        if th.kind ~= 'creature' then
            local splash = usable and type(th.id) == 'number'
                           and th.id >= 1 and th.id <= items.MAX_ID and items.isSplash(th.id)
            if not splash then return th end
        end
    end
    return things[1]
end

-- Tile::getTopMoveThing (tile.cpp:654-675): the first isCommon thing; if that thing is not
-- at index 0 and is NOT_MOVEABLE, return the thing BEFORE it; else the first creature; else
-- things[0].
function state:getTopMoveThing(pos)
    local t = self.map[tileKey(pos)]
    if not t or #t.things == 0 then return nil end
    local things = t.things
    for i = 1, #things do
        local th = things[i]
        if th.kind ~= 'creature' and items.loaded
           and type(th.id) == 'number' and th.id >= 1 and th.id <= items.MAX_ID
           and items.isCommon(th.id) then
            if i > 1 and items.isNotMoveable(th.id) then return things[i - 1] end
            return th
        end
    end
    for i = 1, #things do
        if things[i].kind == 'creature' then return things[i] end
    end
    return things[1]
end

-- Tile::getTopCreature (tile.cpp:617-651), SIMPLIFIED: the first non-local-player creature,
-- else the local player, else nil.  The C++ additionally consults m_walkingCreatures and,
-- with checkAround, the 8 neighbouring tiles for a creature mid-step onto this one; a
-- headless client has no render-time walking list, so those clauses are dropped on purpose.
function state:getTopCreature(pos)
    local t = self.map[tileKey(pos)]
    if not t then return nil end
    local myId = self.player and self.player.id
    local mine
    local things = t.things
    for i = 1, #things do
        local th = things[i]
        if th.kind == 'creature' then
            if th.creatureId == myId then mine = th else return th end
        end
    end
    return mine
end

-- Map::isSightClear (map.cpp:1181-1225) -- the exact loop, including the two traps:
--   * a MISSING tile is transparent (`if (tile && !tile->isLookPossible()) return false;`),
--   * and so is a missing tile in the vertical tail.
-- Used by canShoot (which additionally gates on Chebyshev distance from the LOCAL PLAYER --
-- that part is not derivable here) and by AttackBot line-of-sight.
function state:isSightClear(fromPos, toPos)
    if samePos(fromPos, toPos) then return true end
    local start = (fromPos.z > toPos.z) and copyPos(toPos) or copyPos(fromPos)
    local dest  = (fromPos.z > toPos.z) and fromPos or toPos
    local mx = (start.x < dest.x) and 1 or ((start.x == dest.x) and 0 or -1)
    local my = (start.y < dest.y) and 1 or ((start.y == dest.y) and 0 or -1)
    local A, B = dest.y - start.y, start.x - dest.x
    local C = -(A * dest.x + B * dest.y)
    while start.x ~= dest.x or start.y ~= dest.y do
        local h = math.abs(A * (start.x + mx) + B * start.y        + C)
        local v = math.abs(A * start.x        + B * (start.y + my) + C)
        local x = math.abs(A * (start.x + mx) + B * (start.y + my) + C)
        if start.y ~= dest.y and (start.x == dest.x or h > v or h > x) then
            start.y = start.y + my
        end
        if start.x ~= dest.x and (start.y == dest.y or v > h or v > x) then
            start.x = start.x + mx
        end
        local f = self:tileFlags(start)
        if f and band(f, TF.BLOCK_PROJECTILE) ~= 0 then return false end
    end
    while start.z ~= dest.z do
        if self:thingCount(start) > 0 then return false end
        start.z = start.z + 1
    end
    return true
end

-- ---------------------------------------------------------------------------
-- containers / channels -- thin helpers; the parser owns the field contents
-- ---------------------------------------------------------------------------
function state:container(id)         return self.containers[id] end
function state:setContainer(id, c)   self.containers[id] = c; return c end
function state:closeContainer(id)    local c = self.containers[id]; self.containers[id] = nil; return c end

return state
