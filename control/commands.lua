--[[============================================================================
control/commands.lua -- the worker's command table (PANEL.md "Worker control
protocol"), the vBot-compatible script environment and the `exec` sandbox-that-
is-not-a-sandbox.

    local commands = require('control.commands')
    local ok, resultOrErr = commands.dispatch(ctx, cmd, args)

`ctx` is built by control/server.lua and carries { LC, server, log }.  Every
handler returns `result` (any JSON-encodable value, `true` when there is nothing
to say) or `nil, 'message'`.  A handler that RAISES is caught by dispatch and
turned into an error reply -- PANEL.md's "a bad command returns an error rather
than killing the worker" is enforced here, not by the caller.

Commands (exactly PANEL.md's list):

    status                      full instance snapshot
    login {account,password,token,character,world,host,port}
    logout                      leave the game, keep the process
    relogin {delayMs}           logout, then login again with the same config
    bot.enable {on}             start / stop the bot layer
    bot.setCavebot {name}       select cavebot_configs/<name>.cfg   ('' = off)
    bot.setTargetbot {name}     select targetbot_configs/<name>.json ('' = off)
    bot.listConfigs             what is on disk, and what is selected
    bot.reload                  re-read the whole profile from disk
    config.get  {kind}          the ACTIVE config of one of the six kinds (CONFIGAPI.md)
    config.set  {kind, data, reload=true, execCapability=false}
                                 validate + write + hot-reload one kind's config
    config.list {kind}          named profiles/configs for a kind, and which is active
    script.put {name, source}   write + load a script into the bot environment
    script.remove {name}        unload it and delete the file
    script.list                 loaded scripts, with sizes and load times
    exec {code}                 run one chunk in the same environment
    stats                       the lib/stats.lua snapshot
    debug.snapshot              structured diagnostics for a panel debug console (work item R2)
    shutdown {code}             clean exit

------------------------------------------------------------------------------
THE SCRIPT ENVIRONMENT
------------------------------------------------------------------------------
`script.put` and `exec` both run in ONE shared environment per bot instance,
built the same way bot/cavebot.lua:1773 builds the environment for a `function:`
waypoint -- the bot's own vBot-compatible surface (`bot.api`) first, then `_G`.
On top of that it carries:

  * a shared globals table, so `foo = 1` in one script is visible to the next
    (this is what vBot's scripts assume: they are all loaded into one _G);
  * `CaveBot` / `TargetBot` dot-proxies, so `CaveBot.setOff()` works;
  * event registrars with vBot's callback signatures -- `onTextMessage(mode,text)`,
    `onTalk`, `onCreatureAppear`, ... -- which bot/api.lua does not provide (they
    are classified [U] in docs/vbot/bot-core.md §3.6).  Every registration made
    while a script is loading is REMEMBERED, so `script.remove` can take it back
    out; the same goes for macros the script registers.

Nothing is sandboxed.  PANEL.md is explicit about that ("the worker sandboxes
nothing beyond what vBot does") -- the trust boundary is the hub's web login and
the audit log, not this file.

Lua 5.1 / LuaJIT: no goto, `setfenv`, `loadstring`.
============================================================================]]

local M = {}

local sys          = require('lib.sys')
local cfglib        = require('bot.config')
local configschema   = require('bot.configschema')

-- lib/events.lua is BOTH a bus and a module: `events.on(name, fn)` on the module, but
-- `bus:on(name, fn)` on an independent bus from events.new().  The worker hands us the
-- module; a test may hand us its own bus.  One adapter, so both work.
local function busOn(bus, name, fn)
    if bus.new then return bus.on(name, fn) end
    return bus:on(name, fn)
end

local function busOff(bus, handle)
    if bus.new then return bus.off(handle) end
    return bus:off(handle)
end

-- ===========================================================================
-- helpers
-- ===========================================================================
local function argTable(args)
    if args == nil then return {} end
    if type(args) ~= 'table' then return nil end
    return args
end

local function optString(t, key)
    local v = t[key]
    if v == nil then return nil end
    if type(v) ~= 'string' then return nil, ('%s must be a string'):format(key) end
    return v
end

-- ---------------------------------------------------------------------------
-- work item R2: the debug-console event ring buffer.  Declared up here (not
-- beside the rest of `debug.snapshot` near the bottom of this file) because
-- several EARLIER command handlers (bot.enable, bot.setCavebot/setTargetbot,
-- bot.setMacro, bot.reload, config.set) push one structured event each, at
-- the exact moment they already act -- see the `debug.snapshot` section below
-- for the full rationale.  Lives on ctx.server (not the bot instance) so it
-- survives a bot.reload -- the reload itself is one of the events worth
-- keeping.
local DEBUG_EVENTS_DEFAULT = 200

local function pushDebugEvent(ctx, kind, detail)
    local srv = ctx and ctx.server
    if not srv then return end
    local buf = srv._debugEvents
    if not buf then buf = {}; srv._debugEvents = buf end
    local cap = tonumber(srv.debugEventsMax) or DEBUG_EVENTS_DEFAULT
    buf[#buf + 1] = { tMs = sys.nowMs(), kind = kind, detail = detail }
    while #buf > cap do table.remove(buf, 1) end
end
M.pushDebugEvent = pushDebugEvent

--- A script name has to be a plain file name we are willing to create: no path
--- separators, no '..', no drive letters, no NUL.  '.lua' is optional on input and
--- always present on disk.
local SCRIPT_NAME_MAX = 96
function M.normaliseScriptName(name)
    if type(name) ~= 'string' then return nil, 'name must be a string' end
    local n = name:gsub('%.lua$', '')
    if n == '' then return nil, 'name is empty' end
    if #n > SCRIPT_NAME_MAX then return nil, 'name is too long' end
    if n:find('[/\\]') then return nil, 'name must not contain a path separator' end
    if n:find('%z') then return nil, 'name must not contain NUL' end
    if n:find(':') then return nil, 'name must not contain a colon' end
    if n == '.' or n == '..' or n:find('^%.') then return nil, 'name must not start with a dot' end
    if not n:find('^[%w%-_. ]+$') then
        return nil, 'name may only contain letters, digits, space, dot, dash and underscore'
    end
    return n
end

-- ===========================================================================
-- the shared script environment
-- ===========================================================================
-- Adapters from OUR event bus (a single data table per event) to vBot's callback
-- signatures.  Anything not listed here is still reachable through the generic
-- `onEvent(name, fn)`, which passes the raw data table.
local EVENT_ADAPTERS = {
    onTextMessage = { 'textMessage', function(d) return d and d.mode, d and d.text end },
    onTalk        = { 'talk', function(d)
                          return d and d.name, d and d.level, d and d.mode, d and d.text
                      end },
    onCreatureAppear     = { 'creatureAppear',     function(d) return d and d.creature or d end },
    onCreatureDisappear  = { 'creatureDisappear',  function(d) return d and d.creature or d end },
    onCreatureHealthPercentChange = { 'creatureHealth', function(d)
                          return d and (d.creature or d.id), d and (d.healthPercent or d.health)
                      end },
    onContainerOpen  = { 'containerOpen',  function(d) return d end },
    onContainerClose = { 'containerClose', function(d) return d end },
    onAddItem        = { 'containerAddItem', function(d)
                          return d and d.containerId, d and d.slot, d and d.item
                      end },
    onContainerUpdateItem = { 'containerUpdateItem', function(d)
                          return d and d.containerId, d and d.slot, d and d.item
                      end },
    onPositionChange = { 'positionChange', function(d) return d and d.pos, d and d.old end },
    onHealthChange   = { 'healthChange',   function(d) return d and d.health, d and d.maxHealth end },
    onManaChange     = { 'manaChange',     function(d) return d and d.mana, d and d.maxMana end },
    onDeath          = { 'death',          function(d) return d end },
    onSpellCooldown  = { 'spellCooldown',  function(d) return d and d.id, d and d.duration end },
}

--- envFor(LC) -> env, registry
---
--- Built once per bot instance and cached on the bot object, so a script loaded now
--- can see a global a script loaded earlier set.  It is dropped with the bot: a
--- `bot.reload` gives every script a clean slate, which is what a reload is for.
local function envFor(LC)
    local b = LC and LC.bot
    if not b then return nil, 'the bot layer is not running (bot.enable {on:true} first)' end
    if b._controlEnv then return b._controlEnv, b._controlScripts end

    local ctx = b.api
    local okcb, cavebot = pcall(require, 'bot.cavebot')
    local dotProxy = okcb and cavebot.dotProxy or nil

    -- `current` is set to a script's registry entry while that script's chunk runs, so
    -- every macro and every event handler it creates is charged to it.
    local reg = { scripts = {}, order = {}, current = nil }

    local env = {}
    setmetatable(env, { __index = function(_, k)
        if ctx then
            local v = ctx[k]
            if v ~= nil then return v end
        end
        return _G[k]
    end })

    -- CaveBot / TargetBot dot-proxies, exactly what a vBot script expects to find.
    if dotProxy then
        env.CaveBot   = dotProxy(b.modules and b.modules.cavebot)
        env.TargetBot = dotProxy(b.modules and b.modules.targetbot)
    end

    -- macro(): the real one, with the returned record remembered so it can be removed.
    env.macro = function(...)
        local rec = b:macro(...)
        local cur = reg.current
        if cur and rec then cur.macros[#cur.macros + 1] = rec end
        return rec
    end

    local bus = LC.events
    local function register(eventName, adapt, fn)
        if type(fn) ~= 'function' then
            error('event callback must be a function, got ' .. type(fn), 2)
        end
        if not bus then return nil end
        local handle = busOn(bus, eventName, function(d)
            if adapt then return fn(adapt(d)) else return fn(d) end
        end)
        local cur = reg.current
        if cur then cur.handles[#cur.handles + 1] = handle end
        return handle
    end

    for envName, spec in pairs(EVENT_ADAPTERS) do
        local eventName, adapt = spec[1], spec[2]
        env[envName] = function(fn) return register(eventName, adapt, fn) end
    end
    env.onEvent = function(name, fn) return register(tostring(name), nil, fn) end
    env.offEvent = function(handle) if bus then return busOff(bus, handle) end end

    b._controlEnv     = env
    b._controlScripts = reg
    return env, reg
end
M.envFor = envFor

--- Take a loaded script back out: remove the macros it registered and unsubscribe its
--- event handlers.  Anything else it did (a timer through schedule(), a global it set)
--- cannot be undone -- say so in the reply rather than pretending otherwise.
local function unloadEntry(LC, reg, entry)
    local b = LC.bot
    local removedMacros, removedHandles = 0, 0
    if b and entry.macros then
        for i = 1, #entry.macros do
            local rec = entry.macros[i]
            for j = #b._macros, 1, -1 do
                if b._macros[j] == rec then
                    table.remove(b._macros, j)
                    removedMacros = removedMacros + 1
                end
            end
        end
    end
    if LC.events and entry.handles then
        for i = 1, #entry.handles do
            if busOff(LC.events, entry.handles[i]) ~= false then
                removedHandles = removedHandles + 1
            end
        end
    end
    reg.scripts[entry.name] = nil
    for i = #reg.order, 1, -1 do
        if reg.order[i] == entry.name then table.remove(reg.order, i) end
    end
    return removedMacros, removedHandles
end

local function scriptDir(LC)
    local b = LC.bot
    local dir = b and b.profileDir
    if not dir then return nil, 'the bot has no profile directory' end
    return dir .. '/panel_scripts'
end

-- ===========================================================================
-- the command table
-- ===========================================================================
local cmds = {}
M.commands = cmds

-- ---------------------------------------------------------------- status ----
local function botSnapshot(LC)
    local b = LC.bot
    if not b then return { on = false } end
    local ok, st = pcall(b.status, b)
    if not ok or type(st) ~= 'table' then return { on = false, error = tostring(st) } end
    local out = {
        on = st.on, profileDir = st.profileDir, vprofile = st.vprofile,
        macros = st.macros and #st.macros or 0,
        schedules = st.schedules,
        stats = st.stats,
    }
    local cb = st.cavebot
    if cb then
        out.cavebot = {
            on = cb.on, config = cb.config or cb.route or cb.routeName,
            waypointIndex = cb.waypointIndex or cb.index,
            waypointCount = cb.waypointCount,
            status = cb.currentAction or cb.status,
        }
    end
    local tb = st.targetbot
    if tb then
        out.targetbot = {
            on = tb.on, config = tb.config or tb.configName,
            target = tb.target and tb.target.name or nil,
            danger = tb.danger,
        }
    end
    out.healbot   = st.healbot   and { on = st.healbot.on } or nil
    out.attackbot = st.attackbot and { on = st.attackbot.on } or nil
    -- Supplies travel as TWO fields on purpose.  `supplies` is bot/supplies.lua's
    -- pure per-item ARRAY (itemId, name, count, threshold, ok) -- the shape
    -- hub/supervisor.lua's flattenLive forwards and panel/app.js draws.
    -- `suppliesStatus` is the context around it (profile, rounds, pouch pages,
    -- how many items are below their minimum).  Mixing the two in one table was
    -- what made every encoder on the way to the browser emit an object and the
    -- panel say "no supply data".
    local sup = st.supplies
    if type(sup) == 'table' then
        if type(sup.levels) == 'table' then out.supplies = sup.levels
        elseif sup[1] ~= nil then out.supplies = nil end   -- a pre-ledger worker: no rows
        -- Only the STRING keys: the status table still carries the rows in its array
        -- part for in-process readers, and copying those in here would recreate
        -- exactly the mixed-key table this split exists to avoid.
        local ctx = {}
        for k, v in pairs(sup) do
            if type(k) == 'string' and k ~= 'levels' then ctx[k] = v end
        end
        out.suppliesStatus = ctx
    end
    local reg = b._controlScripts
    if reg then
        local names = {}
        for i = 1, #reg.order do names[i] = reg.order[i] end
        out.scripts = names
    end
    return out
end
M.botSnapshot = botSnapshot

function M.statusSnapshot(ctx)
    local LC = ctx.LC
    local srv = ctx.server
    local st = LC.state
    local pl = st and st.player
    local t  = LC.transport
    local http = package.loaded['lib.http']
    local out = {
        instance   = srv and srv.instanceName or nil,
        pid        = sys.pid and sys.pid() or nil,
        uptimeMs   = srv and (sys.nowMs() - srv.startedMs) or nil,
        loginState = LC.loginState or (LC.inGame and 'online' or 'offline'),
        inGame     = LC.inGame and true or false,
        dryRun     = (LC.config and LC.config.dryRun) and true or false,
        character  = LC.characterName or (LC.config and LC.config.character) or nil,
        world      = LC.worldName or (LC.config and LC.config.world) or nil,
        host       = t and t.host or (LC.config and LC.config.host) or nil,
        port       = t and t.port or (LC.config and LC.config.port) or nil,
        ping       = st and st.ping or nil,
    }
    if http and http.getProxy then
        local p = http.getProxy()
        if p then
            out.proxy = { host = p.host, port = p.port, auth = p.hasAuth and true or false,
                          tunnelEstablished = t and t.proxyEstablished and true or false }
        end
    end
    if pl then
        out.player = {
            id = pl.id, name = pl.name,
            hp = pl.health, maxHp = pl.maxHealth,
            mana = pl.mana, maxMana = pl.maxMana,
            level = pl.level, levelPercent = pl.levelPercent, exp = pl.exp,
            soul = pl.soul, stamina = pl.stamina,
            cap = pl.freeCapacity or pl.capacity,
            pos = pl.pos, states = pl.states,
        }
    end
    if t then
        out.transport = { state = t.state, dead = t.dead and true or false,
                          bytesIn = t.stats.bytesIn, bytesOut = t.stats.bytesOut,
                          sent = t.stats.sent, recv = t.stats.recv, seq = t.stats.seq }
    end
    out.bot = botSnapshot(LC)
    if srv and srv.telemetry then
        local s = srv.telemetry:snapshot()
        out.stats = {
            expPerHour = s.expPerHour, moneyPerHour = s.moneyPerHour,
            lootPerHour = s.lootPerHour, wastePerHour = s.wastePerHour,
            balance = s.balance, kills = s.kills, deaths = s.deaths,
            level = s.level, sessionMs = s.sessionMs,
            -- The panel has to be able to say "prices not loaded" rather than draw a
            -- confident 0 gp/h, and the 1 Hz `status` push is what it has between
            -- `stats` pushes -- so the provenance travels with the number.
            moneySource = s.moneySource, pricesLoaded = s.pricesLoaded,
            pricesSource = s.pricesSource, noDataFor = s.noDataFor,
        }
    end
    return out
end

cmds['status'] = function(ctx) return M.statusSnapshot(ctx) end

-- ------------------------------------------------------------ session -------
cmds['login'] = function(ctx, args)
    local a = argTable(args)
    if not a then return nil, 'args must be an object' end
    local LC = ctx.LC
    if type(LC.login) ~= 'function' then
        return nil, 'this worker was built without a runtime login entry point'
    end
    return LC.login(a)
end

cmds['logout'] = function(ctx)
    local LC = ctx.LC
    if type(LC.logout) ~= 'function' then return nil, 'no runtime logout entry point' end
    return LC.logout()
end

cmds['relogin'] = function(ctx, args)
    local a = argTable(args) or {}
    local LC = ctx.LC
    if type(LC.relogin) ~= 'function' then return nil, 'no runtime relogin entry point' end
    return LC.relogin(tonumber(a.delayMs) or 1500)
end

-- ---------------------------------------------------------------- bot -------
cmds['bot.enable'] = function(ctx, args)
    local a = argTable(args)
    if not a then return nil, 'args must be an object' end
    local on = a.on
    if on == nil then return nil, 'bot.enable needs {on: true|false}' end
    on = (on == true) or (on == 'true') or (on == 1)
    local LC = ctx.LC
    if on then
        if LC.bot then return { on = true, changed = false } end
        LC.config = LC.config or {}
        LC.config.bot = true
        if type(LC.startBot) ~= 'function' then return nil, 'no startBot entry point' end
        LC.startBot()
        if not LC.bot then return nil, 'the bot layer failed to start (see the log)' end
        pushDebugEvent(ctx, 'module_enable', { module = 'bot' })
        return { on = true, changed = true }
    end
    if not LC.bot then return { on = false, changed = false } end
    if type(LC.stopBot) ~= 'function' then return nil, 'no stopBot entry point' end
    LC.stopBot()
    if LC.config then LC.config.bot = false end
    pushDebugEvent(ctx, 'module_disable', { module = 'bot' })
    return { on = false, changed = true }
end

--- One implementation for both config pickers: they differ only in the storage
--- directory key, the module name and how that module is told to re-read.
local function setConfig(ctx, which, name)
    local LC = ctx.LC
    local b = LC.bot
    if not b then return nil, 'the bot layer is not running' end
    if name ~= nil and type(name) ~= 'string' then return nil, 'name must be a string' end
    local dir = (which == 'cavebot') and 'cavebot_configs' or 'targetbot_configs'
    local mod = b.modules and b.modules[which]
    local off = (name == nil or name == '')

    if off then
        b:setConfigEnabled(dir, false)
        if mod then
            if which == 'cavebot' then pcall(mod.disable, mod) else pcall(mod.setOff, mod) end
        end
        if LC.config then LC.config[which] = nil end
        pushDebugEvent(ctx, 'module_disable', { module = which })
        return { config = '', on = false }
    end

    -- Refuse a name that is not on disk rather than silently loading an empty route.
    local prof = b.config
    local list = prof and ((which == 'cavebot') and prof:listCavebots() or prof:listTargetbots()) or {}
    local found = false
    for i = 1, #list do if list[i] == name then found = true end end
    if not found then
        return nil, ('%s/%s does not exist (bot.listConfigs shows what does)'):format(dir, name)
    end

    b:selectConfig(dir, name)
    b:setConfigEnabled(dir, true)
    if LC.config then LC.config[which] = name end
    if not mod then
        return { config = name, on = false,
                 note = 'selected and persisted; the module is not wired, so it takes effect on bot.reload' }
    end
    if which == 'cavebot' then
        local ok, err = pcall(mod.reload, mod, name)
        if not ok then return nil, 'cavebot reload failed: ' .. tostring(err) end
        pcall(mod.enable, mod)
        pushDebugEvent(ctx, 'config_reload', { module = which, config = name })
        return { config = name, on = mod.isOn and mod:isOn() or true }
    end
    local ok, err = pcall(mod.setCurrentProfile, mod, name)
    if not ok then return nil, 'targetbot reload failed: ' .. tostring(err) end
    pushDebugEvent(ctx, 'config_reload', { module = which, config = name })
    return { config = name, on = mod.isOn and mod:isOn() or true }
end

cmds['bot.setCavebot'] = function(ctx, args)
    local a = argTable(args); if not a then return nil, 'args must be an object' end
    return setConfig(ctx, 'cavebot', a.name)
end

cmds['bot.setTargetbot'] = function(ctx, args)
    local a = argTable(args); if not a then return nil, 'args must be an object' end
    return setConfig(ctx, 'targetbot', a.name)
end

cmds['bot.listConfigs'] = function(ctx)
    local LC = ctx.LC
    local b = LC.bot
    local prof = b and b.config
    if not prof then
        -- The bot is not running: read the profile directly so the panel can still
        -- populate its pickers before the worker is in the game.
        local okc, config = pcall(require, 'bot.config')
        if not okc then return nil, 'cannot load bot.config: ' .. tostring(config) end
        local dir = (LC.config and LC.config.botProfile) or LC.botProfileDir
        if not dir then return nil, 'no bot profile directory is known yet' end
        prof = config.new{ profileDir = dir, vprofile = (LC.config and LC.config.botVProfile) or 1 }
    end
    local out = {
        profileDir = prof.dir, vprofile = prof.vprofile,
        cavebot = prof:listCavebots(), targetbot = prof:listTargetbots(),
        profiles = {},
        macros = {},
        selected = { cavebot = '', targetbot = '' },
        enabled  = { cavebot = false, targetbot = false },
    }
    -- The bot PROFILES are the storage/profile_<n>.json files beside the configs.
    -- listDir is a directory read, not a file read, so this stays cheap.
    local okc, config = pcall(require, 'bot.config')
    if okc and prof.dir then
        local seen = {}
        for _, name in ipairs(config.listDir(prof.dir .. '/storage') or {}) do
            local n = name:match('^(profile_%d+)%.json$')
            if n and not seen[n] then seen[n] = true; out.profiles[#out.profiles + 1] = n end
        end
        table.sort(out.profiles)
    end
    if #out.profiles == 0 then out.profiles = { 'profile_' .. tostring(prof.vprofile or 1) } end
    if b then
        local c1, c2 = b:configState('cavebot_configs'), b:configState('targetbot_configs')
        out.selected.cavebot   = c1.selected or ''
        out.selected.targetbot = c2.selected or ''
        out.enabled.cavebot    = c1.enabled and true or false
        out.enabled.targetbot  = c2.enabled and true or false
        -- The panel's Bot tab draws one toggle per macro.  An UNNAMED macro has no
        -- switch a human can address, so it is not offered.
        for _, m in ipairs(b._macros or {}) do
            if type(m.name) == 'string' and #m.name > 0 then
                out.macros[#out.macros + 1] = { name = m.name, label = m.name,
                                                on = m.enabled and true or false,
                                                hotkey = (m.hotkey ~= '' and m.hotkey) or nil }
            end
        end
    end
    return out
end

--- bot.setMacro {name, on} -- flip one named macro.
--- vBot persists the switch in storage._macros[name], which is exactly what
--- m.setOn()/m.setOff() write, so the state survives a profile save.
cmds['bot.setMacro'] = function(ctx, args)
    local a = argTable(args)
    if not a then return nil, 'args must be an object' end
    local name = a.name
    if type(name) ~= 'string' or #name == 0 then return nil, 'bot.setMacro needs {name}' end
    if a.on == nil then return nil, 'bot.setMacro needs {on: true|false}' end
    local on = (a.on == true) or (a.on == 'true') or (a.on == 1)
    local b = ctx.LC.bot
    if not b then return nil, 'the bot is not running' end
    for _, m in ipairs(b._macros or {}) do
        if m.name == name then
            if on then m.setOn() else m.setOff() end
            pushDebugEvent(ctx, on and 'module_enable' or 'module_disable', { macro = name })
            return { macro = { name = name, label = name, on = m.enabled and true or false,
                               hotkey = (m.hotkey ~= '' and m.hotkey) or nil } }
        end
    end
    return nil, ('no macro named %q (bot.listConfigs shows the ones there are)'):format(name)
end

--- say {text, channel} -- speak in the game.
--- The panel's Chat tab needs this; without it the hub has to fall back to `exec`,
--- which audits as arbitrary code rather than as a chat message.
cmds['say'] = function(ctx, args)
    local a = argTable(args)
    if not a then return nil, 'args must be an object' end
    local text = a.text
    if type(text) ~= 'string' or not text:match('%S') then return nil, 'say needs {text}' end
    if #text > 255 then return nil, 'that message is longer than the protocol allows' end
    local LC = ctx.LC
    local b = LC.bot
    -- bot/api.lua's ctx.say is the vBot-compatible entry point: it picks the
    -- talk mode the server expects and goes through the same send path a macro
    -- would, so a channel message and a spell behave identically.
    if b and b.api and type(b.api.say) == 'function' then
        local ok, e = pcall(b.api.say, text)
        if not ok then return nil, tostring(e) end
        return { said = text, channel = a.channel }
    end
    local g = LC.game
    if g and type(g.talk) == 'function' then
        local ok, e = pcall(g.talk, g, text)
        if not ok then return nil, tostring(e) end
        return { said = text, channel = a.channel }
    end
    -- Last resort: the raw sender.  A worker started WITHOUT --bot has no bot.api
    -- and main.lua exposes no LC.game at all, so before this the panel's Chat tab
    -- could not speak in a perfectly healthy session -- `say` answered "there is no
    -- game session to speak in" while the character was standing in the world.
    -- proto/sender.lua:344 talk(mode, channelId, receiver, text) is the same packet
    -- bot/api.lua's ctx.say ends up sending for a non-spell message.
    local s = LC.sender
    if s and type(s.talk) == 'function' and LC.transport and not LC.transport.dead then
        -- proto/sender.lua's MODE: Say = 1, Channel = 7 (the only one of the two
        -- that puts a u16 channel id on the wire).
        local mode, channelId = 1, 0
        if type(a.channel) == 'number' then mode, channelId = 7, a.channel end
        local ok, e = pcall(s.talk, s, mode, channelId, '', text)
        if not ok then return nil, tostring(e) end
        if e == nil then return nil, 'the message was refused by the sender' end
        return { said = text, channel = a.channel }
    end
    return nil, 'there is no game session to speak in'
end

cmds['bot.reload'] = function(ctx)
    local LC = ctx.LC
    if type(LC.startBot) ~= 'function' or type(LC.stopBot) ~= 'function' then
        return nil, 'no bot lifecycle entry points'
    end
    local was = LC.bot and true or false
    if was then LC.stopBot() end
    LC.config = LC.config or {}
    LC.config.bot = true
    LC.startBot()
    if not LC.bot then return nil, 'the bot layer failed to restart (see the log)' end
    pushDebugEvent(ctx, 'config_reload', { scope = 'bot.reload' })
    return { on = true, wasRunning = was,
             note = 'scripts loaded through script.put are NOT restored by a reload' }
end

-- ============================================================== config.* ====
-- Work item N2 / CONFIGAPI.md.  Six kinds, one currently-ACTIVE config per
-- kind (the running module's own in-memory state -- never the filesystem
-- directly, so a change is visible to bot.status() and the next tick before
-- any file is even written).  bot/configschema.lua is the single source of
-- truth for field names/types/required-ness; hub/botconfig.lua (the stopped-
-- instance path) loads the SAME file so the two validations cannot drift.
--
-- Every kind's `data` shape is EXACTLY what bot/configschema.lua's `M.kinds`
-- table documents -- not the whole vBot profile object.  healbot/attackbot in
-- particular expose only the rule table(s) (itemTable/spellTable /
-- attackTable); the surrounding profile switches (Cooldown, Visible, Rotate,
-- PvpSafe, ...) are out of this contract's scope (CONFIGAPI.md's "shape"
-- column), so config.set never touches them.
local CONFIG_KINDS = {}
for _, k in ipairs(configschema.KIND_NAMES) do CONFIG_KINDS[k] = true end

local function requireBot(LC)
    local b = LC.bot
    if not b then return nil, 'the bot layer is not running (bot.enable {on:true} first)' end
    return b
end

local function isReadOnly(LC)
    return (LC.config and LC.config.dryRun) and true or false
end

-- ---- healbot -----------------------------------------------------------
local function getHealbot(b)
    local mod = b.modules and b.modules.healbot
    if not mod then return nil, 'the healbot module is not running' end
    local p = mod:profile()
    local source = cfglib.fileExists(b.config:healBotPath()) and 'profile' or 'default'
    return { itemTable = p.itemTable or {}, spellTable = p.spellTable or {} }, source
end

local function setHealbot(b, data, readOnly)
    local mod = b.modules and b.modules.healbot
    if not mod then return nil, 'the healbot module is not running' end
    local p = mod:profile()
    p.itemTable, p.spellTable = data.itemTable, data.spellTable
    mod:reload(mod.cfg)
    local persisted = false
    if not readOnly then
        local ok, err = mod:save()
        if not ok then return nil, 'failed to save HealBot.json: ' .. tostring(err) end
        persisted = true
    end
    return { kind = 'healbot', applied = true, persisted = persisted }
end

-- ---- conditions (bot/healbot.lua's ConditionPanel section) -------------
local function getConditions(b)
    local mod = b.modules and b.modules.healbot
    if not mod then return nil, 'the healbot module is not running' end
    local C = mod:conditions()
    local out = {}
    for k, v in pairs(C) do out[k] = v end
    -- CONFIGAPI.md: GET always presents the canonical `curePoison`, falling
    -- back to the misspelled on-disk key only when the canonical one is unset.
    if out.curePoison == nil then out.curePoison = out.curePosion end
    local source = cfglib.fileExists(b.config:healBotPath()) and 'profile' or 'default'
    return out, source
end

local function setConditions(b, data, readOnly)
    local mod = b.modules and b.modules.healbot
    if not mod then return nil, 'the healbot module is not running' end
    local old = mod:conditions() or {}
    local C = {}
    for k, v in pairs(data) do C[k] = v end
    -- Keep `curePosion` in sync ONLY when it was already present on disk, or
    -- the caller explicitly sent it -- never invent the key on a fresh file
    -- (CONFIGAPI.md: "keep curePosion unset unless it was already present").
    if old.curePosion ~= nil or data.curePosion ~= nil then
        C.curePosion = (data.curePosion ~= nil) and data.curePosion or data.curePoison
    else
        C.curePosion = nil
    end
    mod.cfg.ConditionPanel = C
    mod:reload(mod.cfg)
    local persisted = false
    if not readOnly then
        local ok, err = mod:save()
        if not ok then return nil, 'failed to save HealBot.json: ' .. tostring(err) end
        persisted = true
    end
    return { kind = 'conditions', applied = true, persisted = persisted }
end

-- ---- attackbot -----------------------------------------------------------
local function getAttackbot(b)
    local mod = b.modules and b.modules.attackbot
    if not mod then return nil, 'the attackbot module is not running' end
    local p = mod:profile()
    local source = cfglib.fileExists(b.config:attackBotPath()) and 'profile' or 'default'
    return p.attackTable or {}, source
end

local function setAttackbot(b, data, readOnly)
    local mod = b.modules and b.modules.attackbot
    if not mod then return nil, 'the attackbot module is not running' end
    local p = mod:profile()
    p.attackTable = data
    mod:reload(mod.cfg)
    local persisted = false
    if not readOnly then
        local ok, err = mod:save()
        if not ok then return nil, 'failed to save AttackBot.json: ' .. tostring(err) end
        persisted = true
    end
    return { kind = 'attackbot', applied = true, persisted = persisted }
end

-- ---- stances ---------------------------------------------------------------
-- bot/stances.lua is work item N1, being written concurrently (CONFIGAPI.md).
-- Its documented shape is storage.stances = {enabled, ignoreInPz, entries}, a
-- SHARED-STORAGE value (not a dedicated file), so persistence here always goes
-- through bot:saveStorage() rather than a module-owned save().  When the real
-- module is not wired yet (b.modules.stances absent, or its :reload signature
-- differs from every other module's `:reload(cfg)` convention) this falls
-- back to reading/writing bot.storage.stances directly, so config.get/set
-- work against CONFIGAPI.md's documented shape even before N1 lands --
-- see this work item's crossFileRequests.
local function stancesDefault() return { enabled = false, ignoreInPz = true, entries = {} } end

local function getStances(b)
    local mod = b.modules and b.modules.stances
    if mod and type(mod.cfg) == 'table' then
        return mod.cfg, 'profile'
    end
    local st = b.storage and b.storage.stances
    if type(st) ~= 'table' then return stancesDefault(), 'default' end
    return st, 'profile'
end

local function setStances(b, data, readOnly)
    b.storage = b.storage or {}
    local mod = b.modules and b.modules.stances
    if mod and type(mod.reload) == 'function' then
        local ok, err = pcall(mod.reload, mod, data)
        if not ok then return nil, 'stances reload failed: ' .. tostring(err) end
        b.storage.stances = (type(mod.cfg) == 'table') and mod.cfg or data
    else
        b.storage.stances = data
    end
    local persisted = false
    if not readOnly then
        local ok, err = pcall(b.saveStorage, b)
        if not ok then return nil, 'failed to save storage: ' .. tostring(err) end
        persisted = true
    end
    return { kind = 'stances', applied = true, persisted = persisted }
end

-- ---- targetbot -----------------------------------------------------------
local function getTargetbot(b)
    local mod = b.modules and b.modules.targetbot
    if not mod then return nil, 'the targetbot module is not running' end
    local raw = mod.raw or {}
    local targeting = type(raw.targeting) == 'table' and raw.targeting or {}
    local looting = mod.loot and mod.loot:save({}) or {}
    local source = (type(mod.configName) == 'string' and #mod.configName > 0) and 'profile' or 'default'
    return { targeting = targeting, looting = looting }, source
end

local function setTargetbot(b, data, readOnly)
    local mod = b.modules and b.modules.targetbot
    if not mod then return nil, 'the targetbot module is not running' end
    local name = mod.configName
    if type(name) ~= 'string' or name == '' then
        return nil, 'no targetbot config is selected (bot.setTargetbot first)'
    end
    mod:reload{ targeting = data.targeting, looting = data.looting or {} }
    local persisted = false
    if not readOnly then
        local ok, err = mod:save()
        if not ok then
            return nil, ('failed to save targetbot_configs/%s: %s'):format(name, tostring(err))
        end
        persisted = true
    end
    return { kind = 'targetbot', applied = true, persisted = persisted }
end

-- ---- cavebot ---------------------------------------------------------------
-- The one kind with the exec-capability gate (CONFIGAPI.md "Security").  This
-- module never checks WHO is allowed to write a function body -- that lives in
-- hub/api.lua's EXEC_CAPABILITY check -- it only reports HONESTLY whether the
-- diff adds/changes one, via `needsExec`, so the hub can decide before (not
-- after) anything is written.  `args.execCapability == true` is the hub's own
-- assertion that it already ran that check; commands.lua trusts it exactly as
-- far as it trusts the hub for every other privileged command.
local function getCavebot(b)
    local mod = b.modules and b.modules.cavebot
    if not mod then return nil, 'the cavebot module is not running' end
    local route = mod.route or {}
    local pairs_ = (type(route.pairs) == 'table') and route.pairs
                   or configschema.cavebotPairsFromRoute(route)
    local out = {}
    for i = 1, #pairs_ do
        local p = pairs_[i]
        out[i] = { type = configschema.cavebotPairType(p), value = configschema.cavebotPairValue(p) }
    end
    local source = (type(route.path) == 'string') and 'profile' or 'default'
    return out, source
end

local function setCavebot(b, data, execCapability, readOnly)
    local mod = b.modules and b.modules.cavebot
    if not mod then return nil, 'the cavebot module is not running' end
    local selected = b:configState('cavebot_configs').selected
    if type(selected) ~= 'string' or selected == '' then
        return nil, 'no cavebot config is selected (bot.setCavebot first)'
    end

    -- Normalise to the positional {type, value} shape encodeCfg/decodeCfg (and
    -- our own diff/route helpers) expect.
    local newPairs = {}
    for i = 1, #data do
        newPairs[i] = { configschema.cavebotPairType(data[i]), configschema.cavebotPairValue(data[i]) }
    end

    local oldRoute = mod.route or {}
    local oldPairs = (type(oldRoute.pairs) == 'table') and oldRoute.pairs
                     or configschema.cavebotPairsFromRoute(oldRoute)

    local changed = configschema.cavebotFunctionBodyChanged(oldPairs, newPairs)
    if changed and execCapability ~= true then
        return { kind = 'cavebot', applied = false, needsExec = true,
                 reason = 'this change adds or changes a function-type waypoint body; ' ..
                          'the exec capability is required' }
    end

    local persisted = false
    if not readOnly then
        local ok, err = b.config:saveCavebot(selected, { pairs = newPairs })
        if not ok then
            return nil, ('failed to save cavebot_configs/%s: %s'):format(selected, tostring(err))
        end
        persisted = true
    end

    -- Re-read from disk when we actually wrote it (keeps mod.route.pairs/.path
    -- byte-identical to the file for the next GET); apply in-memory only under
    -- --dry-run, so the change still hot-applies without touching the profile.
    if persisted then
        mod:reload(selected)
    else
        local route = configschema.cavebotRouteFromPairs(newPairs)
        route.name, route.pairs = selected, newPairs
        mod:reload(route)
    end

    return { kind = 'cavebot', applied = true, needsExec = false,
             persisted = persisted, functionBodyChanged = changed }
end

-- ---- dispatch ------------------------------------------------------------
local CONFIG_GET = { healbot = getHealbot, conditions = getConditions, attackbot = getAttackbot,
                     stances = getStances, targetbot = getTargetbot, cavebot = getCavebot }

cmds['config.get'] = function(ctx, args)
    local a = argTable(args); if not a then return nil, 'args must be an object' end
    local kind = a.kind
    if not CONFIG_KINDS[kind] then return nil, ('unknown config kind %q'):format(tostring(kind)) end
    local b, berr = requireBot(ctx.LC)
    if not b then return nil, berr end
    local data, source = CONFIG_GET[kind](b)
    if data == nil then return nil, source end   -- source carries the error message here
    return { kind = kind, data = data, source = source or 'profile' }
end

cmds['config.list'] = function(ctx, args)
    local a = argTable(args); if not a then return nil, 'args must be an object' end
    local kind = a.kind
    if not CONFIG_KINDS[kind] then return nil, ('unknown config kind %q'):format(tostring(kind)) end
    local b, berr = requireBot(ctx.LC)
    if not b then return nil, berr end

    if kind == 'healbot' or kind == 'attackbot' then
        local mod = b.modules and b.modules[kind]
        if not mod then return nil, ('the %s module is not running'):format(kind) end
        return { names = { 1, 2, 3, 4, 5 }, active = mod:getActiveProfile() }
    end
    if kind == 'cavebot' or kind == 'targetbot' then
        local dir = (kind == 'cavebot') and 'cavebot_configs' or 'targetbot_configs'
        local prof = b.config
        local names = prof and ((kind == 'cavebot') and prof:listCavebots() or prof:listTargetbots()) or {}
        local st = b:configState(dir)
        return { names = names, active = st.selected or '' }
    end
    -- conditions / stances: a single object, no named sub-profiles.
    return { names = {}, active = nil }
end

cmds['config.set'] = function(ctx, args)
    local a = argTable(args); if not a then return nil, 'args must be an object' end
    local kind = a.kind
    if not CONFIG_KINDS[kind] then return nil, ('unknown config kind %q'):format(tostring(kind)) end
    local LC = ctx.LC
    local b, berr = requireBot(LC)
    if not b then return nil, berr end

    -- Validate BEFORE touching anything: "reject, don't coerce" (CONFIGAPI.md)
    -- means a bad payload must leave the running module and the file untouched.
    local vok, verr = configschema.validate(kind, a.data)
    if not vok then return nil, verr end

    local readOnly = isReadOnly(LC)
    local res, err
    if kind == 'healbot' then       res, err = setHealbot(b, a.data, readOnly)
    elseif kind == 'conditions' then res, err = setConditions(b, a.data, readOnly)
    elseif kind == 'attackbot' then  res, err = setAttackbot(b, a.data, readOnly)
    elseif kind == 'stances' then    res, err = setStances(b, a.data, readOnly)
    elseif kind == 'targetbot' then  res, err = setTargetbot(b, a.data, readOnly)
    elseif kind == 'cavebot' then    res, err = setCavebot(b, a.data, a.execCapability == true, readOnly)
    end
    if not res then return nil, err or 'config.set failed' end
    if res.applied then pushDebugEvent(ctx, 'config_reload', { kind = kind }) end
    return res
end

-- ------------------------------------------------------------- scripts ------
local function compile(source, chunkName)
    if type(source) ~= 'string' then return nil, 'source must be a string' end
    -- A leading '#' would be read as a shebang by loadstring's text loader; and a
    -- pre-compiled bytecode blob must never be accepted from the wire.
    if source:sub(1, 1) == '\27' then return nil, 'pre-compiled bytecode is not accepted' end
    local chunk, err = loadstring(source, chunkName)
    if not chunk then return nil, tostring(err) end
    return chunk
end

cmds['script.put'] = function(ctx, args)
    local a = argTable(args); if not a then return nil, 'args must be an object' end
    local LC = ctx.LC
    local name, nerr = M.normaliseScriptName(a.name)
    if not name then return nil, nerr end
    local source = a.source
    if type(source) ~= 'string' then return nil, 'source must be a string' end

    local env, reg = envFor(LC)
    if not env then return nil, reg end

    -- 1. compile FIRST: a syntax error must be reported, never written and never thrown.
    local chunk, cerr = compile(source, '@panel:' .. name .. '.lua')
    if not chunk then return nil, 'compile error: ' .. tostring(cerr) end

    -- 2. replacing a script means taking the old one out before the new one runs,
    --    or a re-upload doubles every macro it registers.
    local prev = reg.scripts[name]
    local removedMacros, removedHandles = 0, 0
    if prev then removedMacros, removedHandles = unloadEntry(LC, reg, prev) end

    -- 3. write it into the running bot profile (PANEL.md: "writes the file into the
    --    running bot profile").  A --dry-run worker runs with readOnlyProfile, so the
    --    write is skipped there rather than touching the user's real vBot tree.
    local wrote, writeErr = false, nil
    local readOnly = (LC.config and LC.config.dryRun) and true or false
    local dir = scriptDir(LC)
    if dir and not readOnly then
        local okc, config = pcall(require, 'bot.config')
        if okc then
            config.mkdirp(dir)
            local ok, e = config.writeFileAtomic(dir .. '/' .. name .. '.lua', source)
            wrote = ok and true or false
            if not ok then writeErr = tostring(e) end
        else
            writeErr = tostring(config)
        end
    end

    -- 4. load it into the shared environment, with the registry pointed at this entry
    --    so its macros and event handlers can be taken back out later.
    local entry = { name = name, macros = {}, handles = {}, bytes = #source,
                    loadedAt = sys.nowMs(), path = dir and (dir .. '/' .. name .. '.lua') or nil }
    setfenv(chunk, env)
    reg.current = entry
    local ok, res = pcall(chunk)
    reg.current = nil
    if not ok then
        -- It half-ran: take back whatever it managed to register, then report.
        unloadEntry(LC, reg, entry)
        return nil, 'runtime error: ' .. tostring(res)
    end

    reg.scripts[name] = entry
    reg.order[#reg.order + 1] = name
    return { name = name, bytes = #source, wrote = wrote, writeError = writeErr,
             path = entry.path, macros = #entry.macros, handlers = #entry.handles,
             replaced = prev and true or false,
             removedMacros = removedMacros, removedHandlers = removedHandles,
             returned = (type(res) == 'number' or type(res) == 'string'
                         or type(res) == 'boolean') and res or nil }
end

cmds['script.remove'] = function(ctx, args)
    local a = argTable(args); if not a then return nil, 'args must be an object' end
    local LC = ctx.LC
    local name, nerr = M.normaliseScriptName(a.name)
    if not name then return nil, nerr end
    local b = LC.bot
    local reg = b and b._controlScripts
    if not reg or not reg.scripts[name] then
        return nil, ('no script named %q is loaded'):format(name)
    end
    local entry = reg.scripts[name]
    local macros, handles = unloadEntry(LC, reg, entry)
    local deleted = false
    if entry.path and a.keepFile ~= true then
        deleted = os.remove(entry.path) and true or false
    end
    return { name = name, removedMacros = macros, removedHandlers = handles,
             deletedFile = deleted,
             note = 'timers created with schedule() and globals the script set are not undone' }
end

cmds['script.list'] = function(ctx)
    local b = ctx.LC.bot
    local reg = b and b._controlScripts
    local out = { scripts = {} }
    if not reg then return out end
    for i = 1, #reg.order do
        local e = reg.scripts[reg.order[i]]
        if e then
            out.scripts[#out.scripts + 1] = {
                name = e.name, bytes = e.bytes, loadedAt = e.loadedAt,
                macros = #e.macros, handlers = #e.handles, path = e.path,
            }
        end
    end
    return out
end

-- ---------------------------------------------------------------- exec ------
cmds['exec'] = function(ctx, args)
    local a = argTable(args); if not a then return nil, 'args must be an object' end
    local code, cerr = optString(a, 'code')
    if code == nil then return nil, cerr or 'exec needs {code: "..."}' end
    local env, reg = envFor(ctx.LC)
    if not env then return nil, reg end

    -- Accept both an expression and a statement block, the way a REPL does.
    local chunk = compile('return (' .. code .. '\n)', '@panel:exec')
    if not chunk then
        local c2, e2 = compile(code, '@panel:exec')
        if not c2 then return nil, 'compile error: ' .. tostring(e2) end
        chunk = c2
    end
    setfenv(chunk, env)
    local t0 = sys.nowMs()
    local ok, res = pcall(chunk)
    if not ok then return nil, 'runtime error: ' .. tostring(res) end
    local out = { ms = sys.nowMs() - t0, type = type(res) }
    if res == nil then out.value = nil
    elseif type(res) == 'table' then out.value = res       -- JSON-encoded by the caller
    elseif type(res) == 'function' or type(res) == 'userdata' or type(res) == 'thread' then
        out.value = tostring(res)
    else out.value = res end
    return out
end

-- --------------------------------------------------------------- stats ------
cmds['stats'] = function(ctx)
    local srv = ctx.server
    if not srv or not srv.telemetry then return nil, 'no telemetry engine' end
    return srv.telemetry:snapshot(true)
end

-- ============================================================================
-- debug.snapshot -- work item R2: structured diagnostics for the panel's own
-- Debug tab (work item R3, already built -- panel/app.js's TabDebug), a
-- separate stream from the plain text log stream and the chat feed on the
-- Console tab (see panel/app.js's Console view, read but not touched here).
-- ============================================================================
-- OWNERSHIP NOTE.  This file owns control/*.lua only -- not a single bot/*.lua
-- or proto/*.lua line changed for this feature.  Every number below is REAL,
-- pulled from the running bot/transport by instrumenting them FROM OUTSIDE:
-- a handful of instance-level function wraps (never a source edit) that call
-- straight through to the original behaviour and additionally record a
-- timestamp or bump a counter.  Two techniques, used throughout:
--   * `wrapOnce` reads `obj[method]` -- which resolves through the object's
--     OWN metatable, so this needs no cooperating export from bot/path.lua,
--     bot/init.lua or proto/transport.lua -- and replaces it on the INSTANCE,
--     which every real call site reaches because they all call
--     `obj:method(...)`, resolved fresh at call time (Lua does not cache
--     method lookups across calls).  Idempotent via a marker field, so a
--     bot.reload's fresh bot/path/walker objects each get wrapped exactly
--     once and a repeated debug.snapshot never double-wraps.
--   * a handful of existing command handlers (bot.enable, bot.setCavebot/
--     setTargetbot, bot.setMacro, bot.reload, config.set) push one
--     structured event each, at the exact moment they already act -- no
--     polling needed for those, since this file IS where they happen.
-- Fields no amount of outside instrumentation can honestly produce today are
-- listed in this work item's crossFileRequests rather than being invented
-- here: see that list before assuming a field is a placeholder.
--
-- EVENT KINDS.  panel/app.js's DEBUG_EVENT_LABEL already special-cases seven:
-- `resync`, `reconnect`, `macro_error`, `slow_tick`, `stuck`, `path_blocked`,
-- `info` (anything else still renders -- eventKindLabel() falls back to the
-- raw kind with underscores turned to spaces -- just without a curated label).
-- Every one of the seven is emitted below except `info`, which this file never
-- had a reason to raise on its own: resync/walk_cancel/macro_error/slow_tick/
-- stuck/path_blocked/reconnect/config_reload/module_enable/module_disable.
-- The last three are outside panel/app.js's curated set but follow the same
-- snake_case convention and still render via the fallback.
local SLOW_TICK_FLOOR_MS = 30        -- a 10ms-tick bot should not warn on 31ms alone
local STUCK_THRESHOLD_MS = 8000      -- panel/app.js's DEBUG_EVENT_LABEL 'stuck'
local TICK_DURATIONS_MAX = 30        -- panel/app.js's tick sparkline sample count

--- A human-usable label for a macro record.  Most of BOT.md's macro table is
--- UNNAMED (only CaveBot's two macros carry a name) -- healbot alone
--- registers four -- so falling back to the call site bot/init.lua's own
--- `macro()` already captures (`m.site`, e.g. "bot/healbot.lua:123") is what
--- makes the debug console's macro list identify which module owns which
--- row, without bot/init.lua adding a name field.
local function macroLabel(m)
    if type(m.name) == 'string' and #m.name > 0 then return m.name end
    if type(m.site) == 'string' and #m.site > 0 then return m.site end
    return '?'
end

--- Wrap `obj[method]` exactly once.  `wrap(orig)` receives the CURRENT
--- function (read through the metatable, so nothing needs to export it) and
--- returns the replacement; the replacement decides how to call `orig`
--- (method-style vs a plain callback -- both shapes are used below).
local function wrapOnce(obj, method, markerField, wrap)
    if not obj or obj[markerField] then return end
    local orig = obj[method]
    if type(orig) ~= 'function' then return end
    obj[method] = wrap(orig)
    obj[markerField] = true
end

--- Per-bot-instance recorder: tick timing, per-path-search timing, and the
--- diff trackers the events below need (cavebot waypoint stall, walker
--- resync/cancel counts).  Cached on the bot instance itself, so a
--- bot.reload's brand new bot object starts with a clean recorder -- exactly
--- right, since its tick/macro history legitimately restarts too.
local function botRecorder(ctx)
    local b = ctx.LC and ctx.LC.bot
    if not b then return nil end
    if b._debugRec then return b._debugRec end

    local rec = {
        tick = { lastTickMs = nil, lastTickDurationMs = nil, avgTickDurationMs = nil,
                 slowTicks = 0, slowThresholdMs = math.max(SLOW_TICK_FLOOR_MS, (b.tickMs or 10) * 3),
                 durations = {} },
        path = { lastFindMs = nil, lastFindDurationMs = nil, lastFindResult = nil,
                 lastFindTileCount = nil },
        cavebot = { lastIndex = nil, lastAdvanceMs = nil },
        walker  = { lastResyncSeenAt = nil, lastCancels = 0 },
    }
    b._debugRec = rec

    -- tick timing: wraps bot/init.lua's Bot:tick, called every `tickMs` from
    -- main.lua's `b.sched.every(b.tickMs, function() b:tick() end)`.
    wrapOnce(b, 'tick', '_debugTickWrapped', function(orig)
        return function(self, ...)
            local t0 = sys.nowMs()
            local ok, err = pcall(orig, self, ...)
            local dt = sys.nowMs() - t0
            rec.tick.lastTickMs = self.now or sys.nowMs()
            rec.tick.lastTickDurationMs = dt
            rec.tick.avgTickDurationMs = rec.tick.avgTickDurationMs
                and (rec.tick.avgTickDurationMs * 0.9 + dt * 0.1) or dt
            local durs = rec.tick.durations
            durs[#durs + 1] = dt
            while #durs > TICK_DURATIONS_MAX do table.remove(durs, 1) end
            if dt > rec.tick.slowThresholdMs then
                rec.tick.slowTicks = rec.tick.slowTicks + 1
                pushDebugEvent(ctx, 'slow_tick', { ms = dt, thresholdMs = rec.tick.slowThresholdMs })
            end
            if not ok then error(err, 0) end
        end
    end)

    -- per-macro timing/errors: wraps bot/init.lua's Bot:_invoke, the ONE
    -- place every macro (and hotkey command) actually runs
    -- (`pcall(self._invoke, self, m, m.fn)`).  A hotkey command's record has
    -- no `.timeout` field (bot/init.lua's Bot:command), which is what tells
    -- the two apart without needing either to say so itself.
    wrapOnce(b, '_invoke', '_debugInvokeWrapped', function(orig)
        return function(self, record, fn, ...)
            local t0 = sys.nowMs()
            local ok, res = pcall(orig, self, record, fn, ...)
            if ok and res == false then
                -- record.delay held it (b:delay() from a previous run): nothing ran
                -- this tick, so the LAST real duration/error stays exactly as it was.
            elseif ok then
                record._dbgLastDurationMs = sys.nowMs() - t0
                record._dbgLastError = nil
            else
                record._dbgLastDurationMs = sys.nowMs() - t0
                record._dbgLastError = tostring(res)
                if record.timeout ~= nil then
                    pushDebugEvent(ctx, 'macro_error',
                                   { name = macroLabel(record), error = tostring(res) })
                end
            end
            if not ok then error(res, 0) end
            return res
        end
    end)

    -- path search timing/result: wraps bot/path.lua's P:getPath, the ONE
    -- entry point bot/walker.lua, bot/cavebot.lua and bot/targetbot.lua all
    -- call (`self.path:getPath(...)`) against the ONE shared pathfinder
    -- BOT.md's "As built" #3 documents.
    if b.path then
        wrapOnce(b.path, 'getPath', '_debugGetPathWrapped', function(orig)
            return function(self, ...)
                local t0 = sys.nowMs()
                local dirs, why, F = orig(self, ...)
                rec.path.lastFindMs = sys.nowMs()
                rec.path.lastFindDurationMs = rec.path.lastFindMs - t0
                rec.path.lastFindTileCount = F and (F.complexity or F.classified) or nil
                if dirs ~= nil then rec.path.lastFindResult = 'ok'
                elseif why == 'max-complexity' then rec.path.lastFindResult = 'timeout'
                else rec.path.lastFindResult = 'nopath' end
                -- edge-triggered: a route that keeps failing every tick reports
                -- ONE `path_blocked` event per failure episode, not one per tick.
                if rec.path.lastFindResult == 'nopath' and rec.path.lastReportedResult ~= 'nopath' then
                    pushDebugEvent(ctx, 'path_blocked', { why = why })
                end
                rec.path.lastReportedResult = rec.path.lastFindResult
                return dirs, why, F
            end
        end)
    end

    return rec
end

--- Per-transport recorder.  A relogin builds a BRAND NEW transport object
--- (main.lua's openSession), so this is keyed off `LC` (which outlives every
--- transport) and re-wraps whenever the transport identity changes -- which
--- is also how a real "how many times has this worker reconnected" count
--- falls out, without control/server.lua's own header comment ("reconnects:
--- the hub's supervisor bookkeeping, not the worker's") having to change:
--- this is a genuinely different, complementary count, kept honest by
--- calling it what it is below.
local function netRecorder(ctx)
    local LC = ctx.LC
    local t = LC and LC.transport
    if not t then return nil end
    local net = LC._debugNet
    if not net then net = { connects = 0, lastTransport = nil, lastRecvMs = nil }; LC._debugNet = net end
    if net.lastTransport ~= t then
        net.lastTransport = t
        net.connects = net.connects + 1
        if net.connects > 1 then
            pushDebugEvent(ctx, 'reconnect', { connects = net.connects })
        end
        wrapOnce(t, 'onMessage', '_debugOnMessageWrapped', function(orig)
            return function(payload)
                net.lastRecvMs = sys.nowMs()
                return orig(payload)
            end
        end)
    end
    return net
end

local function tickDebug(b, rec)
    local macros = {}
    if b then
        for i, m in ipairs(b._macros or {}) do
            macros[i] = {
                name = macroLabel(m), enabled = m.enabled and true or false,
                lastRanMs = m.lastExecution, lastDurationMs = m._dbgLastDurationMs,
                errorCount = m.errors or 0, lastError = m._dbgLastError,
            }
        end
    end
    return {
        intervalMs = b and b.tickMs or nil,
        lastTickMs = (rec and rec.tick.lastTickMs) or (b and b.now) or nil,
        lastTickDurationMs = rec and rec.tick.lastTickDurationMs or nil,
        avgTickDurationMs  = rec and rec.tick.avgTickDurationMs or nil,
        slowTicks  = rec and rec.tick.slowTicks or 0,
        slowThresholdMs = rec and rec.tick.slowThresholdMs or nil,
        durationsMs = rec and rec.tick.durations or {},
        macroCount = b and #(b._macros or {}) or 0,
        macros     = macros,
    }
end

local function networkDebug(ctx)
    local LC = ctx.LC
    local t, st = LC.transport, LC.state
    local net = netRecorder(ctx)
    return {
        connected = (t and t.state == 'connected' and not t.dead) and true or false,
        ping = st and st.ping or nil,
        lastPacketAgeMs = (net and net.lastRecvMs) and (sys.nowMs() - net.lastRecvMs) or nil,
        packetsIn  = (t and t.stats and t.stats.recv) or 0,
        packetsOut = (t and t.stats and t.stats.sent) or 0,
        bytesIn    = (t and t.stats and t.stats.bytesIn) or 0,
        bytesOut   = (t and t.stats and t.stats.bytesOut) or 0,
        -- how many DISTINCT transport objects this worker has connected through
        -- (main.lua builds a fresh one per login/relogin): 0 until the first
        -- connect, then one less than the transports seen so far.
        reconnects = net and math.max(0, net.connects - 1) or 0,
        lastDesyncOrError = t and t.lastError or nil,
    }
end

local function botModulesDebug(ctx, rec)
    local b = ctx.LC.bot
    local out = {}
    if not b then return out end
    local now = sys.nowMs()

    local cb = b.modules and b.modules.cavebot
    if cb then
        local ok, cst = pcall(cb.status, cb)
        if ok then
            local idx = cst.waypointIndex
            local stuckSince = nil
            if rec then
                if rec.cavebot.lastIndex == nil or rec.cavebot.lastIndex ~= idx then
                    rec.cavebot.lastIndex, rec.cavebot.lastAdvanceMs = idx, now
                    rec.cavebot.reportedStuck = false
                end
                stuckSince = rec.cavebot.lastAdvanceMs and (now - rec.cavebot.lastAdvanceMs) or nil
                if stuckSince and stuckSince >= STUCK_THRESHOLD_MS and not rec.cavebot.reportedStuck then
                    rec.cavebot.reportedStuck = true
                    pushDebugEvent(ctx, 'stuck', { waypointIndex = idx, stuckForMs = stuckSince })
                end
            end
            out.cavebot = {
                on = cst.on, config = cst.config,
                waypointIndex = idx, waypointCount = cst.waypointCount,
                currentAction = cst.currentAction, lastActionResult = cst.status,
                stuckSince = stuckSince, stuckThresholdMs = STUCK_THRESHOLD_MS,
            }
        end
    end

    local tb = b.modules and b.modules.targetbot
    if tb then
        local ok, tst = pcall(tb.status, tb)
        if ok then
            local reason = nil
            local lp = tb.lastParams
            if lp and lp.config then
                reason = ('matched %q (priority=%s danger=%s)'):format(
                    tostring(lp.config.name or lp.config.creature or '?'),
                    tostring(lp.priority), tostring(lp.danger))
            end
            out.targetbot = {
                on = tst.on, config = tst.config, target = tst.target,
                candidateCount = tb.targets or 0,
                lastSelectionReason = reason,
                looting = { state = tst.looting and tst.looting.status,
                            queueLength = tst.looting and tst.looting.queued },
            }
        end
    end

    local hb = b.modules and b.modules.healbot
    if hb then
        local la = hb.lastAction
        out.healbot = {
            on = hb:isOn(),
            lastRuleFired = la and (tostring(la.kind) .. ':' .. tostring(la.what)) or nil,
            lastCastMs = la and la.at or nil,
        }
    end

    local ab = b.modules and b.modules.attackbot
    if ab then
        local ls = ab.lastSpell
        out.attackbot = {
            on = ab:isOn(), lastSpell = ls and (ls.spell or ls.rune) or nil,
            lastFiredMs = ls and ls.at or nil,
        }
    end

    local stm = b.modules and b.modules.stances
    if stm then
        local ok, sst = pcall(stm.status, stm)
        if ok then
            out.stances = { on = sst.on, activeStanceIds = sst.active or {}, lastCastMs = sst.lastCastAt }
        end
    end

    -- resync / walk-cancel events: diffed off the ONE shared walker every time
    -- a snapshot is built (the periodic control/server.lua push, or an
    -- on-demand `debug.snapshot`) -- no separate poller needed.
    local wk = b.walker
    if wk and rec then
        local lr = wk.lastResync
        if lr and lr.at and rec.walker.lastResyncSeenAt ~= lr.at then
            rec.walker.lastResyncSeenAt = lr.at
            pushDebugEvent(ctx, 'resync', { why = lr.why, pos = lr.pos })
        end
        local cancels = (wk.stats and wk.stats.cancels) or 0
        if cancels > rec.walker.lastCancels then
            pushDebugEvent(ctx, 'walk_cancel', { cancels = cancels })
            rec.walker.lastCancels = cancels
        end
    end

    return out
end

local function pathDebug(rec)
    if not rec then return {} end
    return { lastFindMs = rec.path.lastFindMs, lastFindDurationMs = rec.path.lastFindDurationMs,
             lastFindResult = rec.path.lastFindResult, lastFindTileCount = rec.path.lastFindTileCount }
end

function M.debugSnapshot(ctx)
    local rec = botRecorder(ctx)
    local srv = ctx.server
    return {
        tMs     = sys.nowMs(),
        tick    = tickDebug(ctx.LC.bot, rec),
        network = networkDebug(ctx),
        bot     = botModulesDebug(ctx, rec),
        path    = pathDebug(rec),
        events  = (srv and srv._debugEvents) or {},
    }
end

cmds['debug.snapshot'] = function(ctx) return M.debugSnapshot(ctx) end

-- ------------------------------------------------------------ shutdown ------
cmds['shutdown'] = function(ctx, args)
    local a = argTable(args) or {}
    local code = tonumber(a.code) or 0
    local LC = ctx.LC
    local sched = LC.sched
    -- Reply first: the caller must see {ok:true} before the process goes away.
    if sched and sched.after then
        sched.after(tonumber(a.delayMs) or 50, function()
            if type(LC.shutdown) == 'function' then LC.shutdown(code) else os.exit(code) end
        end)
    elseif type(LC.shutdown) == 'function' then
        LC.shutdown(code)
    end
    return { shuttingDown = true, code = code }
end

-- ===========================================================================
-- dispatch
-- ===========================================================================
function M.names()
    local out = {}
    for k in pairs(cmds) do out[#out + 1] = k end
    table.sort(out)
    return out
end

--- dispatch(ctx, cmd, args) -> true, result | false, errorString
---
--- Never raises: an unknown command, a handler that returns nil,err and a handler that
--- throws all come out as (false, message).  That is what keeps one bad panel click
--- from taking the worker down with it.
function M.dispatch(ctx, cmd, args)
    if type(cmd) ~= 'string' or cmd == '' then
        return false, 'cmd must be a non-empty string'
    end
    local fn = cmds[cmd]
    if not fn then
        return false, ('unknown command %q (known: %s)'):format(cmd,
                       table.concat(M.names(), ', '))
    end
    local ok, res, err = pcall(fn, ctx, args)
    if not ok then return false, tostring(res) end
    if res == nil then
        if err ~= nil then return false, tostring(err) end
        return true, true
    end
    return true, res
end

return M
