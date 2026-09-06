--[[============================================================================
main.lua -- entry point, CLI, module wiring and the boot sequence.

  run.bat --account=you@example.com --password=... --character="Char Name"

Boot order (API.md, and the ordering constraints the module agents flagged):

  parse flags
    -> package.path
    -> load proto/items.lua           (the parser cannot decode a tile without it)
    -> HTTPS account login            (proto/login_http via proto/handshake)
    -> pick world + character
    -> transport.new{worldName=...}   world name is set BEFORE connect()
    -> connect (async) -> raw "<world>\n" preamble
    -> server 0x1F challenge  -> buildLoginPacket -> transport:send()  (seq 0, XTEA OFF)
                              -> transport:enableXtea(key)   AFTER the packet is queued
    -> server 0x0A pending    -> the TWO enter-game frames, sent separately (seq 1, 2)
    -> server 0x0A/0x17...    -> gameStart; arm the 10 s keepalive ping
    -> sched.run() parse loop

Ping rules (docs/state-events.md §14, GameClientPing ON at 1530):
  * server 0x1E is the PONG for our ping  -> latency sample only
  * server 0x1D is a ping REQUEST         -> we must answer immediately with
    opcode 28 (ClientPingBackGunz, because OS is 61 and cv >= 1200)
  * our own keepalive is opcode 29 (ClientPing) every 10 s.

The only global is `_G.LC` (API.md).
============================================================================]]

io.stdout:setvbuf('line')

-- ---------------------------------------------------------------- package.path
local SCRIPT_DIR
do
    local src = debug.getinfo(1, 'S').source
    if src:sub(1, 1) == '@' then
        SCRIPT_DIR = src:sub(2):match('^(.*)[/\\][^/\\]*$')
    end
    SCRIPT_DIR = (SCRIPT_DIR or '.'):gsub('\\', '/')
    package.path = SCRIPT_DIR .. '/?.lua;' .. SCRIPT_DIR .. '/?/init.lua;' .. package.path
end

-- =============================================================== CLI parsing
local USAGE = [[
luaclient -- standalone LuaJIT worker client for Gunzodus (protocol 1530, OS 61)

  run.bat [flags]                (or: luajit main.lua [flags])

Account / session
  --account=EMAIL          account (email) for the HTTPS login
  --password=PASS          account password        (never logged)
  --token=DIGITS           authenticator token, when the account has 2FA
  --character=NAME         character to enter with (default: the first one)
  --session-key=KEY        skip the HTTPS login and use this session key
                           (needs --character and --host=HOST:PORT)
  --world=NAME             restrict the character choice to this world
  --host=HOST[:PORT]       override the game-server address from the login reply
  --port=N                 override the game-server port

Runtime
  --assets=DIR             directory holding items1530.bin (default: ./assets)
  --content-revision=N     override the login packet's content revision string
  --log-level=LEVEL        debug | info | warn | error          (default: info)
  --log-file=PATH          append every log line to PATH as well
  --capture=PATH           append every inbound payload as a .cam '<' record
  --ping=MS                keepalive interval in ms             (default: 10000)
  --exit-after=SECONDS     disconnect cleanly and exit 0 after N seconds in game
                           (live testing: bounds a run without killing the socket)

Bot layer (vBot 4.8 behaviour: HealBot, AttackBot, CaveBot, TargetBot)
  --bot                    enable the bot layer once the game has started
  --bot-profile=DIR        vBot profile directory (HealBot.json, cavebot_configs/,
                           targetbot_configs/, storage/ ...).  Default: the vBot_4.8
                           profile next to this checkout when it exists, else ./profiles
  --bot-vprofile=N         vBot_configs/profile_<N> and storage/profile_<N>.json (1)
  --cavebot=NAME           cavebot_configs/<NAME>.cfg -- selects it AND enables CaveBot
  --targetbot=NAME         targetbot_configs/<NAME>.json -- selects it AND enables it
  --bot-status-interval=MS one-line bot status at info level (default 5000, 0 = off)
  --minimap=PATH           OTMM minimap to use as the pathfinder's knowledge of the
                           world outside the aware area.  Defaults to the reference
                           client's profiles/minimap.otmm when that file exists.
                           Read-only, never written.  --minimap=off disables it.

vBot compatibility shim (docs/shim/COMPAT.md) -- runs the REAL vBot 4.8 scripts
  --vbot                   run the user's real vBot tree through the otclient
                           compatibility shim instead of the native bot layer.
                           Mutually exclusive with --bot / --cavebot / --targetbot.
  --vbot-profile=DIR       the /bot/<config> directory to run, e.g.
                           .../otclient/profiles/bot/vBot_4.8.  Implies --vbot.
                           The otclient checkout, the g_resources write dir and the
                           config name are all derived from it.
  --vbot-otroot=DIR        override the otclient checkout (READ-ONLY) the shim reads
                           mods/game_bot and modules/ from
  --vbot-vprofile=N        storage/profile_<N>.json    (default: --bot-vprofile, else 1)
  --vbot-tick=MS           the executor tick in ms                    (default 10)
  --vbot-strict            a missing API raises instead of returning an inert stub
  --vbot-safe              LIVE SMOKE TEST MODE.  Boots and ticks the whole vBot tree
                           exactly as normal, but turns AttackBot, TargetBot and
                           CaveBot OFF the moment the tree is up, so the session
                           never attacks anything and never auto-walks a hunting
                           route.  HealBot is deliberately left ON (it protects the
                           character and starts no fight).  Nothing is persisted --
                           the shim is read-only unless --vbot-write is given, and
                           --vbot-safe does not imply --vbot-write.
  --vbot-write             allow the bot to write its own storage/configs back into
                           the profile.  OFF by default: the shim runs read-only and
                           records every refused write, so a shim bug cannot corrupt
                           a config the real vBot still has to read.

Proxy (PANEL.md "Proxy support")
  --proxy=HOST:PORT        tunnel the game socket through this HTTP CONNECT proxy
                           and send the HTTPS login POST through it as well
  --proxy-auth             read "user:pass" for the proxy from STDIN (one line)
  --proxy-auth=@PATH       ... from a file (first line)
  --proxy-auth=fd:N        ... from file descriptor N (0 = stdin)
                           An inline --proxy-auth=user:pass is REFUSED: argv is
                           world-readable in /proc and visible to `ps`.

Control endpoint (the hub talks to the worker over this; PANEL.md)
  --control-port=N         start the JSON control endpoint on this port.  0 =
                           ephemeral, which is the default once a token is given;
                           the port it settled on is announced on stdout as
                           "control-endpoint <bind> <port> <instance>"
  --control-bind=ADDR      address to bind (default 127.0.0.1).  A non-loopback
                           address additionally needs --control-allow-remote.
  --control-allow-remote   permit a non-loopback bind.  Say this out loud.
  --control-token-file=P   read the endpoint's auth token from this file
  --control-token-fd=N     read it from file descriptor N.  0 = stdin, which is
                           the portable choice; N > 0 needs /dev/fd (POSIX only).
                           Several stdin-fed flags consume lines in the order the
                           flags appear on the command line.
  --instance-name=NAME     the name the panel shows for this worker

Modes
  --dry-run                offline: no sockets, no HTTPS; exercises the whole
                           wiring (items, login packet, framing, parser, events).
                           With --control-port it stays up and serves the control
                           endpoint, which is how test/controlsuite.lua drives it.
  --selftest               run test/selftest.lua and exit with its status
  --replay=FILE            run test/replay.lua over FILE and exit
  -h, --help               this text

Exit codes: 0 ok, 1 usage/config error, 2 login refused by the server,
            3 protocol/runtime failure.
]]

-- Secrets never travel in argv (lib/process.lua "SECRETS IN argv"): a flag that names
-- one records a READER here, and the readers are drained after parsing, in the order
-- the flags appeared, so two stdin-fed secrets cannot race for the same first line.
local function readFirstLine(path)
    local f, err = io.open(path, 'r')
    if not f then return nil, ('cannot open %s: %s'):format(tostring(path), tostring(err)) end
    local line = f:read('*l')
    f:close()
    if not line then return nil, ('%s is empty'):format(tostring(path)) end
    return (line:gsub('%s+$', ''))
end

local function readFd(n)
    n = tonumber(n)
    if n == 0 then
        local line = io.stdin:read('*l')
        if not line then return nil, 'stdin closed before the secret arrived' end
        return (line:gsub('%s+$', ''))
    end
    -- POSIX exposes every inherited descriptor here; Windows does not.
    return readFirstLine('/dev/fd/' .. tostring(n))
end

local function parseArgs(argv)
    local cfg = {
        logLevel = 'info',
        pingMs   = 10000,
        secretReaders = {},          -- { {field=, read=function() -> value, err} }
    }
    local i = 1
    local function valueOf(name, inlineValue)
        if inlineValue then return inlineValue end
        i = i + 1
        local v = argv[i]
        if v == nil then
            return nil, ('--%s needs a value'):format(name)
        end
        return v
    end

    while i <= #argv do
        local a = argv[i]
        local name, inline = a:match('^%-%-([%w%-]+)=(.*)$')
        if not name then name = a:match('^%-%-([%w%-]+)$') end
        if a == '-h' then name = 'help' end

        if not name then
            return nil, ('unexpected argument %q'):format(a)
        end

        local v, err
        if name == 'account' or name == 'password' or name == 'token'
        or name == 'character' or name == 'world' or name == 'host'
        or name == 'assets' or name == 'log-level' or name == 'log-file'
        or name == 'capture' or name == 'port' or name == 'ping'
        or name == 'exit-after'
        or name == 'content-revision' or name == 'replay' or name == 'login-url'
        or name == 'bot-profile' or name == 'bot-vprofile' or name == 'cavebot'
        or name == 'targetbot' or name == 'bot-status-interval' or name == 'minimap'
        or name == 'session-key'
        or name == 'proxy' or name == 'control-port' or name == 'control-bind'
        or name == 'control-token-file' or name == 'control-token-fd'
        or name == 'vbot-profile' or name == 'vbot-otroot'
        or name == 'vbot-vprofile' or name == 'vbot-tick'
        or name == 'instance-name' then
            v, err = valueOf(name, inline)
            if not v then return nil, err end
        elseif name == 'proxy-auth' then
            v = inline                    -- OPTIONAL: bare means "read stdin"
        elseif inline ~= nil and inline ~= '' then
            return nil, ('--%s takes no value'):format(name)
        end

        if     name == 'account'   then cfg.account = v
        elseif name == 'password'  then cfg.password = v
        elseif name == 'token'     then cfg.token = v
        elseif name == 'character' then cfg.character = v
        elseif name == 'world'     then cfg.world = v
        elseif name == 'host'      then
            local h, p = v:match('^(.-):(%d+)$')
            if h then cfg.host, cfg.port = h, tonumber(p) else cfg.host = v end
        elseif name == 'port'      then cfg.port = tonumber(v)
        elseif name == 'assets'    then cfg.assets = v
        elseif name == 'content-revision' then cfg.contentRevision = v
        elseif name == 'log-level' then cfg.logLevel = v
        elseif name == 'log-file'  then cfg.logFile = v
        elseif name == 'capture'   then cfg.capture = v
        elseif name == 'login-url' then cfg.loginUrl = v
        elseif name == 'session-key' then cfg.sessionKey = v
        elseif name == 'ping'      then cfg.pingMs = tonumber(v) or 10000
        elseif name == 'exit-after' then cfg.exitAfter = tonumber(v)
        elseif name == 'replay'    then cfg.replay = v
        elseif name == 'dry-run'   then cfg.dryRun = true
        elseif name == 'bot'       then cfg.bot = true
        elseif name == 'bot-profile' then
            -- The value becomes the bot's profile ROOT verbatim, and every
            -- profile read and every script.put write is resolved under it.  A
            -- '..' component would therefore point those reads and writes
            -- outside the tree; the hub also pins the field to a single path
            -- segment (hub/model.lua's PROFILE_PAT), and this is the same rule
            -- enforced for a hand-typed command line.
            for seg in tostring(v):gmatch('[^/\\]+') do
                if seg == '..' then
                    return nil, '--bot-profile must not contain a ".." path component'
                end
            end
            cfg.botProfile = v
        elseif name == 'bot-vprofile' then cfg.botVProfile = tonumber(v)
        elseif name == 'cavebot'   then cfg.cavebot = v; cfg.bot = true
        elseif name == 'targetbot' then cfg.targetbot = v; cfg.bot = true
        elseif name == 'bot-status-interval' then cfg.botStatusMs = tonumber(v)
        elseif name == 'vbot'      then cfg.vbot = true
        elseif name == 'vbot-profile' then
            if type(v) ~= 'string' or v == '' then
                return nil, '--vbot-profile needs a directory'
            end
            for part in tostring(v):gmatch('[^/\\]+') do
                if part == '..' then
                    return nil, '--vbot-profile must not contain a ".." path component'
                end
            end
            cfg.vbotProfile = v
            cfg.vbot = true
        elseif name == 'vbot-otroot' then cfg.vbotOtRoot = v; cfg.vbot = true
        elseif name == 'vbot-vprofile' then cfg.vbotVProfile = tonumber(v)
        elseif name == 'vbot-tick' then cfg.vbotTickMs = tonumber(v)
        elseif name == 'vbot-strict' then cfg.vbotStrict = true
        elseif name == 'vbot-safe' then cfg.vbotSafe = true
        elseif name == 'vbot-write' then cfg.vbotWrite = true
        elseif name == 'minimap'   then cfg.minimap = v
        elseif name == 'proxy'     then
            local h, p = v:match('^%[?([^%]]-)%]?:(%d+)$')
            if not h or h == '' then
                return nil, '--proxy needs HOST:PORT'
            end
            cfg.proxyHost, cfg.proxyPort = h, tonumber(p)
        elseif name == 'proxy-auth' then
            -- NEVER from argv.  An inline value that is not @PATH / fd:N is a
            -- credential on the command line, which is exactly what this flag exists
            -- to avoid, so it is refused rather than quietly accepted.
            local reader
            if v == nil or v == '' or v == '-' or v == 'stdin' then
                reader = function() return readFd(0) end
            elseif v:sub(1, 1) == '@' then
                local path = v:sub(2)
                reader = function() return readFirstLine(path) end
            elseif v:match('^fd:%d+$') then
                local n = tonumber(v:match('^fd:(%d+)$'))
                reader = function() return readFd(n) end
            else
                return nil, '--proxy-auth must be bare (stdin), @PATH or fd:N -- a ' ..
                            'credential must never appear in argv'
            end
            cfg.secretReaders[#cfg.secretReaders + 1] = { field = 'proxyAuth', read = reader }
        elseif name == 'control-port' then
            cfg.controlPort = tonumber(v)
            if not cfg.controlPort or cfg.controlPort < 0 or cfg.controlPort > 65535 then
                return nil, '--control-port must be 0..65535'
            end
        elseif name == 'control-bind' then cfg.controlBind = v
        elseif name == 'control-allow-remote' then cfg.controlAllowRemote = true
        elseif name == 'control-token-file' then
            local path = v
            cfg.secretReaders[#cfg.secretReaders + 1] =
                { field = 'controlToken', read = function() return readFirstLine(path) end }
        elseif name == 'control-token-fd' then
            local n = tonumber(v)
            if not n or n < 0 then return nil, '--control-token-fd must be a descriptor number' end
            cfg.secretReaders[#cfg.secretReaders + 1] =
                { field = 'controlToken', read = function() return readFd(n) end }
        elseif name == 'instance-name' then cfg.instanceName = v
        elseif name == 'selftest'  then cfg.selftest = true
        elseif name == 'help'      then cfg.help = true
        else return nil, ('unknown flag --%s (try --help)'):format(name)
        end
        i = i + 1
    end
    return cfg
end

--- Drain the secret readers, in the order their flags appeared, and check the flag
--- combinations that only make sense together.  Kept out of parseArgs so that
--- --help never reads a descriptor and never blocks on an empty stdin.
local function resolveSecrets(cfg)
    for _, r in ipairs(cfg.secretReaders or {}) do
        local v, err = r.read()
        if not v then return nil, ('--%s: %s'):format(r.field, tostring(err)) end
        if v == '' then return nil, ('--%s: the value is empty'):format(r.field) end
        cfg[r.field] = v
    end
    cfg.secretReaders = nil

    if cfg.proxyAuth and not cfg.proxyHost then
        return nil, '--proxy-auth without --proxy=HOST:PORT'
    end
    if cfg.proxyAuth then
        local u, p = cfg.proxyAuth:match('^([^:]*):(.*)$')
        if not u then return nil, '--proxy-auth must be "user:pass"' end
        cfg.proxyUser, cfg.proxyPass = u, p
        cfg.proxyAuth = nil                       -- never keep the pair around whole
    end

    if cfg.controlPort and not cfg.controlToken then
        return nil, '--control-port needs --control-token-file=PATH or --control-token-fd=N ' ..
                    '(the token must not travel in argv)'
    end
    if cfg.controlToken and not cfg.controlPort then
        cfg.controlPort = 0                       -- a token alone means "ephemeral port"
    end
    if cfg.controlToken and #cfg.controlToken < 8 then
        return nil, '--control-token: at least 8 characters, please'
    end

    -- PLAN invariant I10: exactly one bot engine at a time.  Track A (the vBot
    -- scripts through the shim) and Track B (bot/cavebot.lua et al) both walk and
    -- both attack; running the two together makes them fight over the character.
    if cfg.vbot and (cfg.bot or cfg.cavebot or cfg.targetbot) then
        -- --cavebot / --targetbot imply --bot, so naming both would be noise.
        local which = {}
        if cfg.cavebot then which[#which + 1] = '--cavebot' end
        if cfg.targetbot then which[#which + 1] = '--targetbot' end
        if #which == 0 then which[1] = '--bot' end
        return nil, ('--vbot runs the real vBot scripts through the compatibility shim '
                     .. 'and %s runs the native bot layer; the two engines both walk and '
                     .. 'both attack, so exactly one may be enabled.  Drop %s, or drop '
                     .. '--vbot.'):format(table.concat(which, ' / '), table.concat(which, ' / '))
    end
    if (cfg.vbotVProfile or cfg.vbotTickMs or cfg.vbotStrict or cfg.vbotWrite
         or cfg.vbotSafe) and not cfg.vbot then
        return nil, 'the --vbot-* options need --vbot (or --vbot-profile=DIR)'
    end
    if cfg.vbotTickMs and (cfg.vbotTickMs < 1 or cfg.vbotTickMs > 1000) then
        return nil, '--vbot-tick must be between 1 and 1000 ms'
    end
    return cfg
end

-- =========================================================== module wiring
local log      = require('lib.log')
local sys      = require('lib.sys')
local events   = require('lib.events')
local sched    = require('lib.sched')
local state    = require('game.state')
local items    = require('proto.items')
local transport = require('proto.transport')
local handshake = require('proto.handshake')
local parser   = require('proto.parser')
local sender   = require('proto.sender')

local LC = {
    log       = log,
    sys       = sys,
    sched     = sched,
    events    = events,
    items     = items,
    state     = nil,
    transport = nil,
    parser    = nil,
    sender    = nil,
    config    = nil,
    dir       = SCRIPT_DIR,
    minimap   = nil,          -- lib/minimap.lua instance (work item M), or nil
    exitCode  = 0,
}
_G.LC = LC

-- ---------------------------------------------------------------- shutdown
local shuttingDown = false
local function shutdown(code)
    if shuttingDown then return end
    shuttingDown = true
    LC.exitCode = code or LC.exitCode or 0
    -- The control endpoint goes first: it must stop pushing status into a half-torn-down
    -- client, and its listener has to be closed before the reactor stops.
    if LC.control then pcall(function() LC.control:stop() end); LC.control = nil end
    if LC.stopBot then pcall(LC.stopBot) end   -- saves the bot storage
    if LC.pingTimer then pcall(sched.cancel, LC.pingTimer); LC.pingTimer = nil end
    -- Ask the server to end the session (0x14 LeaveGame) before dropping the socket.  A bare
    -- TCP close leaves the character "online" for the server's logout timeout, and the NEXT
    -- login on the same account is then answered with `session ended (reason 0)` -- which is
    -- exactly the failure the walk-pacing work item kept having to disambiguate from a real
    -- kick.  Best effort: it is fine for this to be refused (in combat, etc.).
    if LC.inGame and LC.sender and LC.transport and not LC.transport.dead then
        pcall(function() LC.sender:logout() end)
    end
    if LC.transport then pcall(function() LC.transport:close() end) end
    if LC.captureFile then pcall(function() LC.captureFile:close() end); LC.captureFile = nil end
    pcall(sched.stop)
end

LC.shutdown = shutdown          -- control/commands.lua's `shutdown` command

-- fatal(msg) -- one clean line, no stack trace, then unwind the loop.
local function fatal(code, fmt, ...)
    log.error(fmt, ...)
    shutdown(code)
end

-- ------------------------------------------------------------- status line
-- "log `player: hp/mana/level/pos` whenever any of them changes"
local lastStatus = {}
local function statusLine(force)
    local pl = LC.state and LC.state.player
    if not pl then return end
    local pos = pl.pos
    local key = table.concat({
        tostring(pl.health), tostring(pl.maxHealth),
        tostring(pl.mana), tostring(pl.maxMana),
        tostring(pl.level),
        pos and (pos.x .. ',' .. pos.y .. ',' .. pos.z) or '-',
    }, '|')
    if not force and key == lastStatus.key then return end
    lastStatus.key = key
    log.info('player: hp %d/%d  mana %d/%d  level %d  pos %s',
        pl.health or 0, pl.maxHealth or 0, pl.mana or 0, pl.maxMana or 0, pl.level or 0,
        pos and ('(%d,%d,%d)'):format(pos.x, pos.y, pos.z) or '(unknown)')
end

-- =============================================================== bot layer
-- The vBot-compatible bot (BOT.md).  It is OFF unless --bot / --cavebot /
-- --targetbot is given, is started once the server says we are in the game, and
-- is stopped (which saves its storage) on any shutdown path.

-- Default profile directory: the user's real vBot_4.8 profile when this checkout
-- sits next to it, otherwise ./profiles.  LUACLIENT_BOT_PROFILE overrides both.
local function defaultBotProfile()
    local env = sys.getEnv and sys.getEnv('LUACLIENT_BOT_PROFILE')
    if env and #env > 0 then return env end
    local candidates = {
        SCRIPT_DIR .. '/../../otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
        'D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
        '/mnt/d/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
    }
    for _, c in ipairs(candidates) do
        local f = io.open(c .. '/vBot_configs/profile_1/HealBot.json', 'r')
        if f then f:close(); return (c:gsub('\\', '/')) end
    end
    return SCRIPT_DIR .. '/profiles'
end

-- One line, info level: hp/mana/pos, the CaveBot waypoint and the TargetBot target.
local function botStatusLine()
    local b = LC.bot
    if not b then return end
    local ok, st = pcall(b.status, b)
    if not ok or not st then return end
    local pl = st.player or {}
    local pos = pl.pos
    local parts = { ('hp %s/%s  mana %s/%s  pos %s'):format(
        tostring(pl.hp or 0), tostring(pl.maxHp or 0),
        tostring(pl.mana or 0), tostring(pl.maxMana or 0),
        pos and ('(%d,%d,%d)'):format(pos.x, pos.y, pos.z) or '(unknown)') }

    local cb = st.cavebot
    if cb then
        parts[#parts + 1] = ('cavebot %s %s wp %s/%s %s'):format(
            cb.on and 'on' or 'off', tostring(cb.config or cb.route or '-'),
            tostring(cb.waypointIndex or cb.index or 0),
            tostring(cb.waypointCount or 0),
            tostring(cb.currentAction or cb.status or '-'))
    end

    local tb = st.targetbot
    if tb then
        local t = tb.target
        parts[#parts + 1] = ('target %s%s  danger %s'):format(
            t and tostring(t.name) or 'none',
            (t and t.hpPercent) and (' (' .. tostring(t.hpPercent) .. '%)') or '',
            tostring(tb.danger or 0))
    end

    local sup = st.supplies
    if sup and sup.rounds then
        parts[#parts + 1] = ('supplies round %s%s'):format(tostring(sup.rounds),
            sup.pouchPages and (', pouch ' .. tostring(sup.pouchPages) .. 'p') or '')
    end

    log.info('bot: %s', table.concat(parts, ' | '))
end

-- ====================================================== persisted minimap
-- Work item M: the pathfinder's knowledge of the world OUTSIDE the aware area.  The client
-- only knows tiles the server has described, so a cavebot waypoint more than a screen away
-- has no path at all (docs/live-findings.md, bug 3).  `Map::findEveryPath` solves that by
-- consulting the persisted minimap for every neighbour outside the aware range, and
-- lib/minimap.lua is the reader for exactly that file.  READ-ONLY: it is slurped and closed,
-- never held open (the reference client publishes with an atomic rename, which any open
-- handle would break).
local function loadMinimap(cfg)
    if cfg.minimap == 'off' or cfg.minimap == 'none' or cfg.minimap == '' then
        log.info('minimap: disabled (--minimap=%s); the pathfinder sees only the aware area',
                 tostring(cfg.minimap))
        return nil
    end

    local okmod, minimap = pcall(require, 'lib.minimap')
    if not okmod then
        log.warn('minimap: lib/minimap.lua is unavailable (%s)', tostring(minimap))
        return nil
    end

    local file = cfg.minimap
    if not file then
        file = minimap.findDefault(SCRIPT_DIR)
        if not file then
            log.info('minimap: no minimap.otmm found; the pathfinder sees only the aware area')
            return nil
        end
    end

    local mm, err = minimap.load(file)
    if not mm then
        -- never fatal: a missing or damaged minimap only costs long-distance pathing
        log.warn('%s', tostring(err))
        return nil
    end

    local st = mm:stats()
    local floors = {}
    for z = 0, minimap.MAP_MAX_Z do
        if st.floors[z] then floors[#floors + 1] = ('%d:%d'):format(z, st.floors[z]) end
    end
    log.info('minimap: %s -- %d blocks loaded (%d tile slots) from %d bytes in %.0f ms%s '
             .. '| blocks per floor %s',
             file, st.blocks, st.tiles, st.fileSize, st.loadMs,
             st.damaged and (', DAMAGED: %d unusable, %d resync(s), %d salvaged')
                            :format(st.blocksDamaged, st.resyncs, st.blocksSalvaged) or '',
             table.concat(floors, ' '))
    return mm
end

local function startBot(cfg)
    if not cfg.bot or LC.bot then return end
    local okmod, botmod = pcall(require, 'bot.init')
    if not okmod then
        log.error('bot: cannot load bot/init.lua: %s', tostring(botmod))
        return
    end
    local dir = cfg.botProfile or defaultBotProfile()
    if LC.minimap == nil and not cfg._minimapTried then
        cfg._minimapTried = true
        LC.minimap = loadMinimap(cfg)
    end
    local okb, b = pcall(botmod.new, LC, {
        profileDir = dir,
        vprofile   = cfg.botVProfile or 1,
        known      = LC.minimap,
        cavebot    = cfg.cavebot,
        targetbot  = cfg.targetbot,
        -- --dry-run must never write into the user's real vBot profile.
        readOnlyProfile = cfg.dryRun and true or nil,
    })
    if not okb then
        log.error('bot: construction failed: %s', tostring(b))
        return
    end
    LC.bot = b
    b.inGame = true                          -- the HealBot / AttackBot death+offline gate
    log.info('bot: profile %s (vprofile %d)%s%s', dir, cfg.botVProfile or 1,
             cfg.cavebot and (', cavebot ' .. cfg.cavebot) or '',
             cfg.targetbot and (', targetbot ' .. cfg.targetbot) or '')
    b:wireModules{
        cavebot   = cfg.cavebot,
        targetbot = cfg.targetbot,
        -- bot/init.lua hands this to world.new as `opts.known`: the pathfinder's knowledge of
        -- everything outside the aware area (bot/world.lua:classifyForPath).
        known     = LC.minimap,
        enableCavebot   = cfg.cavebot   and true or nil,
        enableTargetbot = cfg.targetbot and true or nil,
    }
    b:start()

    local every = cfg.botStatusMs or 5000
    if every > 0 and sched.every then
        LC.botStatusTimer = sched.every(every, botStatusLine)
    end
end

-- ====================================================== vBot compatibility shim
-- Track A: the user's REAL vBot 4.8 scripts, unmodified, running on the otclient
-- API surface synthesised in shim/ (docs/shim/COMPAT.md).  It replaces the native
-- bot layer entirely -- never both (invariant I10, enforced in resolveSecrets).
--
-- `--vbot-profile=DIR` names the /bot/<config> directory.  Everything else falls
-- out of it: config = the last path component, the g_resources write dir = its
-- grandparent (.../profiles), and the otclient checkout = one above that.  That
-- is exactly the layout the reference client itself uses, so pointing at the real
-- profile is all the user has to do.
local function resolveVBotPaths(cfg)
    local dir = cfg.vbotProfile or defaultBotProfile()
    dir = tostring(dir):gsub('\\', '/'):gsub('/+$', '')
    local parent, config = dir:match('^(.*)/([^/]+)$')
    if not config then return nil, ('--vbot-profile: %s is not a directory path'):format(dir) end
    -- <writeDir>/bot/<config>: the shim's g_resources is rooted at the profiles dir.
    local writeDir = parent:match('^(.*)/[Bb]ot$')
    if not writeDir then
        return nil, ('--vbot-profile: %s must live under a "bot" directory '
                     .. '(the layout is <profiles>/bot/<config>)'):format(dir)
    end
    local otRoot = cfg.vbotOtRoot
    if not otRoot then otRoot = writeDir:match('^(.*)/[^/]+$') end
    if not otRoot then
        return nil, 'cannot derive the otclient root; pass --vbot-otroot=DIR'
    end
    return { dir = dir, config = config, writeDir = writeDir,
             otRoot = (tostring(otRoot):gsub('\\', '/'):gsub('/+$', '')) }
end

local function startVBot(cfg)
    if not cfg.vbot or LC.vbot then return end
    local paths, perr = resolveVBotPaths(cfg)
    if not paths then
        log.error('vbot: %s', tostring(perr))
        return
    end
    local okmod, shim = pcall(require, 'shim.bootstrap')
    if not okmod then
        log.error('vbot: cannot load shim/bootstrap.lua: %s', tostring(shim))
        return
    end
    if LC.minimap == nil and not cfg._minimapTried then
        cfg._minimapTried = true
        LC.minimap = loadMinimap(cfg)
    end
    local readOnly = (not cfg.vbotWrite) or (cfg.dryRun and true or false)
    log.info('vbot: %s (config %s, vprofile %d) from %s -- %s, tick %d ms%s',
             paths.dir, paths.config, cfg.vbotVProfile or cfg.botVProfile or 1,
             paths.otRoot, readOnly and 'READ-ONLY' or 'writes allowed (--vbot-write)',
             cfg.vbotTickMs or 10, cfg.vbotStrict and ', strict' or '')

    local okb, S, serr = pcall(shim.start, LC, {
        otRoot   = paths.otRoot,
        writeDir = paths.writeDir,
        config   = paths.config,
        profile  = cfg.vbotVProfile or cfg.botVProfile or 1,
        tickMs   = cfg.vbotTickMs or 10,
        readOnly = readOnly,
        strict   = cfg.vbotStrict and true or false,
        arm      = true,
        log      = log,
        onForceExit = function() shutdown(0) end,
    })
    if not okb then
        log.error('vbot: boot raised: %s', tostring(S))
        return
    end
    if not S then
        log.error('vbot: boot failed: %s', tostring(serr))
        return
    end
    LC.vbot = shim
    -- Count macro invocations.  Without this every status line reports
    -- "macros 0/N ran" no matter how much work the tree did, because `runs` is only
    -- populated by the instrumentation wrapper -- so a clean live session looked
    -- exactly like a session in which nothing ever ran.  forceEnable is NOT passed:
    -- the user's own on/off state is untouched.
    pcall(shim.instrumentMacros, {})
    local st = shim.status()
    log.info('vbot: %d profile files loaded (%d failed), %d runtime files, '
             .. '%d macros (%d enabled), %d callbacks, UI backend %s',
             st.vbotLoaded or 0, st.vbotFailed or 0, st.runtimeLoaded or 0,
             st.macroCount or 0, st.macrosEnabled or 0, st.callbacks or 0,
             tostring(st.ui))
    for _, f in ipairs(st.failures or {}) do
        log.warn('vbot: %s did not load: %s', tostring(f.name), tostring(f.err))
    end
    if serr then log.warn('vbot: %s', tostring(serr)) end

    -- --vbot-safe: the whole tree is up and ticking; now take the three engines that
    -- can act on the world offline.  This runs AFTER the boot on purpose, so the
    -- proof that the tree loads and ticks is unchanged -- only what it is allowed to
    -- DO is narrowed.  HealBot stays on: it never starts a fight and it is the one
    -- thing that keeps the character alive if something else does.
    if cfg.vbotSafe then
        local ctx = shim.context()
        local off = {}
        for _, name in ipairs({ 'AttackBot', 'TargetBot', 'CaveBot' }) do
            local mod = ctx and rawget(ctx, name)
            local fn = type(mod) == 'table' and mod.setOff
            if type(fn) == 'function' then
                local okoff = pcall(fn)
                off[#off + 1] = ('%s=%s'):format(name, okoff and 'off' or 'FAILED')
            else
                off[#off + 1] = ('%s=absent'):format(name)
            end
        end
        log.warn('vbot: --vbot-safe -- combat and auto-walk disabled (%s); '
                 .. 'HealBot left on', table.concat(off, ' '))
    end
end

local function vbotStatusLine()
    local shim = LC.vbot
    if not shim then return end
    local ok, st = pcall(shim.status)
    if not ok or not st then return end
    local pl = LC.state and LC.state.player or {}
    local pos = pl.pos
    log.info('vbot: hp %s/%s mana %s/%s pos %s | ticks %d (%d raised, slowest %d ms) | '
             .. 'macros %d/%d ran',
             tostring(pl.health or 0), tostring(pl.maxHealth or 0),
             tostring(pl.mana or 0), tostring(pl.maxMana or 0),
             pos and ('(%d,%d,%d)'):format(pos.x, pos.y, pos.z) or '(unknown)',
             st.ticks or 0, st.tickErrors or 0, st.maxTickMs or 0,
             st.macrosRan or 0, st.macroCount or 0)
end

local function stopVBot()
    local shim = LC.vbot
    if not shim then return end
    LC.vbot = nil
    if LC.vbotStatusTimer then
        pcall(sched.cancel, LC.vbotStatusTimer); LC.vbotStatusTimer = nil
    end
    pcall(shim.stop)          -- saves storage when --vbot-write was given
end

-- Stop + persist.  Safe to call twice and safe when the bot never came up.
local function stopBot()
    local b = LC.bot
    if not b then return end
    b.inGame = false
    if LC.botStatusTimer then pcall(sched.cancel, LC.botStatusTimer); LC.botStatusTimer = nil end
    pcall(function() b:unwireModules() end)
    pcall(function() b:stop() end)          -- stop() saves storage
    LC.bot = nil
end
LC.loadMinimap = function() return loadMinimap(LC.config or {}) end
-- One entry point for both engines; resolveSecrets already guarantees only one of
-- them is configured (invariant I10), so this dispatch can never start two.
LC.stopBot  = function() stopVBot(); return stopBot() end
LC.startBot = function()
    local cfg = LC.config or {}
    if cfg.vbot then
        startVBot(cfg)
        local every = cfg.botStatusMs or 5000
        if LC.vbot and every > 0 and sched.every and not LC.vbotStatusTimer then
            LC.vbotStatusTimer = sched.every(every, vbotStatusLine)
        end
        return
    end
    return startBot(cfg)
end
LC.startVBot = function() return startVBot(LC.config or {}) end
LC.stopVBot  = stopVBot
-- The control endpoint's `bot.listConfigs` has to work before the bot is running (the
-- panel populates its pickers while the worker is still logging in), so the profile
-- directory is resolved once here rather than only inside startBot.
LC.botProfileDir = nil
LC.resolveBotProfileDir = function()
    local cfg = LC.config or {}
    LC.botProfileDir = cfg.botProfile or defaultBotProfile()
    return LC.botProfileDir
end

-- =============================================================== capture
local function openCapture(path)
    if not path then return end
    local f, err = io.open(path, 'a')
    if not f then
        log.warn('capture: cannot open %s (%s) -- continuing without it', path, tostring(err))
        return
    end
    LC.captureFile = f
    LC.captureStart = sys.nowMs()
    log.info('capture: appending inbound payloads to %s', path)
end

local HEXD = {}
for b = 0, 255 do HEXD[string.char(b)] = ('%02x'):format(b) end
local function toHex(s) return (s:gsub('.', HEXD)) end

local function captureIn(payload)
    local f = LC.captureFile
    if not f then return end
    f:write('< ', tostring(math.floor(sys.nowMs() - (LC.captureStart or 0))), ' ',
            toHex(payload), '\n')
    f:flush()
end

-- =============================================================== game wiring
-- Build state/parser/sender/transport and hook the event bus. `t` may be nil in
-- dry-run mode (the parser and the event bus are still fully exercised).
local function buildGame(cfg, t)
    local st = state.new()
    LC.state = st
    LC.transport = t

    local p = parser.new(st, function(name, data)
        events.emit(name, data)
    end)
    LC.parser = p

    local s = sender.new(t)
    LC.sender = s

    -- A relogin builds a fresh game and calls this again; without dropping the previous
    -- registrations every event would be handled twice (two login packets, two pongs)
    -- and the FIRST, dead transport would be the one written to.  The control endpoint's
    -- own subscriptions live on the same bus, so this drops exactly ours and nothing else.
    if LC._gameHandles then
        for i = 1, #LC._gameHandles do pcall(events.off, LC._gameHandles[i]) end
    end
    local handles = {}
    LC._gameHandles = handles
    local function on(name, fn) handles[#handles + 1] = events.on(name, fn) end

    -- every event may have moved hp/mana/level/pos
    handles[#handles + 1] = events.onAny(function() statusLine(false) end)

    -- TEST HOOK, never for production use: LUACLIENT_TEST_XTEA=<32 hex chars>
    -- pins the session key so an offline fake server (which has no RSA private
    -- key and therefore cannot read the real one) can decrypt our frames.
    local function fixedXteaKey()
        local hex = sys.getEnv('LUACLIENT_TEST_XTEA')
        if not hex or #hex ~= 32 or hex:match('%X') then return nil end
        log.warn('LUACLIENT_TEST_XTEA is set: using a FIXED, NON-SECRET XTEA key (testing only)')
        local k = {}
        for i = 0, 3 do k[i + 1] = tonumber(hex:sub(i * 8 + 1, i * 8 + 8), 16) end
        return k
    end

    on('challenge', function(d)
        log.info('challenge: ts=%d random=%d -- sending login packet', d.timestamp, d.random)
        local body, key = handshake.buildLoginPacket{
            xteaKey         = fixedXteaKey(),
            sessionKey      = cfg.sessionKey,
            accountName     = cfg.account,
            characterName   = cfg.characterName,
            challengeTs     = d.timestamp,
            challengeRand   = d.random,
            contentRevision = cfg.contentRevision,
            assetsDir       = cfg.assetsRoot,
        }
        local ok, err = t:send(body)
        if not ok then return fatal(3, 'failed to send the login packet: %s', tostring(err)) end
        -- XTEA turns on only AFTER the login packet has been framed in plaintext.
        t:enableXtea(key)
        log.info('login packet sent (%d body bytes); XTEA enabled', #body)
    end)

    on('pending', function()
        log.info('server accepted the login (pending) -- entering game')
        local frames = handshake.buildEnterGameFrames(cfg.account or '')
        for _, body in ipairs(frames) do
            local ok, err = t:send(body)
            if not ok then return fatal(3, 'failed to send an enter-game frame: %s', tostring(err)) end
        end
    end)

    -- The keepalive is armed by whichever of the two "we are in" packets arrives
    -- first: 0x0F EnterGame (-> gameStart) or 0x17 LoginSuccess (-> login).
    local function armPing(what)
        LC.inGame = true
        if LC.pingTimer then return end
        log.info('%s -- arming the %d ms keepalive ping (opcode 29)', what, cfg.pingMs or 10000)
        LC.pingTimer = sched.every(cfg.pingMs or 10000, function()
            if LC.transport and not LC.transport.dead then
                LC.pingSentAt = sys.nowMs()
                LC.sender:ping()
            end
        end)
        statusLine(true)
        -- BOT.md: the bot starts once the server says we are in the game.
        if LC.startBot then LC.startBot() end
    end
    on('gameStart', function() armPing('game started') end)
    on('login', function(d)
        -- 0x17 LoginSuccess carries serverBeat + the GameNewSpeedLaw constants.  The parser
        -- keeps them on itself; the walker's step timing needs them on the STATE, because
        -- Creature::getStepDuration divides by m_calculatedStepSpeed (derived from A/B/C)
        -- rather than by the raw wire speed whenever all three are non-zero.
        if LC.state and d then
            LC.state.speedA, LC.state.speedB, LC.state.speedC = d.speedA, d.speedB, d.speedC
        end
        log.debug('[walk] login serverBeat=%s speedA=%s speedB=%s speedC=%s',
                  tostring(d and d.serverBeat), tostring(d and d.speedA),
                  tostring(d and d.speedB), tostring(d and d.speedC))
        armPing(('login success (player id %s)'):format(tostring(d and d.playerId)))
    end)

    -- 0x1D: the server asks US to answer -> pong immediately (opcode 28).
    on('ping', function()
        if LC.transport and not LC.transport.dead then LC.sender:pingBack() end
    end)
    on('pingBack', function()
        -- 0x1E is the PONG for our keepalive: turn it into the RTT the bot layer's
        -- step timing, smooth-walk pacer and cooldown ping compensation all read.
        if LC.pingSentAt then
            local rtt = sys.nowMs() - LC.pingSentAt
            LC.pingSentAt = nil
            if rtt >= 0 and rtt < 5000 and LC.state then LC.state.ping = math.floor(rtt) end
        end
        log.debug('pong from server (latency %s ms)', tostring(LC.state and LC.state.ping))
    end)

    on('loginError', function(d) fatal(2, 'login refused: %s', tostring(d.message)) end)
    on('loginWait',  function(d) log.warn('login wait: %s (%s s)', tostring(d.message), tostring(d.time)) end)
    on('loginAdvice', function(d) log.info('server: %s', tostring(d.message)) end)
    on('sessionEnd', function(d) fatal(0, 'session ended by the server (reason %s)', tostring(d.reason)) end)
    on('death', function() log.warn('the character has died') end)
    on('talk', function(d)
        log.info('talk [%s] %s: %s', tostring(d.mode), tostring(d.name), tostring(d.text))
    end)
    on('textMessage', function(d)
        log.info('message [%s] %s', tostring(d.mode), tostring(d.text))
    end)

    return st, p, s
end

-- ======================================================= control endpoint
-- PANEL.md: "a local control endpoint bound to 127.0.0.1 on an ephemeral port,
-- speaking the same JSON command/event protocol".  Started after boot so that a
-- `status` served on the first millisecond already has the items table, the state
-- object and the event bus behind it; stopped from shutdown().
local function startControl(cfg)
    if not cfg.controlToken then return end
    local okmod, control = pcall(require, 'control.server')
    if not okmod then
        log.error('control: cannot load control/server.lua: %s', tostring(control))
        return nil, tostring(control)
    end
    -- The loot/waste value model reads vBot's own price table out of the profile.
    local profileDir = LC.botProfileDir or LC.resolveBotProfileDir()
    local srv, err = control.new{
        LC = LC,
        host = cfg.controlBind or '127.0.0.1',
        port = cfg.controlPort or 0,
        token = cfg.controlToken,
        allowRemote = cfg.controlAllowRemote,
        instanceName = cfg.instanceName or (cfg.character or 'worker'),
        pricesPath = profileDir and (profileDir .. '/vBot/items.lua') or nil,
    }
    if not srv then
        log.error('control: %s', tostring(err))
        return nil, tostring(err)
    end
    local port, serr = srv:start()
    if not port then
        log.error('control: cannot listen on %s:%s: %s',
                  tostring(cfg.controlBind or '127.0.0.1'), tostring(cfg.controlPort), tostring(serr))
        return nil, tostring(serr)
    end
    LC.control = srv
    -- One machine-readable line so the hub can learn an ephemeral port from stdout.
    io.stdout:write(('control-endpoint %s %d %s\n'):format(
        cfg.controlBind or '127.0.0.1', port, srv.instanceName))
    io.stdout:flush()
    return srv
end

-- The credentials the hub gave us are kept so that `relogin` can use them again; the
-- password is held ONLY while a login is in flight (see LC.login below).
local sessionCfg = nil

-- =============================================================== dry run
-- Everything except sockets and HTTPS: items table, login-packet construction,
-- outgoing framing, the receive path (fed one byte at a time), parser dispatch
-- and the event bus. Exercises the exact wiring the live path uses.
local function runDryRun(cfg)
    log.info('--dry-run: offline wiring check (no sockets, no HTTPS)')

    local nItems = items.MAX_ID
    log.info('items: %d ids, %d with an appearance, revision %s',
        nItems, items.COUNT, tostring(items.CONTENT_REVISION))

    -- A transport that never touches a socket: capture the frames it builds.
    local wire = {}
    local t = transport.new{
        host = '127.0.0.1', port = 0, worldName = cfg.world or 'Gunzodus',
        onMessage = function(payload)
            local ok, err = pcall(function() LC.parser:parse(payload) end)
            if not ok then error(err, 0) end
        end,
        onError = function(msg) fatal(3, 'transport: %s', msg) end,
    }
    t._write = function(self, bytes) wire[#wire + 1] = bytes; return true end

    buildGame({
        account = cfg.account or 'dryrun@example.invalid',
        characterName = cfg.character or 'DryRun',
        sessionKey = 'DRYRUN-SESSION-KEY',
        contentRevision = cfg.contentRevision,
        assetsRoot = cfg.assetsRoot,
        pingMs = cfg.pingMs,
    }, t)

    -- The server side of the same framing code, so a frame we build is a frame
    -- we can read back.
    local peer = transport.new{ gunzOs = false, onMessage = function() end }

    -- 1. challenge -> login packet
    local challenge = string.char(0x1F) .. string.char(0x44, 0x33, 0x22, 0x11)
                      .. string.char(0x5A) .. string.char(0)
    local frame = peer:buildFrame(challenge)
    for k = 1, #frame do
        local ok, err = t:feed(frame:sub(k, k))
        if not ok then error('dry-run: transport rejected the challenge frame: ' .. tostring(err)) end
    end
    assert(#wire == 1, 'dry-run: expected exactly one outgoing frame after the challenge')
    local loginFrame = wire[1]
    assert(#loginFrame == 158, ('dry-run: login frame is %d bytes, expected 158'):format(#loginFrame))
    assert(t.xteaOn, 'dry-run: XTEA was not enabled after the login packet')
    log.info('dry-run: login frame %d bytes, %d blocks, sequence 0, XTEA now on',
        #loginFrame, loginFrame:byte(1) + loginFrame:byte(2) * 256)

    -- 2. pending -> the two enter-game frames (separately framed, seq 1 and 2)
    peer:enableXtea(t.xteaKey)
    local ok, err = t:feed(peer:buildFrame(string.char(0x0A)))
    if not ok then error('dry-run: pending frame rejected: ' .. tostring(err)) end
    assert(#wire == 3, ('dry-run: expected 2 enter-game frames, got %d'):format(#wire - 1))
    assert(t.stats.seq == 3, 'dry-run: sequence should be 3 after login + 2 enter-game frames')
    log.info('dry-run: enter-game frames sent (hwid %s), sequence now %d',
        handshake.hwid(cfg.account or 'dryrun@example.invalid'), t.stats.seq)

    -- 3. a gameplay packet through the real parser + event bus
    local seen = {}
    events.onAny(function(name) seen[name] = (seen[name] or 0) + 1 end)
    -- 0xA0 PlayerData: exactly 60 payload bytes at 1530
    local w = require('lib.buffer').writer()
    w:u8(0xA0)
    w:u32(150):u32(200):u32(87650):u64(1234):u16(8):u16(4200)
    w:u16(0):u16(0):u16(0):u16(0)
    w:u32(30):u32(60):u8(100):u16(2400):u16(220):u16(0):u16(0)
    w:u16(0):u8(0)
    w:u32(0):u32(0)
    local ok2, err2 = t:feed(peer:buildFrame(w:data()))
    if not ok2 then error('dry-run: PlayerData frame rejected: ' .. tostring(err2)) end
    assert(seen.healthChange == 1, 'dry-run: healthChange did not fire')
    assert(LC.state.player.health == 150 and LC.state.player.level == 8,
        'dry-run: player state was not updated')

    -- 4. the ping rules: a server 0x1D must produce a pong on the wire
    local before = #wire
    local ok3 = t:feed(peer:buildFrame(string.char(0x1D)))
    if not ok3 then error('dry-run: ping frame rejected') end
    assert(#wire == before + 1, 'dry-run: the server ping was not answered')
    log.info('dry-run: server ping answered with opcode 28 (%d frames on the wire total)', #wire)

    -- 5. the bot layer, when asked for: construct, wire, tick, stop.  Everything the
    --    live path does except the socket, so --bot --dry-run is a real wiring check.
    if cfg.bot then
        LC.state.player.pos = LC.state.player.pos or { x = 32369, y = 32241, z = 7 }
        startBot(cfg)
        if not LC.bot then error('dry-run: the bot layer failed to start') end
        local b = LC.bot
        local macros = #b._macros
        for _ = 1, 50 do b:tick() end
        if (cfg.botStatusMs or 5000) > 0 then botStatusLine() end
        log.info('dry-run: bot wired -- %d macros, %d ticks, %d macro errors, world %s',
                 macros, b.stats.ticks, b.stats.macroErrors,
                 tostring(b.world and b.world.itemDataLevel))
        if b.stats.macroErrors > 0 then error('dry-run: a bot macro raised') end
        -- With a control endpoint the worker stays up, so the bot layer stays up with
        -- it: the panel must be able to drive bot.enable / script.put against a real
        -- running bot.  Without one, --dry-run is a one-shot check and the bot is
        -- stopped here exactly as before.
        if not cfg.controlToken then stopBot() end
    end

    -- 5b. the same check for Track A: boot the real vBot tree through the shim and
    --     tick it.  `--vbot --dry-run` is the offline wiring proof for the shim.
    if cfg.vbot then
        LC.state.player.pos = LC.state.player.pos or { x = 32369, y = 32241, z = 7 }
        LC.inGame = true
        startVBot(cfg)
        if not LC.vbot then error('dry-run: the vBot shim failed to start') end
        local st = LC.vbot.status()
        if (st.vbotFailed or 0) > 0 then
            local first = (st.failures or {})[1]
            error(("dry-run: %d vBot files failed to load (first: %s -- %s)")
                  :format(st.vbotFailed, tostring(first and first.name),
                          tostring(first and first.err)))
        end
        for _ = 1, 50 do LC.vbot.tick() end
        st = LC.vbot.status()
        vbotStatusLine()
        log.info('dry-run: vbot wired -- %d files, %d macros (%d enabled), %d ticks, '
                 .. '%d tick errors, UI %s',
                 st.loaded or 0, st.macroCount or 0, st.macrosEnabled or 0,
                 st.ticks or 0, st.tickErrors or 0, tostring(st.ui))
        if (st.tickErrors or 0) > 0 then
            error('dry-run: a vBot tick raised: ' .. tostring(st.firstTickError))
        end
        if not cfg.controlToken then stopVBot() end
    end

    log.info('--dry-run OK: items, login packet, framing, parser, events and the ping rules all wired')

    if cfg.controlToken then
        -- The wiring check passed; now serve the control endpoint until someone says
        -- `shutdown` (or --exit-after elapses).  This is the mode test/controlsuite.lua
        -- drives: a real process, a real socket, no network of any kind.
        -- A bot started later through `bot.enable` needs a position the same way the
        -- --bot branch above does, and in a dry run nothing on the wire supplies one.
        LC.state.player.pos = LC.state.player.pos or { x = 32369, y = 32241, z = 7 }
        local srv, cerr = startControl(cfg)
        if not srv then
            log.error('control: %s', tostring(cerr))
            return 1
        end
        -- The dry run has no game session, but the bot ticks and the stats engine
        -- samples exactly as they do live, so the panel sees a real 1 Hz status.
        LC.inGame = false
        LC.loginState = 'offline'
        if cfg.exitAfter and cfg.exitAfter > 0 then
            sched.after(math.floor(cfg.exitAfter * 1000), function()
                log.info('--exit-after elapsed -- shutting the control endpoint down')
                shutdown(0)
            end)
        end
        sched.run()
        return LC.exitCode or 0
    end
    return 0
end

-- =============================================================== live boot
local function pickCharacter(cfg, login)
    local chars = login.characters or {}
    if #chars == 0 then return nil, 'the account has no characters' end
    local wanted = cfg.character and cfg.character:lower()
    local world  = cfg.world and cfg.world:lower()
    local names = {}
    for _, c in ipairs(chars) do
        names[#names + 1] = ('%s (%s)'):format(tostring(c.name), tostring(c.worldName or c.world))
        local nameOk  = (not wanted) or (c.name and c.name:lower() == wanted)
        local worldOk = (not world) or ((c.worldName or c.world or ''):lower() == world)
        if nameOk and worldOk then return c end
    end
    return nil, ('no character matched (available: %s)'):format(table.concat(names, ', '))
end

--- openSession(cfg) -> nil | code, err
---
--- Everything between "we have credentials" and "the socket is connecting": the HTTPS
--- account login, the character choice, the transport and the event wiring.  Split out
--- of runLive so that the control endpoint's `login` / `relogin` commands can run the
--- very same path at any time instead of only at boot.
---
--- NOTE for the panel: the HTTPS POST inside lib/http.lua is BLOCKING.  Calling this
--- from a control command stalls the reactor for the length of that one request
--- (bounded by http.DEFAULT_TIMEOUT_MS).  That is the same stall the boot path has
--- always had; making it non-blocking means a non-blocking TLS client, which this
--- checkout does not have.
local function openSession(cfg)
    local login

    if cfg.sessionKey then
        -- Skip the HTTPS round trip and use a session key we already hold.
        -- Requires --host/--port and --character, since there is no reply to
        -- read the world address out of.
        if not cfg.character then return 1, '--session-key also needs --character' end
        if not cfg.host or not cfg.port then return 1, '--session-key also needs --host=HOST:PORT' end
        login = {
            sessionKey = cfg.sessionKey,
            worlds = {},
            characters = { { name = cfg.character, worldName = cfg.world or 'Gunzodus',
                             host = cfg.host, port = cfg.port } },
        }
        log.info('using the session key supplied on the command line (no HTTPS login)')
    else
        -- 1. HTTPS account login --------------------------------------------
        if not cfg.account or cfg.account == '' then
            return 1, '--account is required (try --help)'
        end
        if not cfg.password then
            return 1, '--password is required (try --help)'
        end
        log.info('logging in as %s ...', cfg.account)
        local msg, code
        login, msg, code = handshake.httpLogin{
            account  = cfg.account,
            password = cfg.password,
            token    = cfg.token,
            url      = cfg.loginUrl,
        }
        cfg.password = nil                            -- never keep it around
        if not login then
            if code == 6 then
                return 2, ('login refused: %s (pass --token=DIGITS)'):format(tostring(msg))
            end
            return 2, ('login refused: %s'):format(tostring(msg))
        end
        log.info('login ok: %d character(s)', #(login.characters or {}))
    end

    -- 2. world + character ---------------------------------------------------
    local ch, err = pickCharacter(cfg, login)
    if not ch then return 1, err end
    local host = cfg.host or ch.host
    local port = cfg.port or ch.port
    local worldName = ch.worldName or ch.world
    if not host or not port then
        return 1, ('the login reply has no address for world %s'):format(tostring(worldName))
    end
    -- The world name is the raw preamble on the game socket, so a nil one is a wrong-bytes-
    -- on-the-wire defect, not a cosmetic gap.  It can be nil while host/port are fine when
    -- the character's worldid has no matching entry in playdata.worlds AND --host was given.
    if not worldName or worldName == '' then
        return 1, ('the login reply has no world name for character %s (pass --world=NAME)')
            :format(tostring(ch.name))
    end
    log.info('character: %s @ %s (%s:%d)', tostring(ch.name), tostring(worldName), host, port)

    -- 3. transport -----------------------------------------------------------
    local t
    -- PANEL.md "Proxy support": with --proxy the TCP connection goes to the proxy and
    -- lib/proxy.lua's CONNECT handshake runs before the world-name preamble.
    local proxyOpt = nil
    if cfg.proxyHost then
        proxyOpt = { host = cfg.proxyHost, port = cfg.proxyPort,
                     user = cfg.proxyUser, pass = cfg.proxyPass }
        log.info('proxy: tunnelling the game socket through %s:%d%s',
                 cfg.proxyHost, cfg.proxyPort,
                 (cfg.proxyUser and cfg.proxyUser ~= '') and ' (with credentials)' or '')
    end
    t = transport.new{
        host = host, port = port,
        worldName = worldName,                         -- set BEFORE connect()
        proxy = proxyOpt,
        onConnect = function()
            log.info('connected to %s:%d, world preamble sent%s', host, port,
                     proxyOpt and ' (through the proxy tunnel)' or '')
        end,
        onMessage = function(payload)
            captureIn(payload)
            local ok, perr = pcall(function() LC.parser:parse(payload) end)
            if not ok then
                fatal(3, 'parser desync -- disconnecting.\n%s', tostring(perr))
            end
        end,
        onError = function(m)
            m = tostring(m)
            -- A peer disconnect after we were in the game is a normal end of
            -- session, not a protocol failure.
            local closed = m:find('closed', 1, true) or m:find('CONNRESET', 1, true)
            if closed and LC.inGame then
                log.warn('the server closed the connection')
                return shutdown(0)
            end
            fatal(3, 'transport: %s', m)
        end,
    }

    buildGame({
        account         = cfg.account,
        characterName   = ch.name,
        sessionKey      = login.sessionKey,
        contentRevision = cfg.contentRevision,
        assetsRoot      = cfg.assetsRoot,
        pingMs          = cfg.pingMs,
    }, t)
    -- Keep what a relogin needs and NOT the password: the session key the login reply
    -- gave us is exactly what --session-key takes, so a reconnect needs no second HTTPS
    -- round trip and no credential kept in memory.  (A session key does expire; when it
    -- has, `relogin` fails and the hub calls `login {account, password}` again.)
    LC._resume = { sessionKey = login.sessionKey, character = ch.name,
                   world = worldName, host = host, port = port }
    login.sessionKey = nil

    LC.characterName = ch.name
    LC.worldName     = worldName
    LC.loginState    = 'connecting'

    local ok, cerr = t:connect()
    if not ok then return 3, ('connect failed: %s'):format(tostring(cerr)) end
    return nil
end

-- ---------------------------------------------------------- runtime session
-- The three entry points control/commands.lua calls.  They are installed here rather
-- than in the control module because only main.lua knows the boot configuration.
LC.logout = function()
    local wasIn = LC.inGame and true or false
    if LC.inGame and LC.sender and LC.transport and not LC.transport.dead then
        pcall(function() LC.sender:logout() end)
    end
    if LC.stopBot then pcall(LC.stopBot) end
    if LC.pingTimer then pcall(sched.cancel, LC.pingTimer); LC.pingTimer = nil end
    if LC.transport then pcall(function() LC.transport:close() end) end
    LC.inGame = false
    LC.loginState = 'offline'
    if LC.control then LC.control:broadcast('gameEnd', { reason = 'logout' }) end
    return { wasOnline = wasIn, state = 'offline' }
end

LC.login = function(args)
    args = args or {}
    local cfg = LC.config or {}
    if cfg.dryRun then
        return nil, 'this worker runs with --dry-run: there is no network to log in over'
    end
    if LC.inGame or (LC.transport and not LC.transport.dead) then
        return nil, 'already connected -- logout or relogin first'
    end
    -- Per-call overrides let the hub hand the credential over at login time instead of
    -- at spawn time.  The password is used and dropped inside openSession.
    local one = {}
    for k, v in pairs(cfg) do one[k] = v end
    for _, k in ipairs({ 'account', 'password', 'token', 'character', 'world',
                         'sessionKey', 'loginUrl' }) do
        if args[k] ~= nil then one[k] = args[k] end
    end
    if args.host ~= nil then one.host = args.host end
    if args.port ~= nil then one.port = tonumber(args.port) end
    args.password = nil
    local code, err = openSession(one)
    one.password = nil
    if code then return nil, tostring(err) end
    -- keep everything except the password for a later relogin
    one.password = nil
    LC.config = one
    return { state = LC.loginState, character = LC.characterName, world = LC.worldName,
             host = LC.transport and LC.transport.host, port = LC.transport and LC.transport.port }
end

LC.relogin = function(delayMs)
    local cfg = LC.config or {}
    if cfg.dryRun then
        return nil, 'this worker runs with --dry-run: there is no network to log in over'
    end
    local resume = LC._resume
    if not (resume and resume.sessionKey) and not cfg.sessionKey then
        return nil, 'no session key is held for a relogin: call login {account, password} instead'
    end
    LC.logout()
    sched.after(math.max(0, tonumber(delayMs) or 1500), function()
        local ok, err = LC.login(resume and {
            sessionKey = resume.sessionKey, character = resume.character,
            world = resume.world, host = resume.host, port = resume.port,
        } or {})
        if not ok then
            log.error('relogin failed: %s', tostring(err))
            if LC.control then
                LC.control:broadcast('error', { kind = 'relogin', message = tostring(err) })
            end
        end
    end)
    return { reloginIn = math.max(0, tonumber(delayMs) or 1500) }
end

local function runLive(cfg)
    -- ---- hub-managed boot ---------------------------------------------------
    -- A worker the panel spawned gets NO credentials in argv: hub/process.lua
    -- refuses a secret there, so the hub hands over the control token on stdin
    -- and then sends the account, password, character and world inside the
    -- authenticated `login` command over the loopback control socket (see
    -- hub/supervisor.lua's _afterHandshake).  openSession would refuse such a
    -- start with "--account is required" and the worker would exit 1 into the
    -- supervisor's restart-backoff loop, which is exactly what used to happen:
    -- every hub-managed instance was stuck unless it also carried --dry-run.
    --
    -- So when a control token is present and no credential was given, bring the
    -- control endpoint up FIRST and wait in the reactor for the hub to log us in.
    local deferred = cfg.controlToken and not cfg.account and not cfg.sessionKey
    if not deferred then
        local code, err = openSession(cfg)
        if code then return code, err end
    end

    -- The control endpoint comes up once the session is on its way, so a `status` the
    -- hub asks for immediately already reports a real transport.
    if cfg.controlToken then
        local srv, cerr = startControl(cfg)
        if not srv then return 1, cerr end
        if deferred then
            LC.loginState = 'offline'
            log.info('control: no account was given -- waiting for the hub to send `login`')
        end
    end

    -- Bounded live run: shut down the same way a Ctrl-C would, so the bot storage is saved
    -- and the game socket is closed instead of being killed from outside.
    if cfg.exitAfter and cfg.exitAfter > 0 then
        log.info('--exit-after=%s: this run will disconnect on its own', tostring(cfg.exitAfter))
        sched.after(math.floor(cfg.exitAfter * 1000), function()
            log.info('--exit-after elapsed -- disconnecting')
            shutdown(0)
        end)
    end

    -- 4. loop ----------------------------------------------------------------
    sched.run()
    return LC.exitCode or 0
end

-- =============================================================== entry point
local function main(argv)
    local cfg, perr = parseArgs(argv)
    if not cfg then
        io.stderr:write('luaclient: ', perr, '\n')
        return 1
    end
    LC.config = cfg

    if cfg.help then
        io.stdout:write(USAGE)
        return 0
    end

    -- Secrets (the control token, the proxy credential) are read from stdin or a file
    -- HERE, after --help and before anything else touches them.
    local rcfg, serr = resolveSecrets(cfg)
    if not rcfg then
        io.stderr:write('luaclient: ', tostring(serr), '\n')
        return 1
    end

    log.setLevel(cfg.logLevel)
    if cfg.logFile then
        local ok, ferr = log.setFile(cfg.logFile)
        if not ok then io.stderr:write('luaclient: --log-file: ', tostring(ferr), '\n'); return 1 end
    end

    if cfg.selftest then
        return (dofile(SCRIPT_DIR .. '/test/selftest.lua')) or 0
    end
    if cfg.replay then
        LC.replayTarget = cfg.replay
        return (dofile(SCRIPT_DIR .. '/test/replay.lua')) or 0
    end

    -- items table (both modes need it: the parser cannot decode a tile without it)
    cfg.assetsRoot = cfg.assets or (SCRIPT_DIR .. '/assets')
    local ok, ierr = pcall(items.load, cfg.assets or (SCRIPT_DIR .. '/assets/items1530.bin'))
    if not ok then
        io.stderr:write('luaclient: ', tostring(ierr), '\n')
        return 1
    end

    openCapture(cfg.capture)
    LC.resolveBotProfileDir()

    -- The HTTPS login POST leaves through the same proxy as the game socket, or an
    -- IP-restricted account sees two different source addresses (PANEL.md, and
    -- docs/live-login-notes.md).
    if cfg.proxyHost then
        local http = require('lib.http')
        local okp, perr2 = http.setProxy{ host = cfg.proxyHost, port = cfg.proxyPort,
                                          user = cfg.proxyUser, pass = cfg.proxyPass }
        if not okp then
            io.stderr:write('luaclient: --proxy: ', tostring(perr2), '\n')
            return 1
        end
        log.info('proxy: the HTTPS login will go through %s:%d as well',
                 cfg.proxyHost, cfg.proxyPort)
    end

    if cfg.dryRun then
        return runDryRun(cfg) or 0
    end

    local code, lerr = runLive(cfg)
    if lerr then log.error('%s', lerr) end
    return code or 0
end

local ok, res = xpcall(function() return main(arg or {}) end, function(e)
    -- Graceful shutdown on an unexpected error: one line, no stack trace on stdout.
    -- The traceback goes to the debug log only.
    log.debug('traceback: %s', debug.traceback(tostring(e), 2))
    return tostring(e)
end)

shutdown(ok and res or 3)
pcall(sys.shutdown)

if not ok then
    log.error('fatal: %s', tostring(res))
    os.exit(3)
end
os.exit(tonumber(res) or 0)
