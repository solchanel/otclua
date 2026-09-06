--[[============================================================================
shim/object.lua -- the INTERN REGISTRY and the class tables (work item S1, PLAN sec.1.15).

This is the first thing the game shim builds and the load-bearing one.  Invariant **I1**
(PLAN sec.0, api-game.md sec.0.1) is the whole reason it exists:

    the same creature id / tile position / tile-thing / container id must return the
    SAME LUA TABLE on every call, forever

because vBot compares game objects with `==` / `~=` (`spec ~= player` in AttackBot 6x,
`top ~= ground` in cavebot/walking.lua:148) and uses them as table keys.  A naive adapter
that builds a fresh wrapper per call compiles, runs, and is silently wrong.

WRAPPERS ARE THIN.  They hold a key (a creature id, a tile key, a container id, or the
underlying `tile.things[i]` Lua table) and read `LC.state` LIVE on every call.  Nothing is
ever snapshotted, so a wrapper handed to vBot ten ticks ago still answers correctly.

CLASS HIERARCHY.  otclient's own `modules/gamelib/*.lua` is loaded VERBATIM on top of the
shim (PLAN sec.1.13) and does `function Creature.isDruid(self)` / `function Player:isPartyMember()`
-- i.e. it appends methods to the CLASS TABLES.  So the tables this module exports must be
the very tables `shim/otlua.lua` publishes as `G.Creature`, `G.Player`, ... and the
instance metatable must chain through them:

    Thing <- Creature <- Player <- LocalPlayer
    Thing <- Item
    Tile        (LuaObject in C++, not a Thing)
    Container   (LuaObject in C++, not a Thing)

Each class table IS the instance metatable (`C.__index = C`) and carries a metatable of its
own pointing at its parent, so a method added to `Creature` later is visible on a
`LocalPlayer` instance created earlier.

THE FLOOR INDEX.  `g_map.getTiles(z)` has 16 T1 call sites and is called several times per
tick; api-game.md sec.2 is explicit that it must be INDEXED, never a rescan of `state.map`.
The registry therefore keeps `reg.floors[z] = { [key] = pos }` incrementally, maintained by
INSTANCE-LEVEL hooks on `state:setTile` / `cleanTile` / `getOrCreateTile` / `reset`.  The
hooks are installed on the state INSTANCE (shadowing the shared metatable), so
`game/state.lua` is never modified and other state objects are untouched; `reg:detach()`
removes them again.
============================================================================]]

local posmod = require('shim.position')

local objects = {}

-- ---------------------------------------------------------------------------
-- class tables
-- ---------------------------------------------------------------------------
local function newClass(name, parent)
    local C = {}
    C.__classname = name
    C.__index = C
    C.__tostring = function(o)
        local ok, s = pcall(function() return name .. '<' .. tostring(o._key or o._id or '?') .. '>' end)
        return ok and s or name
    end
    if parent then setmetatable(C, { __index = parent }) end
    -- UIWidget-style introspection; `getClassName` is called on game objects too
    -- (functions/map.lua:242 does it on a widget, targetbot on things).
    C.getClassName = function() return name end
    return C
end

local Thing       = newClass('Thing')
local Creature    = newClass('Creature',   Thing)
local Player      = newClass('Player',     Creature)
local LocalPlayer = newClass('LocalPlayer', Player)
local Monster     = newClass('Monster',    Creature)
local Npc         = newClass('Npc',        Creature)
local Item        = newClass('Item',       Thing)
local Tile        = newClass('Tile')
local Container   = newClass('Container')
local ThingType   = newClass('ThingType')

objects.Thing, objects.Creature, objects.Player      = Thing, Creature, Player
objects.LocalPlayer, objects.Monster, objects.Npc    = LocalPlayer, Monster, Npc
objects.Item, objects.Tile, objects.Container        = Item, Tile, Container
objects.ThingType                                    = ThingType

objects.classes = {
    Thing = Thing, Creature = Creature, Player = Player, LocalPlayer = LocalPlayer,
    Monster = Monster, Npc = Npc, Item = Item, Tile = Tile, Container = Container,
    ThingType = ThingType,
}

-- Thing base: the four virtuals every subclass overrides, with the C++ defaults
-- (thing.h:60-84).  Defined here so a caller that gets a bare Thing never errors.
function Thing:isItem()     return false end
function Thing:isCreature() return false end
function Thing:isTile()     return false end
function Thing:isEffect()   return false end
function Thing:isMissile()  return false end
function Thing:isLocalPlayer() return false end
function Thing:isPlayer()   return false end
function Thing:isMonster()  return false end
function Thing:isNpc()      return false end
function Thing:isAnimatedText() return false end
function Thing:isStaticText()   return false end
function Thing:getId()      return 0 end
function Thing:getPosition() return posmod.invalid() end
function Thing:getStackPos() return -1 end

-- ---------------------------------------------------------------------------
-- the registry
-- ---------------------------------------------------------------------------
local Reg = {}
Reg.__index = Reg
objects.Reg = Reg

-- objects.new(LC [, opts])
--   LC.state      game/state.lua instance (required)
--   LC.log        lib/log.lua              (optional)
--   opts.strict   true -> an unimplemented API raises instead of returning an inert value
function objects.new(LC, opts)
    opts = opts or {}
    if type(LC) ~= 'table' or type(LC.state) ~= 'table' then
        error('objects.new: LC.state is required', 2)
    end
    local reg = setmetatable({}, Reg)
    reg.LC     = LC
    reg.state  = LC.state
    reg.log    = LC.log
    reg.strict = opts.strict == true
    reg.classes = objects.classes

    reg.creatures  = {}                                   -- [id]  = Creature wrapper
    reg.tiles      = {}                                   -- [key] = Tile wrapper
    reg.containers = {}                                   -- [id]  = Container wrapper
    -- Item wrappers are interned on the UNDERLYING thing table, which game/state.lua keeps
    -- identity-stable across stack moves.  Weak keys so a tile the server forgot does not
    -- pin its items forever.
    reg.items      = setmetatable({}, { __mode = 'k' })
    reg._player    = nil
    reg._playerId  = nil

    reg.floors     = {}     -- [z] = { [key] = pos }
    reg.floorList  = {}     -- [z] = sorted array of Tile wrappers (cache)
    reg.floorGen   = {}     -- [z] = generation the cache was built at
    reg.floorDirty = {}     -- [z] = generation counter
    reg.indexed    = 0      -- how many keys the index holds (cross-check vs state.tileCount)
    reg._reported  = {}

    reg:_seedFloors()
    reg:_hookState()
    -- `Item.create(id[, count])` is a CLASS-level factory (8 T1 call sites) and therefore
    -- needs a registry to mint detached items from.  Bound here so a caller can never
    -- publish `Item` into the sandbox without it; idempotent, and the last registry wins
    -- (only one bot engine runs at a time -- PLAN invariant I10).
    if objects.installItemFactory then objects.installItemFactory(reg) end
    return reg
end

-- Loud, once per symbol.  "A function that silently returns a wrong value is worse than one
-- that is absent and errors loudly" -- so every deliberately-unimplemented corner routes here.
function Reg:report(symbol, why)
    if self._reported[symbol] then return end
    self._reported[symbol] = true
    local msg = ('shim: %s is not implemented headless (%s)'):format(symbol, why or 'no data source')
    if self.strict then error(msg, 3) end
    if self.log and self.log.warn then self.log.warn('%s', msg) end
end

-- ---------------------------------------------------------------------------
-- floor index
-- ---------------------------------------------------------------------------
local tileKeyOf   -- forward (state.tileKey)

function Reg:_seedFloors()
    local st = self.state
    tileKeyOf = st.tileKey or (getmetatable(st) and getmetatable(st).tileKey)
    self.floors, self.floorList, self.floorGen, self.floorDirty, self.indexed = {}, {}, {}, {}, 0
    for key, tile in pairs(st.map) do
        local p = tile.pos or st.parseKey(key)
        if p then self:_noteAdded(key, p) end
    end
end

function Reg:_noteAdded(key, pos)
    local z = pos.z
    local f = self.floors[z]
    if not f then f = {}; self.floors[z] = f end
    if f[key] == nil then
        f[key] = { x = pos.x, y = pos.y, z = z }
        self.indexed = self.indexed + 1
        self.floorDirty[z] = (self.floorDirty[z] or 0) + 1
    end
end

function Reg:_noteRemoved(key, pos)
    local z = pos and pos.z
    if z == nil then
        local p = self.state.parseKey(key)
        z = p and p.z
    end
    if z == nil then return end
    local f = self.floors[z]
    if f and f[key] ~= nil then
        f[key] = nil
        self.indexed = self.indexed - 1
        self.floorDirty[z] = (self.floorDirty[z] or 0) + 1
    end
    -- Drop the wrapper too.  `Map::cleanTile` destroys the C++ Tile object, so a tile that
    -- is forgotten and later re-described IS a different object there; matching that also
    -- bounds memory over a long session (setCentralPosition evicts on every step).
    self.tiles[key] = nil
end

-- Install the instance-level hooks.  Several registries may share one state, so the wrapper
-- fans out over a list parked on the state instance.
function Reg:_hookState()
    local st = self.state
    local hooks = rawget(st, '__shimRegs')
    if hooks then
        hooks[#hooks + 1] = self
        self._hooked = true
        return
    end
    hooks = { self }
    rawset(st, '__shimRegs', hooks)

    local baseSet, baseClean = st.setTile, st.cleanTile
    local baseCreate, baseReset = st.getOrCreateTile, st.reset

    st.setTile = function(s, pos, tile)
        local key = s.tileKey(pos)
        local had = s.map[key] ~= nil
        local out = baseSet(s, pos, tile)
        for i = 1, #hooks do
            if tile ~= nil and not had then hooks[i]:_noteAdded(key, pos)
            elseif tile == nil and had then hooks[i]:_noteRemoved(key, pos) end
        end
        return out
    end

    st.cleanTile = function(s, pos)
        local key = s.tileKey(pos)
        local out = baseClean(s, pos)
        if out then for i = 1, #hooks do hooks[i]:_noteRemoved(key, pos) end end
        return out
    end

    st.getOrCreateTile = function(s, pos)
        local key = s.tileKey(pos)
        local had = s.map[key] ~= nil
        local out = baseCreate(s, pos)
        if not had then for i = 1, #hooks do hooks[i]:_noteAdded(key, pos) end end
        return out
    end

    st.reset = function(s, ...)
        local out = baseReset(s, ...)
        for i = 1, #hooks do hooks[i]:_onReset() end
        return out
    end

    rawset(st, '__shimBase', { setTile = baseSet, cleanTile = baseClean,
                               getOrCreateTile = baseCreate, reset = baseReset })
    self._hooked = true
end

function Reg:_onReset()
    self.creatures, self.tiles, self.containers = {}, {}, {}
    self.items = setmetatable({}, { __mode = 'k' })
    self._player, self._playerId = nil, nil
    self:_seedFloors()
end

-- Remove the hooks and forget everything.  `boot` must be able to run again after `stop`.
function Reg:detach()
    local st = self.state
    local hooks = rawget(st, '__shimRegs')
    if hooks then
        for i = #hooks, 1, -1 do if hooks[i] == self then table.remove(hooks, i) end end
        if #hooks == 0 then
            -- Clearing the INSTANCE fields uncovers the shared `state` metatable methods
            -- again, which is exactly the pre-hook state.
            st.setTile, st.cleanTile, st.getOrCreateTile, st.reset = nil, nil, nil, nil
            rawset(st, '__shimRegs', nil)
            rawset(st, '__shimBase', nil)
        end
    end
    self._hooked = false
end

-- Cheap consistency net: something that writes `state.map` directly (a hand-built test
-- world) bypasses the hooks.  `state.tileCount` is maintained by every documented mutator,
-- so a mismatch means the index is stale and we rebuild rather than answer wrongly.
function Reg:_syncFloors()
    if self.indexed ~= self.state.tileCount then self:_seedFloors() end
end

-- ---------------------------------------------------------------------------
-- interning
-- ---------------------------------------------------------------------------

-- The LocalPlayer singleton.  It is ALSO what reg:creature(playerId) returns, because
-- `spec ~= player` (AttackBot) compares a spectator against `context.player` by identity.
function Reg:localPlayer()
    local st = self.state
    local id = st.player and st.player.id
    if self._player and self._playerId == id then return self._player end
    local w = setmetatable({ _reg = self, _id = id, _local = true }, LocalPlayer)
    self._player, self._playerId = w, id
    if id and id ~= 0 then self.creatures[id] = w end
    return w
end

-- Choose the most specific class so gamelib's `function Player:isPartyMember()` lands on
-- remote players and `function Creature.isDruid()` on everything.
local function creatureClassFor(rec)
    if rec == nil then return Creature end
    if rec.isPlayer  then return Player end
    if rec.isNpc     then return Npc end
    if rec.isMonster then return Monster end
    return Creature
end

function Reg:creature(id)
    if type(id) ~= 'number' or id == 0 then return nil end
    local st = self.state
    if st.player and st.player.id == id and id ~= 0 then return self:localPlayer() end
    local rec = st.creatures[id]
    if rec == nil then
        -- Do not mint a wrapper for a creature we have never heard of; vBot branches on nil.
        self.creatures[id] = nil
        return nil
    end
    local w = self.creatures[id]
    if w == nil then
        w = setmetatable({ _reg = self, _id = id }, creatureClassFor(rec))
        self.creatures[id] = w
    end
    return w
end

-- Wrap a raw `state.creatures[...]` record (what bot/world.lua hands back).
function Reg:creatureRec(rec)
    if type(rec) ~= 'table' then return nil end
    return self:creature(rec.id)
end

function Reg:creatureRecord(id)
    local st = self.state
    if st.player and st.player.id == id then return st.creatures[id] end
    return st.creatures[id]
end

-- `g_map.getTile(pos)` -> Tile or NIL.  nil is meaningful: vBot branches on an undescribed
-- tile (cavebot/walking.lua:135-140), so a wrapper must never be minted for one.
-- Identity is per POSITION and survives the tile being forgotten and re-described, which is
-- strictly stronger than the C++ (which mints a new Tile object) and is what
-- `g_map.getTile(p) == g_map.getTile(p)` needs.
function Reg:tile(pos)
    if not posmod.is(pos) then return nil end
    local st = self.state
    local key = st.tileKey(pos)
    if st.map[key] == nil then return nil end
    local w = self.tiles[key]
    if w == nil then
        w = setmetatable({ _reg = self, _key = key,
                           _pos = { x = pos.x, y = pos.y, z = pos.z } }, Tile)
        self.tiles[key] = w
    end
    return w
end

-- Same, but from a key we already hold (the floor index).
function Reg:tileByKey(key)
    local st = self.state
    if st.map[key] == nil then return nil end
    local w = self.tiles[key]
    if w == nil then
        local p = st.parseKey(key)
        if not p then return nil end
        w = setmetatable({ _reg = self, _key = key, _pos = p }, Tile)
        self.tiles[key] = w
    end
    return w
end

-- `container.itemsPanel` is NOT a C++ Container field: modules/game_containers/
-- containers.lua:1073 hangs it on the Lua object when it opens the container window,
-- and everything that walks a container's widgets reads
-- `container.itemsPanel:getChildById('item' .. slot)`.  vBot does exactly that at
-- vBot/analyzer.lua:1111 (the loot-rarity frames), so a headless client with no
-- container window makes that file die on the first open container.
--
-- The panel built here is the same shape, filled from the container's REAL items,
-- so `child:getItemId()` answers the truth rather than a placeholder.  It is
-- rebuilt only when the item list actually changes, and only when a UI factory has
-- been installed (`reg.mkItemsPanel`, wired by shim/bootstrap.lua step 9); without
-- one the field stays nil and analyzer.lua fails loudly, as it should.
function Reg:_refreshItemsPanel(w)
    local mk = self.mkItemsPanel
    if not mk then return end
    local rec = self.state.containers[w._id]
    if not rec then return end
    local list = rec.items or {}
    -- A cheap signature: rebuilding 8 widgets on every getContainers() call would be
    -- a per-tick cost for nothing, and vBot calls getContainers() a lot.
    local sig = tostring(#list)
    for i = 1, #list do
        local it = list[i]
        sig = sig .. '/' .. tostring(it and it.id) .. ':' .. tostring(it and it.count)
    end
    if w._itemsPanelSig == sig and w.itemsPanel then return end
    local panel = mk(w)
    if not panel then return end
    if panel.destroyChildren then panel:destroyChildren() end
    for i = 1, #list do
        local it = list[i]
        local child = mk(w, 'UIItem')
        if child then
            if child.setId then child:setId('item' .. tostring(i - 1)) end
            if child.setItemId then child:setItemId(it and it.id or 0) end
            if child.setItemCount then child:setItemCount(it and it.count or 1) end
            if panel.addChild then panel:addChild(child) end
        end
    end
    w.itemsPanel = panel
    w._itemsPanelSig = sig
end

function Reg:container(id)
    if type(id) ~= 'number' then return nil end
    if self.state.containers[id] == nil then return nil end
    local w = self.containers[id]
    if w == nil then
        w = setmetatable({ _reg = self, _id = id }, Container)
        self.containers[id] = w
    end
    if self.mkItemsPanel then self:_refreshItemsPanel(w) end
    return w
end

-- ---------------------------------------------------------------------------
-- items
-- ---------------------------------------------------------------------------
-- `loc` describes WHERE the thing currently lives; it is refreshed on every query, exactly
-- like the C++ stamps `Thing::m_position` on add.  Shapes:
--     { kind = 'tile',      pos = {x,y,z} }
--     { kind = 'container', cid = <container id> }
--     { kind = 'inventory', slot = <InventorySlot 1..11> }
--     { kind = 'detached' }
function Reg:item(thing, loc)
    if type(thing) ~= 'table' then return nil end
    local w = self.items[thing]
    if w == nil then
        w = setmetatable({ _reg = self, _thing = thing, _loc = loc or { kind = 'detached' } }, Item)
        self.items[thing] = w
    elseif loc ~= nil then
        w._loc = loc
    end
    return w
end

-- A thing straight off a tile: creature things become Creature wrappers, item things Items.
function Reg:thing(t, loc)
    if type(t) ~= 'table' then return nil end
    if t.kind == 'creature' then return self:creature(t.creatureId) end
    return self:item(t, loc)
end

-- Item.create(id [, count]) -- a DETACHED item with no position (api-game.md sec.4.4).
function Reg:detachedItem(id, count)
    local thing = { kind = 'item', id = id, count = count or 1, _detached = true }
    return self:item(thing, { kind = 'detached' })
end

-- ---------------------------------------------------------------------------
-- housekeeping
-- ---------------------------------------------------------------------------
function Reg:forget(kind, key)
    if kind == 'creature' then self.creatures[key] = nil
    elseif kind == 'tile' then self.tiles[key] = nil
    elseif kind == 'container' then self.containers[key] = nil end
end

-- Drop wrappers whose backing record is gone.  Cheap and idempotent; the executor may call
-- it once a second.  Item wrappers are weak-keyed and need no sweep.
function Reg:sweep()
    local st = self.state
    for id in pairs(self.creatures) do
        if st.creatures[id] == nil and not (st.player and st.player.id == id) then
            self.creatures[id] = nil
        end
    end
    for key in pairs(self.tiles) do
        if st.map[key] == nil then self.tiles[key] = nil end
    end
    for id in pairs(self.containers) do
        if st.containers[id] == nil then self.containers[id] = nil end
    end
end

function Reg:stats()
    local nc, nt, ncn = 0, 0, 0
    for _ in pairs(self.creatures)  do nc  = nc  + 1 end
    for _ in pairs(self.tiles)      do nt  = nt  + 1 end
    for _ in pairs(self.containers) do ncn = ncn + 1 end
    return { creatures = nc, tiles = nt, containers = ncn, indexedTiles = self.indexed }
end

-- The children register their methods on the class tables above.  package.loaded is primed
-- first so `require('shim.object')` inside them resolves to this very table.
package.loaded['shim.object'] = objects
require('shim.creature')
require('shim.item')
require('shim.tile')
require('shim.container')

return objects
