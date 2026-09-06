--[[============================================================================
shim/container.lua -- Container (work item S1, PLAN sec.1.19).

The second-hottest cluster after Tile (api-game.md sec.4.5): 35 `getName`, 27 `getItems`,
17 `getContainerItem`, 14 `getItemsCount`, 13 `getSlotPosition` T1 call sites -- looting and
the depositor live here.

`getSlotPosition(slot)` is `container.h:37` VERBATIM, and the slot is **0-BASED**:

    Position getSlotPosition(const int slot) { return { 0xffff, m_id | 0x40, uint8_t(slot) }; }

`targetbot/looting.lua:290` passes `slot - 1` from an `ipairs` index and `:299` passes
`container:getItemsCount()` (i.e. one past the last used slot) -- both only work with the
0-based reading, and both are asserted in test/shim_game_suite.lua.

`getContainerItem` has TWO arities in the wild (api-game.md sec.4.5):
  * `container:getContainerItem()`  -- C++ Container::getContainerItem(), the BACKPACK ITEM
    the container was opened from (13 T1 sites);
  * `x:getContainerItem(index)`     -- Item::getContainerItem(index) on the parent item.
Both are supported; the receiver disambiguates.
============================================================================]]

local objects = require('shim.object')
local posmod  = require('shim.position')

local Container = objects.Container

local function rec(self)
    return self._reg.state.containers[self._id]
end
Container._rec = rec

function Container:getId()
    return self._id
end

function Container:getName()
    local c = rec(self)
    return (c and c.name) or ''
end

function Container:getCapacity()
    local c = rec(self)
    return (c and c.capacity) or 0
end

function Container:hasParent()
    local c = rec(self)
    return (c and c.hasParent) == true
end

function Container:isUnlocked()
    local c = rec(self)
    return (c and c.isUnlocked) == true
end

-- A container the parser has dropped from state.containers is closed.
function Container:isClosed()
    return rec(self) == nil
end

function Container:hasPages()
    local c = rec(self)
    return (c and c.hasPages) == true
end

function Container:getSize()
    local c = rec(self)
    return (c and c.size) or 0
end

function Container:getFirstIndex()
    local c = rec(self)
    return (c and c.firstIndex) or 0
end

-- ---------------------------------------------------------------------------
-- items
-- ---------------------------------------------------------------------------
local function loc(self, slot0)
    return { kind = 'container', cid = self._id, slot = slot0 }
end

function Container:getItems()
    local c = rec(self)
    local out = {}
    if not (c and c.items) then return out end
    local list = c.items
    for i = 1, #list do
        out[i] = self._reg:item(list[i], loc(self, i - 1))
    end
    return out
end

function Container:getItemsCount()
    local c = rec(self)
    return (c and c.items and #c.items) or 0
end

-- Container::getItem (container.cpp:27) -- 0-BASED slot, nil out of range.
function Container:getItem(slot)
    local c = rec(self)
    if not (c and c.items) then return nil end
    if type(slot) ~= 'number' or slot < 0 or slot >= #c.items then return nil end
    return self._reg:item(c.items[slot + 1], loc(self, slot))
end

-- Container::findItemById (container.cpp:69) -- subType -1 means "any"; tier must match.
function Container:findItemById(itemId, subType, tier)
    local c = rec(self)
    if not (c and c.items) then return nil end
    tier = tier or 0
    if subType == nil then subType = -1 end
    local list = c.items
    for i = 1, #list do
        local it = list[i]
        if it.id == itemId and (it.tier or 0) == tier then
            local w = self._reg:item(it, loc(self, i - 1))
            if subType == -1 or w:getSubType() == subType then return w end
        end
    end
    return nil
end

-- Both arities (see the header).
function Container:getContainerItem(index)
    local c = rec(self)
    if index == nil then
        local it = c and c.item
        if not it then return nil end
        -- the backpack ITEM this container was opened from; its own position belongs to
        -- wherever that item lives, which the parser does not record -- so it stays
        -- detached and `g_game.use/open` falls back to Position(0xFFFF, 0, 0) exactly like
        -- game.cpp:846 does for a virtual item.
        return self._reg:item(it, { kind = 'detached' })
    end
    return self:getItem(index)
end

-- container.h:37 -- the destination of every g_game.move into a container.  0-BASED slot.
function Container:getSlotPosition(slot)
    return posmod.containerSlot(self._id, slot or 0)
end

return objects
