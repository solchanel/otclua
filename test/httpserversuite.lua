--[[============================================================================
test/httpserversuite.lua -- lib/httpserver.lua

Unit tests for the parsing helpers plus end-to-end tests against a REAL loopback
server driven by lib/socket.lua clients on lib/sched.lua's reactor:

    luajit test/httpserversuite.lua                (from D:/Claude/otclient_web/luaclient)
    luajit test/httpserversuite.lua --bench-ms=3000

Covered: GET / POST / HEAD, query parsing, chunked request bodies, keep-alive with
several requests on one connection and a per-connection request limit, an idle
timeout, byte-at-a-time delivery, an oversized header block (431) including one
that arrives in a single segment, an oversized Content-Length body and an oversized
chunked body (413), an unsupported Transfer-Encoding (501), 100-continue, a handler
that throws (500 + logged), a double send (logged, one response on the wire), path
traversal refusals, 404, ETag / If-None-Match revalidation, a slow client that must
not stall the others, the per-connection write-backlog cap, 20 simultaneous clients
and a requests/second measurement.

Everything binds 127.0.0.1 on an ephemeral port; nothing leaves the machine.
Exits non-zero if any check fails.
============================================================================]]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. package.path
end

local httpserver = require('lib.httpserver')
local socket     = require('lib.socket')
local sched      = require('lib.sched')
local sys        = require('lib.sys')
local json       = require('lib.json')

local CRLF = string.char(13, 10)
local BENCH_MS = 1500
for i = 1, #arg do
    local v = tostring(arg[i]):match('^%-%-bench%-ms=(%d+)$')
    if v then BENCH_MS = tonumber(v) end
end

-- =========================================================== tiny framework
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
    if #g > 160 then g = g:sub(1, 157) .. '...' end
    if #w > 160 then w = w:sub(1, 157) .. '...' end
    return check(false, desc, ('got %q, want %q'):format(g, w))
end

local function runSuite(name, fn)
    suite(name)
    local ok, err = pcall(fn)
    if not ok then
        cur.fail, totalFail = cur.fail + 1, totalFail + 1
        io.write('    FAIL  suite crashed: ', tostring(err), '\n')
    end
end

local function note(fmt, ...) notes[#notes + 1] = string.format(fmt, ...) end

-- ==================================================== capturing log sink ====
local function newLog()
    local rec = { lines = {} }
    local function mk(level)
        return function(fmt, ...)
            local ok, s = pcall(string.format, tostring(fmt), ...)
            rec.lines[#rec.lines + 1] = level .. ': ' .. (ok and s or tostring(fmt))
        end
    end
    rec.debug, rec.info, rec.warn, rec.error = mk('debug'), mk('info'), mk('warn'), mk('error')
    function rec:find(pat)
        for i = 1, #self.lines do if self.lines[i]:find(pat) then return self.lines[i] end end
        return nil
    end
    return rec
end

-- ========================================================= test HTTP client =
local Client = {}
Client.__index = Client

local liveClients = {}

local function newClient(port, opts)
    opts = opts or {}
    local s, err = socket.tcp()
    if not s then error('socket.tcp: ' .. tostring(err)) end
    if opts.rcvbuf then s:setBufferSize(nil, opts.rcvbuf) end
    local ok, cerr = s:connect('127.0.0.1', port)
    if not ok then error('connect: ' .. tostring(cerr)) end
    local c = setmetatable({
        sock = s, rx = '', responses = {}, expect = {}, continues = 0,
        closed = false, lazy = opts.lazy and true or false,
    }, Client)
    if not opts.lazy then
        sched.onSocket(s, function() c:onReadable() end)
        c.registered = true
    end
    liveClients[#liveClients + 1] = c
    return c
end

function Client:onReadable()
    local d, err = self.sock:recv(65536)
    if d == nil then
        self.closed, self.closeErr = true, err
        self:parse()
        return
    end
    if d == '' then return end
    self.rx = self.rx .. d
    self:parse()
end

--- Start draining a lazy client (used by the slow-client test).
function Client:activate()
    if self.registered then return end
    local c = self
    sched.onSocket(self.sock, function() c:onReadable() end)
    self.registered = true
end

function Client:parse()
    while true do
        local e = self.rx:find('\r\n\r\n', 1, true)
        if not e then return end
        local head = self.rx:sub(1, e - 1)
        local code = tonumber(head:match('^HTTP/1%.%d (%d+)'))
        if not code then
            self.protocolError = 'bad status line: ' .. head:sub(1, 40)
            return
        end
        local hdrs = {}
        for line in head:gmatch('[^\r\n]+') do
            local k, v = line:match('^([^:]+):%s*(.-)%s*$')
            if k then
                k = k:lower()
                hdrs[k] = hdrs[k] and (hdrs[k] .. ', ' .. v) or v
            end
        end
        if code == 100 then
            self.continues = self.continues + 1
            self.rx = self.rx:sub(e + 4)
        else
            local method = table.remove(self.expect, 1) or 'GET'
            local n = tonumber(hdrs['content-length'])
            if method == 'HEAD' or code == 304 or code == 204 then n = 0 end
            if n == nil then
                if not self.closed then
                    table.insert(self.expect, 1, method)   -- put it back, wait for EOF
                    return
                end
                n = #self.rx - (e + 3)
            end
            if #self.rx < e + 3 + n then
                table.insert(self.expect, 1, method)
                return
            end
            local body = self.rx:sub(e + 4, e + 3 + n)
            self.rx = self.rx:sub(e + 4 + n)
            self.responses[#self.responses + 1] =
                { status = code, headers = hdrs, body = body, head = head, method = method }
        end
    end
end

-- A send that fails because the server already closed the connection (an RST after
-- a 4xx that ends the stream) is recorded, not raised: the test then asserts on the
-- response the server did send.
function Client:raw(str, method)
    self.expect[#self.expect + 1] = method or 'GET'
    local n, err = self.sock:send(str)
    if not n then self.sendErr = tostring(err) end
end

function Client:rawNoExpect(str)
    local n, err = self.sock:send(str)
    if not n then self.sendErr = tostring(err) end
end

function Client:request(method, path, headers, body)
    local lines = { method .. ' ' .. path .. ' HTTP/1.1', 'Host: 127.0.0.1' }
    if headers then for k, v in pairs(headers) do lines[#lines + 1] = k .. ': ' .. v end end
    if body then lines[#lines + 1] = 'Content-Length: ' .. #body end
    lines[#lines + 1] = ''
    lines[#lines + 1] = body or ''
    self:raw(table.concat(lines, '\r\n'), method)
end

function Client:close()
    if self.registered then sched.removeSocket(self.sock) end
    pcall(function() self.sock:close() end)
    self.registered = false
end

local function closeClients()
    for i = 1, #liveClients do liveClients[i]:close() end
    liveClients = {}
end

-- ============================================================ reactor pump ==
local function pump(pred, ms)
    local t0 = sys.nowMs()
    ms = ms or 3000
    while sys.nowMs() - t0 < ms do
        sched.tick(2)
        if pred and pred() then return true end
    end
    return pred and pred() or true
end

local function waitFor(c, n, ms)
    return pump(function() return #c.responses >= n end, ms)
end

local function take(c)
    return table.remove(c.responses, 1)
end

-- ================================================================== router ==
local function router(req, res)
    local p = req.path
    if p == '/hello' then
        return res:text(200, 'hello ' .. req.method)
    elseif p == '/bench' then
        return res:send(200, 'ok', { ['Content-Type'] = 'text/plain' })
    elseif p == '/echo' then
        return res:json(200, {
            method = req.method, len = #req.body, body = req.body,
            ct = req:header('content-type') or '', ver = req.version,
            ka = req.keepAlive and 1 or 0, ip = req.remoteIp,
        })
    elseif p == '/q' then
        local q = req.query
        return res:json(200, { a = q.a, list = q.list, n = q.n,
                               raw = req.rawQuery or '', path = req.path,
                               rawPath = req.rawPath, target = req.target })
    elseif p == '/boom' then
        error('kaboom in handler')
    elseif p == '/twice' then
        res:text(200, 'first')
        res:text(200, 'second')
        return
    elseif p == '/slow' then
        sched.after(60, function() res:text(200, 'slow') end)
        return
    elseif p == '/big' then
        return res:send(200, string.rep('B', tonumber(req.query.n) or 1024),
                        { ['Content-Type'] = 'application/octet-stream' })
    elseif p == '/redir' then
        return res:redirect('/hello')
    elseif p == '/setter' then
        res:status(201):header('X-Made-By', 'res:header')
        res:header('X-Injected', 'a\r\nX-Evil: yes')
        return res:send(nil, 'created')
    elseif p == '/cookies' then
        return res:send(200, 'ck', { ['Set-Cookie'] = { 'a=1', 'b=2' } })
    elseif p == '/jsonin' then
        local t, e = req:json()
        if not t then return res:json(400, { err = tostring(e) }) end
        return res:json(200, { got = t.name, n = t.n })
    elseif p == '/file' then
        return res:file(ROOT .. '/README.md', 'text/markdown; charset=utf-8',
                        { chunkBytes = 1024 })
    end
    return res:send(404, 'no route\n')
end

--- Start a server, run fn(server, port), always stop it.
local function withServer(opts, fn)
    opts = opts or {}
    local log = newLog()
    local s = httpserver.new{
        host = '127.0.0.1', port = 0, sched = sched, log = log,
        onRequest = opts.onRequest or router,
        maxHeaderBytes = opts.maxHeaderBytes or 4096,
        maxBodyBytes = opts.maxBodyBytes or (64 * 1024),
        idleTimeoutMs = opts.idleTimeoutMs or 15000,
        headerTimeoutMs = opts.headerTimeoutMs or 15000,
        requestTimeoutMs = opts.requestTimeoutMs or 15000,
        allowBareLF = opts.allowBareLF,
        allowedHosts = opts.allowedHosts,
        maxRequests = opts.maxRequests or 100,
        maxConnections = opts.maxConnections,
        maxWriteBacklog = opts.maxWriteBacklog,
        sendBufferBytes = opts.sendBufferBytes,
        sweepMs = opts.sweepMs or 100,
    }
    local port, err = s:start()
    if not port then error('server start: ' .. tostring(err)) end
    local ok, ferr = pcall(fn, s, port, log)
    closeClients()
    s:stop()
    pump(nil, 20)
    if not ok then error(ferr, 0) end
end

-- ======================================================= 1. pure functions ==
runSuite('percent-decoding and query parsing', function()
    local pd = httpserver.percentDecode
    eq(pd('plain'), 'plain', 'plain string passes through')
    eq(pd('a%20b'), 'a b', '%20 decodes to a space')
    eq(pd('%41%42%43'), 'ABC', 'hex escapes decode')
    eq(pd('a+b'), 'a+b', "'+' is literal outside a query")
    eq(pd('a+b', true), 'a b', "'+' is a space inside a query")
    eq(pd('100%'), nil, 'a trailing bare % is refused')
    eq(pd('%zz'), nil, 'non-hex escape is refused')
    eq(pd('%2'), nil, 'truncated escape is refused')
    eq(pd('a%00b'), nil, '%00 is refused')
    eq(pd('a\0b'), nil, 'a raw NUL is refused')
    eq(select(2, pd('%zz')) ~= nil, true, 'the refusal carries a reason')

    local q = httpserver.parseQuery('a=1&b=hello%20world&b=two&flag&c=')
    eq(q.a, '1', 'scalar value')
    eq(q.b and type(q.b), 'table', 'a repeated key becomes an array')
    eq(q.b and q.b[1], 'hello world', 'first repeated value, decoded')
    eq(q.b and q.b[2], 'two', 'second repeated value')
    eq(q.flag, '', 'a bare key has an empty value')
    eq(q.c, '', 'an empty value stays empty')
    eq(httpserver.parseQuery('x=%zz'), nil, 'a malformed escape in a query is refused')
    local q2 = httpserver.parseQuery('n=a+b')
    eq(q2.n, 'a b', "'+' decodes to a space in a query value")
end)

runSuite('path normalisation (document root cannot be escaped)', function()
    local sp = httpserver.safePath
    eq((sp('/root', '/a/b.txt')), '/root/a/b.txt', 'simple path')
    eq((sp('/root/', '/a.txt')), '/root/a.txt', 'a trailing slash on the root is trimmed')
    eq((sp('/root', '/./a.txt')), '/root/a.txt', "'.' segments are dropped")
    eq((sp('/root', '/a//b.txt')), '/root/a/b.txt', 'empty segments collapse')
    eq((sp('/root', '/a%20b.txt')), '/root/a b.txt', 'segments are percent-decoded')
    eq(sp('/root', '/../etc/passwd'), nil, "'..' is refused")
    eq(sp('/root', '/a/../../etc'), nil, "'..' is refused mid-path")
    eq(sp('/root', '/%2e%2e/etc'), nil, "encoded '..' is refused")
    eq(sp('/root', '/%2fetc/passwd'), nil, 'an encoded slash is refused')
    eq(sp('/root', '/%2Fetc'), nil, 'an encoded slash is refused case-insensitively')
    eq(sp('/root', '/%5Cwindows'), nil, 'an encoded backslash is refused')
    eq(sp('/root', '/a\\b'), nil, 'a raw backslash is refused')
    eq(sp('/root', '/a%00b'), nil, 'an encoded NUL is refused')
    eq(sp('/root', '/C:/x'), nil, 'a colon in a segment is refused')
    eq(sp('/root', 'a.txt'), nil, 'a path must start with /')
    eq(sp('/root', '/'), nil, 'the bare root is not a file')

    eq(httpserver.mimeType('a/b/index.html'), 'text/html; charset=utf-8', 'html mime')
    eq(httpserver.mimeType('app.js'), 'text/javascript; charset=utf-8', 'js mime')
    eq(httpserver.mimeType('style.css'), 'text/css; charset=utf-8', 'css mime')
    eq(httpserver.mimeType('icon.svg'), 'image/svg+xml', 'svg mime')
    eq(httpserver.mimeType('logo.PNG'), 'image/png', 'png mime (case-insensitive)')
    eq(httpserver.mimeType('font.woff2'), 'font/woff2', 'woff2 mime')
    eq(httpserver.mimeType('data.json'), 'application/json; charset=utf-8', 'json mime')
    eq(httpserver.mimeType('blob.bin'), 'application/octet-stream', 'unknown mime falls back')

    eq(httpserver.etagMatches('"abc"', '"abc"'), true, 'ETag matches itself')
    eq(httpserver.etagMatches('"x", "abc"', '"abc"'), true, 'ETag matches in a list')
    eq(httpserver.etagMatches('*', '"abc"'), true, 'the * wildcard matches')
    eq(httpserver.etagMatches('W/"abc"', '"abc"'), true, 'the weak prefix is ignored')
    eq(httpserver.etagMatches('"zzz"', '"abc"'), false, 'a different ETag does not match')
    eq(httpserver.etagMatches(nil, '"abc"'), false, 'no If-None-Match does not match')
end)

-- ===================================================== 2. basic request/response
runSuite('GET / HEAD / POST, headers and helpers', function()
    withServer(nil, function(s, port)
        local c = newClient(port)
        c:request('GET', '/hello')
        check(waitFor(c, 1), 'GET answered')
        local r = take(c)
        eq(r and r.status, 200, 'GET /hello -> 200')
        eq(r and r.body, 'hello GET', 'GET body')
        eq(r and r.headers['content-type'], 'text/plain; charset=utf-8', 'text content type')
        eq(r and r.headers['content-length'], '9', 'Content-Length set')
        check(r and r.headers['date'] ~= nil, 'Date header present')
        check(r and r.headers['server'] ~= nil, 'Server header present')

        c:request('HEAD', '/hello')
        check(waitFor(c, 1), 'HEAD answered')
        r = take(c)
        eq(r and r.status, 200, 'HEAD -> 200')
        eq(r and r.body, '', 'HEAD carries no body')
        eq(r and r.headers['content-length'], '10', 'HEAD reports the body length it would send')

        c:request('POST', '/echo', { ['Content-Type'] = 'application/json' }, '{"a":1}')
        check(waitFor(c, 1), 'POST answered')
        r = take(c)
        eq(r and r.status, 200, 'POST -> 200')
        local d = r and json.decode(r.body)
        eq(d and d.method, 'POST', 'method seen by the handler')
        eq(d and d.len, 7, 'body length')
        eq(d and d.body, '{"a":1}', 'body content')
        eq(d and d.ct, 'application/json', 'req:header() is case-insensitive')
        eq(d and d.ver, 'HTTP/1.1', 'version')
        eq(d and d.ip, '127.0.0.1', 'remoteIp')

        c:request('POST', '/jsonin', { ['Content-Type'] = 'application/json' },
                  '{"name":"bob","n":42}')
        check(waitFor(c, 1), 'req:json() route answered')
        r = take(c)
        d = r and json.decode(r.body)
        eq(d and d.got, 'bob', 'req:json() decoded the body')
        eq(d and d.n, 42, 'req:json() numbers survive')

        c:request('POST', '/jsonin', nil, 'not json at all')
        check(waitFor(c, 1), 'bad json answered')
        r = take(c)
        eq(r and r.status, 400, 'req:json() reports a decode failure to the handler')

        c:request('GET', '/redir')
        check(waitFor(c, 1), 'redirect answered')
        r = take(c)
        eq(r and r.status, 302, 'res:redirect -> 302')
        eq(r and r.headers['location'], '/hello', 'Location header')

        c:request('GET', '/cookies')
        check(waitFor(c, 1), 'array-valued header answered')
        r = take(c)
        eq(r and r.headers['set-cookie'], 'a=1, b=2', 'an array header emits one line per value')

        c:request('GET', '/setter')
        check(waitFor(c, 1), 'res:status/res:header route answered')
        r = take(c)
        eq(r and r.status, 201, 'res:status(code) sets the status for a later send')
        eq(r and r.headers['x-made-by'], 'res:header', 'res:header(name, value) is emitted')
        eq(r and r.headers['x-evil'], nil, 'CR/LF in a header value cannot split the response')
        eq(r and r.headers['x-injected'], 'a  X-Evil: yes', 'the CR/LF was neutralised')
        eq(r and r.body, 'created', 'body sent with the preset status')

        c:request('GET', '/nothing-here')
        check(waitFor(c, 1), '404 answered')
        r = take(c)
        eq(r and r.status, 404, 'unknown route -> 404')

        local st = s:stats()
        eq(st.requests, 9, 'stats counted every request')
        eq(st.responses, 9, 'stats counted every response')
        eq(st.active, 1, 'one live connection')
        check(st.bytesIn > 0 and st.bytesOut > 0, 'byte counters move')
    end)
end)

runSuite('query parsing over the wire', function()
    withServer(nil, function(s, port)
        local c = newClient(port)
        c:request('GET', '/q?a=hello%20world&list=1&list=2&n=5')
        check(waitFor(c, 1), 'query request answered')
        local r = take(c)
        local d = r and json.decode(r.body)
        eq(d and d.a, 'hello world', 'percent-decoded query value')
        eq(d and d.list and d.list[1], '1', 'repeated key -> array [1]')
        eq(d and d.list and d.list[2], '2', 'repeated key -> array [2]')
        eq(d and d.n, '5', 'plain value')
        eq(d and d.raw, 'a=hello%20world&list=1&list=2&n=5', 'rawQuery is the undecoded string')
        eq(d and d.path, '/q', 'path excludes the query')
        eq(d and d.rawPath, '/q', 'rawPath excludes the query')

        c:request('GET', '/q%20x?a=1')
        check(waitFor(c, 1), 'encoded path answered')
        r = take(c)
        eq(r and r.status, 404, 'a decoded path that matches no route is a 404')

        c:request('GET', '/q?a=%zz')
        check(waitFor(c, 1), 'malformed query answered')
        r = take(c)
        eq(r and r.status, 400, 'a malformed escape in the query -> 400')
    end)
end)

-- ============================================================ 3. body framing
runSuite('chunked request bodies', function()
    withServer(nil, function(s, port)
        local c = newClient(port)
        local body = table.concat({
            'POST /echo HTTP/1.1\r\n', 'Host: 127.0.0.1\r\n',
            'Transfer-Encoding: chunked\r\n', 'Content-Type: text/plain\r\n\r\n',
            '5\r\nhello\r\n', '1\r\n \r\n', '6\r\nworld!\r\n', '0\r\n\r\n' })
        c:raw(body, 'POST')
        check(waitFor(c, 1), 'chunked request answered')
        local r = take(c)
        local d = r and json.decode(r.body)
        eq(d and d.body, 'hello world!', 'chunks reassembled in order')
        eq(d and d.len, 12, 'chunked length')

        -- chunk extensions and a trailer section
        c:raw(table.concat({
            'POST /echo HTTP/1.1\r\n', 'Host: 127.0.0.1\r\n',
            'Transfer-Encoding: chunked\r\n\r\n',
            '4;name=value\r\nabcd\r\n', '0\r\n', 'X-Trailer: 1\r\n', '\r\n' }), 'POST')
        check(waitFor(c, 1), 'chunk extensions + trailer answered')
        r = take(c)
        d = r and json.decode(r.body)
        eq(d and d.body, 'abcd', 'chunk extensions are ignored, trailers skipped')

        -- an empty chunked body
        c:raw('POST /echo HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n', 'POST')
        check(waitFor(c, 1), 'empty chunked body answered')
        r = take(c)
        d = r and json.decode(r.body)
        eq(d and d.len, 0, 'empty chunked body -> empty body')

        -- the connection is still usable afterwards
        c:request('GET', '/hello')
        check(waitFor(c, 1), 'keep-alive survives a chunked body')
        eq(take(c).body, 'hello GET', 'follow-up request on the same connection')

        -- unsupported transfer coding
        local c2 = newClient(port)
        c2:raw('POST /echo HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: gzip\r\n\r\n', 'POST')
        check(waitFor(c2, 1), 'gzip transfer-encoding answered')
        r = take(c2)
        eq(r and r.status, 501, 'an unsupported Transfer-Encoding -> 501')

        -- malformed chunk size
        local c3 = newClient(port)
        c3:raw('POST /echo HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\nZZ\r\n', 'POST')
        check(waitFor(c3, 1), 'malformed chunk size answered')
        r = take(c3)
        eq(r and r.status, 400, 'a malformed chunk size -> 400')
    end)
end)

runSuite('100-continue', function()
    withServer(nil, function(s, port)
        local c = newClient(port)
        c:raw('POST /echo HTTP/1.1\r\nHost: h\r\nExpect: 100-continue\r\n' ..
              'Content-Length: 5\r\n\r\n', 'POST')
        check(pump(function() return c.continues >= 1 end, 2000),
              'the server sends 100 Continue before the body')
        eq(#c.responses, 0, 'no final response until the body arrives')
        c:rawNoExpect('hello')
        check(waitFor(c, 1), 'final response after the body')
        local r = take(c)
        eq(r and r.status, 200, '100-continue request -> 200')
        eq(r and json.decode(r.body).body, 'hello', 'the deferred body arrived intact')
        eq(s:stats().continues, 1, 'stats counted the 100-continue')

        -- Expect + a body over the cap must be rejected instead of invited
        local c2 = newClient(port)
        c2:raw('POST /echo HTTP/1.1\r\nHost: h\r\nExpect: 100-continue\r\n' ..
               'Content-Length: 999999\r\n\r\n', 'POST')
        check(waitFor(c2, 1), 'oversized 100-continue answered')
        local r2 = take(c2)
        eq(r2 and r2.status, 413, 'an oversized Expect body is refused, not invited')
        eq(c2.continues, 0, 'no 100 Continue was sent for it')
    end)
end)

-- ============================================================= 4. keep-alive
runSuite('keep-alive, request limit and idle timeout', function()
    withServer({ maxRequests = 3 }, function(s, port)
        local c = newClient(port)
        for i = 1, 5 do c:request('GET', '/hello') end
        check(waitFor(c, 3, 3000), 'three responses on one connection')
        local r1, r2, r3 = take(c), take(c), take(c)
        eq(r1 and r1.status, 200, 'request 1')
        eq(r2 and r2.status, 200, 'request 2')
        eq(r3 and r3.status, 200, 'request 3')
        eq(r1 and r1.headers['connection'], 'keep-alive', 'connection kept alive on #1')
        eq(r2 and r2.headers['connection'], 'keep-alive', 'connection kept alive on #2')
        eq(r3 and r3.headers['connection'], 'close', 'the request limit closes the connection')
        pump(function() return c.closed end, 1000)
        eq(c.closed, true, 'the server actually closed the socket')
        check(pump(function() return s:stats().active == 0 end, 2000),
              'the connection was reaped')
    end)

    withServer(nil, function(s, port)
        local c = newClient(port)
        c:request('GET', '/hello', { ['Connection'] = 'close' })
        check(waitFor(c, 1), 'Connection: close request answered')
        local r = take(c)
        eq(r and r.headers['connection'], 'close', 'Connection: close is honoured')
        pump(function() return c.closed end, 1000)
        eq(c.closed, true, 'socket closed after the response')
    end)

    -- HTTP/1.0 without Connection: keep-alive closes; with it, it stays
    withServer(nil, function(s, port)
        local c = newClient(port)
        c:raw('GET /hello HTTP/1.0\r\n\r\n')
        check(waitFor(c, 1), 'HTTP/1.0 request answered')
        local r = take(c)
        eq(r and r.status, 200, 'HTTP/1.0 -> 200')
        eq(r and r.headers['connection'], 'close', 'HTTP/1.0 defaults to close')
    end)

    withServer({ idleTimeoutMs = 250, sweepMs = 50 }, function(s, port)
        local c = newClient(port)
        c:request('GET', '/hello')
        check(waitFor(c, 1), 'first request answered')
        take(c)
        eq(s:stats().active, 1, 'connection still open right after the response')
        check(pump(function() return c.closed end, 3000), 'idle connection closed by the timeout')
        eq(s:stats().timeouts >= 1, true, 'stats counted the timeout')
    end)
end)

runSuite('byte-at-a-time delivery', function()
    withServer(nil, function(s, port)
        local c = newClient(port)
        local req = 'POST /echo HTTP/1.1\r\nHost: 127.0.0.1\r\n' ..
                    'Content-Type: text/plain\r\nContent-Length: 11\r\n\r\nhello world'
        c.expect[#c.expect + 1] = 'POST'
        for i = 1, #req do
            c:rawNoExpect(req:sub(i, i))
            sched.tick(1)                    -- one reactor turn per byte
            if i < #req then
                check(#c.responses == 0 or i == #req, 'no early response at byte ' .. i)
            end
        end
        check(waitFor(c, 1, 3000), 'a request split byte-by-byte is answered')
        local r = take(c)
        local d = r and json.decode(r.body)
        eq(d and d.body, 'hello world', 'the dribbled body reassembles exactly')

        -- the same for a chunked body, one byte per turn
        local chunked = 'POST /echo HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n' ..
                        '3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n'
        c.expect[#c.expect + 1] = 'POST'
        for i = 1, #chunked do
            c:rawNoExpect(chunked:sub(i, i))
            sched.tick(1)
        end
        check(waitFor(c, 1, 3000), 'a dribbled chunked request is answered')
        r = take(c)
        d = r and json.decode(r.body)
        eq(d and d.body, 'abcdef', 'the dribbled chunked body reassembles exactly')
    end)
end)

-- ================================================================ 5. limits
runSuite('caps: oversized header block and body', function()
    withServer({ maxHeaderBytes = 2048, maxBodyBytes = 4096 }, function(s, port)
        -- a) header block delivered in many small writes
        local c = newClient(port)
        c:rawNoExpect('GET /hello HTTP/1.1\r\nHost: h\r\n')
        c.expect[#c.expect + 1] = 'GET'
        for i = 1, 40 do
            c:rawNoExpect('X-Pad-' .. i .. ': ' .. string.rep('p', 100) .. '\r\n')
            sched.tick(1)
            if #c.responses > 0 or c.closed then break end
        end
        check(waitFor(c, 1, 2000), 'oversized header block answered')
        local r = take(c)
        eq(r and r.status, 431, 'a header block over the cap -> 431')
        pump(function() return c.closed end, 1000)
        eq(c.closed, true, 'the connection is closed after 431')

        -- b) the whole oversized head in ONE segment
        local c2 = newClient(port)
        c2:raw('GET /hello HTTP/1.1\r\nHost: h\r\nX-Big: ' .. string.rep('Z', 8000) ..
               '\r\n\r\n', 'GET')
        check(waitFor(c2, 1, 2000), 'single-segment oversized head answered')
        r = take(c2)
        eq(r and r.status, 431, 'an oversized head in a single chunk is still rejected')

        -- c) an oversized request line alone
        local c3 = newClient(port)
        c3:raw('GET /' .. string.rep('u', 6000) .. ' HTTP/1.1\r\nHost: h\r\n\r\n', 'GET')
        check(waitFor(c3, 1, 2000), 'oversized request line answered')
        r = take(c3)
        eq(r and r.status, 431, 'an oversized request line is rejected')

        -- d) Content-Length over the cap: rejected before any body byte is read
        local c4 = newClient(port)
        c4:raw('POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: 100000\r\n\r\n', 'POST')
        check(waitFor(c4, 1, 2000), 'oversized Content-Length answered')
        r = take(c4)
        eq(r and r.status, 413, 'Content-Length over the cap -> 413')
        eq(s:stats().bytesIn < 20000, true, 'the body was never buffered')

        -- e) a chunked body that grows past the cap
        local c5 = newClient(port)
        c5:raw('POST /echo HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n', 'POST')
        for i = 1, 6 do
            c5:rawNoExpect(string.format('%x\r\n%s\r\n', 1024, string.rep('c', 1024)))
            sched.tick(1)
            if #c5.responses > 0 or c5.closed then break end
        end
        check(waitFor(c5, 1, 2000), 'oversized chunked body answered')
        r = take(c5)
        eq(r and r.status, 413, 'a chunked body over the cap -> 413')

        -- f) a body just under the cap still works
        local c6 = newClient(port)
        local payload = string.rep('x', 4000)
        c6:request('POST', '/echo', { ['Content-Type'] = 'text/plain' }, payload)
        check(waitFor(c6, 1, 2000), 'in-cap body answered')
        r = take(c6)
        eq(r and r.status, 200, 'a body just under the cap is accepted')
        eq(r and json.decode(r.body).len, 4000, 'the whole in-cap body arrived')

        -- g) malformed framing
        local c7 = newClient(port)
        c7:raw('POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: abc\r\n\r\n', 'POST')
        check(waitFor(c7, 1, 2000), 'malformed Content-Length answered')
        eq(take(c7).status, 400, 'a non-numeric Content-Length -> 400')

        local c8 = newClient(port)
        c8:raw('GET /hello HTTP/1.1\r\n\r\n', 'GET')
        check(waitFor(c8, 1, 2000), 'missing Host answered')
        eq(take(c8).status, 400, 'HTTP/1.1 without Host -> 400')

        local c9 = newClient(port)
        c9:raw('GET /hello HTTP/9.9\r\nHost: h\r\n\r\n', 'GET')
        check(waitFor(c9, 1, 2000), 'bad version answered')
        eq(take(c9).status, 505, 'an unsupported HTTP major version -> 505')

        local c10 = newClient(port)
        c10:raw('NOT-A-REQUEST\r\n\r\n', 'GET')
        check(waitFor(c10, 1, 2000), 'garbage request answered')
        eq(take(c10).status, 400, 'a malformed request line -> 400')
    end)
end)

-- ====================================================== 6. handler failures
runSuite('handler errors and double sends', function()
    withServer(nil, function(s, port, log)
        local c = newClient(port)
        c:request('GET', '/boom')
        check(waitFor(c, 1), 'throwing handler answered')
        local r = take(c)
        eq(r and r.status, 500, 'a handler that throws -> 500')
        check(log:find('kaboom in handler') ~= nil, 'the handler error was logged')
        eq(s:stats().handlerErrors, 1, 'stats counted the handler error')

        -- the server is still alive and the connection is still usable
        c:request('GET', '/hello')
        check(waitFor(c, 1), 'the server survives a throwing handler')
        eq(take(c).body, 'hello GET', 'the same connection still serves requests')

        c:request('GET', '/twice')
        check(waitFor(c, 1), 'double-send route answered')
        r = take(c)
        eq(r and r.body, 'first', 'only the first send reaches the wire')
        check(log:find('already sent') ~= nil, 'the double send was caught and logged')
        eq(s:stats().doubleSend, 1, 'stats counted the double send')
        pump(nil, 60)
        eq(#c.responses, 0, 'no second response was written')

        -- an asynchronous handler answers from a later reactor turn
        c:request('GET', '/slow')
        check(waitFor(c, 1, 2000), 'asynchronous handler answered')
        eq(take(c).body, 'slow', 'the deferred response arrived')
    end)
end)

-- ======================================================== 7. static serving
runSuite('static files, ETag revalidation and traversal refusal', function()
    local serve = httpserver.static{ root = ROOT, index = 'API.md' }
    withServer({ onRequest = function(req, res) return serve(req, res) end },
    function(s, port)
        local c = newClient(port)
        c:request('GET', '/lib/httpserver.lua')
        check(waitFor(c, 1, 3000), 'static file answered')
        local r = take(c)
        eq(r and r.status, 200, 'an existing file -> 200')
        eq(r and r.headers['content-type'], 'text/plain; charset=utf-8', 'lua content type')
        check(r and r.headers['etag'] ~= nil, 'an ETag is issued')
        local disk = io.open(ROOT .. '/lib/httpserver.lua', 'rb'):read('*a')
        eq(r and #r.body, #disk, 'the whole file was served')
        eq(r and r.body == disk, true, 'the bytes match the file on disk')
        local etag = r and r.headers['etag']

        c:request('GET', '/lib/httpserver.lua', { ['If-None-Match'] = etag })
        check(waitFor(c, 1, 3000), 'revalidation answered')
        r = take(c)
        eq(r and r.status, 304, 'a matching If-None-Match -> 304')
        eq(r and r.body, '', '304 carries no body')
        eq(r and r.headers['etag'], etag, '304 repeats the ETag')

        c:request('GET', '/lib/httpserver.lua', { ['If-None-Match'] = '"stale"' })
        check(waitFor(c, 1, 3000), 'stale revalidation answered')
        r = take(c)
        eq(r and r.status, 200, 'a stale If-None-Match -> 200 with the body')

        c:request('HEAD', '/lib/httpserver.lua')
        check(waitFor(c, 1, 3000), 'HEAD on a static file answered')
        r = take(c)
        eq(r and r.status, 200, 'HEAD -> 200')
        eq(r and r.body, '', 'HEAD sends no file bytes')
        eq(r and tonumber(r.headers['content-length']), #disk, 'HEAD reports the file size')

        c:request('GET', '/no/such/file.txt')
        check(waitFor(c, 1, 3000), 'missing file answered')
        eq(take(c).status, 404, 'a missing file -> 404')

        c:request('GET', '/lib')
        check(waitFor(c, 1, 3000), 'directory request answered')
        eq(take(c).status, 404, 'a directory is a 404, never a listing')

        for _, bad in ipairs({ '/../API.md', '/lib/../../API.md', '/%2e%2e/API.md',
                               '/%2fetc/passwd', '/lib%2fhttpserver.lua',
                               '/lib\\httpserver.lua', '/a%00.txt' }) do
            -- a fresh connection each time: some of these are rejected at the
            -- protocol level, which ends the connection
            local cb = newClient(port)
            cb:request('GET', bad)
            check(waitFor(cb, 1, 3000), 'traversal attempt answered: ' .. bad)
            local rr = take(cb)
            check(rr and (rr.status == 403 or rr.status == 400),
                  'traversal refused: ' .. bad, rr and rr.status)
            check(not (rr and rr.body:find('module contract', 1, true)),
                  'no file content leaked for ' .. bad)
        end

        c:request('POST', '/lib/httpserver.lua')
        check(waitFor(c, 1, 3000), 'POST to the static handler answered')
        r = take(c)
        eq(r and r.status, 405, 'POST to a static file -> 405')
        eq(r and r.headers['allow'], 'GET, HEAD', 'the 405 carries Allow')

        c:request('GET', '/')
        check(waitFor(c, 1, 3000), 'index request answered')
        r = take(c)
        eq(r and r.status, 200, 'a trailing slash serves the index file')

        -- the panel document root, when the other work item has produced it
        local pf = io.open(ROOT .. '/panel/index.html', 'rb')
        if pf then
            pf:close()
            c:request('GET', '/panel/index.html')
            check(waitFor(c, 1, 3000), 'panel/index.html answered')
            r = take(c)
            eq(r and r.status, 200, 'panel/index.html -> 200')
            eq(r and r.headers['content-type'], 'text/html; charset=utf-8',
               'panel/index.html is served as html')
        else
            note('panel/index.html not present; skipped the panel content-type check')
        end
    end)
end)

runSuite('res:file streams a large file in chunks', function()
    withServer(nil, function(s, port)
        local disk = io.open(ROOT .. '/README.md', 'rb'):read('*a')
        local c = newClient(port, { rcvbuf = 4096 })
        c:request('GET', '/file')
        check(waitFor(c, 1, 5000), 'streamed file answered')
        local r = take(c)
        eq(r and r.status, 200, 'streamed file -> 200')
        eq(r and r.headers['content-type'], 'text/markdown; charset=utf-8', 'explicit content type')
        eq(r and tonumber(r.headers['content-length']), #disk, 'Content-Length is the file size')
        eq(r and #r.body, #disk, 'the whole file arrived')
        eq(r and r.body == disk, true, 'the streamed bytes match the file on disk')
        check(#disk > 1024, 'the streamed file needed several chunks', #disk)
    end)
end)

-- =================================================== 8. slow / hostile peers
runSuite('a slow client cannot stall the others', function()
    withServer(nil, function(s, port)
        -- a client that never reads: its response sits in the connection's outbox
        local slow = newClient(port, { lazy = true, rcvbuf = 2048 })
        slow:raw('GET /big?n=400000 HTTP/1.1\r\nHost: h\r\n\r\n', 'GET')
        pump(nil, 100)

        -- while it is stuck, a normal client is served at full speed
        local fast = newClient(port)
        for i = 1, 5 do
            fast:request('GET', '/hello')
            check(waitFor(fast, 1, 2000), 'fast client round trip ' .. i)
            local r = take(fast)
            eq(r and r.body, 'hello GET', 'fast client response ' .. i)
        end
        eq(s:stats().active, 2, 'both connections are still open')

        -- now let the slow client drain: it gets every byte
        slow:activate()
        check(pump(function() return #slow.responses >= 1 end, 8000),
              'the slow client eventually receives its whole response')
        local r = take(slow)
        eq(r and r.status, 200, 'slow client -> 200')
        eq(r and #r.body, 400000, 'the slow client got all 400000 bytes')
        eq(s:stats().backlogDrops, 0, 'nothing was dropped under the default backlog cap')
    end)
end)

runSuite('the per-connection write backlog cap drops a stuck peer', function()
    -- White-box, and therefore identical on every platform: the connection's socket
    -- is swapped for one that accepts bytes and never drains them, which is exactly
    -- what a peer that has stopped reading looks like to the outbox.  (An end-to-end
    -- version of this is not portable: Windows loopback absorbs 8 MB into the kernel
    -- regardless of SO_SNDBUF, so no reasonable response size fills the outbox.)
    withServer({ maxWriteBacklog = 4096, onRequest = function(req, res)
        local conn = res.conn
        local real = conn.sock
        local stuckSock = setmetatable({ outboxLen = 0 }, { __index = real })
        function stuckSock:send(str)
            self.outboxLen = self.outboxLen + #str      -- queued, never drained
            return #str
        end
        conn.sock = stuckSock
        res:send(200, string.rep('B', 100000))
    end }, function(s, port)
        local c = newClient(port)
        c:request('GET', '/big')
        check(pump(function() return s:stats().backlogDrops >= 1 end, 3000),
              'a peer that will not read is dropped past the backlog cap')
        eq(s:stats().backlogDrops, 1, 'exactly one connection was dropped')
        eq(s:stats().active, 0, 'the dropped connection was reaped')
        check(pump(function() return c.closed end, 2000), 'the client sees the drop')
    end)

    -- And end to end, as far as the platform allows: a client that never reads.
    withServer({ maxWriteBacklog = 4096, sendBufferBytes = 2048 }, function(s, port)
        local stuck = newClient(port, { lazy = true, rcvbuf = 2048 })
        stuck:raw('GET /big?n=2000000 HTTP/1.1' .. CRLF .. 'Host: h' .. CRLF .. CRLF, 'GET')
        pump(function() return s:stats().backlogDrops >= 1 end, 3000)
        if s:stats().backlogDrops >= 1 then
            check(true, 'the stuck peer was dropped end to end')
            check(pump(function() return s:stats().active == 0 end, 2000),
                  'the dropped connection was reaped')
        else
            note('%s loopback absorbed the whole 2 MB response into kernel buffers; ' ..
                 'the end-to-end backlog drop could not be provoked', socket.os)
            stuck:activate()
            check(pump(function() return #stuck.responses >= 1 end, 8000),
                  'the response was delivered intact instead')
            eq(#take(stuck).body, 2000000, 'every byte arrived')
        end

        -- the server still works afterwards
        local ok = newClient(port)
        ok:request('GET', '/hello')
        check(waitFor(ok, 1, 2000), 'the server still serves after a drop')
        eq(take(ok).body, 'hello GET', 'response after a backlog drop')
    end)
end)

-- ============================================================ 9. concurrency
runSuite('20 simultaneous clients', function()
    withServer(nil, function(s, port)
        local N = 20
        local cs = {}
        for i = 1, N do cs[i] = newClient(port) end
        for i = 1, N do
            cs[i]:request('POST', '/echo', { ['Content-Type'] = 'text/plain' },
                          'client-' .. i)
        end
        local done = pump(function()
            for i = 1, N do if #cs[i].responses < 1 then return false end end
            return true
        end, 8000)
        check(done, 'all 20 clients received a response')
        local okCount = 0
        for i = 1, N do
            local r = take(cs[i])
            if r and r.status == 200 then
                local d = json.decode(r.body)
                if d.body == ('client-' .. i) then okCount = okCount + 1 end
            end
        end
        eq(okCount, N, 'every client got its own body back, unmixed')
        eq(s:stats().active, N, 'all 20 connections are alive (keep-alive)')

        -- a second round on the same 20 connections, interleaved
        for i = 1, N do cs[i]:request('GET', '/hello') end
        done = pump(function()
            for i = 1, N do if #cs[i].responses < 1 then return false end end
            return true
        end, 8000)
        check(done, 'all 20 keep-alive connections served a second request')
        local second = 0
        for i = 1, N do
            local r = take(cs[i])
            if r and r.body == 'hello GET' then second = second + 1 end
        end
        eq(second, N, 'every second-round response is correct')
        eq(s:stats().responses, 2 * N, 'stats counted all 40 responses')
    end)
end)

-- ============================================================= 10. benchmark
local benchLine = 'benchmark did not run'
runSuite('throughput (trivial handler)', function()
    -- maxRequests must not cap the run: with the default 100 the benchmark would
    -- measure the keep-alive limit instead of the server.
    withServer({ maxRequests = 100000000, sweepMs = 1000 }, function(s, port)
        local N = 8
        local cs = {}
        for i = 1, N do cs[i] = newClient(port) end
        -- warm-up
        for i = 1, N do cs[i]:request('GET', '/bench') end
        pump(function()
            for i = 1, N do if #cs[i].responses < 1 then return false end end
            return true
        end, 3000)
        for i = 1, N do take(cs[i]) end

        local done = 0
        for i = 1, N do cs[i]:request('GET', '/bench') end
        local t0 = sys.nowMs()
        while sys.nowMs() - t0 < BENCH_MS do
            sched.tick(1)
            for i = 1, N do
                local c = cs[i]
                while #c.responses > 0 do
                    table.remove(c.responses, 1)
                    done = done + 1
                    c:request('GET', '/bench')
                end
            end
        end
        local elapsed = sys.nowMs() - t0
        local rps = done / (elapsed / 1000)
        benchLine = string.format(
            '%s: %d requests in %.0f ms over %d keep-alive connections -> %.0f req/s ' ..
            '(%.3f ms mean round trip; the clients share this one reactor)',
            socket.os, done, elapsed, N, rps, elapsed * N / done)
        note('%s', benchLine)
        check(done > 100, 'the benchmark completed a meaningful number of requests', done)
        check(rps > 50, 'throughput is sane', string.format('%.0f req/s', rps))
    end)
end)

-- ============================================ 11. review regressions (hub) ==
-- One block per finding from the adversarial review of the hub primitives.  Each
-- of these FAILS against the code as it was reviewed and passes against the fix.

-- BLOCKER 1: a socket handed to another protocol stayed in server.conns, so the
-- idle sweep wrote a raw "HTTP/1.1 408" into the middle of the established stream
-- and closed the TCP connection behind the new owner's back.
runSuite('res:upgrade() detaches the connection (blocker)', function()
    local taken = {}
    local opts = {
        idleTimeoutMs = 200, sweepMs = 40, headerTimeoutMs = 500,
        onRequest = function(req, res)
            if req.path == '/ws' then
                local sock, pending = res:upgrade()
                taken[#taken + 1] = { sock = sock, pending = pending, req = req }
                return
            end
            return res:text(200, 'plain')
        end,
    }
    withServer(opts, function(s, port)
        local c = newClient(port)
        -- the bytes past the header block must come back as `pending`
        c:rawNoExpect('GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\n' ..
                      'Upgrade: websocket\r\nConnection: Upgrade\r\n\r\nLEFTOVER-BYTES')
        check(pump(function() return #taken == 1 end, 2000), 'the route ran and detached')
        local t = taken[1]
        check(t and t.sock ~= nil, 'res:upgrade() returned the socket')
        eq(t and t.pending, 'LEFTOVER-BYTES', 'and every byte read past the head')

        eq(s:stats().connections, 0, 'the detached connection is gone from stats()')
        eq(s:stats().active, 0, '   and from the live count that maxConnections uses')
        eq(s:stats().upgrades, 1, 'the upgrade is counted separately')

        -- survive well past idleTimeoutMs (200 ms): the sweep must not touch it
        pump(nil, 900)
        eq(s:stats().connections, 0, 'still not tracked after several sweeps')
        check(not c.closed, 'the socket the new owner holds is still open')
        eq(#c.responses, 0, 'no HTTP response was ever written to it')
        check(not (c.rx or ''):find('408', 1, true),
              'no 408 was injected into the handed-over stream', tostring(c.rx))

        -- it is a working socket: the new owner speaks its own protocol on it
        t.sock:send('OWNED-BY-THE-NEW-PROTOCOL')
        check(pump(function() return (c.rx or ''):find('OWNED', 1, true) ~= nil end, 2000),
              'the new owner can still write to the peer')

        -- other connections are unaffected
        local c2 = newClient(port)
        c2:request('GET', '/plain')
        check(waitFor(c2, 1, 2000), 'the server still serves everybody else')
        eq(take(c2).status, 200, '   with a normal response')

        -- closing is the new owner's job, and doing it must not double-close
        t.sock:close()
        s:stop()                       -- must not touch the detached socket either
        pump(nil, 50)
        check(true, 'closing the detached socket and stopping the server is clean')
    end)
end)

-- MAJOR: idleTimeoutMs is a SLIDING window that any byte resets, so one byte per
-- (idleTimeout/2) held a connection, and its buffered body, forever.
runSuite('absolute request deadlines (slow loris)', function()
    withServer({ idleTimeoutMs = 30000, headerTimeoutMs = 250,
                 requestTimeoutMs = 400, sweepMs = 40 }, function(s, port)
        -- a head delivered one byte per 60 ms: every byte resets `last`, so only an
        -- absolute deadline can ever end this
        local c = newClient(port)
        local head = 'GET /hello HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Pad: '
        local sent = 0
        local t0 = sys.nowMs()
        while sys.nowMs() - t0 < 1200 and not c.closed do
            sent = sent + 1
            c:rawNoExpect(head:sub(sent, sent) ~= '' and head:sub(sent, sent) or 'a')
            pump(nil, 60)
        end
        check(c.closed or #c.responses > 0, 'the drip-fed connection was ended',
              ('after %d bytes'):format(sent))
        local r = c.responses[1]
        eq(r and r.status, 408, 'with 408 Request Timeout')
        check(s:stats().deadlines >= 1, 'stats counted an absolute deadline',
              s:stats().deadlines)
        check(pump(function() return s:stats().active == 0 end, 2000),
              'and the connection slot was returned', s:stats().active)

        -- a complete head, then a body dribbled forever: requestTimeoutMs is the cap
        local c2 = newClient(port)
        c2:raw('POST /echo HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 400\r\n\r\n', 'POST')
        local t1 = sys.nowMs()
        while sys.nowMs() - t1 < 1500 and #c2.responses == 0 do
            c2:rawNoExpect('x')
            pump(nil, 60)
        end
        eq(c2.responses[1] and c2.responses[1].status, 408,
           'a body that never ends hits the request deadline')
    end)

    -- and the absolute head deadline must NOT break ordinary keep-alive idling
    withServer({ idleTimeoutMs = 2000, headerTimeoutMs = 150, sweepMs = 40 },
    function(s, port)
        local c = newClient(port)
        c:request('GET', '/hello')
        check(waitFor(c, 1, 2000), 'first request answered')
        take(c)
        pump(nil, 600)                 -- 4x headerTimeoutMs of doing nothing
        eq(s:stats().active, 1, 'an idle keep-alive connection is not killed by it')
        c:request('GET', '/hello')
        check(waitFor(c, 1, 2000), 'and it is still usable')
        eq(take(c).body, 'hello GET', '   second request on the same connection')
    end)
end)

-- MAJOR: the chunked decoder rebuilt the input buffer once per chunk-size line,
-- once per data take and once per terminator -- O(bytes^2 / chunkSize).
runSuite('chunked decoding is linear in the bytes received', function()
    withServer({ maxBodyBytes = 1024 * 1024 }, function(s, port)
        local N = 131072                      -- a 128 KB body delivered as 131072 1-byte chunks
        local parts = { 'POST /echo HTTP/1.1\r\nHost: 127.0.0.1\r\n',
                        'Transfer-Encoding: chunked\r\n\r\n' }
        for _ = 1, N do parts[#parts + 1] = '1\r\nz\r\n' end
        parts[#parts + 1] = '0\r\n\r\n'
        local wire = table.concat(parts)
        local c = newClient(port)
        local t0 = sys.nowMs()
        c:raw(wire, 'POST')
        local ok = waitFor(c, 1, 20000)
        local elapsed = sys.nowMs() - t0
        check(ok, 'the 1-byte-chunk body was answered')
        local d = ok and json.decode(take(c).body)
        eq(d and d.len, N, 'every chunk arrived exactly once')
        eq(d and d.body, string.rep('z', N), '   and in order')
        note('%d one-byte chunks (%.0f KB on the wire) decoded in %d ms',
             N, #wire / 1024, elapsed)
        -- measured on this machine: 1290 ms with the O(n^2) decoder, 61 ms with the fix
        check(elapsed < 400, 'decoding stayed linear', elapsed .. ' ms')
    end)
end)

-- MAJOR: chunk-size was a PREFIX match, so "5junk" was 5 and "0x5" was 0 -- the
-- last chunk -- after which the real body was eaten as trailers and the bytes
-- behind it were dispatched as a pipelined request.
runSuite('chunk-size lines are parsed whole (request smuggling)', function()
    withServer(nil, function(s, port)
        local seen = 0
        local c = newClient(port)
        c:raw('POST /echo HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n' ..
              '5junk\r\nHELLO\r\n0\r\n\r\n', 'POST')
        check(waitFor(c, 1, 2000), 'answered')
        eq(take(c).status, 400, 'junk after the hex chunk size -> 400')

        local c2 = newClient(port)
        c2:raw('POST /E HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n' ..
               '0x5\r\nHELLO\r\n0\r\n\r\n' ..
               'GET /SMUGGLED HTTP/1.1\r\nHost: h\r\n\r\n', 'POST')
        check(waitFor(c2, 1, 2000), 'answered')
        eq(take(c2).status, 400, '"0x5" is not a chunk size -> 400')
        pump(nil, 200)
        eq(#c2.responses, 0, 'and nothing behind it was dispatched as a second request')

        -- a chunk extension is still legal
        local c3 = newClient(port)
        c3:raw('POST /echo HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n' ..
               '4;name=value\r\nabcd\r\n0\r\n\r\n', 'POST')
        check(waitFor(c3, 1, 2000), 'chunk extension answered')
        local d = json.decode(take(c3).body)
        eq(d and d.body, 'abcd', '   and decoded normally')

        -- an absurdly long hex value cannot reach tonumber
        local c4 = newClient(port)
        c4:raw('POST /echo HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n' ..
               string.rep('f', 20) .. '\r\n', 'POST')
        check(waitFor(c4, 1, 2000), 'answered')
        eq(take(c4).status, 400, 'a 20-digit chunk size -> 400')
    end)
end)

-- MAJOR: a bare LF was accepted as framing in three places.  Behind a proxy that
-- requires CRLF, that is a request-smuggling desync (RFC 9112 2.2).
runSuite('framing is CRLF only (bare LF is not a line terminator)', function()
    local seen
    local function recorder(req, res)
        seen[#seen + 1] = req.method .. ' ' .. req.rawPath
        return res:text(200, 'dispatched')
    end
    withServer({ onRequest = recorder, headerTimeoutMs = 400, sweepMs = 40 },
    function(s, port)
        seen = {}
        -- an LF-only message is not a message at all: it never terminates, so it is
        -- never parsed and the absolute head deadline eventually closes it
        local c = newClient(port)
        c:raw('POST /A HTTP/1.1\nHost: h\nContent-Length: 5\n\nHELLO', 'POST')
        pump(nil, 300)
        eq(#seen, 0, 'a request framed entirely with bare LF is never dispatched')
        check(pump(function() return #c.responses > 0 or c.closed end, 2000),
              'the head deadline ends it')
        eq(c.responses[1] and c.responses[1].status, 408, '   with 408, not 200')

        seen = {}
        local c2 = newClient(port)
        c2:raw('GET /B1 HTTP/1.1\nHost: h\n\nGET /B2 HTTP/1.1\nHost: h\n\n', 'GET')
        pump(nil, 300)
        eq(#seen, 0, 'a bare-LF head cannot smuggle one request, let alone two')

        seen = {}
        local c3 = newClient(port)
        c3:raw('POST /C HTTP/1.1\r\nHost: h\r\nTransfer-Encoding: chunked\r\n\r\n' ..
               '5\nHELLO\n0\n\n', 'POST')
        check(waitFor(c3, 1, 2000), 'answered')
        eq(take(c3).status, 400, 'a chunked body framed with bare LF -> 400')
        eq(#seen, 0, '   and the handler never saw it')

        -- a single LF-terminated line inside an otherwise CRLF head is still a desync
        seen = {}
        local c4 = newClient(port)
        c4:raw('GET /D HTTP/1.1\r\nHost: h\nX-Smuggle: 1\r\n\r\n', 'GET')
        check(waitFor(c4, 1, 2000), 'answered')
        eq(take(c4).status, 400, 'a single bare-LF header line -> 400')
        eq(#seen, 0, '   and the handler never saw it either')
    end)

    -- opt-in tolerance for hand-typed clients
    withServer({ allowBareLF = true }, function(s, port)
        local c = newClient(port)
        c:raw('GET /hello HTTP/1.1\nHost: h\n\n', 'GET')
        check(waitFor(c, 1, 2000), 'answered')
        eq(take(c).status, 200, 'opts.allowBareLF = true restores the old tolerance')
    end)
end)

-- MINOR x2: the response framing was not authoritative -- a handler could set
-- Content-Length itself (response desync) and a header set twice went out twice
-- (browsers honour the FIRST Content-Type: stored XSS).
runSuite('the server owns the response framing', function()
    local function routes(req, res)
        if req.path == '/dupCL' then
            res:header('Content-Length', '0')
            return res:send(200, 'PIPELINED-BODY-BYTES')
        elseif req.path == '/dupCT' then
            res:header('Content-Type', 'text/html')
            return res:json(200, { a = 1 })
        elseif req.path == '/cookies2' then
            return res:send(200, 'ck', { ['Set-Cookie'] = { 'a=1', 'b=2' } })
        end
        return res:send(404, 'x')
    end
    withServer({ onRequest = routes }, function(s, port)
        local function count(head, name)
            local n = 0
            for line in head:gmatch('[^\r\n]+') do
                if line:lower():find('^' .. name .. ':') then n = n + 1 end
            end
            return n
        end
        local c = newClient(port)
        c:request('GET', '/dupCL')
        check(waitFor(c, 1, 2000), 'answered')
        local r = take(c)
        eq(count(r.head, 'content%-length'), 1, 'exactly one Content-Length')
        eq(r.headers['content-length'], '20', '   and it is the real body length')
        eq(r.body, 'PIPELINED-BODY-BYTES', '   so the peer stays in sync')

        c:request('GET', '/dupCT')
        check(waitFor(c, 1, 2000), 'answered')
        r = take(c)
        eq(count(r.head, 'content%-type'), 1, 'exactly one Content-Type')
        eq(r.headers['content-type'], 'application/json; charset=utf-8',
           '   and it is the one res:json chose (last writer wins)')

        c:request('GET', '/cookies2')
        check(waitFor(c, 1, 2000), 'answered')
        r = take(c)
        eq(count(r.head, 'set%-cookie'), 2, 'Set-Cookie is still allowed to repeat')
    end)
end)

-- MINOR: a repeated Content-Length was merged into "5, 5", so the framing was safe
-- but every handler saw a string tonumber() cannot read (RFC 9112 6.3: reject).
runSuite('repeated framing headers are refused', function()
    withServer(nil, function(s, port)
        local c = newClient(port)
        c:raw('POST /echo HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n' ..
              'Content-Length: 5\r\n\r\nHELLO', 'POST')
        check(waitFor(c, 1, 2000), 'answered')
        eq(take(c).status, 400, 'a duplicated Content-Length -> 400')

        local c2 = newClient(port)
        c2:raw('GET /hello HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n', 'GET')
        check(waitFor(c2, 1, 2000), 'answered')
        eq(take(c2).status, 400, 'a duplicated Host -> 400')

        local c3 = newClient(port)
        c3:raw('GET /hello HTTP/1.1\r\nHost: h\r\nAccept: a\r\nAccept: b\r\n\r\n', 'GET')
        check(waitFor(c3, 1, 2000), 'answered')
        eq(take(c3).status, 200, 'an ordinary header may still repeat')
    end)
end)

-- BLOCKER 2 (the HTTP half): pinning Host is what closes DNS rebinding against a
-- loopback-bound hub -- an Origin check alone cannot, because a rebound name makes
-- the request genuinely same-origin.
runSuite('opts.allowedHosts pins the authority (DNS rebinding)', function()
    withServer({ allowedHosts = { '127.0.0.1', 'localhost' } }, function(s, port)
        local c = newClient(port)
        c:raw('GET /hello HTTP/1.1\r\nHost: 127.0.0.1:' .. port .. '\r\n\r\n', 'GET')
        check(waitFor(c, 1, 2000), 'answered')
        eq(take(c).status, 200, 'an allowed Host (with a port) is served')

        local c2 = newClient(port)
        c2:raw('GET /hello HTTP/1.1\r\nHost: rebind.evil.example\r\n\r\n', 'GET')
        check(waitFor(c2, 1, 2000), 'answered')
        eq(take(c2).status, 400, 'a Host that is not on the list -> 400')
    end)
    withServer(nil, function(s, port)
        local c = newClient(port)
        c:raw('GET /hello HTTP/1.1\r\nHost: anything.example\r\n\r\n', 'GET')
        check(waitFor(c, 1, 2000), 'answered')
        eq(take(c).status, 200, 'without the option any Host is accepted (default)')
    end)
end)

-- ================================================================ 11. teardown
runSuite('start / stop lifecycle', function()
    local s = httpserver.new{ host = '127.0.0.1', port = 0, sched = sched,
                              log = newLog(), onRequest = router }
    local port = s:start()
    check(port and port > 0, 'start() returns the ephemeral port', tostring(port))
    eq(s:stats().listening, true, 'stats reports listening')
    local c = newClient(port)
    c:request('GET', '/hello')
    check(waitFor(c, 1, 2000), 'served before stop')
    take(c)
    s:stop()
    pump(nil, 50)
    eq(s:stats().active, 0, 'stop() closed every connection')
    eq(s:stats().listening, false, 'stop() closed the listener')
    check(pump(function() return c.closed end, 1000), 'the client sees the connection closed')
    closeClients()

    -- the port is free again: a new server can bind an ephemeral port and serve
    local s2 = httpserver.new{ host = '127.0.0.1', port = 0, sched = sched,
                               log = newLog(), onRequest = router }
    local p2 = s2:start()
    check(p2 and p2 > 0, 'a second server starts')
    local c2 = newClient(p2)
    c2:request('GET', '/hello')
    check(waitFor(c2, 1, 2000), 'the second server serves')
    eq(take(c2).body, 'hello GET', 'second server response')
    closeClients()
    s2:stop()
end)

-- ===================================================================== report
sched.reset()
io.write('\n============== httpserversuite ==============\n')
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
io.write(('  TOTAL: %d passed, %d failed  -> %s\n'):format(
    totalPass, totalFail, totalFail == 0 and 'PASS' or 'FAIL'))

pcall(function() socket.cleanup() end)
os.exit(totalFail == 0 and 0 or 1)
