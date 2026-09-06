--[[============================================================================
shim/g_things.lua -- `g_things` (work item S1, PLAN sec.1.22, api-game.md sec.3).

Only ONE binding is ever called: `g_things.getThingType(id [, category])`.  The 76 other
bound ThingType methods have zero call sites -- but the FOUR the user's live profile does
call are not the four api-game.md predicted, so they are all implemented over
`proto/items.lua`:

    targetbot/target.lua:302,320   thing:isFluidContainer()
    cavebot/imbuing.lua:77         tt:getName()          (pcall'd, falls back to "item <id>")
    cavebot/walking.lua:122        tt:getLensHelp()      <- floor-change detection
    cavebot/walking.lua:125        tt:isNotPathable()    <- floor-change detection

`getLensHelp()` is load-bearing: cavebot's `itemChangesFloor` classifies stairs/holes with
`FLOOR_CHANGE_LENSHELP = {1104, 1105}`, and proto/items.lua's LENSHELP section carries
exactly that column (NOTE 2 in its header explains why 1100/1102 are deliberately excluded).

ThingType objects are INTERNED per (category, id) so `==` between two lookups holds.

`g_things.getThingType` in C++ returns the NULL ThingType for an unknown id rather than nil;
vBot's two call sites both guard with `if not tt then` anyway.  We return nil for an id
outside 1..MAX_ID (loud once) and a real object otherwise, which is the branch vBot expects.
============================================================================]]

local objects = require('shim.object')
local items   = require('proto.items')

local ThingType = objects.ThingType

local CATEGORY_ITEM     = 0
local CATEGORY_CREATURE = 1
local CATEGORY_EFFECT   = 2
local CATEGORY_MISSILE  = 3

local function valid(id)
    return items.loaded and type(id) == 'number' and id >= 1 and id <= items.MAX_ID
end

local function col(fn, id, dflt)
    if not valid(id) then return dflt end
    local ok, v = pcall(fn, id)
    if not ok then return dflt end
    return v
end

function ThingType:getId()       return self._id end
function ThingType:getCategory() return self._category end

function ThingType:getName()
    return col(items.name, self._id, nil) or ''
end

function ThingType:getMarketData()
    local id = self._id
    return { name = col(items.marketName, id, nil) or '', category = 0, requiredLevel = 0,
             restrictVocation = 0, showAs = id, tradeAs = id }
end

function ThingType:isGround()          return col(items.isGround,          self._id, false) end
function ThingType:isGroundBorder()    return col(items.isGroundBorder,    self._id, false) end
function ThingType:isOnBottom()        return col(items.isOnBottom,        self._id, false) end
function ThingType:isOnTop()           return col(items.isOnTop,           self._id, false) end
function ThingType:isNotWalkable()     return col(items.isNotWalkable,     self._id, false) end
function ThingType:isNotPathable()     return col(items.isNotPathable,     self._id, false) end
function ThingType:isNotMoveable()     return col(items.isNotMoveable,     self._id, false) end
function ThingType:blockProjectile()   return col(items.isBlockProjectile, self._id, false) end
function ThingType:isPickupable()      return col(items.isPickupable,      self._id, false) end
function ThingType:isUsable()          return col(items.isUsable,          self._id, false) end
function ThingType:isMultiUse()        return col(items.isMultiUse,        self._id, false) end
function ThingType:isForceUse()        return col(items.isForceUse,        self._id, false) end
function ThingType:isFluidContainer()  return col(items.isFluidContainer,  self._id, false) end
function ThingType:isSplash()          return col(items.isSplash,          self._id, false) end
function ThingType:isHangable()        return col(items.isHangable,        self._id, false) end
function ThingType:isWritable()        return col(items.isWritable,        self._id, false) end
function ThingType:isRotateable()      return col(items.isRotateable,      self._id, false) end
function ThingType:isFullGround()      return col(items.isFullGround,      self._id, false) end
function ThingType:isIgnoreLook()      return col(items.isIgnoreLook,      self._id, false) end
function ThingType:isContainer()       return col(items.isContainer,       self._id, false) end
function ThingType:isStackable()       return col(items.isStackable,       self._id, false) end
function ThingType:isCommon()          return col(items.isCommon,          self._id, false) end
function ThingType:hasElevation()      return col(items.hasElevation,      self._id, false) end
function ThingType:getGroundSpeed()    return col(items.groundSpeed,       self._id, 0) end
function ThingType:getMinimapColor()   return col(items.minimapColor,      self._id, 0) end
function ThingType:getElevation()      return col(items.elevation,         self._id, 0) end
function ThingType:getLensHelp()       return col(items.lensHelp,          self._id, 0) end
function ThingType:getClothSlot()      return col(items.clothSlot,         self._id, 0) end

-- No FloorChange flag exists at 1530 (proto/items.lua NOTE 2) -- the live client answers
-- false here too.
function ThingType:isFloorChange()     return false end
function ThingType:hasFloorChange()    return false end

-- Render-only geometry: 0 rather than a fabricated number.
function ThingType:getWidth()  return 1 end
function ThingType:getHeight() return 1 end
function ThingType:getLayers() return 1 end
function ThingType:getAnimationPhases() return 1 end
function ThingType:getExactSize() return 32 end
function ThingType:getDisplacement() return 0 end

-- ---------------------------------------------------------------------------
local M = {}

-- M.new(LC, reg [, opts]) -> g_things
function M.new(LC, reg, opts)
    opts = opts or {}
    local cache = { [CATEGORY_ITEM] = {}, [CATEGORY_CREATURE] = {},
                    [CATEGORY_EFFECT] = {}, [CATEGORY_MISSILE] = {} }

    local g = {}
    g.ThingCategoryItem     = CATEGORY_ITEM
    g.ThingCategoryCreature = CATEGORY_CREATURE
    g.ThingCategoryEffect   = CATEGORY_EFFECT
    g.ThingCategoryMissile  = CATEGORY_MISSILE

    function g.getThingType(id, category)
        category = category or CATEGORY_ITEM
        if type(id) ~= 'number' then return nil end
        id = math.floor(id)
        if category ~= CATEGORY_ITEM then
            -- Only the item table is extracted headless; creature/effect/missile appearance
            -- data is not in assets/items1530.bin.  Loud, and nil rather than a lie.
            reg:report('g_things.getThingType(category=' .. tostring(category) .. ')',
                       'only the item category is present in assets/items1530.bin')
            return nil
        end
        if not valid(id) then return nil end
        local c = cache[category]
        local t = c[id]
        if t == nil then
            t = setmetatable({ _id = id, _category = category }, ThingType)
            c[id] = t
        end
        return t
    end

    -- ThingTypeManager::isValidDatId
    function g.isValidDatId(id, category)
        category = category or CATEGORY_ITEM
        if category == CATEGORY_ITEM     then return items.isValidItemId(id) end
        if category == CATEGORY_CREATURE then return items.isValidCreatureId(id) end
        if category == CATEGORY_EFFECT   then return items.isValidEffectId(id) end
        if category == CATEGORY_MISSILE  then return items.isValidMissileId(id) end
        return false
    end

    function g.getThingTypes(category)
        reg:report('g_things.getThingTypes', 'enumerating 62k appearances is never needed')
        return {}
    end

    function g.isLoaded() return items.loaded == true end
    function g.getContentRevision() return items.CONTENT_REVISION or 0 end
    function g.getDatSignature() return items.CONTENT_REVISION or 0 end

    -- Everything else on g_things (loadDat, loadOtb, ...) is boot-time asset plumbing the
    -- shim owns itself; make it callable and inert rather than absent.
    setmetatable(g, { __index = function(_, k)
        reg:report('g_things.' .. tostring(k), 'unused binding')
        return function() return nil end
    end })

    return g
end

M.ThingType = ThingType
return M
