--[[============================================================================
test/statsuite.lua -- offline proof for work item P2 (lib/stats.lua).

  luajit test/statsuite.lua              (from D:/Claude/otclient_web/luaclient)

Every second of every "hunt" below is simulated: the suite owns a fake clock and
hands lib/stats.lua the milliseconds, so an 27-hour run costs milliseconds of
wall time and nothing ever sleeps.  Exits non-zero if any check fails.

  S1  a steady 1,000,000 exp/h run: window rate, session rate, measured span
  S2  a level-up: the rate must not blink, expToLevel/timeToLevel must follow
  S3  a death (experience going DOWN): never negative, never absurd, recovers
  S4  an empty window: nil rates, zero counters, and the seeded 0/h case
  S5  a partially-filled window: the real elapsed span, and nil below minSpanMs
  S6  loot and waste interleaved, prices, unit-value override, unknown item = 0
  S7  money/h from gold on hand, and the loot-minus-waste fallback
  S8  kills/h and deaths
  S9  eviction: 100k samples, bounded memory, bounded retained sample count
  S10 the price table: JSON text, Lua text, a real file, junk
  S11 clock guards: out-of-order timestamps, junk arguments
  S12 reset() and sessionStart()
  S13 the module defines no globals
============================================================================]]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. package.path
end

local stats = require('lib.stats')

-- --------------------------------------------------------------- framework
local pass, fail, msgs = 0, 0, {}
local function check(ok, desc, detail)
    if ok then pass = pass + 1 else
        fail = fail + 1
        local line = '    FAIL  ' .. desc .. (detail and ('  -- ' .. tostring(detail)) or '')
        msgs[#msgs + 1] = line
        io.write(line, '\n')
    end
    return ok
end
local function eq(got, want, desc)
    if got == want then return check(true, desc) end
    return check(false, desc, ('got %s, want %s'):format(tostring(got), tostring(want)))
end
local function near(got, want, tol, desc)
    if type(got) == 'number' and math.abs(got - want) <= tol then return check(true, desc) end
    return check(false, desc, ('got %s, want %s +/- %s'):format(tostring(got), tostring(want), tostring(tol)))
end
local function isNil(got, desc) return eq(got, nil, desc) end
local function head(t) io.write('\n== ', t, ' ==\n') end
local function note(s) io.write('     ', s, '\n') end
local function fmt(v)
    if type(v) ~= 'number' then return tostring(v) end
    return string.format('%.2f', v)
end

-- The fake clock.  Nothing in this file calls os.time/os.clock for logic;
-- os.clock appears once, in S9, purely to report how long 100k samples took.
local BASE = 1234567          -- deliberately not 0: no module may assume t0 == 0

--=============================================================================
head('S1  steady 1,000,000 exp/h for 30 minutes')
do
    local s = stats.new{ window = 15 * 60 * 1000 }
    s:sessionStart(BASE)
    s:sampleLevel(BASE, 100, 0)
    local EXP0 = 4200000
    local perSec = 1000000 / 3600
    local t
    for sec = 1, 30 * 60 do
        t = BASE + sec * 1000
        s:sampleExperience(t, EXP0 + math.floor(sec * perSec))
    end
    local snap = s:snapshot(t)
    near(snap.expPerHour, 1000000, 2000, 'expPerHour is ~1M/h over the window')
    near(snap.expPerHourSession, 1000000, 2000, 'expPerHourSession is ~1M/h')
    eq(snap.spanMs.exp, 15 * 60 * 1000, 'the window span is exactly 15 min once full')
    eq(snap.sessionMs, 30 * 60 * 1000, 'sessionMs is the real session length')
    -- 499,723 exactly: the gain is measured from the FIRST sample, and that
    -- sample already carried one second's worth of experience (277).
    eq(snap.expGained, 499723, 'expGained == 30 min at 1M/h, minus the first sample')
    eq(snap.expTotal, EXP0 + math.floor(30 * 60 * perSec), 'expTotal is the raw value fed in')
    eq(snap.deaths, 0, 'no deaths')
    check(snap.samplesBySeries.exp >= 899 and snap.samplesBySeries.exp <= 903,
          'the exp series retains ~1 window of samples',
          'n=' .. tostring(snap.samplesBySeries.exp))
    note(('exp/h=%s  session=%s  span=%d ms  retained=%d')
         :format(fmt(snap.expPerHour), fmt(snap.expPerHourSession),
                 snap.spanMs.exp, snap.samplesBySeries.exp))

    -- the rate must not depend on WHEN we ask inside a steady run
    local mid = s:snapshot(BASE + 20 * 60 * 1000)
    near(mid.expPerHour, snap.expPerHour, 1500, 'the same steady rate at t+20min')
end

--=============================================================================
head('S2  a level-up mid-window')
do
    eq(stats.expForLevel(2), 100, 'expForLevel(2) == 100 (vBot expLeft formula)')
    eq(stats.expForLevel(8), 4200, 'expForLevel(8) == 4200')
    eq(stats.expForLevel(9), 6400, 'expForLevel(9) == 6400')

    local s = stats.new{ window = 15 * 60 * 1000 }
    s:sessionStart(BASE)
    -- level 20 climbing at 100 exp/s == 360,000 exp/h; level 21 needs 17,200
    -- more, so the first ding lands ~3 minutes in, well past minSpanMs.
    local level = 20
    local exp = stats.expForLevel(level) + 100
    s:sampleLevel(BASE, level, 0)
    local before, after, dingT, t
    for sec = 1, 20 * 60 do
        t = BASE + sec * 1000
        exp = exp + 100
        s:sampleExperience(t, exp)
        while exp >= stats.expForLevel(level + 1) do
            level = level + 1
            if not before then before, dingT = s:snapshot(t), t end
            s:sampleLevel(t, level, 0)
            if not after then after = s:snapshot(t) end
        end
    end
    check(before ~= nil, 'the level-up happened inside the run')
    check(dingT - BASE >= 60000, '   and after the minimum measurable span',
          (dingT - BASE) .. ' ms')
    eq(before.level, 20, 'level 20 before the ding')
    eq(after.level, 21, 'level 21 after the ding')
    eq(after.expPerHour, before.expPerHour,
       'the exp rate does not blink across the level-up')
    -- ~358k, not 360k: the window is only ~3 min old and its first sample
    -- already carried one second of experience.  That is the honest number.
    near(after.expPerHour, 360000, 2500, '   and is the true 360k/h at the ding')
    local snap = s:snapshot(t)
    eq(snap.levelsGained, level - 20, 'levelsGained tracks every ding')
    near(snap.expPerHour, 360000, 700, 'the window rate is the true 360k/h')
    eq(snap.expToLevel, stats.expForLevel(snap.level + 1) - snap.expTotal,
       'expToLevel == expForLevel(level+1) - exp   (analyzer.lua expLeft)')
    near(snap.timeToLevelMs, snap.expToLevel * 3600000 / snap.expPerHour, 1,
         'timeToLevelMs == expToLevel / exp-per-hour')
    note(('level %d (%s%%)  expToLevel=%d  timeToLevel=%.1f min')
         :format(snap.level, tostring(snap.levelPercent), snap.expToLevel,
                 snap.timeToLevelMs / 60000))

    -- percent-only estimate, when no absolute experience was ever sampled
    local p = stats.new{}
    p:sessionStart(BASE)
    p:sampleLevel(BASE, 20, 50)
    local ps = p:snapshot(BASE + 1000)
    eq(ps.expToLevel, math.floor((stats.expForLevel(21) - stats.expForLevel(20)) * 0.5),
       'without an exp sample, expToLevel falls back to the level percentage')
end

--=============================================================================
head('S3  a death: experience goes DOWN')
do
    local s = stats.new{ window = 15 * 60 * 1000 }
    s:sessionStart(BASE)
    local exp = 10000000
    local t = BASE
    local worst = math.huge
    for sec = 1, 10 * 60 do                 -- 10 min at 36k/h
        t = BASE + sec * 1000
        exp = exp + 10
        s:sampleExperience(t, exp)
    end
    local pre = s:snapshot(t)
    near(pre.expPerHour, 36000, 60, 'pre-death rate is 36k/h')

    -- die: the server sends a much lower total experience
    t = t + 1000
    exp = exp - 500000
    s:addDeath(t)
    s:sampleExperience(t, exp)
    local at = s:snapshot(t)
    eq(at.deaths, 1, 'the death is counted')
    check(at.expPerHour >= 0, 'exp/h is not negative at the moment of death',
          fmt(at.expPerHour))
    check(at.expPerHourSession >= 0, 'session exp/h is not negative either',
          fmt(at.expPerHourSession))
    eq(at.expGained, 5990, 'the drop did not subtract from expGained')
    eq(at.expLost, 500000, 'the lost experience is reported separately')

    -- and it keeps working afterwards, measured from the NEW total
    for sec = 1, 10 * 60 do
        t = t + 1000
        exp = exp + 10
        s:sampleExperience(t, exp)
        local sn = s:snapshot(t)
        if sn.expPerHour and sn.expPerHour < worst then worst = sn.expPerHour end
        if sn.expPerHour and sn.expPerHour > 100000 then
            check(false, 'no absurd spike after the death', fmt(sn.expPerHour))
            break
        end
    end
    check(worst >= 0, 'exp/h never went negative anywhere after the death', fmt(worst))
    local post = s:snapshot(t)
    near(post.expPerHour, 36000, 60, 'the rate is back to the true 36k/h ten minutes later')
    eq(post.expGained, 11990, 'expGained counts only real gains')
    note(('at death: exp/h=%s  gained=%d  lost=%d  |  10 min later: exp/h=%s')
         :format(fmt(at.expPerHour), at.expGained, at.expLost, fmt(post.expPerHour)))

    -- a downward sample with no addDeath() (e.g. a relogin on another char)
    local q = stats.new{}
    q:sessionStart(BASE)
    q:sampleExperience(BASE + 1000, 5000000)
    q:sampleExperience(BASE + 2000, 10)
    local qs = q:snapshot(BASE + 120000)
    eq(qs.expGained, 0, 'a bare downward jump yields zero gain')
    eq(qs.expPerHour, 0, '   and a rate of exactly 0, not a negative number')
end

--=============================================================================
head('S4  an empty window')
do
    local s = stats.new{ window = 15 * 60 * 1000 }
    local snap = s:snapshot()
    eq(snap.sessionMs, 0, 'no session yet -> sessionMs 0')
    eq(snap.samples, 0, 'no samples retained')
    isNil(snap.expPerHour, 'expPerHour is nil')
    isNil(snap.expPerHourSession, 'expPerHourSession is nil')
    isNil(snap.lootPerHour, 'lootPerHour is nil')
    isNil(snap.wastePerHour, 'wastePerHour is nil')
    isNil(snap.balancePerHour, 'balancePerHour is nil')
    isNil(snap.moneyPerHour, 'moneyPerHour is nil')
    isNil(snap.moneySource, 'moneySource is nil')
    isNil(snap.killsPerHour, 'killsPerHour is nil')
    isNil(snap.level, 'level is nil')
    isNil(snap.expToLevel, 'expToLevel is nil')
    eq(snap.kills, 0, 'kills 0')
    eq(snap.deaths, 0, 'deaths 0')
    eq(snap.balance, 0, 'balance 0')

    -- a started but idle session: after the minimum span the honest answer is 0/h
    local i = stats.new{ window = 15 * 60 * 1000, minSpanMs = 60000 }
    i:sessionStart(BASE)
    local early = i:snapshot(BASE + 59999)
    isNil(early.lootPerHour, 'below minSpanMs an idle session still reports nil')
    local later = i:snapshot(BASE + 120000)
    eq(later.lootPerHour, 0, 'two minutes of nothing is 0 gp/h, not nil')
    eq(later.wastePerHour, 0, '   waste 0/h')
    eq(later.balancePerHour, 0, '   balance 0/h')
    eq(later.expPerHour, 0, '   exp 0/h')
    eq(later.killsPerHour, 0, '   kills 0/h')
    eq(later.moneySource, 'balance', '   money/h falls back to the balance rate')
end

--=============================================================================
head('S5  a partially-filled window')
do
    local s = stats.new{ window = 15 * 60 * 1000, minSpanMs = 60000 }
    s:sessionStart(BASE)
    -- 1000 gp every 10 s == 360,000 gp/h
    local t
    for i = 1, 18 do
        t = BASE + i * 10000
        s:addLoot(t, 3031, 1000, 1)
    end
    local snap = s:snapshot(t)
    eq(snap.spanMs.money, 180000, 'the span is the 3 minutes we actually measured')
    near(snap.lootPerHour, 360000, 1, 'loot/h uses the measured span, not the 15 min window')
    eq(snap.loot, 18000, 'the raw total is 18k gp')
    note(('3 min into a 15 min window: loot/h=%s over span=%d ms')
         :format(fmt(snap.lootPerHour), snap.spanMs.money))

    -- below the minimum span: nil, never an extrapolation
    local q = stats.new{ window = 15 * 60 * 1000, minSpanMs = 60000 }
    q:sessionStart(BASE)
    q:addLoot(BASE + 3000, 3031, 200, 1)
    local qs = q:snapshot(BASE + 3000)
    isNil(qs.lootPerHour, '200 gp in the first 3 s is nil, not 240k gp/h')
    isNil(qs.expPerHour, '   exp/h likewise')
    isNil(qs.killsPerHour, '   kills/h likewise')
    eq(qs.loot, 200, '   but the raw total is still reported')
    local qs2 = q:snapshot(BASE + 60000)
    near(qs2.lootPerHour, 12000, 1, 'at exactly minSpanMs the rate appears (200 gp/min)')

    -- an old burst must decay out of the window instead of ruling it forever
    local b = stats.new{ window = 15 * 60 * 1000, minSpanMs = 60000 }
    b:sessionStart(BASE)
    b:addLoot(BASE + 1000, 3031, 800, 1)
    near(b:snapshot(BASE + 300000).lootPerHour, 9600, 1,
         'a lone 800 gp burst reads as 9.6k/h five minutes later')
    eq(b:snapshot(BASE + 16 * 60 * 1000).lootPerHour, 0,
       '   and as 0 gp/h once it has left the 15 min window')
end

--=============================================================================
head('S6  loot and waste interleaved')
do
    local prices = stats.prices{ [3031] = 1, [3035] = 100, [3043] = 10000, [268] = 50 }
    eq(stats.itemValue(prices, 3035), 100, 'itemValue reads the table')
    eq(stats.itemValue(prices, 9999), 0, 'an unknown item is worth 0 (vBot getPrice rule)')
    eq(stats.itemValue(nil, 3035), 0, 'no table at all -> 0')

    local s = stats.new{ window = 15 * 60 * 1000, prices = prices }
    s:sessionStart(BASE)
    eq(s:itemValue(3043), 10000, 'the engine exposes itemValue too')

    local t = BASE
    for minute = 1, 10 do
        t = BASE + minute * 60000
        s:addLoot(t, 3031, 100)              -- 100 gold coins  = 100
        s:addLoot(t + 100, 3035, 5)          -- 5 platinum      = 500
        s:addLoot(t + 200, 9999, 3)          -- unknown item    = 0
        s:addWaste(t + 300, 268, 10)         -- 10 mana potions = 500
        s:addWaste(t + 400, 3155, 1, 700)    -- unit override   = 700
    end
    t = t + 400
    local snap = s:snapshot(t)
    eq(snap.loot, 6000, 'loot  == sum(unit price x count) over 10 minutes')
    eq(snap.waste, 12000, 'waste == sum over the used items, override included')
    eq(snap.balance, -6000, 'balance == loot - waste (analyzer.lua bottingStats)')
    eq(snap.lootItems[9999].count, 30, 'the unknown item is still counted')
    eq(snap.lootItems[9999].value, 0, '   but worth 0')
    eq(snap.wasteItems[3155].value, 7000, 'the unit-value override is honoured')

    near(snap.lootPerHour, 6000 * 3600000 / snap.spanMs.money, 1e-6, 'loot/h')
    near(snap.wastePerHour, 12000 * 3600000 / snap.spanMs.money, 1e-6, 'waste/h')
    near(snap.balancePerHour, snap.lootPerHour - snap.wastePerHour, 1e-6,
         'balance/h == loot/h - waste/h exactly (one shared baseline)')
    check(snap.balancePerHour < 0, 'a losing hunt reports a negative balance/h',
          fmt(snap.balancePerHour))
    note(('loot=%d waste=%d balance=%d  ->  %s / %s / %s per hour')
         :format(snap.loot, snap.waste, snap.balance, fmt(snap.lootPerHour),
                 fmt(snap.wastePerHour), fmt(snap.balancePerHour)))

    -- the same numbers, over a full window
    local long = stats.new{ window = 15 * 60 * 1000, prices = prices }
    long:sessionStart(BASE)
    for sec = 1, 60 * 60 do                  -- one hour, 10 gp/s of loot, 4 gp/s of waste
        local tt = BASE + sec * 1000
        long:addLoot(tt, 3031, 10)
        long:addWaste(tt, 3031, 4)
    end
    local ls = long:snapshot(BASE + 3600000)
    eq(ls.spanMs.money, 900000, 'a full window is 15 min once the session is long enough')
    near(ls.lootPerHour, 36000, 40, 'loot/h over the full window')
    near(ls.wastePerHour, 14400, 40, 'waste/h over the full window')
    near(ls.balancePerHour, 21600, 60, 'balance/h over the full window')
    near(ls.balance, 21600, 1, 'the session balance is one hour of it')
end

--=============================================================================
head('S7  money/h')
do
    local s = stats.new{ window = 15 * 60 * 1000 }
    s:sessionStart(BASE)
    -- carrying 10k gp, gaining 100 gp/min for 10 minutes
    local t
    for minute = 0, 10 do
        t = BASE + minute * 60000
        s:sampleBalance(t, 10000 + minute * 100)
    end
    local snap = s:snapshot(t)
    eq(snap.gold, 11000, 'the last gold-on-hand value is reported')
    near(snap.moneyPerHour, 6000, 1, 'money/h from real cash on hand')
    eq(snap.moneySource, 'gold', 'moneySource says where it came from')

    -- a refill: cash falls, money/h may legitimately go negative
    t = t + 60000
    s:sampleBalance(t, 4000)
    local sn = s:snapshot(t)
    check(sn.moneyPerHour < 0, 'spending 7k on supplies drives money/h negative',
          fmt(sn.moneyPerHour))
    note(('gold 10k -> 11k -> 4k gives money/h=%s (%s)')
         :format(fmt(sn.moneyPerHour), sn.moneySource))

    -- no gold samples at all: fall back to the vBot balance rate
    local f = stats.new{ window = 15 * 60 * 1000 }
    f:sessionStart(BASE)
    for minute = 1, 10 do
        f:addLoot(BASE + minute * 60000, 3031, 500, 1)
        f:addWaste(BASE + minute * 60000, 268, 1, 50)
    end
    local fs = f:snapshot(BASE + 600000)
    eq(fs.moneySource, 'balance', 'without cash samples money/h falls back to balance/h')
    eq(fs.moneyPerHour, fs.balancePerHour, '   and equals it exactly')
end

--=============================================================================
head('S8  kills and deaths')
do
    local s = stats.new{ window = 15 * 60 * 1000 }
    s:sessionStart(BASE)
    local t
    for i = 1, 120 do                        -- 120 kills in 10 min == 720/h
        t = BASE + i * 5000
        s:addKill(t, i % 3 == 0 and 'Dragon' or 'Rotworm')
    end
    s:addDeath(t)
    s:addDeath(t + 1)
    local snap = s:snapshot(t)
    eq(snap.kills, 120, 'kills counted')
    eq(snap.killsByName['dragon'], 40, 'per-monster counts (lower-cased)')
    eq(snap.killsByName['rotworm'], 80, '   and the rest')
    near(snap.killsPerHour, 720, 1.5, 'kills/h over the measured span')
    eq(s:snapshot(t + 1).deaths, 2, 'deaths counted')
    note(('120 kills in 10 min -> %s kills/h'):format(fmt(snap.killsPerHour)))

    -- kills age out of the window like everything else
    local far = s:snapshot(t + 40 * 60 * 1000)
    eq(far.killsPerHour, 0, 'forty idle minutes later the rate is 0/h')
    eq(far.kills, 120, '   while the session total stays')
end

--=============================================================================
head('S9  eviction: 100,000 samples')
do
    local N = 100000
    collectgarbage('collect')
    local kb0 = collectgarbage('count')
    local s = stats.new{ window = 15 * 60 * 1000 }
    s:sessionStart(BASE)
    local t0 = os.clock()
    local exp = 0
    for i = 1, N do
        local t = BASE + i * 1000            -- 1 Hz, i.e. 27.8 simulated hours
        exp = exp + 277
        s:sampleExperience(t, exp)
    end
    local elapsed = os.clock() - t0
    local snap = s:snapshot(BASE + N * 1000)
    collectgarbage('collect')
    local kb1 = collectgarbage('count')

    eq(snap.samplesBySeries.exp <= 903, true, 'the exp series never exceeds one window of samples')
    eq(snap.samplesDropped, 0, 'the sliding window evicted everything; the hard cap never fired')
    near(snap.expPerHour, 277 * 3600, 400, 'and the rate is still right after 100k samples')
    check(kb1 - kb0 < 512, 'retained memory stays bounded (< 512 KB)',
          ('%.1f KB'):format(kb1 - kb0))
    note(('100,000 samples in %.3f s (%.2f us/sample); retained %d exp samples, %d total; heap +%.1f KB')
         :format(elapsed, elapsed * 1e6 / N, snap.samplesBySeries.exp, snap.samples, kb1 - kb0))

    -- the pathological caller: a clock that never advances cannot grow the ring
    local p = stats.new{ window = 15 * 60 * 1000, maxSamples = 1000 }
    p:sessionStart(BASE)
    for i = 1, 30000 do p:sampleExperience(BASE, i) end
    local ps = p:snapshot(BASE)
    eq(ps.samplesBySeries.exp, 1000, 'a frozen clock is capped at maxSamples')
    check(ps.samplesDropped >= 29000, 'and the drops are reported', ps.samplesDropped)
    note(('frozen clock: 30,000 pushes -> %d retained, %d dropped')
         :format(ps.samplesBySeries.exp, ps.samplesDropped))

    -- a tiny cap must still be respected (the ring starts smaller than 8)
    local tiny = stats.new{ window = 15 * 60 * 1000, maxSamples = 4 }
    tiny:sessionStart(BASE)
    for i = 1, 50 do tiny:sampleExperience(BASE, i) end
    eq(tiny:snapshot(BASE).samplesBySeries.exp, 4, 'maxSamples = 4 is honoured exactly')

    -- amortised O(1): the second 50k samples must not cost more than the first
    local a = stats.new{ window = 15 * 60 * 1000 }
    a:sessionStart(BASE)
    local half = 50000
    local c0 = os.clock()
    for i = 1, half do a:sampleExperience(BASE + i * 1000, i * 100) end
    local c1 = os.clock()
    for i = half + 1, 2 * half do a:sampleExperience(BASE + i * 1000, i * 100) end
    local c2 = os.clock()
    local first, second = c1 - c0, c2 - c1
    check(second <= math.max(first * 3, 0.05),
          'the cost per sample does not grow with history (amortised O(1))',
          ('first 50k %.3f s, second 50k %.3f s'):format(first, second))
    note(('first 50k %.3f s, second 50k %.3f s'):format(first, second))
end

--=============================================================================
head('S10 the price table')
do
    local j, n = stats.decodePrices('{"3031": 1, "3035": 100, "3043": 10000}')
    eq(type(j), 'table', 'JSON text decodes')
    eq(n, 3, '   three entries')
    eq(j[3035], 100, '   string keys become numbers')

    local l = stats.decodePrices('{ [3031] = 1, [3035] = 100 }')
    eq(type(l) == 'table' and l[3035], 100, 'a plain Lua table literal decodes')
    local r = stats.decodePrices('return { [268] = 50 }')
    eq(type(r) == 'table' and r[268], 50, 'a Lua file with `return` decodes')

    local bad, err = stats.decodePrices('this is not a price table')
    isNil(bad, 'junk text is refused')
    check(type(err) == 'string', '   with an error message', err)
    isNil((stats.decodePrices(nil)), 'a non-string is refused')

    -- a Lua price file cannot reach globals
    local ev = stats.decodePrices('return { [1] = (os and 1 or 2) }')
    eq(type(ev) == 'table' and ev[1], 2, 'the price chunk runs with no globals')

    -- and from a real file, on both platforms
    local dir = (os.getenv('TEMP') or os.getenv('TMP') or os.getenv('TMPDIR') or '/tmp')
                :gsub('\\', '/')
    local path = dir .. '/statsuite_prices.json'
    local fh = io.open(path, 'wb')
    if fh then
        fh:write('{"3031": 1, "3035": 100}\n')
        fh:close()
        local p, cnt = stats.loadPrices(path)
        eq(type(p) == 'table' and p[3031], 1, 'loadPrices reads a JSON file')
        eq(cnt, 2, '   two entries')
        os.remove(path)
        note('price file: ' .. path)
    else
        note('SKIP file test: cannot write to ' .. dir)
    end
    local miss, merr = stats.loadPrices(dir .. '/statsuite_does_not_exist.json')
    isNil(miss, 'a missing price file returns nil, not an error')
    check(type(merr) == 'string', '   with a message', merr)

    -- prices flow into addLoot when no unit value is given
    local s = stats.new{ prices = { ['3035'] = 100 } }     -- string keys accepted
    s:sessionStart(BASE)
    s:addLoot(BASE + 1000, 3035, 7)
    eq(s:snapshot(BASE + 1000).loot, 700, 'the price table drives addLoot')
    s:setPrices{ [3035] = 250 }
    s:addLoot(BASE + 2000, 3035, 2)
    eq(s:snapshot(BASE + 2000).loot, 1200, 'setPrices() changes later valuations only')
end

--=============================================================================
head('S11 clock and argument guards')
do
    local s = stats.new{}
    s:sessionStart(BASE)
    s:sampleExperience(BASE + 10000, 1000)
    s:sampleExperience(BASE + 5000, 2000)             -- backwards!
    local snap = s:snapshot(BASE + 120000)
    eq(snap.outOfOrder, 1, 'a backwards timestamp is counted')
    eq(snap.expGained, 1000, '   and still accounted for at the clamped time')
    check(snap.expPerHour >= 0, '   with a sane rate', fmt(snap.expPerHour))

    local behind = s:snapshot(BASE + 1)                -- snapshot in the past
    eq(behind.sessionMs, 10000, 'a snapshot older than the newest sample clamps to it')
    eq(s:snapshot(BASE + 120000).sessionMs, 120000,
       '   and reading the past does not move the clock for the next read')

    -- junk arguments are ignored, not fatal
    s:sampleExperience(nil, 5)
    s:sampleExperience(BASE + 130000, 'not a number')
    s:addLoot('x', 3031, 1, 1)
    s:addKill(nil, 'Rat')
    s:sampleLevel(BASE + 130000, nil, 50)
    s:sampleBalance(BASE + 130000, nil)
    local ok = s:snapshot(BASE + 130000)
    eq(ok.kills, 0, 'a kill with no timestamp is dropped')
    eq(ok.loot, 0, 'loot with a junk timestamp is dropped')
    eq(ok.expGained, 1000, 'the experience total is untouched by junk')
    isNil(ok.level, 'a junk level is ignored')

    -- count defaults to 1
    local d = stats.new{}
    d:sessionStart(BASE)
    d:addLoot(BASE + 1, 3031, nil, 42)
    eq(d:snapshot(BASE + 1).loot, 42, 'count defaults to 1')
end

--=============================================================================
head('S12 reset() and sessionStart()')
do
    local s = stats.new{ window = 15 * 60 * 1000 }
    s:sessionStart(BASE)
    for i = 1, 600 do
        s:sampleExperience(BASE + i * 1000, i * 100)
        s:addLoot(BASE + i * 1000, 3031, 1, 10)
        s:addKill(BASE + i * 1000, 'Rat')
    end
    local live = s:snapshot(BASE + 600000)
    check(live.expPerHour > 0 and live.loot == 6000 and live.kills == 600,
          'a live session has numbers')

    s:reset()
    local dead = s:snapshot()
    eq(dead.samples, 0, 'reset() drops every sample')
    eq(dead.loot, 0, '   and every total')
    eq(dead.kills, 0, '   and the kill count')
    eq(dead.sessionMs, 0, '   and the session clock')
    isNil(dead.expPerHour, '   and every rate')

    local T2 = BASE + 9000000
    s:sessionStart(T2)
    s:addLoot(T2 + 60000, 3031, 600, 1)
    local fresh = s:snapshot(T2 + 60000)
    eq(fresh.sessionMs, 60000, 'sessionStart() re-anchors the session clock')
    near(fresh.lootPerHour, 36000, 1, '   and the new window measures from there')
    eq(fresh.loot, 600, '   with only the new totals')
end

--=============================================================================
head('S13 no globals')
do
    local created = {}
    setmetatable(_G, { __newindex = function(t, k, v)
        created[#created + 1] = tostring(k); rawset(t, k, v)
    end })
    package.loaded['lib.stats'] = nil
    local fresh = require('lib.stats')          -- re-run the chunk under the guard
    local s = fresh.new{ window = 60000, prices = { [3031] = 1 } }
    s:sessionStart(1)
    s:sampleExperience(2, 10)
    s:sampleLevel(3, 8, 10)
    s:addLoot(4, 3031, 5)
    s:addWaste(5, 268, 1, 50)
    s:addKill(6, 'Rat')
    s:addDeath(7)
    s:sampleBalance(8, 100)
    s:snapshot(9)
    s:reset()
    fresh.decodePrices('{ [1] = 2 }')
    fresh.expForLevel(30)
    setmetatable(_G, nil)
    check(#created == 0, 'lib/stats.lua touches no globals, in any code path',
          table.concat(created, ', '))
end

--=============================================================================
io.write('\n================ stats P2 ================\n')
for _, m in ipairs(msgs) do io.write(m, '\n') end
io.write(('  TOTAL: %d passed, %d failed -> %s\n'):format(pass, fail,
         fail == 0 and 'PASS' or 'FAIL'))
if _G.STATS_P2_NO_EXIT then return { pass = pass, fail = fail, failures = msgs } end
os.exit(fail == 0 and 0 or 1)
