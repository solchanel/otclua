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
    script.put {name, source}   write + load a script into the bot environment
    script.remove {name}        unload it and delete the file
    script.list                 loaded scripts, with sizes and load times
    exec {code}                 run one chunk in the same environment
    stats                       the lib/stats.lua snapshot
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

local sys = require('lib.sys')

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
    out.supplies  = st.supplies
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
        return { on = true, changed = true }
    end
    if not LC.bot then return { on = false, changed = false } end
    if type(LC.stopBot) ~= 'function' then return nil, 'no stopBot entry point' end
    LC.stopBot()
    if LC.config then LC.config.bot = false end
    return { on = false, changed = true }
end

--- One implementation for both config pickers: they differ only in the storage
--- directory key, the module name and how that module is told to re-read.
local function setConfig(LC, which, name)
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
        return { config = name, on = mod.isOn and mod:isOn() or true }
    end
    local ok, err = pcall(mod.setCurrentProfile, mod, name)
    if not ok then return nil, 'targetbot reload failed: ' .. tostring(err) end
    return { config = name, on = mod.isOn and mod:isOn() or true }
end

cmds['bot.setCavebot'] = function(ctx, args)
    local a = argTable(args); if not a then return nil, 'args must be an object' end
    return setConfig(ctx.LC, 'cavebot', a.name)
end

cmds['bot.setTargetbot'] = function(ctx, args)
    local a = argTable(args); if not a then return nil, 'args must be an object' end
    return setConfig(ctx.LC, 'targetbot', a.name)
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
    return { on = true, wasRunning = was,
             note = 'scripts loaded through script.put are NOT restored by a reload' }
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
