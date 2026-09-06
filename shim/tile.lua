--[[============================================================================
shim/tile.lua -- Tile (work item S1, PLAN sec.1.17).

`game/state.lua` already carries VERBATIM C++ ports of every predicate this class needs
(isWalkable, isPathable, isLookPossible, hasCreatures, hasElevation, getGround,
getGroundSpeed, getMinimapColorByte, getTopUseThing, getTopMoveThing, getTopCreature,
isSightClear) -- api-game.md sec.5 lists them.  So this file is a THIN ADAPTER: it turns
raw `tile.things[i]` records into interned Creature / Item wrappers and adds the two
orderings the C++ imposes.

The two orderings that a naive port gets wrong:

  * `Tile::getCreatures()` (tile.cpp:498) calls `appendSpectators` -- which walks the things
    array in REVERSE, top of stack first -- and then REVERSES the result.  Net effect:
    creatures in FORWARD stack order.  `g_map.getSpectators*` uses appendSpectators
    directly and therefore gets them TOP FIRST; shim/g_map.lua keeps that difference.
  * `Tile::getTopThing()` (tile.cpp:515) is the first `isCommon()` thing, and only if there
    is none the LAST thing on the tile -- not the last item, the last thing.
    `Thing::isCommon()` (thing.h:67) excludes creatures, so a tile holding only a ground and
    a creature answers the CREATURE.
============================================================================]]

local objects = require('shim.object')
local posmod  = require('shim.position')
local items   = require('proto.items')

local Tile = objects.Tile

local abs, max = math.abs, math.max

local function raw(self)
    return self._reg.state.map[self._key]
end
Tile._raw = raw

local function pos(self) return self._pos end

-- ---------------------------------------------------------------------------
-- identity / geometry
-- ---------------------------------------------------------------------------
function Tile:isTile() return true end

function Tile:getPosition()
    local p = self._pos
    return { x = p.x, y = p.y, z = p.z }
end

function Tile:isEmpty()
    local t = raw(self)
    return t == nil or #t.things == 0
end

function Tile:getThingCount()
    local t = raw(self)
    return t and #t.things or 0
end

-- Tile::getThingStackPos (tile.cpp:506) -- 0-based, -1 when absent.
function Tile:getThingStackPos(thing)
    local t = raw(self)
    if not t then return -1 end
    local target = (type(thing) == 'table' and thing._thing) or thing
    for i = 1, #t.things do
        if t.things[i] == target then return i - 1 end
    end
    return -1
end

-- ---------------------------------------------------------------------------
-- contents
-- ---------------------------------------------------------------------------
-- Wrap one raw thing with the location this tile gives it.
local function wrap(self, th)
    if th.kind == 'creature' then return self._reg:creature(th.creatureId) end
    return self._reg:item(th, { kind = 'tile', pos = self._pos })
end

function Tile:getThings()
    local t = raw(self)
    local out = {}
    if not t then return out end
    local things = t.things
    for i = 1, #things do
        local w = wrap(self, things[i])
        if w then out[#out + 1] = w end
    end
    return out
end

-- Tile::getItems (tile.cpp:539) -- stack order, items only.
function Tile:getItems()
    local t = raw(self)
    local out = {}
    if not t then return out end
    local things = t.things
    for i = 1, #things do
        local th = things[i]
        if th.kind ~= 'creature' then
            out[#out + 1] = self._reg:item(th, { kind = 'tile', pos = self._pos })
        end
    end
    return out
end

-- NOT a C++ Tile binding (only Container has one); every T1 `getItemsCount()` receiver is a
-- Container.  Provided because the work item asks for it and it is unambiguous.
function Tile:getItemsCount()
    local t = raw(self)
    if not t then return 0 end
    local n, things = 0, t.things
    for i = 1, #things do if things[i].kind ~= 'creature' then n = n + 1 end end
    return n
end

-- Tile::getCreatures (tile.cpp:498): appendSpectators (reverse) then reverse => FORWARD
-- stack order.  Deduplicated on id, like cleanNewSpectators.
function Tile:getCreatures()
    local t = raw(self)
    local out = {}
    if not t then return out end
    local things, seen = t.things, {}
    for i = 1, #things do
        local th = things[i]
        if th.kind == 'creature' and th.creatureId and not seen[th.creatureId] then
            local c = self._reg:creature(th.creatureId)
            if c then seen[th.creatureId] = true; out[#out + 1] = c end
        end
    end
    return out
end

-- Tile::getTopThing (tile.cpp:515-525).
function Tile:getTopThing()
    local t = raw(self)
    if not t or #t.things == 0 then return nil end
    local things = t.things
    for i = 1, #things do
        local th = things[i]
        if th.kind ~= 'creature' then
            local id = th.id
            if items.loaded and type(id) == 'number' and id >= 1 and id <= items.MAX_ID then
                if items.isCommon(id) then return wrap(self, th) end
            else
                -- no item table: the legacy heuristic in game/state.lua treats index 0 as
                -- the ground and everything else as common
                if i > 1 then return wrap(self, th) end
            end
        end
    end
    return wrap(self, things[#things])
end

-- Tile::getGround (tile.cpp:537) -- things[0] ONLY when it carries the GROUND flag.
function Tile:getGround()
    local g = self._reg.state:getGround(self._pos)
    if not g then return nil end
    return self._reg:item(g, { kind = 'tile', pos = self._pos })
end

-- Tile::getTopUseThing (tile.cpp:600-617) -- how looting finds the corpse.
function Tile:getTopUseThing()
    local th = self._reg.state:getTopUseThing(self._pos)
    if not th then return nil end
    return wrap(self, th)
end

-- Tile::getTopMoveThing (tile.cpp:654-675)
function Tile:getTopMoveThing()
    local th = self._reg.state:getTopMoveThing(self._pos)
    if not th then return nil end
    return wrap(self, th)
end

-- Tile::getTopCreature (tile.cpp:617-651), simplified in game/state.lua (no render-time
-- walking-creature list headless -- documented there).
function Tile:getTopCreature(_checkAround)
    local th = self._reg.state:getTopCreature(self._pos)
    if not th then return nil end
    return self._reg:creature(th.creatureId)
end

-- ---------------------------------------------------------------------------
-- predicates -- straight through to the verbatim ports in game/state.lua
-- ---------------------------------------------------------------------------
function Tile:isWalkable(ignoreCreatures)
    return self._reg.state:isWalkable(self._pos, ignoreCreatures) == true
end

function Tile:isPathable()
    return self._reg.state:isPathable(self._pos) == true
end

-- NOT a C++ binding: `cavebot/walking.lua:142` calls it and it fails on the real client.
-- Keeping it working is strictly better than reproducing the crash (api-game.md sec.4.3).
function Tile:isNotPathable()
    return not self:isPathable()
end

function Tile:isLookPossible()
    return self._reg.state:isLookPossible(self._pos) == true
end

function Tile:hasCreatures()
    return self._reg.state:hasCreatures(self._pos) == true
end
Tile.hasCreature = Tile.hasCreatures

function Tile:hasBlockingCreature()
    return self._reg.state:hasBlockingCreature(self._pos) == true
end

function Tile:hasElevation(n)
    return self._reg.state:hasElevation(self._pos, n) == true
end

function Tile:getElevation()
    return self._reg.state:elevation(self._pos)
end
Tile.getDrawElevation = Tile.getElevation

function Tile:getGroundSpeed()
    return self._reg.state:getGroundSpeed(self._pos)
end

-- Tile::getMinimapColorByte (tile.cpp:571-586) -- 1..255, NEVER 0 for a tile we hold.
function Tile:getMinimapColorByte()
    local c = self._reg.state:getMinimapColorByte(self._pos)
    if c == nil then return 255 end
    return c
end

-- Tile::hasFloorChange (tile.cpp:529): any thing whose ThingType carries the FloorChange
-- flag.  At 1530 that flag is only ever set from the legacy .dat path (thingtype.cpp:1096),
-- so the LIVE CLIENT ALSO ANSWERS FALSE HERE -- the user's own vBot says so at
-- cavebot/walking.lua:62 ("Tile:hasFloorChange() cannot help here: that attribute is only
-- ever ...").  Answering `true` from a heuristic would make the shim behave DIFFERENTLY
-- from the client vBot was written against, so it stays false and says so once.
function Tile:hasFloorChange()
    self._reg:report('Tile:hasFloorChange',
        'ThingFlagAttrFloorChange is never set at 1530; the live client also returns false '
        .. '(see cavebot/walking.lua:62)')
    return false
end

-- Tile::canShoot (tile.cpp:1133): Chebyshev from the LOCAL PLAYER, then isSightClear.
function Tile:canShoot(distance)
    local st = self._reg.state
    local playerPos = st.player and st.player.pos
    if not playerPos then return false end
    local p = self._pos
    if type(distance) == 'number' and distance > 0 then
        if max(abs(p.x - playerPos.x), abs(p.y - playerPos.y)) > distance then return false end
    end
    return st:isSightClear(playerPos, p)
end

-- ---------------------------------------------------------------------------
-- render / map-editor surface: callable, inert (blocker B4, 0 decision-affecting sites)
-- ---------------------------------------------------------------------------
function Tile:isHouseTile() return false end
function Tile:getHouseId()  return 0 end
function Tile:getTimer()    return 0 end
function Tile:isClickable() return true end

-- Tile::setText / getText (luafunctions.cpp:1088-1089).  Stateful for the same
-- reason Creature's pair is: `vBot/extras.lua:535-540` walks every tile on the
-- floor, reads `tile:getText()` and clears the ones holding "HOLD".  A missing
-- getText raised there; an inert setText would make the clear a silent lie.
function Tile:setText(t) rawset(self, '_text', t == nil and '' or tostring(t)) end
function Tile:getText()  return rawget(self, '_text') or '' end

local INERT = { 'setFill', 'select', 'unselect', 'overwriteMinimapColor',
                'setTimer', 'setHouseId', 'clearTexts', 'remFlag', 'setFlag' }
for i = 1, #INERT do Tile[INERT[i]] = function() return nil end end

return objects
