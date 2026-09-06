--[[============================================================================
test/fdleaksuite.lua -- a socket whose PEER closes first must still release its
descriptor.

    luajit test/fdleaksuite.lua              (from D:/Claude/otclient_web/luaclient)
    luajit test/fdleaksuite.lua --verbose

WHY THIS FILE EXISTS
--------------------
lib/socket.lua's Sock:recv() sets `state = 'closed'` when recv() returns 0 -- the
peer's orderly FIN.  That is a statement about the PROTOCOL: the connection is in
CLOSE-WAIT and the descriptor is still ours until we close it.  Sock:close() used
to guard on `self.state ~= 'closed'`, so for every socket the peer closed first
P.close() was never reached and the fd leaked permanently.

Nothing caught it.  test/httpserversuite.lua has 444 assertions and drives real
loopback sockets, but it counts REQUESTS and RESPONSES, never descriptors, and
lib/httpserver.lua's Conn:destroy() decrements stat.active whether or not the
close underneath succeeded -- so maxConnections stayed happy while the process
ran out of files.  Measured on the installed Debian hub before the fix: one
ordinary keep-alive request whose client closed first leaked exactly one fd, and
100 requests left 100 CLOSE-WAIT sockets that never went away, past the 30 s idle
sweep, until the process died at LimitNOFILE.

So this suite asserts the thing that actually matters -- the DESCRIPTOR -- rather
than the protocol bookkeeping around it.  It is deliberately a separate file: it
is about lib/socket.lua's contract, and it should stay cheap enough to run first.

Everything binds 127.0.0.1 on an ephemeral port; nothing leaves the machine.
============================================================================]]

local ROOT
do
  local src = debug.getinfo(1, 'S').source
  local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
  ROOT = (dir .. '/..'):gsub('\\', '/')
  package.path = ROOT .. '/?.lua;' .. package.path
end

local socket = require('lib.socket')
local sys    = require('lib.sys')

local VERBOSE = false
for i = 1, #arg do if arg[i] == '--verbose' then VERBOSE = true end end

local IS_WINDOWS = (package.config:sub(1, 1) == '\\')

-- =========================================================== tiny framework
local suites, cur = {}, nil
local totalPass, totalFail = 0, 0

local function suite(name)
  cur = { name = name, pass = 0, fail = 0 }
  suites[#suites + 1] = cur
end

local function check(ok, desc, detail)
  if ok then
    cur.pass, totalPass = cur.pass + 1, totalPass + 1
    if VERBOSE then io.write('    ok    ', desc, '\n') end
  else
    cur.fail, totalFail = cur.fail + 1, totalFail + 1
    io.write('    FAIL  ', desc, detail and ('  -- ' .. tostring(detail)) or '', '\n')
  end
  return ok
end

local function eq(got, want, desc)
  if got == want then return check(true, desc) end
  return check(false, desc, ('got %s, want %s'):format(tostring(got), tostring(want)))
end

local function runSuite(name, fn)
  suite(name)
  local ok, err = pcall(fn)
  if not ok then
    cur.fail, totalFail = cur.fail + 1, totalFail + 1
    io.write('    FAIL  suite crashed: ', tostring(err), '\n')
  end
end

-- ================================================== how we count descriptors
--
-- /proc/<pid>/fd, and the pid has to be OUR pid, taken from getpid().  Writing
-- `/proc/self/fd` inside an io.popen would count the descriptors of the SHELL
-- the popen forked, which is a constant four and would make this whole suite
-- pass against the very bug it exists to catch -- that mistake was made once
-- here already.  Windows has no equivalent, so the counting checks are skipped
-- there and only the contract check above runs.
local PID
if not IS_WINDOWS then
  local ok, ffi = pcall(require, 'ffi')
  if ok then
    pcall(ffi.cdef, 'int getpid(void);')
    local got, v = pcall(function() return tonumber(ffi.C.getpid()) end)
    if got then PID = v end
  end
end

local function fdCount()
  if not PID then return nil end
  local d = io.popen('ls /proc/' .. PID .. '/fd 2>/dev/null | wc -l')
  if not d then return nil end
  local n = tonumber((d:read('*a') or ''):match('%d+'))
  d:close()
  -- the popen pipe itself is open while we read, so take it back off
  return n and (n - 1) or nil
end

-- Drive both ends of a loopback pair until `fn` says it is done, or we run out
-- of turns.  Everything in lib/socket.lua is non-blocking, so a turn is a poll.
local function pump(turns, fn)
  for _ = 1, (turns or 400) do
    if fn and fn() then return true end
    sys.sleepMs(1)
  end
  return fn and fn() or false
end

--- Make one connected loopback pair: returns listener, serverSide, clientSide.
local function pair()
  local ls, e = socket.listen('127.0.0.1', 0, 8)
  assert(ls, tostring(e))
  local _, port = ls:localAddr()
  local cs = assert(socket.tcp())
  cs:connect('127.0.0.1', port)
  local ss
  pump(400, function()
    if not ss then ss = ls:accept() end
    if cs.state == 'connecting' then cs:_settleConnect() end
    return ss ~= nil and cs.state == 'connected'
  end)
  assert(ss, 'accept() never produced the server side')
  return ls, ss, cs
end

-- ============================================ 1. the contract, on one socket
runSuite('a peer-closed socket still owns its descriptor', function()
  local ls, ss, cs = pair()

  eq(ss.state, 'connected', 'the accepted socket starts connected')
  eq(ss.fdOpen, true, 'and its descriptor is open')

  -- the CLIENT goes away first: this is what a browser, curl or any HTTP
  -- keep-alive client does at the end of a page load
  cs:close()
  eq(cs.fdOpen, false, 'closing our own side releases the descriptor')

  -- the server side now reads EOF
  local got, why
  pump(400, function()
    got, why = ss:recv(4096)
    return got == nil
  end)
  eq(got, nil, 'the server side reads EOF after the peer closed')
  eq(why, 'closed', 'and reports it as an orderly close')
  eq(ss.state, 'closed', "recv() marks the PROTOCOL state 'closed'")

  -- ...and this is the whole point: the descriptor is still ours.
  eq(ss.fdOpen, true, 'but the DESCRIPTOR is still open -- the socket is in CLOSE-WAIT')

  ss:close()
  eq(ss.fdOpen, false, 'close() after a peer-initiated EOF really closes the fd')

  -- idempotent, and does not double-close a descriptor number the OS may have
  -- already handed to somebody else
  ss:close()
  eq(ss.fdOpen, false, 'close() is idempotent')

  ls:close()
  eq(ls.fdOpen, false, 'the listener closes too')
end)

-- ==================================== 2. the measurement that found the bug
runSuite('200 peer-closed connections leak no descriptors', function()
  local base = fdCount()
  if not base then
    check(true, 'skipped on this platform: no /proc/self/fd (Windows)')
    return
  end

  local ls, e = socket.listen('127.0.0.1', 0, 64)
  assert(ls, tostring(e))
  local _, port = ls:localAddr()
  local afterListen = fdCount()

  local ROUNDS = 200
  for _ = 1, ROUNDS do
    local cs = assert(socket.tcp())
    cs:connect('127.0.0.1', port)
    local ss
    pump(200, function()
      if not ss then ss = ls:accept() end
      if cs.state == 'connecting' then cs:_settleConnect() end
      return ss ~= nil and cs.state == 'connected'
    end)
    assert(ss, 'accept() failed mid-run')
    -- the PEER closes first, then we notice and close: exactly the sequence
    -- that used to leak
    cs:close()
    pump(200, function() return (select(1, ss:recv(4096))) == nil end)
    ss:close()
  end

  local final = fdCount()
  if VERBOSE then
    io.write(('    fds: %d before, %d with the listener, %d after %d rounds\n')
             :format(base, afterListen, final, ROUNDS))
  end
  -- The listener is still open, so allow for it plus a little slack for the
  -- io.popen pipes the counter itself uses.
  check(final <= afterListen + 2,
        ('%d peer-closed connections leak no descriptors'):format(ROUNDS),
        ('%d fds with just the listener, %d after'):format(afterListen, final))

  ls:close()
  local closed = fdCount()
  check(closed <= base + 2, 'and the listener gives its own back',
        ('%d before everything, %d after'):format(base, closed))
end)

-- =============================== 3. the same thing through lib/httpserver.lua
runSuite('the HTTP server gives a descriptor back per request', function()
  local base = fdCount()
  if not base then
    check(true, 'skipped on this platform: no /proc/self/fd (Windows)')
    return
  end

  local httpserver = require('lib.httpserver')
  local sched      = require('lib.sched')

  local srv, e = httpserver.new{
    host = '127.0.0.1', port = 0, sched = sched,
    allowedHosts = { '127.0.0.1' },
    onRequest = function(req, res) res:send(200, 'ok\n') end,
  }
  assert(srv, tostring(e))
  local port, se = srv:start()
  assert(port, tostring(se))
  local afterStart = fdCount()

  local N = 50
  for _ = 1, N do
    local cs = assert(socket.tcp())
    cs:connect('127.0.0.1', port)
    local sent, done = false, false
    for _ = 1, 600 do
      sched.tick()
      if cs.state == 'connecting' then cs:_settleConnect() end
      if cs.state == 'connected' and not sent then
        cs:send('GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n')
        sent = true
      end
      if sent then
        local d = cs:recv(4096)
        if d and d:find('200', 1, true) then done = true; break end
      end
      sys.sleepMs(1)
    end
    -- the CLIENT hangs up, keep-alive and all -- the browser's behaviour
    cs:close()
    for _ = 1, 60 do sched.tick(); sys.sleepMs(1) end
    if not done then error('no response on round') end
  end

  local final = fdCount()
  if VERBOSE then
    io.write(('    fds: %d before, %d with the server up, %d after %d requests\n')
             :format(base, afterStart, final, N))
  end
  check(final <= afterStart + 2,
        ('%d keep-alive requests whose client closed first leak no descriptors'):format(N),
        ('%d with the server up, %d after'):format(afterStart, final))
  check(srv.stat.closed >= N, 'and the server accounted for every connection',
        ('accepted %d, closed %d'):format(srv.stat.accepted, srv.stat.closed))

  srv:stop()
  for _ = 1, 60 do sched.tick(); sys.sleepMs(1) end
  local stopped = fdCount()
  check(stopped <= base + 2, 'stopping the server gives the listener back',
        ('%d before, %d after stop'):format(base, stopped))
end)

-- ===================================================================== report
io.write('\n================ fdleaksuite ================\n')
local width = 0
for _, s in ipairs(suites) do if #s.name > width then width = #s.name end end
for _, s in ipairs(suites) do
  io.write(('  %-' .. width .. 's  %s  %d passed'):format(
    s.name, s.fail == 0 and 'PASS' or 'FAIL', s.pass))
  if s.fail > 0 then io.write((', %d FAILED'):format(s.fail)) end
  io.write('\n')
end
io.write(('  %s\n'):format(string.rep('-', width + 20)))
io.write(('  TOTAL: %d passed, %d failed  -> %s\n'):format(
  totalPass, totalFail, totalFail == 0 and 'PASS' or 'FAIL'))

pcall(function() socket.cleanup() end)
os.exit(totalFail == 0 and 0 or 1)
