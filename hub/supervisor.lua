--[[============================================================================
hub/supervisor.lua -- one worker process per instance, spawned, watched, stopped.

  local supervisor = require('hub.supervisor')
  local sup = supervisor.new{
      model      = model,                 -- hub/model.lua (read-only here)
      audit      = audit,                 -- hub/audit.lua (optional)
      luajit     = 'D:/.../luajit.exe',   -- interpreter for the worker
      workersDir = ROOT,                  -- cwd of the worker; main.lua lives here
      workerScript = 'main.lua',
      onEvent      = function(instanceId, event, data) ... end,
      onLog        = function(instanceId, line) ... end,
      onState      = function(instanceId, state, detail) ... end,
  }
  sup:install()                           -- installs the sched timers
  sup:startInstance(id)  sup:stopInstance(id)  sup:restartInstance(id)
  sup:command(id, 'exec', { code = '...' }, function(ok, res) ... end)
  sup:shutdownAll(graceMs)                -- also wired to sys.atExit / SIGINT

================================================================================
THE WORKER CONTROL PROTOCOL -- control/server.lua + control/commands.lua
================================================================================
argv (NO SECRETS -- lib/process.lua refuses them, and main.lua's own CLI says so):

    <luajit> main.lua --control-port=0 --control-bind=127.0.0.1
                      --control-token-fd=0 --instance-name=<character>
                      [--proxy=<host>:<port> --proxy-auth=fd:0]
                      [--bot-profile=<dir>] [--log-level=<level>]

stdin, one line per stdin-fed flag IN THE ORDER THE FLAGS APPEAR:
    1. the control token   (--control-token-fd=0)
    2. "user:pass" for the proxy, when there is one   (--proxy-auth=fd:0)
A private anonymous pipe with exactly two ends.  Nothing reaches /proc, ps, WMI
or an ETW process-start event.

stdout: main.lua announces the endpoint it settled on, once:

    control-endpoint <bind> <port> <instance-name>

Every other stdout/stderr line is an ordinary log line and lands in the per-
instance ring buffer (and, live, on subscribed panel sockets).  The worker MUST
keep stdout UNBUFFERED: the MSVC CRT turns line buffering into full buffering on
a pipe, and the announcement would then arrive after the spawn deadline.

transport: the hub opens ONE WebSocket to  ws://127.0.0.1:<port>/ws?token=<tok>
(also sending Authorization: Bearer <tok>), and uses it for both halves, which is
what control/server.lua's /ws does:
    hub -> worker  a TEXT message   {"id":N,"cmd":"...","args":{...}}
    worker -> hub  a TEXT message   {"id":N,"ok":true,"result":...}
                                    {"id":N,"ok":false,"error":{...}}
                   pushes           {"event":"...","data":{...}}
The handshake IS the authentication: an accepted 101 means the token was right.
POST /rpc exists too and is left alone -- one socket is one thing to time out.

The game-account password is NOT in argv and NOT on stdin: it goes in the
`login` command over that authenticated loopback socket, once, and the hub drops
its copy in the same callback.

commands  status login logout relogin bot.enable bot.setCavebot bot.setTargetbot
          bot.listConfigs bot.reload script.put script.remove script.list exec
          stats debug.snapshot shutdown
events    status stats debug log chat loginState gameStart gameEnd death error

================================================================================
LIFECYCLE
================================================================================
  stopped -> starting -> (control-endpoint line + WS handshake) -> running
  running -> connecting -> online           (the `login` command, then loginState)
  running  + loginState -> the panel-visible state ('connecting' / 'online')
  running -> stopping -> stopped            (shutdown cmd, then stdin EOF/SIGTERM)
  any     -> backoff  -> starting           (unexpected exit, autoRelogin on)
  any     -> error                          (retries exhausted, or spawn refused)

Restart backoff is exponential from `restartBaseMs` (1 s), doubling to
`restartMaxMs` (60 s), with +-20% jitter, reset to zero once a worker has been
healthy for `healthyResetMs` (60 s).  `maxRestarts` (0 = unlimited) caps the
consecutive attempts; past it the instance parks in 'error' until an operator
starts it again.

Health: a `status` command every `healthMs` (5 s).  `healthMissLimit` (3)
consecutive misses -- no answer inside `commandTimeoutMs` -- kills the worker,
which then follows the ordinary restart path.

NOTHING here blocks the reactor: the spawn is lib/process.lua's non-blocking
fork/CreateProcess, the control socket is a lib/socket.lua non-blocking socket
driven by sched.onSocket, and every wait is a sched timer.  The only blocking
call in the file is process.reapAll() on the final shutdown path.

Lua 5.1 / LuaJIT: no goto, math.floor for integer division.
============================================================================]]

local socket   = require('lib.socket')
local sched    = require('lib.sched')
local sys      = require('lib.sys')
local json     = require('lib.json')
local process  = require('lib.process')
local base64   = require('lib.base64')
local wsserver = require('lib.wsserver')   -- acceptKey() only; this is a CLIENT
local bit      = require('bit')

local band, bxor = bit.band, bit.bxor
local schar, sbyte, ssub = string.char, string.byte, string.sub
local concat = table.concat

--- Percent-encode everything outside the unreserved set, so a token can never
--- terminate the query string or introduce a second parameter.
local function urlEncode(s)
  return (tostring(s):gsub('[^%w%-%._~]', function(c)
    return string.format('%%%02X', c:byte())
  end))
end

local M = {}

local floor = math.floor

-- ============================================================ small helpers ==
local function nowMs() return sys.nowMs() end

local function hex(n)
  local b = sys.randomBytes(n)
  return (b:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end
M.newToken = function() return hex(32) end

local function jitter(ms)
  -- +-20 %, from the OS CSPRNG so two hubs restarted together do not sync up
  local r = (sys.randomU32() % 4001) / 10000.0    -- 0 .. 0.4
  return floor(ms * (0.8 + r))
end

local function truthy(v) return v ~= nil and v ~= false end

-- =========================================================== the ring buffer =
local Ring = {}
Ring.__index = Ring

local function newRing(cap)
  return setmetatable({ cap = cap or 800, n = 0, head = 1, items = {}, seq = 0 }, Ring)
end

function Ring:push(v)
  self.seq = self.seq + 1
  if self.n < self.cap then
    self.items[(self.head + self.n - 1) % self.cap + 1] = v
    self.n = self.n + 1
  else
    self.items[self.head] = v
    self.head = self.head % self.cap + 1
  end
  return v
end

function Ring:tail(limit)
  limit = math.min(tonumber(limit) or self.n, self.n)
  local out = {}
  local start = self.n - limit
  for i = 1, limit do
    out[i] = self.items[(self.head + start + i - 2) % self.cap + 1]
  end
  return out
end

function Ring:clear() self.n, self.head, self.items = 0, 1, {} end
M.newRing = newRing

-- ====================================================== the control client ===
-- control/server.lua speaks two transports over ONE authenticated HTTP endpoint:
-- POST /rpc for request/response, and GET /ws for both (a TEXT message is a
-- request object, the answer comes back as a TEXT message, and `{event,data}`
-- pushes arrive on the same socket).  The hub uses /ws ONLY -- one connection
-- carries commands and telemetry, so there is one thing to open, one to
-- authenticate, one to time out, and one to notice when the worker dies.
--
-- That makes this a WebSocket CLIENT, which lib/wsserver.lua (a server) is not:
-- the handshake, MASKED client frames (RFC 6455 5.1), unmasked server frames
-- with continuation reassembly, and ping/pong.  Nothing here blocks.

local Ctl = {}
Ctl.__index = Ctl

local OP_CONT, OP_TEXT, OP_BIN, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA

local function maskBytes(payload, key)
  local n = #payload
  if n == 0 then return '' end
  local out, chunk, ci = {}, {}, 0
  for i = 1, n do
    ci = ci + 1
    chunk[ci] = schar(bxor(sbyte(payload, i), sbyte(key, ((i - 1) % 4) + 1)))
    if ci == 4096 then out[#out + 1] = concat(chunk); chunk, ci = {}, 0 end
  end
  if ci > 0 then out[#out + 1] = concat(chunk, '', 1, ci) end
  return concat(out)
end

local function clientFrame(op, payload)
  payload = payload or ''
  local n = #payload
  local key = sys.randomBytes(4)
  local hdr
  if n < 126 then
    hdr = schar(0x80 + op, 0x80 + n)
  elseif n < 65536 then
    hdr = schar(0x80 + op, 0xFE, floor(n / 256), n % 256)
  else
    local b, v = {}, n
    for i = 8, 1, -1 do b[i] = v % 256; v = floor(v / 256) end
    hdr = schar(0x80 + op, 0xFF, b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8])
  end
  return hdr .. key .. maskBytes(payload, key)
end
M.clientFrame = clientFrame

local function newCtl(opts)
  return setmetatable({
    host = opts.host, port = opts.port, token = opts.token,
    onFrame = opts.onFrame, onClose = opts.onClose, onOpen = opts.onOpen,
    maxMessage = opts.maxMessage or (4 * 1024 * 1024),
    rx = '', rpos = 1, nextId = 1, waiting = {}, state = 'connecting',
    sock = nil, openedAt = nowMs(), handshook = false,
    frag = nil, fragOp = nil,
  }, Ctl)
end

function Ctl:_die(err)
  if self.state == 'closed' then return end
  self.state = 'closed'
  if self.sock then
    pcall(function() sched.removeSocket(self.sock) end)
    pcall(function() self.sock:close() end)
    self.sock = nil
  end
  local waiting = self.waiting
  self.waiting = {}
  for _, w in pairs(waiting) do
    if w.cb then pcall(w.cb, false, { code = 'closed', message = err or 'control link closed' }) end
  end
  if self.onClose then pcall(self.onClose, err) end
end

function Ctl:close(err) self:_die(err or 'closed by hub') end

function Ctl:connect()
  local s, err = socket.tcp()
  if not s then return nil, err end
  self.sock = s
  local ok, cerr = s:connect(self.host, self.port)
  if not ok then self.sock = nil; pcall(function() s:close() end); return nil, cerr end
  local self_ = self
  sched.onSocket(s,
    function() self_:_readable() end,
    function() self_:_writable() end)
  return true
end

function Ctl:_writable()
  if self.state ~= 'connecting' then
    if self.sock then self.sock:flush() end
    return
  end
  if not self.sock:isConnected() then
    if self.sock.state == 'error' then self:_die(self.sock.err or 'connect failed') end
    return
  end
  self.state = 'opening'
  -- Both accepted forms are sent: the Authorization header (what control/server.lua
  -- prefers) and the query parameter it also honours on a handshake.  The token is
  -- percent-encoded so it cannot terminate the query or add a second parameter, and
  -- the connection is loopback-only.
  self.wsKey = base64.encode(sys.randomBytes(16))
  local req = {
    'GET /ws?token=' .. urlEncode(self.token) .. ' HTTP/1.1',
    'Host: ' .. self.host .. ':' .. tostring(self.port),
    'Upgrade: websocket',
    'Connection: Upgrade',
    'Authorization: Bearer ' .. self.token,
    'Sec-WebSocket-Key: ' .. self.wsKey,
    'Sec-WebSocket-Version: 13',
  }
  local n, serr = self.sock:send(concat(req, '\r\n') .. '\r\n\r\n')
  if not n then self:_die(serr) end
end

function Ctl:_readable()
  if self.state == 'closed' or not self.sock then return end
  if self.state == 'connecting' then self:_writable() end
  while true do
    local d, err = self.sock:recv(65536)
    if d == nil then self:_die(err or 'closed'); return end
    if d == '' then break end
    self.rx = self.rx .. d
    if #self.rx > self.maxMessage * 2 then self:_die('control stream too large'); return end
  end
  if not self.handshook then
    local i = self.rx:find('\r\n\r\n', 1, true)
    if not i then return end
    local head = self.rx:sub(1, i - 1)
    self.rx, self.rpos = self.rx:sub(i + 4), 1
    local status = tonumber(head:match('^HTTP/1%.%d (%d+)'))
    if status ~= 101 then
      self:_die('control handshake refused: HTTP ' .. tostring(status))
      return
    end
    local accept = head:match('[Ss]ec%-[Ww]eb[Ss]ocket%-[Aa]ccept:%s*([^\r\n]+)')
    if accept then accept = accept:match('^%s*(.-)%s*$') end
    if accept ~= wsserver.acceptKey(self.wsKey) then
      self:_die('control handshake: bad Sec-WebSocket-Accept')
      return
    end
    self.handshook = true
    self.state = 'open'
    if self.onOpen then pcall(self.onOpen, self) end
    if self.state == 'closed' then return end
  end
  self:_parse()
end

function Ctl:_parse()
  while true do
    local buf, pos = self.rx, self.rpos
    if #buf - pos + 1 < 2 then break end
    local b1, b2 = sbyte(buf, pos), sbyte(buf, pos + 1)
    local fin = band(b1, 0x80) ~= 0
    local op  = band(b1, 0x0F)
    if band(b1, 0x70) ~= 0 then self:_die('control frame with an RSV bit set'); return end
    if band(b2, 0x80) ~= 0 then self:_die('the worker masked a server frame'); return end
    local len = band(b2, 0x7F)
    local at = pos + 2
    if len == 126 then
      if #buf - at + 1 < 2 then break end
      len = sbyte(buf, at) * 256 + sbyte(buf, at + 1); at = at + 2
    elseif len == 127 then
      if #buf - at + 1 < 8 then break end
      len = 0
      for i = 0, 7 do len = len * 256 + sbyte(buf, at + i) end
      at = at + 8
    end
    if len > self.maxMessage then self:_die('control frame over the size cap'); return end
    if #buf - at + 1 < len then break end
    local payload = ssub(buf, at, at + len - 1)
    self.rpos = at + len
    if self.rpos > 65536 then
      self.rx = ssub(self.rx, self.rpos)
      self.rpos = 1
    end

    if op == OP_PING then
      if self.sock then self.sock:send(clientFrame(OP_PONG, payload)) end
    elseif op == OP_PONG then                      -- nothing to do
    elseif op == OP_CLOSE then
      if self.sock then self.sock:send(clientFrame(OP_CLOSE, payload)) end
      self:_die('the worker closed the control link')
      return
    elseif op == OP_TEXT or op == OP_BIN then
      if fin then
        self:_message(payload)
      else
        self.frag, self.fragOp = { payload }, op
      end
    elseif op == OP_CONT and self.frag then
      self.frag[#self.frag + 1] = payload
      if fin then
        local whole = concat(self.frag)
        self.frag, self.fragOp = nil, nil
        self:_message(whole)
      end
    end
    if self.state == 'closed' then return end
  end
end

--- control/server.lua answers `{id, ok=false, error="<message>"}` -- a plain
--- STRING, not an object.  Everything above this file wants {code, message}, so
--- the shape is normalised here, in one place, and a code is derived from the
--- one message the caller actually branches on (control/commands.lua's
--- `unknown command %q (known: ...)`).  A future object-shaped error passes
--- through untouched.
local function normaliseError(e)
  if type(e) == 'table' then
    return { code = e.code or 'worker-error', message = tostring(e.message or 'worker error') }
  end
  local msg = tostring(e or 'worker error')
  local code = 'worker-error'
  local low = msg:lower()
  if low:find('unknown command', 1, true) or low:find('no such command', 1, true) then
    code = 'unknown-command'
  end
  return { code = code, message = msg }
end
M.normaliseError = normaliseError

function Ctl:_message(text)
  local ok, frame = pcall(json.decode, text)
  if not ok or type(frame) ~= 'table' then return end
  if frame.id then
    local w = self.waiting[frame.id]
    if w then
      self.waiting[frame.id] = nil
      if w.cb then
        if frame.ok then
          -- a handler may answer with `true` or a scalar; give the caller a table
          local result = frame.result
          if type(result) ~= 'table' then result = { value = result } end
          pcall(w.cb, true, result)
        else
          pcall(w.cb, false, normaliseError(frame.error))
        end
      end
    end
    return
  end
  if frame.event and self.onFrame then pcall(self.onFrame, frame.event, frame.data or {}) end
end

--- Send a command.  cb(ok, resultOrError).  Never blocks.
function Ctl:send(cmd, args, cb, timeoutMs)
  if self.state ~= 'open' or not self.sock then
    if cb then pcall(cb, false, { code = 'offline', message = 'no control link' }) end
    return nil, 'no control link'
  end
  local id = self.nextId
  self.nextId = id + 1
  local ok, payload = pcall(json.encode, { id = id, cmd = cmd, args = args or {} })
  if not ok then
    if cb then pcall(cb, false, { code = 'encode', message = tostring(payload) }) end
    return nil, payload
  end
  local n, serr = self.sock:send(clientFrame(OP_TEXT, payload))
  payload = nil                                   -- may have carried a credential
  if not n then
    self:_die(serr)
    return nil, serr
  end
  self.waiting[id] = { cb = cb, deadline = nowMs() + (timeoutMs or 15000), cmd = cmd }
  return id
end

function Ctl:sweep(now)
  for id, w in pairs(self.waiting) do
    if now >= w.deadline then
      self.waiting[id] = nil
      if w.cb then pcall(w.cb, false, { code = 'timeout', message = w.cmd .. ': no answer' }) end
    end
  end
end

-- ================================================================ supervisor =
local Sup = {}
Sup.__index = Sup
M.Sup = Sup

local DEFAULTS = {
  logRingSize      = 800,
  chatRingSize     = 500,
  restartBaseMs    = 1000,
  restartMaxMs     = 60000,
  healthyResetMs   = 60000,
  maxRestarts      = 0,             -- 0 = unlimited
  healthMs         = 5000,
  healthMissLimit  = 3,
  commandTimeoutMs = 15000,
  spawnTimeoutMs   = 30000,         -- CONTROL line + hello must land inside this
  stopGraceMs      = 8000,
  pollMs           = 25,
  workerScript     = 'main.lua',
}

function M.new(opts)
  opts = opts or {}
  local s = setmetatable({}, Sup)
  for k, v in pairs(DEFAULTS) do s[k] = opts[k] ~= nil and opts[k] or v end
  s.model      = opts.model
  s.audit      = opts.audit
  s.log        = opts.log or require('lib.log')
  s.sched      = opts.sched or sched
  s.luajit     = opts.luajit
  s.workersDir = opts.workersDir
  s.onEvent    = opts.onEvent
  s.onLog      = opts.onLog
  s.onState    = opts.onState
  s.extraArgs  = opts.extraArgs or {}
  -- Extra environment for every worker, MERGED over the hub's own (lib/process
  -- inherits by default).  It is for non-secret settings an operator needs the
  -- worker to see -- a profile root, a locale, a test hook.  Never a credential:
  -- an environment is readable from /proc on some configurations, which is the
  -- whole reason the token and the proxy credential travel on stdin instead.
  s.workerEnv  = opts.workerEnv
  -- fn(instanceId) -> spec | nil, err.  See startInstance.
  s.specProvider = opts.specProvider
  s.logLevel   = opts.logLevel
  s.workers    = {}                  -- instanceId -> worker record
  s.timers     = {}
  s.installed  = false
  s.stopping   = false
  return s
end

-- --------------------------------------------------- profile directory scan
-- The config pickers used to be answerable ONLY by a running worker, because the
-- lists live in files under its profile directory and nothing hub-side could read a
-- directory.  bot/config.lua can (`config.listDir`, FFI readdir with an io.popen
-- fallback), and the hub runs on the same machine as its workers -- it spawns them
-- with `cwd = self.workersDir` -- so the same path the worker would resolve
-- resolves here too.  That is what lets a NEVER-STARTED instance offer a cavebot
-- config to pick.
local botconfig = nil
local function botConfigMod()
  if botconfig == nil then
    local ok, m = pcall(require, 'bot.config')
    botconfig = (ok and type(m) == 'table') and m or false
  end
  return botconfig or nil
end

local function isAbsolutePath(p)
  return p:match('^%a:[/\\]') ~= nil or p:sub(1, 1) == '/' or p:sub(1, 1) == '\\'
end

--- Collapse `.` and `a/..` textually.  Returns the normalised path and how many `..`
--- components were left over, i.e. how far the path climbs ABOVE its own first
--- segment.  Purely lexical -- no symlink resolution -- which is enough here because
--- the answer is only ever used to build a directory listing, and a leftover `..` is
--- refused before any listing happens.
local function normalisePath(p)
  local prefix = ''
  local drive = p:match('^(%a:)[/\\]')
  if drive then prefix = drive .. '/'; p = p:sub(#drive + 2)
  elseif p:sub(1, 1) == '/' then prefix = '/'; p = p:sub(2) end
  local out, up = {}, 0
  for seg in p:gmatch('[^/]+') do
    if seg == '.' then                      -- nothing
    elseif seg == '..' then
      if #out > 0 then out[#out] = nil
      elseif prefix == '' then up = up + 1; out[#out + 1] = '..'
      end                                   -- above an absolute root: swallow it
    else
      out[#out + 1] = seg
    end
  end
  return prefix .. table.concat(out, '/'), up
end
M._normalisePath = normalisePath

--- Resolve an instance's `botProfile` the way the worker will.
---
--- `botProfile` is a free-form string a web account controls, and the answer here is
--- turned into a directory listing that goes back to that account's browser -- so a
--- RELATIVE value must stay inside the directory the hub spawns its workers in.
--- `../../etc` is refused; `a/../b` is not, because it names `b` inside that
--- directory and refusing it would only be theatre.  An ABSOLUTE value is taken as
--- given: pointing an instance at a vBot profile elsewhere on the box is the normal
--- case (`--bot-profile=D:/.../vBot_4.8`), and refusing `..` inside it would refuse
--- nothing an absolute path could not already say directly.
function Sup:profileDir(botProfile)
  if type(botProfile) ~= 'string' or botProfile == '' then return nil end
  local p = botProfile:gsub('\\', '/')
  local norm, up = normalisePath(p)
  if norm == '' then return nil end
  if isAbsolutePath(p) then return norm end
  if up > 0 then return nil end            -- climbs out of the worker directory
  local root = self.workersDir
  if type(root) ~= 'string' or root == '' then return norm end
  -- The root is joined VERBATIM (only trailing slashes go).  Normalising it would be
  -- wrong: `workersDir` is whatever hub/main.lua was given, often a relative
  -- 'test/..', and collapsing that to '' would turn the join into an ABSOLUTE
  -- '/profile_1'.  The OS resolves the uncollapsed form correctly.
  return (root:gsub('\\', '/'):gsub('/+$', '')) .. '/' .. norm
end

--- Read the three config lists straight off disk.
---   cavebot_configs/*.cfg          -> cavebot
---   targetbot_configs/*.json       -> targetbot
---   vBot_configs/profile_*         -> profiles
--- `macros` is deliberately absent: a macro is a Lua registration inside a RUNNING
--- bot, not a file, so a directory scan cannot honestly produce that list.
function Sup:scanProfileConfigs(botProfile)
  local dir = self:profileDir(botProfile)
  if not dir then return nil, 'the bot profile name is not a usable path' end
  local cfg = botConfigMod()
  if not cfg or type(cfg.listDir) ~= 'function' then
    return nil, 'bot/config.lua is not available to the hub'
  end
  -- Anchored, unlike bot/config.lua's stripConfigExt (which reproduces a vBot bug on
  -- purpose and would list "backup.json.bak" as "backup.bak").  A picker offering a
  -- name the worker cannot then open is worse than a shorter list.
  local function listWithExt(sub, ext)
    local out = {}
    for _, name in ipairs(cfg.listDir(dir .. '/' .. sub)) do
      local base = name:match('^(.+)%.' .. ext .. '$')
      if base and #base > 0 then out[#out + 1] = base end
    end
    table.sort(out)
    return out
  end
  local out = {
    cavebot   = listWithExt('cavebot_configs', 'cfg'),
    targetbot = listWithExt('targetbot_configs', 'json'),
    profiles  = {},
    macros    = {},
  }
  for _, name in ipairs(cfg.listDir(dir .. '/vBot_configs')) do
    if name:match('^profile_%d+$') then out.profiles[#out.profiles + 1] = name end
  end
  table.sort(out.profiles)
  local found = #out.cavebot + #out.targetbot + #out.profiles
  if found == 0 then
    return out, 'nothing found under ' .. tostring(botProfile)
  end
  return out
end

-- ----------------------------------------------------------------- accessors
function Sup:worker(id) return self.workers[tostring(id)] end

function Sup:state(id)
  local w = self.workers[tostring(id)]
  return w and w.state or 'stopped'
end

function Sup:info(id)
  local w = self.workers[tostring(id)]
  if not w then return { state = 'stopped', pid = nil, uptimeMs = 0, restarts = 0 } end
  return {
    state    = w.state,
    detail   = w.detail,
    pid      = w.proc and w.proc:pid() or nil,
    uptimeMs = w.startedAt and (nowMs() - w.startedAt) or 0,
    onlineMs = w.onlineAt and (nowMs() - w.onlineAt) or 0,
    restarts = w.restarts or 0,
    healthy  = w.healthy and true or false,
    lastError = w.lastError,
    reconnects = w.reconnects or 0,
    lastStop = w.lastStop,          -- {ms, acked, killed, code, signal, graceful}
  }
end

--- How the workers this supervisor stopped actually went: {total, graceful, killed}.
--- hub/main.lua prints it on the way out, so "did anything get killed" is a fact in
--- the log rather than a guess.
function Sup:stopSummary()
  local s = self.stopStats or { total = 0, graceful = 0, killed = 0 }
  return { total = s.total, graceful = s.graceful, killed = s.killed }
end

function Sup:logs(id, limit)
  local w = self.workers[tostring(id)]
  if not w then return {} end
  return w.logRing:tail(limit or 200)
end

function Sup:chat(id, limit)
  local w = self.workers[tostring(id)]
  if not w then return {} end
  return w.chatRing:tail(limit or 200)
end

-- ------------------------------------------------------ ring persistence ----
-- The rings live in memory, so a hub restart used to leave the panel's Console
-- and Chat tabs blank for every instance -- including the lines that explain WHY
-- the hub had to be restarted, which are the ones an operator wants most.  These
-- two calls are the whole mechanism; hub/main.lua owns the file (same atomic
-- write and integrity footer as the rest of the data dir) and the flush cadence.

--- The tail of every instance's rings, ready to be written out.
--- `maxLines` caps each ring (default 200), because this is a convenience cache,
--- not an archive: the audit log is the record that must be complete.
function Sup:snapshotLogs(maxLines)
  local n = tonumber(maxLines) or 200
  local out = {}
  for id, w in pairs(self.workers) do
    local logs, chat = w.logRing:tail(n), w.chatRing:tail(n)
    if #logs > 0 or #chat > 0 then
      out[#out + 1] = { id = id, logs = logs, chat = chat }
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

--- Put a saved tail back.  Creates the bookkeeping record for an instance that is
--- NOT running -- state 'stopped', no process, no control link -- which is exactly
--- what every instance is one moment after a hub start.
function Sup:restoreLogs(id, logs, chat)
  id = tostring(id)
  local w = self.workers[id]
  if not w then
    w = {
      id = id,
      logRing  = newRing(self.logRingSize),
      chatRing = newRing(self.chatRingSize),
      restarts = 0, reconnects = 0,
      live = {}, state = 'stopped', wantUp = false, restored = true,
    }
    self.workers[id] = w
  end
  for _, line in ipairs(logs or {}) do
    if type(line) == 'table' and line.text then
      w.logRing:push{ id = id, t = tonumber(line.t) or 0,
                      level = tostring(line.level or 'info'), text = tostring(line.text) }
    end
  end
  for _, msg in ipairs(chat or {}) do
    if type(msg) == 'table' and msg.text then
      w.chatRing:push{ id = id, t = tonumber(msg.t) or 0,
                       channel = tostring(msg.channel or 'Default'),
                       from = tostring(msg.from or '?'), text = tostring(msg.text) }
    end
  end
  return true
end

function Sup:isRunning(id)
  local st = self:state(id)
  return st ~= 'stopped' and st ~= 'error'
end

function Sup:runningCount()
  local n = 0
  for _, w in pairs(self.workers) do if w.state ~= 'stopped' and w.state ~= 'error' then n = n + 1 end end
  return n
end

-- --------------------------------------------------------------- state edges
--- Terminal states are terminal.  A `stopping` worker still has commands in
--- flight -- its own `login` answer, a health check, a `loginState` push -- and
--- every one of those calls _setState.  One of them landing after the stop began
--- used to drag the instance back to `running`, which then made _workerExit take
--- the "unexpected exit" branch: no lastStop record, no graceful/killed
--- bookkeeping, and (with wantUp still true) a restart of a worker the operator
--- had just asked to stop.  Measured on Debian: the `--dry-run` login refusal
--- arrived 4 ms after the shutdown command and turned an orderly stop into
--- `graceful=0 stopped=0`.
local TERMINAL_NEXT = {
  stopping = { stopped = true, error = true },
  stopped  = { starting = true, error = true },
}

function Sup:_setState(w, state, detail)
  if w.state == state and w.detail == detail then return end
  local allowed = TERMINAL_NEXT[w.state]
  if allowed and not allowed[state] then return end
  w.state, w.detail = state, detail
  if state ~= 'online' then w.onlineAt = nil end
  if self.onState then pcall(self.onState, w.id, state, detail) end
end

function Sup:_pushLog(w, level, text)
  local line = { id = w.id, t = os.time() * 1000, level = level or 'info', text = tostring(text) }
  w.logRing:push(line)
  if self.onLog then pcall(self.onLog, w.id, line) end
  return line
end

-- ====================================================================== spawn
-- lib/process.lua's own denylist now exempts a REFERENCE to a secret (a bare
-- descriptor number, `fd:N`, `@path`, or a flag named `...-file`/`-fd`/`-path`),
-- so the worker's `--control-token-fd=0` and `--proxy-auth=fd:0` pass the FULL
-- default check and nothing has to be narrowed here.  startInstance() still
-- checks the exact plaintexts of this launch against every argv element, which
-- is stronger than any name list.

-- main.lua's flags, in the order the worker's own --help lists them.  NOTHING
-- secret goes in here: lib/process.lua refuses it, and both PANEL.md and the
-- worker's own CLI say the same.  The credentials travel two ways instead --
-- the control token and the proxy user:pass down the private stdin pipe, and
-- the game-account password inside the `login` command over the authenticated
-- loopback control socket, once it is up.
--
-- ORDER MATTERS on stdin: main.lua reads the stdin-fed flags in the order the
-- FLAGS appear on the command line ("Several stdin-fed flags consume lines in
-- the order the flags appear"), so --control-token-fd=0 must precede
-- --proxy-auth=fd:0 here exactly as the two lines are written below.
local function buildLaunch(self, w)
  local spec = w.spec
  local inst = spec.instance or {}
  local ch   = spec.character or {}
  local argv = { self.luajit, self.workerScript,
                 '--control-port=0', '--control-bind=127.0.0.1', '--control-token-fd=0',
                 '--instance-name=' .. (ch.name or w.id) }
  local stdin = { w.token }
  if spec.proxy and spec.proxy.host then
    argv[#argv + 1] = '--proxy=' .. spec.proxy.host .. ':' .. tostring(spec.proxy.port or 8080)
    if spec.proxy.user and spec.proxy.user ~= '' then
      argv[#argv + 1] = '--proxy-auth=fd:0'
      stdin[#stdin + 1] = spec.proxy.user .. ':' .. (spec.proxy.pass or '')
    end
  end
  if inst.botProfile and inst.botProfile ~= '' then
    argv[#argv + 1] = '--bot-profile=' .. tostring(inst.botProfile)
  end
  if self.logLevel then argv[#argv + 1] = '--log-level=' .. self.logLevel end
  for i = 1, #self.extraArgs do argv[#argv + 1] = self.extraArgs[i] end
  return argv, table.concat(stdin, '\n') .. '\n'
end

--- Start (or re-start) the worker for an instance.
--- `spec` is the launch payload built by hub/api.lua's launchSpec(); it carries the
--- DECRYPTED credentials, is used here and nowhere else, and is dropped as soon as
--- the child has them.  It is never logged and never written to disk.
function Sup:startInstance(id, spec)
  id = tostring(id)
  local w = self.workers[id]
  -- The guard is "is there a live child", not "is the state stopped": the backoff
  -- timer re-enters here from state 'backoff', and refusing that would turn the
  -- restart policy into a single retry.  The API layer uses isRunning() instead,
  -- which DOES count 'backoff' as running so an operator cannot double-start.
  if w and w.proc then return nil, 'already running' end
  if self.stopping then return nil, 'hub is shutting down' end
  -- A restart has to re-derive the launch payload rather than reuse the stored
  -- one: _afterHandshake DROPS the decrypted game password from w.spec the
  -- moment the worker has it (that is the point -- the plaintext must not sit in
  -- the hub's memory), so replaying w.spec would spawn a worker that can never
  -- log in.  specProvider is hub/main.lua's hook back into hub/api.lua's
  -- launchSpec, which decrypts afresh from the sealed record.
  if not spec and self.specProvider then
    local fresh, fe = self.specProvider(id)
    if fresh then spec = fresh
    elseif w then
      self:_pushLog(w, 'warn', 'supervisor: cannot rebuild the launch spec: ' .. tostring(fe))
    end
  end
  if not spec and w then spec = w.spec end
  if not spec then return nil, 'no launch spec' end
  if not self.luajit then return nil, 'no --luajit interpreter configured' end

  if not w then
    w = {
      id = id,
      logRing  = newRing(self.logRingSize),
      chatRing = newRing(self.chatRingSize),
      restarts = 0, reconnects = 0,
      live = {},
    }
    self.workers[id] = w
  end
  w.spec       = spec
  w.wantUp     = true
  w.stopRequested = false
  w.stopDeadline, w.stopSignalAt, w.stopStartedAt = nil, nil, nil
  w.lastError  = nil
  w.healthMiss = 0
  w.healthy    = false
  w.loggedIn   = false
  w.startedAt  = nowMs()
  w.controlPort = nil
  w.ctl        = nil
  w.token      = M.newToken()
  self:_setState(w, 'starting', 'spawning worker')

  local argv, stdinData = buildLaunch(self, w)

  -- lib/process.lua refuses any argv element that LOOKS like a secret, and its
  -- default pattern list contains 'token' and 'auth' -- which catches
  -- `--control-token-fd=0` and `--proxy-auth=fd:0`, whose values are a file
  -- DESCRIPTOR, not a credential.  Narrowing the list would weaken a real check,
  -- so we do the stronger thing first: assert that no argv element contains any
  -- of the plaintext this launch actually holds.  That is an exact test, not a
  -- name heuristic, and it fires on a credential the denylist would never
  -- recognise (a bare `-p hunter2`).
  local secrets = {}
  local acc, px = spec.account or {}, spec.proxy or {}
  for _, v in ipairs{ acc.password, acc.token2fa, px.pass, w.token } do
    if type(v) == 'string' and #v > 0 then secrets[#secrets + 1] = v end
  end
  for i = 1, #argv do
    for _, sec in ipairs(secrets) do
      if tostring(argv[i]):find(sec, 1, true) then
        self:_fail(w, ('refusing to spawn: argument %d carries a credential'):format(i))
        return nil, 'credential in argv'
      end
    end
  end

  local self_ = self
  local proc, err = process.spawn{
    cwd           = self.workersDir,
    cmd           = argv,
    env           = self.workerEnv,
    captureOutput = true,
    stdinData     = stdinData,
    secretArgs    = secrets,
    name          = 'worker:' .. id,
    maxLineBytes  = 64 * 1024,
    onLine        = function(text, stream) self_:_workerLine(w, text, stream) end,
    onExit        = function(code, signal) self_:_workerExit(w, code, signal) end,
  }
  stdinData = nil          -- held the proxy credential; drop the reference at once
  if not proc then
    self:_fail(w, 'spawn failed: ' .. tostring(err))
    return nil, err
  end
  w.proc = proc
  w.spawnDeadline = nowMs() + self.spawnTimeoutMs
  self:_pushLog(w, 'info', 'supervisor: spawned pid ' .. tostring(proc:pid()) ..
                ' -- ' .. proc:describe())
  return true
end

function Sup:_fail(w, why)
  w.lastError = why
  w.wantUp = false
  self:_pushLog(w, 'error', 'supervisor: ' .. tostring(why))
  self:_setState(w, 'error', why)
end

-- ------------------------------------------------------------- worker output
function Sup:_workerLine(w, text, stream)
  if type(text) ~= 'string' then return end
  -- main.lua announces the endpoint it settled on, once, machine-readably:
  --     control-endpoint <bind> <port> <instance-name>
  local host, port = text:match('^control%-endpoint%s+(%S+)%s+(%d+)')
  if port and not w.controlPort then
    w.controlPort = tonumber(port)
    self:_pushLog(w, 'info', text)
    self:_connectControl(w, host, w.controlPort)
    return
  end
  local level = 'info'
  if stream == 'stderr' then level = 'error' end
  -- lib/log.lua writes "[   123.4] LEVEL message"
  local lv = text:match('^%s*%[[%d%.%s]*%]%s*(%u+)') or text:match('^%s*(%u%u%u%u+)')
  if lv == 'ERROR' then level = 'error'
  elseif lv == 'WARN' then level = 'warn'
  elseif lv == 'DEBUG' then level = 'debug' end
  self:_pushLog(w, level, text)
end

--- Once the control link is up: log the character in, then push the bot config
--- and every assigned script.  This is the only moment the decrypted game-account
--- password exists in the hub, and it goes straight out over the loopback socket.
function Sup:_afterHandshake(w, c)
  local self_ = self
  local spec = w.spec or {}
  local acc  = spec.account or {}
  local ch   = spec.character or {}
  local inst = spec.instance or {}

  -- `script.put` and `exec` run inside the bot's vBot-compatible environment, and
  -- that environment does not exist until a session does: a hub-managed worker
  -- boots with NO credentials in argv (main.lua's deferred path) and builds the
  -- game and bot layers only when this `login` arrives.  So the login goes first
  -- and the bot configuration follows it -- on EITHER outcome, because a worker
  -- started with --dry-run refuses to log in and still has a bot layer to
  -- configure.  An instance is created to run the bot, so it starts enabled
  -- unless the caller says otherwise; instance.botEnable turns it off at runtime.
  local function pushBotConfig(quiet)
    if inst.botEnabled ~= false then
      c:send('bot.enable', { on = true }, function(ok, res)
        if not ok and not quiet then
          self_:_pushLog(w, 'warn', 'supervisor: the bot layer refused to start: ' ..
                         tostring(res and res.message or 'unknown'))
        end
      end)
    end
    if inst.cavebotConfig then c:send('bot.setCavebot', { name = inst.cavebotConfig }) end
    if inst.targetbotConfig then c:send('bot.setTargetbot', { name = inst.targetbotConfig }) end
    for _, s in ipairs(spec.scripts or {}) do
      c:send('script.put', { name = s.name, source = s.source })
    end
  end

  if not acc.login or acc.login == '' then
    self:_pushLog(w, 'warn', 'supervisor: no game account configured -- not logging in')
    pushBotConfig()
    return
  end

  -- A worker started with a session already open (--dry-run, or a hand-started
  -- one the hub adopted) has its bot layer up NOW, so configure it now; the
  -- attempt is quiet because a hub-managed worker legitimately has no bot layer
  -- until the `login` below builds one, and it is repeated after that login.
  pushBotConfig(true)
  local args = {
    account = acc.login, password = acc.password, token = acc.token2fa,
    character = ch.name, world = ch.world,
    host = spec.server and spec.server.host or nil,
    port = spec.server and spec.server.port or nil,
    loginUrl = spec.server and spec.server.loginUrl or nil,
  }
  self:_setState(w, 'connecting', 'logging in')
  c:send('login', args, function(ok, res)
    args.password, args.token = nil, nil          -- drop the plaintext immediately
    if ok then
      w.loggedIn = true
      self_:_pushLog(w, 'info', 'supervisor: login accepted by the worker')
    else
      w.lastError = tostring(res and res.message or 'login refused')
      self_:_pushLog(w, 'error', 'supervisor: login refused: ' .. w.lastError)
      self_:_setState(w, 'running', w.lastError)
    end
    -- The login is what BUILDS the bot layer in a hub-managed worker, so the
    -- configuration has to be pushed once it has succeeded.  Repeating it on a
    -- worker that already had one is harmless: every one of these commands is
    -- idempotent.
    if ok then pushBotConfig() end
  end, 60000)                                     -- an HTTPS login through a proxy is slow
  -- The spec's plaintext is no longer needed; keep only what a restart can rebuild.
  spec.account = { login = acc.login }
end

function Sup:_connectControl(w, host, port)
  local self_ = self
  local ctl = newCtl{
    host = host or '127.0.0.1', port = port, token = w.token,
    onOpen = function(c)
      -- The handshake itself carried the token, so an open socket IS the
      -- authenticated state; `status` is the first thing we ask for.
      w.healthy = true
      w.healthMiss = 0
      w.token = nil                    -- no longer needed anywhere in the hub
      self_:_setState(w, 'running', 'control link up')
      self_:_pushLog(w, 'info', 'supervisor: control link established on port ' .. tostring(port))
      c:send('status', {}, function(sok, sres)
        if sok then self_:_event(w, 'status', sres) end
      end, self_.commandTimeoutMs)
      self_:_afterHandshake(w, c)
    end,
    onFrame = function(event, data) self_:_event(w, event, data) end,
    onClose = function(err)
      if w.ctl then w.ctl = nil end
      if w.state ~= 'stopping' and w.state ~= 'stopped' then
        self_:_pushLog(w, 'warn', 'supervisor: control link lost: ' .. tostring(err))
      end
      w.healthy = false
    end,
  }
  w.ctl = ctl
  local ok, err = ctl:connect()
  if not ok then
    self:_pushLog(w, 'error', 'supervisor: cannot reach the worker control port: ' .. tostring(err))
    w.ctl = nil
    if w.proc then w.proc:stop(1000) end
  end
end

local STATE_FROM_LOGIN = {
  offline       = 'running',
  connecting    = 'connecting',
  authenticating= 'connecting',
  characterlist = 'connecting',
  online        = 'online',
  disconnected  = 'running',
}

--- Flatten one worker `status` / `stats` payload into the flat `live` object the
--- panel draws (panel/api.js documents its fields).  control/commands.lua answers
--- with the WORKER's natural shape -- player{}, bot{cavebot{},targetbot{}},
--- stats{} -- which is the right shape for the worker and the wrong one for a
--- table row, so the translation happens once, here, rather than in every screen.
--- Anything already flat is passed through untouched, so a `stats` push needs no
--- special case.
local function flattenLive(data)
  local out = {}
  for k, v in pairs(data) do
    if k ~= 'player' and k ~= 'bot' and k ~= 'stats' and k ~= 'transport' then out[k] = v end
  end
  local p = data.player
  if type(p) == 'table' then
    out.hp, out.maxHp     = p.hp, p.maxHp
    out.mana, out.maxMana = p.mana, p.maxMana
    out.level      = p.level or out.level
    out.expPercent = p.levelPercent
    out.exp        = p.exp
    out.soul, out.stamina = p.soul, p.stamina
    out.cap        = p.cap
    out.pos        = p.pos
    if p.name and p.name ~= '' then out.characterName = p.name end
  end
  local b = data.bot
  if type(b) == 'table' then
    out.botEnabled = b.on and true or false
    local cb = b.cavebot
    if type(cb) == 'table' then
      out.cavebotOn     = cb.on and true or false
      out.cavebotConfig = cb.config
      out.waypointIndex = cb.waypointIndex
      out.waypointCount = cb.waypointCount
      out.waypoint      = cb.status or cb.config
    end
    local tb = b.targetbot
    if type(tb) == 'table' then
      out.targetbotOn     = tb.on and true or false
      out.targetbotConfig = tb.config
      out.target          = tb.target
      out.danger          = tb.danger
    end
    if b.supplies ~= nil then out.supplies = b.supplies end
    if b.suppliesStatus ~= nil then out.suppliesStatus = b.suppliesStatus end
    if b.macros ~= nil then out.macroCount = b.macros end
  end
  local st = data.stats
  if type(st) == 'table' then
    for k, v in pairs(st) do if out[k] == nil then out[k] = v end end
  end

  -- panel/api.js declares `supplies` as an ARRAY of {name,itemId,count,min}, and
  -- bot/supplies.lua's ledger now produces exactly that (control/commands.lua splits
  -- the rows from the surrounding profile/rounds context, which travels as
  -- `suppliesStatus`).  The guard stays because an OLDER worker -- one built before
  -- the ledger, still running against a newer hub -- sends the mixed status object
  -- under `supplies`, and handing that to the panel is what made its Overview throw.
  -- Anything that is not a non-empty list is demoted rather than forwarded.
  if out.supplies ~= nil and not (type(out.supplies) == 'table' and #out.supplies > 0) then
    if out.suppliesStatus == nil then out.suppliesStatus = out.supplies end
    out.supplies = nil
  end
  return out
end
Sup.flattenLive = flattenLive

-- ---------------------------------------------------------------------------
-- work item R2's debug.snapshot -> the shape panel/app.js's Debug tab (work
-- item R3, already built) assumes -- see panel/api.js's `instances.debug`
-- comment and panel/rpc.js's WsClient#subscribeDebug doc comment, both marked
-- "ASSUMED shape pending R2".  This is exactly `flattenLive` above's job for
-- status/stats, for the same reason: "the worker answers with its own natural
-- shape ... and hub/supervisor.lua's flattenLive() folds that into the flat
-- shape the panel draws. That translation happens once, in the hub." R2's
-- shape is control/commands.lua's own documented contract (BOT.md-adjacent,
-- not this file's to redefine); this only RENAMES/reshapes it for the one
-- consumer that assumed something else before R2 existed to ask.
--
-- Known, deliberate simplifications where the two sides disagree on MEANING,
-- not just spelling (see this work item's crossFileRequests for the fuller
-- account):
--   * R3's `stuckSince` is a TIMESTAMP (`Date.now() - stuckSince`); R2's is
--     already a DURATION ("ms since the waypoint index last advanced").
--     Converted here as `generatedAt - stuckSince` so panel/app.js's existing
--     arithmetic keeps working unmodified.
--   * R3 wants `network.staleThresholdMs`, a concept R2 has no configured
--     value for; STALE_THRESHOLD_MS below is this file's own reasonable
--     constant, not read from anywhere upstream.
--   * every event's `detail` is rendered as a plain DOM text node in
--     panel/app.js (`h('td', {text: e.detail})`), so a structured R2 detail
--     table is compacted into one readable string here rather than handed
--     over as an object (which would render as "[object Object]").
--   * CLOCK DOMAIN (found and fixed during this integration pass, not part of
--     either R2's or R3's original design note above): every "moment" field
--     control/commands.lua reports (`macro.lastRanMs`, `heal/atk/stances
--     .last{Cast,Fired}Ms`, `path.lastFindMs`, each event's `tMs`, and the
--     `generatedAt`/`tMs` the snapshot is stamped with) comes from
--     `sys.nowMs()`, which lib/sys.lua documents as "monotonic milliseconds
--     since the first call" -- i.e. since THAT WORKER PROCESS started, not
--     Unix epoch.  panel/app.js's TabDebug (R3) was built assuming these are
--     epoch ms and compares them straight against the browser's `Date.now()`
--     (`agoStr(Date.now() - m.lastRanAt)`, `new Date(e.tMs)` in `clockOf`,
--     etc.) -- with the raw worker value passed through, a macro that ran one
--     tick ago would render as having last run decades ago.  Fixed the same
--     way hub/storage.lua already anchors its own wall-clock estimate: at
--     flatten time we know both the worker's monotonic "now"
--     (`data.tMs`) and the hub's own wall-clock "now" (`os.time()*1000`), so
--     `EPOCH_OFFSET_MS = wallNow - data.tMs` converts any other moment from
--     that same snapshot into an epoch-comparable value with one addition.
--     Duration fields (`lastDurationMs`, `lastPacketAgeMs`, tick
--     `durationsMs`, etc.) are NOT touched -- a difference of two
--     monotonic moments is already a correct duration regardless of epoch.
local STALE_THRESHOLD_MS = 5000

local function describeDetail(detail)
  if type(detail) ~= 'table' then return tostring(detail or '') end
  local parts = {}
  for k, v in pairs(detail) do
    if type(v) ~= 'table' then parts[#parts + 1] = tostring(k) .. '=' .. tostring(v) end
  end
  table.sort(parts)
  return table.concat(parts, ' ')
end

--- Convert one worker-monotonic "moment" (as produced by `sys.nowMs()` inside
--- control/commands.lua) into an epoch-ms value comparable to a browser's
--- `Date.now()`, using the per-snapshot offset computed in `flattenDebug`.
--- `nil` in, `nil` out, so an absent timestamp still renders as "-" instead
--- of becoming a bogus `offset`.
local function toEpochMs(momentMs, offset)
  if momentMs == nil then return nil end
  return momentMs + offset
end

local function flattenDebugEvents(events, offset)
  local out = {}
  for i = 1, #(events or {}) do
    local e = events[i]
    out[i] = { tMs = toEpochMs(e.tMs, offset), kind = e.kind, detail = describeDetail(e.detail) }
  end
  return out
end

local function flattenDebugTick(t, offset)
  t = t or {}
  local macros = {}
  for i, m in ipairs(t.macros or {}) do
    macros[i] = { name = m.name, label = m.name, on = m.enabled,
                  lastRanAt = toEpochMs(m.lastRanMs, offset), lastDurationMs = m.lastDurationMs,
                  errorCount = m.errorCount, lastError = m.lastError }
  end
  return { configuredMs = t.intervalMs, lastMs = t.lastTickDurationMs, avgMs = t.avgTickDurationMs,
           durationsMs = t.durationsMs or {}, slowThresholdMs = t.slowThresholdMs,
           slowCount = t.slowTicks, macros = macros }
end

local function flattenDebugNetwork(n)
  n = n or {}
  return { connected = n.connected, pingMs = n.ping, packetsIn = n.packetsIn, packetsOut = n.packetsOut,
           bytesIn = n.bytesIn, bytesOut = n.bytesOut, reconnects = n.reconnects,
           lastError = n.lastDesyncOrError, lastPacketAgeMs = n.lastPacketAgeMs,
           staleThresholdMs = STALE_THRESHOLD_MS }
end

--- `generatedAt` here is the already-converted EPOCH ms of the snapshot
--- (`flattenDebug`'s `wallNow`), so `cave.stuckSince` -- a DURATION on the
--- wire ("ms since the waypoint index last advanced") -- becomes
--- `wallNow - duration`, an epoch moment panel/app.js can diff against its
--- own `Date.now()` directly, exactly like every other `*At` field here.
local function flattenDebugBot(b, generatedAt, offset)
  b = b or {}
  local cave, targ, heal, atk, stan = b.cavebot, b.targetbot, b.healbot, b.attackbot, b.stances
  local out = {}
  if cave then
    out.cavebot = {
      enabled = cave.on, waypointIndex = cave.waypointIndex, waypointCount = cave.waypointCount,
      waypointLabel = cave.currentAction,
      stuckSince = (cave.stuckSince and generatedAt) and (generatedAt - cave.stuckSince) or nil,
      stuckThresholdMs = cave.stuckThresholdMs,
    }
  end
  if targ then
    local n = tonumber(targ.candidateCount) or 0
    out.targetbot = {
      enabled = targ.on, candidate = n .. ' candidate' .. (n == 1 and '' or 's'),
      target = targ.target and targ.target.name or nil,
      lootingState = targ.looting and targ.looting.state or nil,
    }
  end
  if heal then out.healbot = { enabled = heal.on, lastAction = heal.lastRuleFired, lastActionAt = toEpochMs(heal.lastCastMs, offset) } end
  if atk  then out.attackbot = { enabled = atk.on, lastAction = atk.lastSpell, lastActionAt = toEpochMs(atk.lastFiredMs, offset) } end
  if stan then
    local ids = stan.activeStanceIds or {}
    out.stances = { enabled = stan.on, lastActionAt = toEpochMs(stan.lastCastMs, offset),
                    lastAction = #ids == 0 and 'none' or (#ids .. ' active stance' .. (#ids == 1 and '' or 's')) }
  end
  return out
end

local function flattenDebugPath(p, offset)
  p = p or {}
  return { lastComputedAt = toEpochMs(p.lastFindMs, offset), lengthTiles = p.lastFindTileCount,
           blocked = (p.lastFindResult == 'nopath' or p.lastFindResult == 'timeout') }
end

--- data = control/commands.lua's `debug.snapshot` result, exactly as the
--- worker answered it (or as hub/api.lua's on-demand route received it).
--- instanceId is the HUB's id (a hub/model.lua row id), which the worker has
--- no way to know about itself.
local function flattenDebug(data, instanceId)
  data = type(data) == 'table' and data or {}
  local wallNow = os.time() * 1000
  -- offset from the WORKER's monotonic clock to the HUB's wall clock, valid
  -- for every "moment" field on THIS snapshot (see the clock-domain note
  -- above `STALE_THRESHOLD_MS`). 0 when the worker never stamped a `tMs`
  -- (an empty/placeholder snapshot) so toEpochMs's nil-in/nil-out still holds.
  local offset = data.tMs and (wallNow - data.tMs) or 0
  return {
    id = instanceId, generatedAt = wallNow,
    tick = flattenDebugTick(data.tick, offset),
    network = flattenDebugNetwork(data.network),
    bot = flattenDebugBot(data.bot, wallNow, offset),
    path = flattenDebugPath(data.path, offset),
    events = flattenDebugEvents(data.events, offset),
  }
end
Sup.flattenDebug = flattenDebug

function Sup:_event(w, event, data)
  data = type(data) == 'table' and data or {}
  if event == 'log' then
    local line = { id = w.id, t = data.t or (os.time() * 1000),
                   level = data.level or 'info', text = tostring(data.text or '') }
    w.logRing:push(line)
    if self.onLog then pcall(self.onLog, w.id, line) end
    if self.onEvent then pcall(self.onEvent, w.id, 'log', line) end
    return
  end
  if event == 'chat' then
    local msg = { id = w.id, t = data.t or (os.time() * 1000), channel = data.channel or 'Default',
                  from = data.from or '?', text = tostring(data.text or '') }
    w.chatRing:push(msg)
    if self.onEvent then pcall(self.onEvent, w.id, 'chat', msg) end
    return
  end
  if event == 'loginState' then
    local st = STATE_FROM_LOGIN[tostring(data.state or ''):lower()]
    if st then
      if st == 'online' then
        if w.state ~= 'online' then w.onlineAt = nowMs() end
      elseif w.state == 'online' then
        w.reconnects = (w.reconnects or 0) + 1
      end
      self:_setState(w, st, data.detail)
    end
  end
  if event == 'status' or event == 'stats' then
    local flat = flattenLive(data)
    for k, v in pairs(flat) do w.live[k] = v end
    w.live.id = w.id
    data = flat                      -- the panel gets the flat shape too
  end
  if event == 'debug' then
    data = flattenDebug(data, w.id)  -- work item R2 -> R3's assumed shape
  end
  if event == 'gameStart' then
    if w.state ~= 'online' then w.onlineAt = nowMs() end
    self:_setState(w, 'online', nil)
  end
  if event == 'gameEnd' then
    if w.state == 'online' then w.reconnects = (w.reconnects or 0) + 1 end
    self:_setState(w, 'running', data.reason)
  end
  if event == 'error' then
    w.lastError = tostring(data.message or 'worker error')
    self:_pushLog(w, 'error', w.lastError)
  end
  if self.onEvent then pcall(self.onEvent, w.id, event, data) end
end

-- ------------------------------------------------------------------ exit path
function Sup:_workerExit(w, code, signal)
  -- The flag, not the state string: an operator asked for this stop, and that
  -- fact must not depend on which asynchronous callback last touched w.state.
  local wasStopping = (w.stopRequested or w.state == 'stopping') and true or false
  w.proc = nil
  w.healthy = false
  if w.ctl then w.ctl:close('worker exited'); w.ctl = nil end
  local how = signal and ('signal ' .. tostring(signal)) or ('exit code ' .. tostring(code))
  self:_pushLog(w, wasStopping and 'info' or 'warn', 'supervisor: worker gone (' .. how .. ')')

  if wasStopping then
    -- What actually happened, so an operator (and the test suite) can tell an
    -- orderly logout from a kill instead of inferring it.  "graceful" means the
    -- worker acknowledged `shutdown` and left on its own, inside the window,
    -- without the SIGKILL/TerminateProcess step.
    local ms = w.stopStartedAt and (nowMs() - w.stopStartedAt) or 0
    w.lastStop = {
      ms       = ms,
      acked    = w.stopAcked and true or false,
      killed   = w.stopKilled and true or false,
      code     = code, signal = signal,
      graceful = (w.stopAcked and not w.stopKilled and signal == nil and code == 0) and true or false,
    }
    self.stopStats = self.stopStats or { total = 0, graceful = 0, killed = 0 }
    self.stopStats.total = self.stopStats.total + 1
    if w.lastStop.graceful then self.stopStats.graceful = self.stopStats.graceful + 1 end
    if w.lastStop.killed then self.stopStats.killed = self.stopStats.killed + 1 end
    self:_pushLog(w, w.lastStop.graceful and 'info' or 'warn', string.format(
      'supervisor: stopped %s after %d ms (%s)',
      w.lastStop.graceful and 'gracefully' or 'the hard way', ms, how))
    w.stopStartedAt, w.stopDeadline, w.stopSignalAt = nil, nil, nil
    w.stopRequested = false
  end

  if wasStopping or not w.wantUp or self.stopping then
    w.wantUp = false
    self:_setState(w, 'stopped', how)
    return
  end
  -- an unexpected exit: back off and try again
  w.restarts = (w.restarts + 1)
  if self.maxRestarts > 0 and w.restarts > self.maxRestarts then
    self:_fail(w, 'gave up after ' .. tostring(w.restarts - 1) .. ' restarts (' .. how .. ')')
    return
  end
  local wait = self.restartBaseMs * (2 ^ math.min(w.restarts - 1, 16))
  if wait > self.restartMaxMs then wait = self.restartMaxMs end
  wait = jitter(wait)
  w.retryAt = nowMs() + wait
  w.lastError = how
  self:_setState(w, 'backoff', string.format('restart #%d in %d ms (%s)', w.restarts, wait, how))
  self:_pushLog(w, 'warn', string.format('supervisor: restart #%d in %d ms', w.restarts, wait))
end

-- ------------------------------------------------------------------- stopping
function Sup:stopInstance(id, graceMs)
  id = tostring(id)
  local w = self.workers[id]
  if not w then return nil, 'not running' end
  w.wantUp = false
  w.retryAt = nil
  if w.state == 'stopped' or w.state == 'error' then
    self:_setState(w, 'stopped', 'stopped')
    return true
  end
  if not w.proc then
    self:_setState(w, 'stopped', 'stopped')
    return true
  end
  -- ------------------------------------------------------------------------
  -- The orderly stop, in three steps, on BOTH platforms.
  --
  -- Step 1 is the `shutdown` COMMAND over the control link, and it is the whole
  -- point of the exercise: main.lua's shutdown handler sends 0x14 LeaveGame
  -- before it drops the socket.  Without that the server keeps the character
  -- online for its own logout timeout and the NEXT login on that account is
  -- answered with `session ended` (docs/live-findings.md) -- so a worker that is
  -- merely killed costs the operator the next login, not just this one.
  --
  -- Step 2, at `signalAt`, is proc:stop() -- stdin EOF everywhere, plus SIGTERM
  -- on POSIX.  It is a fallback, not the plan: it runs when the control link
  -- was never up, when the worker did not acknowledge, or when it acknowledged
  -- and then took too long.
  --
  -- Step 3, at `deadline`, is proc:kill().
  --
  -- Windows used to have no step 1 at all on the hub-exit path, and step 2 is
  -- weaker there (there is no SIGTERM), which is exactly why the job object was
  -- doing the work and no worker ever logged out.  _tick() drives both edges, so
  -- they hold whether the stop came from the panel, from a signal, or from the
  -- console control handler.
  local grace = tonumber(graceMs) or self.stopGraceMs
  if grace < 200 then grace = 200 end
  local now = nowMs()
  w.stopRequested = true
  w.stopStartedAt = now
  w.stopDeadline  = now + grace
  -- 60 % of the window for the polite path, the rest for SIGTERM/EOF.
  w.stopSignalAt  = now + floor(grace * 0.6)
  w.stopAcked     = false
  w.stopKilled    = false
  self:_setState(w, 'stopping', 'shutting down')

  if w.ctl and w.ctl.state == 'open' then
    self:_pushLog(w, 'info', 'supervisor: asking the worker to shut down (logout first)')
    local wr = self
    w.ctl:send('shutdown', {}, function(ok, res)
      w.stopAcked = ok and true or false
      if ok then
        wr:_pushLog(w, 'info', 'supervisor: the worker acknowledged shutdown')
      else
        wr:_pushLog(w, 'warn', 'supervisor: the worker refused shutdown: ' ..
                    tostring(res and res.message or 'no answer'))
        -- No point waiting out the polite window for an answer we have.
        w.stopSignalAt = nowMs()
      end
    end, math.min(grace, 5000))
  else
    self:_pushLog(w, 'info', 'supervisor: no control link -- stopping the process directly')
    w.stopSignalAt = now                     -- nothing to be polite to
  end
  return true
end

function Sup:restartInstance(id, spec)
  id = tostring(id)
  local w = self.workers[id]
  if not w or w.state == 'stopped' or w.state == 'error' then
    return self:startInstance(id, spec)
  end
  w.pendingRestart = spec or w.spec
  self:stopInstance(id)
  return true
end

--- Forget an instance entirely (after a delete).  Stops it first.
function Sup:forget(id)
  id = tostring(id)
  local w = self.workers[id]
  if not w then return true end
  self:stopInstance(id)
  local self_ = self
  self.sched.after(self.stopGraceMs + 500, function() self_.workers[id] = nil end)
  return true
end

-- ------------------------------------------------------------------ commands
--- Forward a panel command to the worker.  cb(ok, resultOrError).
function Sup:command(id, cmd, args, cb, timeoutMs)
  local w = self.workers[tostring(id)]
  if not w or not w.ctl or w.ctl.state ~= 'open' then
    if cb then pcall(cb, false, { code = 'offline', message = 'the worker is not running' }) end
    return nil, 'the worker is not running'
  end
  return w.ctl:send(cmd, args or {}, cb, timeoutMs or self.commandTimeoutMs)
end

--- work item R2: a fresh, on-demand `debug.snapshot` from the running worker --
--- the same thing hub/telemetry.lua receives PUSHED every debugIntervalMs, but
--- pulled once, right now, for hub/api.lua's GET /api/instances/:id/debug.
--- Plain sugar over :command -- kept here (not inlined in hub/api.lua) so a
--- caller that only has a Sup handle (a test, say) can ask the same way.
function Sup:debugSnapshot(id, cb, timeoutMs)
  return self:command(id, 'debug.snapshot', {}, cb, timeoutMs)
end

function Sup:live(id)
  local w = self.workers[tostring(id)]
  return w and w.live or nil
end

-- ==================================================================== ticking
function Sup:_tick()
  local now = nowMs()
  process.pollAll()
  for _, w in pairs(self.workers) do
    if w.ctl then w.ctl:sweep(now) end

    -- the spawn handshake did not land in time
    if w.state == 'starting' and w.spawnDeadline and now > w.spawnDeadline then
      w.spawnDeadline = nil
      self:_pushLog(w, 'error', 'supervisor: the worker never announced its control port')
      if w.proc then w.proc:stop(1000) else self:_setState(w, 'error', 'no control port') end
    end

    -- the orderly-stop ladder (see stopInstance): shutdown command -> stdin
    -- EOF / SIGTERM -> kill.  Driven here so the deadline is enforced by the
    -- reactor rather than by whoever happened to call stop().
    if w.state == 'stopping' and w.proc then
      if w.stopSignalAt and now >= w.stopSignalAt then
        w.stopSignalAt = nil
        local left = (w.stopDeadline or now) - now
        if left < 100 then left = 100 end
        self:_pushLog(w, 'info', ('supervisor: escalating -- %s (%d ms left)'):format(
          process.isWindows and 'closing stdin' or 'stdin EOF + SIGTERM', left))
        w.proc:stop(left)
      end
      if w.stopDeadline and now >= w.stopDeadline and not w.stopKilled then
        w.stopKilled = true
        self:_pushLog(w, 'warn', 'supervisor: the worker outlasted its grace window -- killing it')
        w.proc:kill()
      end
    end

    -- backoff expired
    if w.state == 'backoff' and w.retryAt and now >= w.retryAt then
      w.retryAt = nil
      self:startInstance(w.id)
    end

    -- a stop that was really a restart
    if w.state == 'stopped' and w.pendingRestart then
      w.pendingRestart = nil
      w.restarts = 0
      self:startInstance(w.id)          -- re-derive: see the note in startInstance
    end

    -- restart counter decay once the worker has been up a while
    if w.healthy and w.restarts > 0 and w.startedAt and (now - w.startedAt) > self.healthyResetMs then
      w.restarts = 0
    end
  end
end

function Sup:_health()
  if self.stopping then return end
  local self_ = self
  for _, w in pairs(self.workers) do
    if w.ctl and w.ctl.state == 'open' and (w.state == 'running' or w.state == 'online' or w.state == 'connecting') then
      local wr = w
      wr.healthPending = true
      w.ctl:send('status', {}, function(ok, res)
        wr.healthPending = false
        if ok then
          wr.healthMiss = 0
          wr.healthy = true
          self_:_event(wr, 'status', res)
        else
          wr.healthMiss = (wr.healthMiss or 0) + 1
          if wr.healthMiss >= self_.healthMissLimit then
            wr.healthy = false
            self_:_pushLog(wr, 'error', string.format(
              'supervisor: %d health checks missed -- killing the worker', wr.healthMiss))
            wr.healthMiss = 0
            if wr.proc then wr.proc:stop(1000) end
          end
        end
      end, self_.commandTimeoutMs)
    end
  end
end

function Sup:install()
  if self.installed then return end
  self.installed = true
  local self_ = self
  self.timers[#self.timers + 1] = self.sched.every(self.pollMs, function() self_:_tick() end)
  self.timers[#self.timers + 1] = self.sched.every(self.healthMs, function() self_:_health() end)
  -- Children can never outlive the hub: lib/process.lua arms a Windows job object
  -- and PR_SET_PDEATHSIG on Linux, and this is the orderly path on top of it.
  -- shutdownAll only ASKS; drainStop is what turns the reactor by hand until the
  -- asking has had its effect, which on an exit path nothing else will do.
  sys.atExit(function()
    pcall(function()
      if self_:allStopped() then return end
      self_:shutdownAll(2000)
      self_:drainStop(2000)
    end)
  end)
end

function Sup:uninstall()
  for _, t in ipairs(self.timers) do pcall(self.sched.cancel, t) end
  self.timers = {}
  self.installed = false
end

--- Ask every worker to stop.  Non-blocking; call :allStopped() to check, and
--- :reap() on the very last shutdown step.
function Sup:shutdownAll(graceMs)
  self.stopping = true
  for id, w in pairs(self.workers) do
    if w.proc then self:stopInstance(id, graceMs) end
  end
end

function Sup:allStopped()
  for _, w in pairs(self.workers) do if w.proc then return false end end
  return true
end

--- BLOCKING.  Turn the reactor by hand until every worker is gone, or the window
--- closes.  Exit paths only -- an exit hook, an unhandled error, a test.
---
--- It exists because `shutdown` is a COMMAND over a socket: it needs the reactor
--- to deliver it, to read the answer and to notice the worker leaving, and on
--- those paths lib/sched.lua is no longer running.  Without this the exit hook
--- would fall straight through to process.reapAll(), which is the kill path, and
--- the last thing a hub does before dying would be to leave every character
--- online server-side.
---
--- It refuses to run while the reactor IS running -- re-entering sched.tick()
--- from inside one of its own callbacks would iterate the timer array under
--- itself -- so an orderly shutdown driven from the reactor (hub/main.lua's
--- M.shutdown) is left alone to finish on its own turns.
function Sup:drainStop(graceMs)
  if self._draining then return false, 'already draining' end
  if self.sched and self.sched.running then return false, 'the reactor is still running' end
  self._draining = true
  local deadline = nowMs() + (tonumber(graceMs) or self.stopGraceMs) + 1500
  local ok = pcall(function()
    while nowMs() < deadline do
      if self.sched and self.sched.tick then self.sched.tick(5) else process.pollAll() end
      if self:allStopped() then break end
      sys.sleepMs(2)
    end
  end)
  self._draining = false
  return ok and self:allStopped()
end

--- The final, blocking step of process exit only.  Asks politely first (that is
--- the only chance the worker gets to log out), then reaps whatever is left.
function Sup:reap(graceMs)
  local grace = tonumber(graceMs) or 3000
  self.stopping = true
  if not self:allStopped() then
    self:shutdownAll(grace)
    self:drainStop(grace)
  end
  self:uninstall()
  for _, w in pairs(self.workers) do
    if w.ctl then pcall(function() w.ctl:close('hub shutting down') end); w.ctl = nil end
  end
  pcall(process.reapAll, grace)
end

return M
