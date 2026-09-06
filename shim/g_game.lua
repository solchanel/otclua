--[[============================================================================
shim/g_game.lua -- `g_game` (work item S1, PLAN sec.1.20, api-game.md sec.1).

World mutators go to `proto/sender.lua`; accessors read `game/state.lua`.  Every byte-level
decision below is taken from `src/client/game.cpp`, because the *arguments* the C++ puts on
the wire are derived from the object model (`thing->getPosition()`, `thing->getStackPos()`),
not from what vBot passes -- so invariant I3 in shim/item.lua is what makes these correct.

THE FIVE THINGS THAT MUST BE EXACTLY RIGHT
------------------------------------------
 * `walk(dir)` returns **false** when the step is refused.  `cavebot/walking.lua:294` reads
   `if g_game.walk(nextDir, false) ~= false then` and only then advances its ledger; a
   truthy return on a refused step desynchronises the whole walk queue.  (I4: the second
   argument is ignored, not rejected.)
 * `attack(creature)` must make `getAttackingCreature()` answer THAT creature on the very
   next line -- vBot polls it synchronously (api-game.md sec.1.2, gap G1).
 * `open(item, previousContainer)` returns the container INDEX it will open into, and reuses
   `previousContainer:getId()` when one is given -- that is what makes a container open
   *in place* (game.cpp:935-944).
 * `getUnjustifiedPoints()` must return a TABLE with killsDayRemaining / killsWeekRemaining /
   killsMonthRemaining -- `vBot/vlib.lua:224-226` calls `math.min` on all three and nil
   crashes it (gap G3).
 * `getClientVersion()` / `getProtocolVersion()` are 1530: all 26 call sites are version
   gates (`>= 960`, `>= 860`, `< 780`, `>= 810`, `< 1090`).

PREWALK (invariant I2, PLAN sec.6.4)
------------------------------------
`walk()` performs the LocalPlayer prewalk bookkeeping in `state.player.preWalks`, and
retires it exactly like `LocalPlayer::walk` (localplayer.cpp:65-79): on a confirmed move,
pop the FRONT prewalk if it matches, otherwise clear the queue.  The confirmation comes from
the parser's `positionChange` event, which proto/parser.lua emits exactly once per real move.
A safety timer mirrors `registerAdjustInvalidPosEvent` (localplayer.cpp:151-158) and clears
the queue after `min(max(stepDuration, ping) + 100, 1000)` ms so a lost confirmation can
never strand the predicted position.

THREE SENDERS DO NOT EXIST YET in proto/sender.lua (gaps G9/G10): `partyInvite`, `partyJoin`
and `stashStowItem`.  They are built here, against the same `sender:_send(writer)` path
(so the send counter and the dead-transport error handling stay honest), and a
crossFileRequest asks for them to be moved into proto/sender.lua where they belong.
============================================================================]]

local objects = require('shim.object')
local posmod  = require('shim.position')
local buffer  = require('lib.buffer')
local sys     = require('lib.sys')

local M = {}

local floor, max, min, abs = math.floor, math.max, math.min, math.abs

-- Proto::Creature -- the pseudo thing id a creature is moved by (game.cpp:810).
local PROTO_CREATURE = 0x63

-- Client opcodes proto/sender.lua does not build yet.
local OP_STASH_STOW      = 0x28    -- Proto::ClientUseStash (protocolcodes.h:268)
local OP_INVITE_TO_PARTY = 0xA3    -- Proto::ClientInviteToParty (protocolcodes.h:343)
local OP_JOIN_PARTY      = 0xA4    -- Proto::ClientJoinParty (protocolcodes.h:344)

local CLIENT_VERSION   = 1530
local PROTOCOL_VERSION = 1530
local WALK_MAX_STEPS   = 2         -- Game::getWalkMaxSteps default

-- Otc::Direction validity (const.h:158-170); 8 is InvalidDirection.
local function validDir(d)
    return type(d) == 'number' and d >= 0 and d <= 7 and d == floor(d)
end

-- ---------------------------------------------------------------------------
function M.new(LC, reg, opts)
    opts = opts or {}
    local st = LC.state
    local g  = {}

    local sender = function() return LC.sender end

    -- ------------------------------------------------------------------ state
    local attackingId, followingId = 0, 0
    local features   = {}
    -- game.cpp:69-70's own construction defaults: m_fightMode = FightBalanced(unused by
    -- this shim's own callers, which pass their own `mode`), m_chaseMode = DontChase,
    -- m_pvpMode = WhiteDove(0), m_safeFight = true.  REVIEW FIX: this used to start
    -- safeFight at `false`, so a ported vBot script calling g_game.isSafeFight() before
    -- ever calling a setter itself (or before the first live 0xA7 PlayerModes update) got
    -- the opposite of what the real client would report at the same point.
    local fightMode, chaseMode, safeFight, pvpMode = 1, 0, true, 0
    local tileThingLuaCallback = false
    local unjustified = { killsDay = 0, killsDayRemaining = 0,
                          killsWeek = 0, killsWeekRemaining = 0,
                          killsMonth = 0, killsMonthRemaining = 0,
                          skullTime = 0 }
    local preWalkTimer = nil

    g._reg = reg

    -- Game::canPerformGameAction (game.cpp): a local player AND an online session.
    local function canAct()
        if not LC.inGame then return false end
        if not (st.player and st.player.id and st.player.id ~= 0) then return false end
        return true
    end
    g.canPerformGameAction = canAct

    -- ------------------------------------------------------------- prewalk
    local function preWalks()
        local pl = st.player
        if not pl then return nil end
        pl.preWalks = pl.preWalks or {}
        return pl.preWalks
    end

    local function clearPreWalks()
        local pw = preWalks()
        if pw then for i = #pw, 1, -1 do pw[i] = nil end end
        if preWalkTimer and LC.sched then LC.sched.cancel(preWalkTimer) end
        preWalkTimer = nil
    end
    g.resetPreWalk = clearPreWalks

    -- LocalPlayer::walk (localplayer.cpp:65-79) -- the confirmation half.
    local function onConfirmedMove(newPos)
        local pw = preWalks()
        if not (pw and #pw > 0) then return end
        local front = pw[1]
        if front and front.x == newPos.x and front.y == newPos.y and front.z == newPos.z then
            table.remove(pw, 1)
            if #pw == 0 and preWalkTimer and LC.sched then
                LC.sched.cancel(preWalkTimer); preWalkTimer = nil
            end
            return
        end
        clearPreWalks()
    end

    -- `LC.events` is the lib/events MODULE in main.lua (function-call form) but a Bus
    -- INSTANCE in tests and in the hub worker (method form).  Support both rather than
    -- forcing either side to change.
    local function busOn(bus, name, fn)
        if rawget(bus, '_named') ~= nil then return bus:on(name, fn) end
        return bus.on(name, fn)
    end
    local function busOff(bus, handle)
        if rawget(bus, '_named') ~= nil then return bus:off(handle) end
        return bus.off(handle)
    end

    local posHandle
    if LC.events and LC.events.on then
        posHandle = busOn(LC.events, 'positionChange', function(d)
            if d and d.pos then onConfirmedMove(d.pos) end
        end)
    end

    -- registerAdjustInvalidPosEvent (localplayer.cpp:151-158)
    local function armPreWalkTimeout()
        if not (LC.sched and LC.sched.after) then return end
        if preWalkTimer then LC.sched.cancel(preWalkTimer) end
        local player = reg:localPlayer()
        local dur = 0
        local ok, v = pcall(player.getStepDuration, player, true)
        if ok and type(v) == 'number' then dur = v end
        local ms = min(max(dur, g.getPing()) + 100, 1000)
        preWalkTimer = LC.sched.after(ms, function()
            preWalkTimer = nil
            clearPreWalks()
        end)
    end

    -- ------------------------------------------------------------- helpers
    -- Game::findEmptyContainerId (game.cpp:1786): the smallest id not currently open.
    local function findEmptyContainerId()
        local id = 0
        while st.containers[id] ~= nil do id = id + 1 end
        return id
    end
    g.findEmptyContainerId = findEmptyContainerId

    -- The source position the C++ puts on the wire for a thing: its own position, or the
    -- synthetic "item in inventory" address when that is invalid (game.cpp:846/873/900).
    local function sourcePos(thing)
        local p = thing and thing.getPosition and thing:getPosition()
        if posmod.isValid(p) then return p end
        return posmod.virtualInventory()
    end

    local function stackPosOf(thing)
        if not (thing and thing.getStackPos) then return 0 end
        local sp = thing:getStackPos()
        if type(sp) ~= 'number' or sp < 0 then return 0 end
        return sp
    end

    -- =======================================================================
    -- world mutators
    -- =======================================================================

    -- Game::open (game.cpp:935-944).  Returns the container index it will open into.
    function g.open(item, previousContainer)
        if not (canAct() and item) then return -1 end
        local s = sender()
        if not s then reg:report('g_game.open', 'no sender'); return -1 end
        local id = previousContainer and previousContainer.getId and previousContainer:getId()
                   or findEmptyContainerId()
        s:openContainer(item:getPosition(), item:getId(), stackPosOf(item), id)
        return id
    end

    function g.openParent(container)
        if not (canAct() and container) then return end
        local s = sender(); if not s then return end
        return s:upContainer(container:getId())
    end

    function g.close(container)
        if not (canAct() and container) then return end
        local s = sender(); if not s then return end
        return s:closeContainer(container:getId())
    end

    function g.refreshContainer() return nil end        -- 0 vBot call sites

    -- Game::move (game.cpp:802-812).  count <= 0 -> 1; a move onto its own position is a
    -- no-op; a CREATURE is moved by the pseudo id 0x63.
    function g.move(thing, toPos, count)
        if not (canAct() and thing and posmod.is(toPos)) then return end
        if type(count) ~= 'number' or count <= 0 then count = 1 end
        local from = thing:getPosition()
        if posmod.equals(from, toPos) then return end
        local s = sender(); if not s then reg:report('g_game.move', 'no sender'); return end
        local thingId = thing:isCreature() and PROTO_CREATURE or thing:getId()
        return s:move(from, thingId, stackPosOf(thing), toPos, count)
    end

    -- Game::moveToParentContainer (game.cpp:814-821): the same position with z = 254.
    function g.moveToParentContainer(thing, count)
        if not (canAct() and thing) then return end
        local p = thing:getPosition()
        return g.move(thing, { x = p.x, y = p.y, z = 254 }, count)
    end

    -- ---------------------------------------------------------------- use echo
    -- In the live client the SERVER never announces our own use; `g_game.onUse` is
    -- emitted client-side by Game::use itself (game.cpp:851) and that is what the
    -- sandbox's onUse/onUseWith callbacks listen to.  The shim reproduces exactly
    -- that: the hook fields below are nil until shim/callbacks.lua installs them,
    -- and `_acceptsUseHook` is how it knows the fields are honoured at all (a
    -- nil-valued field is indistinguishable from an unsupported one).
    g._acceptsUseHook = true
    g._onUse, g._onUseWith = nil, nil
    local function echoUse(pos, itemId, stackPos, subType)
        local h = rawget(g, '_onUse')
        if h then pcall(h, pos, itemId, stackPos, subType) end
    end
    local function echoUseWith(pos, itemId, target, subType)
        local h = rawget(g, '_onUseWith')
        if h then pcall(h, pos, itemId, target, subType) end
    end

    -- Game::use (game.cpp:839-853): the index byte carries findEmptyContainerId(), which is
    -- what lets a parcel-shaped item open as a container.
    function g.use(thing)
        if not (canAct() and thing) then return end
        local s = sender(); if not s then reg:report('g_game.use', 'no sender'); return end
        local pos, id, sp = sourcePos(thing), thing:getId(), stackPosOf(thing)
        local r = s:use(pos, id, sp, findEmptyContainerId())
        echoUse(pos, id, sp, 0)
        return r
    end

    -- Game::useInventoryItem (game.cpp:855-864)
    function g.useInventoryItem(itemId, _subType)
        if not canAct() then return end
        local s = sender(); if not s then return end
        local pos = posmod.virtualInventory()
        local r = s:use(pos, itemId, 0, 0)
        echoUse(pos, itemId, 0, _subType or 0)
        return r
    end

    -- Game::useWith (game.cpp:866-881).  The third argument vBot sometimes passes
    -- (`useWith(tmpItem, target, subType)`) is ignored by the C++ binder -- I4.
    function g.useWith(item, toThing, _subType)
        if not (canAct() and item and toThing) then return end
        local s = sender(); if not s then reg:report('g_game.useWith', 'no sender'); return end
        local pos = sourcePos(item)
        local r
        if toThing:isCreature() then
            r = s:useOnCreature(pos, item:getId(), stackPosOf(item), toThing:getId())
        else
            r = s:useWith(pos, item:getId(), stackPosOf(item),
                          toThing:getPosition(), toThing:getId(), stackPosOf(toThing))
        end
        echoUseWith(pos, item:getId(), toThing, _subType or 0)
        return r
    end

    -- Game::useInventoryItemWith (game.cpp:883-907).  cv 1530 >= 780, so the synthetic
    -- source position and stackpos 0 go straight out; there is no hotkey opcode at 1530.
    function g.useInventoryItemWith(itemId, toThing, _subType)
        if not (canAct() and toThing) then return end
        local s = sender(); if not s then return end
        local pos = posmod.virtualInventory()
        local r
        if toThing:isCreature() then
            r = s:useOnCreature(pos, itemId, 0, toThing:getId())
        else
            r = s:useWith(pos, itemId, 0, toThing:getPosition(), toThing:getId(), stackPosOf(toThing))
        end
        echoUseWith(pos, itemId, toThing, _subType or 0)
        return r
    end

    function g.equipItem(item)
        if not (canAct() and item) then return end
        local s = sender(); if not s then return end
        return s:equipItem(item:getId(), item:getTier() or 0)
    end

    function g.equipItemId(itemId, tier)
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:equipItem(itemId, tier or 0)
    end

    function g.look(thing, isBattleList)
        if not (canAct() and thing) then return end
        local s = sender(); if not s then return end
        if isBattleList and thing.isCreature and thing:isCreature() then
            return s:lookCreature(thing:getId())
        end
        return s:look(thing:getPosition(), thing:getId(), stackPosOf(thing))
    end

    function g.rotate(thing)
        reg:report('g_game.rotate', 'no 0x85 builder in proto/sender.lua (0 vBot call sites)')
        return nil
    end

    -- G10: opcode 0x28 -- u8 action, Position(5), u16 itemId, u8 stackpos, [u32 count when
    -- action == SUPPLY_STASH_ACTION_STOW_ITEM(0)].  protocolgamesend.cpp:1815-1828.
    function g.stashStowItem(position, itemId, count, stackpos, action)
        if not canAct() then return end
        local s = sender(); if not s then reg:report('g_game.stashStowItem', 'no sender'); return end
        if not posmod.is(position) then return end
        action = action or 0
        local w = buffer.writer()
        w:u8(OP_STASH_STOW)
        w:u8(action)
        w:u16(position.x); w:u16(position.y); w:u8(position.z)
        w:u16(itemId or 0)
        w:u8(stackpos or 0)
        if action == 0 then w:u32(count or 0) end
        return s:_send(w)
    end

    -- =======================================================================
    -- movement
    -- =======================================================================
    -- Game::walk (game.cpp:671-681) returns false ONLY for !canPerformGameAction() and an
    -- invalid direction.  A refused SEND (dead transport) is added here and also answers
    -- false, because a packet that never left must not advance cavebot's walk ledger.
    function g.walk(dir, _ignored)
        if not canAct() then return false end
        if not validDir(dir) then return false end
        local s = sender()
        if not s then reg:report('g_game.walk', 'no sender'); return false end

        -- prewalk BEFORE the send, like Game::autoWalk/LocalPlayer::preWalk: getPosition()
        -- must already answer the predicted tile when the caller looks at it next.
        local player = reg:localPlayer()
        local from = player:getPosition()
        local body, err = s:walk(dir)
        if not body then
            if LC.log and LC.log.debug then
                LC.log.debug('shim: g_game.walk(%s) refused: %s', tostring(dir), tostring(err))
            end
            return false
        end
        if posmod.isValid(from) then
            local pw = preWalks()
            if pw and #pw < WALK_MAX_STEPS then
                pw[#pw + 1] = posmod.translatedToDirection(from, dir)
                armPreWalkTimeout()
            end
        end
        return true
    end

    -- Game::autoWalk (game.cpp:683-711).  vBot always calls it as
    -- `autoWalk(path, {x=0,y=0,z=0})` -- the zero startPos is the documented
    -- "no prewalk animation" trick, and with it the C++ preWalk branch cannot fire.
    function g.autoWalk(dirs, startPos)
        if not canAct() then return end
        if type(dirs) ~= 'table' or #dirs == 0 then return end
        if #dirs > 127 then
            if LC.log and LC.log.error then LC.log.error('shim: auto walk path too great') end
            return
        end
        local s = sender(); if not s then return end
        if followingId ~= 0 then g.cancelFollow() end
        clearPreWalks()
        local body, sent = s:autoWalk(dirs)
        if body and sent and sent < #dirs and LC.log and LC.log.warn then
            LC.log.warn('shim: autoWalk clamped to %d of %d steps', sent, #dirs)
        end
        return body
    end

    function g.stop()
        if not canAct() then return end
        local s = sender(); if not s then return end
        clearPreWalks()
        return s:stop()
    end

    function g.turn(dir)
        if not (canAct() and validDir(dir)) then return end
        local s = sender(); if not s then return end
        if dir > 3 then return end                 -- only the four cardinals have an opcode
        return s:turn(dir)
    end

    function g.getWalkMaxSteps() return WALK_MAX_STEPS end

    -- =======================================================================
    -- talk
    -- =======================================================================
    function g.talk(text)
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:talk(1, 0, '', text)                            -- MessageModeSay
    end

    function g.talkChannel(mode, channelId, text)
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:talk(mode, channelId, '', text)
    end

    function g.talkPrivate(mode, receiver, text)
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:talk(mode, 0, receiver, text)
    end

    -- gunz OS && cv >= 1525: EVERY 0x96 ends with an aimMode byte, and a plain `talk` for a
    -- 15.25+ spell is rejected server-side (functions/player.lua:82-89) -- so this path is
    -- load-bearing, not cosmetic.
    function g.talkSpell(text, aimMode, aimPos, mode)
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:talkSpell(text, aimMode or 0, aimPos, mode)
    end

    -- =======================================================================
    -- combat / targeting
    -- =======================================================================
    -- G1: the client caches the target so `getAttackingCreature()` answers on the NEXT LINE.
    -- Game::attack (game.cpp:970-991) has three guards, and vBot leans on all three:
    --   1. `creature == m_localPlayer` -> return, no packet at all;
    --   2. "cancel when attacking again" -- re-attacking the CURRENT target sets
    --      creature = nullptr, i.e. it TOGGLES the attack off and sends id 0.  Unguarded
    --      re-attacks exist at vBot/combo.lua:294,341,347,431 and
    --      mods/game_bot/panels/attacking.lua:1085,1095;
    --   3. the follow is cancelled with a real packet (`cancelFollow`), not silently.
    function g.attack(creature)
        if not canAct() then return end
        local s = sender(); if not s then reg:report('g_game.attack', 'no sender'); return end
        if creature ~= nil and creature == reg:localPlayer() then return end
        if creature ~= nil and creature.getId and creature:getId() == attackingId
           and attackingId ~= 0 then
            creature = nil                                -- cancel when attacking again
        end
        local id = (creature and creature.getId) and creature:getId() or 0
        local old = attackingId ~= 0 and reg:creature(attackingId) or nil
        if id ~= 0 and followingId ~= 0 then g.cancelFollow() end
        local body = s:attack(id)
        if body == nil and id ~= 0 then return end       -- refused: do not fake a target
        attackingId = id
        if g.onAttackingCreatureChange then
            pcall(g.onAttackingCreatureChange, creature, old)
        end
        return body
    end

    -- Game::follow (game.cpp:993-1015) is the mirror image of attack, with the SAME three
    -- guards -- following yourself is an early return, re-following the current target
    -- cancels, and the attack is cancelled with a real packet (`cancelAttack()`, which is
    -- `attack(nullptr)`).  Fixing attack and leaving follow alone would just move the bug.
    function g.follow(creature)
        if not canAct() then return end
        local s = sender(); if not s then return end
        if creature ~= nil and creature == reg:localPlayer() then return end
        if creature ~= nil and creature.getId and creature:getId() == followingId
           and followingId ~= 0 then
            creature = nil                                -- cancel when following again
        end
        local id = (creature and creature.getId) and creature:getId() or 0
        if id ~= 0 and attackingId ~= 0 then g.cancelAttack() end
        local body = s:follow(id)
        if body == nil and id ~= 0 then return end
        followingId = id
        return body
    end

    function g.cancelAttack()
        attackingId = 0
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:attack(0)
    end

    function g.cancelFollow()
        followingId = 0
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:follow(0)
    end

    function g.cancelAttackAndFollow()
        attackingId, followingId = 0, 0
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:cancelAttackAndFollow()
    end

    -- The server's own "your target is gone" (0xA3) -- callbacks.lua wires this up.
    function g.clearAttackingCreature() attackingId = 0 end
    function g.clearFollowingCreature() followingId = 0 end

    function g.getAttackingCreature() return reg:creature(attackingId) end
    function g.getFollowingCreature() return reg:creature(followingId) end
    function g.isAttacking() return attackingId ~= 0 and reg:creature(attackingId) ~= nil end
    function g.isFollowing() return followingId ~= 0 and reg:creature(followingId) ~= nil end

    function g.setChaseMode(mode)
        chaseMode = mode
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:setFightMode(fightMode, chaseMode, safeFight, pvpMode)
    end
    function g.setFightMode(mode)
        fightMode = mode
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:setFightMode(fightMode, chaseMode, safeFight, pvpMode)
    end
    function g.setSafeFight(on)
        safeFight = on and true or false
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:setFightMode(fightMode, chaseMode, safeFight, pvpMode)
    end
    function g.setPVPMode(mode)
        pvpMode = mode
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:setFightMode(fightMode, chaseMode, safeFight, pvpMode)
    end
    function g.getChaseMode() return chaseMode end
    function g.getFightMode() return fightMode end
    function g.isSafeFight() return safeFight end
    function g.getPVPMode()  return pvpMode end

    -- =======================================================================
    -- party / channels / session
    -- =======================================================================
    -- G9: 0xA3 / 0xA4, u32 creatureId (protocolgamesend.cpp:843-857).
    local function partyOp(opcode, creatureId)
        if not canAct() then return end
        local s = sender(); if not s then return end
        local w = buffer.writer()
        w:u8(opcode)
        w:u32(creatureId or 0)
        return s:_send(w)
    end
    function g.partyInvite(cid) return partyOp(OP_INVITE_TO_PARTY, cid) end
    function g.partyJoin(cid)   return partyOp(OP_JOIN_PARTY, cid) end

    function g.requestChannels()
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:requestChannels()
    end

    function g.joinChannel(id)
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:joinChannel(id)
    end

    function g.leaveChannel(id)
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:leaveChannel(id)
    end

    function g.safeLogout()
        local s = sender(); if not s then return end
        return s:logout()
    end
    g.forceLogout = g.safeLogout

    function g.requestOutfit()
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:requestOutfit()
    end

    function g.changeOutfit(outfit)
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:changeOutfit(outfit)
    end

    function g.buyItem(item, amount, ignoreCapacity, buyWithBackpack)
        if not (canAct() and item) then return end
        local s = sender(); if not s then return end
        -- Game::buyItem (game.cpp:1390) sends getCountOrSubType(), NOT getSubType():
        -- for a stackable offer getSubType() is 0 at cv > 862 (item.cpp:107), which puts
        -- a 0x00 count byte on the wire.  sellItem really does use getSubType()
        -- (game.cpp:1398) -- the asymmetry is upstream's, not a typo here.
        return s:buyItem(item:getId(), item:getCountOrSubType(), amount or 1,
                         ignoreCapacity, buyWithBackpack)
    end

    function g.sellItem(item, amount, ignoreEquipped)
        if not (canAct() and item) then return end
        local s = sender(); if not s then return end
        return s:sellItem(item:getId(), item:getSubType(), amount or 1, ignoreEquipped)
    end

    function g.closeNpcTrade()
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:closeNpcTrade()
    end

    function g.answerModalDialog(id, button, choice)
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:answerModalDialog(id, button, choice)
    end

    -- =======================================================================
    -- accessors
    -- =======================================================================
    function g.getLocalPlayer() return reg:localPlayer() end
    function g.getCharacterName() return (st.player and st.player.name) or '' end
    function g.isOnline() return LC.inGame == true end
    function g.isLogging() return LC.inGame ~= true and LC.transport ~= nil end
    function g.isDead() return (st.player and st.player.isDead) == true end
    function g.isConnectionOk() return LC.transport ~= nil and not LC.transport.dead end

    function g.getClientVersion()   return CLIENT_VERSION end
    function g.getProtocolVersion() return PROTOCOL_VERSION end
    function g.getOs() return 61 end                       -- Gunzodus custom OS
    function g.getServerBeat() return st.serverBeat or 50 end

    -- G2: main.lua writes the measured round trip to state.ping (API.md); nil until the
    -- first pong, and `vBot/AttackBot.lua:54` adds it to every timing budget, so 0 -- not
    -- nil -- is the honest answer before the first measurement.
    function g.getPing() return st.ping or 0 end

    function g.getContainers()
        local out = {}
        for id in pairs(st.containers) do
            out[id] = reg:container(id)
        end
        return out
    end

    function g.getContainer(index) return reg:container(index) end

    -- Game::findItemInContainers (game.cpp:922-933) -- first match in container-id order.
    -- `pairs` over state.containers is hash order, so iterate the ids ASCENDING: two runs
    -- against the same state must pick the same item.
    function g.findItemInContainers(itemId, subType, tier)
        local ids = {}
        for id in pairs(st.containers) do ids[#ids + 1] = id end
        table.sort(ids)
        for i = 1, #ids do
            local c = reg:container(ids[i])
            if c then
                local it = c:findItemById(itemId, subType, tier or 0)
                if it then return it end
            end
        end
        return nil
    end

    -- modules/gamelib/game.lua:5 + game.cpp:909-920: the 11 equipped slots first, in
    -- InventorySlotFirst..Last order, then the open containers.  subType == -1 means "any".
    function g.findPlayerItem(itemId, subType, tier)
        if subType == nil then subType = -1 end
        local player = reg:localPlayer()
        for slot = 1, 11 do
            local it = player:getInventoryItem(slot)
            if it and it:getId() == itemId and (subType == -1 or it:getSubType() == subType) then
                return it
            end
        end
        return g.findItemInContainers(itemId, subType, tier or 0)
    end

    -- STATEFUL: latched from opcode 0x43 by the parser's feature table when there is one.
    function g.getFeature(f)
        if features[f] ~= nil then return features[f] == true end
        local p = LC.parser
        if p and p.features then return p.features[f] == true end
        return false
    end
    function g.enableFeature(f)  features[f] = true end
    function g.disableFeature(f) features[f] = false end

    -- Opcode 0xB7 (GameServerUnjustifiedStats) IS parsed -- proto/parser.lua writes
    -- `state.unjustified` verbatim from parseUnjustifiedStats (protocolgameparse.cpp:1322).
    -- Prefer it; fall back to whatever setUnjustifiedPoints was handed, and only report
    -- when NEITHER exists (i.e. the server has not sent the packet yet this session).
    --
    -- The fallback is NOT zeros.  vBot/vlib.lua:223-227 killsToRs() is the min of the three
    -- *Remaining fields; 0 is conservative for the AttackBot PvP gate
    -- (AttackBot.lua:1573,2949,... `killsToRs() > KillsAmount`) but it INVERTS
    -- vBot/antiRs.lua:21 (`killsToRs() < 6`), which would then latch on for the whole
    -- session.  255 -- the wire byte's own maximum -- is the only value that is
    -- conservative in BOTH directions until the packet arrives.
    local UNJ_UNKNOWN = 255
    function g.getUnjustifiedPoints()
        local src = st.unjustified
        if type(src) ~= 'table' then src = unjustified.__set and unjustified or nil end
        if src == nil then
            reg:report('g_game.getUnjustifiedPoints',
                       'opcode 0xB7 has not arrived this session; the three *Remaining '
                       .. 'fields answer 255 so vlib.killsToRs() stays conservative in '
                       .. 'BOTH directions (AttackBot gate off, antiRs.lua:21 quiet)')
            return { killsDay = 0, killsDayRemaining = UNJ_UNKNOWN,
                     killsWeek = 0, killsWeekRemaining = UNJ_UNKNOWN,
                     killsMonth = 0, killsMonthRemaining = UNJ_UNKNOWN,
                     skullTime = 0 }
        end
        local out = {}
        for _, k in ipairs{ 'killsDay', 'killsDayRemaining', 'killsWeek',
                            'killsWeekRemaining', 'killsMonth', 'killsMonthRemaining',
                            'skullTime' } do
            out[k] = tonumber(src[k]) or 0
        end
        return out
    end
    function g.setUnjustifiedPoints(t)
        if type(t) ~= 'table' then return end
        for k, v in pairs(t) do unjustified[k] = v end
        unjustified.__set = true
        st.unjustified = st.unjustified or {}
        for k, v in pairs(t) do st.unjustified[k] = v end
    end

    -- functions/callbacks.lua:8-9 / bot.lua:115 gate the per-thing fan-out on this.
    -- The gate now HAS something behind it (gap G5 closed): shim/object.lua wraps
    -- state:addThing / state:_removeAt and fans out to reg.onTileThing, which
    -- shim/callbacks.lua turns into onAddThing / onRemoveThing.  Both sides read the
    -- same flag, so with the callback off nothing is allocated -- same as game.h:431.
    function g.enableTileThingLuaCallback(v)
        tileThingLuaCallback = (v == true)
        reg.tileThingCallback = tileThingLuaCallback
    end
    function g.isTileThingLuaCallbackEnabled() return tileThingLuaCallback end

    -- =======================================================================
    -- imbuements -- blocker B2 CLOSED.  Senders are proto/sender.lua (0xD5 0xD6 0xD7
    -- 0xB2 0x60, protocolgamesend.cpp:1735-1775,1887-1893) and the three inbound
    -- opcodes (0x5D tracker, 0xEB window, 0xEC close) are parsed and emitted by
    -- proto/parser.lua.  shim/callbacks.lua turns those into the g_game signals the
    -- user's own profiles/bot/vBot_4.8/cavebot/imbuing.lua connects to:
    -- onUpdateImbuementTracker, onOpenImbuementWindow, onImbuementItem,
    -- onImbuementScroll, onCloseImbuementWindow -- plus the game_bot-facing
    -- onImbuementWindow (bot.lua:566).
    --
    -- Every guard is Game::canPerformGameAction, exactly like game.cpp:2063-2108.

    -- Game::applyImbuement (game.cpp:2063)
    function g.applyImbuement(slot, imbuementId, protectionCharm)
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:applyImbuement(slot or 0, imbuementId or 0, protectionCharm)
    end

    -- Game::clearImbuement (game.cpp:2071)
    function g.clearImbuement(slot)
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:clearImbuement(slot or 0)
    end

    -- Game::closeImbuingWindow (game.cpp:2079)
    function g.closeImbuingWindow()
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:closeImbuingWindow()
    end

    -- Game::selectImbuementItem (game.cpp:2087) -- IMBUEMENT_WINDOW_SELECT_ITEM = 1.
    -- vBot calls it as selectImbuementItem(itemId, pos, stackpos)
    -- (cavebot/imbuing.lua:752); an Item may be passed instead of the three parts.
    function g.selectImbuementItem(itemId, pos, stackpos)
        if not canAct() then return end
        local s = sender(); if not s then return end
        if type(itemId) == 'table' and itemId.getId then
            local it = itemId
            pos = pos or it:getPosition()
            stackpos = stackpos or it:getStackPos()
            itemId = it:getId()
        end
        if type(pos) ~= 'table' then pos = { x = 0xFFFF, y = 0, z = 0 } end
        return s:imbuementWindowAction(1, itemId or 0, pos, stackpos or 0)
    end

    -- Game::selectImbuementScroll (game.cpp:2095) -- IMBUEMENT_WINDOW_SCROLL = 2, and
    -- the SCROLL branch writes no position at all (protocolgamesend.cpp:1768).
    function g.selectImbuementScroll()
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:imbuementWindowAction(2)
    end

    -- Game::imbuementDurations (game.cpp:2103) -- the tracker subscription.
    -- imbuing.lua:236-239 toggles it false->true to force a fresh 0x5D push.
    function g.imbuementDurations(isOpen)
        if not canAct() then return end
        local s = sender(); if not s then return end
        return s:imbuementDurations(isOpen and true or false)
    end

    function g.forgeRequest()
        reg:report('g_game.forgeRequest', 'no forge sender (1 decorative call site)')
        return nil
    end

    -- Render / map-view surface (blocker B4): callable, inert, never consulted for a
    -- decision.  `getTileUnderCursor` MUST return nil rather than raise.
    function g.getTileUnderCursor() return nil end

    -- Signal fields the C++ exposes as `g_game.onX`.  `g_game.onMultiUseCooldown` never
    -- fires on this client -- both T1 hits are comments saying so (api-game.md sec.1.2).
    g.onMultiUseCooldown = nil

    -- ------------------------------------------------------------------ teardown
    function g._shutdown()
        if posHandle and LC.events and LC.events.off then busOff(LC.events, posHandle) end
        posHandle = nil
        if preWalkTimer and LC.sched then LC.sched.cancel(preWalkTimer) end
        preWalkTimer = nil
    end

    -- Anything else on g_game: loud, callable, inert -- never a silent wrong value.
    setmetatable(g, { __index = function(_, k)
        if type(k) == 'string' and k:sub(1, 2) == 'on' then return nil end  -- signal slots
        reg:report('g_game.' .. tostring(k), 'not implemented')
        return function() return nil end
    end })

    return g
end

return M
