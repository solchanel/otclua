--[[============================================================================
shim/callbacks.lua -- LC.events  ->  the vBot sandbox callbacks  (PLAN sec.1.26)

`mods/game_bot/executor.lua:200-440` builds ONE dispatcher per otclient signal and
hangs them off the value `executeBot()` returns (`res.callbacks.<name>`).  In the
real client `mods/game_bot/bot.lua:549-614` wires those to `connect(g_game, ...)`,
`connect(Creature, ...)`, `connect(Container, ...)` and friends.  Headless there
are no C++ signals at all -- the equivalent facts arrive on `LC.events` from
`proto/parser.lua`.  This file is that wiring, and nothing else: it translates a
parser event into the argument tuple the dispatcher expects, wraps every raw state
record in its interned shim object (invariant I1), and calls it.

    local cb = require('shim.callbacks')
    local h  = cb.install(LC, exec.callbacks, { reg = reg, g_game = G.g_game,
                                                cooldown = modulesCtl.cooldown,
                                                modules = G.modules, log = log })
    h:remove()

WHAT IS AND IS NOT WIRED

  wired, 1:1               talk textMessage loginAdvice creatureAppear
                           creatureDisappear creatureHealth containerOpen
                           containerClose containerUpdateItem containerAddItem
                           containerRemoveItem channelList openChannel
                           closeChannel channelEvent modalDialog manaChange
                           statesChange inventoryChange spellCooldown
                           spellGroupCooldown distanceEffect
  wired, synthesised       onCreaturePositionChange + onWalk   (creatureMove for
                             remote creatures, positionChange for us)
                           onAttackingCreatureChange           (attackCancel, and
                             g_game.attack()/follow() fire their own)
                           updateInventoryItems                (after inventoryChange)
  NOT wired, and why
    onKeyDown/onKeyUp/onKeyPress   there is no keyboard headless (blocker B2).
                                   Hotkeys register and never fire.
    onAddThing / onRemoveThing     game/state.lua has no per-thing emit hook
                                   (gap G5).  `g_game.enableTileThingLuaCallback`
                                   exists as the gate; the hook does not.
    onUse / onUseWith              a client-side echo from the shim's own
                                   g_game.use/useWith; installed here when
                                   g_game exposes the `_onUse` / `_onUseWith`
                                   hook fields, skipped (loudly, once) otherwise.
    onImbuementWindow              no parser for it (blocker B2).
    onGameEditText                 no parser for 0x96 EditText.
    onAnimatedText / onStaticText  the parser does not surface either.
    onTurn                         the parser folds a turn into creatureMove.

MESSAGE MODES ARE TRANSLATED.  `proto/opcodes.lua` names modes by their WIRE
byte; `Otc::MessageMode` (const.h:300-365) numbers them differently, and vBot
compares against the CLIENT numbers -- `mode == 20` is Look, `21` DamageDealed,
`22` DamageReceived (vBot/combo.lua:229, analyzer.lua:1258, alarms.lua:137).
Handing the wire byte straight through would make every one of those tests fire
on the wrong message.  MODE_FROM_WIRE below is protocolcodes.cpp:37-87 inverted.
============================================================================]]

local callbacks = {}

-- ===========================================================================
-- Otc::MessageMode  <-  the 1055+ wire byte   (protocolcodes.cpp:37-87)
-- ===========================================================================
local MODE_FROM_WIRE = {
    [0] = 0,  [1] = 1,  [2] = 2,  [3] = 3,  [4] = 4,  [5] = 5,
    [6] = 6,  [7] = 7,  [8] = 8,  [9] = 9,
    [10] = 51,               -- MessageNpcFromStartBlock
    [11] = 10,               -- MessageNpcFrom
    [12] = 11,               -- MessageNpcTo
    [13] = 12, [14] = 13, [15] = 14, [16] = 15,
    [17] = 16,               -- MessageLogin
    [18] = 17,               -- MessageWarning
    [19] = 18,               -- MessageGame
    [20] = 50,               -- MessageGameHighlight
    [21] = 19,               -- MessageFailure
    [22] = 20,               -- MessageLook
    [23] = 21,               -- MessageDamageDealed
    [24] = 22,               -- MessageDamageReceived
    [25] = 23,               -- MessageHeal
    [26] = 24,               -- MessageExp
    [27] = 25, [28] = 26, [29] = 27,
    [30] = 28,               -- MessageStatus
    [31] = 29,               -- MessageLoot
    [32] = 30, [33] = 31, [34] = 32, [35] = 33, [36] = 34, [37] = 35,
    [38] = 36, [39] = 37, [40] = 38, [41] = 39, [42] = 40,
    [43] = 41,               -- MessageMana
    [44] = 42,               -- MessageBeyondLast
    [48] = 52, [49] = 53, [50] = 54, [51] = 55, [52] = 56,
}
callbacks.MODE_FROM_WIRE = MODE_FROM_WIRE

--- The wire byte a parser event carries -> the Otc::MessageMode vBot compares.
--- Unknown bytes become Otc::MessageInvalid (255) rather than silently becoming 0
--- ("None"), which would look like a real mode.
local function clientMode(d)
    local byte = d and (d.modeByte or d.mode)
    if type(byte) ~= 'number' then return 255 end
    local m = MODE_FROM_WIRE[byte]
    if m == nil then return 255 end
    return m
end
callbacks.clientMode = clientMode

-- ===========================================================================
-- the bus (LC.events is a MODULE in main.lua, a Bus INSTANCE elsewhere)
-- ===========================================================================
local function busOn(bus, name, fn)
    if rawget(bus, '_named') ~= nil then return bus:on(name, fn) end
    return bus.on(name, fn)
end
local function busOff(bus, handle)
    if rawget(bus, '_named') ~= nil then return bus:off(handle) end
    return bus.off(handle)
end

-- ===========================================================================
-- install
-- ===========================================================================
local Handle = {}
Handle.__index = Handle

function Handle:remove()
    if self._removed then return end
    self._removed = true
    for _, h in ipairs(self._handles) do
        pcall(busOff, self._bus, h)
    end
    self._handles = {}
    local g = self.deps and self.deps.g_game
    if g and self._prevOnUse ~= nil then g._onUse = self._prevOnUse end
    if g and self._prevOnUseWith ~= nil then g._onUseWith = self._prevOnUseWith end
end

--- Diagnostics: how many times each sandbox callback was dispatched, and which
--- parser events arrived that this bridge deliberately drops.
function Handle:stats()
    return { fired = self.fired, dropped = self.dropped, wired = self.wired }
end

--- install(LC, cb, deps) -> handle
---   LC          the luaclient handle (LC.events is the bus)
---   cb          exec.callbacks -- the executor's dispatcher table
---   deps.reg      the shim object registry (required: every argument is interned)
---   deps.g_game   the shim g_game (attack/follow echo, use echo)
---   deps.cooldown modulesCtl.cooldown (spell + group cooldown recording)
---   deps.modules  G.modules (game_interface.lastManualWalk)
---   deps.log      lib/log
function callbacks.install(LC, cb, deps)
    deps = deps or {}
    if type(cb) ~= 'table' then
        return nil, 'shim/callbacks: the executor callback table is missing'
    end
    local bus = LC and LC.events
    if not (bus and (bus.on or bus._named)) then
        return nil, 'shim/callbacks: LC.events is not an event bus'
    end
    local reg = deps.reg
    if not reg then return nil, 'shim/callbacks: deps.reg is required' end
    local log = deps.log
    local state = LC.state

    local H = setmetatable({
        _bus = bus, _handles = {}, deps = deps,
        fired = {}, dropped = {}, wired = {},
    }, Handle)

    -- Every dispatch is pcall'd.  executor.lua's dispatchers call user callbacks
    -- directly with no protection, and a throwing vBot callback must not take the
    -- parser down with it (the live client's signalcall is equally forgiving).
    local function fire(name, ...)
        local fn = cb[name]
        if type(fn) ~= 'function' then
            H.dropped[name] = (H.dropped[name] or 0) + 1
            return
        end
        H.fired[name] = (H.fired[name] or 0) + 1
        local ok, err = pcall(fn, ...)
        if not ok and log and log.error then
            log.error('shim/callbacks: %s raised: %s', name, tostring(err))
        end
    end
    H.fire = fire

    local function on(event, fn)
        H._handles[#H._handles + 1] = busOn(bus, event, fn)
        H.wired[#H.wired + 1] = event
    end

    -- ---------------------------------------------------------------- chat
    on('talk', function(d)
        if not d then return end
        fire('onTalk', d.name, d.level or 0, clientMode(d), d.text or '',
             d.channelId or 0, d.pos)
    end)
    on('textMessage', function(d)
        if not d then return end
        fire('onTextMessage', clientMode(d), d.text or '')
    end)
    on('loginAdvice', function(d) fire('onLoginAdvice', d and d.message or '') end)

    -- ----------------------------------------------------------- creatures
    on('creatureAppear', function(rec)
        local c = rec and reg:creatureRec(rec)
        if c then fire('onCreatureAppear', c) end
    end)
    on('creatureDisappear', function(rec)
        -- The record is already unlinked from state, so mint the wrapper from the
        -- record rather than from the id -- the id no longer resolves.
        local c = rec and (reg.creatures[rec.id] or reg:creatureRec(rec))
        if c then fire('onCreatureDisappear', c) end
    end)
    on('creatureHealth', function(d)
        if not (d and d.creature) then return end
        local c = reg:creatureRec(d.creature)
        if c then fire('onCreatureHealthPercentChange', c, d.healthPercent or 0) end
    end)
    on('creatureMove', function(d)
        if not (d and d.creature) then return end
        local c = reg:creatureRec(d.creature)
        if not c then return end
        -- otclient fires BOTH: Creature::onPositionChange and Creature::walk.
        -- Note the argument order differs between them (bot.lua:585,590 ->
        -- executor.lua:307,385).
        fire('onCreaturePositionChange', c, d.to, d.from)
        fire('onWalk', c, d.from, d.to)
    end)
    on('positionChange', function(d)
        -- The local player moves through its own event; `creatureMove` does not
        -- carry us.  cavebot/*, targetbot/* and vBot/* all watch this one.
        if not d then return end
        local me = reg:localPlayer()
        if not me then return end
        fire('onCreaturePositionChange', me, d.pos, d.oldPos)
        fire('onWalk', me, d.oldPos, d.pos)
    end)

    -- ---------------------------------------------------------- containers
    local prevContainer = nil
    on('containerOpen', function(c)
        if not (c and c.id) then return end
        local w = reg:container(c.id)
        if not w then return end
        local prev = prevContainer
        prevContainer = w
        fire('onContainerOpen', w, prev)
    end)
    on('containerClose', function(c)
        if not (c and c.id) then return end
        -- The record is gone from state by now, so reg:container(id) returns nil;
        -- hand over the wrapper we already minted if there is one.
        local w = reg.containers[c.id] or reg:container(c.id)
        if w == prevContainer then prevContainer = nil end
        if w then fire('onContainerClose', w) end
    end)
    on('containerAddItem', function(d)
        if not d then return end
        local w = reg:container(d.containerId)
        local it = d.item and reg:item(d.item, { kind = 'container', cid = d.containerId })
        if w then fire('onAddItem', w, d.slot or 0, it) end
    end)
    on('containerRemoveItem', function(d)
        if not d then return end
        local w = reg:container(d.containerId)
        if w then fire('onRemoveItem', w, d.slot or 0, nil) end
    end)
    on('containerUpdateItem', function(d)
        if not d then return end
        local w = reg:container(d.containerId)
        local it = d.item and reg:item(d.item, { kind = 'container', cid = d.containerId })
        if w then fire('onContainerUpdateItem', w, d.slot or 0, it, nil) end
    end)

    -- ----------------------------------------------------------- inventory
    on('inventoryChange', function(d)
        if not d then return end
        local me = reg:localPlayer()
        local it = d.item and reg:item(d.item, { kind = 'inventory', slot = d.slot })
        fire('onInventoryChange', me, d.slot, it, nil)
        fire('updateInventoryItems')
    end)

    -- ------------------------------------------------------------ channels
    on('channelList', function(list) fire('onChannelList', list or {}) end)
    on('openChannel', function(d)
        if not d then return end
        fire('onOpenChannel', d.id, d.name or '')
    end)
    on('closeChannel', function(d) fire('onCloseChannel', d and d.id) end)
    on('channelEvent', function(d)
        if not d then return end
        fire('onChannelEvent', d.channelId, d.name or '', d.eventType)
    end)

    -- --------------------------------------------------------------- misc
    on('modalDialog', function(d)
        if not d then return end
        fire('onModalDialog', d.id, d.title or '', d.message or '', d.buttons or {},
             d.enterButton, d.escapeButton, d.choices or {}, d.priority)
    end)
    on('manaChange', function(d)
        if not d then return end
        local me = reg:localPlayer()
        fire('onManaChange', me, d.mana, d.maxMana, d.old, d.maxMana)
    end)
    on('statesChange', function(d)
        if not d then return end
        local me = reg:localPlayer()
        fire('onStatesChange', me, d.states, d.oldStates or 0)
    end)
    on('distanceEffect', function(d)
        if d then fire('onMissle', d) end
    end)

    -- ----------------------------------------------------------- cooldowns
    -- vlib.lua:368,374 canCast() is blind until these arrive (api-platform B14).
    on('spellCooldown', function(d)
        if not d then return end
        if deps.cooldown and deps.cooldown.record then
            pcall(deps.cooldown.record, d.spellId, d.delay)
        end
        fire('onSpellCooldown', d.spellId, d.delay)
    end)
    on('spellGroupCooldown', function(d)
        if not d then return end
        if deps.cooldown and deps.cooldown.recordGroup then
            pcall(deps.cooldown.recordGroup, d.groupId, d.delay)
        end
        fire('onGroupSpellCooldown', d.groupId, d.delay)
    end)

    -- ------------------------------------------------------- attack target
    -- The shim's g_game caches the attacked creature client-side (gap G1); only the
    -- parser sees the server clearing it.
    on('attackCancel', function()
        local g = deps.g_game
        local old = g and g.getAttackingCreature and g.getAttackingCreature() or nil
        if g and g.clearAttackingCreature then pcall(g.clearAttackingCreature) end
        if old then fire('onAttackingCreatureChange', nil, old) end
    end)
    if deps.g_game then
        local g = deps.g_game
        H._prevOnAttack = rawget(g, 'onAttackingCreatureChange')
        g.onAttackingCreatureChange = function(new, old)
            fire('onAttackingCreatureChange', new, old)
        end
        -- The client-side echo of our own use/useWith, when g_game offers the hook.
        if rawget(g, '_onUse') ~= nil or g._acceptsUseHook then
            H._prevOnUse = rawget(g, '_onUse')
            H._prevOnUseWith = rawget(g, '_onUseWith')
            g._onUse = function(pos, itemId, stackPos, subType)
                fire('onUse', pos, itemId, stackPos, subType)
            end
            g._onUseWith = function(pos, itemId, target, subType)
                fire('onUseWith', pos, itemId, target, subType)
            end
        else
            H.dropped.onUse = 0
            H.dropped.onUseWith = 0
            if log and log.debug then
                log.debug('shim/callbacks: g_game exposes no _onUse hook -- onUse / '
                          .. 'onUseWith will never fire (PLAN sec.1.26)')
            end
        end
    end

    -- The never-fired set, recorded so status() can say so out loud rather than
    -- letting a silent zero look like "nothing happened yet".
    for _, name in ipairs{ 'onKeyDown', 'onKeyUp', 'onKeyPress', 'onAddThing',
                           'onRemoveThing', 'onImbuementWindow', 'onGameEditText',
                           'onAnimatedText', 'onStaticText', 'onTurn' } do
        H.dropped[name] = H.dropped[name] or 0
    end

    -- game_interface.lastManualWalk: attacking.lua:904,1116 and waypoints.lua:602
    -- never see a manual walk otherwise.  A walk WE send is not manual, so this is
    -- deliberately left for the control plane to set; recorded here for the doc.
    H.lastManualWalkOwner = deps.modules and deps.modules.game_interface or nil

    if state == nil and log and log.warn then
        log.warn('shim/callbacks: LC.state is nil; every wrapper will be empty')
    end
    return H
end

return callbacks
