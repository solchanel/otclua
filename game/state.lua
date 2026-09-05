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

-- Thing::getStackPriority without ThingType data.
-- We only know 'item' vs 'creature' from the parser.  Whether an item is ground /
-- ground-border / on-bottom / on-top needs the appearance flags, which assets/items1530.bin
-- does NOT carry (proto/items.lua exposes only CUMULATIVE/WEAROUT/EXPIRE/CONTAINER/CLASSIFY/
-- PODIUM/DECOKIT).  So a caller that knows better may set thing.stackPriority explicitly;
-- otherwise we fall back to CREATURE(4) for creatures and COMMON_ITEMS(5) for items, which is
-- the correct answer for every thing that arrives with an EXPLICIT stackpos (0x6A, tile
-- descriptions) -- auto-detect is only ever used by callers that pass nil/-1/255.
local function stackPriorityOf(thing)
    if type(thing.stackPriority) == 'number' then return thing.stackPriority end
    if thing.kind == 'creature' then return PRIO_CREATURE end
    return PRIO_COMMON_ITEM
end
state.stackPriorityOf = stackPriorityOf

-- Same thing, but knowing WHERE on the tile it already sits.  The one piece of ground
-- information we can recover without ThingType flags is that the item at 0-based index 0 of a
-- described tile is the ground (the server always writes the ground item first), so give it
-- PRIO_GROUND.  Without this an auto-placed creature would sort BELOW the ground, because our
-- flagless fallback calls every item a common item (priority 5).
local function priorityAt(things, idx0, thing)
    if type(thing.stackPriority) == 'number' then return thing.stackPriority end
    if idx0 == 0 and thing.kind ~= 'creature' then return PRIO_GROUND end
    return stackPriorityOf(thing)
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
-- walkableAt
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- containers / channels -- thin helpers; the parser owns the field contents
-- ---------------------------------------------------------------------------
function state:container(id)         return self.containers[id] end
function state:setContainer(id, c)   self.containers[id] = c; return c end
function state:closeContainer(id)    local c = self.containers[id]; self.containers[id] = nil; return c end

return state
