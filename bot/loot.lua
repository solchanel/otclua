--[[============================================================================
bot/loot.lua -- corpse discovery + the looting state machine (work item M3).

Port of `P/targetbot/looting.lua` (vBot 4.8), spec docs/vbot/targetbot.md section 4.
The "## VERIFIER (Corrections)" section of that file overrides its body and is followed
here; the two MISSING SECTIONS the verifier supplies (`lootContainer` / `lootItem`) are
implemented from the real source, which I re-read line by line.

    local L = loot.new(ctx)
    L:update(data.looting)                 -- Looting.update: WIPES the corpse queue
    local busy = L:process(targets, danger) -- one 100 ms tick; true == "the looter is in charge"
    L:getStatus()                          -- "" | "Looting" | "High danger" | "No cap" | "No space"
    L:onCreatureDisappear(creature)        -- queue the corpse (20 ms deferred tile check)
    L:onContainerOpen(container)           -- flag the corpse window as a loot container
    L:onContainerClose(container)          -- forget its lootTries / openedFrom bookkeeping
    L:onTextMessage({text=})               -- "you are not the owner" -> drop the entry

`ctx` (all supplied by bot/targetbot.lua; every field is required unless marked):
    client   {state, sender, events, items, log}
    world    bot/world.lua instance      path   bot/path.lua instance
    storage  the bot storage table (extras.* / foodItems live there)
    now      function() -> ms            schedule  function(ms, fn)   (bot:schedule)
    walkTo   function(dest, maxDist, params)        -- TargetBot.walkTo, records a destination
    isOn     function() -> bool                     -- TargetBot.isOn (the Config switch)
    isInPz   function() -> bool
    calculateParams  function(creature, path) -> {config=,danger=,priority=}
    clientVersion    number (optional, default 1530)

------------------------------------------------------------------------------
THE STATE MACHINE (looting.lua:107-183), in order, verbatim
------------------------------------------------------------------------------
 1  nothing to take (no items and not everyItem) or no loot bag configured -> "" , false
 2  dangerLevel > maxDanger                                    -> "High danger", false
 3  FREE capacity < minCapacity  -> "No cap", the QUEUE IS WIPED, false
 4  pick the entry: `lootLast and list[#list] or list[1]`; none -> "", false
 5  waitTill > now                                             -> true  (hold everything)
 6  lootContainers = getLootContainers()
 7  none                                                       -> "No space", false
 8  status = "Looting"
 9  any open container flagged lootContainer -> lootContainer(); true   (BEFORE approaching)
10  tries > 30, wrong floor, or Chebyshev distance > extras.looting(40) -> drop it, true
11  distance > 2 or the tile is not loaded -> tries+1, walkTo(pos, 20, precision 2), true
12  the tile's top-use thing is not a container -> drop it, true
13  open it, waitTill = now + extras.lootDelay(200), waitingForContainerItemId = its id, true

Emptying a corpse (`lootContainer`, :237-274) -- first matching branch per item wins, and
only ONE item moves per call:
  (i)   a container item that is NOT on the loot list -> remembered as `nextContainer`
        (the LAST such slot; no break -- a container that IS listed falls through to (ii))
  (ii)  a wanted item (or, with everyItem, any non-container item that is not on the
        IGNORE list) -> lootTries+1 and, only while < 5, move it and return
  (iii) else food: storage.foodItems, at most one bite per 5 s -> use() and return
  after the loop: nextContainer -> lootTries+1 and, while < 2, open it IN PLACE of the
  corpse window (previousContainer = the corpse), waitTill = now+300
  otherwise: unflag, close the corpse, drop the queue entry.

Moving one item (`lootItem`, :284-301): a stackable first looks for a partial stack
(count < 100) of the same id in any loot bag and moves the WHOLE stack onto it; otherwise
exactly ONE unit is appended at the end of lootContainers[1].  Both set waitTill = now+300.
That `1` is verbatim vBot: a fresh stack costs two moves (~600 ms), the second of which
merges the rest.

------------------------------------------------------------------------------
DELIBERATE DEVIATIONS (each one is a VERIFIER-flagged upstream defect)
------------------------------------------------------------------------------
1. CONTAINER ORDER IS SORTED BY ID.  vBot iterates `pairs(g_game.getContainers())` in
   three places (the lootContainer scan, getLootContainers, the spare-bag scan); the
   VERIFIER says the resulting order is an accident and asks for an explicit choice.
   `openContainersSorted()` sorts ascending by container id, so `lootContainers[1]` --
   the default destination for every non-stackable -- is reproducible.
2. `lootTries` IS KEYED EXPLICITLY.  vBot stores it on the C++ Item userdata, which the
   client recreates whenever the container contents are re-sent, so the counter silently
   resets.  We key it "<containerId>:<slot>:<itemId>" (and "nc:<cid>:<slot>:<itemId>" for
   the nested-bag counter) and drop the whole container's keys on close, exactly as the
   Pitfalls section demands -- otherwise a corpse can loop forever.
3. THE QUEUE SORT IS DETERMINISTIC.  vBot's comparator MUTATES the entries it compares
   (writes a.dist/b.dist) which is undefined behaviour with an unstable sort.  We compute
   every distance up front from the CURRENT player position (which is what the mutating
   comparator effectively does) and break ties by insertion sequence.
4. FREE capacity.  `player:getFreeCapacity()` maps to `state.player.freeCapacity`
   (proto/parser.lua:1750, opcode 0xA0).  `capacity` is TOTAL capacity and using it would
   disable the minCapacity gate permanently (VERIFIER on the pseudocode).
5. The container's source item id is read from `state.containers[id].item` -- the server
   sends it in OpenContainer (proto/parser.lua:1330) -- with the id we recorded when we
   sent the open as the fallback.  docs/vbot/targetbot.md assumed luaclient could not know
   it; it can.

WIDGET DETAIL NOT REPRODUCED (spec section 5): `container:setMarked('#000088')` on a
discovered corpse, and the "Items to ignore" label flip.
============================================================================]]

local bit = require('bit')
local bor = bit.bor

local floor, abs, max = math.floor, math.abs, math.max

local loot = {}

local L = {}
L.__index = L

-- ---------------------------------------------------------------------------
-- constants (docs/vbot/targetbot.md 4.8 "All looting timers in one place")
-- ---------------------------------------------------------------------------
loot.DISCOVERY_DELAY_MS   = 20     -- looting.lua:323
loot.QUEUE_CAP            = 20     -- looting.lua:325  (list[20] ~= nil -> refuse)
loot.DISCOVERY_RADIUS     = 6      -- looting.lua:322  (Chebyshev)
loot.DISCOVERY_PATH_STEPS = 6      -- looting.lua:330
loot.MAX_WALK_TRIES       = 30     -- looting.lua:152  (`tries > 30`)
loot.DEFAULT_MAX_RANGE    = 40     -- storage.extras.looting
loot.MIN_DIST             = 2      -- looting.lua:158-166
loot.WALK_PRECISION       = 2
loot.MIN_DIST_OLD         = 1      -- clientVersion <= 760
loot.WALK_PRECISION_OLD   = 1
loot.DEFAULT_LOOT_DELAY   = 200    -- storage.extras.lootDelay
loot.WAIT_OPEN_NESTED_MS  = 300    -- looting.lua:264
loot.WAIT_OPEN_SPARE_MS   = 500    -- looting.lua:208,217,229
loot.WAIT_MOVE_MS         = 300    -- looting.lua:291,300
loot.MAX_ITEM_TRIES       = 5      -- looting.lua:245  (`< 5`)
loot.MAX_NESTED_TRIES     = 2      -- looting.lua:262  (`< 2`)
loot.FOOD_INTERVAL_MS     = 5000   -- looting.lua:248
loot.STACK_MERGE_LIMIT    = 100    -- looting.lua:288  (`getCount() < 100`)
loot.WALK_MAX_DIST        = 20     -- looting.lua:169
loot.MAX_CONTAINER_ID     = 15     -- Game::findEmptyContainerId scans the open-container map
loot.INVENTORY_FIRST      = 1
loot.INVENTORY_LAST       = 10

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
-- getDistanceBetween INSIDE the bot context is Chebyshev, NOT battle.lua's
-- xd+yd-with-1-subtracted version: mods/game_bot/executor.lua:123-125 overrides the
-- global for every script loaded by the bot, and the whole vBot profile runs there.
-- docs/vbot/targetbot.md 0.4 documents the battle.lua form; that is wrong for bot code
-- and bot/world.lua already made the same call.  Verified by reading executor.lua.
local function cheb(a, b)
    return max(abs(a.x - b.x), abs(a.y - b.y))
end

local function copyPos(p) return { x = p.x, y = p.y, z = p.z } end

-- Container::getSlotPosition (src/client/container.h:37) -- the slot index is 0-BASED
-- while `container:getItems()` is 1-based Lua, hence every `slot - 1` below.
local function slotPos(containerId, slot0)
    return { x = 0xFFFF, y = bor(containerId, 0x40), z = slot0 }
end
loot.slotPos = slotPos

local function inventoryPos(slot)
    return { x = 0xFFFF, y = slot, z = 0 }
end

local function nolog() end
local function mklog(l)
    if type(l) ~= 'table' then
        return { info = nolog, warn = nolog, error = nolog, debug = nolog }
    end
    return {
        info  = l.info  or nolog,
        warn  = l.warn  or l.warning or nolog,
        error = l.error or nolog,
        debug = l.debug or nolog,
    }
end

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
function loot.new(ctx)
    ctx = ctx or {}
    local self = setmetatable({}, L)
    local client = ctx.client or {}
    self.client  = client
    self.state   = ctx.state  or client.state
    self.sender  = ctx.sender or client.sender
    self.events  = ctx.events or client.events
    self.log     = mklog(ctx.log or client.log)
    self.world   = ctx.world
    self.path    = ctx.path
    self.storage = ctx.storage or {}
    self.clientVersion = ctx.clientVersion or 1530
    if not self.state then error('loot.new: client.state is required', 2) end
    if not self.world then error('loot.new: ctx.world is required', 2) end
    if not self.path  then error('loot.new: ctx.path is required',  2) end

    self._now      = ctx.now      or function() return 0 end
    self._schedule = ctx.schedule or function(_, fn) return fn() end
    self._walkTo   = ctx.walkTo   or function() end
    self._isOn     = ctx.isOn     or function() return true end
    self._isInPz   = ctx.isInPz   or function() return false end
    self._params   = ctx.calculateParams or function() return {} end

    -- item predicates.  proto/items.lua v2 supplies both directly; the v1 fallback keeps
    -- the module usable against a v1 items1530.bin (and against a test double).
    local it = client.items
    if type(it) ~= 'table' then
        local ok, m = pcall(require, 'proto.items')
        it = ok and m or {}
    end
    self.itemsApi = it
    if type(it.isContainer) == 'function' then
        self.isContainerItem = it.isContainer
    elseif type(it.flags) == 'function' then
        local CONTAINER = it.CONTAINER or 0x08
        self.isContainerItem = function(id)
            return floor((it.flags(id) or 0) / CONTAINER) % 2 == 1
        end
    else
        self.isContainerItem = function() return false end
    end
    if type(it.isStackable) == 'function' then
        self.isStackableItem = it.isStackable
    elseif type(it.flags) == 'function' then
        local CUMULATIVE = it.CUMULATIVE or 0x01
        self.isStackableItem = function(id)
            return floor((it.flags(id) or 0) / CUMULATIVE) % 2 == 1
        end
    else
        self.isStackableItem = function() return false end
    end

    self:_resetRuntime()
    self:update(ctx.data)
    return self
end

function L:_resetRuntime()
    self.list       = {}          -- the corpse queue (TargetBot.Looting.list)
    self.waitTill   = 0
    self.waitingForContainerItemId = nil
    self.status     = ''
    self.lastFood   = 0
    self.lootTries  = {}          -- deviation (2)
    self.openedFromItemId = {}    -- containerId -> the item id we opened it from
    self.isLootContainer  = {}    -- containerId -> true
    self._seq       = 0
    self.stats = { queued = 0, dropped = 0, opens = 0, moves = 0, closes = 0,
                   food = 0, abandoned = 0 }
end

-- ---------------------------------------------------------------------------
-- configuration (looting.lua:55-96)
-- ---------------------------------------------------------------------------
--- TargetBot.Looting.update(data).  Its FIRST statement wipes the queue
--- (VERIFIER: a reimplementation that keeps it loots corpses vBot has forgotten).
function L:update(data)
    self.list = {}
    if type(data) ~= 'table' then data = {} end
    self.data       = data
    self.items      = type(data.items)      == 'table' and data.items      or {}
    self.containers = type(data.containers) == 'table' and data.containers or {}
    self.itemsById, self.containersById = {}, {}
    for _, e in ipairs(self.items) do
        local id = type(e) == 'table' and e.id or e
        if type(id) == 'number' then self.itemsById[id] = true end
    end
    for _, e in ipairs(self.containers) do
        local id = type(e) == 'table' and e.id or e
        if type(id) == 'number' then self.containersById[id] = true end
    end
    self.lootTries = {}
    return self
end

--- TargetBot.Looting.save(data) (looting.lua:77-83) -- writes the five behaviour-bearing
--- values back into the `looting` object.  Unknown keys of the original table survive
--- because we mutate it in place.
function L:save(data)
    data = data or {}
    data.items       = self.items
    data.containers  = self.containers
    data.everyItem   = self:everyItem()
    data.maxDanger   = self:maxDanger()
    data.minCapacity = self:minCapacity()
    return data
end

-- VERIFIER: everyItem / maxDanger / minCapacity are NOT cached module locals -- `process`
-- re-reads them from the widgets on every tick, so a live edit takes effect immediately.
-- Reading them from `self.data` per call reproduces that.
function L:everyItem()   return (self.data.everyItem and true) or false end
function L:maxDanger()   return tonumber(self.data.maxDanger)   or 10  end
function L:minCapacity() return tonumber(self.data.minCapacity) or 100 end

function L:now() return self._now() end

function L:extras()
    local e = self.storage and self.storage.extras
    return type(e) == 'table' and e or {}
end

--- storage.extras.lootLast defaults to TRUE (looting.lua:121).  With the queue sorted
--- DESCENDING by distance, list[#list] is the NEAREST corpse -- the option label
--- ("Start loot from last corpse") is misleading, the behaviour is not.
function L:lootLast() return self:extras().lootLast ~= false end

function L:maxRange()  return tonumber(self:extras().looting)   or loot.DEFAULT_MAX_RANGE  end
function L:lootDelay() return tonumber(self:extras().lootDelay) or loot.DEFAULT_LOOT_DELAY end

function L:foodItems()
    local f = self.storage and self.storage.foodItems
    return type(f) == 'table' and f or nil
end

function L:getStatus() return self.status end

--- `player:getFreeCapacity()` -- deviation (4).
function L:freeCapacity()
    local pl = self.state.player
    if not pl then return 0 end
    local fc = pl.freeCapacity
    if type(fc) == 'number' then return fc end
    return tonumber(pl.capacity) or 0
end

-- ---------------------------------------------------------------------------
-- queue helpers
-- ---------------------------------------------------------------------------
--- `table.remove(list, lootLast and #list or 1)` -- always the end the reader picked.
function L:pop()
    local n = #self.list
    if n == 0 then return nil end
    local e = table.remove(self.list, self:lootLast() and n or 1)
    self.stats.dropped = self.stats.dropped + 1
    return e
end

function L:current()
    if self:lootLast() then return self.list[#self.list] end
    return self.list[1]
end

-- ---------------------------------------------------------------------------
-- container helpers
-- ---------------------------------------------------------------------------
--- Deviation (1): a reproducible container order.
function L:openContainersSorted()
    local out, ids = {}, {}
    local cs = self.state.containers
    if type(cs) ~= 'table' then return out end
    for id in pairs(cs) do ids[#ids + 1] = id end
    table.sort(ids)
    for i = 1, #ids do out[i] = cs[ids[i]] end
    return out
end

--- `container:getContainerItem():getId()` -- deviation (5).
function L:containerItemId(ct)
    if type(ct) ~= 'table' then return nil end
    if type(ct.item) == 'table' and ct.item.id then return ct.item.id end
    return self.openedFromItemId[ct.id]
end

--- Game::findEmptyContainerId (game.cpp:940): the lowest index not currently open.
function L:freeContainerId()
    local cs = self.state.containers or {}
    for id = 0, loot.MAX_CONTAINER_ID do
        if cs[id] == nil then return id end
    end
    return 0
end

--- g_game.open(item, previousContainer) (game.cpp:935).  `prev` nil => a fresh window at
--- the lowest free id; `prev` given => the item replaces THAT window.
function L:_open(itemId, fromPos, stackpos, prevContainerId)
    local cid = prevContainerId
    if cid == nil then cid = self:freeContainerId() end
    local body
    if self.sender then
        body = self.sender:openContainer(fromPos, itemId, stackpos, cid)
    end
    if body then
        self.openedFromItemId[cid] = itemId
        self.stats.opens = self.stats.opens + 1
    end
    return cid, body
end

function L:openGroundThing(thing, tilePos, stackpos, prevContainerId)
    return self:_open(thing.id, tilePos, stackpos, prevContainerId)
end

function L:openInContainer(ct, slot, item, prevContainerId)
    return self:_open(item.id, slotPos(ct.id, slot - 1), slot - 1, prevContainerId)
end

function L:openInventory(slot, item)
    return self:_open(item.id, inventoryPos(slot), 0, nil)
end

function L:clearTriesFor(containerId)
    local prefix1 = tostring(containerId) .. ':'
    local prefix2 = 'nc:' .. tostring(containerId) .. ':'
    for k in pairs(self.lootTries) do
        if k:sub(1, #prefix1) == prefix1 or k:sub(1, #prefix2) == prefix2 then
            self.lootTries[k] = nil
        end
    end
end

--- Tile::getTopUseThing, plus the 0-based stackpos the wire needs.  bot/world.lua owns
--- the predicate; we only have to recover the index, which it does not return.
function L:topUseThing(tile)
    local thing = self.world:getTopUseThing(tile)
    if not thing then return nil end
    local things = tile.things
    for i = 1, #things do
        if things[i] == thing then return thing, i - 1 end
    end
    return thing, 0
end

-- ---------------------------------------------------------------------------
-- 4.2 corpse discovery -- onCreatureDisappear (looting.lua:310-341)
-- ---------------------------------------------------------------------------
--- `posHint` is bot/targetbot.lua's last-known position for this creature.  It is REQUIRED
--- in luaclient: `game/state.lua:_removeAt` clears `creature.pos` when the creature thing
--- leaves its tile, and proto/parser.lua:411 emits `creatureDisappear` AFTER
--- `state:removeCreature`, so `c.pos` is already nil by the time we see it.  The real
--- client's C++ Creature keeps m_position, which is what vBot reads.
function L:onCreatureDisappear(c, posHint)
    if not c then return end
    if self._isInPz() then return end
    if not self._isOn() then return end
    if not c.isMonster then return end

    -- NOTE the EMPTY path: `#path == 0` always passes the maxDistance gate, so only
    -- "has a matching config" and `dontLoot` decide here (looting.lua:314).
    local params = self._params(c, {})
    if not params or not params.config or params.config.dontLoot then return end

    local pl = self.state.player
    local ppos = pl and pl.pos
    local mpos = c.pos or posHint
    if not ppos or not mpos then return end
    if ppos.z ~= mpos.z or cheb(ppos, mpos) > loot.DISCOVERY_RADIUS then return end

    local name = c.name
    local corpsePos = copyPos(mpos)
    self._schedule(loot.DISCOVERY_DELAY_MS, function()
        self:_discover(corpsePos, name)
    end)
end

function L:_discover(mpos, name)
    if not self.containers[1] then return end                 -- no loot bag configured
    if self.list[loot.QUEUE_CAP] then return end              -- queue cap: 20 entries
    local tile = self.state:tile(mpos)
    if not tile then return end
    local thing = self:topUseThing(tile)
    if not thing or thing.kind ~= 'item' or not self.isContainerItem(thing.id) then return end
    local pl = self.state.player
    if not (pl and pl.pos) then return end
    if not self.path:getPath(pl.pos, mpos, loot.DISCOVERY_PATH_STEPS,
                             { ignoreNonPathable = true, ignoreCreatures = true,
                               ignoreCost = true }) then return end

    self._seq = self._seq + 1
    self.list[#self.list + 1] = { pos = mpos, creature = name, container = thing.id,
                                  added = self:now(), tries = 0, seq = self._seq }
    self.stats.queued = self.stats.queued + 1
    self:_sortQueue()
    return true
end

--- Deviation (3): FARTHEST FIRST, distances taken from the current player position,
--- ties broken by insertion order so the result is reproducible.
function L:_sortQueue()
    local pl = self.state.player
    local ppos = pl and pl.pos
    for i = 1, #self.list do
        local e = self.list[i]
        e.dist = ppos and cheb(ppos, e.pos) or 0
    end
    table.sort(self.list, function(a, b)
        if a.dist ~= b.dist then return a.dist > b.dist end
        return a.seq < b.seq
    end)
end

--- onTextMessage (looting.lua:276-282)
function L:onTextMessage(m)
    if not self._isOn() then return end
    if #self.list == 0 then return end
    local text = type(m) == 'table' and m.text or m
    if type(text) ~= 'string' then return end
    if text:lower():find('you are not the owner', 1, true) then self:pop() end
end

--- onContainerOpen (looting.lua:303-308)
function L:onContainerOpen(ct)
    if type(ct) ~= 'table' or ct.id == nil then return end
    local fromId = self:containerItemId(ct)
    if fromId ~= nil and fromId == self.waitingForContainerItemId then
        self.isLootContainer[ct.id] = true
        self.waitingForContainerItemId = nil
    end
end

--- Not in vBot (the Item userdata simply died with the window) -- deviation (2).
function L:onContainerClose(ct)
    local id = type(ct) == 'table' and ct.id or ct
    if id == nil then return end
    self.isLootContainer[id]   = nil
    self.openedFromItemId[id]  = nil
    self:clearTriesFor(id)
end

-- ---------------------------------------------------------------------------
-- 4.3 the per-tick state machine
-- ---------------------------------------------------------------------------
function L:process(targets, dangerLevel)
    dangerLevel = dangerLevel or 0

    -- 1
    local everyItem = self:everyItem()
    if (not self.items[1] and not everyItem) or not self.containers[1] then
        self.status = ''
        return false
    end
    -- 2
    if dangerLevel > self:maxDanger() then
        self.status = 'High danger'
        return false
    end
    -- 3  (the queue is WIPED, not merely paused)
    if self:freeCapacity() < self:minCapacity() then
        self.status = 'No cap'
        self.list = {}
        return false
    end
    -- 4
    local entry = self:current()
    if entry == nil then
        self.status = ''
        return false
    end
    -- 5
    local now = self:now()
    if self.waitTill > now then return true end
    -- 6/7
    local lootContainers = self:getLootContainers()
    if not lootContainers[1] then
        self.status = 'No space'
        return false
    end
    -- 8
    self.status = 'Looting'
    -- 9  (BEFORE the corpse-approach code: once a corpse window is flagged, nothing else runs)
    for _, ct in ipairs(self:openContainersSorted()) do
        if self.isLootContainer[ct.id] then
            self:lootContainer(lootContainers, ct)
            return true
        end
    end
    -- 10
    local pl = self.state.player
    local pos = pl and pl.pos
    if not pos then return true end
    local dist = cheb(pos, entry.pos)
    if entry.tries > loot.MAX_WALK_TRIES or entry.pos.z ~= pos.z or dist > self:maxRange() then
        self:pop()
        return true
    end
    -- 11
    local tile = self.state:tile(entry.pos)
    local minDist, walkPrecision = loot.MIN_DIST, loot.WALK_PRECISION
    if self.clientVersion <= 760 then
        minDist, walkPrecision = loot.MIN_DIST_OLD, loot.WALK_PRECISION_OLD
    end
    if dist > minDist or not tile then
        entry.tries = entry.tries + 1
        self._walkTo(entry.pos, loot.WALK_MAX_DIST,
                     { ignoreNonPathable = true, precision = walkPrecision })
        return true
    end
    -- 12
    local thing, stackpos = self:topUseThing(tile)
    if not thing or thing.kind ~= 'item' or not self.isContainerItem(thing.id) then
        self:pop()
        return true
    end
    -- 13
    self:openGroundThing(thing, entry.pos, stackpos, nil)
    self.waitTill = now + self:lootDelay()
    self.waitingForContainerItemId = thing.id
    return true
end

-- ---------------------------------------------------------------------------
-- 4.4 destination bags -- getLootContainers (looting.lua:186-235)
-- ---------------------------------------------------------------------------
function L:getLootContainers()
    local out, openedById, toOpen = {}, {}, nil
    local byId = self.containersById
    local open = self:openContainersSorted()

    for i = 1, #open do
        local ct = open[i]
        local fromId = self:containerItemId(ct)
        if fromId ~= nil then openedById[fromId] = 1 end
        if fromId ~= nil and byId[fromId] and not self.isLootContainer[ct.id] then
            local items = ct.items or {}
            if #items < (ct.capacity or 0) or ct.hasPages then
                out[#out + 1] = ct                                   -- has room
            else
                for slot = 1, #items do                              -- a nested spare bag
                    local it = items[slot]
                    if self.isContainerItem(it.id) and byId[it.id] then
                        toOpen = { it, ct, slot }
                        break
                    end
                end
            end
        end
    end

    if not out[1] then
        -- A) replace the full bag with the spare it carries, in its own window
        if toOpen then
            self:openInContainer(toOpen[2], toOpen[3], toOpen[1], toOpen[2].id)
            self.waitTill = self:now() + loot.WAIT_OPEN_SPARE_MS
            return out
        end
        -- B) any non-loot container holding a loot bag
        for i = 1, #open do
            local ct = open[i]
            local fromId = self:containerItemId(ct)
            if not (fromId ~= nil and byId[fromId]) and not self.isLootContainer[ct.id] then
                local items = ct.items or {}
                for slot = 1, #items do
                    local it = items[slot]
                    if self.isContainerItem(it.id) and byId[it.id] then
                        self:openInContainer(ct, slot, it, nil)
                        self.waitTill = self:now() + loot.WAIT_OPEN_SPARE_MS
                        return out
                    end
                end
            end
        end
        -- C) an equipped container that is not open yet
        local inv = self.state.player and self.state.player.inventory
        if inv then
            for slot = loot.INVENTORY_FIRST, loot.INVENTORY_LAST do
                local it = inv[slot]
                if it and it.id and self.isContainerItem(it.id) and not openedById[it.id] then
                    self:openInventory(slot, it)
                    self.waitTill = self:now() + loot.WAIT_OPEN_SPARE_MS
                    return out
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- 4.5 emptying a corpse -- lootContainer (looting.lua:237-274)
-- ---------------------------------------------------------------------------
function L:lootContainer(lootContainers, ct)
    local now       = self:now()
    local everyItem = self:everyItem()
    local byId      = self.itemsById
    local items     = ct.items or {}
    local food      = self:foodItems()
    local nextContainer, nextSlot = nil, nil

    for slot = 1, #items do
        local it = items[slot]
        local isCt = it.id ~= nil and self.isContainerItem(it.id) or false
        if isCt and not byId[it.id] then
            nextContainer, nextSlot = it, slot                 -- keeps the LAST such slot
        elseif (not everyItem and byId[it.id])
            or (everyItem and not isCt and not byId[it.id]) then
            local key = ct.id .. ':' .. slot .. ':' .. tostring(it.id)
            local n = (self.lootTries[key] or 0) + 1
            self.lootTries[key] = n
            if n < loot.MAX_ITEM_TRIES then
                return self:lootItem(lootContainers, ct, slot, it)
            end
            self.stats.abandoned = self.stats.abandoned + 1
        elseif food and food[1] and self.lastFood + loot.FOOD_INTERVAL_MS < now then
            for _, f in ipairs(food) do
                if it.id == f.id then
                    if self.sender then
                        self.sender:use(slotPos(ct.id, slot - 1), it.id, slot - 1, 0)
                    end
                    self.lastFood = now
                    self.stats.food = self.stats.food + 1
                    return
                end
            end
        end
    end

    if nextContainer then
        local key = 'nc:' .. ct.id .. ':' .. nextSlot .. ':' .. tostring(nextContainer.id)
        local n = (self.lootTries[key] or 0) + 1
        self.lootTries[key] = n
        if n < loot.MAX_NESTED_TRIES then
            -- opens IN PLACE of the corpse window (previousContainer = the corpse)
            self:openInContainer(ct, nextSlot, nextContainer, ct.id)
            self.waitTill = now + loot.WAIT_OPEN_NESTED_MS
            self.waitingForContainerItemId = nextContainer.id
            return
        end
    end

    -- looting finished
    self.isLootContainer[ct.id] = nil
    if self.sender then self.sender:closeContainer(ct.id) end
    self.stats.closes = self.stats.closes + 1
    self:clearTriesFor(ct.id)
    self:pop()
end

-- ---------------------------------------------------------------------------
-- 4.6 moving one item -- lootItem (looting.lua:284-301)
-- ---------------------------------------------------------------------------
function L:lootItem(lootContainers, ct, slot, it)
    local from  = slotPos(ct.id, slot - 1)
    local stack = slot - 1
    if self.isStackableItem(it.id) then
        local count = it.count or 1
        for i = 1, #lootContainers do
            local c = lootContainers[i]
            local citems = c.items or {}
            for s2 = 1, #citems do
                local ci = citems[s2]
                if ci.id == it.id and (ci.count or 1) < loot.STACK_MERGE_LIMIT then
                    if self.sender then
                        self.sender:move(from, it.id, stack, slotPos(c.id, s2 - 1), count)
                    end
                    self.stats.moves = self.stats.moves + 1
                    self.waitTill = self:now() + loot.WAIT_MOVE_MS
                    return
                end
            end
        end
    end
    -- the fallback moves exactly ONE unit, appended at the end of the FIRST loot bag.
    -- Verbatim vBot: a fresh stackable costs two moves, the second merging the rest.
    local c = lootContainers[1]
    if self.sender then
        self.sender:move(from, it.id, stack, slotPos(c.id, #(c.items or {})), 1)
    end
    self.stats.moves = self.stats.moves + 1
    self.waitTill = self:now() + loot.WAIT_MOVE_MS
end

-- ---------------------------------------------------------------------------
-- introspection (BOT.md status object)
-- ---------------------------------------------------------------------------
function L:snapshot()
    local nLoot = 0
    for _ in pairs(self.isLootContainer) do nLoot = nLoot + 1 end
    local cur = self:current()
    return {
        status      = self.status,
        queued      = #self.list,
        current     = cur and { pos = cur.pos, creature = cur.creature, tries = cur.tries } or nil,
        waitTill    = self.waitTill,
        waitingFor  = self.waitingForContainerItemId,
        openCorpses = nLoot,
        items       = #self.items,
        containers  = #self.containers,
        everyItem   = self:everyItem(),
        maxDanger   = self:maxDanger(),
        minCapacity = self:minCapacity(),
        stats       = self.stats,
    }
end
L.status_  = L.snapshot        -- `status` itself is a STRING field, hence the name
L.getStats = function(self) return self.stats end

loot.Loot  = L
loot.cheb  = cheb
return loot
