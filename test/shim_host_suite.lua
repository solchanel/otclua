--[==[========================================================================
test/shim_host_suite.lua -- work item S4: the modules.* graph, the vBot runtime
host, and the boot sequence.

    luajit test/shim_host_suite.lua            (from D:/Claude/otclient_web/luaclient)
    wsl.exe -d Debian -e sh -c 'cd /mnt/d/Claude/otclient_web/luaclient && \
        luajit test/shim_host_suite.lua'

THE DELIVERABLE is section D: shim/bootstrap.lua boots against a SYNTHETIC world
and loads the user's REAL profile at
D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8 -- all 74 vBot files
plus the 27 mods/game_bot runtime files -- then reports

    * how many files loaded and how many failed, split vBot / runtime,
    * the FIRST error per failing file (a per-file table, never a single
      traceback: one crash in _Loader.lua would otherwise hide the other 73),
    * how many macros registered and how many the user's own storage has enabled,
    * how many ticks ran and how many raised,
    * every modules.* symbol that resolved to a recorded stub, with its call count.

Sections A-C are unit tests and run everywhere.  Section D SKIPS WITH A PRINTED
REASON when the otclient tree is absent, so the suite still passes on Debian.

NOTHING is written under D:/Claude/otclient_mehah1530.  The host runs in
readOnly mode, which intercepts every g_resources write, records it and refuses
it; section D asserts that the interception actually happened.

Set `_G.SHIMHOST_NO_EXIT = true` before dofile()ing this file and it returns
{ pass=, fail=, failures={} } instead of exiting.
==========================================================================]==]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. ROOT .. '/?/init.lua;' .. package.path
end

-- The user's REAL otclient checkout.  Resolved relative to this one first, so the
-- identical file runs on Windows and under WSL.  READ ONLY.
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

-- ========================================================== shared fixtures
local state   = require('game.state')
local events  = require('lib.events')
local sched   = require('lib.sched')
local items   = require('proto.items')
local sender  = require('proto.sender')

--- A synthetic client: real state, real sender over a capturing transport.
local function newLC()
    local st = state.new()
    local sent = {}
    local transport = {
        send = function(_, body) sent[#sent + 1] = body; return true end,
    }
    local logged = {}
    local function cap(f, ...)
        local line = tostring(f)
        if select('#', ...) > 0 then
            local ok, r = pcall(string.format, line, ...)
            if ok then line = r end
        end
        logged[#logged + 1] = line
    end
    local log = { info = cap, warn = cap, error = cap, debug = cap }
    local LC = {
        state = st, items = items, events = events.new(), sched = sched,
        log = log, inGame = true,
        sender = sender.new(transport, { accountName = 'test' }),
        transport = transport,
    }
    return LC, sent, logged, st
end

--==============================================================================
section('A  shim/modules.lua -- the module graph')
--==============================================================================
do
    local modmod = require('shim.modules')
    local G = { g_clock = { millis = function() return 1000 end },
                connect = function() return 'THE-REAL-CONNECT' end,
                SpellInfo = { Default = {} },
                Spells = { getSpellByWords = function(w) return w == 'exura' and { id = 1 } or nil end },
                SpellAimTarget = 3, SpellAimCursor = 1,
                SpellAimInvalidPosition = { x = 0xFFFF, y = 0, z = 0 } }

    local talked = {}
    G.g_game = {
        getClientVersion = function() return 1530 end,
        talk = function(t) talked[#talked + 1] = { kind = 'talk', text = t }; return true end,
        talkSpell = function(t, aim, pos)
            talked[#talked + 1] = { kind = 'talkSpell', text = t, aim = aim, pos = pos }
            return true
        end,
        walk = function(dir) talked[#talked + 1] = { kind = 'walk', dir = dir }; return true end,
        cancelLogin = function() talked[#talked + 1] = { kind = 'cancelLogin' } end,
    }

    local LC = { state = { channels = { [1] = 'Loot', [3] = 'Help' }, player = { levelPercent = 42, stamina = 2400 } } }
    local exited = 0
    local mods, ctl = modmod.build(G, {
        config = 'vBot_4.8', LC = LC, g_game = G.g_game,
        onForceExit = function() exited = exited + 1; return true end,
    })

    -- I7: every modules.X is a sandbox env whose __index is SHIM_G
    eq(mods.game_bot.connect(), 'THE-REAL-CONNECT',
       'modules.game_bot.connect resolves through __index to the global connect (I7)')
    check(rawget(mods.game_bot, 'connect') == nil,
          'and it is NOT an own field -- it really goes through the metatable')
    eq(mods.gamelib.SpellInfo, G.SpellInfo, 'modules.gamelib.SpellInfo is the global table')
    eq(mods.game_spelllist.SpellInfo, G.SpellInfo, 'modules.game_spelllist.SpellInfo is the SAME table')

    -- api-platform.md sec.5.2: the modules that must exist or _Loader aborts
    for _, name in ipairs({ 'game_bot', 'gamelib', 'game_cooldown', 'game_textmessage',
                            'game_console', 'game_interface', 'game_minimap', 'game_skills',
                            'game_buttons', 'game_mainpanel', 'client_topmenu',
                            'client_terminal', 'client_entergame', 'client_textedit',
                            'game_npctrade', 'game_inventory', 'game_spelllist',
                            'game_walk', 'game_outfit', 'client_options' }) do
        check(type(mods[name]) == 'table', 'modules.' .. name .. ' exists')
    end
    check(mods.client_profiles == nil,
          'modules.client_profiles is NIL -- bot.lua:341 needs the fallback path')

    -- the four unguarded load-time chains (api-platform.md sec.5.2)
    eq(mods.game_bot.contentsPanel.config:getCurrentOption().text, 'vBot_4.8',
       'contentsPanel.config:getCurrentOption().text is the config dir name')
    check(type(mods.game_textmessage.messagesPanel.statusLabel) == 'table',
          'game_textmessage.messagesPanel.statusLabel exists')
    check(type(mods.game_textmessage.messagesPanel.centerTextMessagePanel.highCenterLabel:getText()) == 'string',
          'highCenterLabel:getText() returns a STRING (it is compared with ==)')
    check(type(mods.game_interface.gameRootPanel) == 'table',
          'game_interface.gameRootPanel is assignable (xeno_menu.lua:1)')
    check(type(mods.game_minimap.getMiniMapUi()) == 'table',
          'game_minimap.getMiniMapUi() returns an object (cavebot/minimap.lua:1)')
    check(mods.game_minimap.getMiniMapUi() == mods.game_minimap.getMiniMapUi(),
          'and it is the SAME object every call -- the handler is assigned to it once')
    eq(type(mods.game_interface.lastManualWalk), 'number',
       'game_interface.lastManualWalk is a NUMBER (attacking.lua:904 adds 500 to it)')
    eq(mods.game_skills.skillsWindow.contentsPanel.level.percent:getPercent(), 42,
       'game_skills level.percent:getPercent() is backed by state.player.levelPercent')
    eq(mods.game_skills.skillsWindow.contentsPanel.stamina.value:getText(), '40:00',
       'game_skills stamina.value:getText() is backed by state.player.stamina')
    eq(type(mods.game_buttons.buttonsWindow), 'table',
       'game_buttons.buttonsWindow exists (analyzer.lua:198 indexes two levels)')
    eq(mods.client_topmenu.getButton('x'), nil, 'client_topmenu.getButton returns nil')
    check(type(mods.game_npctrade.getSellExceptions()) == 'table',
          'game_npctrade.getSellExceptions() is ipairs-able')
    eq(mods.game_spelllist.getSpelllistProfile(), 'Default', 'getSpelllistProfile() -> "Default"')
    eq(mods.game_inventory.getSlot(5), mods.game_inventory.getSlot5(),
       'game_inventory.getSlot(5) and getSlot5() are the same object')

    -- game_console.channels is a LIVE reference, not a copy
    eq(mods.game_console.channels[3], 'Help', 'game_console.channels is backed by state.channels')
    LC.state.channels[5] = 'Trade'
    eq(mods.game_console.channels[5], 'Trade', 'and it tracks later parser updates')
    eq(mods.game_console.isEnabledWASD(), false, 'isEnabledWASD() is false headless')

    -- game_walk.smartWalk IS context.walk: it must really walk
    local n = #talked
    mods.game_walk.smartWalk(1)
    check(#talked == n + 1 and talked[#talked].kind == 'walk' and talked[#talked].dir == 1,
          'game_walk.smartWalk(dir) reaches g_game.walk -- this IS context.walk')

    -- game_interface.tryCastSpellMessage IS context.say
    talked = {}
    local handled = mods.game_interface.tryCastSpellMessage('exura')
    check(handled == true and talked[1] and talked[1].kind == 'talkSpell' and talked[1].aim == 3,
          'tryCastSpellMessage("exura") casts with SpellAimTarget, not a plain talk')
    talked = {}
    eq(mods.game_interface.tryCastSpellMessage('hello there'), false,
       'a non-spell message is NOT handled, so context.say falls through to g_game.talk')
    eq(#talked, 0, 'and nothing was sent for it')
    talked = {}
    mods.game_interface.castAimedSpell('exura', 3, { x = 100, y = 100, z = 7 })
    check(talked[1] and talked[1].aim == 1 and talked[1].pos.x == 100,
          'an explicit aim position is sent as SpellAimCursor + that tile')

    -- forceExit is REAL
    mods.game_interface.forceExit()
    check(exited == 1, 'game_interface.forceExit() ran the real exit handler (antiRs.lua:14)')

    -- cooldown predicates
    local nowv = 1000
    G.g_clock.millis = function() return nowv end
    local cd = ctl.cooldown
    eq(cd.isCooldownIconActive(7), false, 'an unknown cooldown icon is not active')
    cd.record(7, 2000)
    eq(mods.game_cooldown.isCooldownIconActive(7), true, 'a recorded icon cooldown is active')
    nowv = 3500
    eq(mods.game_cooldown.isCooldownIconActive(7), false, 'and expires on the clock')
    cd.recordGroup(2, 500)
    eq(mods.game_cooldown.isGroupCooldownIconActive(2), true, 'group cooldowns work the same way')
    nowv = 4100
    eq(mods.game_cooldown.isGroupCooldownIconActive(2), false, 'group cooldown expires')

    -- the recorder: nothing silent
    local rep = ctl.report()
    check(#rep > 0, 'ctl.report() lists the stubs that were actually called')
    local found = false
    mods.client_textedit.show('x', {}, function() error('the modal callback must NEVER fire') end)
    for _, e in ipairs(ctl.report()) do if e.symbol == 'client_textedit.show' then found = true end end
    check(found, 'client_textedit.show is recorded and its callback is never invoked')
end

--==============================================================================
section('B  shim/modules.lua -- npctrade sellAll')
--==============================================================================
do
    local modmod = require('shim.modules')
    local LC, sent = newLC()
    -- the exact shape proto/parser.lua:1549 (opcode 0x7A) leaves on the state,
    -- plus an open container holding 47 of the sellable item
    LC.state.npcTrade = { open = true, items = {
        { id = 3031, subType = 0, name = 'gold coin', weight = 10, buyPrice = 0, sellPrice = 1 },
        { id = 3300, subType = 0, name = 'sword',     weight = 100, buyPrice = 50, sellPrice = 0 },
    } }
    LC.state.containers[1] = { id = 1, name = 'bp', items = { { id = 3031, count = 40 } } }
    LC.state.player.inventory[10] = { id = 3031, count = 7 }   -- game/state.lua:134

    local G = { g_clock = { millis = function() return 0 end } }
    local mods, ctl = modmod.build(G, { config = 'c', LC = LC, g_game = {} })

    eq(mods.game_npctrade.isTrading(), true, 'isTrading() reads the parsed trade state')
    eq(#mods.game_npctrade.getSellItems(), 1, 'getSellItems() keeps only the offers the NPC pays for')
    eq(#mods.game_npctrade.getBuyItems(), 1, 'getBuyItems() keeps only the offers the NPC charges for')
    eq(mods.game_npctrade.getSellQuantity(3031), 47,
       'getSellQuantity counts the open containers AND the equipped slots (40 + 7)')
    local before = #sent
    local n = mods.game_npctrade.sellAll()
    eq(n, 1, 'sellAll() sent one sell packet')
    check(#sent == before + 1, 'and it really reached the transport')
    eq(sent[#sent]:byte(1), 0x7B, 'the opcode is 0x7B ClientSellItem')

    mods.game_npctrade.setSellExceptions({ 3031 })
    local n2 = mods.game_npctrade.sellAll()
    eq(n2, 0, 'an excepted id is not sold')
    local ex = mods.game_npctrade.getSellExceptions()
    ex[1] = 999
    eq(mods.game_npctrade.getSellExceptions()[1], 3031,
       'getSellExceptions() returns a COPY (sell_exceptions.lua:122-130)')
end

--==============================================================================
section('C  shim/host.lua -- units that need no otclient tree')
--==============================================================================
do
    local host = require('shim.host')

    -- the bot-tabs contract (executor.lua:24, ui_legacy.lua:32-46)
    local made = {}
    local tabs = host.newTabs(function(style) made[#made + 1] = style; return { style = style } end)
    local main = tabs:addTab('Main', { style = 'BotPanel' })
    check(main.tabPanel and main.tabPanel.content, 'addTab(name, panel).tabPanel.content exists')
    eq(main.tabPanel.content.style, 'BotPanel', 'and it is the panel that was passed in')
    eq(tabs:getTab('Main'), main, 'getTab(name) returns the same tab')
    eq(tabs:addTab('Main'), main, 'addTab of an existing name does not duplicate it')
    eq(main:getText(), 'Main', 'tab:getText() is the tab name (ui_legacy.lua:41)')
    tabs:setOn(true)
    eq(tabs:isOn(), true, 'tabs:setOn is stateful')

    -- the audited patch table must be exactly what PLAN sec.1.14 documents
    local p = host.PATCHES['functions/map.lua']
    check(p and #p == 2, 'functions/map.lua carries both getSpectators branches')
    do
        local n = 0
        for _ in pairs(host.PATCHES) do n = n + 1 end
        check(n == 3, ('exactly three patched files (%d) -- the only three '
                       .. 'table-vs-userdata tests in the tree'):format(n))
        check(host.PATCHES['functions/ui_elements.lua'] ~= nil, 'ui_elements.lua setItems is patched')
        check(host.PATCHES['/vBot/training.lua'] ~= nil, 'the profile training.lua copy is patched')
    end
    check(p[2].replacement:find("param1.getPosition ~= nil", 1, true) ~= nil,
          'the userdata branch is rewritten to a table-with-getPosition test')

    -- drift detection: a patch whose `expected` text is gone must FAIL LOUDLY
    if OTROOT then
        local f = io.open(OTROOT .. '/mods/game_bot/functions/map.lua', 'rb')
        local src = f:read('*a'); f:close()
        for _, e in ipairs(p) do
            check(src:find(e.expected, 1, true) ~= nil,
                  'upstream still contains the patched text: ' .. e.expected:gsub('\n', ''))
        end
    else
        skip('patch drift check', 'otclient tree not present')
    end
end

--==============================================================================
section('D  THE DELIVERABLE -- boot the real vBot 4.8 profile')
--==============================================================================
local D = nil
if not OTROOT then
    skip('real-profile boot', 'otclient tree not found next to this checkout')
else
    local shim = require('shim.bootstrap')
    local LC, sent, logged = newLC()

    -- Put a player in the world so LocalPlayer-shaped reads have something real.
    LC.state.player = LC.state.player or {}
    local pl = LC.state.player
    pl.id, pl.name = 0x1000, 'ShimTester'
    pl.pos = { x = 1000, y = 1000, z = 7 }
    pl.health, pl.maxHealth, pl.mana, pl.maxMana = 500, 800, 300, 400
    pl.level, pl.levelPercent, pl.stamina = 100, 55, 2400
    pl.states, pl.speed, pl.direction = 0, 220, 0
    pl.vocation, pl.soul, pl.capacity = 1, 100, 4000
    LC.state.creatures = LC.state.creatures or {}
    LC.state.creatures[pl.id] = pl

    -- A virtual clock, stepped 1 s per tick: five ticks of wall time span well
    -- under a millisecond, so without this almost no macro is ever due and
    -- "5 ticks, 0 errors" would prove nothing.
    local vnow = 0
    local S, err = shim.start(LC, {
        otRoot = OTROOT, config = 'vBot_4.8', profile = 1,
        readOnly = true, arm = false,
        clock = function() return vnow end,
    })
    check(S ~= nil, 'shim.start returned a handle', err)

    if S then
        for _, b in ipairs(shim.status().boot or {}) do
            check(b.ok, 'boot step ' .. b.step, b.err)
        end

        -- Count every macro body that actually runs.  Without this, "12 ticks, 0
        -- errors" is not evidence: a tick over 48 macros none of which is due does
        -- nothing at all and still reports clean (A4 sec.5 makes the same point).
        eq(shim.instrumentMacros(), 48, 'all 48 macro callbacks were instrumented')

        local TICKS = 12
        for i = 1, TICKS do
            vnow = vnow + 1000            -- 1 s per tick, so 500-1000 ms macros are due
            shim.tick()
        end
        D = shim.status()

        -- ---- the numbers ------------------------------------------------
        eq(D.vbotFailed, 0, ('all %d vBot profile files loaded'):format(D.vbotLoaded))
        check(D.vbotLoaded >= 74, ('at least 74 vBot files loaded (got %d)'):format(D.vbotLoaded))
        eq(D.runtimeFailed, 0, ('all %d mods/game_bot runtime files loaded'):format(D.runtimeLoaded))
        check(D.runtimeLoaded >= 27, ('at least 27 runtime files loaded (got %d)'):format(D.runtimeLoaded))
        check(D.macroCount >= 40, ('at least 40 macros registered (got %d)'):format(D.macroCount))
        check(D.storageBytes and D.storageBytes > 1000,
              ('the user real storage/profile_1.json was read (%s bytes)'):format(tostring(D.storageBytes)))
        check(D.macrosEnabled > 0 and D.macrosEnabled < D.macroCount,
              ('the user own storage._macros decided which macros are on (%d of %d)')
              :format(D.macrosEnabled, D.macroCount))
        eq(D.ticks, TICKS, ('%d ticks ran'):format(TICKS))
        eq(D.tickErrors, 0, 'no tick raised', D.firstTickError)
        check(D.macrosRan > 0,
              ('%d distinct macros actually executed (%d bodies run in total)')
              :format(D.macrosRan, D.macroRuns))
        check(D.maxTickMs < 200, ('the slowest tick was %d ms'):format(D.maxTickMs))

        -- ---- the safety property ---------------------------------------
        -- Nothing may be written under the user's profile.  The guard records
        -- every attempt; the real vBot config-save path fires during load.
        eq(type(D.blockedWrites), 'table', 'the read-only guard is installed')
        do
            local res = S.G.g_resources
            eq(res.writeFileContents('/bot/vBot_4.8/storage/profile_1.json', 'x'), false,
               'a write into the user profile is REFUSED')
            check(#D.blockedWrites > 0, 'and it is recorded, not silent')
            local f = io.open(OTROOT .. '/profiles/bot/vBot_4.8/storage/profile_1.json', 'rb')
            local bytes = f and #f:read('*a') or 0
            if f then f:close() end
            check(bytes == D.storageBytes,
                  ('the user storage file is byte-identical after the run (%d bytes)'):format(bytes))
        end

        -- ---- the patch really applied -----------------------------------
        -- 2 x functions/map.lua + functions/ui_elements.lua + /vBot/training.lua
        check(#D.patchNotes == 4,
              ('all four audited patches applied (%d)'):format(#D.patchNotes))
        check(#(D.patchFailures or {}) == 0, 'no patch drifted')
        local sawUI, sawTraining = false, false
        for _, n in ipairs(D.patchNotes) do
            if n:find('ui_elements', 1, true) then sawUI = true end
            if n:find('training', 1, true) then sawTraining = true end
        end
        check(sawUI, 'functions/ui_elements.lua setItems patch applied')
        check(sawTraining, 'the profile vBot/training.lua setItems patch applied')
        do
            local ctx = shim.context()
            check(type(ctx) == 'table', 'the sandbox context was recovered from the executor')
            if ctx then
                check(type(rawget(ctx, 'getSpectators')) == 'function',
                      'context.getSpectators exists (functions/map.lua loaded)')
                check(type(rawget(ctx, 'macro')) == 'function', 'context.macro exists')
                check(type(rawget(ctx, 'storage')) == 'table', 'context.storage is the decoded profile')
                check(rawget(ctx, 'CaveBot') ~= nil, 'the profile defined CaveBot')
                check(rawget(ctx, 'TargetBot') ~= nil, 'the profile defined TargetBot')
                check(rawget(ctx, 'HealBot') ~= nil or rawget(ctx, 'vBot') ~= nil,
                      'the profile defined its own top-level tables')
            end
        end

        shim.stop()
        eq(shim.status().started, false, 'shim.stop() tore the host down')

        -- PLAN sec.1.1: boot is idempotent per LC -- stop() must leave things clean
        -- enough that a config reload can boot again on the same client.
        local LC2 = newLC()
        LC2.state.player = { id = 0x1000, name = 'Again', pos = { x = 1, y = 1, z = 7 },
                             health = 1, maxHealth = 1, mana = 1, maxMana = 1, states = 0 }
        local v2 = 0
        local S2 = shim.start(LC2, { otRoot = OTROOT, config = 'vBot_4.8', profile = 1,
                                     readOnly = true, clock = function() return v2 end })
        local st2 = shim.status()
        check(S2 ~= nil and st2.vbotFailed == 0 and st2.vbotLoaded >= 74,
              ('a second boot after stop() loaded the tree again (%d files, %d failed)')
              :format(st2.vbotLoaded or -1, st2.vbotFailed or -1))
        shim.stop()
    end
end

--==============================================================================
-- THE TABLE
--==============================================================================
io.write('\n', string.rep('=', 78), '\n')
io.write('S4 -- real vBot 4.8 under shim/bootstrap.lua\n')
io.write(string.rep('=', 78), '\n')
if not D then
    io.write('  (skipped: no otclient tree at ', tostring(OTROOT), ')\n')
else
    io.write(('  otclient tree     : %s\n'):format(D.otRoot))
    io.write(('  config / profile  : %s / %d      read-only: %s\n')
             :format(D.config, D.profile, tostring(D.readOnly)))
    io.write(('  UI backend        : %s\n'):format(tostring(D.ui)))
    io.write(('  vBot profile files: %d loaded, %d failed\n'):format(D.vbotLoaded, D.vbotFailed))
    io.write(('  game_bot runtime  : %d loaded, %d failed\n'):format(D.runtimeLoaded, D.runtimeFailed))
    io.write(('  load time         : %d ms   (storage %s bytes)\n')
             :format(D.loadMs or -1, tostring(D.storageBytes)))
    io.write(('  macros            : %d registered, %d enabled by the user storage\n')
             :format(D.macroCount, D.macrosEnabled))
    io.write(('  callbacks/hotkeys : %d / %d\n'):format(D.callbacks, D.hotkeys))
    io.write(('  ticks             : %d run, %d raised   (slowest %d ms)\n')
             :format(D.ticks, D.tickErrors, D.maxTickMs))
    io.write(('  macro bodies      : %d distinct macros ran, %d executions, %d raised\n')
             :format(D.macrosRan or 0, D.macroRuns or 0, D.macroFails or 0))
    io.write(('  bot messages      : info=%d warn=%d error=%d\n')
             :format(D.messages.info, D.messages.warn, D.messages.error))
    io.write(('  refused writes    : %d (the user profile is untouched)\n'):format(#D.blockedWrites))

    if #D.failures > 0 then
        io.write('\n  FIRST ERROR PER FAILING FILE\n')
        for _, f in ipairs(D.failures) do
            io.write(('   %-46s %s\n'):format(f.name, (f.err or '?'):gsub('\n.*', ''):sub(1, 160)))
        end
    else
        io.write('\n  no file failed to load\n')
    end

    do
        local bad = {}
        for _, m in ipairs(D.macros) do
            if (m.fails or 0) > 0 then bad[#bad + 1] = m end
        end
        if #bad > 0 then
            io.write('\n  MACROS THAT RAISED (first error each)\n')
            for _, m in ipairs(bad) do
                io.write(('   %-38s %d/%d fail  %s\n')
                         :format(m.name ~= '' and m.name or '<unnamed>', m.fails, m.runs,
                                 (m.err or '?'):gsub('\n.*', ''):sub(1, 110)))
            end
        end
    end

    if D.firstTickError then
        io.write('\n  FIRST TICK ERROR\n   ', D.firstTickError:gsub('\n.*', ''), '\n')
    end

    if #D.messageLog > 0 then
        io.write('\n  BOT-LEVEL MESSAGES (the user own scripts, first 10)\n')
        for i = 1, math.min(10, #D.messageLog) do
            io.write('   ', D.messageLog[i]:gsub('\n.*', ''):sub(1, 150), '\n')
        end
    end

    io.write('\n  modules.* SYMBOLS THAT RESOLVED TO A RECORDED STUB\n')
    if #D.stubs == 0 then
        io.write('   (none)\n')
    else
        for i = 1, math.min(25, #D.stubs) do
            io.write(('   %-52s %5d  %s\n')
                     :format(D.stubs[i].symbol, D.stubs[i].n, D.stubs[i].why or ''))
        end
        if #D.stubs > 25 then io.write(('   ... and %d more\n'):format(#D.stubs - 25)) end
    end

    local slowest, slowestName = 0, '?'
    for _, f in ipairs(D.files) do
        if (f.ms or 0) > slowest then slowest, slowestName = f.ms, f.name end
    end
    io.write(('\n  slowest file to load: %s (%d ms)\n'):format(slowestName, slowest))
end

--==============================================================================
io.write('\n================ shim host suite ================\n')
for _, m in ipairs(msgs) do io.write(m, '\n') end
io.write(('  TOTAL: %d passed, %d failed  -> %s\n')
         :format(pass, fail, fail == 0 and 'PASS' or 'FAIL'))
io.write(('  platform: %s  luajit: %s  otclient: %s\n')
         :format(package.config:sub(1, 1) == '\\' and 'windows' or 'posix',
                 _VERSION .. (jit and (' / ' .. jit.version) or ''),
                 OTROOT or '<absent>'))

if _G.SHIMHOST_NO_EXIT then return { pass = pass, fail = fail, failures = msgs } end
os.exit(fail == 0 and 0 or 1)
