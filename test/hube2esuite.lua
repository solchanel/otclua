--[[============================================================================
test/hube2esuite.lua -- the whole panel stack, end to end, against REAL workers.

    luajit test/hube2esuite.lua            (from D:/Claude/otclient_web/luaclient)
    luajit test/hube2esuite.lua --keep     (leave the temp data dir behind)

WHAT MAKES THIS DIFFERENT FROM test/hubapisuite.lua
  hubapisuite proves the hub's internals against a fake worker and drives the
  older POST /api/rpc envelope.  This suite proves the path a BROWSER actually
  takes:

    * every call goes through the REST surface panel/api.js declares -- the same
      method, the same path, the same request body, the same response keys;
    * the WebSocket is /ws in the panel's own dialect: {type:'auth'} first, then
      {type:'subscribe'}, and {event:'ready'} / {event:'status'} / {event:'log'}
      coming back;
    * the workers are the REAL client, `luajit main.lua --dry-run`, whose control
      endpoint is control/server.lua.  No game server is involved and nothing
      leaves the machine, but every byte between the hub and the worker is the
      production path: a spawned child, a token down a private stdin pipe, an
      announced ephemeral port, and an authenticated control WebSocket.

  It also asserts the CONTRACT in both directions: every route hub/api.lua
  serves is one panel/api.js calls, and every endpoint panel/api.js calls is one
  the hub serves.  A drift in either file fails here rather than in a browser.

Sections
  1  contract      panel/api.js <-> hub/api.lua, both directions
  2  bootstrap     first run over REST, the session cookie, the CSRF token
  3  fleet         game account -> character -> proxy -> instance, over REST
  4  worker        start a REAL worker, watch the dashboard follow it
  5  stream        /ws: auth, ready, status, subscribed log lines
  6  exec          run Lua in the worker and read the answer back
  7  scripts       upload, assign, and see it running inside the worker
  8  stop          stop it, and prove the pid is gone
  9  audit         the admin-only log recorded every one of those actions
 10  roles         a non-admin sees none of it
 11  real login    a hub-spawned worker completes the 1530 login handshake
                  against test/fakeserver.lua, with the game password decrypted
                  at spawn time and NEVER in argv or the environment
 12  surface       the development harness is not served, /ws is capped per user

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
local bit      = require('bit')
local process  = require('lib.process')
local hubapi   = require('hub.api')

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
  if #g > 240 then g = g:sub(1, 237) .. '...' end
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
local storage = require('hub.storage')
local function tempRoot()
  local base = sys.getEnv('TMPDIR') or sys.getEnv('TEMP') or sys.getEnv('TMP') or '/tmp'
  base = tostring(base):gsub('\\', '/'):gsub('/$', '')
  return sformat('%s/luaclient-hube2e-%08x', base, sys.randomU32())
end
local DATA = tempRoot()
assert(storage.fs.mkdirp(DATA))
assert(storage.fs.mkdirp(DATA .. '/scripts'))

-- Remove only what this run created.  storage.fs has no readdir, so the script
-- blobs and the history files are deleted by the ids the suite handed out (see
-- `created` below) rather than by sweeping the directory.
local created = { scripts = {}, instances = {} }
local function rmrf(dir)
  local names = { 'users.json', 'accounts.json', 'characters.json', 'instances.json',
                  'proxies.json', 'scripts.json', 'secret.key', 'audit.jsonl' }
  for _, n in ipairs(names) do pcall(storage.fs.remove, dir .. '/' .. n) end
  for i = 1, 5 do pcall(storage.fs.remove, dir .. '/audit.' .. i .. '.jsonl') end
  for _, id in ipairs(created.scripts) do
    pcall(storage.fs.remove, dir .. '/scripts/' .. id .. '.lua')
  end
  for _, id in ipairs(created.instances) do
    pcall(storage.fs.remove, dir .. '/history/' .. id .. '.json')
  end
  pcall(os.remove, dir .. '/scripts')
  pcall(os.remove, dir .. '/history')
  pcall(os.remove, dir)
end

-- ================================================================ the reactor
local function step(ms)
  local stopAt = sys.nowMs() + (ms or 20)
  local t = sched.every(5, function() if sys.nowMs() >= stopAt then sched.stop() end end)
  sched.run()
  sched.cancel(t)
end

local function waitFor(cond, ms)
  local deadline = sys.nowMs() + (ms or 8000)
  while sys.nowMs() < deadline do
    if cond() then return true end
    step(20)
  end
  return cond() or false
end

local function selfInterpreter()
  local a = rawget(_G, 'arg')
  local i, best = -1, nil
  while a and a[i] do best = a[i]; i = i - 1 end
  return best and (tostring(best):gsub('\\', '/')) or (sys.isWindows and 'luajit.exe' or 'luajit')
end
local LUAJIT = selfInterpreter()

-- ============================================================== HTTP client ==
local jar = {}

local function setCookiesFrom(headers)
  local raw = headers['set-cookie']
  if not raw then return end
  for _, piece in ipairs(type(raw) == 'table' and raw or { raw }) do
    for one in tostring(piece):gmatch('[^\n]+') do
      local k, v = one:match('^%s*([^=;]+)=([^;]*)')
      if k then if v == '' then jar[k] = nil else jar[k] = v end end
    end
  end
end

local function cookieHeader()
  local parts = {}
  for k, v in pairs(jar) do parts[#parts + 1] = k .. '=' .. v end
  table.sort(parts)
  return #parts > 0 and concat(parts, '; ') or nil
end

local function httpRequest(port, method, path, body, headers)
  local s = assert(socket.tcp())
  assert(s:connect('127.0.0.1', port))
  local rx, done = '', false
  sched.onSocket(s, function()
    while true do
      local d = s:recv(65536)
      if d == nil then done = true; return end
      if d == '' then return end
      rx = rx .. d
    end
  end)
  local lines = { sformat('%s %s HTTP/1.1', method, path),
                  'Host: 127.0.0.1:' .. port, 'Connection: close' }
  for k, v in pairs(headers or {}) do
    if v ~= false then lines[#lines + 1] = k .. ': ' .. tostring(v) end
  end
  local ck = (headers and headers['Cookie'] == false) and nil or cookieHeader()
  if ck then lines[#lines + 1] = 'Cookie: ' .. ck end
  if body then lines[#lines + 1] = 'Content-Length: ' .. #body end
  s:send(concat(lines, '\r\n') .. '\r\n\r\n' .. (body or ''))
  waitFor(function() return done end, 20000)
  sched.removeSocket(s)
  pcall(function() s:close() end)

  local i = rx:find('\r\n\r\n', 1, true)
  if not i then return nil, 'no response head (' .. #rx .. ' bytes)' end
  local headBlock, payload = rx:sub(1, i - 1), rx:sub(i + 4)
  local hdrs = {}
  for ln in headBlock:gmatch('[^\r\n]+') do
    local k, v = ln:match('^([^:]+):%s*(.-)%s*$')
    if k then
      k = k:lower()
      if hdrs[k] then hdrs[k] = hdrs[k] .. '\n' .. v else hdrs[k] = v end
    end
  end
  setCookiesFrom(hdrs)
  return { status = tonumber(headBlock:match('^HTTP/1%.%d (%d+)')),
           headers = hdrs, body = payload, head = headBlock }
end

--- One REST call, exactly as panel/rpc.js makes it: JSON in, JSON out, the CSRF
--- header on every unsafe verb, cookies carried by the jar.
local PORT
local function rest(method, path, body, opts)
  opts = opts or {}
  local payload = nil
  local h = {}
  if method ~= 'GET' and method ~= 'HEAD' then
    payload = json.encode(body or {})
    h['Content-Type'] = opts.contentType or 'application/json'
    if opts.csrf ~= nil then h['X-CSRF-Token'] = opts.csrf
    elseif jar['hub_csrf'] then h['X-CSRF-Token'] = jar['hub_csrf'] end
  end
  if opts.origin ~= nil then h['Origin'] = opts.origin end
  if opts.noCookie then h['Cookie'] = false end
  local res, e = httpRequest(opts.port or PORT, method, path, payload, h)
  if not res then return nil, e end
  local ok, doc = pcall(json.decode, res.body)
  res.json = ok and doc or nil
  res.err = res.json and res.json.error or nil
  return res
end

local function restOk(method, path, body, opts)
  local res, e = rest(method, path, body, opts)
  if not res then error(method .. ' ' .. path .. ': ' .. tostring(e), 2) end
  if res.status ~= 200 then
    error(sformat('%s %s: HTTP %s %s', method, path, tostring(res.status),
                  res.err and (tostring(res.err.code) .. ' ' .. tostring(res.err.message))
                          or res.body:sub(1, 200)), 2)
  end
  return res.json or {}
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
    local op, len = bit.band(b1, 0x0F), bit.band(b2, 0x7F)
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
    frames[#frames + 1] = { op = op, payload = ssub(buf, at, at + len - 1) }
    pos = at + len
  end
  return frames, pos
end

local Ws = {}
Ws.__index = Ws

local function wsConnect(port, opts)
  opts = opts or {}
  local s = assert(socket.tcp())
  assert(s:connect('127.0.0.1', port))
  local kb = {}
  for i = 1, 16 do kb[i] = schar(sys.randomU32() % 256) end
  local c = setmetatable({ sock = s, rbuf = '', rpos = 1, events = {},
                           handshook = false, dead = false, closeCode = nil }, Ws)
  sched.onSocket(s, function()
    while true do
      local d = s:recv(65536)
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
        if ok and type(doc) == 'table' and doc.event then c.events[#c.events + 1] = doc end
      elseif f.op == 0x8 then
        c.closed = true
        if #f.payload >= 2 then c.closeCode = sbyte(f.payload, 1) * 256 + sbyte(f.payload, 2) end
      end
    end
  end)
  local lines = { 'GET ' .. (opts.path or '/ws') .. ' HTTP/1.1',
                  'Host: 127.0.0.1:' .. port,
                  'Upgrade: websocket', 'Connection: Upgrade',
                  'Sec-WebSocket-Key: ' .. base64.encode(concat(kb)),
                  'Sec-WebSocket-Version: 13' }
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

function Ws:send(tbl) self.sock:send(clientFrame(0x1, json.encode(tbl))) end
function Ws:countEvents(name)
  local n = 0
  for _, e in ipairs(self.events) do if e.event == name then n = n + 1 end end
  return n
end
function Ws:lastEvent(name)
  for i = #self.events, 1, -1 do if self.events[i].event == name then return self.events[i] end end
end
function Ws:eventsFor(name, pred)
  local out = {}
  for _, e in ipairs(self.events) do
    if e.event == name and (not pred or pred(e.data)) then out[#out + 1] = e end
  end
  return out
end
function Ws:close()
  pcall(function() self.sock:send(clientFrame(0x8, schar(0x03, 0xE8))) end)
  sched.removeSocket(self.sock)
  pcall(function() self.sock:close() end)
end

-- ================================================================ hub driver =
local hubMain = require('hub.main')
local hub

local function buildHub()
  local o = assert(hubMain.parseArgs{
    '--port=0', '--bind=127.0.0.1',
    '--data-dir=' .. DATA,
    '--panel-dir=' .. ROOT .. '/panel',
    '--workers-dir=' .. ROOT,
    '--worker-script=main.lua',
    '--luajit=' .. LUAJIT,
    '--no-autostart',
  })
  local h, e = hubMain.build(o)
  if not h then error('hub.build: ' .. tostring(e), 2) end
  -- The REAL worker, with no game server: --dry-run boots the client, starts the
  -- bot layer and serves control/server.lua with no network at all.
  h.sup.extraArgs = { '--dry-run' }
  return h
end

local function teardown(h)
  if not h then return end
  pcall(function() h.server:stop() end)
  pcall(function() h.sup:shutdownAll(3000) end)
  waitFor(function() return h.sup:allStopped() end, 15000)
  pcall(function() h.sup:reap(3000) end)
  pcall(function() h.tel:uninstall() end)
  pcall(function() h.tel:flush() end)
  pcall(function() h.storage:close() end)
  pcall(function() h.audit:close() end)
  step(50)
end

local ADMIN = { name = 'e2eadmin', password = 'a-long-enough-secret' }
local WATCHER = { name = 'e2ewatcher', password = 'another-long-secret' }
local ids = {}
local haveWorker = false

-- ==================================================== 1. the contract ========
runSuite('contract / panel and hub agree on every route', function()
  local f = assert(io.open(ROOT .. '/panel/api.js', 'rb'))
  local src = f:read('*a'); f:close()

  -- Pull `method: 'X', path: '/api/...'` out of panel/api.js's ENDPOINTS table.
  local wanted, names = {}, {}
  for name, method, path in src:gmatch("'([%w%.]+)':%s*{%s*method:%s*'(%u+)',%s*path:%s*'([^']+)'") do
    wanted[method .. ' ' .. path] = name
    names[#names + 1] = name
  end
  check(#names >= 44, sformat('panel/api.js declares %d endpoints', #names))

  local served = {}
  for _, r in ipairs(hubapi.restRoutes()) do served[r] = true end
  eq(#hubapi.restRoutes(), #names, 'the hub serves exactly as many routes as the panel calls')

  local missing = {}
  for route, name in pairs(wanted) do
    if not served[route] then missing[#missing + 1] = name .. ' (' .. route .. ')' end
  end
  table.sort(missing)
  eq(#missing, 0, 'every endpoint the panel calls is served by the hub',
     concat(missing, ', '))

  local orphan = {}
  for route in pairs(served) do
    if not wanted[route] then orphan[#orphan + 1] = route end
  end
  table.sort(orphan)
  eq(#orphan, 0, 'the hub serves no route the panel never calls', concat(orphan, ', '))

  -- The WebSocket path and its close code are part of the contract too.
  check(src:find("path:%s*'/ws'") ~= nil or
        (function()
           local g = assert(io.open(ROOT .. '/panel/rpc.js', 'rb'))
           local s2 = g:read('*a'); g:close()
           return s2:find("opts.path || '/ws'", 1, true) ~= nil
         end)(), 'the panel opens its event stream on /ws')

  -- Error codes: every status hub/api.lua can answer with is one panel/api.js names.
  local declared = {}
  for code in src:gmatch('([%a%-]+)') do declared[code] = true end
  local unknown = {}
  for code in pairs(hubapi.STATUS) do
    if code ~= 'unknown-command' and not declared[code] then unknown[#unknown + 1] = code end
  end
  table.sort(unknown)
  eq(#unknown, 0, 'every error code the hub emits is one the panel documents',
     concat(unknown, ', '))
end)

-- ==================================================== 2. bootstrap over REST =
runSuite('bootstrap / first run through the REST surface', function()
  hub = buildHub()
  PORT = hub.port
  check(PORT and PORT > 0, 'the hub bound an ephemeral loopback port')
  note('hub port %d, data dir %s', PORT, DATA)

  local s = restOk('GET', '/api/session')
  eq(s.bootstrap, true, 'GET /api/session says the hub needs bootstrapping')
  eq(s.user, nil, '   with no user')
  eq(s.insecure, false, '   and insecure=false on a loopback bind')
  check(type(s.csrfToken) == 'string' or s.csrfToken == nil,
        '   and a csrfToken field the panel can read')

  -- Nothing else is reachable before the first administrator exists.
  local pre = rest('GET', '/api/instances')
  eq(pre.status, 401, 'GET /api/instances before bootstrap is 401')
  eq(pre.err and pre.err.code, 'unauthorized', '   with code unauthorized')

  local bad = rest('POST', '/api/bootstrap',
                   { token = string.rep('0', 64), name = 'nope', password = 'longenough1' })
  eq(bad.status, 403, 'a wrong bootstrap token is refused')

  local tok = hub.auth:bootstrapToken()
  check(type(tok) == 'string' and #tok >= 32, 'the hub minted a one-time bootstrap token')

  local shortpw = rest('POST', '/api/bootstrap',
                       { token = tok, name = ADMIN.name, password = 'short' })
  eq(shortpw.status, 400, 'a too-short administrator password is refused')

  local res = restOk('POST', '/api/bootstrap',
                     { token = tok, name = ADMIN.name, password = ADMIN.password })
  eq(res.user and res.user.name, ADMIN.name, 'POST /api/bootstrap creates the administrator')
  eq(res.user and res.user.role, 'admin', '   with the admin role')
  check(type(res.csrfToken) == 'string' and #res.csrfToken > 0,
        '   and answers with the csrfToken panel/rpc.js adopts')
  check(jar['hub_sid'] ~= nil, '   and sets the session cookie')
  check(jar['hub_csrf'] == res.csrfToken, '   and the readable CSRF cookie matches it')

  local sc = res.headers or {}
  local raw = tostring((rest('GET', '/api/session').headers or {})['set-cookie'] or '')
  local _ = sc, raw

  local again = rest('POST', '/api/bootstrap',
                     { token = tok, name = 'second', password = ADMIN.password })
  eq(again.status, 409, 'bootstrapping twice is a conflict')

  local s2 = restOk('GET', '/api/session')
  eq(s2.user and s2.user.name, ADMIN.name, 'GET /api/session now names the signed-in user')
  eq(s2.bootstrap, false, '   and bootstrap is done')

  -- CSRF still guards a write even with a valid session.
  local noHeader = rest('POST', '/api/accounts',
                        { label = 'x', login = 'x', password = 'x' }, { csrf = 'deadbeef' })
  eq(noHeader.status, 403, 'a wrong X-CSRF-Token is refused')
  eq(noHeader.err and noHeader.err.code, 'csrf-invalid',
     '   with the code panel/rpc.js retries on')
  local foreign = rest('POST', '/api/accounts',
                       { label = 'x', login = 'x', password = 'x' },
                       { origin = 'http://evil.example' })
  eq(foreign.status, 403, 'a foreign Origin is refused')

  -- REGRESSION.  hub/auth.lua's authenticate() answers `nil, <reason>, <code>` on
  -- failure, so its SECOND return value is a string.  Taking that for a user made
  -- every made-up cookie look signed in: indexing a string yields nil for id,
  -- name and role, so the request arrived with a nameless, roleless "user" that
  -- still passed the authentication gate and reached the shared-pool endpoints.
  local savedSid, savedCsrf = jar['hub_sid'], jar['hub_csrf']
  jar['hub_sid'] = 'deadbeefdeadbeefdeadbeefdeadbeef'
  local forged = rest('GET', '/api/session')
  eq(forged.status, 200, 'GET /api/session answers a forged cookie')
  eq(forged.json and forged.json.user, nil, '   with NO user -- the cookie is not a session')
  local forgedList = rest('GET', '/api/proxies')
  eq(forgedList.status, 401, 'a forged session cookie reaches no endpoint')
  eq(forgedList.err and forgedList.err.code, 'unauthorized', '   with code unauthorized')
  local forgedWrite = rest('POST', '/api/accounts',
                           { label = 'f', login = 'f', password = 'f' }, { csrf = 'x' })
  check(forgedWrite.status == 401 or forgedWrite.status == 403,
        '   and cannot create anything either')
  jar['hub_sid'], jar['hub_csrf'] = savedSid, savedCsrf
  eq(restOk('GET', '/api/session').user.name, ADMIN.name, 'the real session still works')
end)

-- ==================================================== 3. the fleet, by REST ==
runSuite('fleet / account, character, proxy and instance over REST', function()
  local acc = restOk('POST', '/api/accounts',
                     { label = 'e2e account', login = 'e2e@example.invalid',
                       password = 'game-password-e2e' })
  ids.account = acc.account and acc.account.id
  check(ids.account ~= nil, 'POST /api/accounts creates a game account')
  eq(acc.account and acc.account.password, nil, '   and never echoes the password')
  eq(acc.account and acc.account.hasPassword, true, '   but says one is stored')

  local accs = restOk('GET', '/api/accounts')
  eq(#(accs.accounts or {}), 1, 'GET /api/accounts lists it')

  local ch = restOk('POST', '/api/characters',
                    { accountId = ids.account, name = 'E2ETester', world = 'Gunzodus',
                      vocation = 'Elder Druid' })
  ids.character = ch.character and ch.character.id
  check(ids.character ~= nil, 'POST /api/characters creates a character')
  eq(ch.character and ch.character.accountLabel, 'e2e account', '   under its account')

  local px = restOk('POST', '/api/proxies',
                    { label = 'e2e proxy', kind = 'http-connect',
                      host = '127.0.0.1', port = 1, user = 'pu', pass = 'proxy-password-e2e' })
  ids.proxy = px.proxy and px.proxy.id
  check(ids.proxy ~= nil, 'POST /api/proxies creates a proxy')
  eq(px.proxy and px.proxy.pass, nil, '   and never echoes its password')
  eq(px.proxy and px.proxy.hasPass, true, '   but says one is stored')

  local inst = restOk('POST', '/api/instances',
                      { characterId = ids.character, botProfile = 'profile_1',
                        autoStart = false, autoRelogin = true })
  ids.instance = inst.instance and inst.instance.id
  created.instances[#created.instances + 1] = ids.instance
  check(ids.instance ~= nil, 'POST /api/instances creates an instance')
  eq(inst.instance and inst.instance.characterName, 'E2ETester', '   naming the character')
  eq(inst.instance and inst.instance.state, 'stopped', '   in state stopped')
  check(type(inst.instance.live) == 'table', "   with a `live` object for the dashboard")

  local one = restOk('GET', '/api/instances/' .. ids.instance)
  eq(one.instance and one.instance.id, ids.instance, 'GET /api/instances/:id returns it')

  local patched = restOk('PATCH', '/api/instances/' .. ids.instance,
                         { cavebotConfig = 'e2e-route', autoStart = false })
  eq(patched.instance and patched.instance.cavebotConfig, 'e2e-route',
     'PATCH /api/instances/:id takes a flat patch body')

  local gone = rest('GET', '/api/instances/i_does_not_exist')
  eq(gone.status, 404, 'an unknown instance id is 404, not 403')
end)

-- ==================================================== 4. a REAL worker =======
runSuite('worker / the hub starts luajit main.lua --dry-run', function()
  local w = io.open(ROOT .. '/main.lua', 'rb')
  if w then w:close() end
  local a = io.open(ROOT .. '/assets/items1530.bin', 'rb')
  if a then a:close() end
  if not w or not a then
    note('real-worker sections skipped: main.lua or assets/items1530.bin is missing')
    check(true, 'skipped (no worker binary or assets in this checkout)')
    return
  end
  haveWorker = true

  local res = restOk('POST', '/api/instances/actions',
                     { action = 'start', ids = { ids.instance } })
  local r1 = (res.results or {})[1]
  eq(r1 and r1.ok, true, 'POST /api/instances/actions {start} is accepted',
     r1 and r1.error)

  -- The worker has to boot, announce its control endpoint, and complete the
  -- token-authenticated control handshake before the hub calls it `running`.
  local up = waitFor(function()
    local st = hub.sup:state(ids.instance)
    return st == 'running' or st == 'online'
  end, 90000)
  if not up then
    for _, l in ipairs(hub.sup:logs(ids.instance, 20)) do io.write('      ', l.text, '\n') end
  end
  eq(up, true, 'the real worker came up and the control link is established')

  local info = hub.sup:info(ids.instance)
  check(info.pid and info.pid > 0, 'it is a live child process (pid ' .. tostring(info.pid) .. ')')
  ids.pid = info.pid

  -- What the dashboard actually draws.
  local list = restOk('GET', '/api/instances')
  local row
  for _, i in ipairs(list.instances or {}) do if i.id == ids.instance then row = i end end
  check(row ~= nil, 'GET /api/instances shows the running instance')
  check(row and (row.state == 'running' or row.state == 'online'),
        '   with a live state (' .. tostring(row and row.state) .. ')')
  eq(row and row.characterName, 'E2ETester', '   and the character name')
  check(row and row.live and row.live.uptimeMs and row.live.uptimeMs > 0,
        '   and a non-zero uptime the panel can render')

  -- The worker reports its own nested shape (player{}, bot{cavebot{}}, stats{});
  -- panel/api.js declares a FLAT `live`.  Prove the translation, because a nested
  -- object arriving where the panel expects a scalar is what takes a screen down.
  -- Wait for the state the assertions below are about, not merely for the keys to
  -- exist: the worker enables its bot layer a moment after the control link comes
  -- up (it loads the minimap and the profile first), so `botEnabled ~= nil` is
  -- satisfied by the FIRST status push, which still says false.
  local live = waitFor(function()
    local l = restOk('GET', '/api/instances/' .. ids.instance).instance.live
    return l and l.hp ~= nil and l.botEnabled == true and l.suppliesStatus ~= nil
  end, 30000)
  eq(live, true, '   and a FLAT live object (hp, botEnabled, ...)')
  local L = restOk('GET', '/api/instances/' .. ids.instance).instance.live
  check(type(L.hp) == 'number' and type(L.maxHp) == 'number', '   hp / maxHp are numbers')
  check(type(L.level) == 'number', '   level is a number')
  if L.botEnabled ~= true then
    io.write('    --- dry-run worker log ---\n')
    for _, l in ipairs(hub.sup:logs(ids.instance, 80)) do
      io.write('      ', tostring(l.level), ' ', tostring(l.text), '\n')
    end
  end
  eq(L.botEnabled, true, '   the bot layer was started with the instance')
  eq(type(L.player), 'nil', "   and the worker's nested player object did not leak through")
  -- bot/supplies.lua keeps no per-item ledger, so `supplies` -- which the panel
  -- iterates as an array -- must be ABSENT rather than the module's status object.
  eq(L.supplies, nil, '   no `supplies` array, because the worker has no per-item ledger')
  check(type(L.suppliesStatus) == 'table',
        "   the module's own status travels beside it as suppliesStatus")

  -- The log ring the Console tab reads before it subscribes.
  local logs = restOk('GET', '/api/instances/' .. ids.instance .. '/logs?limit=200')
  check(#(logs.lines or {}) > 0, 'GET /api/instances/:id/logs returns the worker log')
  local sawEndpoint, sawLink = false, false
  for _, l in ipairs(logs.lines) do
    if tostring(l.text):find('control%-endpoint 127%.0%.0%.1 %d+ E2ETester') then sawEndpoint = true end
    if tostring(l.text):find('control link established', 1, true) then sawLink = true end
  end
  check(sawEndpoint, "   including the worker's own control-endpoint announcement")
  check(sawLink, '   and the supervisor confirming the link')
  local firstLine = logs.lines[1]
  check(type(firstLine) == 'table' and firstLine.t and firstLine.level and firstLine.text,
        '   shaped {id,t,level,text} as panel/api.js declares')

  -- The command line must not carry a credential -- this is the whole point of
  -- the stdin handshake, and it is worth re-proving on the real binary.
  local spawnLine
  for _, l in ipairs(logs.lines) do
    local d = tostring(l.text):match('supervisor: spawned pid %d+ %-%- (.*)$')
    if d then spawnLine = d end
  end
  check(spawnLine ~= nil, 'the spawn is logged with the command line')
  check(spawnLine and not spawnLine:find('game%-password%-e2e'),
        '   and it holds no game password')
  check(spawnLine and not spawnLine:find('proxy%-password%-e2e'), '   and no proxy password')
  check(spawnLine and spawnLine:find('%-%-control%-token%-fd=0'),
        '   and reads the control token from stdin')

  -- The config pickers, answered by the running worker.
  local cfg = restOk('GET', '/api/instances/' .. ids.instance .. '/configs')
  check(type(cfg.cavebot) == 'table' and type(cfg.targetbot) == 'table',
        'GET /api/instances/:id/configs answers from the live worker')
  check(type(cfg.profiles) == 'table', '   with a profile list')
  check(type(cfg.macros) == 'table', '   and a macro list for the Bot tab')
  note('worker reported %d cavebot, %d targetbot configs and %d macros',
       #cfg.cavebot, #cfg.targetbot, #cfg.macros)
end)

-- ==================================================== 5. the event stream ====
local sock
runSuite('stream / the panel WebSocket carries the worker', function()
  if not haveWorker then check(true, 'skipped (no worker)'); return end

  sock = wsConnect(PORT)
  waitFor(function() return sock.handshook or sock.dead end, 8000)
  eq(sock.handshook, true, 'GET /ws upgrades for a session-cookie holder')

  -- Nothing must arrive before the auth frame.
  step(300)
  eq(#sock.events, 0, 'no event is pushed before the auth frame')

  sock:send{ type = 'auth', csrf = jar['hub_csrf'] }
  local ready = waitFor(function() return sock:lastEvent('ready') ~= nil end, 8000)
  eq(ready, true, "the auth frame is answered with {event:'ready'}")
  local r = sock:lastEvent('ready')
  eq(r and r.data and r.data.user, ADMIN.name, '   naming the signed-in user')

  sock:send{ type = 'ping', t = 12345 }
  local pong = waitFor(function() return sock:lastEvent('pong') ~= nil end, 5000)
  eq(pong, true, 'a ping is answered with a pong')

  local gotStatus = waitFor(function()
    return #sock:eventsFor('status', function(d) return d and d.id == ids.instance end) >= 2
  end, 15000)
  eq(gotStatus, true, 'status frames for the instance arrive without asking')

  -- Log lines go ONLY to a socket that subscribed to that instance.
  local before = #sock:eventsFor('log')
  hub.tel:onWorkerLog(ids.instance, { id = ids.instance, t = 1, level = 'info',
                                      text = 'e2e unsubscribed line' })
  step(400)
  eq(#sock:eventsFor('log'), before, 'an unsubscribed socket receives no log line')

  sock:send{ type = 'subscribe', logs = ids.instance, chat = ids.instance }
  step(300)
  hub.tel:onWorkerLog(ids.instance, { id = ids.instance, t = 2, level = 'info',
                                      text = 'e2e subscribed line' })
  local gotLog = waitFor(function()
    for _, e in ipairs(sock:eventsFor('log')) do
      if e.data and tostring(e.data.text) == 'e2e subscribed line' then return true end
    end
    return false
  end, 6000)
  eq(gotLog, true, '   and receives them after {type:"subscribe"}')

  -- A wrong CSRF token on the auth frame is a 4401 close, which is what tells
  -- panel/rpc.js to stop retrying and show the login screen.
  local bad = wsConnect(PORT)
  waitFor(function() return bad.handshook or bad.dead end, 8000)
  bad:send{ type = 'auth', csrf = 'not-the-token' }
  local closed = waitFor(function() return bad.closeCode ~= nil end, 6000)
  eq(closed, true, 'a wrong CSRF token on the auth frame closes the socket')
  eq(bad.closeCode, 4401, '   with close code 4401')
  bad:close()

  local anon = wsConnect(PORT, { noCookie = true })
  waitFor(function() return anon.handshook or anon.dead end, 6000)
  eq(anon.handshook, false, 'a socket with no session cookie is refused the upgrade')
  eq(anon.status, 401, '   with HTTP 401')
  anon:close()
end)

-- ==================================================== 6. exec ================
runSuite('exec / Lua runs inside the real worker', function()
  if not haveWorker then check(true, 'skipped (no worker)'); return end

  local out = restOk('POST', '/api/instances/' .. ids.instance .. '/exec',
                     { code = 'return 6 * 7' })
  eq(tostring(out.output), '42', 'POST /api/instances/:id/exec returns the value')

  local ver = restOk('POST', '/api/instances/' .. ids.instance .. '/exec',
                     { code = 'return type(hppercent)' })
  eq(tostring(ver.output), 'function', "   in the bot's own vBot-compatible environment")

  local boom = rest('POST', '/api/instances/' .. ids.instance .. '/exec',
                    { code = 'this is not lua' })
  check(boom.status >= 400, 'a syntax error is an error, not a crash')
  check(hub.sup:isRunning(ids.instance), '   and the worker is still alive')

  local empty = rest('POST', '/api/instances/' .. ids.instance .. '/exec', { code = '' })
  eq(empty.status, 400, 'an empty chunk is refused')
end)

-- ==================================================== 7. script upload =======
runSuite('scripts / uploaded, assigned, and running in the worker', function()
  if not haveWorker then check(true, 'skipped (no worker)'); return end

  local SRC = 'E2E_MARKER = "loaded-by-the-hub"\n'
  local up = restOk('POST', '/api/scripts', { name = 'e2e_probe.lua', source = SRC })
  ids.script = up.script and up.script.id
  created.scripts[#created.scripts + 1] = ids.script
  check(ids.script ~= nil, 'POST /api/scripts stores the script')
  eq(up.script and up.script.name, 'e2e_probe.lua', '   under its name')
  eq(up.script and up.script.size, #SRC, '   with its size')

  local got = restOk('GET', '/api/scripts/' .. ids.script)
  eq(got.source, SRC, 'GET /api/scripts/:id returns the source verbatim')

  local assigned = restOk('PUT', '/api/scripts/' .. ids.script .. '/assignments',
                          { instanceIds = { ids.instance } })
  check(assigned.script ~= nil, 'PUT /api/scripts/:id/assignments assigns it')

  local ran = false
  for _ = 1, 20 do
    local r = rest('POST', '/api/instances/' .. ids.instance .. '/exec',
                   { code = 'return tostring(E2E_MARKER)' })
    if r and r.status == 200 and r.json and tostring(r.json.output) == 'loaded-by-the-hub' then
      ran = true
      break
    end
    step(500)
  end
  eq(ran, true, 'the assigned script really executed inside the running worker')

  local list = restOk('GET', '/api/scripts')
  local mine
  for _, s in ipairs(list.scripts or {}) do if s.id == ids.script then mine = s end end
  check(mine and #(mine.instanceIds or {}) == 1, 'GET /api/scripts shows the assignment')

  local big = rest('POST', '/api/scripts',
                   { name = 'huge.lua', source = string.rep('-', 600 * 1024) })
  eq(big.status, 413, 'a script past the size cap is 413')
  eq(big.err and big.err.code, 'too-large', '   with code too-large')

  local badName = rest('POST', '/api/scripts', { name = '../escape.lua', source = 'return 1' })
  eq(badName.status, 400, 'a traversal name is refused')
end)

-- ==================================================== 8. stop ================
runSuite('stop / the worker is stopped and reaped', function()
  if not haveWorker then check(true, 'skipped (no worker)'); return end

  local res = restOk('POST', '/api/instances/actions',
                     { action = 'stop', ids = { ids.instance } })
  local r1 = (res.results or {})[1]
  eq(r1 and r1.ok, true, 'POST /api/instances/actions {stop} is accepted', r1 and r1.error)

  local stopped = waitFor(function() return hub.sup:state(ids.instance) == 'stopped' end, 30000)
  eq(stopped, true, 'the worker stopped gracefully')
  local reaped = waitFor(function() return not process.isPidAlive(ids.pid) end, 10000)
  eq(reaped, true, '   and the process is really gone')

  local list = restOk('GET', '/api/instances')
  local row
  for _, i in ipairs(list.instances or {}) do if i.id == ids.instance then row = i end end
  eq(row and row.state, 'stopped', 'the dashboard shows it stopped')

  local again = restOk('POST', '/api/instances/actions',
                       { action = 'stop', ids = { ids.instance } })
  eq((again.results or {})[1] and again.results[1].ok, false,
     'stopping a stopped instance is a per-id failure, not a 500')

  local exec = rest('POST', '/api/instances/' .. ids.instance .. '/exec', { code = 'return 1' })
  eq(exec.status, 409, 'exec against a stopped instance is a conflict')
end)

-- ==================================================== 9. the audit log =======
runSuite('audit / every action was recorded, admin only', function()
  local users = restOk('GET', '/api/admin/users')
  local me
  for _, u in ipairs(users.users or {}) do if u.name == ADMIN.name then me = u end end
  check(me ~= nil, 'GET /api/admin/users lists the administrator')
  check(me and type(me.lastLoginAt) == 'number' and me.lastLoginAt > 0,
        '   with the LAST LOGIN the admin screen shows')
  eq(me and me.pwhash, nil, '   and never a password hash')

  local a = restOk('GET', '/api/admin/audit?limit=400')
  check(type(a.rows) == 'table' and #a.rows > 0, 'GET /api/admin/audit returns records')
  check(type(a.actors) == 'table' and type(a.actions) == 'table',
        '   with the filter vocabularies the panel draws')

  local want = { 'user.create', 'account.create', 'character.create', 'proxy.create',
                 'instance.create', 'instance.config' }
  if haveWorker then
    want[#want + 1] = 'instance.start'
    want[#want + 1] = 'instance.stop'
    want[#want + 1] = 'exec'
    want[#want + 1] = 'script.upload'
    want[#want + 1] = 'script.assign'
  end
  local byAction = {}
  for _, act in ipairs(want) do
    local page = restOk('GET', '/api/admin/audit?limit=20&action=' .. act)
    byAction[act] = page.rows or {}
    check(#byAction[act] > 0, 'the log records ' .. act)
    for _, r in ipairs(byAction[act]) do
      if r.action ~= act then
        check(false, '   and the action filter is exact', tostring(r.action))
        break
      end
    end
  end

  -- PANEL.md asks for the exec source to be in the record.
  if haveWorker then
    local sawCode = false
    for _, r in ipairs(restOk('GET', '/api/admin/audit?limit=200&action=exec').rows or {}) do
      if tostring(r.detail):find('6 * 7', 1, true) then sawCode = true end
    end
    check(sawCode, 'the exec record carries the code that was run')
  end

  -- No password of any kind, anywhere in the log.
  local f = assert(io.open(DATA .. '/audit.jsonl', 'rb'))
  local raw = f:read('*a'); f:close()
  check(not raw:find('game-password-e2e', 1, true), 'no game password reached the audit log')
  check(not raw:find('proxy-password-e2e', 1, true), 'no proxy password reached it either')
  check(not raw:find(ADMIN.password, 1, true), 'nor the web-account password')

  local filtered = restOk('GET', '/api/admin/audit?action=instance.create&limit=50')
  check(#(filtered.rows or {}) >= 1, 'the action filter narrows the log')
  for _, r in ipairs(filtered.rows) do
    eq(r.action, 'instance.create', '   and every row matches')
  end
end)

-- ==================================================== 10. roles ==============
runSuite('roles / a non-admin sees none of it', function()
  restOk('POST', '/api/admin/users',
         { name = WATCHER.name, role = 'user', password = WATCHER.password })

  restOk('DELETE', '/api/session')
  check(jar['hub_sid'] == nil, 'DELETE /api/session clears the cookie')
  local after = rest('GET', '/api/instances')
  eq(after.status, 401, '   and the session is really gone')

  local login = restOk('POST', '/api/session',
                       { name = WATCHER.name, password = WATCHER.password })
  eq(login.user and login.user.role, 'user', 'the non-admin signs in')
  check(type(login.csrfToken) == 'string', '   and gets a csrfToken')

  local list = restOk('GET', '/api/instances')
  eq(#(list.instances or {}), 0, 'they see no instances')
  eq(#(restOk('GET', '/api/accounts').accounts or {}), 0, '   and no game accounts')

  local peek = rest('GET', '/api/instances/' .. tostring(ids.instance))
  eq(peek.status, 404, "another user's instance is 404, not 403 -- no id oracle")

  for _, ep in ipairs{ { 'GET', '/api/admin/users' }, { 'GET', '/api/admin/audit' },
                       { 'GET', '/api/admin/sessions' } } do
    local r = rest(ep[1], ep[2])
    eq(r.status, 403, ep[1] .. ' ' .. ep[2] .. ' is forbidden for a user')
  end

  local start = rest('POST', '/api/instances/actions',
                     { action = 'start', ids = { tostring(ids.instance) } })
  local r1 = start.json and (start.json.results or {})[1]
  eq(r1 and r1.ok, false, "they cannot start someone else's instance")

  -- The refusal is itself audited, under the user's own name.
  restOk('DELETE', '/api/session')
  restOk('POST', '/api/session', { name = ADMIN.name, password = ADMIN.password })
  local a = restOk('GET', '/api/admin/audit?limit=400')
  local sawRefusal = false
  for _, r in ipairs(a.rows or {}) do
    if r.actor == WATCHER.name and r.outcome == 'denied' then sawRefusal = true end
  end
  check(sawRefusal, "the non-admin's refused admin route is in the log, under their name")
end)

-- ============================= 11. a REAL worker against a fake game server ==
-- PANEL.md's whole point is that the hub can run a real session.  Sections 4-8
-- proved the plumbing with `--dry-run`, which never opens a socket and never
-- calls openSession -- so they could not catch a hub-managed worker that refuses
-- to boot at all.  This one runs the production path end to end:
--
--   POST /api/instances/actions {start}
--     -> hub/api.lua decrypts the stored game password (the ONE place it does)
--     -> hub/supervisor.lua spawns luajit main.lua with NO credential in argv,
--        the control token on the child's stdin
--     -> main.lua boots, brings the control endpoint up and WAITS
--     -> the supervisor sends `login` over the authenticated loopback socket
--     -> main.lua POSTs the account and password to the login endpoint (a fake
--        one, in this process), gets a session key and a world address back
--     -> it connects to test/fakeserver.lua, a real 1530 server implementation,
--        and completes the login handshake
--     -> the panel's GET /api/instances reports state=online
--
-- Nothing leaves the machine and no game server is involved.
runSuite('real login / a hub-spawned worker reaches test/fakeserver.lua', function()
  local httpserver = require('lib.httpserver')
  local hubMain2   = require('hub.main')

  local FS_ACCOUNT   = 'fakeserver@example.invalid'   -- fakeserver checks the hwid
  local FS_CHARACTER = 'Fake Tester'
  local FS_WORLD     = 'Gunzodus'
  local FS_XTEA      = '0123456789abcdeffedcba9876543210'
  local GAME_PASSWORD = 'real-launch-game-password'

  -- ---- 1. a fake 1530 game server, in its own process ---------------------
  local probe = assert(socket.listen('127.0.0.1', 0))
  local gamePort = probe:port()
  probe:close()

  local fsLines = {}
  local fsProc, fsErr = process.spawn{
    cmd = { LUAJIT, ROOT .. '/test/fakeserver.lua',
            '--serve=' .. tostring(gamePort), '--hold-ms=9000' },
    cwd = ROOT, captureOutput = true,
    onLine = function(t) fsLines[#fsLines + 1] = t end,
  }
  if not check(fsProc ~= nil, 'test/fakeserver.lua started in --serve mode', tostring(fsErr)) then
    return
  end
  local listening = waitFor(function()
    process.pollAll()
    for _, l in ipairs(fsLines) do
      if l:find('listening on 127.0.0.1:' .. tostring(gamePort), 1, true) then return true end
    end
    return false
  end, 15000)
  check(listening, '   and is listening on 127.0.0.1:' .. tostring(gamePort))

  -- ---- 2. a fake account-login endpoint, in THIS process -------------------
  -- It answers exactly the shape proto/login_http.lua parses, and it asserts
  -- that the credential the hub decrypted really arrived.
  local loginHits, sawAccount, sawPassword = 0, false, false
  local loginSrv = httpserver.new{
    host = '127.0.0.1', port = 0, sched = sched, log = log,
    onRequest = function(req, res)
      if req.path ~= '/login' then return res:send(404, 'no such endpoint\n') end
      loginHits = loginHits + 1
      local raw = req.body or ''
      if raw:find('"email":"' .. FS_ACCOUNT .. '"', 1, true) then sawAccount = true end
      if raw:find('"password":"' .. GAME_PASSWORD .. '"', 1, true) then sawPassword = true end
      return res:json(200, {
        session = { sessionkey = 'E2E-SESSION-KEY', premiumuntil = 0 },
        playdata = {
          worlds = { { id = 0, name = FS_WORLD,
                       externaladdressprotected = '127.0.0.1',
                       externalportprotected = gamePort,
                       previewstate = 0, pvptype = 0 } },
          characters = { { name = FS_CHARACTER, worldid = 0, level = 9, vocation = 1 } },
        },
      })
    end,
  }
  local loginPort = assert(loginSrv:start())
  local LOGIN_URL = 'http://127.0.0.1:' .. tostring(loginPort) .. '/login'

  -- ---- 3. a second hub, with NO --dry-run ---------------------------------
  local DATA2 = DATA .. '-live'
  assert(storage.fs.mkdirp(DATA2))
  assert(storage.fs.mkdirp(DATA2 .. '/scripts'))
  local o2 = assert(hubMain2.parseArgs{
    '--port=0', '--bind=127.0.0.1',
    '--data-dir=' .. DATA2,
    '--panel-dir=' .. ROOT .. '/panel',
    '--workers-dir=' .. ROOT,
    '--worker-script=main.lua',
    '--luajit=' .. LUAJIT,
    '--no-autostart',
    '--login-url=' .. LOGIN_URL,
    '--game-host=127.0.0.1',
    '--game-port=' .. tostring(gamePort),
    -- the documented offline test hook: the XTEA key the fake server also uses
    '--worker-env=LUACLIENT_TEST_XTEA=' .. FS_XTEA,
  })
  local h2, be = hubMain2.build(o2)
  if not check(h2 ~= nil, 'a second hub, configured for a real login', tostring(be)) then return end
  -- a long keepalive: the fake server holds the session but answers no pings
  h2.sup.extraArgs = { '--ping=600000' }
  -- every state edge and every control event, so a failure says WHERE it stopped
  local edges, evseen = {}, {}
  local prevOnState, prevOnEvent = h2.sup.onState, h2.sup.onEvent
  h2.sup.onState = function(id, st, detail)
    edges[#edges + 1] = tostring(st)
    if prevOnState then return prevOnState(id, st, detail) end
  end
  h2.sup.onEvent = function(id, ev, data)
    evseen[ev] = (evseen[ev] or 0) + 1
    if prevOnEvent then return prevOnEvent(id, ev, data) end
  end

  local savedPort, savedJar = PORT, jar
  PORT, jar = h2.port, {}

  local ok2, err2 = pcall(function()
    -- ---- 4. bootstrap and build one instance ------------------------------
    restOk('POST', '/api/bootstrap', { token = h2.auth:bootstrapToken(),
                                       name = 'liveadmin', password = 'a-long-enough-secret' })
    local acc = restOk('POST', '/api/accounts',
      { label = 'live', login = FS_ACCOUNT, password = GAME_PASSWORD })
    local ch = restOk('POST', '/api/characters',
      { accountId = acc.account.id, name = FS_CHARACTER, world = FS_WORLD })
    local inst = restOk('POST', '/api/instances',
      { characterId = ch.character.id, autoRelogin = false })
    local iid = inst.instance.id
    eq(inst.instance.state, 'stopped', 'the instance starts out stopped')

    -- ---- 5. start it ------------------------------------------------------
    local tStart = sys.nowMs()
    local started = restOk('POST', '/api/instances/actions', { action = 'start', ids = { iid } })
    local startMs = sys.nowMs() - tStart
    -- A spawn must not hold the caller's own connection open.  On Windows
    -- CreateProcess is called with bInheritHandles = TRUE (the child needs the
    -- three std pipes), so a socket left inheritable is DUPLICATED into the
    -- worker and the browser waiting for `Connection: close` sees no EOF until
    -- the worker exits -- minutes or hours later.  lib/socket.lua clears
    -- HANDLE_FLAG_INHERIT for exactly this; the same class of bug is the fd
    -- sweep on POSIX.
    check(startMs < 5000, sformat(
      'the start call answers at once (%d ms) -- the worker inherited no panel socket', startMs))
    note('start call took %d ms', startMs)
    eq(started.results and started.results[1] and started.results[1].ok, true,
       'POST /api/instances/actions {start} is accepted')

    local samples = {}
    local online = waitFor(function()
      process.pollAll()
      local st = h2.sup:state(iid)
      if samples[#samples] ~= st then samples[#samples + 1] = st end
      return st == 'online'
    end, 60000)
    if not online then
      io.write('    --- worker log ---\n')
      for _, l in ipairs(h2.sup:logs(iid, 80)) do
        io.write('      ', tostring(l.level), ' ', tostring(l.text), '\n')
      end
      io.write('    --- fake server ---\n')
      for _, l in ipairs(fsLines) do io.write('      ', l, '\n') end
      io.write('    --- state=', tostring(h2.sup:state(iid)), ' ---\n')
      io.write('    --- state edges: ', concat(edges, ' -> '), ' ---\n')
      io.write('    --- polled states: ', concat(samples, ' -> '), ' ---\n')
      local evs = {}
      for k, v in pairs(evseen) do evs[#evs + 1] = k .. '=' .. v end
      table.sort(evs)
      io.write('    --- control events: ', concat(evs, ' '), ' ---\n')
    end
    check(online, 'the worker completed the login handshake and is ONLINE')

    -- the panel sees the same thing, through the REST surface it really uses
    local view = restOk('GET', '/api/instances/' .. iid)
    eq(view.instance.state, 'online', 'the panel own view reports state=online')
    check(loginHits >= 1, 'the worker really POSTed to the account-login endpoint')
    check(sawAccount, '   carrying the account name the hub stored')
    check(sawPassword, '   and the password the hub decrypted at spawn time')

    -- ---- 5b. the hub keeps no plaintext, and a restart can still log in ---
    -- The supervisor drops the decrypted password the moment the worker has it,
    -- so replaying the stored spec would spawn a worker that can never log in.
    -- A restart therefore goes back through launchSpec, which decrypts afresh.
    local w = h2.sup:worker(iid)
    check(w and w.spec and w.spec.account and w.spec.account.password == nil,
          'the hub dropped the decrypted password once the worker had it')
    check(type(h2.sup.specProvider) == 'function',
          'the supervisor can rebuild a launch spec for a restart')
    local fresh = h2.sup.specProvider(iid)
    check(type(fresh) == 'table' and fresh.account and
          fresh.account.password == GAME_PASSWORD,
          '   and that rebuild decrypts the credential again')
    fresh = nil

    -- ---- 6. no credential is visible from outside the process -------------
    local info = h2.sup:info(iid)
    check(info.pid and info.pid > 0, 'the supervisor knows the worker pid (' ..
          tostring(info.pid) .. ')')
    if sys.isLinux and info.pid then
      local f = io.open('/proc/' .. info.pid .. '/cmdline', 'rb')
      local cmdline = f and f:read('*a') or ''
      if f then f:close() end
      check(cmdline ~= '' and not cmdline:find(GAME_PASSWORD, 1, true),
            '/proc/<pid>/cmdline carries no game password')
      local g = io.open('/proc/' .. info.pid .. '/environ', 'rb')
      local environ = g and g:read('*a') or ''
      if g then g:close() end
      check(not environ:find(GAME_PASSWORD, 1, true),
            '/proc/<pid>/environ carries no game password either')
      -- the fd sweep, on a REAL hub-spawned worker
      local extra = {}
      local dh = io.popen('ls /proc/' .. info.pid .. '/fd 2>/dev/null')
      if dh then
        for line in dh:lines() do
          local num = tonumber(line)
          if num and num > 2 then extra[#extra + 1] = tostring(num) end
        end
        dh:close()
      end
      note('live worker descriptors beyond stdio: %s',
           #extra == 0 and 'none' or concat(extra, ','))
      -- Paste-able evidence, not just an assertion: the reviewer's own probes.
      note('live worker /proc/%d/cmdline: %s', info.pid,
           (cmdline:gsub('%z', ' '):gsub('%s+$', '')))
      local envKeys = {}
      for kv in environ:gmatch('[^%z]+') do
        local k = kv:match('^([^=]+)=')
        if k then envKeys[#envKeys + 1] = k end
      end
      table.sort(envKeys)
      note('live worker /proc/%d/environ holds %d variables: %s', info.pid, #envKeys,
           concat(envKeys, ' '))
    end

    -- ---- 7. stop it -------------------------------------------------------
    restOk('POST', '/api/instances/actions', { action = 'stop', ids = { iid } })
    local stopped = waitFor(function()
      process.pollAll()
      return h2.sup:state(iid) == 'stopped'
    end, 20000)
    check(stopped, 'the panel stops the worker again')
  end)

  PORT, jar = savedPort, savedJar

  pcall(function() h2.server:stop() end)
  pcall(function() h2.sup:shutdownAll(3000) end)
  waitFor(function() return h2.sup:allStopped() end, 15000)
  pcall(function() h2.sup:reap(3000) end)
  pcall(function() h2.tel:uninstall() end)
  pcall(function() h2.tel:flush() end)
  pcall(function() h2.storage:close() end)
  pcall(function() h2.audit:close() end)
  pcall(function() loginSrv:stop() end)
  if fsProc then
    fsProc:stop(1000)
    waitFor(function() process.pollAll(); return not fsProc:isRunning() end, 8000)
    fsProc:kill()
  end
  process.pollAll()
  if not KEEP then rmrf(DATA2) end
  if not ok2 then check(false, 'the live-launch suite raised', tostring(err2)) end
end)

-- ================================ 12. the surface an unauthenticated visitor sees
runSuite('surface / only the panel is served, and sockets are capped', function()
  -- --panel-dir also holds the development harness: devhub.lua (server-side Lua),
  -- panel/mock (a second implementation of the API) and panel/test.  All three
  -- were served to anyone who could reach the port, WITHOUT a session -- a free
  -- map of the application and a spare copy to look for mistakes in.
  local savedJar = jar
  jar = {}                                   -- unauthenticated, deliberately
  for _, path in ipairs{ '/devhub.lua', '/test/', '/test/index.html',
                         '/mock/api.js', '/MOCK/api.js' } do
    local r = rest('GET', path)
    eq(r.status, 404, path .. ' is not served')
  end
  -- ...while the panel itself still is.
  for _, path in ipairs{ '/', '/index.html', '/app.js', '/api.js', '/style.css' } do
    local r = rest('GET', path)
    eq(r.status, 200, path .. ' is still served')
  end
  jar = savedJar

  -- One account cannot hold every WebSocket.  An upgraded socket stops counting
  -- against httpserver's connection cap, so without a cap of its own /ws was
  -- effectively unlimited -- one session could hold as many sockets as the
  -- process has descriptors, each with its own outbox allowance.
  local before = hub.tel:socketCount()
  local socks = {}
  for _ = 1, 14 do
    local w = wsConnect(PORT)
    socks[#socks + 1] = w
  end
  for _, w in ipairs(socks) do
    waitFor(function() return w.handshook or w.dead end, 4000)
    if w.handshook then w:send{ type = 'auth', csrf = jar['hub_csrf'] } end
  end
  step(600)
  local held = hub.tel:socketCount()
  check(held <= 8, ('one account holds at most 8 registered sockets (held %d, started at %d)')
        :format(held, before))
  check(held > 0, '   and the newest ones are the survivors, not nothing at all')
  for _, w in ipairs(socks) do pcall(function() w:close() end) end
  step(300)
end)

-- ===================================================================== report
if sock then pcall(function() sock:close() end) end
teardown(hub)
pcall(function() process.reapAll(3000) end)
sched.reset()
if not KEEP then rmrf(DATA) end

io.write('\n=============== hube2esuite ===============\n')
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
