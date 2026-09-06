--[==[========================================================================
test/shim_game_suite.lua -- work item S1: the game object model and the game singletons.

    luajit test/shim_game_suite.lua        (from D:/Claude/otclient_web/luaclient)
    wsl.exe -d Debian -e sh -c 'cd /mnt/d/Claude/otclient_web/luaclient && \
        luajit test/shim_game_suite.lua'

No server, no account, no otclient tree required.  Every world is built in Lua on the REAL
game/state.lua with the REAL proto/items.lua metadata, and every packet is captured off the
REAL proto/sender.lua through a fake transport -- so the synthetic-position asserts are
asserts on ACTUAL WIRE BYTES, not on the shim's own bookkeeping.

WHAT IS PROVEN HERE
  A  object identity (invariant I1) across repeated queries, and after the entity moves
  B  g_map.getTile returns NIL for an undescribed tile
  C  g_game.walk returns FALSE on refusal, and the prewalk bookkeeping (I2)
  D  every getter against a known state
  E  the three synthetic position forms (I3), round-tripped through a real g_game.move,
     a real stashStowItem and a real use, decoded back off the wire
  F  g_map.findEveryPath agrees with bot/path.lua, including the vBot string-param contract
     and vBot's own translateAllPathsToPath
  G  SIX code fragments lifted VERBATIM from the user's live vBot 4.8 profile, each quoted
     with its file and line range, asserted to produce the right calls

Set `_G.SHIMGAME_NO_EXIT = true` before dofile()ing this file and it returns
{ pass=, fail=, failures={} } instead of exiting.
==========================================================================]==]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. ROOT .. '/?/init.lua;' .. package.path
end

local items    = require('proto.items')
local state    = require('game.state')
local events   = require('lib.events')
local sender   = require('proto.sender')
local sched    = require('lib.sched')
local pathmod  = require('bot.path')
local worldmod = require('bot.world')

local objects  = require('shim.object')
local posmod   = require('shim.position')
local gamemod  = require('shim.g_game')
local mapmod   = require('shim.g_map')
local thingmod = require('shim.g_things')
local minimod  = require('shim.g_minimap')

if not items.loaded then items.load(ROOT .. '/assets/items1530.bin') end

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
end
local function eq(a, b, desc)
    ok(a == b, desc, ('got %s, want %s'):format(tostring(a), tostring(b)))
end

local function hex(s)
    local o = {}
    for i = 1, #s do o[i] = ('%02X'):format(s:byte(i)) end
    return table.concat(o, ' ')
end

-- ============================================================ world fixtures
-- item ids picked out of the real assets/items1530.bin (tools/find):
local ID_GRASS   = 103    -- ground, walkable, minimap colour 129, ground speed 110
local ID_STAIRS  = 369    -- ground + NOT_PATHABLE + minimap colour 210  (the stairs band)
local ID_WALL    = 230    -- NOT_WALKABLE + BLOCK_PROJECTILE, not a ground
local ID_GOLD    = 3031   -- stackable, common
local ID_BP      = 2854   -- backpack (container)
local ID_CORPSE  = 862    -- dead troll (container)
local ID_LADDER  = 1630   -- lensHelp 1104 -- cavebot's floor-change classifier

local PLAYER_ID  = 0x1000
local ORIGIN     = { x = 1000, y = 1000, z = 7 }

--- Build a whole client (state + events + real sender over a capturing transport + shim).
local function newHost(opts)
    opts = opts or {}
    local st = state.new()
    local bus = events.new()

    local sent = {}
    local transport = {
        dead = false,
        send = function(self, body)
            if self.dead then return nil, 'transport dead' end
            sent[#sent + 1] = body
            return true
        end,
    }
    local snd = sender.new(transport, { accountName = 'test' })

    local logged = {}
    local function cap(f, ...)
        local line = tostring(f)
        if select('#', ...) > 0 then
            local okf, r = pcall(string.format, line, ...)
            if okf then line = r end
        end
        logged[#logged + 1] = line
    end
    local log = { info = cap, warn = cap, error = cap, debug = cap }

    local LC = { state = st, items = items, events = bus, sender = snd, transport = transport,
                 log = log, sched = sched, inGame = true }

    local reg = objects.new(LC, { strict = opts.strict })
    objects.installItemFactory(reg)
    local gmini  = minimod.new(LC, reg, { known = opts.known })
    local g_map  = mapmod.new(LC, reg, { minimap = opts.known, gMinimap = gmini })
    local g_game = gamemod.new(LC, reg)
    local g_things = thingmod.new(LC, reg)

    local H = {
        st = st, bus = bus, LC = LC, reg = reg, transport = transport, sender = snd,
        sent = sent, logged = logged,
        g_map = g_map, g_game = g_game, g_things = g_things, g_minimap = gmini,
        Item = objects.Item,
    }

    function H:clear() for i = #sent, 1, -1 do sent[i] = nil end end
    function H:last() return sent[#sent] end
    function H:count() return #sent end

    -- the shared Track-B primitives, over the SAME state, for the differential asserts
    H.world = worldmod.new({ state = st, items = items, log = log, minimap = opts.known },
                           { known = opts.known })
    H.path  = pathmod.new({ state = st, items = items, log = log }, H.world)
    return H
end

--- The local player: state.player AND its creature record (the wire writes both).
local function addPlayer(H, pos, extra)
    local st = H.st
    st.player.id = PLAYER_ID
    st.player.name = 'Testchar'
    st.player.pos = { x = pos.x, y = pos.y, z = pos.z }
    st.player.health, st.player.maxHealth = 800, 1000
    st.player.mana, st.player.maxMana = 300, 600
    st.player.level, st.player.levelPercent = 120, 42
    st.player.exp = 12345678
    st.player.magicLevel, st.player.baseMagicLevel = 30, 28
    st.player.soul, st.player.stamina = 100, 2400
    st.player.freeCapacity, st.player.capacity, st.player.maxCapacity = 1234.5, 4000, 4000
    st.player.speed, st.player.baseSpeed = 500, 220
    st.player.vocation = 4                       -- VocationsClient.Druid
    st.player.blessings = 0x1F
    st.player.regeneration = 900
    st.player.states = 32 + 64                   -- IconParalyze | IconHaste
    st.player.skills = { [0] = { level = 15, baseLevel = 10, percent = 55 },
                         [1] = { level = 90, baseLevel = 80, percent = 12 } }
    st.player.virtues = { 311, 274 }             -- secondary 311, primary 274
    st.player.harmony = 3
    st.player.serene = true
    st.serverBeat = 50
    st.ping = 37
    st.resources = { [0] = 5000000, [1] = 250 }
    if extra then for k, v in pairs(extra) do st.player[k] = v end end
    st:addCreature{ id = PLAYER_ID, name = 'Testchar', type = 0, pos = pos,
                    healthPercent = 80, direction = 2, speed = 500, vocation = 4 }
    st:addThing(pos, -1, { kind = 'creature', creatureId = PLAYER_ID, id = 0x63 })
    st:setCentralPosition(pos)
    return H.g_game.getLocalPlayer()
end

--- A rectangle of walkable ground centred on ORIGIN.
local function fillGround(H, cx, cy, z, radius, id)
    for y = cy - radius, cy + radius do
        for x = cx - radius, cx + radius do
            H.st:addThing({ x = x, y = y, z = z }, -1, { kind = 'item', id = id or ID_GRASS })
        end
    end
end

local function addCreature(H, id, name, pos, kind)
    local t = (kind == 'player') and 0 or ((kind == 'npc') and 2 or 1)
    H.st:addCreature{ id = id, name = name, type = t, pos = pos, healthPercent = 77,
                      direction = 1, speed = 200, shield = (kind == 'party') and 6 or 0,
                      emblem = 0, skull = 0, outfit = { lookType = 3, head = 1, body = 2,
                                                        legs = 3, feet = 4, addons = 0 } }
    if kind == 'party' then H.st.creatures[id].isPlayer = true; H.st.creatures[id].type = 0 end
    H.st:addThing(pos, -1, { kind = 'creature', creatureId = id, id = 0x63 })
    return H.g_map.getCreatureById(id)
end

local function addContainer(H, id, name, capacity, itemList)
    H.st.containers[id] = { id = id, name = name, capacity = capacity, hasPages = false,
                            firstIndex = 0, size = #itemList, items = itemList,
                            hasParent = false, isUnlocked = true,
                            item = { kind = 'item', id = ID_BP } }
    return H.g_game.getContainer(id)
end

-- ============================================================================
-- A. object identity (invariant I1)
-- ============================================================================
S('A. object identity (I1)')
do
    local H = newHost()
    local player = addPlayer(H, ORIGIN)
    fillGround(H, ORIGIN.x, ORIGIN.y, ORIGIN.z, 4)
    local rat = addCreature(H, 5001, 'Rat', { x = ORIGIN.x + 2, y = ORIGIN.y, z = ORIGIN.z })
    addCreature(H, 5002, 'Cave Rat', { x = ORIGIN.x, y = ORIGIN.y + 2, z = ORIGIN.z })

    local s1 = H.g_map.getSpectators(ORIGIN, false)
    local s2 = H.g_map.getSpectators(ORIGIN, false)
    ok(#s1 == 3, 'getSpectators sees the player and both monsters', '#=' .. #s1)
    local sameAll = (#s1 == #s2)
    if sameAll then for i = 1, #s1 do if s1[i] ~= s2[i] then sameAll = false end end end
    ok(sameAll, 'getSpectators twice returns the SAME Lua objects, in the same order')

    -- vBot's `spec ~= player` idiom: the local player must be the SAME object in both places
    local foundPlayer = false
    for i = 1, #s1 do if s1[i] == player then foundPlayer = true end end
    ok(foundPlayer, 'the local player among the spectators IS g_game.getLocalPlayer()')

    eq(H.g_map.getCreatureById(5001), rat, 'getCreatureById is interned')
    eq(H.g_game.getLocalPlayer(), H.g_game.getLocalPlayer(), 'getLocalPlayer is a singleton')

    -- identity survives a move
    H.st:moveCreature(5001, { x = ORIGIN.x + 2, y = ORIGIN.y, z = ORIGIN.z },
                      nil, { x = ORIGIN.x + 3, y = ORIGIN.y, z = ORIGIN.z })
    eq(H.g_map.getCreatureById(5001), rat, 'creature identity survives a move')
    eq(rat:getPosition().x, ORIGIN.x + 3, 'and the wrapper reads the NEW position')

    -- tiles
    local t1 = H.g_map.getTile(ORIGIN)
    local t2 = H.g_map.getTile({ x = ORIGIN.x, y = ORIGIN.y, z = ORIGIN.z })
    eq(t1, t2, 'getTile(pos) == getTile(copyOf(pos))')
    eq(H.g_map.getTiles(ORIGIN.z)[1], H.g_map.getTiles(ORIGIN.z)[1],
       'getTiles returns the same Tile objects')

    -- things on a tile
    local i1 = t1:getItems()[1]
    local i2 = t1:getItems()[1]
    eq(i1, i2, 'tile:getItems() returns the same Item object for the same thing')
    eq(t1:getGround(), i1, 'getGround() is that same object')

    -- containers
    local c = addContainer(H, 0, 'backpack', 20, { { kind = 'item', id = ID_GOLD, count = 40 } })
    eq(H.g_game.getContainer(0), c, 'container identity per id')
    eq(c:getItems()[1], c:getItems()[1], 'container item identity')

    -- a wrapper used as a table key (vBot does this in TargetBot/looting)
    local keyed = {}
    keyed[rat] = 'seen'
    eq(keyed[H.g_map.getCreatureById(5001)], 'seen', 'wrappers work as table keys')

    -- sweep drops only what is gone
    H.st:removeCreature(5002)
    H.reg:sweep()
    eq(H.g_map.getCreatureById(5002), nil, 'a removed creature no longer resolves')
    eq(H.g_map.getCreatureById(5001), rat, 'sweep keeps a live creature interned')
end

-- ============================================================================
-- B. nil for an undescribed tile
-- ============================================================================
S('B. undescribed tiles are nil')
do
    local H = newHost()
    addPlayer(H, ORIGIN)
    fillGround(H, ORIGIN.x, ORIGIN.y, ORIGIN.z, 2)

    eq(H.g_map.getTile({ x = ORIGIN.x + 50, y = ORIGIN.y, z = ORIGIN.z }), nil,
       'getTile on a never-described tile is nil')
    eq(H.g_map.getTile({ x = ORIGIN.x, y = ORIGIN.y, z = 5 }), nil,
       'getTile on an undescribed FLOOR is nil')
    ok(H.g_map.getTile(ORIGIN) ~= nil, 'getTile on a described tile is a Tile')

    -- I4: extra arguments are tolerated (functions/map.lua:251 passes a distance)
    ok(H.g_map.getTile(ORIGIN, 5) ~= nil, 'getTile(pos, distance) tolerates the extra arg')

    -- and nil again after the tile is forgotten
    local p = { x = ORIGIN.x + 1, y = ORIGIN.y, z = ORIGIN.z }
    local before = H.g_map.getTile(p)
    ok(before ~= nil, 'neighbour described')
    H.st:cleanTile(p)
    eq(H.g_map.getTile(p), nil, 'cleanTile makes getTile nil again')
    eq(#H.g_map.getTiles(ORIGIN.z), 24, 'the floor index dropped it too (5x5 - 1)')

    -- Map::cleanTile destroys the C++ Tile, so a re-described tile is a NEW object there.
    -- Matching that is what bounds the wrapper table over a long session.
    H.st:addThing(p, -1, { kind = 'item', id = ID_GRASS })
    local after = H.g_map.getTile(p)
    ok(after ~= nil, 'the tile is back')
    ok(after ~= before, 'and it is a NEW Tile object, as in the C++ client')
    eq(after, H.g_map.getTile(p), 'which is itself interned from now on')
end

-- ============================================================================
-- C. g_game.walk refusal + prewalk (I2)
-- ============================================================================
S('C. g_game.walk refusal and prewalk')
do
    local H = newHost()
    local player = addPlayer(H, ORIGIN)
    fillGround(H, ORIGIN.x, ORIGIN.y, ORIGIN.z, 3)
    H:clear()

    eq(H.g_game.walk(8), false, 'walk(InvalidDirection) is false')
    eq(H.g_game.walk('north'), false, 'walk(non-number) is false')
    eq(H.g_game.walk(nil), false, 'walk(nil) is false')
    eq(H:count(), 0, 'no packet was sent for a refused direction')

    H.LC.inGame = false
    eq(H.g_game.walk(0), false, 'walk while offline is false')
    H.LC.inGame = true

    H.transport.dead = true
    eq(H.g_game.walk(0), false, 'walk over a dead transport is false')
    H.transport.dead = false

    -- the success path: cavebot/walking.lua:294 tests `~= false`
    local r = H.g_game.walk(2)                        -- South
    ok(r ~= false, 'a real walk does NOT return false', tostring(r))
    eq(H:count(), 1, 'exactly one packet')
    eq(H:last():byte(1), 0x67, 'and it is 0x67 WalkSouth')

    -- I2: getPosition() is now the PREWALK position
    eq(player:getPosition().y, ORIGIN.y + 1, 'LocalPlayer:getPosition() is the prewalk tile')
    eq(player:isPreWalking(), true, 'isPreWalking()')
    eq(player:getServerPosition().y, ORIGIN.y, 'the confirmed position is unchanged')
    eq(H.g_map.getCreatureById(PLAYER_ID):getPosition().y, ORIGIN.y + 1,
       'the same object answers the prewalk position through g_map too')

    -- the confirmation retires exactly one prewalk (LocalPlayer::walk, localplayer.cpp:65-79)
    H.st.player.pos = { x = ORIGIN.x, y = ORIGIN.y + 1, z = ORIGIN.z }
    H.bus:emit('positionChange', { pos = H.st.player.pos, oldPos = ORIGIN })
    eq(player:isPreWalking(), false, 'a matching confirmation pops the prewalk')
    eq(player:getPosition().y, ORIGIN.y + 1, 'and the position is the confirmed one')

    -- a NON-matching confirmation clears the whole queue
    H.g_game.walk(2)
    eq(player:isPreWalking(), true, 'prewalk queued again')
    H.st.player.pos = { x = ORIGIN.x + 5, y = ORIGIN.y + 5, z = ORIGIN.z }
    H.bus:emit('positionChange', { pos = H.st.player.pos, oldPos = ORIGIN })
    eq(player:isPreWalking(), false, 'a teleport clears every prewalk')

    -- walk never queues more than getWalkMaxSteps
    H.st.player.pos = { x = ORIGIN.x, y = ORIGIN.y, z = ORIGIN.z }
    H.g_game.resetPreWalk()
    for _ = 1, 6 do H.g_game.walk(2) end
    ok(#H.st.player.preWalks <= H.g_game.getWalkMaxSteps(),
       'the prewalk queue is capped at getWalkMaxSteps()', #H.st.player.preWalks)
    H.g_game.resetPreWalk()
    H.g_game._shutdown()
end

-- ============================================================================
-- D. getters against a known state
-- ============================================================================
S('D. getters against a known state')
do
    local H = newHost()
    local player = addPlayer(H, ORIGIN)
    fillGround(H, ORIGIN.x, ORIGIN.y, ORIGIN.z, 3)

    -- --- LocalPlayer -------------------------------------------------------
    eq(player:getName(), 'Testchar', 'getName')
    eq(player:getId(), PLAYER_ID, 'getId')
    eq(player:isLocalPlayer(), true, 'isLocalPlayer')
    eq(player:isPlayer(), true, 'isPlayer')
    eq(player:isMonster(), false, 'isMonster')
    eq(player:getHealth(), 800, 'getHealth')
    eq(player:getMaxHealth(), 1000, 'getMaxHealth')
    eq(player:getHealthPercent(), 80, 'getHealthPercent is derived from hp/maxhp')
    eq(player:getMana(), 300, 'getMana')
    eq(player:getMaxMana(), 600, 'getMaxMana')
    eq(player:getLevel(), 120, 'getLevel')
    eq(player:getExperience(), 12345678, 'getExperience')
    eq(player:getMagicLevel(), 30, 'getMagicLevel')
    eq(player:getSoul(), 100, 'getSoul')
    eq(player:getStamina(), 2400, 'getStamina')
    eq(player:getFreeCapacity(), 1234.5, 'getFreeCapacity')
    eq(player:getTotalCapacity(), 4000, 'getTotalCapacity')
    eq(player:getCapacity(), 1234.5, 'getCapacity == free capacity (documented deviation)')
    eq(player:getBlessings(), 0x1F, 'getBlessings')
    eq(player:getStates(), 96, 'getStates is the combined mask')
    eq(player:isParalyzed(), true, 'isParalyzed reads bit 32 of the mask')
    eq(player:getSkillLevel(1), 90, 'getSkillLevel')
    eq(player:getSkillBaseLevel(1), 80, 'getSkillBaseLevel')
    eq(player:getVocation(), 4, 'getVocation')
    eq(player:isDruid(), true, 'isDruid')
    eq(player:isKnight(), false, 'isKnight')
    eq(type(player:getRegenerationTime()), 'number', 'getRegenerationTime is a NUMBER (trap)')
    eq(player:getRegenerationTime(), 900, 'getRegenerationTime value')
    eq(player:getResourceBalance(0), 5000000, 'getResourceBalance(bank)')
    eq(player:getTotalMoney(), 5000250, 'getTotalMoney')
    eq(player:getHarmony(), 3, 'getHarmony')
    eq(player:isSerene(), true, 'isSerene')
    -- virtues {311, 274}: 311 goes to the SECONDARY slot, 274 becomes primary
    eq(player:getStance(), 274, 'getStance derives the primary stance')
    eq(player:getSecondaryStance(), 311, 'getSecondaryStance takes 311/312')
    eq(player:getVirtue(), 1, 'getVirtue maps 274 -> 1')
    eq(#player:getVirtues(), 2, 'getVirtues')
    eq(player:getSpeed(), 500, 'getSpeed')
    eq(player:getDirection(), 2, 'getDirection')
    eq(player:isDead(), false, 'isDead')

    -- getStepDuration must agree with bot/walker.lua's independent implementation
    local walkermod = require('bot.walker')
    local w = walkermod.new({ state = H.st, items = items, log = H.LC.log },
                            { world = H.world, path = H.path })
    local mine  = player:getStepDuration(true)
    local hers  = w:stepDuration(2)
    eq(mine, hers, 'getStepDuration(true) == bot/walker.lua stepDuration')
    ok(mine > 0, 'and it is positive', mine)

    -- --- remote creature ---------------------------------------------------
    local dragon = addCreature(H, 6001, 'Dragon', { x = ORIGIN.x + 2, y = ORIGIN.y, z = ORIGIN.z })
    eq(dragon:getName(), 'Dragon', 'creature getName')
    eq(dragon:getId(), 6001, 'creature getId')
    eq(dragon:isMonster(), true, 'creature isMonster')
    eq(dragon:isPlayer(), false, 'creature isPlayer')
    eq(dragon:isNpc(), false, 'creature isNpc')
    eq(dragon:isLocalPlayer(), false, 'creature isLocalPlayer')
    eq(dragon:getType(), 1, 'creature getType')
    eq(dragon:getHealthPercent(), 77, 'creature getHealthPercent')
    eq(dragon:getDirection(), 1, 'creature getDirection')
    eq(dragon:getSpeed(), 200, 'creature getSpeed')
    eq(dragon:getOutfit().lookType, 3, 'creature getOutfit().lookType')
    eq(dragon:getOutfit().type, 3, 'getOutfit() publishes both `type` and `lookType`')
    eq(dragon:getShield(), 0, 'creature getShield')
    eq(dragon:getEmblem(), 0, 'creature getEmblem')
    eq(dragon:getSkull(), 0, 'creature getSkull')
    eq(dragon:isPartyMember(), false, 'creature isPartyMember')
    eq(dragon:canBeSeen(), true, 'creature canBeSeen')
    eq(dragon:canShoot(5), true, 'canShoot within range and with clear sight')
    eq(dragon:canShoot(1), false, 'canShoot refuses beyond the distance')
    eq(dragon:getTile(), H.g_map.getTile({ x = ORIGIN.x + 2, y = ORIGIN.y, z = ORIGIN.z }),
       'creature getTile is the interned Tile')

    -- getPosition() is NEVER nil: every vBot site indexes it unguarded
    -- (`distanceFromPlayer(spec:getPosition())`, `target():getPosition().z`), and the C++
    -- default-constructs an INVALID Position instead.
    H.st.creatures[6001].pos = nil
    local lost = dragon:getPosition()
    ok(type(lost) == 'table', 'getPosition() on a creature with no position is still a table')
    eq(posmod.isValid(lost), false, 'and it is the INVALID position, like the C++')
    eq(dragon:getTile(), nil, 'and getTile() on it is nil')
    eq(dragon:canShoot(5), false, 'and canShoot() refuses instead of raising')
    H.st.creatures[6001].pos = { x = ORIGIN.x + 2, y = ORIGIN.y, z = ORIGIN.z }

    local mate = addCreature(H, 6002, 'Friend', { x = ORIGIN.x - 1, y = ORIGIN.y, z = ORIGIN.z }, 'party')
    eq(mate:isPartyMember(), true, 'shield 6 is a party member')
    eq(mate:isPartyLeader(), true, 'shield 6 is a party leader (ShieldYellowSharedExp)')
    eq(mate:isPlayer(), true, 'a party mate is a Player')

    -- --- Tile --------------------------------------------------------------
    local tp = { x = ORIGIN.x + 1, y = ORIGIN.y + 1, z = ORIGIN.z }
    H.st:addThing(tp, -1, { kind = 'item', id = ID_GOLD, count = 55 })
    local t = H.g_map.getTile(tp)
    eq(t:getPosition().x, tp.x, 'tile getPosition')
    eq(#t:getThings(), 2, 'tile getThings')
    eq(#t:getItems(), 2, 'tile getItems')
    eq(t:getItemsCount(), 2, 'tile getItemsCount')
    eq(t:getGround():getId(), ID_GRASS, 'tile getGround')
    eq(t:getTopThing():getId(), ID_GOLD, 'tile getTopThing is the first isCommon thing')
    eq(t:getTopUseThing():getId(), ID_GOLD, 'tile getTopUseThing')
    eq(t:isWalkable(), true, 'tile isWalkable')
    eq(t:isPathable(), true, 'tile isPathable')
    eq(t:isNotPathable(), false, 'tile isNotPathable')
    eq(t:hasCreatures(), false, 'tile hasCreatures (empty)')
    eq(t:hasCreature(), false, 'tile hasCreature alias')
    eq(t:getMinimapColorByte(), 129, 'tile getMinimapColorByte (grass)')
    eq(t:getGroundSpeed(), 110, 'tile getGroundSpeed')
    eq(t:isLookPossible(), true, 'tile isLookPossible')
    eq(t:hasElevation(), false, 'tile hasElevation')
    eq(t:canShoot(5), true, 'tile canShoot')
    eq(#t:getCreatures(), 0, 'tile getCreatures (empty)')

    local ct = H.g_map.getTile({ x = ORIGIN.x + 2, y = ORIGIN.y, z = ORIGIN.z })
    eq(ct:hasCreatures(), true, 'tile with a creature: hasCreatures')
    eq(#ct:getCreatures(), 1, 'tile getCreatures')
    eq(ct:getCreatures()[1], dragon, 'tile getCreatures returns the interned Creature')
    eq(ct:getTopCreature(), dragon, 'tile getTopCreature')
    eq(ct:isWalkable(), false, 'a tile with a blocking creature is not walkable')
    eq(ct:isWalkable(true), true, 'isWalkable(true) ignores creatures')

    -- a wall tile
    local wp = { x = ORIGIN.x - 2, y = ORIGIN.y, z = ORIGIN.z }
    H.st:addThing(wp, -1, { kind = 'item', id = ID_WALL })
    local wt = H.g_map.getTile(wp)
    eq(wt:isWalkable(), false, 'a wall tile is not walkable')
    eq(wt:isLookPossible(), false, 'a wall blocks projectiles')

    -- a stairs tile
    local sp = { x = ORIGIN.x, y = ORIGIN.y - 2, z = ORIGIN.z }
    H.st:setTile(sp, nil)
    H.st:addThing(sp, -1, { kind = 'item', id = ID_STAIRS })
    local stt = H.g_map.getTile(sp)
    eq(stt:isPathable(), false, 'the stairs ground is NOT pathable')
    eq(H.g_map.getMinimapColor(sp), 210, 'g_map.getMinimapColor sees the 210 stairs band')

    -- --- Item --------------------------------------------------------------
    local gold = t:getItems()[2]
    eq(gold:getId(), ID_GOLD, 'item getId')
    eq(gold:getCount(), 55, 'item getCount (stackable)')
    eq(gold:getCountOrSubType(), 55, 'item getCountOrSubType')
    eq(gold:getSubType(), 0, 'item getSubType is 0 at cv > 862 for a non-fluid')
    eq(gold:isStackable(), true, 'item isStackable')
    eq(gold:isContainer(), false, 'item isContainer')
    eq(gold:isPickupable(), true, 'item isPickupable')
    eq(gold:isItem(), true, 'item isItem')
    eq(gold:isCreature(), false, 'item isCreature')
    eq(gold:getTier(), 0, 'item getTier')
    eq(gold:getName(), 'gold coin', 'item getName')
    -- B3 RESOLVED.  Item::m_serverId is only ever assigned at item.cpp:273, which sits
    -- inside #ifdef FRAMEWORK_EDITOR, and src/CMakeLists.txt:12 defaults
    -- TOGGLE_FRAMEWORK_EDITOR to OFF -- so the shipped client returns the item.h:193
    -- initialiser 0 for every item while still binding the method (luafunctions.cpp:853).
    -- 0 is therefore BOTH the honest headless answer and the C++-exact one; the client id
    -- was simply wrong.
    eq(gold:getServerId(), 0, 'item getServerId is 0, like the non-editor C++ build')
    ok(gold:getMarketData() ~= nil, 'getMarketData is never nil')
    -- DECIDED deviation, api-game.md sec.4.4: `.name` falls back to items.name(id).
    -- thingtype.cpp:340-357 copies m_name into m_market.name only inside `if has_market()`,
    -- so the live client answers '' for a marketless item; the C++-exact value is kept
    -- alongside as `.marketName` and only `.name` gets the fallback.
    eq(gold:getMarketData().name, 'gold coin',
       'getMarketData().name falls back to items.name(id) for a marketless item')
    eq(gold:getMarketData().marketName, '',
       'and .marketName still carries the C++-exact empty string')
    eq(gold:getMarketData().tradeAs, ID_GOLD, 'getMarketData().tradeAs')
    eq(gold:getName(), 'gold coin', 'but getName() still has the raw appearance name')
    eq(H.Item.create(ID_BP):getMarketData().name, 'backpack',
       'getMarketData().name is the real name for an item that HAS a market block')
    local ground = t:getGround()
    eq(ground:isGround(), true, 'ground isGround')
    eq(ground:isNotWalkable(), false, 'grass is walkable')
    eq(ground:getGroundSpeed(), 110, 'ground speed off the item table')
    eq(ground:hasFloorChange(), false, 'Item:hasFloorChange is false at 1530 (no such flag)')

    -- Item.create
    local made = H.Item.create(ID_GOLD, 7)
    eq(made:getId(), ID_GOLD, 'Item.create id')
    eq(made:getCount(), 7, 'Item.create count')
    eq(posmod.isValid(made:getPosition()), false, 'Item.create has an INVALID position')
    eq(made:getStackPos(), 255, 'Item.create getStackPos() is the invalid position z')
    eq(made:getName(), 'gold coin', 'Item.create getName()')

    -- --- Container ---------------------------------------------------------
    local c = addContainer(H, 0, 'Loot Bag', 20,
        { { kind = 'item', id = ID_GOLD, count = 30 }, { kind = 'item', id = ID_GOLD, count = 12 } })
    eq(c:getName(), 'Loot Bag', 'container getName')
    eq(c:getId(), 0, 'container getId')
    eq(c:getCapacity(), 20, 'container getCapacity')
    eq(c:getItemsCount(), 2, 'container getItemsCount')
    eq(#c:getItems(), 2, 'container getItems')
    eq(c:getItems()[2]:getCount(), 12, 'container item count')
    eq(c:getItem(0):getCount(), 30, 'container getItem is 0-BASED')
    eq(c:getItem(5), nil, 'container getItem out of range is nil')
    eq(c:hasPages(), false, 'container hasPages')
    eq(c:getFirstIndex(), 0, 'container getFirstIndex')
    eq(c:isClosed(), false, 'container isClosed')
    eq(c:isUnlocked(), true, 'container isUnlocked')
    eq(c:findItemById(ID_GOLD, -1, 0):getCount(), 30, 'container findItemById')
    ok(c:getContainerItem() ~= nil, 'container getContainerItem() (no arg) is the bag item')
    eq(c:getContainerItem():getId(), ID_BP, 'and it is the backpack')
    eq(c:getContainerItem(1):getCount(), 12, 'container getContainerItem(index)')

    -- --- g_game accessors --------------------------------------------------
    eq(H.g_game.getClientVersion(), 1530, 'getClientVersion')
    eq(H.g_game.getProtocolVersion(), 1530, 'getProtocolVersion')
    eq(H.g_game.getCharacterName(), 'Testchar', 'getCharacterName')
    eq(H.g_game.isOnline(), true, 'isOnline')
    eq(H.g_game.getPing(), 37, 'getPing reads state.ping')
    eq(H.g_game.getServerBeat(), 50, 'getServerBeat')
    eq(H.g_game.getLocalPlayer(), player, 'getLocalPlayer')
    eq(H.g_game.getContainer(0), c, 'getContainer')
    eq(H.g_game.getContainers()[0], c, 'getContainers is keyed by container id')
    eq(H.g_game.findItemInContainers(ID_GOLD, -1, 0), c:getItems()[1], 'findItemInContainers')

    -- getUnjustifiedPoints: the shape vlib.lua:224 needs
    local up = H.g_game.getUnjustifiedPoints()
    ok(type(up) == 'table', 'getUnjustifiedPoints is a table')
    eq(type(up.killsDayRemaining), 'number', 'killsDayRemaining is a number')
    eq(type(up.killsWeekRemaining), 'number', 'killsWeekRemaining is a number')
    eq(type(up.killsMonthRemaining), 'number', 'killsMonthRemaining is a number')

    -- attack caches the target SYNCHRONOUSLY (gap G1)
    H:clear()
    H.g_game.attack(dragon)
    eq(H.g_game.getAttackingCreature(), dragon, 'getAttackingCreature() answers immediately')
    eq(H.g_game.isAttacking(), true, 'isAttacking')
    eq(H:last():byte(1), 0xA1, 'and a 0xA1 attack went out')
    H.g_game.cancelAttack()
    eq(H.g_game.getAttackingCreature(), nil, 'cancelAttack clears it')

    -- findPlayerItem: equipped slots first
    H.st.player.inventory[3] = { kind = 'item', id = ID_BP }        -- SlotBack
    local found = H.g_game.findPlayerItem(ID_BP, -1)
    ok(found ~= nil, 'findPlayerItem finds an equipped item')
    eq(found:getId(), ID_BP, 'and it is the right one')
    eq(found, player:getInventoryItem(3), 'and it is the interned inventory Item')
    eq(player:hasEquippedItemId(ID_BP, 0), true, 'hasEquippedItemId')
    eq(player:getInventoryCount(ID_GOLD, 0), 42, 'getInventoryCount sums the open containers')

    -- g_things
    local tt = H.g_things.getThingType(ID_LADDER, 0)
    ok(tt ~= nil, 'g_things.getThingType')
    eq(tt:getLensHelp(), 1104, 'ThingType:getLensHelp (cavebot floor-change classifier)')
    eq(H.g_things.getThingType(ID_LADDER, 0), tt, 'ThingType is interned')
    eq(H.g_things.getThingType(ID_STAIRS, 0):isNotPathable(), true, 'ThingType:isNotPathable')
    eq(H.g_things.getThingType(ID_GOLD, 0):getName(), 'gold coin', 'ThingType:getName')
    eq(H.g_things.getThingType(ID_GOLD, 0):isFluidContainer(), false, 'ThingType:isFluidContainer')
    eq(H.g_things.getThingType(0, 0), nil, 'getThingType(0) is nil, not a crash')

    -- g_map misc
    eq(H.g_map.isSightClear(ORIGIN, { x = ORIGIN.x + 2, y = ORIGIN.y, z = ORIGIN.z }), true,
       'isSightClear across open ground')
    eq(H.g_map.isSightClear(ORIGIN, { x = ORIGIN.x - 3, y = ORIGIN.y, z = ORIGIN.z }), false,
       'isSightClear blocked by the wall')
    eq(H.g_map.isAwareOfPosition(ORIGIN), true, 'isAwareOfPosition')
    eq(H.g_map.getCentralPosition().x, ORIGIN.x, 'getCentralPosition')
    H.g_game._shutdown()
end

-- ============================================================================
-- E. the synthetic position forms round-tripping through real packets (I3)
-- ============================================================================
S('E. synthetic positions on the wire (I3)')
do
    local H = newHost()
    local player = addPlayer(H, ORIGIN)
    fillGround(H, ORIGIN.x, ORIGIN.y, ORIGIN.z, 3)

    -- 0x78 Move: Position from(5), u16 thingId, u8 stackpos, Position to(5), u8 count
    local function decodeMove(body)
        local b = { body:byte(1, #body) }
        local function u16(i) return b[i] + b[i + 1] * 256 end
        return {
            op = b[1],
            from = { x = u16(2), y = u16(4), z = b[6] },
            id = u16(7), stack = b[9],
            to = { x = u16(10), y = u16(12), z = b[14] },
            count = b[15],
        }
    end

    -- --- container item ----------------------------------------------------
    local src = addContainer(H, 0, 'Loot Bag', 20,
        { { kind = 'item', id = ID_GOLD, count = 30 },
          { kind = 'item', id = ID_GOLD, count = 12 } })
    local dst = addContainer(H, 3, 'Main BP', 20, { { kind = 'item', id = ID_BP } })

    local it = src:getItems()[2]                     -- slot index 1 (0-based)
    local p = it:getPosition()
    eq(p.x, 65535, 'container item position.x is 0xFFFF')
    eq(p.y, 0x40, 'container item position.y is containerId|0x40 (id 0)')
    eq(p.z, 1, 'container item position.z is the 0-BASED slot')
    eq(it:getStackPos(), 1, 'container item getStackPos() == position.z')

    local dp = dst:getSlotPosition(dst:getItemsCount())
    eq(dp.x, 65535, 'getSlotPosition().x')
    eq(dp.y, 0x43, 'getSlotPosition().y is id 3 | 0x40')
    eq(dp.z, 1, 'getSlotPosition(getItemsCount()) is one past the last used slot')

    H:clear()
    H.g_game.move(it, dp, it:getCount())
    eq(H:count(), 1, 'move sent one packet')
    local m = decodeMove(H:last())
    eq(m.op, 0x78, '0x78 Move')
    eq(m.from.x, 65535, 'wire from.x')
    eq(m.from.y, 0x40, 'wire from.y (source container)')
    eq(m.from.z, 1, 'wire from.z (source slot)')
    eq(m.id, ID_GOLD, 'wire item id')
    eq(m.stack, 1, 'wire stackpos == the source slot')
    eq(m.to.y, 0x43, 'wire to.y (destination container)')
    eq(m.to.z, 1, 'wire to.z (destination slot)')
    eq(m.count, 12, 'wire count')

    -- the slot is read LIVE: remove the first item and the wrapper re-addresses itself
    table.remove(H.st.containers[0].items, 1)
    eq(it:getStackPos(), 0, 'after the container shifts, getStackPos() follows the item')
    H:clear()
    H.g_game.move(it, dp, 1)
    eq(decodeMove(H:last()).from.z, 0, 'and so does the wire address')

    -- --- equipped item -----------------------------------------------------
    H.st.player.inventory[6] = { kind = 'item', id = ID_GOLD, count = 3 }   -- SlotRight
    local eq6 = player:getInventoryItem(6)
    local ep = eq6:getPosition()
    eq(ep.x, 65535, 'equipped item position.x')
    eq(ep.y, 6, 'equipped item position.y is the inventory slot')
    eq(ep.z, 0, 'equipped item position.z is 0')
    eq(eq6:getStackPos(), 0, 'equipped item getStackPos() is 0')

    H:clear()
    H.g_game.move(eq6, dp, 3)
    local m2 = decodeMove(H:last())
    eq(m2.from.x, 65535, 'equipped move: wire from.x')
    eq(m2.from.y, 6, 'equipped move: wire from.y is the slot')
    eq(m2.from.z, 0, 'equipped move: wire from.z')
    eq(m2.stack, 0, 'equipped move: wire stackpos')

    -- --- tile item ---------------------------------------------------------
    local tp = { x = ORIGIN.x + 1, y = ORIGIN.y, z = ORIGIN.z }
    H.st:addThing(tp, -1, { kind = 'item', id = ID_GOLD, count = 9 })
    local tileItem = H.g_map.getTile(tp):getItems()[2]
    local tpp = tileItem:getPosition()
    eq(tpp.x, tp.x, 'tile item position is the tile position')
    eq(tpp.y, tp.y, 'tile item position.y')
    eq(tpp.z, tp.z, 'tile item position.z')
    eq(tileItem:getStackPos(), 1, 'tile item getStackPos() is the stack index')

    H:clear()
    H.g_game.move(tileItem, dp, 9)
    local m3 = decodeMove(H:last())
    eq(m3.from.x, tp.x, 'tile move: wire from.x')
    eq(m3.stack, 1, 'tile move: wire stackpos')
    eq(m3.to.y, 0x43, 'tile move: wire to.y')

    -- --- g_game.use on a detached item falls back to Position(0xFFFF,0,0) ---
    H:clear()
    H.g_game.use(H.Item.create(ID_GOLD))
    local b = { H:last():byte(1, 11) }
    eq(b[1], 0x82, 'use sends 0x82')
    eq(b[2] + b[3] * 256, 65535, 'virtual item use: pos.x is 0xFFFF')
    eq(b[4] + b[5] * 256, 0, 'virtual item use: pos.y is 0')
    eq(b[6], 0, 'virtual item use: pos.z is 0')

    -- --- open() reuses the previous container id, else the first free one ---
    H:clear()
    local idx = H.g_game.open(dst:getContainerItem(), nil)
    eq(idx, 1, 'open() picks the first free container id (0 and 3 are taken)')
    eq(H:last():byte(1), 0x82, 'open sends 0x82 UseItem')
    -- 0x82 body: opcode(1) Position(5) u16 itemId(2) u8 stackpos(1) u8 index(1) = 10 bytes
    eq(#H:last(), 10, 'the 0x82 body is 10 bytes')
    eq(H:last():byte(10), 1, 'and the index byte carries the container id')
    H:clear()
    eq(H.g_game.open(dst:getContainerItem(), src), 0, 'open(item, prev) reuses prev:getId()')
    eq(H:last():byte(10), 0, 'and the index byte is that id')

    -- --- stashStowItem (gap G10, opcode 0x28) ------------------------------
    H:clear()
    local stowMe = src:getItems()[1]
    H.g_game.stashStowItem(stowMe:getPosition(), stowMe:getId(), 0, stowMe:getStackPos(), 2)
    local sbody = H:last()
    local sb = { sbody:byte(1, #sbody) }
    eq(sb[1], 0x28, 'stashStowItem opcode 0x28')
    eq(sb[2], 2, 'action byte (2 = STOW_STACK)')
    eq(sb[3] + sb[4] * 256, 65535, 'stow pos.x')
    eq(sb[5] + sb[6] * 256, 0x40, 'stow pos.y (container 0)')
    eq(sb[7], 0, 'stow pos.z (slot 0)')
    eq(sb[8] + sb[9] * 256, ID_GOLD, 'stow item id')
    eq(sb[10], 0, 'stow stackpos')
    eq(#sbody, 10, 'action 2 carries NO u32 count (only action 0 does)')
    H:clear()
    H.g_game.stashStowItem(stowMe:getPosition(), stowMe:getId(), 77, stowMe:getStackPos(), 0)
    eq(#H:last(), 14, 'action 0 DOES carry the u32 count')

    -- --- partyInvite / partyJoin (gap G9) ----------------------------------
    H:clear()
    H.g_game.partyInvite(6001)
    eq(H:last():byte(1), 0xA3, 'partyInvite opcode 0xA3')
    eq(#H:last(), 5, 'partyInvite body length')
    H.g_game.partyJoin(6001)
    eq(H:last():byte(1), 0xA4, 'partyJoin opcode 0xA4')

    -- --- useWith against a creature goes out as 0x84 -----------------------
    local mob = addCreature(H, 7001, 'Rat', { x = ORIGIN.x + 2, y = ORIGIN.y, z = ORIGIN.z })
    H:clear()
    H.g_game.useWith(eq6, mob)
    eq(H:last():byte(1), 0x84, 'useWith on a creature sends 0x84 UseOnCreature')
    H:clear()
    H.g_game.useWith(eq6, tileItem)
    eq(H:last():byte(1), 0x83, 'useWith on an item sends 0x83 UseItemWith')
    H:clear()
    H.g_game.useInventoryItemWith(ID_GOLD, mob)
    local ub = { H:last():byte(1, 6) }
    eq(ub[1], 0x84, 'useInventoryItemWith on a creature sends 0x84')
    eq(ub[2] + ub[3] * 256, 65535, 'and the synthetic inventory position')
    H.g_game._shutdown()
end

-- ============================================================================
-- F. findEveryPath agrees with bot/path.lua
-- ============================================================================
S('F. findEveryPath vs bot/path.lua')
do
    local H = newHost()
    addPlayer(H, ORIGIN)
    fillGround(H, ORIGIN.x, ORIGIN.y, ORIGIN.z, 8)
    -- a wall column with one gap, so the path has to be interesting
    for y = ORIGIN.y - 4, ORIGIN.y + 4 do
        if y ~= ORIGIN.y + 3 then
            H.st:addThing({ x = ORIGIN.x + 3, y = y, z = ORIGIN.z }, -1,
                          { kind = 'item', id = ID_WALL })
        end
    end

    local dest = { x = ORIGIN.x + 6, y = ORIGIN.y, z = ORIGIN.z }

    local function deepEqualField(a, b)
        local na, nb = 0, 0
        for _ in pairs(a) do na = na + 1 end
        for _ in pairs(b) do nb = nb + 1 end
        if na ~= nb then return false, ('node count %d vs %d'):format(na, nb) end
        for k, va in pairs(a) do
            local vb = b[k]
            if not vb then return false, 'missing key ' .. k end
            for i = 1, 4 do
                if va[i] ~= vb[i] then
                    return false, ('%s[%d]: %s vs %s'):format(k, i, tostring(va[i]), tostring(vb[i]))
                end
            end
        end
        return true
    end

    local mine = H.g_map.findEveryPath(ORIGIN, 20, {})
    local theirs = H.path:findEveryPath(ORIGIN, 20, {}):toStringMap()
    local same, why = deepEqualField(mine, theirs)
    ok(same, 'g_map.findEveryPath == bot/path.lua findEveryPath (no params)', why)

    -- the vBot string-param contract: functions/map.lua turns booleans into 0/1, and
    -- findPath injects `destination` as "x,y,z"
    local destStr = dest.x .. ',' .. dest.y .. ',' .. dest.z
    local mine2 = H.g_map.findEveryPath(ORIGIN, 20,
        { ignoreCreatures = 1, ignoreNonPathable = 0, allowUnseen = 0, destination = destStr })
    local theirs2 = H.path:findEveryPath(ORIGIN, 20,
        { ignoreCreatures = true, ignoreNonPathable = false, allowUnseen = false,
          destination = dest }):toStringMap()
    local same2, why2 = deepEqualField(mine2, theirs2)
    ok(same2, 'the 0/1 + string-destination param form matches the native param form', why2)
    ok(mine2[destStr] ~= nil, 'and the destination node exists in the field')

    -- the maxDistanceFrom string form "x,y,z,dist"
    local mdfStr = ORIGIN.x .. ',' .. ORIGIN.y .. ',' .. ORIGIN.z .. ',2'
    local mine3 = H.g_map.findEveryPath(ORIGIN, 20, { maxDistanceFrom = mdfStr })
    local theirs3 = H.path:findEveryPath(ORIGIN, 20,
        { maxDistanceFrom = { { x = ORIGIN.x, y = ORIGIN.y, z = ORIGIN.z }, 2 } }):toStringMap()
    local same3, why3 = deepEqualField(mine3, theirs3)
    ok(same3, 'the "x,y,z,dist" maxDistanceFrom string is decoded correctly', why3)
    local far = (ORIGIN.x + 6) .. ',' .. ORIGIN.y .. ',' .. ORIGIN.z
    ok(mine3[far] == nil, 'and it really did clip the field')

    -- vBot's own translateAllPathsToPath, VERBATIM from
    -- mods/game_bot/functions/map.lua:113-134
    local function translateAllPathsToPath(paths, destPos)
        local predirections = {}
        local directions = {}
        local destPosStr = destPos
        if type(destPos) ~= 'string' then
            destPosStr = destPos.x .. "," .. destPos.y .. "," .. destPos.z
        end

        while destPosStr:len() > 0 do
            local node = paths[destPosStr]
            if not node then
                break
            end
            if node[3] < 0 then
                break
            end
            table.insert(predirections, node[3])
            destPosStr = node[4]
        end
        -- reverse
        for i = #predirections, 1, -1 do
            table.insert(directions, predirections[i])
        end
        return directions
    end

    local vbotDirs = translateAllPathsToPath(mine2, dest)
    local nativeDirs = H.path:getPath(ORIGIN, dest, 20, { ignoreCreatures = true })
    ok(nativeDirs ~= nil, 'bot/path.lua found a path')
    eq(#vbotDirs, #nativeDirs, 'vBot translateAllPathsToPath and bot/path agree on length')
    local sameDirs = (#vbotDirs == #nativeDirs)
    if sameDirs then
        for i = 1, #vbotDirs do if vbotDirs[i] ~= nativeDirs[i] then sameDirs = false end end
    end
    ok(sameDirs, 'and on every direction',
       table.concat(vbotDirs, ',') .. ' vs ' .. table.concat(nativeDirs or {}, ','))
    ok(#vbotDirs > 6, 'the path really had to go around the wall', #vbotDirs)

    -- the field node shape vBot indexes
    local node = mine2[destStr]
    eq(#node, 4, 'a field node is a 4-element array')
    eq(type(node[1]), 'number', 'node[1] totalCost')
    eq(type(node[2]), 'number', 'node[2] distance')
    eq(type(node[3]), 'number', 'node[3] direction')
    eq(type(node[4]), 'string', 'node[4] is the "x,y,z" prev key')
    local startKey = ORIGIN.x .. ',' .. ORIGIN.y .. ',' .. ORIGIN.z
    eq(mine2[startKey][3], -1, 'the start node has direction -1 (the loop terminator)')

    -- g_map.findPath is bound on the real client too
    local dirs = H.g_map.findPath(ORIGIN, dest, 20, { ignoreCreatures = 1 })
    eq(#dirs, #nativeDirs, 'g_map.findPath agrees with bot/path.lua getPath')

    -- determinism: getSpectators must not depend on `pairs` hash order
    addCreature(H, 8001, 'A', { x = ORIGIN.x + 1, y = ORIGIN.y, z = ORIGIN.z })
    addCreature(H, 8002, 'B', { x = ORIGIN.x - 1, y = ORIGIN.y, z = ORIGIN.z })
    addCreature(H, 8003, 'C', { x = ORIGIN.x, y = ORIGIN.y - 1, z = ORIGIN.z })
    local function ids(list)
        local o = {}
        for i = 1, #list do o[i] = list[i]:getId() end
        return table.concat(o, ',')
    end
    local a = ids(H.g_map.getSpectators(ORIGIN, false))
    local b = ids(H.g_map.getSpectators(ORIGIN, false))
    eq(a, b, 'getSpectators order is deterministic')
    -- the C++ walks z, then y, then x -> C(y-1) before B/player/A(y) left to right
    eq(a, '8003,8002,' .. PLAYER_ID .. ',8001', 'and it is the C++ z->y->x order')

    -- same SET as bot/world.lua's spectators (which uses hash order)
    local worldSet, mineSet = {}, {}
    for _, c in ipairs(H.world:spectators(ORIGIN, false)) do worldSet[c.id] = true end
    for _, c in ipairs(H.g_map.getSpectators(ORIGIN, false)) do mineSet[c:getId()] = true end
    local setSame = true
    for id in pairs(worldSet) do if not mineSet[id] then setSame = false end end
    for id in pairs(mineSet) do if not worldSet[id] then setSame = false end end
    ok(setSame, 'g_map.getSpectators and bot/world.lua spectators return the same SET')

    -- getSpectatorsInRange honours the box
    eq(#H.g_map.getSpectatorsInRange(ORIGIN, false, 1, 1), 4,
       'getSpectatorsInRange(1,1) sees the 3x3 box')
    eq(#H.g_map.getSpectatorsInRange(ORIGIN, false, 0, 0), 1,
       'getSpectatorsInRange(0,0) sees only the centre tile')

    -- getSpectatorsByPattern: a 3x3 grid with only the four orthogonals on
    local pattern = '010\n101\n010'
    local byPattern = H.g_map.getSpectatorsByPattern(ORIGIN, pattern, 8)
    eq(#byPattern, 3, 'getSpectatorsByPattern sees the three orthogonal neighbours')
    local seenIds = {}
    for i = 1, #byPattern do seenIds[byPattern[i]:getId()] = true end
    ok(seenIds[8001] and seenIds[8002] and seenIds[8003],
       'and it is exactly A, B and C -- not the player on the centre cell')
    ok(byPattern[1] == H.g_map.getCreatureById(byPattern[1]:getId()),
       'pattern spectators are interned too')

    -- getTopThing on a tile whose only non-ground thing is a creature: Thing::isCommon()
    -- excludes creatures, so the fallback "the LAST thing" answers the creature.
    local cp = { x = ORIGIN.x + 1, y = ORIGIN.y, z = ORIGIN.z }
    local top = H.g_map.getTile(cp):getTopThing()
    eq(top:isCreature(), true, 'getTopThing falls back to the last thing (the creature)')
    eq(top:getId(), 8001, 'and it is the interned Creature')
    H.g_game._shutdown()
end

-- ============================================================================
-- F3. blocker B1: the persisted-minimap fallback reaches findEveryPath
-- ============================================================================
S('F3. the minimap fallback (blocker B1)')
do
    -- Map::findEveryPath reads the PERSISTED minimap for every tile OUTSIDE the aware range
    -- (map.cpp, the `else if (!allowOnlyVisibleTiles)` branch).  Headless that store is empty
    -- unless main.lua's --minimap=PATH threads a lib/minimap.lua reader in as LC.minimap,
    -- which is what makes a long cavebot `goto` pathable at all (PLAN sec.6.1).
    local dest = { x = ORIGIN.x + 14, y = ORIGIN.y, z = ORIGIN.z }

    -- The described island must cover the whole AWARE rectangle (left 8 / right 9 / top 6 /
    -- bottom 7), because inside it `classifyForPath` reads the live tile store and never the
    -- minimap -- an undescribed tile in there is blocked on the real client too.  Only the
    -- tiles PAST the aware edge (x + 10 .. x + 14 here) take the minimap branch.
    local without = newHost()
    addPlayer(without, ORIGIN)
    fillGround(without, ORIGIN.x, ORIGIN.y, ORIGIN.z, 9)
    local f0 = without.g_map.findEveryPath(ORIGIN, 30, {})
    eq(f0[posmod.key(dest)], nil,
       'with NO minimap, a destination outside the aware range is unreachable (B1)')

    -- a stand-in for lib/minimap.lua: every tile was seen, walkable, speed byte 10
    local knownReads = 0
    local known = { get = function(_, _pos) knownReads = knownReads + 1; return 1, 129, 10 end }
    local with = newHost({ known = known })
    addPlayer(with, ORIGIN)
    fillGround(with, ORIGIN.x, ORIGIN.y, ORIGIN.z, 9)
    local f1 = with.g_map.findEveryPath(ORIGIN, 30, {})
    ok(f1[posmod.key(dest)] ~= nil,
       'with a minimap reader wired in, the same destination IS reachable')
    ok(knownReads > 0, 'and the reader was actually consulted', knownReads)

    -- allowUnseen is the other documented escape hatch, and the vBot 0/1 form must work
    local f2 = without.g_map.findEveryPath(ORIGIN, 30, { allowUnseen = 1 })
    ok(f2[posmod.key(dest)] ~= nil, 'allowUnseen = 1 (the vBot string/number form) also works')

    -- g_map.getMinimapColor falls back to the minimap for a tile we do NOT hold
    eq(without.g_map.getMinimapColor(dest), 255,
       'getMinimapColor on an unknown tile with no minimap is the null-tile 255')
    eq(with.g_map.getMinimapColor(dest), 129,
       'and it is the minimap colour when a reader is wired in')
    eq(with.g_map.getMinimapColor(ORIGIN), 129,
       'a tile we DO hold answers from the tile, never from the minimap')
    without.g_game._shutdown(); with.g_game._shutdown()
end

-- ============================================================================
-- F2. the floor index is an index, not a rescan
-- ============================================================================
S('F2. g_map.getTiles performance and correctness')
do
    local H = newHost()
    addPlayer(H, ORIGIN)
    fillGround(H, ORIGIN.x, ORIGIN.y, ORIGIN.z, 9)          -- 19x19 = 361 tiles
    fillGround(H, ORIGIN.x, ORIGIN.y, ORIGIN.z - 1, 4)      -- another floor

    eq(#H.g_map.getTiles(ORIGIN.z), 361, 'getTiles(z) sees exactly its own floor')
    eq(#H.g_map.getTiles(ORIGIN.z - 1), 81, 'getTiles on the other floor')
    eq(#H.g_map.getTiles(-1), 442, 'getTiles(-1) is every floor')

    -- row-major order
    local list = H.g_map.getTiles(ORIGIN.z)
    local sorted = true
    for i = 2, #list do
        local a, b = list[i - 1]:getPosition(), list[i]:getPosition()
        if not (a.y < b.y or (a.y == b.y and a.x < b.x)) then sorted = false end
    end
    ok(sorted, 'getTiles(z) is row-major (y, then x) and therefore deterministic')

    -- A direct write to state.map (what a hand-built fixture does) bypasses the instance
    -- hooks; `state.tileCount` is the cross-check that makes the index resync anyway.
    H.st.map['5000,5000,7'] = { pos = { x = 5000, y = 5000, z = 7 }, things = {} }
    H.st.tileCount = H.st.tileCount + 1
    eq(#H.g_map.getTiles(7), 362, 'a direct state.map write is picked up by the index resync')
    eq(H.reg.indexed, H.st.tileCount, 'and the index total agrees with state.tileCount again')

    -- timing gate: PLAN sec.5.6 wants < 1 ms per call over a full aware area
    local sys = require('lib.sys')
    local t0 = sys.nowMs()
    local N = 200
    for _ = 1, N do H.g_map.getTiles(ORIGIN.z) end
    local per = (sys.nowMs() - t0) / N
    ok(per < 1.0, ('getTiles over 362 tiles takes %.3f ms (< 1 ms budget)'):format(per), per)

    -- ...and the same with a tile appearing and disappearing between every call, which is
    -- what a live tick does: that forces the per-floor list to be rebuilt every time.
    local t1 = sys.nowMs()
    for i = 1, N do
        local p = { x = ORIGIN.x + 40 + (i % 3), y = ORIGIN.y + 40, z = ORIGIN.z }
        H.st:addThing(p, -1, { kind = 'item', id = ID_GRASS })
        H.g_map.getTiles(ORIGIN.z)
        H.st:cleanTile(p)
    end
    local perDirty = (sys.nowMs() - t1) / N
    ok(perDirty < 1.0,
       ('getTiles with a rebuild every call takes %.3f ms (< 1 ms budget)'):format(perDirty),
       perDirty)
    io.write(('        getTiles: %.4f ms/call cached, %.4f ms/call rebuilding, over %d tiles\n')
             :format(per, perDirty, #list))
    H.g_game._shutdown()
end

-- ============================================================================
-- G. REAL vBot fragments, lifted verbatim
-- ============================================================================
S('G. verbatim vBot 4.8 fragments')
do
    local H = newHost()
    local player = addPlayer(H, ORIGIN)
    fillGround(H, ORIGIN.x, ORIGIN.y, ORIGIN.z, 6)

    -- the sandbox globals these fragments close over
    local g_game, g_map, g_things = H.g_game, H.g_map, H.g_things
    local modules = {}
    local table_find = function(t, v)
        for i = 1, #t do if t[i] == v then return i end end
        return nil
    end
    if not table.find then table.find = table_find end

    -- ---------------------------------------------------------------- (1)
    -- VERBATIM: profiles/bot/vBot_4.8/cavebot/walking.lua:102 and 108-127
    local FLOOR_CHANGE_LENSHELP = { [1104] = true, [1105] = true }

    local function thingsApi()
      if g_things then return g_things end
      for _, m in ipairs({ "game_interface", "game_things", "game_bot" }) do
        local env = modules and modules[m]
        if env and env.g_things then return env.g_things end
      end
      return nil
    end

    local function itemChangesFloor(item)
      if not item then return false end
      local things = thingsApi()
      if not things then return false end
      local tt = things.getThingType(item:getId(), 0) -- 0 = ThingCategoryItem (the constant is not whitelisted)
      if not tt then return false end
      if FLOOR_CHANGE_LENSHELP[tt:getLensHelp()] then return true end
      -- an "avoid" GROUND is how holes/stairs/trapdoors are flagged; fields are
      -- items on top of the ground, so they do not trip this
      if item:isGround() and tt:isNotPathable() then return true end
      return false
    end

    local plainTile = H.g_map.getTile(ORIGIN)
    eq(itemChangesFloor(plainTile:getGround()), false,
       '[walking.lua:116-127] grass is not a floor change')

    local stairsPos = { x = ORIGIN.x + 1, y = ORIGIN.y, z = ORIGIN.z }
    H.st:setTile(stairsPos, nil)
    H.st:addThing(stairsPos, -1, { kind = 'item', id = ID_STAIRS })
    eq(itemChangesFloor(H.g_map.getTile(stairsPos):getGround()), true,
       '[walking.lua:116-127] an "avoid" GROUND is a floor change')

    local ladderPos = { x = ORIGIN.x + 2, y = ORIGIN.y, z = ORIGIN.z }
    H.st:addThing(ladderPos, -1, { kind = 'item', id = ID_LADDER })
    eq(itemChangesFloor(H.g_map.getTile(ladderPos):getTopUseThing()), true,
       '[walking.lua:116-127] lensHelp 1104 is a floor change')

    -- ---------------------------------------------------------------- (2)
    -- VERBATIM: profiles/bot/vBot_4.8/cavebot/walking.lua:132-165
    local avoidIds = {}
    local function avoidTileIds() return avoidIds end

    local function isFloorChangeTile(p)
      local ok, bad, why = pcall(function()
        local tile = g_map.getTile(p)
        if not tile then
          -- not loaded (path planned through unseen tiles): only the minimap knows
          -- it, and colour alone is not proof - the pathfinder already blocks
          -- yellow+not-pathable there, and the tile is re-checked once it loads
          return false
        end
        local color = g_map.getMinimapColor(p)
        if color and color >= 210 and color <= 213 and not tile:isPathable() then
          return true, "stairs (yellow, not pathable)"
        end
        local ground = tile:getGround()
        if itemChangesFloor(ground) then
          return true, "floor-change ground id " .. ground:getId()
        end
        local top = tile:getTopUseThing()
        if top and top ~= ground and itemChangesFloor(top) then
          return true, "floor-change item id " .. top:getId()
        end
        local ids = avoidTileIds()
        if #ids > 0 then
          if ground and table.find(ids, ground:getId()) then
            return true, "listed ground id " .. ground:getId()
          end
          if top and table.find(ids, top:getId()) then
            return true, "listed item id " .. top:getId()
          end
        end
        return false
      end)
      if not ok then return false end
      return bad, why
    end

    eq(isFloorChangeTile(ORIGIN), false, '[walking.lua:132-165] plain grass is safe')
    local bad, why = isFloorChangeTile(stairsPos)
    eq(bad, true, '[walking.lua:132-165] the stairs tile is refused')
    eq(why, 'stairs (yellow, not pathable)',
       '[walking.lua:132-165] and for the minimap-colour reason (210 + not pathable)')
    local bad2, why2 = isFloorChangeTile(ladderPos)
    eq(bad2, true, '[walking.lua:132-165] the ladder tile is refused')
    eq(why2, 'floor-change item id ' .. ID_LADDER,
       '[walking.lua:132-165] via the `top ~= ground` IDENTITY comparison (invariant I1)')
    eq(isFloorChangeTile({ x = ORIGIN.x + 40, y = ORIGIN.y, z = ORIGIN.z }), false,
       '[walking.lua:132-165] an unknown tile returns false, not an error (getTile nil)')
    avoidIds = { ID_GRASS }
    eq((isFloorChangeTile(ORIGIN)), true,
       '[walking.lua:132-165] the avoid-id list matches the ground id')
    avoidIds = {}

    -- ---------------------------------------------------------------- (3)
    -- VERBATIM: profiles/bot/vBot_4.8/vBot/vlib.lua:223-227
    local function killsToRs()
        return math.min(g_game.getUnjustifiedPoints().killsDayRemaining,
                        g_game.getUnjustifiedPoints().killsWeekRemaining,
                        g_game.getUnjustifiedPoints().killsMonthRemaining)
    end
    local okk, res = pcall(killsToRs)
    ok(okk, '[vlib.lua:223-227] killsToRs() does not crash on the shim', tostring(res))
    -- G3 CLOSED.  Before 0xB7 arrives the three *Remaining fields answer 255, not 0:
    -- 0 is conservative for the AttackBot PvP gate (`killsToRs() > KillsAmount`) but it
    -- INVERTS vBot/antiRs.lua:21 (`killsToRs() < 6`), which would then latch on for the
    -- whole session.  255 is the only value that is safe in both directions.
    eq(res, 255, '[vlib.lua:223-227] answers 255 before opcode 0xB7 has arrived')
    local u0 = H.g_game.getUnjustifiedPoints()
    eq(u0.killsDay, 0, 'the progress fields are still 0 before 0xB7')
    -- ... and the REAL numbers once the parser has seen the packet
    H.st.unjustified = { killsDay = 12, killsDayRemaining = 3,
                         killsWeek = 40, killsWeekRemaining = 5,
                         killsMonth = 60, killsMonthRemaining = 9, skullTime = 0 }
    local u1 = H.g_game.getUnjustifiedPoints()
    eq(u1.killsDayRemaining, 3, 'getUnjustifiedPoints reads state.unjustified (0xB7)')
    eq(u1.killsMonth, 60, 'and every one of the seven fields')
    eq(killsToRs(), 3, 'killsToRs() is then the real minimum')
    H.st.unjustified = nil

    -- ---------------------------------------------------------------- (4)
    -- VERBATIM: profiles/bot/vBot_4.8/targetbot/looting.lua:284-301
    local TargetBot = { Looting = {} }
    local now, waitTill = 1000, 0

    TargetBot.Looting.lootItem = function(lootContainers, item)
      if item:isStackable() then
        local count = item:getCount()
        for _, container in ipairs(lootContainers) do
          for slot, citem in ipairs(container:getItems()) do
            if item:getId() == citem:getId() and citem:getCount() < 100 then
              g_game.move(item, container:getSlotPosition(slot - 1), count)
              waitTill = now + 300 -- give it 0.3s to move item
              return
            end
          end
        end
      end

      local container = lootContainers[1]
      g_game.move(item, container:getSlotPosition(container:getItemsCount()), 1)
      waitTill = now + 300 -- give it 0.3s to move item
    end

    -- a corpse on the ground holding gold, and an open loot bag with a partial stack
    local corpsePos = { x = ORIGIN.x, y = ORIGIN.y + 1, z = ORIGIN.z }
    H.st:addThing(corpsePos, -1, { kind = 'item', id = ID_CORPSE })
    local corpseBag = addContainer(H, 1, 'dead troll', 10,
        { { kind = 'item', id = ID_GOLD, count = 60 } })
    local lootBag = addContainer(H, 2, 'Loot Bag', 20,
        { { kind = 'item', id = ID_BP }, { kind = 'item', id = ID_GOLD, count = 30 } })

    local function decodeMove(body)
        local b = { body:byte(1, #body) }
        local function u16(i) return b[i] + b[i + 1] * 256 end
        return { op = b[1], from = { x = u16(2), y = u16(4), z = b[6] }, id = u16(7),
                 stack = b[9], to = { x = u16(10), y = u16(12), z = b[14] }, count = b[15] }
    end

    H:clear()
    TargetBot.Looting.lootItem({ lootBag }, corpseBag:getItems()[1])
    eq(H:count(), 1, '[looting.lua:284-301] one move packet')
    local mv = decodeMove(H:last())
    eq(mv.op, 0x78, '[looting.lua:284-301] 0x78 Move')
    eq(mv.from.y, 0x41, '[looting.lua:284-301] from the corpse container (id 1)')
    eq(mv.from.z, 0, '[looting.lua:284-301] slot 0')
    eq(mv.to.y, 0x42, '[looting.lua:284-301] into the loot bag (id 2)')
    eq(mv.to.z, 1, '[looting.lua:284-301] onto the EXISTING gold stack at slot 1 '
                   .. '(the `slot - 1` 0-based conversion)')
    eq(mv.count, 60, '[looting.lua:284-301] the whole stack')
    eq(waitTill, 1300, '[looting.lua:284-301] waitTill was set (the stacking branch ran)')

    -- the non-stacking branch: an item the bag has no stack of
    H:clear()
    local nonStack = { kind = 'item', id = ID_BP }
    H.st.containers[1].items[2] = nonStack
    TargetBot.Looting.lootItem({ lootBag }, corpseBag:getItems()[2])
    local mv2 = decodeMove(H:last())
    eq(mv2.to.z, 2, '[looting.lua:284-301] a non-stackable goes to getItemsCount() = slot 2')
    eq(mv2.count, 1, '[looting.lua:284-301] count 1')

    -- ---------------------------------------------------------------- (5)
    -- VERBATIM: profiles/bot/vBot_4.8/cavebot/depositor.lua:245-252 (the stow branch)
    local statusMessages = {}
    local function statusMessage(s) statusMessages[#statusMessages + 1] = s end
    local function delay() end
    local stowAttempts, stowFallback = {}, {}

    local function stowBranch(item)
        local id = item:getId()
        stowAttempts[id] = (stowAttempts[id] or 0) + 1
        -- still here after a few tries? the stash won't take it
        if stowAttempts[id] > 3 then
            stowFallback[id] = true
            statusMessage("[Stow] " ..id.. " not stowable, will use depot")
        else
            statusMessage("[Stow] stowing all of item: " ..id)
            g_game.stashStowItem(item:getPosition(), id, 0, item:getStackPos(), 2)
            delay(200)
            return "retry"
        end
    end

    H:clear()
    local stowTarget = lootBag:getItems()[2]           -- the gold at slot 1 of container 2
    eq(stowBranch(stowTarget), 'retry', '[depositor.lua:245-252] the stow branch ran')
    local sb = { H:last():byte(1, #H:last()) }
    eq(sb[1], 0x28, '[depositor.lua:245-252] 0x28 stash stow')
    eq(sb[2], 2, '[depositor.lua:245-252] action 2')
    eq(sb[5] + sb[6] * 256, 0x42, '[depositor.lua:245-252] item:getPosition() addressed '
                                  .. 'container 2')
    eq(sb[7], 1, '[depositor.lua:245-252] at slot 1')
    eq(sb[10], 1, '[depositor.lua:245-252] and item:getStackPos() agreed with it')

    -- ---------------------------------------------------------------- (6)
    -- VERBATIM: profiles/bot/vBot_4.8/targetbot/target.lua:299-315
    local lastItemUse = 0
    TargetBot.useItem = function(item, subType, target, delay)
      if not delay then delay = 200 end
      if lastItemUse + delay < now then
        local thing = g_things.getThingType(item)
        if not thing or not thing:isFluidContainer() then
          subType = g_game.getClientVersion() >= 860 and 0 or 1
        end
        if g_game.getClientVersion() < 780 then
          local tmpItem = g_game.findPlayerItem(item, subType)
          if not tmpItem then return end
          g_game.useWith(tmpItem, target, subType) -- using item from bp
        else
          g_game.useInventoryItemWith(item, target, subType) -- hotkey
        end
        lastItemUse = now
      end
    end

    local target = addCreature(H, 9001, 'Dragon', { x = ORIGIN.x + 1, y = ORIGIN.y + 1, z = ORIGIN.z })
    H:clear()
    TargetBot.useItem(ID_GOLD, nil, target)
    eq(H:count(), 1, '[target.lua:299-315] one packet')
    eq(H:last():byte(1), 0x84, '[target.lua:299-315] 0x84 UseOnCreature (cv 1530 >= 780)')
    local tb = { H:last():byte(1, 12) }
    eq(tb[2] + tb[3] * 256, 65535, '[target.lua:299-315] the synthetic inventory position')
    eq(tb[7] + tb[8] * 256, ID_GOLD, '[target.lua:299-315] the item id')
    eq(tb[9], 0, '[target.lua:299-315] stackpos 0')
    eq(tb[10] + tb[11] * 256 + tb[12] * 65536, 9001 % 16777216,
       '[target.lua:299-315] the target creature id')
    eq(lastItemUse, now, '[target.lua:299-315] the cooldown was stamped')
    H.g_game._shutdown()
end

-- ============================================================================
-- H. strict mode makes the deliberate gaps LOUD
-- ============================================================================
S('H. strict mode')
do
    local H = newHost({ strict = true })
    addPlayer(H, ORIGIN)
    -- gap G3 is closed, but only ONCE the server has sent 0xB7; until then the answer is
    -- still a documented deviation and strict mode still has to say so.
    local okk = pcall(H.g_game.getUnjustifiedPoints)
    eq(okk, false, 'strict: getUnjustifiedPoints raises while 0xB7 has not arrived')
    H.st.unjustified = { killsDay = 1, killsDayRemaining = 2, killsWeek = 3,
                         killsWeekRemaining = 4, killsMonth = 5, killsMonthRemaining = 6,
                         skullTime = 7 }
    local okk1b, u = pcall(H.g_game.getUnjustifiedPoints)
    ok(okk1b and u and u.killsWeekRemaining == 4,
       'strict: and it stops reporting once the real numbers are in')
    H.st.unjustified = nil
    local okk2 = pcall(function() return H.g_map.findItemsById(1) end)
    eq(okk2, false, 'strict: an unimplemented g_map binding raises')

    -- blocker B2 CLOSED: the imbuement family is a real sender now, so it must NOT raise
    -- even in strict mode -- it must put bytes on the wire.
    H:clear()
    local okk3 = pcall(function() return H.g_game.applyImbuement(1, 2, true) end)
    ok(okk3, 'strict: applyImbuement no longer raises (blocker B2 closed)')
    local apply = H:last()
    ok(apply ~= nil and apply:byte(1) == 0xD5, 'strict: and it sent a real 0xD5')

    -- non-strict: the same calls are inert and callable
    local H2 = newHost()
    addPlayer(H2, ORIGIN)
    ok(type(H2.g_game.getUnjustifiedPoints()) == 'table', 'non-strict: still a table')
    eq(H2.g_map.findItemsById(1), nil, 'non-strict: an unknown binding is callable and inert')
    ok(#H2.logged > 0, 'and every one of them logged a warning')
    H.g_game._shutdown(); H2.g_game._shutdown()
end

-- ============================================================================
-- I. the registry does not degrade game/state.lua
-- ============================================================================
S('I. the state hooks are reversible and inert')
do
    local st = state.new()
    local baseSet, baseClean = st.setTile, st.cleanTile
    local LC = { state = st, items = items, events = events.new(), inGame = true, sched = sched }
    local reg = objects.new(LC, {})
    ok(rawget(st, 'setTile') ~= nil, 'the registry installed an INSTANCE-level hook')
    st:addThing({ x = 1, y = 2, z = 3 }, -1, { kind = 'item', id = ID_GRASS })
    eq(st.tileCount, 1, 'the hooked state still counts tiles correctly')
    eq(reg.indexed, 1, 'and the floor index saw it')
    reg:detach()
    eq(rawget(st, 'setTile'), nil, 'detach() removes the instance hook')
    eq(st.setTile, baseSet, 'and the shared metatable method is uncovered again')
    eq(st.cleanTile, baseClean, 'for every hooked method')
    st:addThing({ x = 4, y = 5, z = 3 }, -1, { kind = 'item', id = ID_GRASS })
    eq(st.tileCount, 2, 'the detached state still works')

    -- two registries over one state
    local r1 = objects.new(LC, {})
    local r2 = objects.new(LC, {})
    st:addThing({ x = 9, y = 9, z = 3 }, -1, { kind = 'item', id = ID_GRASS })
    eq(r1.indexed, 3, 'registry 1 indexed all three tiles')
    eq(r2.indexed, 3, 'registry 2 too (the hook fans out)')
    r1:detach(); r2:detach()
    eq(rawget(st, 'setTile'), nil, 'the last detach uninstalls the hook')

    -- state:reset() invalidates everything
    local r3 = objects.new(LC, {})
    st:reset()
    eq(r3.indexed, 0, 'state:reset() clears the floor index')
    eq(next(r3.tiles), nil, 'and every interned wrapper')
    r3:detach()
end

-- ============================================================================
-- J. the adversarial-review findings (work item F)
--    Each block FAILED before the fix named in its comment and passes after it.
-- ============================================================================
S('J. review findings: the disappear payload, identity, counts, addresses')
do
    local parsermod = require('proto.parser')
    local cbmod     = require('shim.callbacks')

    -- ---------------------------------------------------------------- J1
    -- BLOCKER: onCreatureDisappear used to hand vBot a BLANK creature -- or, if
    -- nothing had wrapped that creature during the session, not to fire at all.
    -- proto/parser.lua:dropCreature unlinks the record BEFORE emitting, and
    -- game/state.lua cleared `creature.pos` on the way out, so every getter fell
    -- back to its C++ default: getName()=='' , getPosition()=={65535,65535,255},
    -- isMonster()==false.  targetbot/looting.lua:313 (`if not creature:isMonster()
    -- then return end`) and :322 (`if pos.z ~= mpos.z`) both bail on that, so the
    -- bot never loots a corpse -- silently, with no error and no log line.
    local H = newHost()
    addPlayer(H, ORIGIN)
    fillGround(H, ORIGIN.x, ORIGIN.y, ORIGIN.z, 4)
    local ratPos = { x = ORIGIN.x + 2, y = ORIGIN.y, z = ORIGIN.z }
    addCreature(H, 7001, 'Rotworm', ratPos)

    local seen = {}
    local cb = { onCreatureDisappear = function(c)
        seen.n = (seen.n or 0) + 1
        seen.name = c:getName()
        seen.pos = c:getPosition()
        seen.monster = c:isMonster()
        seen.id = c:getId()
        seen.outfit = c:getOutfit()
    end }
    local handle = cbmod.install(H.LC, cb, { reg = H.reg, g_game = H.g_game })
    ok(handle ~= nil, 'the callback bridge installed')

    local P = parsermod.new(H.st, function(name, d) H.bus:emit(name, d) end)
    H.reg:creature(7001)                       -- a spectator scan wrapped it earlier
    P:dropCreature(7001)

    eq(seen.n, 1, 'J1 onCreatureDisappear fired exactly once')
    eq(seen.name, 'Rotworm', 'J1 the handler still sees the NAME')
    eq(seen.monster, true, 'J1 and isMonster() (looting.lua:313 bails otherwise)')
    eq(seen.id, 7001, 'J1 and the id')
    ok(seen.pos and seen.pos.x == ratPos.x and seen.pos.y == ratPos.y
       and seen.pos.z == ratPos.z,
       'J1 and the POSITION it died on (looting.lua:322 compares its z)',
       seen.pos and (seen.pos.x .. ',' .. seen.pos.y .. ',' .. seen.pos.z))
    ok(seen.outfit and seen.outfit.lookType == 3, 'J1 and the outfit')
    eq(H.g_map.getCreatureById(7001), nil,
       'J1 while g_map.getCreatureById STILL answers nil for a removed id (C++ exact)')
    eq(H.st.creatures[7001], nil, 'J1 and the record really is unlinked from state')

    -- the harder half: nothing ever wrapped this creature, so the old code could not
    -- mint one and dropped the callback entirely
    local ghostPos = { x = ORIGIN.x - 2, y = ORIGIN.y, z = ORIGIN.z }
    addCreature(H, 7002, 'Cave Rat', ghostPos)
    H.reg.creatures[7002] = nil                -- never queried this session
    seen = {}
    P:dropCreature(7002)
    eq(seen.n, 1, 'J1 it fires even when the creature was never wrapped before')
    eq(seen.name, 'Cave Rat', 'J1 with its name')
    ok(seen.pos and seen.pos.x == ghostPos.x, 'J1 and its last position')

    -- and the wrapper keeps answering afterwards, like the live client CreaturePtr
    local dead = H.reg:creatureFromRecord({ id = 7002 })
    ok(dead ~= nil, 'J1 the wrapper survives the removal')
    handle:remove()

    -- containerClose gets the same treatment
    local H2 = newHost()
    addPlayer(H2, ORIGIN)
    addContainer(H2, 3, 'loot bag', 20, { { kind = 'item', id = ID_GOLD, count = 5 } })
    local closed = {}
    local cb2 = { onContainerClose = function(c)
        closed.name = c:getName(); closed.items = #c:getItems(); closed.shut = c:isClosed()
    end }
    local h2 = cbmod.install(H2.LC, cb2, { reg = H2.reg, g_game = H2.g_game })
    H2.reg.containers[3] = nil                 -- never queried
    local rec3 = H2.st:closeContainer(3)
    H2.bus:emit('containerClose', rec3)
    eq(closed.name, 'loot bag', 'J1b onContainerClose still knows WHICH bag closed')
    eq(closed.items, 1, 'J1b and what was in it')
    eq(closed.shut, true, 'J1b while isClosed() stays a live, honest test')
    h2:remove()

    -- ---------------------------------------------------------------- J2
    -- MAJOR: Reg:localPlayer() re-minted the wrapper whenever state.player.id
    -- changed, so after a relog `spec ~= player` was TRUE for our own character and
    -- AttackBot (1233,1317,1477,2543,2966,3050) counted us as a hostile spectator.
    local H3 = newHost()
    local captured = H3.g_game.getLocalPlayer()          -- executor.lua does this ONCE
    eq(captured:getId(), 0, 'J2 captured before login, id 0')
    addPlayer(H3, ORIGIN)
    fillGround(H3, ORIGIN.x, ORIGIN.y, ORIGIN.z, 3)
    ok(H3.g_game.getLocalPlayer() == captured, 'J2 the SAME table after login (I1)')
    eq(captured:getId(), PLAYER_ID, 'J2 re-keyed in place, not re-minted')
    eq(captured:getName(), 'Testchar', 'J2 and it reads the live player record')
    local selfSpec
    for _, sp in ipairs(H3.g_map.getSpectators(ORIGIN, false)) do
        if sp:getId() == PLAYER_ID then selfSpec = sp end
    end
    ok(selfSpec == captured,
       'J2 the spectator for ourselves IS the captured player (AttackBot spec ~= player)')

    -- a relog: a brand new player id, no shim restart (main.lua:646 early-returns)
    H3.st.player.id = 0x2000
    H3.st:addCreature{ id = 0x2000, name = 'Testchar', type = 0, pos = ORIGIN }
    ok(H3.g_game.getLocalPlayer() == captured, 'J2 still the same table across a RELOG')
    eq(captured:getId(), 0x2000, 'J2 with the new id')
    eq(H3.reg.creatures[PLAYER_ID], nil, 'J2 and the stale id was un-keyed')
    ok(H3.reg:creature(0x2000) == captured, 'J2 reg:creature(newId) is the singleton too')

    -- ---------------------------------------------------------------- J3
    -- MAJOR: getInventoryCount summed the RAW wire byte, which for a fluid container
    -- or a splash is the FLUID SUBTYPE, not a count.  localplayer.cpp:565-569
    -- accumulates Item::getCount() = `isStackable() ? m_countOrSubType : 1`.
    local H4 = newHost()
    local me4 = addPlayer(H4, ORIGIN)
    local ID_VIAL = 2874                       -- fluid container in items1530.bin
    ok(not items.isStackable(ID_VIAL), 'J3 the vial is not stackable')
    ok(items.isStackable(ID_GOLD), 'J3 gold is')
    H4.st.player.inventory = {
        [5] = { kind = 'item', id = ID_VIAL, count = 7 },   -- subtype 7 (a fluid)
        [6] = { kind = 'item', id = ID_GOLD, count = 100 },
    }
    addContainer(H4, 0, 'bp', 20, { { kind = 'item', id = ID_VIAL, count = 7 },
                                    { kind = 'item', id = ID_VIAL, count = 3 } })
    eq(me4:getInventoryCount(ID_VIAL), 3,
       'J3 three vials count as 3, not 7+7+3=17 (Item::getCount, item.h:96)')
    eq(me4:getInventoryCount(ID_GOLD), 100, 'J3 while a stackable still sums its count')

    -- ---------------------------------------------------------------- J4
    -- MAJOR (invariant I3): Reg:item interned on the THING alone and rewrote _loc on
    -- every later call, so the last caller silently repointed every earlier holder --
    -- and Item:getPosition()/getStackPos() are where g_game.move gets its fromPos and
    -- stackpos bytes.  The intern key is now (thing, location).
    local H5 = newHost()
    addPlayer(H5, ORIGIN)
    local bpThing = { kind = 'item', id = ID_BP }
    H5.st.player.inventory = { [3] = bpThing }               -- worn in the backpack slot
    H5.st.containers[0] = { id = 0, name = 'bp', capacity = 20, firstIndex = 0,
                            size = 0, items = {}, hasParent = false, isUnlocked = true,
                            item = bpThing }                 -- the SAME table, twice over
    local slotItem = H5.reg:item(bpThing, { kind = 'inventory', slot = 3 })
    local p1 = slotItem:getPosition()
    eq(p1.y, 3, 'J4 the equipped wrapper addresses inventory slot 3')
    local viaContainer = H5.g_game.getContainer(0):getContainerItem()   -- stamps detached
    ok(viaContainer ~= slotItem, 'J4 two locations no longer share one wrapper')
    local p2 = slotItem:getPosition()
    eq(p2.x, p1.x, 'J4 and the equipped wrapper still addresses slot 3 -- x')
    eq(p2.y, p1.y, 'J4 ... y')
    eq(p2.z, p1.z, 'J4 ... z')
    ok(H5.reg:item(bpThing, { kind = 'inventory', slot = 3 }) == slotItem,
       'J4 identity for the SAME thing at the SAME place is still stable (I1)')

    -- and the wire bytes, decoded off a real g_game.move
    H5:clear()
    H5.LC.inGame = true
    H5.g_game.move(slotItem, { x = 0xFFFF, y = 0x40, z = 3 }, 1)
    local body = H5:last()
    ok(body ~= nil and body:byte(1) == 0x78, 'J4 a real 0x78 move went out')
    eq(body:byte(2) + body:byte(3) * 256, 0xFFFF, 'J4 fromPos.x is the synthetic 0xFFFF')
    eq(body:byte(4) + body:byte(5) * 256, 3, 'J4 fromPos.y is the inventory slot, not 65535')

    -- ---------------------------------------------------------------- J4b
    -- MAJOR: the two Game::attack guards (game.cpp:970-991) and their mirror image in
    -- Game::follow (game.cpp:993-1015).  vBot/combo.lua:294,341,347,431 and
    -- mods/game_bot/panels/attacking.lua:1085,1095 all call g_game.attack(x) with no
    -- `getAttackingCreature() ~= creature` guard of their own.
    local Hf = newHost()
    addPlayer(Hf, ORIGIN)
    fillGround(Hf, ORIGIN.x, ORIGIN.y, ORIGIN.z, 3)
    local mob = addCreature(Hf, 8100, 'Rotworm', { x = ORIGIN.x + 1, y = ORIGIN.y, z = ORIGIN.z })
    Hf.g_game.attack(mob)
    ok(Hf.g_game.getAttackingCreature() == mob, 'J4b the first attack sets the target')
    Hf:clear()
    Hf.g_game.attack(mob)
    eq(Hf.g_game.getAttackingCreature(), nil,
       'J4b attacking the SAME creature again CANCELS (game.cpp:974-977)')
    local cancel = Hf:last()
    ok(cancel ~= nil and cancel:byte(1) == 0xA1, 'J4b and the cancel is a real 0xA1')
    eq(cancel:byte(2) + cancel:byte(3) * 256 + cancel:byte(4) * 65536
       + cancel:byte(5) * 16777216, 0, 'J4b carrying creature id 0')
    Hf.g_game.attack(mob)
    ok(Hf.g_game.getAttackingCreature() == mob, 'J4b and a third call re-attacks')

    local n = Hf:count()
    Hf.g_game.attack(Hf.g_game.getLocalPlayer())
    eq(Hf:count(), n, 'J4b attack(localPlayer) puts NOTHING on the wire (game.cpp:971)')
    ok(Hf.g_game.getAttackingCreature() == mob, 'J4b and leaves the target alone')

    -- following while attacking sends a REAL cancel, not a silent local clear
    Hf:clear()
    Hf.g_game.follow(mob)
    eq(Hf:count(), 2, 'J4b follow while attacking sends TWO packets')
    eq(Hf.sent[#Hf.sent - 1]:byte(1), 0xA1, 'J4b the cancelAttack 0xA1 first (game.cpp:1002)')
    eq(Hf:last():byte(1), 0xA2, 'J4b then the 0xA2 follow')
    eq(Hf.g_game.getAttackingCreature(), nil, 'J4b and the attack really is cancelled')
    Hf.g_game.follow(mob)
    eq(Hf.g_game.getFollowingCreature(), nil,
       'J4b following the same creature again cancels too (game.cpp:999-1000)')
    local m = Hf:count()
    Hf.g_game.follow(Hf.g_game.getLocalPlayer())
    eq(Hf:count(), m, 'J4b and follow(localPlayer) is an early return')

    -- ---------------------------------------------------------------- J5
    -- MINOR: buyItem sent getSubType() where Game::buyItem (game.cpp:1390) sends
    -- getCountOrSubType(), so every stackable trade offer carried a 0x00 count byte.
    local H6 = newHost()
    addPlayer(H6, ORIGIN)
    local gold100 = H6.Item.create(ID_GOLD, 100)
    H6:clear()
    H6.g_game.buyItem(gold100, 1, false, false)
    local buy = H6:last()
    ok(buy ~= nil and buy:byte(1) == 0x7A, 'J5 a real 0x7A buyItem went out')
    eq(buy:byte(4), 100, 'J5 byte 4 is getCountOrSubType() = 100, not getSubType() = 0')
    H6:clear()
    H6.g_game.sellItem(gold100, 1, false)
    local sell = H6:last()
    ok(sell ~= nil and sell:byte(1) == 0x7B, 'J5 a real 0x7B sellItem went out')
    eq(sell:byte(4), 0, 'J5 and sellItem still sends getSubType() = 0 (game.cpp:1398)')
end

-- ============================================================================
-- K. the closed gaps (work item F): onAddThing/onRemoveThing, 0xB7, 0x96 EditText,
--    a separated turn, and the whole imbuement family -- senders AND parsers.
--    Every assertion here failed before the change that its comment names.
-- ============================================================================
S('K. closed gaps: tile things, 0xB7, edit text, turn, imbuements')
do
    local parsermod = require('proto.parser')
    local cbmod     = require('shim.callbacks')
    local buffer    = require('lib.buffer')

    --- Feed a raw server packet body (opcode byte first) through the REAL parser.
    local function feed(H, P, body)
        local R = buffer.reader(body)
        local opcode = R:u8()
        local h = parsermod.handlers[opcode]
        ok(h ~= nil, 'K parser has a handler for opcode ' .. ('0x%02X'):format(opcode))
        if h then h(P, R) end
        return R
    end

    -- ---------------------------------------------------------------- K1
    -- gap G5: onAddThing / onRemoveThing.  state:addThing and state:_removeAt now carry
    -- a hook, GATED on the same flag as tile.cpp:374-376 / 420-422.
    local H = newHost()
    addPlayer(H, ORIGIN)
    fillGround(H, ORIGIN.x, ORIGIN.y, ORIGIN.z, 3)
    local added, removed = {}, {}
    local cb = {
        onAddThing    = function(tile, thing) added[#added + 1] = { tile, thing } end,
        onRemoveThing = function(tile, thing) removed[#removed + 1] = { tile, thing } end,
    }
    local h = cbmod.install(H.LC, cb, { reg = H.reg, g_game = H.g_game })

    local dropPos = { x = ORIGIN.x + 1, y = ORIGIN.y, z = ORIGIN.z }
    eq(H.g_game.isTileThingLuaCallbackEnabled(), false, 'K1 the gate starts OFF (game.h:431)')
    H.st:addThing(dropPos, -1, { kind = 'item', id = ID_GOLD, count = 7 })
    eq(#added, 0, 'K1 and with the gate off nothing fires -- it costs one boolean')

    H.g_game.enableTileThingLuaCallback(true)
    eq(H.g_game.isTileThingLuaCallbackEnabled(), true, 'K1 the gate reads back on')
    local corpse = { kind = 'item', id = ID_CORPSE }
    local sp = H.st:addThing(dropPos, -1, corpse)
    eq(#added, 1, 'K1 onAddThing fired once for the corpse')
    ok(added[1][1] == H.g_map.getTile(dropPos),
       'K1 with the INTERNED Tile wrapper (connect(Tile,...) prepends the receiver)')
    eq(added[1][2]:getId(), ID_CORPSE, 'K1 and an Item wrapper for the thing')
    local addedPos = added[1][2]:getPosition()
    eq(addedPos.x, dropPos.x, 'K1 addressed at the tile it landed on')
    eq(added[1][2]:getStackPos(), sp, 'K1 with the stack index state:addThing returned')

    H.st:removeThing(dropPos, sp)
    eq(#removed, 1, 'K1 onRemoveThing fired once')
    eq(removed[1][2]:getId(), ID_CORPSE, 'K1 and carries the thing that LEFT')

    -- a creature thing becomes a Creature wrapper, not an Item
    addCreature(H, 9001, 'Rat', dropPos)
    eq(#added, 2, 'K1 a creature landing on a tile fires onAddThing too')
    eq(added[2][2]:getName(), 'Rat', 'K1 as a Creature wrapper')
    ok(added[2][2]:isCreature(), 'K1 ... which knows it is one')

    H.g_game.enableTileThingLuaCallback(false)
    local before = #added
    H.st:addThing(dropPos, -1, { kind = 'item', id = ID_GOLD, count = 1 })
    eq(#added, before, 'K1 turning the gate off again silences it')
    h:remove()
    H.g_game.enableTileThingLuaCallback(true)
    H.st:addThing(dropPos, -1, { kind = 'item', id = ID_GOLD, count = 1 })
    eq(#added, before, 'K1 and handle:remove() unhooks reg.onTileThing')

    -- ------------------------------------------------------------- K1b
    -- The same "the removal event has to carry what LEFT" rule as the blocker, applied to
    -- the other two removal paths: Container::onRemoveItem(container, slot, item) and
    -- LocalPlayer::onInventoryChange(slot, item, oldItem) (localplayer.cpp:523).
    local Hr = newHost()
    addPlayer(Hr, ORIGIN)
    local gone, unequipped = {}, {}
    local cbr = {
        onRemoveItem = function(c, slot, item) gone[#gone + 1] = item end,
        onInventoryChange = function(p, slot, item, old)
            unequipped[#unequipped + 1] = { slot = slot, item = item, old = old }
        end,
    }
    local hr = cbmod.install(Hr.LC, cbr, { reg = Hr.reg, g_game = Hr.g_game })
    Hr.st.containers[4] = { id = 4, name = 'bag', capacity = 8, firstIndex = 0, size = 2,
                            items = { { kind = 'item', id = ID_GOLD, count = 9 },
                                      { kind = 'item', id = ID_BP } },
                            hasParent = false, isUnlocked = true }
    local Pr = parsermod.new(Hr.st, function(n, d) Hr.bus:emit(n, d) end)
    Pr.emit('containerRemoveItem', { containerId = 4, slot = 0,
                                     item = table.remove(Hr.st.containers[4].items, 1) })
    ok(gone[1] ~= nil, 'K1b onRemoveItem carries the item that LEFT')
    eq(gone[1] and gone[1]:getId(), ID_GOLD, 'K1b by id')
    Hr.st.player.inventory[3] = { kind = 'item', id = ID_BP }
    Pr.emit('inventoryChange', { slot = 3, item = nil,
                                 oldItem = Hr.st.player.inventory[3] })
    ok(unequipped[1] and unequipped[1].old ~= nil,
       'K1b onInventoryChange carries oldItem (localplayer.cpp:523)')
    eq(unequipped[1] and unequipped[1].old and unequipped[1].old:getId(), ID_BP,
       'K1b the item that was unequipped')
    eq(unequipped[1] and unequipped[1].item, nil, 'K1b and nil for the new one')
    hr:remove()

    -- ---------------------------------------------------------------- K2
    -- gap G3: opcode 0xB7 UnjustifiedStats really parsed, off a real packet.
    local H2 = newHost()
    addPlayer(H2, ORIGIN)
    local got
    local cb2 = {}
    local h2 = cbmod.install(H2.LC, cb2, { reg = H2.reg, g_game = H2.g_game })
    H2.bus:on('unjustifiedPoints', function(u) got = u end)
    local P2 = parsermod.new(H2.st, function(n, d) H2.bus:emit(n, d) end)
    feed(H2, P2, string.char(0xB7, 12, 3, 40, 5, 60, 9, 77))
    ok(got ~= nil, 'K2 the parser emits unjustifiedPoints for 0xB7')
    eq(got.killsDay, 12, 'K2 killsDay')
    eq(got.killsDayRemaining, 3, 'K2 killsDayRemaining')
    eq(got.killsWeek, 40, 'K2 killsWeek')
    eq(got.killsWeekRemaining, 5, 'K2 killsWeekRemaining')
    eq(got.killsMonth, 60, 'K2 killsMonth')
    eq(got.killsMonthRemaining, 9, 'K2 killsMonthRemaining')
    eq(got.skullTime, 77, 'K2 skullTime')
    local u = H2.g_game.getUnjustifiedPoints()
    eq(u.killsWeekRemaining, 5, 'K2 and g_game.getUnjustifiedPoints answers the real bytes')
    eq(math.min(u.killsDayRemaining, u.killsWeekRemaining, u.killsMonthRemaining), 3,
       'K2 so vlib.lua:223-227 killsToRs() is 3, not a placeholder')
    h2:remove()

    -- ---------------------------------------------------------------- K3
    -- onGameEditText: opcode 0x96 EditText was consumed and discarded.
    local H3 = newHost()
    addPlayer(H3, ORIGIN)
    local edit
    local cb3 = { onGameEditText = function(id, itemId, maxLength, text, writer, date)
        edit = { id = id, itemId = itemId, maxLength = maxLength, text = text,
                 writer = writer, date = date }
    end }
    local h3 = cbmod.install(H3.LC, cb3, { reg = H3.reg, g_game = H3.g_game })
    local P3 = parsermod.new(H3.st, function(n, d) H3.bus:emit(n, d) end)
    -- u32 windowId, [item], u16 maxLength, string text, string writer, u8 suffix
    local w = buffer.writer()
    w:u8(0x96); w:u32(4242); w:u16(ID_GOLD); w:u8(1)      -- a stackable item: count byte
    -- GameWritableDate is on at 1530, so the date string is part of the packet
    w:u16(128); w:string('a note'); w:string('Testchar'); w:u8(0); w:string('06/09/2026')
    feed(H3, P3, w:data())
    ok(edit ~= nil, 'K3 onGameEditText fires (was: no parser for 0x96)')
    eq(edit and edit.id, 4242, 'K3 the window id')
    eq(edit and edit.itemId, ID_GOLD, 'K3 the item id')
    eq(edit and edit.maxLength, 128, 'K3 the max length')
    eq(edit and edit.text, 'a note', 'K3 the text')
    eq(edit and edit.writer, 'Testchar', 'K3 the writer')
    eq(edit and edit.date, '06/09/2026', 'K3 and the GameWritableDate string')
    h3:remove()

    -- ---------------------------------------------------------------- K4
    -- onTurn: the dedicated turn packet shape (Proto::Creature, "this is send creature
    -- turn", protocolgameparse.cpp:4483-4494) is separated out instead of being folded
    -- into a move.  It reports a DIRECTION change and no position change.
    local H4 = newHost()
    addPlayer(H4, ORIGIN)
    fillGround(H4, ORIGIN.x, ORIGIN.y, ORIGIN.z, 3)
    local turnPos = { x = ORIGIN.x + 1, y = ORIGIN.y, z = ORIGIN.z }
    addCreature(H4, 9100, 'Rat', turnPos)
    local turns, moves = {}, {}
    local cb4 = {
        onTurn = function(c, dir) turns[#turns + 1] = { c, dir } end,
        onWalk = function(c, from, to) moves[#moves + 1] = c end,
    }
    local h4 = cbmod.install(H4.LC, cb4, { reg = H4.reg, g_game = H4.g_game })
    local P4 = parsermod.new(H4.st, function(n, d) H4.bus:emit(n, d) end)
    -- readCreature ty == 99 (Proto::Creature): u32 id, u8 direction, u8 unpass
    P4:applyCreature({ id = 9100, direction = 3, unpass = 0, turnOnly = true })
    eq(#turns, 1, 'K4 onTurn fires for a turn-only creature update')
    eq(turns[1][2], 3, 'K4 with the new direction')
    eq(turns[1][1]:getName(), 'Rat', 'K4 and the creature')
    eq(turns[1][1]:getDirection(), 3, 'K4 which now reports it')
    eq(#moves, 0, 'K4 and a turn is NOT reported as a walk')
    h4:remove()

    -- ---------------------------------------------------------------- K5
    -- blocker B2: the imbuement family.  Senders first -- byte-exact against
    -- protocolgamesend.cpp:1735-1775 and 1887-1893.
    local H5 = newHost()
    addPlayer(H5, ORIGIN)
    H5:clear()
    H5.g_game.applyImbuement(2, 0x1234, true)
    local b = H5:last()
    eq(b:byte(1), 0xD5, 'K5 applyImbuement is 0xD5')
    eq(b:byte(2), 2, 'K5 u8 slot')
    eq(b:byte(3) + b:byte(4) * 256 + b:byte(5) * 65536 + b:byte(6) * 16777216, 0x1234,
       'K5 u32 imbuementId')
    eq(#b, 6, 'K5 and NO protection byte at cv 1530 (that is a cv < 1510 field)')

    H5:clear(); H5.g_game.clearImbuement(3)
    b = H5:last()
    eq(b:byte(1), 0xD6, 'K5 clearImbuement is 0xD6'); eq(b:byte(2), 3, 'K5 u8 slot')
    eq(#b, 2, 'K5 two bytes exactly')

    H5:clear(); H5.g_game.closeImbuingWindow()
    b = H5:last()
    eq(b:byte(1), 0xD7, 'K5 closeImbuingWindow is 0xD7'); eq(#b, 1, 'K5 and empty')

    H5:clear(); H5.g_game.imbuementDurations(true)
    b = H5:last()
    eq(b:byte(1), 0x60, 'K5 imbuementDurations is 0x60'); eq(b:byte(2), 1, 'K5 isOpen = 1')
    H5:clear(); H5.g_game.imbuementDurations(false)
    eq(H5:last():byte(2), 0, 'K5 and 0 for the off toggle imbuing.lua:237 sends first')

    H5:clear(); H5.g_game.selectImbuementItem(ID_GOLD, { x = 0xFFFF, y = 3, z = 0 }, 0)
    b = H5:last()
    eq(b:byte(1), 0xB2, 'K5 selectImbuementItem is 0xB2 ImbuementWindowAction')
    eq(b:byte(2), 1, 'K5 with type 1 = IMBUEMENT_WINDOW_SELECT_ITEM (const.h:993)')
    eq(b:byte(3) + b:byte(4) * 256, 0xFFFF, 'K5 then the position')
    eq(b:byte(8) + b:byte(9) * 256, ID_GOLD, 'K5 then the item id')
    eq(#b, 10, 'K5 opcode + type + pos(5) + id(2) + stackpos(1)')

    H5:clear(); H5.g_game.selectImbuementScroll()
    b = H5:last()
    eq(b:byte(1), 0xB2, 'K5 selectImbuementScroll is 0xB2 too')
    eq(b:byte(2), 2, 'K5 with type 2 = SCROLL')
    eq(#b, 2, 'K5 and the SCROLL branch writes NO position (protocolgamesend.cpp:1768)')

    -- ---------------------------------------------------------------- K6
    -- ... and the parsers, driven into the user's own signal names.
    local H6 = newHost()
    addPlayer(H6, ORIGIN)
    local tracker, window, closed
    H6.g_game.onUpdateImbuementTracker = function(list) tracker = list end
    H6.g_game.onImbuementItem = function(itemId, tier, slots, active, imbus, needed)
        window = { itemId = itemId, tier = tier, slots = slots, active = active,
                   imbuements = imbus, needed = needed }
    end
    H6.g_game.onCloseImbuementWindow = function() closed = true end
    local h6 = cbmod.install(H6.LC, {}, { reg = H6.reg, g_game = H6.g_game,
                                          signalcall = function(slot, ...)
                                              if type(slot) == 'function' then return slot(...) end
                                          end })
    local P6 = parsermod.new(H6.st, function(n, d) H6.bus:emit(n, d) end)

    -- 0x5D: u8 count, then per item: u8 slot, [item], u8 slots, per slot u8 imbued
    --       and when imbued: string name, u16 icon, u32 duration, u8 state
    local w6 = buffer.writer()
    w6:u8(0x5D); w6:u8(1)
    w6:u8(5); w6:u16(ID_BP); w6:u8(0)            -- slot 5, a backpack: id + containerType
    w6:u8(2)                                     -- two imbuing slots
    w6:u8(1); w6:string('Vampirism'); w6:u16(101); w6:u32(180000); w6:u8(1)
    w6:u8(0)                                     -- slot 1 empty
    feed(H6, P6, w6:data())
    ok(tracker ~= nil, 'K6 onUpdateImbuementTracker fires for 0x5D (was discarded)')
    eq(tracker and #tracker, 1, 'K6 one tracked item')
    eq(tracker and tracker[1].slot, 5, 'K6 the equipment slot')
    eq(tracker and tracker[1].totalSlots, 2, 'K6 the total imbuing slots')
    ok(tracker and tracker[1].item and tracker[1].item:getId() == ID_BP,
       'K6 entry.item is a real Item wrapper (imbuing.lua:155 calls it:getId())')
    eq(tracker and tracker[1].slots[0] and tracker[1].slots[0].name, 'Vampirism',
       'K6 the imbuement name')
    eq(tracker and tracker[1].slots[0] and tracker[1].slots[0].duration, 180000,
       'K6 and its remaining duration')
    eq(tracker and tracker[1].slots[1], nil, 'K6 while an empty slot is absent')

    -- 0xEB windowType 1 (SELECT_ITEM), modern layout: u8 type, u8 unknown, u16 itemId,
    -- [u8 tier iff classified], u8 slots, per slot u8 flag + imbuement + u32 + u32,
    -- u16 imbuementCount + imbuements, u32 neededCount + (u16 id, u16 count)*
    local function writeImbuement(ww, id, name)
        ww:u32(id); ww:string(name); ww:string('desc')
        ww:u8(0)                                  -- tier (cv >= 1510)
        ww:u16(555)                               -- iconId
        ww:u32(180000)                            -- duration
        ww:u8(1); ww:u16(ID_GOLD); ww:string('gold coin'); ww:u16(3)   -- 1 source
        ww:u32(25000)                             -- cost
    end
    local w7 = buffer.writer()
    w7:u8(0xEB); w7:u8(1); w7:u8(0); w7:u16(ID_BP)
    w7:u8(1)                                      -- one imbuing slot
    w7:u8(0x01); writeImbuement(w7, 7, 'Vampirism'); w7:u32(120000); w7:u32(5000)
    w7:u16(1); writeImbuement(w7, 8, 'Swiftness')
    w7:u32(1); w7:u16(ID_GOLD); w7:u16(100)
    feed(H6, P6, w7:data())
    ok(window ~= nil, 'K6 onImbuementItem fires for 0xEB SELECT_ITEM')
    eq(window and window.itemId, ID_BP, 'K6 the item the shrine is showing')
    eq(window and window.slots, 1, 'K6 the slot count')
    ok(window and window.active[0], 'K6 activeSlots is 0-based, like the C++ map')
    eq(window and window.active[0] and window.active[0][1].name, 'Vampirism',
       'K6 activeSlots[i][1] is the Imbuement (imbuing.lua:194 reads tup[1])')
    eq(window and window.active[0] and window.active[0][2], 120000,
       'K6 activeSlots[i][2] is the duration (imbuing.lua:199 reads tup[2])')
    eq(window and window.active[0] and window.active[0][1].group, 'Basic',
       'K6 with the tier name the C++ derives at cv >= 1510')
    eq(window and #window.imbuements, 1, 'K6 the offered list')
    eq(window and window.imbuements[1].name, 'Swiftness', 'K6 by name')
    eq(window and window.imbuements[1].id, 8, 'K6 and id (imbuing.lua:207)')
    eq(window and #window.needed, 1, 'K6 the needed-items list')
    ok(window and window.needed[1]:getId() == ID_GOLD, 'K6 as Item wrappers')

    feed(H6, P6, string.char(0xEC))
    eq(closed, true, 'K6 onCloseImbuementWindow fires for 0xEC')
    h6:remove()
end

S('L. review fix: g_game fight-mode defaults match game.cpp construction')
do
    -- game.cpp:69-70: m_pvpMode = WhiteDove(0), m_safeFight = true.  Before the fix this
    -- shim started safeFight at `false`, so a ported vBot script calling isSafeFight()
    -- before ever calling a setter (or before the first live 0xA7 PlayerModes update) saw
    -- the opposite of what the real client would report at the same point.
    local H = newHost()
    eq(H.g_game.isSafeFight(), true, 'isSafeFight defaults true, like m_safeFight at construction')
    eq(H.g_game.getPVPMode(), 0, 'getPVPMode defaults to WhiteDove(0)')
    eq(H.g_game.getChaseMode(), 0, 'getChaseMode defaults to DontChase(0)')
end

-- ============================================================================
io.write('\n================ shim game suite (S1) ================\n')
for _, m in ipairs(msgs) do io.write(m, '\n') end
io.write(('  TOTAL: %d passed, %d failed  -> %s\n')
         :format(pass, fail, fail == 0 and 'PASS' or 'FAIL'))

if _G.SHIMGAME_NO_EXIT then return { pass = pass, fail = fail, failures = msgs } end
os.exit(fail == 0 and 0 or 1)
