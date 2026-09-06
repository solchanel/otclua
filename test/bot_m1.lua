--[[============================================================================
test/bot_m1.lua -- offline proof for work item M1 (bot/healbot.lua,
bot/attackbot.lua, bot/shared.lua).

  luajit test/bot_m1.lua                    (from D:/Claude/otclient_web/luaclient)
  luajit test/bot_m1.lua --profile=<dir>    point at another vBot config dir

Everything runs against a SYNTHETIC world built directly on game/state.lua and a
capturing sender; nothing here touches the network, and nothing WRITES to the
user's vBot profile (the JSON files are read with config.readFile only).

  H1  the user's real HealBot.json, read verbatim
  H2  the required rule matrix: hp% / mana / mana% -> exactly which rule fires
      and exactly which packet goes on the wire
  H3  spell cooldown prediction over simulated time (0xA4 / 0xA5, group MAX,
      ping early-fire, Cooldown=false)
  H4  the item loop: shared 1 s use-exhaust, the 50 ms guard, the two AttackBot
      hold-offs, ping compensation, the looting throttle
  H5  dead / not-in-game / PZ guards
  H6  ConditionPanel: the five cures, the elseif chain, utamo+NewManaShield,
      haste's standTime window, the paralysis branch, utana's 120 s interval
  H7  burst damage, including the scheduled wipe
  H8  the four macros register at the documented periods and fire through the
      real bot tick

  A1  the user's real AttackBot.json, read verbatim, plus the migration
  A2  monster counting inside a pattern, the name filter and the summon rule
  A3  entry priority + direction picking on synthetic monster layouts
  A4  "not enough monsters"
  A5  PvP guards: the PvpSafe grid veto, and the pvpMode short-circuit
  A6  area runes: best tile, the packet, the rune-delay gate and the
      "hold the tick" rule
  A7  mana / harmony / cooldown gates and the optimizer flag
============================================================================]]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. package.path
end

local config   = require('bot.config')
local bot      = require('bot.init')
local gstate   = require('game.state')
local items    = require('proto.items')
local shared   = require('bot.shared')
local healbot  = require('bot.healbot')
local attackbot= require('bot.attackbot')
local events   = require('lib.events')

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
local function note(s) io.write('     ', s, '\n') end

-- ---------------------------------------------------------------- profile
local PROFILE
for i = 1, #(arg or {}) do
    local v = tostring(arg[i]):match('^%-%-profile=(.+)$')
    if v then PROFILE = v end
end
if not PROFILE then
    for _, c in ipairs({ 'D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
                         '/mnt/d/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8' }) do
        if config.fileExists(c .. '/_Loader.lua') then PROFILE = c; break end
    end
end
io.write('bot M1 selftest -- profile: ', tostring(PROFILE), '\n')

local function loadJson(rel)
    if not PROFILE then return nil end
    local text = config.readFile(PROFILE .. '/' .. rel)
    if not text then return nil end
    return config.jsonDecode(text)
end

-- AttackBot.json's top-level `enabled` flag (and, it turns out, entry 1's own
-- per-rule `enabled` flag) mirror LIVE on/off toggles in the user's own real
-- client and drift independently of this suite (as of this session the user
-- has turned AttackBot off in game AND disabled attackTable rule 1, so a raw
-- read currently sees profile `enabled: false` and attackTable[1].enabled:
-- false). Every scenario below that drives ab:tick() is proving the FIRING
-- LOGIC against the user's real 8-rule attackTable, not either toggle -- so
-- it loads through this helper, which forces the ACTIVE profile AND every one
-- of its rules on in the freshly-decoded in-memory copy only (config.readFile
-- is read-only; the file on disk is never touched). A1 loads the raw JSON
-- directly instead, since it is specifically the "read verbatim" section.
local function loadAttackBotJsonOn()
    local d = loadJson('vBot_configs/profile_1/AttackBot.json')
    if d and d.AttackBot then
        local p = d.AttackBot[d.currentBotProfile or 1]
        if p then
            p.enabled = true
            for _, entry in ipairs(p.attackTable or {}) do entry.enabled = true end
        end
    end
    return d
end

-- items1530.bin: without it bot/world.lua runs degraded and walls/ground vanish.
do
    local ok, err = pcall(items.load, ROOT .. '/assets/items1530.bin')
    io.write('items1530.bin: ', ok and ('loaded, format v' .. tostring(items.VERSION))
             or ('NOT loaded (' .. tostring(err) .. ')'), '\n')
end

-- ======================================================================
-- the synthetic client
-- ======================================================================
local CLOCK = { t = 1000000 }
local function now()     return CLOCK.t end
local function advance(ms) CLOCK.t = CLOCK.t + ms end

local function newWorld()
    local sent, log = {}, {}
    local sender = setmetatable({}, { __index = function(_, k)
        return function(_, ...) sent[#sent + 1] = { k, ... }; return 'ok' end
    end })
    local bus = events.new()
    local st = gstate.new()
    st.player.id = 1
    st.player.name = 'Tester'
    st.player.pos = { x = 100, y = 100, z = 7 }
    st.player.health, st.player.maxHealth = 1000, 1000
    st.player.mana,   st.player.maxMana   = 1000, 1000
    st.player.level, st.player.vocation = 500, 9
    st.player.direction = 0
    st.player.skills = {}
    st.central = { x = 100, y = 100, z = 7 }

    local client = {
        log = { info  = function(f, ...) log[#log+1] = 'I ' .. tostring(f) end,
                warn  = function(f, ...) log[#log+1] = 'W ' .. tostring(f) end,
                error = function(f, ...) log[#log+1] = 'E ' .. tostring(f) end,
                debug = function() end },
        sched = nil, state = st, sender = sender, items = items,
        events = { on = function(n, f) return bus:on(n, f) end,
                   off = function(h) return bus:off(h) end,
                   emit = function(n, d) return bus:emit(n, d) end },
    }
    local b = bot.new(client, { clock = now, storageSaveMs = 0 })
    return { bot = b, state = st, sent = sent, log = log, bus = bus, client = client }
end

local function clearSent(W) for i = #W.sent, 1, -1 do W.sent[i] = nil end end
local function lastSent(W) return W.sent[#W.sent] end
local function sentStr(W)
    local out = {}
    for i = 1, #W.sent do
        local p = W.sent[i]
        local a = {}
        for j = 2, #p do a[#a+1] = type(p[j]) == 'table'
            and ('{' .. tostring(p[j].x) .. ',' .. tostring(p[j].y) .. ',' .. tostring(p[j].z) .. '}')
            or tostring(p[j]) end
        out[#out+1] = p[1] .. '(' .. table.concat(a, ',') .. ')'
    end
    return table.concat(out, ' ')
end

-- ground the area so tiles exist, are walkable and are projectile-transparent
local GROUND = 103            -- grass; F1 verified: FLAGS2 GROUND, speed 110
local function layGround(st, cx, cy, z, r)
    for x = cx - r, cx + r do
        for y = cy - r, cy + r do
            st:addThing({ x = x, y = y, z = z }, nil, { kind = 'item', id = GROUND })
        end
    end
end

local function placeCreature(st, id, name, x, y, z, o)
    o = o or {}
    st:addCreature({ id = id, name = name, type = o.type or 1,
                     healthPercent = o.hp or 100,
                     pos = { x = x, y = y, z = z },
                     shield = o.shield or 0, emblem = o.emblem or 0,
                     direction = 0, outfit = { lookType = 128 } })
    st:addThing({ x = x, y = y, z = z }, nil, { kind = 'creature', creatureId = id })
    return st.creatures[id]
end

--=============================================================================
head('H1. the user\'s real HealBot.json, read verbatim')
--=============================================================================
local HBJSON = loadJson('vBot_configs/profile_1/HealBot.json')
check(HBJSON ~= nil, 'HealBot.json loads')
if HBJSON then
    eq(HBJSON.currentHealBotProfile, 1, 'currentHealBotProfile = 1')
    local p = HBJSON.healbot[1]
    eq(#HBJSON.healbot, 5, 'exactly five profiles')
    eq(p.enabled, true, 'profile 1 is enabled')
    eq(p.Visible, false, 'Visible = false  (fire blind, no hasItemAvailable gate)')
    eq(p.Cooldown, true, 'Cooldown = true')
    eq(#p.spellTable, 2, 'two spell rules')
    eq(#p.itemTable, 3, 'three item rules')
    eq(p.spellTable[1].spell, 'exura gran tio',
       'ARRAY ORDER is priority: the stale index 2 entry is FIRST')
    eq(p.spellTable[1].index, 2, '... and its .index really is the stale 2')
    eq(p.spellTable[2].spell, 'exura gran', 'second rule')
    local C = HBJSON.ConditionPanel
    eq(C.enabled, true, 'ConditionPanel is enabled')
    eq(C.curePoison, nil, 'the correctly-spelled curePoison key is ABSENT')
    eq(C.curePosion, false, 'only the misspelled curePosion is present, and false')
    eq(C.cureParalyse, true, 'cureParalyse on, cost 200, "utani gran hur"')
    eq(C.paralyseCost, 200, 'paralyseCost 200')
    eq(C.paralyseSpell, 'utani gran hur', 'paralyseSpell')
    eq(C.holdHaste, true, 'holdHaste on')
    eq(C.hasteCost, 200, 'hasteCost 200')
    eq(C.ignoreInPz, true, 'ignoreInPz')
end

--=============================================================================
head('H2. RULE MATRIX -- which rule fires, and which packet')
--=============================================================================
do
    local W = newWorld()
    local hb = healbot.new(W.bot, HBJSON)
    W.bot.now = now()

    -- spellTable:  [1] exura gran tio  HP% <= 75  cost 210
    --              [2] exura gran      HP% <= 95  cost  75
    -- The mana gate is STRICT `cost < mana()`; '<' means <=.
    local SPELLS = {
        -- hp%   mana   expect                   why
        { 100, 1000, nil,               'full hp: neither threshold met' },
        {  96, 1000, nil,               'hp 96 > 95' },
        {  95, 1000, 'exura gran',      "'Below 95' is INCLUSIVE -- fires at exactly 95" },
        {  76, 1000, 'exura gran',      'hp 76 still above the 75 rule' },
        {  75, 1000, 'exura gran tio',  'hp 75 inclusive; ARRAY ORDER gives tio priority' },
        {  10, 1000, 'exura gran tio',  'deep damage still picks the top rule' },
        {  75,  211, 'exura gran tio',  'mana 211 > cost 210' },
        {  75,  210, 'exura gran',      'STRICT <: cost 210 is NOT satisfied at 210 mana' },
        {  75,   76, 'exura gran',      'a blocked high-priority rule does not stop the next' },
        {  75,   75, nil,               'both mana gates fail (75 < 75 is false)' },
        {  95,   75, nil,               'exura gran needs 76+ mana' },
    }
    for _, c in ipairs(SPELLS) do
        local hpp, mana, want, why = c[1], c[2], c[3], c[4]
        clearSent(W)
        W.state.player.maxHealth = 100
        W.state.player.health    = hpp
        W.state.player.mana      = mana
        hb.sh.cdSpell, hb.sh.cdGroup = {}, {}
        local fired = hb:spellTick()
        local got = fired and fired.spell or nil
        eq(got, want, ('spell: hp%%=%d mana=%d -> %s  (%s)')
                      :format(hpp, mana, tostring(want), why))
        if want then
            local p = lastSent(W)
            check(p and p[1] == 'talkSpell' and p[2] == want and p[3] == 3,
                  '   packet: talkSpell("' .. want .. '", aim 3, no position)', sentStr(W))
        else
            eq(#W.sent, 0, '   no packet at all')
        end
    end

    -- itemTable: [1] 23374 HP% <= 40 DISABLED, [2] 23374 HP% <= 75, [3] 23374 MP% <= 75
    local ITEMS = {
        -- hp%  mp%   expect  why
        { 100, 100, nil,   'nothing matches' },
        {  75, 100, 23374, 'HP% rule 2 (rule 1 is disabled)' },
        {  30, 100, 23374, 'the DISABLED 40% rule is skipped, rule 2 still matches' },
        { 100,  75, 23374, 'MP% rule 3, inclusive at exactly 75' },
        { 100,  76, nil,   'mp 76 > 75' },
    }
    for _, c in ipairs(ITEMS) do
        local hpp, mpp, want, why = c[1], c[2], c[3], c[4]
        local W2 = newWorld()
        local h2 = healbot.new(W2.bot, loadJson('vBot_configs/profile_1/HealBot.json'))
        W2.bot.now = now()
        W2.state.player.maxHealth, W2.state.player.health = 100, hpp
        W2.state.player.maxMana,   W2.state.player.mana   = 100, mpp
        local fired = h2:itemTick()
        eq(fired and fired.item or nil, want,
           ('item:  hp%%=%d mp%%=%d -> %s  (%s)'):format(hpp, mpp, tostring(want), why))
        if want then
            local p = lastSent(W2)
            check(p and p[1] == 'useOnCreature' and p[2].x == 0xFFFF and p[2].y == 0
                  and p[2].z == 0 and p[3] == want and p[4] == 0 and p[5] == 1,
                  '   packet: useOnCreature({0xFFFF,0,0}, 23374, stack 0, ownId)  -- y is 0, NOT the id',
                  sentStr(W2))
        else
            eq(#W2.sent, 0, '   no packet at all')
        end
    end

    -- an unknown origin can never fire
    do
        local W2 = newWorld()
        local cfg = loadJson('vBot_configs/profile_1/HealBot.json')
        cfg.healbot[1].spellTable = { { spell = 'exura', origin = 'LUCK', sign = '<',
                                        value = 100, cost = 0, enabled = true } }
        local h2 = healbot.new(W2.bot, cfg); W2.bot.now = now()
        eq(h2:spellTick(), nil, 'an unknown origin token can never match')
    end
end

--=============================================================================
head('H3. spell cooldown prediction over simulated time')
--=============================================================================
do
    local W = newWorld()
    -- one rule only, so a blocked rule cannot be masked by the lower one firing
    -- (that fall-through is proved separately in H2).
    local cfg1 = loadJson('vBot_configs/profile_1/HealBot.json')
    cfg1.healbot[1].spellTable[2] = nil
    local hb = healbot.new(W.bot, cfg1)
    W.state.player.maxHealth, W.state.player.health = 100, 50   -- HP% 50 -> rule 1
    W.bot.now = now()

    clearSent(W)
    eq((hb:spellTick() or {}).spell, 'exura gran tio', 'first cast goes out (no cooldown data)')

    -- vBot's spell loop deliberately RE-SENDS every 50 ms until 0xA4/0xA5 lands
    -- (HealBot.lua:638-643).  We reproduce that by default.
    advance(50); W.bot.now = now()
    eq((hb:spellTick() or {}).spell, 'exura gran tio',
       'and re-fires on the next tick -- the documented, intentional re-send')

    -- now the server answers: group 2 (Healing) is on cooldown for 1000 ms
    W.client.events.emit('spellGroupCooldown', { groupId = 2, delay = 1000 })
    local t0 = now()
    eq(hb:spellTick(), nil, 'the 0xA5 group cooldown blocks the cast')
    advance(999); W.bot.now = now()
    eq(hb:spellTick(), nil, '   still blocked at 999 ms (remaining 1 > ping 0)')
    advance(1); W.bot.now = now()
    eq((hb:spellTick() or {}).spell, 'exura gran tio', '   fires again at exactly 1000 ms')

    -- the MAX rule: the spell's OWN cooldown outlives the group's
    W.client.events.emit('spellGroupCooldown', { groupId = 2, delay = 1000 })
    W.client.events.emit('spellCooldown', { spellId = 273, delay = 4000 })  -- Spirit Mend
    advance(1500); W.bot.now = now()
    eq(hb:spellTick(), nil, 'getRealSpellRemaining takes the MAX of own(4000) and group(1000)')
    eq(math.floor(hb.sh:realSpellRemaining('exura gran tio')), 2500, '   remaining is 2500 ms')
    advance(2500); W.bot.now = now()
    eq((hb:spellTick() or {}).spell, 'exura gran tio', '   and it clears at own-exhaustion end')

    -- ping lets it fire early by exactly one RTT
    W.client.events.emit('spellCooldown', { spellId = 273, delay = 1000 })
    advance(880); W.bot.now = now()
    hb.sh.ping = 0
    eq(hb:spellTick(), nil, 'remaining 120 ms, ping 0 -> blocked')
    hb.sh.ping = 120
    eq((hb:spellTick() or {}).spell, 'exura gran tio', 'remaining 120 ms, ping 120 -> fires early')
    hb.sh.ping = 0

    -- Cooldown = false disables the gate entirely
    W.client.events.emit('spellCooldown', { spellId = 273, delay = 5000 })
    W.bot.now = now()
    eq(hb:spellTick(), nil, 'with Cooldown=true a fresh 5 s exhaust blocks')
    hb:profile().Cooldown = false
    eq((hb:spellTick() or {}).spell, 'exura gran tio', 'Cooldown=false ignores cooldowns entirely')
    hb:profile().Cooldown = true

    -- the optimistic post-cast mark (opts.optimisticSpellCooldown)
    local W2 = newWorld()
    local cfg2 = loadJson('vBot_configs/profile_1/HealBot.json')
    cfg2.healbot[1].spellTable[2] = nil
    local h2 = healbot.new(W2.bot, cfg2, { optimisticSpellCooldown = true })
    W2.state.player.maxHealth, W2.state.player.health = 100, 50
    W2.bot.now = now()
    eq((h2:spellTick() or {}).spell, 'exura gran tio', 'optimistic mode: first cast')
    advance(50); W2.bot.now = now()
    eq(h2:spellTick(), nil, '   ... and the SAME tick pattern is now silent for 1000 ms')
    advance(1000); W2.bot.now = now()
    eq((h2:spellTick() or {}).spell, 'exura gran tio', '   ... re-arms after the exhaustion')
end

--=============================================================================
head('H4. the item loop: exhaust, guards and throttles')
--=============================================================================
do
    local W = newWorld()
    local hb = healbot.new(W.bot, loadJson('vBot_configs/profile_1/HealBot.json'))
    W.state.player.maxHealth, W.state.player.health = 100, 50
    W.state.player.maxMana,   W.state.player.mana   = 100, 100
    W.bot.now = now()

    clearSent(W)
    check(hb:itemTick() ~= nil, 'a potion goes out')
    eq(#W.sent, 1, '   exactly one packet')
    eq(hb.sh:getMultiUseCooldown(), 1000, '   the shared use slot is now 1000 ms')

    advance(999); W.bot.now = now(); clearSent(W)
    eq(hb:itemTick(), nil, 'the item loop refuses while the shared slot is busy (999 ms)')
    eq(#W.sent, 0, '   and sends nothing')
    advance(1); W.bot.now = now()
    check(hb:itemTick() ~= nil, 'it fires again the instant the slot clears (1000 ms)')

    -- the 50 ms same-tick double-send guard inside useHealItem
    clearSent(W)
    hb.sh.useCooldownExpiresAt = 0
    eq(hb:useHealItem(23374), false, 'useHealItem refuses a second send inside 50 ms')
    eq(#W.sent, 0, '   nothing on the wire')
    advance(50); W.bot.now = now()
    hb.sh.useCooldownExpiresAt = 0
    eq(hb:useHealItem(23374), true, '   and allows it once 50 ms have passed')

    -- the two AttackBot hold-offs
    advance(2000); W.bot.now = now(); clearSent(W)
    hb.sh.useCooldownExpiresAt = 0
    hb.sh.attackBotFiringUntil = now() + 150
    eq(hb:itemTick(), nil, 'AttackBotFiringUntil blocks the item loop')
    hb.sh.attackBotFiringUntil = 0
    hb.sh.attackBotRuneReadyUntil = now() + 250
    eq(hb:itemTick(), nil, 'AttackBotRuneReadyUntil blocks it too (a rune is waiting)')
    hb.sh.attackBotRuneReadyUntil = 0
    check(hb:itemTick() ~= nil, 'with both clear the potion goes out')

    -- ping compensation shortens the shared slot (HealBot.lua:48-62)
    hb.sh.useCooldownExpiresAt = now() + 1000
    hb.sh.ping = 200                                     -- > 150 -> compensation 170
    eq(hb.sh:pingCompensation(), 170, 'getPingCompensation() = ping - 30 above 150 ms')
    eq(hb.sh:getMultiUseCooldown(), 830, '   so the effective wait is 830 ms')
    hb.sh.ping = 100
    eq(hb.sh:pingCompensation(), 0, '   and 0 at or below 150 ms')
    eq(hb.sh:getMultiUseCooldown(), 1000, '   leaving the full 1000 ms')
    hb.sh.ping = 0

    -- the looting throttle (Interval + MessageDelay).  delay() postpones the NEXT
    -- invocation only -- this pass still completes.
    local W2 = newWorld()
    local cfg = loadJson('vBot_configs/profile_1/HealBot.json')
    cfg.healbot[1].Interval = true
    local h2 = healbot.new(W2.bot, cfg, { targetBotLooting = true })
    W2.state.player.maxHealth, W2.state.player.health = 100, 50
    W2.bot.now = now()
    check(h2:itemTick() ~= nil, 'looting throttle: THIS pass still fires')
    eq(h2.itemLoopBlockedUntil - now(), 700, '   and the NEXT one is postponed 700 ms')
    h2.itemLoopBlockedUntil = 0
    h2.sh.useCooldownExpiresAt = 0
    h2:profile().MessageDelay = true
    h2.lastHealItemUse = 0
    check(h2:itemTick() ~= nil, '   MessageDelay=true still fires')
    eq(h2.itemLoopBlockedUntil - now(), 200, '   ... but throttles to the SHORTER 200 ms')

    -- Visible=true adds the hasItemAvailable gate
    local W3 = newWorld()
    local cfg3 = loadJson('vBot_configs/profile_1/HealBot.json')
    cfg3.healbot[1].Visible = true
    local h3 = healbot.new(W3.bot, cfg3)
    W3.state.player.maxHealth, W3.state.player.health = 100, 50
    W3.bot.now = now()
    eq(h3:itemTick(), nil, 'Visible=true and no visible potion -> nothing fires')
    W3.state.containers[1] = { id = 1, items = { { id = 23374, count = 5 } } }
    check(h3:itemTick() ~= nil, '   an OPEN container holding the potion satisfies it')
    W3.state.containers[1] = nil
    W3.state.inventoryCounts = { [23374 * 256] = 3 }     -- opcode 0xF5
    h3.sh.useCooldownExpiresAt = 0; h3.lastHealItemUse = 0
    check(h3:itemTick() ~= nil, '   so does the 0xF5 server count with every bag CLOSED')
end

--=============================================================================
head('H5. dead / not-in-game / PZ guards')
--=============================================================================
do
    local W = newWorld()
    local hb = healbot.new(W.bot, loadJson('vBot_configs/profile_1/HealBot.json'))
    W.state.player.maxHealth, W.state.player.health = 100, 0     -- HP% 0
    W.bot.now = now(); clearSent(W)
    hb:tick()
    eq(#W.sent, 0, 'DEAD: hp 0 makes every "HP% <" rule match -- and we send NOTHING')
    W.state.player.health = 50
    W.state.player.isDead = true
    hb:tick()
    eq(#W.sent, 0, 'player.isDead alone also silences every loop')
    W.state.player.isDead = false
    W.bot.inGame = false
    hb:tick()
    eq(#W.sent, 0, 'not in game: silent')
    W.bot.inGame = nil
    hb.sh.cdSpell, hb.sh.cdGroup = {}, {}
    hb:tick()
    check(#W.sent > 0, 'and alive + in game it heals again')

    -- PZ: only the four HOLD buffs are suppressed, never the cures
    local W2 = newWorld()
    local cfg = loadJson('vBot_configs/profile_1/HealBot.json')
    cfg.ConditionPanel.holdUtamo, cfg.ConditionPanel.utamoCost = true, 40
    local h2 = healbot.new(W2.bot, cfg)
    W2.state.player.statesLo = shared.PlayerStates.Pz
    W2.bot.now = now(); clearSent(W2)
    eq(h2:conditionFastTick(), nil, 'ignoreInPz suppresses utamo inside a PZ')
    W2.state.player.statesLo = shared.PlayerStates.Pz + shared.PlayerStates.Paralyze
    eq(h2:conditionFastTick(), 'paralyse',
       'but the PARALYSIS cure has no PZ gate at all and still fires')
    eq(lastSent(W2)[2], 'utani gran hur', '   with the configured paralyseSpell')
end

--=============================================================================
head('H6. ConditionPanel')
--=============================================================================
do
    local S = shared.PlayerStates

    -- the real config: curePoison is ABSENT, only the misspelled curePosion=false
    local W = newWorld()
    local hb = healbot.new(W.bot, loadJson('vBot_configs/profile_1/HealBot.json'))
    W.state.player.statesLo = S.Poison
    W.bot.now = now(); clearSent(W)
    hb:conditionSlowTick()
    eq(#W.sent, 0, 'poison cure stays OFF: the file only carries the misspelled curePosion=false')

    hb:conditions().curePosion = true            -- flip the misspelled key
    hb:conditionSlowTick()
    eq(lastSent(W) and lastSent(W)[2], 'exana pox',
       'and the misspelled key is honoured when nothing else is set')
    hb:conditions().curePoison = false           -- the correct key WINS when present
    clearSent(W); hb:conditionSlowTick()
    eq(#W.sent, 0, 'the correctly-spelled key takes precedence when it exists')
    hb:conditions().curePoison = nil
    hb:conditions().curePosion = false

    -- the full cure table, one condition at a time
    local CURES = {
        { 'curePoison',    'poisonCost',    S.Poison,   'exana pox'  },
        { 'cureCurse',     'curseCost',     S.Cursed,   'exana mort' },
        { 'cureBleed',     'bleedCost',     S.Bleeding, 'exana kor'  },
        { 'cureBurn',      'burnCost',      S.Burn,     'exana flam' },
        { 'cureElectrify', 'electrifyCost', S.Energy,   'exana vis'  },
    }
    for _, c in ipairs(CURES) do
        local W2 = newWorld()
        local cfg = loadJson('vBot_configs/profile_1/HealBot.json')
        cfg.ConditionPanel[c[1]] = true
        local h2 = healbot.new(W2.bot, cfg)
        W2.state.player.statesLo = c[3]
        W2.state.player.mana = 1000
        W2.bot.now = now()
        h2:conditionSlowTick()
        eq(lastSent(W2) and lastSent(W2)[2], c[4], ('%s -> say("%s")'):format(c[1], c[4]))
        -- mana gate is >= here (NOT the strict < the spell rules use)
        clearSent(W2)
        W2.state.player.mana = cfg.ConditionPanel[c[2]]
        h2:conditionSlowTick()
        eq(lastSent(W2) and lastSent(W2)[2], c[4], ('   mana == cost still cures (>= , not <)'))
        clearSent(W2)
        W2.state.player.mana = cfg.ConditionPanel[c[2]] - 1
        h2:conditionSlowTick()
        eq(#W2.sent, 0, '   one mana short and it does not')
        -- hp gate
        clearSent(W2)
        W2.state.player.mana = 1000
        W2.state.player.maxHealth, W2.state.player.health = 100, 95
        h2:conditionSlowTick()
        eq(#W2.sent, 0, '   cures need hppercent() > 95; at exactly 95 nothing fires')
    end

    -- the group-2 gate kills the WHOLE slow loop
    do
        local W2 = newWorld()
        local cfg = loadJson('vBot_configs/profile_1/HealBot.json')
        cfg.ConditionPanel.curePoison = true
        local h2 = healbot.new(W2.bot, cfg)
        W2.state.player.statesLo = S.Poison
        W2.bot.now = now()
        W2.client.events.emit('spellGroupCooldown', { groupId = 2, delay = 1000 })
        clearSent(W2); h2:conditionSlowTick()
        eq(#W2.sent, 0, 'an active group-2 (Healing) cooldown returns from the slow loop')
        advance(1000); W2.bot.now = now()
        h2:conditionSlowTick()
        eq(lastSent(W2) and lastSent(W2)[2], 'exana pox', '   and it resumes when the group clears')
    end

    -- TWO INDEPENDENT chains: a cure AND a hold in the same 500 ms tick
    do
        local W2 = newWorld()
        local cfg = loadJson('vBot_configs/profile_1/HealBot.json')
        cfg.ConditionPanel.curePoison = true
        cfg.ConditionPanel.holdUtana  = true
        cfg.ConditionPanel.utanaCost  = 440
        local h2 = healbot.new(W2.bot, cfg)
        W2.state.player.statesLo = S.Poison
        W2.bot.now = now(); clearSent(W2)
        h2:conditionSlowTick()
        eq(#W2.sent, 2, 'the cure chain and the utura/utana chain are SEPARATE statements')
        eq(W2.sent[1][2], 'exana pox', '   cure first')
        eq(W2.sent[2][2], 'utana vid', '   then the hold, in the SAME tick')
        -- utana's 120 s interval
        clearSent(W2); advance(119999); W2.bot.now = now()
        h2:conditionSlowTick()
        local sawUtana = false
        for i = 1, #W2.sent do if W2.sent[i][2] == 'utana vid' then sawUtana = true end end
        eq(sawUtana, false, '   utana will not repeat inside 120000 ms')
        advance(2); W2.bot.now = now(); clearSent(W2)
        h2:conditionSlowTick()
        sawUtana = false
        for i = 1, #W2.sent do if W2.sent[i][2] == 'utana vid' then sawUtana = true end end
        eq(sawUtana, true, '   and repeats once the interval elapses')
    end

    -- the FAST loop: a strict elseif chain, utamo > haste > paralysis
    do
        local W2 = newWorld()
        local cfg = loadJson('vBot_configs/profile_1/HealBot.json')
        cfg.ConditionPanel.holdUtamo = true
        cfg.ConditionPanel.utamoCost = 40
        local h2 = healbot.new(W2.bot, cfg)
        W2.state.player.mana = 1000
        W2.bot.now = now()

        W2.state.player.statesLo = S.Paralyze
        h2.lastPosChange = now()                    -- "moving", so haste is eligible too
        eq(h2:conditionFastTick(), 'utamo',
           'all three eligible: utamo wins the elseif chain')
        W2.state.player.statesLo = S.Paralyze + S.ManaShield
        eq(h2:conditionFastTick(), 'haste', '   with a mana shield up, haste is next')
        W2.state.player.statesLo = S.Paralyze + S.ManaShield + S.Haste
        eq(h2:conditionFastTick(), 'paralyse', '   and only then the paralysis cure')

        -- VERIFIER: NewManaShield (bit 26) also satisfies the utamo guard
        W2.state.player.statesLo = S.NewManaShield
        eq(h2:conditionFastTick(), 'haste',
           'NewManaShield (2^26) suppresses utamo just like ManaShield (VERIFIER)')
        eq(shared.PlayerStates.NewManaShield, 67108864, '   NewManaShield == 67108864')

        -- haste only within 3 s of the last step
        W2.state.player.statesLo = S.ManaShield
        h2.lastPosChange = now() - 2999
        eq(h2:conditionFastTick(), 'haste', 'haste fires 2999 ms after the last step')
        h2.lastPosChange = now() - 3000
        eq(h2:conditionFastTick(), nil, '   and never at 3000 ms -- standing still, no haste')
        -- ... and the position event re-arms it
        W2.client.events.emit('positionChange', { pos = { x = 1, y = 1, z = 7 } })
        eq(h2:conditionFastTick(), 'haste', '   a positionChange re-arms the window')

        -- stopHaste + a target
        h2:conditions().stopHaste = true
        h2.opts.hasTarget = true
        h2.opts.caveBotActionAllowed = false
        eq(h2:conditionFastTick(), nil, 'stopHaste + a target + CaveBot blocked -> no haste')
        h2.opts.caveBotActionAllowed = true
        eq(h2:conditionFastTick(), 'haste', '   ... unless CaveBot is allowed to act')
        h2.opts.hasTarget = nil; h2.opts.caveBotActionAllowed = nil
        h2:conditions().stopHaste = false

        -- the haste branch consults the spell's own cooldown
        W2.client.events.emit('spellCooldown', { spellId = 39, delay = 2000 })  -- utani gran hur
        eq(h2:conditionFastTick(), nil, 'an active cooldown on the haste spell suppresses it')
        advance(2000); W2.bot.now = now()
        eq(h2:conditionFastTick(), 'haste', '   and it returns when the cooldown ends')
    end

    -- utura's canCast() level/mana gate (VERIFIER: NOT a cooldown-only check)
    do
        local W2 = newWorld()
        local cfg = loadJson('vBot_configs/profile_1/HealBot.json')
        cfg.ConditionPanel.holdUtura = true
        cfg.ConditionPanel.uturaCost = 100
        cfg.ConditionPanel.uturaType = 'Utura'          -- stored with CAPITALS
        local h2 = healbot.new(W2.bot, cfg)
        W2.state.player.maxHealth, W2.state.player.health = 100, 80   -- < 90
        W2.state.player.mana, W2.state.player.level = 1000, 500
        W2.bot.now = now(); clearSent(W2)
        h2:conditionSlowTick()
        eq(lastSent(W2) and lastSent(W2)[2], 'utura',
           'uturaType "Utura" is LOWERCASED before it hits the wire')
        clearSent(W2)
        W2.state.player.level = 49                       -- 'utura' needs level 50
        h2:conditionSlowTick()
        eq(#W2.sent, 0, 'canCast enforces the spell level (utura = level 50)')
        W2.state.player.level = 500
        W2.state.player.mana = 74                        -- needs 75, and cost 100 too
        h2:conditionSlowTick()
        eq(#W2.sent, 0, '   and the spell mana requirement')
        W2.state.player.mana = 1000
        W2.state.player.health = 90
        clearSent(W2); h2:conditionSlowTick()
        eq(#W2.sent, 0, 'utura needs hppercent() < 90, so exactly 90 does not fire')
    end
end

--=============================================================================
head('H7. burst damage')
--=============================================================================
do
    local W = newWorld()
    local cfg = loadJson('vBot_configs/profile_1/HealBot.json')
    cfg.healbot[1].spellTable = { { spell = 'exura gran', origin = 'burst', sign = '>',
                                    value = 300, cost = 0, enabled = true } }
    local hb = healbot.new(W.bot, cfg)
    W.bot.now = now()

    eq(hb:burstDamageValue(), 0, 'fewer than two samples -> 0')
    W.client.events.emit('textMessage', { text = 'You lose 200 hitpoints due to an attack by a dragon.' })
    eq(hb:burstDamageValue(), 0, 'one sample is still 0')
    advance(500); W.bot.now = now()
    W.client.events.emit('textMessage', { text = 'You lose 200 hitpoints due to an attack by a dragon.' })
    eq(hb:burstDamageValue(), 800, 'two 200s over 0.5 s -> ceil(400/0.5) = 800 dps')
    check(hb:spellTick() ~= nil, "a 'burst >= 300' rule fires")
    W.client.events.emit('textMessage', { text = 'You see a dragon.' })
    eq(#hb.dmg, 2, 'a non-damage message is ignored')
    W.client.events.emit('textMessage', { text = 'You lose 30 hitpoints.' })
    eq(#hb.dmg, 2, "'you lose' without 'due to' is ignored")

    -- the scheduled wipe (vlib.lua:61-63) -- the only thing that returns it to 0
    advance(3100); W.bot.now = now()
    W.bot:tick()                       -- drains the scheduler
    eq(hb:burstDamageValue(), 0, 'the schedule(3050) wipe empties the table once damage stops')
    eq(#hb.dmg, 0, '   the sample table really is empty')
end

--=============================================================================
head('H8. the four macros register at the documented periods')
--=============================================================================
do
    local W = newWorld()
    local hb = healbot.new(W.bot, loadJson('vBot_configs/profile_1/HealBot.json'))
    local periods = {}
    for _, m in ipairs(W.bot._macros) do periods[#periods + 1] = m.timeout end
    eq(#W.bot._macros, 4, 'four macros')
    eq(table.concat(periods, ','), '500,50,50,100',
       'periods 500 / 50 / 50(clamped from 20) / 100, in Conditions-first order')
    local allOn = true
    for _, m in ipairs(W.bot._macros) do if not m.enabled then allOn = false end end
    eq(allOn, true, 'all four are UNNAMED macros, so all are enabled unconditionally')

    W.state.player.maxHealth, W.state.player.health = 100, 50
    clearSent(W)
    advance(1000)
    for _ = 1, 3 do W.bot:tick(); advance(10) end
    check(#W.sent > 0, 'driving the real bot tick actually heals')
    eq(W.sent[1][1], 'talkSpell', '   through talkSpell')
    note('packets from three 10 ms ticks: ' .. sentStr(W))
end

--=============================================================================
head('A1. the user\'s real AttackBot.json, read verbatim')
--=============================================================================
local ABJSON = loadJson('vBot_configs/profile_1/AttackBot.json')
check(ABJSON ~= nil, 'AttackBot.json loads')
if ABJSON then
    eq(ABJSON.currentBotProfile, 1, 'currentBotProfile = 1')
    eq(#ABJSON.AttackBot, 5, 'exactly five profiles')
    local p = ABJSON.AttackBot[1]
    -- NOTE: `enabled` mirrors the user's own live in-game AttackBot toggle and
    -- drifts independently of this suite (see loadAttackBotJsonOn above) -- so
    -- this is read and reported, not asserted as a fixed value.
    note('profile 1 enabled (live toggle, informational only): ' .. tostring(p.enabled))
    eq(p.ServerCooldown, true, 'ServerCooldown mode')
    eq(p.Rotate, true, 'Auto Turn on')
    eq(p.PvpSafe, false, 'PvpSafe off')
    eq(#p.attackTable, 8, 'eight entries')
    eq(p.attackTable[1].spell, 'exori mas res', 'entry 1 (Balanced Brawl, pattern 19)')
    eq(p.attackTable[8].spell, 'exori amp pug', 'entry 8 (7 sqm targeted, maxHp 20)')
    eq(p.attackTable[3].augmented, nil, 'entry 3 legitimately has NO `augmented` key')
    eq(ABJSON.AttackBot[2].ServerCooldown, nil, 'profile 2 on disk has NO ServerCooldown key')

    local norm = attackbot.normalise(loadJson('vBot_configs/profile_1/AttackBot.json'))
    eq(norm.AttackBot[2].RuneDelay, 50, 'migration: RuneDelay defaults on ALL five profiles')
    eq(norm.AttackBot[2].RuneDelayEnabled, true, '   RuneDelayEnabled too')
    eq(norm.AttackBot[2].OptPenance, false, '   and the five Opt* flags')
    eq(norm.AttackBot[1].AntiRsRange, 5, 'AntiRsRange is present on the ACTIVE profile')
    local blank = attackbot.normalise({ AttackBot = { {}, {}, {}, {}, {} }, currentBotProfile = 3 })
    eq(blank.AttackBot[1].AntiRsRange, nil,
       'VERIFIER: AntiRsRange is migrated ONLY on the active profile, not all five')
    eq(blank.AttackBot[3].AntiRsRange, 5, '   ... which here is profile 3')
end

--=============================================================================
head('A2. counting monsters inside a pattern')
--=============================================================================
do
    local W = newWorld()
    local ab = attackbot.new(W.bot, ABJSON)
    W.bot.now = now()
    layGround(W.state, 100, 100, 7, 8)
    eq(ab.world.itemDataLevel, 'full', 'bot/world.lua has the full item table')

    placeCreature(W.state, 10, 'Dragon',  101, 100, 7)
    placeCreature(W.state, 11, 'Dragon',  102, 100, 7, { hp = 40 })
    placeCreature(W.state, 12, 'Hydra',   100, 101, 7)
    placeCreature(W.state, 13, 'Summon',  100,  99, 7, { type = 3 })   -- own summon
    placeCreature(W.state, 14, 'Someone', 99,  100, 7, { type = 0 })   -- a player

    local grid = attackbot.PATTERNS.spellPatterns[4][3][1]   -- small area 7x7
    eq(ab:getMonstersInArea(5, W.state.player.pos, grid, 0, 100, false, true, nil), 3,
       'a 7x7 self-centred area counts 3 monsters (the player and the PLAYER are excluded)')
    eq(ab:getMonstersInArea(5, W.state.player.pos, grid, 0, 100, false, true, nil) == 3
       and W.state.creatures[13].isMonster == true, true,
       'game/state.lua marks the summon isMonster=true -- and we still do NOT count it')
    eq(ab:getMonstersInArea(5, W.state.player.pos, grid, 0, 50, false, true, nil), 1,
       'the HP window is inclusive on both ends: only the 40%% dragon survives 0..50')
    eq(ab:getMonstersInArea(5, W.state.player.pos, grid, 0, 100, false, { 'dragon' }, nil), 2,
       'the lowercase name whitelist keeps only the two dragons')
    eq(ab:getMonstersInArea(5, W.state.player.pos, grid, 0, 100, false, { ' hydra' }, nil), 0,
       "vBot's string.split does not trim, so a ' hydra' entry can never match")

    -- getSpectators with a POSITION centre passes direction 8, disabling letters
    local wave = attackbot.PATTERNS.spellPatterns[4][10][1]
    eq(ab:getMonstersInArea(5, W.state.player.pos, wave, 0, 100, false, true, nil), 0,
       'a LETTER grid counted from a position centre yields 0 (direction 8 disables N/E/S/W)')

    -- ... which is exactly why waves go through extractDirGrid
    local east = attackbot.extractDirGrid(wave, 'E')
    check(east:find('1', 1, true) ~= nil, 'extractDirGrid("E") produces a plain 1/0 grid')
    check(ab:getMonstersInArea(5, W.state.player.pos, east, 0, 100, false, true, nil) >= 1,
       '   and that grid does count the eastern monsters')

    -- the two malformed union grids parse to nothing, exactly like the C++
    eq(ab:getMonstersInArea(5, W.state.player.pos,
                            attackbot.PATTERNS.spellPatterns[4][13][1], 0, 100, false, true), 0,
       'spellPatterns[4][13][1] is 3x4 -- even height, so it counts NOTHING (C++ parity)')
end

--=============================================================================
head('A3. entry priority and direction picking (the REAL profile)')
--=============================================================================
do
    local W = newWorld()
    local ab = attackbot.new(W.bot, loadAttackBotJsonOn())
    W.bot.now = now()
    layGround(W.state, 100, 100, 7, 8)
    -- ONE monster 3 sqm due EAST.  monkDirPatterns[13] (Flurry of Blows) covers
    -- dx +1..+3 on its East grid but only dx -1/+1 on its North grid, so the
    -- direction scan has an unambiguous winner.
    local tgt = placeCreature(W.state, 20, 'Dragon', 103, 100, 7)
    ab:setTarget(tgt)
    W.state.player.direction = 0                                   -- facing NORTH
    clearSent(W)

    local r = ab:tick()
    eq(r, 'fired', 'the tick fires')
    eq(ab.lastSpell.spell, 'exori mas pug',
       'entries 1-6 all fail (name filter / harmony / count) -- entry 7 wins')
    eq(#W.sent, 2, 'two packets')
    eq(W.sent[1][1] .. ' ' .. tostring(W.sent[1][2]), 'turn 1',
       'Auto Turn: the TURN packet goes first, facing East')
    eq(W.sent[2][1] .. ' ' .. tostring(W.sent[2][2]) .. ' ' .. tostring(W.sent[2][3]),
       'talkSpell exori mas pug 3', '   then the cast, same tick, aim byte 3')
    eq(W.state.player.direction, 1, 'the local direction is updated immediately, like the C++')
    note('packets: ' .. sentStr(W))

    -- already facing the right way -> no turn packet
    clearSent(W)
    ab:tick()
    eq(#W.sent, 1, 'facing East already: only the cast goes out')
    eq(W.sent[1][1], 'talkSpell', '   no redundant turn')

    -- Rotate=false refuses to turn
    W.state.player.direction = 0
    ab:profile().Rotate = false
    clearSent(W)
    ab:tick()
    eq(#W.sent, 0, 'with Auto Turn off the wrong facing simply does not fire')
    ab:profile().Rotate = true

    -- a second monster promotes entry 6 (Greater Flurry, 2+) over entry 7.  The
    -- target moves to 4 sqm so the chain entry (3) stays out of range.
    W.state.player.direction = 1
    W.state:moveCreature(20, { x = 103, y = 100, z = 7 }, nil, { x = 104, y = 100, z = 7 })
    placeCreature(W.state, 21, 'Dragon', 101, 100, 7)
    clearSent(W)
    ab:tick()
    eq(ab.lastSpell.spell, 'exori gran mas pug',
       'two monsters in the East grid promote entry 6 (Greater Flurry, 2+)')

    -- the chain entry (3) takes over the moment the target is within 3 sqm
    W.state:moveCreature(20, { x = 104, y = 100, z = 7 }, nil, { x = 103, y = 100, z = 7 })
    clearSent(W)
    ab:tick()
    eq(ab.lastSpell.spell, 'exori med pug',
       'target at 3 sqm + 2 monsters within 5 -> entry 3 (Chained Penance) outranks it')
    eq(#W.sent, 1, '   the chain path fires without turning')

    -- the name filter gates entry 1: only a "true frost flower asura" unlocks it
    local W2 = newWorld()
    local a2 = attackbot.new(W2.bot, loadAttackBotJsonOn())
    W2.bot.now = now(); layGround(W2.state, 100, 100, 7, 8)
    local plain = placeCreature(W2.state, 22, 'Dragon', 103, 100, 7)
    a2:setTarget(plain)
    W2.state.player.direction = 1
    clearSent(W2); a2:tick()
    eq(a2.lastSpell.spell, 'exori mas pug', 'a plain Dragon at 3 sqm still only reaches entry 7')
    W2.state.creatures[22].name = 'True Frost Flower Asura'
    clearSent(W2); a2:tick()
    eq(a2.lastSpell.spell, 'exori mas res',
       'rename it to the whitelisted asura and entry 1 (Balanced Brawl) wins outright')
    eq(W2.sent[#W2.sent][2], 'exori mas res', '   packet carries the right formula')
end

--=============================================================================
head('A4. not enough monsters')
--=============================================================================
do
    local W = newWorld()
    local ab = attackbot.new(W.bot, loadAttackBotJsonOn())
    W.bot.now = now()
    layGround(W.state, 100, 100, 7, 9)
    -- one full-health monster, 8 sqm away: outside every pattern, and entry 8's
    -- maxHp is 20 so the targeted spell cannot take it either.
    local tgt = placeCreature(W.state, 30, 'Dragon', 108, 100, 7, { hp = 100 })
    ab:setTarget(tgt)
    clearSent(W)
    eq(ab:tick(), nil, 'nothing fires: every entry fails its count / distance / hp gate')
    eq(#W.sent, 0, '   and not a single packet is emitted')

    -- drop it to 15 % hp and pull it to 7 sqm: entry 8 (7 Sqm, 0-20 %) takes it
    W.state.creatures[30].healthPercent = 15
    W.state:moveCreature(30, { x = 108, y = 100, z = 7 }, nil, { x = 107, y = 100, z = 7 })
    clearSent(W)
    eq(ab:tick(), 'fired', 'at 15 %% hp and 7 sqm the targeted entry fires')
    eq(ab.lastSpell.spell, 'exori amp pug', '   entry 8, [7 Sqm] 1+ Creatures 0-20 %%')
    eq(W.sent[1][1], 'talkSpell', '   one talkSpell, no turn (category 1 never turns)')

    -- one sqm further and the distance gate closes again
    W.state:moveCreature(30, { x = 107, y = 100, z = 7 }, nil, { x = 108, y = 100, z = 7 })
    clearSent(W)
    eq(ab:tick(), nil, 'at 8 sqm the pattern-as-range gate (7) refuses')

    -- exact-count semantics when orMore is false
    do
        local W2 = newWorld()
        local cfg = { currentBotProfile = 1, AttackBot = { {
            name = 'P', enabled = true, ServerCooldown = true, Rotate = false,
            Visible = false, PvpSafe = false, attackTable = { {
                spell = 'exori', itemId = 0, category = 5, patternCategory = 4,
                pattern = 3, count = 2, orMore = false, minHp = 0, maxHp = 100,
                mana = 0, cooldown = 1, harmony = 0, monsters = true, enabled = true } } },
            {}, {}, {}, {} } }
        local a2 = attackbot.new(W2.bot, cfg)
        W2.bot.now = now(); layGround(W2.state, 100, 100, 7, 4)
        local t = placeCreature(W2.state, 40, 'Rat', 101, 100, 7); a2:setTarget(t)
        eq(a2:tick(), nil, 'orMore=false, count=2: one monster is not enough')
        placeCreature(W2.state, 41, 'Rat', 100, 101, 7)
        eq(a2:tick(), 'fired', '   two is exactly right')
        placeCreature(W2.state, 42, 'Rat', 99, 100, 7)
        clearSent(W2)
        eq(a2:tick(), nil, '   and THREE is too many -- orMore=false means EXACTLY')
    end
end

--=============================================================================
head('A5. PvP guards')
--=============================================================================
do
    -- (a) the PvpSafe grid veto
    local W = newWorld()
    local cfg = { currentBotProfile = 1, AttackBot = { {
        name = 'P', enabled = true, ServerCooldown = true, Rotate = false,
        Visible = false, PvpSafe = true, attackTable = { {
            spell = 'exori', itemId = 0, category = 5, patternCategory = 4,
            pattern = 3, count = 1, orMore = true, minHp = 0, maxHp = 100,
            mana = 0, cooldown = 1, harmony = 0, monsters = true, enabled = true } } },
        {}, {}, {}, {} } }
    local ab = attackbot.new(W.bot, cfg)
    W.bot.now = now(); layGround(W.state, 100, 100, 7, 6)
    local t = placeCreature(W.state, 50, 'Rat', 101, 100, 7); ab:setTarget(t)
    eq(ab:tick(), 'fired', 'PvpSafe with nobody around: fires')

    local stranger = placeCreature(W.state, 51, 'Stranger', 100, 103, 7, { type = 0 })
    clearSent(W)
    eq(ab:tick(), nil, 'a NON-PARTY player inside the safe grid vetoes the whole spell')
    eq(#W.sent, 0, '   silently, with no packet')

    stranger.shield = 3                                  -- ShieldYellow: a party member
    eq(ab:tick(), 'fired', 'the same player as a PARTY member (shield 3) does not veto')
    stranger.shield = 1                                  -- ShieldWhiteYellow
    eq(ab:tick(), 'fired', '   shield 1 counts as party for the veto too')
    stranger.shield = 0
    clearSent(W)
    eq(ab:tick(), nil, '   and back to a stranger, the veto returns')

    -- getPlayers()'s deliberately different rule (VERIFIER): shield 1 IS counted
    stranger.shield = 1
    eq(ab:countPlayersNear(5), 1,
       'getPlayers() DOES count a ShieldWhiteYellow party member (the `~= 1` term)')
    stranger.shield = 3
    eq(ab:countPlayersNear(5), 0, '   but not any other party shield')
    stranger.shield = 0
    stranger.emblem = 1
    eq(ab:countPlayersNear(5), 0, '   nor a green-emblem (guild) player')
    stranger.emblem = 0

    -- (b) the pvpMode short-circuit: no counts, no patterns, no name filter
    local W2 = newWorld()
    local cfg2 = { currentBotProfile = 1, AttackBot = { {
        name = 'P', enabled = true, ServerCooldown = true, Rotate = false,
        Visible = false, PvpSafe = false, pvpMode = true, attackTable = { {
            spell = 'exori gran', itemId = 0, category = 1, patternCategory = 1,
            pattern = 1, count = 99, orMore = false, minHp = 0, maxHp = 100,
            mana = 0, cooldown = 1, harmony = 0, monsters = { 'nothing' },
            enabled = true } } }, {}, {}, {}, {} } }
    local a2 = attackbot.new(W2.bot, cfg2)
    W2.bot.now = now(); layGround(W2.state, 100, 100, 7, 6)
    local victim = placeCreature(W2.state, 60, 'Victim', 105, 105, 7, { type = 0 })
    a2:setTarget(victim)
    clearSent(W2)
    eq(a2:tick(), 'fired',
       'pvpMode fires at the target ignoring count(99), the name filter and the pattern')
    eq(W2.sent[1][2], 'exori gran', '   packet goes out')
    victim.healthPercent = 100
    a2:profile().attackTable[1].maxHp = 50
    clearSent(W2)
    eq(a2:tick(), nil, 'pvpMode still honours the target HP window')

    -- area runes are refused outright in pvpMode
    a2:profile().attackTable[1].maxHp = 100
    a2:profile().attackTable[1].category = 2
    a2:profile().attackTable[1].itemId = 3200
    a2:profile().attackTable[1].patternCategory = 2
    a2:profile().attackTable[1].pattern = 1
    clearSent(W2)
    eq(a2:tick(), 'hold', 'an Area Rune entry in pvpMode is refused')
    eq(#W2.sent, 0, '   with a warning and no packet')

    -- (c) the BlackList guard
    local W3 = newWorld()
    local cfg3 = { currentBotProfile = 1, AttackBot = { {
        name = 'P', enabled = true, ServerCooldown = true, Rotate = false,
        Visible = false, PvpSafe = false, BlackListSafe = true, AntiRsRange = 5,
        attackTable = { { spell = 'exori', itemId = 0, category = 5, patternCategory = 4,
            pattern = 3, count = 1, orMore = true, minHp = 0, maxHp = 100, mana = 0,
            cooldown = 1, harmony = 0, monsters = true, enabled = true } } },
        {}, {}, {}, {} } }
    local a3 = attackbot.new(W3.bot, cfg3, { blackList = { 'Nemesis' } })
    W3.bot.now = now(); layGround(W3.state, 100, 100, 7, 6)
    local t3 = placeCreature(W3.state, 70, 'Rat', 101, 100, 7); a3:setTarget(t3)
    eq(a3:tick(), 'fired', 'BlackListSafe with nobody listed nearby: fires')
    local rs = placeCreature(W3.state, 71, 'Nemesis', 104, 100, 7, { type = 0 })
    eq(a3:tick(), nil, 'a blacklisted player at Chebyshev 4 (< 5) stops the area spell')
    W3.state:moveCreature(71, { x = 104, y = 100, z = 7 }, nil, { x = 105, y = 100, z = 7 })
    eq(a3:tick(), 'fired', '   at exactly 5 it does not (the compare is STRICTLY <)')
    W3.state:moveCreature(71, { x = 105, y = 100, z = 7 }, nil, { x = 104, y = 100, z = 6 })
    eq(a3:tick(), nil, '   and the check is MULTI-FLOOR (|dz| <= 2)')
    rs.name = 'nemesis'
    eq(a3:tick(), 'fired', '   name comparison is CASE-SENSITIVE, so "nemesis" is not listed')
end

--=============================================================================
head('A6. area runes')
--=============================================================================
do
    local W = newWorld()
    local cfg = { currentBotProfile = 1, AttackBot = { {
        name = 'P', enabled = true, ServerCooldown = true, Rotate = false,
        Visible = false, PvpSafe = false, RuneDelay = 0, RuneDelayEnabled = false,
        attackTable = { { spell = '', itemId = 3200, category = 2, patternCategory = 2,
            pattern = 2, count = 3, orMore = true, minHp = 0, maxHp = 100, mana = 0,
            cooldown = 2, harmony = 0, monsters = true, enabled = true } } },
        {}, {}, {}, {} } }
    local ab = attackbot.new(W.bot, cfg)
    W.bot.now = now(); layGround(W.state, 100, 100, 7, 6)
    -- pattern 2 = "bomb", a 3x3 of ones.  Three rats around the FREE tile
    -- (102,100): getBestTileByPattern uses tile:isWalkable() with no argument, so
    -- an occupied tile is never a candidate -- the rune has to land on a gap.
    local t = placeCreature(W.state, 80, 'Rat', 102,  99, 7); ab:setTarget(t)
    placeCreature(W.state, 81, 'Rat', 102, 101, 7)
    placeCreature(W.state, 82, 'Rat', 103, 100, 7)

    clearSent(W)
    eq(ab:tick(), 'fired', 'three rats around one free tile -> the area rune goes out')
    eq(ab.lastSpell.amount, 3, '   the best tile covers all three')
    eq(ab.lastSpell.pos.x .. ',' .. ab.lastSpell.pos.y, '102,100',
       '   and it is the unoccupied centre tile, not one of the rats')
    local p = W.sent[#W.sent]
    eq(p[1], 'useWith', '   packet is useWith')
    check(p[2].x == 0xFFFF and p[2].y == 0 and p[2].z == 0,
          '   from the inventory sentinel {0xFFFF,0,0}')
    eq(p[3], 3200, '   with the rune id')
    eq(p[4], 0, '   source stackpos 0')
    check(p[5] ~= nil and ab:distFromPlayer(p[5]) < 4,
          '   aimed at a tile strictly within 4 sqm', tostring(p[5] and p[5].x))
    eq(p[6], GROUND, '   at the ground item (getTopUseThing on an empty tile)')
    eq(ab.sh:getMultiUseCooldown(), 1000, 'recordLocalUseCooldown fired with the packet')
    check(ab.sh.attackBotFiringUntil >= now() + 400, 'AttackBotFiringUntil reserved now+400')

    -- ... and HealBot now yields to it
    local hb = healbot.new(W.bot, loadJson('vBot_configs/profile_1/HealBot.json'))
    W.state.player.maxHealth, W.state.player.health = 100, 50
    clearSent(W)
    eq(hb:itemTick(), nil, 'HealBot refuses to drink while AttackBot holds the slot')
    eq(#W.sent, 0, '   the handshake really is shared state, not two copies')

    -- the "hold the tick" rule: a rune ready but the shared slot busy
    do
        local W2 = newWorld()
        local cfg2 = { currentBotProfile = 1, AttackBot = { {
            name = 'P', enabled = true, ServerCooldown = true, Rotate = false,
            Visible = false, PvpSafe = false, RuneDelayEnabled = false,
            attackTable = {
              { spell = '', itemId = 3155, category = 3, patternCategory = 3, pattern = 5,
                count = 1, orMore = true, minHp = 0, maxHp = 100, mana = 0, cooldown = 1,
                harmony = 0, monsters = true, enabled = true },
              { spell = 'exori', itemId = 0, category = 5, patternCategory = 4, pattern = 3,
                count = 1, orMore = true, minHp = 0, maxHp = 100, mana = 0, cooldown = 1,
                harmony = 0, monsters = true, enabled = true } } },
            {}, {}, {}, {} } }
        local a2 = attackbot.new(W2.bot, cfg2)
        W2.bot.now = now(); layGround(W2.state, 100, 100, 7, 4)
        local tt = placeCreature(W2.state, 90, 'Rat', 101, 100, 7); a2:setTarget(tt)
        clearSent(W2)
        eq(a2:tick(), 'fired', 'the targeted rune fires first (entry order)')
        eq(W2.sent[1][1], 'useOnCreature', '   as useOnCreature')
        eq(a2.sh:getMultiUseCooldown(), 1000, '   and takes the shared slot')
        clearSent(W2)
        eq(a2:tick(), 'hold',
           'next tick: the rune is READY but the slot is busy -> the WHOLE tick is held')
        eq(#W2.sent, 0, '   so the lower-priority SPELL cannot steal the slot')
        advance(1000); W2.bot.now = now(); clearSent(W2)
        eq(a2:tick(), 'fired', 'once the slot clears the rune fires again')
        eq(a2.sh.attackBotRuneReadyUntil, now() + 250, 'AttackBotRuneReadyUntil = now + 250')
    end

    -- the rune delay gate
    do
        local W2 = newWorld()
        local cfg2 = { currentBotProfile = 1, AttackBot = { {
            name = 'P', enabled = true, ServerCooldown = true, Rotate = false,
            Visible = false, PvpSafe = false, RuneDelay = 300, RuneDelayEnabled = true,
            attackTable = { { spell = '', itemId = 3155, category = 3, patternCategory = 3,
                pattern = 5, count = 1, orMore = true, minHp = 0, maxHp = 100, mana = 0,
                cooldown = 1, harmony = 0, monsters = true, enabled = true } } },
            {}, {}, {}, {} } }
        local a2 = attackbot.new(W2.bot, cfg2)
        W2.bot.now = now(); layGround(W2.state, 100, 100, 7, 4)
        local tt = placeCreature(W2.state, 95, 'Rat', 101, 100, 7); a2:setTarget(tt)
        clearSent(W2)
        eq(a2:tick(), 'hold', 'RuneDelay 300: the first tick only ARMS the timer')
        eq(#W2.sent, 0, '   nothing sent')
        eq(a2.sh.attackBotFiringUntil, now() + 310, '   and reserves the slot for delay + 10')
        advance(299); W2.bot.now = now()
        eq(a2:tick(), 'hold', '   still waiting at 299 ms')
        advance(1); W2.bot.now = now()
        eq(a2:tick(), 'fired', '   and fires at exactly 300 ms')
        eq(W2.sent[1][1], 'useOnCreature', '   with the rune packet')
    end
end

--=============================================================================
head('A7. mana / harmony / cooldown gates, and the optimizer flag')
--=============================================================================
do
    local W = newWorld()
    local ab = attackbot.new(W.bot, loadAttackBotJsonOn())
    W.bot.now = now(); layGround(W.state, 100, 100, 7, 8)
    -- three monsters in a vertical bar 4 sqm East (inside monkDirPatterns[16]'s
    -- East grid, outside [14]'s dy != 0 rows) plus one adjacent to the East.
    -- The target is the far one, so the chain entries stay out of range.
    local t = placeCreature(W.state, 100, 'Dragon', 104, 100, 7); ab:setTarget(t)
    placeCreature(W.state, 101, 'Dragon', 104,  99, 7)
    placeCreature(W.state, 102, 'Dragon', 104, 101, 7)
    placeCreature(W.state, 103, 'Dragon', 101, 100, 7)
    W.state.player.direction = 1                       -- already facing East: no turn noise

    eq(ab.optimizers, false,
       'the five spell optimizers are OFF even though the JSON turns three of them ON')
    eq(ab:profile().OptPenance, true, '   (the config really does say OptPenance=true)')

    -- entry.mana is a PERCENT; canCast separately enforces the spell's absolute
    -- mana (VERIFIER), so maxMana is large enough that 10 % still buys the spell.
    W.state.player.harmony = 0
    W.state.player.maxMana = 5000
    W.state.player.mana = 450                                   -- manapercent 9 < 10
    clearSent(W)
    eq(ab:tick(), nil, 'every entry needs manapercent() >= entry.mana, and the cheapest is 10')
    W.state.player.mana = 500                                   -- manapercent exactly 10
    eq(ab:tick(), 'fired', '   at exactly 10 % the cheapest entry fires')
    eq(ab.lastSpell.spell, 'exori mas pug', '   which is entry 7 (mana 10)')
    W.state.player.mana = 750                                   -- 15 %
    eq(ab:tick(), 'fired', '   at 15 % entry 6 (mana 15) becomes affordable')
    eq(ab.lastSpell.spell, 'exori gran mas pug', '   and outranks entry 7')

    -- harmony: entry 5 (Sweeping Takedown) needs 5, entry 6 does not
    W.state.player.mana = 1000                                  -- 20 %
    ab:tick()
    eq(ab.lastSpell.spell, 'exori gran mas pug', 'harmony 0 skips entry 5 (which needs 5)')
    W.state.player.harmony = 5
    ab:tick()
    eq(ab.lastSpell.spell, 'exori mas nia', 'harmony 5 lets entry 5 (Sweeping Takedown) win')

    -- the cooldown gate: a blocked HIGH-priority entry hands the tick down
    W.client.events.emit('spellCooldown', { spellId = 294, delay = 8000 })  -- exori mas nia
    ab:tick()
    eq(ab.lastSpell.spell, 'exori gran mas pug',
       'an active cooldown on entry 5 hands the tick to the next entry that fits')
    W.client.events.emit('spellGroupCooldown', { groupId = 1, delay = 8000 })
    clearSent(W)
    eq(ab:tick(), nil, 'a group-1 (Attack) cooldown silences every attack spell')
    eq(#W.sent, 0, '   nothing on the wire')
    advance(8000); W.bot.now = now()
    eq(ab:tick(), 'fired', '   and they all come back when it expires')

    -- canCast enforces level and mana for a KNOWN formula (VERIFIER)
    W.state.player.level = 10
    advance(10000); W.bot.now = now()
    clearSent(W)
    eq(ab:tick(), nil, 'level 10 cannot cast any of these monk spells (canCast, ignoreRL=false)')
    W.state.player.level = 500
    eq(ab:tick(), 'fired', '   level 500 can')

    -- global gates
    W.state.player.statesLo = shared.PlayerStates.Pz
    clearSent(W)
    eq(ab:tick(), nil, 'inside a PZ the whole tick returns')
    W.state.player.statesLo = 0
    ab:setTarget(nil)
    eq(ab:tick(), nil, 'with no target the whole tick returns')
    ab:setTarget(t)
    W.state.player.isDead = true
    eq(ab:tick(), nil, 'dead: the whole tick returns')
    W.state.player.isDead = false
    ab:profile().Training = true
    W.state.creatures[100].name = 'Training Machine'
    clearSent(W)
    eq(ab:tick(), nil, 'Training mode refuses a target whose name contains "training"')
    ab:profile().Training = false

    -- the shared module really is ONE object
    local hb = healbot.new(W.bot, loadJson('vBot_configs/profile_1/HealBot.json'))
    eq(hb.sh, ab.sh, 'HealBot and AttackBot hold the SAME shared state object')
    eq(rawequal(hb.sh, W.bot._shared), true, '   which lives on the bot instance')
end

--=============================================================================
head('S1. bot/shared.lua -- say routing, cast(), CustomCooldown, status')
--=============================================================================
do
    local W = newWorld()
    local hb = healbot.new(W.bot, loadJson('vBot_configs/profile_1/HealBot.json'))
    local sh = hb.sh
    W.bot.now = now()

    clearSent(W)
    sh:say('exura gran')
    eq(sentStr(W), 'talkSpell(exura gran,3)',
       'a KNOWN formula goes out as an aimed spell (SpellAimTarget 3, no position)')
    clearSent(W)
    sh:say('hocus pocus')
    eq(sentStr(W), 'talk(1,0,,hocus pocus,0)',
       'an UNKNOWN formula falls back to a plain Say with aim byte 0')
    clearSent(W)
    sh:sayAt('exori mas amp pug', { x = 105, y = 105, z = 7 })
    eq(W.sent[1][1] .. ' ' .. tostring(W.sent[1][3]), 'talkSpell 2',
       'castSpellAt uses SpellAimCursor (2) and appends the position')
    eq(W.sent[1][4].x, 105, '   with the aimed tile')

    -- cast(): delay < 100 degenerates to a plain say (this is what ServerCooldown's 30 does)
    clearSent(W); sh:cast('exura gran', 30)
    eq(#W.sent, 1, 'cast(words, 30) is just a say -- the ServerCooldown case')
    clearSent(W); sh:cast('exura gran', 1000)
    eq(#W.sent, 1, 'cast(words, 1000) registers the spell and says it immediately')
    clearSent(W); sh:cast('exura gran', 1000)
    eq(#W.sent, 0, '   and is silent inside the window')
    advance(1001); W.bot.now = now()
    clearSent(W); sh:cast('exura gran', 1000)
    eq(#W.sent, 1, '   then says again once the window elapses')
    -- the own-talk echo refreshes the timestamp (vlib.lua:249-253)
    W.client.events.emit('talk', { name = 'Tester', text = 'Exura Gran' })
    clearSent(W); sh:cast('exura gran', 1000)
    eq(#W.sent, 0, '   an own-talk echo re-arms the window')

    -- AttackBot CustomCooldown: MILLISECONDS on the spell path
    local W2 = newWorld()
    local cfg = { currentBotProfile = 1, AttackBot = { {
        name = 'P', enabled = true, ServerCooldown = false, CustomCooldown = true,
        Rotate = false, Visible = false, PvpSafe = false, attackTable = { {
            spell = 'exori', itemId = 0, category = 5, patternCategory = 4, pattern = 3,
            count = 1, orMore = true, minHp = 0, maxHp = 100, mana = 0, cooldown = 2000,
            harmony = 0, monsters = true, enabled = true } } }, {}, {}, {}, {} } }
    local ab = attackbot.new(W2.bot, cfg)
    W2.bot.now = now(); layGround(W2.state, 100, 100, 7, 4)
    local t = placeCreature(W2.state, 200, 'Rat', 101, 100, 7); ab:setTarget(t)
    clearSent(W2)
    eq(ab:tick(), 'fired', 'CustomCooldown spell: the first tick fires')
    eq(#W2.sent, 1, '   one packet')
    clearSent(W2); ab:tick()
    eq(#W2.sent, 0, '   cooldown 2000 is MILLISECONDS for a spell -- silent inside it')
    advance(2001); W2.bot.now = now(); clearSent(W2)
    ab:tick()
    eq(#W2.sent, 1, '   and it speaks again after 2001 ms')

    -- ... SECONDS on the rune path
    local W3 = newWorld()
    local cfg3 = { currentBotProfile = 1, AttackBot = { {
        name = 'P', enabled = true, ServerCooldown = false, CustomCooldown = true,
        Rotate = false, Visible = false, PvpSafe = false, RuneDelayEnabled = false,
        attackTable = { { spell = '', itemId = 3155, category = 3, patternCategory = 3,
            pattern = 5, count = 1, orMore = true, minHp = 0, maxHp = 100, mana = 0,
            cooldown = 2, harmony = 0, monsters = true, enabled = true } } },
        {}, {}, {}, {} } }
    local a3 = attackbot.new(W3.bot, cfg3)
    W3.bot.now = now(); layGround(W3.state, 100, 100, 7, 4)
    local t3 = placeCreature(W3.state, 201, 'Rat', 101, 100, 7); a3:setTarget(t3)
    clearSent(W3)
    eq(a3:tick(), 'fired', 'CustomCooldown rune: the first tick fires')
    a3.sh.useCooldownExpiresAt = 0                    -- take the shared slot out of the way
    advance(1999); W3.bot.now = now(); clearSent(W3)
    eq(a3:tick(), nil, '   cooldown 2 is SECONDS for a rune -- not ready at 1999 ms')
    advance(1); W3.bot.now = now()
    eq(a3:tick(), 'fired', '   and ready at exactly 2000 ms')

    -- status objects (BOT.md)
    local hs = hb:status()
    check(type(hs) == 'table' and hs.profile == 1 and hs.rules.spells == 2
          and hs.rules.items == 3, 'HealBot:status() carries the profile and rule counts')
    check(hs.conditions == true, '   and the ConditionPanel switch')
    local as = ab:status()
    check(type(as) == 'table' and as.entries == 1 and as.optimizers == false,
          'AttackBot:status() carries the entry count and the optimizer flag')
    check(as.target ~= nil and as.target.id == 200, '   and the current target')
end

--=============================================================================
io.write('\n================ bot M1 ================\n')
for _, m in ipairs(msgs) do io.write(m, '\n') end
io.write(('  TOTAL: %d passed, %d failed -> %s\n'):format(pass, fail,
         fail == 0 and 'PASS' or 'FAIL'))
if _G.BOT_M1_NO_EXIT then return { pass = pass, fail = fail, failures = msgs } end
os.exit(fail == 0 and 0 or 1)
