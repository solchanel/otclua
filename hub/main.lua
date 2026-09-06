--[[============================================================================
hub/main.lua -- the hub process: CLI, first-run bootstrap, wiring, shutdown.

    luajit hub/main.lua [options]

    --port=N              TCP port                              (default 8777)
    --bind=ADDR           bind address                     (default 127.0.0.1)
    --data-dir=DIR        users/accounts/instances/audit  (default ./hub-data)
    --panel-dir=DIR       static files to serve               (default ./panel)
    --workers-dir=DIR     cwd for the workers; main.lua lives here  (default .)
    --luajit=PATH         interpreter used to spawn workers  (default: our own)
    --worker-script=PATH  relative to --workers-dir            (default main.lua)
    --allow-insecure      permit a non-loopback bind (see the warning below)
    --csrf-strict         require X-CSRF-Token on every mutating request
    --log-level=LEVEL     debug|info|warn|error                    (default info)
    --log-file=PATH       append the hub's own log there
    --no-autostart        do not start instances flagged autoStart
    --proxy-test-target=H:P   what `proxy.test` CONNECTs to  (default example.com:443)
    --game-host=HOST      game-server address handed to every worker's `login`
    --login-url=URL      the account-login endpoint the worker POSTs to
    --game-port=N         its port.  Both optional: without them the worker uses
                          whatever the HTTPS login reply names, which is the
                          normal case.
    --help

FIRST RUN.  With no accounts on disk the hub prints a one-time bootstrap token to
stdout and serves nothing but `auth.session` / `auth.bootstrap` until the first
administrator has been created with it (PANEL.md).  The token is never written to
the log file and never leaves stdout.

SECURITY.  The hub speaks plain HTTP.  It binds 127.0.0.1 and REFUSES any other
address unless --allow-insecure is given, in which case it logs a banner and
tells the panel to draw one (`auth.session.insecure`).  Put nginx/Caddy or an SSH
tunnel in front to expose it.

SHUTDOWN.  Every worker is stopped before the hub exits.
  * Linux: SIGINT/SIGTERM/SIGHUP are BLOCKED at startup and collected with
    sigtimedwait(2) from the reactor loop.  No async signal handler ever enters
    the Lua VM (LuaJIT callbacks from a signal context are undefined behaviour);
    the reactor simply notices a pending signal on its next turn and starts an
    orderly shutdown: stop every worker, flush telemetry, close the listener.
  * Windows: there is no safe way to run Lua from a console control handler, so
    Ctrl+C ends the process directly -- and lib/process.lua has already put every
    worker in a job object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, so the kernel
    reaps them all when the hub's handle closes.  sys.atExit() covers the orderly
    path (a normal exit, os.exit, an unhandled error).

Lua 5.1 / LuaJIT: no goto, math.floor for integer division.
============================================================================]]

local ROOT
do
  local src = debug.getinfo(1, 'S').source
  local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
  ROOT = (dir .. '/..'):gsub('\\', '/')
  package.path = ROOT .. '/?.lua;' .. package.path
end

local sys   = require('lib.sys')
local log   = require('lib.log')
local sched = require('lib.sched')
local json  = require('lib.json')

local M = {}
M.ROOT = ROOT

local floor = math.floor

-- ===================================================== structured logging ====
--- `event=<name> k=v k=v` -- greppable, one line, no secrets.  Values that
--- contain a space or a quote are quoted; nothing is ever formatted through
--- string.format with caller data.
local function kv(v)
  v = tostring(v)
  if v:find('[%s"=]') then return '"' .. v:gsub('"', "'") .. '"' end
  return v
end

local function slog(level, event, fields)
  local parts = { 'event=' .. kv(event) }
  local keys = {}
  for k in pairs(fields or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. '=' .. kv(fields[k]) end
  log[level](table.concat(parts, ' '))
end
M.slog = slog

-- ==================================================================== CLI ====
local function usage()
  io.write((debug.getinfo(1, 'S').source:sub(2)), '\n')
  local text = [[
  --port=N              TCP port                              (default 8777)
  --bind=ADDR           bind address                     (default 127.0.0.1)
  --data-dir=DIR        data directory                  (default ./hub-data)
  --panel-dir=DIR       static files                        (default ./panel)
  --workers-dir=DIR     worker cwd                                (default .)
  --luajit=PATH         interpreter for workers          (default: our own)
  --worker-script=PATH  worker entry point               (default main.lua)
  --allow-insecure      permit a non-loopback bind (implies --csrf-strict)
  --csrf-strict         require X-CSRF-Token on mutating requests
  --allowed-host=NAME   extra Host header this hub answers to (repeatable).  A
                        non-loopback bind answers to its own bind address and to
                        these names ONLY -- that is the DNS-rebinding guard.
  --trusted-proxy=CIDR  believe X-Forwarded-For from this front end (repeatable,
                        IPv4).  Without it every request behind a reverse proxy
                        shares one rate-limiter bucket.
  --log-level=LEVEL     debug|info|warn|error                 (default info)
  --log-file=PATH       append the hub log
  --no-autostart        ignore the autoStart flag
  --proxy-test-target=H:P  CONNECT target for proxy.test
  --game-host=HOST      game server the workers log in to (optional)
  --game-port=N         its port                          (optional)
  --login-url=URL       account-login endpoint the workers POST to (optional;
                        the worker's own default is used when it is not given)
  --worker-env=K=V      extra environment for every worker (repeatable).  For
                        settings, never for a credential -- those go on stdin.
  --worker-arg=FLAG     extra flag for every worker (repeatable)
  --help
]]
  io.write(text)
end

function M.parseArgs(argv)
  local o = {
    port = 8777, bind = '127.0.0.1',
    dataDir = ROOT .. '/hub-data', panelDir = ROOT .. '/panel',
    workersDir = ROOT, workerScript = 'main.lua',
    luajit = nil, allowInsecure = false, csrfStrict = false,
    logLevel = 'info', logFile = nil, autostart = true, allowedHosts = {}, trustedProxies = {},
    proxyTestTarget = 'example.com:443',
    gameHost = nil, gamePort = nil, loginUrl = nil, workerArgs = {}, workerEnv = nil,
  }
  for i = 1, #(argv or {}) do
    local a = tostring(argv[i])
    local k, v = a:match('^%-%-([%w%-]+)=(.*)$')
    if not k then k, v = a:match('^%-%-([%w%-]+)$'), true end
    if k == 'port' then o.port = tonumber(v) or o.port
    elseif k == 'bind' then o.bind = v
    elseif k == 'data-dir' then o.dataDir = (tostring(v):gsub('\\', '/'))
    elseif k == 'panel-dir' then o.panelDir = (tostring(v):gsub('\\', '/'))
    elseif k == 'workers-dir' then o.workersDir = (tostring(v):gsub('\\', '/'))
    elseif k == 'worker-script' then o.workerScript = v
    elseif k == 'luajit' then o.luajit = (tostring(v):gsub('\\', '/'))
    elseif k == 'allow-insecure' then o.allowInsecure = true
    elseif k == 'csrf-strict' then o.csrfStrict = true
    elseif k == 'allowed-host' then o.allowedHosts[#o.allowedHosts + 1] = tostring(v):lower()
    elseif k == 'trusted-proxy' then o.trustedProxies[#o.trustedProxies + 1] = tostring(v)
    elseif k == 'log-level' then o.logLevel = tostring(v)
    elseif k == 'log-file' then o.logFile = tostring(v)
    elseif k == 'no-autostart' then o.autostart = false
    elseif k == 'proxy-test-target' then o.proxyTestTarget = tostring(v)
    elseif k == 'game-host' then o.gameHost = tostring(v)
    elseif k == 'game-port' then o.gamePort = tonumber(v)
    elseif k == 'login-url' then o.loginUrl = tostring(v)
    elseif k == 'worker-arg' then o.workerArgs[#o.workerArgs + 1] = tostring(v)
    elseif k == 'worker-env' then
      local key, val = tostring(v):match('^([^=]+)=(.*)$')
      if not key then return nil, '--worker-env needs NAME=VALUE' end
      o.workerEnv = o.workerEnv or {}
      o.workerEnv[key] = val
    elseif k == 'help' or k == 'h' then o.help = true
    elseif k then return nil, 'unknown option: --' .. k end
  end
  return o
end

--- Best guess at the interpreter running us, so --luajit is optional in the
--- common case.  arg[-1] is what the shell actually invoked.
local function selfInterpreter()
  local a = rawget(_G, 'arg')
  if type(a) == 'table' then
    local i = -1
    local best = nil
    while a[i] do best = a[i]; i = i - 1 end
    if best then return (tostring(best):gsub('\\', '/')) end
  end
  return sys.isWindows and 'luajit.exe' or 'luajit'
end
M.selfInterpreter = selfInterpreter

-- ======================================================= POSIX signal gate ===
-- Blocked signals collected by polling.  No callback ever runs in signal context.
local signals = { enabled = false, pending = nil }

local function installSignalGate()
  if not sys.isLinux then return false end
  local ok, ffi = pcall(require, 'ffi')
  if not ok then return false end
  local okc = pcall(ffi.cdef, [[
    typedef struct { unsigned long __lc_val[16]; } lc_sigset_t;
    typedef struct { long lc_tv_sec; long lc_tv_nsec; } lc_timespec_t;
    int sigemptyset(lc_sigset_t *set);
    int sigaddset(lc_sigset_t *set, int signum);
    int sigprocmask(int how, const lc_sigset_t *set, lc_sigset_t *oldset);
    int sigtimedwait(const lc_sigset_t *set, void *info, const lc_timespec_t *timeout);
  ]])
  if not okc then return false end
  local set = ffi.new('lc_sigset_t')
  local ts  = ffi.new('lc_timespec_t')
  ts.lc_tv_sec, ts.lc_tv_nsec = 0, 0
  local okRun = pcall(function()
    ffi.C.sigemptyset(set)
    ffi.C.sigaddset(set, 2)     -- SIGINT
    ffi.C.sigaddset(set, 15)    -- SIGTERM
    ffi.C.sigaddset(set, 1)     -- SIGHUP
    ffi.C.sigprocmask(0, set, nil)   -- SIG_BLOCK
  end)
  if not okRun then return false end
  signals.enabled = true
  signals.poll = function()
    local n = ffi.C.sigtimedwait(set, nil, ts)
    if n and n > 0 then return tonumber(n) end
    return nil
  end
  return true
end
M.installSignalGate = installSignalGate

-- ===================================================================== run ===
--- Build every hub object and start listening.  Returns a `hub` table; the caller
--- runs the reactor.  Split out of main() so the test suite can drive it.
function M.build(o)
  local storage    = require('hub.storage')
  local model      = require('hub.model')
  local authMod    = require('hub.auth')
  local auditMod   = require('hub.audit')
  local authsecret = require('lib.authsecret')
  local supervisor = require('hub.supervisor')
  local telemetry  = require('hub.telemetry')
  local apiMod     = require('hub.api')
  local serverMod  = require('hub.server')

  local store, se = storage.open(o.dataDir, { log = log })
  if not store then return nil, 'cannot open the data dir: ' .. tostring(se) end

  -- secret.key: created on first run, 0600 on POSIX.  Everything sealed at rest
  -- (game-account and proxy passwords) hangs off this one file.
  --
  -- lib/authsecret.lua refuses to mint a new master secret unless the caller has
  -- LOOKED at the surrounding state, and it is right to: a missing key file is
  -- far more often a wrong --data-dir or an unmounted volume than a first run,
  -- and minting one there would make every stored password undecryptable while
  -- reporting it as tampering.  So the decision is made here, from the data:
  -- allowCreate only when nothing sealed exists yet.
  local sealed = 0
  for _, kind in ipairs{ 'accounts', 'proxies' } do
    for _, row in ipairs(store:items(kind) or {}) do
      for _, field in ipairs{ 'password', 'token2fa', 'pass' } do
        local v = row[field]
        if type(v) == 'string' and v:sub(1, 4) == 'sbx$' then sealed = sealed + 1 end
      end
    end
  end
  local box, be = authsecret.open(o.dataDir .. '/secret.key', { allowCreate = (sealed == 0) })
  if not box then return nil, 'cannot open secret.key: ' .. tostring(be) end
  if be == true then slog('info', 'hub.secret', { created = 'secret.key' }) end
  if sealed > 0 then slog('debug', 'hub.secret', { sealedRecords = sealed }) end

  local db, de = model.attach(store, { secret = box })
  if not db then return nil, 'cannot attach the data model: ' .. tostring(de) end
  local intact, problems = db:checkIntegrity()
  if not intact then
    for _, p in ipairs(problems or {}) do slog('warn', 'model.integrity', { problem = p }) end
  end

  local audit, ae = auditMod.open{ dir = o.dataDir, log = log }
  if not audit then return nil, 'cannot open the audit log: ' .. tostring(ae) end
  local auth, aue = authMod.open{ db = db, secret = box, log = log }
  if not auth then return nil, 'cannot open auth: ' .. tostring(aue) end

  local hub = { o = o, storage = store, db = db, model = db, auth = auth, audit = audit,
                secret = box }

  hub.sup = supervisor.new{
    audit = audit, log = log, sched = sched, logLevel = o.logLevel,
    luajit = o.luajit, workersDir = o.workersDir, workerScript = o.workerScript,
    extraArgs = o.workerArgs, workerEnv = o.workerEnv,
  }
  hub.tel = telemetry.new{ sup = hub.sup, storage = store, log = log, sched = sched,
                           dataDir = o.dataDir }

  -- hub/telemetry.lua persists its rings through a tiny file API; hub/storage.lua's
  -- store is a collection store, so give telemetry the three calls it needs on top
  -- of storage.fs rather than teaching either side about the other.
  local fs = storage.fs
  local histDir = o.dataDir .. '/history'
  hub.tel.storage = {
    dir = o.dataDir,
    writeFile = function(_, rel, data)
      local ok, e = fs.mkdirp(histDir)
      if not ok then return nil, e end
      return fs.writeDurable(o.dataDir .. '/' .. rel, data)
    end,
    readFile   = function(_, rel) return fs.readFile(o.dataDir .. '/' .. rel) end,
    deleteFile = function(_, rel) return fs.remove(o.dataDir .. '/' .. rel) end,
  }

  -- hub/model.lua's `state` enum is narrower than the supervisor's lifecycle, and
  -- deliberately so: what is worth persisting is "was this meant to be running",
  -- not which millisecond of the handshake it is in.
  local PERSIST_STATE = {
    stopped = 'stopped', starting = 'starting', running = 'starting',
    connecting = 'starting', backoff = 'starting', online = 'online',
    stopping = 'stopping', error = 'error',
  }

  hub.sup.onEvent = function(id, event, data) hub.tel:onWorkerEvent(id, event, data) end
  hub.sup.onLog   = function(id, line) hub.tel:onWorkerLog(id, line) end
  hub.sup.onState = function(id, state, detail)
    hub.tel:onState(id, state, detail)
    slog('info', 'instance.state', { instance = id, state = state, detail = detail or '' })
    local mapped = PERSIST_STATE[state]
    if mapped then pcall(function() db:update('instances', id, { state = mapped }) end) end
  end

  hub.api = apiMod.new{
    db = db, auth = auth, audit = audit, sup = hub.sup, tel = hub.tel,
    storage = store, dataDir = o.dataDir,
    log = log, sched = sched, version = o.version or 'hub-1.0',
    workersDir = o.workersDir, proxyTestTarget = o.proxyTestTarget,
    gameHost = o.gameHost, gamePort = o.gamePort, loginUrl = o.loginUrl,
  }
  -- A restart must decrypt the game credential afresh (hub/supervisor.lua's
  -- startInstance says why); launchSpec is the only place that decrypts.
  hub.sup.specProvider = function(instanceId)
    local inst = db:get('instances', tostring(instanceId))
    if not inst then return nil, 'the instance is gone' end
    return hub.api:launchSpec(inst)
  end

  hub.server = serverMod.new{
    host = o.bind, port = o.port, panelDir = o.panelDir,
    api = hub.api, auth = auth, tel = hub.tel, log = log, sched = sched,
    allowInsecure = o.allowInsecure, csrfStrict = o.csrfStrict,
    allowedHosts = o.allowedHosts, trustedProxies = o.trustedProxies,
    version = o.version or 'hub-1.0',
  }

  -- housekeeping: expired sessions and stale rate-limiter buckets
  sched.every(60000, function() pcall(function() auth:sweep() end) end)

  local ids = {}
  for _, i in ipairs(db:list('instances')) do ids[#ids + 1] = i.id end
  hub.tel:load(ids)

  local port, perr = hub.server:start()
  if not port then return nil, perr end
  hub.port = port
  hub.sup:install()
  hub.tel:install()

  -- Every instance starts from disk as 'stopped': a state left over from a hub
  -- that was killed describes a process that no longer exists.
  for _, i in ipairs(db:list('instances')) do
    if i.state and i.state ~= 'stopped' then
      pcall(function() db:update('instances', i.id, { state = 'stopped' }) end)
    end
  end
  return hub
end

--- Start every instance flagged autoStart.  Audited as `system`.
function M.autostart(hub)
  local started = 0
  for _, inst in ipairs(hub.db:list('instances')) do
    if inst.autoStart then
      local spec, e = hub.api:launchSpec(inst)
      if spec then
        local ok, se = hub.sup:startInstance(inst.id, spec)
        spec = nil
        if hub.audit then
          pcall(function()
            hub.audit:system('instance.start', inst.id, ok and 'ok' or 'error',
                             ok and 'autoStart' or ('autoStart: ' .. tostring(se)))
          end)
        end
        if ok then started = started + 1
        else slog('warn', 'autostart.failed', { instance = inst.id, err = tostring(se) }) end
      else
        slog('warn', 'autostart.failed', { instance = inst.id, err = tostring(e) })
        if hub.audit then
          pcall(function()
            hub.audit:system('instance.start', inst.id, 'error', tostring(e))
          end)
        end
      end
    end
  end
  return started
end

function M.shutdown(hub, why)
  if hub.shuttingDown then return end
  hub.shuttingDown = true
  slog('info', 'hub.shutdown', { reason = why or 'exit', workers = hub.sup:runningCount() })
  hub.server:stop()
  hub.tel:flush()
  hub.tel:uninstall()
  hub.sup:shutdownAll(4000)
  -- give the children their grace period on the reactor, then reap for real
  local deadline = sys.nowMs() + 6000
  sched.every(100, function()
    if hub.sup:allStopped() or sys.nowMs() > deadline then
      hub.sup:reap(2000)
      sched.stop()
    end
  end)
end

function M.main(argv)
  local o, e = M.parseArgs(argv)
  if not o then io.stderr:write(tostring(e), '\n'); usage(); return 2 end
  if o.help then usage(); return 0 end
  log.setLevel(o.logLevel)
  if o.logFile then log.setFile(o.logFile) end
  o.luajit = o.luajit or selfInterpreter()

  slog('info', 'hub.start', { version = 'hub-1.0', os = sys.os, bind = o.bind, port = o.port,
                              dataDir = o.dataDir, workersDir = o.workersDir,
                              luajit = o.luajit, insecure = tostring(o.allowInsecure) })

  local hub, be = M.build(o)
  if not hub then
    io.stderr:write('hub: ', tostring(be), '\n')
    return 1
  end

  if hub.auth:needsBootstrap() then
    local token = hub.auth:bootstrapToken()
    io.write('\n')
    io.write('================================================================\n')
    io.write(' FIRST RUN -- no web accounts exist yet.\n')
    io.write(' Open  http://', o.bind, ':', tostring(hub.port), '/  and create the\n')
    io.write(' administrator with this one-time bootstrap token:\n\n')
    io.write('     ', tostring(token), '\n\n')
    io.write(' It is printed here only, never to the log file.\n')
    io.write('================================================================\n\n')
    io.stdout:flush()
    slog('info', 'hub.bootstrap', { state = 'waiting' })
  elseif o.autostart then
    local n = M.autostart(hub)
    slog('info', 'hub.autostart', { started = n })
  end

  installSignalGate()
  if signals.enabled then
    sched.every(200, function()
      local sig = signals.poll()
      if sig then M.shutdown(hub, 'signal ' .. tostring(sig)) end
    end)
    slog('debug', 'hub.signals', { mode = 'sigtimedwait', signals = 'INT,TERM,HUP' })
  else
    slog('debug', 'hub.signals', { mode = 'atexit-only', os = sys.os })
  end
  sys.atExit(function() pcall(function() hub.tel:flush(); hub.sup:reap(2000) end) end)

  sched.run()
  hub.sup:reap(2000)
  hub.tel:flush()
  slog('info', 'hub.stopped', {})
  return 0
end

-- Run only when this file is the script the interpreter was given -- never when a
-- test or another module require()s it.  Comparing arg[0] to our own chunk name is
-- exact; matching 'main%.lua$' would also fire for the WORKER's main.lua.
do
  local a = rawget(_G, 'arg')
  local invoked = (type(a) == 'table') and a[0] or nil
  local src = debug.getinfo(1, 'S').source
  if invoked and src:sub(1, 1) == '@' and not rawget(_G, 'HUB_NO_MAIN') then
    local lhs = tostring(invoked):gsub('\\', '/')
    local rhs = src:sub(2):gsub('\\', '/')
    if lhs == rhs then
      os.exit(M.main(a) or 0)
    end
  end
end

return M
