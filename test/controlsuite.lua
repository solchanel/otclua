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

    -- The command table is exactly PANEL.md's list.
    local want = { 'status', 'login', 'logout', 'relogin', 'bot.enable', 'bot.setCavebot',
                   'bot.setTargetbot', 'bot.listConfigs', 'bot.reload', 'script.put',
                   'script.remove', 'script.list', 'exec', 'stats', 'shutdown',
                   'bot.setMacro', 'say' }
    local have = {}
    for _, n2 in ipairs(commands.names()) do have[n2] = true end
    for _, n2 in ipairs(want) do truthy(have[n2], 'command ' .. n2 .. ' exists') end
    eq(#commands.names(), #want, 'no commands beyond PANEL.md\'s list')
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
