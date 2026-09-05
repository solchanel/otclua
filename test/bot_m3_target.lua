--[[============================================================================
test/bot_m3_target.lua -- offline tests for work item M3 (bot/targetbot.lua, bot/loot.lua).

No network, no live account: everything runs against a synthetic world built from ASCII
maps, a scripted container store and a capturing sender.  The creature configs come from
the USER'S REAL FILES under
  D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/targetbot_configs/
loaded UNCHANGED through bot/config.lua, so the format of record is exercised for real.

    luajit test/bot_m3_target.lua            (from D:/Claude/otclient_web/luaclient)

Exits non-zero on any failure.  Set _G.BOT_M3_NO_EXIT = true before dofile()ing it to get
`{pass=, fail=, failures={}}` back instead.
============================================================================]]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. package.path
end

local state     = require('game.state')
local events    = require('lib.events')
local worldmod  = require('bot.world')
local pathmod   = require('bot.path')
local walkmod   = require('bot.walker')
local lootmod   = require('bot.loot')
local tbmod     = require('bot.targetbot')
local cfgmod    = require('bot.config')

-- The user's REAL vBot profile.  The same drive is reachable under two names depending on
-- which OS is running the test, so probe for it rather than hard-coding one.
local VBOT_PROFILE
do
    for _, root in ipairs({ 'D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
                            '/mnt/d/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8' }) do
        local f = io.open(root .. '/targetbot_configs/true_asura.json', 'rb')
        if f then f:close(); VBOT_PROFILE = root; break end
    end
    if not VBOT_PROFILE then
        io.write('!! the vBot reference profile was not found; the config tests cannot run\n')
        os.exit(2)
    end
end

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
    if got == want then return ok(true, desc) end
    return ok(false, desc, ('got %s, want %s'):format(tostring(got), tostring(want)))
end
local function near(got, want, desc)
    if type(got) == 'number' and math.abs(got - want) < 1e-9 then return ok(true, desc) end
    return ok(false, desc, ('got %s, want %s'):format(tostring(got), tostring(want)))
end
local function list2str(t, f)
    if t == nil then return 'nil' end
    local o = {}
    for i = 1, #t do o[i] = f and f(t[i]) or tostring(t[i]) end
    return '{' .. table.concat(o, ',') .. '}'
end
local function eqList(got, want, desc, f)
    local g, w = list2str(got, f), list2str(want, f)
    if g == w then return ok(true, desc .. ' = ' .. g) end
    return ok(false, desc, ('got %s, want %s'):format(g, w))
end

-- ============================================================ fake item table
-- Same shape as test/bot_f2_path.lua's, plus the two flags the looter needs.
local ITEMS = {
    [100] = { ground = true, speed = 100 },
    [200] = { unpass = true, unsight = true },        -- wall
    [300] = { avoid  = true },                        -- magic field
    [501] = { lens   = 1104 },                        -- stairs up (a floor change)
    -- looting fixtures
    [3031] = { stackable = true },                    -- gold coin
    [3043] = { stackable = true },                    -- crystal coin
    [2854] = { container = true },                    -- backpack (a loot bag)
    [23721] = { container = true },                   -- the user's real loot bag id
    [3994] = { container = true, corpse = true },     -- dead rat (the corpse)
    [1987] = { container = true },                    -- bag (nested, NOT on the loot list)
    [16131] = {},                                     -- a wanted non-stackable
    [9636]  = {},                                     -- a wanted non-stackable
    [3982]  = {},                                     -- junk, never on any list
    [3582]  = {},                                     -- ham (foodItems[1] on the real profile)
}
local function I(id) return ITEMS[id] or {} end
local fakeItems = {
    isGround          = function(id) return I(id).ground    == true end,
    isGroundBorder    = function(id) return I(id).clip      == true end,
    isOnBottom        = function(id) return I(id).bottom    == true end,
    isOnTop           = function(id) return I(id).top       == true end,
    isNotWalkable     = function(id) return I(id).unpass    == true end,
    isNotPathable     = function(id) return I(id).avoid     == true end,
    isBlockProjectile = function(id) return I(id).unsight   == true end,
    isForceUse        = function(id) return I(id).forceuse  == true end,
    isSplash          = function(id) return I(id).splash    == true end,
    groundSpeed       = function(id) return I(id).speed or 0 end,
    minimapColor      = function(id) return I(id).color or 0 end,
    elevation         = function(id) return I(id).elev  or 0 end,
    lensHelp          = function(id) return I(id).lens  or 0 end,
    isContainer       = function(id) return I(id).container == true end,
    isStackable       = function(id) return I(id).stackable == true end,
    isFluidContainer  = function(id) return I(id).fluid     == true end,
}

-- ============================================================ capturing sender
local function newSender()
    local s = { packets = {} }
    local function rec(kind, t)
        t = t or {}
        t.kind = kind
        s.packets[#s.packets + 1] = t
        return kind                                    -- a truthy "body"
    end
    function s:walk(dir)  return rec('walk',  { dir = dir }) end
    function s:turn(dir)  return rec('turn',  { dir = dir }) end
    function s:stop()     return rec('stop') end
    function s:autoWalk(d) return rec('autoWalk', { dirs = d }), #d end
    function s:attack(id) return rec('attack', { id = id }) end
    function s:cancelAttackAndFollow() return rec('cancelAttackAndFollow') end
    function s:talk(mode, ch, rcv, text) return rec('talk', { text = text }) end
    function s:openContainer(pos, itemId, stackpos, cid)
        return rec('open', { pos = pos, id = itemId, stackpos = stackpos, cid = cid })
    end
    function s:closeContainer(id) return rec('close', { cid = id }) end
    function s:move(fromPos, itemId, stackpos, toPos, count)
        return rec('move', { from = fromPos, id = itemId, stackpos = stackpos,
                             to = toPos, count = count })
    end
    function s:use(pos, itemId, stackpos, index)
        return rec('use', { pos = pos, id = itemId, stackpos = stackpos, index = index })
    end
    function s:useOnCreature(pos, itemId, stackpos, cid)
        return rec('useOnCreature', { id = itemId, creatureId = cid })
    end
    function s:byKind(kind)
        local o = {}
        for i = 1, #s.packets do if s.packets[i].kind == kind then o[#o + 1] = s.packets[i] end end
        return o
    end
    function s:clear() s.packets = {} end
    return s
end

-- ============================================================ synthetic world
-- '.' floor  '#' floor+wall  '~' floor+field  'U' floor+stairs-up  ' ' no tile
-- '@' start  'X' goal
local nextCreatureId = 5000
local CLOCK = { t = 100000 }
local function now() return CLOCK.t end

local function buildMap(rows, opts)
    opts = opts or {}
    local st = state.new()
    local baseX, baseY, z = opts.baseX or 1000, opts.baseY or 1000, opts.z or 7
    local a = st.world.awareRange
    a.left, a.top, a.right, a.bottom = 40, 40, 40, 40
    local start, goal
    for y = 1, #rows do
        local row = rows[y]
        for x = 1, #row do
            local ch = row:sub(x, x)
            local pos = { x = baseX + x - 1, y = baseY + y - 1, z = z }
            local ground, extra
            if ch == '.' or ch == '@' or ch == 'X' then ground = 100
            elseif ch == '#' then ground, extra = 100, 200
            elseif ch == '~' then ground, extra = 100, 300
            elseif ch == 'U' then ground, extra = 100, 501
            elseif ch == ' ' then ground = nil
            else error('bad map char ' .. ch) end
            if ground then
                st:addThing(pos, 0, { kind = 'item', id = ground })
                if extra then st:addThing(pos, -2, { kind = 'item', id = extra }) end
            end
            if ch == '@' then start = pos end
            if ch == 'X' then goal = pos end
        end
    end
    st.player.id    = 1
    st.player.pos   = start or { x = baseX, y = baseY, z = z }
    st.player.speed = 220
    st.player.mana  = 500
    st.player.states = 0
    st.player.freeCapacity = 1000
    st.player.capacity     = 2000
    st.player.direction    = 0
    st.player.inventory    = {}
    st.central = { x = st.player.pos.x, y = st.player.pos.y, z = st.player.pos.z }
    return st, start, goal, { x = baseX, y = baseY, z = z }
end

local function addMonster(st, pos, name, o)
    o = o or {}
    nextCreatureId = nextCreatureId + 1
    local id = o.id or nextCreatureId
    local c = { id = id, name = name, type = o.type or 1, pos = pos,
                healthPercent = o.hp or 100, isMonster = o.isMonster ~= false,
                isPlayer = o.isPlayer or false, shield = o.shield or 0,
                passable = o.passable or false,
                outfit = { lookType = 128, lookTypeEx = 0 } }
    local stored = st:addCreature(c)
    st:addThing(pos, -2, { kind = 'creature', creatureId = id, id = 0x63 })
    return stored          -- state:addCreature OWNS the record; the argument is only a seed
end

local function removeMonster(st, c)
    local sp = st:creatureStackPos(c.pos, c.id)
    if sp then st:removeThing(c.pos, sp) end
    st:removeCreature(c.id)
end

--- The bot-like host: storage, schedule, configState, modules.  Small enough to keep the
--- tests deterministic, faithful enough that bot/targetbot.lua cannot tell.
local function newHost(st, opts)
    opts = opts or {}
    local sender = newSender()
    local bus = events.new()
    local logged = {}
    local client = { state = st, sender = sender, events = bus, items = fakeItems,
                     log = { info = function() end, debug = function() end,
                             warn  = function(f) logged[#logged + 1] = tostring(f) end,
                             error = function(f) logged[#logged + 1] = tostring(f) end } }
    local host = {
        client = client, state = st, sender = sender, events = bus,
        storage = opts.storage or { extras = {}, _configs = {} },
        modules = {}, logged = logged, sched = {},
    }
    host.now = CLOCK.t
    if type(host.storage._configs) ~= 'table' then host.storage._configs = {} end
    function host:configState(dir)
        local c = self.storage._configs[dir]
        if type(c) ~= 'table' then c = { enabled = false, selected = '' }
            self.storage._configs[dir] = c end
        return c
    end
    function host:setConfigEnabled(dir, on) self:configState(dir).enabled = on and true or false end
    function host:selectConfig(dir, name) self:configState(dir).selected = name end
    function host:schedule(ms, fn)
        self.sched[#self.sched + 1] = { at = CLOCK.t + ms, fn = fn }
        return self.sched[#self.sched]
    end
    function host:drain()
        local again = true
        while again do
            again = false
            for i = 1, #self.sched do
                local e = self.sched[i]
                if e and not e.done and e.at <= CLOCK.t then
                    e.done = true; e.fn(); again = true
                end
            end
        end
    end
    function host:advance(ms) CLOCK.t = CLOCK.t + ms; self.now = CLOCK.t; self:drain() end
    function host:sync() self.now = CLOCK.t end
    return host
end

local function newTB(st, config, opts)
    opts = opts or {}
    local host = opts.host or newHost(st, opts)
    local world = worldmod.new(host.client)
    local path  = pathmod.new(host.client, world)
    local walker = walkmod.new(host.client, { world = world, path = path,
                                              config = opts.walkerConfig, now = now })
    host.world, host.path, host.walker = world, path, walker
    local tb = tbmod.new(host, config, { world = world, path = path, walker = walker,
                                         now = now })
    tb:setOn()
    host.modules.targetbot = tb
    return tb, host
end

-- a tiny targeting entry factory using the editor defaults
local function entry(t)
    local e = { name = t.name or '*', priority = t.priority or 1, danger = t.danger or 1 }
    for k, v in pairs(t) do e[k] = v end
    for k, v in pairs(tbmod.ENTRY_DEFAULTS) do if e[k] == nil then e[k] = v end end
    return e
end

local function cfgOf(targeting, looting)
    return { targeting = targeting, looting = looting or { items = {}, containers = {} } }
end

-- ============================================================================
S('config: the user REAL targetbot_configs load unchanged')
do
    local profile = cfgmod.new{ profileDir = VBOT_PROFILE, vprofile = 1 }
    local names = profile:listTargetbots()
    ok(#names >= 10, 'the profile lists its targetbot configs (' .. #names .. ')')

    local asura = profile:loadTargetbot('true_asura')
    ok(type(asura) == 'table', 'true_asura.json parses')
    eq(#asura.targeting, 1, 'true_asura has one targeting entry')
    eq(asura.targeting[1].name, '*', 'its name pattern is "*"')
    eq(asura.targeting[1].regex, '^.*$', 'its cached regex is ^.*$')
    eq(asura.targeting[1].dontLoot, true, 'dontLoot is true on that entry')
    eq(asura.looting.containers[1].id, 23721, 'the loot bag id is 23721')
    eq(#asura.looting.items, 2, 'two loot item ids')
    eq(asura.looting.maxDanger, 10, 'maxDanger 10')
    eq(asura.looting.minCapacity, 100, 'minCapacity 100')

    local turter = profile:loadTargetbot('turter')
    eq(#turter.targeting, 4, 'turter.json has 4 entries')
    eqList({ turter.targeting[1].priority, turter.targeting[2].priority,
             turter.targeting[3].priority, turter.targeting[4].priority },
           { 4, 3, 2, 1 }, 'their priorities in list order')
    eq(turter.targeting[4].maxDistance, 10, 'Hand Of Cursed Fate keeps maxDistance 10')
    eq(turter.looting.maxDanger, 25, 'turter maxDanger 25')

    local empty = profile:loadTargetbot('true_asuras')
    ok(type(empty) == 'table', 'true_asuras.json ("[]") loads as an empty table')

    -- the storage file supplies the real extras
    local storage = profile:loadStorage()
    eq(storage.extras.killUnder, 1,  'storage extras.killUnder = 1')
    eq(storage.extras.looting,   40, 'storage extras.looting = 40')
    eq(storage.extras.lootDelay, 220,'storage extras.lootDelay = 220 (not the 200 default)')
    eq(storage.extras.lootLast,  true, 'storage extras.lootLast = true')
    eq(storage.foodItems[1].id,  3582, 'foodItems[1] is ham (3582)')
    eq(storage.targetbotAvoidFloorChange, nil,
       'targetbotAvoidFloorChange is absent -> the guard defaults ON')
end

-- ============================================================================
S('config: name -> regex and matching')
do
    eq(tbmod.buildRegex('*'), '^.*$', 'the "*" pattern')
    eq(tbmod.buildRegex('Demon,Vexclaw,Grimeleech,Blightwalker,Undead Dragon'),
       '^demon$|^vexclaw$|^grimeleech$|^blightwalker$|^undead dragon$',
       'hellhub.json name -> regex, byte for byte')
    eq(tbmod.buildRegex('Dark Torturer'), '^dark torturer$', 'a single name')

    ok(tbmod.matchesName('anything at all', '^.*$'), '"*" matches everything')
    ok(tbmod.matchesName('dark torturer', '^dark torturer$'), 'exact name matches')
    ok(not tbmod.matchesName('dark torturers', '^dark torturer$'), 'and is anchored')
    ok(tbmod.matchesName('vexclaw',
        '^demon$|^vexclaw$|^grimeleech$|^blightwalker$|^undead dragon$'),
       'alternation matches the second name')
    ok(not tbmod.matchesName('hellflayer',
        '^demon$|^vexclaw$|^grimeleech$|^blightwalker$|^undead dragon$'),
       'and rejects a name that is not in the list')

    -- VERIFIER: `?` is `.?` = ZERO OR ONE, not "exactly one"
    local re = tbmod.buildRegex('Dem?n')
    eq(re, '^dem.?n$', '"?" becomes ".?"')
    ok(tbmod.matchesName('demon', re), 'and matches "demon" (the ".?" eats the "o")')
    ok(tbmod.matchesName('demn',  re), 'AND "demn" -- ZERO or one, per the VERIFIER')
    -- (the VERIFIER's own example, "Demo?n", is `^demo.?n$` and matches "demon"/"demoXn"
    --  but NOT "demn"; the correction it makes -- `?` is `.?`, zero-or-one of ANY char --
    --  is what matters and is what this asserts.)
    local re3 = tbmod.buildRegex('Demo?n')
    ok(tbmod.matchesName('demon', re3) and not tbmod.matchesName('demn', re3),
       'and "Demo?n" really is ^demo.?n$ -- the literal "o" survives')

    -- Lua-magic characters in a real monster name must not blow up the matcher
    local re2 = tbmod.buildRegex('Kongra-Ape (Test)')
    ok(tbmod.matchesName('kongra-ape (test)', re2),
       'a name with Lua-magic characters still matches')
    ok(not tbmod.matchesName('kongraXape (test)', re2), 'and "-" is a literal, not a range')

    -- a hand-edited regex that disagrees with `name` must WIN (VERIFIER)
    local st = buildMap({ '@.....' })
    local tb = newTB(st, cfgOf{ entry{ name = 'Rat', regex = '^dragon$' } })
    local c = addMonster(st, { x = 1002, y = 1000, z = 7 }, 'Rat')
    eq(#tb:getConfigs(c), 0, 'the persisted regex wins over the name field')
    local d = addMonster(st, { x = 1003, y = 1000, z = 7 }, 'Dragon')
    eq(#tb:getConfigs(d), 1, 'and the creature the regex names does match')
end

-- ============================================================================
S('selection: the exact scores decide, adjacency bonus included')
do
    local st, start = buildMap({ '.......', '.@.....', '.......' })
    local tb = newTB(st, cfgOf{
        entry{ name = 'Dark Torturer', priority = 4, danger = 3, maxDistance = 8 },
        entry{ name = 'Lost Soul',     priority = 2, danger = 1, maxDistance = 8 },
    })
    local dt = addMonster(st, { x = start.x + 3, y = start.y, z = 7 }, 'Dark Torturer')
    local ls = addMonster(st, { x = start.x + 1, y = start.y, z = 7 }, 'Lost Soul')

    local pDT = tb:calculateParams(dt, { 1, 1, 1 })     -- 3 steps
    local pLS = tb:calculateParams(ls, { 1 })           -- 1 step
    near(pDT.priority, 4 + 5,  'Dark Torturer: priority 4 + the <=3 bonus 5 = 9')
    near(pLS.priority, 2 + 10, 'Lost Soul: priority 2 + the ==1 bonus 10 = 12')

    tb:tick()
    eq(tb.lastParams.creature.id, ls.id, 'so the ADJACENT Lost Soul is selected')
    eq(tb.targets, 2, 'both monsters counted as targets')
    near(tb:Danger(), 4, 'and the danger aggregate CaveBot sees is 3 + 1 = 4')

    -- move the Dark Torturer next to us too: 4+10 = 14 > 12
    local sender = tb.sender
    removeMonster(st, dt)
    local dt2 = addMonster(st, { x = start.x, y = start.y - 1, z = 7 }, 'Dark Torturer')
    tb:tick()
    eq(tb.lastParams.creature.id, dt2.id, 'adjacent Dark Torturer (14) now beats the Lost Soul (12)')
end

-- ============================================================================
S('selection: hysteresis keeps the current target')
do
    local st, start = buildMap({ '.......', '.@.....', '.......' })
    local tb = newTB(st, cfgOf{ entry{ name = '*', priority = 1, danger = 1 } })
    local a = addMonster(st, { x = start.x + 2, y = start.y, z = 7 }, 'Rat A')
    local b = addMonster(st, { x = start.x + 2, y = start.y + 1, z = 7 }, 'Rat B')

    tb:tick()
    local first = tb.lastParams.creature.id
    eq(first, a.id, 'the spectator order (y then x, ascending) picks Rat A first')
    eq(tb.attackingId, a.id, 'and it is attacked')

    -- both now score priority 1 + the <=3 bonus 5 = 6; the current target adds +1
    local pA = tb:calculateParams(a, { 1, 1 })
    local pB = tb:calculateParams(b, { 4, 1 })
    near(pA.priority, 7, 'the current target scores 6 + 1 hysteresis = 7')
    near(pB.priority, 6, 'the rival scores 6')
    tb:tick()
    eq(tb.lastParams.creature.id, a.id, 'so the target does NOT flip on the next tick')

    -- a rival that scores MORE than +1 higher steals it immediately
    b.healthPercent = 15                       -- chase=true -> the <30 branch gives +5
    local pB2 = tb:calculateParams(b, { 4, 1 })
    near(pB2.priority, 11, 'a 15 %% rival with chase=true gets +5 (never +2.5) = 11')
    tb:tick()
    eq(tb.lastParams.creature.id, b.id, 'and it steals the target on the very next tick')
    eq(tb.attackingId, b.id, 'the attack is re-sent for the new target')
end

-- ============================================================================
S('selection: the maxDistance gate and the out-of-range current target')
do
    local st, start = buildMap({ '.........', '.@.......', '.........' })
    local tb = newTB(st, cfgOf{ entry{ name = '*', priority = 5, danger = 7,
                                       maxDistance = 2 } })
    local c = addMonster(st, { x = start.x + 5, y = start.y, z = 7 }, 'Rat')
    local p = tb:calculateParams(c, { 1, 1, 1, 1, 1 })
    near(p.priority, 0, 'out of maxDistance with no hysteresis scores 0')
    near(p.danger, 0, 'and contributes 0 danger')

    tb.attackingId = c.id
    local p2 = tb:calculateParams(c, { 1, 1, 1, 1, 1 })
    near(p2.priority, 1, 'VERIFIER: the CURRENT target out of range still scores 1')
    near(p2.danger, 7, 'and 1 > 0 so it DOES add its danger to the aggregate')
    ok(p2.config ~= nil, 'and it selects a config')
end

-- ============================================================================
S('selection: rpSafe cancels the attack when the target leaves maxDistance')
do
    local st, start = buildMap({ '.........', '.@.......' })
    local tb = newTB(st, cfgOf{ entry{ name = '*', maxDistance = 2, rpSafe = true } })
    local c = addMonster(st, { x = start.x + 5, y = start.y, z = 7 }, 'Rat')
    tb.attackingId = c.id
    tb.sender:clear()
    tb:calculateParams(c, { 1, 1, 1, 1, 1 })
    eq(#tb.sender:byKind('cancelAttackAndFollow'), 1, 'cancelAttackAndFollow was sent')
    eq(tb.attackingId, nil, 'and the tracked target was cleared')
end

-- ============================================================================
S('selection: diamondArrows adds a floor of +4 (the monster counts itself)')
do
    local st, start = buildMap({ '.......', '.......', '..@....', '.......', '.......' })
    local tb = newTB(st, cfgOf{ entry{ name = '*', priority = 4, diamondArrows = true,
                                       maxDistance = 10 } })
    local c = addMonster(st, { x = start.x + 4, y = start.y, z = 7 }, 'Dark Torturer')
    local p = tb:calculateParams(c, { 1, 1, 1, 1 })
    near(p.priority, 4 + 4, 'a LONE monster still scores priority 4 + 1 mob * 4 = 8')

    addMonster(st, { x = start.x + 4, y = start.y + 1, z = 7 }, 'Dark Torturer')
    local p2 = tb:calculateParams(c, { 1, 1, 1, 1 })
    near(p2.priority, 4 + 8, 'a second mob inside its diamond adds another 4')
end

-- ============================================================================
S('selection: the low-HP chain is if/elseif, and summons are excluded')
do
    local st, start = buildMap({ '.......', '.@.....' })
    local tb = newTB(st, cfgOf{ entry{ name = '*', priority = 0, chase = true } })
    local c = addMonster(st, { x = start.x + 5, y = start.y, z = 7 }, 'Rat')
    local function score(hp, chase)
        c.healthPercent = hp
        tb.targeting[1].chase = chase
        tb.configsCache = {}
        return tb:calculateParams(c, { 1, 1, 1, 1, 1 }).priority
    end
    near(score(15, true),  5,   'chase + 15 %% -> +5 (the first branch wins)')
    near(score(15, false), 2.5, 'no chase + 15 %% -> +2.5')
    near(score(35, true),  1.5, '35 %% -> +1.5')
    near(score(55, true),  0.5, '55 %% -> +0.5')
    near(score(75, true),  0.2, '75 %% -> +0.2')
    near(score(95, true),  0,   '95 %% -> nothing')

    -- summons: creature type >= 3
    local st2, start2 = buildMap({ '.......', '.@.....' })
    local tb2 = newTB(st2, cfgOf{ entry{ name = '*', priority = 1 } })
    local real   = addMonster(st2, { x = start2.x + 2, y = start2.y, z = 7 }, 'Rat')
    local summon = addMonster(st2, { x = start2.x + 1, y = start2.y, z = 7 },
                              'Fire Elemental', { type = 3 })
    tb2:tick()
    eq(tb2.targets, 1, 'a SummonOwn (type 3) is not a candidate: only the Rat counts')
    eq(tb2.lastParams.creature.id, real.id,
       'and the real monster is selected even though the summon is closer')
end

-- ============================================================================
S('combat: chase stepping produces the right directions')
do
    local st, start = buildMap({ '........', '.@......', '........' })
    local tb, host = newTB(st, cfgOf{ entry{ name = '*', chase = true, maxDistance = 10 } })
    local c = addMonster(st, { x = start.x + 4, y = start.y, z = 7 }, 'Rat')
    tb.sender:clear()

    local sent = {}
    for i = 1, 3 do
        tb:tick()
        local w = tb.sender:byKind('walk')
        if #w > #sent then sent[#sent + 1] = w[#w].dir end
        -- confirm the step so the ledger drains, then advance past the walk delay
        local pp = st.player.pos
        local np = { x = pp.x + 1, y = pp.y, z = pp.z }
        st.player.pos = np
        tb.walker:onPositionChange({ pos = np, oldPos = pp })
        host:advance(400)
    end
    eqList(sent, { 1, 1, 1 }, 'three steps EAST toward the monster')
    eq(st.player.pos.x, start.x + 3, 'the player is now adjacent to it')

    tb.sender:clear()
    tb:tick()
    eq(#tb.sender:byKind('walk'), 0, 'and at path length 1 the chase stops')
    eq(tb.dest, nil, 'no destination was recorded (`#currentDistance > 1` is false)')
end

-- ============================================================================
S('combat: keep-distance stepping produces the right directions')
do
    -- keepDistanceRange 3 -> the dead band is {3,4}; from 1 tile away the bot must retreat.
    -- 16 wide so that retreating WEST is cheaper than the eastern half of the ring
    local st, start = buildMap({
        '................',
        '........@.......',
        '................',
    })
    local tb, host = newTB(st, cfgOf{ entry{ name = '*', chase = false, keepDistance = true,
                                             keepDistanceRange = 3, maxDistance = 10 } })
    local c = addMonster(st, { x = start.x + 1, y = start.y, z = 7 }, 'Rat')
    tb.sender:clear()

    local sent = {}
    for i = 1, 4 do
        tb:tick()
        local w = tb.sender:byKind('walk')
        if #w > #sent then
            sent[#sent + 1] = w[#w].dir
            local pp = st.player.pos
            local d = ({ [0] = { 0, -1 }, [1] = { 1, 0 }, [2] = { 0, 1 }, [3] = { -1, 0 } })[w[#w].dir]
            local np = { x = pp.x + d[1], y = pp.y + d[2], z = pp.z }
            st.player.pos = np
            tb.walker:onPositionChange({ pos = np, oldPos = pp })
        end
        host:advance(400)
    end
    eqList(sent, { 3, 3 }, 'the bot backs away WEST twice, then stops inside the dead band')
    eq(st.player.pos.x, start.x - 2, 'ending 3 tiles from the monster')
    eq(math.max(math.abs(st.player.pos.x - c.pos.x), math.abs(st.player.pos.y - c.pos.y)), 3,
       'i.e. exactly keepDistanceRange away')

    tb.sender:clear()
    tb:tick()
    eq(#tb.sender:byKind('walk'), 0, 'no further movement while the distance is 3 or 4')

    -- the anchor: re-anchored on the first keepDistance evaluation
    ok(tb.anchorPos ~= nil, 'an anchor position was recorded')
end

-- ============================================================================
S('combat: avoidAttacks side-steps, and faceMonster is NEVER reached with it on')
do
    local st, start = buildMap({ '.....', '.....', '..@..', '.....', '.....' })
    local tb = newTB(st, cfgOf{ entry{ name = '*', chase = false, avoidAttacks = true,
                                       faceMonster = true, maxDistance = 10 } })
    -- monster straight east at distance 1 -> candidates are north / south
    local c = addMonster(st, { x = start.x + 1, y = start.y, z = 7 }, 'Rat')
    tb:creatureWalk(c, tb.targeting[1], 1)
    ok(tb.dest ~= nil, 'a side-step destination was recorded')
    eq(tb.dest.x, start.x, 'it keeps the same x')
    eq(tb.dest.y, start.y - 1, 'and steps NORTH out of the straight line')
    eq(#tb.sender:byKind('turn'), 0,
       'VERIFIER: the faceMonster turn() fallback is unreachable while avoidAttacks is on')
end

-- ============================================================================
S('combat: faceMonster turns when the monster is not diagonal')
do
    local st, start = buildMap({ '.....', '.....', '..@..', '.....', '.....' })
    local tb = newTB(st, cfgOf{ entry{ name = '*', chase = false, faceMonster = true,
                                       maxDistance = 10 } })
    st.player.direction = 0                       -- facing north
    local c = addMonster(st, { x = start.x + 1, y = start.y, z = 7 }, 'Rat')
    tb.sender:clear()
    tb:creatureWalk(c, tb.targeting[1], 1)
    local turns = tb.sender:byKind('turn')
    eq(#turns, 1, 'a turn was sent')
    eq(turns[1].dir, 1, 'facing EAST toward the monster')
end

-- ============================================================================
S('luring: closeLure hands control to CaveBot')
do
    local st, start = buildMap({ '.....', '.....', '..@..', '.....', '.....' })
    local tb = newTB(st, cfgOf{ entry{ name = '*', closeLure = true, closeLureAmount = 2,
                                       maxDistance = 10 } })
    local a = addMonster(st, { x = start.x + 1, y = start.y, z = 7 }, 'Rat')
    tb:creatureWalk(a, tb.targeting[1], 1)
    ok(not tb:isCaveBotActionAllowed(), 'one adjacent monster is below closeLureAmount 2')

    addMonster(st, { x = start.x, y = start.y + 1, z = 7 }, 'Rat')
    tb:creatureWalk(a, tb.targeting[1], 2)
    ok(tb:isCaveBotActionAllowed(), 'two adjacent monsters grant CaveBot 150 ms')
    eq(tb.dest, nil, 'and no movement destination was set')
end

-- ============================================================================
S('luring: the dynamic-lure latch is hysteretic and survives ticks')
do
    local st, start = buildMap({ '.......', '.@.....' })
    -- the real true_asura.json numbers: lureMin 2, lureMax 5
    local tb = newTB(st, cfgOf{ entry{ name = '*', dynamicLure = true, lureMin = 2,
                                       lureMax = 5, lureDelay = 536, dynamicLureDelay = true,
                                       delayFrom = 4, maxDistance = 10 } })
    local c = addMonster(st, { x = start.x + 3, y = start.y, z = 7 }, 'Rat')
    local cfg = tb.targeting[1]

    tb:creatureWalk(c, cfg, 1)
    eq(tb.targetBotLure, true, 'targets 1 <= lureMin 2 -> start pulling')
    ok(tb:isCaveBotActionAllowed(), 'and CaveBot is allowed to walk (that IS the pull)')

    CLOCK.t = CLOCK.t + 200
    tb:creatureWalk(c, cfg, 3)
    eq(tb.targetBotLure, true, 'targets 3 is between lureMin and lureMax -> the latch HOLDS')

    tb:creatureWalk(c, cfg, 5)
    eq(tb.targetBotLure, false, 'targets 5 >= lureMax 5 -> stop pulling')
    tb:creatureWalk(c, cfg, 3)
    eq(tb.targetBotLure, false, 'and 3 does not restart it: that is the hysteresis')
    tb:creatureWalk(c, cfg, 2)
    eq(tb.targetBotLure, true, 'only dropping back to lureMin restarts it')

    -- VERIFIER: these four are assigned UNCONDITIONALLY on every walk() call
    eq(tb.targetCount, 2, 'targetCount is refreshed every call')
    eq(tb.delayValue, 536, 'delayValue = config.lureDelay')
    eq(tb.lureMax, 5, 'lureMax is latched under its own guard')
    eq(tb.delayFrom, 4, 'delayFrom is refreshed')
    eq(tb.dynamicLureDelay, true, 'dynamicLureDelay is refreshed')
end

-- ============================================================================
S('luring: classic lure holds a 5-6 tile ring')
do
    local st, start = buildMap({
        '................',
        '.@..............',
        '................',
    })
    local tb = newTB(st, cfgOf{ entry{ name = '*', lure = true, lureCount = 3,
                                       dynamicLure = false, maxDistance = 10 } })
    local c = addMonster(st, { x = start.x + 2, y = start.y, z = 7 }, 'Rat')
    tb:creatureWalk(c, tb.targeting[1], 1)             -- targets 1 < lureCount 3
    ok(tb.dest ~= nil, 'a lure destination was recorded')
    eq(tb.params.marginMin, 5, 'marginMin 5')
    eq(tb.params.marginMax, 6, 'marginMax 6')
    eq(tb.dest.x, c.pos.x, 'centred on the monster')
end

-- ============================================================================
S('luring: the CaveBot per-step lure delay')
do
    local st, start = buildMap({ '.......', '.@.....' })
    local tb, host = newTB(st, cfgOf{ entry{ name = '*', dynamicLure = true, lureMin = 0,
                                             lureMax = 5, dynamicLureDelay = true,
                                             delayFrom = 2, lureDelay = 655,
                                             maxDistance = 10 } })
    local seen = {}
    host.modules.cavebot = { isOn = function() return true end,
                             delay = function(_, v) seen[#seen + 1] = v end }
    local c = addMonster(st, { x = start.x + 2, y = start.y, z = 7 }, 'Rat')
    tb:creatureWalk(c, tb.targeting[1], 3)
    tb.attackingId = c.id
    tb:onPositionChange()
    eqList(seen, { 655 }, 'each player step costs CaveBot config.lureDelay ms')

    tb.targetCount = 1
    tb:onPositionChange()
    eqList(seen, { 655 }, 'below delayFrom nothing is charged')

    tb.targetCount = 3
    tb.storage.TargetBotDelayWhenPlayer = true
    tb:onPositionChange()
    eqList(seen, { 655 }, 'and TargetBotDelayWhenPlayer suppresses it entirely')
    tb.storage.TargetBotDelayWhenPlayer = nil
end

-- ============================================================================
S('interlock: the danger value and what CaveBot sees')
do
    local st, start = buildMap({ '.........', '.@.......', '.........' })
    local tb, host = newTB(st, cfgOf{
        entry{ name = 'Dark Torturer', priority = 4, danger = 5, maxDistance = 8 },
        entry{ name = 'Lost Soul',     priority = 2, danger = 3, maxDistance = 8 },
        entry{ name = 'Rat',           priority = 1, danger = 1, maxDistance = 1 },
    })
    addMonster(st, { x = start.x + 2, y = start.y, z = 7 }, 'Dark Torturer')
    addMonster(st, { x = start.x + 3, y = start.y, z = 7 }, 'Lost Soul')
    addMonster(st, { x = start.x + 5, y = start.y, z = 7 }, 'Rat')   -- beyond ITS maxDistance
    tb:tick()
    near(tb:Danger(), 8, 'danger = 5 + 3; the out-of-range Rat contributes 0')
    eq(tb.targets, 2, 'and only two creatures score above 0')

    -- the CaveBot interlock (cavebot.lua:81)
    ok(tb:isActive(), 'TargetBot is active for 300 ms after acting')
    ok(not tb:isCaveBotActionAllowed(), 'and CaveBot is not explicitly allowed')

    local bot = require('bot.init')
    local b = bot.new({ state = st, sender = tb.sender, events = host.events,
                        log = host.client.log },
                      { clock = now })
    b.storage._configs.targetbot_configs = { enabled = true, selected = 'x' }
    b:registerModule('targetbot', tb)
    eq(b:isActionAllowed('cavebot'), false, 'bot:isActionAllowed("cavebot") is FALSE')
    eq(b:isActionAllowed('healbot'), true,  'healing never yields')
    tb:allowCaveBot(150)
    eq(b:isActionAllowed('cavebot'), true,  'allowCaveBot(150) opens the window')
    CLOCK.t = CLOCK.t + 200
    b.now = CLOCK.t
    eq(b:isActionAllowed('cavebot'), false,
       'after 200 ms the 150 ms allowance has lapsed but isActive (300 ms) has not')
    CLOCK.t = CLOCK.t + 200
    b.now = CLOCK.t
    eq(b:isActionAllowed('cavebot'), true,
       'after 400 ms isActive lapsed too, so CaveBot runs again')
end

-- ============================================================================
S('interlock: PZ gates attacking but not looting')
do
    local st, start = buildMap({ '.......', '.@.....' })
    local tb = newTB(st, cfgOf{ entry{ name = '*' } })
    addMonster(st, { x = start.x + 2, y = start.y, z = 7 }, 'Rat')
    st.player.states = 16384                       -- PlayerStates.Pz
    ok(tb:isInPz(), 'the PZ state bit is decoded')
    tb.sender:clear()
    tb:tick()
    eq(#tb.sender:byKind('attack'), 0, 'no attack is issued inside a PZ')
    eq(tb:getStatus(), 'Waiting', 'and the status falls back to Waiting')
    st.player.states = 0
end

-- ============================================================================
S('walking: the floor-change guard refuses a step onto stairs')
do
    local st, start = buildMap({ '.....', '.@U..' })
    local tb = newTB(st, cfgOf{ entry{ name = '*', chase = true, maxDistance = 10 } })
    local c = addMonster(st, { x = start.x + 3, y = start.y, z = 7 }, 'Rat')
    tb:walkTo(c.pos, 10, { ignoreNonPathable = true, precision = 1 })
    tb.sender:clear()
    tb:walk()
    eq(#tb.sender:byKind('walk'), 0, 'the step onto the lenshelp-1104 tile is refused')

    tb.storage.targetbotAvoidFloorChange = false
    tb:walk()
    eq(#tb.sender:byKind('walk'), 1, 'and is taken once the guard is switched off')
    tb.storage.targetbotAvoidFloorChange = nil
end

-- ============================================================================
-- LOOTING
-- ============================================================================
local function addContainer(st, id, itemId, items, cap)
    local c = { id = id, name = 'bag', capacity = cap or 20, hasPages = false,
                firstIndex = 0, size = #items, items = items,
                item = { kind = 'item', id = itemId } }
    st.containers[id] = c
    return c
end

local function lootHost(opts)
    opts = opts or {}
    local st, start = buildMap({ '.......', '.......', '..@....', '.......', '.......' })
    local storage = { extras = { lootLast = true, looting = 40, lootDelay = 220,
                                 killUnder = 1 }, _configs = {} }
    if opts.storage then for k, v in pairs(opts.storage) do storage[k] = v end end
    local host = newHost(st, { storage = storage })
    local tb = newTB(st, cfgOf(opts.targeting or { entry{ name = '*', dontLoot = false } },
                               opts.looting or { items = { { id = 16131, count = 0 },
                                                           { id = 3031, count = 0 } },
                                                 containers = { { id = 2854, count = 0 } },
                                                 everyItem = false, maxDanger = 10,
                                                 minCapacity = 100 }),
                     { host = host })
    return tb, host, st, start
end

--- The whole realistic flow: the monster is SEEN (which is what records its last position),
--- then dies, the server drops a corpse container on its tile, and creatureDisappear fires.
--- `noCorpse` skips the corpse item, i.e. the "it just walked off screen" case.
local function kill(tb, host, st, pos, name, noCorpse)
    local c = addMonster(st, pos, name)
    tb:spectatorsInRange(st.player.pos, 6)      -- the production scan; a tick calls it too
    removeMonster(st, c)
    if not noCorpse then st:addThing(pos, -2, { kind = 'item', id = 3994 }) end
    tb:onCreatureDisappear(c)
    host:advance(20)
    return c
end

S('looting: corpse discovery queues the body 20 ms later')
do
    local tb, host, st, start = lootHost()
    addContainer(st, 0, 2854, {})                       -- the loot bag must be open
    local corpsePos = { x = start.x + 2, y = start.y, z = 7 }
    local c = addMonster(st, corpsePos, 'Rat')

    -- deviation (11): the state clears creature.pos before creatureDisappear fires, so the
    -- corpse tile can only come from what the scan remembered.  Prove the production code
    -- path is what fills it in.
    eq(tb.lastPos[c.id], nil, 'nothing is remembered before the first scan')
    tb:tick()
    ok(tb.lastPos[c.id] ~= nil, 'a tick remembers where the monster stood')

    removeMonster(st, c)
    eq(c.pos, nil, 'and game/state.lua has already cleared creature.pos by then')
    st:addThing(corpsePos, -2, { kind = 'item', id = 3994 })   -- the corpse container

    tb:onCreatureDisappear(c)
    eq(#tb.loot.list, 0, 'nothing is queued synchronously')
    host:advance(20)
    eq(#tb.loot.list, 1, 'the deferred tile check queues it after 20 ms')
    eq(tb.loot.list[1].creature, 'Rat', 'with the creature name')
    eq(tb.loot.list[1].container, 3994, 'and the corpse item id')

    -- dontLoot
    tb.targeting[1].dontLoot = true
    tb.configsCache = {}
    kill(tb, host, st, { x = start.x + 1, y = start.y, z = 7 }, 'Rat')
    eq(#tb.loot.list, 1, 'a dontLoot creature is never queued')
    tb.targeting[1].dontLoot = false
    tb.configsCache = {}

    -- out of the 6-tile discovery radius
    local far = { x = start.x + 9, y = start.y, z = 7 }
    st:addThing(far, 0, { kind = 'item', id = 100 })
    kill(tb, host, st, far, 'Rat')
    eq(#tb.loot.list, 1, 'a corpse beyond Chebyshev 6 is never queued')

    -- no container on the tile at all (onCreatureDisappear also fires when a creature
    -- merely leaves the aware range -- the 20 ms tile check is what filters those out)
    local p4 = { x = start.x + 1, y = start.y + 1, z = 7 }
    kill(tb, host, st, p4, 'Rat', true)
    eq(#tb.loot.list, 1, 'a creature that merely left the screen leaves no corpse entry')

    -- the queue cap
    tb.loot.list = {}
    for i = 1, 25 do
        tb.loot.list[i] = { pos = { x = start.x, y = start.y, z = 7 }, tries = 0, seq = i }
    end
    kill(tb, host, st, { x = start.x + 1, y = start.y, z = 7 }, 'Rat')
    eq(#tb.loot.list, 25, 'with 20+ entries already queued nothing more is accepted')
end

-- ============================================================================
S('looting: the queue is farthest-first, so lootLast takes the NEAREST corpse')
do
    local tb, host, st, start = lootHost()
    addContainer(st, 0, 2854, {})
    local function corpseAt(dx, name)
        kill(tb, host, st, { x = start.x + dx, y = start.y, z = 7 }, name)
    end
    corpseAt(1, 'Near')
    corpseAt(4, 'Far')
    corpseAt(2, 'Mid')
    eq(#tb.loot.list, 3, 'three corpses queued')
    eqList(tb.loot.list, { 'Far', 'Mid', 'Near' }, 'sorted DESCENDING by distance',
           function(e) return e.creature end)
    eq(tb.loot:current().creature, 'Near',
       'and lootLast=true therefore picks the NEAREST -- the label is misleading')

    tb.storage.extras.lootLast = false
    eq(tb.loot:current().creature, 'Far', 'with lootLast off it takes the farthest')
    tb.storage.extras.lootLast = true
end

-- ============================================================================
S('looting: a complete sequence -- open, take the listed items, skip the rest, close')
do
    local tb, host, st, start = lootHost()
    local bag = addContainer(st, 0, 2854, {})            -- the loot bag, empty, capacity 20
    local corpsePos = { x = start.x + 1, y = start.y, z = 7 }
    local corpse = addMonster(st, corpsePos, 'Rat')

    tb:spectatorsInRange(st.player.pos, 6)               -- the scan that records lastPos
    removeMonster(st, corpse)
    st:addThing(corpsePos, -2, { kind = 'item', id = 3994 })
    tb:onCreatureDisappear(corpse)
    host:advance(20)
    eq(#tb.loot.list, 1, 'the corpse is queued')

    -- 1) adjacent already (distance 1 <= 2), so the first process() OPENS it
    tb.sender:clear()
    local busy = tb.loot:process(0, 0)
    eq(busy, true, 'the looter is in charge')
    eq(tb.loot:getStatus(), 'Looting', 'status Looting')
    local opens = tb.sender:byKind('open')
    eq(#opens, 1, 'exactly one openContainer packet')
    eq(opens[1].id, 3994, 'for the corpse item id')
    eq(opens[1].cid, 1, 'into the lowest free container id (0 is the loot bag)')
    eq(tb.loot.waitingForContainerItemId, 3994, 'and the looter waits for that item id')

    -- 2) while waitTill has not expired NOTHING happens
    tb.sender:clear()
    eq(tb.loot:process(0, 0), true, 'still busy during the lootDelay')
    eq(#tb.sender.packets, 0, 'and no packet is sent')

    -- 3) the server answers: the corpse window opens with 4 items
    local corpseItems = {
        { kind = 'item', id = 3982 },                       -- junk, NOT on the list
        { kind = 'item', id = 16131 },                      -- wanted
        { kind = 'item', id = 3031, count = 47 },           -- wanted, stackable
        { kind = 'item', id = 3982 },                       -- junk
    }
    local corpseCt = addContainer(st, 1, 3994, corpseItems)
    tb.loot:onContainerOpen(corpseCt)
    eq(tb.loot.isLootContainer[1], true, 'the corpse window is flagged as a loot container')
    eq(tb.loot.waitingForContainerItemId, nil, 'and the wait is cleared')

    host:advance(300)                                       -- past the lootDelay

    -- 4) one item per call, in slot order, skipping the unlisted ones
    tb.sender:clear()
    tb.loot:process(0, 0)
    local mv = tb.sender:byKind('move')
    eq(#mv, 1, 'exactly ONE move per call')
    eq(mv[1].id, 16131, 'slot 1 (junk 3982) was SKIPPED; slot 2 (16131) is taken')
    eq(mv[1].from.x, 0xFFFF, 'from a container position')
    eq(mv[1].from.y, 0x40 + 1, 'in container 1 (the corpse)')
    eq(mv[1].from.z, 1, 'slot index 1 (0-based: the 2nd slot)')
    eq(mv[1].to.y, 0x40 + 0, 'into container 0 (the loot bag)')
    eq(mv[1].to.z, 0, 'appended at index #items = 0')
    eq(mv[1].count, 1, 'count 1 -- the append branch always moves one')

    -- the server applies it
    table.remove(corpseItems, 2)
    bag.items[1] = { kind = 'item', id = 16131 }
    host:advance(300)

    -- 5) the gold: no partial stack in the bag yet, so ONE unit moves first (verbatim vBot)
    tb.sender:clear()
    tb.loot:process(0, 0)
    mv = tb.sender:byKind('move')
    eq(#mv, 1, 'the next call moves the gold')
    eq(mv[1].id, 3031, 'item 3031')
    eq(mv[1].count, 1, 'ONE unit -- the append branch, exactly like vBot')
    eq(mv[1].to.z, 1, 'appended after the item already in the bag')

    bag.items[2] = { kind = 'item', id = 3031, count = 1 }
    corpseItems[2].count = 46
    host:advance(300)

    -- 6) now the merge branch finds the partial stack and moves the WHOLE remainder
    tb.sender:clear()
    tb.loot:process(0, 0)
    mv = tb.sender:byKind('move')
    eq(#mv, 1, 'a third move')
    eq(mv[1].id, 3031, 'the same gold stack')
    eq(mv[1].count, 46, 'the WHOLE remaining stack merges onto the partial one')
    eq(mv[1].to.z, 1, 'onto slot 1 (0-based) where the partial stack sits')

    table.remove(corpseItems, 2)
    bag.items[2].count = 47
    host:advance(300)

    -- 7) only junk left -> close the corpse and drop the queue entry
    tb.sender:clear()
    tb.loot:process(0, 0)
    eq(#tb.sender:byKind('move'), 0, 'nothing left to take')
    local cl = tb.sender:byKind('close')
    eq(#cl, 1, 'the corpse window is closed')
    eq(cl[1].cid, 1, 'container 1')
    eq(tb.loot.isLootContainer[1], nil, 'the flag is cleared')
    eq(#tb.loot.list, 0, 'and the queue entry is removed')

    -- 8) with the queue empty the looter reports "" and yields the tick
    st.containers[1] = nil
    eq(tb.loot:process(0, 0), false, 'the looter is no longer in charge')
    eq(tb.loot:getStatus(), '', 'and the status is empty')
end

-- ============================================================================
S('looting: everyItem inverts the list into an IGNORE list')
do
    local tb, host, st, start = lootHost{
        looting = { items = { { id = 3982, count = 0 } }, containers = { { id = 2854 } },
                    everyItem = true, maxDanger = 10, minCapacity = 100 } }
    local bag = addContainer(st, 0, 2854, {})
    local corpseItems = { { kind = 'item', id = 3982 },            -- IGNORED now
                          { kind = 'item', id = 9636 } }           -- taken (anything else)
    local corpseCt = addContainer(st, 1, 3994, corpseItems)
    tb.loot.list = { { pos = { x = start.x, y = start.y, z = 7 }, tries = 0, seq = 1 } }
    tb.loot.isLootContainer[1] = true

    tb.sender:clear()
    tb.loot:process(0, 0)
    local mv = tb.sender:byKind('move')
    eq(#mv, 1, 'one item moved')
    eq(mv[1].id, 9636, 'the UNLISTED item is the one taken')
end

-- ============================================================================
S('looting: a nested bag inside the corpse is opened in place, at most twice')
do
    local tb, host, st, start = lootHost()
    addContainer(st, 0, 2854, {})
    local corpseItems = { { kind = 'item', id = 1987 } }        -- a bag, not on the loot list
    local corpseCt = addContainer(st, 1, 3994, corpseItems)
    tb.loot.list = { { pos = { x = start.x, y = start.y, z = 7 }, tries = 0, seq = 1 } }
    tb.loot.isLootContainer[1] = true

    tb.sender:clear()
    tb.loot:process(0, 0)
    local op = tb.sender:byKind('open')
    eq(#op, 1, 'the nested bag is opened')
    eq(op[1].id, 1987, 'by item id')
    eq(op[1].cid, 1, 'IN PLACE of the corpse window (previousContainer = the corpse)')
    eq(tb.loot.waitingForContainerItemId, 1987, 'and the looter waits for it')

    -- it never opens: the second attempt is the last one (lootTries < 2)
    host:advance(400)
    tb.sender:clear()
    tb.loot:process(0, 0)
    eq(#tb.sender:byKind('open'), 0, 'the second pass has already spent both tries')
    eq(#tb.sender:byKind('close'), 1, 'so the corpse is closed instead')
    eq(#tb.loot.list, 0, 'and the entry dropped')
end

-- ============================================================================
S('looting: an item that will not move is abandoned after 5 tries')
do
    local tb, host, st, start = lootHost()
    local bag = addContainer(st, 0, 2854, {})
    local corpseItems = { { kind = 'item', id = 16131 } }       -- never actually removed
    local corpseCt = addContainer(st, 1, 3994, corpseItems)
    tb.loot.list = { { pos = { x = start.x, y = start.y, z = 7 }, tries = 0, seq = 1 } }
    tb.loot.isLootContainer[1] = true

    local moves = 0
    for i = 1, 8 do
        tb.sender:clear()
        tb.loot:process(0, 0)
        moves = moves + #tb.sender:byKind('move')
        host:advance(400)
    end
    eq(moves, 4, 'the item is retried until lootTries reaches 5, i.e. 4 moves')
    eq(tb.loot.stats.abandoned > 0, true, 'then it is abandoned')
    eq(#tb.loot.list, 0, 'and the corpse is finished')
end

-- ============================================================================
S('looting: the walk-to-corpse TIMEOUT (tries > 30 drops the entry)')
do
    local tb, host, st, start = lootHost()
    addContainer(st, 0, 2854, {})
    -- a corpse 5 tiles away that we never actually walk to (the walker is never pumped)
    local corpsePos = { x = start.x + 4, y = start.y, z = 7 }
    st:addThing(corpsePos, -2, { kind = 'item', id = 3994 })
    tb.loot.list = { { pos = corpsePos, tries = 0, seq = 1, creature = 'Rat' } }

    local walks = 0
    for i = 1, 31 do
        local busy = tb.loot:process(0, 0)
        if busy and tb.dest then walks = walks + 1 end
        tb:walkTo(nil)
    end
    eq(tb.loot.list[1].tries, 31, 'tries incremented once per tick while walking')
    eq(walks, 31, 'and a destination was recorded every time')
    eq(#tb.loot.list, 1, 'the entry survives while tries <= 30')

    tb.loot:process(0, 0)
    eq(#tb.loot.list, 0, 'the 32nd pass sees tries > 30 and DROPS the corpse')
    eq(tb.loot.stats.dropped, 1, 'counted as a drop')
end

-- ============================================================================
S('looting: the other three refusal gates')
do
    -- (a) High danger
    local tb, host, st, start = lootHost()
    addContainer(st, 0, 2854, {})
    tb.loot.list = { { pos = { x = start.x, y = start.y, z = 7 }, tries = 0, seq = 1 } }
    eq(tb.loot:process(0, 11), false, 'dangerLevel 11 > maxDanger 10 -> not looting')
    eq(tb.loot:getStatus(), 'High danger', 'status High danger')
    eq(#tb.loot.list, 1, 'and the queue survives')

    -- (b) No cap -- the queue is WIPED, not paused
    st.player.freeCapacity = 50
    eq(tb.loot:process(0, 0), false, 'free capacity below minCapacity -> not looting')
    eq(tb.loot:getStatus(), 'No cap', 'status No cap')
    eq(#tb.loot.list, 0, 'and the WHOLE QUEUE is wiped')
    st.player.freeCapacity = 1000

    -- (c) No space -- every configured loot bag is full
    local full = {}
    for i = 1, 20 do full[i] = { kind = 'item', id = 3982 } end
    st.containers[0] = nil
    addContainer(st, 0, 2854, full, 20)
    tb.loot.list = { { pos = { x = start.x, y = start.y, z = 7 }, tries = 0, seq = 1 } }
    eq(tb.loot:process(0, 0), false, 'a full loot bag with no spare -> not looting')
    eq(tb.loot:getStatus(), 'No space', 'status No space')

    -- (d) nothing configured at all
    tb.loot:update({ items = {}, containers = {} })
    eq(tb.loot:process(0, 0), false, 'no items and no everyItem -> not looting')
    eq(tb.loot:getStatus(), '', 'status ""')
end

-- ============================================================================
S('looting: a full loot bag is replaced by the spare it carries')
do
    local tb, host, st, start = lootHost()
    local full = {}
    for i = 1, 19 do full[i] = { kind = 'item', id = 3982 } end
    full[20] = { kind = 'item', id = 2854 }            -- a spare loot bag inside it
    addContainer(st, 0, 2854, full, 20)
    tb.loot.list = { { pos = { x = start.x, y = start.y, z = 7 }, tries = 0, seq = 1 } }

    tb.sender:clear()
    local busy = tb.loot:process(0, 0)
    eq(busy, false, 'this tick yields (getLootContainers returned nothing)')
    local op = tb.sender:byKind('open')
    eq(#op, 1, 'but the spare bag was opened')
    eq(op[1].id, 2854, 'by item id')
    eq(op[1].cid, 0, 'replacing the full bag in its OWN window')
    eq(tb.loot.waitTill > now(), true, 'and a 500 ms wait was armed')
end

-- ============================================================================
S('looting: an unopened equipped loot bag is opened')
do
    local tb, host, st, start = lootHost()
    st.player.inventory[3] = { kind = 'item', id = 2854 }     -- backpack slot
    tb.loot.list = { { pos = { x = start.x, y = start.y, z = 7 }, tries = 0, seq = 1 } }
    tb.sender:clear()
    tb.loot:process(0, 0)
    local op = tb.sender:byKind('open')
    eq(#op, 1, 'the equipped container is opened')
    eq(op[1].id, 2854, 'by item id')
    eq(op[1].pos.y, 3, 'from inventory slot 3')
    eq(op[1].cid, 0, 'into container id 0')
end

-- ============================================================================
S('looting: "you are not the owner" drops the current entry')
do
    local tb, host, st, start = lootHost()
    tb.loot.list = { { pos = start, tries = 0, seq = 1, creature = 'A' },
                     { pos = start, tries = 0, seq = 2, creature = 'B' } }
    tb.loot:onTextMessage({ text = 'Sorry, you are not the owner.' })
    eq(#tb.loot.list, 1, 'one entry dropped')
    eq(tb.loot.list[1].creature, 'A', 'the LAST one (lootLast), i.e. B')
    tb.loot:onTextMessage({ text = 'a completely unrelated message' })
    eq(#tb.loot.list, 1, 'an unrelated message changes nothing')
end

-- ============================================================================
S('looting: food is eaten at most once per 5 s, and only when nothing is loot')
do
    local tb, host, st, start = lootHost{ storage = { foodItems = { { id = 3582, count = 1 } } } }
    addContainer(st, 0, 2854, {})
    local corpseItems = { { kind = 'item', id = 3582 } }        -- ham: not loot, but food
    addContainer(st, 1, 3994, corpseItems)
    tb.loot.list = { { pos = { x = start.x, y = start.y, z = 7 }, tries = 0, seq = 1 } }
    tb.loot.isLootContainer[1] = true

    tb.sender:clear()
    tb.loot:process(0, 0)
    local u = tb.sender:byKind('use')
    eq(#u, 1, 'the ham is eaten')
    eq(u[1].id, 3582, 'item 3582')
    eq(u[1].pos.y, 0x40 + 1, 'from the corpse container')

    tb.sender:clear()
    tb.loot:process(0, 0)
    eq(#tb.sender:byKind('use'), 0, 'not again inside the 5 s interval')
    eq(#tb.sender:byKind('close'), 1,
       'and with nothing else to take the corpse is closed instead')

    -- re-arm the same corpse and step past the interval
    host:advance(5100)
    tb.loot.list = { { pos = { x = start.x, y = start.y, z = 7 }, tries = 0, seq = 2 } }
    tb.loot.isLootContainer[1] = true
    tb.sender:clear()
    tb.loot:process(0, 0)
    eq(#tb.sender:byKind('use'), 1, 'after 5 s the next bite is allowed')
end

-- ============================================================================
S('interleaving: attacking wins the tick and suppresses chase movement while looting')
do
    local tb, host, st, start = lootHost()
    local bag = addContainer(st, 0, 2854, {})
    local corpseItems = { { kind = 'item', id = 16131 } }
    addContainer(st, 1, 3994, corpseItems)
    tb.loot.list = { { pos = { x = start.x, y = start.y, z = 7 }, tries = 0, seq = 1 } }
    tb.loot.isLootContainer[1] = true
    local mob = addMonster(st, { x = start.x + 3, y = start.y, z = 7 }, 'Rat')

    tb.sender:clear()
    tb:tick()
    eq(#tb.sender:byKind('attack'), 1, 'the monster is still attacked')
    eq(tb:getStatus(), 'Attack & Looting', 'and the status shows both')
    eq(#tb.sender:byKind('move'), 1, 'the looter moved an item')
    eq(#tb.sender:byKind('walk'), 0,
       'but NO chase step: Creature.walk is skipped entirely while looting')
    ok(tb:isActive(), 'lastAction was refreshed, so CaveBot stays frozen')

    -- with the looter idle the chase resumes
    tb.loot.list = {}
    tb.loot.isLootContainer[1] = nil
    st.containers[1] = nil
    host:advance(500)
    tb.sender:clear()
    tb:tick()
    eq(#tb.sender:byKind('walk'), 1, 'once looting stops, the chase step is sent again')
    eq(tb:getStatus(), 'Attacking', 'status Attacking')
end

-- ============================================================================
S('interleaving: with no target the looter still drives the stepper')
do
    local tb, host, st, start = lootHost()
    addContainer(st, 0, 2854, {})
    local corpsePos = { x = start.x + 4, y = start.y, z = 7 }
    st:addThing(corpsePos, -2, { kind = 'item', id = 3994 })
    tb.loot.list = { { pos = corpsePos, tries = 0, seq = 1, creature = 'Rat' } }

    tb.sender:clear()
    tb:tick()
    eq(tb.lastParams, nil, 'there is no target')
    eq(tb:getStatus(), 'Looting', 'the status is the looter status')
    local w = tb.sender:byKind('walk')
    eq(#w, 1, 'and one step toward the corpse was sent')
    eq(w[1].dir, 1, 'EAST')
    ok(tb:isActive(), 'lastAction is refreshed on the looting-only path too')
end

-- ============================================================================
S('status: the BOT.md status object')
do
    local tb, host, st, start = lootHost()
    local mob = addMonster(st, { x = start.x + 2, y = start.y, z = 7 }, 'Rat')
    tb:tick()
    local s = tb:status()
    eq(s.on, true, 'on')
    eq(type(s.danger), 'number', 'danger is a number')
    eq(s.target.id, mob.id, 'target.id')
    eq(s.target.name, 'Rat', 'target.name')
    eq(s.target.hpPercent, 100, 'target.hpPercent')
    eq(s.target.distance, 2, 'target.distance')
    eq(type(s.looting), 'table', 'looting sub-table')
    eq(s.looting.status, tb:lootStatus(), 'looting.status agrees with lootStatus()')
    eq(s.entries, 1, 'entry count')
end

-- ============================================================================
S('reload: update() wipes the corpse queue (VERIFIER)')
do
    local tb, host, st, start = lootHost()
    tb.loot.list = { { pos = start, tries = 0, seq = 1 } }
    tb:reload(cfgOf({ entry{ name = '*' } },
                    { items = { { id = 1 } }, containers = { { id = 2854 } } }))
    eq(#tb.loot.list, 0, 'a config reload forgets every queued corpse')
    eq(tb.lureEnabled, true, 'and luring is re-enabled')
    eq(tb.delayUntil, 0, 'and the macro delay cleared')

    -- reload(nil) with no config available turns the module off (target.lua:132-135)
    local tb2 = newTB(buildMap({ '@..' }), cfgOf{ entry{ name = '*' } })
    eq(tb2:isOn(), true, 'the module starts on')
    tb2:reload(nil)
    eq(tb2:isOn(), false, 'reload with no data switches TargetBot off')
    eq(#tb2.targeting, 0, 'and the creature list is emptied')
end

-- ============================================================================
S('save: unknown fields in the user config survive a round trip')
do
    local profile = cfgmod.new{ profileDir = VBOT_PROFILE, vprofile = 1 }
    local data = profile:loadTargetbot('true_asura')
    data.targeting[1].someFutureField = 'keep me'
    local st = buildMap({ '@..' })
    local tb = newTB(st, data)
    local out = tb:save()
    eq(out.targeting[1].someFutureField, 'keep me', 'an unknown entry field is preserved')
    eq(out.targeting[1].name, '*', 'and the known ones too')
    eq(out.looting.containers[1].id, 23721, 'the loot bag id survives')
    ok(out.targeting[1].maxDistance == 10 and out.targeting[1]._raw == nil,
       'the saved table is the ORIGINAL, not the defaults-filled copy')
end

-- ============================================================================
S('config: the real true_asura profile drives a live tick end to end')
do
    local profile = cfgmod.new{ profileDir = VBOT_PROFILE, vprofile = 1 }
    local data    = profile:loadTargetbot('true_asura')
    local storage = profile:loadStorage()
    storage._configs = storage._configs or {}
    local st, start = buildMap({ '.........', '.@.......', '.........' })
    local host = newHost(st, { storage = storage })
    local tb = newTB(st, data, { host = host })
    local mob = addMonster(st, { x = start.x + 2, y = start.y, z = 7 }, 'Asura')

    tb.sender:clear()
    tb:tick()
    eq(#tb.sender:byKind('attack'), 1, 'the "*" entry matches an Asura and it is attacked')
    near(tb:Danger(), 1, 'danger 1 (the entry value)')
    eq(tb.targets, 1, 'one target')
    -- dynamicLure with lureMin 2 >= targets 1 -> the latch turns ON and CaveBot is allowed
    eq(tb.targetBotLure, true, 'lureMin 2 >= 1 target -> dynamic luring starts')
    ok(tb:isCaveBotActionAllowed(), 'so CaveBot is granted its 150 ms pull window')
    eq(tb:getStatus(), 'Luring using CaveBot', 'and the status says so')
    eq(tb.loot:getStatus(), '',
       'looting is idle -- the entry has dontLoot=true so nothing is ever queued')
end

-- ============================================================================
S('looting: the item predicates against the REAL items1530.bin (and the v1 fallback)')
do
    local realItems = require('proto.items')
    local loaded = pcall(realItems.load, ROOT .. '/assets/items1530.bin')
    if loaded and realItems.loaded then
        local st = buildMap({ '@..' })
        local host = newHost(st)
        host.client.items = realItems
        local L = lootmod.new{ client = host.client, world = worldmod.new(host.client),
                               path = pathmod.new(host.client, worldmod.new(host.client)),
                               storage = host.storage, now = now }
        eq(L.isContainerItem(3994), true,  'the real table: 3994 "dead rat" IS a container')
        eq(L.isContainerItem(2854), true,  '2854 "backpack" IS a container')
        eq(L.isContainerItem(3031), false, '3031 "gold coin" is NOT')
        eq(L.isStackableItem(3031), true,  '3031 IS stackable')
        eq(L.isStackableItem(2874), false,
           '2874 "vial" is a FLUID CONTAINER: CUMULATIVE on the wire but NOT isStackable')
        eq(L.isStackableItem(2854), false, '2854 is not stackable')
    else
        ok(true, '(assets/items1530.bin is absent -- the real-table check is skipped)')
    end

    -- the v1 fallback: an items module exposing only flags() + the two bit constants
    local v1 = { CONTAINER = 0x08, CUMULATIVE = 0x01,
                 flags = function(id)
                     if id == 3994 then return 0x08 end
                     if id == 3031 then return 0x01 end
                     return 0
                 end }
    local st2 = buildMap({ '@..' })
    local host2 = newHost(st2)
    host2.client.items = v1
    local w2 = worldmod.new(host2.client)
    local L2 = lootmod.new{ client = host2.client, world = w2,
                            path = pathmod.new(host2.client, w2),
                            storage = host2.storage, now = now }
    eq(L2.isContainerItem(3994), true,  'the v1 fallback derives isContainer from flags()')
    eq(L2.isContainerItem(3031), false, 'and says no for a coin')
    eq(L2.isStackableItem(3031), true,  'and isStackable from CUMULATIVE')
end

-- ============================================================================
io.write(('\nTOTAL: %d passed, %d failed  -> %s\n'):format(pass, fail,
         fail == 0 and 'PASS' or 'FAIL'))
if fail > 0 then
    io.write('\nFAILURES:\n')
    for _, m in ipairs(msgs) do io.write(m, '\n') end
end

if _G.BOT_M3_NO_EXIT then
    return { pass = pass, fail = fail, failures = msgs }
end
os.exit(fail == 0 and 0 or 1)
