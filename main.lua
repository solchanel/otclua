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

Modes
  --dry-run                offline: no sockets, no HTTPS; exercises the whole
                           wiring (items, login packet, framing, parser, events)
  --selftest               run test/selftest.lua and exit with its status
  --replay=FILE            run test/replay.lua over FILE and exit
  -h, --help               this text

Exit codes: 0 ok, 1 usage/config error, 2 login refused by the server,
            3 protocol/runtime failure.
]]

local function parseArgs(argv)
    local cfg = {
        logLevel = 'info',
        pingMs   = 10000,
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
        or name == 'session-key' then
            v, err = valueOf(name, inline)
            if not v then return nil, err end
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
        elseif name == 'bot-profile' then cfg.botProfile = v
        elseif name == 'bot-vprofile' then cfg.botVProfile = tonumber(v)
        elseif name == 'cavebot'   then cfg.cavebot = v; cfg.bot = true
        elseif name == 'targetbot' then cfg.targetbot = v; cfg.bot = true
        elseif name == 'bot-status-interval' then cfg.botStatusMs = tonumber(v)
        elseif name == 'minimap'   then cfg.minimap = v
        elseif name == 'selftest'  then cfg.selftest = true
        elseif name == 'help'      then cfg.help = true
        else return nil, ('unknown flag --%s (try --help)'):format(name)
        end
        i = i + 1
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
LC.stopBot  = stopBot
LC.startBot = function() return startBot(LC.config or {}) end

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

    -- every event may have moved hp/mana/level/pos
    events.onAny(function() statusLine(false) end)

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

    events.on('challenge', function(d)
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

    events.on('pending', function()
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
    events.on('gameStart', function() armPing('game started') end)
    events.on('login', function(d)
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
    events.on('ping', function()
        if LC.transport and not LC.transport.dead then LC.sender:pingBack() end
    end)
    events.on('pingBack', function()
        -- 0x1E is the PONG for our keepalive: turn it into the RTT the bot layer's
        -- step timing, smooth-walk pacer and cooldown ping compensation all read.
        if LC.pingSentAt then
            local rtt = sys.nowMs() - LC.pingSentAt
            LC.pingSentAt = nil
            if rtt >= 0 and rtt < 5000 and LC.state then LC.state.ping = math.floor(rtt) end
        end
        log.debug('pong from server (latency %s ms)', tostring(LC.state and LC.state.ping))
    end)

    events.on('loginError', function(d) fatal(2, 'login refused: %s', tostring(d.message)) end)
    events.on('loginWait',  function(d) log.warn('login wait: %s (%s s)', tostring(d.message), tostring(d.time)) end)
    events.on('loginAdvice', function(d) log.info('server: %s', tostring(d.message)) end)
    events.on('sessionEnd', function(d) fatal(0, 'session ended by the server (reason %s)', tostring(d.reason)) end)
    events.on('death', function() log.warn('the character has died') end)
    events.on('talk', function(d)
        log.info('talk [%s] %s: %s', tostring(d.mode), tostring(d.name), tostring(d.text))
    end)
    events.on('textMessage', function(d)
        log.info('message [%s] %s', tostring(d.mode), tostring(d.text))
    end)

    return st, p, s
end

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
        stopBot()
    end

    log.info('--dry-run OK: items, login packet, framing, parser, events and the ping rules all wired')
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

local function runLive(cfg)
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
    t = transport.new{
        host = host, port = port,
        worldName = worldName,                         -- set BEFORE connect()
        onConnect = function()
            log.info('connected to %s:%d, world preamble sent', host, port)
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
    login.sessionKey = nil

    local ok, cerr = t:connect()
    if not ok then return 3, ('connect failed: %s'):format(tostring(cerr)) end

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
