--[==[========================================================================
test/botsuite.lua -- the bot layer, end to end, offline.

    luajit test/botsuite.lua                 (from D:/Claude/otclient_web/luaclient)
    run.bat --selftest  /  ./run.sh --selftest     (this file is folded in)

There is NO live account and NO server anywhere in here.  Every world is built in
Lua on the REAL game/state.lua, with the REAL proto/items.lua metadata loaded from
assets/items1530.bin, and every packet is captured off a fake sender.  The bot's
CONFIGURATION comes from the user's real vBot 4.8 profile, read unchanged and
never written to (`readOnlyProfile = true`).

WHAT THIS FILE IS FOR, as opposed to the five per-module suites it embeds:
the module suites drive each module in isolation (`cb:tick()`, `tb:attack(...)`).
This one drives the WHOLE STACK through `bot:tick()` after `bot:wireModules()` --
one clock, one macro list, one walker, one shared cooldown slot -- and asserts the
places where two modules have to agree:

  * macro registration order == BOT.md priority order,
  * one world / path / walker shared by CaveBot and TargetBot,
  * TargetBot's attack is what makes AttackBot fire (`bot._attacking`),
  * TargetBot suspends CaveBot (`bot:isActionAllowed('cavebot')`),
  * HealBot and AttackBot share ONE use-cooldown slot (bot/shared.lua),
  * the BOT.md status object,
  * storage round-trips to disk without dropping the user's unknown fields.

Set `_G.BOTSUITE_NO_EXIT = true` before dofile()ing this file and it returns
{ pass=, fail=, failures={} } instead of exiting.
Set `_G.BOTSUITE_ONLY_INTEGRATION = true` to skip the five embedded suites.
==========================================================================]==]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. ROOT .. '/?/init.lua;' .. package.path
end

-- The user's REAL vBot profile -- resolved relative to this checkout first so the
-- identical file runs on Windows and under WSL.
local PROFILE
do
    local candidates = {
        ROOT .. '/../../otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
        'D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
        '/mnt/d/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
    }
    for _, c in ipairs(candidates) do
        local f = io.open(c .. '/vBot_configs/profile_1/HealBot.json', 'r')
        if f then f:close(); PROFILE = c; break end
    end
end

local items   = require('proto.items')
local state   = require('game.state')
local events  = require('lib.events')
local botmod  = require('bot.init')
local cfgmod  = require('bot.config')
local worldm  = require('bot.world')
local walkmod = require('bot.walker')

local function loadItems()
    if not items.loaded then items.load(ROOT .. '/assets/items1530.bin') end
end
loadItems()

-- ============================================================ tiny framework
local pass, fail, msgs = 0, 0, {}
local section = ''
local function S(name) section = name; io.write('\n-- ', name, '\n') end
local function ok(cond, desc, detail)
    if cond then
        pass = pass + 1
        io.write('   ok   ', desc, '\n')
    else
        fail = fail + 1
        local line = '   FAIL ' .. section .. ' / ' .. desc
                     .. (detail and ('  -- ' .. tostring(detail)) or '')
        msgs[#msgs + 1] = line
        io.write(line, '\n')
    end
    return cond
end
local function eq(got, want, desc)
    if got == want then return ok(true, desc .. ' = ' .. tostring(got)) end
    return ok(false, desc, ('got %s, want %s'):format(tostring(got), tostring(want)))
end
local function listStr(t)
    local o = {}
    for i = 1, #t do o[i] = tostring(t[i]) end
    return '{' .. table.concat(o, ',') .. '}'
end
local function eqList(got, want, desc)
    local g, w = listStr(got), listStr(want)
    if g == w then return ok(true, desc .. ' = ' .. g) end
    return ok(false, desc, ('got %s, want %s'):format(g, w))
end

-- ==================================================== ids from the REAL item table
-- (all verified by work item F1's dump of assets/items1530.bin)
local ID_GROUND   = 103     -- grass:  GROUND, groundSpeed 110, minimap 129
local ID_WALL     = 1025    -- stone wall: ON_BOTTOM|NOT_WALKABLE|NOT_MOVEABLE|BLOCK_PROJECTILE
local ID_CORPSE   = 3994    -- "dead rat": CORPSE + container
local ID_GOLD     = 3031    -- gold coin: stackable, pickupable
local ID_BACKPACK = 2854    -- backpack: container

-- ==================================================== synthetic world
local nextCreatureId = 7000

--- rows: ASCII, one char per tile.
---   '.' floor   '#' floor+wall   ' ' no tile at all
---   '@' player start   'X' goal   'm' floor + a monster   'c' floor + a corpse item
local function newWorld(rows, opts)
    opts = opts or {}
    local st = state.new()
    local baseX, baseY, z = opts.baseX or 1000, opts.baseY or 1000, opts.z or 7
    local a = st.world.awareRange
    a.left, a.top, a.right, a.bottom = 60, 60, 60, 60

    local start, goal, corpses, monsters = nil, nil, {}, {}
    for y = 1, #rows do
        local row = rows[y]
        for x = 1, #row do
            local ch = row:sub(x, x)
            local pos = { x = baseX + x - 1, y = baseY + y - 1, z = z }
            if ch ~= ' ' then
                st:addThing(pos, 0, { kind = 'item', id = ID_GROUND })
                if ch == '#' then st:addThing(pos, -2, { kind = 'item', id = ID_WALL }) end
                if ch == 'c' then
                    st:addThing(pos, -2, { kind = 'item', id = ID_CORPSE })
                    corpses[#corpses + 1] = pos
                end
                if ch == 'm' then
                    nextCreatureId = nextCreatureId + 1
                    local c = { id = nextCreatureId, pos = pos, name = opts.monsterName or 'Dragon',
                                type = 1, isMonster = true, healthPercent = 100,
                                passable = false, direction = 0,
                                outfit = { lookType = 128, lookTypeEx = 0 } }
                    st:addCreature(c)
                    st:addThing(pos, -2, { kind = 'creature', creatureId = c.id, id = 0x63 })
                    monsters[#monsters + 1] = c
                end
            end
            if ch == '@' then start = pos end
            if ch == 'X' then goal  = pos end
        end
    end

    st.player.id          = 1
    st.player.name        = 'Tester'
    st.player.pos         = start or { x = baseX, y = baseY, z = z }
    st.player.health      = opts.hp     or 1000
    st.player.maxHealth   = opts.maxHp  or 1000
    st.player.mana        = opts.mana   or 1000
    st.player.maxMana     = opts.maxMana or 1000
    st.player.level       = opts.level  or 500
    st.player.capacity    = 2000
    st.player.freeCapacity = 1500
    st.player.speed       = 500
    st.player.direction   = 0
    st.player.vocation    = opts.vocation or 0
    st.player.states      = 0
    st.player.skills      = {}
    st.player.inventory   = {}
    st.central = { x = st.player.pos.x, y = st.player.pos.y, z = st.player.pos.z }
    return { st = st, start = start, goal = goal, corpses = corpses, monsters = monsters,
             base = { x = baseX, y = baseY, z = z },
             at = function(dx, dy) return { x = baseX + dx, y = baseY + dy, z = z } end }
end

--- A capturing sender with every builder the bot layer calls.
local function newSender(clock)
    local sent = {}
    local s = { refuse = false, _sent = sent }
    local function rec(op, fields)
        return function(self, ...)
            local e = { op = op, t = clock.t, args = { ... } }
            local a = { ... }
            for i, name in ipairs(fields or {}) do e[name] = a[i] end
            sent[#sent + 1] = e
            if self and self.refuse then return nil end
            return 'body'
        end
    end
    s.walk          = rec('walk',   { 'dir' })
    s.turn          = rec('turn',   { 'dir' })
    s.stop          = rec('stop',   {})
    s.autoWalk      = function(_, dirs) sent[#sent+1] = { op='autoWalk', n=#dirs, t=clock.t }
                          return 'body', #dirs end
    s.talk          = rec('talk',      { 'mode', 'channel', 'to', 'text' })
    s.talkSpell     = rec('talkSpell', { 'text', 'aim', 'pos' })
    s.use           = rec('use',       { 'pos', 'id', 'stack', 'index' })
    s.useWith       = rec('useWith',   { 'fromPos', 'id', 'fromStack', 'toPos', 'toId', 'toStack' })
    s.useOnCreature = rec('useOnCreature', { 'pos', 'id', 'stack', 'creatureId' })
    s.move          = rec('move',   { 'fromPos', 'id', 'stack', 'toPos', 'count' })
    s.attack        = rec('attack', { 'id' })
    s.follow        = rec('follow', { 'id' })
    s.cancelAttackAndFollow = rec('cancelAttackAndFollow', {})
    s.setFightMode  = rec('setFightMode', { 'fight', 'chase', 'safe' })
    s.buyItem       = rec('buy',    { 'id', 'sub', 'amount' })
    s.sellItem      = rec('sell',   { 'id', 'sub', 'amount' })
    s.openContainer = rec('open',   { 'pos', 'id', 'stack', 'cid' })
    s.closeContainer= rec('close',  { 'cid' })
    s.ping          = rec('ping',   {})
    s.pingBack      = rec('pingBack', {})
    function s:clear() for i = #sent, 1, -1 do sent[i] = nil end end
    function s:all() return sent end
    function s:byKind(kind)
        local o = {}
        for i = 1, #sent do if sent[i].op == kind then o[#o + 1] = sent[i] end end
        return o
    end
    function s:count(kind) return #self:byKind(kind) end
    return s
end

--- The whole client + bot, wired exactly the way main.lua wires it.
local function newHost(F, opts)
    opts = opts or {}
    local clock = { t = 1000000 }
    local sender = newSender(clock)
    local bus = events.new()
    local logged = {}
    local function cap(f, ...)
        local line = tostring(f)
        if select('#', ...) > 0 then
            local okf, r = pcall(string.format, line, ...)
            if okf then line = r end
        end
        logged[#logged + 1] = line
    end
    local log = { info = cap, warn = cap, error = cap, debug = function() end }
    local client = { state = F.st, items = items, events = bus, sender = sender, log = log }

    local b = botmod.new(client, {
        profileDir      = opts.profileDir or PROFILE,
        vprofile        = opts.vprofile or 1,
        clock           = function() return clock.t end,
        storageSaveMs   = 0,
        readOnlyProfile = opts.readOnlyProfile ~= false,   -- never touch the real profile
    })
    b.inGame = true
    b:wireModules(opts.wire or {})
    b:start()                        -- what main.lua does on the "game started" event

    local H = { bot = b, clock = clock, sender = sender, bus = bus, log = logged,
                st = F.st, F = F, client = client }
    H.cb = b.modules.cavebot
    H.tb = b.modules.targetbot
    H.hb = b.modules.healbot
    H.ab = b.modules.attackbot
    H.sup = b.modules.supplies

    function H:advance(ms) clock.t = clock.t + ms end
    function H:tick(n, stepMs)
        for _ = 1, (n or 1) do
            clock.t = clock.t + (stepMs or 10)
            b:tick()
        end
    end
    function H:moveTo(pos)
        local old = F.st.player.pos
        F.st.player.pos = pos
        F.st.central = pos
        bus:emit('positionChange', { pos = pos, oldPos = old })
    end
    function H:stepDir(dir)
        local d = worldm.DELTA[dir]
        local pp = F.st.player.pos
        self:moveTo({ x = pp.x + d[1], y = pp.y + d[2], z = pp.z })
    end
    --- Let the "server" confirm whatever the walker put on the wire.
    function H:confirmSteps(limit)
        local guard = 0
        local wk = b.walker
        while #wk.expected > 0 and guard < (limit or 16) do
            guard = guard + 1
            self:stepDir(wk.expected[1])
        end
        return guard
    end
    function H:logged(pattern)
        for i = 1, #logged do if logged[i]:find(pattern, 1, true) then return logged[i] end end
        return nil
    end
    return H
end

local function addContainer(st, id, itemId, list, cap)
    local c = { id = id, name = 'bag', capacity = cap or 20, hasPages = false,
                firstIndex = 0, size = #list, items = list,
                item = { kind = 'item', id = itemId } }
    st.containers[id] = c
    return c
end

-- ============================================================================
S('the profile the whole suite reads')
do
    ok(PROFILE ~= nil, 'the user\'s vBot_4.8 profile was found',
       PROFILE or 'none of the three candidate paths exist')
    if PROFILE then
        io.write('        profile: ', PROFILE, '\n')
        local p = cfgmod.new{ profileDir = PROFILE, vprofile = 1 }
        ok(type(p:loadHealBot()) == 'table',   'HealBot.json decodes')
        ok(type(p:loadAttackBot()) == 'table', 'AttackBot.json decodes')
        ok(type(p:loadSupplies()) == 'table',  'Supplies.json decodes')
        ok(#p:listCavebots()   > 0, 'cavebot_configs/ lists ' .. #p:listCavebots() .. ' routes')
        ok(#p:listTargetbots() > 0, 'targetbot_configs/ lists ' .. #p:listTargetbots() .. ' configs')
    end
    ok(items.loaded, 'assets/items1530.bin is loaded')
end

-- ============================================================================
S('wiring: one world / path / walker, four modules, BOT.md macro order')
do
    local F = newWorld({ '.....', '..@..', '.....' })
    local H = newHost(F)
    local b = H.bot

    ok(b.modules.healbot   ~= nil, 'healbot is registered')
    ok(b.modules.attackbot ~= nil, 'attackbot is registered')
    ok(b.modules.targetbot ~= nil, 'targetbot is registered')
    ok(b.modules.cavebot   ~= nil, 'cavebot is registered')
    ok(b.modules.supplies  ~= nil, 'supplies is registered (through cavebot)')

    eq(b.world.itemDataLevel, 'full', 'bot/world.lua runs on the full v2 item table')
    ok(b.path.world == b.world, 'the pathfinder uses that same world')
    ok(H.cb.world == b.world and H.tb.world == b.world, 'CaveBot and TargetBot share the world')
    ok(H.cb.path  == b.path  and H.tb.path  == b.path,  'and the pathfinder')
    ok(H.cb.walker == b.walker and H.tb.walker == b.walker,
       'and the WALKER -- one step ledger, so the two can never double-step')
    ok(H.hb.sh == H.ab.sh, 'HealBot and AttackBot share ONE bot/shared.lua cooldown slot')
    ok(H.ab.world == b.world, 'AttackBot counts monsters through the same world')

    -- registration order == priority order == intra-tick send order
    local periods, names = {}, {}
    for i, m in ipairs(b._macros) do
        periods[i] = m.timeout
        names[i] = (#m.name > 0) and m.name or '-'
    end
    eq(#b._macros, 8, 'eight macros are registered')
    eqList(periods, { 500, 50, 50, 100, 50, 100, 50, 200 },
           'the periods, in registration order')
    eqList(names, { '-', '-', '-', '-', '-', '-', 'CaveBot', 'CaveBot AntiLost' },
           'only the two CaveBot macros are named (vBot keeps the rest unnamed)')
    -- 1-4 healbot (conditions500, conditions50, spells50, items100), 5 attackbot,
    -- 6 targetbot, 7-8 cavebot
    ok(b._macros[5].timeout == 50 and b._macros[6].timeout == 100,
       'attackbot (50 ms) precedes targetbot (100 ms), which precedes CaveBot')

    -- idempotence
    local before = #b._macros
    b:wireModules{}
    eq(#b._macros, before, 'wireModules is idempotent')
end

-- ============================================================================
S('a full bot tick heals, with the real HealBot.json')
do
    -- profile 1: spellTable[1] "exura gran tio" HP% < 75 cost 210, [2] "exura gran" < 95 cost 75
    local F = newWorld({ '.....', '..@..', '.....' }, { hp = 700, maxHp = 1000, mana = 1000 })
    local H = newHost(F)
    H.sender:clear()
    H:tick(30)
    local said = H.sender:byKind('talkSpell')
    ok(#said > 0, 'the heal went out through the full bot tick (' .. #said .. ' casts)')
    eq(said[1].text, 'exura gran tio', 'the 75% rule wins at 70% hp')
    eq(said[1].aim, 3, 'sent as a spell (SpellAimTarget == 3)')

    -- full hp: nothing
    local G = newWorld({ '.....', '..@..', '.....' }, { hp = 1000, maxHp = 1000 })
    local H2 = newHost(G)
    H2.sender:clear()
    H2:tick(30)
    local heals = 0
    for _, c in ipairs(H2.sender:byKind('talkSpell')) do
        if type(c.text) == 'string' and c.text:sub(1, 5) == 'exura' then heals = heals + 1 end
    end
    eq(heals, 0, 'at full health no HEAL is cast (ConditionPanel buffs still may)')

    -- dead: silent even though every "HP% <" rule matches
    local D = newWorld({ '.....', '..@..', '.....' }, { hp = 0, maxHp = 1000 })
    local H3 = newHost(D)
    H3.st.player.isDead = true
    H3.sender:clear()
    H3:tick(30)
    eq(#H3.sender:all(), 0, 'a dead player sends NOTHING (BOT.md death guard)')
end

-- ============================================================================
S('TargetBot picks the monster, and that is what makes AttackBot fire')
do
    -- the bridge under test: TargetBot writes bot._attacking; AttackBot is a passenger on it
    local F = newWorld({ '.......',
                         '.......',
                         '..@.m..',
                         '.......',
                         '.......' }, { hp = 1000, maxHp = 1000, mana = 1000, level = 500 })
    local mon = F.monsters[1]
    local H = newHost(F, { wire = {
        targetbot = { targeting = { { name = 'Dragon', priority = 5, danger = 3,
                                      maxDistance = 6, chase = false, keepDistance = false,
                                      dontLoot = true } },
                      looting = { items = {}, containers = {} } },
        enableTargetbot = true } })

    eq(H.tb:isOn(), true, 'TargetBot is on')
    eq(#H.tb.targeting, 1, 'the synthetic targeting list loaded')

    H.sender:clear()
    H:tick(40)

    local atk = H.sender:byKind('attack')
    ok(#atk > 0, 'TargetBot sent an attack')
    eq(atk[1].id, mon.id, 'at the Dragon')
    eq(H.tb.attackingId, mon.id, 'TargetBot remembers the target')
    eq(H.bot._attacking, mon.id, 'and MIRRORED it into bot._attacking (the AttackBot bridge)')
    ok(H.ab:target() ~= nil, 'so AttackBot now has a target')

    local spells = H.sender:byKind('talkSpell')
    local exori = nil
    for _, s in ipairs(spells) do
        if type(s.text) == 'string' and s.text:sub(1, 5) == 'exori' then exori = s; break end
    end
    ok(exori ~= nil, 'AttackBot fired an offensive spell in the same run',
       exori and exori.text or ('only: ' .. tostring(spells[1] and spells[1].text)))
    if exori then io.write('        AttackBot cast: ', exori.text, '\n') end

    -- and the mirror is cleared again
    H.bus:emit('attackCancel', {})
    eq(H.bot._attacking, nil, 'attackCancel clears the mirror too')
end

-- ============================================================================
S('arbitration: TargetBot suspends CaveBot, healing never yields')
do
    local F = newWorld({ '.........',
                         '.........',
                         '..@.....X',
                         '.........' }, { hp = 700, maxHp = 1000 })
    local H = newHost(F, { wire = {
        cavebot = { waypoints = {
            { action = 'goto', value = ('%d,%d,%d'):format(F.goal.x, F.goal.y, F.goal.z) },
            { action = 'label', value = 'end' } },
            config = { avoidFloorChange = false, stayPathEnabled = false,
                       antiLostEnabled = false } },
        enableCavebot = true,
        targetbot = { targeting = { { name = 'Dragon', priority = 5, maxDistance = 6 } },
                      looting = { items = {}, containers = {} } },
        enableTargetbot = true } })

    eq(H.bot:isActionAllowed('cavebot'), true, 'with nothing to fight CaveBot may act')

    -- TargetBot "acted" just now: CaveBot must freeze.  lastAction is re-armed on every
    -- tick because isActive() is a 300 ms window measured against the bot clock.
    H.sender:clear()
    local idx = H.cb.index
    for _ = 1, 20 do
        H.tb.lastAction = H.clock.t
        H:tick(1, 60)
    end
    eq(H.bot:isActionAllowed('cavebot'), false, 'an active TargetBot freezes CaveBot')
    eq(H.cb.index, idx, 'the waypoint index did not advance while frozen')
    eq(H.cb.lastStatus, 'yield:targetbot', 'and CaveBot says why')
    eq(H.sender:count('walk'), 0, 'CaveBot sent no step at all')
    ok(H.sender:count('talkSpell') > 0, 'but HealBot still healed -- healing never yields')

    -- the 150 ms lure grant re-opens the window
    H.tb.lastAction = H.clock.t
    H.tb:allowCaveBot(150)
    H:tick(1, 10)
    eq(H.bot:isActionAllowed('cavebot'), true, 'allowCaveBot(150) lets CaveBot act again')
    H:tick(1, 200)
    H.tb.lastAction = H.clock.t
    eq(H.bot:isActionAllowed('cavebot'), false, 'and the grant expires 150 ms later')
end

-- ============================================================================
S('CaveBot walks a synthetic route end to end through bot:tick()')
do
    local F = newWorld({ '.........',
                         '.........',
                         '..@.....X',
                         '.........' })
    local H = newHost(F, { wire = {
        cavebot = { waypoints = {
            { action = 'goto', value = ('%d,%d,%d'):format(F.goal.x, F.goal.y, F.goal.z) },
            { action = 'label', value = 'home' },
            { action = 'goto', value = ('%d,%d,%d'):format(F.start.x, F.start.y, F.start.z) },
            { action = 'gotolabel', value = 'home' } },
            config = { avoidFloorChange = false, stayPathEnabled = false,
                       antiLostEnabled = false, walkDelay = 0 } },
        enableCavebot = true } })

    eq(#H.cb.waypoints, 4, 'four waypoints')
    H.sender:clear()
    local reached = false
    for _ = 1, 400 do
        H:tick(1, 60)
        H:confirmSteps()
        if F.st.player.pos.x == F.goal.x and F.st.player.pos.y == F.goal.y then
            reached = true; break
        end
    end
    ok(reached, 'the character reached the goal waypoint')
    eq(F.st.player.pos.x, F.goal.x, 'ending x')
    ok(H.sender:count('walk') >= 6, 'and it took ' .. H.sender:count('walk') .. ' walk packets')

    -- keep going: the label jump must bring it home and then loop
    local home = false
    for _ = 1, 600 do
        H:tick(1, 60)
        H:confirmSteps()
        if F.st.player.pos.x == F.start.x and F.st.player.pos.y == F.start.y then
            home = true; break
        end
    end
    ok(home, 'the second goto walked it back to the start')
    ok(H.cb.stats.arrivals >= 1, 'goto arrivals recorded (' .. H.cb.stats.arrivals .. ')')
end

-- ============================================================================
S('CaveBot: a wall makes the waypoint unreachable and the route survives it')
do
    local F = newWorld({ '..#..',
                         '..#..',
                         '@.#.X',
                         '..#..',
                         '..#..' })
    local H = newHost(F, { wire = {
        cavebot = { waypoints = {
            { action = 'goto', value = ('%d,%d,%d'):format(F.goal.x, F.goal.y, F.goal.z) },
            { action = 'label', value = 'after' } },
            config = { avoidFloorChange = false, stayPathEnabled = false,
                       antiLostEnabled = false } },
        enableCavebot = true } })
    H.sender:clear()
    -- one pass is enough: an unreachable goto is skipped immediately, it does not retry
    for _ = 1, 20 do
        H:tick(1, 60)
        if H.cb.index == 2 then break end
    end
    eq(H.cb.index, 2, 'the walled-off waypoint was skipped on the first pass')
    eq(H.cb.noPath, 1, 'one noPath strike')
    eq(H.cb.lastStatus, 'ok:goto', 'the action returned false, which ADVANCES')
    eq(H.sender:count('walk'), 0, 'and not a single step was sent into the wall')
    ok(H.bot.stats.macroErrors == 0, 'no macro raised')

    -- and it keeps lapping instead of wedging
    for _ = 1, 40 do H:tick(1, 60) end
    ok(H.cb.stats.skips >= 2, 'the route kept lapping (' .. H.cb.stats.skips .. ' skips)')
    eq(H.bot.stats.macroErrors, 0, 'still no macro error')
end

-- ============================================================================
S('CaveBot: an unknown waypoint type warns ONCE and never aborts the route')
do
    local F = newWorld({ '..@..' })
    local H = newHost(F, { wire = {
        cavebot = { waypoints = {
            { action = 'frobnicate', value = 'x' },
            { action = 'frobnicate', value = 'y' },
            { action = 'label', value = 'end' } },
            config = { stayPathEnabled = false, antiLostEnabled = false } },
        enableCavebot = true } })
    H:tick(20, 60)
    local n = 0
    for _, line in ipairs(H.log) do
        if line:find('Invalid cavebot action: frobnicate', 1, true) then n = n + 1 end
    end
    eq(n, 1, 'exactly one warning for the two bad waypoints')
    ok(H.cb.index >= 1, 'the route kept running (index ' .. H.cb.index .. ')')
    eq(H.bot.stats.macroErrors, 0, 'and no macro error')
end

-- ============================================================================
S('looting: a corpse is queued, opened and emptied into the backpack')
do
    local F = newWorld({ '.....',
                         '..@c.',
                         '.....' })
    local corpsePos = F.corpses[1]
    local H = newHost(F, { wire = {
        targetbot = { targeting = { { name = 'Dragon', priority = 1 } },
                      looting = { items = { { id = ID_GOLD, count = 0 } },
                                  containers = { { id = ID_BACKPACK, count = 0 } },
                                  everyItem = false, maxDanger = 10, minCapacity = 100 } },
        enableTargetbot = true } })
    local loot = H.tb.loot
    eq(#loot.items, 1, 'the loot item list loaded')

    -- a monster we saw dies on the corpse tile
    local c = { id = 9001, name = 'Dragon', type = 1, isMonster = true, healthPercent = 100,
                pos = corpsePos, outfit = { lookType = 128, lookTypeEx = 0 } }
    H.st:addCreature(c)
    H.tb:spectatorsInRange(H.st.player.pos, 6)     -- records lastPos, like a real tick
    H.st:removeCreature(9001)
    H.bus:emit('creatureDisappear', c)
    H:advance(50)
    H:tick(5)
    ok(#loot.list > 0, 'the corpse was queued (' .. #loot.list .. ')')

    -- the open goes out
    -- our own loot bag has to be OPEN, or the looter reports "No space" and stops
    addContainer(H.st, 0, ID_BACKPACK, {})
    H.sender:clear()
    loot:process(0, 0)
    local op = H.sender:byKind('open')
    ok(#op > 0, 'the corpse container is opened')
    if #op > 0 then eq(op[1].id, ID_CORPSE, 'by the corpse item id') end

    -- the server answers with the container contents
    local corpseItems = { { kind = 'item', id = ID_GOLD, count = 37 },
                          { kind = 'item', id = 9636 } }        -- junk, not on the list
    addContainer(H.st, 1, ID_CORPSE, corpseItems)
    loot.isLootContainer[1] = true
    -- from here the LOOTER RUNS INSIDE THE REAL BOT TICK: the loot delay is measured on
    -- the bot clock, so nothing happens until time actually advances through tick().
    H.sender:clear()
    H:tick(3, 250)
    local mv = H.sender:byKind('move')
    ok(#mv > 0, 'the gold is moved out')
    if #mv > 0 then
        eq(mv[1].id, ID_GOLD, 'only the listed item is taken')
        eq(mv[1].fromPos.x, 0xFFFF, 'from the container pseudo-position')
        eq(mv[1].toPos.y, 0x40, 'into our backpack (container 0 -> y = 0x40|0)')
    end
    ok(#loot:getStatus() > 0, 'the looter reports a status while it works')
    eq(H.tb:isLooting(), true, 'so TargetBot:isLooting() is true (HealBot reads this)')
end

-- ============================================================================
S('supplies: the real Supplies.json thresholds drive the round gate')
do
    local F = newWorld({ '..@..' })
    local H = newHost(F)
    local sup = H.sup
    ok(sup ~= nil, 'the supplies module is reachable from the bot')
    local order = sup:itemOrder()
    local list  = sup:items()
    ok(#order > 0, 'the real Supplies.json lists ' .. #order .. ' supply items')

    -- every threshold parsed out of the JSON is a NUMBER, even though vBot stores strings
    local allNumbers = true
    for _, id in ipairs(order) do
        local it = list[id]
        if it and it.min ~= nil and type(it.min) ~= 'number' then allNumbers = false end
    end
    ok(allNumbers, 'the string thresholds in the file were tonumber()d')

    -- nothing in the backpack -> the round gate must ask for a refill
    H.st.inventoryCounts = {}
    local reason = sup:checkRound()
    ok(reason ~= nil, 'with an empty backpack a refill is required (' .. tostring(reason) .. ')')
    ok(tostring(reason):sub(1, 9) == 'supplies:', 'and it names the missing supply id')

    -- give it plenty of everything -> no refill
    local counts = {}
    for _, id in ipairs(order) do counts[id * 256] = 100000 end
    H.st.inventoryCounts = counts
    H.st.player.capacity = 100000
    H.st.player.freeCapacity = 100000
    eq(sup:checkRound(), nil, 'fully stocked, the gate lets the round continue')

    local stt = sup:status()
    ok(type(stt) == 'table' and stt[1] and stt[1].item ~= nil,
       'status() is BOT.md\'s {{item, count, threshold}} array')
end

-- ============================================================================
S('the BOT.md status object')
do
    local F = newWorld({ '.....', '..@m.', '.....' }, { hp = 800, maxHp = 1000 })
    local H = newHost(F, { wire = {
        cavebot = { waypoints = { { action = 'label', value = 'x' } },
                    config = { stayPathEnabled = false, antiLostEnabled = false } },
        enableCavebot = true,
        targetbot = { targeting = { { name = 'Dragon', priority = 5, maxDistance = 6 } },
                      looting = { items = {}, containers = {} } },
        enableTargetbot = true } })
    H:tick(30)
    local s = H.bot:status()

    ok(type(s) == 'table', 'status() returns a table')
    eq(s.on, true, 'on')
    ok(s.player and s.player.hp == 800 and s.player.maxHp == 1000, 'player.hp/maxHp')
    ok(s.player.pos and s.player.pos.z == 7, 'player.pos')
    ok(type(s.healbot) == 'table',   'healbot block')
    ok(type(s.attackbot) == 'table', 'attackbot block')
    ok(type(s.cavebot) == 'table',   'cavebot block')
    ok(s.cavebot.waypointCount == 1, 'cavebot.waypointCount')
    ok(s.cavebot.waypointIndex ~= nil, 'cavebot.waypointIndex')
    ok(type(s.targetbot) == 'table', 'targetbot block')
    ok(s.targetbot.target ~= nil, 'targetbot.target is populated while fighting')
    if s.targetbot.target then eq(s.targetbot.target.name, 'Dragon', 'target name') end
    ok(type(s.targetbot.danger) == 'number', 'targetbot.danger')
    ok(type(s.macros) == 'table' and #s.macros == 8, 'macros list')
    ok(type(s.supplies) == 'table', 'supplies block')
    -- it must be serialisable for the future web panel: no cycles
    local okj, js = pcall(cfgmod.jsonEncode, s)
    ok(okj and type(js) == 'string', 'the whole status object json-encodes (web panel ready)',
       not okj and tostring(js) or nil)
end

-- ============================================================================
S('storage: round-trips to disk, keeps unknown fields, and never touches a read-only profile')
do
    local tmp
    do
        local base = os.getenv('TMPDIR') or os.getenv('TEMP') or os.getenv('TMP') or '/tmp'
        tmp = (base:gsub('\\', '/')) .. '/luaclient_botsuite_' .. tostring(os.time())
              .. '_' .. tostring(math.random(1, 1e6))
    end
    cfgmod.mkdirp(tmp .. '/storage')
    -- a storage file with a field no bot code knows about
    local wrote = cfgmod.writeFileAtomic(tmp .. '/storage/profile_1.json',
        '{"userField":{"keepMe":42},"_macros":{"Exchange money":true}}')
    ok(wrote == true, 'a synthetic storage file was written to ' .. tmp)

    local F = newWorld({ '..@..' })
    local H = newHost(F, { profileDir = tmp, readOnlyProfile = false })
    eq(H.bot.storage.userField.keepMe, 42, 'the unknown field is in memory')
    eq(H.bot.storage._macros['Exchange money'], true, 'and the persisted macro state')

    H.bot.storage.newField = 'hello'
    ok(H.bot:saveStorage() == true, 'saveStorage() wrote it')
    local back = cfgmod.new{ profileDir = tmp, vprofile = 1 }:loadStorage()
    eq(back.userField.keepMe, 42, 'the unknown field survived the round trip')
    eq(back.newField, 'hello', 'and the new one was written')

    -- and a read-only bot refuses to write at all
    local G = newWorld({ '..@..' })
    local H2 = newHost(G, { profileDir = tmp })          -- readOnlyProfile defaults to true
    local okw, why = H2.bot:saveStorage()
    eq(okw, false, 'a read-only bot refuses to save')
    eq(why, 'read-only profile', 'with the documented reason')

    os.remove(tmp .. '/storage/profile_1.json')
end

-- ============================================================================
S('the user\'s real profile is never written by this suite')
do
    if PROFILE then
        local F = newWorld({ '..@..' })
        local H = newHost(F)                               -- read-only by construction
        H.cb:enable(); H.tb:setOn()
        local okw = H.bot:saveStorage()
        eq(okw, false, 'saveStorage() on the real profile is refused')
        eq(H.bot:stop(), true, 'stop() still succeeds (it just cannot persist)')
    else
        ok(false, 'no profile to check')
    end
end

-- ============================================================================
S('a `function` waypoint sees the bot api, and TargetBot/CaveBot are DOT-callable')
do
    -- the user's real routes call `TargetBot.setOn()` / `TargetBot.setOff()` with a dot
    -- (8 sites across cavebot_configs/*.cfg); our modules are OO instances, so the
    -- sandbox has to bind the receiver or every one of those waypoints would raise.
    local F = newWorld({ '..@..' })
    local H = newHost(F, { wire = {
        cavebot = { waypoints = {
            { action = 'function', value = 'TargetBot.setOff()\nreturn true' },
            { action = 'function', value = 'TargetBot.setOn()\nCaveBot.delay(10)\nreturn true' },
            { action = 'function', value = 'storage.__probe = { hp(), pos().z, true }\nreturn true' },
            { action = 'label', value = 'end' } },
            config = { stayPathEnabled = false, antiLostEnabled = false } },
        enableCavebot = true,
        targetbot = { targeting = { { name = 'Dragon', priority = 1 } }, looting = {} },
        enableTargetbot = true } })

    eq(H.tb:isOn(), true, 'TargetBot starts on')
    for _ = 1, 40 do
        H:tick(1, 60)
        if H.cb.index >= 4 then break end
    end
    ok(H.cb.index >= 3, 'the three function waypoints ran (index ' .. H.cb.index .. ')')
    eq(H.tb:isOn(), true, 'TargetBot.setOff() then .setOn() left it on -- the DOT call worked')
    eq(H.bot.stats.macroErrors, 0, 'and nothing raised')
    local probe = H.bot.storage.__probe
    ok(probe ~= nil, 'the sandbox exposes the bot/api.lua surface')
    if probe then
        eq(probe[1], 1000, 'hp() inside the waypoint')
        eq(probe[2], 7, 'pos().z inside the waypoint')
        eq(probe[3], true, 'storage is the bot storage, and writable from a waypoint')
    end
    H.bot.storage.__probe = nil

    -- a broken body is contained, warned about, and the route keeps going
    local G = newWorld({ '..@..' })
    local H2 = newHost(G, { wire = {
        cavebot = { waypoints = {
            { action = 'function', value = 'this is not lua(' },
            { action = 'label', value = 'end' } },
            config = { stayPathEnabled = false, antiLostEnabled = false } },
        enableCavebot = true } })
    for _ = 1, 20 do H2:tick(1, 60) end
    eq(H2.bot.stats.macroErrors, 0, 'a syntax error in a function waypoint kills nothing')
end

-- ============================================================================
S('client -> bot contract fields the modules read off game/state.lua')
do
    local F = newWorld({ '.....', '..@..', '.....' })
    local H = newHost(F)

    -- proto/parser.lua 0x17 now publishes the server beat; walker:stepDuration rounds to it
    H.st.serverBeat = 50
    local d50 = H.bot.walker:stepDuration(1)
    H.st.serverBeat = 200
    local d200 = H.bot.walker:stepDuration(1)
    ok(d50 % 50 == 40 or d50 > 0, 'stepDuration with beat 50 = ' .. tostring(d50))
    ok(d200 ~= d50, 'a different serverBeat gives a different step duration ('
                    .. tostring(d200) .. ')')
    H.st.serverBeat = nil

    -- state.ping (main.lua measures it off the 0x1E pong) reaches the walker
    H.st.ping = 275
    eq(H.bot.walker:pingMs(), 275, 'walker:pingMs() reads state.ping')
    H.st.ping = nil
    ok(H.bot.walker:pingMs() > 0, 'and falls back to the configured ping when absent')

    -- proto/parser.lua 0x7A now keeps the NPC offer list; cavebot's buysupplies reads it
    H.st.npcTrade = { open = true, items = {
        { id = 3031, subType = 0, name = 'gold coin', buyPrice = 1, sellPrice = 1, weight = 10 },
        { id = 23374, subType = 0, name = 'potion', buyPrice = 50, sellPrice = 25, weight = 100 } } }
    local offers = H.cb:npcOffers()
    ok(type(offers) == 'table' and #offers == 2, 'CaveBot sees the NPC offer list')
    eq(H.cb:npcTradeOpen(), true, 'and knows the trade window is open')
    H.st.npcTrade = { open = false, items = {} }
    eq(H.cb:npcTradeOpen(), false, 'and that it closed')

    -- state.inventoryCounts (opcode 0xC0) is what makes a CLOSED backpack count
    H.st.inventoryCounts = { [23374 * 256] = 412 }
    eq(H.sup:itemAmount(23374), 412, 'supplies counts the server-side inventory total')
end

-- ============================================================================
S('bot/api.lua exposes the BOT.md script surface')
do
    local F = newWorld({ '..@..' })
    local H = newHost(F)
    local a = H.bot.api
    ok(type(a) == 'table', 'bot.api exists')
    local required = {
        'say','yell','talkNpc','talkPrivate','use','useWith','useOnCreature','usePos',
        'moveItem','findItem','findItemCount','itemAmount','getSpectators','getCreatureById',
        'getPlayer','pos','hp','hpPercent','mana','manaPercent','level','cap','storage','now',
        'delay','schedule','macro','walk','turn','stopWalk','attack','follow','cancelAttack',
        'canCast','castSpell','isInPz','isDead','isWalking','distanceFromPlayer','getMonsters',
        'getPlayers','getNpcs','openContainer','closeContainer','getContainers','getBackpacks',
        'depositItems','withdrawItems' }
    local missing = {}
    for _, n in ipairs(required) do
        if a[n] == nil then missing[#missing + 1] = n end
    end
    ok(#missing == 0, 'all ' .. #required .. ' BOT.md names are present',
       #missing > 0 and table.concat(missing, ', ') or nil)
    eq(a.hp(), 1000, 'api.hp() reads the synthetic player')
    eq(a.pos().z, 7, 'api.pos()')
    ok(a.isDead() == false, 'api.isDead()')
end

-- ============================================================================
S('a bot tick never raises, even with a hostile world')
do
    -- no ground under the player, no creatures, empty route, everything enabled
    local st = state.new()
    st.player.id, st.player.name = 1, 'Ghost'
    st.player.pos = { x = 500, y = 500, z = 3 }
    st.player.health, st.player.maxHealth = 1, 1000
    st.player.mana, st.player.maxMana = 0, 1000
    st.player.level, st.player.capacity, st.player.speed = 8, 100, 220
    st.player.states, st.player.skills, st.player.inventory = 0, {}, {}
    st.central = st.player.pos
    local F = { st = st, start = st.player.pos, monsters = {}, corpses = {} }
    local H = newHost(F, { wire = {
        cavebot = { waypoints = { { action = 'goto', value = '400,400,3' } } },
        enableCavebot = true,
        targetbot = { targeting = { { name = '*', priority = 1 } }, looting = {} },
        enableTargetbot = true } })
    H:tick(200)
    eq(H.bot.stats.macroErrors, 0, '200 ticks on a groundless map, zero macro errors')
    eq(H.bot.stats.scheduleErrors, 0, 'and zero scheduled-callback errors')
    ok(H.bot.stats.ticks == 200, 'all ' .. H.bot.stats.ticks .. ' ticks ran')
end


-- ============================================================================
-- WORK ITEM W -- walk pacing.  Every assertion below fails on the pre-fix code.
--
-- The live evidence these pin (docs/live-findings.md "Bug 2"):
--   * state.player.speed is NEVER written by the wire; the local player's speed only ever
--     arrives on its CREATURE record (0x8F / the creature block of a map description).  The
--     walker therefore fell back to STEP_FALLBACK_MS = 200 ms for every step of every live
--     session, and paced walk packets 210-220 ms apart while the server granted 400 ms.
--   * CB:doWalking() returned FALSE once the stored lookahead was exhausted even though a
--     step was still unconfirmed; CB:tick() then fell through to the action, which re-pathed
--     from the STALE position and re-sent the same direction -- two steps per server beat and
--     a waypoint overshoot.
-- ============================================================================
S('work item W: the local player speed resolves off the creature record')
do
    local F = newWorld({ '.....', '..@..', '.....' })
    local H = newHost(F)
    local wk = H.bot.walker

    eq(select(2, wk:playerSpeed()), 'player', 'state.player.speed wins when it is usable')

    -- LIVE SHAPE: the wire never writes state.player.speed.
    F.st.player.speed = 0
    F.st.creatures[F.st.player.id] = { id = F.st.player.id, speed = 129,
                                       pos = F.st.player.pos }
    local sp, src = wk:playerSpeed()
    eq(sp, 129, 'the creature record is the fallback')
    eq(src, 'creature', 'and it is reported as such')
    ok(wk:stepDuration(1) ~= walkmod.STEP_FALLBACK_MS,
       'so stepDuration no longer collapses to the 200 ms fallback ('
       .. tostring(wk:stepDuration(1)) .. ' ms)')

    -- nothing at all -> the documented fallback is still the answer
    F.st.creatures[F.st.player.id] = nil
    eq(wk:playerSpeed(), nil, 'no speed anywhere -> nil')
    eq(wk:stepDuration(1), walkmod.STEP_FALLBACK_MS, 'and the 200 ms fallback applies')
end

-- ============================================================================
S('work item W: GameNewSpeedLaw and the camera-following padding')
do
    local F = newWorld({ '.....', '..@..', '.....' })
    local H = newHost(F)
    local wk = H.bot.walker
    local st = F.st

    st.serverBeat = 50
    st.player.speed = 0
    st.creatures[st.player.id] = { id = st.player.id, speed = 129, pos = st.player.pos }

    -- No speedA/B/C -> hasSpeedFormula() is false, the raw wire speed is the divisor.
    eq(wk:speedFormula(), nil, 'no constants -> no formula')
    eq(select(3, wk:stepSpeed()), false, 'stepSpeed reports it did not use the formula')
    eq(wk:stepSpeed(), 129, 'and the divisor is the raw speed')

    -- The REAL Gunzodus constants out of 0x17 LoginSuccess (run 1, 2026-09-06):
    --   serverBeat=50 speedA=1550.36 speedB=500 speedC=-9720.01, wire speed 129.
    -- calculatedStepSpeed = floor(1550.36*ln(129 + 500) - 9720.01 + 0.5) = 271
    -- ground speed 110 (ID_GROUND) -> ceil((1000*110/271)/50)*50 = 450, minus the fork's 10.
    st.speedA, st.speedB, st.speedC = 1550.36, 500, -9720.01
    eq(wk:stepSpeed(), 271, 'Creature::setSpeed m_calculatedStepSpeed')
    eq(select(3, wk:stepSpeed()), true, 'and the formula was used')
    eq(wk:stepDuration(1), 440, 'stepDuration = ceil((1000*110/271)/50)*50 - 10')
    -- isCameraFollowing() && isLocalPlayer() adds 10*max(1, preWalks); a headless client IS
    -- the local player, so a single outstanding step gets the un-corrected duration back.
    eq(wk:paceDuration(1), 450, 'paceDuration puts the -10 ms back for one pre-walk')
    eq(wk:confirmTimeoutMs(1), 540, 'confirm timeout = min(max(step, ping) + 100, 1000)')

    -- a zero constant disables the formula (creature.cpp:1103)
    st.speedB = 0
    eq(wk:speedFormula(), nil, 'speedB = 0 disables the formula')
    eq(wk:stepSpeed(), 129, 'and the raw speed is the divisor again')
end

-- ============================================================================
S('work item W: at most ONE step outstanding, paced by the computed duration')
do
    local F = newWorld({ '.........',
                         '.........',
                         '..@.....X',
                         '.........' })
    local H = newHost(F, { wire = {
        cavebot = { waypoints = {
            { action = 'goto', value = ('%d,%d,%d'):format(F.goal.x, F.goal.y, F.goal.z) } },
            config = { avoidFloorChange = false, stayPathEnabled = false,
                       antiLostEnabled = false, walkDelay = 10 } },
        enableCavebot = true } })
    local wk = H.bot.walker
    local st = F.st

    eq(wk.cfg.strictPacing, true, 'a real route turns strict pacing ON')

    st.serverBeat = 50
    st.player.speed = 0
    st.creatures[st.player.id] = { id = st.player.id, speed = 129, pos = st.player.pos }
    st.speedA, st.speedB, st.speedC = 1550.36, 500, -9720.01
    st.ping = 100
    H.sender:clear()

    -- 1500 ticks of 10 ms = 15 s of model time.  The "server" confirms a step only after
    -- the full step duration has elapsed, exactly like the real one.
    local maxOutstanding, confirmAt = 0, nil
    for _ = 1, 1500 do
        H:tick(1, 10)
        local n = #wk.expected
        if n > maxOutstanding then maxOutstanding = n end
        if n > 0 then
            confirmAt = confirmAt or (wk.lastSendAt + 450)
            if H.clock.t >= confirmAt then
                local d = worldm.DELTA[wk.expected[1]]
                local pp = st.player.pos
                H:moveTo({ x = pp.x + d[1], y = pp.y + d[2], z = pp.z })
                confirmAt = nil
            end
        end
    end

    eq(maxOutstanding, 1, 'never more than ONE walk packet in flight')

    local walks = H.sender:byKind('walk')
    ok(#walks >= 5, 'and it kept walking (' .. #walks .. ' packets)')
    local minGap = math.huge
    for i = 2, #walks do
        local g = walks[i].t - walks[i - 1].t
        if g < minGap then minGap = g end
    end
    -- walkDelay 10 + paceDuration 450 = 460; the 10 ms tick can only ever round UP.
    ok(minGap >= 460, 'the tightest packet interval is ' .. tostring(minGap)
                      .. ' ms >= walkDelay + paceDuration (460)')
    eq(wk.stats.confirmed, #walks, 'every packet that went out was confirmed')
    eq(wk.stats.lost, 0, 'and none timed out')
end

-- ============================================================================
S('work item W: an unconfirmed step is never re-sent from the stale position')
do
    -- The exact live regression: CB:doWalking() used to answer "not walking" as soon as the
    -- stored lookahead ran out, and CB:tick() re-pathed from a position the server had not
    -- moved yet.  Freeze the "server" (never confirm) and assert only ONE packet goes out.
    local F = newWorld({ '.........',
                         '..@.....X',
                         '.........' })
    local H = newHost(F, { wire = {
        cavebot = { waypoints = {
            { action = 'goto', value = ('%d,%d,%d'):format(F.goal.x, F.goal.y, F.goal.z) } },
            config = { avoidFloorChange = false, stayPathEnabled = false,
                       antiLostEnabled = false, walkDelay = 10 } },
        enableCavebot = true } })
    local wk = H.bot.walker
    F.st.serverBeat, F.st.ping = 50, 100
    H.sender:clear()

    -- speed 500 on ground 110 -> stepDuration 240, pace 250, confirm timeout 340 ms.
    local dur = wk:stepDuration(1)
    local timeout = wk:confirmTimeoutMs(1)
    ok(timeout > dur, 'the confirm timeout (' .. timeout .. ' ms) outlasts the step ('
                      .. dur .. ' ms)')

    -- Run until the dropped-confirmation fallback fires, and assert that NOTHING extra went
    -- on the wire before it did.  (Pre-fix, the second packet went out one paced delay after
    -- the first -- ~250 ms -- from the position the server had not moved yet.)
    local firstSendAt, extraDuringTimeout = nil, 0
    for _ = 1, 300 do
        H:tick(1, 10)
        firstSendAt = firstSendAt or wk.lastSendAt
        if wk.stats.lost >= 1 then break end
        if firstSendAt and (H.clock.t - firstSendAt) <= timeout then
            local extra = H.sender:count('walk') - 1
            if extra > extraDuringTimeout then extraDuringTimeout = extra end
        end
    end
    eq(extraDuringTimeout, 0, 'no second packet while the first step is inside its timeout')
    ok(wk.stats.lost >= 1, 'the dropped-confirmation fallback fired')
    ok(wk.lastResync and wk.lastResync.why == 'confirm-timeout',
       'the timeout resynced to the server position')
    -- The very tick that declares the step lost also re-paths and sends a FRESH one -- that
    -- is the recovery.  What matters is that it could not happen a moment earlier.
    local walks = H.sender:byKind('walk')
    eq(#walks, 2, 'and exactly one replacement step followed')
    ok(walks[2].t - walks[1].t >= timeout,
       'the replacement waited the full confirm timeout (' .. (walks[2].t - walks[1].t)
       .. ' ms >= ' .. timeout .. ')')
end

-- ============================================================================
S('work item W: walkCancel clears the outstanding step and resyncs')
do
    local F = newWorld({ '.....', '..@..', '.....' })
    local H = newHost(F, { wire = {
        cavebot = { waypoints = {}, config = { walkDelay = 10 } }, enableCavebot = false } })
    local wk = H.bot.walker
    local st = F.st
    st.player.speed = 220
    local here = { x = st.player.pos.x, y = st.player.pos.y, z = st.player.pos.z }

    ok(wk:step(1), 'a step goes out')
    eq(#wk.expected, 1, 'one step outstanding')
    ok(wk.stepTo ~= nil and wk.stepTo.x == here.x + 1, 'and the predicted tile is recorded')

    H.bus:emit('walkCancel', { direction = 3 })
    eq(#wk.expected, 0, 'walkCancel clears the outstanding step')
    eq(wk.stepFrom, nil, 'and the prediction')
    ok(wk.serverPos ~= nil, 'the walker snapped to a server position')
    eq(wk.serverPos.x, here.x, 'which is where the server still has us (x)')
    eq(wk.serverPos.y, here.y, 'which is where the server still has us (y)')
    eq(wk.lastResync.why, 'walk-cancel', 'and it recorded why')
    eq(wk.stats.cancels, 1, 'the cancel was counted')
    ok(wk:isDelayed(), 'and the flat 200 ms back-off is armed')
end

-- ============================================================================
S('work item W: a move to a tile we did not predict resyncs instead of confirming')
do
    -- This is what the LIVE server produced once pacing was fixed: proto/parser.lua advances
    -- the local player TWICE per step (0x6D MoveCreature, then the 0x65-0x68 row slice in the
    -- same message, whose setCentral() writes player.pos a second time).  The walker must not
    -- treat "moved in the right direction, wrong tile" as a confirmation.
    local F = newWorld({ '.......', '..@....', '.......' })
    local H = newHost(F, { wire = {
        cavebot = { waypoints = {}, config = { walkDelay = 10 } }, enableCavebot = false } })
    local wk = H.bot.walker
    F.st.player.speed = 220
    local here = { x = F.st.player.pos.x, y = F.st.player.pos.y, z = F.st.player.pos.z }

    ok(wk:step(1), 'step east')
    H:moveTo({ x = here.x + 2, y = here.y, z = here.z })     -- TWO tiles east
    eq(#wk.expected, 0, 'the ledger is dropped')
    eq(wk.stats.confirmed, 0, 'the overshoot was NOT counted as a confirmation')
    eq(wk.stats.voids, 1, 'it was counted as a void')
    eq(wk.lastResync.why, 'unexpected-move', 'and resynced to the server position')
    eq(wk.serverPos.x, here.x + 2, 'the walker now believes what the server said')
end

-- ============================================================================
S('work item W: arrival stops exactly on the target tile')
do
    local F = newWorld({ '.........',
                         '..@....X.',
                         '.........' })
    local H = newHost(F, { wire = {
        cavebot = { waypoints = {
            { action = 'goto', value = ('%d,%d,%d'):format(F.goal.x, F.goal.y, F.goal.z) } },
            config = { avoidFloorChange = false, stayPathEnabled = false,
                       antiLostEnabled = false, walkDelay = 10 } },
        enableCavebot = true } })
    local wk = H.bot.walker
    F.st.serverBeat, F.st.ping = 50, 100
    F.st.player.speed = 220
    H.sender:clear()

    for _ = 1, 4000 do
        H:tick(1, 10)
        if #wk.expected > 0 and H.clock.t - wk.lastSendAt >= wk:paceDuration(wk.expected[1]) then
            local d = worldm.DELTA[wk.expected[1]]
            local pp = F.st.player.pos
            H:moveTo({ x = pp.x + d[1], y = pp.y + d[2], z = pp.z })
        end
        if F.st.player.pos.x == F.goal.x and F.st.player.pos.y == F.goal.y then break end
    end
    eq(F.st.player.pos.x, F.goal.x, 'stopped on the target tile (x)')
    eq(F.st.player.pos.y, F.goal.y, 'stopped on the target tile (y)')

    -- and it STAYS there: 5 s more must not put another walk packet on the wire
    local before = H.sender:count('walk')
    for _ = 1, 500 do H:tick(1, 10) end
    eq(H.sender:count('walk'), before, 'no step past the target tile')
    ok(H.cb.stats.arrivals >= 1, 'the goto reported arrival')
end

-- ============================================================================
S('work item W: walker:walkTo honours strict pacing too')
do
    local F = newWorld({ '.........', '..@.....X', '.........' })
    local H = newHost(F)
    local wk = H.bot.walker
    wk:configure({ walkDelay = 10, strictPacing = true, avoidFloorChange = false })
    F.st.player.speed = 220
    F.st.serverBeat, F.st.ping = 50, 100
    H.sender:clear()

    eq(wk:walkTo(F.goal, { maxDist = 20 }), 'walking', 'first call steps')
    eq(H.sender:count('walk'), 1, 'one packet')
    for _ = 1, 3 do
        H:advance(120)
        eq(wk:walkTo(F.goal, { maxDist = 20 }), 'walking', 'and it holds while unconfirmed')
    end
    eq(H.sender:count('walk'), 1, 'still exactly one packet after 360 ms of holding')
    eq(#wk.expected, 1, 'the same single step is still outstanding')
end

-- ============================================================================
-- REVIEW FIXES.  One block per finding from the bot-layer review; each of these
-- fails against the pre-fix code and passes against the current one.  The vBot
-- citation for every fix is inline in the module it patches.
-- ============================================================================
local sharedmod   = require('bot.shared')
local suppliesmod = require('bot.supplies')
local pathmod     = require('bot.path')
local attackbotm  = require('bot.attackbot')

S('REVIEW: AttackBot reads the SERVER-side facing, not state.player.direction')
do
    local F = newWorld({ '@..' }, { vocation = 11 })
    local H = newHost(F)
    local ab = H.ab

    -- The server turns us EAST.  Every path (0x6B turnOnly, and every 0x64/0x61/0x62
    -- describe) goes through P:applyCreature -> state:addCreature, which writes the
    -- CREATURE record.  state.player is a separate table the wire never touches here.
    F.st:addCreature({ id = F.st.player.id, direction = 1 })
    eq(F.st.player.direction, 0, 'state.player.direction is still the state.lua default')
    eq(F.st.creatures[F.st.player.id].direction, 1, 'the creature record is the truth')
    eq(ab:facing(), 1, 'A:facing() reads the creature record')

    -- vBot: player:getDirection() == neededDir -> fire WITHOUT turning, even with
    -- Auto Turn off.  Reading the dead field made this return false and fire nothing.
    ab:profile().Rotate = false
    H.sender:clear()
    local fired = false
    eq(ab:autoTurnAndFire(1, function() fired = true end), true,
       'already facing East -> autoTurnAndFire fires with Rotate OFF')
    eq(fired, true, 'and the fire callback really ran')
    eq(H.sender:count('turn'), 0, 'no turn packet was needed')

    -- a turn writes the optimistic facing to BOTH records
    ab:profile().Rotate = true
    ab:autoTurnAndFire(2, function() end)
    eq(ab:facing(), 2, 'after a turn the facing is South')
    eq(F.st.creatures[F.st.player.id].direction, 2, 'the creature record was updated too')
    eq(F.st.player.direction, 2, 'and so was state.player, so both stay in sync')
end

S('REVIEW: the two direction scanners use the CLASS monster predicate')
do
    -- AB:1258 / AB:1327 use a BARE spec:isMonster() with no getType() < 3 term, and
    -- Creature::isMonster() is class-derived: CreatureTypeMonster(1), SummonOwn(3),
    -- SummonOther(4) and Hidden(5) all build a Monster (protocolgameparse.cpp:4317).
    eq(attackbotm.isRealMonster({ type = 4 }), false, 'isRealMonster excludes summons')
    eq(attackbotm.isClassMonster({ type = 4 }), true, 'isClassMonster includes them')
    eq(attackbotm.isClassMonster({ type = 5 }), true, 'and the Hidden case')
    eq(attackbotm.isClassMonster({ type = 0 }), false, 'but never a player')

    local F = newWorld({ '@..' })
    local H = newHost(F)
    local ab = H.ab
    -- a 3x3 letter grid whose EAST cell is the tile one step east of us
    local grid = '\n000\n00E\n000\n'
    local east = { x = F.start.x + 1, y = F.start.y, z = F.start.z }
    F.st:addCreature({ id = 9001, name = 'Fire Elemental', type = 4, pos = east,
                       healthPercent = 100 })
    F.st:addThing(east, -2, { kind = 'creature', creatureId = 9001, id = 0x63 })
    local n, dir = ab:getWaveBestDir(grid, 0, 100, false, nil)
    eq(n, 1, 'getWaveBestDir counts an OWN/OTHER summon (bare isMonster)')
    eq(dir, 1, 'and picks East')

    -- getMonstersInArea still applies getType() < 3, exactly as AB:2559/2571 does
    eq(ab:getMonstersInArea(5, F.st.player.pos, '\n000\n010\n000\n', 0, 100, false, nil,
                            F.st.player.pos), 0,
       'getMonstersInArea keeps excluding summons')
end

S('REVIEW: the quadrant grids latch on the FIRST non-zero vocation')
do
    -- The bot is built on gameStart, before 0x9F PlayerDataBasic; freezing `ek` in the
    -- constructor froze it on the state.lua default of 0, so every knight got the 11x11
    -- grids instead of AB:842's 3x3 ones.
    local F = newWorld({ '@..' })            -- vocation 0 at construction
    local H = newHost(F)
    local ab = H.ab
    eq(ab.ek, false, 'nothing latched while the vocation is still unknown')
    F.st.player.vocation = 11                -- ... then 0x9F arrives
    local grids = ab:quadrantGrids()
    eq(ab.ek, true, 'an Elite Knight latches the knight grids')
    eq(grids == attackbotm.PATTERNS.quadrant.knight, true, 'and they ARE the knight grids')
    F.st.player.vocation = 2                 -- a later change must NOT re-latch
    ab:quadrantGrids()
    eq(ab.ek, true, 'the latch is frozen afterwards, as the VERIFIER requires')
end

S('REVIEW: HealBot burst damage -- the divide-by-zero guard is a switch')
do
    local F = newWorld({ '@..' })
    local H = newHost(F)
    local hb = H.hb
    hb.dmg = { { d = 100, t = H.clock.t }, { d = 100, t = H.clock.t } }
    eq(hb:burstDamageValue(), 0, 'two samples inside one tick fail CLOSED by default')
    hb.vbotBurstInfinity = true
    eq(hb:burstDamageValue(), math.huge, 'opts.vbotBurstInfinity reproduces vBot inf')
    hb.vbotBurstInfinity = false
end

S('REVIEW: player.isDead is cleared by demonstrably-alive health')
do
    local F = newWorld({ '@..' })
    local H = newHost(F)
    -- proto/parser.lua:907 sets it on 0x28 and NOTHING clears it except a whole new
    -- state, so a resurrection used to disable every heal loop for the session.
    F.st.player.isDead = true
    eq(H.hb:playable(), false, 'a dead player is not playable')
    eq(H.ab:playable(), false, 'and AttackBot agrees')
    H.bus:emit('healthChange', { health = 900, maxHealth = 1000, old = 0 })
    eq(F.st.player.isDead, false, 'the health event cleared the sticky flag')
    eq(H.hb:playable(), true, 'HealBot runs again')
    eq(H.ab:playable(), true, 'and so does AttackBot')
end

S('REVIEW: _lastPhrase is written ONLY by the talk echo')
do
    local F = newWorld({ '@..' })
    local H = newHost(F)
    local sh = sharedmod.attach(H.bot)
    H.bot._lastPhrase = nil
    sh:say('exura gran')
    eq(H.bot._lastPhrase, nil, 'a SEND does not claim the phrase (vlib.lua:302-307)')
    sh:sayAt('exori gran', F.st.player.pos)
    eq(H.bot._lastPhrase, nil, 'neither does sayAt')
    H.bus:emit('talk', { name = 'Tester', text = 'Exura Gran' })
    eq(H.bot._lastPhrase, 'exura gran', 'the server ECHO is what sets it')

    -- and therefore a rejected formula cannot poison the customCooldowns learner
    sh:say('zzz never echoed')
    H.bus:emit('spellCooldown', { spellId = 4242, delay = 1000 })
    eq(sh.custom['zzz never echoed'], nil, 'the unechoed formula owns no cooldown id')
end

S('REVIEW: Supplies reads FREE capacity, not total')
do
    local F = newWorld({ '@..' })
    local H = newHost(F)
    F.st.player.capacity     = 3155      -- 0xA1 total capacity
    F.st.player.freeCapacity = 940       -- 0xA0 free capacity, what vBot's freecap() is
    eq(H.sup:freeCap(), 940, 'S:freeCap() is player.freeCapacity')
    eq(H.bot.api.freecap(), 940, 'and so is the sandbox freecap()')
    eq(H.bot.api.cap(), 940, 'cap() is an alias of it (vBot cap() is a dead call)')
    F.st.player.freeCapacity = nil
    eq(H.sup:freeCap(), 3155, 'with no 0xA0 yet it falls back to total, never to 0')
end

S('REVIEW: loot pouch -- getSize() == 0 falls back to the item count')
do
    local F = newWorld({ '@..' })
    local H = newHost(F)
    local items22 = {}
    for i = 1, 22 do items22[i] = { kind = 'item', id = ID_GOLD, count = 1 } end
    F.st.containers[3] = { id = 3, name = 'loot pouch', capacity = 20, firstIndex = 0,
                           size = 0, items = items22 }
    eq(H.sup:lootPouchPages(), 2, 'size <= 0 -> ceil(#items / capacity) (supply_check.lua:47)')

    -- and a lootPouchValue of 0 DISABLES the check entirely (supply_check.lua:97).
    -- Branch 11 is the LAST one, so silence 1..10 first.
    local ad = H.sup:additionalData()
    for _, k in ipairs({ 'mana', 'health', 'cap', 'imbues', 'stamina', 'softBoots',
                         'capacity', 'ammo', 'anySupply' }) do
        if type(ad[k]) == 'table' then ad[k].enabled = false end
    end
    H.sup.hasEnough = function() return true end
    ad.lootPouch.enabled = true
    ad.lootPouch.value   = 0
    eq(H.sup:checkRound(), nil, 'pouchLimit 0 keeps hunting')
    ad.lootPouch.value   = 1
    eq(H.sup:checkRound(), 'lootPouch', 'a real limit still triggers')
end

S('REVIEW: missedChecks counts CONSECUTIVE misses only')
do
    local F = newWorld({ '@..' })
    local H = newHost(F)
    H.sup.missedChecks = 3
    H.sup:roundCompleted()
    eq(H.sup.missedChecks, 0,
       'setCaveBotData() ends with missedChecks = 0 on BOTH paths (supply_check.lua:29)')
end

S('REVIEW: CaveBot knows about protection zones')
do
    local F = newWorld({ '@.' })
    local H = newHost(F)
    local cb = H.cb
    local furn = F.at(1, 0)
    F.st:addThing(furn, -2, { kind = 'item', id = 2130 })   -- the "wg" wall vBot always breaks

    F.st.player.states = 0
    eq(cb:isInPz(), false, 'not in PZ')
    H.sender:clear()
    eq(cb:breakFurniture(furn), true, 'outside a PZ the furniture is disintegrated')
    eq(H.sender:count('useWith'), 1, 'one destroy-field rune')
    eq((H.sender:byKind('useWith')[1] or {}).id, 3197, 'item 3197')

    F.st.player.states = 16384                              -- PlayerStates.Pz
    eq(cb:isInPz(), true, 'in PZ')
    H.sender:clear()
    eq(cb:breakFurniture(furn), false, 'actions.lua:71 -- never in PZ')
    eq(H.sender:count('useWith'), 0, 'and no rune is wasted')
    F.st.player.states = 0
end

S("REVIEW: the unconditional 'There is not enough room.' anti-stuck hook")
do
    local F = newWorld({ '@..', '...', '...' })
    local H = newHost(F)
    H.cb:enable()
    local pile = F.at(1, 0)
    for _ = 1, 11 do F.st:addThing(pile, -2, { kind = 'item', id = ID_GOLD, count = 1 }) end

    H.sender:clear()
    H.bus:emit('textMessage', { mode = 20, text = 'There is not enough room.' })
    eq(H.sender:count('useWith'), 1, 'outside a PZ the pile is disintegrated (actions.lua:49)')
    eq((H.sender:byKind('useWith')[1] or {}).id, 3197, 'with the destroy-field rune')

    -- inside a PZ the top thing is MOVED instead, throttled to one per 200 ms
    F.st.player.states = 16384
    H.sender:clear()
    H.bus:emit('textMessage', { mode = 20, text = 'There is not enough room.' })
    eq(H.sender:count('useWith'), 0, 'no rune inside a PZ')
    eq(H.sender:count('move'), 1, 'the top item is moved aside instead')
    H.sender:clear()
    H.bus:emit('textMessage', { mode = 20, text = 'There is not enough room.' })
    eq(H.sender:count('move'), 0, 'and the 200 ms throttle holds')
    F.st.player.states = 0

    -- an unrelated message does nothing at all
    H.sender:clear()
    H.bus:emit('textMessage', { mode = 20, text = 'You see a rat.' })
    eq(#H.sender:all(), 0, 'any other text is ignored')
end

S('REVIEW: poscheck counts CONSECUTIVE failures')
do
    local F = newWorld({ '@..' })
    local H = newHost(F, { wire = {} })
    local cb = H.cb
    cb:reload({ waypoints = { { action = 'label', value = 'home' },
                              { action = 'poscheck', value = '' } } })
    local here = F.st.player.pos
    local far  = { x = here.x + 50, y = here.y + 50, z = here.z }
    local val  = ('home,1,%d,%d,%d,3'):format(far.x, far.y, far.z)
    eq(cb:_actionPosCheck(val), false, 'far away -> bounce back to the label')
    eq(cb.posCheck.count, 1, 'one failure')
    local okVal = ('home,1,%d,%d,%d,3'):format(here.x, here.y, here.z)
    cb.posCheck.value = okVal          -- same visit, position now satisfied
    cb.posCheck.count = 1
    eq(cb:_actionPosCheck(okVal), true, 'at the position -> pass')
    eq(cb.posCheck.count, 0, 'pos_check.lua:48 resets the counter on success')
end

S('REVIEW: supplycheck is Chebyshev over x/y ONLY, and needs exactly 4 fields')
do
    local F = newWorld({ '@..' })
    local H = newHost(F)
    local cb, sup = H.cb, H.sup
    cb:reload({ waypoints = { { action = 'label', value = 'hunt' },
                             { action = 'supplycheck', value = 'hunt' } } })
    local p = F.st.player.pos
    sup.missedChecks = 0
    -- the coordinate sits one floor away: getDistanceBetween() ignores z entirely
    cb:_actionSupplyCheck(('hunt,%d,%d,%d'):format(p.x, p.y, p.z - 1))
    eq(sup.missedChecks, 0, 'supply_check.lua:77 ignores z -- this is NOT a miss')
    -- a 5-field value must not activate the guard at all (supply_check.lua:68 `#data == 4`)
    sup.missedChecks = 0
    cb:_actionSupplyCheck(('hunt,%d,%d,%d,extra'):format(p.x + 500, p.y + 500, p.z))
    eq(sup.missedChecks, 0, 'a 5-field value leaves the position guard switched off')
    -- but a real 4-field miss still counts
    sup.missedChecks = 0
    cb:_actionSupplyCheck(('hunt,%d,%d,%d'):format(p.x + 500, p.y + 500, p.z))
    eq(sup.missedChecks, 1, 'a genuine out-of-range check is a miss')
end

S('REVIEW: travel / bank reject a malformed value before talking to the NPC')
do
    local F = newWorld({ '@..' })
    local H = newHost(F)
    local cb = H.cb
    -- the NPC EXISTS and is adjacent, so only the missing city can stop this
    F.st:addCreature({ id = 5601, name = 'Captain Bluebear', type = 2, isNpc = true,
                       pos = F.at(1, 0) })
    H.sender:clear()
    eq(cb:_actionTravel('Captain Bluebear', 0), false,
       'travel.lua:6-9 -- a missing city is rejected')
    eq(#H.sender:all(), 0, 'and the character never says the literal "nil"')
    F.st:addCreature({ id = 5602, name = 'Bank Clerk', type = 2, isNpc = true,
                       pos = F.at(1, 0) })
    H.sender:clear()
    eq(cb:_actionBank('withdraw,Bank Clerk,notanumber', 0), false,
       'bank.lua:32-38 -- a non-numeric withdraw amount is rejected')
    eq(#H.sender:all(), 0, 'still nothing said')
end

S('REVIEW: the anti-lost fallback does not require a path')
do
    -- cavebot.lua:439-445 checks ONLY the floor and gotoMaxDistance/2 -- there is no
    -- findPath there.  A walled-off character must still be able to snap back.
    local F = newWorld({ '@#X' })
    local H = newHost(F)
    local cb = H.cb
    local dest = F.at(2, 0)
    cb:reload({ waypoints = {
        { action = 'goto', value = ('%d,%d,%d'):format(dest.x, dest.y, dest.z) },
        { action = 'label', value = 'x' } } })
    cb.index = 2
    eq(cb:gotoFirstPreviousReachableWaypoint(), true,
       'the unreachable-but-near goto is accepted')
    eq(cb.index, 1, 'and the route rewinds to it')
end

S('REVIEW: sellall is capped on rounds WITHOUT progress, not on sales')
do
    local F = newWorld({ '@.' })
    local H = newHost(F)
    local cb = H.cb
    local npcPos = F.at(1, 0)
    F.st:addCreature({ id = 5555, name = 'Rashid', type = 2, isNpc = true, pos = npcPos })
    F.st.npcTrade = { open = true, items = {} }
    local list = {}
    for i = 1, 20 do list[i] = { kind = 'item', id = 3000 + i, count = 1 } end
    addContainer(F.st, 0, ID_BACKPACK, list)
    F.st.player.freeCapacity = 100

    local sold = 0
    for i = 1, 30 do
        H.sender:clear()
        local r = cb:_actionSellAll('Rashid', i - 1)
        local n = H.sender:count('sell')
        if n > 0 then
            sold = sold + n
            table.remove(list, 1)                      -- the server takes the item
            F.st.player.freeCapacity = F.st.player.freeCapacity + 1
        end
        if r == false or r == true then break end
    end
    ok(sold > 11, 'more than the old ~11-item ceiling was sold (' .. sold .. ')')
    eq(sold, 20, 'in fact the whole backpack went')
end

S('REVIEW: buysupplies never buys blind, and clears noProgress on a missing NPC')
do
    local F = newWorld({ '@.' })
    local H = newHost(F)
    local cb = H.cb
    cb.noProgress = 7
    eq(cb:_actionBuySupplies('Nobody Here,200', 1), false, 'a missing NPC skips')
    eq(cb.noProgress, 0, 'buy_supplies.lua:43 resets noProgress there')

    local npcPos = F.at(1, 0)
    F.st:addCreature({ id = 5556, name = 'Rashid', type = 2, isNpc = true, pos = npcPos })
    F.st.npcTrade = { open = true }                    -- trading, but NO offer list
    H.sender:clear()
    local r = cb:_actionBuySupplies('Rashid,200', 0)
    eq(H.sender:count('buy'), 0, 'an unknown offer list buys NOTHING (buy_supplies.lua:70)')
    eq(r, true, 'and the action reports "bought everything, proceeding"')
end

S('REVIEW: cleartile never pushes a player onto the tile WE stand on')
do
    -- The player stands EAST of the blocked tile, so DELTA order (N, E, S, W, ...) reaches
    -- our own tile first: the old `not samePos(q, tPos)` guard was dead code (DELTA never
    -- yields (0,0)) and let the bot pick it.
    local F = newWorld({ '.@.', '...' })
    local H = newHost(F)
    local cb = H.cb
    local tPos = F.at(0, 0)
    F.st:addCreature({ id = 6001, name = 'Blocker', type = 0, isPlayer = true, pos = tPos,
                       healthPercent = 100 })
    F.st:addThing(tPos, -2, { kind = 'creature', creatureId = 6001, id = 0x63 })
    local pushes = 0
    math.randomseed(1)
    for _ = 1, 20 do
        H.sender:clear()
        cb:_actionClearTile(('%d,%d,%d'):format(tPos.x, tPos.y, tPos.z), 0)
        local mv = H.sender:byKind('move')
        if #mv > 0 then
            pushes = pushes + 1
            local to = mv[1].toPos or {}
            ok(not (to.x == F.st.player.pos.x and to.y == F.st.player.pos.y
                    and to.z == F.st.player.pos.z),
               'clear_tile.lua:88 -- the push destination is never our own tile')
        end
    end
    ok(pushes > 0, 'the push really was attempted (' .. pushes .. 'x)')
end

S('REVIEW: the walker paces on the PREVIOUS step direction')
do
    local F = newWorld({ '....', '....', '....' }, { baseX = 1000, baseY = 1000 })
    local H = newHost(F)
    local wk = H.bot.walker
    F.st.player.speed = 500
    F.st.serverBeat   = 50

    wk:reset(true)
    wk.lastStepDir = 0                                   -- the last real step was North
    local orth = wk:stepDuration(4)                      -- NE, but the REFERENCE is North
    wk.lastStepDir = 4                                   -- the last real step was NE
    local diag = wk:stepDuration(0)                      -- North, but the REFERENCE is NE
    ok(diag >= orth * 2,
          ('creature.cpp:1155 -- the x3 follows the LAST direction (%d vs %d)')
          :format(diag, orth))

    -- and step(dir) must use the value computed BEFORE lastStepDir is overwritten
    wk:reset(true)
    wk.lastStepDir = 0
    local used
    local orig = wk.delay
    wk.delay = function(self, ms) used = ms; return orig(self, ms) end
    wk:step(4)                                           -- one diagonal step
    wk.delay = orig
    ok(used ~= nil, 'the step armed a delay')
    ok(used < diag,
          ('the NE step after a North step is paced orthogonally (%s < %d)')
          :format(tostring(used), diag))
    eq(wk.lastStepDir, 4, 'and only THEN does lastStepDir become the new direction')
end

S('REVIEW: the goto final approach really has an in-flight guard')
do
    local F = newWorld({ '@...' })
    local H = newHost(F)
    local cb, wk = H.cb, H.bot.walker
    eq(cb:_stepInFlight(), false, 'nothing outstanding to begin with')
    wk:step(1)
    eq(cb:_stepInFlight(), true, 'a sent step is in flight')
    cb:resetWalking()                                    -- what CB:tick does every pass
    eq(wk:isWalking(), false, 'resetWalking() empties the walker ledger ...')
    eq(cb:_stepInFlight(), true, '... but the send timestamp survives it')
    wk.lastSendAt = wk.lastSendAt - 5000                 -- age the send past the timeout
    eq(cb:_stepInFlight(), false, 'and it expires on the confirmation timeout')
end

S('REVIEW: the looter moves EVERY copy of a repeated item id')
do
    local F = newWorld({ '@..' })
    local H = newHost(F)
    local lt = H.tb.loot
    lt:update({ items = { { id = 16131, count = 0 } },
                containers = { { id = ID_BACKPACK, count = 0 } },
                everyItem = false, maxDanger = 10, minCapacity = 100 })
    local bag = addContainer(F.st, 0, ID_BACKPACK, {})
    local corpseItems = {}
    for i = 1, 5 do corpseItems[i] = { kind = 'item', id = 16131 } end
    local corpse = addContainer(F.st, 1, 3994, corpseItems)

    local moved = 0
    for _ = 1, 12 do
        H.sender:clear()
        lt:lootContainer({ bag }, corpse)
        if H.sender:count('move') == 0 then break end
        moved = moved + 1
        table.remove(corpseItems, 1)                     -- the server applies the move
        corpse.size = #corpseItems
        bag.items[#bag.items + 1] = { kind = 'item', id = 16131 }
    end
    eq(moved, 5, 'all five identical items left the corpse (vBot keys tries per ITEM)')
    eq(#corpseItems, 0, 'the corpse is empty')
    eq(lt.stats.abandoned, 0, 'and nothing was abandoned')
end

S('REVIEW: TargetBot tracks creature positions from the EVENT bus')
do
    local F = newWorld({ '@....' })
    local H = newHost(F)
    local tb = H.tb
    local p1 = F.at(1, 0)
    local p2 = F.at(2, 0)
    local c = F.st:addCreature({ id = 8001, name = 'Rat', type = 1, isMonster = true,
                                 pos = p1, healthPercent = 100 })
    H.bus:emit('creatureAppear', c)
    eq(tb.lastPos[8001] ~= nil and tb.lastPos[8001].x, p1.x,
       'creatureAppear seeds lastPos without any tick')
    H.bus:emit('creatureMove', { creature = c, from = p1, to = p2 })
    eq((tb.lastPos[8001] or {}).x, p2.x, 'creatureMove keeps it fresh even while the macro is delayed')
    eq((tb.lastPos[8001] or {}).y, p2.y, 'y too')
end

S('REVIEW: TargetBot isFriend covers the local player and party members')
do
    local F = newWorld({ '@..' })
    local H = newHost(F)
    local tb = H.tb
    eq(tb:isFriend('Tester'), true, 'vlib.lua:422 -- `if c == player then return true end`')
    eq(tb:isFriend('Stranger'), false, 'a stranger is not a friend')
    F.st:addCreature({ id = 8100, name = 'Mate', type = 0, isPlayer = true, shield = 4,
                       pos = F.at(1, 0), healthPercent = 100 })
    tb.storage.playerList = tb.storage.playerList or {}
    tb.storage.playerList.groupMembers = nil
    eq(tb:isFriend('Mate'), false, 'with groupMembers off a party member is not a friend')
    tb.storage.playerList.groupMembers = true
    eq(tb:isFriend('Mate'), true, 'with groupMembers on it is (vlib.lua:437-447)')
    tb.storage.playerList.groupMembers = nil
end

S('REVIEW: TargetBot rePosition reaches the real CaveBot entry point')
do
    local F = newWorld({ '@..' })
    local H = newHost(F)
    local tb = H.tb
    local seen = nil
    local orig = H.cb.goTo
    H.cb.goTo = function(self, pos, precision) seen = { pos = pos, p = precision } end
    tb:cavebotGoTo(F.at(2, 0), 0)
    H.cb.goTo = orig
    ok(seen ~= nil, 'CB:goTo (lower-case g) is the method that exists, and it was called')
    eq((seen or {}).p, 0, 'with precision 0')
end

S('REVIEW: bot/api.lua -- the sandbox surface')
do
    local F = newWorld({ '@..' })
    local H = newHost(F)
    local a = H.bot.api
    local st = F.st

    -- itemAmount must see a CLOSED backpack through state.inventoryCounts
    st.inventoryCounts = { [3723 * 256] = 12 }
    eq(a.findItemCount(3723), 0, 'findItemCount stays the pure open-container scan')
    eq(a.itemAmount(3723), 12, 'itemAmount reads the server-pushed count (vlib.lua:783-888)')

    -- use(container-thing) must claim a FREE container window (Game::use)
    st.containers[0] = { id = 0, name = 'bag', capacity = 20, firstIndex = 0, items = {} }
    H.sender:clear()
    a.use({ id = ID_BACKPACK, pos = { x = 100, y = 100, z = 7 }, stackPos = 1 })
    eq((H.sender:byKind('use')[1] or {}).index, 1, 'not the hardcoded window 0 (game.cpp:838-852)')
    st.containers[0] = nil

    -- findItem on a PAGED container returns the PAGE-LOCAL slot
    st.containers[3] = { id = 3, name = 'bag', capacity = 20, hasPages = true,
                         firstIndex = 20, size = 40,
                         items = { { kind = 'item', id = 3492, count = 1 } } }
    local found = a.findItem(3492)
    ok(found ~= nil, 'the item is found')
    eq((found and found.pos or {}).z, 0, 'Container::getSlotPosition uses the page-local index')
    eq(found and found.stackPos, 0, 'and so does the stackpos')
    eq(found and found.absoluteSlot, 20, 'the absolute index is kept separately')
    st.containers[3] = nil

    -- useWith on a bare creature record must route to 0x84, not 0x83
    local bare = st:addCreature({ id = 65535 })
    H.sender:clear()
    a.useWith(3155, bare)
    eq(H.sender:count('useOnCreature'), 1,
       'Game::useWith tests toThing->isCreature(), not duck-typed fields')
    eq((H.sender:byKind('useOnCreature')[1] or {}).creatureId, 65535, 'on the right creature')
    H.sender:clear()
    a.useWith(3155, st.player)
    eq(H.sender:count('useOnCreature'), 1, 'state.player is a creature too')
    st.creatures[65535] = nil

    -- storage is served live, so a reload cannot orphan it
    local before = a.storage
    eq(before == H.bot.storage, true, 'ctx.storage is the bot storage')
    H.bot.storage.__reviewProbe = 7
    eq(a.storage.__reviewProbe, 7, 'writes are visible through the sandbox')
    H.bot:reloadStorage()
    eq(a.storage == H.bot.storage, true, 'still the same table after a reload')
    eq(H.bot.storage == before, true, 'reloadStorage mutates in place, it does not swap')
    H.bot.storage.__reviewProbe = nil
end

S('REVIEW: bot/world.lua tolerates a missing / out-of-range item id')
do
    local F = newWorld({ '@..' })
    local H = newHost(F)
    local w = H.bot.world
    local bogus = F.at(1, 0)
    F.st:addThing(bogus, -2, { kind = 'item', id = 65000 })   -- above items.MAX_ID
    local tile = F.st:tile(bogus)
    eq(pcall(function() return w:classifyForPath(bogus) end), true,
       'classifyForPath does not raise out of the CaveBot macro')
    eq(pcall(function() return w:minimapColor(tile) end), true, 'nor does minimapColor')
    eq(pcall(function() return w:getTopUseThing(tile) end), true, 'nor getTopUseThing')
    eq(pcall(function() return w:isWalkable(tile, true) end), true, 'nor isWalkable')

    -- an UNLOADED item table must report degraded, not "full"
    local w2 = worldm.new({ state = F.st, items = { loaded = false,
                                                    isGround = function() error('nope') end } })
    ok(w2.itemDataLevel ~= 'full', 'an unloaded table is never reported as full')
end

S('REVIEW: world.countInArea excludes summons, like getMonstersInArea')
do
    local F = newWorld({ '@..', '...', '...' })
    local H = newHost(F)
    local w = H.bot.world
    local grid = '\n111\n111\n111\n'
    local east = F.at(1, 0)
    F.st:addCreature({ id = 9101, name = 'Rat', type = 1, isMonster = true, pos = east,
                       healthPercent = 100 })
    F.st:addThing(east, -2, { kind = 'creature', creatureId = 9101, id = 0x63 })
    local south = F.at(0, 1)
    if F.st:tile(south) then
        F.st:addCreature({ id = 9102, name = 'Fire Elemental', type = 4, isMonster = true,
                           pos = south, healthPercent = 100 })
        F.st:addThing(south, -2, { kind = 'creature', creatureId = 9102, id = 0x63 })
    end
    ok(F.st:tile(south) ~= nil, 'the summon really is on the map')
    eq(w:countInArea(F.st.player.pos, grid, 8), 1, 'AB:2571 -- summons do not count')
    eq(w:countInArea(F.st.player.pos, grid, 8, { includeSummons = true }), 2,
       'the escape hatch counts them')
end

S('REVIEW: pathfinder -- maxDistanceFrom with range 0 means NO limit')
do
    local F = newWorld({ '@....' })
    local H = newHost(F)
    local p = H.bot.path
    local dest = F.at(3, 0)
    local dirs = p:getPath(F.st.player.pos, dest, 20,
                           { maxDistanceFrom = { F.st.player.pos, 0 } })
    ok(dirs ~= nil and #dirs == 3,
          'map.cpp:1427 -- maxDistanceFrom is an int, and 0 disables the test')
    local limited = p:getPath(F.st.player.pos, dest, 20,
                              { maxDistanceFrom = { F.st.player.pos, 1 } })
    eq(limited, nil, 'a REAL range of 1 still blocks the far tiles')
end

S('REVIEW: Bot:stop() unwires the modules')
do
    local F = newWorld({ '@..' })
    local H = newHost(F)
    local calls = {}
    H.bot.walker.detach = function() calls[#calls + 1] = 'walker' end
    H.tb.detach         = function() calls[#calls + 1] = 'targetbot' end
    H.bot:stop()
    eqList(calls, { 'walker', 'targetbot' }, 'stop() drops the live event hooks')
end

S('REVIEW: config.writeFileAtomic never leaves the target missing')
do
    local dir = os.getenv('TEMP') or os.getenv('TMPDIR') or '.'
    local path = dir:gsub('\\', '/') .. '/luaclient_review_atomic.json'
    os.remove(path); os.remove(path .. '.bak'); os.remove(path .. '.tmp')
    eq(cfgmod.writeFileAtomic(path, '{"a":1}'), true, 'first write')
    eq(cfgmod.readFile(path), '{"a":1}', 'and it reads back')
    eq(cfgmod.writeFileAtomic(path, '{"a":2}'), true, 'overwrite')
    eq(cfgmod.readFile(path), '{"a":2}', 'the new contents are there')
    eq(cfgmod.fileExists(path .. '.bak'), false, 'the backup is cleaned up on success')
    -- the crash window: simulate "we got as far as renaming the old file aside"
    os.rename(path, path .. '.bak')
    eq(cfgmod.fileExists(path), false, 'the target is momentarily gone')
    eq(cfgmod.readFile(path .. '.bak'), '{"a":2}', 'but the previous contents survive in .bak')
    os.remove(path); os.remove(path .. '.bak')

    -- and Profile:loadStorage prefers the .bak when the target vanished in that window
    local pdir = dir:gsub('\\', '/') .. '/luaclient_review_profile'
    cfgmod.mkdirp(pdir .. '/storage')
    local prof = cfgmod.new({ profileDir = pdir, vprofile = 9 })
    local spath = prof:storagePath()
    os.remove(spath)
    local f = io.open(spath .. '.bak', 'wb'); f:write('{"kept":true}'); f:close()
    local st9 = prof:loadStorage()
    eq(type(st9) == 'table' and st9.kept, true,
       'a crash in the swap window recovers from storage/profile_9.json.bak')
    os.remove(spath .. '.bak')
    os.remove(pdir .. '/storage'); os.remove(pdir)      -- best effort; both are empty now
end

-- ============================================================================
-- WORK ITEM M -- the persisted minimap is the pathfinder's knowledge of the world
-- OUTSIDE the aware area (docs/live-findings.md bug 3, docs/minimap.md).
--
-- Every fixture here is BUILT IN THIS FILE by lib/minimap.lua's own writer; the
-- user's real 6.9 MB profiles/minimap.otmm is never read and never shipped.
-- ============================================================================
local minimapmod = require('lib.minimap')

-- one 64x64 block, tiles supplied by a callback (x, y, z) -> flags, colour, speedByte
local MM_SEEN     = minimapmod.WAS_SEEN          -- 1
local MM_NOTPATH  = minimapmod.NOT_PATHABLE      -- 2
local MM_NOTWALK  = minimapmod.NOT_WALKABLE      -- 4

--- Build an OTMM image covering every 64x64 block the rectangle touches.
--- `tiles(x, y, z)` returns flags, colour, speedByte -- nil leaves the null tile
--- (flags 0 = never seen, colour 255, speed byte 10), which is what an unexplored
--- tile looks like on disk.
local function buildMinimap(x0, y0, x1, y1, z, tiles)
    local B = minimapmod.MMBLOCK_SIZE
    local specs = {}
    local by = math.floor(y0 / B) * B
    while by <= y1 do
        local bx = math.floor(x0 / B) * B
        while bx <= x1 do
            specs[#specs + 1] = { x = bx, y = by, z = z, tiles = tiles }
            bx = bx + B
        end
        by = by + B
    end
    return minimapmod.buildFile(specs), #specs
end

--- A live state that knows ONLY a small square around the player: exactly the
--- situation the live sessions hit -- the server has described the aware area and
--- nothing else exists as far as game/state.lua is concerned.
--- `corridor` places live ground only along y = cy, so the live map is a one-tile
--- corridor too and a blocked tile really is unroutable.
local function sparseState(cx, cy, z, aware, walls, corridor)
    local st = state.new()
    local a = st.world.awareRange
    a.left, a.top, a.right, a.bottom = aware, aware, aware, aware
    for y = cy - aware, cy + aware do
        for x = cx - aware, cx + aware do
            if not (corridor and y ~= cy) then
                local pos = { x = x, y = y, z = z }
                st:addThing(pos, 0, { kind = 'item', id = ID_GROUND })
                if walls and walls[x .. ',' .. y] then
                    st:addThing(pos, -2, { kind = 'item', id = ID_WALL })
                end
            end
        end
    end
    st.player.id, st.player.name = 1, 'Tester'
    st.player.pos = { x = cx, y = cy, z = z }
    st.player.health, st.player.maxHealth = 100, 100
    st.player.speed = 500
    st.central = { x = cx, y = cy, z = z }
    return st
end

local function mmClient(st, mm)
    return { state = st, items = items, minimap = mm }
end

S('work item M: the OTMM reader decodes flags, colour and speed byte for byte')
do
    local bytes = buildMinimap(1000, 1000, 1000, 1000, 7, function(x, y)
        if x == 1000 and y == 1000 then return MM_SEEN, 129, 10 end
        if x == 1001 and y == 1000 then return MM_SEEN + MM_NOTWALK, 0, 10 end
        if x == 1002 and y == 1000 then return MM_SEEN + MM_NOTPATH, 210, 10 end
        if x == 1003 and y == 1000 then return MM_SEEN, 79, 25 end
        return nil                                   -- the null tile: never explored
    end)
    local mm, err = minimapmod.parse(bytes, nil, '<fixture>')
    ok(mm ~= nil, 'the fixture parses', err)
    local st = mm:stats()
    eq(st.blocks, 1, 'one 64x64 block')
    eq(st.blocksDamaged, 0, 'nothing damaged')
    eq(st.resyncs, 0, 'no framing resync was needed')
    eq(st.sawEndMarker, true, 'the invalid-Position sentinel closes the file')
    eq(st.version, minimapmod.OTMM_VERSION, 'OTMM v1')

    local t = mm:tile(1000, 1000, 7) or {}
    ok(next(t) ~= nil, 'a tile inside the block comes back')
    eq(t.seen, true,  'WasSeen')
    eq(t.walkable, true, 'walkable')
    eq(t.pathable, true, 'pathable')
    eq(t.color, 129, 'the colour byte survives')
    eq(t.speed, 100, 'MinimapTile::getSpeed() is the byte * 10')

    local w = mm:tile(1001, 1000, 7) or {}
    eq(w.walkable, false, 'NotWalkable decodes')
    eq(w.pathable, true,  'and does not imply NotPathable')

    local s = mm:tile(1002, 1000, 7) or {}
    eq(s.pathable, false, 'NotPathable decodes')
    eq(s.stairs, true, 'colour 210 AND not-pathable is the floor-change band')

    local f = mm:tile(1003, 1000, 7) or {}
    eq(f.speed, 250, 'speed byte 25 -> ground speed 250')

    local n = mm:tile(1010, 1010, 7) or {}
    ok(next(n) ~= nil, 'a never-explored tile inside a stored block still has a record')
    eq(n.seen, false, 'but it is not seen')
    eq(n.color, 255, 'and carries the 255 "never filled in" colour')

    eq(mm:tile(5000, 5000, 7), nil, 'a position in a block the file does not hold is nil')
    eq(mm:tile(1000, 1000, 3), nil, 'and so is another floor')

    local flags, color, speedByte = mm:get({ x = 1003, y = 1000, z = 7 })
    eq(flags, MM_SEEN, 'the bot/world.lua `known` interface returns raw flags')
    eq(color, 79, '... the raw colour')
    eq(speedByte, 25, '... and the raw speed BYTE (world multiplies by 10)')
end

S('work item M: load() reads a file from disk read-only, and the module facade follows it')
do
    local dir = (os.getenv('TEMP') or os.getenv('TMPDIR') or '.'):gsub('\\', '/')
    local p = dir .. '/luaclient_workitem_m.otmm'
    local bytes = buildMinimap(2000, 2000, 2000, 2000, 5,
                               function() return MM_SEEN, 42, 12 end)
    local fh = assert(io.open(p, 'wb')); fh:write(bytes); fh:close()

    local mm, err = minimapmod.load(p)
    ok(mm ~= nil, 'minimap.load(path) works', err)
    eq(mm:blockCount(), 1, 'one block')
    eq(minimapmod.blockCount(), 1, 'the module facade sees the last-loaded instance')
    local t = minimapmod.tile(2000, 2000, 5)
    eq(t and t.color, 42, 'minimap.tile(x, y, z) reads through the facade')
    eq(minimapmod.stats().fileSize, #bytes, 'minimap.stats() too')
    eq((minimapmod.tile(mm, 2000, 2000, 5) or {}).speed, 120,
       'and an explicit instance may be passed as the first argument')

    -- the file must still be byte-identical: this reader NEVER writes
    local rh = assert(io.open(p, 'rb')); local after = rh:read('*a'); rh:close()
    eq(after, bytes, 'the file on disk is untouched')
    os.remove(p)
end

S('work item M: the reader is fail-soft -- junk between blocks costs the junk, not the map')
do
    local good, nblocks = buildMinimap(3000, 3000, 3100, 3000, 6,
                                       function() return MM_SEEN, 7, 10 end)
    ok(nblocks >= 3, 'the fixture spans several 64x64 blocks', nblocks)
    local clean = minimapmod.parse(good, nil, '<clean>')
    eq(clean:blockCount(), nblocks, 'every block indexes cleanly')

    -- splice three bytes of garbage in front of the SECOND block header
    local firstLen = 22 + 7 + (good:byte(22 + 6) + good:byte(22 + 7) * 256)
    local dirty = good:sub(1, firstLen) .. '\1\2\3' .. good:sub(firstLen + 1)
    local mm = minimapmod.parse(dirty, nil, '<dirty>')
    ok(mm ~= nil, 'a damaged file still parses')
    eq(mm:blockCount(), nblocks, 'the resync recovers every block behind the garbage')
    ok(mm:stats().resyncs >= 1, 'and the damage is reported')
    eq((mm:tile(3100, 3000, 6) or {}).color, 7, 'the recovered block decodes')

    eq(minimapmod.parse('not an otmm file at all', nil, '<junk>'), nil,
       'a non-OTMM file is refused, not guessed at')
end

S('work item M: a 26-tile waypoint has NO path from live state and a path with the minimap')
do
    -- The teeest route's first waypoint, reproduced offline: 26 tiles east of the player,
    -- with the live map covering only +-3 tiles (docs/live-findings.md bug 3).
    local st = sparseState(1000, 1000, 7, 3)
    local dest = { x = 1026, y = 1000, z = 7 }
    ok(st:isAwareOf({ x = 1003, y = 1000, z = 7 }), 'the aware area reaches +3')
    eq(st:isAwareOf(dest), false, 'and the waypoint is far outside it')

    local blind = pathmod.new(mmClient(st, nil))
    local dirs, why = blind:getPath(st.player.pos, dest, 60)
    eq(dirs, nil, 'without the minimap there is no path at all')
    eq(why, 'no-path', '... which is exactly bug 3')

    -- the same world, plus a minimap that remembers a walkable corridor along y = 1000
    local bytes = buildMinimap(960, 960, 1090, 1040, 7, function(x, y)
        if y == 1000 and x >= 990 and x <= 1030 then return MM_SEEN, 129, 10 end
        return nil
    end)
    local mm = assert(minimapmod.parse(bytes, nil, '<corridor>'))
    local seeing = pathmod.new(mmClient(st, mm))
    local dirs2, why2 = seeing:getPath(st.player.pos, dest, 60)
    ok(dirs2 ~= nil, 'with the minimap the waypoint is reachable', why2)
    dirs2 = dirs2 or {}
    eq(#dirs2, 26, 'and the route is the 26 straight steps')
    local endPos = pathmod.endPosition(st.player.pos, dirs2)
    eq(endPos.x .. ',' .. endPos.y, dest.x .. ',' .. dest.y, 'it ends on the waypoint')
    local allEast = (#dirs2 > 0)
    for i = 1, #dirs2 do if dirs2[i] ~= worldm.EAST then allEast = false end end
    eq(allEast, true, 'every step is EAST -- the corridor the minimap remembers')
end

S('work item M: the minimap speed byte is the step cost')
do
    local st = sparseState(1000, 1000, 7, 1)
    local bytes = buildMinimap(960, 960, 1090, 1040, 7, function(x, y)
        if y == 1000 then return MM_SEEN, 129, 25 end       -- ground speed 250
        return nil
    end)
    local mm = assert(minimapmod.parse(bytes, nil, '<slow>'))
    local p = pathmod.new(mmClient(st, mm))
    local F = p:findEveryPath(st.player.pos, 12, {})
    -- x=1001 is inside the aware area (grass, groundSpeed 110); 1002.. come from the minimap
    local t1002 = F:node(1002, 1000)
    local t1005 = F:node(1005, 1000)
    ok(t1002 ~= nil and t1005 ~= nil, 'the field reaches out through the minimap')
    eq((t1005 or 0) - (t1002 or 0), 750, 'three minimap steps cost 3 * 250 -- the RECORDED speed')
end

S('work item M: an unseen minimap tile is only usable with allowUnseen')
do
    local st = sparseState(1000, 1000, 7, 1)
    local dest = { x = 1020, y = 1000, z = 7 }
    -- a one-tile-wide corridor with a hole at x = 1010 that was never explored
    local bytes = buildMinimap(960, 960, 1090, 1040, 7, function(x, y)
        if y == 1000 and x ~= 1010 then return MM_SEEN, 129, 10 end
        return nil                                  -- flags 0: never seen
    end)
    local mm = assert(minimapmod.parse(bytes, nil, '<gap>'))
    eq((mm:tile(1010, 1000, 7) or {}).seen, false, 'the gap tile is recorded as never seen')

    local p = pathmod.new(mmClient(st, mm))
    local dirs, why = p:getPath(st.player.pos, dest, 40)
    eq(dirs, nil, 'an unexplored tile is NOT pathable by default')
    eq(why, 'no-path', 'the search simply cannot cross it')

    local dirs2 = p:getPath(st.player.pos, dest, 40, { allowUnseen = true })
    ok(dirs2 ~= nil, 'allowUnseen opens it')
    eq(#(dirs2 or {}), 20, 'and the route is the straight 20 steps through the gap')

    -- the gate is a real gate: allowOnlyVisibleTiles skips the minimap branch entirely,
    -- so even the SEEN corridor disappears (map.cpp:1415)
    local dirs3, why3 = p:getPath(st.player.pos, dest, 40, { allowOnlyVisibleTiles = true })
    eq(dirs3, nil, 'allowOnlyVisibleTiles refuses to look at the minimap at all')
    eq(why3, 'no-path', '... and there is nothing else out there')
end

S('work item M: where both know a tile, the LIVE map wins')
do
    local dest = { x = 1012, y = 1000, z = 7 }
    -- one-tile-wide corridor in the minimap, walkable the whole way
    local bytes = buildMinimap(960, 960, 1090, 1040, 7, function(x, y)
        if y == 1000 then return MM_SEEN, 129, 10 end
        return nil
    end)
    local mm = assert(minimapmod.parse(bytes, nil, '<corridor>'))

    -- (a) the live state says there is a WALL at 1002,1000 -- inside the aware area.
    --     The minimap says that tile is walkable, and it is ignored.
    local walled = sparseState(1000, 1000, 7, 3, { ['1002,1000'] = true }, true)
    local pw = pathmod.new(mmClient(walled, mm))
    local dirs, why = pw:getPath(walled.player.pos, dest, 40)
    eq(dirs, nil, 'the live wall blocks the corridor the minimap calls walkable')
    eq(why, 'no-path', '... the minimap never gets a vote on an aware tile')
    -- and the wall really is the only reason: knock it out of the live map and the
    -- identical minimap now produces the route
    local open = sparseState(1000, 1000, 7, 3, nil, true)
    local po = pathmod.new(mmClient(open, mm))
    local dirs2 = po:getPath(open.player.pos, dest, 40)
    ok(dirs2 ~= nil, 'without the live wall the same minimap routes straight through')
    eq(#(dirs2 or {}), 12, 'twelve steps')

    -- (b) the other direction: the minimap remembers 1002,1000 as NOT WALKABLE, but the
    --     server has just described it as plain ground.  The live map wins again.
    local stale = buildMinimap(960, 960, 1090, 1040, 7, function(x, y)
        if y == 1000 and x == 1002 then return MM_SEEN + MM_NOTWALK, 0, 10 end
        if y == 1000 then return MM_SEEN, 129, 10 end
        return nil
    end)
    local mm2 = assert(minimapmod.parse(stale, nil, '<stale>'))
    eq((mm2:tile(1002, 1000, 7) or {}).walkable, false, 'the minimap remembers a blocker there')
    local ps = pathmod.new(mmClient(sparseState(1000, 1000, 7, 3, nil, true), mm2))
    local dirs3 = ps:getPath({ x = 1000, y = 1000, z = 7 }, dest, 40)
    ok(dirs3 ~= nil, 'but the live ground the server described overrides it')
    eq(#(dirs3 or {}), 12, 'and the route is the same twelve steps')

    -- (c) outside the aware area the stale record is still authoritative
    local ps2 = pathmod.new(mmClient(sparseState(1000, 1000, 7, 1, nil, true), mm2))
    local dirs4, why4 = ps2:getPath({ x = 1000, y = 1000, z = 7 }, dest, 40)
    eq(dirs4, nil, 'with 1002,1000 outside the aware area the minimap blocks it again')
    eq(why4, 'no-path', 'which is what makes the fallback load-bearing at all')
end

S('work item M: the 210-213 stair/hole band survives the minimap fallback')
do
    local dest = { x = 1012, y = 1000, z = 7 }
    local function corridorWith(colour, flags)
        local bytes = buildMinimap(960, 960, 1090, 1040, 7, function(x, y)
            if y ~= 1000 then return nil end
            if x == 1006 then return MM_SEEN + flags, colour, 10 end
            return MM_SEEN, 129, 10
        end)
        local mm = assert(minimapmod.parse(bytes, nil, '<stairband>'))
        return pathmod.new(mmClient(sparseState(1000, 1000, 7, 1), mm)), mm
    end

    -- 210 AND not-pathable: a real floor change.  Blocked even with ignoreNonPathable,
    -- because hasStairs is tested separately (map.cpp:1428-1432, bot/path.lua:419).
    local p, mm = corridorWith(210, MM_NOTPATH)
    eq((mm:tile(1006, 1000, 7) or {}).stairs, true, 'the reader flags it as stairs')
    eq(p:getPath({ x = 1000, y = 1000, z = 7 }, dest, 40), nil,
       'stairs are not walked over by default')
    eq(p:getPath({ x = 1000, y = 1000, z = 7 }, dest, 40, { ignoreNonPathable = true }), nil,
       'ignoreNonPathable alone does NOT open a staircase')
    ok(p:getPath({ x = 1000, y = 1000, z = 7 }, dest, 40,
                 { ignoreNonPathable = true, ignoreStairs = true }) ~= nil,
       'ignoreStairs + ignoreNonPathable does')

    -- the documented local patch: yellow ALONE is not a floor change.  Staircases are drawn
    -- over several yellow tiles of which only one changes floor, and blocking every one made
    -- them unreachable.
    local p2, mm2 = corridorWith(210, 0)
    eq((mm2:tile(1006, 1000, 7) or {}).stairs, false, 'colour 210 without NotPathable is NOT stairs')
    ok(p2:getPath({ x = 1000, y = 1000, z = 7 }, dest, 40) ~= nil,
       'and the pathfinder walks straight over it')

    -- the band is exactly 210..213
    for _, c in ipairs({ 210, 211, 212, 213 }) do
        local pc = corridorWith(c, MM_NOTPATH)
        eq(pc:getPath({ x = 1000, y = 1000, z = 7 }, dest, 40,
                      { ignoreNonPathable = true }), nil,
           'colour ' .. c .. ' + not-pathable is inside the band')
    end
    for _, c in ipairs({ 209, 214 }) do
        local pc = corridorWith(c, MM_NOTPATH)
        ok(pc:getPath({ x = 1000, y = 1000, z = 7 }, dest, 40,
                      { ignoreNonPathable = true }) ~= nil,
           'colour ' .. c .. ' + not-pathable is OUTSIDE the band')
    end
end

S('work item M: a blocked minimap tile counts as SEEN (map.cpp:1421-1422)')
do
    -- A tile the client remembers as a wall has NotWalkable but, in older saves, no WasSeen.
    -- The C++ sets wasSeen for it anyway, so allowUnseen cannot smuggle a known wall in.
    local dest = { x = 1012, y = 1000, z = 7 }
    local bytes = buildMinimap(960, 960, 1090, 1040, 7, function(x, y)
        if y ~= 1000 then return nil end
        if x == 1006 then return MM_NOTWALK, 0, 10 end      -- blocked, WasSeen NOT set
        return MM_SEEN, 129, 10
    end)
    local mm = assert(minimapmod.parse(bytes, nil, '<wall>'))
    eq((mm:tile(1006, 1000, 7) or {}).seen, false, 'the byte on disk really has no WasSeen')

    local st = sparseState(1000, 1000, 7, 1)
    local w = worldm.new(mmClient(st, mm))
    local seen, _, notWalk = w:classifyForPath({ x = 1006, y = 1000, z = 7 }, false)
    eq(notWalk, true, 'the classifier sees the blocker')
    eq(seen, true, 'and forces wasSeen on top of it (map.cpp:1421-1422)')

    local p = pathmod.new(mmClient(st, mm))
    eq(p:getPath({ x = 1000, y = 1000, z = 7 }, dest, 40), nil, 'the wall blocks')
    -- allowUnseen opens every UNEXPLORED tile, so a route exists again -- but it must go
    -- around the wall, never over it: blocked implies seen, so allowUnseen cannot reach it.
    local around = p:getPath({ x = 1000, y = 1000, z = 7 }, dest, 40, { allowUnseen = true })
    ok(around ~= nil, 'allowUnseen opens the unexplored ground either side')
    local over = false
    for _, q in ipairs(pathmod.positionsOf({ x = 1000, y = 1000, z = 7 }, around or {})) do
        if q.x == 1006 and q.y == 1000 then over = true end
    end
    eq(over, false, 'and the route still refuses to step on the remembered wall')
    ok(p:getPath({ x = 1000, y = 1000, z = 7 }, dest, 40,
                 { ignoreNonWalkable = true }) ~= nil, 'only ignoreNonWalkable opens it')
end

S('work item M: no minimap at all leaves every pre-work-item-M behaviour untouched')
do
    -- world.new with no `known` answers the reference client's null tile (0, 255, 10), which
    -- is exactly what the code did before this work item existed.
    local st = sparseState(1000, 1000, 7, 3)
    local w = worldm.new(mmClient(st, nil))
    local f, c, s = w:knownAt({ x = 1050, y = 1000, z = 7 })
    eq(f, 0, 'flags 0')
    eq(c, 255, 'colour 255')
    eq(s, 10, 'speed byte 10')
    local seen, _, notWalk, notPath, colour, speed =
        w:classifyForPath({ x = 1050, y = 1000, z = 7 }, false)
    eq(seen, false, 'an outside tile is not seen')
    eq(notWalk, false, 'and carries no blocking flag')
    eq(notPath, false, '...')
    eq(colour, 255, 'the null colour')
    eq(speed, 100, 'and the null speed byte * 10')

    -- a source that raises is reported once and then ignored, never propagated into the
    -- CaveBot macro (which bot/init.lua would retry every 10 ms forever)
    local hostile = worldm.new(mmClient(st, { get = function() error('boom') end }))
    local f2, c2, s2 = hostile:knownAt({ x = 1050, y = 1000, z = 7 })
    eq(f2 .. ',' .. c2 .. ',' .. s2, '0,255,10', 'a raising minimap degrades to the null tile')
    eq(hostile.knownFailed, true, 'and is switched off for the rest of the session')
end

-- ============================================================================
-- WORK ITEM V -- bug 4: the local player advanced TWO tiles per step and every
-- map row slice landed one column off.
--
-- The wire fact these tests encode (docs/live-findings.md, bug 4): for ONE player
-- step the server sends 0x6D MoveCreature and the matching row slice in the SAME
-- message, and GameMapMovePosition is OFF at 1530, so the row slice derives its own
-- position from `Map::getCentralPosition()`.  In the C++, parseCreatureMove does not
-- touch the camera -- only the row slice does.  Our parser used to advance the centre
-- in BOTH handlers, so:
--   * `state.player.pos` moved twice per step, and
--   * the slice wrote its column at (centre - 1) - 1, i.e. one tile too far in the
--     direction of travel, corrupting the tile store the pathfinder reads.
-- ============================================================================
do
    S('WORK ITEM V: bug 4 -- one step is ONE tile, and the row slice lands square')

    local parser = require('proto.parser')

    -- default aware range (selftest pins these): left 8, top 6, right 9, bottom 7
    local AL, AT = 8, 6
    local AH     = AT + 7 + 1               -- top + bottom + 1 = 14 rows in a column

    local function u16le(v) return string.char(v % 256, math.floor(v / 256) % 256) end
    local function posBytes(p) return u16le(p.x) .. u16le(p.y) .. string.char(p.z) end

    -- A floor description that is nothing but empty tiles: setTileDescription cleans the
    -- first tile then reads [skip][0xFF]; setFloorDescription cleans the remaining `skip`.
    local function emptyColumn()          -- w=1, h=AH, on all 8 floors of a z<=7 description
        return string.rep(string.char(AH - 1, 0xFF), 8)
    end

    local function newParser()
        local st = state.new()
        local ev = {}
        local p = parser.new(st, function(name, data) ev[#ev + 1] = { name = name, data = data } end)
        st.player.id = 0x1000
        st.player.pos = { x = 100, y = 100, z = 7 }
        st:addCreature({ id = 0x1000, name = 'me', speed = 129 })
        -- ground under the whole east-west corridor, so every 0x6D's `fromStackPos = 1`
        -- addresses the creature exactly as the real server's does
        for x = 90, 112 do
            st:addThing({ x = x, y = 100, z = 7 }, -2, { kind = 'item', id = ID_GROUND })
        end
        st:addThing({ x = 100, y = 100, z = 7 }, -1,
                    { kind = 'creature', creatureId = 0x1000, id = 0x63 })
        p.central = { x = 100, y = 100, z = 7 }
        return st, p, ev
    end
    local function posOf(ev)
        local n, last = 0, nil
        for _, e in ipairs(ev) do
            if e.name == 'positionChange' then n = n + 1; last = e.data.pos end
        end
        return n, last
    end
    local function posStr(p)
        if not p then return 'nil' end
        return ('%d,%d,%d'):format(p.x, p.y, p.z)
    end

    -- ---- one westward step: 0x6D then 0x68 MapLeftRow, one message ----------
    do
        local st, p, ev = newParser()
        -- a marker item in the column the slice must clear.  Pre-fix the centre was
        -- already at 99 when 0x68 ran, so the slice addressed x=90 and this survived.
        for y = 90, 112 do
            st:addThing({ x = 91, y = y, z = 7 }, -2, { kind = 'item', id = ID_GROUND })
        end

        local move = string.char(0x6D) .. posBytes({ x = 100, y = 100, z = 7 })
                     .. string.char(1) .. posBytes({ x = 99, y = 100, z = 7 })
        p:parse(move)

        eq(posStr(st.player.pos), '99,100,7', '0x6D moved the player exactly one tile')
        eq(posStr(p.central),     '100,100,7', '0x6D did NOT advance the camera (C++ never does)')
        local n, last = posOf(ev)
        eq(n, 1, '0x6D emitted exactly one positionChange')
        eq(posStr(last), '99,100,7', 'and it carried the real new tile')

        -- the row slice that the server put in the SAME message
        p:parse(string.char(0x68) .. emptyColumn())

        eq(posStr(p.central), '99,100,7', 'the row slice is what advances the camera')
        eq(posStr(st.player.pos), '99,100,7',
           'the row slice did NOT advance the player a second time')
        eq(select(1, posOf(ev)), 1, 'still exactly ONE positionChange for the whole step')

        -- x of the written column = (central.x after the slice) - aware.left = 99 - 8 = 91
        eq(st:tile({ x = 91, y = 100, z = 7 }), nil,
           'the empty column was applied at x=91 (centre 99 - awareRange.left 8)')
        eq(st:tile({ x = 90, y = 100, z = 7 }), nil,
           'x=90 -- where the double-advance used to write it -- is outside the new rect')
        ok(st:tile({ x = 99, y = 100, z = 7 }) ~= nil, 'and our own tile survived the sweep')
    end

    -- ---- and back east: the error used to flip sides ------------------------
    do
        local st, p, ev = newParser()
        for y = 90, 112 do
            st:addThing({ x = 109, y = y, z = 7 }, -2, { kind = 'item', id = ID_GROUND })
            st:addThing({ x = 110, y = y, z = 7 }, -2, { kind = 'item', id = ID_GROUND })
        end
        p:parse(string.char(0x6D) .. posBytes({ x = 100, y = 100, z = 7 }) .. string.char(1)
                .. posBytes({ x = 101, y = 100, z = 7 }))
        p:parse(string.char(0x66) .. emptyColumn())          -- MapRightRow
        eq(posStr(st.player.pos), '101,100,7', 'an eastward step is one tile too')
        eq(posStr(p.central),     '101,100,7', 'centre follows the player, not ahead of it')
        eq(select(1, posOf(ev)), 1, 'one positionChange')
        -- x = central.x + aware.right = 101 + 9 = 110
        eq(st:tile({ x = 110, y = 100, z = 7 }), nil, 'the east column was applied at x=110')
        ok(st:tile({ x = 109, y = 100, z = 7 }) ~= nil, 'and not at x=109')
    end

    -- ---- four steps out and back: the walker's ledger sees 1:1 -------------
    do
        local st, p, ev = newParser()
        local x = 100
        local route = { -1, -1, -1, 1, 1, 1 }
        for _, dx in ipairs(route) do
            local from, to = x, x + dx
            p:parse(string.char(0x6D) .. posBytes({ x = from, y = 100, z = 7 })
                    .. string.char(1) .. posBytes({ x = to, y = 100, z = 7 }))
            p:parse(string.char(dx < 0 and 0x68 or 0x66) .. emptyColumn())
            x = to
        end
        eq(posStr(st.player.pos), '100,100,7', 'six steps out and back land on the start tile')
        eq(posStr(p.central),     '100,100,7', 'and so does the camera')
        eq(select(1, posOf(ev)), 6, 'six moves produced exactly six positionChange events')
    end

    -- ---- 0x6C for OURSELVES must not destroy the local player's record -----
    -- TFS sends RemoveTileThing instead of 0x6D for the surface -> underground floor
    -- change and for a teleport.  Dropping the record loses the creature speed the
    -- walker paces on, which silently reinstates bug 2's 200 ms fallback mid-hunt.
    do
        local st, p, ev = newParser()
        p:parse(string.char(0x6C) .. posBytes({ x = 100, y = 100, z = 7 }) .. string.char(1))
        ok(st.creatures[0x1000] ~= nil, '0x6C on the local player keeps the creature record')
        eq(st.creatures[0x1000].speed, 129, 'and its speed, which is what paces every step')
        eq(st.creatures[0x1000].pos, nil, 'but it is off the map until the server re-adds it')
        local sawGone = false
        for _, e in ipairs(ev) do
            if e.name == 'creatureDisappear' then sawGone = true end
        end
        eq(sawGone, false, 'and no creatureDisappear is emitted for ourselves')

        -- a monster is still dropped normally
        st:addCreature({ id = 0x2000, name = 'rat', pos = { x = 101, y = 100, z = 7 } })
        st:addThing({ x = 101, y = 100, z = 7 }, -1,
                    { kind = 'creature', creatureId = 0x2000, id = 0x63 })
        p:parse(string.char(0x6C) .. posBytes({ x = 101, y = 100, z = 7 }) .. string.char(1))
        eq(st.creatures[0x2000], nil, 'a monster IS dropped by 0x6C')
    end

    -- ---- while we are off the map, the centre is what fixes us up ----------
    -- Map::setCentralPosition's deferred local-player fixup (map.cpp).
    do
        local st, p = newParser()
        p:parse(string.char(0x6C) .. posBytes({ x = 100, y = 100, z = 7 }) .. string.char(1))
        p:setCentral({ x = 100, y = 101, z = 8 })
        eq(posStr(st.player.pos), '100,101,8',
           'off the map, setCentral snaps us to the new centre')
        -- back on the map: the creature record wins over the bare centre
        st:addThing({ x = 100, y = 102, z = 8 }, -1,
                    { kind = 'creature', creatureId = 0x1000, id = 0x63 })
        p:setCentral({ x = 100, y = 101, z = 8 })
        eq(posStr(st.player.pos), '100,102,8',
           'on the map, the creature record the wire wrote wins')
    end
end

-- ============================================================================
-- The five per-module suites, embedded so --selftest gates all of them.
-- ============================================================================
local embedded = {}
if not _G.BOTSUITE_ONLY_INTEGRATION then
    local suites = {
        { 'F1 item metadata + tile flags', 'BOT_F1_NO_EXIT', 'test/f1_metadata.lua' },
        { 'F2 pathfinder + walker',        'BOT_F2_NO_EXIT', 'test/bot_f2_path.lua' },
        { 'F3 bot core + api',             'BOT_F3_NO_EXIT', 'test/bot_f3.lua' },
        { 'M1 healbot + attackbot',        'BOT_M1_NO_EXIT', 'test/bot_m1.lua' },
        { 'M2 cavebot + supplies',         'BOT_M2_NO_EXIT', 'test/bot_m2_cavebot.lua' },
        { 'M3 targetbot + loot',           'BOT_M3_NO_EXIT', 'test/bot_m3_target.lua' },
    }
    for _, s in ipairs(suites) do
        io.write('\n================ embedded: ', s[1], ' ================\n')
        _G[s[2]] = true
        local okr, res = pcall(dofile, ROOT .. '/' .. s[3])
        _G[s[2]] = nil
        loadItems()                     -- a suite may have unloaded the item table
        if not okr then
            fail = fail + 1
            local line = '   FAIL embedded ' .. s[1] .. ' raised: ' .. tostring(res)
            msgs[#msgs + 1] = line
            io.write(line, '\n')
            embedded[#embedded + 1] = { name = s[1], pass = 0, fail = 1 }
        elseif type(res) ~= 'table' then
            fail = fail + 1
            local line = '   FAIL embedded ' .. s[1] .. ' returned ' .. type(res)
                         .. ' (the NO_EXIT hook did not fire)'
            msgs[#msgs + 1] = line
            io.write(line, '\n')
            embedded[#embedded + 1] = { name = s[1], pass = 0, fail = 1 }
        else
            pass = pass + (res.pass or 0)
            fail = fail + (res.fail or 0)
            for _, m in ipairs(res.failures or {}) do msgs[#msgs + 1] = m end
            embedded[#embedded + 1] = { name = s[1], pass = res.pass or 0, fail = res.fail or 0 }
        end
    end
end

-- ============================================================================
io.write('\n================ botsuite ================\n')
for _, e in ipairs(embedded) do
    io.write(('  %-34s %s  %d passed'):format(e.name, e.fail == 0 and 'PASS' or 'FAIL', e.pass))
    if e.fail > 0 then io.write((', %d FAILED'):format(e.fail)) end
    io.write('\n')
end
for _, m in ipairs(msgs) do io.write(m, '\n') end
io.write(('  TOTAL: %d passed, %d failed  -> %s\n')
         :format(pass, fail, fail == 0 and 'PASS' or 'FAIL'))

if _G.BOTSUITE_NO_EXIT then return { pass = pass, fail = fail, failures = msgs } end
os.exit(fail == 0 and 0 or 1)
