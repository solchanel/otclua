--[[============================================================================
test/proxysuite.lua -- lib/proxy.lua: unit tests for the CONNECT state machine
plus an end-to-end tunnel through a REAL loopback proxy built on lib/socket.lua.

    luajit test/proxysuite.lua              (from D:/Claude/otclient_web/luaclient)
    luajit test/proxysuite.lua --dump       (also print the reference request bytes)

Exits non-zero if any check fails.  The end-to-end part binds 127.0.0.1 on an
ephemeral port; nothing leaves the machine.

Reference behaviour under test is documented in docs/proxy.md; the byte-exact
expectations come from otclient/src/framework/net/connection.cpp:293-400.
============================================================================]]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. package.path
end

local proxy  = require('lib.proxy')
local socket = require('lib.socket')
local sys    = require('lib.sys')

local DUMP = false
for i = 1, #arg do if arg[i] == '--dump' then DUMP = true end end

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
        io.write('    FAIL  ', desc, detail and ('  -- ' .. tostring(detail)) or '', '\n')
    end
    return ok
end

local function eq(got, want, desc)
    if got == want then return check(true, desc) end
    local g, w = tostring(got), tostring(want)
    if #g > 120 then g = g:sub(1, 117) .. '...' end
    if #w > 120 then w = w:sub(1, 117) .. '...' end
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

local function vis(s)                     -- printable form of a wire string
    return (tostring(s):gsub('\r', '\\r'):gsub('\n', '\\n'))
end

-- ================================================================== base64 ==
runSuite('base64 (RFC 4648)', function()
    -- The canonical RFC 4648 section 10 vectors.
    eq(proxy.base64(''),       '',          'base64("")')
    eq(proxy.base64('f'),      'Zg==',      'base64("f")')
    eq(proxy.base64('fo'),     'Zm8=',      'base64("fo")')
    eq(proxy.base64('foo'),    'Zm9v',      'base64("foo")')
    eq(proxy.base64('foob'),   'Zm9vYg==',  'base64("foob")')
    eq(proxy.base64('fooba'),  'Zm9vYmE=',  'base64("fooba")')
    eq(proxy.base64('foobar'), 'Zm9vYmFy',  'base64("foobar")')
    eq(proxy.base64('bob:s3cr3t'), 'Ym9iOnMzY3IzdA==', 'base64("bob:s3cr3t")')
    eq(proxy.base64('Man'),    'TWFu',      'base64("Man")')
    -- Binary safety: every byte value round-trips through the encoder length rule.
    local all = {}
    for i = 0, 255 do all[i + 1] = string.char(i) end
    local enc = proxy.base64(table.concat(all))
    eq(#enc, 344, 'base64 of 256 bytes is 344 chars (ceil(256/3)*4)')
    eq(enc:sub(1, 8), 'AAECAwQF', 'base64 of \\0\\1\\2... starts AAECAwQF')
    -- 256 = 85 full triples + one trailing 0xFF byte -> a 1-byte final group
    eq(enc:sub(-4), '/w==', 'base64 of 256 bytes ends /w== (1-byte tail group)')
    eq(proxy.base64(string.char(0xFF, 0xFF, 0xFF)), '////', 'base64(\\xFF\\xFF\\xFF)')
    eq(proxy.base64(string.char(0xFB, 0xEF, 0xBE)), '++++', 'base64 hits + and / of the alphabet')
end)

-- ========================================================= request builder ==
local REF_NOAUTH =
    'CONNECT game.example.net:7171 HTTP/1.1\r\n' ..
    'Host: game.example.net:7171\r\n' ..
    'User-Agent: OTClient\r\n' ..
    'Proxy-Connection: keep-alive\r\n' ..
    '\r\n'

local REF_AUTH =
    'CONNECT game.example.net:7171 HTTP/1.1\r\n' ..
    'Host: game.example.net:7171\r\n' ..
    'User-Agent: OTClient\r\n' ..
    'Proxy-Connection: keep-alive\r\n' ..
    'Proxy-Authorization: Basic Ym9iOnMzY3IzdA==\r\n' ..
    '\r\n'

runSuite('buildConnect (byte-exact vs connection.cpp:293)', function()
    local req = proxy.buildConnect{ host = 'game.example.net', port = 7171 }
    eq(req, REF_NOAUTH, 'no-auth request matches the reference byte for byte')
    eq(#req, 123, 'no-auth request is 123 bytes')

    local req2, red2 = proxy.buildConnect{ host = 'game.example.net', port = 7171,
                                           user = 'bob', pass = 's3cr3t' }
    eq(req2, REF_AUTH, 'auth request inserts Proxy-Authorization last')
    check(not red2:find('Ym9iOnMzY3IzdA==', 1, true), 'redacted copy hides the credential')
    check(red2:find('Basic <redacted>', 1, true) ~= nil, 'redacted copy says <redacted>')
    eq(proxy.redact(req2), red2, 'proxy.redact() reproduces the redacted copy')

    -- proxy.redact is a documented public helper for ARBITRARY request text, so it must never
    -- destroy a line it was supposed to show.  `%s` matches CR and LF: with `%s+` after the
    -- scheme token an empty credential blob let the greedy match swallow the line terminator
    -- and eat the NEXT header, which vanished from the log.
    local empty = 'Proxy-Authorization: Basic \r\nHost: h:1\r\nX-Keep: yes\r\n\r\n'
    local redEmpty = proxy.redact(empty)
    check(redEmpty:find('Host: h:1', 1, true) ~= nil,
          'redact() with an empty credential blob keeps the following header', vis(redEmpty))
    check(redEmpty:find('X-Keep: yes', 1, true) ~= nil, '   and every header after that too')
    check(redEmpty:find('<redacted>', 1, true) ~= nil, '   while still masking the blob')
    -- the same for a header with no scheme token at all
    local bare = 'Proxy-Authorization: Ym9iOnMz\r\nHost: h:1\r\n\r\n'
    local redBare = proxy.redact(bare)
    check(not redBare:find('Ym9iOnMz', 1, true), 'a scheme-less credential is masked too')
    check(redBare:find('Host: h:1', 1, true) ~= nil, '   without eating the next header')
    -- and redact() is idempotent: running it twice changes nothing
    eq(proxy.redact(redEmpty), redEmpty, 'redact() is idempotent')
    eq(proxy.redact(red2), red2, '   for a built request too')

    -- hasAuth() == !user.empty(): a password with no user sends NO header.
    local req3 = proxy.buildConnect{ host = 'h', port = 1, user = '', pass = 'lonely' }
    check(not req3:find('Proxy%-Authorization'), 'password without a user emits no header (hasAuth)')
    check(not req3:find('lonely', 1, true), 'and the password never reaches the wire')

    -- A colon in the password is fine, a colon in the user is the caller's problem.
    local req4 = proxy.buildConnect{ host = 'h', port = 1, user = 'u', pass = 'a:b' }
    eq(req4:match('Basic ([^\r]+)'), proxy.base64('u:a:b'), 'colon in the password is encoded raw')

    -- Optional headers.
    local bare = proxy.buildConnect{ host = 'h', port = 1, userAgent = false, proxyConnection = false }
    eq(bare, 'CONNECT h:1 HTTP/1.1\r\nHost: h:1\r\n\r\n', 'userAgent/proxyConnection = false omit them')
    local extra = proxy.buildConnect{ host = 'h', port = 1, userAgent = false,
                                      proxyConnection = false, extraHeaders = { { 'X-A', '1' } } }
    eq(extra, 'CONNECT h:1 HTTP/1.1\r\nHost: h:1\r\nX-A: 1\r\n\r\n', 'extraHeaders are appended')

    -- DEVIATION: IPv6 literals are bracketed (the reference emits "::1:7171").
    eq(proxy.formatTarget('::1', 7171), '[::1]:7171', 'IPv6 target is bracketed')
    local v6 = proxy.buildConnect{ host = '::1', port = 7171, userAgent = false, proxyConnection = false }
    eq(v6, 'CONNECT [::1]:7171 HTTP/1.1\r\nHost: [::1]:7171\r\n\r\n', 'IPv6 CONNECT line')

    -- DEVIATION: header injection is rejected (the reference validates nothing).
    for _, bad in ipairs({ { host = 'h\r\nX: 1', port = 1 },
                           { host = 'h', port = 1, user = 'u\r\nX: 1', pass = 'p' },
                           { host = 'h', port = 1, user = 'u', pass = 'p\nX: 1' },
                           { host = 'h', port = 1, user = 'u\0z', pass = 'p' } }) do
        local r, e = proxy.buildConnect(bad)
        check(r == nil and e ~= nil, 'CRLF/NUL injection rejected', e)
        if e then check(not e:find('X: 1', 1, true), 'the rejection message does not echo the payload') end
    end

    for _, badPort in ipairs({ 0, 65536, -1, 1.5, 'x' }) do
        local r = proxy.buildConnect{ host = 'h', port = badPort }
        check(r == nil, 'port ' .. tostring(badPort) .. ' rejected')
    end
    check(proxy.buildConnect{ host = '', port = 1 } == nil, 'empty host rejected')
end)

runSuite('parseEndpoint / parseAuth', function()
    local h, p = proxy.parseEndpoint('31.59.20.176:6754')
    eq(h, '31.59.20.176', 'parseEndpoint host'); eq(p, 6754, 'parseEndpoint port')
    h, p = proxy.parseEndpoint('  proxy.local:8080 ')
    eq(h, 'proxy.local', 'parseEndpoint trims'); eq(p, 8080, 'parseEndpoint trims port')
    h, p = proxy.parseEndpoint('[2001:db8::1]:3128')
    eq(h, '2001:db8::1', 'parseEndpoint IPv6 host'); eq(p, 3128, 'parseEndpoint IPv6 port')
    check(proxy.parseEndpoint('nohost') == nil, 'endpoint without a port rejected')
    check(proxy.parseEndpoint('h:0') == nil, 'endpoint with port 0 rejected')
    check(proxy.parseEndpoint('h:99999') == nil, 'endpoint with port 99999 rejected')

    local u, pw = proxy.parseAuth('user:pass')
    eq(u, 'user', 'parseAuth user'); eq(pw, 'pass', 'parseAuth pass')
    u, pw = proxy.parseAuth('user:pa:ss:word')
    eq(u, 'user', 'parseAuth splits on the FIRST colon'); eq(pw, 'pa:ss:word', 'colons kept in pass')
    u, pw = proxy.parseAuth('user:')
    eq(u, 'user', 'empty password allowed'); eq(pw, '', 'empty password is empty string')
    check(proxy.parseAuth('nocolon') == nil, 'auth without a colon rejected')
end)

-- ========================================================== state machine ===
local OPTS = { host = 'game.example.net', port = 7171,
               proxyHost = '203.0.113.9', proxyPort = 6754 }

local function newHS(over)
    local o = {}
    for k, v in pairs(OPTS) do o[k] = v end
    for k, v in pairs(over or {}) do o[k] = v end
    return (proxy.newHandshake(o))
end

--- Feed `resp` one byte at a time; return the final status and extras.
local function feedByByte(hs, resp)
    local st, a, b
    for i = 1, #resp do
        st, a, b = hs:feed(resp:sub(i, i))
        if st ~= proxy.NEED_MORE then return st, a, b, i end
    end
    return st, a, b, #resp
end

runSuite('state machine: 200 (whole, byte-at-a-time, every split)', function()
    local RESP = 'HTTP/1.1 200 Connection established\r\n' ..
                 'Proxy-agent: squid/5.7\r\n' ..
                 'Via: 1.1 edge\r\n\r\n'

    local hs = newHS()
    eq(hs.request, REF_NOAUTH, 'handshake.request is the reference request')
    eq(hs.state, 'init', 'fresh handshake state is init')
    local st, a = hs:feed(RESP)
    eq(st, proxy.CONNECTED, 'whole response in one chunk -> connected')
    eq(a, '', 'no trailing bytes -> empty leftover')
    eq(hs.status, 200, 'status 200 recorded')
    eq(hs.reason, 'Connection established', 'reason phrase recorded')
    eq(hs.httpVersion, '1.1', 'http version recorded')
    eq(hs.headers['proxy-agent'], 'squid/5.7', 'extra header Proxy-agent parsed (lower-cased key)')
    eq(hs.headers['via'], '1.1 edge', 'extra header Via parsed')
    eq(#hs.headerList, 2, 'headerList has both headers in order')
    eq(hs.headerList[1][1], 'proxy-agent', 'headerList preserves order')
    check(hs:isDone(), 'isDone()')

    -- byte at a time
    local hs2 = newHS()
    local st2, a2, _, consumed = feedByByte(hs2, RESP)
    eq(st2, proxy.CONNECTED, 'byte-at-a-time -> connected')
    eq(a2, '', 'byte-at-a-time leftover empty')
    eq(consumed, #RESP, 'connected exactly on the last byte of the header block')

    -- every possible two-chunk split
    local bad = 0
    for cut = 0, #RESP do
        local h = newHS()
        local s1 = h:feed(RESP:sub(1, cut))
        local s2 = (s1 == proxy.NEED_MORE) and h:feed(RESP:sub(cut + 1)) or s1
        if not (s2 == proxy.CONNECTED and h.status == 200 and h.leftover == '') then bad = bad + 1 end
    end
    eq(bad, 0, 'all ' .. (#RESP + 1) .. ' two-chunk splits of the header block connect identically')

    -- feed() is TOTAL: the documented usage loop in docs/proxy.md is unconditional, and the
    -- ordinary case (200 in one segment, first tunnel bytes in the next) must not raise.
    -- Late bytes are appended to leftover and handed back, never dropped, never thrown on.
    local hs3 = newHS()
    hs3:feed(RESP)
    eq(hs3.leftover, '', 'nothing after the header block yet')
    local okLate, stLate, leftLate = pcall(function()
        local a, b = hs3:feed('GAME')
        return { a, b }
    end)
    check(okLate, 'feed() after connected does not raise')
    stLate = okLate and stLate[1] or nil
    leftLate = okLate and (select(2, hs3:feed(''))) or nil
    eq(stLate, proxy.CONNECTED, 'feed() after connected re-reports connected')
    eq(hs3.leftover, 'GAME', 'late bytes are appended to leftover, not dropped')
    eq(leftLate, 'GAME', '   and returned again on the next call')
    hs3:feed('MORE')
    eq(hs3.leftover, 'GAMEMORE', 'a second late chunk appends too')
    eq(select(1, hs3:feed(nil)), proxy.CONNECTED, 'feed(nil) after connected is harmless')
    eq(select(1, hs3:tick(1)), proxy.CONNECTED, 'tick() after connected still reports connected')
end)

runSuite('state machine: trailing bytes become leftover', function()
    local EARLY = 'EARLY-TUNNEL-BYTES\0\1\2'
    local RESP  = 'HTTP/1.1 200 Connection established\r\n\r\n' .. EARLY

    local hs = newHS()
    local st, a = hs:feed(RESP)
    eq(st, proxy.CONNECTED, 'connected with a body after the headers')
    eq(a, EARLY, 'the bytes after \\r\\n\\r\\n are returned as leftover')
    eq(hs.leftover, EARLY, 'hs.leftover holds the same bytes')

    -- split so the terminator itself straddles the chunk boundary
    local cut = #'HTTP/1.1 200 Connection established\r\n\r'
    local hs2 = newHS()
    eq(hs2:feed(RESP:sub(1, cut)), proxy.NEED_MORE, 'split inside the CRLFCRLF -> need-more')
    local st2, a2 = hs2:feed(RESP:sub(cut + 1))
    eq(st2, proxy.CONNECTED, 'terminator split across chunks still connects')
    eq(a2, EARLY, 'leftover intact when the terminator was split')

    -- byte at a time, leftover arriving one byte per feed()
    local hs3 = newHS()
    local st3, a3, _, at = feedByByte(hs3, RESP)
    eq(st3, proxy.CONNECTED, 'byte-at-a-time with trailing bytes connects')
    eq(a3, '', 'byte-at-a-time leftover is empty -- the rest had not arrived yet')
    eq(at, #RESP - #EARLY, 'connected at the last byte of the header block, not later')
end)

runSuite('state machine: line-ending tolerance', function()
    -- DEVIATION: the reference reads until "\r\n\r\n" only and hangs on bare LF.
    local hs = newHS()
    eq(select(1, hs:feed('HTTP/1.1 200 OK\nProxy-agent: tiny\n\nZ')), proxy.CONNECTED,
       'bare-LF response is accepted')
    eq(hs.leftover, 'Z', 'bare-LF leftover correct')
    eq(hs.headers['proxy-agent'], 'tiny', 'bare-LF header parsed')

    local hs2 = newHS()
    eq(select(1, hs2:feed('HTTP/1.1 200 OK\r\nA: 1\nB: 2\r\n\n')), proxy.CONNECTED,
       'mixed CRLF/LF response is accepted')
    eq(hs2.headers['b'], '2', 'mixed line endings parse every header')

    -- leading blank lines before the status line (RFC 9112 robustness)
    local hs3 = newHS()
    eq(select(1, hs3:feed('\r\n\r\nHTTP/1.1 200 OK\r\n\r\n')), proxy.CONNECTED,
       'two leading blank lines tolerated')
    local hs4 = newHS()
    local st4, _, k4 = hs4:feed('\r\n\r\n\r\n\r\n\r\nHTTP/1.1 200 OK\r\n\r\n')
    eq(st4, proxy.ERROR, 'too many leading blank lines is an error')
    eq(k4, 'malformed', 'kind = malformed')

    -- obs-fold continuation
    local hs5 = newHS()
    hs5:feed('HTTP/1.1 200 OK\r\nX-Long: part1,\r\n   part2\r\n\r\n')
    eq(hs5.headers['x-long'], 'part1, part2', 'obs-fold continuation lines are joined')

    -- duplicate headers combine as an RFC list
    local hs6 = newHS()
    hs6:feed('HTTP/1.1 200 OK\r\nVia: a\r\nVia: b\r\n\r\n')
    eq(hs6.headers['via'], 'a, b', 'duplicate headers combine with ", "')
    eq(#hs6.headerList, 2, 'headerList keeps both occurrences')
end)

runSuite('state machine: 407 reports the realm', function()
    -- The realm string is the one the real proxy at 31.59.20.176:6754 answers with
    -- (docs/live-login-notes.md).
    local REALM = 'Invalid proxy credentials or missing IP Authorization.'
    local RESP = 'HTTP/1.1 407 Proxy Authentication Required\r\n' ..
                 'Proxy-Authenticate: Basic realm="' .. REALM .. '"\r\n' ..
                 'Content-Length: 0\r\n\r\n'

    local hs = newHS()
    local st, msg, kind = hs:feed(RESP)
    eq(st, proxy.ERROR, '407 is an error')
    eq(kind, 'auth-required', 'kind = auth-required')
    eq(hs.status, 407, 'status 407 recorded')
    eq(hs.realm, REALM, 'realm extracted from Proxy-Authenticate')
    eq(hs.authSchemes and hs.authSchemes[1], 'Basic', 'auth scheme reported')
    check(msg:find(REALM, 1, true) ~= nil, 'the error message quotes the realm', msg)
    check(msg:find('203.0.113.9:6754', 1, true) ~= nil, 'the message names the proxy endpoint')
    check(msg:find('game.example.net:7171', 1, true) ~= nil, 'the message names the target')

    -- byte at a time reaches the identical verdict
    local hs2 = newHS()
    local st2, _, kind2 = feedByByte(hs2, RESP)
    eq(st2, proxy.ERROR, '407 byte-at-a-time is an error')
    eq(kind2, 'auth-required', '407 byte-at-a-time kind')
    eq(hs2.realm, REALM, '407 byte-at-a-time realm')

    -- the state is sticky: feeding more does not resurrect it
    eq(select(1, hs2:feed('anything')), proxy.ERROR, 'a failed handshake stays failed')

    -- an unquoted realm is also accepted
    local hs3 = newHS()
    hs3:feed('HTTP/1.1 407 Nope\r\nProxy-Authenticate: Basic realm=corp\r\n\r\n')
    eq(hs3.realm, 'corp', 'unquoted realm token parsed')

    -- authSchemes is PLURAL: every scheme the proxy offers, not just the first.  Truncating to
    -- schemes[1] hid from the operator that Digest or NTLM would also be accepted -- exactly
    -- the diagnostic docs/proxy.md says the reference throws away and this module recovers.
    -- The split is quote-aware, so a comma inside a realm is part of the value, not a separator.
    local function schemesOf(v)
        local h = newHS()
        h:feed('HTTP/1.1 407 x\r\nProxy-Authenticate: ' .. v .. '\r\n\r\n')
        return table.concat(h.authSchemes or {}, '|'), h.realm
    end
    eq(schemesOf('Basic realm="r", Digest realm="d", NTLM'), 'Basic|Digest|NTLM',
       'all three offered schemes are reported')
    eq(schemesOf('Basic'), 'Basic', 'a single bare scheme still works')
    eq(schemesOf('Basic realm="corp"'), 'Basic', 'realm parameters are not mistaken for schemes')
    eq(select(2, schemesOf('Basic realm="a,b", NTLM')), 'a,b',
       'a comma INSIDE a quoted realm stays part of the realm')
    eq(schemesOf('Basic realm="a,b", NTLM'), 'Basic|NTLM',
       '   and does not split the challenge list')
    eq(schemesOf('Negotiate, Negotiate'), 'Negotiate', 'repeats are de-duplicated')

    -- a 403 is a plain rejection, not an auth problem
    local hs4 = newHS()
    local _, m4, k4 = hs4:feed('HTTP/1.1 403 Forbidden\r\n\r\n')
    eq(k4, 'rejected', '403 kind = rejected')
    check(m4:find('403 Forbidden', 1, true) ~= nil, '403 message quotes the status line')

    -- 2xx other than 200 is accepted, exactly like the reference
    local hs5 = newHS()
    eq(select(1, hs5:feed('HTTP/1.0 299 Weird\r\n\r\n')), proxy.CONNECTED,
       'any 2xx opens the tunnel (matches connection.cpp)')
end)

runSuite('state machine: malformed, oversized, EOF, timeout, 1xx', function()
    -- malformed status lines
    local cases = {
        { 'NOTHTTP 200 OK\r\n\r\n',        'non-HTTP first bytes' },
        { 'HTTP/1.1 2\r\n\r\n',            'reference would ACCEPT this ("2" after the space)' },
        { 'HTTP/1.1 20x OK\r\n\r\n',       'three-digit code required' },
        { 'HTTP/1.1\r\n\r\n',              'status line without a code' },
        { '\1\2\3\4\5\6\7\8\r\n\r\n',      'binary garbage' },
        -- The 3-digit code must be anchored at BOTH ends.  Without the trailing anchor the
        -- reason phrase absorbed the rest of the token: "2000 OK" parsed as 200 and opened a
        -- tunnel onto a dead pipe, and "4070 Nope" was reported as 407 'auth-required'.
        { 'HTTP/1.1 2000 OK\r\n\r\n',      'a 4-digit code is not 200' },
        { 'HTTP/1.1 200OK\r\n\r\n',        'no delimiter after the code' },
        { 'HTTP/1.1 2007\r\n\r\n',         'code run together with a digit' },
        { 'HTTP/1.1 299junk\r\n\r\n',      'code run together with a word' },
        { 'HTTP/1.1 4070 Nope\r\n\r\n',    'a 4-digit code is not 407 either' },
    }
    for _, c in ipairs(cases) do
        local hs = newHS()
        local st, msg, kind = hs:feed(c[1])
        eq(st, proxy.ERROR, 'malformed: ' .. c[2])
        eq(kind, 'malformed', 'malformed kind: ' .. c[2])
        check(msg ~= nil and #msg > 0, 'malformed message is non-empty')
        check(not msg:find('[^\32-\126]'), 'malformed message is printable only', vis(msg))
    end
    -- the non-HTTP fast path fires before a full line arrives
    local fast = newHS()
    local stF, _, kF = fast:feed('\5\1\0garbage')
    eq(stF, proxy.ERROR, 'non-HTTP answer rejected without waiting for a newline')
    eq(kF, 'malformed', 'non-HTTP fast-path kind')

    -- oversized header block (DEVIATION: the reference has no cap)
    local hs = newHS{ maxHeaderBytes = 256 }
    local st, _, kind = hs:feed('HTTP/1.1 200 OK\r\n' .. ('X-Pad: ' .. string.rep('a', 400) .. '\r\n'))
    eq(st, proxy.ERROR, 'header block over the cap is an error')
    eq(kind, 'too-large', 'kind = too-large')
    local ok9 = newHS{ maxHeaderBytes = 0 }
    eq(select(1, ok9:feed('HTTP/1.1 200 OK\r\nX: ' .. string.rep('a', 100000) .. '\r\n\r\n')),
       proxy.CONNECTED, 'maxHeaderBytes = 0 disables the cap')

    -- The cap must hold when the WHOLE oversized block arrives in ONE chunk: enforced only
    -- after the parse loop it was never reached, and 4 MB sailed past a 32 KiB cap.
    local one = newHS{ maxHeaderBytes = 32768 }
    local stB, _, kB = one:feed('HTTP/1.1 200 OK\r\nX-Pad: '
                                .. string.rep('a', 4 * 1024 * 1024) .. '\r\n\r\n')
    eq(stB, proxy.ERROR, 'a 4 MB header block in ONE chunk is refused')
    eq(kB, 'too-large', '   with kind = too-large')
    -- ... and a legitimate 200 followed by a huge tunnel payload in the same segment is NOT
    -- refused: the cap is about the header block, not about how much arrived with it.
    local pay = newHS{ maxHeaderBytes = 32768 }
    local stP, leftP = pay:feed('HTTP/1.1 200 OK\r\n\r\n' .. string.rep('z', 4 * 1024 * 1024))
    eq(stP, proxy.CONNECTED, 'a small header block plus a 4 MB tunnel payload still connects')
    eq(#leftP, 4 * 1024 * 1024, '   and every payload byte comes back as leftover')
    -- the same block delivered one byte at a time must reach the same verdict
    local drip = newHS{ maxHeaderBytes = 256 }
    local stD, kD
    local blob = 'HTTP/1.1 200 OK\r\nX-Pad: ' .. string.rep('a', 400) .. '\r\n\r\n'
    for i = 1, #blob do
        stD, _, kD = drip:feed(blob:sub(i, i))
        if stD ~= proxy.NEED_MORE then break end
    end
    eq(stD, proxy.ERROR, 'byte-at-a-time delivery hits the same cap')
    eq(kD, 'too-large', '   with the same kind')

    -- peer closed mid-handshake
    local hs2 = newHS()
    hs2:feed('HTTP/1.1 200 Conn')
    local st2, msg2, kind2 = hs2:eof()
    eq(st2, proxy.ERROR, 'EOF during the handshake is an error')
    eq(kind2, 'closed', 'kind = closed')
    check(msg2:find('17 bytes', 1, true) ~= nil, 'the EOF message reports how much arrived', msg2)

    -- timeout, driven entirely by the caller's clock
    local hs3 = newHS{ timeoutMs = 30000, nowMs = 1000 }
    eq(hs3:tick(1000), proxy.NEED_MORE, 'tick at t0 -> need-more')
    eq(hs3:tick(31000), proxy.NEED_MORE, 'tick exactly at the deadline -> need-more')
    local st3, msg3, kind3 = hs3:tick(31001)
    eq(st3, proxy.ERROR, 'tick past the deadline -> error')
    eq(kind3, 'timeout', 'kind = timeout')
    check(msg3:find('30000 ms', 1, true) ~= nil, 'the timeout message names the budget', msg3)
    eq(select(1, hs3:feed('HTTP/1.1 200 OK\r\n\r\n')), proxy.ERROR, 'a timed-out handshake stays failed')

    local hs4 = newHS{ timeoutMs = 0, nowMs = 0 }
    eq(hs4:tick(999999999), proxy.NEED_MORE, 'timeoutMs = 0 disables the timeout')

    -- feed() starts the clock when nowMs was not given at construction
    local hs5 = newHS{ timeoutMs = 100 }
    hs5:feed('HTTP/1.1 ', 5000)
    eq(hs5:tick(5050), proxy.NEED_MORE, 'clock starts at the first feed')
    eq(hs5:tick(5200), proxy.ERROR, 'and expires 100 ms later')

    -- 1xx interim responses (DEVIATION: the reference rejects them)
    local hs6 = newHS()
    local st6, a6 = hs6:feed('HTTP/1.1 100 Continue\r\nX: 1\r\n\r\nHTTP/1.1 200 OK\r\n\r\nTAIL')
    eq(st6, proxy.CONNECTED, '1xx is skipped and the following 2xx connects')
    eq(a6, 'TAIL', 'leftover after a skipped 1xx is correct')
    eq(hs6.interimCount, 1, 'the skipped interim response is counted')
    eq(hs6.headers['x'], nil, 'headers from the interim response are discarded')
    local hs7 = newHS{ interim = 'error' }
    local st7, _, k7 = hs7:feed('HTTP/1.1 100 Continue\r\n\r\n')
    eq(st7, proxy.ERROR, "interim = 'error' rejects 1xx like the reference")
    eq(k7, 'rejected', "interim = 'error' kind")

    -- A 1xx flood must be BOUNDED.  The skip branch resets self.buf, so maxHeaderBytes can
    -- never fire on it, and a feed-only transport (one that never runs tick()'s watchdog)
    -- would otherwise spin forever: 200k interim responses used to still say 'need-more'.
    local hs8 = newHS()
    local ONE = 'HTTP/1.1 100 Continue\r\n\r\n'
    local st8, k8
    for _ = 1, 1000 do
        st8, _, k8 = hs8:feed(ONE)
        if st8 ~= proxy.NEED_MORE then break end
    end
    eq(st8, proxy.ERROR, 'a 1xx flood is refused instead of looping forever')
    eq(k8, 'malformed', '   with kind = malformed')
    eq(hs8.interimCount, proxy.MAX_INTERIM + 1, '   after exactly MAX_INTERIM skips')
    -- ... while a handful of interim responses is still tolerated, as RFC 9110 requires
    local hs9 = newHS()
    local st9, a9 = hs9:feed(string.rep(ONE, proxy.MAX_INTERIM) .. 'HTTP/1.1 200 OK\r\n\r\nT')
    eq(st9, proxy.CONNECTED, 'MAX_INTERIM interim responses followed by a 200 still connects')
    eq(a9, 'T', '   with the right leftover')
end)

runSuite('state machine: no credential ever leaks into text', function()
    local SECRET = 'sUpErSeCrEt-do-not-print'
    local hs = newHS{ user = 'bob', pass = SECRET }
    check(hs.request:find(proxy.base64('bob:' .. SECRET), 1, true) ~= nil,
          'the request does carry the credential (sanity)')
    check(not hs.requestRedacted:find(proxy.base64('bob:' .. SECRET), 1, true),
          'requestRedacted does not')
    check(not tostring(hs):find(SECRET, 1, true), 'tostring(handshake) does not print it')
    check(not tostring(hs):find(proxy.base64('bob:' .. SECRET), 1, true),
          'tostring(handshake) does not print the encoded blob')
    local _, msg = hs:feed('HTTP/1.1 407 Nope\r\nProxy-Authenticate: Basic realm="x"\r\n\r\n')
    check(not msg:find(SECRET, 1, true), 'the 407 message does not contain the password')
    check(not msg:find(proxy.base64('bob:' .. SECRET), 1, true),
          'the 407 message does not contain the encoded credential')
    local hs2 = newHS{ user = 'bob', pass = SECRET, timeoutMs = 1, nowMs = 0 }
    local _, tmsg = hs2:tick(1000)
    check(not tmsg:find(SECRET, 1, true), 'the timeout message does not contain the password')
end)

-- =================================================== end-to-end, real socket ==
-- A tiny HTTP CONNECT proxy on 127.0.0.1, built on lib/socket.lua: it accepts a
-- CONNECT, optionally demands Basic auth, answers 200 and then echoes every byte
-- of the "tunnel".  Non-blocking throughout, polled from the same loop as the
-- client, so the whole test is single-threaded.

local TEST_REALM = 'luaclient test proxy'

local function newTestProxy(opts)
    opts = opts or {}
    local L, err = socket.listen('127.0.0.1', 0)
    if not L then return nil, err end
    local P = { listener = L, port = L.boundPort, conns = {}, requests = {}, opts = opts }

    function P:respond(head)
        local auth = head:match('[Pp]roxy%-[Aa]uthorization:[ \t]*([^\r\n]*)')
        if opts.requireAuth then
            local want = 'Basic ' .. proxy.base64((opts.user or '') .. ':' .. (opts.pass or ''))
            if auth ~= want then
                return false, 'HTTP/1.1 407 Proxy Authentication Required\r\n' ..
                              'Proxy-Authenticate: Basic realm="' .. TEST_REALM .. '"\r\n' ..
                              'Content-Length: 0\r\n\r\n'
            end
        end
        local eol = opts.bareLF and '\n' or '\r\n'
        return true, 'HTTP/1.1 200 Connection established' .. eol ..
                     'Proxy-agent: luaclient-test-proxy/1' .. eol .. eol ..
                     (opts.earlyBytes or '')
    end

    -- Returns 'keep' or 'drop'.
    local function service(k)
        if #k.out > 0 then
            local n = opts.dribble and 1 or #k.out
            local sent = k.sock:send(k.out:sub(1, n))
            if sent == nil then return 'drop' end
            k.out = k.out:sub(n + 1)
            return 'keep'                        -- one piece per poll
        end
        local fl = k.sock:flush()
        if fl == nil then return 'drop' end
        if k.closeAfter and fl == true then return 'drop' end
        local data = k.sock:recv(4096)
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
                    if #rest > 0 then k.out = k.out .. rest end   -- echo pipelined bytes
                else
                    k.closeAfter = true
                end
            end
        else
            k.out = k.out .. data                                  -- echo
        end
        return 'keep'
    end

    function P:poll()
        local c = self.listener:accept()
        if c then
            self.conns[#self.conns + 1] = { sock = c, buf = '', out = '', phase = 'head' }
        end
        for i = #self.conns, 1, -1 do
            if service(self.conns[i]) == 'drop' then
                pcall(function() self.conns[i].sock:close() end)
                table.remove(self.conns, i)
            end
        end
    end

    function P:close()
        for i = 1, #self.conns do pcall(function() self.conns[i].sock:close() end) end
        self.conns = {}
        pcall(function() self.listener:close() end)
    end

    return P
end

--- Drive one client through the proxy.  Returns a result table.
--- `expectBytes` = how many tunnel bytes to wait for before returning (early
--- bytes + echo).  It cannot be derived from `leftover`: when the proxy dribbles
--- its answer the early bytes have not arrived yet at the moment we connect.
local function tunnelThrough(P, over, payload, expectBytes, budgetMs)
    budgetMs = budgetMs or 10000
    local o = { host = 'game.example.net', port = 7171,
                proxyHost = '127.0.0.1', proxyPort = P.port }
    for k, v in pairs(over or {}) do o[k] = v end
    local hs, herr = proxy.newHandshake(o)
    if not hs then return { err = herr } end

    local s = socket.tcp()
    local ok, cerr = s:connect('127.0.0.1', P.port)
    if not ok then return { err = cerr } end

    local res, sentReq, echo, t0 = { hs = hs }, false, '', sys.nowMs()
    while true do
        if sys.nowMs() - t0 > budgetMs then res.err = 'test harness timeout'; break end
        P:poll()

        if not sentReq then
            if s:isConnected() then
                local n, serr = s:send(hs.request)
                if not n then res.err = 'send: ' .. tostring(serr); break end
                sentReq = true
            end
        elseif not (hs:isDone() or hs:isFailed()) then
            s:flush()
            local data = s:recv(4096)
            if data == nil then
                local st, msg, kind = hs:eof()
                res.status, res.msg, res.kind = st, msg, kind
                break
            end
            local st, a, b
            if #data > 0 then st, a, b = hs:feed(data, sys.nowMs())
            else               st, a, b = hs:tick(sys.nowMs()) end
            if st == proxy.CONNECTED then
                res.status, res.leftover = st, a
                echo = a
                if payload then s:send(payload) end
                if not payload then break end
            elseif st == proxy.ERROR then
                res.status, res.msg, res.kind = st, a, b
                break
            end
        else
            s:flush()
            local data = s:recv(4096)
            if data == nil then break end
            if #data > 0 then echo = echo .. data end
            if #echo >= (expectBytes or (#(res.leftover or '') + #payload)) then break end
        end
        sys.sleepMs(1)
    end
    s:close()
    res.echo = echo
    return res
end

runSuite('end-to-end through a real loopback proxy', function()
    local EARLY   = 'EARLY!'
    local PAYLOAD = 'the world name would go here\n\0\1\2\255binary-safe'

    -- 1. no auth, response delivered whole, early bytes present
    local P = newTestProxy{ earlyBytes = EARLY }
    check(P ~= nil, 'test proxy bound a loopback port')
    if not P then return end
    check(P.port and P.port > 0, 'ephemeral port allocated: ' .. tostring(P.port))

    local r = tunnelThrough(P, nil, PAYLOAD, #EARLY + #PAYLOAD)
    eq(r.err, nil, 'no harness error')
    eq(r.status, proxy.CONNECTED, 'tunnel opened over a real socket')
    eq(r.leftover, EARLY, 'early bytes sent right after the 200 arrive as leftover')
    eq(r.echo, EARLY .. PAYLOAD, 'every payload byte came back through the tunnel')
    eq(#P.requests, 1, 'the proxy saw exactly one CONNECT')
    eq(P.requests[1], REF_NOAUTH, 'the bytes the proxy received are the reference request')
    P:close()

    -- 2. the same, but the proxy dribbles its response ONE BYTE PER POLL
    local P2 = newTestProxy{ dribble = true, earlyBytes = EARLY }
    local r2 = tunnelThrough(P2, nil, 'ping', #EARLY + 4)
    eq(r2.err, nil, 'no harness error (dribbled)')
    eq(r2.status, proxy.CONNECTED, 'tunnel opens when the response arrives one byte per read')
    eq(r2.leftover, '', 'a dribbled response leaves nothing over at the connect instant')
    eq(r2.echo, EARLY .. 'ping', 'dribbled tunnel still delivers the early bytes then the echo')
    P2:close()

    -- 3. bare-LF proxy (the reference client would hang here)
    local P3 = newTestProxy{ bareLF = true }
    local r3 = tunnelThrough(P3, nil, 'lf', 2)
    eq(r3.status, proxy.CONNECTED, 'a bare-LF proxy response opens the tunnel')
    eq(r3.echo, 'lf', 'echo through the bare-LF tunnel')
    P3:close()

    -- 4. auth required: wrong/absent credentials -> 407 with the realm
    local P4 = newTestProxy{ requireAuth = true, user = 'bob', pass = 's3cr3t' }
    local r4 = tunnelThrough(P4, {}, nil, 0)
    eq(r4.status, proxy.ERROR, 'no credentials -> error')
    eq(r4.kind, 'auth-required', 'kind = auth-required over a real socket')
    eq(r4.hs.status, 407, 'status 407')
    eq(r4.hs.realm, TEST_REALM, 'realm reported from the real 407')
    check(not r4.msg:find('s3cr3t', 1, true), 'the real 407 message carries no password')

    local r5 = tunnelThrough(P4, { user = 'bob', pass = 'wrong' }, nil, 0)
    eq(r5.kind, 'auth-required', 'wrong credentials -> auth-required')

    -- 5. correct credentials -> tunnel
    local r6 = tunnelThrough(P4, { user = 'bob', pass = 's3cr3t' }, 'authed-payload', 14)
    eq(r6.status, proxy.CONNECTED, 'correct credentials open the tunnel')
    eq(r6.echo, 'authed-payload', 'echo through the authenticated tunnel')
    local last = P4.requests[#P4.requests]
    check(last:find('Proxy%-Authorization: Basic Ym9iOnMzY3IzdA==') ~= nil,
          'the proxy received exactly the reference Proxy-Authorization header')
    eq(last, REF_AUTH, 'the authenticated request is byte-identical to the reference')
    P4:close()
end)

-- ======================================================================= dump
if DUMP then
    io.write('\n-- reference CONNECT request, no auth (', #REF_NOAUTH, ' bytes) --\n')
    local function hexdump(s)
        for off = 0, #s - 1, 16 do
            local chunk = s:sub(off + 1, off + 16)
            local hex, asc = {}, {}
            for i = 1, #chunk do
                hex[i] = ('%02X'):format(chunk:byte(i))
                local c = chunk:byte(i)
                asc[i] = (c >= 32 and c < 127) and chunk:sub(i, i) or '.'
            end
            io.write(('%s%s   %s\n'):format(table.concat(hex, ' '),
                     string.rep('   ', 16 - #chunk), table.concat(asc)))
        end
    end
    hexdump(REF_NOAUTH)
    io.write('-- with auth (', #REF_AUTH, ' bytes) --\n')
    hexdump(REF_AUTH)
end

-- ===================================================================== report
io.write('\n================ proxysuite ================\n')
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
