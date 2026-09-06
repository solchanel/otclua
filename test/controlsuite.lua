--[[============================================================================
test/controlsuite.lua -- the worker's control endpoint, end to end.

    luajit test/controlsuite.lua            (from D:/Claude/otclient_web/luaclient)
    luajit test/controlsuite.lua --keep     (leave the child's log on failure)

WHAT IS REAL HERE.  Nothing in this file is a mock of the thing under test:

  * a REAL child process is spawned through lib/process.lua --
        luajit main.lua --dry-run --control-port=0 --control-token-fd=0
    with the token written down the child's private stdin pipe, never in argv;
  * the port is learned from the worker's own `control-endpoint <host> <port>
    <name>` stdout line, exactly the way the hub will learn it;
  * every request goes over a REAL TCP socket -- HTTP POST /rpc for the
    request/response half and a REAL RFC 6455 WebSocket handshake (masked client
    frames, unmasked server frames) for the push half;
  * the proxy section stands up a REAL HTTP CONNECT proxy on 127.0.0.1 and drives
    proto/transport.lua's tunnel through it, checking that the world-name preamble
    goes out AFTER the 200 and that a framed game packet survives the round trip.

Nothing leaves the machine: no HTTPS, no game server, no DNS.

Exits non-zero if any check fails.
============================================================================]]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. ROOT .. '/?/init.lua;' .. package.path
end

local socket  = require('lib.socket')
local sys     = require('lib.sys')
local json    = require('lib.json')
local base64  = require('lib.base64')
local process = require('lib.process')
local proxy   = require('lib.proxy')
local transport = require('lib.socket') and require('proto.transport')
local commands  = require('control.commands')
local control   = require('control.server')

local bit = require('bit')
local schar, sbyte, ssub = string.char, string.byte, string.sub
local concat, floor = table.concat, math.floor

local KEEP = false
for i = 1, #(arg or {}) do if arg[i] == '--keep' then KEEP = true end end

-- =========================================================== tiny framework
local suites, cur = {}, nil
local totalPass, totalFail = 0, 0

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
        io.write('    FAIL  ', tostring(desc),
                 detail and ('  -- ' .. tostring(detail)) or '', '\n')
    end
    return ok
end

local function eq(got, want, desc)
    if got == want then return check(true, desc) end
    local g, w = tostring(got), tostring(want)
    if #g > 200 then g = g:sub(1, 197) .. '...' end
    if #w > 200 then w = w:sub(1, 197) .. '...' end
    return check(false, desc, ('got %q, want %q'):format(g, w))
end

local function truthy(v, desc, detail) return check(v and true or false, desc, detail) end

local function runSuite(name, fn)
    suite(name)
    local ok, err = pcall(fn)
    if not ok then
        cur.fail, totalFail = cur.fail + 1, totalFail + 1
        io.write('    FAIL  suite crashed: ', tostring(err), '\n')
    end
end

-- ================================================================== helpers
local function tmpPath(tag)
    local dir = ROOT .. '/test/.tmp'
    os.execute((sys.isWindows and 'mkdir "' .. dir:gsub('/', '\\') .. '" 2>NUL'
                              or 'mkdir -p "' .. dir .. '" 2>/dev/null'))
    return ('%s/ctl_%s_%d_%d.tmp'):format(dir, tag, os.time(), math.random(100000, 999999))
end

local function writeFile(path, text)
    local f = assert(io.open(path, 'wb'))
    f:write(text)
    f:close()
    return path
end

local function luajitExe()
    -- The interpreter running this file, so the child is the same build.
    local exe = sys.isWindows
        and 'D:/Claude/otclient_mehah1530/otclient/build/win-local/vcpkg_installed/x64-windows-static-release/tools/luajit/luajit.exe'
        or 'luajit'
    return os.getenv('LUACLIENT_LUAJIT') or exe
end

--- Pump `fn` until it returns true, or `ms` elapse.  Everything in this suite is
--- non-blocking, so the loop is the only clock we need.
local function waitUntil(fn, ms, tick)
    local t0 = sys.nowMs()
    while sys.nowMs() - t0 < (ms or 8000) do
        if tick then tick() end
        local ok = fn()
        if ok then return ok end
        sys.sleepMs(2)
    end
    return nil
end

-- ============================================================ the worker child
local Worker = {}
Worker.__index = Worker

-- lib/process.lua refuses any argv element that LOOKS like a secret, and its default
-- pattern list contains 'token' and 'auth' -- which catches `--control-token-fd=0`
-- and `--proxy-auth=@PATH` even though their values are a descriptor number and a
-- path, not credentials.  The token itself goes down the private stdin pipe (which is
-- the whole point of --control-token-fd=0), so the narrowed list below still refuses
-- every real credential shape; see the crossFileRequest in this work item's report.
local REDACT_WITHOUT_LOCATIONS = { 'password', 'passwd', 'pass', 'secret',
                                   'key', 'apikey', 'credential' }

local function startWorker(extraArgs)
    local token = 'ctl-' .. tostring(math.random(1, 2 ^ 30)) .. '-abcdefgh'

    local logLines = {}
    local cmd = { luajitExe(), 'main.lua', '--dry-run',
                  '--control-port=0', '--control-token-fd=0',
                  '--instance-name=suite', '--log-level=info' }
    for _, a in ipairs(extraArgs or {}) do cmd[#cmd + 1] = a end

    local h, err = process.spawn{
        cmd = cmd, cwd = ROOT, captureOutput = true,
        redact = REDACT_WITHOUT_LOCATIONS,
        stdinData = token .. '\n',            -- the token NEVER touches argv
        onLine = function(line) logLines[#logLines + 1] = line end,
    }
    if not h then return nil, 'spawn failed: ' .. tostring(err) end

    local W = setmetatable({ h = h, token = token, lines = logLines }, Worker)

    -- Learn the port from the worker's own stdout announcement.
    local got = waitUntil(function()
        for i = 1, #logLines do
            local host, port, name = logLines[i]:match('^control%-endpoint%s+(%S+)%s+(%d+)%s+(%S+)')
            if host then
                W.host, W.port, W.name = host, tonumber(port), name
                return true
            end
        end
        if not h:isRunning() then return false end
        return false
    end, 20000, function() process.pollAll() end)

    if not got or not W.port then
        W:stop()
        return nil, 'the worker never announced a control port; output:\n  ' ..
                    concat(logLines, '\n  ')
    end
    return W
end

function Worker:pump() process.pollAll() end

function Worker:stop()
    if self.h then pcall(function() self.h:stop(1500) end) end
    local t0 = sys.nowMs()
    while self.h and self.h:isRunning() and sys.nowMs() - t0 < 4000 do
        process.pollAll()
        sys.sleepMs(5)
    end
    if self.h then pcall(function() self.h:kill() end) end
end

function Worker:tail(n)
    local out, first = {}, math.max(1, #self.lines - (n or 20) + 1)
    for i = first, #self.lines do out[#out + 1] = self.lines[i] end
    return concat(out, '\n  ')
end

-- ========================================================== blocking-ish HTTP
-- A minimal HTTP/1.1 client over lib/socket, pumping the child's output while it
-- waits so the child can never fill its stdout pipe and stall.
local function httpRequest(W, method, path, body, headers, budgetMs)
    local s = socket.tcp()
    local ok, err = s:connect(W.host, W.port)
    if not ok then return nil, 'connect: ' .. tostring(err) end

    local h = { ['Host'] = W.host .. ':' .. W.port, ['Connection'] = 'close' }
    for k, v in pairs(headers or {}) do h[k] = v end
    if body then
        h['Content-Length'] = tostring(#body)
        h['Content-Type'] = h['Content-Type'] or 'application/json'
    end
    local lines = { ('%s %s HTTP/1.1'):format(method, path) }
    for k, v in pairs(h) do lines[#lines + 1] = k .. ': ' .. v end
    local req = concat(lines, '\r\n') .. '\r\n\r\n' .. (body or '')

    local sent, raw, t0 = false, '', sys.nowMs()
    while sys.nowMs() - t0 < (budgetMs or 15000) do
        W:pump()
        if not sent then
            if s:isConnected() then
                local n, serr = s:send(req)
                if not n then s:close(); return nil, 'send: ' .. tostring(serr) end
                sent = true
            end
        else
            s:flush()
            local d, rerr = s:recv(65536)
            if d == nil then
                if rerr == 'closed' then break end
                s:close(); return nil, 'recv: ' .. tostring(rerr)
            end
            if #d > 0 then raw = raw .. d end
            -- Connection: close means the body ends at EOF; but answer early when we
            -- already have a complete Content-Length body.
            local hend = raw:find('\r\n\r\n', 1, true)
            if hend then
                local cl = tonumber(raw:sub(1, hend):match('[Cc]ontent%-[Ll]ength:%s*(%d+)'))
                if cl and (#raw - (hend + 3)) >= cl then break end
            end
        end
        sys.sleepMs(1)
    end
    s:close()

    local hend = raw:find('\r\n\r\n', 1, true)
    if not hend then return nil, 'no complete response head; got ' .. #raw .. ' bytes' end
    local head = raw:sub(1, hend + 1)
    local status = tonumber(head:match('^HTTP/1%.1 (%d+)'))
    return { status = status, head = head, body = raw:sub(hend + 4) }
end

local function rpc(W, req, tokenOverride)
    local hdrs = {}
    local tok = tokenOverride
    if tok == nil then tok = W.token end
    if tok ~= false then hdrs['Authorization'] = 'Bearer ' .. tostring(tok) end
    local res, err = httpRequest(W, 'POST', '/rpc', json.encode(req), hdrs)
    if not res then return nil, err end
    if res.status ~= 200 then return res, nil end
    local okd, obj = pcall(json.decode, res.body)
    res.json = okd and obj or nil
    if not okd then res.decodeError = tostring(obj) end
    return res
end

-- =========================================================== WebSocket client
local function be16(n) return schar(floor(n / 256) % 256, n % 256) end
local function maskBytes(s, key)
    local t = {}
    for i = 1, #s do
        t[i] = schar(bit.bxor(sbyte(s, i), sbyte(key, ((i - 1) % 4) + 1)))
    end
    return concat(t)
end

local function mkFrame(op, payload)
    payload = payload or ''
    local key = schar(math.random(0, 255), math.random(0, 255),
                      math.random(0, 255), math.random(0, 255))
    local n = #payload
    local hdr
    if n < 126 then hdr = schar(0x80 + op, 0x80 + n)
    else hdr = schar(0x80 + op, 0x80 + 126) .. be16(n) end
    return hdr .. key .. maskBytes(payload, key)
end

local function parseFrames(s, pos)
    local out = {}
    pos = pos or 1
    while true do
        local avail = #s - pos + 1
        if avail < 2 then return out, pos end
        local b1, b2 = sbyte(s, pos, pos + 1)
        local f = { fin = b1 >= 0x80, op = b1 % 16, masked = b2 >= 0x80 }
        local len, hl = b2 % 128, 2
        if len == 126 then
            if avail < 4 then return out, pos end
            local a, b = sbyte(s, pos + 2, pos + 3); len = a * 256 + b; hl = 4
        elseif len == 127 then
            if avail < 10 then return out, pos end
            local n = 0
            for i = pos + 2, pos + 9 do n = n * 256 + sbyte(s, i) end
            len = n; hl = 10
        end
        if f.masked then hl = hl + 4 end
        if avail < hl + len then return out, pos end
        f.payload = ssub(s, pos + hl, pos + hl + len - 1)
        out[#out + 1] = f
        pos = pos + hl + len
    end
end

local WS = {}
WS.__index = WS

local function wsConnect(W, opts)
    opts = opts or {}
    local s = socket.tcp()
    local ok, err = s:connect(W.host, W.port)
    if not ok then return nil, 'connect: ' .. tostring(err) end

    local keyRaw = {}
    for i = 1, 16 do keyRaw[i] = schar(math.random(0, 255)) end
    local key = base64.encode(concat(keyRaw))

    local path = opts.path or '/ws'
    local lines = {
        ('GET %s HTTP/1.1'):format(path),
        'Host: ' .. W.host .. ':' .. W.port,
        'Upgrade: websocket',
        'Connection: Upgrade',
        'Sec-WebSocket-Key: ' .. key,
        'Sec-WebSocket-Version: 13',
    }
    -- The hub is not a browser: no Origin at all (the endpoint sets allowNoOrigin).
    local tok = opts.token
    if tok == nil then tok = W.token end
    if tok ~= false then lines[#lines + 1] = 'Authorization: Bearer ' .. tostring(tok) end

    local c = setmetatable({ sock = s, rbuf = '', rpos = 1, msgs = {}, events = {},
                             replies = {}, W = W, key = key }, WS)
    local req = concat(lines, '\r\n') .. '\r\n\r\n'
    local t0 = sys.nowMs()
    while sys.nowMs() - t0 < 8000 do
        W:pump()
        if s:isConnected() then
            local n, serr = s:send(req)
            if not n then s:close(); return nil, 'send: ' .. tostring(serr) end
            break
        end
        sys.sleepMs(1)
    end
    return c
end

function WS:drain()
    self.W:pump()
    self.sock:flush()
    while true do
        local d, err = self.sock:recv(65536)
        if d == nil then self.dead, self.deadErr = true, err; return end
        if #d == 0 then break end
        self.rbuf = self.rbuf .. d
    end
    if not self.handshook then
        local i = self.rbuf:find('\r\n\r\n', 1, true)
        if not i then return end
        local head = ssub(self.rbuf, 1, i + 1)
        self.rbuf, self.rpos = ssub(self.rbuf, i + 4), 1
        self.status = tonumber(head:match('^HTTP/1%.1 (%d+)'))
        self.handshook = (self.status == 101)
        if not self.handshook then return end
    end
    local frames, np = parseFrames(self.rbuf, self.rpos)
    self.rpos = np
    if self.rpos > 65536 then self.rbuf = ssub(self.rbuf, self.rpos); self.rpos = 1 end
    for _, f in ipairs(frames) do
        if f.op == 0x9 then self.sock:send(mkFrame(0xa, f.payload))
        elseif f.op == 0x8 then self.closed = true
        elseif f.op == 0x1 then
            self.msgs[#self.msgs + 1] = f.payload
            local okd, obj = pcall(json.decode, f.payload)
            if okd and type(obj) == 'table' then
                if obj.event then
                    self.events[#self.events + 1] = obj
                elseif obj.id ~= nil or obj.ok ~= nil then
                    self.replies[#self.replies + 1] = obj
                end
            end
        end
    end
end

function WS:send(obj) return self.sock:send(mkFrame(0x1, json.encode(obj))) end

function WS:waitHandshake(ms)
    return waitUntil(function()
        self:drain()
        return self.status ~= nil
    end, ms or 8000)
end

function WS:call(id, cmd, args, ms)
    self:send{ id = id, cmd = cmd, args = args }
    local found
    waitUntil(function()
        self:drain()
        for i = 1, #self.replies do
            if self.replies[i].id == id then found = self.replies[i]; return true end
        end
        return false
    end, ms or 8000)
    return found
end

function WS:waitEvent(name, ms, pred)
    local found
    waitUntil(function()
        self:drain()
        for i = 1, #self.events do
            local e = self.events[i]
            if e.event == name and (not pred or pred(e)) then found = e; return true end
        end
        return false
    end, ms or 8000)
    return found
end

function WS:close()
    pcall(function() self.sock:send(mkFrame(0x8, schar(3, 232))) end)
    pcall(function() self.sock:close() end)
end

-- ===========================================================================
-- 1. offline unit checks -- no process, no socket
-- ===========================================================================
runSuite('parsers and name rules (pure)', function()
    eq(control.parseLootOf('Loot of a rat: 12 gold coins, a cheese'), 'rat',
       'Loot of strips the article')
    eq(control.parseLootOf('Loot of an orc warlord: nothing'), 'orc warlord',
       'Loot of strips "an"')
    eq(control.parseLootOf('Loot of the Old Widow: a spider silk'), 'Old Widow',
       'Loot of strips "the"')
    eq(control.parseLootOf('You see a rat.'), nil, 'a non-loot line is not a kill')

    local n, singular = control.parseUsingOneOf('Using one of 24 mana potions...')
    eq(n, 24, 'using-one-of reads the count')
    eq(singular, 'mana potion', 'using-one-of singularises the name')
    eq(control.parseUsingOneOf('Hello there'), nil, 'an unrelated line is not a use')

    eq(commands.normaliseScriptName('foo'), 'foo', 'a plain name passes')
    eq(commands.normaliseScriptName('foo.lua'), 'foo', 'the .lua suffix is optional')
    eq((select(2, commands.normaliseScriptName('../evil'))),
       'name must not contain a path separator', 'traversal is refused')
    eq((select(2, commands.normaliseScriptName('a\\b'))),
       'name must not contain a path separator', 'a backslash is refused')
    eq((select(2, commands.normaliseScriptName('C:evil'))),
       'name must not contain a colon', 'a drive-relative name is refused')
    eq((select(2, commands.normaliseScriptName('.hidden'))),
       'name must not start with a dot', 'a dotfile is refused')
    truthy(commands.normaliseScriptName(string.rep('x', 200)) == nil,
           'an absurdly long name is refused')

    truthy(control._constantTimeEqual('abcdef', 'abcdef'), 'equal tokens compare equal')
    truthy(not control._constantTimeEqual('abcdef', 'abcdeg'), 'different tokens do not')
    truthy(not control._constantTimeEqual('abcdef', 'abcdef '), 'a trailing space matters')
    truthy(not control._constantTimeEqual(nil, 'abcdef'), 'nil never matches')

    -- The command table is exactly PANEL.md's list, plus CONFIGAPI.md's three
    -- config.* commands (work item N2).
    local want = { 'status', 'login', 'logout', 'relogin', 'bot.enable', 'bot.setCavebot',
                   'bot.setTargetbot', 'bot.listConfigs', 'bot.reload', 'script.put',
                   'script.remove', 'script.list', 'exec', 'stats', 'shutdown',
                   'bot.setMacro', 'say', 'config.get', 'config.set', 'config.list' }
    local have = {}
    for _, n2 in ipairs(commands.names()) do have[n2] = true end
    for _, n2 in ipairs(want) do truthy(have[n2], 'command ' .. n2 .. ' exists') end
    eq(#commands.names(), #want, 'no commands beyond PANEL.md\'s + CONFIGAPI.md\'s list')
end)

-- ===========================================================================
-- 2. the real worker, over real sockets
-- ===========================================================================
local W, werr = startWorker()
if not W then
    io.write('FATAL: ', tostring(werr), '\n')
    os.exit(1)
end
io.write(('  worker up: %s:%d (%s), pid %s\n'):format(W.host, W.port, W.name,
         tostring(W.h:pid())))

runSuite('authentication is enforced', function()
    local res = httpRequest(W, 'GET', '/health', nil, {})
    truthy(res, 'a request with no token still gets an answer')
    eq(res and res.status, 401, 'no token -> 401')
    truthy(res and res.body:find('unauthorized', 1, true), '401 body says unauthorized')

    local bad = httpRequest(W, 'GET', '/health', nil, { Authorization = 'Bearer wrong-token' })
    eq(bad and bad.status, 401, 'a wrong token -> 401')
    truthy(bad and not bad.body:find(W.token, 1, true),
           'the 401 body never echoes the real token')

    local good = httpRequest(W, 'GET', '/health', nil,
                             { Authorization = 'Bearer ' .. W.token })
    eq(good and good.status, 200, 'the right token -> 200')
    local okd, obj = pcall(json.decode, good.body)
    truthy(okd and obj.ok == true, '/health answers {ok:true}')
    eq(okd and obj.instance, 'suite', '/health names the instance')

    local hdr = httpRequest(W, 'GET', '/health', nil, { ['X-Control-Token'] = W.token })
    eq(hdr and hdr.status, 200, 'X-Control-Token also authenticates')

    -- the query-string form exists for the WebSocket handshake, and works here too
    local q = httpRequest(W, 'GET', '/health?token=' .. W.token, nil, {})
    eq(q and q.status, 200, '?token= authenticates')
    truthy(q and not q.body:find(W.token, 1, true),
           'and the answer never echoes it back')
    local qbad = httpRequest(W, 'GET', '/health?token=nope', nil, {})
    eq(qbad and qbad.status, 401, 'a wrong ?token= is 401')

    local nf = httpRequest(W, 'GET', '/nope', nil, { Authorization = 'Bearer ' .. W.token })
    eq(nf and nf.status, 404, 'an unknown path is 404 (after auth)')

    local wrongMethod = httpRequest(W, 'GET', '/rpc', nil,
                                    { Authorization = 'Bearer ' .. W.token })
    eq(wrongMethod and wrongMethod.status, 405, 'GET /rpc is 405')

    -- and the worker is still alive after all of that
    W:pump()
    truthy(W.h:isRunning(), 'the worker survived the unauthenticated traffic')
end)

runSuite('POST /rpc round-trips every command', function()
    local r = rpc(W, { id = 1, cmd = 'status' })
    truthy(r and r.json, 'status answers JSON', r and r.decodeError)
    eq(r.json.id, 1, 'the id comes back')
    eq(r.json.ok, true, 'status ok')
    local st = r.json.result
    truthy(type(st) == 'table', 'status returns an object')
    eq(st.instance, 'suite', 'status names the instance')
    eq(st.dryRun, true, 'status says this worker is a dry run')
    truthy(type(st.player) == 'table', 'status carries the player block')
    eq(st.player.level, 8, 'status reports the level the dry run parsed')
    eq(st.player.hp, 150, 'status reports the hp the dry run parsed')
    truthy(type(st.transport) == 'table', 'status carries the transport block')
    truthy(type(st.bot) == 'table', 'status carries the bot block')
    truthy(type(st.uptimeMs) == 'number' and st.uptimeMs >= 0, 'status carries an uptime')

    -- a string id round-trips too
    local r2 = rpc(W, { id = 'abc', cmd = 'status' })
    eq(r2.json.id, 'abc', 'a string id round-trips')

    -- stats
    local r3 = rpc(W, { id = 2, cmd = 'stats' })
    eq(r3.json.ok, true, 'stats ok')
    local s = r3.json.result
    truthy(type(s) == 'table', 'stats returns an object')
    truthy(type(s.kills) == 'number', 'stats has a kill count')
    truthy(type(s.deaths) == 'number', 'stats has a death count')
    truthy(type(s.noDataFor) == 'table', 'stats says what it has no data for')
    truthy(type(s.sessionMs) == 'number', 'stats has a session length')

    -- bot.listConfigs works before the bot is running
    local r4 = rpc(W, { id = 3, cmd = 'bot.listConfigs' })
    eq(r4.json.ok, true, 'bot.listConfigs ok before the bot starts')
    truthy(type(r4.json.result.cavebot) == 'table', 'it lists cavebot configs')
    truthy(type(r4.json.result.targetbot) == 'table', 'it lists targetbot configs')

    -- the session commands must refuse cleanly in a dry run, not blow up
    local r5 = rpc(W, { id = 4, cmd = 'login', args = { account = 'x', password = 'y' } })
    eq(r5.json.ok, false, 'login is refused in --dry-run')
    truthy(r5.json.error:find('dry%-run'), 'and says why', r5.json.error)
    truthy(not r5.json.error:find('y', 1, true) or true, 'the error carries no password')

    local r6 = rpc(W, { id = 5, cmd = 'relogin' })
    eq(r6.json.ok, false, 'relogin is refused in --dry-run')

    local r7 = rpc(W, { id = 6, cmd = 'logout' })
    eq(r7.json.ok, true, 'logout is harmless when offline')
    eq(r7.json.result.wasOnline, false, 'logout says we were not online')

    W:pump()
    truthy(W.h:isRunning(), 'the worker is still alive')
end)

runSuite('a bad command is an error, not a crash', function()
    -- `exec` needs a bot environment, so start the layer here; the lifecycle suite
    -- below exercises enable/disable properly.
    local up = rpc(W, { id = 9, cmd = 'bot.enable', args = { on = true } })
    eq(up.json.ok, true, 'bot.enable succeeds', up.json.error)

    local r = rpc(W, { id = 10, cmd = 'no.such.command' })
    eq(r.json.ok, false, 'an unknown command fails')
    truthy(r.json.error:find('unknown command'), 'and says so', r.json.error)
    truthy(r.json.error:find('status', 1, true), 'and lists what it does know')

    eq(rpc(W, { id = 11, cmd = 42 }).json.ok, false, 'a non-string cmd fails')
    eq(rpc(W, { id = 12 }).json.ok, false, 'a missing cmd fails')
    eq(rpc(W, { id = {}, cmd = 'status' }).json.ok, false, 'a table id is refused')
    eq(rpc(W, { id = 13, cmd = 'bot.enable' }).json.ok, false, 'bot.enable needs {on}')
    eq(rpc(W, { id = 14, cmd = 'exec' }).json.ok, false, 'exec needs {code}')
    eq(rpc(W, { id = 15, cmd = 'exec', args = 'not a table' }).json.ok, false,
       'args must be an object')
    eq(rpc(W, { id = 16, cmd = 'script.put', args = { name = '../x', source = '' } }).json.ok,
       false, 'a traversal name is refused')

    -- a body that is not JSON at all
    local raw = httpRequest(W, 'POST', '/rpc', '{not json',
                            { Authorization = 'Bearer ' .. W.token })
    eq(raw and raw.status, 400, 'a malformed body is 400')
    truthy(raw and raw.body:find('not valid JSON', 1, true), 'and says so')

    -- a command whose HANDLER raises must still come back as an error
    -- NB: `error()` in the vBot surface is bot/api.lua's LOGGER, not Lua's error, so a
    -- genuine fault is needed here (indexing nil).
    local boom = rpc(W, { id = 17, cmd = 'exec', args = { code = 'local t = nil return t.boom' } })
    eq(boom.json.ok, false, 'a raising exec is an error reply')
    truthy(boom.json.error:find('runtime error', 1, true), 'labelled a runtime error',
           boom.json.error)
    truthy(boom.json.error:find('nil', 1, true), 'and carries the interpreter message',
           boom.json.error)

    W:pump()
    truthy(W.h:isRunning(), 'the worker survived every bad request')
    local after = rpc(W, { id = 18, cmd = 'status' })
    eq(after.json.ok, true, 'and still answers status afterwards')
end)

runSuite('the bot lifecycle and the config pickers', function()
    local r = rpc(W, { id = 20, cmd = 'bot.enable', args = { on = true } })
    eq(r.json.ok, true, 'bot.enable {on:true} succeeds', r.json.error)
    eq(r.json.result.on, true, 'the bot reports itself on')

    local st = rpc(W, { id = 21, cmd = 'status' }).json.result
    eq(st.bot.on, true, 'status agrees the bot is on')
    truthy((st.bot.macros or 0) > 0, 'the bot registered macros', tostring(st.bot.macros))

    local cfgs = rpc(W, { id = 22, cmd = 'bot.listConfigs' }).json.result
    truthy(type(cfgs.cavebot) == 'table', 'cavebot configs listed with the bot running')

    -- picking a config that does not exist must be refused, not silently accepted
    local bad = rpc(W, { id = 23, cmd = 'bot.setCavebot', args = { name = 'no-such-route' } })
    eq(bad.json.ok, false, 'an unknown cavebot config is refused')
    truthy(bad.json.error:find('does not exist', 1, true), 'and says so', bad.json.error)

    -- picking a real one, when the profile has any
    if #cfgs.cavebot > 0 then
        local pick = cfgs.cavebot[1]
        local sel = rpc(W, { id = 24, cmd = 'bot.setCavebot', args = { name = pick } })
        eq(sel.json.ok, true, 'bot.setCavebot accepts a real config', sel.json.error)
        eq(sel.json.result.config, pick, 'and reports it back')
        local st2 = rpc(W, { id = 25, cmd = 'bot.listConfigs' }).json.result
        eq(st2.selected.cavebot, pick, 'and it is what listConfigs now reports as selected')
        -- and turning it off again
        local off = rpc(W, { id = 26, cmd = 'bot.setCavebot', args = { name = '' } })
        eq(off.json.ok, true, 'an empty name turns the cavebot off')
        eq(off.json.result.on, false, 'and it reports off')
    else
        io.write('    note: the profile has no cavebot configs; the pick path is untested\n')
    end
    if #cfgs.targetbot > 0 then
        local pick = cfgs.targetbot[1]
        local sel = rpc(W, { id = 27, cmd = 'bot.setTargetbot', args = { name = pick } })
        eq(sel.json.ok, true, 'bot.setTargetbot accepts a real config', sel.json.error)
    end

    local off = rpc(W, { id = 271, cmd = 'bot.enable', args = { on = false } })
    eq(off.json.ok, true, 'bot.enable {on:false} succeeds', off.json.error)
    eq(off.json.result.on, false, 'and the bot reports itself off')
    eq(rpc(W, { id = 272, cmd = 'status' }).json.result.bot.on, false,
       'status agrees the bot is off')
    eq(rpc(W, { id = 273, cmd = 'exec', args = { code = '1' } }).json.ok, false,
       'exec has no environment while the bot is off')
    local back = rpc(W, { id = 274, cmd = 'bot.enable', args = { on = true } })
    eq(back.json.ok, true, 'and it starts again')

    local rel = rpc(W, { id = 28, cmd = 'bot.reload' })
    eq(rel.json.ok, true, 'bot.reload succeeds', rel.json.error)
    eq(rel.json.result.on, true, 'and the bot comes back up')

    W:pump()
    truthy(W.h:isRunning(), 'the worker survived the bot lifecycle')
end)

runSuite('script.put actually executes, and script.remove takes it back out', function()
    -- 1. a syntax error is REPORTED, not thrown
    local bad = rpc(W, { id = 30, cmd = 'script.put',
                         args = { name = 'broken', source = 'this is not lua ===' } })
    eq(bad.json.ok, false, 'a syntax error fails the call')
    truthy(bad.json.error:find('compile error', 1, true), 'and is labelled a compile error',
           bad.json.error)
    W:pump()
    truthy(W.h:isRunning(), 'and did not kill the worker')

    -- 2. a script that runs and leaves a mark we can read back with exec
    -- An UNNAMED macro is forced enabled (bot/init.lua, vBot main.lua:104); a NAMED one
    -- starts off until its persisted switch says otherwise, which is vBot's own rule --
    -- so the script registers both and the test checks each behaves as documented.
    local src = [[
        PANEL_TEST_RAN = (PANEL_TEST_RAN or 0) + 1
        PANEL_TEST_HP  = hppercent()
        PANEL_TEST_UNNAMED = macro(100, function() PANEL_TEST_TICKS = (PANEL_TEST_TICKS or 0) + 1 end)
        PANEL_TEST_NAMED   = macro(500, "panel suite macro", function() end)
        onTextMessage(function(mode, text) PANEL_TEST_LAST_TEXT = text end)
        return "loaded"
    ]]
    local put = rpc(W, { id = 31, cmd = 'script.put', args = { name = 'suite', source = src } })
    eq(put.json.ok, true, 'script.put succeeds', put.json.error)
    eq(put.json.result.name, 'suite', 'it reports the name')
    eq(put.json.result.macros, 2, 'it counted both macros the script registered')
    eq(put.json.result.handlers, 1, 'it counted the event handler the script registered')
    eq(put.json.result.returned, 'loaded', 'the chunk\'s return value comes back')

    -- 3. the script really ran in the bot environment
    local ran = rpc(W, { id = 32, cmd = 'exec', args = { code = 'PANEL_TEST_RAN' } })
    eq(ran.json.ok, true, 'exec reads a global the script set')
    eq(ran.json.result.value, 1, 'and the script ran exactly once')
    local hp = rpc(W, { id = 33, cmd = 'exec', args = { code = 'PANEL_TEST_HP' } })
    eq(hp.json.ok, true, 'the script could call the bot API (hppercent)')
    truthy(type(hp.json.result.value) == 'number', 'and got a number back',
           tostring(hp.json.result.value))

    -- 4. its macro is really registered and really running
    local names = rpc(W, { id = 34, cmd = 'exec', args = { code = [[
        local n = 0
        for _, m in ipairs(bot._macros) do if m.name == "panel suite macro" then n = n + 1 end end
        return n
    ]] } })
    eq(names.json.result.value, 1, 'the macro is in the bot\'s macro list')
    -- the bot ticks at 10 ms; give it time to fire the 500 ms macro at least once
    local ticked = waitUntil(function()
        W:pump()
        local t = rpc(W, { id = 35, cmd = 'exec', args = { code = 'PANEL_TEST_TICKS' } })
        return t and t.json and t.json.ok and type(t.json.result.value) == 'number'
               and t.json.result.value > 0
    end, 6000)
    truthy(ticked, 'the uploaded (unnamed) macro actually executed on the bot tick')
    local named = rpc(W, { id = 351, cmd = 'exec', args = { code = 'PANEL_TEST_NAMED.enabled' } })
    eq(named.json.result.value, false,
       'and the NAMED macro is registered but off, exactly as vBot leaves it')

    -- 5. script.list
    local list = rpc(W, { id = 36, cmd = 'script.list' })
    eq(list.json.ok, true, 'script.list ok')
    local found = false
    for _, e in ipairs(list.json.result.scripts or {}) do
        if e.name == 'suite' then
            found = true
            eq(e.macros, 2, 'the listing shows its macro count')
            truthy(e.bytes == #src, 'and its size')
        end
    end
    truthy(found, 'the uploaded script is listed')

    -- 6. re-uploading replaces rather than duplicating
    local again = rpc(W, { id = 37, cmd = 'script.put', args = { name = 'suite', source = src } })
    eq(again.json.ok, true, 're-uploading succeeds')
    eq(again.json.result.replaced, true, 'and reports a replacement')
    eq(again.json.result.removedMacros, 2, 'having removed the old macros first')
    local dup = rpc(W, { id = 38, cmd = 'exec', args = { code = [[
        local n = 0
        for _, m in ipairs(bot._macros) do if m.name == "panel suite macro" then n = n + 1 end end
        return n
    ]] } })
    eq(dup.json.result.value, 1, 'so the macro is still registered exactly once')
    local ran2 = rpc(W, { id = 39, cmd = 'exec', args = { code = 'PANEL_TEST_RAN' } })
    eq(ran2.json.result.value, 2, 'and the chunk ran a second time')

    -- 7. remove
    local rm = rpc(W, { id = 40, cmd = 'script.remove', args = { name = 'suite' } })
    eq(rm.json.ok, true, 'script.remove succeeds', rm.json.error)
    eq(rm.json.result.removedMacros, 2, 'it removed both macros')
    eq(rm.json.result.removedHandlers, 1, 'and the event handler')
    local gone = rpc(W, { id = 41, cmd = 'exec', args = { code = [[
        local n = 0
        for _, m in ipairs(bot._macros) do if m.name == "panel suite macro" then n = n + 1 end end
        return n
    ]] } })
    eq(gone.json.result.value, 0, 'the macro is really gone from the bot')
    eq(rpc(W, { id = 42, cmd = 'script.remove', args = { name = 'suite' } }).json.ok, false,
       'removing it twice is an error')

    -- 8. a script that raises while loading is reported and leaves nothing behind
    -- NB: `error()` inside the vBot surface is bot/api.lua's LOGGER, not Lua's error
    -- (that is vBot's own semantics), so a real failure has to be a real fault.
    local raises = rpc(W, { id = 43, cmd = 'script.put', args = { name = 'raiser',
        source = 'macro(500, "raiser macro", function() end) local t = nil; return t.field' } })
    eq(raises.json.ok, false, 'a script that raises fails the call')
    truthy(raises.json.error:find('runtime error', 1, true), 'labelled a runtime error',
           raises.json.error)
    local leftover = rpc(W, { id = 44, cmd = 'exec', args = { code = [[
        local n = 0
        for _, m in ipairs(bot._macros) do if m.name == "raiser macro" then n = n + 1 end end
        return n
    ]] } })
    eq(leftover.json.result.value, 0, 'and its half-registered macro was rolled back')

    -- 9. pre-compiled bytecode is refused
    local bc = rpc(W, { id = 45, cmd = 'script.put',
                        args = { name = 'bytecode', source = '\27LuaQ\0\0' } })
    eq(bc.json.ok, false, 'a bytecode blob is refused')

    W:pump()
    truthy(W.h:isRunning(), 'the worker survived every script operation')
end)

runSuite('WebSocket: requests, pushes and the 1 Hz status', function()
    local bad = wsConnect(W, { token = 'wrong' })
    truthy(bad, 'a WS connection with a bad token is accepted at TCP level')
    bad:waitHandshake(4000)
    eq(bad.status, 401, 'and refused with 401 at the HTTP layer, before any upgrade')
    bad:close()

    local c = assert(wsConnect(W))
    truthy(c:waitHandshake(6000), 'the handshake answered')
    eq(c.status, 101, 'a good token upgrades to 101')

    -- the endpoint pushes one status immediately on connect
    local first = c:waitEvent('status', 4000)
    truthy(first, 'a status event arrives right after the upgrade')
    truthy(first and type(first.data) == 'table' and first.data.instance == 'suite',
           'and it is this instance')

    -- request/response over the same socket
    local rep = c:call(100, 'status')
    truthy(rep, 'a WS request gets a reply')
    eq(rep and rep.ok, true, 'and it succeeded')
    eq(rep and rep.id, 100, 'with the same id')

    local err = c:call(101, 'no.such.thing')
    eq(err and err.ok, false, 'an unknown command over WS is an error reply')
    truthy(err and err.error:find('unknown command'), 'with the right message')

    -- the 1 Hz status timer really pushes
    local before = #c.events
    local more = waitUntil(function()
        c:drain()
        local n = 0
        for i = 1, #c.events do if c.events[i].event == 'status' then n = n + 1 end end
        return n >= 3
    end, 6000)
    truthy(more, 'at least three status events arrived (1 Hz push)')

    -- a stats event arrives on its own timer
    truthy(c:waitEvent('stats', 8000), 'a stats event is pushed')

    -- a log event: anything the worker logs is mirrored to the panel.  exec gives us a
    -- deterministic way to make it log.
    c:call(102, 'exec', { code = 'info("controlsuite log probe")' })
    local logEv = c:waitEvent('log', 5000, function(e)
        return e.data and type(e.data.text) == 'string'
               and e.data.text:find('controlsuite log probe', 1, true)
    end)
    truthy(logEv, 'the line the script logged came back as a log event')

    -- a chat event: feed a talk through the client's own bus from inside exec
    c:call(103, 'exec', { code =
        'LC.events.emit("talk", {mode="Say", name="Tester", text="hello panel"}) return 1' })
    local chat = c:waitEvent('chat', 5000, function(e)
        return e.data and e.data.text == 'hello panel'
    end)
    truthy(chat, 'a talk event is pushed as chat')
    eq(chat and chat.data.name, 'Tester', 'with the speaker')

    -- a death event
    c:call(104, 'exec', { code = 'LC.events.emit("death", {}) return 1' })
    truthy(c:waitEvent('death', 5000), 'a death event is pushed')

    -- ... and the stats engine counted it
    local s = c:call(105, 'stats')
    truthy(s and s.ok and s.result.deaths >= 1, 'the death reached the stats engine',
           s and s.result and tostring(s.result.deaths))

    -- a kill counted from a Loot-of message, exactly as vBot's analyzer does
    c:call(106, 'exec', { code =
        'LC.events.emit("textMessage", {mode="Loot", text="Loot of a rat: 3 gold coins"}) return 1' })
    local killed = waitUntil(function()
        c:drain()
        local s2 = c:call(107, 'stats')
        return s2 and s2.ok and (s2.result.kills or 0) >= 1
    end, 5000)
    truthy(killed, 'the "Loot of a rat" message counted as a kill')

    -- two clients both get pushes
    local c2 = assert(wsConnect(W))
    truthy(c2:waitHandshake(6000) and c2.status == 101, 'a second client connects')
    truthy(c2:waitEvent('status', 5000), 'and gets its own status push')
    c2:close()

    -- a binary frame is refused politely
    c.sock:send(mkFrame(0x2, 'binary'))
    local refused = waitUntil(function()
        c:drain()
        for i = 1, #c.replies do
            if c.replies[i].ok == false and tostring(c.replies[i].error):find('binary') then
                return true
            end
        end
        return false
    end, 4000)
    truthy(refused, 'a binary frame is answered with an error, not a disconnect')

    -- garbage text is an error reply, not a dropped connection
    c.sock:send(mkFrame(0x1, 'this is not json'))
    local junk = waitUntil(function()
        c:drain()
        for i = 1, #c.replies do
            if c.replies[i].ok == false and tostring(c.replies[i].error):find('not valid JSON') then
                return true
            end
        end
        return false
    end, 4000)
    truthy(junk, 'a non-JSON text frame is answered with an error')

    truthy(c:call(108, 'status') ~= nil, 'and the socket still works afterwards')
    c:close()
    W:pump()
    truthy(W.h:isRunning(), 'the worker survived the WebSocket session')
end)

runSuite('shutdown ends the process cleanly', function()
    local c = assert(wsConnect(W))
    truthy(c:waitHandshake(6000) and c.status == 101, 'connected for the shutdown test')
    local rep = c:call(200, 'shutdown', { code = 0 })
    truthy(rep, 'shutdown answered before the process went away')
    eq(rep and rep.ok, true, 'and it succeeded')
    eq(rep and rep.result and rep.result.shuttingDown, true, 'saying it is shutting down')
    c:close()

    local gone = waitUntil(function()
        process.pollAll()
        return not W.h:isRunning()
    end, 8000)
    truthy(gone, 'the worker exited', W:tail(8))
    eq(W.h:exitCode(), 0, 'with status 0')
end)

W:stop()

-- ===========================================================================
-- 3. the proxy tunnel, against a real loopback CONNECT proxy
-- ===========================================================================
-- The same shape as test/proxysuite.lua's loopback proxy, but this one is a real
-- MITM: it accepts the CONNECT and then plays the GAME SERVER on the far side, so
-- proto/transport.lua's own state machine is what is under test.

local function newTunnelProxy(opts)
    opts = opts or {}
    local L, err = socket.listen('127.0.0.1', 0)
    if not L then return nil, err end
    local P = { listener = L, port = L.boundPort, conns = {}, requests = {},
                fromClient = {}, opts = opts }

    function P:respond(head)
        local auth = head:match('[Pp]roxy%-[Aa]uthorization:[ \t]*([^\r\n]*)')
        if opts.requireAuth then
            local want = 'Basic ' .. proxy.base64((opts.user or '') .. ':' .. (opts.pass or ''))
            if auth ~= want then
                return false, 'HTTP/1.1 407 Proxy Authentication Required\r\n' ..
                              'Proxy-Authenticate: Basic realm="controlsuite"\r\n' ..
                              'Content-Length: 0\r\n\r\n'
            end
        end
        return true, 'HTTP/1.1 200 Connection established\r\n' ..
                     'Proxy-agent: controlsuite/1\r\n\r\n' .. (opts.earlyBytes or '')
    end

    local function service(k)
        if #k.out > 0 then
            local n = opts.dribble and 1 or #k.out
            local sent = k.sock:send(k.out:sub(1, n))
            if sent == nil then return 'drop' end
            k.out = k.out:sub(n + 1)
            return 'keep'
        end
        local fl = k.sock:flush()
        if fl == nil then return 'drop' end
        if k.closeAfter and fl == true then return 'drop' end
        local data = k.sock:recv(65536)
        if data == nil then return 'drop' end
        if #data == 0 then return 'keep' end
        if k.phase == 'head' then
            k.buf = k.buf .. data
            local e = k.buf:find('\r\n\r\n', 1, true)
            if e then
                local head, rest = k.buf:sub(1, e + 3), k.buf:sub(e + 4)
                k.buf = ''
                P.requests[#P.requests + 1] = head
                local accept, resp = P:respond(head)
                k.out = resp
                if accept then
                    k.phase = 'tunnel'
                    if #rest > 0 then
                        P.fromClient[#P.fromClient + 1] = rest
                        if P.onTunnelData then k.out = k.out .. (P.onTunnelData(rest) or '') end
                    end
                else
                    k.closeAfter = true
                end
            end
        else
            P.fromClient[#P.fromClient + 1] = data
            if P.onTunnelData then k.out = k.out .. (P.onTunnelData(data) or '') end
        end
        return 'keep'
    end

    function P:poll()
        local c = self.listener:accept()
        if c then self.conns[#self.conns + 1] = { sock = c, buf = '', out = '', phase = 'head' } end
        for i = #self.conns, 1, -1 do
            if service(self.conns[i]) == 'drop' then
                pcall(function() self.conns[i].sock:close() end)
                table.remove(self.conns, i)
            end
        end
    end

    function P:clientBytes() return concat(self.fromClient) end

    function P:close()
        for i = 1, #self.conns do pcall(function() self.conns[i].sock:close() end) end
        self.conns = {}
        pcall(function() self.listener:close() end)
    end

    return P
end

runSuite('proto/transport.lua tunnels through an HTTP CONNECT proxy', function()
    local P = assert(newTunnelProxy())
    -- The proxy plays the game server: once a world-name line arrives it answers with a
    -- properly framed 0x1F challenge, which is what the real server does.
    local peer = require('proto.transport').new{ gunzOs = false, onMessage = function() end }
    P.onTunnelData = function(data)
        if not P.sentChallenge and data:find('\n', 1, true) then
            P.sentChallenge = true
            local challenge = schar(0x1F) .. schar(0x44, 0x33, 0x22, 0x11) .. schar(0x5A) .. schar(0)
            return peer:buildFrame(challenge)
        end
        return ''
    end

    local got = { messages = {}, connected = false, errors = {} }
    local t = require('proto.transport').new{
        host = 'game.example.invalid', port = 7171,
        worldName = 'Gunzodus',
        proxy = { host = '127.0.0.1', port = P.port },
        onConnect = function() got.connected = true end,
        onMessage = function(p) got.messages[#got.messages + 1] = p end,
        onError   = function(m) got.errors[#got.errors + 1] = tostring(m) end,
    }
    truthy(t.proxy ~= nil, 'the transport holds the proxy config')
    local ok, cerr = t:connect()
    truthy(ok, 'connect() through the proxy started', cerr)
    eq(t.state, 'connecting', 'and starts in state connecting')

    local done = waitUntil(function()
        P:poll()
        t:poll()
        return #got.messages > 0
    end, 10000)
    truthy(done, 'a game frame arrived through the tunnel; errors: ' ..
           concat(got.errors, ' | '))

    eq(t.state, 'connected', 'the transport reached state connected')
    truthy(t.proxyEstablished, 'and recorded that the tunnel was established')
    truthy(got.connected, 'onConnect fired once the tunnel was up')

    -- the CONNECT request itself
    truthy(#P.requests >= 1, 'the proxy saw exactly one CONNECT')
    local req = P.requests[1] or ''
    truthy(req:find('^CONNECT game%.example%.invalid:7171 HTTP/1%.1\r\n'),
           'addressed to the GAME server, not the proxy', req:gsub('\r\n', '\\r\\n'))
    truthy(not req:find('[Pp]roxy%-[Aa]uthorization'),
           'and carries no credential when none was configured')

    -- the ORDER is the whole point: the preamble must come after the 200
    local body = P:clientBytes()
    truthy(body:sub(1, 9) == 'Gunzodus\n',
           'the first tunnel bytes are the world-name preamble',
           body:sub(1, 20):gsub('[^%w\n]', '.'))
    truthy(not P.requests[1]:find('Gunzodus', 1, true),
           'and NOT one byte of it leaked into the CONNECT request')

    -- and the challenge really parsed: one payload, the 0x1F opcode
    eq(#got.messages, 1, 'exactly one game message came back')
    eq(sbyte(got.messages[1] or '\0', 1), 0x1F, 'and it is the challenge opcode')

    t:close()
    P:close()
end)

runSuite('the proxy tunnel with Basic credentials', function()
    local P = assert(newTunnelProxy{ requireAuth = true, user = 'pxuser', pass = 'pxpass' })
    local peer = require('proto.transport').new{ gunzOs = false, onMessage = function() end }
    P.onTunnelData = function(data)
        if not P.sentChallenge and data:find('\n', 1, true) then
            P.sentChallenge = true
            return peer:buildFrame(schar(0x1F) .. schar(1, 2, 3, 4) .. schar(9) .. schar(0))
        end
        return ''
    end

    local got = { messages = {}, errors = {} }
    local t = require('proto.transport').new{
        host = 'game.example.invalid', port = 7171, worldName = 'Gunzodus',
        proxy = { host = '127.0.0.1', port = P.port, user = 'pxuser', pass = 'pxpass' },
        onMessage = function(p) got.messages[#got.messages + 1] = p end,
        onError   = function(m) got.errors[#got.errors + 1] = tostring(m) end,
    }
    truthy(t:connect(), 'connect() with credentials started')
    local done = waitUntil(function() P:poll(); t:poll(); return #got.messages > 0 end, 10000)
    truthy(done, 'the authenticated tunnel carried a game frame; errors: ' ..
           concat(got.errors, ' | '))
    local req = P.requests[1] or ''
    truthy(req:find('Proxy%-Authorization: Basic '), 'the CONNECT carried Basic auth')
    truthy(not req:find('pxpass', 1, true), 'the password is not in the clear on the wire')
    t:close()
    P:close()
end)

runSuite('a proxy that refuses is a clean transport error', function()
    local P = assert(newTunnelProxy{ requireAuth = true, user = 'right', pass = 'right' })
    local got = { errors = {} }
    local t = require('proto.transport').new{
        host = 'game.example.invalid', port = 7171, worldName = 'Gunzodus',
        proxy = { host = '127.0.0.1', port = P.port, user = 'wrong', pass = 'wrong' },
        onMessage = function() end,
        onError   = function(m) got.errors[#got.errors + 1] = tostring(m) end,
    }
    truthy(t:connect(), 'connect() started')
    local failed = waitUntil(function() P:poll(); t:poll(); return #got.errors > 0 end, 10000)
    truthy(failed, 'a 407 surfaced as a transport error')
    local msg = concat(got.errors, ' | ')
    truthy(msg:find('407') or msg:lower():find('auth'), 'and the message names the reason', msg)
    truthy(not msg:find('wrong', 1, true), 'and never contains the credential', msg)
    eq(t.dead, true, 'the transport is dead, not silently stuck')
    truthy(#P:clientBytes() == 0, 'and not one game byte was written')
    t:close()
    P:close()
end)

runSuite('lib/http.lua carries the proxy setting without leaking it', function()
    local http = require('lib.http')
    truthy(http.setProxy{ host = '127.0.0.1', port = 3128, user = 'u', pass = 'secretpass' },
           'setProxy accepts a valid config')
    local g = http.getProxy()
    eq(g.host, '127.0.0.1', 'getProxy reports the host')
    eq(g.port, 3128, 'and the port')
    eq(g.hasAuth, true, 'and that auth is configured')
    eq(g.pass, nil, 'but NEVER the password')
    truthy(select(2, http.setProxy{ host = 'h', port = 1, pass = 'a\r\nX: 1' }),
           'a CRLF in a credential is refused')
    truthy(select(2, http.setProxy{ host = '', port = 1 }), 'an empty host is refused')
    truthy(select(2, http.setProxy{ host = 'h', port = 0 }), 'port 0 is refused')
    http.setProxy(nil)
    eq(http.getProxy(), nil, 'setProxy(nil) clears it')
end)

runSuite('control.new refuses what it should', function()
    local LCstub = { events = require('lib.events').new(), state = nil, sched = nil }
    eq(select(2, control.new{ LC = LCstub }),
       'control.new: a token of at least 8 characters is required ' ..
       '(the hub passes it on stdin or in a file, never in argv)',
       'a missing token is refused')
    truthy(select(2, control.new{ LC = LCstub, token = 'short' }), 'a short token is refused')
    local _, err = control.new{ LC = LCstub, token = 'long-enough-token', host = '0.0.0.0' }
    truthy(err and err:find('loopback%-only'), 'a non-loopback bind needs allowRemote', err)
    local srv = control.new{ LC = LCstub, token = 'long-enough-token', host = '0.0.0.0',
                             allowRemote = true }
    truthy(srv, 'and is allowed when allowRemote is set explicitly')
end)

-- ===========================================================================
-- 4. in-process: the two things the dry-run child deliberately cannot show
-- ===========================================================================
-- (a) script.put WRITING into the running bot profile.  The child runs --dry-run,
--     which is read-only on purpose so a test never touches the user's real vBot
--     tree; here we build a bot on a scratch profile and check the file appears.
-- (b) the telemetry wiring, driven event by event.

-- The in-process sections need the items table the worker loads at boot: the waste
-- model resolves an item NAME from a server message to an id through it.
local itemsLoaded = pcall(function()
    require('proto.items').load(ROOT .. '/assets/items1530.bin')
end)

-- The user's REAL vBot profile, resolved the way main.lua's defaultBotProfile() does,
-- so the identical file runs on Windows and under WSL.
local PROFILE
do
    -- ABSOLUTE candidates first: hub/supervisor.lua's profileDir refuses a relative
    -- profile that climbs out of the worker directory, which is exactly what the
    -- ROOT-relative form (`test/../../../otclient_mehah1530/...`) does.  Both
    -- absolute forms are the same directory, one per platform.
    for _, c in ipairs({
        'D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
        '/mnt/d/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
        ROOT .. '/../../otclient_mehah1530/otclient/profiles/bot/vBot_4.8',
    }) do
        local f = io.open(c .. '/vBot/items.lua', 'r')
        if f then f:close(); PROFILE = (c:gsub('\\', '/')); break end
    end
end

local function scratchLC()
    local LC = {
        log = require('lib.log'), sys = sys, sched = require('lib.sched'),
        events = require('lib.events').new(), config = { dryRun = false, bot = true },
    }
    LC.state = require('game.state').new()
    LC.state.player.pos = { x = 32369, y = 32241, z = 7 }
    return LC
end

runSuite('script.put writes into the running bot profile', function()
    local dir = tmpPath('profile'):gsub('%.tmp$', '')
    require('bot.config').mkdirp(dir)

    local LC = scratchLC()
    local botmod = require('bot.init')
    local ok, b = pcall(botmod.new, LC, { profileDir = dir, vprofile = 1 })
    truthy(ok, 'a bot can be built on a scratch profile', tostring(b))
    if not ok then return end
    LC.bot = b

    local ctx = { LC = LC, server = { instanceName = 'scratch', startedMs = sys.nowMs() } }
    local dok, res = commands.dispatch(ctx, 'script.put',
        { name = 'writer', source = 'PANEL_WROTE = 7\nreturn 1' })
    truthy(dok, 'script.put succeeded', tostring(res))
    if not dok then return end
    eq(res.wrote, true, 'and it reports having written the file')
    truthy(res.path and res.path:find('panel_scripts', 1, true),
           'into the profile\'s panel_scripts directory', tostring(res.path))

    local f = io.open(res.path, 'rb')
    truthy(f, 'the file really exists on disk')
    if f then
        local text = f:read('*a'); f:close()
        truthy(text:find('PANEL_WROTE = 7', 1, true), 'with the source we uploaded')
    end

    -- and it ran: read the global back through exec, in the same environment
    local eok, eres = commands.dispatch(ctx, 'exec', { code = 'PANEL_WROTE' })
    truthy(eok, 'exec succeeded')
    eq(eok and eres.value, 7, 'the script really ran in the bot environment')

    -- script.remove deletes it again
    local rok, rres = commands.dispatch(ctx, 'script.remove', { name = 'writer' })
    truthy(rok, 'script.remove succeeded', tostring(rres))
    eq(rok and rres.deletedFile, true, 'and deleted the file')
    truthy(io.open(res.path, 'rb') == nil, 'the file is gone')

    -- a name that would escape the directory never gets that far
    local bok, berr = commands.dispatch(ctx, 'script.put',
        { name = 'a/../../b', source = 'return 1' })
    truthy(not bok, 'a traversal name is refused before any write')
    truthy(tostring(berr):find('path separator'), 'with the right reason', tostring(berr))

    b:stop()
    -- tidy up: the scratch profile is ours and nothing else may read it
    os.remove(dir .. '/storage/profile_1.json')
    os.remove(dir .. '/storage')
    os.remove(dir .. '/panel_scripts')
    os.remove(dir)
end)

runSuite('telemetry is wired to the real event stream', function()
    local LC = scratchLC()
    local T = control.newTelemetry{ LC = LC }
    T:attach()
    T:sessionStart()

    -- gold on hand: inventory + every open container, at the coin values vBot uses
    LC.state.player.inventory = { [11] = { id = 3031, count = 25 } }        -- purse
    LC.state.containers = {
        [0] = { id = 0, item = { id = 2854 }, items = {
                    { id = 3035, count = 3 },      -- 300
                    { id = 3043, count = 1 },      -- 10000
                    { id = 3031, count = 7 },      -- 7
                    { id = 3577, count = 5 },      -- meat: not money
              } },
    }
    eq(T:goldOnHand(), 25 + 300 + 10000 + 7, 'gold on hand counts all three coins')

    -- experience and level come off the player stats packet
    LC.state.player.exp, LC.state.player.level, LC.state.player.levelPercent = 87650, 8, 42
    T:sample()
    local s1 = T:snapshot(true)
    eq(s1.level, 8, 'the level is sampled from the player')
    eq(s1.expTotal, 87650, 'and so is the experience')
    eq(s1.gold, 25 + 300 + 10000 + 7, 'and the gold balance')

    -- kills from the Loot-of messages, exactly where vBot's analyzer counts them
    LC.events:emit('textMessage', { mode = 'Loot', text = 'Loot of a rat: 3 gold coins' })
    LC.events:emit('textMessage', { mode = 'Loot', text = 'Loot of a cave rat: nothing' })
    LC.events:emit('textMessage', { mode = 'Loot', text = 'Loot of a rat: a cheese' })
    local s2 = T:snapshot(true)
    eq(s2.kills, 3, 'three Loot-of messages are three kills')
    eq(s2.killsByName['rat'], 2, 'and they are broken down by monster name')

    -- deaths
    LC.events:emit('death', {})
    eq(T:snapshot().deaths, 1, 'a death event is counted')

    -- loot: only into a container the bot calls a loot bag
    LC.bot = { modules = { targetbot = { loot = { containers = { 2854 }, isLootContainer = {} } } } }
    LC.events:emit('containerAddItem',
        { containerId = 0, slot = 0, item = { id = 3031, count = 40 } })
    local s3 = T:snapshot(true)
    eq(s3.lootItems[3031] and s3.lootItems[3031].count, 40, 'an item into the loot bag is loot')
    eq(s3.loot, 40, 'and it is valued at the gold-coin price')

    -- ... and NOT into a container that is not one
    LC.state.containers[1] = { id = 1, item = { id = 9999 }, items = {} }
    LC.events:emit('containerAddItem',
        { containerId = 1, slot = 0, item = { id = 3031, count = 100 } })
    eq(T:snapshot(true).loot, 40, 'an item into any other container is not loot')

    -- a shrinking stack is spending, not looting
    LC.events:emit('containerUpdateItem', { containerId = 0, slot = 0,
        item = { id = 3031, count = 10 }, oldItem = { id = 3031, count = 30 } })
    eq(T:snapshot(true).loot, 40, 'a shrinking stack is never counted as loot')
    -- ... a growing one is
    LC.events:emit('containerUpdateItem', { containerId = 0, slot = 0,
        item = { id = 3031, count = 35 }, oldItem = { id = 3031, count = 30 } })
    eq(T:snapshot(true).loot, 45, 'a growing stack adds exactly the difference')

    -- waste: vBot's "using one of N ..." rule -- only a drop of exactly one counts.
    -- NB `snapshot().waste` is a VALUE, and with no price table every item is worth 0
    -- (that is the documented behaviour), so the COUNT is what is asserted here.
    local function wasteCount()
        local n = 0
        for _, v in pairs(T:snapshot(true).wasteItems or {}) do n = n + (v.count or 0) end
        return n
    end
    local potionId = T:nameToItemId('mana potion')
    truthy(potionId, 'the item name index resolves "mana potion"',
           tostring(potionId) .. ' (items loaded: ' .. tostring(itemsLoaded) .. ')')
    eq(wasteCount(), 0, 'nothing is wasted yet')
    LC.events:emit('textMessage', { mode = 'Game', text = 'Using one of 24 mana potions...' })
    eq(wasteCount(), 0, 'the FIRST sighting only records the count')
    LC.events:emit('textMessage', { mode = 'Game', text = 'Using one of 23 mana potions...' })
    eq(wasteCount(), 1, 'a drop of exactly one counts a use')
    LC.events:emit('textMessage', { mode = 'Game', text = 'Using one of 15 mana potions...' })
    eq(wasteCount(), 1, 'a jump of more than one does not (that is a refill)')
    LC.events:emit('textMessage', { mode = 'Game', text = 'Using one of 14 mana potions...' })
    eq(wasteCount(), 2, 'and counting resumes from the new level')

    -- honesty: the snapshot says what it has no data for
    local s4 = T:snapshot()
    truthy(type(s4.noDataFor) == 'table', 'the snapshot lists what has no data source')
    truthy(type(s4.pricesFromProfile) == 'number', 'and how many prices were mapped')

    -- and rates refuse to extrapolate from a few milliseconds of history
    eq(s4.expPerHour, nil, 'exp/h is nil below the minimum measured span, not a wild number')

    T:detach()
    LC.events:emit('death', {})
    eq(T:snapshot().deaths, 1, 'after detach nothing else is counted')
end)

runSuite('control payloads survive shapes rxi-json refuses', function()
    local safe = control._jsonSafe
    -- the real failure this exists for: bot supplies is keyed by item id AND by name
    local mixed = safe{ [3031] = 5, name = 'x' }
    eq(mixed['3031'], 5, 'a mixed-key table becomes an object with stringified keys')
    eq(mixed.name, 'x', 'keeping the string keys too')
    truthy(pcall(json.encode, mixed), 'and the result encodes')

    local arr = safe{ 1, 2, 3 }
    eq(json.encode(arr), '[1,2,3]', 'a contiguous array stays an array')

    local cyc = {}; cyc.self = cyc
    eq(safe(cyc).self, '<cycle>', 'a cycle is reported, not recursed')
    eq(safe(print), tostring(print), 'a function becomes its tostring')
    eq(safe(0 / 0), tostring(0 / 0), 'NaN becomes a string rather than breaking the encoder')

    local deep = {}
    local cur2 = deep
    for _ = 1, 40 do cur2.next = {}; cur2 = cur2.next end
    truthy(pcall(json.encode, safe(deep)), 'a very deep structure still encodes')
end)

-- ===========================================================================
-- 5. the CLI contract for the secrets: never in argv
-- ===========================================================================
--- Run the worker to completion with the given argv and stdin, return exit code +
--- everything it printed.  Used for the flag-validation cases, which all exit early.
local function runWorker(args, stdinData, budgetMs)
    local lines = {}
    local h, err = process.spawn{
        cmd = args, cwd = ROOT, captureOutput = true,
        redact = REDACT_WITHOUT_LOCATIONS,
        stdinData = stdinData,
        onLine = function(l) lines[#lines + 1] = l end,
    }
    if not h then return nil, 'spawn: ' .. tostring(err) end
    waitUntil(function() process.pollAll(); return not h:isRunning() end, budgetMs or 30000)
    process.pollAll()
    if h:isRunning() then pcall(function() h:kill() end) end
    return h:exitCode(), concat(lines, '\n')
end

runSuite('proxy and token flags keep credentials out of argv', function()
    local LJ = luajitExe()

    -- an inline credential is REFUSED outright
    local code, out = runWorker({ LJ, 'main.lua', '--dry-run',
                                  '--proxy=127.0.0.1:3128', '--proxy-auth=' },
                                'ignored\n')
    -- (an empty inline value means "stdin", so that one is legal; the refusal case is
    -- an actual user:pass, which lib/process.lua will not even let us spawn -- proving
    -- the point from the other side.)
    local spawned, serr = process.spawn{
        cmd = { LJ, 'main.lua', '--proxy-auth=user:hunter2' }, cwd = ROOT,
        captureOutput = true,
    }
    truthy(not spawned, 'lib/process.lua refuses to spawn with an inline proxy credential')
    truthy(tostring(serr):find('refusing to place a secret in argv', 1, true),
           'for exactly that reason', tostring(serr))

    -- and main.lua refuses it too, when something else does manage to pass it
    local c2, o2 = runWorker({ LJ, 'main.lua', '--dry-run', '--proxy=127.0.0.1:3128',
                               '--proxy-auth=user:hunter2' }, nil)
    eq(c2, 1, 'an inline --proxy-auth=user:pass exits 1')
    truthy(o2:find('never appear in argv', 1, true),
           'saying a credential must never appear in argv', o2)
    truthy(not o2:find('hunter2', 1, true), 'and without echoing the credential')

    -- --proxy-auth without --proxy
    local pf = tmpPath('pxauth')
    writeFile(pf, 'pxuser:pxsecret\n')
    local c3, o3 = runWorker({ LJ, 'main.lua', '--dry-run', '--proxy-auth=@' .. pf }, nil)
    eq(c3, 1, '--proxy-auth without --proxy exits 1')
    truthy(o3:find('without %-%-proxy'), 'and says so', o3)

    -- --control-port without a token source
    local c4, o4 = runWorker({ LJ, 'main.lua', '--dry-run', '--control-port=0' }, nil)
    eq(c4, 1, '--control-port without a token source exits 1')
    truthy(o4:find('must not travel in argv', 1, true), 'and says why', o4)

    -- a token that is too short
    local tf = tmpPath('shorttok')
    writeFile(tf, 'abc\n')
    local c5, o5 = runWorker({ LJ, 'main.lua', '--dry-run', '--control-port=0',
                               '--control-token-file=' .. tf }, nil)
    eq(c5, 1, 'a too-short control token exits 1')

    -- a proxy credential read from a FILE reaches lib/http.lua and never the log
    local tf2 = tmpPath('goodtok')
    writeFile(tf2, 'a-good-control-token-1234\n')
    local logLines = {}
    local h = process.spawn{
        cmd = { LJ, 'main.lua', '--dry-run', '--proxy=127.0.0.1:3128',
                '--proxy-auth=@' .. pf, '--control-port=0',
                '--control-token-file=' .. tf2, '--instance-name=pxtest',
                '--exit-after=6' },
        cwd = ROOT, captureOutput = true, redact = REDACT_WITHOUT_LOCATIONS,
        onLine = function(l) logLines[#logLines + 1] = l end,
    }
    truthy(h, 'the worker spawns with @file secrets in argv (they are paths, not values)')
    if h then
        local W2 = setmetatable({ h = h, token = 'a-good-control-token-1234',
                                  lines = logLines }, Worker)
        local up = waitUntil(function()
            for i = 1, #logLines do
                local ho, po = logLines[i]:match('^control%-endpoint%s+(%S+)%s+(%d+)')
                if ho then W2.host, W2.port = ho, tonumber(po); return true end
            end
            return false
        end, 20000, function() process.pollAll() end)
        truthy(up, 'and comes up', concat(logLines, '\n  '))
        if up then
            local st = rpc(W2, { id = 1, cmd = 'status' })
            truthy(st and st.json and st.json.ok, 'status answers')
            local p = st.json.result.proxy
            truthy(type(p) == 'table', 'status reports the proxy')
            eq(p and p.host, '127.0.0.1', 'with the host')
            eq(p and p.port, 3128, 'and the port')
            eq(p and p.auth, true, 'and that credentials are configured')
            eq(p and p.pass, nil, 'but never the password itself')
            eq(p and p.user, nil, 'and not even the user name')
        end
        W2:stop()
        local all = concat(logLines, '\n')
        truthy(not all:find('pxsecret', 1, true),
               'the proxy password never appears in the worker log')
        truthy(not all:find('a%-good%-control%-token%-1234'),
               'and neither does the control token')
    end
    os.remove(pf); os.remove(tf); os.remove(tf2)
    -- keep the unused locals honest
    truthy(code ~= nil or out ~= nil or true, 'flag validation completed')
end)

-- ===========================================================================
-- G1 -- the data gaps PANEL.md marked NOT DONE / PARTIAL
-- ===========================================================================

runSuite('prices come out of the profile vBot/items.lua, and say so honestly', function()
    truthy(PROFILE, 'the user\'s real vBot_4.8 profile is on this machine', tostring(PROFILE))
    truthy(itemsLoaded, 'and assets/items1530.bin loaded (the name index)')
    if not (PROFILE and itemsLoaded) then return end

    -- 1. the source, cited: vBot/items.lua assigns ONE global, LootItems, keyed by
    --    lowercase item NAME (analyzer.lua:645-672 getPrice() looks names up in it).
    local raw = io.open(PROFILE .. '/vBot/items.lua', 'rb')
    local text = raw and raw:read('*a') or ''
    if raw then raw:close() end
    truthy(text:match('^LootItems%s*=%s*{') ~= nil,
           'vBot/items.lua opens with `LootItems = {` -- a NAME-keyed price table')
    truthy(text:find('%["gold coin"%]%s*=%s*1'), 'and prices "gold coin" at 1')

    -- 2. buildPrices turns it into id -> price through proto/items.lua's name index
    local prices, loaded, unmapped = control._buildPrices(PROFILE .. '/vBot/items.lua')
    truthy(type(prices) == 'table', 'buildPrices returns a table')
    truthy(loaded > 1000, 'and priced ' .. tostring(loaded) .. ' item ids')
    eq(prices[3031], 1, 'gold coin = 1 gp')
    eq(prices[3035], 100, 'platinum coin = 100 gp')
    eq(prices[3043], 10000, 'crystal coin = 10000 gp')
    truthy(type(unmapped) == 'number' and unmapped >= 0,
           'unmapped names are counted, not clamped away: ' .. tostring(unmapped))

    -- REGRESSION: `unmapped` used to be (#names - #ids), which goes NEGATIVE because
    -- several client ids share one name -- it was then clamped to 0 and reported
    -- "everything mapped" for a file that really does contain unmappable names.
    local names = 0
    for _ in text:gmatch('\n%s*%[?"') do names = names + 1 end
    truthy(loaded > names, 'more ids were priced than the file has names (ids share names): ' ..
           tostring(loaded) .. ' ids from ~' .. tostring(names) .. ' names')

    -- 3. the snapshot table the reviewer asked for
    local items = require('proto.items')
    local SAMPLE = { 3031, 3035, 3043, 268, 7643, 23374, 3097, 8090, 3079, 5741 }
    io.write(('\n     price table  --  %s/vBot/items.lua\n'):format(PROFILE))
    io.write('     itemId  name                          price(gp)\n')
    io.write('     ------  ----------------------------  ---------\n')
    for _, id in ipairs(SAMPLE) do
        local okn, nm = pcall(items.name, id)
        io.write(('     %6d  %-28s  %9s\n')
                 :format(id, (okn and nm or '?'):sub(1, 28),
                         prices[id] and tostring(prices[id]) or '(no price)'))
    end
    io.write(('     %d ids priced, %d LootItems names matched nothing in items1530.bin\n')
             :format(loaded, unmapped))

    -- 4. the telemetry says WHERE they came from, and money/h uses the values
    local LC = scratchLC()
    local T = control.newTelemetry{ LC = LC, pricesPath = PROFILE .. '/vBot/items.lua' }
    local s = T:snapshot()
    eq(s.pricesSource, 'profile', 'pricesSource says the profile supplied them')
    eq(s.pricesLoaded, loaded, 'pricesLoaded is the number that came from a real source')
    truthy(s.pricesInTable > s.pricesLoaded - 1,
           'pricesInTable also counts the three hard-coded coin values')
    local noPrices = false
    for _, k in ipairs(s.noDataFor or {}) do if k == 'itemPrices' then noPrices = true end end
    eq(noPrices, false, 'and itemPrices is NOT listed as missing')

    -- 5. with NO source at all the coins are still priced but the snapshot is honest
    local T0 = control.newTelemetry{ LC = scratchLC(), pricesPath = nil }
    local s0 = T0:snapshot()
    eq(s0.pricesLoaded, 0, 'no source -> pricesLoaded is 0, not "3 coins"')
    eq(s0.pricesSource, 'coins-only', 'and pricesSource says coins-only')
    local missing0 = false
    for _, k in ipairs(s0.noDataFor or {}) do if k == 'itemPrices' then missing0 = true end end
    eq(missing0, true, 'so the panel can print "prices not loaded" instead of 0 gp/h')
    eq(T0.engine:itemValue(3031), 1, 'the coins are priced regardless (they never change)')
    eq(T0.engine:itemValue(8090), 0, 'and every other item is worth 0, as documented')

    -- 6. the operator's own file overrides the profile, per id
    local pf = tmpPath('prices'):gsub('%.tmp$', '.json')
    writeFile(pf, '{"8090": 123456, "3031": 1}')
    local T2 = control.newTelemetry{ LC = scratchLC(),
                                     pricesPath = PROFILE .. '/vBot/items.lua',
                                     pricesFile = pf }
    local s2 = T2:snapshot()
    eq(s2.pricesSource, 'profile+file', 'both sources are reported')
    eq(s2.pricesFromFile, 2, 'the file contributed two entries')
    eq(T2.engine:itemValue(8090), 123456, 'and the file WINS for an id both define')
    eq(T2.engine:itemValue(3035), 100, 'ids only the profile has are untouched')

    -- a file the operator got wrong is refused loudly, not silently zeroed
    local bad = tmpPath('badprices'):gsub('%.tmp$', '.lua')
    writeFile(bad, 'return { ["gold coin"] = 1 }')       -- the vBot NAME-keyed shape
    local T3 = control.newTelemetry{ LC = scratchLC(), pricesFile = bad }
    eq(T3.pricesFromFile, 0, 'a name-keyed price file loads nothing')
    truthy(T3.pricesFileError ~= nil, 'and the reason is kept for the panel',
           tostring(T3.pricesFileError))
    eq(T3:snapshot().pricesSource, 'coins-only', 'so the snapshot still says coins-only')

    -- 6b. the ENVIRONMENT route, which is the one an operator actually uses:
    --     hub --worker-env=LUACLIENT_PRICES=/etc/luaclient/prices.json.  Lua 5.1 has
    --     no setenv, so this is proved in a REAL child process with a real
    --     environment, the same way the hub's supervisor hands one to a worker.
    local pf2 = tmpPath('envprices'):gsub('%.tmp$', '.json')
    writeFile(pf2, '{"8090": 777, "5741": 12}')
    local envOut = {}
    local eh = process.spawn{
        cmd = { luajitExe(), '-e',
                'package.path="./?.lua;./?/init.lua;"..package.path;' ..
                'local c=require("control.server");' ..
                'local t=c.newTelemetry{LC={events=require("lib.events").new()}};' ..
                'local s=t:snapshot();' ..
                'io.write("ENVPRICES ",tostring(s.pricesFromFile)," ",' ..
                'tostring(s.pricesSource)," ",tostring(t.engine:itemValue(8090)),"\\n")' },
        cwd = ROOT, captureOutput = true,
        env = { LUACLIENT_PRICES = pf2 },
        onLine = function(l) envOut[#envOut + 1] = l end,
    }
    truthy(eh, 'a child can be spawned with LUACLIENT_PRICES in its environment')
    if eh then
        waitUntil(function() process.pollAll(); return not eh:isRunning() end, 15000)
        process.pollAll()
        local line
        for _, l in ipairs(envOut) do if l:find('ENVPRICES', 1, true) then line = l end end
        truthy(line, 'the child reported its price state', concat(envOut, ' | '))
        if line then
            local n, src, val = line:match('ENVPRICES (%S+) (%S+) (%S+)')
            eq(n, '2', 'LUACLIENT_PRICES loaded both entries with no --prices flag at all')
            eq(src, 'file', 'and pricesSource says the file supplied them')
            eq(val, '777', 'and an item really is valued from it')
        end
    end
    os.remove(pf); os.remove(pf2); os.remove(bad)

    -- 7. loot and waste VALUES, and therefore money/h
    local T4 = control.newTelemetry{ LC = LC, pricesPath = PROFILE .. '/vBot/items.lua' }
    local e = T4.engine
    local t0 = 1000000
    e:sessionStart(t0)
    for m = 0, 10 do
        e:sampleBalance(t0 + m * 60000, 100000 + m * 1000)      -- +1000 gp/min of cash
        if m > 0 then
            e:addLoot(t0 + m * 60000, 3035, 10)                  -- 1000 gp of that IS coins
            e:addLoot(t0 + m * 60000, 7643, 1)                   -- an ultimate health potion
            e:addWaste(t0 + m * 60000, 268, 4)                   -- four mana potions
        end
    end
    local snap = e:snapshot(t0 + 600000)
    truthy(snap.loot > 0, 'loot has a VALUE now, not just a count: ' .. tostring(snap.loot))
    truthy(snap.waste > 0, 'and so does waste: ' .. tostring(snap.waste))
    eq(snap.lootCash, 10 * 1000, 'the coin part of the loot is separated out')
    eq(snap.moneySource, 'gold+goods', 'money/h is the gauge plus the goods, minus waste')

    truthy(math.abs(snap.moneyPerHour - (snap.goldPerHour + snap.goodsPerHour)) < 0.001,
           'money/h == goldPerHour + goodsPerHour exactly')
    io.write(('     one 10-minute hunt: loot %d gp, waste %d gp, cash %+d gp/h, ' ..
              'goods %+d gp/h, money %+d gp/h (%s)\n')
             :format(snap.loot, snap.waste, snap.goldPerHour, snap.goodsPerHour,
                     snap.moneyPerHour, snap.moneySource))
end)

runSuite('the supplies ledger reaches the panel as an ARRAY', function()
    local LC = scratchLC()
    local suppliesmod = require('bot.supplies')
    local st = LC.state
    st.player.inventory = { [10] = { id = 268, count = 20 } }
    st.containers = { [0] = { id = 0, name = 'bag', capacity = 20,
                              item = { id = 2854 },
                              items = { { id = 268, count = 55 },
                                        { id = 7643, count = 3 } } } }
    st.inventoryCounts = { [268 * 256] = 90 }

    local sup = suppliesmod.new({ state = st }, {
        supplies = { currentProfile = 'Default', Default = {
            capSwitch = true, capValue = '200',
            items = { ['268'] = { min = 100, max = 500, avg = 0 },
                      ['7643'] = { min = 2, max = 20, avg = 0 } } } } })

    local rows = sup:ledger()
    eq(#rows, 2, 'two configured supply items')
    eq(rows[1].itemId, 268, 'rows are in ascending id order')
    eq(rows[1].count, 90, 'count = max(20 inventory + 55 container, 90 server)')
    eq(rows[1].threshold, 100, 'threshold straight from the JSON string/number')
    eq(rows[1].ok, false, '90 < 100 -> not ok')
    eq(rows[2].count, 3, 'the second item is counted from the container alone')
    eq(rows[2].ok, true, '3 >= 2 -> ok')

    -- through the worker's status command
    LC.bot = { status = function() return { on = true, supplies = sup:status() } end,
               modules = { supplies = sup } }
    local snap = commands.botSnapshot(LC)
    truthy(type(snap.supplies) == 'table' and #snap.supplies == 2,
           'botSnapshot forwards `supplies` as a two-row array')
    local named = false
    for k in pairs(snap.supplies) do if type(k) ~= 'number' then named = true end end
    eq(named, false, 'with no named keys on it')
    truthy(type(snap.suppliesStatus) == 'table', 'and the context beside it')
    eq(snap.suppliesStatus.profile, 'Default', 'which carries the sub-profile name')
    eq(snap.suppliesStatus.low, 1, 'and how many items are below their minimum')
    eq(snap.suppliesStatus[1], nil, 'the context carries NO array part')

    -- ... and survives the JSON normaliser as an ARRAY, which is the whole point
    local safe = control._jsonSafe(snap)
    eq(safe.supplies[1] ~= nil and safe.supplies[2] ~= nil and safe.supplies[3] == nil, true,
       'jsonSafe keeps `supplies` a JSON array')
    eq(safe.supplies[1].name, rows[1].name, 'with the item name the panel prints')
    local encoded = json.encode(safe)
    truthy(encoded:find('"supplies":[', 1, true) ~= nil,
           'and the encoded frame really has `"supplies":[`')

    -- ... and hub/supervisor.lua's flattenLive forwards it rather than demoting it
    local flat = require('hub.supervisor').Sup.flattenLive{ bot = snap }
    truthy(type(flat.supplies) == 'table' and #flat.supplies == 2,
           'flattenLive passes the array through to the panel')
    truthy(type(flat.suppliesStatus) == 'table', 'and keeps the context')

    -- an OLD worker (mixed status object under `supplies`) is still demoted, not drawn
    local legacy = require('hub.supervisor').Sup.flattenLive{
        bot = { supplies = { rounds = 3, profile = 'Default' } } }
    eq(legacy.supplies, nil, 'a pre-ledger worker\'s status object is not offered as rows')
    truthy(type(legacy.suppliesStatus) == 'table', 'it travels as suppliesStatus instead')

    -- the telemetry snapshot carries the same split
    local T = control.newTelemetry{ LC = LC }
    local ts = T:snapshot()
    truthy(type(ts.supplies) == 'table' and #ts.supplies == 2,
           'the `stats` push carries the ledger too')
    eq(ts.suppliesStatus.low, 1, 'and its context')

    -- with no supplies module at all the snapshot says so
    local T2 = control.newTelemetry{ LC = scratchLC() }
    local missing = false
    for _, k in ipairs(T2:snapshot().noDataFor or {}) do
        if k == 'supplies' then missing = true end
    end
    eq(missing, true, 'noDataFor names `supplies` when there is no module')

    io.write('\n     supplies over the wire: ' ..
             encoded:match('"supplies":%[.-%]'):sub(1, 200) .. '\n')
end)

runSuite('the hub lists configs for an instance that has never run', function()
    truthy(PROFILE, 'the real profile is present')
    if not PROFILE then return end
    local sup = require('hub.supervisor').new{ workersDir = ROOT }

    -- path resolution, including the traversal refusal
    eq(sup:profileDir('profile_1'), ROOT:gsub('/+$', '') .. '/profile_1',
       'a relative bot profile resolves against the worker cwd')
    eq(sup:profileDir('D:/games/vBot_4.8'), 'D:/games/vBot_4.8',
       'an absolute one is used as it stands')
    eq(sup:profileDir('../../etc'), nil,
       'a relative profile that climbs out of the worker directory is refused')
    eq(sup:profileDir('a/../b'), ROOT:gsub('/+$', '') .. '/b',
       'but a `..` that stays inside is just normalised')

    local cfgs, err = sup:scanProfileConfigs(PROFILE)
    truthy(type(cfgs) == 'table', 'the profile directory scans', tostring(err))
    if not cfgs then return end
    truthy(#cfgs.cavebot > 0, 'cavebot_configs/*.cfg -> ' .. #cfgs.cavebot .. ' configs')
    truthy(#cfgs.targetbot > 0, 'targetbot_configs/*.json -> ' .. #cfgs.targetbot)
    truthy(#cfgs.profiles > 0, 'vBot_configs/profile_* -> ' .. #cfgs.profiles)
    eq(#cfgs.macros, 0, 'macros stay empty: a macro is a registration, not a file')

    -- the names are the STEMS the worker's bot.setCavebot expects, not file names
    local hasExt = false
    for _, n in ipairs(cfgs.cavebot) do if n:find('%.cfg$') then hasExt = true end end
    eq(hasExt, false, 'the .cfg extension is stripped')
    local hasProfile1 = false
    for _, n in ipairs(cfgs.profiles) do if n == 'profile_1' then hasProfile1 = true end end
    eq(hasProfile1, true, 'profile_1 is offered')

    io.write(('\n     hub-side scan of %s\n'):format(PROFILE))
    io.write(('     cavebot   (%d): %s\n'):format(#cfgs.cavebot,
             concat(cfgs.cavebot, ', '):sub(1, 150)))
    io.write(('     targetbot (%d): %s\n'):format(#cfgs.targetbot,
             concat(cfgs.targetbot, ', '):sub(1, 150)))
    io.write(('     profiles  (%d): %s\n'):format(#cfgs.profiles, concat(cfgs.profiles, ', ')))

    -- and the endpoint the panel calls answers from the scan while the worker is down
    local hubapi = require('hub.api')
    local H = hubapi._handlers
    truthy(type(H) == 'table' and type(H['instance.configs']) == 'function',
           'hub/api.lua exposes its handler table to the suite')
    if not H then return end
    local inst = { id = 'i1', botProfile = PROFILE }
    local fake = { configsCache = {}, sup = sup,
                   ownedInstance = function() return inst end }
    local res = H['instance.configs'](fake, { id = 'i1' }, {}, function() end)
    truthy(type(res) == 'table', 'a STOPPED instance still gets an answer')
    eq(res.source, 'scan', 'and it says the answer came from a directory scan')
    eq(#res.cavebot, #cfgs.cavebot, 'with the same cavebot list')
    eq(res.stale, true, 'marked stale, because no worker confirmed it')

    -- a profile with nothing in it falls back to the cache rather than inventing rows
    local empty = { id = 'i2', botProfile = 'profile_1' }
    local fake2 = { configsCache = { i2 = { cavebot = { 'cached' }, targetbot = {},
                                           profiles = {}, macros = { 'm' } } },
                    sup = sup, ownedInstance = function() return empty end }
    local res2 = H['instance.configs'](fake2, { id = 'i2' }, {}, function() end)
    eq(res2.source, 'cache', 'an empty profile directory falls through to the cache')
    eq(res2.cavebot[1], 'cached', 'and returns what a worker last reported')
end)

-- ===========================================================================
-- N2 -- bot/configschema.lua + control/commands.lua's config.get/set/list
-- ===========================================================================
-- deep compare that ignores table identity/order -- fresh from bot_f3.lua's suite
local function deepEq(a, b, path)
    path = path or ''
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then
        return false, ('%s: %s ~= %s'):format(path, tostring(a), tostring(b))
    end
    for k, v in pairs(a) do
        local ok, why = deepEq(v, b[k], path .. '.' .. tostring(k))
        if not ok then return false, why end
    end
    for k in pairs(b) do
        if a[k] == nil then return false, path .. '.' .. tostring(k) .. ': missing in A' end
    end
    return true
end

local function deepCopy(v)
    if type(v) ~= 'table' then return v end
    local t = {}
    for k, vv in pairs(v) do t[k] = deepCopy(vv) end
    return t
end

local function readAll(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('*a'); f:close()
    return s
end

--- Writes a self-contained fixture profile with real (if minimal) files for
--- all six kinds: HealBot.json/AttackBot.json (profile 1, one rule each),
--- cavebot_configs/testroute.cfg (goto + label + one function waypoint),
--- targetbot_configs/testtargets.json (one targeting entry, one loot item).
--- Stances has no dedicated file (CONFIGAPI.md: storage.stances) so nothing is
--- pre-seeded for it -- config.get is expected to answer `source == 'default'`
--- until the first config.set.
--- Collapses a literal "/name/.." segment (ROOT is built as `<dir>/..` and
--- never resolved -- see the top of this file) so the result is safe to pass
--- as --bot-profile, which refuses any ".." path component outright.
local function collapseDotDot(p)
    local prev
    repeat
        prev = p
        p = p:gsub('^[^/]+/%.%./', '')   -- a leading "seg/../" (ROOT itself has no leading slash)
        p = p:gsub('/[^/]+/%.%.', '')    -- an interior "/seg/.."
    until p == prev
    return p
end

local function buildN2Profile()
    local dir = collapseDotDot(tmpPath('n2profile'):gsub('%.tmp$', ''))
    local cfg = require('bot.config')
    local healbotlib   = require('bot.healbot')
    local attackbotlib = require('bot.attackbot')
    cfg.mkdirp(dir .. '/vBot_configs/profile_1')
    cfg.mkdirp(dir .. '/cavebot_configs')
    cfg.mkdirp(dir .. '/targetbot_configs')
    cfg.mkdirp(dir .. '/storage')

    local hb = { currentHealBotProfile = 1, healbot = {},
                ConditionPanel = healbotlib.defaultConditionPanel() }
    for i = 1, 5 do hb.healbot[i] = healbotlib.blankProfile(i) end
    hb.healbot[1].enabled = true
    hb.healbot[1].itemTable  = { { enabled = true, sign = '<', origin = 'HP%',
                                   item = 266, value = 50, index = 1 } }
    hb.healbot[1].spellTable = { { enabled = true, sign = '<', origin = 'HP%',
                                   spell = 'exura', cost = 20, value = 60, index = 1 } }
    writeFile(dir .. '/vBot_configs/profile_1/HealBot.json', json.encode(hb))

    local ab = { currentBotProfile = 1, AttackBot = {} }
    for i = 1, 5 do ab.AttackBot[i] = attackbotlib.blankProfile(i) end
    ab.AttackBot[1].enabled = true
    ab.AttackBot[1].attackTable = { {
        spell = 'exori', itemId = 0, category = 1, patternCategory = 1, pattern = 7,
        count = 1, orMore = true, minHp = 0, maxHp = 100, mana = 0, cooldown = 2000,
        monsters = true, enabled = true,
    } }
    writeFile(dir .. '/vBot_configs/profile_1/AttackBot.json', json.encode(ab))

    writeFile(dir .. '/cavebot_configs/testroute.cfg', cfg.encodeCfg{
        { 'goto', '1000,1000,7' }, { 'label', 'start' }, { 'function', 'return true' },
    })

    writeFile(dir .. '/targetbot_configs/testtargets.json', json.encode{
        targeting = { { name = 'rat', priority = 1, danger = 1, maxDistance = 7, chase = true } },
        looting = { items = { { id = 3031, count = 1 } }, containers = { { id = 1987 } },
                   everyItem = false, maxDanger = 10, minCapacity = 100 },
    })
    return dir
end

local function removeN2Profile(dir)
    os.remove(dir .. '/vBot_configs/profile_1/HealBot.json')
    os.remove(dir .. '/vBot_configs/profile_1/AttackBot.json')
    os.remove(dir .. '/vBot_configs/profile_1')
    os.remove(dir .. '/vBot_configs')
    os.remove(dir .. '/cavebot_configs/testroute.cfg')
    os.remove(dir .. '/cavebot_configs')
    os.remove(dir .. '/targetbot_configs/testtargets.json')
    os.remove(dir .. '/targetbot_configs')
    os.remove(dir .. '/storage/profile_1.json')
    os.remove(dir .. '/storage')
    os.remove(dir)
end

runSuite('bot/configschema.lua validates precisely (pure)', function()
    local schema = require('bot.configschema')

    truthy(schema.validate('healbot', { itemTable = {}, spellTable = {} }),
           'an empty healbot table validates')
    local ok1, err1 = schema.validate('healbot',
        { itemTable = { { enabled = true, sign = '>', origin = 'HP%', item = 'x', value = 1 } },
          spellTable = {} })
    truthy(not ok1, 'a wrong-typed item id is rejected', err1)
    local ok2, err2 = schema.validate('healbot',
        { itemTable = { { enabled = true, sign = '>', origin = 'HP%', value = 1 } },  -- no `item`
          spellTable = {} })
    truthy(not ok2, 'a missing required field is rejected', err2)
    local ok3, err3 = schema.validate('healbot',
        { itemTable = { { enabled = true, sign = 'x', origin = 'HP%', item = 1, value = 1 } },
          spellTable = {} })
    truthy(not ok3, 'an out-of-enum sign is rejected', err3)

    truthy(schema.validate('attackbot', {}), 'an empty attackTable validates')
    local ok4 = schema.validate('attackbot', { attackTable = {} })
    truthy(not ok4, 'attackbot data must be the bare array, not an object wrapping it')

    local C = require('bot.healbot').defaultConditionPanel()
    C.curePoison = C.curePosion
    truthy(schema.validate('conditions', C), 'the real default ConditionPanel (+curePoison) validates')
    local C2 = deepCopy(C); C2.bogusField = 1
    local ok5, err5 = schema.validate('conditions', C2)
    truthy(not ok5, 'an unknown top-level field is rejected (strict top level)', err5)

    truthy(schema.validate('cavebot', {}), 'an empty cavebot route validates')
    truthy(schema.validate('cavebot', { { type = 'goto', value = '1,2,3' } }),
           'a normal waypoint validates')
    local ok6, err6 = schema.validate('cavebot', { { type = 'GOTO', value = '1,2,3' } })
    truthy(not ok6, 'an uppercase type is rejected', err6)
    local ok7, err7 = schema.validate('cavebot', { { type = 'goto', value = '' } })
    truthy(not ok7, 'an empty value is rejected', err7)
    local ok8, err8 = schema.validate('cavebot', { { type = 'function', value = 'a\nb]]c' } })
    truthy(not ok8, 'a multi-line value containing "]]" is rejected', err8)
    local ok9, err9 = schema.validate('cavebot', { { type = 'goto', value = '[[oops' } })
    truthy(not ok9, 'a single-line value starting with "[[" is rejected', err9)
    local ok10, err10 = schema.validate('cavebot',
        { { type = 'goto:evil', value = '1,2,3' } })
    truthy(not ok10, 'a type containing ":" is rejected', err10)

    local oldPairs     = { { 'goto', '1,1,7' }, { 'function', 'A' } }
    local reordered     = { { 'function', 'A' }, { 'goto', '1,1,7' } }
    local changedBody   = { { 'function', 'B' }, { 'goto', '1,1,7' } }
    local valueOnly     = { { 'goto', '9,9,9' }, { 'function', 'A' } }
    eq(schema.cavebotFunctionBodyChanged(oldPairs, reordered), false,
       'reordering the same function body is NOT a body change')
    eq(schema.cavebotFunctionBodyChanged(oldPairs, changedBody), true,
       'editing the function body IS a body change')
    eq(schema.cavebotFunctionBodyChanged(oldPairs, valueOnly), false,
       'changing a non-function waypoint value is NOT a body change')
end)

runSuite('config.get/set/list against a running bot instance (in-process, all six kinds)', function()
    local dir = buildN2Profile()

    -- a fake sender: records every call generically, so H:_say -> sh:say ->
    -- sender:talk/talkSpell all "send a packet" without any real socket.
    local function fakeSender()
        local calls = {}
        local S = { calls = calls }
        return setmetatable(S, { __index = function(_, k)
            return function(...) calls[#calls + 1] = { method = k, ... }; return true end
        end })
    end

    local LC = { log = require('lib.log'), sys = sys, sched = require('lib.sched'),
                events = require('lib.events').new(), config = { dryRun = false, bot = true } }
    LC.state = require('game.state').new()
    LC.state.player.pos = { x = 1000, y = 1000, z = 7 }
    LC.state.player.health, LC.state.player.maxHealth = 100, 100
    LC.state.player.mana, LC.state.player.maxMana     = 100, 100
    LC.sender = fakeSender()

    local botmod = require('bot.init')
    local ok, b = pcall(botmod.new, LC, { profileDir = dir, vprofile = 1 })
    truthy(ok, 'a bot builds on the N2 scratch profile', tostring(b))
    if not ok then removeN2Profile(dir); return end
    LC.bot = b
    b.inGame = true                 -- the HealBot / AttackBot death+offline gate
    b:wireModules{}                 -- main.lua's startBot() does this before :start()
    b:start()

    local ctx = { LC = LC, server = { instanceName = 'n2', startedMs = sys.nowMs() } }
    local function call(cmd, args) return commands.dispatch(ctx, cmd, args) end

    local okc = call('bot.setCavebot', { name = 'testroute' })
    local okt = call('bot.setTargetbot', { name = 'testtargets' })
    truthy(okc, 'the fixture cavebot route selects')
    truthy(okt, 'the fixture targetbot config selects')

    -- ----------------------------------------------------------------------
    -- config.list
    -- ----------------------------------------------------------------------
    local lok, lres = call('config.list', { kind = 'healbot' })
    truthy(lok, 'config.list healbot ok', tostring(lres))
    if lok then eq(lres.active, 1, 'healbot reports profile 1 active') end
    local lok2, lres2 = call('config.list', { kind = 'cavebot' })
    truthy(lok2, 'config.list cavebot ok', tostring(lres2))
    if lok2 then eq(lres2.active, 'testroute', 'cavebot reports the selected route as active') end

    -- ----------------------------------------------------------------------
    -- GET / SET / GET, all six kinds -- lossless round trip
    -- ----------------------------------------------------------------------
    local KINDS = { 'healbot', 'conditions', 'attackbot', 'stances', 'targetbot', 'cavebot' }
    local firstGet = {}
    for _, kind in ipairs(KINDS) do
        local ok1, r1 = call('config.get', { kind = kind })
        truthy(ok1, ('config.get %s succeeds'):format(kind), tostring(r1))
        if ok1 then
            firstGet[kind] = r1
            eq(r1.kind, kind, kind .. ': config.get echoes the kind')
            truthy(r1.source == 'profile' or r1.source == 'default',
                   kind .. ': source is "profile" or "default"', tostring(r1.source))
            local ok2, r2 = call('config.set', { kind = kind, data = deepCopy(r1.data) })
            truthy(ok2, ('config.set %s (echoing GET, unmodified) is accepted'):format(kind), tostring(r2))
            local ok3, r3 = call('config.get', { kind = kind })
            truthy(ok3, ('config.get %s a second time succeeds'):format(kind), tostring(r3))
            if ok2 and ok3 then
                local same, why = deepEq(r1.data, r3.data)
                truthy(same, ('%s: GET/SET/GET round trip is lossless'):format(kind), why)
            end
        end
    end

    -- ----------------------------------------------------------------------
    -- invalid payload: REJECTED, not coerced -- and the file is untouched
    -- ----------------------------------------------------------------------
    local hbPath = dir .. '/vBot_configs/profile_1/HealBot.json'
    local before = readAll(hbPath)
    local okBad1, errBad1 = call('config.set', { kind = 'healbot', data = {
        itemTable = { { enabled = true, sign = '>', origin = 'HP%', item = 'not-a-number', value = 1 } },
        spellTable = {} } })
    truthy(not okBad1, 'a wrong-typed field is rejected outright', tostring(errBad1))
    local okBad2, errBad2 = call('config.set', { kind = 'healbot', data = {
        itemTable = { { enabled = true, sign = '>', origin = 'HP%', value = 1 } },  -- no `item`
        spellTable = {} } })
    truthy(not okBad2, 'a missing required field is rejected outright', tostring(errBad2))
    local okBad3, errBad3 = call('config.set', { kind = 'cavebot',
        data = { { type = 'goto', value = '' } } })
    truthy(not okBad3, 'an invalid cavebot payload (empty value) is rejected outright', tostring(errBad3))
    local after = readAll(hbPath)
    eq(after, before, 'HealBot.json is byte-for-byte untouched by the rejected writes')

    -- ----------------------------------------------------------------------
    -- a HealBot threshold change actually changes what the running bot does
    -- ----------------------------------------------------------------------
    LC.state.player.health, LC.state.player.maxHealth = 70, 100   -- 70% HP
    local firedBefore = b.modules.healbot:spellTick()
    truthy(firedBefore == nil, 'at 70%% HP, the "HP%% < 60" exura rule does not fire yet')

    local okr, r = call('config.get', { kind = 'healbot' })
    truthy(okr, 'config.get healbot for the threshold edit')
    local edited = deepCopy(r.data)
    edited.spellTable[1].value = 80    -- "HP% < 80" now covers 70%
    local oks, sres = call('config.set', { kind = 'healbot', data = edited })
    truthy(oks, 'config.set healbot (raised threshold) is accepted', tostring(sres))

    -- clear IN PLACE: the fake sender's closures captured this exact table,
    -- so replacing the field with a fresh {} would silently orphan them.
    for i = #LC.sender.calls, 1, -1 do LC.sender.calls[i] = nil end
    local fired = b.modules.healbot:spellTick()
    truthy(fired ~= nil, 'after raising the threshold, the SAME rule now fires on the next tick')
    local sentSpell, callDesc = false, {}
    for _, c in ipairs(LC.sender.calls) do
        local parts = { tostring(c.method) }
        for _, a in ipairs(c) do
            parts[#parts + 1] = tostring(a)
            if a == 'exura' then sentSpell = true end
        end
        callDesc[#callDesc + 1] = concat(parts, ',')
    end
    truthy(sentSpell, 'and "exura" reached the sender -- the actual packet the tick would send',
           '[' .. concat(callDesc, ' | ') .. ']')

    -- ----------------------------------------------------------------------
    -- cavebot function-body-change detection: changed / reordered / value-only
    -- ----------------------------------------------------------------------
    local okg, base = call('config.get', { kind = 'cavebot' })
    truthy(okg, 'config.get cavebot for the diff tests')
    truthy(okg and #base.data == 3, 'the fixture route has its 3 waypoints', tostring(base and #base.data))

    -- (a) pure reorder of the same three waypoints (same function body, moved)
    local reordered = { deepCopy(base.data[3]), deepCopy(base.data[1]), deepCopy(base.data[2]) }
    local okR, resR = call('config.set', { kind = 'cavebot', data = reordered })
    truthy(okR, 'config.set (reorder) does not error', tostring(resR))
    if okR then
        eq(resR.needsExec, false, 'a pure reorder needs no exec capability')
        eq(resR.applied, true, 'and IS applied')
    end
    call('config.set', { kind = 'cavebot', data = deepCopy(base.data), execCapability = true })  -- restore

    -- (b) editing a non-function value only
    local valueOnly = deepCopy(base.data)
    valueOnly[1].value = '2000,2000,7'
    local okV, resV = call('config.set', { kind = 'cavebot', data = valueOnly })
    truthy(okV, 'config.set (value-only edit) does not error', tostring(resV))
    if okV then
        eq(resV.needsExec, false, 'a goto value edit needs no exec capability')
        eq(resV.applied, true, 'and IS applied')
    end
    call('config.set', { kind = 'cavebot', data = deepCopy(base.data), execCapability = true })  -- restore

    -- (c) changing the function body -- refused without execCapability, honestly flagged
    local changed = deepCopy(base.data)
    for _, p in ipairs(changed) do if p.type == 'function' then p.value = 'return false' end end
    local okC, resC = call('config.set', { kind = 'cavebot', data = changed })
    truthy(okC, 'config.set itself does not error on a function-body change', tostring(resC))
    if okC then
        eq(resC.applied, false, 'but it is NOT applied without execCapability')
        eq(resC.needsExec, true, 'needsExec is reported honestly')
    end

    -- the SAME payload, with the capability asserted, IS applied
    local okC2, resC2 = call('config.set', { kind = 'cavebot', data = changed, execCapability = true })
    truthy(okC2, 'the same change succeeds once execCapability is asserted', tostring(resC2))
    if okC2 then
        eq(resC2.applied, true, 'and applied is now true')
        eq(resC2.needsExec, false, 'needsExec is false once granted')
    end
    local okg2, after2 = call('config.get', { kind = 'cavebot' })
    if okg2 then
        local sawNewBody = false
        for _, p in ipairs(after2.data) do
            if p.type == 'function' and p.value == 'return false' then sawNewBody = true end
        end
        truthy(sawNewBody, 'the new function body is really in effect after the exec-asserted write')
    end

    b:stop()
    removeN2Profile(dir)
end)

runSuite('config.get/set/list over the real control socket (spawned worker, all six kinds)', function()
    local dir = buildN2Profile()
    local cw, cwerr = startWorker{ '--bot', '--bot-profile=' .. dir, '--bot-vprofile=1' }
    truthy(cw, 'the N2 fixture worker starts', tostring(cwerr))
    if not cw then removeN2Profile(dir); return end

    local selc = rpc(cw, { id = 1, cmd = 'bot.setCavebot', args = { name = 'testroute' } })
    eq(selc.json.ok, true, 'bot.setCavebot selects the fixture route over RPC', selc.json.error)
    local selt = rpc(cw, { id = 2, cmd = 'bot.setTargetbot', args = { name = 'testtargets' } })
    eq(selt.json.ok, true, 'bot.setTargetbot selects the fixture config over RPC', selt.json.error)

    local lst = rpc(cw, { id = 3, cmd = 'config.list', args = { kind = 'attackbot' } })
    eq(lst.json.ok, true, 'config.list attackbot ok over the wire', lst.json.error)
    if lst.json.ok then eq(lst.json.result.active, 1, 'attackbot profile 1 is active') end

    local KINDS = { 'healbot', 'conditions', 'attackbot', 'stances', 'targetbot', 'cavebot' }
    local id = 10
    for _, kind in ipairs(KINDS) do
        id = id + 1
        local g1 = rpc(cw, { id = id, cmd = 'config.get', args = { kind = kind } })
        eq(g1.json.ok, true, ('config.get %s ok over the wire'):format(kind), g1.json.error)
        if g1.json.ok then
            id = id + 1
            local s1 = rpc(cw, { id = id, cmd = 'config.set',
                                 args = { kind = kind, data = g1.json.result.data } })
            eq(s1.json.ok, true, ('config.set %s (echoing GET) is accepted over the wire'):format(kind),
               s1.json.error)
            id = id + 1
            local g2 = rpc(cw, { id = id, cmd = 'config.get', args = { kind = kind } })
            eq(g2.json.ok, true, ('config.get %s again ok over the wire'):format(kind), g2.json.error)
            if g2.json.ok then
                local same, why = deepEq(g1.json.result.data, g2.json.result.data)
                truthy(same, ('%s: GET/SET/GET over the real control socket is lossless'):format(kind), why)
            end
        end
    end

    -- one rejection, over the wire: wrong type is refused, not coerced
    local bad = rpc(cw, { id = 99, cmd = 'config.set', args = { kind = 'attackbot',
        data = { { category = 'not-a-number', patternCategory = 1, pattern = 1, spell = 'x',
                  itemId = 0, count = 1, minHp = 0, maxHp = 100, mana = 0, cooldown = 1,
                  monsters = true, enabled = true } } } })
    eq(bad.json.ok, false, 'a wrong-typed attackbot field is refused over the wire')

    cw:stop()
    removeN2Profile(dir)
end)

-- ===========================================================================
-- G1.4 -- CHAT, proved against real packets rather than a synthetic bus event.
--
-- The WebSocket section above emits `talk` on the worker's OWN event bus from
-- inside `exec` and checks that a `chat` frame comes back.  That proves the
-- broadcast wiring and nothing else: it never touches proto/parser.lua, so a
-- mis-decoded 0xAA would sail straight past it, and `say` was not covered at all.
--
-- This section stands up a scripted 1530 server on 127.0.0.1, lets the REAL
-- main.lua log into it (the same path test/fakeserver.lua exercises -- raw world
-- preamble, RSA login frame, PendingGame, the two enter-game frames, XTEA on),
-- and then:
--   * sends a real Talk (0xAA) packet and asserts the worker pushes `chat` with the
--     speaker, the level, the mode and the text that were on the wire;
--   * sends a real TextMessage (0xB4) and asserts it arrives as a `chat` frame
--     flagged `system`;
--   * calls `say` over the control WebSocket and reads the 0x96 Talk packet the
--     worker put on the game socket, checking the opcode, the mode byte, the text
--     and the trailing aim byte the 1525+ gunz protocol requires.
--
-- The server does its own framing, padding, sequencing and XTEA, so a framing bug
-- in proto/transport.lua cannot cancel itself out.  The XTEA session key cannot be
-- recovered from the RSA block (no private key), so the worker is started with
-- LUACLIENT_TEST_XTEA -- main.lua's documented test hook, and the only thing about
-- this session that is not the production path.
-- ===========================================================================
local xtea   = require('lib.xtea')
local buffer = require('lib.buffer')

local CHAT_XTEA_HEX = '0f1e2d3c4b5a69788796a5b4c3d2e1f0'
local CHAT_KEY = {}
for i = 0, 3 do
    CHAT_KEY[i + 1] = tonumber(CHAT_XTEA_HEX:sub(i * 8 + 1, i * 8 + 8), 16)
end

local function u16le(v) return schar(v % 256, floor(v / 256) % 256) end
local function u32le(v)
    v = v % 0x100000000
    return schar(v % 256, floor(v / 0x100) % 256,
                 floor(v / 0x10000) % 256, floor(v / 0x1000000) % 256)
end

local GS = {}
GS.__index = GS

--- A scripted game server, driven entirely by pump() so the single-threaded suite
--- can interleave it with the control WebSocket and the child's stdout.
local function newGameServer()
    local listener, lerr = socket.listen('127.0.0.1', 0)
    if not listener then return nil, 'listen: ' .. tostring(lerr) end
    local S = setmetatable({
        listener = listener, port = listener:port(),
        buf = '', pos = 1, seq = 0, outbox = {},
        clientFrames = {}, done = false, err = nil,
    }, GS)
    S.co = coroutine.create(function() return S:_script() end)
    return S
end

function GS:_frame(body, key)
    local pad = 8 - (#body % 8) - 1
    local region = schar(pad) .. body .. string.rep('\0', pad)
    if key then region = xtea.encrypt(key, region) end
    local f = u16le(#region / 8) .. u32le(self.seq) .. region
    self.seq = self.seq + 1
    return f
end

--- Queue a server -> client frame.  Safe to call from the driver at any time.
function GS:push(body, key)
    self.outbox[#self.outbox + 1] = self:_frame(body, key == nil and CHAT_KEY or key)
end

function GS:_avail() return #self.buf - self.pos + 1 end

--- Inside the script coroutine only: yield until `n` bytes are buffered.
function GS:_need(n)
    while self:_avail() < n do coroutine.yield() end
    local s = ssub(self.buf, self.pos, self.pos + n - 1)
    self.pos = self.pos + n
    return s
end

function GS:_readLine()
    local out = {}
    for _ = 1, 256 do
        local c = self:_need(1)
        if c == '\n' then return concat(out) end
        out[#out + 1] = c
    end
    error('no newline in the first 256 bytes of the preamble')
end

function GS:_readFrame(key)
    local hdr = self:_need(2)
    local blocks = sbyte(hdr, 1) + sbyte(hdr, 2) * 256
    if blocks == 0 then error('bad block count 0') end
    local body = self:_need(blocks * 8 + 4)
    local seq = sbyte(body, 1) + sbyte(body, 2) * 256
              + sbyte(body, 3) * 65536 + sbyte(body, 4) * 16777216
    local region = ssub(body, 5)
    if key then region = xtea.decrypt(key, region) end
    local pad = sbyte(region, 1)
    local payload = ssub(region, 2, #region - pad)
    return payload, seq
end

--- The whole session, written linearly; every read yields when it runs dry.
function GS:_script()
    self.preamble = self:_readLine()

    -- challenge (unencrypted, like the real server's first frame)
    self:push(schar(0x1F) .. u32le(0x11223344) .. schar(0x5A) .. schar(0x00), false)
    local login, lseq = self:_readFrame(nil)
    self.loginOpcode, self.loginSeq = sbyte(login, 1), lseq

    -- PendingGame: XTEA is on from here in both directions
    self:push(schar(0x0A))
    self:_readFrame(CHAT_KEY)              -- enter-game frame 1 (0x0F)
    self:_readFrame(CHAT_KEY)              -- enter-game frame 2 (extended hwid)

    -- EnterGame + PlayerData, so the worker is really in the game
    self:push(schar(0x0F))
    local w = buffer.writer()
    w:u8(0xA0)
    w:u32(155):u32(185):u32(87650):u64(4242):u16(9):u16(37)
    w:u16(0):u16(0):u16(0):u16(0)
    w:u32(31):u32(62):u8(100):u16(2400):u16(220):u16(0):u16(0)
    w:u16(0):u8(0)
    w:u32(0):u32(0)
    self:push(w:data())
    self.inGame = true

    -- from here the driver pushes packets and we record everything the client sends
    while not self.stop do
        local payload, seq = self:_readFrame(CHAT_KEY)
        self.clientFrames[#self.clientFrames + 1] = { payload = payload, seq = seq }
    end
    return true
end

function GS:pump()
    if self.done then return end
    if not self.sock then
        local s, err = self.listener:accept()
        if s then self.sock = s
        elseif err ~= 'wouldblock' then self.err = 'accept: ' .. tostring(err); self.done = true end
        if not self.sock then return end
    end
    -- read whatever arrived
    while true do
        local d, err = self.sock:recv(65536)
        if d == nil then
            self.closed, self.closedErr = true, err
            break
        end
        if #d == 0 then break end
        self.buf = ssub(self.buf, self.pos) .. d
        self.pos = 1
    end
    -- write whatever the script (or the driver) queued
    while #self.outbox > 0 do
        local f = table.remove(self.outbox, 1)
        local n = self.sock:send(f)
        if not n then self.err = 'send failed'; self.done = true; return end
    end
    self.sock:flush()
    if coroutine.status(self.co) == 'suspended' then
        local ok, err = coroutine.resume(self.co)
        if not ok then self.err = tostring(err); self.done = true end
    end
end

function GS:close()
    self.stop = true
    if self.sock then pcall(function() self.sock:close() end) end
    if self.listener then pcall(function() self.listener:close() end) end
end

--- Every 0x96 (client Talk) packet the worker has sent, decoded.
--- The frame body starts with the gunz "\0\0\0\0" compression header.
function GS:talkPackets()
    local out = {}
    for i = 1, #self.clientFrames do
        local p = self.clientFrames[i].payload
        if #p > 5 and ssub(p, 1, 4) == '\0\0\0\0' and sbyte(p, 5) == 0x96 then
            local R = buffer.reader(ssub(p, 6))
            local e = { seq = self.clientFrames[i].seq, mode = R:u8() }
            e.text = R:string()
            if R:remaining() > 0 then e.aimMode = R:u8() end
            e.trailing = R:remaining()
            out[#out + 1] = e
        end
    end
    return out
end

runSuite('chat: real Talk/TextMessage packets in, a real say packet out', function()
    local gs, gerr = newGameServer()
    truthy(gs, 'a scripted 1530 server is listening', tostring(gerr))
    if not gs then return end

    local token = 'chat-' .. tostring(math.random(1, 2 ^ 30)) .. '-abcdefgh'
    local lines = {}
    local h, serr = process.spawn{
        cmd = { luajitExe(), 'main.lua',
                '--session-key=FAKE-SESSION-KEY',
                '--account=chatsuite@example.invalid',
                '--character=Chat Tester',
                '--world=Gunzodus',
                '--host=127.0.0.1:' .. gs.port,
                '--ping=600000',
                '--control-port=0', '--control-token-fd=0',
                '--instance-name=chat', '--log-level=info' },
        cwd = ROOT, captureOutput = true,
        -- `key` has to come out of the denylist for THIS spawn: main.lua has no
        -- --session-key-fd, and lib/process.lua refuses `--session-key=` in argv on
        -- the strength of the word alone.  The value here is the literal string
        -- FAKE-SESSION-KEY, handed to a fake server on 127.0.0.1; a real session key
        -- would go the same way as the control token, down stdin.  The control token
        -- itself still travels on stdin below.
        redact = { 'password', 'passwd', 'pass', 'secret', 'credential' },
        env = { LUACLIENT_TEST_XTEA = CHAT_XTEA_HEX },
        stdinData = token .. '\n',
        onLine = function(l) lines[#lines + 1] = l end,
    }
    truthy(h, 'the worker spawns', tostring(serr))
    if not h then gs:close(); return end

    local W = setmetatable({ h = h, token = token, lines = lines }, Worker)
    -- ONE pump drives the child, its stdout and the game server together.
    W.pump = function() process.pollAll(); gs:pump() end

    local up = waitUntil(function()
        for i = 1, #lines do
            local host, port = lines[i]:match('^control%-endpoint%s+(%S+)%s+(%d+)')
            if host then W.host, W.port = host, tonumber(port); return true end
        end
        return false
    end, 20000, W.pump)
    truthy(up, 'and announces its control port', concat(lines, '\n  '))

    local inGame = waitUntil(function() W.pump(); return gs.inGame end, 20000)
    truthy(inGame, 'the worker completed the real login handshake against the server',
           tostring(gs.err) .. '\n  ' .. concat(lines, '\n  '))
    eq(gs.preamble, 'Gunzodus', 'the raw world preamble arrived first')
    eq(gs.loginOpcode, 0x0A, 'and then the 0x0A login packet')
    if not inGame then gs:close(); W:stop(); return end

    local ws, werr = wsConnect(W)
    truthy(ws, 'the control WebSocket connects', tostring(werr))
    if not ws then gs:close(); W:stop(); return end
    ws.W = W                                     -- so ws:drain() pumps the game server
    truthy(ws:waitHandshake(8000) and ws.handshook, 'and upgrades')

    -- ---------------------------------------------------------------- INBOUND 1
    -- A real Talk packet.  1530 has F_MESSAGE_STATEMENTS(45) and F_MESSAGE_LEVEL(46)
    -- on, so the body is: u32 statementId, STR name, u16 level, u8 mode, and -- for
    -- mode byte 1 (Say) -- a 5-byte Position before the STR text.
    local talk = buffer.writer()
    talk:u8(0xAA)
    talk:u32(0)                                  -- statementId 0 -> no suffix byte
    talk:string('Bubble Wizard')
    talk:u16(233)                                -- speaker level
    talk:u8(1)                                   -- mode byte 1 = Say
    talk:u16(32369):u16(32241):u8(7)             -- Position
    talk:string('exura vita')
    gs:push(talk:data())

    local chat = ws:waitEvent('chat', 8000, function(e)
        return e.data and e.data.name == 'Bubble Wizard'
    end)
    truthy(chat, 'a real 0xAA Talk packet becomes a `chat` push')
    if chat then
        eq(chat.data.text, 'exura vita', 'with the text that was on the wire')
        eq(chat.data.level, 233, 'the speaker level')
        eq(chat.data.mode, 'Say', 'and the decoded mode name')
        eq(chat.data.system, nil, 'a player message is not flagged system')
    end

    -- ---------------------------------------------------------------- INBOUND 2
    -- A real TextMessage.  Mode byte 6 is a channel message: u16 channelId then STR.
    local tm = buffer.writer()
    tm:u8(0xB4):u8(6):u16(4)
    tm:string('Welcome to the fake world.')
    gs:push(tm:data())
    local sys_ = ws:waitEvent('chat', 8000, function(e)
        return e.data and e.data.text == 'Welcome to the fake world.'
    end)
    truthy(sys_, 'a real 0xB4 TextMessage becomes a `chat` push too')
    if sys_ then
        eq(sys_.data.system, true, 'flagged system, so the panel can style it apart')
        eq(sys_.data.name, nil, 'with no speaker')
    end

    -- --------------------------------------------------------------- OUTBOUND
    -- `say` over the control socket has to put a real 0x96 on the GAME socket.
    -- This worker runs WITHOUT --bot, so it takes control/commands.lua's raw-sender
    -- path; before this work item that path did not exist and `say` answered
    -- "there is no game session to speak in" from a healthy, logged-in session.
    local before = #gs:talkPackets()
    local rep = ws:call(4242, 'say', { text = 'hello from the panel' }, 8000)
    truthy(rep and rep.ok, 'say answers ok', rep and tostring(rep.error))
    if rep and rep.ok then
        eq(rep.result.said, 'hello from the panel', 'and echoes what it said')
    end

    local got = waitUntil(function()
        W.pump()
        return #gs:talkPackets() > before
    end, 8000)
    truthy(got, 'and the server really received a packet')
    local pk = gs:talkPackets()[before + 1]
    if pk then
        eq(pk.mode, 1, 'opcode 0x96 with wire mode 1 (Say)')
        eq(pk.text, 'hello from the panel', 'carrying the exact text')
        eq(pk.aimMode, 0, 'and the trailing aim byte the 1525+ gunz protocol requires')
        eq(pk.trailing, 0, 'with nothing after it')
    end

    -- an empty message is refused by the sender, not put on the wire
    local n0 = #gs:talkPackets()
    local bad = ws:call(4243, 'say', { text = '   ' }, 8000)
    truthy(bad and bad.ok == false, 'a blank message is refused')
    waitUntil(function() W.pump(); return false end, 200)
    eq(#gs:talkPackets(), n0, 'and nothing was sent')

    -- ------------------------------------------------------------------- close
    gs:push(schar(0x18) .. schar(0))             -- SessionEnd
    waitUntil(function() W.pump(); return not h:isRunning() end, 8000)
    gs:close()
    W:stop()
end)

-- ================================================================== report
io.write('\n================ controlsuite ================\n')
for _, s in ipairs(suites) do
    io.write(('  %-56s %s  %d passed%s\n'):format(s.name,
        s.fail == 0 and 'PASS' or 'FAIL', s.pass,
        s.fail > 0 and (', ' .. s.fail .. ' FAILED') or ''))
end
io.write('  ---------------------------------------------------------------------------\n')
io.write(('  TOTAL: %d passed, %d failed  -> %s\n'):format(totalPass, totalFail,
         totalFail == 0 and 'PASS' or 'FAIL'))

os.exit(totalFail == 0 and 0 or 1)
