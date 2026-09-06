--[[============================================================================
shim/host.lua -- the vBot runtime host  (work item S4, PLAN.md sec.1.27).

Replaces `mods/game_bot/bot.lua` (the CLIENT-SIDE half: the window, the config
manager, the callback wiring, the 10 ms `check()` loop).  It does NOT replace
`mods/game_bot/executor.lua`, `functions/*.lua` or `panels/*.lua` -- those are
loaded VERBATIM from the user's own otclient tree, because they *are* the
vBot-facing API and reimplementing them is exactly how drift gets introduced
(PLAN sec.3.4).

What it runs, in order (PLAN sec.4.1 steps 11-13):

  1. otRoot/mods/game_bot/executor.lua       -> defines executeBot()
  2. executeBot(config, storage, tabs, msg, save, reload, websockets)
       a. dofiles("functions")               -> 19 files, sorted
       b. dofiles("panels")                  ->  7 files, sorted
       c. g_ui.importStyle for each top-level .otui   (there are none)
       d. load('/bot/<config>/_Loader.lua', ..., context)()
            -> chains all 74 profile files in _Loader.lua's fixed order
  3. res.script() every tickMs, with g_clock frame-quantised first (I5)

Everything under D:/Claude/otclient_mehah1530 is READ-ONLY.  With
`opts.readOnly` (the default) every g_resources write/delete is intercepted,
recorded and refused, so a bot script that calls CaveBot.save() cannot touch the
user's live profile.

Per-file verdicts come from wrapping the GLOBAL `load`: executor.lua compiles
every bot chunk with `load(src, chunkname, nil, context)` and its own
`context.dofile` goes through the same call, so one wrapper records enter/exit
for all 74 files including _Loader.lua's nesting.  That table -- files loaded,
macros registered, ticks run, and the FIRST error per failing file -- is the
deliverable of test/shim_host_suite.lua.

    local host = require('shim.host')
    local h = host.new{ G = G, LC = LC, resources = g_resources,
                        otRoot = '.../otclient', config = 'vBot_4.8', profile = 1 }
    h:start(); h:tick(); h:stop()
    h:status()   -- { loaded=, failed=, files={}, macros={}, ticks=, errors= }
============================================================================]]

local host = {}

local H = {}
H.__index = H

-- ===========================================================================
-- 0. host filesystem (the otclient tree is OUTSIDE the g_resources sandbox)
-- ===========================================================================
-- g_resources is rooted at <otRoot>/profiles/, so mods/game_bot is not reachable
-- through it.  Those reads go straight to io, read-only.

local function readHostFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil, 'cannot open ' .. path end
    local s = f:read('*a')
    f:close()
    return s
end

-- Sorted .lua listing of a host directory.  Reuses shim/resources' platform
-- primitives so there is exactly one directory-listing implementation and it
-- works identically on Windows and on Debian.
local function listHostLua(dir)
    local ok, resources = pcall(require, 'shim.resources')
    local names = {}
    if ok and resources and resources.host and resources.host.list then
        for _, name in ipairs(resources.host.list(dir) or {}) do
            if name:sub(-4) == '.lua' and resources.host.isFile(dir .. '/' .. name) then
                names[#names + 1] = name
            end
        end
    else
        -- Fallback: shell out.  Only used when shim/resources stops exporting its
        -- primitives; loud, because a silently empty functions/ dir would look like
        -- "the runtime has no API" rather than "the listing broke".
        local cmd = (package.config:sub(1, 1) == '\\')
            and ('dir /b "' .. dir:gsub('/', '\\') .. '\\*.lua" 2>nul')
            or  ('ls -1 "' .. dir .. '"/*.lua 2>/dev/null')
        local p = io.popen(cmd)
        if p then
            for line in p:lines() do
                local n = line:match('([^/\\]+%.lua)%s*$')
                if n then names[#names + 1] = n end
            end
            p:close()
        end
    end
    table.sort(names)
    return names
end

-- ===========================================================================
-- 1. audited source patches  (PLAN sec.1.14)
-- ===========================================================================
-- The otclient tree is never edited (invariant I9); a vendored file that needs a
-- fix is rewritten IN MEMORY on the way to `load`, and the rewrite FAILS LOUDLY
-- when `expected` is no longer present -- that is the upstream-drift detector.
--
-- The table itself now lives in shim/patches.lua (PLAN sec.1.14) so that the
-- profile-script path below and the dofiles path above share ONE audited list.
-- Three entries, all the same table-vs-userdata bug class:
--   functions/map.lua           getSpectators overload discrimination
--   functions/ui_elements.lua   UI.Container:setItems discarded its argument
--   /vBot/training.lua          the user's private copy of the same setItems bug
local patchmod = require('shim.patches')

local PATCHES = patchmod.LIST

local function applyPatches(src, virtualPath, notes)
    return patchmod.apply(src, virtualPath, notes)
end
host.PATCHES = PATCHES
host.patches = patchmod

-- ===========================================================================
-- 2. the bot-tabs stub
-- ===========================================================================
-- executor.lua:24 does
--     context.tabs:addTab("Main", g_ui.createWidget('BotPanel')).tabPanel.content
-- and ui_legacy.lua:32-46 does getTab(name), setOn(true) and iterates `.tabs`
-- calling tab:getText() / tab:setFont().  That is the WHOLE contract.

local function newTabs(mkWidget)
    local T = { tabs = {}, _byName = {}, _on = false }
    function T:addTab(name, panel)
        local existing = self._byName[name]
        if existing then return existing end
        local content = panel or mkWidget('BotPanel')
        local tab = {
            _name = name,
            tabPanel = { content = content },
            getText = function() return name end,
            setText = function(_, t) name = t end,
            setFont = function() end,
            setOn  = function() end,
            isOn   = function() return false end,
        }
        self._byName[name] = tab
        self.tabs[#self.tabs + 1] = tab
        return tab
    end
    function T:getTab(name) return self._byName[name] end
    function T:setOn(v) self._on = v and true or false end
    function T:isOn() return self._on end
    function T:getChildCount() return #self.tabs end
    return T
end
host.newTabs = newTabs

-- ===========================================================================
-- 3. host.new
-- ===========================================================================

--- new(opts) -> h
---   opts.G          SHIM_G                                    (required)
---   opts.LC         the luaclient handle                      (required)
---   opts.resources  the shim g_resources rooted at <otRoot>/profiles/ (required)
---   opts.otRoot     the otclient checkout                     (required)
---   opts.config     the /bot/<dir> name, default 'vBot_4.8'
---   opts.profile    g_settings profile number, default 1
---   opts.readOnly   true (default) -> every g_resources write is refused+recorded
---   opts.storage    override the decoded storage table (tests)
---   opts.log        lib/log.lua
---   opts.mkWidget   fn(styleName) -> widget (the UI backend); default g_ui.createWidget
---   opts.onMessage  fn(kind, text) -- the sandbox's info()/warn()/error() sink
---   opts.saveEvery  ms between storage autosaves; default 60000, 0 disables
function host.new(opts)
    opts = opts or {}
    for _, k in ipairs({ 'G', 'LC', 'resources', 'otRoot' }) do
        if opts[k] == nil then error('host.new: opts.' .. k .. ' is required', 2) end
    end
    local h = setmetatable({}, H)
    h.G         = opts.G
    h.LC        = opts.LC
    h.res       = opts.resources
    h.otRoot    = (opts.otRoot:gsub('\\', '/')):gsub('/+$', '')
    h.botMod    = h.otRoot .. '/mods/game_bot'
    h.config    = opts.config or 'vBot_4.8'
    h.profile   = tonumber(opts.profile) or 1
    h.readOnly  = opts.readOnly ~= false
    h.log       = opts.log or (opts.LC and opts.LC.log)
    h.mkWidget  = opts.mkWidget
    h.saveEvery = opts.saveEvery == nil and 60000 or tonumber(opts.saveEvery)
    h.onMessage = opts.onMessage
    h._storageOverride = opts.storage
    -- opts.clock: fn() -> ms.  When given, it REPLACES platform.beginTick for the
    -- duration of a tick, so a suite can step time deterministically (I5 still
    -- holds: the value is quantised once per tick).
    h.clock     = opts.clock

    h.files     = {}          -- ordered { name, ok, err, ms, bytes, kind }
    h._byName   = {}
    h.patchNotes = {}
    h.patchFailures = {}
    h.messages  = { info = 0, warn = 0, error = 0 }
    h.messageLog = {}         -- last 200, so a failing macro is diagnosable
    h.ticks     = 0
    h.tickErrors = 0
    h.lastTickMs = 0
    h.maxTickMs = 0
    h.blockedWrites = {}
    h.started   = false
    return h
end

-- ---------------------------------------------------------------------------
function H:_note(name, kind, ok, err, ms, bytes)
    local rec = self._byName[name]
    if not rec then
        rec = { name = name, kind = kind }
        self._byName[name] = rec
        self.files[#self.files + 1] = rec
    end
    rec.ok = ok
    -- FIRST error wins: a later cascade failure is noise, the first one is the bug.
    if err and not rec.err then rec.err = tostring(err) end
    rec.ms = ms or rec.ms
    rec.bytes = bytes or rec.bytes
    return rec
end

function H:_msg(kind, text)
    self.messages[kind] = (self.messages[kind] or 0) + 1
    if #self.messageLog < 200 then
        self.messageLog[#self.messageLog + 1] = ('[%s] %s'):format(kind, tostring(text))
    end
    if self.log then
        local fn = (kind == 'error' and self.log.error)
                or (kind == 'warn' and self.log.warn) or self.log.info
        if fn then fn('vbot: %s', tostring(text)) end
    end
    if self.onMessage then pcall(self.onMessage, kind, text) end
end

-- ---------------------------------------------------------------------------
-- read-only guard over g_resources
-- ---------------------------------------------------------------------------
-- The user's live profile is the thing this project exists not to damage.  In
-- readOnly mode a write is RECORDED and refused (returning false, which is what
-- the real g_resources returns on failure), never performed.

function H:_guardResources()
    if not self.readOnly then return end
    local res = self.res
    if res._shimGuarded then return end
    local blocked = self.blockedWrites
    local log = self.log
    local function refuse(what)
        return function(path, ...)
            blocked[#blocked + 1] = what .. ' ' .. tostring(path)
            if log and log.debug then
                log.debug('shim/host: read-only mode refused %s(%s)', what, tostring(path))
            end
            return false
        end
    end
    res._realWrite  = res.writeFileContents
    res._realDelete = res.deleteFile
    res._realRemove = res.removeFile
    res._realMakeDir = res.makeDir
    res.writeFileContents = refuse('writeFileContents')
    res.deleteFile        = refuse('deleteFile')
    res.removeFile        = refuse('removeFile')
    res.makeDir           = refuse('makeDir')
    res._shimGuarded = true
end

function H:_unguardResources()
    local res = self.res
    if not res._shimGuarded then return end
    res.writeFileContents = res._realWrite
    res.deleteFile        = res._realDelete
    res.removeFile        = res._realRemove
    res.makeDir           = res._realMakeDir
    res._shimGuarded = nil
end

-- ---------------------------------------------------------------------------
-- storage
-- ---------------------------------------------------------------------------
-- bot.lua:268-282 reads /bot/<config>/storage/profile_<N>.json into the table
-- the sandbox sees as `context.storage`.  It carries `_macros`, which is how the
-- user's own macro on/off switches are persisted -- so a shim that ignores it
-- would run every macro the user has deliberately disabled.

function H:_storagePath()
    return ('/bot/%s/storage/profile_%d.json'):format(self.config, self.profile)
end

function H:loadStorage()
    if self._storageOverride then return self._storageOverride end
    local path = self:_storagePath()
    local ok, txt = pcall(self.res.readFileContents, path)
    if not ok or type(txt) ~= 'string' or txt == '' then
        if self.log and self.log.warn then
            self.log.warn('shim/host: no bot storage at %s -- starting from an empty table', path)
        end
        return {}
    end
    self.storageBytes = #txt
    local json = require('lib.json')
    local okd, decoded = pcall(json.decode, txt)
    if not okd or type(decoded) ~= 'table' then
        if self.log and self.log.error then
            self.log.error('shim/host: %s is not valid JSON (%s) -- starting from an empty table',
                           path, tostring(decoded))
        end
        return {}
    end
    return decoded
end

function H:saveStorage()
    if not self.context then return false, 'not started' end
    if self.readOnly then
        self.blockedWrites[#self.blockedWrites + 1] = 'saveStorage ' .. self:_storagePath()
        return false, 'read-only'
    end
    local json = require('lib.json')
    local ok, txt = pcall(json.encode, self.context.storage)
    if not ok then return false, txt end
    local res = self.res
    res.makeDir(('/bot/%s/storage'):format(self.config))
    return res.writeFileContents(self:_storagePath(), txt) and true or false
end

-- ---------------------------------------------------------------------------
-- the `load` wrapper: per-file verdicts for the whole vBot tree
-- ---------------------------------------------------------------------------
function H:_instrumentLoad()
    local G = self.G
    local rawLoad = G.load or _G.load
    self._rawLoad = rawLoad
    local self_ = self
    local depth = 0

    G.load = function(chunk, name, mode, env)
        -- Audited in-memory rewrites for PROFILE scripts.  executor.lua:115
        -- compiles every one of the 74 files as load(src, file, nil, context)
        -- with `file` exactly as _Loader.lua wrote it ('/vBot/training.lua'), so
        -- this is the only place a profile source can be fixed without touching
        -- the user's tree (invariant I9).  Drift is loud but NOT fatal here: a
        -- drifted patch logs and the file loads unpatched, because bricking the
        -- whole bot over one stale literal is worse than one wrong container.
        if type(chunk) == 'string' and name then
            local key = patchmod.key(name)
            if key and patchmod.has(key) then
                local patched, perr = patchmod.tryApply(chunk, key, self_.patchNotes)
                if perr then
                    self_.patchFailures[#self_.patchFailures + 1] = perr
                    if self_.log and self_.log.error then self_.log.error('%s', perr) end
                else
                    chunk = patched
                end
            end
        end
        local f, err = rawLoad(chunk, name, mode, env)
        if not f then
            -- A COMPILE error never reaches the pcall below, so record it here or
            -- the file silently disappears from the table.
            local label = tostring(name or '?'):gsub('^@', '')
            if label:sub(1, 1) == '/' then
                self_:_note(label, 'vbot', false, 'compile: ' .. tostring(err), 0,
                            type(chunk) == 'string' and #chunk or nil)
            end
            return f, err
        end
        local label = tostring(name or '?'):gsub('^@', '')
        if label:sub(1, 1) ~= '/' then return f end     -- only bot scripts
        return function(...)
            local rec = self_:_note(label, 'vbot', false, nil, nil,
                                    type(chunk) == 'string' and #chunk or nil)
            rec.depth = rec.depth or depth
            depth = depth + 1
            local t0 = self_:_millis()
            local r = { pcall(f, ...) }
            depth = depth - 1
            rec.ms = self_:_millis() - t0
            if r[1] then
                rec.ok = true
                return unpack(r, 2)
            end
            rec.ok = false
            if not rec.err then rec.err = tostring(r[2]) end
            -- Re-raise: _Loader.lua has no pcall, so the failure must propagate to
            -- the caller exactly as it does in the live client.  The record above
            -- is what makes the failure attributable to THIS file.
            error(r[2], 0)
        end
    end
end

function H:_restoreLoad()
    if self._rawLoad then self.G.load = self._rawLoad; self._rawLoad = nil end
end

function H:_millis()
    local c = self.G.g_clock
    if c and c.realMillis then return c.realMillis() end
    return math.floor(os.clock() * 1000)
end

-- ---------------------------------------------------------------------------
-- dofiles(dir): the C++ builtin (luainterface.cpp:599-617)
-- ---------------------------------------------------------------------------
-- Loads every .lua in <game_bot>/<dir> in SORTED order, with the module's own
-- environment -- here SHIM_G, because that is what executor.lua itself runs in.
-- Each file's only entry point is `local context = G.botContext`.

function H:_installDofiles()
    local self_ = self
    local G = self.G
    self._rawDofiles = G.dofiles
    G.dofiles = function(dir, recursive, contains)
        local base = self_.botMod .. '/' .. dir
        for _, name in ipairs(listHostLua(base)) do
            if not contains or name:find(contains, 1, true) then
                local vpath = dir .. '/' .. name
                local src, rerr = readHostFile(base .. '/' .. name)
                if not src then
                    self_:_note(vpath, 'runtime', false, rerr)
                else
                    local okp, patched = pcall(applyPatches, src, vpath, self_.patchNotes)
                    if not okp then
                        self_:_note(vpath, 'runtime', false, patched)
                    else
                        local f, cerr = self_._rawLoad(patched, '@' .. vpath, 't', G)
                        if not f then
                            self_:_note(vpath, 'runtime', false, 'compile: ' .. tostring(cerr), 0, #patched)
                        else
                            local t0 = self_:_millis()
                            local ok, err = pcall(f)
                            self_:_note(vpath, 'runtime', ok, (not ok) and err or nil,
                                        self_:_millis() - t0, #patched)
                            if not ok and self_.log and self_.log.error then
                                self_.log.error('shim/host: %s failed to load: %s', vpath, tostring(err))
                            end
                        end
                    end
                end
            end
        end
    end
end

function H:_restoreDofiles()
    self.G.dofiles = self._rawDofiles
    self._rawDofiles = nil
end

-- ---------------------------------------------------------------------------
-- start
-- ---------------------------------------------------------------------------
function H:start()
    if self.started then return true end
    local G = self.G

    self:_guardResources()
    self:_instrumentLoad()
    self:_installDofiles()

    -- 1. executor.lua -- runs in SHIM_G, exactly like the real game_bot module env.
    local execPath = self.botMod .. '/executor.lua'
    local src, rerr = readHostFile(execPath)
    if not src then
        self:_note('mods/game_bot/executor.lua', 'runtime', false, rerr)
        self:_teardownHooks()
        return false, rerr
    end
    do
        local f, cerr = self._rawLoad(src, '@mods/game_bot/executor.lua', 't', G)
        if not f then
            self:_note('mods/game_bot/executor.lua', 'runtime', false, 'compile: ' .. tostring(cerr))
            self:_teardownHooks()
            return false, cerr
        end
        local ok, err = pcall(f)
        self:_note('mods/game_bot/executor.lua', 'runtime', ok, (not ok) and err or nil, nil, #src)
        if not ok then self:_teardownHooks(); return false, err end
    end
    if type(G.executeBot) ~= 'function' then
        local why = 'executor.lua did not define executeBot'
        self:_note('mods/game_bot/executor.lua', 'runtime', false, why)
        self:_teardownHooks()
        return false, why
    end

    -- 2. the arguments bot.lua:283-296 passes to executeBot
    local storage = self:loadStorage()
    self.storage = storage
    local mk = self.mkWidget or (G.g_ui and G.g_ui.createWidget)
                or function() return {} end
    self.tabs = newTabs(function(style) return mk(style) end)

    local self_ = self
    local function msgCallback(kind, text) self_:_msg(kind, text) end
    local function saveConfigCallback() return self_:saveStorage() end
    local function reloadCallback()
        -- bot.lua's refresh(): a full reload.  The shim does not hot-reload inside
        -- a run; the supervisor restarts the worker instead.  Recorded, not silent.
        if self_.log and self_.log.warn then
            self_.log.warn('shim/host: the bot asked for a config reload; not supported in-process')
        end
        self_.reloadRequested = true
    end

    -- 3. THE run.  Everything inside is the user's own code.
    local t0 = self:_millis()
    local ok, res = xpcall(function()
        return G.executeBot(self_.config, storage, self_.tabs, msgCallback,
                            saveConfigCallback, reloadCallback, {})
    end, function(e) return tostring(e) .. '\n' .. debug.traceback('', 2) end)
    self.loadMs = self:_millis() - t0

    -- The load hook stays installed only for the duration of the load; the tick
    -- must not pay for it, and a script that calls load() at run time is not a
    -- file verdict.
    self:_restoreLoad()
    self:_restoreDofiles()

    if not ok then
        self.startError = res
        if self.log and self.log.error then
            self.log.error('shim/host: executeBot failed: %s', tostring(res))
        end
        return false, res
    end

    self.exec = res
    self.context = self:_recoverContext(res)
    self.started = true
    self._lastSave = self:_millis()
    return true
end

-- executor.lua clears G.botContext when it is done, so the context is recovered
-- through the closures it returned: every callback upvalue chain reaches it.
function H:_recoverContext(res)
    if self.G.G and self.G.G.botContext then return self.G.G.botContext end
    local fn = res and res.script
    if type(fn) ~= 'function' then return nil end
    for i = 1, 32 do
        local name, val = debug.getupvalue(fn, i)
        if not name then break end
        if type(val) == 'table' and rawget(val, '_macros') and rawget(val, '_callbacks') then
            return val
        end
    end
    -- Second try: through one of the callbacks, whose upvalue is `context` too.
    local cbs = res and res.callbacks
    if type(cbs) == 'table' then
        for _, f in pairs(cbs) do
            if type(f) == 'function' then
                for i = 1, 32 do
                    local name, val = debug.getupvalue(f, i)
                    if not name then break end
                    if type(val) == 'table' and rawget(val, '_macros') then return val end
                end
            end
        end
    end
    return nil
end

function H:_teardownHooks()
    self:_restoreLoad()
    self:_restoreDofiles()
end

-- ---------------------------------------------------------------------------
-- tick  (PLAN sec.4.2)
-- ---------------------------------------------------------------------------
function H:tick()
    if not (self.started and self.exec and self.exec.script) then return false, 'not started' end
    local G = self.G
    -- I5: one cached g_clock.millis() per tick, so context.now and any in-tick
    -- g_clock.millis() agree.  executor.lua sets context.now from it on the next
    -- line, and vBot compares `now - x` in hundreds of places.
    local ok, platform = pcall(require, 'shim.platform')
    if ok then
        if self.clock then
            -- A test drives a VIRTUAL clock: macros with a 500 ms timeout cannot be
            -- observed at all when five ticks span under a millisecond of wall time.
            platform.setClock(self.clock())
        elseif platform.beginTick then
            platform.beginTick()
        end
    end

    local t0 = self:_millis()
    local tok, terr = pcall(self.exec.script)
    local dt = self:_millis() - t0

    self.ticks = self.ticks + 1
    self.lastTickMs = dt
    if dt > self.maxTickMs then self.maxTickMs = dt end
    if not tok then
        self.tickErrors = self.tickErrors + 1
        if not self.firstTickError then self.firstTickError = tostring(terr) end
        if self.log and self.log.error then
            self.log.error('shim/host: tick %d failed: %s', self.ticks, tostring(terr))
        end
        return false, terr
    end

    if self.saveEvery and self.saveEvery > 0 and not self.readOnly then
        local now = self:_millis()
        if now - (self._lastSave or 0) >= self.saveEvery then
            self._lastSave = now
            self:saveStorage()
        end
    end
    return true
end

--- Arm the 10 ms tick on lib/sched.  Separate from start() so a test can drive
--- tick() by hand and a live worker can drive it from the reactor.
function H:arm(tickMs)
    if self._timer then return self._timer end
    local sched = (self.LC and self.LC.sched) or require('lib.sched')
    local self_ = self
    self._timer = sched.every(tickMs or 10, function()
        if self_.LC and self_.LC.inGame == false then return end
        self_:tick()
    end)
    return self._timer
end

function H:disarm()
    if not self._timer then return end
    local sched = (self.LC and self.LC.sched) or require('lib.sched')
    sched.cancel(self._timer)
    self._timer = nil
end

-- ---------------------------------------------------------------------------
-- stop
-- ---------------------------------------------------------------------------
function H:stop()
    self:disarm()
    if self.started and not self.readOnly then self:saveStorage() end
    self:_teardownHooks()
    self:_unguardResources()
    self.started = false
    self.exec = nil
    return true
end

-- ---------------------------------------------------------------------------
-- status -- the deliverable table
-- ---------------------------------------------------------------------------
--- Wrap every registered macro callback with a run/failure counter.
--- Without this "N ticks, 0 errors" is not evidence: a tick over 48 macros none of
--- which was due does exactly nothing and still reports clean (A4 sec.5 makes the
--- same point).  The wrapper is transparent -- it returns whatever the macro
--- returned, which is what executor.lua:200 uses to advance lastExecution.
---   opts.forceEnable : run even the macros the user's storage has switched off
function H:instrumentMacros(opts)
    opts = opts or {}
    local ctx = self.context
    local list = ctx and rawget(ctx, '_macros')
    if not list then return 0 end
    self._macroStats = {}
    for i, m in ipairs(list) do
        local stat = { name = m.name, runs = 0, fails = 0 }
        self._macroStats[i] = stat
        if opts.forceEnable then m.enabled = true; m.lastExecution = 0 end
        local inner = m.callback
        m.callback = function(...)
            stat.runs = stat.runs + 1
            local r = { pcall(inner, ...) }
            if not r[1] then
                stat.fails = stat.fails + 1
                if not stat.err then stat.err = tostring(r[2]) end
                error(r[2], 0)          -- let executor.lua report it as it always does
            end
            return unpack(r, 2)
        end
    end
    return #list
end

function H:macros()
    local out = {}
    local ctx = self.context
    local list = ctx and rawget(ctx, '_macros')
    if not list then return out end
    for i, m in ipairs(list) do
        local stat = self._macroStats and self._macroStats[i]
        out[i] = { name = m.name, timeout = m.timeout, enabled = m.enabled and true or false,
                   hotkey = m.hotkey, delay = m.delay,
                   runs = stat and stat.runs, fails = stat and stat.fails,
                   err = stat and stat.err }
    end
    return out
end

function H:status()
    local loaded, failed, vbotLoaded, vbotFailed, rtLoaded, rtFailed = 0, 0, 0, 0, 0, 0
    local failures = {}
    for _, f in ipairs(self.files) do
        if f.ok then
            loaded = loaded + 1
            if f.kind == 'vbot' then vbotLoaded = vbotLoaded + 1 else rtLoaded = rtLoaded + 1 end
        else
            failed = failed + 1
            if f.kind == 'vbot' then vbotFailed = vbotFailed + 1 else rtFailed = rtFailed + 1 end
            failures[#failures + 1] = { name = f.name, err = f.err }
        end
    end
    local ctx = self.context
    local nCallbacks, nHotkeys, nSched = 0, 0, 0
    if ctx then
        for _, l in pairs(rawget(ctx, '_callbacks') or {}) do nCallbacks = nCallbacks + #l end
        for _ in pairs(rawget(ctx, '_hotkeys') or {}) do nHotkeys = nHotkeys + 1 end
        nSched = #(rawget(ctx, '_scheduler') or {})
    end
    local macros = self:macros()
    local enabled, ran, macroRuns, macroFails = 0, 0, 0, 0
    for _, m in ipairs(macros) do
        if m.enabled then enabled = enabled + 1 end
        if (m.runs or 0) > 0 then ran = ran + 1 end
        macroRuns = macroRuns + (m.runs or 0)
        macroFails = macroFails + (m.fails or 0)
    end
    return {
        started      = self.started,
        config       = self.config,
        profile      = self.profile,
        readOnly     = self.readOnly,
        loaded       = loaded,
        failed       = failed,
        vbotLoaded   = vbotLoaded,
        vbotFailed   = vbotFailed,
        runtimeLoaded = rtLoaded,
        runtimeFailed = rtFailed,
        files        = self.files,
        failures     = failures,
        macros       = macros,
        macroCount   = #macros,
        macrosEnabled = enabled,
        macrosRan     = ran,
        macroRuns     = macroRuns,
        macroFails    = macroFails,
        hotkeys      = nHotkeys,
        callbacks    = nCallbacks,
        scheduled    = nSched,
        ticks        = self.ticks,
        tickErrors   = self.tickErrors,
        firstTickError = self.firstTickError,
        lastTickMs   = self.lastTickMs,
        maxTickMs    = self.maxTickMs,
        loadMs       = self.loadMs,
        messages     = self.messages,
        messageLog   = self.messageLog,
        storageBytes = self.storageBytes,
        blockedWrites = self.blockedWrites,
        patchNotes   = self.patchNotes,
        patchFailures = self.patchFailures,
        startError   = self.startError,
    }
end

host.H = H
return host
