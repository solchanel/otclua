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
