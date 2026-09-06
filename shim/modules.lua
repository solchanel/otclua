--[[============================================================================
shim/modules.lua -- the `modules.*` graph  (work item S4, PLAN.md sec.1.25).

`modules == package.loaded` (modules/corelib/globals.lua:4) and every entry is a
module SANDBOX ENV: a table whose metatable `__index` points at the global
environment (src/framework/luaengine/luainterface.cpp:554-562, used by
core/module.cpp:30).  That single fact is why

    modules.game_bot.connect            -> the corelib global `connect`
    modules.game_bot.g_app.getOs()      -> the C++ global `g_app`
    modules.gamelib.SpellInfo           -> the global defined by gamelib/spells.lua
    modules.game_spelllist.SpellInfo    -> the SAME global

all resolve even though none of those modules defines the name.  The shim
reproduces it exactly: every table built here is
`setmetatable(<own fields>, {__index = SHIM_G})` -- PLAN invariant I7.

Fidelity, per docs/shim/api-platform.md sec.5.1.  REAL means it does the thing;
STATEFUL means it remembers a value and has no side effect; INERT means it is a
recorded no-op.  Every INERT/STATEFUL call is recorded and `ctl.report()` prints
the tally, so "it ran and did nothing" is never silent.

  REAL      game_walk.smartWalk            -> g_game.walk  (this IS context.walk)
            game_interface.tryCastSpellMessage / castAimedSpell  (this IS context.say)
            game_interface.forceExit       -> real disconnect + terminate
            game_cooldown.isCooldownIconActive / isGroupCooldownIconActive
            game_console.channels          -> LC.state.channels
            game_console.sendMessage       -> g_game.talk
            game_npctrade.sellAll          -> sender:sellItem, over the parsed sell list
            game_skills level.percent / stamina.value  -> LC.state.player
            client_terminal.addLine        -> lib/log
            game_textmessage.display*      -> lib/log
  STATEFUL  game_bot.contentsPanel.config:getCurrentOption() -> {text=<config>}
            game_interface.lastManualWalk (a NUMBER: attacking.lua:904 adds 500 to it)
            game_npctrade.get/setSellExceptions
            game_outfit.ignoreNextOutfitWindow
            client_options.getOption
  INERT     every widget-shaped leaf, the modal editors, the popup menus, and
            client_entergame.CharacterList.doLogin (B4 -- no char-list widget tree)

`client_profiles` MUST stay nil: bot.lua:341 takes its fallback path on `nil`.

Usage:
    local modules = require('shim.modules')
    local tbl, ctl = modules.build(G, {
        config = 'vBot_4.8', LC = LC, log = log,
        widget = <fn(styleName) -> widget-like>,     -- optional; a UI backend
        onForceExit = fn, onRelog = fn(charName),
    })
    G.modules = tbl                       -- also becomes package.loaded for the sandbox
    ctl.cooldown.record(iconId, ms)       -- fed by the spellCooldown parser event
    ctl.report()                          -- { {symbol=, n=}, ... }, sorted
============================================================================]]

local M = {}

-- ===========================================================================
-- 0. helpers
-- ===========================================================================

--- A module sandbox env (luainterface.cpp:554-562).  `own` wins; everything else
--- falls through to SHIM_G.  This is the ONLY way a `modules.X` table is built.
local function sandbox(G, own)
    return setmetatable(own or {}, { __index = G })
end
M.sandbox = sandbox

--- The recorder.  Every stubbed call lands here so `ctl.report()` can answer
--- "what did vBot ask for that this shim does not really do".
local function newRecorder(log, strict)
    local counts, order = {}, {}
    local R = {}
    function R.hit(symbol, why)
        local e = counts[symbol]
        if not e then
            e = { symbol = symbol, n = 0, why = why }
            counts[symbol] = e
            order[#order + 1] = e
            -- Loud ONCE per symbol, exactly like shim/object.lua's Reg:report.
            if strict then
                error(('shim/modules: %s is not implemented headless (%s)')
                      :format(symbol, why or 'no data source'), 3)
            end
            if log and log.debug then
                log.debug('shim/modules: %s -> stub (%s)', symbol, why or 'inert')
            end
        end
        e.n = e.n + 1
    end
    function R.report()
        table.sort(order, function(a, b)
            if a.n ~= b.n then return a.n > b.n end
            return a.symbol < b.symbol
        end)
        return order
    end
    function R.reset() counts, order = {}, {} end
    return R
end

-- ===========================================================================
-- 1. the fallback widget-ish leaf
-- ===========================================================================
-- Several modules.* leaves are indexed and ASSIGNED at vBot load time and would
-- otherwise be a nil-index crash:
--   vBot/xeno_menu.lua:1        modules.game_interface.gameRootPanel.onMouseRelease = ...
--   cavebot/minimap.lua:1       modules.game_minimap.getMiniMapUi().onMouseRelease = ...
--   vBot/analyzer.lua:958,984   messagesPanel.statusLabel:setVisible/:setColoredText
--   vBot/analyzer.lua:205       game_mainpanel.addToggleButton(...):setOn(false)
-- When a real UI backend is injected (`deps.widget`) these are real widgets.
-- Without one they are this: an assignable table whose unknown methods are
-- recorded no-ops returning nil, and whose getters return a SAFE-SHAPED value
-- (getText -> '', getPercent -> 0, isOn/isChecked -> false).  api-platform.md
-- sec.3.5 lists the return shapes vBot actually reads back.

local LEAF_GETTERS = {
    getText = '', getColoredText = '', getId = '', getStyleName = '',
    getPercent = 0, getValue = 0, getMinimum = 0, getMaximum = 0,
    getItemId = 0, getItemCount = 0, getItemSubType = 0, getWidth = 0, getHeight = 0,
    getX = 0, getY = 0, getChildCount = 0, getCurrentIndex = 0, getOptionsCount = 0,
    isOn = false, isChecked = false, isVisible = false, isHidden = true,
    isEnabled = false, isFocused = false, isDestroyed = false,
}
-- Shapes whose FIELDS are read back: a bare {} turns `getPosition().x` into a nil
-- arithmetic error, so each one is minted with its real key set.
local LEAF_TABLES = {
    getChildren = function() return {} end,
    getItems    = function() return {} end,
    getPosition = function() return { x = 0, y = 0, z = 0 } end,
    getRect     = function() return { x = 0, y = 0, width = 0, height = 0 } end,
    getSize     = function() return { width = 0, height = 0 } end,
}

local function newLeaf(rec, path)
    local self = {}
    local store = {}
    local mt
    mt = {
        __index = function(t, k)
            if type(k) ~= 'string' then return nil end
            local v = store[k]
            if v ~= nil then return v end
            -- Known read-back shapes first, so a comparison never sees a function.
            local g = LEAF_GETTERS[k]
            if g ~= nil then
                local fn = function() rec.hit(path .. ':' .. k, 'no UI backend'); return g end
                store[k] = fn
                return fn
            end
            local shape = LEAF_TABLES[k]
            if shape then
                local fn = function() rec.hit(path .. ':' .. k, 'no UI backend'); return shape() end
                store[k] = fn
                return fn
            end
            -- getChildById / recursiveGetChildById / getTab -> another leaf, so a
            -- chained `a:getChildById('x'):setText(...)` cannot crash.
            if k:match('^getChild') or k:match('^recursiveGetChild') or k == 'getTab'
               or k == 'getParent' or k == 'getFocusedChild' then
                local fn = function()
                    rec.hit(path .. ':' .. k, 'no UI backend')
                    return newLeaf(rec, path .. '.' .. k)
                end
                store[k] = fn
                return fn
            end
            -- Anything else: a recorded no-op that returns the receiver, so the
            -- otclient `w:setX():setY()` chaining idiom keeps working.
            local fn = function(...)
                rec.hit(path .. ':' .. k, 'no UI backend')
                return t
            end
            store[k] = fn
            return fn
        end,
        __newindex = function(t, k, v) store[k] = v end,
        __tostring = function() return 'shimLeaf<' .. path .. '>' end,
    }
    return setmetatable(self, mt)
end
M.newLeaf = newLeaf

-- ===========================================================================
-- 2. game_cooldown  (PLAN sec.1.23)
-- ===========================================================================
-- vlib.lua:368,374 -> canCast, the heal/attack hot path.  Fed by the
-- spellCooldown / spellGroupCooldown parser events.
--
-- api-platform.md B14: the LIVE client early-returns in cooldown.lua:542,562 when
-- its window is hidden, so it silently under-reports and canCast over-reports
-- readiness.  The shim records UNCONDITIONALLY -- a deliberate behaviour fix.

local function newCooldown(nowFn)
    local icons, groups = {}, {}
    local C = { _icons = icons, _groups = groups }

    function C.record(iconId, duration)
        if type(iconId) ~= 'number' then return end
        icons[iconId] = nowFn() + (tonumber(duration) or 0)
    end
    function C.recordGroup(groupId, duration)
        if type(groupId) ~= 'number' then return end
        groups[groupId] = nowFn() + (tonumber(duration) or 0)
    end
    function C.isCooldownIconActive(iconId)
        local d = icons[iconId]
        return d ~= nil and nowFn() < d
    end
    function C.isGroupCooldownIconActive(groupId)
        local d = groups[groupId]
        return d ~= nil and nowFn() < d
    end
    function C.clear()
        for k in pairs(icons) do icons[k] = nil end
        for k in pairs(groups) do groups[k] = nil end
    end
    return C
end
M.newCooldown = newCooldown

-- ===========================================================================
-- 3. game_npctrade  (PLAN sec.1.24)
-- ===========================================================================
-- cavebot/sell_all.lua:73 is the ONE unguarded call: a nil modules.game_npctrade
-- crashes the SellAll waypoint outright.  Everything else is guarded.
--
-- The sell list comes from LC.state.npcTrade (populated by the 0x7A parser when
-- that lands).  Until it does, getSellItems() is empty and sellAll() sells
-- nothing -- which is RECORDED, not silent.

-- modules/game_npctrade/sell_exceptions.lua:32.  The real module seeds an
-- uninitialised list with these and persists to g_settings.
local DEFAULT_SELL_EXCEPTIONS = { 23544, 3081 }

local function newNpcTrade(deps, rec)
    local LC = deps.LC or {}
    local exceptions = {}
    local T = {}

    for i, id in ipairs(DEFAULT_SELL_EXCEPTIONS) do exceptions[i] = id end

    --- seedSellExceptions(list) -- adopt a list ONLY while this one is still the
    --- untouched first-run default.
    ---
    --- WHY THIS EXISTS.  In the real client the sell-exception list is persisted in
    --- the CLIENT's own g_settings ('npctrade-sell-exceptions'), which the shim has
    --- no access to and which a headless worker has never written.  The bot profile
    --- keeps a mirror of it in `storage.cavebotSell`, and
    --- vBot/depositer_config.lua:228 unconditionally does
    ---     mirrorToStorage(sharedApi.getSellExceptions())
    --- at load time -- so booting with an EMPTY list silently overwrites the user's
    --- own sell exceptions with nothing, and saving the storage then persists that
    --- loss.  Measured: the user's seven ids became zero on the first --vbot-write
    --- run.  Seeding from the profile's own mirror before the tree loads makes the
    --- round trip lossless, and is the closest thing to the truth available offline.
    function T.seedSellExceptions(list)
        if type(list) ~= 'table' or #list == 0 then return false end
        if #exceptions ~= #DEFAULT_SELL_EXCEPTIONS then return false end
        for i, id in ipairs(DEFAULT_SELL_EXCEPTIONS) do
            if exceptions[i] ~= id then return false end
        end
        exceptions = {}
        for i, v in ipairs(list) do
            exceptions[i] = (type(v) == 'table' and v.id) or v
        end
        return true
    end

    local function tradeState()
        local st = LC.state
        return st and st.npcTrade or nil
    end

    function T.isTrading()
        local t = tradeState()
        return t ~= nil and t.open == true
    end

    -- proto/parser.lua:1549 (opcode 0x7A) keeps the whole offer list on
    -- `state.npcTrade.items`, each entry {id, subType, name, weight, buyPrice,
    -- sellPrice}.  game_npctrader.lua splits that one list into the two the UI
    -- shows: an item is sellable when the NPC pays for it, buyable when it charges.
    local function offers(field)
        local t = tradeState()
        if not (t and t.items) then
            rec.hit('game_npctrade.' .. field, 'no npc trade window open')
            return {}
        end
        local out = {}
        for _, e in ipairs(t.items) do
            if (e[field] or 0) > 0 then out[#out + 1] = e end
        end
        return out
    end
    function T.getSellItems() return offers('sellPrice') end
    function T.getBuyItems()  return offers('buyPrice') end

    function T.getSellQuantity(item)
        local id = type(item) == 'table' and item.getId and item:getId() or item
        if type(id) ~= 'number' then return 0 end
        local st = LC.state
        if not st then return 0 end
        local n = 0
        for _, c in pairs(st.containers or {}) do
            for _, it in ipairs(c.items or {}) do
                if it.id == id then n = n + math.max(1, it.count or 1) end
            end
        end
        -- game/state.lua:134 -- the equipped slots live on the PLAYER record.
        for _, it in pairs((st.player and st.player.inventory) or {}) do
            if type(it) == 'table' and it.id == id then n = n + math.max(1, it.count or 1) end
        end
        return n
    end
    function T.canTradeItem(item)
        local id = type(item) == 'table' and item.getId and item:getId() or item
        if id == nil then return false end
        for _, e in ipairs(exceptions) do if e == id then return false end end
        for _, s in ipairs(T.getSellItems()) do
            local sid = type(s) == 'table' and (s.id or (s.getId and s:getId())) or s
            if sid == id then return true end
        end
        return false
    end
    function T.getSellExceptions()
        -- sell_exceptions.lua:122-130 returns a COPY; cavebot/sell_all.lua:57 ipairs it.
        local out = {}
        for i = 1, #exceptions do out[i] = exceptions[i] end
        return out
    end
    function T.setSellExceptions(list)
        exceptions = {}
        if type(list) == 'table' then
            for i, v in ipairs(list) do exceptions[i] = v end
        end
        return true
    end
    function T.setSellExceptionsListener(fn)
        rec.hit('game_npctrade.setSellExceptionsListener', 'no npc-trade UI')
        return nil
    end
    function T.closeNpcTrade()
        local s = LC.sender
        if s and s.closeNpcTrade then return s:closeNpcTrade() end
        rec.hit('game_npctrade.closeNpcTrade', 'no sender')
        return false
    end

    --- sellAll(delayed, exceptions) -- game_npctrader.lua:128-168.
    --- Walks the sell list and fires 0x7B per sellable id.  Returns the number of
    --- sell packets sent so a caller (and the test suite) can tell "nothing to
    --- sell" from "no trade window at all".
    function T.sellAll(delayed, exceptionList)
        local skip = {}
        for _, v in ipairs(exceptionList or exceptions) do skip[v] = true end
        local s = LC.sender
        if not (s and s.sellItem) then
            rec.hit('game_npctrade.sellAll', 'no sender')
            return 0
        end
        local sent = 0
        for _, entry in ipairs(T.getSellItems()) do
            local id  = type(entry) == 'table' and (entry.id or entry.itemId) or entry
            local sub = type(entry) == 'table' and (entry.subType or 0) or 0
            if id and not skip[id] then
                local amount = T.getSellQuantity(id)
                if amount and amount > 0 then
                    s:sellItem(id, sub, math.min(amount, 100), true)
                    sent = sent + 1
                end
            end
        end
        if sent == 0 then
            rec.hit('game_npctrade.sellAll', 'sell list empty (no 0x7A parser / no trade open)')
        end
        return sent
    end

    return T
end
M.newNpcTrade = newNpcTrade

-- ===========================================================================
-- 4. build
-- ===========================================================================

--- build(G, deps) -> modulesTable, ctl
---   deps.config    the /bot/<dir> name reported by contentsPanel.config  (required)
---   deps.LC        the luaclient handle (state / sender / log)
---   deps.log       lib/log.lua
---   deps.widget    fn(styleName) -> widget   (a real UI backend; optional)
---   deps.g_game    the shim g_game (defaults to G.g_game at call time)
---   deps.onForceExit  fn()          -- game_interface.forceExit
---   deps.onRelog      fn(charName)  -- client_entergame.CharacterList.doLogin
---   deps.strict    true -> every stub raises instead of recording
function M.build(G, deps)
    deps = deps or {}
    if type(G) ~= 'table' then error('modules.build: G must be a table', 2) end
    local config = deps.config or 'vBot_4.8'
    local LC     = deps.LC or {}
    local log    = deps.log or LC.log
    local rec    = newRecorder(log, deps.strict)

    local function gGame() return deps.g_game or G.g_game end
    local function nowMs()
        local c = G.g_clock
        return (c and c.millis and c.millis()) or 0
    end
    local function leaf(path)
        if deps.widget then
            local ok, w = pcall(deps.widget, path)
            if ok and w ~= nil then return w end
        end
        return newLeaf(rec, path)
    end

    local modules = {}

    -- ---------------------------------------------------------------- gamelib
    -- api-platform.md sec.5.1: vlib.lua:278 reads modules.gamelib.SpellInfo
    -- UNGUARDED at load time.  The value comes through __index from SHIM_G, where
    -- otlua/bootstrap put gamelib/spells.lua's globals.  A load-time BLOCKER if
    -- SHIM_G.SpellInfo is missing, so say so loudly right here.
    modules.gamelib = sandbox(G, {})
    if G.SpellInfo == nil and log and log.warn then
        log.warn('shim/modules: SHIM_G.SpellInfo is nil -- vBot/vlib.lua:278 '
                 .. '(modules.gamelib.SpellInfo) will fail at load time; '
                 .. 'gamelib/spells.lua was not loaded')
    end

    -- --------------------------------------------------------------- game_bot
    -- _Loader.lua:2, vBot/configs.lua:5, cavebot/cavebot.lua:553,
    -- targetbot/target.lua:224 all read
    --   modules.game_bot.contentsPanel.config:getCurrentOption().text
    local configCombo = {
        getCurrentOption = function() return { text = config, data = config } end,
        getCurrentOptionText = function() return config end,
        getOptionsCount = function() return 1 end,
        setCurrentOption = function(t) rec.hit('game_bot.config:setCurrentOption', 'config is fixed by the shim') end,
    }
    modules.game_bot = sandbox(G, {
        contentsPanel = sandbox(G, { config = configCombo }),
        -- reachable only from mods/game_bot/*.otui, which the shim drops entirely
        edit           = function() rec.hit('game_bot.edit', 'config-manager UI dropped') end,
        uploadConfig   = function() rec.hit('game_bot.uploadConfig', 'config-manager UI dropped') end,
        downloadConfig = function() rec.hit('game_bot.downloadConfig', 'config-manager UI dropped') end,
        onMiniWindowClose = function() end,
    })

    -- -------------------------------------------------------------- game_walk
    -- functions/player.lua:64  context.walk = modules.game_walk.smartWalk
    -- THE walking entry point for the whole bot.  walk.lua:168-170 defers the step
    -- one dispatcher pass and drops it when a modifier key is held; headless there
    -- are no modifiers and no frame boundary, so the step goes straight out --
    -- through g_game.walk, which owns the prewalk bookkeeping (PLAN I2) and
    -- returns false when the step is refused (cavebot/walking.lua:294).
    local smartWalkDirs = {}
    modules.game_walk = sandbox(G, {
        smartWalk = function(dir)
            local g = gGame()
            if not (g and g.walk) then
                rec.hit('game_walk.smartWalk', 'no g_game')
                return false
            end
            return g.walk(dir)
        end,
        walk = function(dir)
            local g = gGame()
            return g and g.walk and g.walk(dir) or false
        end,
        changeWalkDir = function(dir, pop)
            if pop then
                for i = #smartWalkDirs, 1, -1 do
                    if smartWalkDirs[i] == dir then table.remove(smartWalkDirs, i) end
                end
            else
                table.insert(smartWalkDirs, 1, dir)
            end
        end,
        stopSmartWalk = function() smartWalkDirs = {} end,
        cancelWalkEvent = function() end,
        getFirstWalkDir = function() return smartWalkDirs[1] end,
    })

    -- ----------------------------------------------------------- game_console
    -- `channels` is a LIVE reference to LC.state.channels ([id] = name), which is
    -- what functions/player.lua getChannels() iterates.
    modules.game_console = sandbox(G, {
        channels = (LC.state and LC.state.channels) or {},
        -- extras.lua:210,364,505,528 gate the WASD/useAll hotkeys on this.  false =
        -- "chat is focused", which makes those keyboard paths inert -- correct
        -- headless, where B2 says no key event is ever delivered anyway.
        isEnabledWASD = function() return false end,
        sendMessage = function(message, channelId)
            local g = gGame()
            if not (g and g.talk) then rec.hit('game_console.sendMessage', 'no g_game'); return false end
            if channelId and channelId ~= 0 and g.talkChannel then
                return g.talkChannel(G.MessageModes and G.MessageModes.Channel or 5,
                                     channelId, tostring(message))
            end
            return g.talk(tostring(message))
        end,
        addText = function(text) rec.hit('game_console.addText', 'no console UI') end,
        addPrivateText = function() rec.hit('game_console.addPrivateText', 'no console UI') end,
        addTab = function(name) rec.hit('game_console.addTab', 'no console UI'); return leaf('consoleTab') end,
        -- extras.lua:180-185 aliases this and calls getTab(name) inside onTalk when
        -- settings.separatePm; a nil return there takes the "create the tab" branch,
        -- so a leaf keeps both branches alive.
        getTab = function(name) rec.hit('game_console.getTab', 'no console UI'); return leaf('consoleTab') end,
        removeTab = function() rec.hit('game_console.removeTab', 'no console UI') end,
        applyMessagePrefixies = function(name, level, text)
            if level and level > 0 then return ('%s [%d]: %s'):format(tostring(name), level, tostring(text)) end
            return ('%s: %s'):format(tostring(name), tostring(text))
        end,
        SpeakTypesSettings = G.SpeakTypesSettings or {},
        channelsWindow = nil,     -- combo.lua:205 is `if channelsWindow then`
    })

    -- ------------------------------------------------------- game_textmessage
    local function msg(kind)
        return function(text)
            rec.hit('game_textmessage.' .. kind, 'no message UI -- logged instead')
            if log and log.info then log.info('[%s] %s', kind, tostring(text)) end
            return true
        end
    end
    modules.game_textmessage = sandbox(G, {
        displayGameMessage      = msg('displayGameMessage'),
        displayStatusMessage    = msg('displayStatusMessage'),
        displayFailureMessage   = msg('displayFailureMessage'),
        displayBroadcastMessage = msg('displayBroadcastMessage'),
        displayPrivateMessage   = msg('displayPrivateMessage'),
        clearMessages = function() rec.hit('game_textmessage.clearMessages', 'no message UI') end,
        -- analyzer.lua:958,959,965 and :984,985,987 index these two chains
        -- UNGUARDED; highCenterLabel:getText() is compared with `==`, so it must
        -- return a string (api-platform.md sec.3.5).
        messagesPanel = sandbox(G, {
            statusLabel = leaf('messagesPanel.statusLabel'),
            centerTextMessagePanel = sandbox(G, {
                highCenterLabel = leaf('messagesPanel.highCenterLabel'),
            }),
        }),
    })

    -- --------------------------------------------------------- game_interface
    local mapPanel = leaf('game_interface.mapPanel')
    if type(mapPanel) == 'table' and rawget(mapPanel, 'lockVisibleFloor') == nil then
        -- spy_level.lua:13,19,22 calls these two by name.
        mapPanel.lockVisibleFloor = function(_, z)
            rec.hit('game_interface.mapPanel:lockVisibleFloor', 'no map view headless')
        end
        mapPanel.unlockVisibleFloor = function()
            rec.hit('game_interface.mapPanel:unlockVisibleFloor', 'no map view headless')
        end
    end

    local gi
    gi = {
        getMapPanel   = function() return mapPanel end,
        gameMapPanel  = mapPanel,
        -- xeno_menu.lua:1 ASSIGNS gameRootPanel.onMouseRelease at load time.
        gameRootPanel = leaf('game_interface.gameRootPanel'),
        getRootPanel  = function() return gi.gameRootPanel end,
        getLeftPanel  = function() return gi._left end,
        getRightPanel = function() return gi._right end,
        checkAndOpenLeftPanel  = function() rec.hit('game_interface.checkAndOpenLeftPanel', 'no panels headless') end,
        checkAndOpenRightPanel = function() rec.hit('game_interface.checkAndOpenRightPanel', 'no panels headless') end,
        -- interface.lua:25 -- a NUMBER.  attacking.lua:904,1116 and
        -- waypoints.lua:602 evaluate `lastManualWalk + 500 > context.now`, so a nil
        -- here is an arithmetic crash inside the two hottest panels.
        lastManualWalk = 0,
        startUseWith = function(thing) rec.hit('game_interface.startUseWith', 'no cursor headless') end,
        addMenuHook    = function() rec.hit('game_interface.addMenuHook', 'no context menu headless') end,
        removeMenuHook = function() rec.hit('game_interface.removeMenuHook', 'no context menu headless') end,
        -- antiRs.lua:14 -- the anti-RS panic exit.  REAL.
        forceExit = function()
            local g = gGame()
            if g and g.cancelLogin then pcall(g.cancelLogin) end
            if g and g.forceLogout then pcall(g.forceLogout) end
            if log and log.error then log.error('shim/modules: game_interface.forceExit() -- bot panic exit') end
            if deps.onForceExit then return deps.onForceExit() end
            rec.hit('game_interface.forceExit', 'no onForceExit handler wired')
            return false
        end,
    }

    -- gameinterface.lua:479 tryCastSpellMessage + :501 castAimedSpell, ported.
    -- This is context.say: every vBot spell cast goes through here, and on
    -- protocol >= 1525 a plain talk() is REJECTED by the server for spells that
    -- carry an aim byte -- so getting this wrong means the bot says the words and
    -- nothing happens.
    function gi.castAimedSpell(words, aimMode, aimPosition)
        if not words or words == '' then return false end
        local g = gGame()
        if not g then rec.hit('game_interface.castAimedSpell', 'no g_game'); return false end
        if (g.getClientVersion and g.getClientVersion() or 0) < 1525 then
            g.talk(words)
            return true
        end
        aimMode = aimMode or G.SpellAimTarget or 3
        if aimPosition then
            local mode = (aimMode == (G.SpellAimTarget or 3)) and (G.SpellAimCursor or 1) or aimMode
            g.talkSpell(words, mode, aimPosition)
            return true
        end
        if aimMode == (G.SpellAimTarget or 3) then
            g.talkSpell(words, aimMode, G.SpellAimInvalidPosition or { x = 0xFFFF, y = 0, z = 0 })
            return true
        end
        -- SpellAimCursor / SpellAimCrosshair both need a mouse.  B3.
        rec.hit('game_interface.castAimedSpell(cursor)', 'no cursor headless')
        return false
    end
    function gi.tryCastSpellMessage(message, aimMode, aimPosition)
        if not message or message == '' then return false end
        local Spells = G.Spells
        if not (Spells and Spells.getSpellByWords) then
            rec.hit('game_interface.tryCastSpellMessage', 'gamelib/spells.lua not loaded')
            return false
        end
        if not Spells.getSpellByWords(message:lower()) then return false end
        return gi.castAimedSpell(message, aimMode or G.SpellAimTarget or 3, aimPosition)
    end
    gi._left  = leaf('game_interface.leftPanel')
    gi._right = leaf('game_interface.rightPanel')
    modules.game_interface = sandbox(G, gi)

    -- ----------------------------------------------------------- game_minimap
    -- cavebot/minimap.lua:1 calls this at LOAD time and assigns onMouseRelease
    -- plus reads .allowNextRelease / .autowalk, so it must be one stable,
    -- assignable object.
    local miniMapUi = leaf('game_minimap.miniMapUi')
    modules.game_minimap = sandbox(G, {
        getMiniMapUi = function() return miniMapUi end,
        minimapWidget = miniMapUi,
        addFlag    = function() rec.hit('game_minimap.addFlag', 'no minimap UI') end,
        removeFlag = function() rec.hit('game_minimap.removeFlag', 'no minimap UI') end,
        center     = function() rec.hit('game_minimap.center', 'no minimap UI') end,
    })

    -- ---------------------------------------------------------- game_cooldown
    local cooldown = deps.cooldown or newCooldown(nowMs)
    modules.game_cooldown = sandbox(G, {
        isCooldownIconActive      = cooldown.isCooldownIconActive,
        isGroupCooldownIconActive = cooldown.isGroupCooldownIconActive,
        -- the two feeds, so callbacks.lua can push parser events straight in
        updateCooldown      = function(id, d) cooldown.record(id, d) end,
        updateGroupCooldown = function(id, d) cooldown.recordGroup(id, d) end,
        turnOffCooldown     = function() rec.hit('game_cooldown.turnOffCooldown', 'no cooldown UI') end,
    })

    -- --------------------------------------------------------- game_inventory
    -- quiver_label.lua:1 is `modules.game_inventory.getSlot5() or ""`, already
    -- guarded -- but getSlot(n) is the general form the runtime uses.
    local invSlots = {}
    local function invSlot(n)
        if not invSlots[n] then invSlots[n] = leaf('game_inventory.slot' .. n) end
        return invSlots[n]
    end
    local inv = { getSlot = function(n) return invSlot(tonumber(n) or 0) end }
    for i = 1, 11 do inv['getSlot' .. i] = function() return invSlot(i) end end
    inv.inventoryWindow = leaf('game_inventory.inventoryWindow')
    modules.game_inventory = sandbox(G, inv)

    -- ------------------------------------------------------------ game_skills
    -- analyzer.lua:587,1718 read level.percent:getPercent() UNGUARDED at load
    -- time; :754 reads stamina.value:getText().  Both are backed by real player
    -- state so the analyzer shows the truth rather than a constant.
    local function playerField(name, default)
        local st = LC.state
        local p = st and st.player
        local v = p and p[name]
        if v == nil then return default end
        return v
    end
    local levelPercent = leaf('game_skills.level.percent')
    if type(levelPercent) == 'table' then
        levelPercent.getPercent = function() return playerField('levelPercent', 0) end
    end
    local staminaValue = leaf('game_skills.stamina.value')
    if type(staminaValue) == 'table' then
        staminaValue.getText = function()
            local mins = playerField('stamina', 0) or 0
            return ('%02d:%02d'):format(math.floor(mins / 60), mins % 60)
        end
    end
    modules.game_skills = sandbox(G, {
        skillsWindow = sandbox(G, {
            contentsPanel = sandbox(G, {
                level   = sandbox(G, { percent = levelPercent }),
                stamina = sandbox(G, { value = staminaValue }),
            }),
        }),
        onLevelChange = function() end,
    })

    -- ---------------------------------------------------------- game_spelllist
    -- getSpelllistProfile() -> 'Default' (spelllist.lua:64-66).  When bootstrap
    -- loaded the real spelllist.lua into a sandbox, deps.spelllistEnv is that env
    -- and it supplies the real function; otherwise this constant is correct for
    -- every stock profile.
    modules.game_spelllist = deps.spelllistEnv or sandbox(G, {
        getSpelllistProfile = function() return 'Default' end,
        setSpelllistProfile = function() rec.hit('game_spelllist.setSpelllistProfile', 'no spelllist UI') end,
    })

    -- ----------------------------------------------------------- game_npctrade
    local npctrade = deps.npctrade or newNpcTrade({ LC = LC, g_game = gGame() }, rec)
    modules.game_npctrade = sandbox(G, npctrade)

    -- ------------------------------------------------------------ game_outfit
    modules.game_outfit = sandbox(G, { ignoreNextOutfitWindow = 0 })

    -- --------------------------------------------------------- game_mainpanel
    -- analyzer.lua:205 does addToggleButton(...):setOn(false) and later :destroy().
    modules.game_mainpanel = sandbox(G, {
        addToggleButton = function(id, desc, image, cb, front, index)
            rec.hit('game_mainpanel.addToggleButton', 'no main panel headless')
            return leaf('mainpanel.' .. tostring(id))
        end,
        addButton = function(id) rec.hit('game_mainpanel.addButton', 'no main panel headless')
            return leaf('mainpanel.' .. tostring(id)) end,
        getButton = function() return nil end,      -- bot.lua:256 expects nil-able
        removeButton = function() rec.hit('game_mainpanel.removeButton', 'no main panel headless') end,
    })

    -- ------------------------------------------------------------ game_buttons
    -- analyzer.lua:198 indexes TWO levels unguarded:
    --   modules.game_buttons.buttonsWindow.contentsPanel and ...
    -- so buttonsWindow must exist; contentsPanel may be nil.
    modules.game_buttons = sandbox(G, { buttonsWindow = leaf('game_buttons.buttonsWindow') })

    -- ---------------------------------------------------------- client_topmenu
    modules.client_topmenu = sandbox(G, {
        getButton = function() return nil end,       -- analyzer.lua:199
        addLeftButton  = function() rec.hit('client_topmenu.addLeftButton', 'no top menu headless')
            return leaf('topmenu.button') end,
        addRightButton = function() rec.hit('client_topmenu.addRightButton', 'no top menu headless')
            return leaf('topmenu.button') end,
    })

    -- --------------------------------------------------------- client_terminal
    -- vlib.lua:17 logInfo() -- forward to the real log.
    modules.client_terminal = sandbox(G, {
        addLine = function(text, color)
            if log and log.info then log.info('%s', tostring(text)) end
            return true
        end,
        show = function() rec.hit('client_terminal.show', 'no terminal UI') end,
        hide = function() rec.hit('client_terminal.hide', 'no terminal UI') end,
    })

    -- -------------------------------------------------------- client_entergame
    -- B4: doLogin needs g_ui.getRootWidget().charactersWindow.characters, a widget
    -- tree that does not exist headless.  vlib.lua:36 relogOnCharacter() is the
    -- only caller; deps.onRelog is the shim-native replacement (transport close ->
    -- supervisor re-login).  Without one this is a LOUD no-op, never a silent one.
    modules.client_entergame = sandbox(G, {
        CharacterList = sandbox(G, {
            doLogin = function(charName)
                if deps.onRelog then return deps.onRelog(charName) end
                rec.hit('client_entergame.CharacterList.doLogin',
                        'B4: no character-list widget tree headless; wire deps.onRelog')
                if log and log.warn then
                    log.warn('shim/modules: relogOnCharacter(%s) ignored -- no reconnect handler wired',
                             tostring(charName))
                end
                return false
            end,
        }),
        show = function() rec.hit('client_entergame.show', 'no enter-game UI') end,
        hide = function() rec.hit('client_entergame.hide', 'no enter-game UI') end,
    })

    -- --------------------------------------------------------- client_textedit
    -- Every site is user-initiated (depositer_config.lua:72,90; new_healer.lua:1036;
    -- supplies.lua:250; the cavebot editors).  NEVER invoke the callback: doing so
    -- would apply an empty edit to the user's real config.
    local function textedit(name)
        return function(...)
            rec.hit('client_textedit.' .. name, 'modal editors need a user; callback never fires')
            return leaf('textedit.' .. name)
        end
    end
    modules.client_textedit = sandbox(G, {
        show = textedit('show'), edit = textedit('edit'),
        singlelineEditor = textedit('singlelineEditor'),
        multilineEditor  = textedit('multilineEditor'),
    })

    -- ---------------------------------------------------------- client_options
    -- game_walk.lua:186 reads getOption('smartWalk'); other otclient code reads
    -- more.  Backed by a real store so a set is readable again.
    local optionDefaults = {
        smartWalk = false, dontStretchShrink = false, walkBooster = false,
        autoChaseOverride = true, showLeftPanel = false, showRightPanel = true,
        displayText = true, enableAudio = false, vsync = false,
    }
    local optionStore = {}
    for k, v in pairs(optionDefaults) do optionStore[k] = v end
    if deps.options then for k, v in pairs(deps.options) do optionStore[k] = v end end
    modules.client_options = sandbox(G, {
        getOption = function(key)
            local v = optionStore[key]
            if v == nil then rec.hit('client_options.getOption:' .. tostring(key), 'unknown option -> nil') end
            return v
        end,
        setOption = function(key, value) optionStore[key] = value end,
        toggleOption = function(key) optionStore[key] = not optionStore[key] end,
    })

    -- ---------------------------------------------- client_profiles MUST be nil
    -- bot.lua:341 is `if not (modules.client_profiles and ...)` and takes the
    -- fallback path only when this is nil.  Do not add it.
    modules.client_profiles = nil

    -- ------------------------------------------ modules == package.loaded shape
    -- corelib/globals.lua:4.  Some otclient code does `modules.corelib`; give the
    -- names the sandbox might touch a home so an index is never a hard nil error
    -- in a chain the profile writes.
    modules.corelib   = sandbox(G, {})
    modules.game_bot_shim = nil

    local ctl = {
        modules  = modules,
        cooldown = cooldown,
        npctrade = npctrade,
        record   = rec,
        report   = rec.report,
        leaf     = leaf,
        setConfig = function(name) config = tostring(name) end,
        --- Wire the real reconnect / exit handlers after the fact (host.lua does
        --- this once it knows the supervisor).
        setHandlers = function(t)
            if t.onForceExit then deps.onForceExit = t.onForceExit end
            if t.onRelog then deps.onRelog = t.onRelog end
        end,
    }
    return modules, ctl
end

return M
