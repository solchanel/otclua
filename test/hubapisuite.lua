--[[============================================================================
test/hubapisuite.lua -- hub/server.lua + hub/api.lua + hub/supervisor.lua +
                        hub/telemetry.lua + hub/main.lua, end to end.

    luajit test/hubapisuite.lua            (from D:/Claude/otclient_web/luaclient)
    luajit test/hubapisuite.lua --keep     (leave the temp data dir behind)

Nothing here is mocked below the HTTP layer.  A REAL hub is built on a REAL
temporary data directory, bound to 127.0.0.1 on an ephemeral port, and every
assertion below goes over a real loopback TCP connection: HTTP/1.1 requests
written by hand, and an RFC 6455 WebSocket the suite masks and parses itself.

The workers are real child processes too.  `fakeworker.lua` is written into the
temp directory at startup and spawned by hub/supervisor.lua through
lib/process.lua exactly as the game client would be; it speaks the control
protocol documented at the top of hub/supervisor.lua (stdin launch payload,
`CONTROL 127.0.0.1 <port>` on stdout, newline-delimited JSON over TCP), pushes
status/stats events, and answers `exec`.  No game server is involved and nothing
leaves the machine.

Covered
  bootstrap    first run refuses everything else; a wrong token is refused and
               audited; the right one creates the sole administrator
  auth         login / logout / whoami, a wrong password, the session cookie's
               HttpOnly + SameSite attributes
  CSRF         a form content type, a foreign Origin, a cross-site
               Sec-Fetch-Site and a wrong X-CSRF-Token are all refused; the
               right token passes; --csrf-strict makes the header mandatory
  roles        a `user` gets 403 from EVERY admin route, and 404 (not 403) for
               another account's instance -- no id oracle
  workers      instance create -> start -> the child really runs -> exec round
               trips through it -> stop -> the pid is really gone
  telemetry    a WebSocket subscriber receives hello + status + stats; an
               unauthenticated socket is refused 401 and a foreign Origin 403
  audit        a record exists for every action, including the refusals
  restart      the hub is torn down and rebuilt on the same directory: the
               accounts, instances and uploaded scripts come back
  real worker  the same supervisor drives `luajit main.lua --dry-run`, whose
               control endpoint is control/server.lua, so the protocol is
               proved against the real thing and not only the fake

Exits non-zero if any check fails.
============================================================================]]

local ROOT
do
  local src = debug.getinfo(1, 'S').source
  local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
  ROOT = (dir .. '/..'):gsub('\\', '/')
  package.path = ROOT .. '/?.lua;' .. package.path
end

local socket   = require('lib.socket')
local sched    = require('lib.sched')
local sys      = require('lib.sys')
local json     = require('lib.json')
local log      = require('lib.log')
local base64   = require('lib.base64')
local sha1     = require('lib.sha1')
local bit      = require('bit')
local process  = require('lib.process')

local schar, sbyte, ssub, sformat = string.char, string.byte, string.sub, string.format
local concat, floor = table.concat, math.floor

local KEEP = false
for i = 1, #arg do if tostring(arg[i]) == '--keep' then KEEP = true end end

log.setLevel('error')

-- =========================================================== tiny framework ==
local suites, cur = {}, nil
local totalPass, totalFail = 0, 0
local notes = {}

local function suite(name)
  cur = { name = name, pass = 0, fail = 0 }
  suites[#suites + 1] = cur
  return cur
end

local function check(ok, desc, detail)
  if ok then
    cur.pass, totalPass = cur.pass + 1, totalPass + 1
  else
    cur.fail, totalFail = cur.fail + 1, totalFail + 1
    io.write('    FAIL  ', desc, detail and ('  -- ' .. tostring(detail)) or '', '\n')
  end
  return ok
end

local function eq(got, want, desc)
  if got == want then return check(true, desc) end
  local g, w = tostring(got), tostring(want)
  if #g > 200 then g = g:sub(1, 197) .. '...' end
  return check(false, desc, sformat('got %q, want %q', g, w))
end

local function runSuite(name, fn)
  suite(name)
  local ok, e = pcall(fn)
  if not ok then
    cur.fail, totalFail = cur.fail + 1, totalFail + 1
    io.write('    FAIL  suite crashed: ', tostring(e), '\n')
  end
end

local function note(fmt, ...) notes[#notes + 1] = sformat(fmt, ...) end

-- ================================================================ temp files =
local function tempRoot()
  local base = sys.getEnv('TMPDIR') or sys.getEnv('TEMP') or sys.getEnv('TMP') or '/tmp'
  base = tostring(base):gsub('\\', '/'):gsub('/$', '')
  local r = sys.randomU32()
  return sformat('%s/luaclient-hubapi-%08x', base, r)
end

local DATA = tempRoot()
local storage = require('hub.storage')
assert(storage.fs.mkdirp(DATA))

local function rmrf(dir)
  -- Only ever the directory this run created, and only the files it knows about.
  local names = { 'users.json', 'accounts.json', 'characters.json', 'instances.json',
                  'proxies.json', 'scripts.json', 'secret.key', 'audit.jsonl',
                  'fakeworker.lua' }
  for _, n in ipairs(names) do pcall(storage.fs.remove, dir .. '/' .. n) end
  for i = 1, 5 do pcall(storage.fs.remove, dir .. '/audit.' .. i .. '.jsonl') end
end

-- ================================================================ fake worker
local FAKE_WORKER = [==[
-- fakeworker.lua -- a stand-in for `luajit main.lua`, implementing exactly the
-- half of control/server.lua that hub/supervisor.lua talks to, and no game.
-- Written by test/hubapisuite.lua and spawned by the real supervisor through
-- lib/process.lua.  See the protocol block at the top of hub/supervisor.lua.
--
-- The supervisor appends opts.extraArgs, so the repo root is the LAST argument.
local argv = { ... }
local ROOT = argv[#argv]
package.path = ROOT .. '/?.lua;' .. package.path

local socket     = require('lib.socket')
local sched      = require('lib.sched')
local sys        = require('lib.sys')
local json       = require('lib.json')
local httpserver = require('lib.httpserver')
local wsserver   = require('lib.wsserver')

-- UNBUFFERED, not line-buffered: the MSVC CRT treats _IOLBF as _IOFBF, so on
-- Windows a line-buffered pipe holds the control-endpoint announcement until the
-- buffer fills and the supervisor's spawn deadline expires.  main.lua does the
-- same thing for the same reason.
io.stdout:setvbuf('no')
local function say(s) io.write(s); io.stdout:flush() end

socket.init()

-- ------------------------------------------------------------------ the flags
local FLAGS = {}
for i = 1, #argv do
  local k, v = tostring(argv[i]):match('^%-%-([%w%-]+)=(.*)$')
  if k then FLAGS[k] = v else
    local b = tostring(argv[i]):match('^%-%-([%w%-]+)$')
    if b then FLAGS[b] = true end
  end
end
if FLAGS['control-token-fd'] ~= '0' then
  say('worker: expected --control-token-fd=0\n'); os.exit(1)
end

-- stdin, in flag order: the control token, then the proxy credential if asked for.
local TOKEN = io.read('*l')
if not TOKEN or #TOKEN < 8 then say('worker: no control token on stdin\n'); os.exit(1) end
local PROXY_AUTH = nil
if FLAGS['proxy-auth'] == 'fd:0' then PROXY_AUTH = io.read('*l') end

local NAME  = FLAGS['instance-name'] or 'worker'
local CRASH = (FLAGS['bot-profile'] == 'crash')

-- ------------------------------------------------------------------ the state
local sockets, botEnabled = {}, false
local account, character, world = nil, nil, nil
local inGame = false
local exp, level = 42000000, 137
local t0 = sys.nowMs()

-- ---------------------------------------------------------- real bot wiring
-- Work item N3 / CONFIGAPI.md: `config.get`/`config.set`/`config.list` are
-- forwarded verbatim to control/commands.lua (work item N2) running against a
-- REAL bot.new(...) instance wired to the profile directory the supervisor
-- passed in `--bot-profile=`.  This is not a second mock of the config
-- surface: it is the exact same module hub/api.lua would forward to if this
-- were `main.lua`, so "running" and "stopped" (hub/botconfig.lua, reading the
-- same directory) are two independent code paths over one real file tree.
-- Every other test in this file passes a throwaway string ('crash',
-- 'profile_1') as --bot-profile and never expects a real bot here, so this
-- only activates for a directory that genuinely has vBot content in it.
local FAKE_LC, REAL_COMMANDS
do
  local dir = FLAGS['bot-profile']
  if type(dir) == 'string' and dir ~= '' and dir ~= 'crash' then
    local okc, cfglib = pcall(require, 'bot.config')
    -- A precise signal, not "the directory has anything in it at all": other
    -- suites' worker runs (this one's own restart/backoff tests included)
    -- leave a bare `profile_1/storage/` behind in the repo root from earlier
    -- --dry-run passes, which is non-empty but is not a vBot profile.  Only a
    -- directory that genuinely has HealBot.json wires a real bot here.
    if okc and cfglib.fileExists(dir .. '/vBot_configs/profile_1/HealBot.json') then
      local okcmd, commandsMod = pcall(require, 'control.commands')
      local okb, botMod = pcall(require, 'bot.init')
      local oks, stateMod = pcall(require, 'game.state')
      local oke, eventsMod = pcall(require, 'lib.events')
      if okcmd and okb and oks and oke then
        local st = stateMod.new()
        st.player = { id = 1, name = 'FakeBotPlayer', pos = { x = 1000, y = 1000, z = 7 },
                      health = 500, maxHealth = 1000, mana = 200, maxMana = 400,
                      level = 100, capacity = 900, states = 0, inventory = {} }
        local bus = eventsMod.new()
        local lc = {
          log = { info = function() end, warn = function() end,
                  error = function() end, debug = function() end },
          sched = nil, state = st,
          sender = setmetatable({}, { __index = function() return function() return 'ok' end end }),
          events = { bus = bus, on = function(n, f) return bus:on(n, f) end,
                     off = function(h) return bus:off(h) end,
                     emit = function(n, d) return bus:emit(n, d) end },
          config = { botProfile = dir, botVProfile = 1, dryRun = false },
        }
        local okn, b = pcall(botMod.new, lc, { profileDir = dir, vprofile = 1, autostart = false })
        if okn then
          local okw = pcall(b.wireModules, b, {})
          if okw then lc.bot = b; FAKE_LC, REAL_COMMANDS = lc, commandsMod end
        end
      end
    end
  end
end

local function statusPayload()
  return { instance = NAME, state = inGame and 'online' or 'offline',
           loginState = inGame and 'online' or 'offline',
           botEnabled = botEnabled, account = account, character = character,
           hp = 1800, maxHp = 2400, mana = 900, maxMana = 1500,
           level = level, expPercent = 42.5, cap = 900, maxCap = 2400,
           soul = 100, stamina = 2400, waypoint = 'wp-7',
           waypointIndex = 7, waypointCount = 40,
           uptimeMs = sys.nowMs() - t0,
           pos = { x = 32800, y = 31900, z = 7 } }
end

local function statsPayload()
  return { level = level, experience = exp, expPerHour = 512000, moneyPerHour = 88000,
           lootPerHour = 120000, wastePerHour = 32000, balancePerHour = 88000,
           killsPerHour = 210, deaths = 0, pricesLoaded = 0 }
end

local function broadcast(event, data)
  local ok, payload = pcall(json.encode, { event = event, data = data })
  if not ok then return end
  for ws in pairs(sockets) do
    if ws:isOpen() then ws:send(payload) end
  end
end

-- ---------------------------------------------------------------- the commands
local cmds = {}

cmds['status'] = function() return statusPayload() end
cmds['stats']  = function() return statsPayload() end

cmds['login'] = function(a)
  a = a or {}
  account, character, world = a.account, a.character, a.world
  say(('worker: login account=%s passwordBytes=%d tokenBytes=%d character=%s world=%s\n')
      :format(tostring(a.account), #tostring(a.password or ''), #tostring(a.token or ''),
              tostring(a.character), tostring(a.world)))
  inGame = true
  broadcast('loginState', { state = 'connecting' })
  broadcast('log', { level = 'info', text = 'worker: entering the game' })
  broadcast('loginState', { state = 'online' })
  broadcast('gameStart', {})
  return { ok = true, character = a.character }
end

cmds['logout'] = function() inGame = false; broadcast('gameEnd', {}); return true end
cmds['relogin'] = function() return true end

cmds['bot.enable'] = function(a)
  botEnabled = (a and a.on) and true or false
  return { botEnabled = botEnabled }
end

cmds['bot.listConfigs'] = function()
  return { cavebot = { 'drefia.cfg', 'venore.cfg' },
           targetbot = { 'knight.json' },
           profiles = { 'profile_1', 'profile_2' },
           macros = { { name = 'healbot', label = 'HealBot', on = true },
                      { name = 'eat_food', label = 'Eat food', on = false } } }
end

cmds['bot.setCavebot'] = function(a)
  say('worker: cavebot=' .. tostring(a and a.name) .. '\n'); return true
end
cmds['bot.setTargetbot'] = function(a)
  say('worker: targetbot=' .. tostring(a and a.name) .. '\n'); return true
end
cmds['bot.reload'] = function() return true end
cmds['bot.setMacro'] = function(a)
  return { name = a and a.name, on = (a and a.on) and true or false }
end

cmds['script.put'] = function(a)
  say(('worker: script.put %s (%d bytes)\n')
      :format(tostring(a and a.name), #tostring(a and a.source or '')))
  return true
end
cmds['script.remove'] = function() return true end
cmds['script.list'] = function() return { scripts = {} } end

cmds['exec'] = function(a)
  local code = (a and a.code) or ''
  if code:find('boom') then return nil, 'chunk:1: boom' end
  return { output = 'exec-ok:' .. code }
end

cmds['say'] = function(a)
  broadcast('chat', { channel = 'Default', from = NAME, text = (a and a.text) or '' })
  return true
end

local stopping = false
cmds['shutdown'] = function()
  say('worker: shutting down on request\n')
  stopping = true
  sched.after(150, function() sched.stop() end)
  return true
end

local REAL_FORWARDED = { ['bot.setCavebot'] = true, ['bot.setTargetbot'] = true,
                         ['bot.listConfigs'] = true }
local function dispatch(req)
  -- config.* (work item N3), plus the config-selection commands it depends on
  -- (bot.setCavebot/bot.setTargetbot), forward to the REAL control/commands.lua
  -- against the REAL bot instance wired above, when one was built for this
  -- worker -- so a config.get('cavebot') sees the SAME selection hub/api.lua
  -- just pushed via instance.update, exactly as the real worker would.
  if FAKE_LC and (tostring(req.cmd or ''):match('^config%.') or REAL_FORWARDED[req.cmd]) then
    local ok, res = REAL_COMMANDS.dispatch({ LC = FAKE_LC }, req.cmd, req.args or {})
    if not ok then return { id = req.id, ok = false, error = tostring(res) } end
    return { id = req.id, ok = true, result = res }
  end
  -- control/server.lua answers with `error` as a plain STRING; so do we, so the
  -- hub's normalisation is exercised rather than bypassed.
  local fn = cmds[tostring(req.cmd or '')]
  if not fn then
    return { id = req.id, ok = false,
             error = ('unknown command %q (known: status, exec, ...)'):format(tostring(req.cmd)) }
  end
  local ok, res, e = pcall(fn, req.args or {})
  if not ok then return { id = req.id, ok = false, error = tostring(res) } end
  if res == nil then return { id = req.id, ok = false, error = tostring(e or 'failed') } end
  return { id = req.id, ok = true, result = res }
end

-- ---------------------------------------------------------------- the endpoint
local function tokenOf(req)
  local h = req:header('authorization')
  if h then
    local t = h:match('^%s*[Bb]earer%s+(.+)%s*$')
    if t then return t end
  end
  local x = req:header('x-control-token')
  if x then return x end
  return req.query and req.query.token or nil
end

local wsRoute = httpserver.websocketRoute(wsserver, {
  allowNoOrigin = true,
  onMessage = function(ws, msg)
    local ok, req = pcall(json.decode, msg)
    if not ok or type(req) ~= 'table' then return end
    local ans = dispatch(req)
    local eok, payload = pcall(json.encode, ans)
    if eok then ws:send(payload) end
  end,
  onClose = function(ws) sockets[ws] = nil end,
})

local srv = httpserver.new{
  host = '127.0.0.1', port = tonumber(FLAGS['control-port']) or 0,
  allowedHosts = { '127.0.0.1', 'localhost' },
  onRequest = function(req, res)
    if tokenOf(req) ~= TOKEN then
      return res:json(401, { ok = false, error = { code = 'unauthorized', message = 'bad token' } })
    end
    if req.path == '/health' then
      return res:json(200, { ok = true, instance = NAME, uptimeMs = sys.nowMs() - t0 })
    end
    if req.path == '/rpc' and req.method == 'POST' then
      local body = req:json()
      if type(body) ~= 'table' then
        return res:json(400, { ok = false, error = { code = 'bad-request', message = 'bad body' } })
      end
      return res:json(200, dispatch(body))
    end
    if req.path == '/ws' then
      local ws = wsRoute(req, res)
      if ws then sockets[ws] = true end
      return ws
    end
    return res:json(404, { ok = false, error = { code = 'not-found', message = 'no route' } })
  end,
}

local port, err = srv:start()
if not port then say('worker: listen failed: ' .. tostring(err) .. '\n'); os.exit(3) end

say(('control-endpoint 127.0.0.1 %d %s\n'):format(port, NAME))
say('worker: fake worker up for ' .. NAME .. '\n')
say('worker: proxy=' .. tostring(FLAGS['proxy'] or 'direct') ..
    ' proxyAuthBytes=' .. tostring(PROXY_AUTH and #PROXY_AUTH or 0) .. '\n')
say('worker: tokenBytes=' .. #TOKEN .. '\n')

sched.every(150, function()
  if stopping then return end
  exp = exp + 900
  broadcast('status', statusPayload())
  broadcast('stats', statsPayload())
end)

if CRASH then
  sched.after(400, function() say('worker: simulated crash\n'); os.exit(9) end)
end

sched.run()
say('worker: exit\n')
os.exit(0)
]==]

do
  local f = assert(io.open(DATA .. '/fakeworker.lua', 'wb'))
  f:write(FAKE_WORKER)
  f:close()
end

-- The interpreter running this suite is the one the hub must spawn workers with.
local function selfInterpreter()
  local a = rawget(_G, 'arg')
  local i, best = -1, nil
  while a and a[i] do best = a[i]; i = i - 1 end
  return best and (tostring(best):gsub('\\', '/')) or (sys.isWindows and 'luajit.exe' or 'luajit')
end
local LUAJIT = selfInterpreter()

-- ================================================================ the reactor
-- lib/sched.lua has no single-turn entry point, so a step is `run() until a
-- stop timer fires`.  Everything in this suite is therefore driven by the real
-- reactor, exactly as the hub is.
local function step(ms)
  local stopAt = sys.nowMs() + (ms or 20)
  local t = sched.every(5, function() if sys.nowMs() >= stopAt then sched.stop() end end)
  sched.run()
  sched.cancel(t)
end

local function waitFor(cond, ms, why)
  local deadline = sys.nowMs() + (ms or 8000)
  while sys.nowMs() < deadline do
    if cond() then return true end
    step(20)
  end
  return cond() or false
end

-- ============================================================== HTTP client ==
local jar = {}                 -- cookie name -> value

local function setCookiesFrom(headers)
  local raw = headers['set-cookie']
  if not raw then return end
  for _, piece in ipairs(type(raw) == 'table' and raw or { raw }) do
    for one in tostring(piece):gmatch('[^\n]+') do
      local k, v = one:match('^%s*([^=;]+)=([^;]*)')
      if k then
        if v == '' then jar[k] = nil else jar[k] = v end
      end
    end
  end
end

local function cookieHeader()
  local parts = {}
  for k, v in pairs(jar) do parts[#parts + 1] = k .. '=' .. v end
  table.sort(parts)
  return #parts > 0 and concat(parts, '; ') or nil
end

--- One request over its own connection (Connection: close), driven by the reactor.
local function httpRequest(port, method, path, body, headers)
  local s = assert(socket.tcp())
  assert(s:connect('127.0.0.1', port))
  local rx, done, closed = '', false, false
  sched.onSocket(s, function()
    while true do
      local d, err = s:recv(65536)
      if d == nil then closed = true; done = true; return end
      if d == '' then return end
      rx = rx .. d
    end
  end)
  local lines = {
    sformat('%s %s HTTP/1.1', method, path),
    'Host: 127.0.0.1:' .. port,
    'Connection: close',
  }
  for k, v in pairs(headers or {}) do
    if v ~= false then lines[#lines + 1] = k .. ': ' .. tostring(v) end
  end
  local ck = (headers and headers['Cookie'] == false) and nil or cookieHeader()
  if ck then lines[#lines + 1] = 'Cookie: ' .. ck end
  if body then
    lines[#lines + 1] = 'Content-Length: ' .. #body
  end
  local head = concat(lines, '\r\n') .. '\r\n\r\n'
  s:send(head .. (body or ''))

  waitFor(function() return done end, 15000)
  sched.removeSocket(s)
  pcall(function() s:close() end)

  local i = rx:find('\r\n\r\n', 1, true)
  if not i then return nil, 'no response head: ' .. tostring(#rx) .. ' bytes' end
  local headBlock = rx:sub(1, i - 1)
  local payload = rx:sub(i + 4)
  local status = tonumber(headBlock:match('^HTTP/1%.%d (%d+)'))
  local hdrs = {}
  for lineTxt in headBlock:gmatch('[^\r\n]+') do
    local k, v = lineTxt:match('^([^:]+):%s*(.-)%s*$')
    if k then
      k = k:lower()
      if hdrs[k] then hdrs[k] = hdrs[k] .. '\n' .. v else hdrs[k] = v end
    end
  end
  setCookiesFrom(hdrs)
  return { status = status, headers = hdrs, body = payload, head = headBlock }
end

local seq = 0
--- POST /api/rpc.  opts.contentType / opts.origin / opts.secFetchSite / opts.csrf
--- / opts.noCookie let one call deliberately break a CSRF rule.
local function rpc(port, cmd, args, opts)
  opts = opts or {}
  seq = seq + 1
  local payload = json.encode{ id = seq, cmd = cmd, args = args or {} }
  local h = { ['Content-Type'] = opts.contentType or 'application/json' }
  if opts.origin ~= nil then h['Origin'] = opts.origin end
  if opts.secFetchSite then h['Sec-Fetch-Site'] = opts.secFetchSite end
  if opts.csrf ~= nil then h['X-CSRF-Token'] = opts.csrf
  elseif jar['hub_csrf'] and not opts.noCsrf then h['X-CSRF-Token'] = jar['hub_csrf'] end
  if opts.noCookie then h['Cookie'] = false end
  local res, e = httpRequest(port, 'POST', '/api/rpc', payload, h)
  if not res then return nil, e end
  local ok, doc = pcall(json.decode, res.body)
  res.json = ok and doc or nil
  res.result = res.json and res.json.result or nil
  res.err = res.json and res.json.error or nil
  return res
end

local function rpcOk(port, cmd, args, opts)
  local res, e = rpc(port, cmd, args, opts)
  if not res then error('rpc ' .. cmd .. ': ' .. tostring(e), 2) end
  if res.status ~= 200 or not res.json or res.json.ok ~= true then
    error(sformat('rpc %s: HTTP %s %s', cmd, tostring(res.status),
                  res.err and (res.err.code .. ' ' .. res.err.message) or res.body:sub(1, 200)), 2)
  end
  return res.result
end

-- ========================================================= WebSocket client ==
local function mask(payload, key)
  local out = {}
  for i = 1, #payload do
    out[i] = schar(bit.bxor(sbyte(payload, i), sbyte(key, ((i - 1) % 4) + 1)))
  end
  return concat(out)
end

local function clientFrame(op, payload)
  payload = payload or ''
  local key = schar(sys.randomU32() % 256, sys.randomU32() % 256,
                    sys.randomU32() % 256, sys.randomU32() % 256)
  local n, hdr = #payload, nil
  if n < 126 then hdr = schar(0x80 + op, 0x80 + n)
  elseif n < 65536 then hdr = schar(0x80 + op, 0xFE, floor(n / 256), n % 256)
  else error('frame too large for the test client') end
  return hdr .. key .. mask(payload, key)
end

local function parseServerFrames(buf, pos)
  local frames = {}
  while true do
    if #buf - pos + 1 < 2 then break end
    local b1, b2 = sbyte(buf, pos), sbyte(buf, pos + 1)
    local op = bit.band(b1, 0x0F)
    local fin = bit.band(b1, 0x80) ~= 0
    local len = bit.band(b2, 0x7F)
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
    if #buf - at + 1 < len then break end
    frames[#frames + 1] = { op = op, fin = fin, payload = ssub(buf, at, at + len - 1) }
    pos = at + len
  end
  return frames, pos
end

local WsClient = {}
WsClient.__index = WsClient

local function wsConnect(port, opts)
  opts = opts or {}
  local s = assert(socket.tcp())
  assert(s:connect('127.0.0.1', port))
  local keyBytes = {}
  for i = 1, 16 do keyBytes[i] = schar(sys.randomU32() % 256) end
  local key = base64.encode(concat(keyBytes))
  local c = setmetatable({ sock = s, rbuf = '', rpos = 1, key = key, events = {},
                           handshook = false, status = nil, headers = {}, dead = false },
                         WsClient)
  sched.onSocket(s, function()
    while true do
      local d, e = s:recv(65536)
      if d == nil then c.dead = true; return end
      if d == '' then break end
      c.rbuf = c.rbuf .. d
    end
    if not c.handshook then
      local i = c.rbuf:find('\r\n\r\n', 1, true)
      if not i then return end
      local head = c.rbuf:sub(1, i - 1)
      c.rbuf, c.rpos = c.rbuf:sub(i + 4), 1
      c.status = tonumber(head:match('^HTTP/1%.%d (%d+)'))
      for ln in head:gmatch('[^\r\n]+') do
        local k, v = ln:match('^([^:]+):%s*(.-)%s*$')
        if k then c.headers[k:lower()] = v end
      end
      c.handshook = (c.status == 101)
      if not c.handshook then c.dead = true; return end
    end
    local frames, np = parseServerFrames(c.rbuf, c.rpos)
    c.rpos = np
    if c.rpos > 32768 then c.rbuf = ssub(c.rbuf, c.rpos); c.rpos = 1 end
    for _, f in ipairs(frames) do
      if f.op == 0x9 then s:send(clientFrame(0xA, f.payload))
      elseif f.op == 0x1 then
        local ok, doc = pcall(json.decode, f.payload)
        if ok and type(doc) == 'table' and doc.event then
          c.events[#c.events + 1] = doc
        end
      elseif f.op == 0x8 then c.closed = true end
    end
  end)
  local lines = {
    'GET /api/events HTTP/1.1',
    'Host: 127.0.0.1:' .. port,
    'Upgrade: websocket',
    'Connection: Upgrade',
    'Sec-WebSocket-Key: ' .. key,
    'Sec-WebSocket-Version: 13',
  }
  if not opts.noOrigin then
    lines[#lines + 1] = 'Origin: ' .. (opts.origin or ('http://127.0.0.1:' .. port))
  end
  if not opts.noCookie then
    local ck = cookieHeader()
    if ck then lines[#lines + 1] = 'Cookie: ' .. ck end
  end
  s:send(concat(lines, '\r\n') .. '\r\n\r\n')
  return c
end

function WsClient:countEvents(name)
  local n = 0
  for _, e in ipairs(self.events) do if e.event == name then n = n + 1 end end
  return n
end

function WsClient:lastEvent(name)
  for i = #self.events, 1, -1 do if self.events[i].event == name then return self.events[i] end end
  return nil
end

function WsClient:close()
  pcall(function() self.sock:send(clientFrame(0x8, schar(0x03, 0xE8))) end)
  sched.removeSocket(self.sock)
  pcall(function() self.sock:close() end)
end

-- ================================================================ hub driver =
local hubMain = require('hub.main')

local function buildHub(extra)
  local o = assert(hubMain.parseArgs{
    '--port=0', '--bind=127.0.0.1',
    '--data-dir=' .. DATA,
    '--panel-dir=' .. ROOT .. '/panel',
    -- cwd = the repo root, so the child's default package.path finds lib/;
    -- the worker script itself is an absolute path in the temp data dir.
    '--workers-dir=' .. ROOT,
    '--worker-script=' .. DATA .. '/fakeworker.lua',
    '--luajit=' .. LUAJIT,
    '--no-autostart',
  })
  for k, v in pairs(extra or {}) do o[k] = v end
  local hub, e = hubMain.build(o)
  if not hub then error('hub.build: ' .. tostring(e), 2) end
  -- fakeworker.lua takes the repo root as its LAST chunk argument; the child's
  -- cwd is already that directory, so '.' is both correct and path-safe.
  hub.sup.extraArgs = { '.' }
  return hub
end

local function teardown(hub)
  pcall(function() hub.server:stop() end)
  -- The same call hub/main.lua's M.shutdown makes, so what these suites drive is
  -- the production exit path and not a test-only shortcut.
  pcall(function() hubMain.flushCaches(hub) end)
  pcall(function() hub.sup:shutdownAll(2000) end)
  waitFor(function() return hub.sup:allStopped() end, 6000)
  pcall(function() hub.sup:reap(2000) end)
  pcall(function() hub.tel:uninstall() end)
  pcall(function() hub.tel:flush() end)
  pcall(function() hub.storage:close() end)
  pcall(function() hub.audit:close() end)
  step(50)
end

-- Shared state across the suites below.
local hub, PORT
local ADMIN = { name = 'arnold', password = 'correct-horse-battery' }
local USER  = { name = 'sam', password = 'another-long-password' }
local ids = {}

-- =========================================================== 1. bootstrap ====
runSuite('bootstrap / first run', function()
  hub = buildHub()
  PORT = hub.port
  check(PORT and PORT > 0, 'the hub bound an ephemeral loopback port')
  note('hub port %d, data dir %s', PORT, DATA)

  local health = httpRequest(PORT, 'GET', '/api/health')
  eq(health.status, 200, '/api/health answers without a session')
  eq(json.decode(health.body).bootstrap, true, '   and says bootstrap is needed')

  local s = rpcOk(PORT, 'auth.session', {})
  eq(s.bootstrap, true, 'auth.session reports bootstrap')
  eq(s.user, nil, '   with no user')
  eq(s.insecure, false, '   and insecure=false on a loopback bind')

  local denied = rpc(PORT, 'instance.list', {})
  eq(denied.status, 401, 'every other command is 401 before bootstrap')

  local bad = rpc(PORT, 'auth.bootstrap',
                  { token = string.rep('0', 64), name = ADMIN.name, password = ADMIN.password })
  eq(bad.status, 403, 'a wrong bootstrap token is refused')
  eq(bad.err and bad.err.code, 'forbidden', '   with code forbidden')

  local token = hub.auth:bootstrapToken()
  check(type(token) == 'string' and #token == 64, 'the hub minted a 32-byte bootstrap token')

  local short = rpc(PORT, 'auth.bootstrap', { token = token, name = ADMIN.name, password = 'short' })
  eq(short.status, 400, 'a too-short administrator password is refused')

  local res = rpc(PORT, 'auth.bootstrap',
                  { token = token, name = ADMIN.name, password = ADMIN.password })
  eq(res.status, 200, 'the right token creates the administrator')
  eq(res.result and res.result.user and res.result.user.role, 'admin', '   with role admin')
  check(jar['hub_sid'] ~= nil, '   and sets the session cookie')
  check(jar['hub_csrf'] ~= nil, '   and the CSRF cookie')

  local setC = res.headers['set-cookie'] or ''
  check(setC:find('HttpOnly'), 'the session cookie is HttpOnly')
  check(setC:find('SameSite=Strict'), 'the session cookie is SameSite=Strict')
  check(not setC:find('Secure'), '   and NOT Secure on a loopback bind')

  eq(hub.auth:needsBootstrap(), false, 'the hub has left bootstrap state')
  local again = rpc(PORT, 'auth.bootstrap', { token = token, name = 'x', password = 'x' })
  eq(again.status, 409, 'bootstrap cannot be run twice')

  local who = rpcOk(PORT, 'auth.session', {})
  eq(who.user and who.user.name, ADMIN.name, 'auth.session now reports the administrator')
end)

-- ================================================================ 2. CSRF ====
runSuite('server / CSRF and cookies', function()
  local formPost = rpc(PORT, 'proxy.create',
                       { label = 'x', host = '10.0.0.1', port = 8080 },
                       { contentType = 'application/x-www-form-urlencoded' })
  eq(formPost.status, 415, 'a form content type on a mutating command is 415')
  eq(formPost.err and formPost.err.code, 'csrf-invalid', '   with code csrf-invalid')

  local foreign = rpc(PORT, 'proxy.create',
                      { label = 'x', host = '10.0.0.1', port = 8080 },
                      { origin = 'http://evil.example' })
  eq(foreign.status, 403, 'a foreign Origin on a mutating command is 403')
  eq(foreign.err and foreign.err.code, 'csrf-invalid', '   with code csrf-invalid')

  local crossSite = rpc(PORT, 'proxy.create',
                        { label = 'x', host = '10.0.0.1', port = 8080 },
                        { secFetchSite = 'cross-site' })
  eq(crossSite.status, 403, 'Sec-Fetch-Site: cross-site is 403')

  local badToken = rpc(PORT, 'proxy.create',
                       { label = 'x', host = '10.0.0.1', port = 8080 },
                       { csrf = 'deadbeef' })
  eq(badToken.status, 403, 'a wrong X-CSRF-Token is 403')

  local readOnly = rpc(PORT, 'proxy.list', {}, { origin = 'http://evil.example' })
  eq(readOnly.status, 200, 'a READ-ONLY command is not blocked by Origin')

  local good = rpc(PORT, 'proxy.create',
                   { label = 'de-frankfurt', host = '10.20.0.11', port = 8080,
                     user = 'w1', pass = 'proxy-secret' })
  eq(good.status, 200, 'the right cookie + token + content type is accepted')
  ids.proxy = good.result.proxy.id
  eq(good.result.proxy.hasPass, true, '   the proxy password is stored')
  eq(good.result.proxy.pass, nil, '   and never returned')

  -- --csrf-strict makes the header mandatory
  local strictHub = require('hub.server').new{
    host = '127.0.0.1', port = 0, api = hub.api, auth = hub.auth, tel = hub.tel,
    csrfStrict = true, log = log }
  local sp = strictHub:start()
  check(sp and sp > 0, 'a second front end starts with --csrf-strict')
  local noHeader = rpc(sp, 'proxy.list', {}, { noCsrf = true })
  eq(noHeader.status, 200, '   a read-only command still needs no header')
  local mutNoHeader = rpc(sp, 'proxy.create',
                          { label = 'y', host = '10.0.0.2', port = 8080 }, { noCsrf = true })
  eq(mutNoHeader.status, 403, '   a mutating command without X-CSRF-Token is refused')
  eq(mutNoHeader.err and mutNoHeader.err.code, 'csrf-invalid', '   with code csrf-invalid')
  strictHub:stop()
  step(50)
end)

-- ======================================================== 3. bind refusal ====
runSuite('server / refuses a non-loopback bind', function()
  local serverMod = require('hub.server')
  local s = serverMod.new{ host = '0.0.0.0', port = 0, api = hub.api, auth = hub.auth, log = log }
  local port, e = s:start()
  eq(port, nil, 'binding 0.0.0.0 without --allow-insecure is refused')
  check(tostring(e):find('refusing to bind'), '   with an explanatory error', e)
  check(tostring(e):find('%-%-allow%-insecure'), '   naming the flag that overrides it')

  local s2 = serverMod.new{ host = '10.1.2.3', port = 0, api = hub.api, auth = hub.auth,
                            allowInsecure = true, log = log }
  eq(s2.insecure, true, 'with --allow-insecure the hub marks itself insecure')
  eq(s2.secureCookies, true, '   and would set Secure on its cookies')
  eq(serverMod.isLoopback('127.0.0.1'), true, 'isLoopback(127.0.0.1)')
  eq(serverMod.isLoopback('127.4.5.6'), true, 'isLoopback(127.4.5.6)')
  eq(serverMod.isLoopback('localhost'), true, 'isLoopback(localhost)')
  eq(serverMod.isLoopback('0.0.0.0'), false, 'isLoopback(0.0.0.0)')
  eq(serverMod.sameOrigin('http://127.0.0.1:8777', '127.0.0.1:8777'), true, 'sameOrigin match')
  eq(serverMod.sameOrigin('http://evil.example', '127.0.0.1:8777'), false, 'sameOrigin mismatch')
  eq(serverMod.sameOrigin('http://127.0.0.1:9999', '127.0.0.1:8777'), false, 'sameOrigin port')
end)

-- ============================================================ 4. the CRUD ====
runSuite('api / accounts, characters, instances, scripts', function()
  local acc = rpcOk(PORT, 'account.create',
                    { label = 'main-eu', login = 'l4g-main', password = 'game-password-1' })
  ids.account = acc.account.id
  eq(acc.account.label, 'main-eu', 'a game account is created')
  eq(acc.account.hasPassword, true, '   with its password sealed at rest')
  eq(acc.account.password, nil, '   and never echoed')

  local ch = rpcOk(PORT, 'character.create',
                   { accountId = ids.account, name = 'Arnoldus', world = 'Gunzodus',
                     vocation = 'Knight' })
  ids.character = ch.character.id
  eq(ch.character.name, 'Arnoldus', 'a character is created')

  local dup = rpc(PORT, 'character.create',
                  { accountId = ids.account, name = 'arnoldus', world = 'Gunzodus' })
  eq(dup.status, 409, 'a duplicate character name is refused')

  local inst = rpcOk(PORT, 'instance.create',
                     { characterId = ids.character, proxyId = ids.proxy,
                       cavebotConfig = 'drefia.cfg', targetbotConfig = 'knight.json' })
  ids.instance = inst.instance.id
  eq(inst.instance.characterName, 'Arnoldus', 'an instance is created')
  eq(inst.instance.state, 'stopped', '   in state stopped')
  eq(inst.instance.proxyLabel, 'de-frankfurt', '   with its proxy joined in')

  local dupI = rpc(PORT, 'instance.create', { characterId = ids.character })
  eq(dupI.status, 409, 'a second instance for one character is refused')

  local up = rpcOk(PORT, 'instance.update',
                   { id = ids.instance, patch = { cavebotConfig = 'venore.cfg', autoRelogin = false } })
  eq(up.instance.cavebotConfig, 'venore.cfg', 'instance.update writes the cavebot config')
  eq(up.instance.autoRelogin, false, '   and autoRelogin')

  local badField = rpc(PORT, 'instance.update',
                       { id = ids.instance, patch = { ownerUserId = 'u_someone' } })
  eq(badField.status, 400, 'a field outside the allowed patch set is refused')

  local sc = rpcOk(PORT, 'script.upload',
                   { name = 'refill.lua', source = '-- refill\nmacro(2000, "refill", function() end)\n' })
  ids.script = sc.script.id
  eq(sc.script.name, 'refill.lua', 'a script is uploaded')
  check(#sc.script.sha256 == 64, '   with a sha256')

  local badName = rpc(PORT, 'script.upload', { name = 'refill', source = 'x' })
  eq(badName.status, 400, 'a script name without .lua is refused')

  local got = rpcOk(PORT, 'script.get', { id = ids.script })
  check(got.source:find('macro%(2000'), 'the uploaded source reads back')

  local assigned = rpcOk(PORT, 'script.assign',
                         { id = ids.script, instanceIds = { ids.instance } })
  eq(#assigned.script.instanceIds, 1, 'the script is assigned to the instance')

  local list = rpcOk(PORT, 'instance.list', {})
  eq(#list.instances, 1, 'instance.list shows the one instance')
  eq(#list.instances[1].scripts, 1, '   carrying the assigned script')
end)

-- =============================================== 5. roles / authorisation ====
runSuite('api / role and ownership enforcement', function()
  local created = rpcOk(PORT, 'admin.userCreate',
                        { name = USER.name, password = USER.password, role = 'user' })
  ids.user = created.user.id
  eq(created.user.role, 'user', 'the administrator creates a plain user')

  local adminJar = {}
  for k, v in pairs(jar) do adminJar[k] = v end

  -- become the plain user
  jar = {}
  local li = rpc(PORT, 'auth.login', { name = USER.name, password = 'wrong-password' })
  eq(li.status, 401, 'a wrong password is 401')
  local li2 = rpcOk(PORT, 'auth.login', { name = USER.name, password = USER.password })
  eq(li2.user.role, 'user', 'the plain user signs in')

  local adminRoutes = {
    'admin.users', 'admin.userCreate', 'admin.userUpdate', 'admin.userDelete',
    'admin.userResetPassword', 'admin.sessions', 'admin.sessionRevoke', 'admin.audit',
  }
  local allForbidden = true
  for _, cmd in ipairs(adminRoutes) do
    local r = rpc(PORT, cmd, { id = ids.user, name = 'x', password = '0123456789', role = 'user' })
    if r.status ~= 403 or not r.err or r.err.code ~= 'forbidden' then
      allForbidden = false
      check(false, 'a user is refused ' .. cmd, tostring(r.status))
    end
  end
  check(allForbidden, 'a user gets 403 forbidden from every admin route (' ..
        #adminRoutes .. ' checked)')

  local mine = rpcOk(PORT, 'instance.list', {})
  eq(#mine.instances, 0, "a user does not see the administrator's instances")
  local probe = rpc(PORT, 'instance.get', { id = ids.instance })
  eq(probe.status, 404, "someone else's instance id is 404, not 403 (no id oracle)")
  local startOther = rpcOk(PORT, 'instance.start', { ids = { ids.instance } })
  eq(startOther.results[1].ok, false, "a user cannot start someone else's instance")
  -- Remote Lua is admin-equivalent (it runs unsandboxed under the hub's uid with
  -- the data directory readable), so a plain account is refused BEFORE ownership
  -- is even considered.  403 with a capability message, not 404.
  local execOther = rpc(PORT, 'instance.exec', { id = ids.instance, code = 'return 1' })
  eq(execOther.status, 403, "a plain user cannot exec at all -- 403, not an ownership 404")
  check(execOther.err and execOther.err.code == 'forbidden' and
        tostring(execOther.err.message):find('canExec', 1, true) ~= nil,
        '   and the refusal names the capability an administrator can grant',
        execOther.err and execOther.err.message)
  local upOther = rpc(PORT, 'script.upload', { name = 'evil.lua', source = 'return 1' })
  eq(upOther.status, 403, 'a plain user cannot upload a script either')
  local accs = rpcOk(PORT, 'account.list', {})
  eq(#accs.accounts, 0, "a user does not see the administrator's game accounts")
  local chars = rpcOk(PORT, 'character.list', {})
  eq(#chars.characters, 0, '   nor their characters')
  local scripts = rpcOk(PORT, 'script.list', {})
  eq(#scripts.scripts, 0, '   nor their scripts')

  rpcOk(PORT, 'auth.logout', {})
  local after = rpcOk(PORT, 'auth.session', {})
  eq(after.user, nil, 'logout clears the session')
  local afterList = rpc(PORT, 'instance.list', {})
  eq(afterList.status, 401, '   and the cookie no longer authenticates')

  -- back to the administrator
  jar = {}
  local back = rpcOk(PORT, 'auth.login', { name = ADMIN.name, password = ADMIN.password })
  eq(back.user.role, 'admin', 'the administrator signs back in')
  check(back.user.canExec == true, '   and an administrator always carries the exec capability')

  -- ---- the capability itself: granted, used, revoked ----------------------
  local granted = rpcOk(PORT, 'admin.userUpdate', { id = ids.user, patch = { canExec = true } })
  eq(granted.user.canExec, true, 'an administrator can grant canExec to a plain account')

  local adminJar2 = {}
  for k, v in pairs(jar) do adminJar2[k] = v end
  jar = {}
  local sess = rpcOk(PORT, 'auth.login', { name = USER.name, password = USER.password })
  eq(sess.user.canExec, true, '   the grant shows up in the granted account`s own session')
  local up = rpc(PORT, 'script.upload', { name = 'granted.lua', source = 'return 1' })
  eq(up.status, 200, '   and the account may now upload a script')
  -- put the fleet back the way the later sections expect to find it
  if up.status == 200 and up.result and up.result.script then
    rpcOk(PORT, 'script.delete', { id = up.result.script.id })
  end

  jar = {}
  for k, v in pairs(adminJar2) do jar[k] = v end
  local revoked = rpcOk(PORT, 'admin.userUpdate', { id = ids.user, patch = { canExec = false } })
  eq(revoked.user.canExec, false, 'the capability can be revoked again')
  jar = {}
  rpcOk(PORT, 'auth.login', { name = USER.name, password = USER.password })
  local up2 = rpc(PORT, 'script.upload', { name = 'revoked.lua', source = 'return 1' })
  eq(up2.status, 403, '   and the very next request is refused')

  -- the grant, the revocation and both refusals are in the audit log
  jar = {}
  for k, v in pairs(adminJar2) do jar[k] = v end
  local aud = rpcOk(PORT, 'admin.audit', { limit = 400 })
  local sawGrant, sawRevoke, sawDenied = false, false, false
  for _, r in ipairs(aud.rows or {}) do
    if r.action == 'user.canExec' and tostring(r.detail):find('GRANTED') then sawGrant = true end
    if r.action == 'user.canExec' and tostring(r.detail):find('revoked') then sawRevoke = true end
    if r.action == 'instance.exec' and r.outcome == 'denied' then sawDenied = true end
  end
  check(sawGrant, 'the audit log records the grant')
  check(sawRevoke, '   and the revocation')
  check(sawDenied, '   and the refusal of a plain account`s exec')
end)

-- ======================================= 5b. the isolation the roles imply ===
-- Everything here is a boundary the previous section assumed and did not check:
-- who may MUTATE a shared proxy, whether a bulk action is bounded, whether a
-- cross-tenant probe leaves a trace, and whether a self-service form can lock
-- the account it belongs to.  The suite is signed in as the ADMINISTRATOR on
-- entry (the roles section signs back in at its end) and leaves it that way.
runSuite('api / mutation boundaries the shared pool does not remove', function()
  local adminJar = {}
  for k, v in pairs(jar) do adminJar[k] = v end

  -- ---- a shared proxy pool is about USE, not about ownership of the entry ---
  local mine = rpcOk(PORT, 'proxy.create',
                     { label = 'admin-exit', host = 'exit.example.com', port = 8080 })
  local adminProxy = mine.proxy.id
  eq(mine.proxy.canEdit, true, 'the creator may edit the proxy they created')

  -- become the plain user the roles section made
  jar = {}
  rpcOk(PORT, 'auth.login', { name = USER.name, password = USER.password })

  local seen = rpcOk(PORT, 'proxy.list', {})
  local row
  for _, p in ipairs(seen.proxies) do if p.id == adminProxy then row = p end end
  check(row ~= nil, 'the pool is still SHARED: a plain user sees the entry')
  eq(row and row.canEdit, false, '   but is told they may not change it')
  eq(row and row.hasPass, false, '   and never sees the credential')

  -- Repointing somebody else's exit node is a man-in-the-middle switch for every
  -- instance attached to it: every instance tunnels its game traffic through
  -- whatever host lands here on its next start.
  local repoint = rpc(PORT, 'proxy.update',
                      { id = adminProxy, patch = { host = 'attacker.example', port = 9999 } })
  eq(repoint.status, 404, "a user cannot repoint someone else's proxy")
  local relabel = rpc(PORT, 'proxy.update', { id = adminProxy, patch = { label = 'pwned' } })
  eq(relabel.status, 404, '   nor relabel it')
  local wipe = rpc(PORT, 'proxy.delete', { id = adminProxy })
  eq(wipe.status, 404, '   nor delete it')

  -- ...while their OWN proxy is fully theirs.
  local ownP = rpcOk(PORT, 'proxy.create',
                     { label = 'user-exit', host = 'user.example.com', port = 3128 })
  eq(ownP.proxy.canEdit, true, 'a user may edit the proxy they created')
  local ownEdit = rpcOk(PORT, 'proxy.update',
                        { id = ownP.proxy.id, patch = { label = 'user-exit-2' } })
  eq(ownEdit.proxy.label, 'user-exit-2', '   and the edit takes')

  -- ---- a bulk action is bounded -------------------------------------------
  -- Unbounded, this wrote one fsynced audit record per failing id: 20,000 ids in
  -- one request, and eleven such requests scrolled the whole retention away.
  local many = {}
  for i = 1, 5000 do many[i] = 'i_' .. i end
  local flood = rpc(PORT, 'instance.start', { ids = many })
  eq(flood.status, 400, 'a 5000-id bulk action is refused outright')
  check(flood.err and tostring(flood.err.message):find('100', 1, true) ~= nil,
        '   and the message names the cap', flood.err and flood.err.message)

  local batch = {}
  for i = 1, 20 do batch[i] = 'i_missing_' .. i end
  local refused = rpcOk(PORT, 'instance.start', { ids = batch })
  eq(#refused.results, 20, 'a legal batch still answers per id')
  eq(refused.results[1].ok, false, '   with each id marked failed')

  -- ---- a cross-tenant probe leaves a trace --------------------------------
  rpc(PORT, 'instance.delete', { id = ids.instance })
  rpc(PORT, 'account.delete',  { id = ids.account })
  rpc(PORT, 'character.delete', { id = ids.character })
  rpc(PORT, 'script.assign', { id = ids.script, instanceIds = {} })

  -- ---- the self-service password form cannot lock the account -------------
  -- Proving the current password used to run the real login limiter, so five
  -- mistyped entries locked the caller out of the panel for fifteen minutes.
  for _ = 1, 8 do
    local r = rpc(PORT, 'auth.changePassword',
                  { current = 'definitely-not-it', next = 'a-brand-new-password' })
    eq(r.status, 403, 'a wrong current password is refused')
  end
  local stillIn = rpc(PORT, 'instance.list', {})
  eq(stillIn.status, 200, '   and the session is still usable afterwards')
  jar = {}
  local relogin = rpc(PORT, 'auth.login', { name = USER.name, password = USER.password })
  eq(relogin.status, 200,
     'eight wrong entries in the password FORM did not lock the account out of logging in')

  -- ---- signing in again drops the session the client already held ---------
  local firstSid = jar['hub_sid']
  check(type(firstSid) == 'string' and #firstSid > 0, 'the first sign-in set a session cookie')
  rpcOk(PORT, 'auth.login', { name = USER.name, password = USER.password })
  local secondSid = jar['hub_sid']
  check(secondSid ~= firstSid, 'a second sign-in mints a different token')
  local oldJar = { hub_sid = firstSid, hub_csrf = jar['hub_csrf'] }
  local keep = jar
  jar = oldJar
  local stale = rpc(PORT, 'instance.list', {})
  eq(stale.status, 401, '   and the PREVIOUS token no longer authenticates')
  jar = keep

  -- back to the administrator, and check what the log caught
  jar = {}
  for k, v in pairs(adminJar) do jar[k] = v end
  local aud = rpcOk(PORT, 'admin.audit', { limit = 500 })
  local probes = {}
  for _, r in ipairs(aud.rows or {}) do
    if r.actor == USER.name and r.outcome == 'denied' then probes[r.action] = true end
  end
  check(probes['instance.delete'], "a user's refused instance.delete is in the log")
  check(probes['account.delete'], '   and their refused account.delete')
  check(probes['proxy.update'] or probes['proxy.delete'],
        '   and their attempt on somebody else`s proxy')

  -- ---- a proxy can actually be DETACHED from an instance ------------------
  -- The documented empty string mapped to Lua nil, which deletes the key from
  -- the patch table: the update became a silent no-op that answered 200 with the
  -- old proxy still attached.
  local before = rpcOk(PORT, 'instance.get', { id = ids.instance })
  check(before.instance.proxyId ~= nil, 'the instance starts out with a proxy attached')
  local detached = rpcOk(PORT, 'instance.update', { id = ids.instance, patch = { proxyId = '' } })
  eq(detached.instance.proxyId, nil, 'PATCH {proxyId:""} really detaches it')
  eq(detached.instance.proxyLabel, nil, '   and the joined label goes with it')
  local after = rpcOk(PORT, 'instance.get', { id = ids.instance })
  eq(after.instance.proxyId, nil, '   and it stayed detached')
  -- `false` means the same thing rather than reaching the model as a boolean
  rpcOk(PORT, 'instance.update', { id = ids.instance, patch = { proxyId = ids.proxy } })
  local detach2 = rpcOk(PORT, 'instance.update',
                        { id = ids.instance, patch = { proxyId = false } })
  eq(detach2.instance.proxyId, nil, 'PATCH {proxyId:false} detaches it too, without an error')
  -- put the fleet back the way the later sections expect it
  rpcOk(PORT, 'instance.update', { id = ids.instance, patch = { proxyId = ids.proxy } })
  local restored = rpcOk(PORT, 'instance.get', { id = ids.instance })
  eq(restored.instance.proxyId, ids.proxy, '   and it can be re-attached')

  -- an unmentioned proxyId is NOT a detach
  rpcOk(PORT, 'instance.update', { id = ids.instance, patch = { cavebotConfig = 'venore.cfg' } })
  eq(rpcOk(PORT, 'instance.get', { id = ids.instance }).instance.proxyId, ids.proxy,
     'an update that does not mention proxyId leaves it alone')

  -- ---- proxy.test is not a port scanner -----------------------------------
  local priv = rpcOk(PORT, 'proxy.create',
                     { label = 'loopback-probe', host = '127.0.0.1', port = PORT })
  local scan = rpcOk(PORT, 'proxy.test', { id = priv.proxy.id })
  eq(scan.ok, false, 'testing a loopback address is refused')
  eq(scan.reason, 'blocked', '   with a fixed reason')
  check(not tostring(scan.error):find('HTTP/', 1, true),
        '   and no peer banner in the answer', tostring(scan.error))
  rpcOk(PORT, 'proxy.delete', { id = priv.proxy.id })

  -- ---- the error code for a duplicate account name is a STRING ------------
  local dupUser = rpc(PORT, 'admin.userCreate',
                      { name = USER.name, password = '0123456789ab', role = 'user' })
  eq(dupUser.status, 409, 'a duplicate web-account name is a conflict')
  eq(type(dupUser.err and dupUser.err.code), 'string', '   and the code is a string, not a number')
  eq(dupUser.err.code, 'conflict', '   namely "conflict"')

  -- ---- a deletion is not announced to every signed-in account ------------
  -- `publish('instance', {removed=true}, {})` -- an EMPTY opts table -- means
  -- "everyone" to hub/telemetry.lua's visibility predicate, so every account
  -- learned the ids of other people's instances and scripts as they vanished.
  local realTel = hub.api.tel
  local seen = {}
  hub.api.tel = setmetatable({
    publish = function(_, event, data, opts)
      if type(data) == 'table' and data.removed then
        seen[#seen + 1] = { event = event, opts = opts or {} }
      end
      return realTel and realTel.publish and realTel:publish(event, data, opts)
    end,
  }, { __index = realTel })

  local victimAcc = rpcOk(PORT, 'account.create',
    { label = 'scope-check', login = 'scope@example.invalid', password = 'x-password-1' })
  local victimCh = rpcOk(PORT, 'character.create',
    { accountId = victimAcc.account.id, name = 'ScopeChar', world = 'Gunzodus' })
  local victimInst = rpcOk(PORT, 'instance.create', { characterId = victimCh.character.id })
  rpcOk(PORT, 'instance.delete', { id = victimInst.instance.id })

  local instEvent
  for _, e in ipairs(seen) do if e.event == 'instance' then instEvent = e end end
  check(instEvent ~= nil, 'deleting an instance publishes a removal')
  check(instEvent and instEvent.opts.instanceId == victimInst.instance.id,
        '   scoped to that instance, so only accounts that could see it are told',
        instEvent and require('lib.json').encode(instEvent.opts))

  seen = {}
  local victimScript = rpcOk(PORT, 'script.upload',
    { name = 'scope.lua', source = '-- scope\n' })
  rpcOk(PORT, 'script.delete', { id = victimScript.script.id })
  local scriptEvent
  for _, e in ipairs(seen) do if e.event == 'script' then scriptEvent = e end end
  check(scriptEvent ~= nil, 'deleting a script publishes a removal')
  check(scriptEvent and scriptEvent.opts.userId ~= nil,
        '   scoped to its owner, not broadcast to the whole panel',
        scriptEvent and require('lib.json').encode(scriptEvent.opts))

  hub.api.tel = realTel
  rpcOk(PORT, 'account.delete', { id = victimAcc.account.id })

  -- clean up what this section created
  rpcOk(PORT, 'proxy.delete', { id = adminProxy })
  rpcOk(PORT, 'proxy.delete', { id = ownP.proxy.id })
end)

-- ================================================= 6. workers + telemetry ====
local ws
runSuite('supervisor / a real worker process', function()
  ws = wsConnect(PORT)
  waitFor(function() return ws.handshook or ws.dead end, 4000)
  eq(ws.status, 101, 'an authenticated WebSocket upgrades')
  waitFor(function() return ws:countEvents('hello') > 0 end, 3000)
  eq(ws:countEvents('hello') > 0, true, '   and receives the hello frame')

  local started = rpcOk(PORT, 'instance.start', { ids = { ids.instance } })
  eq(started.results[1].ok, true, 'instance.start is accepted')

  local ok = waitFor(function() return hub.sup:state(ids.instance) == 'online' end, 15000)
  if not ok then
    -- A failure here is nearly always the worker refusing to start; show its output.
    io.write('    --- worker ring buffer ---\n')
    for _, l in ipairs(hub.sup:logs(ids.instance, 60)) do
      io.write('      ', tostring(l.level), ' ', tostring(l.text), '\n')
    end
    io.write('    --- state=', tostring(hub.sup:state(ids.instance)), ' ---\n')
  end
  eq(ok, true, 'the worker really came up and reported online')
  local info = hub.sup:info(ids.instance)
  check(info.pid and info.pid > 0, 'the supervisor knows the child pid (' .. tostring(info.pid) .. ')')
  check(process.isPidAlive(info.pid), '   and the process is really alive')
  ids.pid = info.pid

  -- The handshake commands (login, script.put, bot.setCavebot) travel over the
  -- control socket AFTER the worker has announced its port, so the lines they
  -- produce arrive a few reactor turns later than the spawn line.  Poll for them
  -- rather than reading the ring once and hoping.
  local logs
  local sawEndpoint, sawWorker, sawToken, sawProxy = false, false, false, false
  local sawLogin, sawScript, sawCavebot = false, false, false
  waitFor(function()
    logs = rpcOk(PORT, 'instance.logs', { id = ids.instance, limit = 400 })
    for _, l in ipairs(logs.lines) do
      local t = l.text
      if t:find('^control%-endpoint 127%.0%.0%.1 %d+ Arnoldus') then sawEndpoint = true end
      if t:find('fake worker up for Arnoldus') then sawWorker = true end
      if t:find('tokenBytes=64') then sawToken = true end
      if t:find('proxy=10%.20%.0%.11:8080') and t:find('proxyAuthBytes=15') then sawProxy = true end
      -- 'game-password-1' is 15 bytes; the worker counts, it never echoes
      if t:find('login account=l4g%-main passwordBytes=15') and t:find('character=Arnoldus') then
        sawLogin = true
      end
      if t:find('script%.put refill%.lua') then sawScript = true end
      if t:find('cavebot=venore%.cfg') then sawCavebot = true end
    end
    return sawEndpoint and sawWorker and sawToken and sawProxy and
           sawLogin and sawScript and sawCavebot
  end, 20000)
  check(sawEndpoint, "the worker's control-endpoint announcement is captured")
  check(sawWorker, "   and so is the rest of its stdout")
  check(sawToken, 'the 32-byte control token reached the child over stdin, not argv')
  check(sawProxy, 'the proxy host is in argv and its decrypted credential came over stdin')
  check(sawLogin, 'the game-account password reached the worker in the `login` command')
  check(sawScript, 'the assigned script was pushed after the handshake')
  check(sawCavebot, 'the cavebot config was pushed after the handshake')

  local desc = nil
  for _, l in ipairs(logs.lines) do
    local d = l.text:match('supervisor: spawned pid %d+ %-%- (.*)$')
    if d then desc = d end
  end
  check(desc ~= nil, 'the spawn is logged with the command line')
  check(desc and not desc:find('game%-password'), '   and the command line holds no game password')
  check(desc and not desc:find('proxy%-secret'), '   and no proxy password')
  check(desc and desc:find('%-%-control%-token%-fd=0'), '   and reads the token from stdin')

  local out = rpcOk(PORT, 'instance.exec', { id = ids.instance, code = 'return getLevel()' })
  eq(out.output, 'exec-ok:return getLevel()', 'instance.exec round-trips through the worker')

  local boom = rpc(PORT, 'instance.exec', { id = ids.instance, code = 'boom()' })
  eq(boom.status, 400, 'a worker-side exec error surfaces as an error')
  eq(boom.err and boom.err.code, 'worker-error',
     "   normalised from the worker's plain-string error")
  check(boom.err and boom.err.message:find('boom'), "   carrying the worker's message")

  local cfgs = rpcOk(PORT, 'instance.configs', { id = ids.instance })
  eq(#cfgs.cavebot, 2, 'instance.configs is answered by the running worker')
  eq(cfgs.macros[1].name, 'healbot', '   including the macro list')

  local be = rpcOk(PORT, 'instance.botEnable', { ids = { ids.instance }, on = true })
  eq(be.results[1].ok, true, 'instance.botEnable reaches the worker')

  rpcOk(PORT, 'instance.say', { id = ids.instance, text = 'hello world' })
  waitFor(function() return #rpcOk(PORT, 'instance.chat', { id = ids.instance }).messages > 0 end, 3000)
  local chat = rpcOk(PORT, 'instance.chat', { id = ids.instance })
  check(#chat.messages > 0, 'instance.say produced a chat message from the worker')
end)

runSuite('telemetry / events reach a panel socket', function()
  waitFor(function() return ws:countEvents('status') >= 2 and ws:countEvents('stats') >= 2 end, 8000)
  check(ws:countEvents('status') >= 2, 'status frames reach the WebSocket subscriber (' ..
        ws:countEvents('status') .. ')')
  check(ws:countEvents('stats') >= 2, 'stats frames reach it too (' ..
        ws:countEvents('stats') .. ')')
  local st = ws:lastEvent('stats')
  eq(st and st.data and st.data.expPerHour, 512000, '   carrying exp/h from the worker')
  eq(st and st.data and st.data.moneyPerHour, 88000, '   and money/h')
  local su = ws:lastEvent('status')
  eq(su and su.data and su.data.id, ids.instance, '   tagged with the instance id')

  local live = rpcOk(PORT, 'instance.get', { id = ids.instance })
  eq(live.instance.live.expPerHour, 512000, 'the REST view carries the same numbers')
  eq(live.instance.state, 'online', '   and the live state')
  check((live.instance.live.uptimeMs or 0) > 0, '   and the supervisor uptime')

  local tstats = hub.tel:stats()
  check(tstats.sockets >= 1, 'telemetry counts the subscriber')
  check(tstats.sent > 0, '   and has flushed frames to it (' .. tstats.sent .. ')')
  note('telemetry: %d queued, %d sent, %d dropped, %d skipped',
       tstats.queued, tstats.sent, tstats.dropped, tstats.skipped)

  -- a socket with no session, and one from a foreign origin
  local savedJar = jar
  jar = {}
  local anon = wsConnect(PORT)
  waitFor(function() return anon.status ~= nil end, 3000)
  eq(anon.status, 401, 'an unauthenticated WebSocket is refused 401')
  anon:close()
  jar = savedJar
  local foreign = wsConnect(PORT, { origin = 'http://evil.example' })
  waitFor(function() return foreign.status ~= nil end, 3000)
  eq(foreign.status, 403, 'a foreign-Origin WebSocket is refused 403')
  foreign:close()
  step(50)
end)

runSuite('supervisor / graceful stop reaps the child', function()
  local stopped = rpcOk(PORT, 'instance.stop', { ids = { ids.instance } })
  eq(stopped.results[1].ok, true, 'instance.stop is accepted')
  local gone = waitFor(function() return hub.sup:state(ids.instance) == 'stopped' end, 15000)
  eq(gone, true, 'the supervisor reports the instance stopped')
  local reaped = waitFor(function() return not process.isPidAlive(ids.pid) end, 8000)
  eq(reaped, true, 'the child process is really gone (pid ' .. tostring(ids.pid) .. ')')
  eq(process.count(), 0, 'lib/process.lua holds no live handle')

  local again = rpcOk(PORT, 'instance.stop', { ids = { ids.instance } })
  eq(again.results[1].ok, false, 'stopping an already-stopped instance is refused')
end)

runSuite('supervisor / restart backoff on an unexpected exit', function()
  rpcOk(PORT, 'instance.update', { id = ids.instance, patch = { botProfile = 'crash' } })
  rpcOk(PORT, 'instance.start', { ids = { ids.instance } })
  local w = hub.sup:worker(ids.instance)
  local backedOff = waitFor(function()
    return w and (w.restarts or 0) >= 2
  end, 20000)
  check(backedOff, 'a worker that keeps dying is restarted with a growing backoff (' ..
        tostring(w and w.restarts) .. ' restarts)')
  check(w and (w.state == 'backoff' or w.state == 'starting' or w.state == 'running'),
        '   and the instance sits in the backoff/start cycle, not silently dead',
        w and w.state)
  hub.sup:stopInstance(ids.instance)
  waitFor(function() return hub.sup:state(ids.instance) == 'stopped' end, 10000)
  rpcOk(PORT, 'instance.update', { id = ids.instance, patch = { botProfile = 'profile_1' } })
  eq(process.count(), 0, 'nothing is left running afterwards')
end)

-- ================================================================ 7. audit ====
runSuite('audit / a record for every action, admin only', function()
  local page = rpcOk(PORT, 'admin.audit', { limit = 500 })
  check(#page.rows > 0, 'the administrator can read the audit log (' .. #page.rows .. ' rows)')
  local byAction, byOutcome = {}, {}
  for _, r in ipairs(page.rows) do
    byAction[r.action] = (byAction[r.action] or 0) + 1
    byOutcome[r.outcome] = (byOutcome[r.outcome] or 0) + 1
  end
  for _, want in ipairs{ 'login.ok', 'login.fail', 'logout', 'user.create',
                         'account.create', 'character.create', 'proxy.create',
                         'instance.create', 'instance.config', 'instance.start',
                         'instance.stop', 'script.upload', 'script.assign', 'exec' } do
    check((byAction[want] or 0) > 0, 'audited: ' .. want, 'no record found')
  end
  check((byOutcome['denied'] or 0) > 0, 'refusals are audited too (' ..
        tostring(byOutcome['denied']) .. ' denied records)')

  local sawAdminRefusal, sawExecCode, sawPassword = false, false, false
  for _, r in ipairs(page.rows) do
    if r.action == 'admin.audit' and r.outcome == 'denied' and r.actor == USER.name then
      sawAdminRefusal = true
    end
    if r.action == 'exec' and (r.detail or ''):find('getLevel') then sawExecCode = true end
    local blob = (r.detail or '') .. ' ' .. (r.target or '')
    if blob:find('game%-password') or blob:find('proxy%-secret') or
       blob:find(ADMIN.password, 1, true) or blob:find(USER.password, 1, true) then
      sawPassword = true
    end
  end
  check(sawAdminRefusal, "a user's attempt at an admin route is audited with the actor")
  check(sawExecCode, 'the exec record carries the executed code (PANEL.md asks for it)')
  check(not sawPassword, 'NO password of any kind appears anywhere in the audit log')

  local filtered = rpcOk(PORT, 'admin.audit', { action = 'exec', limit = 50 })
  check(#filtered.rows > 0, 'the log can be filtered by action')
  for _, r in ipairs(filtered.rows) do
    if r.action ~= 'exec' then check(false, '   filter is exact', r.action) end
  end
  check(true, '   filter is exact')
  local byActor = rpcOk(PORT, 'admin.audit', { actor = USER.name, limit = 50 })
  check(#byActor.rows > 0, 'the log can be filtered by actor')
  check(#(page.actions or {}) > 0, 'the response carries the action vocabulary for the UI')
  check(#(page.actors or {}) > 0, '   and the actor list')

  -- and the raw file really is append-only JSONL on disk
  local raw = storage.fs.readFile(DATA .. '/audit.jsonl')
  check(raw and #raw > 0, 'audit.jsonl exists on disk')
  local lines, decoded = 0, 0
  for ln in tostring(raw):gmatch('[^\n]+') do
    lines = lines + 1
    local ok, rec = pcall(json.decode, ln)
    if ok and rec.action and rec.t and rec.actor then decoded = decoded + 1 end
  end
  eq(decoded, lines, 'every line of audit.jsonl is a complete JSON record (' .. lines .. ')')

  -- sessions listing (admin only)
  local sess = rpcOk(PORT, 'admin.sessions', {})
  check(#sess.sessions >= 1, 'admin.sessions lists the live sessions')
  local hasCurrent = false
  for _, s in ipairs(sess.sessions) do if s.current then hasCurrent = true end end
  check(hasCurrent, '   and marks the caller as current')
end)

-- ============================================================= 8. restart ====
runSuite('hub / restart recovers its state from disk', function()
  if ws then ws:close() end
  local savedInstance, savedScript = ids.instance, ids.script
  teardown(hub)
  step(100)
  jar = {}

  hub = buildHub()
  PORT = hub.port
  check(PORT and PORT > 0, 'the hub restarts on the same data directory')
  eq(hub.auth:needsBootstrap(), false, '   and does not ask to bootstrap again')

  -- Sessions used to die with the process.  They no longer do -- but `jar` was
  -- emptied above, so this hub is being asked about a cookie nobody presented,
  -- and the answer still has to be "no session".  The cookie that DID survive is
  -- proved in `hub / a restart does not sign everyone out` below.
  local s = rpcOk(PORT, 'auth.session', {})
  eq(s.user, nil, 'a client with no cookie is still anonymous after the restart')

  local li = rpcOk(PORT, 'auth.login', { name = ADMIN.name, password = ADMIN.password })
  eq(li.user.role, 'admin', 'the administrator signs in with the stored PBKDF2 hash')

  local list = rpcOk(PORT, 'instance.list', {})
  eq(#list.instances, 1, 'the instance came back from disk')
  eq(list.instances[1].id, savedInstance, '   with the same id')
  eq(list.instances[1].state, 'stopped', '   in state stopped (no orphan process is claimed)')
  eq(list.instances[1].characterName, 'Arnoldus', '   and its character joined in')
  eq(list.instances[1].proxyLabel, 'de-frankfurt', '   and its proxy')

  local scripts = rpcOk(PORT, 'script.list', {})
  eq(#scripts.scripts, 1, 'the uploaded script came back')
  local src = rpcOk(PORT, 'script.get', { id = savedScript })
  check(src.source:find('macro%(2000'), '   with its source intact')

  local users = rpcOk(PORT, 'admin.users', {})
  eq(#users.users, 2, 'both web accounts came back')

  local audit = rpcOk(PORT, 'admin.audit', { limit = 20 })
  check(#audit.rows > 0, 'the audit log continues across the restart')

  -- and the credentials still decrypt with secret.key
  local inst = hub.db:get('instances', savedInstance)
  local spec, e = hub.api:launchSpec(inst)
  check(spec ~= nil, 'the sealed game-account password still decrypts after a restart', e)
  eq(spec and spec.account and spec.account.password, 'game-password-1',
     '   to exactly what was stored')
  eq(spec and spec.proxy and spec.proxy.pass, 'proxy-secret', '   and so does the proxy password')
  eq(spec and #spec.scripts, 1, '   and the assigned script is in the launch payload')

  -- start it once more to prove the recovered state is really runnable
  local started = rpcOk(PORT, 'instance.start', { ids = { savedInstance } })
  eq(started.results[1].ok, true, 'the recovered instance starts again')
  local up = waitFor(function() return hub.sup:state(savedInstance) == 'online' end, 15000)
  eq(up, true, '   and the worker comes online')
  local pid = hub.sup:info(savedInstance).pid
  teardown(hub)
  local reaped = waitFor(function() return not process.isPidAlive(pid) end, 8000)
  eq(reaped, true, 'the hub shutdown reaps every child (pid ' .. tostring(pid) .. ')')
end)

-- ================================ 8b. the caches that survive a restart =====
-- PANEL.md used to say, in two places, that a hub restart signs every operator
-- out and leaves the panel's Console tab blank.  Both were memory-only state for
-- no better reason than that nobody had written them down.
runSuite('hub / a restart does not sign everyone out', function()
  -- the previous suite ends with the hub torn down; bring one back up
  hub = buildHub()
  PORT = hub.port
  -- ---- sign in, note the cookie, and leave a couple of log lines behind ----
  jar = {}
  local li = rpcOk(PORT, 'auth.login', { name = ADMIN.name, password = ADMIN.password })
  eq(li.user.role, 'admin', 'the administrator signs in')
  local sid = jar['hub_sid']
  local csrf = jar['hub_csrf']
  check(type(sid) == 'string' and #sid > 0, '   and holds a session cookie')

  local instId = rpcOk(PORT, 'instance.list', {}).instances[1].id
  hub.sup:restoreLogs(instId, {
    { t = 1, level = 'info',  text = 'a line from BEFORE the restart' },
    { t = 2, level = 'error', text = 'and the error that caused it' },
  }, { { t = 3, channel = 'Default', from = 'Someone', text = 'chat from before' } })

  -- ---- the sessions file itself ------------------------------------------
  hubMain.flushCaches(hub)
  local raw = storage.fs.readFile(DATA .. '/sessions.json')
  check(type(raw) == 'string' and #raw > 0, 'sessions.json was written to the data dir')
  check(raw and raw:find('"sum":"', 1, true), '   with the same integrity footer as the rest')
  check(raw and not raw:find(sid, 1, true),
        '   and NOT the session token itself -- only its SHA-256 digest')

  -- ---- restart, still signed in ------------------------------------------
  local savedJar = { hub_sid = sid, hub_csrf = csrf }
  teardown(hub)
  step(100)
  hub = buildHub()
  PORT = hub.port
  jar = { hub_sid = savedJar.hub_sid, hub_csrf = savedJar.hub_csrf }
  local who = rpcOk(PORT, 'auth.session', {})
  check(who.user ~= nil, 'the cookie from before the restart is still accepted')
  eq(who.user and who.user.name, ADMIN.name, '   and it is still the same account')
  local list = rpc(PORT, 'instance.list', {})
  eq(list.status, 200, '   and it can still drive the panel')

  -- ---- the worker rings came back too ------------------------------------
  local lines = hub.sup:logs(instId, 50)
  local found, foundErr = false, false
  for _, l in ipairs(lines) do
    if l.text == 'a line from BEFORE the restart' then found = true end
    if l.text == 'and the error that caused it' then foundErr = true end
  end
  check(found and foundErr, 'the worker log ring survived the restart (' ..
        tostring(#lines) .. ' lines)')
  local chat, sawChat = hub.sup:chat(instId, 50), false
  for _, c in ipairs(chat) do
    if c.text == 'chat from before' then sawChat = true end
  end
  check(sawChat, '   and so did the chat ring (' .. tostring(#chat) .. ' messages)')
  eq(hub.sup:state(instId), 'stopped',
     '   without claiming the instance is running (it has no process)')
  -- and the PANEL can read them: this is the route its Console tab calls, and
  -- the whole point is that the tab is not blank after a restart.
  local panelLines, sawPanel = rpcOk(PORT, 'instance.logs', { id = instId, limit = 50 }), false
  for _, l in ipairs(panelLines.lines or {}) do
    if l.text == 'a line from BEFORE the restart' then sawPanel = true end
  end
  check(sawPanel, '   and the panel reads them back through instance.logs')

  -- ---- revocation still wins ---------------------------------------------
  local sessions = rpcOk(PORT, 'admin.sessions', {})
  local mine
  for _, s in ipairs(sessions.sessions or {}) do
    if s.userName == ADMIN.name and s.current then mine = s.id end
  end
  check(mine ~= nil, 'the restored session is listed in the admin view')
  -- Revoke it through auth directly: the point is that the REVOCATION is what
  -- gets persisted, not that the route works (that is tested elsewhere).
  eq(hub.auth:revoke(mine), 1, 'the administrator can revoke it')
  local afterRevoke = rpc(PORT, 'instance.list', {}, { noCsrf = true })
  eq(afterRevoke.status, 401, '   and the restored cookie stops working at once')
  local rawAfter = storage.fs.readFile(DATA .. '/sessions.json') or ''
  check(not rawAfter:find(mine, 1, true),
        '   and the revocation reached the file immediately, without waiting for a flush ' ..
        '(a revoked session must not come back from a crash)')

  -- ---- an expired session is not resurrected ------------------------------
  jar = {}
  rpcOk(PORT, 'auth.login', { name = ADMIN.name, password = ADMIN.password })
  local liveSid = jar['hub_sid']
  local expiredJar = { hub_sid = liveSid, hub_csrf = jar['hub_csrf'] }
  for _, s in pairs(hub.auth.byId) do s.expiresAt = 1 end        -- long past
  hubMain.flushCaches(hub)
  teardown(hub)
  step(50)
  hub = buildHub()
  PORT = hub.port
  jar = expiredJar
  local dead = rpc(PORT, 'instance.list', {}, { noCsrf = true })
  eq(dead.status, 401, 'an EXPIRED session is not restored by a restart')
  eq(#hub.auth:sessions(), 0, '   and nothing stale is left in memory either')

  jar = {}
  rpcOk(PORT, 'auth.login', { name = ADMIN.name, password = ADMIN.password })
end)

-- ==================================== 9. against the REAL worker binary =====
-- Everything above proves the hub against a fake that implements the protocol.
-- This proves the protocol itself: hub/supervisor.lua drives the actual
-- `luajit main.lua --dry-run`, whose control endpoint is control/server.lua.
-- --dry-run needs no game server and no network, only assets/items1530.bin; if
-- that is absent the section says so instead of failing.
runSuite('supervisor / the real worker binary (control/server.lua)', function()
  local haveWorker = io.open(ROOT .. '/main.lua', 'rb')
  if haveWorker then haveWorker:close() end
  local haveAssets = io.open(ROOT .. '/assets/items1530.bin', 'rb')
  if haveAssets then haveAssets:close() end
  if not haveWorker or not haveAssets then
    note('real-worker section skipped: main.lua or assets/items1530.bin is missing')
    check(true, 'skipped (no worker binary or assets in this checkout)')
    return
  end

  local supervisor = require('hub.supervisor')
  local states, lines = {}, {}
  local sup = supervisor.new{
    luajit = LUAJIT, workersDir = ROOT, workerScript = 'main.lua',
    extraArgs = { '--dry-run' }, log = log,
    onLog   = function(_, l) lines[#lines + 1] = l.text end,
    onState = function(_, st) states[#states + 1] = st end,
  }
  sup:install()

  local ok, e = sup:startInstance('i_real', {
    instance  = { id = 'i_real' },
    character = { name = 'SuiteChar', world = 'Gunzodus' },
    account   = {},                      -- no credentials: --dry-run never logs in
    scripts   = {},
  })
  eq(ok, true, 'the supervisor spawns the real worker', e)

  local up = waitFor(function() return sup:state('i_real') == 'running' end, 40000)
  if not up then
    for i = math.max(1, #lines - 25), #lines do io.write('      ', tostring(lines[i]), '\n') end
  end
  eq(up, true, 'control/server.lua announced its endpoint and the WebSocket handshake succeeded')

  local sawEndpoint = false
  for _, t in ipairs(lines) do
    if t:find('^control%-endpoint 127%.0%.0%.1 %d+ SuiteChar') then sawEndpoint = true end
  end
  check(sawEndpoint, "   the real worker's control-endpoint line was parsed")

  local pid = sup:info('i_real').pid
  check(pid and pid > 0, 'the real worker is a live child (pid ' .. tostring(pid) .. ')')

  local answer
  sup:command('i_real', 'status', {}, function(k, r) answer = { k = k, r = r } end)
  waitFor(function() return answer ~= nil end, 15000)
  eq(answer and answer.k, true, '`status` is answered over the control WebSocket')
  eq(answer and answer.r and answer.r.instance, 'SuiteChar',
     '   and names the instance the hub asked for')

  local bad
  sup:command('i_real', 'no.such.command', {}, function(k, r) bad = { k = k, r = r } end)
  waitFor(function() return bad ~= nil end, 15000)
  eq(bad and bad.k, false, 'an unknown command comes back as an error')
  eq(bad and bad.r and bad.r.code, 'unknown-command',
     "   normalised from control/server.lua's plain-string `error`")

  sup:stopInstance('i_real')
  local stopped = waitFor(function() return sup:state('i_real') == 'stopped' end, 20000)
  eq(stopped, true, 'the real worker stops gracefully on `shutdown`')
  eq(sup:info('i_real').lastError, nil, '   with no error recorded')
  local reaped = waitFor(function() return not process.isPidAlive(pid) end, 8000)
  eq(reaped, true, '   and the process is really gone')
  sup:reap(2000)
  sup:uninstall()
end)

-- ============================================ 10. bot config API (work item N3) =
-- CONFIGAPI.md: GET/PUT/list over the six vBot config kinds, routed to the
-- live worker's control socket when running and to hub/botconfig.lua's direct
-- file access when stopped.  The fake worker wires a REAL bot.new(...)
-- instance (bot/init.lua + bot/healbot.lua + bot/attackbot.lua + ...) against
-- a copy of the real vBot_4.8 reference profile, so "running" and "stopped"
-- are two INDEPENDENT code paths reading and writing the SAME real files --
-- not one mock agreeing with itself.
runSuite('api / bot config (CONFIGAPI.md, work item N3)', function()
  jar = {}
  rpcOk(PORT, 'auth.login', { name = ADMIN.name, password = ADMIN.password })

  -- ---- locate the real reference profile; skip cleanly if it is absent -----
  local REF_PROFILE
  do
    local candidates = {
      ROOT .. '/../otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
      'D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
      '/mnt/d/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
    }
    for _, c in ipairs(candidates) do
      local f = io.open(c .. '/vBot_configs/profile_1/HealBot.json', 'r')
      if f then f:close(); REF_PROFILE = c; break end
    end
  end
  if not REF_PROFILE then
    check(true, 'SKIPPED: the reference vBot_4.8 profile is not present on this machine')
    return
  end

  local cfglib = require('bot.config')
  local isWin = package.config:sub(1, 1) == '\\'

  -- Two short, RELATIVE bot-profile directories under the repo root.  Relative
  -- (not the long temp DATA path) because hub/model.lua caps botProfile at 64
  -- bytes; hub/supervisor.lua's Sup:profileDir resolves a relative value
  -- against `workersDir` (=ROOT, the spawn cwd), and this fake worker's own
  -- --bot-profile handling does the same by construction (relative to its cwd,
  -- which the supervisor also sets to ROOT) -- so both paths land on the exact
  -- same directory.  Cleaned up at the end of this suite either way.
  local REL_A, REL_B = 'n3cfgtest_a', 'n3cfgtest_b'
  local DIR_A, DIR_B = ROOT .. '/' .. REL_A, ROOT .. '/' .. REL_B

  local function copyTree(src, dst)
    cfglib.mkdirp(dst)
    for _, name in ipairs(cfglib.listDir(src)) do
      local sp, dp = src .. '/' .. name, dst .. '/' .. name
      local f = io.open(sp, 'rb')
      local data = f and f:read('*a')
      if f then f:close() end
      if data then cfglib.writeFileAtomic(dp, data) else copyTree(sp, dp) end
    end
  end
  local function rmrfAbs(path)
    if isWin then os.execute('rmdir /s /q "' .. path:gsub('/', '\\') .. '" 2>nul')
    else os.execute('rm -rf "' .. path .. '"') end
  end
  for _, sub in ipairs{ 'cavebot_configs', 'targetbot_configs', 'vBot_configs', 'storage' } do
    copyTree(REF_PROFILE .. '/' .. sub, DIR_A .. '/' .. sub)
    copyTree(REF_PROFILE .. '/' .. sub, DIR_B .. '/' .. sub)
  end

  -- ---- an instance on DIR_A, owned by the administrator --------------------
  local acc = rpcOk(PORT, 'account.create',
                    { label = 'cfg-a', login = 'cfg-a-login', password = 'cfg-a-password-1' })
  local ch = rpcOk(PORT, 'character.create',
                   { accountId = acc.account.id, name = 'Cfgtestera', world = 'Gunzodus' })
  local inst = rpcOk(PORT, 'instance.create', { characterId = ch.character.id })
  local iid = inst.instance.id
  rpcOk(PORT, 'instance.update',
       { id = iid, patch = { botProfile = REL_A, cavebotConfig = 'bultaur_bottom',
                             targetbotConfig = 'bultaur' } })

  -- Value equality, not byte equality: lib/json.lua's encoder walks `pairs()`,
  -- whose order is not guaranteed to match between two independently-decoded
  -- tables holding the same data, so comparing json.encode(a) == json.encode(b)
  -- is a false negative waiting to happen -- exactly what CONFIGAPI.md's own
  -- compat test avoids by comparing DECODED values, not re-serialised bytes.
  local function deepEq(a, b)
    if a == b then return true end
    if type(a) ~= type(b) or type(a) ~= 'table' then return false end
    for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
  end
  local function eqData(got, want, desc)
    local eqOk = deepEq(got, want)
    local okj1, g = pcall(json.encode, got)
    local okj2, w = pcall(json.encode, want)
    return check(eqOk, desc, (not eqOk) and
      (('got %s want %s'):format(okj1 and g:sub(1, 200) or '?', okj2 and w:sub(1, 200) or '?')) or nil)
  end

  local KINDS = { 'healbot', 'conditions', 'attackbot', 'stances', 'targetbot', 'cavebot' }

  -- ================================== A. STOPPED path (hub/botconfig.lua) ===
  local got = {}
  for _, kind in ipairs(KINDS) do
    local r = rpcOk(PORT, 'instance.configGet', { id = iid, kind = kind })
    eq(r.kind, kind, 'GET ' .. kind .. ' (stopped): kind is echoed')
    eq(r.source, 'profile', '   source=profile (a real file backs it)')
    check(type(r.data) == 'table', '   data is a table')
    got[kind] = r.data
  end
  eq(#got.healbot.itemTable, 3, 'healbot: the reference profile has 3 item rules')
  eq(#got.healbot.spellTable, 2, '   and 2 spell rules')
  eq(got.conditions.curePoison, false, "conditions: curePoison compat resolves from 'curePosion'")
  eq(#got.attackbot, 8, 'attackbot: 8 entries in the active profile')
  check(#got.stances.entries >= 1, 'stances: at least one entry from the real profile')
  check(#got.cavebot >= 1, 'cavebot: at least one {type,value} pair')
  check(#got.targetbot.targeting >= 1, 'targetbot: at least one targeting entry')

  -- round trip every non-cavebot kind: PUT the same data back, GET again,
  -- compare byte-for-byte (as JSON) -- "unknown fields survive unchanged" and
  -- "ints stay ints" both fail loudly here if bot/config.lua's codec drifts.
  for _, kind in ipairs{ 'healbot', 'conditions', 'attackbot', 'stances', 'targetbot' } do
    local put = rpcOk(PORT, 'instance.configSet', { id = iid, kind = kind, data = got[kind] })
    eq(put.applied, true, 'PUT ' .. kind .. ' (stopped) applies')
    local r2 = rpcOk(PORT, 'instance.configGet', { id = iid, kind = kind })
    eqData(r2.data, got[kind], '   ' .. kind .. ' round-trips to the identical value')
  end

  -- ---- MAJOR security-review finding regression: instance.configSet's audit
  -- record must carry a real diff, not just `kind=X` -- reproducing the
  -- finding's own live-probe scenarios (healbot itemTable[1].value 40 -> a
  -- sentinel, an attackbot entry's `enabled` toggle) against a real hub.
  do
    local healSentinel = 918273
    local mutatedHeal = { itemTable = {}, spellTable = got.healbot.spellTable }
    for i, it in ipairs(got.healbot.itemTable) do
      mutatedHeal.itemTable[i] = {}
      for k, v in pairs(it) do mutatedHeal.itemTable[i][k] = v end
    end
    local origHealVal = mutatedHeal.itemTable[1].value
    mutatedHeal.itemTable[1].value = healSentinel
    rpcOk(PORT, 'instance.configSet', { id = iid, kind = 'healbot', data = mutatedHeal })
    local audH = rpcOk(PORT, 'admin.audit', { limit = 500 })
    local expectHeal = ('itemTable[1].value:%s->%s'):format(tostring(origHealVal), tostring(healSentinel))
    local sawHealDiff = false
    for _, r in ipairs(audH.rows or {}) do
      if r.action == 'instance.config' and tostring(r.detail):find(expectHeal, 1, true) then
        sawHealDiff = true
        check(r.detail ~= 'kind=healbot',
              'audit: healbot PUT detail is not just the bare kind (the pre-fix bug)', r.detail)
      end
    end
    check(sawHealDiff, 'a healbot PUT audit record shows itemTable[1].value:old->new exactly ' ..
          '(' .. expectHeal .. ')')
    -- restore the original value so earlier round-trip assertions stay valid
    rpcOk(PORT, 'instance.configSet', { id = iid, kind = 'healbot', data = got.healbot })
  end

  do
    local mutatedAtk = {}
    for i, e in ipairs(got.attackbot) do
      mutatedAtk[i] = {}
      for k, v in pairs(e) do mutatedAtk[i][k] = v end
    end
    local origEnabled = mutatedAtk[1].enabled
    mutatedAtk[1].enabled = not origEnabled
    rpcOk(PORT, 'instance.configSet', { id = iid, kind = 'attackbot', data = mutatedAtk })
    local audA = rpcOk(PORT, 'admin.audit', { limit = 500 })
    local expectAtk = ('[1].enabled:%s->%s'):format(tostring(origEnabled), tostring(not origEnabled))
    local sawAtkDiff = false
    for _, r in ipairs(audA.rows or {}) do
      if r.action == 'instance.config' and tostring(r.detail):find('kind=attackbot', 1, true)
         and tostring(r.detail):find(expectAtk, 1, true) then
        sawAtkDiff = true
      end
    end
    check(sawAtkDiff, 'an attackbot PUT audit record shows [1].enabled:old->new exactly ' ..
          '(' .. expectAtk .. '), not just kind=attackbot')
    rpcOk(PORT, 'instance.configSet', { id = iid, kind = 'attackbot', data = got.attackbot })
  end

  -- ---- invalid payload -> 400, never silently accepted ----------------------
  local bad = rpc(PORT, 'instance.configSet',
                  { id = iid, kind = 'healbot', data = { itemTable = 'not-an-array', spellTable = {} } })
  eq(bad.status, 400, 'a structurally invalid healbot payload is rejected with 400')
  eq(bad.err and bad.err.code, 'bad-request', '   code bad-request')
  local bad2 = rpc(PORT, 'instance.configSet', { id = iid, kind = 'not-a-kind', data = {} })
  eq(bad2.status, 400, 'an unknown kind is rejected with 400')
  local bad3 = rpc(PORT, 'instance.configGet', { id = iid, kind = 'not-a-kind' })
  eq(bad3.status, 400, '   for GET too')
  -- neither bad payload actually changed anything
  local afterBad = rpcOk(PORT, 'instance.configGet', { id = iid, kind = 'healbot' })
  eqData(afterBad.data, got.healbot, '   a rejected PUT leaves the file exactly as it was')

  -- ---- cross-user instance id -> 404, exactly like every other instance route
  local adminJar = {}
  for k, v in pairs(jar) do adminJar[k] = v end
  jar = {}
  rpcOk(PORT, 'auth.login', { name = USER.name, password = USER.password })
  local cross = rpc(PORT, 'instance.configGet', { id = iid, kind = 'healbot' })
  eq(cross.status, 404, "a plain user's cross-tenant id is refused 404 (not 403 -- no id oracle)")
  local crossSet = rpc(PORT, 'instance.configSet', { id = iid, kind = 'healbot', data = got.healbot })
  eq(crossSet.status, 404, '   for PUT too')
  local crossList = rpc(PORT, 'instance.configList', { id = iid, kind = 'cavebot' })
  eq(crossList.status, 404, '   and for the list route')
  jar = {}
  for k, v in pairs(adminJar) do jar[k] = v end

  -- ================================================ B. list ================
  local list = rpcOk(PORT, 'instance.configList', { id = iid, kind = 'cavebot' })
  check(#list.names >= 1, 'config list: cavebot names come back (' .. #list.names .. ')')
  eq(list.active, 'bultaur_bottom', '   active is the instance`s selected cavebot config')
  local hlist = rpcOk(PORT, 'instance.configList', { id = iid, kind = 'healbot' })
  eq(#hlist.names, 5, 'config list: healbot always has exactly 5 numbered profiles')

  -- ============ C. the security rule: cavebot function bodies need canExec ==
  -- A SEPARATE instance/profile (DIR_B) owned by the plain USER, so ownership
  -- is not what is under test -- only the capability.
  jar = {}
  rpcOk(PORT, 'auth.login', { name = USER.name, password = USER.password })
  local uacc = rpcOk(PORT, 'account.create',
                     { label = 'cfg-b', login = 'cfg-b-login', password = 'cfg-b-password-1' })
  local uch = rpcOk(PORT, 'character.create',
                    { accountId = uacc.account.id, name = 'Cfgtesterb', world = 'Gunzodus' })
  local uinst = rpcOk(PORT, 'instance.create', { characterId = uch.character.id })
  local uiid = uinst.instance.id
  rpcOk(PORT, 'instance.update', { id = uiid, patch = { botProfile = REL_B,
                                                        cavebotConfig = 'bultaur_bottom' } })

  local cb = rpcOk(PORT, 'instance.configGet', { id = uiid, kind = 'cavebot' })
  check(#cb.data >= 1, 'the plain user can read their own cavebot config')

  local gotoIdx
  for i, w in ipairs(cb.data) do
    if w.type == 'goto' then gotoIdx = i; break end
  end
  check(gotoIdx ~= nil, 'the route has at least one goto waypoint to edit')

  local edited = {}
  for i, w in ipairs(cb.data) do edited[i] = { type = w.type, value = w.value } end
  if gotoIdx then edited[gotoIdx].value = '999,999,7' end
  local putGoto = rpc(PORT, 'instance.configSet', { id = uiid, kind = 'cavebot', data = edited })
  eq(putGoto.status, 200, 'a plain user with NO canExec may freely edit a goto waypoint value')

  -- MAJOR security-review finding regression: an ORDINARY (non-function)
  -- cavebot edit's audit record used to be `kind=cavebot name=X` -- no diff
  -- at all.  admin.audit is admin-only, so borrow adminJar for the read and
  -- put the plain user's session jar right back before the test continues.
  if gotoIdx then
    local prevJar = {}
    for k, v in pairs(jar) do prevJar[k] = v end
    jar = {}
    for k, v in pairs(adminJar) do jar[k] = v end
    local audG = rpcOk(PORT, 'admin.audit', { limit = 500 })
    jar = prevJar
    local expectGoto = ('[%d].value:'):format(gotoIdx)
    local sawGotoDiff = false
    for _, r in ipairs(audG.rows or {}) do
      local d = tostring(r.detail)
      if r.action == 'instance.config' and d:find('kind=cavebot', 1, true)
         and d:find(expectGoto, 1, true) and d:find('999,999,7', 1, true) then
        sawGotoDiff = true
        check(not d:find('^kind=cavebot name=[^;]*$'),
              'audit: ordinary cavebot PUT detail is not just kind+name (the pre-fix bug)', d)
      end
    end
    check(sawGotoDiff, 'an ordinary (non-function) cavebot PUT audit record shows the changed ' ..
          'waypoint (' .. expectGoto .. '..->999,999,7), not just kind+name')
  end

  local withFunc = {}
  for i, w in ipairs(edited) do withFunc[i] = w end
  withFunc[#withFunc + 1] = { type = 'function', value = 'return true' }
  local putFunc = rpc(PORT, 'instance.configSet', { id = uiid, kind = 'cavebot', data = withFunc })
  eq(putFunc.status, 403, 'the SAME user without canExec is refused adding a function waypoint')
  eq(putFunc.err and putFunc.err.code, 'forbidden', '   code forbidden')
  check(putFunc.err and tostring(putFunc.err.message):find('canExec', 1, true) ~= nil,
        '   naming the capability an administrator can grant', putFunc.err and putFunc.err.message)

  -- confirm the refused write really did not touch the file
  local afterRefusal = rpcOk(PORT, 'instance.configGet', { id = uiid, kind = 'cavebot' })
  eq(#afterRefusal.data, #edited, '   and the refused function body was never written')

  -- grant canExec: the identical PUT now succeeds
  jar = {}
  for k, v in pairs(adminJar) do jar[k] = v end
  rpcOk(PORT, 'admin.userUpdate', { id = ids.user, patch = { canExec = true } })
  jar = {}
  rpcOk(PORT, 'auth.login', { name = USER.name, password = USER.password })
  local putFunc2 = rpc(PORT, 'instance.configSet', { id = uiid, kind = 'cavebot', data = withFunc })
  eq(putFunc2.status, 200, 'the same user WITH canExec may add the function waypoint')
  local afterGrant = rpcOk(PORT, 'instance.configGet', { id = uiid, kind = 'cavebot' })
  local sawFunc = false
  for _, w in ipairs(afterGrant.data) do if w.type == 'function' and w.value == 'return true' then sawFunc = true end end
  check(sawFunc, '   and the function waypoint is really on disk now')

  -- revoke again so later state is not affected
  jar = {}
  for k, v in pairs(adminJar) do jar[k] = v end
  rpcOk(PORT, 'admin.userUpdate', { id = ids.user, patch = { canExec = false } })

  -- MINOR security-review finding: relocating an already-approved function
  -- waypoint (same exact body, new index -- cavebotFunctionBodyChanged
  -- correctly sees no body change, by design) must succeed WITHOUT canExec,
  -- but must be surfaced in the audit trail as a shape change instead of
  -- being silently indistinguishable from an ordinary value edit.
  do
    local curData = rpcOk(PORT, 'instance.configGet', { id = uiid, kind = 'cavebot' })
    local funcIdx
    for i, w in ipairs(curData.data) do
      if w.type == 'function' and w.value == 'return true' then funcIdx = i; break end
    end
    check(funcIdx ~= nil, 'the function waypoint from the earlier grant is present to relocate')
    if funcIdx then
      local relocated = { { type = 'goto', value = '5,5,7' } }  -- inserted BEFORE everything
      for i, w in ipairs(curData.data) do relocated[#relocated + 1] = { type = w.type, value = w.value } end

      jar = {}
      rpcOk(PORT, 'auth.login', { name = USER.name, password = USER.password })  -- canExec is revoked
      local putReloc = rpc(PORT, 'instance.configSet', { id = uiid, kind = 'cavebot', data = relocated })
      eq(putReloc.status, 200,
         'relocating a function waypoint (same body, new index) succeeds WITHOUT canExec')

      jar = {}
      for k, v in pairs(adminJar) do jar[k] = v end
      local audR = rpcOk(PORT, 'admin.audit', { limit = 500 })
      local sawNote = false
      for _, r in ipairs(audR.rows or {}) do
        if r.action == 'instance.config' and
           tostring(r.detail):find('function-waypoint position/count changed', 1, true) then
          sawNote = true
        end
      end
      check(sawNote, 'the relocation is flagged in the audit trail even though canExec was not required')
    end
  end

  -- =========================== D. the RUNNING path (the live worker) ========
  local started = rpcOk(PORT, 'instance.start', { ids = { iid } })
  eq(started.results[1].ok, true, 'the config-test instance starts')
  local upOk = waitFor(function() return hub.sup:state(iid) == 'online' end, 15000)
  eq(upOk, true, 'the fake worker (with a REAL bot instance wired in) comes up')
  -- push the selection onto the now-live bot, exactly as a real login does
  rpcOk(PORT, 'instance.update',
       { id = iid, patch = { cavebotConfig = 'bultaur_bottom', targetbotConfig = 'bultaur' } })

  for _, kind in ipairs(KINDS) do
    local r = rpcOk(PORT, 'instance.configGet', { id = iid, kind = kind })
    eqData(r.data, got[kind], 'GET ' .. kind .. ' (running) matches the stopped-path value exactly')
  end

  -- a PUT while running, through the live module, really persists to disk
  local ab = rpcOk(PORT, 'instance.configGet', { id = iid, kind = 'attackbot' })
  local mutated = {}
  for i, e in ipairs(ab.data) do
    mutated[i] = {}
    for k, v in pairs(e) do mutated[i][k] = v end
  end
  mutated[1].enabled = not mutated[1].enabled
  local putRunning = rpcOk(PORT, 'instance.configSet', { id = iid, kind = 'attackbot', data = mutated })
  eq(putRunning.applied, true, 'PUT attackbot (running) applies through the live module')

  rpcOk(PORT, 'instance.stop', { ids = { iid } })
  waitFor(function() return hub.sup:state(iid) == 'stopped' end, 15000)
  local afterStop = rpcOk(PORT, 'instance.configGet', { id = iid, kind = 'attackbot' })
  eq(afterStop.data[1].enabled, mutated[1].enabled,
     '   and the running-path PUT is still there after the worker stops (it really wrote the file)')

  -- =============================== E. audit ==================================
  local aud = rpcOk(PORT, 'admin.audit', { limit = 500 })
  local putCount, deniedFuncCount, sawFullBody = 0, 0, false
  for _, r in ipairs(aud.rows or {}) do
    if r.action == 'instance.config' then
      putCount = putCount + 1
      if r.outcome == 'denied' and tostring(r.detail):find('canExec', 1, true) then
        deniedFuncCount = deniedFuncCount + 1
      end
      if tostring(r.detail):find('FUNCTION BODY CHANGED', 1, true) and
         tostring(r.detail):find('return true', 1, true) then
        sawFullBody = true
      end
    end
  end
  check(putCount > 0, 'every config PUT is audited as instance.config (' .. putCount .. ' records)')
  check(deniedFuncCount > 0, '   including the canExec refusal, marked denied')
  check(sawFullBody, '   and the function-body change is audited with the FULL new body')

  -- ---- cleanup --------------------------------------------------------------
  rpcOk(PORT, 'instance.delete', { id = iid })
  jar = {}
  rpcOk(PORT, 'auth.login', { name = USER.name, password = USER.password })
  rpcOk(PORT, 'instance.delete', { id = uiid })
  jar = {}
  for k, v in pairs(adminJar) do jar[k] = v end
  rmrfAbs(DIR_A)
  rmrfAbs(DIR_B)
end)

-- ===================================================================== report
pcall(function() process.reapAll(2000) end)
sched.reset()
if not KEEP then rmrf(DATA) end

io.write('\n============== hubapisuite ==============\n')
local width = 0
for _, s in ipairs(suites) do if #s.name > width then width = #s.name end end
for _, s in ipairs(suites) do
  io.write(('  %-' .. width .. 's  %s  %d passed'):format(
    s.name, s.fail == 0 and 'PASS' or 'FAIL', s.pass))
  if s.fail > 0 then io.write((', %d FAILED'):format(s.fail)) end
  io.write('\n')
end
io.write(('  %s\n'):format(string.rep('-', width + 20)))
for _, n in ipairs(notes) do io.write('  note: ', n, '\n') end
io.write(('  os=%s  luajit=%s\n'):format(sys.os, tostring(LUAJIT)))
io.write(('  TOTAL: %d passed, %d failed  -> %s\n'):format(
  totalPass, totalFail, totalFail == 0 and 'PASS' or 'FAIL'))
if KEEP then io.write('  data dir kept: ', DATA, '\n') end

pcall(function() socket.cleanup() end)
os.exit(totalFail == 0 and 0 or 1)
