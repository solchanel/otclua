--[[============================================================================
test/probe_roles.lua -- the reviewer's own probe, kept runnable.

    luajit test/probe_roles.lua

Starts a throwaway hub on a loopback ephemeral port, bootstraps an administrator,
creates a plain `user` account, and then drives EVERY administrator-only REST
route -- plus the two remote-Lua routes -- as that plain user, printing the real
status line for each.  It is a report, not a test: it prints what the hub answers
so the answers can be read rather than trusted.  test/hubapisuite.lua asserts the
same boundaries; this exists so a human can re-run the probe in one command.

Exits 0 when every probed route was refused, 1 otherwise.
============================================================================]]

local ROOT
do
  local src = debug.getinfo(1, 'S').source
  local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
  ROOT = (dir .. '/..'):gsub('\\', '/')
  package.path = ROOT .. '/?.lua;' .. package.path
end

local socket  = require('lib.socket')
local sched   = require('lib.sched')
local sys     = require('lib.sys')
local json    = require('lib.json')
local log     = require('lib.log')
local storage = require('hub.storage')
local hubMain = require('hub.main')

log.setLevel('error')
local sformat, concat = string.format, table.concat

local DATA = sformat('%s/luaclient-probe-%08x',
                     (sys.tempDir():gsub('\\', '/')), sys.randomU32())
assert(storage.fs.mkdirp(DATA))
assert(storage.fs.mkdirp(DATA .. '/scripts'))

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

-- ---------------------------------------------------------------- HTTP client
local jar = {}
local PORT

local function request(method, path, body)
  local s = assert(socket.tcp())
  assert(s:connect('127.0.0.1', PORT))
  local rx, done = '', false
  sched.onSocket(s, function()
    while true do
      local d = s:recv(65536)
      if d == nil then done = true; return end
      if d == '' then return end
      rx = rx .. d
    end
  end)
  -- Every non-GET carries a JSON body, even an empty one: without a
  -- Content-Type the CSRF gate answers 415 and the AUTHORISATION path -- which
  -- is what this probe is about -- is never reached.
  if method ~= 'GET' and method ~= 'HEAD' and body == nil then body = {} end
  local payload = body and json.encode(body) or nil
  local lines = { sformat('%s %s HTTP/1.1', method, path),
                  'Host: 127.0.0.1:' .. PORT, 'Connection: close' }
  if payload then
    lines[#lines + 1] = 'Content-Type: application/json'
    lines[#lines + 1] = 'Content-Length: ' .. #payload
    if jar.hub_csrf then lines[#lines + 1] = 'X-CSRF-Token: ' .. jar.hub_csrf end
  end
  local ck = {}
  for k, v in pairs(jar) do ck[#ck + 1] = k .. '=' .. v end
  if #ck > 0 then lines[#lines + 1] = 'Cookie: ' .. concat(ck, '; ') end
  s:send(concat(lines, '\r\n') .. '\r\n\r\n' .. (payload or ''))
  waitFor(function() return done end, 20000)
  sched.removeSocket(s)
  pcall(function() s:close() end)

  local i = rx:find('\r\n\r\n', 1, true)
  if not i then return { status = 0, body = '' } end
  local head, rest = rx:sub(1, i - 1), rx:sub(i + 4)
  for ln in head:gmatch('[^\r\n]+') do
    local k, v = ln:match('^([Ss]et%-[Cc]ookie):%s*(.-)%s*$')
    if k then
      local ck2, cv = v:match('^([^=;]+)=([^;]*)')
      if ck2 then if cv == '' then jar[ck2] = nil else jar[ck2] = cv end end
    end
  end
  local ok, doc = pcall(json.decode, rest)
  return { status = tonumber(head:match('^HTTP/1%.%d (%d+)')), body = rest,
           json = ok and doc or nil }
end

-- ------------------------------------------------------------------ the hub
local o = assert(hubMain.parseArgs{
  '--port=0', '--bind=127.0.0.1', '--data-dir=' .. DATA,
  '--panel-dir=' .. ROOT .. '/panel', '--workers-dir=' .. ROOT,
  '--worker-script=main.lua', '--no-autostart' })
local hub = assert(hubMain.build(o))
PORT = hub.port
io.write(sformat('probe: hub on 127.0.0.1:%d, data dir %s\n\n', PORT, DATA))

assert(request('POST', '/api/bootstrap',
  { token = hub.auth:bootstrapToken(), name = 'probeadmin',
    password = 'a-long-enough-secret' }).status == 200, 'bootstrap failed')
assert(request('POST', '/api/admin/users',
  { name = 'probeuser', role = 'user', password = 'another-long-secret' }).status == 200,
  'user create failed')
-- one instance owned by the ADMINISTRATOR, for the plain user to reach at
local acc = request('POST', '/api/accounts',
  { label = 'admin-acct', login = 'admin@example.invalid', password = 'admin-game-password' })
local ch = request('POST', '/api/characters',
  { accountId = acc.json.account.id, name = 'AdminChar', world = 'Gunzodus' })
local inst = request('POST', '/api/instances', { characterId = ch.json.character.id })
local adminInstance = inst.json.instance.id
local px = request('POST', '/api/proxies',
  { label = 'admin-proxy', host = 'exit.example.com', port = 8080, pass = 'admin-proxy-pass' })
local adminProxy = px.json.proxy.id

request('DELETE', '/api/session')
jar = {}
assert(request('POST', '/api/session',
  { name = 'probeuser', password = 'another-long-secret' }).status == 200, 'user login failed')

-- ------------------------------------------------------------------ the probe
local PROBES = {
  { 'GET',    '/api/admin/users' },
  { 'POST',   '/api/admin/users',       { name = 'x1', role = 'admin', password = '0123456789' } },
  { 'PATCH',  '/api/admin/users/u_x',   { role = 'admin' } },
  { 'DELETE', '/api/admin/users/u_x' },
  { 'POST',   '/api/admin/users/u_x/password', { password = '0123456789' } },
  { 'GET',    '/api/admin/sessions' },
  { 'DELETE', '/api/admin/sessions/sess_x' },
  { 'GET',    '/api/admin/audit' },
  { 'POST',   '/api/instances/' .. adminInstance .. '/exec', { code = 'return 1' } },
  { 'POST',   '/api/scripts',           { name = 'probe.lua', source = 'return 1' } },
  { 'GET',    '/api/instances/' .. adminInstance },
  { 'DELETE', '/api/instances/' .. adminInstance },
  { 'PATCH',  '/api/proxies/' .. adminProxy, { host = 'attacker.example' } },
  { 'DELETE', '/api/proxies/' .. adminProxy },
  { 'GET',    '/devhub.lua' },
  { 'GET',    '/test/' },
  { 'GET',    '/mock/api.js' },
}

local bad = 0
for _, p in ipairs(PROBES) do
  local r = request(p[1], p[2], p[3])
  local code = r.json and r.json.error and r.json.error.code or ''
  local msg  = r.json and r.json.error and r.json.error.message or ''
  local refused = (r.status == 403 or r.status == 404 or r.status == 401)
  if not refused then bad = bad + 1 end
  io.write(sformat('  %-6s %-46s -> %s %s %s%s\n', p[1], p[2], tostring(r.status),
                   refused and 'REFUSED' or '*** ALLOWED ***',
                   code ~= '' and (code .. ' ') or '', msg))
end

-- and the two things the plain user IS allowed
io.write('\n  the same account, on its own resources:\n')
for _, p in ipairs{ { 'GET', '/api/instances' }, { 'GET', '/api/accounts' },
                    { 'GET', '/api/proxies' }, { 'GET', '/api/session' } } do
  local r = request(p[1], p[2])
  io.write(sformat('  %-6s %-46s -> %s\n', p[1], p[2], tostring(r.status)))
end

pcall(function() hub.server:stop() end)
pcall(function() hub.sup:shutdownAll(2000) end)
pcall(function() hub.tel:uninstall() end)
pcall(function() hub.storage:close() end)
pcall(function() hub.audit:close() end)
step(50)

io.write(sformat('\nprobe: %d of %d probed routes were ALLOWED -> %s\n',
                 bad, #PROBES, bad == 0 and 'PASS' or 'FAIL'))
io.write('probe: data dir left at ', DATA, ' (grep it for plaintext credentials)\n')
os.exit(bad == 0 and 0 or 1)
