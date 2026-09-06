--[==[========================================================================
test/bot_m2_cavebot.lua -- offline tests for work item M2 (bot/cavebot.lua, bot/supplies.lua).

    luajit test/bot_m2_cavebot.lua           (from D:/Claude/otclient_web/luaclient)

No network, no live account: every world is synthesised in Lua, and every route / supply
threshold comes from the USER'S REAL FILES under
D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8, read UNCHANGED.

Set `_G.BOT_M2_NO_EXIT = true` before dofile()ing this file to embed it in test/botsuite.lua:
it then returns { pass=, fail=, failures={} } instead of calling os.exit.

STUBS LIVE HERE, NEVER IN THE SHIPPING MODULES.  The fake item table mirrors work item F1's
proto/items.lua accessor names so bot/world.lua runs in 'full' mode.
==========================================================================]==]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. package.path
end

-- The user's REAL vBot profile.  Resolved relative to this repo first so the same test runs
-- unchanged on Windows and under WSL, with the absolute paths as fallbacks.
local PROFILE
do
    local candidates = {
        ROOT .. '/../../otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
        'D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
        '/mnt/d/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
    }
    for _, c in ipairs(candidates) do
        local f = io.open(c .. '/vBot_configs/profile_1/Supplies.json', 'r')
        if f then f:close(); PROFILE = c; break end
    end
    if not PROFILE then
        io.write('FATAL: the vBot_4.8 profile was not found in any of:\n')
        for _, c in ipairs(candidates) do io.write('  ', c, '\n') end
        os.exit(1)
    end
end

local state     = require('game.state')
local events    = require('lib.events')
local worldmod  = require('bot.world')
local pathmod   = require('bot.path')
local walkermod = require('bot.walker')
local botmod    = require('bot.init')
local configmod = require('bot.config')
local cavebot   = require('bot.cavebot')
local suppliesm = require('bot.supplies')

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

-- ==================================================== fake item table (F1's shape)
local ITEMS = {
    [100]  = { ground = true, speed = 100 },              -- plain floor
    [200]  = { unpass = true, unsight = true, unmove = true, bottom = true }, -- wall
    [386]  = { ground = true, speed = 120, color = 210, lens = 1102 },  -- rope spot
    [1948] = { top = true, color = 210, lens = 1100, usable = true },   -- ladder
    [1949] = { top = true, usable = true },               -- teleport (antiLostTeleportIds)
    [2130] = { unpass = true },                           -- magic wall
    [3031] = { stackable = true, common = true },         -- gold coin
    [3497] = { bottom = true, unmove = true },            -- locker (north access)
    [9596] = { usable = true, multiuse = true },          -- squeezing gear (rope tool)
    [23374]= { stackable = true },                        -- supply item (real Supplies.json)
    [3097] = { stackable = true },                        -- supply item (real Supplies.json)
    [1666] = { usable = true, forceuse = true },          -- a door / lever we `use`
}
local function I(id) return ITEMS[id] or {} end
local fakeItems = {
    isGround          = function(id) return I(id).ground   == true end,
    isGroundBorder    = function(id) return I(id).clip     == true end,
    isOnBottom        = function(id) return I(id).bottom   == true end,
    isOnTop           = function(id) return I(id).top      == true end,
    isNotWalkable     = function(id) return I(id).unpass   == true end,
    isNotPathable     = function(id) return I(id).avoid    == true end,
    isBlockProjectile = function(id) return I(id).unsight  == true end,
    isForceUse        = function(id) return I(id).forceuse == true end,
    isSplash          = function(id) return I(id).splash   == true end,
    groundSpeed       = function(id) return I(id).speed or 0 end,
    minimapColor      = function(id) return I(id).color or 0 end,
    elevation         = function(id) return I(id).elev  or 0 end,
    lensHelp          = function(id) return I(id).lens  or 0 end,
    -- beyond the 13 pathfinding accessors (read defensively by bot/cavebot.lua)
    isUsable          = function(id) return I(id).usable    == true end,
    isNotMoveable     = function(id) return I(id).unmove    == true end,
    isStackable       = function(id) return I(id).stackable == true end,
}

-- ==================================================== synthetic world + fake bot
local nextCreatureId = 5000

--- rows: ASCII, one char per tile.  '.' floor, '#' floor+wall, ' ' no tile,
--- '@' start, 'X' goal, 'm' floor + blocking monster, 'N' floor + an npc.
--- opts.baseX / baseY / z place the map in the real coordinate space.
local function newWorld(rows, opts)
    opts = opts or {}
    local st = state.new()
    local baseX, baseY, z = opts.baseX or 1000, opts.baseY or 1000, opts.z or 7
    local a = st.world.awareRange
    a.left, a.top, a.right, a.bottom = 90, 90, 90, 90

    local start, goal, npcs = nil, nil, {}
    for y = 1, #rows do
        local row = rows[y]
        for x = 1, #row do
            local ch = row:sub(x, x)
            local pos = { x = baseX + x - 1, y = baseY + y - 1, z = z }
            local ground, extra, creature = nil, nil, nil
            if ch == '.' or ch == '@' or ch == 'X' then ground = 100
            elseif ch == '#' then ground, extra = 100, 200
            elseif ch == 'm' then ground, creature = 100, 'monster'
            elseif ch == 'N' then ground, creature = 100, 'npc'
            elseif ch == ' ' then ground = nil
            else error('bad map char ' .. ch) end
            if ground then
                st:addThing(pos, 0, { kind = 'item', id = ground })
                if extra then st:addThing(pos, -2, { kind = 'item', id = extra }) end
                if creature then
                    nextCreatureId = nextCreatureId + 1
                    local id = nextCreatureId
                    local c = { id = id, pos = pos, healthPercent = 100, passable = false,
                                outfit = { lookType = 128, lookTypeEx = 0 } }
                    if creature == 'monster' then
                        c.name, c.type, c.isMonster = 'Rat' .. id, 1, true
                    else
                        c.name, c.type, c.isNpc = opts.npcName or 'Topsy', 2, true
                        npcs[#npcs + 1] = c
                    end
                    st:addCreature(c)
                    st:addThing(pos, -2, { kind = 'creature', creatureId = id, id = 0x63 })
                end
            end
            if ch == '@' then start = pos end
            if ch == 'X' then goal = pos end
        end
    end

    st.player.id       = 1
    st.player.name     = 'Tester'
    st.player.pos      = start or { x = baseX, y = baseY, z = z }
    st.player.speed    = 500
    st.player.capacity = 1000
    st.player.stamina  = 2400
    st.player.skills   = {}
    st.player.inventory= {}
    st.central         = { x = st.player.pos.x, y = st.player.pos.y, z = st.player.pos.z }
    return { st = st, start = start, goal = goal, npcs = npcs,
             base = { x = baseX, y = baseY, z = z },
             at = function(dx, dy) return { x = baseX + dx, y = baseY + dy, z = z } end }
end

local function newHarness(F, opts)
    opts = opts or {}
    local clock = { t = 100000 }
    local sent = {}
    local sender = {
        refuse = false,
        walk = function(self, dir) sent[#sent+1] = {op='walk', dir=dir, t=clock.t}
               if self.refuse then return nil end return 'b' end,
        turn = function(_, dir) sent[#sent+1] = {op='turn', dir=dir}; return 'b' end,
        stop = function() sent[#sent+1] = {op='stop'}; return 'b' end,
        autoWalk = function(_, dirs) sent[#sent+1] = {op='autoWalk', n=#dirs}; return 'b', #dirs end,
        talk = function(_, mode, ch, to, text)
            sent[#sent+1] = {op='talk', mode=mode, text=text}; return 'b' end,
        use = function(_, pos, id, stack, index)
            sent[#sent+1] = {op='use', pos=pos, id=id, stack=stack, index=index}; return 'b' end,
        useWith = function(_, fromPos, id, fromStack, toPos, toId, toStack)
            sent[#sent+1] = {op='useWith', fromPos=fromPos, id=id, toPos=toPos,
                             toId=toId, toStack=toStack}; return 'b' end,
        move = function(_, fromPos, id, stack, toPos, count)
            sent[#sent+1] = {op='move', fromPos=fromPos, id=id, stack=stack,
                             toPos=toPos, count=count}; return 'b' end,
        attack = function(_, id) sent[#sent+1] = {op='attack', id=id}; return 'b' end,
        follow = function(_, id) sent[#sent+1] = {op='follow', id=id}; return 'b' end,
        setFightMode = function(_, f, c) sent[#sent+1] = {op='fightMode', chase=c}; return 'b' end,
        buyItem = function(_, id, sub, amount) sent[#sent+1] = {op='buy', id=id, amount=amount}
                  return 'b' end,
        sellItem = function(_, id, sub, amount) sent[#sent+1] = {op='sell', id=id, amount=amount}
                   return 'b' end,
        openContainer = function(_, pos, id, stack, cid)
            sent[#sent+1] = {op='open', pos=pos, id=id}; return 'b' end,
        closeContainer = function(_, id) sent[#sent+1] = {op='close', id=id}; return 'b' end,
    }
    local bus = events.new()
    local logged = {}
    local function cap(f, ...)
        local line = tostring(f)
        if select('#', ...) > 0 then
            local okf, r = pcall(string.format, line, ...)
            if okf then line = r end
        end
        logged[#logged+1] = line
    end
    local log = { info = cap, warn = cap, error = cap, debug = function() end }
    local client = { state = F.st, items = fakeItems, events = bus, sender = sender, log = log }

    local b = botmod.new(client, { profileDir = opts.profileDir or PROFILE, vprofile = 1,
                                   clock = function() return clock.t end })
    b.sender = sender
    b.events = bus
    b.state  = F.st

    local cb = cavebot.new(b, opts.route, { now = function() return clock.t end })
    b:registerModule('cavebot', cb)
    b:registerModule('supplies', cb.supplies)

    local function moveTo(pos)
        local old = F.st.player.pos
        F.st.player.pos = pos
        F.st.central = pos
        bus:emit('positionChange', { pos = pos, oldPos = old })
    end
    local function stepDir(dir)
        local d = worldmod.DELTA[dir]
        local pp = F.st.player.pos
        moveTo({ x = pp.x + d[1], y = pp.y + d[2], z = pp.z })
    end

    return { bot = b, cb = cb, clock = clock, sent = sent, sender = sender, bus = bus,
             log = logged, moveTo = moveTo, stepDir = stepDir,
             ops = function(kind)
                 local o = {}
                 for i = 1, #sent do if sent[i].op == kind then o[#o+1] = sent[i] end end
                 return o
             end }
end

--- Drive the bot: tick, let the "server" confirm every step the walker sent, advance time.
local function run(H, ticks, hook)
    local trace = {}
    for i = 1, ticks do
        local before = H.cb.index
        H.cb:tick()
        trace[#trace+1] = { index = before, after = H.cb.index, retries = H.cb.retries,
                            pos = { x = H.bot.state.player.pos.x, y = H.bot.state.player.pos.y } }
        if hook and hook(H, i) == 'stop' then break end
        local guard = 0
        while #H.cb.walker.expected > 0 and guard < 12 do
            guard = guard + 1
            H.stepDir(H.cb.walker.expected[1])
        end
        H.clock.t = H.clock.t + 400
    end
    return trace
end

-- ============================================================================
S('cfg: the user\'s REAL routes load unchanged')
do
    local prof = configmod.new{ profileDir = PROFILE, vprofile = 1 }
    local names = prof:listCavebots()
    ok(#names >= 18, 'all route files are listed (' .. #names .. ')')
    local total, bad = 0, {}
    for _, n in ipairs(names) do
        local r = prof:loadCavebot(n)
        if not r then bad[#bad+1] = n else total = total + #r.waypoints end
    end
    eq(#bad, 0, 'every route decodes')
    ok(total > 1700, 'total waypoints across the profile = ' .. total)

    -- the two routes the spec quotes verbatim
    local t = prof:loadCavebot('test')
    eq(#t.waypoints, 3, 'test.cfg waypoint count')
    local wps = cavebot.normaliseWaypoints(t)
    eq(wps[1].action, 'goto', 'test.cfg wp1 action')
    eq(wps[1].value, '33218,32434,7,0', 'test.cfg wp1 value')
    eq(wps[2].action, 'exanihur', 'test.cfg wp2 action')
    -- staypositions keys are 1-based WAYPOINT ordinals, metadata pairs not counted
    ok(wps[2].stayPos ~= nil and wps[2].stayPos.x == 33218 and wps[2].stayPos.z == 7,
       'stayposition "2" attaches to waypoint 2')
    ok(wps[3].stayPos ~= nil and wps[3].stayPos.z == 6,
       'stayposition "3" attaches to waypoint 3 (z=6)')
    eq(t.config.antiLostRopeToolId, 9596, 'the config: blob is decoded')

    local mk = prof:loadCavebot('true_asura_mk')
    eq(#mk.waypoints, 292, 'true_asura_mk.cfg waypoint count (VERIFIER: 292)')
    local mkw = cavebot.normaliseWaypoints(mk)
    eq(mkw[69].action, 'function', 'the multi-line function body lands at ordinal 69')
    ok(mkw[69].value:find('TargetBot.setOn()', 1, true) ~= nil,
       'and carries the decoded multi-line source')
    ok(mkw[69].stayPos ~= nil and mkw[69].stayPos.x == 32629,
       'staypositions["69"] attaches to it')
end

-- ============================================================================
S('goto: value grammar and the precision marker')
do
    local p, marker, prec = cavebot.parseGoto('33218,32434,7,0')
    eq(p.x, 33218, 'x'); eq(p.y, 32434, 'y'); eq(p.z, 7, 'z')
    eq(marker, true,  'a 4th field -- even ",0" -- is the precision marker')
    eq(prec, 0, 'precision 0')
    local p2, m2, pr2 = cavebot.parseGoto('32340,32216,7')
    eq(m2, false, 'no 4th field -> no marker')
    eq(pr2, nil,  'and no precision')
    eq(p2.z, 7, 'z parsed')
    eq(cavebot.parseGoto('rubbish'), nil, 'an unparsable value yields nil')
    eqList(cavebot.split('hunt,32822,32816,11'), {'hunt','32822','32816','11'}, 'split')
    eqList(cavebot.split('Tandros,100'), {'Tandros','100'}, 'split (2 fields)')
end

-- ============================================================================
S('END TO END: the user\'s real teeest.cfg route, walked on a synthetic map')
do
    -- teeest.cfg (real file):  7 plain gotos along y=32216, z=7, x 32340->32352->32334->32340
    local prof = configmod.new{ profileDir = PROFILE, vprofile = 1 }
    local route = prof:loadCavebot('teeest')
    local want = {}
    for i, w in ipairs(route.waypoints) do want[i] = cavebot.parseGoto(w.value).x end
    io.write('        route: ', #route.waypoints, ' waypoints, x = ', listStr(want), '\n')

    -- a 19-tile corridor covering x 32334..32352
    local F = newWorld({ ('.'):rep(19) }, { baseX = 32334, baseY = 32216, z = 7 })
    F.st.player.pos = { x = 32340, y = 32216, z = 7 }
    F.st.central = F.st.player.pos
    local H = newHarness(F, { route = route })
    H.cb:enable()

    eq(#H.cb.waypoints, 7, 'seven waypoints loaded')
    eq(H.cb.cfg.antiLostEnabled, false, 'the route config: blob disabled anti-lost')
    eq(H.cb.cfg.stayPathEnabled, false, 'and stay path')
    eq(H.cb.cfg.walkDelay, 10, 'walkDelay comes from the file')
    eq(H.cb:gotoMaxDistance(), 64, 'gotoMaxDistance comes from the REAL bot storage')

    -- record the waypoint index each time it advances
    local visited, lastIndex = {}, nil
    local arrivals = {}
    for i = 1, 400 do
        local before = H.cb.index
        H.cb:tick()
        if H.cb.index ~= before then
            visited[#visited+1] = before
            arrivals[#arrivals+1] = F.st.player.pos.x
        end
        local guard = 0
        while #H.cb.walker.expected > 0 and guard < 12 do
            guard = guard + 1
            H.stepDir(H.cb.walker.expected[1])
        end
        H.clock.t = H.clock.t + 400
        if #visited >= 7 then break end
    end

    eqList(visited, {1,2,3,4,5,6,7}, 'the waypoint index advanced 1..7 in order')
    eqList(arrivals, want, 'and the player stood on each waypoint x when it advanced')
    eq(H.cb.index, 1, 'the route wrapped back to waypoint 1')
    eq(H.cb.stats.laps, 1, 'one full lap')
    eq(H.cb.stats.arrivals, 7, 'seven goto arrivals')
    eq(H.cb.stats.skips, 0, 'nothing was skipped')
    ok(#H.ops('walk') >= 36, 'walk packets sent = ' .. #H.ops('walk')
       .. ' (>= the 36 tiles the route covers)')
    eq(F.st.player.pos.x, 32340, 'and it finished back on the first waypoint')
end

-- ============================================================================
S('goto: a blocked tile -- retries, the monster attack, then the skip')
do
    -- one-tile corridor: player, a blocking monster, the destination behind it
    local F = newWorld({ '@mX' })
    local H = newHarness(F, { route = { waypoints = {
        { action = 'goto', value = ('%d,%d,%d'):format(F.goal.x, F.goal.y, F.goal.z) },
        { action = 'label', value = 'after' },
    }, config = { avoidFloorChange = false, stayPathEnabled = false, antiLostEnabled = false } } })
    H.cb:enable()

    local seen = {}
    for i = 1, 12 do
        seen[#seen+1] = H.cb.retries
        H.cb:tick()
        if H.cb.index ~= 1 then break end
        H.clock.t = H.clock.t + 400
        H.cb.walker:reset(true)             -- the server never confirms: nothing moves
    end
    io.write('        retries seen: ', listStr(seen), '\n')
    -- REVIEW FIX: actions.lua:472 resets the callback's own `retries` to 0 the moment the
    -- blocking monster is engaged, so steps 10 (precision widening), 11 (the retries >= 5
    -- skip) and 13 (the delay ramp) all see 0 for the rest of that call.  vBot therefore
    -- NEVER skips a monster-blocked goto: it falls through to the last-resort
    -- ignoreCreatures walkTo and answers "retry" indefinitely while it kills its way
    -- through.  The waypoint index must not move.
    eqList(seen, {0,1,2,3,4,5,6,7,8,9,10,11},
           'the goto keeps retrying while it unclogs -- it is never skipped')
    eq(H.cb.index, 1, 'the waypoint was NOT skipped (still on the goto)')
    eq(H.cb.stats.skips, 0, 'no skip recorded')
    ok(#H.ops('attack') > 0, 'the blocking monster was attacked (' .. #H.ops('attack') .. 'x)')
    eq(H.ops('attack')[1].id, F.st:tile({x=F.start.x+1, y=F.start.y, z=F.start.z}).things[2].creatureId,
       'and it is the creature standing on the next tile')
    ok(#H.ops('fightMode') > 0, 'chase mode was set')

    -- a wall instead of a creature: no path at all -> skipped on the very first entry
    local G = newWorld({ '@#X' })
    local H2 = newHarness(G, { route = { waypoints = {
        { action = 'goto', value = ('%d,%d,%d'):format(G.goal.x, G.goal.y, G.goal.z) },
        { action = 'label', value = 'after' } },
        config = { avoidFloorChange = false, stayPathEnabled = false, antiLostEnabled = false } } })
    H2.cb:enable()
    H2.cb:tick()
    eq(H2.cb.index, 2, 'an unreachable destination is skipped immediately')
    eq(H2.cb.noPath, 1, 'and it counted one noPath strike')
end

-- ============================================================================
S('label / gotolabel: the jump lands AFTER the label')
do
    local F = newWorld({ '@..' })
    local H = newHarness(F, { route = { waypoints = {
        { action = 'label',     value = 'start' },
        { action = 'say',       value = 'one' },
        { action = 'gotolabel', value = 'START' },        -- case-insensitive
        { action = 'say',       value = 'never' },
    }, config = { stayPathEnabled = false, antiLostEnabled = false } } })
    H.cb:enable()

    local order = {}
    for i = 1, 8 do
        order[#order+1] = H.cb.index
        H.cb:tick()
        H.clock.t = H.clock.t + 100
    end
    eqList(order, {1,2,3,2,3,2,3,2}, 'label(1) -> say(2) -> gotolabel(3) -> back to say(2)')
    eq(H.cb.lastLabel, 'start', 'the label waypoint recorded vBot.lastLabel')
    eq(H.cb.stats.labelJumps, 3, 'three label jumps')
    local talks = H.ops('talk')
    eq(#talks, 4, 'four say packets, never the unreachable one')
    eq(talks[1].text, 'one', 'and always the same text')

    -- a label that does not exist: gotoLabel returns false, which still ADVANCES
    local H2 = newHarness(newWorld({ '@.' }), { route = { waypoints = {
        { action = 'gotolabel', value = 'nowhere' },
        { action = 'label', value = 'x' } },
        config = { stayPathEnabled = false, antiLostEnabled = false } } })
    H2.cb:enable(); H2.cb:tick()
    eq(H2.cb.index, 2, 'a missing label still advances (false advances)')
end

-- ============================================================================
S('delay: applied once on retries==0, completes on the next entry')
do
    local F = newWorld({ '@.' })
    local H = newHarness(F, { route = { waypoints = {
        { action = 'delay', value = '500' },
        { action = 'label', value = 'done' },
    }, config = { stayPathEnabled = false, antiLostEnabled = false } } })
    H.cb:enable()
    local t0 = H.clock.t

    H.cb:tick()
    eq(H.cb.index, 1, 'the first entry holds position')
    eq(H.cb.retries, 1, 'and counted a retry')
    eq(H.cb.readyAt - t0, 500, 'CaveBot.delay(500) was applied')
    eq(H.cb:isDelayed(), true, 'the module is delayed')

    H.cb:tick()
    eq(H.cb.index, 1, 'a tick inside the delay window does nothing')
    eq(H.cb.retries, 1, 'and does not burn a retry')

    H.clock.t = t0 + 500
    H.cb:tick()
    eq(H.cb.index, 2, 'after the delay the waypoint completes and advances')
    eq(H.cb.retries, 0, 'retries reset on a boolean result')

    -- the randomised form: "500,20" -> uniform in [400, 600]
    local lo, hi = math.huge, -math.huge
    for i = 1, 200 do
        local H2 = newHarness(newWorld({ '@.' }), { route = { waypoints = {
            { action = 'delay', value = '500,20' } },
            config = { stayPathEnabled = false, antiLostEnabled = false } } })
        H2.cb:enable()
        local base = H2.clock.t
        H2.cb:tick()
        local d = H2.cb.readyAt - base
        lo, hi = math.min(lo, d), math.max(hi, d)
    end
    ok(lo >= 400 and hi <= 600, ('"500,20" stays inside [400,600] (saw %d..%d)'):format(lo, hi))
    ok(lo < 450 and hi > 550, 'and really is randomised across the range')
end

-- ============================================================================
S('use / usewith: the exact packets')
do
    -- a lever (1666) two tiles east of the player
    local F = newWorld({ '@..' })
    local target = F.at(2, 0)
    F.st:addThing(target, -2, { kind = 'item', id = 1666 })

    local val = ('%d,%d,%d'):format(target.x, target.y, target.z)
    local H = newHarness(F, { route = { waypoints = {
        { action = 'use',     value = val },
        { action = 'usewith', value = '9596,' .. val },
        { action = 'use',     value = '3031' },              -- a bare inventory item id
    }, config = { stayPathEnabled = false, antiLostEnabled = false, useDelay = 400, ping = 100 } } })
    H.cb:enable()

    local t0 = H.clock.t
    H.cb:tick()
    local u = H.ops('use')[1]
    ok(u ~= nil, 'a use packet was sent')
    eq(u.pos.x, target.x, 'use pos.x'); eq(u.pos.y, target.y, 'use pos.y')
    eq(u.pos.z, target.z, 'use pos.z')
    eq(u.id, 1666, 'use carries the tile\'s top-use item id')
    eq(u.stack, 1, 'and its 0-based stackpos (ground is 0, the lever is 1)')
    eq(H.cb.readyAt - t0, 500, 'CaveBot.delay(useDelay + CONFIG ping) = 500  [VERIFIER]')
    eq(H.cb.index, 2, 'and the waypoint advanced')

    H.clock.t = H.cb.readyAt
    local t1 = H.clock.t
    H.cb:tick()
    local uw = H.ops('useWith')[1]
    ok(uw ~= nil, 'a useWith packet was sent')
    eq(uw.id, 9596, 'usewith carries the configured item id')
    eq(uw.fromPos.x, 0xFFFF, 'sourced from the inventory pseudo-position')
    eq(uw.toPos.x, target.x, 'targeting the waypoint tile')
    eq(uw.toId, 1666, 'and the tile\'s top-use thing')
    eq(H.cb.readyAt - t1, 500, 'same useDelay + ping')

    H.clock.t = H.cb.readyAt
    H.cb:tick()
    local u2 = H.ops('use')[2]
    ok(u2 ~= nil, 'a bare item id is an INVENTORY use')
    eq(u2.pos.x, 0xFFFF, 'at the inventory pseudo-position')
    eq(u2.id, 3031, 'with the id from the waypoint')
    eq(H.cb.readyAt, H.clock.t, 'and NO delay at all (actions.lua:545-580)')

    -- out of range / wrong floor are hard skips
    local G = newWorld({ '@' .. ('.'):rep(9) })
    local far = G.at(9, 0)
    G.st:addThing(far, -2, { kind = 'item', id = 1666 })
    local H2 = newHarness(G, { route = { waypoints = {
        { action = 'use', value = ('%d,%d,%d'):format(far.x, far.y, far.z) },
        { action = 'label', value = 'x' } },
        config = { stayPathEnabled = false, antiLostEnabled = false } } })
    H2.cb:enable(); H2.cb:tick()
    eq(#H2.ops('use'), 0, 'a use beyond 7 sqm sends nothing')
    eq(H2.cb.index, 2, 'and is skipped')
end

-- ============================================================================
S('say / npcsay / turn / walkdelay')
do
    local F = newWorld({ '@.' })
    local H = newHarness(F, { route = { waypoints = {
        { action = 'say',       value = 'exura vita' },
        { action = 'npcsay',    value = 'hi' },
        { action = 'turn',      value = 'east' },
        { action = 'turn',      value = '2' },
        { action = 'walkdelay', value = '30' },
        { action = 'walkdelay', value = '99999' },
    }, config = { stayPathEnabled = false, antiLostEnabled = false } } })
    H.cb:enable()
    for i = 1, 6 do H.cb:tick(); H.clock.t = H.clock.t + 50 end

    local talks = H.ops('talk')
    eq(talks[1].mode, 1,  'say uses MessageSay (1)')
    eq(talks[1].text, 'exura vita', 'with the raw text')
    eq(talks[2].mode, 11, 'npcsay uses MessageNpcTo (11)')
    eq(talks[2].text, 'hi', 'with the raw text')
    local turns = H.ops('turn')
    eq(turns[1].dir, 1, 'turn:east -> direction 1')
    eq(turns[2].dir, 2, 'turn:2 -> direction 2')
    eq(H.cb.cfg.walkDelay, 30, 'walkdelay wrote the live config')
    eq(H.cb.walker.cfg.walkDelay, 30, 'and reconfigured the walker')
    eq(H.cb.index, 1, 'six waypoints ran and the route wrapped')
end

-- ============================================================================
S('function waypoint: sandbox, return value passthrough, error containment')
do
    local F = newWorld({ '@.' })
    local H = newHarness(F, { route = { waypoints = {
        { action = 'function', value = 'return true' },
        { action = 'function', value = 'if retries < 2 then return "retry" end return true' },
        { action = 'function', value = 'gotoLabel("home") return true' },
        { action = 'label',    value = 'home' },
        { action = 'function', value = 'this is not lua' },
    }, config = { stayPathEnabled = false, antiLostEnabled = false } } })
    H.cb:enable()

    H.cb:tick(); eq(H.cb.index, 2, 'a function returning true advances')
    H.cb:tick(); eq(H.cb.retries, 1, 'a function returning "retry" holds (1)')
    H.cb:tick(); eq(H.cb.retries, 2, 'and again (2)')
    H.cb:tick(); eq(H.cb.index, 3, 'then completes')
    H.cb:tick(); eq(H.cb.index, 5, 'gotoLabel("home") focused wp4, +1 lands on wp5')
    H.cb:tick(); eq(H.cb.index, 1, 'a compile error is contained and the waypoint skipped')

    -- the sandbox really does see the bot api
    local H2 = newHarness(newWorld({ '@.' }), { route = { waypoints = {
        { action = 'function', value = 'return hpPercent() > 0' } },
        config = { stayPathEnabled = false, antiLostEnabled = false } } })
    H2.bot.state.player.health, H2.bot.state.player.maxHealth = 50, 100
    H2.cb:enable(); H2.cb:tick()
    eq(H2.cb.prevResult, true, 'the bot api (hpPercent) is visible inside a function waypoint')
end

-- ============================================================================
S('unknown waypoint types: log ONCE and skip, never abort the route')
do
    local F = newWorld({ '@.' })
    local H = newHarness(F, { route = { waypoints = {
        { action = 'node',      value = '1,2,3' },       -- legacy, parsed as a goto
        { action = 'sayhello',  value = 'x' },           -- never registered upstream either
        { action = 'wibble',    value = 'y' },
        { action = 'sayhello',  value = 'z' },
        { action = 'label',     value = 'end' },
    }, config = { stayPathEnabled = false, antiLostEnabled = false } } })
    H.cb:enable()
    for i = 1, 5 do H.cb:tick(); H.clock.t = H.clock.t + 50 end
    eq(H.cb.index, 1, 'the route survived and wrapped')
    eq(H.cb.stats.unknown, 3, 'three unknown-action dispatches')
    local warnings = 0
    for _, l in ipairs(H.log) do
        if l:find('Invalid cavebot action', 1, true) then warnings = warnings + 1 end
    end
    eq(warnings, 2, 'but only TWO warnings: one per distinct type')
end

-- ============================================================================
S('stay path: the hidden goto for non-goto waypoints')
do
    -- wp1 goto sets the route reference; wp2 is a `say` carrying a stayPos 6 tiles away
    local F = newWorld({ ('.'):rep(12) }, { baseX = 500, baseY = 500, z = 7 })
    F.st.player.pos = { x = 500, y = 500, z = 7 }
    F.st.central = F.st.player.pos
    local stay = { x = 506, y = 500, z = 7 }
    local H = newHarness(F, { route = { waypoints = {
        { action = 'goto', value = '505,500,7' },
        { action = 'say',  value = 'here', stayPos = stay },
    }, config = { stayPathEnabled = true, antiLostEnabled = false, avoidFloorChange = false } } })
    H.cb:enable()
    H.cb.index = 2                       -- pretend the goto already ran

    H.cb:tick()
    eq(#H.ops('talk'), 0, 'the action does NOT run while we are >2 tiles from the stayPos')
    ok(#H.ops('walk') > 0, 'it walks toward the saved position instead')
    eq(H.cb.index, 2, 'and the waypoint is not advanced')

    -- arrive within the 2-tile tolerance (a multi-tile jump never confirms the step
    -- ledger, so drop it exactly like CaveBot.resetWalking() does)
    H.moveTo({ x = 505, y = 500, z = 7 })
    H.cb.walker:reset(true)
    H.clock.t = H.clock.t + 500
    H.cb:tick()
    eq(#H.ops('talk'), 1, 'within 2 tiles the action runs')
    eq(H.cb.index, 1, 'and the route advances (wrapping)')

    -- STALE: a stayPos far from the preceding positional waypoint is ignored
    local G = newWorld({ ('.'):rep(12) }, { baseX = 500, baseY = 500, z = 7 })
    local H2 = newHarness(G, { route = { waypoints = {
        { action = 'goto', value = '505,500,7' },
        { action = 'say',  value = 'here', stayPos = { x = 600, y = 500, z = 7 } },
    }, config = { stayPathEnabled = true, antiLostEnabled = false } } })
    H2.cb:enable(); H2.cb.index = 2
    H2.cb:tick()
    eq(#H2.ops('talk'), 1, 'a stayPos >15 tiles from the route reference is stale and ignored')

    -- the 3 s fail-open: an unreachable stayPos must not deadlock the route
    local K = newWorld({ '@..#........' }, { baseX = 500, baseY = 500, z = 7 })
    local H3 = newHarness(K, { route = { waypoints = {
        { action = 'goto', value = '502,500,7' },
        { action = 'say',  value = 'here', stayPos = { x = 508, y = 500, z = 7 } },
    }, config = { stayPathEnabled = true, antiLostEnabled = false, avoidFloorChange = false } } })
    H3.cb:enable(); H3.cb.index = 2
    H3.cb:tick()
    eq(#H3.ops('talk'), 0, 'blocked: the action is held')
    H3.clock.t = H3.clock.t + 3000
    H3.cb:tick()
    eq(#H3.ops('talk'), 1, 'after 3000 ms without improvement it FAILS OPEN and runs anyway')

    -- excluded actions never stay-path
    local L = newWorld({ ('.'):rep(12) }, { baseX = 500, baseY = 500, z = 7 })
    local H4 = newHarness(L, { route = { waypoints = {
        { action = 'goto', value = '505,500,7' },
        { action = 'use',  value = '3031', stayPos = { x = 506, y = 500, z = 7 } },
    }, config = { stayPathEnabled = true, antiLostEnabled = false } } })
    H4.cb:enable(); H4.cb.index = 2
    H4.cb:tick()
    eq(#H4.ops('use'), 1, '`use` is in STAYPATH_EXCLUDED_ACTIONS, so it runs immediately')
end

-- ============================================================================
S('TargetBot arbitration: CaveBot yields, then resumes cleanly')
do
    local F = newWorld({ ('.'):rep(8) }, { baseX = 700, baseY = 700, z = 7 })
    local H = newHarness(F, { route = { waypoints = {
        { action = 'goto', value = '705,700,7' },
    }, config = { stayPathEnabled = false, antiLostEnabled = false, avoidFloorChange = false } } })
    H.cb:enable()

    local tb = { on = true, active = true, allow = false }
    function tb:isOn() return self.on end
    function tb:isActive() return self.active end
    function tb:isCaveBotActionAllowed() return self.allow end
    H.bot:registerModule('targetbot', tb)

    H.cb:tick()
    eq(H.cb.lastStatus, 'yield:targetbot', 'CaveBot yields while TargetBot is fighting')
    eq(#H.ops('walk'), 0, 'and sends nothing')
    eq(H.cb.index, 1, 'the waypoint is untouched')

    tb.allow = true                       -- the 150 ms lure grant
    H.cb:tick()
    ok(#H.ops('walk') > 0, 'a lure grant lets CaveBot keep walking')

    tb.allow, tb.active = false, false
    H.clock.t = H.clock.t + 500
    H.cb.walker:reset(true)
    H.cb:tick()
    ok(#H.ops('walk') > 1, 'and it resumes the same waypoint once TargetBot goes idle')
end

-- ============================================================================
S('supplies: the user\'s REAL Supplies.json')
do
    local prof = configmod.new{ profileDir = PROFILE, vprofile = 1 }
    local raw  = prof:loadSupplies()
    ok(raw ~= nil, 'Supplies.json loads')

    local F = newWorld({ '@.' })
    local fakeBot = { state = F.st, storage = { caveBot = {}, extras = {} },
                      log = { info=function() end, warn=function() end,
                              error=function() end, debug=function() end } }
    local sup = suppliesm.new(fakeBot, raw)

    eq(sup.profileName, 'Default', 'currentProfile')
    eqList(sup:itemOrder(), {3097, 23374}, 'both configured ids, deterministically ordered')
    eq(sup:items()[23374].min, 200, 'id 23374 min')
    eq(sup:items()[23374].max, 1200, 'id 23374 max')
    eq(sup:items()[3097].min, 1, 'id 3097 min')
    -- the thresholds that are STRINGS in the file must come back as numbers
    eq(sup:additionalData().capacity.enabled, true,  'capSwitch')
    eq(sup:additionalData().capacity.value,   200,   'capValue "200" -> number 200')
    eq(type(sup:additionalData().capacity.value), 'number', 'and really is a number')
    eq(sup:additionalData().lootPouch.value,  50,    'lootPouchValue "50" -> 50')
    eq(sup:additionalData().stamina.enabled,  false, 'staminaSwitch is absent -> off')

    -- itemAmount = max(visible scan, the server's own count)
    F.st.containers = { [0] = { id = 0, name = 'backpack', capacity = 20,
                                items = { { id = 23374, count = 150 } } } }
    eq(sup:itemAmount(23374), 150, 'visible scan')
    F.st.inventoryCounts = { [23374 * 256] = 420 }
    eq(sup:itemAmount(23374), 420, 'the SERVER count wins -- a closed backpack still counts')
    F.st.inventoryCounts = nil

    -- hasEnough (ids are visited in ascending order, so 3097 is checked first)
    F.st.containers[0].items = { { id = 23374, count = 150 }, { id = 3097, count = 5 } }
    eq(sup:hasEnough().id, 23374, 'below min -> the offending id is returned')
    eq(sup:hasEnough().amount, 150, 'with the amount we hold')
    F.st.containers[0].items = { { id = 23374, count = 500 }, { id = 3097, count = 0 } }
    eq(sup:hasEnough().id, 3097, 'and the FIRST offender in id order wins')
    F.st.containers[0].items = { { id = 23374, count = 250 }, { id = 3097, count = 3 } }
    eq(sup:hasEnough(), true, 'at/above min -> true')

    -- buyList: min(100, max - have)
    local bl = sup:buyList()
    eq(#bl, 2, 'two ids to buy')
    eq(bl[1].id, 3097, 'the low id first')
    eq(bl[1].amount, 2, '3097: max 5 - have 3')
    eq(bl[2].amount, 100, '23374: max 1200 - have 250 = 950, CLAMPED to the 100 batch size')
end

-- ============================================================================
S('supplies: the round gate fires at exactly the configured threshold')
do
    local prof = configmod.new{ profileDir = PROFILE, vprofile = 1 }
    local raw  = prof:loadSupplies()
    local F = newWorld({ '@.' })
    F.st.player.capacity = 1000
    local storage = { caveBot = { forceRefill = false, backStop = false,
                                  backTrainers = false, backOffline = false },
                      extras = { huntRoutes = 300 } }
    local fakeBot = { state = F.st, storage = storage,
                      log = { info=function() end, warn=function() end,
                              error=function() end, debug=function() end } }
    local sup = suppliesm.new(fakeBot, raw)
    F.st.containers = { [0] = { id = 0, name = 'backpack', capacity = 20, items = {} } }

    local function setCount(id, n) F.st.containers[0].items = { { id = id, count = n } } end

    -- 23374 min = 200
    setCount(23374, 200)
    F.st.containers[0].items[2] = { id = 3097, count = 5 }
    eq(sup:checkRound(), nil, 'exactly AT the min (200) is enough -> keep hunting')
    setCount(23374, 199)
    F.st.containers[0].items[2] = { id = 3097, count = 5 }
    eq(sup:checkRound(), 'supplies:23374', 'one below the min triggers the refill')

    -- capacity: capValue 200
    setCount(23374, 500); F.st.containers[0].items[2] = { id = 3097, count = 5 }
    F.st.player.capacity = 200
    eq(sup:checkRound(), nil, 'cap exactly at the threshold is fine')
    F.st.player.capacity = 199
    eq(sup:checkRound(), 'capacity', 'one below capValue triggers the refill')
    F.st.player.capacity = 1000

    -- loot pouch: lootPouchValue 50, pages = ceil(size / capacity)
    F.st.containers[1] = { id = 1, name = 'loot pouch', capacity = 20, size = 980, items = {} }
    eq(sup:lootPouchPages(), 49, '980 items / 20 per page = 49 pages')
    eq(sup:checkRound(), nil, '49 < 50 -> keep hunting')
    F.st.containers[1].size = 1000
    eq(sup:lootPouchPages(), 50, '1000 / 20 = 50 pages')
    eq(sup:checkRound(), 'lootPouch', '>= lootPouchValue triggers the refill')
    F.st.containers[1] = nil

    -- the cascade ORDER: the first matching branch wins
    storage.caveBot.forceRefill = true
    F.st.player.capacity = 1
    eq(sup:checkRound(), 'forceRefill', 'branch 1 beats everything below it')
    eq(storage.caveBot.forceRefill, false, 'and the one-shot flag was consumed')
    eq(sup:checkRound(), 'capacity', 'the next check falls through to the capacity branch')
    F.st.player.capacity = 1000
    storage.caveBot.backStop = true
    eq(sup:checkRound(), 'backStop', 'backStop')
    storage.caveBot.backStop = false

    -- round limit: (huntRoutes or 0) ~= 0 and rounds > huntRoutes   [VERIFIER]
    sup.supplyRetries = 300
    eq(sup:checkRound(), nil, 'rounds == huntRoutes is still fine (strict >)')
    sup.supplyRetries = 301
    eq(sup:checkRound(), 'huntRoutes', 'one over the limit forces a refill')
    storage.extras.huntRoutes = 0
    eq(sup:checkRound(), nil, 'huntRoutes 0 disables the gate entirely')
    storage.extras.huntRoutes = 300
    sup.supplyRetries = 0
end

-- ============================================================================
S('supplycheck waypoint: keeps hunting, then diverts to the refill branch')
do
    local prof = configmod.new{ profileDir = PROFILE, vprofile = 1 }
    local raw  = prof:loadSupplies()
    local F = newWorld({ ('.'):rep(6) }, { baseX = 800, baseY = 800, z = 7 })
    F.st.containers = { [0] = { id = 0, name = 'backpack', capacity = 20,
                                items = { { id = 23374, count = 500 },
                                          { id = 3097, count = 5 } } } }
    local H = newHarness(F, { route = { waypoints = {
        { action = 'label',       value = 'hunt' },
        { action = 'say',         value = 'hunting' },
        { action = 'supplycheck', value = 'hunt,800,800,7' },
        { action = 'label',       value = 'refill' },
        { action = 'say',         value = 'refilling' },
    }, config = { stayPathEnabled = false, antiLostEnabled = false } } })
    H.cb.supplies:reload(raw)
    H.bot.storage.caveBot = { forceRefill = false, backStop = false,
                              backTrainers = false, backOffline = false }
    H.cb:enable()

    H.cb.index = 3
    H.cb:tick()
    eq(H.cb.index, 2, 'supplies are fine: gotoLabel("hunt") focused wp1, +1 lands on wp2')
    eq(H.cb.supplies.supplyRetries, 1, 'and the hunt round counter advanced')

    -- drop below the min
    F.st.containers[0].items[1].count = 10
    H.cb.index = 3
    H.cb:tick()
    eq(H.cb.index, 4, 'below the min: supplycheck returns false, falling through to the refill')
    eq(H.cb.lastRefillReason, 'supplies:23374', 'and it names the offending id')
    eq(H.cb.supplies.supplyRetries, 0, 'the round counter was reset by the refill')

    -- the position guard: too far from the check position -> bounce back into the hunt
    F.st.player.pos = { x = 900, y = 900, z = 7 }
    H.cb.index = 3
    H.cb:tick()
    eq(H.cb.supplies.missedChecks, 1, 'out of position: missedChecks++')
    eq(H.cb.index, 2, 'and it bounced back to the hunt label')
    for i = 1, 3 do H.cb.index = 3; H.cb:tick() end
    eq(H.cb.supplies.missedChecks, 4, 'four misses recorded')
    H.cb.index = 3
    H.cb:tick()
    eq(H.cb.index, 4, 'the FIFTH miss returns true and proceeds into town anyway')
    eq(H.cb.supplies.missedChecks, 0, 'counters reset')
end

-- ============================================================================
S('buysupplies: reaches the NPC, opens the trade, then buys up to `max`')
do
    local F = newWorld({ '@..N' }, { npcName = 'Topsy' })
    F.st.containers = { [0] = { id = 0, name = 'backpack', capacity = 20,
                                items = { { id = 23374, count = 1000 } } } }
    local H = newHarness(F, { route = { waypoints = {
        { action = 'buysupplies', value = 'Topsy,100' },
        { action = 'label', value = 'done' },
    }, config = { stayPathEnabled = false, antiLostEnabled = false } } })
    local prof = configmod.new{ profileDir = PROFILE, vprofile = 1 }
    H.cb.supplies:reload(prof:loadSupplies())
    H.cb:enable()

    H.cb:tick()
    eq(H.cb.index, 1, 'the NPC is 3 sqm away: reachNPC is satisfied, but no trade window yet')
    local talks = H.ops('talk')
    eq(talks[1].text, 'hi', 'it greets the NPC')
    eq(talks[1].mode, 11, 'on the NPC channel')
    eq(H.cb.retries, 1, 'and retries')

    -- the server answers: a trade window carrying both configured ids
    F.st.npcTrade = { open = true, items = { { id = 23374 }, { id = 3097 } } }
    H.clock.t = H.cb.readyAt
    H.cb:tick()
    local buys = H.ops('buy')
    eq(#buys, 1, 'one batch per tick')
    eq(buys[1].id, 3097, 'the first id that is short')
    eq(buys[1].amount, 5, '3097: max 5 - have 0')

    F.st.containers[0].items[2] = { id = 3097, count = 5 }
    H.clock.t = H.cb.readyAt + 10
    H.cb:tick()
    buys = H.ops('buy')
    eq(#buys, 2, 'the next tick buys the other id')
    eq(buys[2].id, 23374, '23374')
    eq(buys[2].amount, 100, 'max 1200 - have 1000 = 200, CLAMPED to the 100 batch size')

    F.st.containers[0].items[1].count = 1200
    H.clock.t = H.cb.readyAt + 10
    H.cb:tick()
    eq(H.cb.index, 2, 'nothing left to buy -> true, advance')

    -- an NPC that is not there is a hard skip
    local G = newWorld({ '@..' })
    local H2 = newHarness(G, { route = { waypoints = {
        { action = 'buysupplies', value = 'Nobody' },
        { action = 'label', value = 'x' } },
        config = { stayPathEnabled = false, antiLostEnabled = false } } })
    H2.cb:enable(); H2.cb:tick()
    eq(H2.cb.index, 2, 'a missing NPC skips the waypoint')
end

-- ============================================================================
S('depositor: moves loot-list items into the depot chest')
do
    local F = newWorld({ '@.' })
    -- a locker one tile east, so reachDepot is already satisfied
    F.st:addThing(F.at(1, 0), -2, { kind = 'item', id = 3497 })
    F.st.containers = {
        [0] = { id = 0, name = 'backpack', capacity = 20, firstIndex = 0,
                items = { { id = 3031, count = 10 }, { id = 9999, count = 1 } } },
        [1] = { id = 1, name = 'Depot chest', capacity = 20, firstIndex = 0, items = {} },
    }
    local H = newHarness(F, { route = { waypoints = {
        { action = 'depositor', value = 'no' },
        { action = 'label', value = 'x' },
    }, config = { stayPathEnabled = false, antiLostEnabled = false } } })
    -- inject the loot list the TargetBot config would supply
    H.cb._lootList, H.cb._lootContainers = { [3031] = true }, {}
    H.cb:enable()

    H.cb:tick()
    local mv = H.ops('move')[1]
    ok(mv ~= nil, 'a move packet was sent')
    if mv then
        eq(mv.id, 3031, 'the loot-list item, not the unlisted one')
        eq(mv.fromPos.x, 0xFFFF, 'from the container pseudo-position')
        eq(mv.fromPos.y, 0x40 + 0, 'container 0')
        eq(mv.toPos.y, 0x40 + 1, 'into the Depot chest container')
        eq(mv.toPos.z, 1, 'slot 1 (a stackable item, no specialDeposit entry)')
        eq(mv.count, 10, 'the whole stack')
    end
    eq(H.cb.index, 1, 'and it retries until the container is empty')

    F.st.containers[0].items = { { id = 9999, count = 1 } }
    H.clock.t = H.cb.readyAt + 10
    H.cb:tick()
    eq(H.cb.index, 2, 'nothing left on the loot list -> true, advance')

    -- an empty loot list is a no-op
    local G = newWorld({ '@.' })
    local H2 = newHarness(G, { route = { waypoints = {
        { action = 'depositor', value = 'no' }, { action = 'label', value = 'x' } },
        config = { stayPathEnabled = false, antiLostEnabled = false } } })
    H2.cb._lootList, H2.cb._lootContainers = {}, {}
    H2.cb:enable(); H2.cb:tick()
    eq(H2.cb.index, 2, 'an empty loot list advances immediately')
    eq(#H2.ops('move'), 0, 'and moves nothing')
end

-- ============================================================================
S('delay semantics: CaveBot.delay is MAX, plain delay OVERWRITES')
do
    local F = newWorld({ '@.' })
    local H = newHarness(F, { route = { waypoints = { { action = 'label', value = 'x' } } } })
    local t0 = H.clock.t
    H.cb:delay(1000)
    eq(H.cb.readyAt - t0, 1000, 'CaveBot.delay(1000)')
    H.cb:delay(100)
    eq(H.cb.readyAt - t0, 1000, 'CaveBot.delay(100) cannot SHORTEN it (max)')
    H.cb:setDelay(100)
    eq(H.cb.readyAt - t0, 100, 'plain delay(100) overwrites -- and can shorten')
    -- the walker writes the SAME field
    H.cb.walker:delay(700)
    eq(H.cb.readyAt - t0, 700, 'a walker step delay lands on the CaveBot delay field')
end

-- ============================================================================
S('anti-lost: expected vs accidental floor changes')
do
    local F = newWorld({ '@..' }, { baseX = 600, baseY = 600, z = 7 })
    local H = newHarness(F, { route = { waypoints = {
        { action = 'goto',    value = '601,600,7' },
        { action = 'use',     value = '602,600,7' },
        { action = 'goto',    value = '640,600,6' },
    }, config = { antiLostEnabled = true, stayPathEnabled = false } } })
    H.cb:enable()

    -- wp2 is a `use` -> a floor change here is deliberate
    H.cb.index = 2
    eq(H.cb:isExpectedFloorChange(6, { x = 602, y = 600, z = 7 }), true,
       'a `use` waypoint explains the floor change')

    -- wp1 is a plain goto on our floor, and we fell far from it -> accidental
    H.cb.index = 1
    eq(H.cb:isExpectedFloorChange(6, { x = 650, y = 650, z = 7 }), false,
       'a fall far from the current waypoint is accidental (VERIFIER early exit)')

    -- and the recovery actually arms
    H.cb.index = 1
    H.moveTo({ x = 650, y = 650, z = 7 })          -- walk away from waypoint 1 first
    H.moveTo({ x = 650, y = 650, z = 6 })          -- then fall
    eq(H.cb.al.recovering, true, 'recovery armed')
    eq(H.cb.al.mode, 'stairs', 'classified as a stairs recovery')
    ok(H.cb.readyAt > H.clock.t, 'and CaveBot was frozen')

    -- a repeat of the same fall inside 60 s is suppressed by the bounce guard
    local H2 = newHarness(newWorld({ '@..' }, { baseX = 600, baseY = 600, z = 7 }),
        { route = { waypoints = { { action = 'goto', value = '601,600,7' } },
                    config = { antiLostEnabled = true, stayPathEnabled = false } } })
    H2.cb:enable()
    H2.moveTo({ x = 600, y = 600, z = 6 })
    eq(H2.cb.al.recovering, true, 'first fall arms recovery')
    H2.cb.al.recovering = false
    H2.moveTo({ x = 600, y = 600, z = 7 })
    H2.clock.t = H2.clock.t + 1000
    H2.moveTo({ x = 600, y = 600, z = 6 })
    eq(H2.cb.al.recovering, false, 'the same fall inside 60 s is treated as intended')
end

-- ============================================================================
S('follow / lure / poscheck / opendoors')
do
    local F = newWorld({ '@..N' }, { npcName = 'Old Adall' })
    local H = newHarness(F, { route = { waypoints = {
        { action = 'follow', value = 'Old Adall' },
        { action = 'follow', value = 'Nobody' },
    }, config = { stayPathEnabled = false, antiLostEnabled = false } } })
    H.cb:enable()
    H.cb:tick()
    eq(#H.ops('follow'), 1, 'follow sent')
    eq(H.cb.retries, 1, 'and retries while >= 2 tiles away')
    H.moveTo({ x = F.base.x + 2, y = F.base.y, z = F.base.z })
    H.clock.t = H.cb.readyAt
    H.cb:tick()
    eq(H.ops('follow')[2].id, 0, 'within 2 tiles it cancels the follow')
    eq(H.cb.index, 2, 'and advances')
    H.cb:tick()
    eq(H.cb.index, 1, 'a missing creature is a skip')

    -- poscheck
    local G = newWorld({ ('.'):rep(6) }, { baseX = 900, baseY = 900, z = 7 })
    local H2 = newHarness(G, { route = { waypoints = {
        { action = 'label',    value = 'back' },
        { action = 'poscheck', value = 'back,3,900,900,7' },
        { action = 'label',    value = 'ok' },
    }, config = { stayPathEnabled = false, antiLostEnabled = false } } })
    H2.cb:enable()
    H2.cb.index = 2
    H2.cb:tick()
    eq(H2.cb.index, 3, 'in position -> true, advance')
    H2.moveTo({ x = 950, y = 950, z = 7 })
    H2.cb.index = 2
    H2.cb:tick()
    eq(H2.cb.index, 2, 'out of position -> gotoLabel("back") focused wp1, +1 lands on wp2')
    eq(H2.cb.posCheck.count, 1, 'and the counter advanced')

    -- opendoors
    local K = newWorld({ '@#.' })
    local door = K.at(1, 0)
    K.st:addThing(door, -2, { kind = 'item', id = 1666 })
    local H3 = newHarness(K, { route = { waypoints = {
        { action = 'opendoors', value = ('%d,%d,%d'):format(door.x, door.y, door.z) },
        { action = 'label', value = 'x' } },
        config = { stayPathEnabled = false, antiLostEnabled = false } } })
    H3.cb:enable()
    H3.cb:tick()
    eq(#H3.ops('use'), 1, 'a closed (non-walkable) door is used')
    eq(H3.cb.retries, 1, 'and retried')
    eq(H3.ops('use')[1].id, 1666, 'the top-use thing is the door')
    local guard = 0
    while H3.cb.index == 1 and guard < 12 do
        guard = guard + 1
        H3.clock.t = H3.clock.t + 300
        H3.cb:tick()
    end
    eq(H3.cb.index, 2, 'after 5 retries the waypoint is skipped')
    eq(#H3.ops('use'), 5, 'and it used the door exactly 5 times (retries 0..4)')
end

-- ============================================================================
S('module surface + status object')
do
    local prof = configmod.new{ profileDir = PROFILE, vprofile = 1 }
    local F = newWorld({ ('.'):rep(6) }, { baseX = 32334, baseY = 32216, z = 7 })
    local H = newHarness(F, { route = prof:loadCavebot('teeest') })
    eq(H.cb:isOn(), false, 'starts disabled')
    H.cb:enable()
    eq(H.cb:isOn(), true, 'enable()')
    local s = H.cb:status()
    eq(s.waypointCount, 7, 'status.waypointCount')
    eq(s.waypointIndex, 1, 'status.waypointIndex')
    ok(s.currentAction:find('goto:', 1, true) == 1, 'status.currentAction = ' .. s.currentAction)
    ok(s.walker ~= nil, 'status carries the walker sub-status')
    local sup = H.cb.supplies:status()
    ok(#sup == 2 and sup[1].item ~= nil and sup[1].threshold ~= nil,
       'supplies status is the BOT.md array of {item, count, threshold}')
    eq(sup.profile, 'Default', 'plus named context fields')
    H.cb:disable()
    eq(H.cb:isOn(), false, 'disable()')
    -- reload swaps the route and resets every latch
    H.cb.index, H.cb.retries = 5, 3
    H.cb:reload(prof:loadCavebot('poi_fury'))
    eq(#H.cb.waypoints, 16, 'reload() swapped the route')
    eq(H.cb.index, 1, 'and reset the index')
    eq(H.cb.retries, 0, 'and the retry counter')
end

-- ============================================================================
io.write('\n')
for _, m in ipairs(msgs) do io.write(m, '\n') end
io.write(('TOTAL: %d passed, %d failed  -> %s\n'):format(pass, fail,
         fail == 0 and 'PASS' or 'FAIL'))

if _G.BOT_M2_NO_EXIT then
    return { pass = pass, fail = fail, failures = msgs }
end
os.exit(fail == 0 and 0 or 1)
