--[[============================================================================
test/bot_f3.lua -- offline proof for work item F3 (bot/init.lua, bot/api.lua,
bot/config.lua).

  luajit test/bot_f3.lua                      (from D:/Claude/otclient_web/luaclient)
  luajit test/bot_f3.lua --profile=<dir>      point at another vBot config dir

Two halves:

  A. CONFIG -- load EVERY file in the user's real vBot_4.8 profile, print a
     summary (healing rules, attack entries, waypoints per cavebot config,
     creature entries per targetbot config) and assert that a save round trip
     (decode -> encode -> decode) preserves unknown fields.

  B. RUNTIME -- macro semantics against a synthetic bot: registration jitter,
     the 50 ms floor, delay() suspending only the current macro, an erroring
     macro not killing the tick, and persisted enable state surviving stop/start.

Nothing here touches the network.  Exits non-zero on any failure.
============================================================================]]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. package.path
end

local config = require('bot.config')
local bot    = require('bot.init')
local sys    = require('lib.sys')

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
local function head(t) io.write('\n== ', t, ' ==\n') end

-- deep compare that understands config.null and ignores table identity
local function deepEq(a, b, path)
    path = path or ''
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then
        return false, ('%s: %s ~= %s'):format(path, tostring(a), tostring(b))
    end
    for k, v in pairs(a) do
        local ok, why = deepEq(v, b[k], path .. '.' .. tostring(k))
        if not ok then return false, why end
    end
    for k in pairs(b) do
        if a[k] == nil then return false, path .. '.' .. tostring(k) .. ': missing in A' end
    end
    return true
end

-- ---------------------------------------------------------------- profile
local PROFILE
for i = 1, #arg do
    local v = tostring(arg[i]):match('^%-%-profile=(.+)$')
    if v then PROFILE = v end
end
if not PROFILE then
    local candidates = {
        'D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
        '/mnt/d/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
    }
    for _, c in ipairs(candidates) do
        if config.fileExists(c .. '/_Loader.lua') then PROFILE = c; break end
    end
end

io.write('bot F3 selftest -- profile: ', tostring(PROFILE), '\n')

--=============================================================================
head('A0. codec unit checks (no I/O)')
--=============================================================================
do
    -- JSON: order + empty-shape preservation, rxi-identical number/string format
    local src = '{"b":1,"a":[],"c":{},"d":"x\\ny","e":0.010135135135135,"f":true}'
    local v, err = config.jsonDecode(src)
    check(v ~= nil, 'jsonDecode of a mixed object', err)
    eq(config.jsonEncode(v), src, 'jsonEncode reproduces the source byte for byte')
    eq(v.d, 'x\ny', 'string escapes decode')
    eq(config.jsonEncode({}), '[]', 'a fresh empty table encodes as [] (rxi rule)')
    eq(config.jsonEncode(config.markObject({}, {})), '{}', 'a marked empty object encodes as {}')
    eq(config.jsonEncode({ 1, 2, 3 }), '[1,2,3]', 'array encoding')
    eq(config.jsonEncode(1 / 3), '0.33333333333333', 'numbers use %.14g like rxi')

    -- .cfg: key rules, dropped empty values, multiline
    local cfg = 'goto:1,2,3\nstand:\n:novalue\nfunction:[[\nA\nB\n]]\ntail:x\n'
    local prs = config.decodeCfg(cfg)
    eq(#prs, 3, 'decodeCfg drops the empty-valued and empty-keyed pairs')
    eq(prs[1][1] .. '=' .. prs[1][2], 'goto=1,2,3', 'first pair')
    eq(prs[2][1] .. '=' .. prs[2][2], 'function=A\nB', 'multiline body, single-spaced')
    eq(prs[3][1], 'tail', 'a pair after the multiline block is still seen')
    eq(config.encodeCfg(prs), 'goto:1,2,3\nfunction:[[\nA\nB\n]]\ntail:x\n',
       'encodeCfg round-trips the surviving pairs')
    -- the 20-char key cap and the forbidden characters
    local long = config.decodeCfg('abcdefghijklmnopqrstuvwxyz:v\n')
    eq(long[1][1], 'abcdefghijklmnopqrst', 'a key is capped at 20 characters')
    eq(long[1][2], 'uvwxyz:v', 'the overflow lands in the value')
    -- vbotCompat reproduces the upstream newline growth
    local grown = config.decodeCfg('f:[[\nA\nB\n]]\n', { vbotCompat = true })
    eq(grown[1][2], 'A\n\nB\n', 'vbotCompat=true reproduces the upstream newline growth')
end

--=============================================================================
head('A1. the user\'s real vBot_4.8 profile')
--=============================================================================
local prof
if not PROFILE then
    check(false, 'reference profile found', 'no vBot_4.8 directory on this machine')
else
    prof = config.new{ profileDir = PROFILE, vprofile = 1 }

    -- ---- HealBot.json ------------------------------------------------------
    local hb = prof:loadHealBot()
    check(type(hb) == 'table', 'HealBot.json loaded')
    if type(hb) == 'table' then
        local totalSpells, totalItems = 0, 0
        io.write(('  HealBot.json          : %d profiles, current = %s\n')
                 :format(#(hb.healbot or {}), tostring(hb.currentHealBotProfile)))
        for i, p in ipairs(hb.healbot or {}) do
            local sp, it = #(p.spellTable or {}), #(p.itemTable or {})
            totalSpells, totalItems = totalSpells + sp, totalItems + it
            if sp + it > 0 or p.enabled then
                io.write(('    [%d] %-12s enabled=%-5s spells=%d items=%d\n')
                         :format(i, tostring(p.name), tostring(p.enabled), sp, it))
            end
        end
        io.write(('    healing rules total : %d (%d spell, %d item)\n')
                 :format(totalSpells + totalItems, totalSpells, totalItems))
        local cp = hb.ConditionPanel
        io.write(('    ConditionPanel      : %s (%d keys)\n'):format(
                 cp and 'present' or 'MISSING',
                 (function() local n = 0; for _ in pairs(cp or {}) do n = n + 1 end; return n end)()))
        check(totalSpells + totalItems > 0, 'HealBot.json has at least one healing rule')
        check(cp ~= nil and cp.hasteSpell ~= nil, 'ConditionPanel decoded (hasteSpell present)')
    end

    -- ---- AttackBot.json ----------------------------------------------------
    local ab = prof:loadAttackBot()
    check(type(ab) == 'table', 'AttackBot.json loaded')
    if type(ab) == 'table' then
        local total = 0
        io.write(('  AttackBot.json        : %d profiles, current = %s\n')
                 :format(#(ab.AttackBot or {}), tostring(ab.currentBotProfile)))
        for i, p in ipairs(ab.AttackBot or {}) do
            local n = #(p.attackTable or {})
            total = total + n
            if n > 0 then io.write(('    [%d] attack entries = %d\n'):format(i, n)) end
        end
        io.write(('    attack entries total: %d\n'):format(total))
        check(total > 0, 'AttackBot.json has at least one attack entry')
        -- the real file mixes types in one field ("monsters": true vs a list)
        local first = ab.AttackBot and ab.AttackBot[1] and ab.AttackBot[1].attackTable
                      and ab.AttackBot[1].attackTable[1]
        check(first ~= nil and first.spell ~= nil, 'first attack entry carries a spell')
    end

    -- ---- Supplies.json -----------------------------------------------------
    local sup = prof:loadSupplies()
    check(type(sup) == 'table' and type(sup.supplies) == 'table', 'Supplies.json loaded')
    if sup and sup.supplies then
        local cur = sup.supplies.currentProfile
        local p   = sup.supplies[cur]
        local n = 0; for _ in pairs((p or {}).items or {}) do n = n + 1 end
        io.write(('  Supplies.json         : current = %s, %d supply items\n')
                 :format(tostring(cur), n))
        check(n > 0, 'Supplies.json has supply thresholds')
    end

    -- ---- storage/profile_1.json -------------------------------------------
    local storage, serr = prof:loadStorage()
    check(type(storage) == 'table', 'storage/profile_1.json loaded', serr)
    if type(storage) == 'table' then
        local keys = 0; for _ in pairs(storage) do keys = keys + 1 end
        local macros = 0; for _ in pairs(storage._macros or {}) do macros = macros + 1 end
        io.write(('  storage/profile_1.json: %d top-level keys, %d persisted macro flags\n')
                 :format(keys, macros))
        for dir, v in pairs(storage._configs or {}) do
            io.write(('    _configs[%-18s] enabled=%-5s selected=%s\n')
                     :format(dir, tostring(v.enabled), tostring(v.selected)))
        end
        eq(keys, 33, 'storage has the 33 documented top-level keys')
        check(storage._macros and storage._macros[''] == false,
              'the unnamed-macro key "" is present and false (bot-core §1.1)')
    end

    -- ---- cavebot_configs/*.cfg --------------------------------------------
    local cbs = prof:listCavebots()
    io.write(('  cavebot_configs       : %d files\n'):format(#cbs))
    check(#cbs > 0, 'cavebot configs found')
    local wpTypes = {}
    for _, name in ipairs(cbs) do
        local cb, cerr = prof:loadCavebot(name)
        if not check(cb ~= nil, 'loadCavebot ' .. name, cerr) then break end
        local stay = 0; for _ in pairs(cb.staypositions or {}) do stay = stay + 1 end
        io.write(('    %-20s waypoints=%3d  config=%-5s ext=%-5s stayPos=%d\n')
                 :format(name, #cb.waypoints, tostring(cb.config ~= nil),
                         tostring(cb.extensions ~= nil), stay))
        for _, w in ipairs(cb.waypoints) do wpTypes[w.action] = (wpTypes[w.action] or 0) + 1 end
    end
    local tnames = {}
    for k in pairs(wpTypes) do tnames[#tnames + 1] = k end
    table.sort(tnames)
    local parts = {}
    for _, k in ipairs(tnames) do parts[#parts + 1] = k .. '=' .. wpTypes[k] end
    io.write('    waypoint types      : ', table.concat(parts, ' '), '\n')

    -- ---- targetbot_configs/*.json -----------------------------------------
    local tbs = prof:listTargetbots()
    io.write(('  targetbot_configs     : %d files\n'):format(#tbs))
    check(#tbs > 0, 'targetbot configs found')
    for _, name in ipairs(tbs) do
        local tb = prof:loadTargetbot(name)
        local loot = (type(tb) == 'table') and tb.looting or nil
        io.write(('    %-20s creatures=%2d  lootItems=%2d lootContainers=%d\n')
                 :format(name, (type(tb) == 'table' and #(tb.targeting or {})) or 0,
                         loot and #(loot.items or {}) or 0,
                         loot and #(loot.containers or {}) or 0))
    end
    -- true_asuras.json is literally "[]" (2 bytes) on disk.  It must decode to a
    -- table (not nil) and re-encode as "[]", not "{}": the array/object shape of
    -- an EMPTY container is exactly what rxi's encoder throws away.
    local empty = prof:loadTargetbot('true_asuras')
    check(type(empty) == 'table', 'the 2-byte targetbot config decodes to a table')
    eq(config.jsonEncode(empty), '[]', 'the empty-array shape survives re-encoding')
end

--=============================================================================
head('A2. round trip: decode -> encode -> decode preserves unknown fields')
--=============================================================================
if prof then
    local jsonFiles = {
        { prof:healBotPath(),   'HealBot.json' },
        { prof:attackBotPath(), 'AttackBot.json' },
        { prof:suppliesPath(),  'Supplies.json' },
        { prof:storagePath(),   'storage/profile_1.json' },
    }
    for _, name in ipairs(prof:listTargetbots()) do
        jsonFiles[#jsonFiles + 1] = { prof:path('targetbot_configs', name .. '.json'),
                                      'targetbot_configs/' .. name .. '.json' }
    end

    local byteExact, total = 0, 0
    for _, f in ipairs(jsonFiles) do
        local text = config.readFile(f[1])
        if text then
            total = total + 1
            local v1, e1 = config.jsonDecode(text)
            if check(v1 ~= nil, 'decode ' .. f[2], e1) then
                local enc, e2 = config.jsonEncode(v1)
                if check(enc ~= nil, 'encode ' .. f[2], e2) then
                    local v2, e3 = config.jsonDecode(enc)
                    if check(v2 ~= nil, 're-decode ' .. f[2], e3) then
                        local same, why = deepEq(v1, v2)
                        check(same, 'round trip preserves every field of ' .. f[2], why)
                    end
                    if enc == text then byteExact = byteExact + 1 end
                end
            end
        end
    end
    io.write(('  json files round-tripped: %d/%d, byte-identical re-encode: %d\n')
             :format(total, #jsonFiles, byteExact))
    eq(byteExact, total, 'every real json config re-encodes byte for byte')

    -- unknown fields explicitly: inject a key nothing knows about and prove it survives
    local tb = prof:loadTargetbot('def_target')
    if type(tb) == 'table' then
        tb.__unknownFutureField = { keepMe = true, n = 7 }
        local enc = config.jsonEncode(tb)
        local back = config.jsonDecode(enc)
        check(back and back.__unknownFutureField and back.__unknownFutureField.keepMe == true,
              'an unknown nested field survives a save/load cycle')
        check(back and back.targeting and back.targeting[1] and
              back.targeting[1].closeLureAmount == 3,
              'known neighbours are untouched by the unknown field')
    end

    -- .cfg round trip
    local cfgExact, cfgTotal, grew = 0, 0, {}
    for _, name in ipairs(prof:listCavebots()) do
        local text = config.readFile(prof:path('cavebot_configs', name .. '.cfg'))
        if text then
            cfgTotal = cfgTotal + 1
            local prs = config.decodeCfg(text)
            local enc = config.encodeCfg(prs)
            local prs2 = config.decodeCfg(enc)
            check(deepEq(prs, prs2), 'cfg decode is idempotent for ' .. name)
            if enc == text then cfgExact = cfgExact + 1 else grew[#grew + 1] = name end
        end
    end
    io.write(('  cfg files round-tripped : %d, byte-identical re-encode: %d\n')
             :format(cfgTotal, cfgExact))
    if #grew > 0 then io.write('    not byte-identical: ', table.concat(grew, ' '), '\n') end
    eq(cfgExact, cfgTotal, 'every real cavebot .cfg re-encodes byte for byte')

    -- writing: save a cavebot config to a scratch name and read it back
    local scratch = '__f3_roundtrip__'
    local src = prof:loadCavebot(prof:listCavebots()[1])
    if src then
        local ok, werr = prof:saveCavebotRaw(scratch, src.pairs)
        check(ok, 'saveCavebotRaw writes a file', werr)
        local back = prof:loadCavebot(scratch)
        check(back and deepEq(src.pairs, back.pairs), 'the written cfg reloads identically')
        os.remove(prof:path('cavebot_configs', scratch .. '.cfg'))
        check(not config.fileExists(prof:path('cavebot_configs', scratch .. '.cfg')),
              'scratch cfg removed')
    end
end

--=============================================================================
head('B. macro semantics')
--=============================================================================
-- A synthetic client: no sockets, no scheduler (we drive tick() by hand so the
-- test is deterministic), a fake state and a capturing sender.
local logLines = {}
local function fakeLog(level)
    return function(fmt, ...)
        local ok, s = pcall(string.format, tostring(fmt), ...)
        logLines[#logLines + 1] = level .. ' ' .. (ok and s or tostring(fmt))
    end
end

local sentPackets = {}
local fakeSender = setmetatable({}, { __index = function(_, k)
    return function(_, ...)
        sentPackets[#sentPackets + 1] = { k, ... }
        return 'ok'
    end
end })

-- A controllable frame clock: bot.new(..., {clock=}) makes every time comparison
-- in the runtime deterministic, so these assertions do not race the wall clock.
local FAKE = { t = 1000000 }
local function fakeClock() return FAKE.t end
local function advance(ms) FAKE.t = FAKE.t + ms end

local function newClient()
    return {
        log   = { info = fakeLog('I'), warn = fakeLog('W'), error = fakeLog('E'),
                  debug = fakeLog('D') },
        sched = nil,           -- we call b:tick() ourselves
        state = { player = { id = 1, name = 'Tester', pos = { x = 100, y = 100, z = 7 },
                             health = 500, maxHealth = 1000, mana = 200, maxMana = 400,
                             level = 100, capacity = 900, states = 0, inventory = {},
                             preWalks = {}, walkLockUntil = 0 },
                  creatures = {}, containers = {}, channels = {},
                  tile = function() return nil end, isAwareOf = function() return true end },
        sender = fakeSender,
        -- shaped like _G.LC.events (the module singleton: dot-called), which is
        -- what main.lua wires in.  bot/api.lua also accepts a lib/events Bus
        -- instance (colon-called); both paths are supported.
        events = (function()
            local bus = require('lib.events').new()
            return { bus = bus,
                     on   = function(n, f) return bus:on(n, f) end,
                     off  = function(h)    return bus:off(h) end,
                     emit = function(n, d) return bus:emit(n, d) end }
        end)(),
    }
end

-- B1 -- the 50 ms floor and the registration jitter -------------------------
do
    local b = bot.new(newClient(), {})
    local t0 = b.now
    local m20  = b:macro(20, 'twenty', function() end)
    local m500 = b:macro(500, 'fivehundred', function() end)
    local anon = b:macro(1000, function() end)
    eq(m20.timeout, 50, 'macro(20, ...) is clamped up to the 50 ms floor')
    eq(m500.timeout, 500, 'a timeout above the floor is untouched')
    check(m20.lastExecution >= t0 and m20.lastExecution <= t0 + 100,
          'lastExecution carries a 0..100 ms registration jitter',
          m20.lastExecution - t0)
    check(anon.enabled == true, 'an unnamed macro is enabled unconditionally')
    check(m20.enabled == false, 'a named macro starts disabled without stored state')

    local jitters, distinct = {}, {}
    for i = 1, 40 do
        local m = b:macro(50, 'j' .. i, function() end)
        jitters[i] = m.lastExecution - b.now
        distinct[jitters[i]] = true
    end
    local n = 0; for _ in pairs(distinct) do n = n + 1 end
    check(n > 5, 'the jitter actually de-synchronises macros registered together',
          'distinct offsets: ' .. n)

    local okRaise = pcall(function() b:macro(0, 'zero', function() end) end)
    check(not okRaise, 'macro(0, ...) raises (timeout must be >= 1)')
    local okRaise2 = pcall(function() b:macro(100, 'nofn') end)
    check(not okRaise2, 'macro without a callback raises')
end

-- B2 -- the period is measured from the start of the last successful run ----
do
    local b = bot.new(newClient(), { clock = fakeClock })
    local runs = 0
    local m = b:macro(100, 'period', function() runs = runs + 1 end)
    m.setOn()
    m.lastExecution = FAKE.t - 100         -- drop the jitter, make it due now
    b:tick(); eq(runs, 1, 'a due macro runs')
    b:tick(); eq(runs, 1, 'it does not run again inside its period')
    advance(99)
    b:tick(); eq(runs, 1, 'still inside the period one ms early')
    advance(2)
    b:tick(); eq(runs, 2, 'it runs again once the period has elapsed')
    eq(m.lastExecution, FAKE.t,
       'the period is measured from the START of the last successful run')
end

-- B3 -- delay() suspends ONLY the currently executing macro -----------------
do
    local b = bot.new(newClient(), { clock = fakeClock })
    local aRuns, bRuns = 0, 0
    local ma = b:macro(50, 'A', function() aRuns = aRuns + 1; b:delay(500) end)
    local mb = b:macro(50, 'B', function() bRuns = bRuns + 1 end)
    ma.setOn(); mb.setOn()
    ma.lastExecution, mb.lastExecution = FAKE.t - 50, FAKE.t - 50

    b:tick()
    eq(aRuns, 1, 'A ran once')
    eq(bRuns, 1, 'B ran once')
    check(b:isDelayed(ma), 'A is delayed after calling delay(500)')
    check(not b:isDelayed(mb), 'B is NOT delayed -- delay() targets only the caller')

    -- while delayed, lastExecution must NOT advance (bot-core §1.3)
    local lastA = ma.lastExecution
    for _ = 1, 5 do advance(60); b:tick() end
    eq(aRuns, 1, 'A stays suspended across ticks')
    check(bRuns >= 2, 'B keeps running while A is suspended', bRuns)
    eq(ma.lastExecution, lastA, 'a delayed macro does not advance lastExecution')

    -- once the delay expires it fires on the very next tick, with no extra wait
    ma.delay = FAKE.t - 1
    b:tick()
    eq(aRuns, 2, 'A resumes the instant its delay expires')

    -- delay() outside any execution only LOGS (main.lua:206-211)
    local before = #logLines
    b:delay(100)
    check(#logLines > before and logLines[#logLines]:find('Invalid usage of delay'),
          'delay() outside a callback logs an error instead of raising')

    -- ... including from inside a schedule() body, where _currentExecution is nil
    local sawError = false
    b:schedule(0, function()
        local n0 = #logLines
        b:delay(100)
        sawError = #logLines > n0 and logLines[#logLines]:find('Invalid usage of delay') ~= nil
    end)
    b:tick()
    check(sawError, 'delay() from a schedule body logs, and delays nothing stale')
end

-- B4 -- an erroring macro does not kill the tick ----------------------------
do
    local b = bot.new(newClient(), { clock = fakeClock })
    local good, bad = 0, 0
    local mBad = b:macro(50, 'boom', function() bad = bad + 1; error('kaboom') end)
    local mGood = b:macro(50, 'fine', function() good = good + 1 end)
    mBad.setOn(); mGood.setOn()
    mBad.lastExecution, mGood.lastExecution = FAKE.t - 50, FAKE.t - 50

    local before = #logLines
    b:tick()
    eq(bad, 1, 'the throwing macro ran')
    eq(good, 1, 'the macro registered AFTER it still ran in the same tick')
    check(#logLines > before, 'the error was logged')
    local found = false
    for i = before + 1, #logLines do
        if logLines[i]:find('Macro: boom execution error') then found = true end
    end
    check(found, 'the log line matches vBot\'s "Macro: <name> execution error"')
    check(b.stats.macroErrors == 1, 'the error is counted')
    -- lastExecution is NOT advanced -> it throws again on the very next tick
    advance(1)
    b:tick()
    eq(bad, 2, 'an erroring macro retries on the next tick (lastExecution not advanced)')
    check(b._currentExecution == nil,
          '_currentExecution is reset even when the body threw (deviation 3)')

    -- the whole tick still completes and the bot is usable
    local m3 = b:macro(50, 'after', function() good = good + 1 end)
    m3.setOn(); m3.lastExecution = FAKE.t - 50
    advance(60)
    b:tick()
    check(good >= 3, 'macros registered after the failure still run', good)
end

-- B5 -- the scheduler queue --------------------------------------------------
do
    local b = bot.new(newClient(), { clock = fakeClock })
    local order = {}
    b:schedule(30, function() order[#order + 1] = 'c30' end)
    b:schedule(10, function() order[#order + 1] = 'a10' end)
    b:schedule(10, function() order[#order + 1] = 'b10' end)
    advance(1000)                            -- everything is due
    b:tick()
    eq(table.concat(order, ','), 'a10,b10,c30',
       'the queue drains in time order, ties FIFO (deviation 2)')

    -- a throwing entry is removed and the rest still fire
    order = {}
    b:schedule(0, function() error('sched boom') end)
    b:schedule(0, function() order[#order + 1] = 'survivor' end)
    advance(100)
    local before = #logLines
    b:tick()
    eq(table.concat(order, ','), 'survivor', 'a failing scheduled callback does not stop the rest')
    local found = false
    for i = before + 1, #logLines do
        if logLines[i]:find('Schedule execution error') then found = true end
    end
    check(found, 'the scheduler error is logged')
    eq(#b._scheduler, 0, 'both entries were removed')

    -- a delay-0 self-rescheduling callback cannot spin forever (deviation 1)
    local n = 0
    local function again() n = n + 1; b:schedule(0, again) end
    b:schedule(0, again)
    advance(10)
    b:tick()
    check(n > 0 and n <= 1000, 'a self-rescheduling delay-0 callback is capped, not infinite', n)
    b._scheduler = {}
end

-- B6 -- persisted enable state survives a stop/start (and a new instance) ----
do
    local tmpdir = (os.getenv('TEMP') or os.getenv('TMPDIR') or '/tmp')
                   :gsub('\\', '/') .. '/luaclient_f3_' .. tostring(os.time())
    config.mkdirp(tmpdir .. '/storage')

    local c1 = newClient()
    local b1 = bot.new(c1, { profileDir = tmpdir, vprofile = 1, storageSaveMs = 0 })
    local m1 = b1:macro(100, 'Hold Target', function() end)
    local m2 = b1:macro(100, 'Exchange money', function() end)
    eq(m1.enabled, false, 'a fresh named macro starts off')
    m1.setOn()
    m2.setOn(); m2.setOff()
    b1:stop()                                 -- stop() saves storage
    check(config.fileExists(tmpdir .. '/storage/profile_1.json'),
          'stop() wrote storage/profile_1.json')

    -- same instance: start() again, re-register -> restored
    b1:start()
    local m1b = b1:macro(100, 'Hold Target', function() end)
    eq(m1b.enabled, true, 'the persisted ON flag is restored on re-registration')
    b1:stop()

    -- a brand new bot reading the same file
    local b2 = bot.new(newClient(), { profileDir = tmpdir, vprofile = 1, storageSaveMs = 0 })
    eq(b2.storage._macros['Hold Target'], true, 'the flag is on disk')
    eq(b2.storage._macros['Exchange money'], false, 'setOff persists as false')
    local n1 = b2:macro(100, 'Hold Target', function() end)
    local n2 = b2:macro(100, 'Exchange money', function() end)
    local n3 = b2:macro(100, 'Never Seen', function() end)
    local n4 = b2:macro(100, function() end)
    eq(n1.enabled, true,  'ON  survives a stop/start into a new instance')
    eq(n2.enabled, false, 'OFF survives (only `== true` restores)')
    eq(n3.enabled, false, 'an unknown name defaults to off')
    eq(n4.enabled, true,  'the unnamed macro is forced on regardless of storage')
    eq(b2.storage._macros[''], nil, 'the unnamed macro has not written its key yet')
    n4.setOff()
    eq(b2.storage._macros[''], false, 'setOff on an unnamed macro writes the "" key')

    -- storage survives a save/load with unknown keys intact
    b2.storage.someModuleData = { a = 1, list = { 'x', 'y' } }
    b2:saveStorage()
    local b3 = bot.new(newClient(), { profileDir = tmpdir, vprofile = 1, storageSaveMs = 0 })
    check(b3.storage.someModuleData and b3.storage.someModuleData.a == 1 and
          b3.storage.someModuleData.list[2] == 'y',
          'module-defined storage keys survive the save/load cycle')

    os.remove(tmpdir .. '/storage/profile_1.json')
end

-- B7 -- arbitration -----------------------------------------------------------
do
    local b = bot.new(newClient(), {})
    check(b:isActionAllowed('healbot'), 'healing never yields')
    check(b:isActionAllowed('cavebot'), 'cavebot runs when there is no targetbot')

    local tbActive, tbAllow, tbOn = false, false, true
    b:registerModule('targetbot', {
        isOn = function() return tbOn end,
        isActive = function() return tbActive end,
        isCaveBotActionAllowed = function() return tbAllow end,
    })
    check(b:isActionAllowed('cavebot'), 'idle targetbot does not suspend cavebot')
    tbActive = true
    check(not b:isActionAllowed('cavebot'),
          'an active targetbot suspends cavebot (cavebot.lua:81)')
    tbAllow = true
    check(b:isActionAllowed('cavebot'),
          'allowCaveBot() re-opens the window even while targetbot is active')
    tbAllow, tbOn = false, false
    check(b:isActionAllowed('cavebot'), 'a disabled targetbot never suspends cavebot')
    check(b:isActionAllowed('targetbot') and b:isActionAllowed('attackbot'),
          'targetbot and attackbot are always allowed')
end

-- B8 -- the tick loop under lib/sched ----------------------------------------
do
    local sched = require('lib.sched')
    sched.reset()
    local c = newClient()
    c.sched = sched
    local b = bot.new(c, { tickMs = 10, storageSaveMs = 0 })
    local runs = 0
    local m = b:macro(50, 'ticker', function() runs = runs + 1 end)
    m.setOn(); m.lastExecution = 0
    b:start()
    check(b:isOn(), 'b:isOn() after start')
    local t0 = sys.nowMs()
    while sys.nowMs() - t0 < 260 do sched.tick(5) end
    b:stop()
    check(not b:isOn(), 'b:isOn() is false after stop')
    -- 260 ms at a 50 ms period => 4..7 runs (jitter + timer granularity)
    check(runs >= 4 and runs <= 8, 'a 50 ms macro fires ~5x in 260 ms of real ticks', runs)
    check(b.stats.ticks >= 20, 'the 10 ms tick actually ran', b.stats.ticks)
    sched.reset()
end

-- B9 -- the script surface ----------------------------------------------------
do
    local c = newClient()
    local b = bot.new(c, { clock = fakeClock })
    local a = b.api
    local NAMES = {
        'say','yell','talkNpc','talkPrivate','use','useWith','useOnCreature','usePos',
        'moveItem','findItem','findItemCount','itemAmount','getSpectators',
        'getCreatureById','getPlayer','pos','hp','hpPercent','mana','manaPercent',
        'level','cap','delay','schedule','macro','walk','turn','stopWalk','attack',
        'follow','cancelAttack','canCast','castSpell','isInPz','isDead','isWalking',
        'distanceFromPlayer','getMonsters','getPlayers','getNpcs','openContainer',
        'closeContainer','getContainers','getBackpacks','depositItems','withdrawItems',
    }
    local missing = {}
    for _, n in ipairs(NAMES) do
        if type(a[n]) ~= 'function' then missing[#missing + 1] = n end
    end
    eq(#missing, 0, 'every BOT.md api name exists as a function',
       table.concat(missing, ' '))
    check(type(a.storage) == 'table', 'api.storage is the bot storage table')
    check(a.storage == b.storage, 'api.storage is the same table as bot.storage')
    check(type(a.now) == 'number', 'api.now reads as a live number (vBot scripts do now - x)')
    advance(1234); b:tick()
    eq(a.now, b.now, 'api.now tracks the per-tick clock')

    eq(a.hp(), 500, 'hp()')
    eq(a.hpPercent(), 50, 'hpPercent()')
    eq(a.mana(), 200, 'mana()')
    eq(a.manaPercent(), 50, 'manaPercent()')
    eq(a.level(), 100, 'level()')
    eq(a.cap(), 900, 'cap()')
    eq(a.pos().x, 100, 'pos()')
    eq(a.isInPz(), false, 'isInPz() with states = 0')
    c.state.player.states = 16384 + 128
    eq(a.isInPz(), true, 'isInPz() reads PlayerStates.Pz')
    eq(a.isInFight(), true, 'isInFight() reads the Swords bit')
    eq(a.canLogout(), false, 'canLogout() is the NEGATION of Swords (VERIFIER)')
    c.state.player.states = 0
    eq(a.isDead(), false, 'isDead()')
    eq(a.distanceFromPlayer({ x = 105, y = 102, z = 7 }), 5, 'distanceFromPlayer is Chebyshev')

    -- manapercent guard for knights
    c.state.player.maxMana = 1
    eq(a.manaPercent(), 100, 'manaPercent() returns 100 when maxMana <= 1 (player.lua:8-15)')
    c.state.player.maxMana = 400

    -- packets
    sentPackets = {}
    a.say('exura gran')
    eq(sentPackets[1][1], 'talk', 'say() goes out as a talk packet')
    eq(sentPackets[1][2], 1, 'say() uses MessageSay (1)')
    eq(sentPackets[1][5], 'exura gran', 'say() carries the text')
    a.yell('hi');        eq(sentPackets[2][2], 3, 'yell() uses MessageYell (3)')
    a.talkNpc('hi');     eq(sentPackets[3][2], 11, 'talkNpc() uses MessageNpcTo (11)')
    a.talkPrivate('Bob', 'hi')
    eq(sentPackets[4][2], 5, 'talkPrivate() uses MessagePrivateTo (5)')
    eq(sentPackets[4][4], 'Bob', 'talkPrivate() carries the receiver')
    a.use(3031)
    eq(sentPackets[5][1], 'use', 'use(id) sends a use packet')
    eq(sentPackets[5][2].x, 0xFFFF, 'use(id) targets the inventory pseudo-position')
    a.walk(1);   eq(sentPackets[6][1], 'walk', 'walk()')
    a.turn(2);   eq(sentPackets[7][1], 'turn', 'turn()')
    a.attack({ id = 42 }); eq(sentPackets[8][2], 42, 'attack(creature)')
    a.cancelAttack();      eq(sentPackets[9][1], 'cancelAttackAndFollow', 'cancelAttack()')

    -- findItem / itemAmount over inventory + containers
    c.state.player.inventory[6] = { kind = 'item', id = 3031, count = 55 }
    c.state.containers[0] = { id = 0, name = 'Backpack', firstIndex = 0, items = {
        { kind = 'item', id = 3031, count = 100 },
        { kind = 'item', id = 23374, count = 5 },
        { kind = 'item', id = 23374, count = 5, tier = 2 },
    } }
    local found = a.findItem(3031)
    check(found ~= nil and found.id == 3031, 'findItem finds an equipped item first')
    eq(found.slot, 6, 'the equipped hit reports its inventory slot')
    eq(a.itemAmount(3031), 155, 'itemAmount sums equipment and containers')
    eq(a.itemAmount(23374), 10, 'itemAmount counts both container stacks')
    local tiered = a.findItem(23374, -1, 2)
    check(tiered ~= nil and tiered.tier == 2, 'findItem honours the tier filter in containers')
    local untiered = a.findItem(23374)
    check(untiered ~= nil and (untiered.tier or 0) == 0,
          'findItem(id) defaults to tier 0 in containers (VERIFIER asymmetry)')
    eq(#a.getContainers(), 1, 'getContainers()')
    eq(#a.getBackpacks(), 1, 'getBackpacks()')

    -- spectators / monsters
    c.state.creatures[7]  = { id = 7,  name = 'Rat',  isMonster = true,
                              pos = { x = 103, y = 100, z = 7 } }
    c.state.creatures[8]  = { id = 8,  name = 'Bob',  isPlayer = true,
                              pos = { x = 101, y = 100, z = 7 } }
    c.state.creatures[9]  = { id = 9,  name = 'Seller', isNpc = true,
                              pos = { x = 100, y = 101, z = 7 } }
    c.state.creatures[10] = { id = 10, name = 'Deep Rat', isMonster = true,
                              pos = { x = 100, y = 100, z = 8 } }
    eq(#a.getSpectators(), 3, 'getSpectators is single-floor by default')
    eq(#a.getSpectators(true), 4, 'getSpectators(true) is multifloor')
    eq(#a.getMonsters(), 1, 'getMonsters()')
    eq(#a.getMonsters(2), 0, 'getMonsters(range) filters by Chebyshev distance')
    eq(#a.getPlayers(), 1, 'getPlayers()')
    eq(#a.getNpcs(), 1, 'getNpcs()')
    check(a.getCreatureById(7) ~= nil, 'getCreatureById()')
    check(a.getCreatureById(10) == nil, 'getCreatureById is single-floor by default')

    -- canCast: unknown spell => true; cast()-managed spell honours its delay
    check(a.canCast('some custom spell'), 'an unknown spell is assumed castable')
    sentPackets = {}
    check(a.cast('exori', 1000) ~= nil, 'cast() with a delay fires immediately')
    eq(#sentPackets, 1, 'cast() said it once')
    eq(a.cast('exori', 1000), nil, 'cast() refuses inside its own delay (returns nil)')
    eq(#sentPackets, 1, 'and sent nothing the second time')
    eq(a.canCast('exori'), false, 'canCast() reports the cast() cooldown')
    advance(1500); b:tick()
    check(a.canCast('exori'), 'canCast() clears once the cast() delay elapsed')

    -- cooldown tables fed by the client's own events
    c.events.emit('talk', { name = 'Tester', text = 'Exura Gran' })
    c.events.emit('spellCooldown', { spellId = 77, delay = 2000 })
    check(a.isCooldownIconActive(77), 'spellCooldown feeds the icon table')
    check(a.getSpellData('exura gran') ~= false,
          'the talk echo attributed the cooldown to the spell words')
    check(a.getSpellCoolDown('exura gran'), 'getSpellCoolDown() sees the icon')
    check(type(a.modules.game_cooldown.isCooldownIconActive) == 'function',
          'modules.game_cooldown is exposed (VERIFIER: vlib reaches it that way)')

    -- bot/world.lua delegation: colon-style instance AND dot-style table
    do
        local Wm = {}; Wm.__index = Wm
        function Wm:monsters(pos, range) self.calledWith = { pos, range }; return { 'a', 'b' } end
        b.world = setmetatable({}, Wm)
        eq(#a.getMonsters(3), 2, 'getMonsters delegates to a colon-style bot.world')
        check(b.world.calledWith ~= nil and b.world.calledWith[2] == 3,
              'the colon binding passed self correctly (self.calledWith was set)')
        b.world = { monsters = function(pos, range) return { 'x' } end }
        eq(#a.getMonsters(3), 1, 'getMonsters also accepts a dot-style bot.world')
        b.world = nil
        eq(#a.getMonsters(), 1, 'and falls back to the built-in scan when unset')
    end

    -- the two documented no-ops
    eq(a.depositItems(), false, 'depositItems is a logged no-op returning false')
    eq(a.withdrawItems(), false, 'withdrawItems is a logged no-op returning false')

    -- status()
    local s = b:status()
    check(type(s) == 'table' and s.player and s.player.hp == 500, 'status() carries the player')
    check(type(s.macros) == 'table', 'status() lists macros')
end

--=============================================================================
io.write('\n================ bot F3 ================\n')
for _, m in ipairs(msgs) do io.write(m, '\n') end
io.write(('  TOTAL: %d passed, %d failed -> %s\n'):format(pass, fail,
         fail == 0 and 'PASS' or 'FAIL'))
-- Embeddable in test/botsuite.lua (see test/f1_metadata.lua for the same hook).
if _G.BOT_F3_NO_EXIT then return { pass = pass, fail = fail, failures = msgs } end
pcall(function() sys.shutdown() end)
os.exit(fail == 0 and 0 or 1)
