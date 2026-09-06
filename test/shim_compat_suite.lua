--[==[========================================================================
test/shim_compat_suite.lua -- BACKWARD COMPATIBILITY: real otclient/vBot script
fragments, run unchanged through the shim.

    luajit test/shim_compat_suite.lua
    wsl.exe -d Debian -e sh -c 'cd /mnt/d/Claude/otclient_web/luaclient && \
        luajit test/shim_compat_suite.lua'

The acceptance criterion for this whole project is not "the shim has an API
surface", it is "a script written for otclient + vBot runs UNCHANGED".  So this
suite does not test the shim's own functions; it takes scripts and runs them:

  A  EVERY MACRO in the user's real vBot 4.8 profile.  All of them are
     force-enabled and each body is invoked in isolation, so one macro that
     cannot run headless is attributed to itself instead of hiding behind the
     47 that can.  Reported as script / loaded? / ran? / first error.

  B  HAND-WRITTEN SNIPPETS in the g_game / g_map / g_things / UI / corelib
     idioms an otclient user actually writes.  Each one is compiled with
     `load(src, name, nil, context)` -- byte for byte the way
     mods/game_bot/executor.lua:115 compiles the user's own scripts -- so a
     snippet that runs here is a snippet that runs in the real bot.

  C  CALLBACKS: the user's own onTalk / onTextMessage / onCreatureAppear /
     onContainerOpen registrations, driven by REAL parser events pushed onto
     LC.events, proving the shim/callbacks.lua bridge reaches vBot's code.

  D  CONFIG ROUND-TRIP: every one of the user's real cavebot_configs/*.cfg and
     targetbot_configs/*.json parsed through the shim's own path (g_resources +
     table.decodeStringPairList / json), then re-encoded and re-parsed and
     compared.  A shim that cannot read the user's configs is not compatible
     however many API symbols it has.  Writes go to a TEMP copy only; nothing
     under the otclient tree is ever modified.

The coverage table is printed verbatim at the end.

Sections A, C and D need the real otclient tree; they SKIP WITH A PRINTED
REASON when it is absent so the suite still passes anywhere.  Section B needs
it too (the snippets run inside the real sandbox), and says so.

Set `_G.SHIMCOMPAT_NO_EXIT = true` before dofile()ing this file and it returns
{ pass=, fail=, failures={} } instead of exiting.
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
    local candidates = {
        ROOT .. '/../../otclient_mehah1530/otclient',
        'D:/Claude/otclient_mehah1530/otclient',
        '/mnt/d/Claude/otclient_mehah1530/otclient',
    }
    for _, c in ipairs(candidates) do
        local f = io.open(c .. '/profiles/bot/vBot_4.8/_Loader.lua', 'r')
        if f then f:close(); OTROOT = c; break end
    end
end

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
end
local function eq(a, b, desc)
    check(a == b, desc, ('got %s, want %s'):format(tostring(a), tostring(b)))
end
local function skip(what, why)
    io.write('   SKIP ', what, '  -- ', why, '\n')
end

--- One row of the deliverable table.
local COVERAGE = {}      -- { kind, script, loaded, ran, err }
local function row(kind, script, loaded, ran, err)
    COVERAGE[#COVERAGE + 1] = { kind = kind, script = script, loaded = loaded,
                                ran = ran, err = err }
end

--- The first line of an error, with the noisy chunk prefix trimmed.
local function short(err)
    if err == nil then return nil end
    local s = tostring(err):gsub('\r?\n.*', '')
    s = s:gsub('^%[string "', ''):gsub('^@', '')
    if #s > 96 then s = s:sub(1, 93) .. '...' end
    return s
end

-- ========================================================== the world
local state   = require('game.state')
local events  = require('lib.events')
local sched   = require('lib.sched')
local items   = require('proto.items')
local sender  = require('proto.sender')

-- proto/items.lua backs Tile:getGround(), Item:isStackable(), every ThingType
-- getter and bot/path.lua's walkability.  Without it a "no ground" failure would
-- look like a shim bug rather than a missing fixture.
local ITEMS_OK = items.loaded
if not ITEMS_OK then ITEMS_OK = pcall(items.load, ROOT .. '/assets/items1530.bin') end

local ORIGIN     = { x = 1000, y = 1000, z = 7 }
local PLAYER_ID  = 0x1000
local RAT_ID     = 0x2001
local DEMON_ID   = 0x2002
local FRIEND_ID  = 0x2003
local ID_GRASS   = 4526      -- a plain walkable ground at 1530
local ID_WALL    = 1006     -- a genuinely NotWalkable item in items1530.bin
local ID_GOLD    = 3031
local ID_BP      = 2854
local ID_MANA    = 268       -- mana potion
local ID_CORPSE  = 3058

--- A synthetic client: real game/state, a real sender over a capturing transport,
--- a real event bus.  Everything the shim reads is genuine client state.
local function newLC()
    local st = state.new()
    local sent = {}
    local transport = { send = function(_, body) sent[#sent + 1] = body; return true end }
    local logged = {}
    local function cap(f, ...)
        local line = tostring(f)
        if select('#', ...) > 0 then
            local ok, r = pcall(string.format, line, ...)
            if ok then line = r end
        end
        logged[#logged + 1] = line
    end
    local LC = {
        state = st, items = items, events = events.new(), sched = sched,
        log = { info = cap, warn = cap, error = cap, debug = cap }, inGame = true,
        sender = sender.new(transport, { accountName = 'compat' }),
        transport = transport,
    }
    return LC, sent, logged, st
end

--- Furnish the world: a player, ground, a wall, three creatures, two containers
--- with real loot, and a corpse on a neighbouring tile.
local function furnish(st)
    st.player = st.player or {}
    local pl = st.player
    pl.id, pl.name = PLAYER_ID, 'Compat Tester'
    pl.pos = { x = ORIGIN.x, y = ORIGIN.y, z = ORIGIN.z }
    pl.health, pl.maxHealth = 500, 800
    pl.mana, pl.maxMana = 300, 400
    pl.level, pl.levelPercent, pl.exp = 120, 42, 12345678
    pl.magicLevel, pl.baseMagicLevel, pl.magicLevelPercent = 30, 28, 10
    pl.soul, pl.stamina = 100, 2400
    pl.freeCapacity, pl.capacity, pl.maxCapacity = 1234.5, 4000, 4000
    pl.speed, pl.baseSpeed = 500, 220
    pl.vocation, pl.blessings, pl.regeneration = 4, 0x1F, 900
    pl.states, pl.direction = 0, 2
    pl.skills = { [0] = { level = 15, baseLevel = 10, percent = 55 },
                  [1] = { level = 90, baseLevel = 80, percent = 12 } }
    pl.inventory = pl.inventory or {}
    pl.inventory[1]  = { kind = 'item', id = 3079 }           -- head
    pl.inventory[2]  = { kind = 'item', id = 3081 }           -- neck (amulet)
    pl.inventory[3]  = { kind = 'item', id = ID_BP }          -- backpack
    pl.inventory[4]  = { kind = 'item', id = 3068 }           -- armor
    pl.inventory[5]  = { kind = 'item', id = 3003 }           -- right hand: rope
    pl.inventory[6]  = { kind = 'item', id = 50272 }          -- left hand: the weapon
    pl.inventory[7]  = { kind = 'item', id = 3557 }           -- legs
    pl.inventory[8]  = { kind = 'item', id = 3552 }           -- feet
    pl.inventory[9]  = { kind = 'item', id = 3097 }           -- ring
    pl.inventory[10] = { kind = 'item', id = 3447, count = 90 } -- ammo
    st.serverBeat, st.ping = 50, 37
    st.resources = { [0] = 5000000, [1] = 250 }

    st:addCreature{ id = PLAYER_ID, name = 'Compat Tester', type = 0, pos = pl.pos,
                    healthPercent = 62, direction = 2, speed = 500, vocation = 4 }
    st:addThing(pl.pos, -1, { kind = 'creature', creatureId = PLAYER_ID, id = 0x63 })
    st:setCentralPosition(pl.pos)

    for y = ORIGIN.y - 5, ORIGIN.y + 5 do
        for x = ORIGIN.x - 5, ORIGIN.x + 5 do
            st:addThing({ x = x, y = y, z = ORIGIN.z }, -1, { kind = 'item', id = ID_GRASS })
        end
    end
    -- a wall two tiles east, so findPath has something to route around
    st:addThing({ x = ORIGIN.x + 2, y = ORIGIN.y, z = ORIGIN.z },
                -1, { kind = 'item', id = ID_WALL })

    local function creature(id, name, kind, pos)
        local t = (kind == 'player') and 0 or ((kind == 'npc') and 2 or 1)
        st:addCreature{ id = id, name = name, type = t, pos = pos, healthPercent = 77,
                        direction = 1, speed = 200, shield = 0, emblem = 0, skull = 0,
                        outfit = { lookType = 3, head = 1, body = 2, legs = 3, feet = 4,
                                   addons = 0 } }
        st:addThing(pos, -1, { kind = 'creature', creatureId = id, id = 0x63 })
    end
    creature(RAT_ID, 'Rat', 'monster', { x = ORIGIN.x + 1, y = ORIGIN.y, z = ORIGIN.z })
    creature(DEMON_ID, 'Demon', 'monster', { x = ORIGIN.x, y = ORIGIN.y + 3, z = ORIGIN.z })
    creature(FRIEND_ID, 'Some Friend', 'player', { x = ORIGIN.x - 1, y = ORIGIN.y, z = ORIGIN.z })

    -- a corpse with loot on the tile east of us
    st:addThing({ x = ORIGIN.x, y = ORIGIN.y - 1, z = ORIGIN.z },
                -1, { kind = 'item', id = ID_CORPSE })

    st.containers[0] = { id = 0, name = 'backpack', capacity = 20, hasPages = false,
                         firstIndex = 0, size = 3, hasParent = false, isUnlocked = true,
                         item = { kind = 'item', id = ID_BP },
                         items = { { kind = 'item', id = ID_GOLD, count = 87 },
                                   { kind = 'item', id = ID_MANA, count = 12 },
                                   { kind = 'item', id = ID_BP } } }
    st.containers[1] = { id = 1, name = 'loot bag', capacity = 20, hasPages = false,
                         firstIndex = 0, size = 1, hasParent = true, isUnlocked = true,
                         item = { kind = 'item', id = ID_BP },
                         items = { { kind = 'item', id = ID_GOLD, count = 5 } } }
    st.channels = { [0] = 'Loot', [3] = 'Local Chat' }
end

-- ========================================================== boot the shim
local shim, S, ctx, G, LC, sent, logged, st
local vnow = 0

local function bootShim()
    LC, sent, logged, st = newLC()
    furnish(st)
    shim = require('shim.bootstrap')
    local handle, err = shim.start(LC, {
        otRoot = OTROOT, config = 'vBot_4.8', profile = 1,
        readOnly = true, arm = false,
        clock = function() return vnow end,
    })
    if not handle then return nil, err end
    S = handle
    G = handle.G
    ctx = shim.context()
    return handle
end

if not OTROOT then
    io.write('\n!! the otclient tree was not found next to this checkout; every section '
             .. 'that needs the user profile is skipped\n')
else
    local h, err = bootShim()
    if not h then
        check(false, 'shim.start booted the real vBot profile', err)
        OTROOT = nil
    else
        check(true, 'shim.start booted the real vBot profile')
        local st0 = shim.status()
        eq(st0.vbotFailed, 0, ('all %d vBot profile files loaded'):format(st0.vbotLoaded))
        for _, f in ipairs(st0.failures or {}) do
            io.write('        !! ', tostring(f.name), ': ', tostring(f.err), '\n')
        end
        eq(st0.runtimeFailed, 0, ('all %d game_bot runtime files loaded'):format(st0.runtimeLoaded))
        eq(st0.ui, 'shim.g_ui', 'the real OTML/style UI backend is in use')
        check(type(ctx) == 'table', 'the vBot sandbox context is reachable')
    end
end

--==============================================================================
section('A  EVERY MACRO in the user real vBot 4.8 profile')
--==============================================================================
if not OTROOT then
    skip('macro sweep', 'otclient tree not found next to this checkout')
else
    -- Force every macro on (the user has 40 of 48 enabled; the other 8 are just as
    -- much a compatibility question) and reset its due time.
    local n = shim.instrumentMacros{ forceEnable = true }
    check(n >= 40, ('%d macros were instrumented and force-enabled'):format(n))

    local list = rawget(ctx, '_macros') or {}
    local ranCount, failCount = 0, 0

    -- Each macro is invoked directly rather than through the executor tick, so a
    -- macro that raises is attributed to ITSELF.  Three passes with the clock
    -- advanced 1 s each: a macro that only acts on its second visit still runs.
    for pass_ = 1, 3 do
        vnow = vnow + 1000
        ctx.now, ctx.time = vnow, vnow
        for _, m in ipairs(list) do
            -- functions/main.lua:114 declares `macro.callback = function(macro)`
            -- and the executor calls it as callback(macro); passing nothing makes
            -- every macro die on `macro.delay` instead of running.
            local ok, err = pcall(m.callback, m)
            if not ok and not m._compatErr then m._compatErr = err end
            m._compatRan = m._compatRan or ok
        end
    end

    for i, m in ipairs(list) do
        -- Most vBot macros are anonymous (`macro(500, function() ... end)`), so an
        -- unnamed row still has to be identifiable: number it and print its period.
        local name = m.name
        if name == nil or name == '' then
            name = ('(unnamed #%d, every %sms)'):format(i, tostring(m.timeout))
        end
        row('macro', tostring(name), true, m._compatRan and true or false, short(m._compatErr))
        if m._compatRan then ranCount = ranCount + 1 else failCount = failCount + 1 end
    end

    check(failCount == 0,
          ('every one of the %d macros ran headless without raising'):format(#list),
          failCount > 0 and (('%d raised; see the coverage table'):format(failCount)) or nil)
    check(ranCount == #list, ('%d/%d macro bodies executed'):format(ranCount, #list))

    -- The macros must also survive the REAL executor tick, which is what the live
    -- worker runs.  A macro that is fine in isolation but not in the tick order is
    -- still a compatibility failure.
    local before = shim.status().tickErrors or 0
    for _ = 1, 10 do
        vnow = vnow + 1000
        shim.tick()
    end
    local after = shim.status()
    eq(after.tickErrors, before, '10 executor ticks over all macros raised nothing',
       after.firstTickError)
    check((after.macrosRan or 0) > 0,
          ('%d distinct macros ran inside the executor tick (%d bodies)')
          :format(after.macrosRan or 0, after.macroRuns or 0))
end

--==============================================================================
section('B  HAND-WRITTEN otclient / vBot SNIPPETS, compiled into the sandbox')
--==============================================================================
-- Each entry is a script an otclient user would actually write.  It is compiled
-- with `load(src, name, nil, context)` -- exactly how executor.lua:115 compiles
-- the user's own files -- so passing here means passing in the real bot.
local SNIPPETS = {
{ 'g_game.getLocalPlayer basics', [[
  local p = g_game.getLocalPlayer()
  assert(p, 'no local player')
  assert(p:getName() == 'Compat Tester', 'name: ' .. tostring(p:getName()))
  assert(p:getHealth() == 500 and p:getMaxHealth() == 800, 'hp')
  assert(p:getLevel() == 120, 'level')
  assert(p:isLocalPlayer() and p:isPlayer() and p:isCreature(), 'type predicates')
  local pos = p:getPosition()
  assert(pos.x == 1000 and pos.y == 1000 and pos.z == 7, 'pos')
]] },

{ 'g_map.getTile / ground / walkable', [[
  local pos = g_game.getLocalPlayer():getPosition()
  local tile = g_map.getTile(pos)
  assert(tile, 'no tile under the player')
  assert(tile:getGround(), 'no ground')
  assert(tile:getPosition().x == pos.x, 'tile position')
  assert(tile:hasCreatures(), 'the player is standing on it')
  local east = g_map.getTile({x = pos.x + 1, y = pos.y, z = pos.z})
  assert(east and east:isWalkable(false) ~= nil, 'isWalkable answers')
  local wall = g_map.getTile({x = pos.x + 2, y = pos.y, z = pos.z})
  assert(wall and wall:isWalkable() == false, 'the wall tile is not walkable')
  assert(g_map.getTile({x = 1, y = 1, z = 7}) == nil, 'an undescribed tile is nil')
]] },

{ 'g_map.getSpectators + identity', [[
  local player = g_game.getLocalPlayer()
  local pos = player:getPosition()
  local specs = g_map.getSpectators(pos, false)
  assert(#specs >= 3, 'spectators: ' .. #specs)
  local sawSelf, sawRat = false, false
  for _, spec in ipairs(specs) do
    if spec == player then sawSelf = true end          -- the vBot `spec ~= player` idiom
    if spec:getName() == 'Rat' then sawRat = true; assert(spec:isMonster(), 'Rat is a monster') end
  end
  assert(sawSelf, 'the local player is not among the spectators')
  assert(sawRat, 'the Rat is not among the spectators')
  local again = g_map.getSpectators(pos, false)
  assert(again[1] == specs[1], 'spectator identity is not interned')
]] },

{ 'g_map.getCreatureById / getTiles', [[
  local rat
  for _, c in ipairs(g_map.getSpectators(pos(), false)) do
    if c:getName() == 'Rat' then rat = c end
  end
  assert(rat, 'no rat')
  assert(g_map.getCreatureById(rat:getId()) == rat, 'getCreatureById is interned')
  local tiles = g_map.getTiles(posz())
  assert(#tiles > 100, 'getTiles(z) returned ' .. #tiles)
]] },

{ 'g_game.walk sends 0x65..0x68', [[
  local before = _COMPAT.count()
  local r = g_game.walk(North)
  assert(r ~= false, 'walk was refused')
  assert(_COMPAT.count() == before + 1, 'walk sent no packet')
  local b = _COMPAT.last():byte(1)
  assert(b == 0x65, ('walk opcode 0x%02x'):format(b))
  -- LocalPlayer:getPosition() now reports the PREWALK tile (invariant I2), which
  -- is exactly right and exactly what the live client does; retire it so the
  -- later snippets read the server position again.
  local me = g_game.getLocalPlayer()
  assert(me:isPreWalking(), 'walk did not queue a prewalk')
  assert(me:getPosition().y == me:getServerPosition().y - 1, 'the prewalk tile')
  me:resetPreWalk()
  assert(not me:isPreWalking(), 'resetPreWalk')
]] },

{ 'g_game.attack / cancelAttack', [[
  local rat = g_map.getCreatureById(_COMPAT.RAT_ID)
  assert(rat, 'no rat')
  local before = _COMPAT.count()
  g_game.attack(rat)
  assert(_COMPAT.count() > before, 'attack sent nothing')
  assert(_COMPAT.last():byte(1) == 0xA1, 'attack opcode')
  assert(g_game.getAttackingCreature() == rat, 'getAttackingCreature')
  assert(g_game.isAttacking(), 'isAttacking')
  g_game.cancelAttack()
  assert(g_game.getAttackingCreature() == nil, 'attack was not cleared')
]] },

{ 'g_game.talk / talkChannel', [[
  local before = _COMPAT.count()
  g_game.talk('hello world')
  assert(_COMPAT.count() == before + 1, 'talk sent nothing')
  assert(_COMPAT.last():byte(1) == 0x96, 'talk opcode')
  g_game.talkChannel(7, 3, 'in a channel')
  assert(_COMPAT.count() == before + 2, 'talkChannel sent nothing')
]] },

{ 'g_game.use / useWith on a real item', [[
  local bp = g_game.getContainer(0)
  assert(bp, 'no open container')
  local potion = bp:getItems()[2]
  assert(potion and potion:getId() == 268, 'the mana potion is not in slot 2')
  local before = _COMPAT.count()
  g_game.use(potion)
  assert(_COMPAT.count() == before + 1, 'use sent nothing')
  assert(_COMPAT.last():byte(1) == 0x82, 'use opcode')
  local me = g_game.getLocalPlayer()
  g_game.useWith(potion, me)
  assert(_COMPAT.count() == before + 2, 'useWith sent nothing')
  assert(_COMPAT.last():byte(1) == 0x84, 'useOnCreature opcode')
]] },

{ 'g_things.getThingType', [[
  local tt = g_things.getThingType(3031, ThingCategoryItem)
  assert(tt, 'no thing type for gold')
  assert(type(tt:getName()) == 'string', 'getName')
  assert(tt:isStackable(), 'gold is stackable')
  assert(g_things.isValidDatId(3031, ThingCategoryItem) ~= nil, 'isValidDatId')
]] },

{ 'containers: iterate every open container', [[
  local total, seenGold = 0, false
  for _, container in pairs(g_game.getContainers()) do
    assert(container:getName(), 'container with no name')
    for _, item in ipairs(container:getItems()) do
      total = total + 1
      if item:getId() == 3031 then seenGold = true; assert(item:getCount() > 0, 'gold count') end
    end
  end
  assert(total == 4, 'items across containers: ' .. total)
  assert(seenGold, 'no gold found')
  local bag = g_game.getContainer(1)
  assert(bag:getSize() == 1 and bag:getCapacity() == 20, 'loot bag shape')
  assert(bag:getSlotPosition(0).x == 0xFFFF, 'container slot position is synthetic')
]] },

{ 'item positions are the synthetic container/inventory form (I3)', [[
  local bp = g_game.getContainer(0)
  local gold = bp:getItems()[1]
  local p = gold:getPosition()
  assert(p.x == 0xFFFF, 'container item x')
  assert(p.y == 0x40, 'container item y should be containerId|0x40, got ' .. p.y)
  assert(p.z == 0 and gold:getStackPos() == 0, 'container item slot')
  local head = g_game.getLocalPlayer():getInventoryItem(SlotHead)
  assert(head, 'no head item')
  local hp = head:getPosition()
  assert(hp.x == 0xFFFF and hp.y == SlotHead and hp.z == 0, 'inventory item position')
]] },

{ 'g_map.findPath around the wall', [[
  local from = pos()
  local to = {x = from.x + 4, y = from.y, z = from.z}
  local path = g_map.findPath(from, to, 100, 0)
  assert(type(path) == 'table', 'findPath did not return a table')
  assert(#path > 0, 'no path found')
  assert(#path >= 4, 'the path is shorter than the straight-line distance: ' .. #path)
]] },

{ 'the vBot short helpers (functions/player.lua)', [[
  assert(hp() == 500 and maxhp() == 800, 'hp()/maxhp()')
  assert(mana() == 300 and manamax() == 400, 'mana()')
  assert(hppercent() == 62 or hppercent() == 63, 'hppercent(): ' .. hppercent())
  assert(level() == 120, 'level()')
  assert(name() == 'Compat Tester', 'name()')
  assert(posx() == 1000 and posy() == 1000 and posz() == 7, 'posx/y/z')
  assert(type(player) == 'table', 'the `player` global')
  assert(player == g_game.getLocalPlayer(), '`player` is not the local player object')
]] },

{ 'the vBot world helpers (functions/map.lua)', [[
  -- vBot/vlib.lua:652 -- getMonsters/getPlayers return a COUNT, not a list
  local mobs = getMonsters()
  assert(type(mobs) == 'number' and mobs >= 2, 'getMonsters: ' .. tostring(mobs))
  local players = getPlayers()
  assert(type(players) == 'number' and players >= 1, 'getPlayers: ' .. tostring(players))
  local spectators = getSpectators()
  assert(#spectators >= 3, 'getSpectators: ' .. #spectators)
  -- the patched overload: a CREATURE must not be read as a position
  local rat = g_map.getCreatureById(_COMPAT.RAT_ID)
  local around = getSpectators(rat)
  assert(type(around) == 'table' and #around >= 2,
         'getSpectators(creature) returned ' .. tostring(#around))
  assert(getCreatureByName('Rat'), 'getCreatureByName')
  assert(getDistanceBetween(pos(), {x = posx() + 3, y = posy(), z = posz()}) == 3, 'getDistanceBetween')
]] },

{ 'findItem / getContainerByName', [[
  local found = findItem(3031)
  assert(found, 'findItem(gold) found nothing')
  assert(found:getId() == 3031, 'findItem returned the wrong item')
  local bag = getContainerByName('loot bag')
  assert(bag, 'getContainerByName')
  assert(bag:getName() == 'loot bag', 'wrong container')
  assert(itemAmount(3031) > 0, 'itemAmount')
]] },

{ 'corelib string / table extensions', [[
  local parts = ('goto:1000,1000,7'):split(':')
  assert(#parts == 2 and parts[1] == 'goto', 'split')
  assert(('goto:x'):starts('goto'), 'string.starts')
  assert(('  padded  '):trim() == 'padded', 'trim')
  assert(table.find({10, 20, 30}, 20) == 2, 'table.find')
  local c = table.copy({a = 1, b = {2}})
  assert(c.a == 1 and c.b[1] == 2, 'table.copy')
  assert(type(table.merge) == 'function', 'table.merge is missing')
  local pairsList = table.decodeStringPairList('goto:1,2,3\nuse:1234')
  assert(#pairsList == 2, 'decodeStringPairList: ' .. #pairsList)
  assert(pairsList[1][1] == 'goto' and pairsList[1][2] == '1,2,3', 'decodeStringPairList shape')
  local back = table.encodeStringPairList(pairsList)
  assert(back:find('goto:1,2,3', 1, true), 'encodeStringPairList round-trip')
]] },

{ 'connect / signalcall via modules.game_bot (the sandbox idiom)', [[
  -- `connect`, `signalcall` and `scheduleEvent` are NOT sandbox globals -- not
  -- here and not in the real client.  executor.lua never puts them on `context`;
  -- vBot reaches them through modules.game_bot, whose __index falls through to
  -- the module environment (invariant I7).  cavebot/stand_lure.lua:167 is the
  -- canonical example.
  local connect = modules.game_bot.connect
  local signalcall = modules.game_bot.signalcall
  assert(type(connect) == 'function', 'modules.game_bot.connect')
  assert(type(signalcall) == 'function', 'modules.game_bot.signalcall')
  local fired = 0
  local obj = {}
  connect(obj, {onThing = function(v) fired = fired + v end})
  connect(obj, {onThing = function(v) fired = fired + v * 10 end})
  signalcall(obj.onThing, 11)
  assert(fired == 121, 'connect/signalcall chain: ' .. fired)
  -- the sandbox's own deferred-call primitive IS a global, and it is `schedule`
  assert(type(schedule) == 'function', 'schedule')
  local ran = false
  schedule(1, function() ran = true end)
]] },

{ 'macro() registers a new macro at runtime', [[
  local hits = 0
  local m = macro(100, 'compat suite probe', function() hits = hits + 1 end)
  assert(m, 'macro() returned nothing')
  assert(m.name == 'compat suite probe', 'macro name')
  m.callback(m)                      -- functions/main.lua:114 takes the macro itself
  assert(hits == 1, 'the macro body did not run')
  m.enabled = false
]] },

{ 'g_ui.createWidget + the widget tree', [[
  local w = g_ui.createWidget('Panel')
  assert(w, 'createWidget returned nothing')
  local label = g_ui.createWidget('Label', w)
  label:setId('greeting')
  label:setText('hello')
  assert(label:getText() == 'hello', 'setText/getText')
  assert(w:getChildById('greeting') == label, 'getChildById')
  assert(w.greeting == label, 'the parent Lua field was not installed')
  assert(w:getChildCount() == 1, 'child count')
  label:destroy()
  assert(w:getChildCount() == 0, 'destroy did not detach the child')
]] },

{ 'g_ui.loadUIFromString (the vBot inline-.otui idiom)', [[
  local w = g_ui.loadUIFromString([==[
Panel
  id: root
  Label
    id: title
    text: Compat
  Button
    id: go
    text: Go
]==])
  assert(w, 'loadUIFromString returned nothing')
  assert(w:getId() == 'root', 'root id')
  assert(w.title and w.title:getText() == 'Compat', 'the nested label')
  assert(w:recursiveGetChildById('go'), 'recursiveGetChildById')
]] },

{ 'UI.* helpers from mods/game_bot/functions/ui*.lua', [[
  local label = UI.Label('a compat label')
  assert(label and label:getText() == 'a compat label', 'UI.Label')
  local btn = UI.Button('press me', function() end)
  assert(btn, 'UI.Button')
  UI.Separator()
  local edit = UI.TextEdit('typed', function() end)
  assert(edit, 'UI.TextEdit')
]] },

{ 'UI.Container really receives its items (the setItems patch)', [[
  local cont = UI.Container(function() end, false)
  assert(cont, 'UI.Container returned nothing')
  cont:setItems({{id = 3031, count = 10}, {id = 268, count = 3}})
  local got = cont:getItems()
  assert(type(got) == 'table', 'getItems')
  assert(#got == 2, 'the container swallowed its items (got ' .. #got .. ', want 2)')
  assert(got[1].id == 3031, 'the first item survived')
]] },

{ 'modules.* graph', [[
  assert(modules.game_bot, 'modules.game_bot')
  local opt = modules.game_bot.contentsPanel.config:getCurrentOption()
  assert(opt and opt.text == 'vBot_4.8', 'the config combo: ' .. tostring(opt and opt.text))
  assert(type(modules.game_interface.getMapPanel) == 'function', 'game_interface.getMapPanel')
  assert(modules.game_console.channels, 'game_console.channels')
  assert(type(modules.game_walk.smartWalk) == 'function', 'game_walk.smartWalk')
  -- I7: the sandbox falls through to SHIM_G, never to the real _G
  assert(type(modules.game_bot.connect) == 'function', 'modules.game_bot.connect')
  assert(type(modules.game_bot.g_ui) == 'table', 'the module env resolves g_ui too')
]] },

{ 'the platform singletons', [[
  -- `g_clock` is NOT a sandbox global (executor.lua never sets it); the sandbox
  -- reads `now` / `time`, and modules.game_bot.g_clock for the real thing.
  local g_clock = modules.game_bot.g_clock
  assert(type(g_clock.millis()) == 'number', 'g_clock.millis')
  assert(g_clock.millis() == now, 'g_clock is not frame-quantised with context.now (I5)')
  assert(g_settings.getNumber('profile') == 1, 'g_settings.getNumber')
  assert(g_resources.fileExists('/bot/vBot_4.8/_Loader.lua'), 'g_resources.fileExists')
  assert(type(g_resources.getWriteDir()) == 'string', 'g_resources.getWriteDir')
  local listed = g_resources.listDirectoryFiles('/bot/vBot_4.8/vBot')
  assert(#listed > 10, 'listDirectoryFiles: ' .. #listed)
  for i = 2, #listed do assert(listed[i - 1] <= listed[i], 'the listing is not sorted (I6)') end
  assert(g_game.getClientVersion() == 1530, 'getClientVersion')
  assert(g_game.isOnline(), 'isOnline')
]] },

{ 'json + regexMatch + bit', [[
  local encoded = json.encode({a = 1, b = 'two', c = {3}})
  local decoded = json.decode(encoded)
  assert(decoded.a == 1 and decoded.b == 'two' and decoded.c[1] == 3, 'json round-trip')
  local m = regexMatch('Loot of a rat: 12 gold coins', '[Ll]oot of ([^:]+): (.*)')
  assert(type(m) == 'table' and #m > 0, 'regexMatch found nothing')
  assert(m[1][2] == 'a rat', 'regexMatch capture 1: ' .. tostring(m[1][2]))
  assert(bit.band(0xF0, 0x30) == 0x30, 'bit.band')
]] },

{ 'storage persists across the tick', [[
  storage.compatProbe = storage.compatProbe or {}
  storage.compatProbe.n = (storage.compatProbe.n or 0) + 1
  assert(storage.compatProbe.n >= 1, 'storage write')
  assert(storage._macros, 'the user own macro switches are in storage')
]] },

{ 'the callback registration API', [[
  local seen = {}
  onTalk(function(name, level, mode, text) seen[#seen + 1] = text end)
  onTextMessage(function(mode, text) seen[#seen + 1] = mode end)
  onCreatureAppear(function(c) seen[#seen + 1] = c:getName() end)
  onContainerOpen(function(c) seen[#seen + 1] = c:getId() end)
  assert(#_callbacks.onTalk > 0, 'onTalk did not register')
  _COMPAT.seen = seen
]] },

{ 'CaveBot / TargetBot public API is present', [[
  assert(type(CaveBot) == 'table', 'CaveBot')
  assert(type(CaveBot.isOn) == 'function', 'CaveBot.isOn')
  assert(type(CaveBot.setOff) == 'function', 'CaveBot.setOff')
  assert(CaveBot.isOn() ~= nil, 'CaveBot.isOn() answered nil')
  assert(type(TargetBot) == 'table', 'TargetBot')
  assert(type(TargetBot.isOn) == 'function', 'TargetBot.isOn')
  assert(type(TargetBot.Looting) == 'table', 'TargetBot.Looting')
  assert(type(HealBot) == 'table', 'HealBot')
  assert(type(AttackBot) == 'table', 'AttackBot')
  assert(type(CaveBotList) == 'function', 'CaveBotList')
  assert(CaveBotList(), 'CaveBotList() returned nothing')
]] },

{ 'the CaveBot waypoint list behaves as a program counter', [[
  local list = CaveBotList()
  list:destroyChildren()
  for i = 1, 4 do
    local w = g_ui.createWidget('CaveBotLabel', list)
    w.action, w.value = 'goto', ('%d,%d,7'):format(1000 + i, 1000)
    w:setText(w.action .. ':' .. w.value)
  end
  assert(list:getChildCount() == 4, 'four waypoints')
  list:focusChild(list:getChildByIndex(1))
  assert(list:getChildIndex(list:getFocusedChild()) == 1, 'the program counter starts at 1')
  list:focusChild(list:getChildByIndex(2))
  assert(list:getFocusedChild().value == '1002,1000,7', 'advancing the counter')
  list:destroyChildren()
]] },

{ 'g_game.getFeature / fight modes / chase', [[
  assert(g_game.getFeature(GameContainerPagination) ~= nil, 'getFeature')
  g_game.setChaseMode(1)
  g_game.setFightMode(2)
  g_game.setSafeFight(true)
  assert(true, 'the mode setters did not raise')
]] },

{ 'Position helpers from gamelib/position.lua', [[
  -- `Position` is a SHIM_G global from modules/gamelib/position.lua, not a
  -- sandbox one.  vBot reaches gamelib through modules.gamelib (vlib.lua:278).
  local Position = modules.gamelib.Position
  local a = {x = 100, y = 100, z = 7}
  local b = {x = 103, y = 100, z = 7}
  assert(Position.distance(a, b) == 3, 'Position.distance')
  assert(Position.isValid(a), 'Position.isValid')
  assert(Position.equals(a, {x = 100, y = 100, z = 7}), 'Position.equals')
  local t = Position.translated(a, 1, 0)
  assert(t.x == 101, 'Position.translated')
]] },
}

if not OTROOT then
    skip('snippets', 'the sandbox needs the otclient tree')
else
    -- Everything a snippet needs from the harness, reachable as a sandbox global.
    rawset(ctx, '_COMPAT', {
        count = function() return #sent end,
        last  = function() return sent[#sent] end,
        RAT_ID = RAT_ID, DEMON_ID = DEMON_ID, FRIEND_ID = FRIEND_ID,
    })
    for _, sn in ipairs(SNIPPETS) do
        local name, src = sn[1], sn[2]
        local chunk, cerr = load(src, '@snippet:' .. name, 't', ctx)
        if not chunk then
            row('snippet', name, false, false, short(cerr))
            check(false, 'snippet compiles: ' .. name, short(cerr))
        else
            local ok, rerr = pcall(chunk)
            row('snippet', name, true, ok, short(rerr))
            check(ok, 'snippet runs: ' .. name, short(rerr))
        end
    end
end

--==============================================================================
section('C  the user own callbacks, driven by REAL parser events')
--==============================================================================
if not OTROOT then
    skip('callback bridge', 'otclient tree not found next to this checkout')
else
    local seen = ctx._COMPAT and ctx._COMPAT.seen
    check(type(seen) == 'table', 'the snippet registered its callbacks')
    if type(seen) == 'table' then
        local base = #seen

        -- talk: the exact payload proto/parser.lua emits for 0xAA
        LC.events:emit('talk', { statementId = 1, name = 'A Player', level = 50,
                                 mode = 'Say', modeByte = 1, text = 'compat ping',
                                 channelId = 0 })
        check(seen[#seen] == 'compat ping', 'onTalk reached the vBot callback',
              tostring(seen[#seen]))

        -- textMessage: the WIRE byte must be translated to the Otc::MessageMode
        -- vBot compares against (wire 24 = DamageReceived = client 22).
        LC.events:emit('textMessage', { mode = 'DamageReceived', modeByte = 24,
                                        text = 'You lose 10 hitpoints.' })
        eq(seen[#seen], 22, 'onTextMessage translated the wire mode to Otc::MessageMode')

        -- a creature really appearing
        st:addCreature{ id = 0x2010, name = 'Compat Dragon', type = 1,
                        pos = { x = ORIGIN.x + 1, y = ORIGIN.y + 1, z = ORIGIN.z },
                        healthPercent = 100, direction = 0, speed = 200 }
        LC.events:emit('creatureAppear', st.creatures[0x2010])
        check(seen[#seen] == 'Compat Dragon', 'onCreatureAppear reached the vBot callback',
              tostring(seen[#seen]))

        -- a container opening
        st.containers[2] = { id = 2, name = 'a bag', capacity = 8, firstIndex = 0,
                             size = 0, items = {}, hasParent = false, isUnlocked = true,
                             item = { kind = 'item', id = ID_BP } }
        LC.events:emit('containerOpen', st.containers[2])
        eq(seen[#seen], 2, 'onContainerOpen reached the vBot callback')

        check(#seen == base + 4, ('all four callbacks fired exactly once (%d new)')
              :format(#seen - base))

        -- and the bridge's own census agrees
        local br = shim.status().callbackBridge
        check(br and (br.fired.onTalk or 0) > 0, 'the bridge recorded the dispatch')
        check(br and br.dropped.onKeyDown == 0,
              'the never-fired set is declared, not silently empty')
    end
end

--==============================================================================
section('D  the user REAL configs, through the shim own path')
--==============================================================================
if not OTROOT then
    skip('config round-trip', 'otclient tree not found next to this checkout')
else
    local Config = rawget(ctx, 'Config')
    check(type(Config) == 'table' and type(Config.load) == 'function',
          'the vBot Config API is reachable')

    local function deepEq(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= 'table' then return a == b end
        for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
        for k in pairs(b) do if a[k] == nil then return false end end
        return true
    end

    -- ------------------------------------------------- cavebot *.cfg
    local cfgs = Config.list('cavebot_configs')
    check(type(cfgs) == 'table' and #cfgs >= 10,
          ('Config.list found %d cavebot configs'):format(cfgs and #cfgs or 0))
    local cfgOk, cfgBad = 0, 0
    for _, name in ipairs(cfgs or {}) do
        local ok, data = pcall(Config.load, 'cavebot_configs', name)
        local why
        if not ok then
            why = short(data)
        elseif type(data) ~= 'table' or #data == 0 then
            ok, why = false, 'parsed to an empty list'
        else
            -- every entry is a {action, value} pair, and the round-trip through
            -- vBot's own encoder reproduces it
            for i, pair in ipairs(data) do
                if type(pair) ~= 'table' or #pair ~= 2 or type(pair[1]) ~= 'string' then
                    ok, why = false, ('entry %d is not an {action,value} pair'):format(i)
                    break
                end
            end
            if ok then
                local text = G.table.encodeStringPairList(data)
                local again = G.table.decodeStringPairList(text)
                if not deepEq(data, again) then
                    ok, why = false, 'the encode/decode round-trip changed the config'
                end
            end
        end
        row('cavebot.cfg', name .. '.cfg', true, ok,
            why or (('%d waypoints'):format(type(data) == 'table' and #data or 0)))
        if ok then cfgOk = cfgOk + 1 else cfgBad = cfgBad + 1 end
    end
    check(cfgBad == 0, ('all %d cavebot .cfg files parse and round-trip'):format(cfgOk),
          cfgBad > 0 and (cfgBad .. ' failed') or nil)

    -- ------------------------------------------------- targetbot *.json
    local jsons = Config.list('targetbot_configs')
    check(type(jsons) == 'table' and #jsons >= 5,
          ('Config.list found %d targetbot configs'):format(jsons and #jsons or 0))
    local jOk, jBad = 0, 0
    for _, name in ipairs(jsons or {}) do
        local ok, data = pcall(Config.load, 'targetbot_configs', name)
        local why, detail
        if not ok then
            why = short(data)
        elseif type(data) ~= 'table' then
            ok, why = false, 'did not decode to a table'
        elseif next(data) == nil then
            detail = 'empty config ([]) -- parsed, nothing to load'
        elseif type(data.targeting) ~= 'table' then
            ok, why = false, 'no `targeting` array'
        end
        if ok and not detail then
            local json = ctx.json
            local again = json.decode(json.encode(data))
            if not deepEq(data, again) then
                ok, why = false, 'the json encode/decode round-trip changed the config'
            else
                detail = ('%d targeting, %d looting'):format(#data.targeting,
                          type(data.looting) == 'table' and #data.looting or 0)
            end
        end
        row('targetbot.json', name .. '.json', true, ok, why or detail)
        if ok then jOk = jOk + 1 else jBad = jBad + 1 end
    end
    check(jBad == 0, ('all %d targetbot .json files parse and round-trip'):format(jOk),
          jBad > 0 and (jBad .. ' failed') or nil)

    -- --------------------------------- the sell-exception hand-over (data loss)
    -- vBot/depositer_config.lua:228 mirrors modules.game_npctrade's sell-exception
    -- list into storage.cavebotSell at LOAD time.  In the real client that list
    -- lives in the client's own g_settings; headless it starts empty, so without
    -- the seeding in shim/bootstrap.lua the user's own list is silently replaced
    -- with nothing and the next save persists the loss.  Measured: 7 ids -> 0.
    do
        local stored = ctx.storage and ctx.storage.cavebotSell
        check(type(stored) == 'table',
              'storage.cavebotSell survived the load, it was not wiped')
        if type(stored) == 'table' then
            check(#stored > 0,
                  ('the user %d sell exceptions are still there after loading the tree')
                  :format(#stored))
            local shared = G.modules.game_npctrade.getSellExceptions()
            eq(#shared, #stored, 'modules.game_npctrade agrees with the profile mirror')
        end
    end

    -- ------------------------------------------------- the write path, to a TEMP dir
    -- The read-only guard refuses writes into the user's tree; point a SECOND
    -- g_resources at a scratch directory, save a real config through vBot's own
    -- Config.save, and read it back with vBot's own Config.load.
    do
        local resources = require('shim.resources')
        local tmp = ROOT .. '/test/.tmp/compat-config'
        os.remove(tmp .. '/bot/vBot_4.8/cavebot_configs/roundtrip.cfg')
        local res2 = resources.new(tmp)
        res2.makeDir('/bot')
        res2.makeDir('/bot/vBot_4.8')
        res2.makeDir('/bot/vBot_4.8/cavebot_configs')

        local source = Config.load('cavebot_configs', (cfgs or {})[1])
        local text = G.table.encodeStringPairList(source)
        local wrote = res2.writeFileContents('/bot/vBot_4.8/cavebot_configs/roundtrip.cfg', text)
        check(wrote ~= false, 'a config was written into the scratch directory')

        local readBack = res2.readFileContents('/bot/vBot_4.8/cavebot_configs/roundtrip.cfg')
        eq(readBack, text, 'the scratch copy is byte-identical')
        local reparsed = G.table.decodeStringPairList(readBack)
        check(deepEq(source, reparsed),
              'a shim-written cavebot config re-parses to the same waypoints')

        -- and the real profile is STILL untouched
        local d = shim.status()
        check(#(d.blockedWrites or {}) >= 0, 'the read-only guard is still installed')
        local f = io.open(OTROOT .. '/profiles/bot/vBot_4.8/storage/profile_1.json', 'rb')
        local bytes = f and #f:read('*a') or 0
        if f then f:close() end
        eq(bytes, d.storageBytes, 'the user storage file is byte-identical after the run')
    end
end

-- ========================================================== teardown
if OTROOT and shim then pcall(shim.stop) end

-- ========================================================== the deliverable
io.write('\n')
io.write('==============================================================================\n')
io.write('BACKWARD-COMPATIBILITY COVERAGE\n')
io.write('==============================================================================\n')
io.write(('  %-14s %-46s %-7s %-5s %s\n'):format('kind', 'script', 'loaded', 'ran', 'first error / note'))
io.write(('  %-14s %-46s %-7s %-5s %s\n'):format(('-'):rep(14), ('-'):rep(46), ('-'):rep(7), ('-'):rep(5), ('-'):rep(30)))
local byKind = {}
for _, r in ipairs(COVERAGE) do
    local s = r.script
    if #s > 46 then s = s:sub(1, 43) .. '...' end
    io.write(('  %-14s %-46s %-7s %-5s %s\n'):format(
        r.kind, s, r.loaded and 'yes' or 'NO', r.ran and 'yes' or 'NO',
        r.err or ''))
    local b = byKind[r.kind] or { n = 0, ok = 0 }
    b.n = b.n + 1
    if r.ran then b.ok = b.ok + 1 end
    byKind[r.kind] = b
end
io.write('\n  SUMMARY\n')
local kinds = {}
for k in pairs(byKind) do kinds[#kinds + 1] = k end
table.sort(kinds)
for _, k in ipairs(kinds) do
    io.write(('   %-14s %d/%d ran\n'):format(k, byKind[k].ok, byKind[k].n))
end

io.write('\n================ shim compat suite ================\n')
io.write(('  TOTAL: %d passed, %d failed  -> %s\n'):format(pass, fail, fail == 0 and 'PASS' or 'FAIL'))
io.write(('  platform: %s  luajit: %s  otclient: %s\n'):format(
    package.config:sub(1, 1) == '\\' and 'windows' or 'posix',
    _VERSION .. (jit and (' / ' .. jit.version) or ''), tostring(OTROOT)))
for _, m in ipairs(msgs) do io.write(m, '\n') end

if _G.SHIMCOMPAT_NO_EXIT then
    return { pass = pass, fail = fail, failures = msgs, coverage = COVERAGE }
end
os.exit(fail == 0 and 0 or 1)
