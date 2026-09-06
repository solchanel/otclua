--[[============================================================================
bot/init.lua -- the bot runtime core: macros, the 10 ms tick, the scheduler
queue, delay(), storage, the module registry and arbitration.

Work item F3.  Behaviour source: docs/vbot/bot-core.md (the "## VERIFIER
(Corrections)" section overrides the body above it) and BOT.md "bot/init.lua".

    local b = bot.new(LC, { profileDir=, vprofile=1, cavebot=, targetbot=,
                            autostart=true })
    b:start()  b:stop()  b:isOn()
    b.storage                      -- persisted table, saved on stop and every 60 s
    b:macro(timeoutMs, name, fn)   -- vBot semantics
    b:schedule(delayMs, fn)
    b:delay(ms)  b:isDelayed()
    b.modules                      -- { healbot=, attackbot=, cavebot=, targetbot= }
    b:isActionAllowed(who)
    b:status()

------------------------------------------------------------------------------
MACRO MODEL (bot-core.md §1, all VERIFIED CORRECT by the verifier pass)
------------------------------------------------------------------------------
* `macro(timeout, [name], [hotkey], callback, [parent])`, timeout must be a
  number >= 1 or it raises; it is then CLAMPED UP to a minimum of 50 ms
  (main.lua:38-40) -- `macro(20, ...)` in cavebot.lua:80 really runs at 50 ms.
* The record starts DISABLED with
  `lastExecution = now + math.random(0, 100)` -- the jitter de-synchronises
  macros registered in the same frame (main.lua:46).  A macro registered during
  a tick therefore can never fire in that same tick (VERIFIER).
* Enable state persists in `storage._macros[name]`, keyed by the NAME STRING
  ONLY, and only the literal value `true` restores ON (main.lua:100-102).  Two
  macros sharing a name share one flag.
* An UNNAMED macro (name == "") is forced `enabled = true` and cannot be
  disabled from config (main.lua:104) -- but `setOn/setOff` still write the
  empty-string key, which is why the user's real profile_1.json contains
  `"": false`.
* The user callback's RETURN VALUE IS DISCARDED.  Only "did the wrapper run the
  body" propagates: on a real run `lastExecution = now`; while delayed, or when
  the body throws, `lastExecution` is NOT advanced, so the macro is re-evaluated
  on every 10 ms tick and resumes the instant `delay < now`.
* A body slower than 100 ms logs `Slow macro (Nms): <name> - <site>`, timed with
  the REAL clock, not the per-tick `now`.
* `delay(ms)` writes `_currentExecution.delay = now + ms`; it is a field write,
  not a sleep -- the body runs on to its return.  Modules also write
  `macro.delay` directly from outside any execution (target.lua:234-236), so the
  record exposes plain writable `delay/enabled/timeout/lastExecution` fields.

------------------------------------------------------------------------------
DELIBERATE DEVIATIONS FROM vBot (each one is a VERIFIER-flagged upstream bug)
------------------------------------------------------------------------------
1. SCHEDULER DRAIN IS POP-THEN-RUN.  Upstream runs `_scheduler[1].callback()`
   and only then `table.remove(_scheduler, 1)`; if the callback schedules
   something that sorts to index 1, the remove deletes the NEW entry and the
   just-executed one stays at the head and re-runs forever.  We pop first, and
   cap one drain pass at `SCHEDULE_DRAIN_LIMIT` entries.
2. SCHEDULE INSERTION IS STABLE.  Upstream `table.sort` is not stable, so two
   entries with the same execution time fire in an arbitrary order.  We insert
   in place after every entry with `execution <= t`, so ties fire FIFO.
3. `_currentExecution` IS ALWAYS RESET.  Upstream resets it after the body, but
   the pcall lives outside the wrapper -- a throwing body leaves it pointing at
   the dead macro, and a later `delay()` from a `schedule()` body then silently
   delays that stale macro.  We reset in the caller, unconditionally.
4. EVENT CALLBACKS ARE INDIVIDUALLY pcall'd.  vBot wraps the WHOLE dispatch in
   one `safeBotCall`, so listener #1 throwing stops #2..N for that event.
5. STORAGE IS AUTOSAVED (60 s, BOT.md) AND WRITTEN VIA TEMP+RENAME.  vBot has no
   autosave and `save()` bails out entirely once a macro error has killed the
   executor, silently losing the whole session (bot.lua:299-301).
6. A `[[`-quoted cavebot body does not grow a blank line per load (bot/config.lua
   header).

Everything else -- the 50 ms floor, the jitter, the discarded return value, the
non-advancing `lastExecution`, registration-order priority, the per-macro pcall,
the `== true` restore rule, unnamed-macro forcing, macro pass before scheduler
pass -- is reproduced exactly.

TICK RATE: a true 10 ms timer.  The VERIFIER notes real vBot effectively runs at
`max(10 ms, frame time)` (~16.6 ms at 60 FPS) because scheduleEvent drains once
per frame.  A headless client has no frame; 10 ms is what BOT.md specifies and
what docs/vbot/cavebot.md:1696 requires so that a `CaveBot.delay(50)` resumes
~10 ms after expiry instead of gaining up to 50 ms of jitter.
============================================================================]]

local config = require('bot.config')
local api    = require('bot.api')

local ok_sys, sys = pcall(require, 'lib.sys')
local nowMs
if ok_sys and sys and sys.nowMs then
    nowMs = sys.nowMs
else
    nowMs = function() return os.clock() * 1000 end
end

local bot = {}

local Bot = {}
Bot.__index = Bot

local MACRO_MIN_TIMEOUT     = 50        -- main.lua:38-40
local MACRO_JITTER_MAX      = 100       -- main.lua:46  math.random(0, 100)
local SLOW_CALLBACK_MS      = 100       -- main.lua:120
local DEFAULT_TICK_MS       = 10        -- bot.lua:530
local DEFAULT_STORAGE_SAVE  = 60000     -- BOT.md "saved on stop and every 60 s"
local SCHEDULE_DRAIN_LIMIT  = 1000      -- deviation (1)

-- ---------------------------------------------------------------------------
-- logging helpers
-- ---------------------------------------------------------------------------
local function nolog() end

local function mklog(client)
    local l = client and client.log
    if type(l) == 'table' then
        return {
            info  = function(...) (l.info  or nolog)(...) end,
            warn  = function(...) (l.warn  or l.warning or nolog)(...) end,
            error = function(...) (l.error or nolog)(...) end,
            debug = function(...) (l.debug or nolog)(...) end,
        }
    end
    return { info = nolog, warn = nolog, error = nolog, debug = nolog }
end

-- "file:line" of the macro registration site, used only in the slow warning
-- (main.lua:107-111).
local function callSite(level)
    local ok, info = pcall(debug.getinfo, level, 'Sl')
    if not ok or not info then return '?' end
    local src = tostring(info.short_src or info.source or '?')
    return src .. ':' .. tostring(info.currentline or 0)
end

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
--- bot.new(client, opts)
---   client              _G.LC (log, sched, state, sender, events, items)
---   opts.profileDir     the vBot config directory (…/profiles/bot/vBot_4.8)
---   opts.vprofile       1..10, selects vBot_configs/profile_<N> and storage/profile_<N>.json
---   opts.cavebot        cavebot_configs base name to preselect
---   opts.targetbot      targetbot_configs base name to preselect
---   opts.autostart      start() immediately
---   opts.tickMs         default 10
---   opts.storageSaveMs  default 60000 (0 disables the autosave)
---   opts.clock          () -> ms, the frame clock; defaults to sys.nowMs().
---                       Injectable so tests can drive time deterministically --
---                       everything in the runtime and in bot/api.lua reads this
---                       one clock, never os/wall time (the >100 ms slow-macro
---                       timer is the single exception, by design: it must
---                       measure REAL elapsed time, like g_clock.realMillis()).
function bot.new(client, opts)
    opts   = opts or {}
    client = client or _G.LC or {}

    local self = setmetatable({}, Bot)
    self.client = client
    self.log    = mklog(client)
    self.sched  = client.sched
    self.state  = client.state
    self.sender = client.sender
    self.events = client.events
    self.items  = client.items
    self.opts   = opts

    -- The frame clock.  Injectable (opts.clock) so tests can drive time
    -- deterministically; production uses the monotonic sys.nowMs().
    self.clock          = opts.clock or nowMs
    self.tickMs         = tonumber(opts.tickMs) or DEFAULT_TICK_MS
    self.storageSaveMs  = tonumber(opts.storageSaveMs) or DEFAULT_STORAGE_SAVE
    self.profileDir     = opts.profileDir
    self.vprofile       = tonumber(opts.vprofile) or 1

    self.now, self.time = self.clock(), self.clock()
    self.running        = false
    self._inTick        = false
    self._macros        = {}      -- ARRAY: order == registration order == priority
    self._scheduler     = {}      -- ARRAY sorted ascending by .execution (stable on ties)
    self._commands      = {}      -- headless stand-in for vBot's _hotkeys registry
    self._currentExecution = nil
    self._scheduleSeq   = 0
    self.modules        = {}      -- { healbot=, attackbot=, cavebot=, targetbot= }
    self.stats          = { ticks = 0, macroRuns = 0, macroErrors = 0,
                            scheduled = 0, scheduleErrors = 0, storageSaves = 0 }

    -- config store + storage --------------------------------------------------
    self.config = config.new{ profileDir = self.profileDir, vprofile = self.vprofile,
                              log = client.log }
    local st, err = self.config:loadStorage()
    if st == nil then
        -- bot.lua:275-281: a corrupt storage file aborts bot startup.  We keep the
        -- signal but stay constructible so a control plane can report it.
        self.log.error('[BOT] storage load failed: %s', tostring(err))
        self.storageError = err
        st = {}
    end
    self.storage = st
    if type(self.storage._macros)  ~= 'table' then self.storage._macros  = {} end
    if type(self.storage._configs) ~= 'table' then self.storage._configs = {} end

    -- the vBot-compatible script surface
    self.api = api.new(self)

    if opts.cavebot   then self:selectConfig('cavebot_configs',   opts.cavebot)   end
    if opts.targetbot then self:selectConfig('targetbot_configs', opts.targetbot) end

    if opts.autostart then self:start() end
    return self
end

-- ---------------------------------------------------------------------------
-- log sinks (context.info / warn / error, bot.lua:503-523)
-- ---------------------------------------------------------------------------
function Bot:info(fmt, ...)  self.log.info ('[BOT] ' .. tostring(fmt), ...) end
function Bot:warn(fmt, ...)  self.log.warn ('[BOT] ' .. tostring(fmt), ...) end
function Bot:error(fmt, ...) self.log.error('[BOT] ' .. tostring(fmt), ...) end
Bot.warning = Bot.warn

-- ---------------------------------------------------------------------------
-- macros
-- ---------------------------------------------------------------------------
--- b:macro(timeout, callback)
--- b:macro(timeout, name, callback)
--- b:macro(timeout, name, callback, parent)
--- b:macro(timeout, name, hotkey, callback)
--- b:macro(timeout, name, hotkey, callback, parent)
function Bot:macro(timeout, name, hotkey, callback, parent)
    if type(timeout) ~= 'number' or timeout < 1 then
        error('Invalid timeout for macro: ' .. tostring(timeout), 2)
    end
    -- overload resolution, main.lua:13-23
    if type(name) == 'function' then
        callback, name, hotkey = name, '', ''
    elseif type(hotkey) == 'function' then
        parent, callback, hotkey = callback, hotkey, ''
    elseif type(callback) ~= 'function' then
        error('Invalid callback for macro', 2)
    end
    hotkey = hotkey or ''
    if type(name) ~= 'string' or type(hotkey) ~= 'string' then
        error('Invalid name or hotkey for macro', 2)
    end
    if timeout < MACRO_MIN_TIMEOUT then timeout = MACRO_MIN_TIMEOUT end

    local b = self
    local m = {
        enabled       = false,
        name          = name,
        timeout       = timeout,
        -- the de-sync jitter; also guarantees a macro registered mid-tick cannot
        -- fire in that tick (VERIFIER on §1.3)
        lastExecution = b.now + math.random(0, MACRO_JITTER_MAX),
        hotkey        = hotkey,
        parent        = parent,
        delay         = nil,
        fn            = callback,
        site          = callSite(3),
        runs          = 0,
        errors        = 0,
    }

    function m.isOn()  return m.enabled end
    function m.isOff() return not m.enabled end
    function m.setOn(v)
        if v == false then return m.setOff() end
        m.enabled = true
        b.storage._macros[name] = true          -- keyed by NAME ONLY (main.lua:69)
        b._storageDirty = true
    end
    function m.setOff(v)
        if v == false then return m.setOn() end
        m.enabled = false
        b.storage._macros[name] = false         -- main.lua:82
        b._storageDirty = true
    end
    function m.toggle() if m.enabled then m.setOff() else m.setOn() end end
    -- extension (vBot has no unregister); used by tests and by module :reload()
    function m.remove()
        for i = 1, #b._macros do
            if b._macros[i] == m then table.remove(b._macros, i); return true end
        end
        return false
    end

    self._macros[#self._macros + 1] = m

    if #name > 0 then
        -- ONLY the literal `true` restores ON; anything else leaves it off
        if self.storage._macros[name] == true then m.setOn() end
    else
        m.enabled = true                        -- unnamed macros are always on
    end

    if #hotkey > 0 then self._commands[hotkey] = m end
    return m
end

--- Headless stand-in for vBot's hotkey(): a named, externally invocable command.
--- Rejection is a LOGGED message returning nil, never a raise (VERIFIER on §1.7).
function Bot:command(name, callback)
    if type(name) ~= 'string' or #name == 0 then
        self:error('Invalid command name'); return nil
    end
    if self._commands[name] then
        self:error('Duplicated command: %s', name); return nil
    end
    if type(callback) ~= 'function' then
        self:error('Invalid callback for command %s', name); return nil
    end
    local h = { name = name, fn = callback, delay = nil, site = callSite(3) }
    self._commands[name] = h
    return h
end

--- Run a registered command (or toggle the macro bound to that hotkey string).
function Bot:runCommand(name)
    local h = self._commands[name]
    if not h then return nil, 'no such command: ' .. tostring(name) end
    -- a macro bound to this hotkey string toggles, exactly like onKeyDown upstream
    if h.toggle then h.toggle(); return true end
    local ok, ran = pcall(self._invoke, self, h, h.fn)
    if not ok then
        self:error('Command: %s execution error: %s', tostring(name), tostring(ran))
        return nil, ran
    end
    return ran
end

-- ---------------------------------------------------------------------------
-- schedule / delay
-- ---------------------------------------------------------------------------
--- One GLOBAL queue.  It is NOT cancelled when a macro is turned off or a module
--- disabled -- every scheduled closure will fire (bot-core §1.6).
function Bot:schedule(timeout, callback)
    if type(callback) ~= 'function' then
        error('Invalid callback for schedule', 2)
    end
    local base = self._inTick and self.now or self.clock()
    local at   = base + (tonumber(timeout) or 0)
    self._scheduleSeq = self._scheduleSeq + 1
    local e = { execution = at, callback = callback, seq = self._scheduleSeq }
    -- stable insertion: after every entry whose execution <= at (deviation 2)
    local q, i = self._scheduler, #self._scheduler
    while i >= 1 and q[i].execution > at do i = i - 1 end
    table.insert(q, i + 1, e)
    return e
end

--- Suspend the CURRENTLY EXECUTING macro / command / event callback.
--- Outside any callback this only logs an error (main.lua:206-211).
function Bot:delay(ms)
    local cur = self._currentExecution
    if not cur then
        return self:error('Invalid usage of delay function')
    end
    cur.delay = self.now + (tonumber(ms) or 0)
    return cur.delay
end

--- b:isDelayed([record]) -> bool
function Bot:isDelayed(record)
    local e = record or self._currentExecution
    if not e then return false end
    return e.delay ~= nil and e.delay >= self.now
end

-- ---------------------------------------------------------------------------
-- the execution wrapper (main.lua:113-125 + callbacks.lua:19-31)
-- ---------------------------------------------------------------------------
-- Returns true when the body actually ran (that is the ONLY thing that
-- propagates; the user's return value is discarded).
function Bot:_invoke(record, fn, ...)
    if record.delay and record.delay >= self.now then return false end
    local prev = self._currentExecution
    self._currentExecution = record
    local t0 = nowMs()
    local ok, err = pcall(fn, record, ...)
    -- deviation (3): reset unconditionally, even when the body threw
    self._currentExecution = prev
    local dt = nowMs() - t0
    if dt > SLOW_CALLBACK_MS then
        self:warn('Slow macro (%dms): %s - %s', math.floor(dt),
                  tostring(record.name or '?'), tostring(record.site or '?'))
    end
    if not ok then error(err, 0) end
    return true
end

-- ---------------------------------------------------------------------------
-- the tick (bot.lua:525-546 + executor.lua:194-221)
-- ---------------------------------------------------------------------------
function Bot:tick()
    -- ONE sample per tick: every macro in this tick sees the identical `now`,
    -- which is what quantises every `now - x > y` test in ported scripts.
    self.now  = self.clock()
    self.time = self.now
    self._inTick = true
    self.stats.ticks = self.stats.ticks + 1

    -- 1) macros, in registration order.  `while i <= #macros` (not a cached
    --    bound) so a macro registered from inside a callback is reached in the
    --    same pass, exactly like ipairs upstream.
    local macros = self._macros
    local i = 1
    while i <= #macros do
        local m = macros[i]
        if m and m.enabled and (m.lastExecution + m.timeout) <= self.now then
            local ok, ran = pcall(self._invoke, self, m, m.fn)
            if ok then
                if ran then                                   -- the body really ran
                    m.lastExecution = self.now
                    m.runs = m.runs + 1
                    self.stats.macroRuns = self.stats.macroRuns + 1
                end
            else
                local err = ran
                -- lastExecution is deliberately NOT advanced: upstream retries on
                -- the very next tick, and scripts are tuned against that.
                m.errors = m.errors + 1
                self.stats.macroErrors = self.stats.macroErrors + 1
                self:error('Macro: %s execution error: %s', tostring(m.name), tostring(err))
            end
        end
        -- a macro may have removed itself; only advance when macros[i] is unchanged
        if macros[i] == m then i = i + 1 end
    end

    -- 2) scheduler drain, head first, POP-THEN-RUN (deviation 1)
    local q, guard = self._scheduler, 0
    while #q > 0 and q[1].execution <= self.now do
        guard = guard + 1
        if guard > SCHEDULE_DRAIN_LIMIT then
            self:error('Schedule drain runaway (>%d entries in one tick); aborting pass',
                       SCHEDULE_DRAIN_LIMIT)
            break
        end
        local e = table.remove(q, 1)
        -- `_currentExecution` is nil inside a schedule body upstream, so delay()
        -- called from one logs an error instead of delaying something stale.
        local prev = self._currentExecution
        self._currentExecution = nil
        local ok, err = pcall(e.callback)
        self._currentExecution = prev
        self.stats.scheduled = self.stats.scheduled + 1
        if not ok then
            self.stats.scheduleErrors = self.stats.scheduleErrors + 1
            self:error('Schedule execution error: %s', tostring(err))
        end
    end

    self._inTick = false
end

-- ---------------------------------------------------------------------------
-- lifecycle
-- ---------------------------------------------------------------------------
function Bot:isOn() return self.running == true end

function Bot:start()
    if self.running then return false end
    self.now, self.time = self.clock(), self.clock()
    self.running = true

    if self.sched and self.sched.every then
        self._tickId = self.sched.every(self.tickMs, function()
            -- An error escaping tick() itself (never from a macro or a schedule
            -- body -- those are contained) kills the bot, exactly like
            -- bot.lua:536-539.  In practice this can only be a runtime bug.
            local ok, err = pcall(self.tick, self)
            if not ok then
                self:error('FATAL: %s', tostring(err))
                self:stop()
            end
        end)
        if self.storageSaveMs and self.storageSaveMs > 0 then
            self._saveId = self.sched.every(self.storageSaveMs, function()
                self:saveStorage()
            end)
        end
    end

    for _, name in ipairs({ 'healbot', 'attackbot', 'targetbot', 'cavebot' }) do
        local mod = self.modules[name]
        if mod and mod.onBotStart then pcall(mod.onBotStart, mod) end
    end
    self:info('started (tick %d ms, profile %s, vprofile %d)',
              self.tickMs, tostring(self.profileDir), self.vprofile)
    return true
end

function Bot:stop()
    if not self.running then
        self:saveStorage()
        return false
    end
    self.running = false
    if self.sched and self.sched.cancel then
        if self._tickId then pcall(self.sched.cancel, self._tickId) end
        if self._saveId then pcall(self.sched.cancel, self._saveId) end
    end
    self._tickId, self._saveId = nil, nil
    for _, name in ipairs({ 'cavebot', 'targetbot', 'attackbot', 'healbot' }) do
        local mod = self.modules[name]
        if mod and mod.onBotStop then pcall(mod.onBotStop, mod) end
    end
    -- REVIEW FIX: unwireModules() documents itself as "called from stop()", but stop()
    -- never called it.  main.lua's normal shutdown calls it explicitly; the FATAL path in
    -- Bot:start's tick wrapper calls stop() directly, and without this the walker's
    -- walkCancel hook and TargetBot's event hooks stayed live on a "stopped" bot.
    -- unwireModules is idempotent (both branches pcall optional methods).
    pcall(self.unwireModules, self)
    self:saveStorage()
    self:info('stopped')
    return true
end

--- Drop every macro / schedule / command (vBot's clear()).  start() after this
--- gives a virgin runtime; the storage table survives.
function Bot:clear()
    self._macros, self._scheduler, self._commands = {}, {}, {}
    self._currentExecution = nil
end

-- Drive the tick manually (tests, or a host without lib/sched).
function Bot:runTicks(n)
    for _ = 1, (n or 1) do self:tick() end
end

-- ---------------------------------------------------------------------------
-- storage
-- ---------------------------------------------------------------------------
function Bot:saveStorage()
    if not self.profileDir then return false, 'no profileDir' end
    -- opts.readOnlyProfile: never write into the directory we were pointed at.  The
    -- offline test suite runs against the USER'S REAL vBot profile and must not touch it.
    if self.opts and self.opts.readOnlyProfile then return false, 'read-only profile' end
    local ok, err = self.config:saveStorage(self.storage)
    if not ok then
        self:error('storage save failed: %s', tostring(err))
        return false, err
    end
    self._storageDirty = false
    self.stats.storageSaves = self.stats.storageSaves + 1
    return true
end

--- REVIEW FIX: mutate the EXISTING table instead of replacing it.  bot/api.lua's sandbox
--- `storage`, bot/targetbot.lua and bot/loot.lua all capture `bot.storage` by reference;
--- swapping the table left them writing to an orphan that saveStorage() never persists.
function Bot:reloadStorage()
    local st, err = self.config:loadStorage()
    if st == nil then return nil, err end
    local cur = self.storage
    if type(cur) == 'table' and cur ~= st then
        for k in pairs(cur) do cur[k] = nil end
        for k, v in pairs(st) do cur[k] = v end
        local sh = config.shapeOf and config.shapeOf(st)
        if sh and config.setShape then config.setShape(cur, sh.kind, sh.order) end
        st = cur
    end
    self.storage = st
    if type(self.storage._macros)  ~= 'table' then self.storage._macros  = {} end
    if type(self.storage._configs) ~= 'table' then self.storage._configs = {} end
    return self.storage
end

-- ---------------------------------------------------------------------------
-- Config.setup's {enabled, selected} state (storage._configs, bot-core §4.3)
-- ---------------------------------------------------------------------------
function Bot:configState(dir)
    local c = self.storage._configs[dir]
    if type(c) ~= 'table' then
        c = { enabled = false, selected = '' }
        self.storage._configs[dir] = c
    end
    return c
end

function Bot:selectConfig(dir, name)
    local c = self:configState(dir)
    c.selected = name
    self._storageDirty = true
    return c
end

function Bot:setConfigEnabled(dir, on)
    local c = self:configState(dir)
    c.enabled = on and true or false
    self._storageDirty = true
    return c
end

-- ---------------------------------------------------------------------------
-- modules + arbitration
-- ---------------------------------------------------------------------------
function Bot:registerModule(name, instance)
    self.modules[name] = instance
    return instance
end

--- b:isActionAllowed(who) -> bool
---
--- The documented precedence (docs/vbot/cavebot.md + targetbot.md):
---
---   healbot   always allowed -- healing never yields.
---   attackbot always allowed.
---   targetbot always allowed -- it outranks CaveBot by construction.
---   cavebot   yields exactly when
---               TargetBot.isActive() and not TargetBot.isCaveBotActionAllowed()
---             which is cavebot.lua:81 verbatim.  TargetBot.isActive() is
---             `lastAction + 300 > now` (target.lua:182) -- i.e. it attacked or
---             looted within the last 300 ms -- and isCaveBotActionAllowed() is
---             `cavebotAllowance > now`, the window TargetBot.allowCaveBot(ms)
---             opens for close-luring (creature_attack.lua:148-159).
---
--- The TargetBot module only has to expose `isActive()` and
--- `isCaveBotActionAllowed()`; when it is absent or off, CaveBot is allowed.
function Bot:isActionAllowed(who)
    if who == 'cavebot' then
        local tb = self.modules.targetbot
        if not tb then return true end
        if tb.isOn and not tb:isOn() then return true end
        local active = tb.isActive and tb:isActive() or false
        if not active then return true end
        local allowed = tb.isCaveBotActionAllowed and tb:isCaveBotActionAllowed() or false
        return allowed and true or false
    end
    -- healbot / attackbot / targetbot / anything unknown
    return true
end

-- ---------------------------------------------------------------------------
-- status (BOT.md "Status object")
-- ---------------------------------------------------------------------------
local function modStatus(m)
    if not m then return nil end
    if m.status then
        local ok, s = pcall(m.status, m)
        if ok then return s end
    end
    return { on = (m.isOn and select(2, pcall(m.isOn, m))) or false }
end

function Bot:status()
    local st = self.state
    local pl = st and st.player or nil
    local s = {
        on = self:isOn(),
        now = self.now,
        profileDir = self.profileDir,
        vprofile = self.vprofile,
        stats = self.stats,
        player = pl and {
            hp = pl.health, maxHp = pl.maxHealth,
            mana = pl.mana, maxMana = pl.maxMana,
            level = pl.level, cap = pl.capacity,
            pos = pl.pos, states = pl.states,
        } or nil,
        healbot   = modStatus(self.modules.healbot),
        attackbot = modStatus(self.modules.attackbot),
        stances   = modStatus(self.modules.stances),
        cavebot   = modStatus(self.modules.cavebot),
        targetbot = modStatus(self.modules.targetbot),
        macros    = {},
        supplies  = modStatus(self.modules.supplies),
        schedules = #self._scheduler,
    }
    for i, m in ipairs(self._macros) do
        s.macros[i] = { name = m.name, enabled = m.enabled, timeout = m.timeout,
                        runs = m.runs, errors = m.errors,
                        delayed = self:isDelayed(m) }
    end
    return s
end

-- ---------------------------------------------------------------------------
-- module wiring (integration work item)
-- ---------------------------------------------------------------------------
--- b:wireModules(opts) -> b.modules
---
--- Builds the ONE world / path / walker the whole bot layer shares and then the four
--- modules, in BOT.md's registration order (== priority order == intra-tick send order):
---
---     healbot -> attackbot -> targetbot -> cavebot
---
--- Why one walker for CaveBot AND TargetBot: the walker owns the step ledger, the
--- confirmation retry and the walkCancel back-off.  Two instances would each keep their own
--- `expected` list, both would answer "not walking", and the character would be told to step
--- twice per server beat.  Sharing it makes `TB:walk`'s `if self:isWalking() then return end`
--- (targetbot.lua:827) the mutual exclusion between the two walking modules, and lets
--- CaveBot's delay rebinding (CB:_bindWalkerDelay) charge a TargetBot step to the CaveBot
--- macro -- which is exactly the arbitration BOT.md asks for.
---
--- healbot/attackbot register their macros in their constructors; targetbot and cavebot
--- register theirs in :attach(), which is called here, in order, after all four exist.
---
---   opts.cavebot / opts.targetbot   config base names (also accepted by bot.new)
---   opts.enableCavebot / opts.enableTargetbot   nil = leave the persisted state alone
---   opts.moduleOpts                 extra opts forwarded to every module constructor
---   opts.healbot / attackbot / targetbot / cavebot Opts   per-module opts overrides
--- A module whose constructor throws is logged and skipped; the rest still come up.
function Bot:wireModules(opts)
    opts = opts or {}
    if self._wired then return self.modules end
    self._wired = true

    local client = self.client
    if not (client and client.state) then
        self:error('wireModules: no client.state -- the bot layer needs a game state')
        return self.modules
    end

    local b = self
    local nowFn = function() return b.now end

    local okw, worldmod  = pcall(require, 'bot.world')
    local okp, pathmod   = pcall(require, 'bot.path')
    local okk, walkermod = pcall(require, 'bot.walker')
    if not (okw and okp and okk) then
        self:error('wireModules: cannot load bot.world/path/walker: %s',
                   tostring((not okw and worldmod) or (not okp and pathmod) or walkermod))
        return self.modules
    end

    if not self.world  then self.world  = worldmod.new(client, { known = opts.known }) end
    if not self.path   then self.path   = pathmod.new(client, self.world) end
    if not self.walker then
        self.walker = walkermod.new(client, { world = self.world, path = self.path,
                                              now = nowFn, config = opts.walkerConfig })
    end
    self.walker:attach()

    local base = { world = self.world, path = self.path, walker = self.walker, now = nowFn }
    local function mergedOpts(extra)
        local o = {}
        for k, v in pairs(base) do o[k] = v end
        for k, v in pairs(opts.moduleOpts or {}) do o[k] = v end
        for k, v in pairs(extra or {}) do o[k] = v end
        return o
    end

    local function build(name, modname, ctor)
        local okm, mod = pcall(require, modname)
        if not okm then
            self:error('wireModules: cannot load %s: %s', modname, tostring(mod))
            return nil
        end
        local oki, inst = pcall(ctor, mod)
        if not oki then
            self:error('wireModules: %s failed to construct: %s', name, tostring(inst))
            return nil
        end
        self:registerModule(name, inst)
        return inst
    end

    build('healbot', 'bot.healbot', function(m)
        return m.new(self, nil, mergedOpts(opts.healbotOpts))
    end)
    build('attackbot', 'bot.attackbot', function(m)
        return m.new(self, nil, mergedOpts(opts.attackbotOpts))
    end)
    -- work item N1: the fifth module.  Registers its own 200 ms macro in its
    -- constructor, like healbot/attackbot (always-allowed, never yields) --
    -- see bot/stances.lua's header.  Built here, after healbot/attackbot and
    -- before targetbot/cavebot, which sets its place in the macro list BOT.md's
    -- "As built" macro table documents.
    build('stances', 'bot.stances', function(m)
        return m.new(self, nil, mergedOpts(opts.stancesOpts))
    end)
    local tb = build('targetbot', 'bot.targetbot', function(m)
        return m.new(self, opts.targetbot, mergedOpts(opts.targetbotOpts))
    end)
    local cb = build('cavebot', 'bot.cavebot', function(m)
        return m.new(self, opts.cavebot, mergedOpts(opts.cavebotOpts))
    end)
    if cb and cb.supplies then self:registerModule('supplies', cb.supplies) end

    -- macro registration order: targetbot then cavebot, after healbot/attackbot's ctors
    if tb and tb.attach then pcall(tb.attach, tb) end
    if cb and cb.attach then pcall(cb.attach, cb) end

    if tb and opts.enableTargetbot ~= nil then
        if opts.enableTargetbot then tb:setOn() else tb:setOff() end
    end
    if cb and opts.enableCavebot ~= nil then
        if opts.enableCavebot then cb:enable() else cb:disable() end
    end

    self:info('modules wired: %s (world %s)',
              table.concat({ 'healbot', 'attackbot', 'stances', 'targetbot', 'cavebot' }, ', '),
              tostring(self.world and self.world.itemDataLevel))
    return self.modules
end

--- Drop the shared walker's event hooks.  Called from stop(); safe to call twice.
function Bot:unwireModules()
    if self.walker and self.walker.detach then pcall(self.walker.detach, self.walker) end
    local tb = self.modules.targetbot
    if tb and tb.detach then pcall(tb.detach, tb) end
end

bot.Bot    = Bot
bot.config = config
bot.api    = api
return bot
