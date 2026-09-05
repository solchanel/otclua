--[[============================================================================
lib/stats.lua -- the statistics engine behind the panel's per-instance numbers
                 (PANEL.md, "Statistics the panel shows").

  local stats = require('lib.stats')
  local s = stats.new{ window = 15*60*1000 }
  s:sessionStart(t0)
  s:sampleExperience(ms, exp)          s:sampleLevel(ms, level, percent)
  s:addLoot(ms, itemId, count, unitValue)   s:addWaste(ms, itemId, count, unitValue)
  s:addKill(ms, monsterName)           s:addDeath(ms)
  s:sampleBalance(ms, goldOnHand)      s:reset()
  local snap = s:snapshot(ms)

PROPERTIES (these are the requirements, restated so they can be checked):

  * PURE.  No I/O, no globals, no clock of its own: every entry point takes the
    monotonic `ms` the caller read (lib/sys.nowMs()).  That is what makes the
    suite in test/statsuite.lua able to simulate an eight-hour hunt in 30 ms.
    The one exception is `stats.loadPrices(path)` at the very bottom of this
    file, which is a convenience wrapper the engine itself never calls.
  * O(1) AMORTISED.  Every series is a ring buffer of (timestamp, cumulative
    value).  A sample is pushed once and dropped once; nothing is ever shifted
    or re-scanned, so a sample costs the same at minute 1 and at hour 8.
  * BOUNDED.  The ring grows to `maxSamples` (default 20000) and then recycles
    in place, so even a caller that never advances its clock cannot make the
    engine grow without limit.  Under normal use the sliding window evicts long
    before the cap: 15 min at 1 Hz is ~900 retained samples per series.
  * HONEST.  A rate is always (value gained) / (time actually measured), never
    an extrapolation from a full-window assumption.  Below `minSpanMs` of
    measured history (default 60 s) a rate is `nil`, not a wild number: 200 gp
    looted in the first 3 s of a session is not "240k gp/h".

---------------------------------------------------------------------------
WHAT WAS TAKEN FROM THE USER'S REAL ANALYSER
  D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/analyzer.lua
---------------------------------------------------------------------------
The money model is vBot's, not invented here:

  * loot value  -- analyzer.lua `bottingStats()`:
        for k,v in pairs(lootedItems) do lootWorth = lootWorth + LootItems[v.name]*v.count end
    i.e. sum over looted items of (unit price x count).  An item with no price
    entry contributes nothing (vBot's `getPrice()` returns 0 and remembers the
    miss in `noData`).  Here that is `stats.itemValue(prices, id) -> 0` for an
    unknown id -- the documented default.
  * waste value -- the same sum over `usedItems`, which vBot fills from the
    "using one of the ..." server messages and from ammunition count drops.
    We take the already-decided (itemId, count) via `addWaste`.
  * balance     -- `balance = lootWorth - wasteWorth` (analyzer.lua, same
    function).  Positive = profit.
  * hourly rate -- `hourVal(v) = (v/uptime)*3600` (uptime in seconds), i.e. a
    plain session average, and `lootHour()/wasteHour()` refuse to extrapolate
    while `uptime < 5*60`, returning the raw total instead.  We keep the refusal
    but return `nil` instead of a total-that-looks-like-a-rate, and we do it
    over the sliding window as well as over the session.
  * exp to next level -- `expLeft()`:
        local level = lvl()+1
        floor((50*level^3)/3 - 100*level^2 + (850*level)/3 - 200) - exp()
    reproduced exactly as `stats.expForLevel(level)`; `timeToLevelMs` is
    vBot's `timeToLevel()` = expLeft / expPerHour.
  * exp/h -- vBot keeps `expTable`, appends `exp()` every 500 ms and trims it to
    15*60 entries, then does `r = exp() - expTable[1]` and either
    `(r/uptime)*3600` (while uptime < 15 min) or `r*8`.  Two things are wrong
    with that and are deliberately NOT copied: 15*60 entries at 500 ms is a
    7.5-minute window, not 15 minutes, and `r*8` hard-codes "the window is
    exactly 1/8 h" even when it is not.  We measure the span we actually have.
  * kills -- vBot counts them from "Loot of <name>" messages (`killList`); the
    caller decides, we just count.

The vBot analyser has no deaths handling for exp at all (a death makes its
`r = exp() - expTable[1]` go negative and it prints a negative exp/h).  Here a
falling experience total contributes zero gain, never negative -- see
`sampleExperience`.

---------------------------------------------------------------------------
snapshot(ms) -> table
---------------------------------------------------------------------------
  expPerHour          number|nil  sliding-window exp/h  (nil below minSpanMs)
  expPerHourSession   number|nil  session-average exp/h (nil below minSessionMs)
  level               number|nil  last value from sampleLevel
  levelPercent        number|nil  0..100, progress into the current level
  expToLevel          number|nil  experience still needed for level+1
  lootPerHour         number|nil  \
  wastePerHour        number|nil   |  all four share ONE baseline sample, so
  balancePerHour      number|nil   |  balancePerHour == loot - waste exactly
  moneyPerHour        number|nil  /   (see moneySource)
  killsPerHour        number|nil
  kills               number      session total
  deaths              number      session total
  sessionMs           number      0 when the session has not started
  samples             number      retained samples across all series (memory)

  plus, because the panel wants them and they are free:
  expTotal, expGained, expLost, levelsGained, timeToLevelMs, loot, waste,
  balance, gold, moneySource ('gold'|'balance'|nil), windowMs, minSpanMs,
  spanMs (the span each windowed rate was measured over), sessionSpanMs,
  lootItems / wasteItems / killsByName (breakdowns), samplesBySeries,
  samplesDropped, outOfOrder.

`moneySource` says where moneyPerHour came from: 'gold' when the caller feeds
sampleBalance (real cash on hand -- coins looted minus coins spent, which is
what PANEL.md's money/h asks for), 'balance' when it does not and the loot-minus-
waste rate is used instead, nil when neither is available yet.
============================================================================]]

local M = { _version = '1.0.0' }

local floor, max, min = math.floor, math.max, math.min

local HOUR_MS = 3600000

-- ===========================================================================
-- ring buffer of (t, a[, b]) -- push O(1), drop-front O(1), memory capped
-- ===========================================================================
local Ring = {}
Ring.__index = Ring

local function ringNew(maxN)
    return setmetatable({
        cap = 8, n = 0, head = 0,        -- head is 0-based; slot = (head+i)%cap+1
        maxN = maxN or 20000,
        t = {}, a = {}, b = {},
        dropped = 0,
    }, Ring)
end

function Ring:_grow()
    local ncap = self.cap * 2
    if ncap > self.maxN then ncap = self.maxN end
    if ncap <= self.cap then return false end
    local t, a, b = {}, {}, {}
    for i = 0, self.n - 1 do
        local j = (self.head + i) % self.cap + 1
        t[i + 1], a[i + 1], b[i + 1] = self.t[j], self.a[j], self.b[j]
    end
    self.t, self.a, self.b = t, a, b
    self.cap, self.head = ncap, 0
    return true
end

function Ring:push(ts, va, vb)
    if self.n >= self.cap and not self:_grow() then
        -- at the hard cap: recycle the oldest slot (memory stays flat)
        self.head = (self.head + 1) % self.cap
        self.n = self.n - 1
        self.dropped = self.dropped + 1
    end
    local j = (self.head + self.n) % self.cap + 1
    self.t[j], self.a[j], self.b[j] = ts, va, vb
    self.n = self.n + 1
end

function Ring:_slot(i) return (self.head + i) % self.cap + 1 end
function Ring:tAt(i) return self.t[self:_slot(i)] end
function Ring:aAt(i) return self.a[self:_slot(i)] end
function Ring:bAt(i) return self.b[self:_slot(i)] end

function Ring:popFront()
    if self.n == 0 then return end
    local j = self:_slot(0)
    self.t[j], self.a[j], self.b[j] = nil, nil, nil
    self.head = (self.head + 1) % self.cap
    self.n = self.n - 1
end

-- Evict everything older than the window, but keep ONE sample at or before the
-- cutoff: it is the baseline the rate is measured from.  Amortised O(1) -- each
-- push is dropped at most once, and the loop only ever touches the front.
function Ring:trim(nowMs, windowMs)
    local cutoff = nowMs - windowMs
    while self.n >= 2 and self:tAt(1) <= cutoff do self:popFront() end
end

function Ring:clear()
    self.t, self.a, self.b = {}, {}, {}
    self.cap, self.n, self.head, self.dropped = 8, 0, 0, 0
end

-- ===========================================================================
-- prices
-- ===========================================================================

-- stats.itemValue(prices, itemId) -> number
-- Documented default: an item that is not in the table is worth 0, exactly like
-- vBot's getPrice() returning 0 for anything missing from LootItems.
function M.itemValue(prices, itemId)
    if not prices then return 0 end
    local id = tonumber(itemId)
    if not id then return 0 end
    local v = prices[id]
    if v == nil then v = prices[tostring(id)] end
    v = tonumber(v)
    if not v then return 0 end
    return v
end

-- Normalise any id->value table (JSON gives string keys, hand-written Lua gives
-- number keys) into { [number id] = number value }.  Junk entries are skipped.
function M.prices(tbl)
    local out, n = {}, 0
    if type(tbl) == 'table' then
        for k, v in pairs(tbl) do
            local id, val = tonumber(k), tonumber(v)
            if id and val and id > 0 then
                out[floor(id)] = val
                n = n + 1
            end
        end
    end
    return out, n
end

-- Decode a price table from text.  Pure: no file access.  Accepts
--   * JSON            {"3031": 1, "3035": 100}
--   * a Lua table     { [3031] = 1, [3035] = 100 }      (with or without `return`)
-- `decodeJson` may be supplied to avoid the lazy require of lib/json.lua.
function M.decodePrices(text, decodeJson)
    if type(text) ~= 'string' then return nil, 'prices: expected a string' end

    if not decodeJson then
        local ok, json = pcall(require, 'lib.json')
        if ok and type(json) == 'table' and type(json.decode) == 'function' then
            decodeJson = json.decode
        end
    end
    if decodeJson then
        local ok, res = pcall(decodeJson, text)
        if ok and type(res) == 'table' then
            local t, n = M.prices(res)
            if n > 0 then return t, n end
        end
    end

    local src = text
    if not src:match('^%s*return[%s{("\']') then src = 'return ' .. src end
    local chunk, err = loadstring(src, 'prices')
    if not chunk then return nil, 'prices: ' .. tostring(err) end
    if setfenv then setfenv(chunk, {}) end          -- no globals for the chunk
    local ok, res = pcall(chunk)
    if not ok or type(res) ~= 'table' then
        return nil, 'prices: not a table (' .. tostring(res) .. ')'
    end
    local t, n = M.prices(res)
    return t, n
end

-- ===========================================================================
-- the Tibia experience curve (analyzer.lua expLeft())
-- ===========================================================================
-- expForLevel(L) = experience needed to BE level L.  expForLevel(2) == 100,
-- expForLevel(8) == 4200.
function M.expForLevel(level)
    local L = tonumber(level)
    if not L or L < 1 then return nil end
    return floor((50 * L * L * L) / 3 - 100 * L * L + (850 * L) / 3 - 200)
end

-- ===========================================================================
-- the engine
-- ===========================================================================
local Engine = {}
Engine.__index = Engine

local DEFAULTS = {
    window        = 15 * 60 * 1000,   -- sliding window, ms
    minSpanMs     = 60 * 1000,        -- below this measured span a windowed rate is nil
    minSessionMs  = 60 * 1000,        -- ... and the same for the session average
    maxSamples    = 20000,            -- hard per-series cap (memory guard)
}

function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Engine)
    self.windowMs     = tonumber(opts.window) or DEFAULTS.window
    self.minSpanMs    = tonumber(opts.minSpanMs) or DEFAULTS.minSpanMs
    self.minSessionMs = tonumber(opts.minSessionMs) or DEFAULTS.minSessionMs
    self.maxSamples   = tonumber(opts.maxSamples) or DEFAULTS.maxSamples
    if self.windowMs <= 0 then self.windowMs = DEFAULTS.window end
    if self.minSpanMs < 0 then self.minSpanMs = 0 end
    if self.minSessionMs < 0 then self.minSessionMs = 0 end
    if self.maxSamples < 4 then self.maxSamples = 4 end
    self.prices = M.prices(opts.prices)
    self:reset()
    return self
end

function Engine:setPrices(tbl)
    self.prices = M.prices(tbl)
    return self.prices
end

function Engine:itemValue(itemId)
    return M.itemValue(self.prices, itemId)
end

function Engine:reset()
    self.sessionStartMs = nil
    self.lastMs         = nil
    self.outOfOrder     = 0

    -- experience: expRing holds (t, cumulative GAIN) -- monotone by construction
    self.expRing   = ringNew(self.maxSamples)
    self.expLast   = nil          -- last raw experience value seen
    self.expGain   = 0            -- session total gained (never negative)
    self.expLost   = 0            -- session total lost (deaths); diagnostics only
    self.level     = nil
    self.levelPercent = nil
    self.levelStart   = nil

    -- money: ONE ring holding (t, cumLoot, cumWaste) so loot/waste/balance
    -- always share the same baseline sample
    self.moneyRing = ringNew(self.maxSamples)
    self.lootTotal, self.wasteTotal = 0, 0
    self.lootItems, self.wasteItems = {}, {}

    -- gold on hand: (t, gold) -- a gauge, so the rate may legitimately be < 0
    self.goldRing  = ringNew(self.maxSamples)
    self.gold      = nil

    -- kills: (t, cumulative kills)
    self.killRing  = ringNew(self.maxSamples)
    self.kills     = 0
    self.killsByName = {}
    self.deaths    = 0
    self.lastDeathMs = nil
    return self
end

-- sessionStart(ms): begin a new session at `ms`.  This is reset() plus a clock
-- origin, and it seeds every counter series with a zero at `ms` so that "no
-- loot in the last 15 minutes" reads as 0/h rather than "no data".
function Engine:sessionStart(ms)
    ms = tonumber(ms)
    self:reset()
    if ms then
        self.sessionStartMs = ms
        self.lastMs = ms
        self.expRing:push(ms, 0)
        self.moneyRing:push(ms, 0, 0)
        self.killRing:push(ms, 0)
    end
    return self
end

-- Every entry point funnels through here: it starts the session lazily, keeps
-- the clock monotone (a caller that jumps backwards cannot corrupt a span) and
-- returns the timestamp to use.
function Engine:_at(ms)
    ms = tonumber(ms)
    if not ms then return nil end
    if self.sessionStartMs == nil then
        self.sessionStartMs = ms
        self.lastMs = ms
        self.expRing:push(ms, 0)
        self.moneyRing:push(ms, 0, 0)
        self.killRing:push(ms, 0)
    end
    if self.lastMs and ms < self.lastMs then
        self.outOfOrder = self.outOfOrder + 1
        ms = self.lastMs
    end
    self.lastMs = ms
    return ms
end

-- --------------------------------------------------------------- experience
-- `exp` is the player's TOTAL experience (game/state.lua player.exp).
-- A level-up does not move it backwards; a death does.  A falling total
-- contributes ZERO gain (never a negative rate), and the lost amount is kept
-- separately as expLost.  The next real gain is measured from the new, lower
-- total, so the rate recovers immediately instead of waiting to climb back.
function Engine:sampleExperience(ms, exp)
    ms = self:_at(ms); exp = tonumber(exp)
    if not ms or not exp then return self end
    if self.expLast then
        local d = exp - self.expLast
        if d > 0 then
            self.expGain = self.expGain + d
        elseif d < 0 then
            self.expLost = self.expLost - d
        end
    end
    self.expLast = exp
    self.expRing:push(ms, self.expGain)
    self.expRing:trim(ms, self.windowMs)
    return self
end

function Engine:sampleLevel(ms, level, percent)
    ms = self:_at(ms)
    level = tonumber(level)
    if not ms or not level then return self end
    self.level = level
    if self.levelStart == nil then self.levelStart = level end
    local p = tonumber(percent)
    if p then self.levelPercent = max(0, min(100, p)) end
    return self
end

-- --------------------------------------------------------------------- money
function Engine:_pushMoney(ms)
    self.moneyRing:push(ms, self.lootTotal, self.wasteTotal)
    self.moneyRing:trim(ms, self.windowMs)
end

local function bump(tbl, id, count, value)
    local e = tbl[id]
    if e then
        e.count = e.count + count
        e.value = e.value + value
    else
        tbl[id] = { count = count, value = value }
    end
end

-- addLoot(ms, itemId, count, unitValue)
-- unitValue is optional: without it the price table decides, and an unknown
-- item is worth 0 (vBot's rule).
function Engine:addLoot(ms, itemId, count, unitValue)
    ms = self:_at(ms)
    if not ms then return self end
    local id = tonumber(itemId) or 0
    local n = tonumber(count) or 1
    local unit = tonumber(unitValue)
    if not unit then unit = M.itemValue(self.prices, id) end
    local value = n * unit
    self.lootTotal = self.lootTotal + value
    bump(self.lootItems, id, n, value)
    self:_pushMoney(ms)
    return self
end

function Engine:addWaste(ms, itemId, count, unitValue)
    ms = self:_at(ms)
    if not ms then return self end
    local id = tonumber(itemId) or 0
    local n = tonumber(count) or 1
    local unit = tonumber(unitValue)
    if not unit then unit = M.itemValue(self.prices, id) end
    local value = n * unit
    self.wasteTotal = self.wasteTotal + value
    bump(self.wasteItems, id, n, value)
    self:_pushMoney(ms)
    return self
end

-- sampleBalance(ms, goldOnHand): cash actually carried (gold + platinum*100 +
-- crystal*10000, or whatever the caller counts).  A gauge, sampled; the rate is
-- the net change over the window, so buying supplies legitimately drives it
-- negative.
function Engine:sampleBalance(ms, goldOnHand)
    ms = self:_at(ms)
    local g = tonumber(goldOnHand)
    if not ms or not g then return self end
    self.gold = g
    self.goldRing:push(ms, g)
    self.goldRing:trim(ms, self.windowMs)
    return self
end

-- --------------------------------------------------------------- kills/deaths
function Engine:addKill(ms, monsterName)
    ms = self:_at(ms)
    if not ms then return self end
    self.kills = self.kills + 1
    if type(monsterName) == 'string' and monsterName ~= '' then
        local k = monsterName:lower()
        self.killsByName[k] = (self.killsByName[k] or 0) + 1
    end
    self.killRing:push(ms, self.kills)
    self.killRing:trim(ms, self.windowMs)
    return self
end

function Engine:addDeath(ms)
    ms = self:_at(ms)
    if not ms then return self end
    self.deaths = self.deaths + 1
    self.lastDeathMs = ms
    return self
end

-- ------------------------------------------------------------------ rates
-- The right edge of every window is `nowMs` and the current cumulative total,
-- NOT the last sample: 800 gp looted in one second and then nothing for ten
-- minutes must read as ~4.8k gp/h, not 2.8M gp/h.
--
-- The left edge is the retained baseline: the newest sample at or before
-- now-window.  Because every series is a cumulative counter that only moves at
-- a sample, the baseline's value IS the value the counter had at now-window, so
-- the delta is exact and the denominator is the full window.  When the baseline
-- is itself newer than now-window (a young session, or the memory cap dropped
-- the front) we only know the counter from that sample on, and the denominator
-- is the shorter span we actually measured -- which is what makes a
-- partially-filled window report a real rate instead of an extrapolated one.
local function spanOf(ring, nowMs, windowMs)
    if ring.n == 0 then return nil end
    local span = nowMs - ring:tAt(0)
    if span < 0 then span = 0 end
    if span > windowMs then span = windowMs end
    return span
end

local function perHour(delta, spanMs, minSpanMs)
    if not spanMs or spanMs < minSpanMs or spanMs <= 0 then return nil end
    return delta * HOUR_MS / spanMs
end

function Engine:snapshot(ms)
    ms = tonumber(ms) or self.lastMs
    local snap = {
        windowMs   = self.windowMs,
        minSpanMs  = self.minSpanMs,
        kills      = self.kills,
        deaths     = self.deaths,
        killsByName= self.killsByName,
        loot       = self.lootTotal,
        waste      = self.wasteTotal,
        balance    = self.lootTotal - self.wasteTotal,
        lootItems  = self.lootItems,
        wasteItems = self.wasteItems,
        expTotal   = self.expLast,
        expGained  = self.expGain,
        expLost    = self.expLost,
        level      = self.level,
        levelPercent = self.levelPercent,
        levelsGained = (self.level and self.levelStart) and (self.level - self.levelStart) or 0,
        gold       = self.gold,
        outOfOrder = self.outOfOrder,
        sessionMs  = 0,
        samples    = 0,
        spanMs     = {},
    }

    if not ms then
        -- never fed anything: an empty, honest snapshot
        snap.samplesBySeries = { exp = 0, money = 0, gold = 0, kills = 0 }
        snap.samplesDropped  = 0
        return snap
    end
    if self.lastMs and ms < self.lastMs then ms = self.lastMs end

    -- keep the windows tight even when nothing was sampled for a while
    self.expRing:trim(ms, self.windowMs)
    self.moneyRing:trim(ms, self.windowMs)
    self.goldRing:trim(ms, self.windowMs)
    self.killRing:trim(ms, self.windowMs)

    local sessionMs = self.sessionStartMs and max(0, ms - self.sessionStartMs) or 0
    snap.sessionMs     = sessionMs
    snap.sessionSpanMs = sessionMs

    -- experience ------------------------------------------------------------
    local eSpan = spanOf(self.expRing, ms, self.windowMs)
    snap.spanMs.exp = eSpan
    if eSpan then
        snap.expPerHour = perHour(self.expGain - self.expRing:aAt(0), eSpan, self.minSpanMs)
    end
    snap.expPerHourSession = perHour(self.expGain, sessionMs, self.minSessionMs)

    -- level -----------------------------------------------------------------
    if self.level then
        local need = M.expForLevel(self.level + 1)
        if need then
            if self.expLast then
                snap.expToLevel = max(0, need - self.expLast)
            elseif self.levelPercent then
                -- no absolute experience yet: estimate from the progress bar
                local base = M.expForLevel(self.level) or 0
                snap.expToLevel = max(0, floor((need - base) * (1 - self.levelPercent / 100)))
            end
        end
    end
    local expRate = snap.expPerHour or snap.expPerHourSession
    if snap.expToLevel and expRate and expRate > 0 then
        snap.timeToLevelMs = snap.expToLevel * HOUR_MS / expRate
    end

    -- loot / waste / balance -- one baseline, so the three agree exactly ------
    local mSpan = spanOf(self.moneyRing, ms, self.windowMs)
    snap.spanMs.money = mSpan
    if mSpan then
        local l0, w0 = self.moneyRing:aAt(0), self.moneyRing:bAt(0)
        snap.lootPerHour    = perHour(self.lootTotal - l0, mSpan, self.minSpanMs)
        snap.wastePerHour   = perHour(self.wasteTotal - w0, mSpan, self.minSpanMs)
        snap.balancePerHour = perHour((self.lootTotal - l0) - (self.wasteTotal - w0),
                                      mSpan, self.minSpanMs)
    end

    -- money/h: real cash when the caller samples it, else the vBot balance ----
    local gSpan = spanOf(self.goldRing, ms, self.windowMs)
    snap.spanMs.gold = gSpan
    if self.goldRing.n >= 2 and gSpan then
        local d = self.gold - self.goldRing:aAt(0)
        snap.moneyPerHour = perHour(d, gSpan, self.minSpanMs)
        if snap.moneyPerHour then snap.moneySource = 'gold' end
    end
    if snap.moneyPerHour == nil and snap.balancePerHour ~= nil then
        snap.moneyPerHour = snap.balancePerHour
        snap.moneySource  = 'balance'
    end

    -- kills ------------------------------------------------------------------
    local kSpan = spanOf(self.killRing, ms, self.windowMs)
    snap.spanMs.kills = kSpan
    if kSpan then
        snap.killsPerHour = perHour(self.kills - self.killRing:aAt(0), kSpan, self.minSpanMs)
    end

    -- bookkeeping ------------------------------------------------------------
    snap.samplesBySeries = {
        exp   = self.expRing.n,
        money = self.moneyRing.n,
        gold  = self.goldRing.n,
        kills = self.killRing.n,
    }
    snap.samples = self.expRing.n + self.moneyRing.n + self.goldRing.n + self.killRing.n
    snap.samplesDropped = self.expRing.dropped + self.moneyRing.dropped
                        + self.goldRing.dropped + self.killRing.dropped
    return snap
end

-- ===========================================================================
-- the one impure convenience: read a price file from disk.
-- The engine never calls this; the hub/worker does, once, at startup.
-- ===========================================================================
function M.loadPrices(path, decodeJson)
    if type(path) ~= 'string' then return nil, 'loadPrices: path must be a string' end
    local fh, err = io.open(path, 'rb')
    if not fh then return nil, 'loadPrices: ' .. tostring(err) end
    local text = fh:read('*a')
    fh:close()
    if not text then return nil, 'loadPrices: empty read on ' .. path end
    return M.decodePrices(text, decodeJson)
end

M.Ring = nil   -- internal; not part of the contract
return M
