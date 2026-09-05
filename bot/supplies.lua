--[[============================================================================
bot/supplies.lua -- supply thresholds, the round gate and the refill helpers (work item M2).

Behaviour source: docs/vbot/cavebot.md section 4 (`cavebot/supply_check.lua`,
`vBot/supplies.lua`, `vBot/vlib.lua`), whose "## VERIFIER (Corrections)" section overrides
the spec body and is followed here.

    local sup = supplies.new(bot, config)        -- config = decoded Supplies.json (or nil)
    sup:reload(config)
    sup:items()            -> { [itemId] = {min=,max=,avg=} }
    sup:additionalData()   -> { stamina=, capacity=, softBoots=, imbues=, lootPouch= }
    sup:itemAmount(id[,tier])
    sup:hasEnough()        -> true | { id=, amount= }        (vBot Supplies.hasEnough)
    sup:missing()          -> ordered list of every id below its min
    sup:buyList()          -> { {id=, amount=} }  amount = min(100, max - have)
    sup:lootPouchPages()   -> pages | nil
    sup:checkRound(opts)   -> nil (keep hunting) | reason string (go refill)
    sup:status()

CONFIG SHAPE (the user's REAL file, verbatim):

  {"supplies":{"Default":{"capSwitch":true,"lootPouchValue":"50","lootPouchSwitch":true,
   "capValue":"200","items":{"23374":{"avg":0,"min":200,"max":1200},
   "3097":{"avg":0,"min":1,"max":5}}},"currentProfile":"Default"}}

`supplies.currentProfile` names the active sub-profile.  **Every threshold is stored as a
STRING** (`"capValue":"200"`) -- a naive `<` against one throws in LuaJIT, so everything is
tonumber()'d on load (cavebot.md pitfalls).  Item ids are string keys.

`itemAmount(id, tier)` is `max(visible scan over equipped + open containers,
state.inventoryCounts[id*256+tier])` (vlib.lua:822-888).  Using only the visible scan makes a
full but CLOSED backpack read as zero and triggers an endless refill loop -- that is exactly
the bug the comment at buy_supplies.lua:80-81 describes.  proto/parser.lua stores the server's
own count table at `state.inventoryCounts` (opcode 0xC0), keyed `itemId*256 + tier`.

THE ROUND GATE (`supply_check.lua:102-155`).  The FIRST matching branch wins:

   1 storage.caveBot.forceRefill      (consumed -- the flag is cleared)
   2 storage.caveBot.backStop
   3 storage.caveBot.backTrainers
   4 storage.caveBot.backOffline
   5 (extras.huntRoutes or 0) ~= 0 and rounds > (extras.huntRoutes or 50)   [VERIFIER]
   6 imbues        and skillLevel(11) == 0
   7 stamina       and stamina() < staminaValue
   8 softBoots     and itemAmount(6529) + itemAmount(3549) < 1
   9 Supplies.hasEnough() returned a table          (an item below its min)
  10 capacity      and freecap() < capValue
  11 lootPouch     and pouch pages >= lootPouchValue
  12 otherwise -> keep hunting

VERIFIER on branch 5: both reads are defaulted and with DIFFERENT defaults --
`(huntRoutes or 0) ~= 0 and supplyRetries > (huntRoutes or 50)`.  The `or 50` is dead
whenever the first read succeeded, but it is mirrored here so a nil-ish huntRoutes behaves
identically.

LOOT POUCH (`supply_check.lua:39-57`): only the container literally named `loot pouch`;
`pages = ceil(size / capacity)` with `size = getSize()` (the server's total across pages)
falling back to the visible item count; nil (check skipped) when the pouch is closed or its
capacity is <= 0.
============================================================================]]

local ceil, floor, max = math.ceil, math.floor, math.max

local supplies = {}

local S = {}
S.__index = S

-- buy_supplies.lua:14-16
supplies.BATCH_SIZE   = 100      -- the NPC per-trade limit
supplies.STUCK_ROUNDS = 50       -- consecutive no-progress rounds
supplies.MAX_ROUNDS   = 2000     -- absolute retry ceiling

supplies.SOFT_BOOTS_IDS = { 6529, 3549 }   -- worn / unworn soft boots (supply_check.lua)
supplies.IMBUE_SKILL    = 11               -- player:getSkillLevel(11)
supplies.LOOT_POUCH_NAME = 'loot pouch'

supplies.INVENTORY_FIRST = 1
supplies.INVENTORY_LAST  = 10              -- Purse (11) excluded, like gamelib findItem

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local function num(v, dflt)
    if type(v) == 'number' then return v end
    if type(v) == 'string' then
        local n = tonumber(v)
        if n then return n end
    end
    return dflt
end
supplies.num = num

local function truthy(v)
    -- vBot stores these as real booleans; a JSON round trip can leave "true"/1.
    if v == nil or v == false then return false end
    if v == 0 or v == '0' or v == '' or v == 'false' then return false end
    return true
end
supplies.truthy = truthy

local function nolog() end
local function mklog(l)
    if type(l) ~= 'table' then
        return { info = nolog, warn = nolog, error = nolog, debug = nolog }
    end
    return { info  = l.info  or nolog, warn = l.warn  or nolog,
             error = l.error or nolog, debug = l.debug or nolog }
end

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
--- supplies.new(bot, config)
---   bot     the bot/init.lua instance (state, storage, config profile, log).  A bare
---           `{ state = <game.state> }` is enough for tests.
---   config  the decoded Supplies.json.  Accepted in three shapes:
---             { supplies = { Default = {...}, currentProfile = 'Default' } }   (the file)
---             { Default = {...}, currentProfile = 'Default' }                  (the inner)
---             { items = {...}, capSwitch = ... }                               (one profile)
---           nil -> loaded through bot.config:loadSupplies() when that exists.
function supplies.new(bot, config)
    local self = setmetatable({}, S)
    self.bot    = bot
    self.client = bot and (bot.client or bot) or nil
    self.state  = (bot and bot.state) or (self.client and self.client.state)
    self.log    = mklog(bot and bot.log)
    self.enabled = true
    self.stats  = { checks = 0, refills = 0, rounds = 0 }
    -- supply_check.lua's two file-local counters
    self.supplyRetries = 0       -- completed hunt rounds since the last refill
    self.missedChecks  = 0       -- consecutive out-of-position supplycheck visits
    self:reload(config)
    return self
end

--- Accepts any of the three documented shapes; nil re-reads the profile file.
function S:reload(config)
    if config == nil and self.bot and self.bot.config and self.bot.config.loadSupplies then
        config = self.bot.config:loadSupplies()
    end
    self.raw = config

    local root = config
    if type(root) == 'table' and type(root.supplies) == 'table' then root = root.supplies end

    local profileName, profile
    if type(root) == 'table' then
        profileName = root.currentProfile
        if type(profileName) == 'string' and type(root[profileName]) == 'table' then
            profile = root[profileName]
        elseif type(root.items) == 'table' or root.capSwitch ~= nil then
            profile, profileName = root, profileName or 'Default'   -- already a sub-profile
        elseif type(root.Default) == 'table' then
            profile, profileName = root.Default, 'Default'
        end
    end

    self.profileName = profileName or 'Default'
    self.profile     = profile or {}

    -- items: string keys -> numeric ids, string thresholds -> numbers
    local items, order = {}, {}
    local src = (type(self.profile.items) == 'table') and self.profile.items or {}
    for k, v in pairs(src) do
        local id = num(k)
        if id and type(v) == 'table' then
            items[id] = { min = num(v.min, 0), max = num(v.max, 0), avg = num(v.avg, 0) }
            order[#order + 1] = id
        end
    end
    -- pairs() order is unspecified; the cascade must be deterministic across runs.
    table.sort(order)
    self._items      = items
    self._itemOrder  = order

    local p = self.profile
    self._extra = {
        stamina   = { enabled = truthy(p.staminaSwitch),   value = num(p.staminaValue, 0) },
        capacity  = { enabled = truthy(p.capSwitch),       value = num(p.capValue, 0) },
        softBoots = { enabled = truthy(p.SoftBoots or p.softBoots) },
        imbues    = { enabled = truthy(p.imbues) },
        lootPouch = { enabled = truthy(p.lootPouchSwitch), value = num(p.lootPouchValue, 0) },
    }
    return self
end

-- module conformance (BOT.md "Modules") -- supplies is passive, it registers no macro.
function S:enable()  self.enabled = true;  return self end
function S:disable() self.enabled = false; return self end
function S:isOn()    return self.enabled == true end
function S:tick()    return nil end

function S:items()          return self._items end
function S:itemOrder()      return self._itemOrder end
function S:additionalData() return self._extra end
supplies.getAdditionalData = nil     -- (instance method only; vBot's is a free function)

-- ---------------------------------------------------------------------------
-- itemAmount: max(visible scan, the server's own inventory count)
-- ---------------------------------------------------------------------------
function S:visibleCount(itemId, subType)
    subType = subType or -1
    local st = self.state
    if not st then return 0 end
    local total = 0
    local p = st.player
    if p and p.inventory then
        for slot = supplies.INVENTORY_FIRST, supplies.INVENTORY_LAST do
            local it = p.inventory[slot]
            if it and it.id == itemId and (subType == -1 or (it.count or 0) == subType) then
                total = total + (it.count or 1)
            end
        end
    end
    for _, c in pairs(st.containers or {}) do
        for _, it in ipairs(c.items or {}) do
            if it.id == itemId and (subType == -1 or (it.count or 0) == subType) then
                total = total + (it.count or 1)
            end
        end
    end
    return total
end

--- The server-reported count (opcode 0xC0 -> state.inventoryCounts, keyed id*256 + tier).
function S:serverCount(itemId, tier)
    local st = self.state
    local counts = st and st.inventoryCounts
    if type(counts) ~= 'table' then return 0 end
    return counts[itemId * 256 + (tier or 0)] or 0
end

--- vlib.lua:822-888 -- max of the two, so a CLOSED backpack still counts.
function S:itemAmount(itemId, tier)
    if type(itemId) ~= 'number' then return 0 end
    return max(self:visibleCount(itemId), self:serverCount(itemId, tier))
end

-- ---------------------------------------------------------------------------
-- Supplies.hasEnough() (vBot/supplies.lua:396-497)
-- ---------------------------------------------------------------------------
--- true when every configured id is at or above its min; otherwise the FIRST
--- offender as `{ id = <itemId>, amount = <how many we hold> }`.
function S:hasEnough()
    for _, id in ipairs(self._itemOrder) do
        local v = self._items[id]
        local have = self:itemAmount(id)
        if have < (v.min or 0) then return { id = id, amount = have } end
    end
    return true
end

--- Every offender, for the status object / the web panel.
function S:missing()
    local out = {}
    for _, id in ipairs(self._itemOrder) do
        local v = self._items[id]
        local have = self:itemAmount(id)
        if have < (v.min or 0) then
            out[#out + 1] = { id = id, have = have, min = v.min, max = v.max }
        end
    end
    return out
end

--- buy_supplies.lua:71-84 -- `toBuy = min(BATCH_SIZE, max - itemAmount(id))`, one batch per id.
function S:buyList()
    local out = {}
    for _, id in ipairs(self._itemOrder) do
        local v = self._items[id]
        local toBuy = math.min(supplies.BATCH_SIZE, (v.max or 0) - self:itemAmount(id))
        if toBuy > 0 then out[#out + 1] = { id = id, amount = toBuy } end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- loot pouch pages (supply_check.lua:39-57)
-- ---------------------------------------------------------------------------
function S:lootPouch()
    local st = self.state
    if not (st and st.containers) then return nil end
    for _, c in pairs(st.containers) do
        if tostring(c.name or ''):lower() == supplies.LOOT_POUCH_NAME then return c end
    end
    return nil
end

--- nil means "check skipped" (pouch closed or capacity unusable), never 0.
function S:lootPouchPages()
    local c = self:lootPouch()
    if not c then return nil end
    local capacity = num(c.capacity, 0)
    if capacity <= 0 then return nil end
    local size = num(c.size, nil)
    if size == nil then size = #(c.items or {}) end
    return ceil(size / capacity)
end

-- ---------------------------------------------------------------------------
-- player probes
-- ---------------------------------------------------------------------------
function S:freeCap()
    local p = self.state and self.state.player
    return num(p and p.capacity, 0)
end

function S:stamina()
    local p = self.state and self.state.player
    return num(p and p.stamina, 0)
end

function S:skillLevel(i)
    local p = self.state and self.state.player
    local sk = p and p.skills and p.skills[i]
    if type(sk) == 'table' then return num(sk.level, 0) end
    return num(sk, 0)
end

-- ---------------------------------------------------------------------------
-- storage access (bot storage <P>/storage/profile_<N>.json)
-- ---------------------------------------------------------------------------
function S:storage()
    local s = self.bot and self.bot.storage
    return (type(s) == 'table') and s or nil
end

function S:caveBotFlags()
    local s = self:storage()
    local c = s and s.caveBot
    return (type(c) == 'table') and c or {}
end

function S:extras()
    local s = self:storage()
    local e = s and s.extras
    return (type(e) == 'table') and e or {}
end

-- ---------------------------------------------------------------------------
-- the round gate (supply_check.lua:102-155)
-- ---------------------------------------------------------------------------
--- checkRound(opts) -> nil | reason
---
--- nil            supplies are fine, keep hunting (the caller does `rounds++` and
---                `gotoLabel(huntLabel)`).
--- <reason>       go and refill (the caller returns false so the route falls through into
---                the refill branch).
---
--- opts.consume   default true -- `forceRefill` is a ONE-SHOT flag and branch 1 clears it,
---                exactly like supply_check.lua:104.  Pass false for a dry probe.
function S:checkRound(opts)
    opts = opts or {}
    local consume = opts.consume ~= false
    self.stats.checks = self.stats.checks + 1

    local cb    = self:caveBotFlags()
    local extra = self:extras()
    local ad    = self._extra

    -- 1 ----------------------------------------------------------------- forceRefill
    if truthy(cb.forceRefill) then
        if consume then cb.forceRefill = false end
        return 'forceRefill'
    end
    -- 2,3,4 ------------------------------------------------- backStop / trainers / offline
    if truthy(cb.backStop)     then return 'backStop'     end
    if truthy(cb.backTrainers) then return 'backTrainers' end
    if truthy(cb.backOffline)  then return 'backOffline'  end

    -- 5 ------------------------------------------------------------------- round limit
    -- VERIFIER: `(huntRoutes or 0) ~= 0 and supplyRetries > (huntRoutes or 50)`.
    local hrGate  = num(extra.huntRoutes, 0)
    local hrLimit = num(extra.huntRoutes, 50)
    if hrGate ~= 0 and self.supplyRetries > hrLimit then
        return 'huntRoutes'
    end

    -- 6 ---------------------------------------------------------------------- imbuements
    if ad.imbues.enabled and self:skillLevel(supplies.IMBUE_SKILL) == 0 then
        return 'imbues'
    end
    -- 7 ------------------------------------------------------------------------ stamina
    if ad.stamina.enabled and self:stamina() < ad.stamina.value then
        return 'stamina'
    end
    -- 8 --------------------------------------------------------------------- soft boots
    if ad.softBoots.enabled then
        local n = 0
        for _, id in ipairs(supplies.SOFT_BOOTS_IDS) do n = n + self:itemAmount(id) end
        if n < 1 then return 'softBoots' end
    end
    -- 9 ------------------------------------------------------------------- supply items
    local enough = self:hasEnough()
    if type(enough) == 'table' then
        self.lastMissing = enough
        return 'supplies:' .. tostring(enough.id)
    end
    self.lastMissing = nil
    -- 10 ---------------------------------------------------------------------- capacity
    if ad.capacity.enabled and self:freeCap() < ad.capacity.value then
        return 'capacity'
    end
    -- 11 -------------------------------------------------------------------- loot pouch
    if ad.lootPouch.enabled then
        local pages = self:lootPouchPages()
        if pages and pages >= ad.lootPouch.value then return 'lootPouch' end
    end
    -- 12 ------------------------------------------------------------------ keep hunting
    return nil
end

--- Round bookkeeping, kept here so cavebot.lua stays a pure dispatcher.
function S:roundCompleted()
    self.supplyRetries = self.supplyRetries + 1
    self.stats.rounds  = self.stats.rounds + 1
    return self.supplyRetries
end

function S:refillStarted()
    self.supplyRetries = 0
    self.missedChecks  = 0
    self.stats.refills = self.stats.refills + 1
end

function S:resetCounters()
    self.supplyRetries = 0
    self.missedChecks  = 0
end

-- ---------------------------------------------------------------------------
-- status (BOT.md status object: supplies = {{item, count, threshold}})
-- ---------------------------------------------------------------------------
--- BOT.md's status object spells `supplies = {{item, count, threshold}}`, i.e. an ARRAY.
--- The array part carries exactly that; the named fields are extra context for the web
--- panel and do not disturb ipairs / # over it.  Deliberately NO self-referencing alias:
--- bot/config.lua's jsonEncode would not survive a cycle.
function S:status()
    local st = {}
    for _, id in ipairs(self._itemOrder) do
        local v = self._items[id]
        st[#st + 1] = { item = id, count = self:itemAmount(id),
                        threshold = v.min, max = v.max }
    end
    st.on         = self:isOn()
    st.profile    = self.profileName
    st.extra      = self._extra
    st.rounds     = self.supplyRetries
    st.missed     = self.missedChecks
    st.pouchPages = self:lootPouchPages()
    st.stats      = self.stats
    return st
end

supplies.S = S
return supplies
