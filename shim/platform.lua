--[[============================================================================
shim/platform.lua -- the otclient platform singletons, headless.

    local platform = require('shim.platform')
    local P = platform.install(G, { app = LC, version = '3.0', os = 'windows' })
    -- G.g_clock, G.g_logger, G.g_platform, G.g_window, G.g_keyboard, G.g_mouse,
    -- G.g_sounds, G.g_app, G.g_crypt, G.print, G.pinfo/pwarning/perror/pdebug,
    -- G.tr, G.LogFine..G.LogFatal, G.retranslateKeyComboDesc
    platform.beginTick()        -- ONCE at the top of every bot tick  (invariant I5)

WHAT IT REPLACES
  g_clock    src/framework/core/clock.h            (luafunctions.cpp:176-181)
  g_logger   src/framework/core/logger.h           (luafunctions.cpp:194-205)
  g_platform src/framework/platform/platform.h     (luafunctions.cpp:117-139)
  g_app      src/framework/core/application.h      (luafunctions.cpp:142-160)
  g_crypt    src/framework/util/crypt.h            (luafunctions.cpp:163-173)
  g_window / g_keyboard / g_mouse / g_sounds -- graphics- and input-bound singletons
  that cannot exist in a headless worker.

THE THREE FIDELITY POINTS THAT MATTER

  I5  `g_clock.millis()` IS FRAME-QUANTISED.  Clock::millis() returns m_currentMillis,
      an integer refreshed once per application frame by Clock::update(); it is
      CONSTANT for the whole bot tick.  `executor.lua:196-197` copies it into
      `context.now` / `context.time`, and vBot compares `now - x` in hundreds of
      places.  Making it a live read would let `context.now` and an in-tick
      `g_clock.millis()` disagree and would make `game_cooldown`'s own comparisons
      drift.  So: `millis()` returns a cached INTEGER, refreshed only by
      `platform.beginTick()`.  `realMillis()` is the live wall clock -- the only two
      consumers are the "Slow macro (Nms)" warnings in functions/main.lua and
      functions/callbacks.lua, which need real elapsed time.

  Logging is the shim's ONLY diagnostic channel.  vBot calls the sandbox `warn()`,
  `error()` and `info()` constantly, and those land on g_logger via bot.lua:355,509-517.
  corelib's `print` joins its arguments with FOUR SPACES, not a tab (util.lua:2-13),
  and logs at LogInfo -- ~90 call sites across the profile depend on nothing more.

  Everything that cannot work headless is a RECORDING stub, never a lie.  Each such
  call is counted in `platform.record` (name -> {n=, last={args}}) so a test can prove
  a code path was reached and `platform.report()` can list what vBot asked for that
  this process could not do.  Nothing here invents a plausible-looking return value:
  `g_window.getMousePosition()` is `{x=0,y=0}` because there IS no cursor, and
  `g_keyboard.isKeyPressed()` is `false` because no key can be down.

PER-SYMBOL VERDICTS (docs/shim/api-platform.md section 3)
  g_clock.millis/realMillis          REAL
  g_clock.micros/realMicros/seconds  REAL (0 call sites, cheap to do properly)
  g_logger.*                         REAL, onto lib/log.lua
  print/pinfo/pwarning/perror/pdebug REAL
  tr                                 REAL -- it is exactly string.format in this fork
  g_platform.openUrl/openDir         INERT, recorded (no browser, no file manager)
  g_platform.getOSName/isMobile/...  STATEFUL (constant), recorded
  g_window.setTitle                  INERT, recorded; forwarded to opts.onTitle when given
  g_window.setClipboardText          STATEFUL (kept, readable by getClipboardText)
  g_window.flash                     INERT.  NOTE: this method DOES NOT EXIST in this
                                     otclient fork, so `vBot/alarms.lua:128` throws in
                                     the live client whenever flashClient is enabled on
                                     Windows.  Providing a no-op is a FIX, not a
                                     regression (docs/shim B6).
  g_window.getMousePosition          INERT -> {x=0,y=0}; getTileUnderCursor then nil
  g_window.isKeyPressed              INERT -> false
  g_keyboard.isKeyPressed            INERT -> false.  `vBot/Equipper.lua:590` condition
                                     type 9 ("key pressed") therefore never fires (B2).
  g_keyboard.isCtrlPressed           INERT -> false
  g_mouse                            empty table + recording stubs (0 call sites)
  g_sounds.getChannel(...)           INERT channel object.  NOTE: `SoundChannels`
                                     (corelib/const.lua:338-342) defines Music/Ambient/
                                     Effect and NO `Bot`, so bot.lua:153 already passes
                                     nil in the live client -- audio is dead there too (B5).
  g_app.getOs                        STATEFUL -> opts.os, default 'windows'
  g_app.getVersion/getName/...       STATEFUL
  g_app.doScreenshot                 INERT, recorded
  g_app.exit/restart                 forwarded to opts.onExit when given, else recorded
  g_crypt.genUUID/sha256/crc32       REAL (lib/sys, lib/sha2, and a table-free CRC-32)
  g_crypt.get/setMachineUUID         STATEFUL
  g_crypt.encrypt/decrypt/rsa*       RAISE -- they are keyed on a machine UUID and an
                                     RSA context this process does not have, and a
                                     wrong ciphertext is worse than a loud failure.
                                     ZERO call sites in the executed corpus.
  retranslateKeyComboDesc            REAL enough: canonicalises the combo string the
                                     way corelib/keyboard.lua:113-135 does (alias
                                     resolution, Ctrl/Meta/Alt/Shift ordering,
                                     KeyCodeDescs spelling).  It is only ever used as a
                                     table key, and the profile has exactly ONE caller
                                     (`vBot/extras.lua:209`, default "space").
============================================================================]]

local sys = require('lib.sys')

local platform = {}

-- ===========================================================================
-- 0. the recorder
-- ===========================================================================
-- Every inert/stateful stub logs itself here so a test can assert "vBot asked for X"
-- and so platform.report() can print what this process could not honour.

platform.record = {}

local function rec(name, ...)
    local e = platform.record[name]
    if not e then e = { n = 0 }; platform.record[name] = e end
    e.n = e.n + 1
    e.last = { n = select('#', ...), ... }
    return e
end
platform.rec = rec

function platform.resetRecord() platform.record = {} end

--- Sorted "name  count" lines for everything that was stubbed.
function platform.report()
    local names = {}
    for k in pairs(platform.record) do names[#names + 1] = k end
    table.sort(names)
    local out = {}
    for i = 1, #names do
        out[i] = ('%-34s %d'):format(names[i], platform.record[names[i]].n)
    end
    return out
end

-- ===========================================================================
-- 1. g_clock  (invariant I5)
-- ===========================================================================

local floor = math.floor
local baseMs = sys.nowMs()          -- process start; millis() counts from here, as
                                    -- Clock does from application start
local cachedMs = 0

--- Refresh the frame-quantised clock.  Call ONCE at the top of every bot tick, before
--- `context.now = context.time = g_clock.millis()`.  Returns the new value.
function platform.beginTick()
    cachedMs = floor(sys.nowMs() - baseMs)
    return cachedMs
end

--- Force a specific quantised value.  Used by the test suite's fake clock.
function platform.setClock(ms)
    cachedMs = floor(ms)
    return cachedMs
end

function platform.currentMillis() return cachedMs end

local g_clock = {
    millis      = function() return cachedMs end,
    micros      = function() return cachedMs * 1000 end,
    seconds     = function() return cachedMs / 1000 end,
    realMillis  = function() return floor(sys.nowMs() - baseMs) end,
    realMicros  = function() return floor((sys.nowMs() - baseMs) * 1000) end,
}

-- ===========================================================================
-- 2. g_logger + print + p*
-- ===========================================================================

local LOG_LEVELS = { [0] = 'debug',   -- LogFine    -> lib/log has no 'fine'
                     [1] = 'debug',   -- LogDebug
                     [2] = 'info',    -- LogInfo
                     [3] = 'warn',    -- LogWarning
                     [4] = 'error',   -- LogError
                     [5] = 'error' }  -- LogFatal

local function makeLogger()
    local log = require('lib.log')
    local levelValue = 1                     -- LogDebug, as Logger's default
    local onLog = nil

    local function emit(level, msg)
        msg = tostring(msg)
        if onLog then pcall(onLog, level, msg, false) end
        if level < levelValue then return end
        local fn = log[LOG_LEVELS[level] or 'info']
        -- '%%'-safe: lib/log uses the first argument verbatim when no varargs follow
        fn(msg)
    end

    return {
        log             = function(level, msg) emit(tonumber(level) or 2, msg) end,
        debug           = function(msg) emit(1, msg) end,
        info            = function(msg) emit(2, msg) end,
        warning         = function(msg) emit(3, msg) end,
        error           = function(msg) emit(4, msg) end,
        fatal           = function(msg) emit(5, msg) end,
        setLevel        = function(l) levelValue = tonumber(l) or 1 end,
        getLevel        = function() return levelValue end,
        setLogFile      = function(path) return log.setFile(path) end,
        setOnLog        = function(fn) onLog = fn end,
        fireOldMessages = function() rec('g_logger.fireOldMessages') end,
    }, emit
end

-- ===========================================================================
-- 3. retranslateKeyComboDesc  (corelib/keyboard.lua:10-135)
-- ===========================================================================
-- KeyCodeDescs (corelib/const.lua:207-...) mapped by canonical SPELLING; the numeric
-- key codes are irrelevant here because the result is only ever used as a table key.

local KEY_DESCS = {}
do
    local names = {
        'Unknown', 'Escape', 'Tab', 'Backspace', 'Enter', 'Insert', 'Delete', 'Pause',
        'PrintScreen', 'Home', 'End', 'PageUp', 'PageDown', 'Up', 'Down', 'Left',
        'Right', 'NumLock', 'ScrollLock', 'CapsLock', 'Ctrl', 'Shift', 'Alt',
        'Control', 'Meta', 'Menu', 'Space', 'Plus',
        'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12',
        'Numpad0', 'Numpad1', 'Numpad2', 'Numpad3', 'Numpad4', 'Numpad5',
        'Numpad6', 'Numpad7', 'Numpad8', 'Numpad9',
    }
    for i = 1, #names do KEY_DESCS[names[i]:lower()] = names[i] end
    for b = 33, 126 do                      -- the printable singles, incl. A-Z 0-9
        local c = string.char(b)
        KEY_DESCS[c:lower()] = c:upper()
    end
    -- corelib spells these two out rather than using the raw character
    KEY_DESCS['+'] = 'Plus'
    KEY_DESCS[' '] = 'Space'
end

--- resolveKeyAlias (keyboard.lua:10-41), non-macOS branch.
local KEY_ALIASES = {
    cmd = 'Meta', command = 'Meta', primary = 'Ctrl', ctrl = 'Ctrl',
    control = 'Ctrl', alt = 'Alt', option = 'Alt',
    meta = 'Meta', win = 'Meta', super = 'Meta',
}

--- Canonicalise a key-combo description the way the live client does:
--- split on '+', resolve aliases, order Ctrl -> Meta -> Alt -> Shift -> main key
--- (canonicalizeKeyCombo, keyboard.lua:44-84), join with '+' (translateKeyCombo).
--- Unlike the C++ this never returns nil for an unknown key: it keeps the token as
--- typed and records the miss, because dropping it would silently unbind a hotkey.
function platform.retranslateKeyComboDesc(desc)
    if desc == nil then error('Unable to translate key combo \'nil\'', 2) end
    if type(desc) == 'number' then desc = tostring(desc) end

    local hasCtrl, hasMeta, hasAlt, hasShift, main = false, false, false, false, nil
    for token in desc:gmatch('[^+]+') do          -- string.split drops empties too
        local t = token:match('^%s*(.-)%s*$')
        if t ~= '' then
            local alias = KEY_ALIASES[t:lower()]
            local name  = alias or KEY_DESCS[t:lower()]
            if not name then
                rec('retranslateKeyComboDesc:unknown', t)
                name = t
            end
            if     name == 'Ctrl'  then hasCtrl  = true
            elseif name == 'Meta'  then hasMeta  = true
            elseif name == 'Alt'   then hasAlt   = true
            elseif name == 'Shift' then hasShift = true
            else   main = name end
        end
    end

    local parts = {}
    if hasCtrl  then parts[#parts + 1] = 'Ctrl'  end
    if hasMeta  then parts[#parts + 1] = 'Meta'  end
    if hasAlt   then parts[#parts + 1] = 'Alt'   end
    if hasShift then parts[#parts + 1] = 'Shift' end
    if main     then parts[#parts + 1] = main    end
    if #parts == 0 then return nil end
    return table.concat(parts, '+')
end

-- ===========================================================================
-- 4. g_crypt
-- ===========================================================================

local CRC32_TABLE
local function crc32(s)
    local bit = require('bit')
    if not CRC32_TABLE then
        CRC32_TABLE = {}
        for i = 0, 255 do
            local c = i
            for _ = 1, 8 do
                if bit.band(c, 1) ~= 0 then c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
                else c = bit.rshift(c, 1) end
            end
            CRC32_TABLE[i] = c
        end
    end
    local crc = bit.bnot(0)
    for i = 1, #s do
        crc = bit.bxor(CRC32_TABLE[bit.band(bit.bxor(crc, s:byte(i)), 0xFF)], bit.rshift(crc, 8))
    end
    crc = bit.bnot(crc)
    return crc % 4294967296        -- Crypt::crc32 returns an unsigned 32-bit value
end

local function makeCrypt()
    local machineUUID = ''
    local function notHere(name)
        return function()
            error(('g_crypt.%s is not implemented in the headless shim: it is keyed on '
                .. 'a machine UUID / RSA context this process does not have, and a wrong '
                .. 'result is worse than a loud failure. There are ZERO call sites in '
                .. 'vBot 4.8 or mods/game_bot.'):format(name), 2)
        end
    end
    return {
        genUUID = function()
            -- RFC 4122 v4, from the OS CSPRNG (Crypt::genUUID uses boost::uuids::random)
            local b = { sys.randomBytes(16):byte(1, 16) }
            local bit = require('bit')
            b[7] = bit.bor(bit.band(b[7], 0x0F), 0x40)
            b[9] = bit.bor(bit.band(b[9], 0x3F), 0x80)
            local hex = {}
            for i = 1, 16 do hex[i] = ('%02x'):format(b[i]) end
            return table.concat(hex, '', 1, 4) .. '-' .. table.concat(hex, '', 5, 6)
                .. '-' .. table.concat(hex, '', 7, 8) .. '-' .. table.concat(hex, '', 9, 10)
                .. '-' .. table.concat(hex, '', 11, 16)
        end,
        setMachineUUID = function(v) machineUUID = tostring(v or '') end,
        getMachineUUID = function() return machineUUID end,
        sha256 = function(s) return require('lib.sha2').sha256hex(tostring(s)) end,
        crc32  = function(s) return crc32(tostring(s)) end,
        encrypt        = notHere('encrypt'),
        decrypt        = notHere('decrypt'),
        rsaSetPublicKey  = notHere('rsaSetPublicKey'),
        rsaSetPrivateKey = notHere('rsaSetPrivateKey'),
        rsaGetSize       = notHere('rsaGetSize'),
    }
end

-- ===========================================================================
-- 5. install
-- ===========================================================================

--- install(G [, opts]) -> table of the singletons it created
---   opts.os        : g_app.getOs()      default 'windows'  (vBot/alarms.lua:127)
---   opts.version   : g_app.getVersion() default '3.0'
---   opts.name      : g_app.getName()    default 'otclient_web'
---   opts.onTitle   : fn(text)  -- g_window.setTitle forwards here (control-plane line)
---   opts.onExit    : fn(code)  -- g_app.exit / quit forward here
function platform.install(G, opts)
    opts = opts or {}
    if type(G) ~= 'table' then error('platform.install: G must be a table', 2) end

    local logger, emit = makeLogger()

    -- --------------------------------------------------------- log levels ---
    G.LogFine, G.LogDebug, G.LogInfo = 0, 1, 2
    G.LogWarning, G.LogError, G.LogFatal = 3, 4, 5

    -- ------------------------------------------------------------ g_clock ---
    G.g_clock = g_clock

    -- ----------------------------------------------------------- g_logger ---
    G.g_logger = logger

    -- corelib/util.lua:2-32.  print joins with FOUR SPACES and logs at LogInfo.
    G.print = function(...)
        local args, n = { ... }, select('#', ...)
        local parts = {}
        for i = 1, n do parts[i] = tostring(args[i]) end
        emit(2, table.concat(parts, '    '))
    end
    G.pinfo    = function(msg) emit(2, msg) end
    G.perror   = function(msg) emit(4, msg) end
    G.pwarning = function(msg) emit(3, msg) end
    G.pdebug   = function(msg) emit(1, msg) end
    G.fatal    = function(msg) emit(5, msg) end

    -- corelib/util.lua:355-357 -- `tr` is EXACTLY string.format in this fork; no
    -- locale module overrides it anywhere in the tree.
    G.tr = function(s, ...)
        if select('#', ...) == 0 then return s end
        return string.format(s, ...)
    end

    -- --------------------------------------------------------- g_platform ---
    local g_platform = {
        openUrl   = function(url) rec('g_platform.openUrl', url); return false end,
        openDir   = function(dir) rec('g_platform.openDir', dir); return false end,
        getOSName = function() return sys.os end,
        getOsShortName = function() return sys.isWindows and 'win' or 'linux' end,
        getDevice = function() return { type = 1, os = 1 } end,
        getDeviceShortName = function() return 'pc' end,
        isDesktop = function() return true end,
        isMobile  = function() return false end,
        isBrowser = function() return false end,
        isConsole = function() return false end,
        getProcessId = function() rec('g_platform.getProcessId'); return 0 end,
        isProcessRunning = function(n) rec('g_platform.isProcessRunning', n); return false end,
        killProcess = function(n) rec('g_platform.killProcess', n); return false end,
        spawnProcess = function(n) rec('g_platform.spawnProcess', n); return false end,
        getTempPath = function() return (sys.getEnv('TEMP') or '/tmp') .. '/' end,
        getCPUName  = function() return 'unknown' end,
        getTotalSystemMemory = function() return 0 end,
        getMemoryUsage = function() return collectgarbage('count') * 1024 end,
        getFileModificationTime = function(p) rec('g_platform.getFileModificationTime', p); return 0 end,
        copyFile   = function(a, b) rec('g_platform.copyFile', a, b); return false end,
        fileExists = function(p) local f = io.open(p, 'rb'); if f then f:close(); return true end; return false end,
        removeFile = function(p) rec('g_platform.removeFile', p); return os.remove(p) and true or false end,
    }
    G.g_platform = g_platform

    -- ----------------------------------------------------------- g_window ---
    local clipboard = ''
    local title = ''
    local g_window = {
        setTitle = function(t)
            title = tostring(t or '')
            rec('g_window.setTitle', title)
            if opts.onTitle then pcall(opts.onTitle, title) end
        end,
        getTitle = function() return title end,
        setClipboardText = function(t)
            clipboard = tostring(t or '')
            rec('g_window.setClipboardText', clipboard)
        end,
        getClipboardText = function() return clipboard end,
        -- B6: `flash` does not exist in this otclient fork, so alarms.lua:128 throws in
        -- the live client.  A no-op here is a fix.
        flash = function() rec('g_window.flash') end,
        getMousePosition = function() rec('g_window.getMousePosition'); return { x = 0, y = 0 } end,
        isKeyPressed = function(k) rec('g_window.isKeyPressed', k); return false end,
        isMouseButtonPressed = function(b) rec('g_window.isMouseButtonPressed', b); return false end,
        setKeyDelay = function(d) rec('g_window.setKeyDelay', d) end,
        getWidth  = function() return 0 end,
        getHeight = function() return 0 end,
        getSize   = function() return { width = 0, height = 0 } end,
        getDisplayWidth  = function() return 0 end,
        getDisplayHeight = function() return 0 end,
        isVisible = function() return false end,
        isFullscreen = function() return false end,
        setFullscreen = function(v) rec('g_window.setFullscreen', v) end,
        show = function() rec('g_window.show') end,
        hide = function() rec('g_window.hide') end,
        maximize = function() rec('g_window.maximize') end,
    }
    G.g_window = g_window

    -- --------------------------------------------------------- g_keyboard ---
    -- B2: no keyboard exists headless.  Everything is false; the bindings record and
    -- never fire.  Live impact: `vBot/extras.lua:209` useAll hotkey and
    -- `vBot/Equipper.lua:590` condition type 9.
    local g_keyboard = {
        isKeyPressed   = function(k) rec('g_keyboard.isKeyPressed', k); return false end,
        isKeySetPressed = function(k) rec('g_keyboard.isKeySetPressed', k); return false end,
        isCtrlPressed  = function() rec('g_keyboard.isCtrlPressed');  return false end,
        isShiftPressed = function() rec('g_keyboard.isShiftPressed'); return false end,
        isAltPressed   = function() rec('g_keyboard.isAltPressed');   return false end,
        getModifiers   = function() return 0 end,
        setKeyDelay    = function(d) rec('g_keyboard.setKeyDelay', d) end,
        bindKeyDown    = function(c) rec('g_keyboard.bindKeyDown', c) end,
        bindKeyUp      = function(c) rec('g_keyboard.bindKeyUp', c) end,
        bindKeyPress   = function(c) rec('g_keyboard.bindKeyPress', c) end,
        unbindKeyDown  = function(c) rec('g_keyboard.unbindKeyDown', c) end,
        unbindKeyUp    = function(c) rec('g_keyboard.unbindKeyUp', c) end,
        unbindKeyPress = function(c) rec('g_keyboard.unbindKeyPress', c) end,
    }
    G.g_keyboard = g_keyboard
    G.retranslateKeyComboDesc = platform.retranslateKeyComboDesc
    -- determineKeyComboDesc is INERT by design: the shim never delivers key events, so
    -- executor.lua:224,246,258 is unreachable.  It exists so a stray call is a recorded
    -- no-op rather than a nil-call crash.
    G.determineKeyComboDesc = function(code, mods)
        rec('determineKeyComboDesc', code, mods)
        return nil
    end

    -- ------------------------------------------------------------ g_mouse ---
    -- 0 call sites in the profile and in the runtime; present so `context.g_mouse`
    -- (executor.lua:137) is not nil.
    local g_mouse = {
        isPressed = function() rec('g_mouse.isPressed'); return false end,
        getPosition = function() rec('g_mouse.getPosition'); return { x = 0, y = 0 } end,
        pushCursor = function(c) rec('g_mouse.pushCursor', c) end,
        popCursor  = function(c) rec('g_mouse.popCursor', c) end,
        bindAutoPress = function() rec('g_mouse.bindAutoPress') end,
    }
    G.g_mouse = g_mouse

    -- ----------------------------------------------------------- g_sounds ---
    -- B5: audio is already dead in the live client (SoundChannels has no `Bot` key, so
    -- bot.lua:153 passes nil).  A channel object with the full no-op surface keeps
    -- functions/sound.lua:15-27 and vBot/alarms.lua:131 from crashing.
    local function newChannel(id)
        return {
            play       = function(f, fade, gain) rec('soundChannel.play', id, f, fade, gain) end,
            stop       = function(fade) rec('soundChannel.stop', id, fade) end,
            enqueue    = function(f, fade, gain) rec('soundChannel.enqueue', id, f, fade, gain) end,
            setEnabled = function(v) rec('soundChannel.setEnabled', id, v) end,
            isEnabled  = function() return false end,
            setGain    = function(v) rec('soundChannel.setGain', id, v) end,
            getGain    = function() return 0 end,
            setPitch   = function(v) rec('soundChannel.setPitch', id, v) end,
        }
    end
    local channels = {}
    local g_sounds = {
        getChannel = function(id)
            rec('g_sounds.getChannel', id)
            local k = id == nil and '<nil>' or tostring(id)
            if not channels[k] then channels[k] = newChannel(k) end
            return channels[k]
        end,
        play        = function(f, fade, gain) rec('g_sounds.play', f, fade, gain) end,
        stopAll     = function() rec('g_sounds.stopAll') end,
        enableAudio = function() rec('g_sounds.enableAudio') end,
        disableAudio = function() rec('g_sounds.disableAudio') end,
        isAudioEnabled = function() return false end,
        preload     = function(f) rec('g_sounds.preload', f) end,
    }
    G.g_sounds = g_sounds

    -- -------------------------------------------------------------- g_app ---
    local appVersion = opts.version or '3.0'
    local appName    = opts.name or 'otclient_web'
    local appOs      = opts.os or 'windows'
    local g_app = {
        getOs        = function() return appOs end,
        getVersion   = function() return appVersion end,
        getName      = function() return appName end,
        getCompactName = function() return appName end,
        setName      = function(v) appName = tostring(v) end,
        setCompactName = function(v) rec('g_app.setCompactName', v) end,
        setOrganizationName = function(v) rec('g_app.setOrganizationName', v) end,
        isRunning    = function() return true end,
        isStopping   = function() return false end,
        getBuildCompiler = function() return 'luajit' end,
        getBuildDate     = function() return '' end,
        getBuildRevision = function() return '' end,
        getBuildCommit   = function() return '' end,
        getBuildType     = function() return 'shim' end,
        getBuildArch     = function() return jit and jit.arch or '?' end,
        getStartupOptions = function() return {} end,
        doScreenshot = function(f) rec('g_app.doScreenshot', f); return false end,
        exit    = function() rec('g_app.exit'); if opts.onExit then opts.onExit(0) end end,
        quit    = function() rec('g_app.quit'); if opts.onExit then opts.onExit(0) end end,
        restart = function() rec('g_app.restart'); if opts.onExit then opts.onExit(1) end end,
    }
    G.g_app = g_app
    G.exit = function() g_app.exit() end          -- corelib/util.lua:34-40
    G.quit = function() g_app.quit() end

    -- ------------------------------------------------------------ g_crypt ---
    G.g_crypt = makeCrypt()

    platform.beginTick()

    return {
        g_clock = g_clock, g_logger = logger, g_platform = g_platform,
        g_window = g_window, g_keyboard = g_keyboard, g_mouse = g_mouse,
        g_sounds = g_sounds, g_app = g_app, g_crypt = G.g_crypt,
    }
end

return platform
