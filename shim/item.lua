--[[============================================================================
shim/item.lua -- Item (work item S1, PLAN sec.1.18).

api-game.md sec.4.4 calls `Item:getPosition()` "the single most error-prone method in the
shim", and invariant I3 is why: an item's position is a WIRE ADDRESS with three distinct
encodings, and `g_game.move` / `use` / `useWith` / `stashStowItem` are built directly on it.

    tile item        the tile position,               getStackPos() = the tile stack index
    container item   {0xFFFF, containerId|0x40, slot} getStackPos() = slot   (0-BASED)
    equipped item    {0xFFFF, inventorySlot, 0}       getStackPos() = 0
    Item.create(id)  {0xFFFF, 0xFFFF, 255} (invalid)  getStackPos() = 255

    thing.cpp:94-104   `if (m_position.x == UINT16_MAX && isItem()) return m_position.z;`
    container.h:37     `Position{ 0xffff, m_id | 0x40, slot }`
    game.cpp:325       `item->setPosition(Position(UINT16_MAX, slot, 0));`
    tile.cpp:369       `thing->setPosition(m_position, stackPos);`

The wrapper reads its slot / stack index LIVE (by identity search in the backing array), so
an item that the parser has shuffled inside its container still addresses the right slot.

`getMarketData()` must NEVER return nil -- `vBot/analyzer.lua:401,438,494,1118,1191` and
`vBot/depositer_config.lua:42,70` index `.name` unconditionally (api-game.md sec.4.4).
============================================================================]]

local objects = require('shim.object')
local posmod  = require('shim.position')
local items   = require('proto.items')

local Item = objects.Item

-- proto/items.lua raises for id 0 / out of range (items.checkId).  Every predicate here is
-- reachable with a garbage id from vBot config, so each read is guarded once, centrally.
local function valid(id)
    return items.loaded and type(id) == 'number' and id >= 1 and id <= items.MAX_ID
end

local function flagOf(fn, id, dflt)
    if not valid(id) then return dflt end
    local ok, v = pcall(fn, id)
    if not ok then return dflt end
    return v
end

local function thingOf(self) return self._thing end

-- ---------------------------------------------------------------------------
-- identity
-- ---------------------------------------------------------------------------
function Item:isItem()     return true end
function Item:isCreature() return false end

function Item:getId()
    local t = thingOf(self)
    return (t and t.id) or 0
end

-- B3 -- RESOLVED, and the old answer was wrong.  There is no client->server id map to
-- derive offline: the map lives ONLY in items.otb, which ThingTypeManager::loadOtb builds
-- into m_reverseItemTypes (thingtypemanager.cpp:653,566) and which the 1530 data set does
-- not ship at all (data/things/1530 holds appearances/sprites, no .otb; nothing in src/ or
-- modules/ ever calls g_things.loadOtb).
--
-- More to the point, the REFERENCE CLIENT does not answer the client id either.
-- `Item::m_serverId` is assigned in exactly one place, item.cpp:273, and that line sits
-- inside `#ifdef FRAMEWORK_EDITOR`; src/CMakeLists.txt:12 defaults TOGGLE_FRAMEWORK_EDITOR
-- to OFF, so in the shipped client the field keeps its initialiser (item.h:193 `{ 0 }`)
-- forever while the Lua binding (luafunctions.cpp:853) is compiled in unconditionally.
-- A real `item:getServerId()` at 1530 therefore returns 0 for every item.
--
-- So 0 is both the honest headless answer and the C++-exact one.  It still reports, once,
-- because a script that branches on a server id is broken either way and should be told.
function Item:getServerId()
    self._reg:report('Item:getServerId',
                     'there is no client->server id map offline (items.otb is not shipped '
                     .. 'at 1530), and the reference client answers 0 too -- Item::m_serverId '
                     .. 'is only ever written under #ifdef FRAMEWORK_EDITOR (item.cpp:273), '
                     .. 'which is OFF by default')
    return 0
end

function Item:getName()
    local id = self:getId()
    return flagOf(items.name, id, nil) or ''
end

function Item:getTier()
    local t = thingOf(self)
    return (t and t.tier) or 0
end

-- Item::getCountOrSubType (item.h:94) -- the RAW wire byte.
function Item:getCountOrSubType()
    local t = thingOf(self)
    return (t and t.count) or 1
end
Item.getItemCountOrSubType = Item.getCountOrSubType   -- UIItem spelling, seen once in T1

-- Item::getCount (item.h:96): the byte only when the item is stackable, else 1.
function Item:getCount()
    if self:isStackable() then
        local t = thingOf(self)
        return (t and t.count) or 1
    end
    return 1
end

-- Item::getSubType (item.cpp:102-108): the byte for splashes and fluid containers,
-- otherwise 0 at cv > 862 (1530 qualifies).
function Item:getSubType()
    if self:isSplash() or self:isFluidContainer() then
        local t = thingOf(self)
        return (t and t.count) or 0
    end
    return 0
end

function Item:getCharges()  local t = thingOf(self); return (t and t.charges) or 0 end
function Item:getDurationTime() local t = thingOf(self); return (t and t.duration) or 0 end

-- ---------------------------------------------------------------------------
-- position / stackpos  (invariant I3)
-- ---------------------------------------------------------------------------
-- 0-based slot of this exact thing inside its container's live item array, or nil.
local function containerSlot(self)
    local loc = self._loc
    local c = self._reg.state.containers[loc.cid]
    local list = c and c.items
    if list then
        local t = thingOf(self)
        for i = 1, #list do
            if list[i] == t then return i - 1 end
        end
    end
    return loc.slot           -- the slot it was at when the wrapper was last handed out
end

-- 0-based tile stack index of this exact thing, or nil (Tile::getThingStackPos, tile.cpp:506).
local function tileStackPos(self)
    local loc = self._loc
    local tile = self._reg.state.map[self._reg.state.tileKey(loc.pos)]
    if not tile then return nil end
    local things, t = tile.things, thingOf(self)
    for i = 1, #things do
        if things[i] == t then return i - 1 end
    end
    return nil
end

function Item:getPosition()
    local loc = self._loc
    local k = loc and loc.kind
    if k == 'tile' then
        local p = loc.pos
        return { x = p.x, y = p.y, z = p.z }
    elseif k == 'container' then
        local slot = containerSlot(self)
        if slot == nil then return posmod.invalid() end
        return posmod.containerSlot(loc.cid, slot)
    elseif k == 'inventory' then
        return posmod.inventorySlot(loc.slot)
    end
    return posmod.invalid()                 -- Item.create / detached: Position() is INVALID
end

-- Thing::getStackPos (thing.cpp:94-104).
function Item:getStackPos()
    local loc = self._loc
    local k = loc and loc.kind
    if k == 'tile' then
        local sp = tileStackPos(self)
        if sp == nil then return -1 end     -- "got a thing with invalid stackpos"
        return sp
    elseif k == 'container' then
        local slot = containerSlot(self)
        if slot == nil then return posmod.INVALID_Z end
        return slot                          -- == position.z
    elseif k == 'inventory' then
        return 0                             -- == position.z
    end
    return posmod.INVALID_Z                  -- invalid position's z
end

-- The container this item was opened from, when it IS one (Item::getContainerItem's mirror
-- image: `Container:getContainerItem()` is the backpack item, this is the other direction).
function Item:getContainerItem(index)
    if index ~= nil then
        -- Item::getContainerItem(index) -- the item at `index` of the container this item
        -- represents.  Only reachable for an item that is an open container.
        local st = self._reg.state
        for id, c in pairs(st.containers) do
            if c.item == thingOf(self) then
                local it = c.items and c.items[index + 1]
                if it then return self._reg:item(it, { kind = 'container', cid = id, slot = index }) end
                return nil
            end
        end
        return nil
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- ThingType-derived flags (proto/items.lua)
-- ---------------------------------------------------------------------------
function Item:isContainer()      return flagOf(items.isContainer,      self:getId(), false) end
function Item:isStackable()      return flagOf(items.isStackable,      self:getId(), false) end
function Item:isNotMoveable()    return flagOf(items.isNotMoveable,    self:getId(), false) end
function Item:isPickupable()     return flagOf(items.isPickupable,     self:getId(), false) end
function Item:isFluidContainer() return flagOf(items.isFluidContainer, self:getId(), false) end
function Item:isSplash()         return flagOf(items.isSplash,         self:getId(), false) end
function Item:isUsable()         return flagOf(items.isUsable,         self:getId(), false) end
function Item:isMultiUse()       return flagOf(items.isMultiUse,       self:getId(), false) end
function Item:isForceUse()       return flagOf(items.isForceUse,       self:getId(), false) end
function Item:isGround()         return flagOf(items.isGround,         self:getId(), false) end
function Item:isGroundBorder()   return flagOf(items.isGroundBorder,   self:getId(), false) end
function Item:isOnBottom()       return flagOf(items.isOnBottom,       self:getId(), false) end
function Item:isOnTop()          return flagOf(items.isOnTop,          self:getId(), false) end
function Item:isNotWalkable()    return flagOf(items.isNotWalkable,    self:getId(), false) end
function Item:isNotPathable()    return flagOf(items.isNotPathable,    self:getId(), false) end
function Item:isBlockProjectile() return flagOf(items.isBlockProjectile, self:getId(), false) end
function Item:isHangable()       return flagOf(items.isHangable,       self:getId(), false) end
function Item:isRotateable()     return flagOf(items.isRotateable,     self:getId(), false) end
function Item:isWritable()       return flagOf(items.isWritable,       self:getId(), false) end
function Item:isFullGround()     return flagOf(items.isFullGround,     self:getId(), false) end
function Item:isIgnoreLook()     return flagOf(items.isIgnoreLook,     self:getId(), false) end
function Item:isCorpse()         return flagOf(items.isCorpse,         self:getId(), false) end
function Item:isPlayerCorpse()   return flagOf(items.isPlayerCorpse,   self:getId(), false) end
function Item:isCommon()         return flagOf(items.isCommon,         self:getId(), false) end
function Item:hasElevation()     return flagOf(items.hasElevation,     self:getId(), false) end
function Item:hasMarket()        return flagOf(items.hasMarket,        self:getId(), false) end
function Item:getGroundSpeed()   return flagOf(items.groundSpeed,      self:getId(), 0) end
function Item:getMinimapColor()  return flagOf(items.minimapColor,     self:getId(), 0) end
function Item:getElevation()     return flagOf(items.elevation,        self:getId(), 0) end
function Item:getLensHelp()      return flagOf(items.lensHelp,         self:getId(), 0) end
function Item:getClothSlot()     return flagOf(items.clothSlot,        self:getId(), 0) end

-- NOTE 2 of proto/items.lua: there is NO floor-change bit at 1530 -- ThingFlagAttrFloorChange
-- is only ever set from the legacy .dat path, so Thing::hasFloorChange() is permanently
-- false on this client.  Reproduce that exactly rather than guessing.
function Item:hasFloorChange()   return false end

-- ---------------------------------------------------------------------------
-- market data -- NEVER nil
-- ---------------------------------------------------------------------------
-- thingtype.cpp:340-357 copies m_name into m_market.name only inside `if has_market()`, so
-- a named item with no market block hands the bot an EMPTY string in the real client.
-- proto/items.marketName() reproduces exactly that, and items.name() is the raw name.
--
-- DECIDED (was a doc/implementation contradiction): `.name` FALLS BACK to items.name(id).
-- api-game.md sec.4.4 is the authority on the return shape and specifies
-- `items.marketName(id) or items.name(id) or ('item '..id)`.  This is a KNOWN and
-- deliberate deviation from thingtype.cpp:340-357, where m_name is copied into
-- m_market.name only inside `if has_market()` so the live client hands back '' for an
-- item with no market block.  The deviation is one-directional and safe: `.name` is only
-- ever read to be lowercased and string-matched (vBot/depositer_config.lua:42,70,
-- vBot/analyzer.lua:401,438,494,1118,1191), so a real name can only ADD a classification
-- the live client would have dropped, never mis-classify one.  The C++-exact value stays
-- available as `.marketName` for anything that needs to tell the two apart.
function Item:getMarketData()
    local id = self:getId()
    local marketName = flagOf(items.marketName, id, nil)
    return {
        name             = marketName or flagOf(items.name, id, nil) or ('item ' .. id),
        marketName       = marketName or '',
        category         = 0,
        requiredLevel    = 0,
        restrictVocation = 0,
        showAs           = id,
        tradeAs          = id,
    }
end

-- ---------------------------------------------------------------------------
-- inert setters (0 live call sites; must be callable)
-- ---------------------------------------------------------------------------
-- Item::getText / setText (luafunctions.cpp:865,867) -- the writable-item text,
-- Item::m_text.  Nothing on the wire fills it headless (0x96 EditText carries its
-- own string), so it starts empty and round-trips whatever a script wrote.
function Item:setText(t) rawset(self, '_itemText', t == nil and '' or tostring(t)) end
function Item:getText()  return rawget(self, '_itemText') or '' end

local INERT = { 'setCount', 'setTooltip', 'setTier', 'setDescription', 'setShader',
                'setColor', 'setId', 'setPosition', 'setSubType', 'setDurationTime' }
for i = 1, #INERT do Item[INERT[i]] = function() return nil end end

function Item:clone()
    local t = thingOf(self)
    return self._reg:detachedItem(t and t.id or 0, t and t.count or 1)
end

-- ---------------------------------------------------------------------------
-- Item.create(id [, count]) -- the class-level factory (8 T1 sites).  Bound at boot by
-- shim/g_game.lua so `Item` in the sandbox is this class table with `create` on it.
-- ---------------------------------------------------------------------------
function objects.installItemFactory(reg)
    Item.create = function(id, count)
        if type(id) ~= 'number' then return nil end
        return reg:detachedItem(id, count or 1)
    end
    -- `Item.bottom` is read as a plain field 4x in T1 and never assigned; keep it falsy.
    Item.bottom = false
    return Item
end

return objects
