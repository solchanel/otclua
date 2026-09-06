--[==[========================================================================
test/shim_behaviour_suite.lua -- BEHAVIOUR, not the absence of crashes.

    luajit test/shim_behaviour_suite.lua
    wsl.exe -d Debian -e sh -c 'cd /mnt/d/Claude/otclient_web/luaclient && \
        luajit test/shim_behaviour_suite.lua'

test/shim_compat_suite.lua answers "does the user's vBot tree LOAD and TICK
without raising".  That is a crash test, and a crash test cannot tell a bot
that heals at the right hp from a bot that never heals at all: both score
"ran, 0 errors".

This suite answers the other question.  For each vBot subsystem it builds a
world in which the CORRECT ACTION IS UNAMBIGUOUS, ticks the REAL vBot code
through the shim, and asserts THE EXACT PACKET that reached proto/sender.lua.
The transport is captured, so every assertion is on wire bytes -- opcode,
spell words, aim byte, item id, creature id, container slot address -- not on
a Lua return value the shim could have invented.

Every configuration comes from the user's own profile, read-only:

    vBot_configs/profile_1/HealBot.json     2 spell rules, 3 item rules
    vBot_configs/profile_1/AttackBot.json   8 attack rules, monk patterns

and where the config has to be synthetic (a CaveBot route, TargetBot creature
entries) it is built through vBot's OWN public API -- CaveBot.addAction,
TargetBot.Creature.addConfig, TargetBot.Looting.update -- so the data
structures under test are the ones vBot builds for itself.

    A  HealBot   spells: threshold, priority order, mana gate, real cooldown
    B  HealBot   items:  threshold, the shared 1 s use-cooldown
    C  AttackBot pattern count gate, table priority, auto-turn, cooldown
    D  CaveBot   waypoint advance, walking, arrival tolerance, label jump
    E  TargetBot priority selection, attack packet, keep-distance
    F  Looting   corpse queue -> open the corpse -> take the listed item
    G  hand-written otclient idioms, compiled into the real vBot sandbox
    H  SHIM vs NATIVE: bot/*.lua driven through the same world, packets compared

Sections A-F and H each also run the NATIVE bot layer (bot/healbot.lua,
bot/attackbot.lua, bot/targetbot.lua, bot/cavebot.lua) over an identically
furnished world and compare the packets byte for byte.  Two independent
implementations of the same spec agreeing on the wire is much stronger
evidence than either one agreeing with a hand-written expectation.

Set `_G.SHIMBEH_NO_EXIT = true` before dofile()ing this file and it returns
{ pass=, fail=, failures=, table= } instead of exiting.
==========================================================================]==]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. ROOT .. '/?/init.lua;' .. package.path
end

local OTROOT
do
    for _, c in ipairs({ ROOT .. '/../../otclient_mehah1530/otclient',
                         'D:/Claude/otclient_mehah1530/otclient',
                         '/mnt/d/Claude/otclient_mehah1530/otclient' }) do
        local f = io.open(c .. '/profiles/bot/vBot_4.8/_Loader.lua', 'r')
        if f then f:close(); OTROOT = c; break end
    end
end
local PROFILE = OTROOT and (OTROOT .. '/profiles/bot/vBot_4.8')

-- ========================================================== tiny framework
local pass, fail, msgs = 0, 0, {}
local curSection = ''
local function section(name)
    curSection = name
    io.write('\n-- ', name, '\n')
end
local function check(ok, desc, detail)
    if ok then
        pass = pass + 1
        io.write('   ok   ', desc, '\n')
    else
        fail = fail + 1
        local line = '   FAIL ' .. curSection .. ' / ' .. desc
                     .. (detail and ('  -- ' .. tostring(detail)) or '')
        msgs[#msgs + 1] = line
        io.write(line, '\n')
    end
    return ok
end
local function eq(got, want, desc)
    if got == want then return check(true, desc) end
    return check(false, desc, ('got %s, want %s'):format(tostring(got), tostring(want)))
end
local function skip(what, why) io.write('   SKIP ', what, '  -- ', why, '\n') end

--- One row of the deliverable behaviour table.
local BEHAVIOUR = {}     -- { area, scenario, expected, shim, native, verdict }
local function row(area, scenario, expected, shimGot, nativeGot)
    local verdict
    if shimGot ~= expected then
        verdict = 'FAIL'
    elseif nativeGot == nil then
        verdict = 'ok (shim only)'
    elseif nativeGot ~= shimGot then
        verdict = 'DIVERGES'
    else
        verdict = 'ok'
    end
    BEHAVIOUR[#BEHAVIOUR + 1] = { area = area, scenario = scenario, expected = expected,
                                  shim = shimGot, native = nativeGot, verdict = verdict }
    return verdict
end

--- assert a scenario on both engines at once and record the table row.
local function behaves(area, scenario, expected, shimGot, nativeGot)
    local v = row(area, scenario, expected, shimGot, nativeGot)
    check(shimGot == expected, ('%s: %s'):format(area, scenario),
          shimGot ~= expected and ('shim sent %s, expected %s'):format(tostring(shimGot), tostring(expected)) or nil)
    if nativeGot ~= nil then
        check(nativeGot == shimGot, ('%s: %s  [native agrees]'):format(area, scenario),
              nativeGot ~= shimGot and ('native sent %s, shim sent %s'):format(tostring(nativeGot), tostring(shimGot)) or nil)
    end
    return v
end

-- ========================================================== the world
local state   = require('game.state')
local events  = require('lib.events')
local sched   = require('lib.sched')
local items   = require('proto.items')
local sender  = require('proto.sender')

local ITEMS_OK = items.loaded
if not ITEMS_OK then ITEMS_OK = pcall(items.load, ROOT .. '/assets/items1530.bin') end

local ORIGIN    = { x = 1000, y = 1000, z = 7 }
local PID       = 0x1000
local ID_GRASS  = 4526
local ID_BP     = 2854
local ID_GOLD   = 3031
local ID_MANA   = 268
local ID_CORPSE = 4240      -- a real CONTAINER corpse in items1530.bin
local POTION    = 23374     -- the user's own HealBot item rule

--- A world: real game/state, a real proto/sender over a capturing transport,
--- a real event bus.  `sent` collects raw wire bodies.
local function newWorld()
    local st = state.new()
    local sent = {}
    local transport = { send = function(_, body) sent[#sent + 1] = body; return true end }
    local LC = {
        state = st, items = items, events = events.new(), sched = sched, inGame = true,
        log = { info = function() end, warn = function() end,
                error = function() end, debug = function() end },
        sender = sender.new(transport, { accountName = 'behaviour' }),
        transport = transport,
    }
    local pl = st.player
    pl.id, pl.name = PID, 'Beh Tester'
    pl.pos = { x = ORIGIN.x, y = ORIGIN.y, z = ORIGIN.z }
    pl.health, pl.maxHealth = 800, 800
    pl.mana, pl.maxMana = 400, 400
    pl.level, pl.levelPercent, pl.exp = 200, 10, 1
    pl.magicLevel, pl.baseMagicLevel, pl.magicLevelPercent = 30, 30, 0
    pl.soul, pl.stamina = 100, 2400
    pl.freeCapacity, pl.capacity, pl.maxCapacity = 1000, 4000, 4000
    pl.speed, pl.baseSpeed = 500, 220
    pl.vocation, pl.blessings, pl.regeneration = 4, 0x1F, 900
    pl.states, pl.direction = 0, 2
    pl.skills = { [0] = { level = 15, baseLevel = 10, percent = 0 },
                  [1] = { level = 90, baseLevel = 80, percent = 0 } }
    pl.inventory = pl.inventory or {}
    pl.inventory[3] = { kind = 'item', id = ID_BP }
    st:addCreature{ id = PID, name = 'Beh Tester', type = 0, pos = pl.pos,
                    healthPercent = 100, direction = 2, speed = 500, vocation = 4 }
    st:addThing(pl.pos, -1, { kind = 'creature', creatureId = PID, id = 0x63 })
    st:setCentralPosition(pl.pos)
    for y = ORIGIN.y - 9, ORIGIN.y + 9 do
        for x = ORIGIN.x - 9, ORIGIN.x + 9 do
            st:addThing({ x = x, y = y, z = ORIGIN.z }, -1, { kind = 'item', id = ID_GRASS })
        end
    end
    st.serverBeat, st.ping = 50, 0
    return LC, sent, st
end

local function addMonster(st, id, name, x, y, z, hp)
    st:addCreature{ id = id, name = name, type = 1, pos = { x = x, y = y, z = z },
                    healthPercent = hp or 100, direction = 0, speed = 200,
                    shield = 0, emblem = 0, skull = 0, outfit = { lookType = 35 } }
    st:addThing({ x = x, y = y, z = z }, -1, { kind = 'creature', creatureId = id, id = 0x63 })
end

--- hp% through the REAL parser event, so the tree's onPlayerHealthChange runs
--- (HealBot's standByItems latch is cleared by exactly that callback).
local function setHp(LC, st, pct)
    local pl = st.player
    pl.health = math.floor(pl.maxHealth * pct / 100 + 0.5)
    local rec = st.creatures[PID]
    local old = rec and rec.healthPercent
    if rec then rec.healthPercent = pct end
    if old ~= pct then
        LC.events:emit('creatureHealth', { creature = rec, healthPercent = pct })
    end
end
local function setMana(LC, st, pct)
    local pl = st.player
    local old = pl.mana
    pl.mana = math.floor(pl.maxMana * pct / 100 + 0.5)
    if old ~= pl.mana then
        LC.events:emit('manaChange', { mana = pl.mana, maxMana = pl.maxMana, old = old })
    end
end

-- ========================================================== packet decoding
-- Every assertion in this file is on the DECODED WIRE BYTES.
local OPNAME = {
    [0x64] = 'autoWalk', [0x65] = 'walkN', [0x66] = 'walkE', [0x67] = 'walkS',
    [0x68] = 'walkW', [0x6A] = 'walkNE', [0x6B] = 'walkSE', [0x6C] = 'walkSW',
    [0x6D] = 'walkNW', [0x6E] = 'stop',
    [0x6F] = 'turnN', [0x70] = 'turnE', [0x71] = 'turnS', [0x72] = 'turnW',
    [0x78] = 'move', [0x82] = 'use', [0x83] = 'useWith', [0x84] = 'useOnCreature',
    [0x87] = 'closeContainer', [0x88] = 'upContainer', [0x8C] = 'look',
    [0x96] = 'talk', [0xA0] = 'fightMode', [0xA1] = 'attack', [0xA2] = 'follow',
    [0xA3] = 'cancelAttackFollow',
}
local function u16(s, i) return s:byte(i) + s:byte(i + 1) * 256 end
local function u32(s, i)
    return s:byte(i) + s:byte(i + 1) * 256 + s:byte(i + 2) * 65536 + s:byte(i + 3) * 16777216
end
local function rdpos(s, i) return { x = u16(s, i), y = u16(s, i + 2), z = s:byte(i + 4) } end

local function decode(b)
    local o = b:byte(1)
    local t = { op = o, name = OPNAME[o] or ('0x%02X'):format(o) }
    if o == 0x96 then
        local len = u16(b, 3)
        t.mode, t.text, t.aim = b:byte(2), b:sub(5, 4 + len), b:byte(5 + len)
        if t.aim == 1 or t.aim == 2 then t.aimPos = rdpos(b, 6 + len) end
    elseif o == 0xA1 or o == 0xA2 then
        t.id = u32(b, 2)
    elseif o == 0x84 then
        t.fromPos, t.itemId, t.stack, t.creatureId = rdpos(b, 2), u16(b, 7), b:byte(9), u32(b, 10)
    elseif o == 0x82 then
        t.pos, t.itemId, t.stack, t.index = rdpos(b, 2), u16(b, 7), b:byte(9), b:byte(10)
    elseif o == 0x83 then
        t.fromPos, t.itemId, t.fromStack = rdpos(b, 2), u16(b, 7), b:byte(9)
        t.toPos, t.toId, t.toStack = rdpos(b, 10), u16(b, 15), b:byte(17)
    elseif o == 0x78 then
        t.fromPos, t.itemId, t.stack = rdpos(b, 2), u16(b, 7), b:byte(9)
        t.toPos, t.count = rdpos(b, 10), b:byte(15)
    elseif o == 0x64 then
        t.n, t.dirs = b:byte(2), {}
        for i = 1, t.n do t.dirs[i] = b:byte(2 + i) end
    end
    return t
end

--- The single canonical string a scenario is asserted against.
local function fmt(b)
    local t = decode(b)
    if t.op == 0x96 then return ('talk[aim%d]:%s'):format(t.aim or -1, t.text) end
    if t.op == 0xA1 then return ('attack:%d'):format(t.id) end
    if t.op == 0xA2 then return ('follow:%d'):format(t.id) end
    if t.op == 0x84 then return ('useOnCreature:%d->%d'):format(t.itemId, t.creatureId) end
    if t.op == 0x82 then
        return ('use:%d@%d,%d,%d'):format(t.itemId, t.pos.x, t.pos.y, t.pos.z)
    end
    if t.op == 0x78 then
        return ('move:%dx%d %d,%d,%d->%d,%d,%d'):format(t.itemId, t.count,
                t.fromPos.x, t.fromPos.y, t.fromPos.z, t.toPos.x, t.toPos.y, t.toPos.z)
    end
    if t.op == 0x64 then return ('autoWalk:%s'):format(table.concat(t.dirs, ',')) end
    return t.name
end

--- Everything sent since index `from`, as one comparable string ('' = silence).
local function since(sent, from)
    local out = {}
    for i = from + 1, #sent do out[#out + 1] = fmt(sent[i]) end
    return table.concat(out, ' ')
end

-- ========================================================== shim side
local shim = require('shim.bootstrap')
local SH = {}          -- { LC, sent, st, ctx, G, now }

local function shimBoot()
    local LC, sent, st = newWorld()
    SH.LC, SH.sent, SH.st = LC, sent, st
    SH.now = 100000
    local h, err = shim.start(LC, {
        otRoot = OTROOT, config = 'vBot_4.8', profile = 1,
        readOnly = true, arm = false,
        clock = function() return SH.now end,
    })
    if not h then return nil, err end
    SH.h, SH.ctx, SH.G = h, shim.context(), h.G
    if not SH.ctx then return nil, 'no sandbox context: ' .. tostring(err) end
    return h, err
end

--- The registration site of a macro, from the `desc` upvalue functions/main.lua:106
--- captures.  This is how a specific vBot macro is addressed without guessing
--- at list indices: "/vBot/HealBot.lua:687" is the spell loop, and nothing else.
local function macroDesc(m)
    for i = 1, 30 do
        local n, v = debug.getupvalue(m.callback, i)
        if not n then break end
        if n == 'desc' and type(v) == 'string' then
            return (v:gsub('^%[string "', ''):gsub('"%]', ''))
        end
    end
    return '?'
end
local function macroAt(siteSuffix)
    for _, m in ipairs(rawget(SH.ctx, '_macros') or {}) do
        if macroDesc(m):find(siteSuffix, 1, true) then return m end
    end
end

local function shimTime(t)
    SH.now = t
    SH.ctx.now, SH.ctx.time = t, t
end
local function shimAdvance(ms) shimTime(SH.now + ms) end

--- Run ONE macro body, in isolation, and return what it put on the wire.
local function runMacro(m)
    local n = #SH.sent
    m.delay = nil
    local ok, err = pcall(m.callback, m)
    if not ok then return '!ERROR ' .. tostring(err) end
    return since(SH.sent, n)
end

--- Drain the executor's own scheduler (executor.lua:212-220).
local function pumpSchedule()
    local sc = rawget(SH.ctx, '_scheduler')
    local n = 0
    while sc and #sc > 0 and sc[1].execution <= SH.now do
        local e = table.remove(sc, 1)
        local ok, err = pcall(e.callback)
        n = n + 1
        if not ok then check(false, 'a scheduled vBot callback raised', tostring(err)) end
    end
    return n
end

--- The server confirming the prewalk step the shim just queued.
local function confirmWalk()
    local p = SH.ctx.player
    if not p:isPreWalking() then return false end
    local np = p:getPosition()
    SH.st:moveCreature(PID, SH.st.player.pos, nil, { x = np.x, y = np.y, z = np.z })
    SH.st.player.pos = { x = np.x, y = np.y, z = np.z }
    SH.st:setCentralPosition(SH.st.player.pos)
    p:resetPreWalk()
    return true
end

-- ========================================================== native side
local NAT = {}
local botmod, healbotmod, attackbotmod, targetbotmod, cavebotmod, cfgmod
do
    local ok = true
    ok = ok and pcall(function() botmod = require('bot.init') end)
    ok = ok and pcall(function() healbotmod = require('bot.healbot') end)
    ok = ok and pcall(function() attackbotmod = require('bot.attackbot') end)
    ok = ok and pcall(function() targetbotmod = require('bot.targetbot') end)
    ok = ok and pcall(function() cavebotmod = require('bot.cavebot') end)
    ok = ok and pcall(function() cfgmod = require('bot.config') end)
    NAT.available = ok
end

local function loadProfileJson(rel)
    if not (PROFILE and cfgmod) then return nil end
    local text = cfgmod.readFile(PROFILE .. '/' .. rel)
    if not text then return nil end
    local ok, d = pcall(cfgmod.jsonDecode, text)
    return ok and d or nil
end

--- A fresh native world + bot, clock-injected so it is driven the same way.
local function nativeNew()
    local LC, sent, st = newWorld()
    local W = { LC = LC, sent = sent, st = st, now = 100000 }
    W.bot = botmod.new(LC, { clock = function() return W.now end, storageSaveMs = 0,
                             profileDir = PROFILE, vprofile = 1 })
    W.bot.now = W.now
    W.time = function(t) W.now = t; W.bot.now = t end
    W.advance = function(ms) W.now = W.now + ms; W.bot.now = W.now end
    W.run = function(fn, ...)
        local n = #sent
        local ok, err = pcall(fn, ...)
        if not ok then return '!ERROR ' .. tostring(err) end
        return since(sent, n)
    end
    return W
end

-- ========================================================== boot
local BOOTED = false
if not OTROOT then
    io.write('\n!! the otclient tree was not found next to this checkout; every section '
             .. 'that needs the user profile is skipped\n')
else
    local h, err = shimBoot()
    if not h then
        check(false, 'shim.start booted the real vBot profile', err)
    else
        BOOTED = true
        check(true, 'shim.start booted the real vBot profile')
        if err then io.write('        !! boot note: ', tostring(err), '\n') end
        for _, b in ipairs(shim.status().boot or {}) do
            if not b.ok then io.write('        !! boot step ', tostring(b.step), ': ',
                                      tostring(b.err), '\n') end
        end
        local st0 = shim.status()
        eq(st0.vbotFailed, 0, ('all %d vBot profile files loaded'):format(st0.vbotLoaded))
        eq(st0.runtimeFailed, 0, ('all %d game_bot runtime files loaded'):format(st0.runtimeLoaded))
    end
end
check(ITEMS_OK, 'assets/items1530.bin loaded (walkability, containers, corpses)')
check(NAT.available, 'the native bot layer (bot/*.lua) loaded for cross-checking')

local HBJSON = loadProfileJson('vBot_configs/profile_1/HealBot.json')
local ABJSON = loadProfileJson('vBot_configs/profile_1/AttackBot.json')

--==============================================================================
section('A  HealBot SPELLS -- the user real HealBot.json, wire-asserted')
--==============================================================================
-- HealBot.json profile 1, spellTable in ARRAY order (which IS the priority):
--    [1] exura gran tio   HP% "<" 75   cost 210
--    [2] exura gran       HP% "<" 95   cost  75
-- vBot's "<" is implemented as `<=` (HealBot.lua:693), and the mana gate is a
-- STRICT `entry.cost < mana()` (HealBot.lua:690).
if not BOOTED then
    skip('section A', 'the shim did not boot')
elseif not HBJSON then
    skip('section A', 'HealBot.json not readable')
else
    check(HBJSON.healbot[1].enabled == true, 'HealBot profile 1 is enabled in the user config')
    eq(HBJSON.healbot[1].spellTable[1].spell, 'exura gran tio', 'rule 1 is exura gran tio (<=75, 210 mana)')
    eq(HBJSON.healbot[1].spellTable[2].spell, 'exura gran', 'rule 2 is exura gran (<=95, 75 mana)')
    eq(HBJSON.healbot[1].Cooldown, true, 'Cooldown gating is ON in the user config')

    local mSpell = macroAt('/vBot/HealBot.lua:687')
    check(mSpell ~= nil, 'the HealBot spell macro (HealBot.lua:687) is registered')

    -- the native engine over its own identically furnished world
    local NW, nhb
    if NAT.available then
        NW = nativeNew()
        nhb = healbotmod.new(NW.bot, loadProfileJson('vBot_configs/profile_1/HealBot.json'))
    end

    local function scenario(name, hp, mana, expected)
        shimAdvance(5000)
        setHp(SH.LC, SH.st, hp); setMana(SH.LC, SH.st, mana)
        local got = mSpell and runMacro(mSpell) or '!no macro'
        local nat
        if nhb then
            NW.advance(5000)
            setHp(NW.LC, NW.st, hp); setMana(NW.LC, NW.st, mana)
            nat = NW.run(function() nhb:spellTick() end)
        end
        behaves('HealBot/spell', name, expected, got, nat)
    end

    scenario('hp 100%, full mana -> holds (above every rule)', 100, 100, '')
    scenario('hp  96%          -> holds (96 > 95)',             96, 100, '')
    scenario('hp  95%          -> exura gran (boundary is <=)', 95, 100, 'talk[aim3]:exura gran')
    scenario('hp  80%          -> exura gran',                  80, 100, 'talk[aim3]:exura gran')
    scenario('hp  76%          -> exura gran',                  76, 100, 'talk[aim3]:exura gran')
    scenario('hp  75%          -> exura gran tio (boundary)',   75, 100, 'talk[aim3]:exura gran tio')
    scenario('hp  50%          -> exura gran tio (priority)',   50, 100, 'talk[aim3]:exura gran tio')
    -- the mana gate: 210 mana is 52% of 400.  `210 < 208` is false, so the big
    -- heal is skipped and the cheap one fires -- the bot degrades, it does not stall.
    scenario('hp 50%, 208 mana -> exura gran (210 cost gated)', 50,  52, 'talk[aim3]:exura gran')
    scenario('hp 50%, 200 mana -> exura gran',                  50,  50, 'talk[aim3]:exura gran')
    scenario('hp 50%,  72 mana -> holds (both costs gated)',    50,  18, '')

    -- ---- the real spell cooldown, driven by a real 0xA4 / 0xA5 --------------
    if mSpell then
        shimAdvance(5000)
        setHp(SH.LC, SH.st, 50); setMana(SH.LC, SH.st, 100)
        local first = runMacro(mSpell)
        eq(first, 'talk[aim3]:exura gran tio', 'cooldown fixture: the first cast goes out')

        local d = SH.ctx.getSpellData('exura gran tio')
        check(d ~= nil and d.id ~= nil, 'vBot spell DB knows exura gran tio')
        if d then
            SH.LC.events:emit('spellCooldown', { spellId = d.id, delay = 2000 })
            for g in pairs(d.group or {}) do
                SH.LC.events:emit('spellGroupCooldown', { groupId = g, delay = 2000 })
            end
            shimAdvance(100)
            behaves('HealBot/spell', 'a real 0xA4+0xA5 (2000 ms) holds every heal',
                    '', runMacro(mSpell), nil)
            shimAdvance(1000)
            behaves('HealBot/spell', 'still held 1100 ms into a 2000 ms cooldown',
                    '', runMacro(mSpell), nil)
            shimAdvance(1000)
            behaves('HealBot/spell', 'fires again the moment the cooldown expires',
                    'talk[aim3]:exura gran tio', runMacro(mSpell), nil)
        end
    end
end

--==============================================================================
section('B  HealBot ITEMS -- threshold + the shared 1 s use-cooldown')
--==============================================================================
-- itemTable in array order: [1] 23374 HP% <40 DISABLED, [2] 23374 HP% <=75,
-- [3] 23374 MP% <=75.  Visible = false, so the potion is fired blind
-- (g_game.useInventoryItemWith resolves it by id server-side) -- 0x84.
if not BOOTED or not HBJSON then
    skip('section B', 'the shim did not boot or HealBot.json is unreadable')
else
    eq(#HBJSON.healbot[1].itemTable, 3, 'three item rules in the user config')
    eq(HBJSON.healbot[1].itemTable[1].enabled, false, 'rule 1 (HP%<40) is DISABLED by the user')
    eq(HBJSON.healbot[1].Visible, false, 'Visible = false: fire blind, no inventory gate')

    local mItem = macroAt('/vBot/HealBot.lua:748')
    check(mItem ~= nil, 'the HealBot item macro (HealBot.lua:748) is registered')

    local NW, nhb
    if NAT.available then
        NW = nativeNew()
        nhb = healbotmod.new(NW.bot, loadProfileJson('vBot_configs/profile_1/HealBot.json'))
    end
    local EXPECT_USE = ('useOnCreature:%d->%d'):format(POTION, PID)

    local function scenario(name, hp, mana, expected)
        shimAdvance(5000)
        setHp(SH.LC, SH.st, hp); setMana(SH.LC, SH.st, mana)
        local got = mItem and runMacro(mItem) or '!no macro'
        local nat
        if nhb then
            NW.advance(5000)
            setHp(NW.LC, NW.st, hp); setMana(NW.LC, NW.st, mana)
            nat = NW.run(function() nhb:itemTick() end)
        end
        behaves('HealBot/item', name, expected, got, nat)
    end

    scenario('hp 100%, mana 100% -> holds',                 100, 100, '')
    scenario('hp  76%            -> holds (76 > 75)',        76, 100, '')
    scenario('hp  75%            -> ultimate spirit potion', 75, 100, EXPECT_USE)
    scenario('hp  74%            -> ultimate spirit potion', 74, 100, EXPECT_USE)
    scenario('mana 74%           -> ultimate spirit potion (MP% rule)', 100, 74, EXPECT_USE)
    scenario('mana 76%           -> holds',                 100,  76, '')

    -- the shared 1 s use-cooldown that HealBot and AttackBot both consume
    if mItem then
        shimAdvance(5000); setHp(SH.LC, SH.st, 60)
        local a = runMacro(mItem)
        eq(a, EXPECT_USE, 'use-cooldown fixture: the first potion goes out')
        shimAdvance(500); setHp(SH.LC, SH.st, 61); setHp(SH.LC, SH.st, 60)
        behaves('HealBot/item', '+500 ms: the shared 1 s use-cooldown holds the potion',
                '', runMacro(mItem), nil)
        shimAdvance(600); setHp(SH.LC, SH.st, 61); setHp(SH.LC, SH.st, 60)
        behaves('HealBot/item', '+1100 ms: the use-cooldown has expired, it drinks again',
                EXPECT_USE, runMacro(mItem), nil)
    end
end

--==============================================================================
section('C  AttackBot -- the user real AttackBot.json (8 monk rules)')
--==============================================================================
-- attackTable in array order.  With a plain unnamed monster at full health only
-- three of the eight can ever match:
--    [3] exori med pug   Chained Penance   2+ any    (pattern 18)
--    [7] exori mas pug   Flurry of Blows   1+ any    (pattern 13)
--    [8] exori amp pug   7 Sqm targeted    1+, hp<=20
-- so 1 monster is unambiguously "exori mas pug" and 2 monsters is unambiguously
-- "exori med pug" (earlier in the table wins).
if not BOOTED or not ABJSON then
    skip('section C', 'the shim did not boot or AttackBot.json is unreadable')
else
    local p = ABJSON.AttackBot[ABJSON.currentBotProfile]
    -- NOTE: p.enabled mirrors the LIVE on/off toggle in the user's own client and
    -- drifts independently of this suite (the user has since turned AttackBot off
    -- in game, so this currently reads false). This scenario proves the FIRING
    -- LOGIC given the user's real 8-rule table, not the toggle, so it is forced on
    -- through AttackBot's own public API below rather than asserted as a fixed
    -- value that this suite does not control.
    eq(#p.attackTable, 8, 'eight attack rules')
    eq(p.attackTable[7].spell, 'exori mas pug', 'rule 7 is Flurry of Blows, 1+ creatures')
    eq(p.attackTable[3].spell, 'exori med pug', 'rule 3 is Chained Penance, 2+ creatures')

    local mAtk = macroAt('/vBot/AttackBot.lua:2708')
    check(mAtk ~= nil, 'the AttackBot macro (AttackBot.lua:2708) is registered')
    check(SH.ctx.AttackBot ~= nil, 'AttackBot.lua installs its public global table')
    if SH.ctx.AttackBot then
        SH.ctx.AttackBot.setOn()
        check(SH.ctx.AttackBot.isOn(), 'AttackBot forced on through its own setOn(), independent of the live toggle')
    end

    -- one monster, adjacent, targeted
    addMonster(SH.st, 0x3001, 'Rat', ORIGIN.x + 1, ORIGIN.y, ORIGIN.z, 100)
    shimAdvance(5000)
    SH.G.g_game.attack(SH.G.g_map.getCreatureById(0x3001))
    eq(SH.ctx.target() and SH.ctx.target():getName(), 'Rat', 'target() is the Rat')

    local NW, nab
    if NAT.available then
        NW = nativeNew()
        local nabCfg = loadProfileJson('vBot_configs/profile_1/AttackBot.json')
        -- force on in this in-memory copy too, mirroring AttackBot.setOn() above --
        -- the real file on disk is never touched (loadProfileJson re-decodes it
        -- fresh every call).
        nabCfg.AttackBot[nabCfg.currentBotProfile].enabled = true
        nab = attackbotmod.new(NW.bot, nabCfg)
        addMonster(NW.st, 0x3001, 'Rat', ORIGIN.x + 1, ORIGIN.y, ORIGIN.z, 100)
        NW.bot._attacking = 0x3001
    end

    shimAdvance(5000)
    local got = mAtk and runMacro(mAtk) or '!no macro'
    local nat
    if nab then NW.advance(5000); nat = NW.run(function() nab:tick() end) end
    behaves('AttackBot', '1 monster in the pattern -> Flurry of Blows',
            'talk[aim3]:exori mas pug', got, nat)

    -- two monsters: the higher rule in the table takes over
    addMonster(SH.st, 0x3002, 'Rat', ORIGIN.x, ORIGIN.y + 1, ORIGIN.z, 100)
    shimAdvance(5000)
    got = runMacro(mAtk)
    if nab then
        addMonster(NW.st, 0x3002, 'Rat', ORIGIN.x, ORIGIN.y + 1, ORIGIN.z, 100)
        NW.advance(5000); nat = NW.run(function() nab:tick() end)
    end
    behaves('AttackBot', '2 monsters -> Chained Penance (earlier rule wins)',
            'talk[aim3]:exori med pug', got, nat)

    -- HOLD: a target too far away with nothing in the pattern
    do
        -- rebuild the shim world instead of mutating: a clean "nothing adjacent"
        shim.stop()
        local h = shimBoot()
        check(h ~= nil, 'the shim rebooted for the hold scenario')
        if SH.ctx.AttackBot then SH.ctx.AttackBot.setOn() end
        addMonster(SH.st, 0x3001, 'Rat', ORIGIN.x + 6, ORIGIN.y, ORIGIN.z, 100)
        shimAdvance(5000)
        SH.G.g_game.attack(SH.G.g_map.getCreatureById(0x3001))
        local mA2 = macroAt('/vBot/AttackBot.lua:2708')
        shimAdvance(5000)
        local g2 = runMacro(mA2)
        local n2
        if NAT.available then
            local W2 = nativeNew()
            local a2Cfg = loadProfileJson('vBot_configs/profile_1/AttackBot.json')
            a2Cfg.AttackBot[a2Cfg.currentBotProfile].enabled = true
            local a2 = attackbotmod.new(W2.bot, a2Cfg)
            addMonster(W2.st, 0x3001, 'Rat', ORIGIN.x + 6, ORIGIN.y, ORIGIN.z, 100)
            W2.bot._attacking = 0x3001
            W2.advance(5000)
            n2 = W2.run(function() a2:tick() end)
        end
        behaves('AttackBot', 'target 6 sqm away, 0 monsters in the pattern -> HOLDS',
                '', g2, n2)

        -- auto-turn: the monster steps to the tile NORTH of us while we face south
        SH.st:moveCreature(0x3001, { x = ORIGIN.x + 6, y = ORIGIN.y, z = ORIGIN.z }, nil,
                           { x = ORIGIN.x, y = ORIGIN.y - 1, z = ORIGIN.z })
        eq(SH.ctx.player:getDirection(), 2, 'the player is facing South (2)')
        shimAdvance(5000)
        behaves('AttackBot', 'monster to the North while facing South -> turn, then cast',
                'turnN talk[aim3]:exori mas pug', runMacro(mA2), nil)

        -- group-1 cooldown: a real 0xA5 holds every attack spell in the group
        SH.LC.events:emit('spellGroupCooldown', { groupId = 1, delay = 2000 })
        shimAdvance(100)
        behaves('AttackBot', 'a real group-1 cooldown (2000 ms) holds the whole table',
                '', runMacro(mA2), nil)
        shimAdvance(2100)
        behaves('AttackBot', 'resumes the instant the group cooldown expires',
                'turnN talk[aim3]:exori mas pug', runMacro(mA2), nil)
    end
end

--==============================================================================
section('D  CaveBot -- waypoint advance, walking, arrival, label jump')
--==============================================================================
-- A four-step route built through CaveBot's OWN addAction, so the list widget
-- under test is the one vBot builds for itself and getFocusedChild really is the
-- program counter:
--     1 label     start
--     2 goto      +4,0
--     3 goto      +4,+4
--     4 gotolabel start
if not BOOTED then
    skip('section D', 'the shim did not boot')
else
    shim.stop()
    local h = shimBoot()
    check(h ~= nil, 'the shim rebooted for the CaveBot scenario')
    local CB, ctx = SH.ctx.CaveBot, SH.ctx
    ctx.TargetBot.setOff()
    CB.actionList:destroyChildren()
    CB.addAction('label', 'start', false, nil, true)
    CB.addAction('goto', (ORIGIN.x + 4) .. ',' .. ORIGIN.y .. ',' .. ORIGIN.z, false, nil, true)
    CB.addAction('goto', (ORIGIN.x + 4) .. ',' .. (ORIGIN.y + 4) .. ',' .. ORIGIN.z, false, nil, true)
    CB.addAction('gotolabel', 'start', false, nil, true)
    eq(CB.actionList:getChildCount(), 4, 'the route has four waypoints')
    CB.setOn()
    check(CB.isOn(), 'CaveBot is on')

    local mCave = macroAt('/cavebot/cavebot.lua:80')
    check(mCave ~= nil, 'the CaveBot macro (cavebot.lua:80) is registered')

    local function focus()
        local c = CB.actionList:getFocusedChild()
        return c and (c.action .. ':' .. tostring(c.value)) or 'nil'
    end
    local trace, steps = {}, {}
    for i = 1, 20 do
        shimAdvance(200)
        local out = runMacro(mCave)
        trace[#trace + 1] = ('%d:%s@%d,%d/%s'):format(i, out == '' and '-' or out,
                              SH.st.player.pos.x, SH.st.player.pos.y, focus())
        steps[#steps + 1] = { out = out, x = SH.st.player.pos.x, y = SH.st.player.pos.y,
                              focus = focus() }
        confirmWalk()
    end

    -- 1. it walks EAST toward the first goto
    local eastSteps = 0
    for i = 1, 6 do if steps[i] and steps[i].out == 'walkE' then eastSteps = eastSteps + 1 end end
    behaves('CaveBot', 'walks EAST toward goto(+4,0)', 4, eastSteps, nil)
    -- 2. it arrives and the program counter advances to the second goto
    local arrivedAt
    for i = 1, #steps do
        if steps[i].x == ORIGIN.x + 4 and steps[i].focus:find('goto:' .. (ORIGIN.x + 4) .. ',' .. (ORIGIN.y + 4), 1, true) then
            arrivedAt = i; break
        end
    end
    behaves('CaveBot', 'arriving at goto(+4,0) advances the waypoint',
            true, arrivedAt ~= nil, nil)
    -- 3. it then walks SOUTH toward the second goto (first lap only, so the count is
    --    comparable with the native engine's)
    local lapEnd = #steps
    for i = (arrivedAt or 1), #steps do
        if steps[i].focus:find('gotolabel', 1, true) then lapEnd = i; break end
    end
    local southSteps = 0
    for i = (arrivedAt or 1), lapEnd do
        if steps[i].out == 'walkS' then southSteps = southSteps + 1 end
    end
    behaves('CaveBot', 'walks SOUTH toward goto(+4,+4)', true, southSteps >= 3, nil)
    -- 4. a plain goto (no precision marker, not stairs) arrives within 1 tile
    local stoppedAtY
    for i = (arrivedAt or 1), #steps do
        if steps[i].focus:find('gotolabel', 1, true) then stoppedAtY = steps[i].y; break end
    end
    behaves('CaveBot', 'a plain goto arrives within 1 tile (stops at y+3, not y+4)',
            ORIGIN.y + 3, stoppedAtY, nil)
    -- 5. gotolabel jumps the program counter back behind the label
    local jumped
    for i = 1, #steps - 1 do
        if steps[i].focus:find('gotolabel', 1, true)
           and steps[i + 1].focus == ('goto:%d,%d,%d'):format(ORIGIN.x + 4, ORIGIN.y, ORIGIN.z) then
            jumped = true; break
        end
    end
    behaves('CaveBot', 'gotolabel:start jumps back to the first waypoint after the label',
            true, jumped == true, nil)
    -- 6. and it really walks back north afterwards
    local wentBackNorth = false
    for i = 1, #steps do if steps[i].out == 'walkN' then wentBackNorth = true end end
    behaves('CaveBot', 'the route loops: it walks NORTH again after the jump',
            true, wentBackNorth, nil)

    -- the native CaveBot over the same route
    if NAT.available then
        local W = nativeNew()
        local ncb = cavebotmod.new(W.bot, nil, { now = function() return W.now end })
        ncb:reload({ waypoints = {
            { 'label', 'start' },
            { 'goto', (ORIGIN.x + 4) .. ',' .. ORIGIN.y .. ',' .. ORIGIN.z },
            { 'goto', (ORIGIN.x + 4) .. ',' .. (ORIGIN.y + 4) .. ',' .. ORIGIN.z },
            { 'gotolabel', 'start' },
        } })
        ncb:setOn()
        -- The native walker has no prewalk queue of its own: bot/walker.lua learns a
        -- step landed from the parser's `positionChange`, which is what
        -- test/bot_m2_cavebot.lua:241-245 emits too.  So the "server" here decodes
        -- the walk opcode it just sent and answers with the move.
        local DELTA = { walkN = { 0, -1 }, walkE = { 1, 0 }, walkS = { 0, 1 }, walkW = { -1, 0 },
                        walkNE = { 1, -1 }, walkSE = { 1, 1 }, walkSW = { -1, 1 }, walkNW = { -1, -1 } }
        local nEast, nSouth, sawLoop, lapDone = 0, 0, false, false
        for i = 1, 24 do
            W.advance(200)
            local out = W.run(function() ncb:tick() end)
            if ncb.index == 4 then lapDone = true end        -- reached the gotolabel
            if not lapDone then
                if out == 'walkE' then nEast = nEast + 1 end
                if out == 'walkS' then nSouth = nSouth + 1 end
            end
            if i > 8 and ncb.index == 2 then sawLoop = true end
            local d = DELTA[out]
            if d then
                local old = W.st.player.pos
                local np = { x = old.x + d[1], y = old.y + d[2], z = old.z }
                W.st:moveCreature(PID, old, nil, np)
                W.st.player.pos = np
                W.st:setCentralPosition(np)
                W.LC.events:emit('positionChange', { pos = np, oldPos = old })
            end
        end
        check(nEast >= 3, ('native CaveBot also walks EAST toward goto(+4,0) (%d steps)'):format(nEast))
        check(nSouth >= 2, ('native CaveBot also walks SOUTH toward goto(+4,+4) (%d steps)'):format(nSouth))
        row('CaveBot', 'native engine walks the same route', 'E then S',
            ('E%d S%d'):format(eastSteps, southSteps), ('E%d S%d'):format(nEast, nSouth))
    end
end

--==============================================================================
section('E  TargetBot -- priority selection, the attack packet, keep-distance')
--==============================================================================
if not BOOTED then
    skip('section E', 'the shim did not boot')
else
    shim.stop()
    local h = shimBoot()
    check(h ~= nil, 'the shim rebooted for the TargetBot scenario')
    local ctx = SH.ctx
    local TB = ctx.TargetBot
    ctx.CaveBot.setOff()
    TB.targetList:destroyChildren()
    TB.Creature.resetConfigs()

    local function entry(name, prio, extra)
        local c = { name = name, regex = '^' .. name:lower() .. '$', priority = prio,
                    danger = 1, maxDistance = 10, keepDistance = false, keepDistanceRange = 1,
                    anchor = false, anchorRange = 3, lure = false, lureMin = 1, lureMax = 3,
                    lureCount = 1, lureDelay = 250, dynamicLure = false, dynamicLureDelay = false,
                    lureCavebot = false, closeLure = false, closeLureAmount = 3,
                    faceMonster = false, chase = false, rePosition = false, rePositionAmount = 5,
                    avoidAttacks = false, diamondArrows = false, rpSafe = false,
                    dontLoot = true, delayFrom = 2 }
        for k, v in pairs(extra or {}) do c[k] = v end
        return c
    end
    local eRat   = entry('Rat', 1)
    local eDemon = entry('Demon', 5)
    TB.Creature.addConfig(eRat)
    TB.Creature.addConfig(eDemon)
    eq(TB.targetList:getChildCount(), 2, 'two creature configs are loaded')
    TB.setOn()
    check(TB.isOn(), 'TargetBot is on')

    -- Both monsters ADJACENT, so vBot's +10 "path length 1" bonus applies to both
    -- and the only thing separating them is the configured priority.
    addMonster(SH.st, 0x4001, 'Rat', ORIGIN.x + 1, ORIGIN.y, ORIGIN.z, 100)
    addMonster(SH.st, 0x4002, 'Demon', ORIGIN.x, ORIGIN.y + 1, ORIGIN.z, 100)
    local mTgt = macroAt('/targetbot/target.lua:49')
    check(mTgt ~= nil, 'the TargetBot macro (target.lua:49) is registered')
    shimAdvance(5000)
    local got = mTgt and runMacro(mTgt) or '!no macro'

    local NW, ntb
    if NAT.available then
        NW = nativeNew()
        ntb = targetbotmod.new(NW.bot, nil, { now = function() return NW.now end })
        ntb:reload({ targeting = { entry('Rat', 1), entry('Demon', 5) }, looting = {} })
        ntb:setOn()
        addMonster(NW.st, 0x4001, 'Rat', ORIGIN.x + 1, ORIGIN.y, ORIGIN.z, 100)
        addMonster(NW.st, 0x4002, 'Demon', ORIGIN.x, ORIGIN.y + 1, ORIGIN.z, 100)
        NW.advance(5000)
    end
    local nat = ntb and NW.run(function() ntb:tick() end) or nil
    behaves('TargetBot', 'two adjacent monsters -> attacks the higher-priority config',
            'attack:' .. 0x4002, got, nat)
    eq(SH.G.g_game.getAttackingCreature() and SH.G.g_game.getAttackingCreature():getName(),
       'Demon', 'the shim client state agrees the Demon is the target')

    -- keep distance: the same Rat, but the config now wants 3 sqm of air
    shim.stop(); shimBoot()
    do
        local c2 = SH.ctx
        c2.CaveBot.setOff()
        local T2 = c2.TargetBot
        T2.targetList:destroyChildren(); T2.Creature.resetConfigs()
        T2.Creature.addConfig(entry('Rat', 1, { keepDistance = true, keepDistanceRange = 3 }))
        T2.setOn()
        addMonster(SH.st, 0x4001, 'Rat', ORIGIN.x + 1, ORIGIN.y, ORIGIN.z, 100)
        local m2 = macroAt('/targetbot/target.lua:49')
        local out, shimTrace = {}, {}
        for i = 1, 8 do
            shimAdvance(1000)
            out[i] = runMacro(m2)
            if out[i] ~= '' then shimTrace[#shimTrace + 1] = out[i] end
            confirmWalk()
        end
        -- the same scenario through the native engine
        local nout
        if NAT.available then
            local W = nativeNew()
            local tb = targetbotmod.new(W.bot, nil, { now = function() return W.now end })
            tb:reload({ targeting = { entry('Rat', 1, { keepDistance = true,
                                                        keepDistanceRange = 3 }) },
                        looting = {} })
            tb:setOn()
            addMonster(W.st, 0x4001, 'Rat', ORIGIN.x + 1, ORIGIN.y, ORIGIN.z, 100)
            local DELTA = { walkN = { 0, -1 }, walkE = { 1, 0 }, walkS = { 0, 1 }, walkW = { -1, 0 },
                            walkNE = { 1, -1 }, walkSE = { 1, 1 }, walkSW = { -1, 1 },
                            walkNW = { -1, -1 } }
            nout = {}
            for i = 1, 8 do
                W.advance(1000)
                local o = W.run(function() tb:tick() end)
                if o ~= '' then nout[#nout + 1] = o end
                local last = o:match('(walk%a+)$')
                local d = last and DELTA[last]
                if d then
                    local old = W.st.player.pos
                    local np = { x = old.x + d[1], y = old.y + d[2], z = old.z }
                    W.st:moveCreature(PID, old, nil, np)
                    W.st.player.pos = np
                    W.st:setCentralPosition(np)
                    W.LC.events:emit('positionChange', { pos = np, oldPos = old })
                end
            end
            NAT.kdFinalX = W.st.player.pos.x
        end
        behaves('TargetBot', 'keepDistance 3, monster adjacent -> attack, then step away',
                'attack:' .. 0x4001 .. ' walkW', out[1], nout and nout[1] or nil)
        -- The two engines are compared on the SEQUENCE of packets and the resting
        -- place, not on tick alignment: the shim retires its prewalk the instant the
        -- fixture confirms the step, while bot/walker.lua additionally waits out its
        -- own step-duration window, so the native engine spends one extra idle tick
        -- per step.  Same decisions, same wire, different pacing under a fixture that
        -- confirms instantly; a real server never confirms instantly.
        behaves('TargetBot', 'keepDistance 3 -> exactly two steps away, then silence',
                'attack:' .. 0x4001 .. ' walkW|walkW',
                table.concat(shimTrace, '|'),
                nout and table.concat(nout, '|') or nil)
        eq(SH.st.player.pos.x, ORIGIN.x - 2, 'the shim ended 3 tiles from the Rat')
        if NAT.kdFinalX then
            eq(NAT.kdFinalX, ORIGIN.x - 2, 'the native engine ended on the same tile')
        end
    end
end

--==============================================================================
section('F  Looting -- queue a corpse, open it, take the listed item')
--==============================================================================
if not BOOTED then
    skip('section F', 'the shim did not boot')
else
    shim.stop()
    local h = shimBoot()
    check(h ~= nil, 'the shim rebooted for the looting scenario')
    -- the player's own open backpack, which is the loot destination
    SH.st.containers[0] = { id = 0, name = 'backpack', capacity = 20, hasPages = false,
                            firstIndex = 0, size = 0, hasParent = false, isUnlocked = true,
                            item = { kind = 'item', id = ID_BP }, items = {} }
    local ctx = SH.ctx
    local TB = ctx.TargetBot
    ctx.CaveBot.setOff()
    TB.targetList:destroyChildren(); TB.Creature.resetConfigs()
    TB.Creature.addConfig{ name = 'Rat', regex = '^rat$', priority = 1, danger = 1,
        maxDistance = 10, keepDistance = false, keepDistanceRange = 1, anchor = false,
        anchorRange = 3, lure = false, lureMin = 1, lureMax = 3, lureCount = 1,
        lureDelay = 250, dynamicLure = false, dynamicLureDelay = false, lureCavebot = false,
        closeLure = false, closeLureAmount = 3, faceMonster = false, chase = false,
        rePosition = false, rePositionAmount = 5, avoidAttacks = false, diamondArrows = false,
        rpSafe = false, dontLoot = false, delayFrom = 2 }
    -- loot GOLD COINS into a BACKPACK; the mana potion is deliberately NOT listed
    TB.Looting.update({ containers = { { id = ID_BP, count = 0 } },
                        items = { { id = ID_GOLD, count = 0 } } })
    TB.setOn()

    -- ---- the same scenario through the native engine ------------------------
    local NW, ntb
    local function nativeLootStep()
        if not ntb then return nil end
        return NW.run(function() ntb:tick() end)
    end
    if NAT.available then
        NW = nativeNew()
        NW.st.containers[0] = { id = 0, name = 'backpack', capacity = 20, hasPages = false,
            firstIndex = 0, size = 0, hasParent = false, isUnlocked = true,
            item = { kind = 'item', id = ID_BP }, items = {} }
        ntb = targetbotmod.new(NW.bot, nil, { now = function() return NW.now end })
        ntb:reload({ targeting = { { name = 'Rat', regex = '^rat$', priority = 1, danger = 1,
                                     maxDistance = 10, dontLoot = false } },
                     looting = { containers = { { id = ID_BP, count = 0 } },
                                 items = { { id = ID_GOLD, count = 0 } },
                                 maxDanger = 10, minCapacity = 100 } })
        ntb:setOn()
        ntb:attach()
        addMonster(NW.st, 0x5001, 'Rat', ORIGIN.x + 1, ORIGIN.y, ORIGIN.z, 100)
        NW.advance(2000)
        nativeLootStep()
    end

    local mTgt = macroAt('/targetbot/target.lua:49')
    addMonster(SH.st, 0x5001, 'Rat', ORIGIN.x + 1, ORIGIN.y, ORIGIN.z, 100)
    shimAdvance(2000)
    eq(runMacro(mTgt), 'attack:' .. 0x5001, 'looting fixture: the Rat is engaged')

    -- it dies: a corpse appears on its tile and the parser emits creatureDisappear
    local rec = SH.st.creatures[0x5001]
    SH.st:addThing({ x = ORIGIN.x + 1, y = ORIGIN.y, z = ORIGIN.z }, -1,
                   { kind = 'item', id = ID_CORPSE })
    SH.st:removeCreature(0x5001)
    SH.LC.events:emit('creatureDisappear', rec)
    shimAdvance(100)
    pumpSchedule()
    behaves('Looting', 'onCreatureDisappear queues the corpse',
            1, #TB.Looting.list, nil)
    check(TB.Looting.list[1] and TB.Looting.list[1].creature == 'Rat',
          'the queued entry names the creature it came from')

    -- drive the native engine through the same death
    local nOpen, nTake
    if ntb then
        local nrec = NW.st.creatures[0x5001]
        NW.st:addThing({ x = ORIGIN.x + 1, y = ORIGIN.y, z = ORIGIN.z }, -1,
                       { kind = 'item', id = ID_CORPSE })
        NW.st:removeCreature(0x5001)
        NW.LC.events:emit('creatureDisappear', nrec)
        NW.advance(100)
        NW.bot:tick()                       -- drains the native scheduler
        NW.advance(400)
        nOpen = nativeLootStep()
    end

    shimAdvance(400)
    behaves('Looting', 'opens the corpse (0x82 use on the corpse tile)',
            ('use:%d@%d,%d,%d'):format(ID_CORPSE, ORIGIN.x + 1, ORIGIN.y, ORIGIN.z),
            runMacro(mTgt), nOpen)

    -- the server answers: the corpse is container 1 and holds gold plus an
    -- unlisted mana potion
    SH.st.containers[1] = { id = 1, name = 'dead rat', capacity = 8, hasPages = false,
        firstIndex = 0, size = 2, hasParent = false, isUnlocked = true,
        item = { kind = 'item', id = ID_CORPSE },
        items = { { kind = 'item', id = ID_GOLD, count = 42 },
                  { kind = 'item', id = ID_MANA, count = 3 } } }
    SH.LC.events:emit('containerOpen', SH.st.containers[1])
    if ntb then
        NW.st.containers[1] = { id = 1, name = 'dead rat', capacity = 8, hasPages = false,
            firstIndex = 0, size = 2, hasParent = false, isUnlocked = true,
            item = { kind = 'item', id = ID_CORPSE },
            items = { { kind = 'item', id = ID_GOLD, count = 42 },
                      { kind = 'item', id = ID_MANA, count = 3 } } }
        NW.LC.events:emit('containerOpen', NW.st.containers[1])
        NW.advance(400)
        nTake = nativeLootStep()
    end
    shimAdvance(400)
    -- 0xFFFF / 0x40+containerId / slot is the synthetic container address
    behaves('Looting', 'takes the LISTED gold coin out of the corpse',
            ('move:%dx%d 65535,65,0->65535,64,0'):format(ID_GOLD, 1),
            runMacro(mTgt), nTake)

    -- and the unlisted potion is never moved
    SH.st.containers[1].items = { { kind = 'item', id = ID_MANA, count = 3 } }
    SH.st.containers[1].size = 1
    shimAdvance(400)
    local out = runMacro(mTgt)
    behaves('Looting', 'the UNLISTED mana potion is left in the corpse',
            true, out:find('move:' .. ID_MANA) == nil, nil)
end

--==============================================================================
section('G  hand-written otclient idioms, compiled into the real vBot sandbox')
--==============================================================================
-- Each script is compiled with load(src, name, nil, context) -- byte for byte the
-- way mods/game_bot/executor.lua:115 compiles the user's own files -- and each
-- one ASSERTS A BEHAVIOUR, not merely that the call did not raise.
if not BOOTED then
    skip('section G', 'the shim did not boot')
else
    shim.stop()
    local h = shimBoot()
    check(h ~= nil, 'the shim rebooted for the idiom scripts')
    addMonster(SH.st, 0x6001, 'Rat', ORIGIN.x + 1, ORIGIN.y, ORIGIN.z, 40)
    addMonster(SH.st, 0x6002, 'Cave Rat', ORIGIN.x - 2, ORIGIN.y, ORIGIN.z, 100)
    SH.st.containers[0] = { id = 0, name = 'backpack', capacity = 20, hasPages = false,
        firstIndex = 0, size = 2, hasParent = false, isUnlocked = true,
        item = { kind = 'item', id = ID_BP },
        items = { { kind = 'item', id = ID_GOLD, count = 87 },
                  { kind = 'item', id = ID_MANA, count = 12 } } }
    setHp(SH.LC, SH.st, 65)
    shimAdvance(1000)

    local ctx = SH.ctx
    -- a probe table the scripts use to read the capture back
    rawset(ctx, '_BEH', {
        count = function() return #SH.sent end,
        last  = function() return SH.sent[#SH.sent] and fmt(SH.sent[#SH.sent]) or '' end,
        since = function(n) return since(SH.sent, n) end,
        RAT = 0x6001, CAVERAT = 0x6002, PID = PID,
        GOLD = ID_GOLD, MANA = ID_MANA, BP = ID_BP, CORPSE = ID_CORPSE,
    })

    local SCRIPTS = {
{ 'getLocalPlayer():getHealthPercent() reads the live value', [[
  local p = g_game.getLocalPlayer()
  assert(p:getHealthPercent() == 65, 'hp% = ' .. tostring(p:getHealthPercent()))
  assert(p:getHealth() == 520 and p:getMaxHealth() == 800, 'hp')
  assert(p:getMana() == 400, 'mana')
  assert(p:isLocalPlayer(), 'isLocalPlayer')
]] },

{ 'g_map.getSpectators returns the real neighbours, interned', [[
  local p = g_game.getLocalPlayer()
  local specs = g_map.getSpectators(p:getPosition(), false)
  local names = {}
  for _, s in ipairs(specs) do names[s:getName()] = (names[s:getName()] or 0) + 1 end
  assert(names['Rat'] == 1, 'no Rat among the spectators')
  assert(names['Cave Rat'] == 1, 'no Cave Rat among the spectators')
  assert(names['Beh Tester'] == 1, 'the local player is not among the spectators')
  local again = g_map.getSpectators(p:getPosition(), false)
  assert(again[1] == specs[1], 'spectators are not interned')
  local self_ = false
  for _, s in ipairs(specs) do if s == p then self_ = true end end
  assert(self_, 'spec == player identity is broken')
]] },

{ 'g_map.getSpectatorsInRange narrows by the real distance', [[
  local p = g_game.getLocalPlayer()
  local near = g_map.getSpectatorsInRange(p:getPosition(), false, 1, 1)
  local sawFar = false
  for _, s in ipairs(near) do if s:getName() == 'Cave Rat' then sawFar = true end end
  assert(not sawFar, 'a creature 2 tiles away leaked into a 1x1 range query')
  local wide = g_map.getSpectatorsInRange(p:getPosition(), false, 3, 3)
  local sawFar2 = false
  for _, s in ipairs(wide) do if s:getName() == 'Cave Rat' then sawFar2 = true end end
  assert(sawFar2, 'the 3x3 range query lost the creature 2 tiles away')
]] },

{ 'findPath returns a real, minimal path and routes around creatures', [[
  local p = g_game.getLocalPlayer():getPosition()
  -- clear ground to the north: 3 tiles, 3 steps, all North
  local path = findPath(p, {x = p.x, y = p.y - 3, z = p.z}, 10, {ignoreNonPathable = true})
  assert(path, 'no path to a tile 3 sqm north')
  assert(#path == 3, 'path length ' .. #path .. ', expected 3')
  for _, d in ipairs(path) do assert(d == North, 'a step that is not North: ' .. tostring(d)) end
  -- east is blocked by the Rat standing at +1: the default path AVOIDS creatures,
  -- so it must be longer than the straight line, and shorter again when told to
  -- ignore them.  (This is the C++ default: Map::findPath treats a creature tile as
  -- non-walkable unless ignoreCreatures is set.)
  local blocked = findPath(p, {x = p.x + 3, y = p.y, z = p.z}, 20, {ignoreNonPathable = true})
  assert(blocked, 'no path east at all')
  assert(#blocked > 3, 'the path east ignored the Rat standing in the way')
  local through = findPath(p, {x = p.x + 3, y = p.y, z = p.z}, 20,
                           {ignoreNonPathable = true, ignoreCreatures = true})
  assert(through and #through == 3, 'ignoreCreatures did not give the straight line')
  local none = findPath(p, {x = p.x, y = p.y, z = p.z + 1}, 10, {})
  assert(not none, 'findPath invented a path to another floor')
]] },

{ 'g_game.attack puts 0xA1 with the creature id on the wire', [[
  local rat = g_map.getCreatureById(_BEH.RAT)
  assert(rat and rat:getName() == 'Rat', 'no rat')
  g_game.cancelAttack()
  local n = _BEH.count()
  g_game.attack(rat)
  assert(_BEH.since(n) == 'attack:' .. _BEH.RAT, 'sent ' .. _BEH.since(n))
  assert(g_game.getAttackingCreature() == rat, 'getAttackingCreature')
]] },

{ 'g_game.useWith addresses the right thing on the right tile', [[
  local p = g_game.getLocalPlayer():getPosition()
  local tile = g_map.getTile({x = p.x + 1, y = p.y, z = p.z})
  local ground = tile:getGround()
  local n = _BEH.count()
  g_game.useInventoryItemWith(_BEH.MANA, g_game.getLocalPlayer())
  assert(_BEH.since(n) == 'useOnCreature:' .. _BEH.MANA .. '->' .. _BEH.PID,
         'sent ' .. _BEH.since(n))
]] },

{ 'containers: getItems / getSlotPosition / move to a slot', [[
  local c = g_game.getContainers()[0]
  assert(c, 'container 0 is not open')
  local its = c:getItems()
  assert(#its == 2, '#items = ' .. #its)
  assert(its[1]:getId() == _BEH.GOLD and its[1]:getCount() == 87, 'slot 0 is not 87 gold')
  local sp = c:getSlotPosition(1)
  assert(sp.x == 0xFFFF and sp.y == 0x40 and sp.z == 1, 'slot position ' ..
         sp.x .. ',' .. sp.y .. ',' .. sp.z)
  local n = _BEH.count()
  g_game.move(its[1], c:getSlotPosition(1), 87)
  assert(_BEH.since(n):find('move:' .. _BEH.GOLD .. 'x87', 1, true), 'sent ' .. _BEH.since(n))
]] },

{ 'g_things.getThingType answers real 1530 item data', [[
  local tt = g_things.getThingType(_BEH.GOLD, ThingCategoryItem)
  assert(tt:isStackable(), 'gold coin is not stackable')
  local bp = g_things.getThingType(_BEH.BP, ThingCategoryItem)
  assert(bp:isContainer(), 'backpack is not a container')
  local corpse = g_things.getThingType(_BEH.CORPSE, ThingCategoryItem)
  assert(corpse:isContainer(), 'the corpse is not a container')
]] },

{ 'connect(g_game, {onTextMessage=...}) really receives a message', [[
  local seen = nil
  local connect = modules.game_bot.connect
  local h = {onTextMessage = function(mode, text) seen = {mode, text} end}
  connect(g_game, h)
  _BEH.fireTextMessage()
  disconnect = modules.game_bot.disconnect
  disconnect(g_game, h)
  assert(seen, 'onTextMessage never fired')
  assert(seen[2] == 'You lose 40 hitpoints.', 'text was ' .. tostring(seen[2]))
  assert(seen[1] == 22, 'mode was ' .. tostring(seen[1]) .. ', expected 22 (DamageReceived)')
]] },

{ 'onTalk / onTextMessage sandbox callbacks fire with translated modes', [[
  local got = {}
  onTextMessage(function(mode, text) got[#got+1] = {mode, text} end)
  onTalk(function(name, level, mode, text) got[#got+1] = {'talk', name, text} end)
  _BEH.fireTextMessage()
  _BEH.fireTalk()
  assert(#got == 2, 'got ' .. #got .. ' callbacks')
  assert(got[1][1] == 22, 'textMessage mode ' .. tostring(got[1][1]))
  assert(got[2][2] == 'Some Player', 'talk name ' .. tostring(got[2][2]))
]] },

{ 'Tile: getGround / isWalkable / getTopUseThing / getCreatures', [[
  local p = g_game.getLocalPlayer():getPosition()
  local here = g_map.getTile(p)
  assert(here:getGround():getId() == 4526, 'ground id')
  assert(here:hasCreatures(), 'the player is standing here')
  local east = g_map.getTile({x = p.x + 1, y = p.y, z = p.z})
  local cs = east:getCreatures()
  assert(#cs == 1 and cs[1]:getName() == 'Rat', 'the Rat is not on the east tile')
  assert(g_map.getTile({x = 1, y = 1, z = 7}) == nil, 'an undescribed tile is not nil')
]] },

{ 'g_game.walk queues a real prewalk and sends the direction opcode', [[
  local me = g_game.getLocalPlayer()
  me:resetPreWalk()
  local before = me:getServerPosition()
  local n = _BEH.count()
  g_game.walk(North)
  assert(_BEH.since(n) == 'walkN', 'sent ' .. _BEH.since(n))
  assert(me:isPreWalking(), 'no prewalk was queued')
  assert(me:getPosition().y == before.y - 1, 'the prewalk position did not move north')
  assert(me:getServerPosition().y == before.y, 'the SERVER position must not move')
  me:resetPreWalk()
  assert(me:getPosition().y == before.y, 'resetPreWalk did not retire the step')
]] },

{ 'the FIRST position change carries an invalid Position, never nil', [[
  -- Thing::setPosition (thing.cpp:44-52) passes oldPos BY VALUE, so on a creature's
  -- first move it is the default-constructed Position (65535,65535,255).  vBot's own
  -- vBot/extras.lua:565 does `if x.z ~= y.z`, unguarded, and a nil there raises on
  -- the very first position change of a live session.
  local seen
  onPlayerPositionChange(function(newPos, oldPos) seen = {newPos, oldPos} end)
  _BEH.firstMove()
  assert(seen, 'onPlayerPositionChange never fired')
  assert(type(seen[2]) == 'table', 'oldPos was ' .. type(seen[2]) .. ', must be a Position')
  assert(seen[2].z ~= nil, 'oldPos has no z')
  assert(seen[1].x == _BEH.MOVED.x and seen[1].y == _BEH.MOVED.y, 'newPos is wrong')
]] },

{ 'g_game.onTextMessage resolves a registered mode (no perror storm)', [[
  -- gamelib/textmessages.lua:3-8 owns g_game.onTextMessage and perrors
  -- "Unhandled onTextMessage message mode N" for a mode nothing registered.
  -- game_textmessage.init() registers one per mode; the shim must do the same or
  -- every server message of a live session logs an error.
  local gg = modules.game_bot.g_game or g_game
  assert(type(gg.onTextMessage) == 'function' or type(gg.onTextMessage) == 'table',
         'g_game.onTextMessage is missing entirely')
  local perrors = _BEH.countPerrors()
  _BEH.fireTextMessage()
  assert(_BEH.countPerrors() == perrors,
         'a real message mode still perrors as "unhandled"')
  -- and the counter is not vacuous: a mode nothing registers DOES still complain,
  -- which is the diagnostic the reference client keeps.
  g_game.onTextMessage(253, 'a mode nobody registers')
  assert(_BEH.countPerrors() == perrors + 1,
         'an unregistered mode no longer reports itself -- the check above proves nothing')
]] },

{ 'the vBot helper layer agrees with the raw API', [[
  assert(hppercent() == 65, 'hppercent ' .. hppercent())
  assert(manapercent() == 100, 'manapercent ' .. manapercent())
  assert(pos().x == g_game.getLocalPlayer():getPosition().x, 'pos()')
  assert(getMonsters() == 2, 'getMonsters() counted ' .. getMonsters())
  local specs = getSpectators()
  assert(#specs == 3, 'getSpectators() returned ' .. #specs)
  assert(getCreatureById(_BEH.RAT):getName() == 'Rat', 'getCreatureById')
  assert(distanceFromPlayer(getCreatureById(_BEH.RAT):getPosition()) == 1, 'distanceFromPlayer')
]] },
    }

    rawget(ctx, '_BEH').fireTextMessage = function()
        -- wire byte 24 is Otc::MessageDamageReceived (22) after the shim's
        -- protocolcodes.cpp:37-87 translation -- the number vBot actually compares.
        SH.LC.events:emit('textMessage', { mode = 24, text = 'You lose 40 hitpoints.' })
    end
    -- The player's very first move of the session: `positionChange` with NO oldPos,
    -- exactly the shape proto/parser.lua emits on the login teleport.
    rawget(ctx, '_BEH').MOVED = { x = ORIGIN.x, y = ORIGIN.y - 1, z = ORIGIN.z }
    rawget(ctx, '_BEH').firstMove = function()
        SH.LC.events:emit('positionChange', { pos = rawget(ctx, '_BEH').MOVED, oldPos = nil })
    end
    -- perror is corelib's error channel; count what it says rather than reading a log
    do
        local G = SH.G
        local realPerror = G.perror
        local n = 0
        G.perror = function(...) n = n + 1; if realPerror then return realPerror(...) end end
        rawset(ctx, 'perror', G.perror)
        rawget(ctx, '_BEH').countPerrors = function() return n end
    end
    rawget(ctx, '_BEH').fireTalk = function()
        SH.LC.events:emit('talk', { name = 'Some Player', level = 100, mode = 1,
                                    text = 'hello', pos = SH.st.player.pos })
    end

    for _, s in ipairs(SCRIPTS) do
        local name, src = s[1], s[2]
        local chunk, cerr = load(src, '@beh/' .. name, nil, ctx)
        if not chunk then
            check(false, 'idiom: ' .. name, 'compile: ' .. tostring(cerr))
            row('idiom', name, 'runs', 'COMPILE ERROR', nil)
        else
            local ok, err = pcall(chunk)
            check(ok, 'idiom: ' .. name, not ok and tostring(err) or nil)
            row('idiom', name, 'asserts pass', ok and 'asserts pass' or tostring(err), nil)
        end
    end
end

--==============================================================================
section('Dropper -- trash/use/cap-item disposal (vBot/Dropper.lua:127, closes COMPAT SS3.5 #1)')
--==============================================================================
-- Only crash-tested before this: `storage.dropper.{trashItems,useItems,capItems}`
-- feed a THREE-BUCKET priority scan (cap > use > trash) that runs `for i=1,3`
-- OUTSIDE the container/item loop, and the function `return`s the instant ANY
-- item in ANY container matches bucket i -- even when that bucket's own guard
-- (the free-capacity check on i==1) turns out false.  That means a single
-- cap-listed item sitting in the backpack starves the WHOLE macro every tick
-- while capacity is fine: use-items are never drunk and trash is never
-- dropped, not because they were not found but because the cap bucket's match
-- ate the `return` first.  This is exactly the class of bug the crash test
-- cannot see (config.enabled and a good match still ticks with 0 errors).
local ID_TRASH = 3577   -- worm -- distinct from every id used elsewhere in this file
if not BOOTED then
    skip('section Dropper', 'the shim did not boot')
else
    shim.stop()
    local h = shimBoot()
    check(h ~= nil, 'the shim rebooted for the Dropper scenario')
    local ctx = SH.ctx
    check(ctx.storage and ctx.storage.dropper ~= nil, 'vBot/Dropper.lua installs storage.dropper')
    local cfg = ctx.storage and ctx.storage.dropper
    local mDrop = macroAt('/vBot/Dropper.lua:127')
    check(mDrop ~= nil, 'the Dropper macro (Dropper.lua:127) is registered')

    if cfg and mDrop then
        cfg.enabled = true
        cfg.capItems   = { { id = ID_GOLD } }
        cfg.useItems   = { { id = POTION } }
        cfg.trashItems = { { id = ID_TRASH } }

        local function backpack(items)
            SH.st.containers[0] = { id = 0, name = 'backpack', capacity = 20, hasPages = false,
                firstIndex = 0, size = #items, hasParent = false, isUnlocked = true,
                item = { kind = 'item', id = ID_BP }, items = items }
        end

        -- (1) only a TRASH item present -> dropped to the player's own tile
        backpack({ { kind = 'item', id = ID_TRASH, count = 1 } })
        behaves('Dropper', 'only a trash item present -> dropped at the player tile',
                ('move:%dx1 65535,64,0->%d,%d,%d'):format(ID_TRASH, ORIGIN.x, ORIGIN.y, ORIGIN.z),
                runMacro(mDrop), nil)

        -- (2) a USE item and a TRASH item both present -> USE wins (bucket i=2
        --     is scanned, and matches, before bucket i=3 is ever reached)
        backpack({ { kind = 'item', id = POTION, count = 1 },
                   { kind = 'item', id = ID_TRASH, count = 1 } })
        behaves('Dropper', 'a use-item AND a trash-item present -> the use-item wins',
                ('use:%d@65535,64,0'):format(POTION),
                runMacro(mDrop), nil)

        -- (3) all three buckets matched, capacity FINE (>=150) -> the cap
        --     bucket's own guard is false, but its match still owns the
        --     `return`, so NOTHING happens this tick, not even the use-item
        --     one slot away.  This is the starvation bug this test exists for.
        SH.st.player.freeCapacity = 1000
        backpack({ { kind = 'item', id = ID_GOLD, count = 5 },
                   { kind = 'item', id = POTION, count = 1 },
                   { kind = 'item', id = ID_TRASH, count = 1 } })
        behaves('Dropper', 'cap-item present but capacity is FINE -> holds (starves use+trash too)',
                '', runMacro(mDrop), nil)

        -- (4) same three-item backpack, capacity now LOW -> the cap item drops
        SH.st.player.freeCapacity = 100
        behaves('Dropper', 'cap-item present and capacity is LOW -> drops the cap item',
                ('move:%dx5 65535,64,0->%d,%d,%d'):format(ID_GOLD, ORIGIN.x, ORIGIN.y, ORIGIN.z),
                runMacro(mDrop), nil)

        cfg.enabled = false
    end
end

--==============================================================================
section('H  the shim-vs-native verdict')
--==============================================================================
do
    local compared, agree, diverge = 0, 0, 0
    for _, r in ipairs(BEHAVIOUR) do
        if r.native ~= nil then
            compared = compared + 1
            if r.verdict == 'DIVERGES' then diverge = diverge + 1 else agree = agree + 1 end
        end
    end
    check(compared > 0, ('%d scenarios were run through BOTH engines'):format(compared))
    check(diverge == 0, ('the two engines agree on all %d cross-checked scenarios'):format(compared),
          diverge > 0 and (('%d diverged'):format(diverge)) or nil)
end

--==============================================================================
-- the deliverable table
--==============================================================================
io.write('\n')
io.write('=====================================================================================================\n')
io.write('BEHAVIOUR TABLE -- what the real vBot code DID, asserted on the wire\n')
io.write('=====================================================================================================\n')
io.write(('%-16s | %-56s | %-34s | %-34s | %s\n')
         :format('area', 'scenario', 'expected packet', 'shim sent', 'native'))
io.write(('%s\n'):format(string.rep('-', 205)))
local function cell(s, n)
    s = tostring(s == nil and '-' or (s == '' and '(silence)' or s))
    if #s > n then s = s:sub(1, n - 3) .. '...' end
    return s
end
for _, r in ipairs(BEHAVIOUR) do
    io.write(('%-16s | %-56s | %-34s | %-34s | %s\n'):format(
        cell(r.area, 16), cell(r.scenario, 64), cell(r.expected, 38),
        cell(r.shim, 38), (r.native == nil and 'n/a' or cell(r.native, 38)) ..
        (r.verdict == 'ok' and '  [agree]' or (r.verdict == 'DIVERGES' and '  [DIVERGES]' or ''))))
end
io.write(('%s\n'):format(string.rep('-', 205)))

io.write(('\n%d passed, %d failed\n'):format(pass, fail))
for _, m in ipairs(msgs) do io.write(m, '\n') end

if _G.SHIMBEH_NO_EXIT then
    return { pass = pass, fail = fail, failures = msgs, table = BEHAVIOUR }
end
os.exit(fail == 0 and 0 or 1)
