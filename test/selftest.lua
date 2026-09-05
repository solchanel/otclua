--[[============================================================================
test/selftest.lua -- offline self-checks for every module of the client.

  luajit test/selftest.lua              (from D:/Claude/otclient_web/luaclient)
  luajit main.lua --selftest

Exits non-zero if ANY check fails and prints a PASS/FAIL summary per module.

Reference values were produced with Python 3 (zlib / a transcription of
protocol.cpp's XTEA / pow(m,65537,n)) -- the generator lives in the session
scratchpad; the vectors below are frozen copies of its output.  Nothing here
touches the network: the socket/scheduler suite uses a 127.0.0.1 loopback pair.
============================================================================]]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. package.path
end

-- =========================================================== tiny framework
local suites, cur = {}, nil
local totalPass, totalFail = 0, 0

local function suite(name)
    cur = { name = name, pass = 0, fail = 0, msgs = {} }
    suites[#suites + 1] = cur
    return cur
end

local function check(ok, desc, detail)
    if ok then
        cur.pass = cur.pass + 1
        totalPass = totalPass + 1
    else
        cur.fail = cur.fail + 1
        totalFail = totalFail + 1
        local line = '    FAIL  ' .. desc .. (detail and ('  -- ' .. tostring(detail)) or '')
        cur.msgs[#cur.msgs + 1] = line
        io.write(line, '\n')
    end
    return ok
end

local function eq(got, want, desc)
    if got == want then return check(true, desc) end
    local g, w = tostring(got), tostring(want)
    if #g > 90 then g = g:sub(1, 87) .. '...' end
    if #w > 90 then w = w:sub(1, 87) .. '...' end
    return check(false, desc, ('got %s, want %s'):format(g, w))
end

local function raises(fn, pattern, desc)
    local ok, err = pcall(fn)
    if ok then return check(false, desc, 'no error was raised') end
    err = tostring(err)
    if pattern and not err:find(pattern, 1, true) then
        return check(false, desc, ('error %q does not contain %q'):format(err, pattern))
    end
    return check(true, desc)
end

local function runSuite(name, fn)
    suite(name)
    local ok, err = pcall(fn)
    if not ok then
        cur.fail = cur.fail + 1
        totalFail = totalFail + 1
        local line = '    FAIL  suite crashed: ' .. tostring(err)
        cur.msgs[#cur.msgs + 1] = line
        io.write(line, '\n')
    end
end

-- ------------------------------------------------------------------ hex utils
local function fromhex(h)
    return (h:gsub('%x%x', function(cc) return string.char(tonumber(cc, 16)) end))
end
local HEXD = {}
for b = 0, 255 do HEXD[string.char(b)] = ('%02x'):format(b) end
local function tohex(s) return (s:gsub('.', HEXD)) end

-- =============================================================== lib.buffer
local buffer = require('lib.buffer')

runSuite('lib.buffer', function()
    local W = buffer.writer()
    W:u8(0x12):u16(0x3456):u32(0x89ABCDEF):u64(4328719365)
    W:string('Gunzodus'):bytes('\255\0'):pad(3, 0xAA)
    local data = W:data()
    eq(tohex(data),
       '125634efcdab890504030201000000080047756e7a6f647573ff00aaaaaa',
       'writer byte image')
    eq(W:size(), #data, 'writer:size matches data()')

    local R = buffer.reader(data)
    eq(R:u8(), 0x12, 'reader u8')
    eq(R:u16(), 0x3456, 'reader u16')
    eq(R:u32(), 0x89ABCDEF, 'reader u32')
    eq(R:u64(), 4328719365, 'reader u64')
    eq(R:string(), 'Gunzodus', 'reader string (u16 len + bytes)')
    eq(R:u8(), 255, 'reader u8 255')
    eq(R:u8(), 0, 'reader u8 0')
    eq(R:remaining(), 3, 'remaining()')
    eq(R:pos(), #data - 3, 'pos() is 0-based bytes consumed')
    R:skip(3)
    eq(R:eof(), true, 'eof after consuming everything')

    -- u64hex is exact above 2^53
    eq(buffer.reader(fromhex('efcdab8967452301')):u64hex(), '0123456789ABCDEF', 'u64hex exact')

    -- signed readers
    eq(buffer.reader('\255'):i8(), -1, 'i8 -1')
    eq(buffer.reader('\255\255'):i16(), -1, 'i16 -1')
    eq(buffer.reader('\255\255\255\255'):i32(), -1, 'i32 -1')

    -- InputMessage::getDouble: u8 precision + (u32 - INT_MAX)
    local D = buffer.writer(); D:u8(2); D:u32(2147483647)
    eq(buffer.reader(D:data()):double(), 0, 'double(prec 2, raw INT_MAX) == 0')
    local D2 = buffer.writer(); D2:double(857.36, 2)
    eq(buffer.reader(D2:data()):double(), 857.36, 'writer:double round-trips 857.36')
    local D3 = buffer.writer(); D3:double(-4795.01, 2)
    eq(buffer.reader(D3:data()):double(), -4795.01, 'writer:double round-trips -4795.01')

    raises(function() buffer.reader('\1\2\3'):u32() end,
           'over-read', 'over-read raises and names the offset')
    raises(function() buffer.writer():string(string.rep('x', 70000)) end,
           'too long', 'writer:string rejects > 65535 bytes')
end)

-- ================================================================= lib.xtea
runSuite('lib.xtea', function()
    local xtea = require('lib.xtea')
    local K = { 0x01234567, 0x89ABCDEF, 0xDEADBEEF, 0xCAFEBABE }
    local Z = { 0, 0, 0, 0 }
    local vectors = {
        { K, '3132333435363738', '508a5050faa8b496' },
        { K, '000102030405060708090a0b0c0d0e0f', '516809a75f95a3067fbf92aed1b4d981' },
        { K, '030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bc',
             '0f784039bf6d6fc8f2bd4201f04786ccba8bedc72c08039c86ed0d7220c2e0a0de4fb05825fb8e9718666a6c0220244fbf54a6a6083fe512a0f66faf3a04d8a1' },
        { Z, '3132333435363738', '7cf6853b95069c2b' },
        { Z, '000102030405060708090a0b0c0d0e0f', 'd348e8d5655f79b293acf0a4d302ae49' },
    }
    for i, v in ipairs(vectors) do
        local key, plain, cipher = v[1], fromhex(v[2]), v[3]
        eq(tohex(xtea.encrypt(key, plain)), cipher, ('encrypt vector #%d (%d B)'):format(i, #plain))
        eq(tohex(xtea.decrypt(key, fromhex(cipher))), v[2], ('decrypt vector #%d'):format(i))
    end
    raises(function() xtea.encrypt(K, 'seven..') end, 'multiple of 8',
           'non-multiple-of-8 plaintext is rejected')
end)

-- ============================================================== lib.adler32
runSuite('lib.adler32', function()
    local adler32 = require('lib.adler32')
    eq(('%08X'):format(adler32.sum('')), '00000001', 'adler32("")')
    eq(('%08X'):format(adler32.sum('a')), '00620062', 'adler32("a")')
    eq(('%08X'):format(adler32.sum('abc')), '024D0127', 'adler32("abc")')
    eq(('%08X'):format(adler32.sum('Gunzodus')), '0EAE0360', 'adler32("Gunzodus")')
    local big = {}
    for i = 0, 255 do big[#big + 1] = string.char(i) end
    big = string.rep(table.concat(big), 4)
    eq(('%08X'):format(adler32.sum(big)), 'E4C9FE10', 'adler32(1024 bytes)')
end)

-- ================================================================== lib.rsa
runSuite('lib.rsa', function()
    local rsa = require('lib.rsa')
    local sys = require('lib.sys')
    eq(rsa.size(), 128, 'rsa.size() == 128')
    local vectors = {
        { '0011304f6e8daccbea0928476685a4c3e201203f5e7d9cbbdaf91837567594b3d2f1102f4e6d8cabcae90827466584a3c2e1001f3e5d7c9bbad9f81736557493b2d1f00f2e4d6c8baac9e80726456483a2c1e0ff1e3d5c7b9ab9d8f71635547392b1d0ef0e2d4c6b8aa9c8e70625446382a1c0dffe1d3c5b7a99b8d7f6153453',
          '4799b078cc2fc76864c08861aac0f2e91dbe83f5db78e31242ca9ce6f7a21b23d71b54182a04372877cb6872691658fce44a1f11a03eb766070dec9293d379902223adbfaaecca5d5c0a4fc5a50dc833b877b0cec0328bfdf9c78db8a401f3916175c72eea33a32041fcccb02edc187f93931fb5cd24eecba0a42862837e44e6' },
        { '00114f8dcb094785c3013f7dbbf93775b3f12f6dabe92765a3e11f5d9bd9175593d10f4d8bc9074583c1ff3d7bb9f73573b1ef2d6ba9e72563a1df1d5b99d7155391cf0d4b89c7054381bffd3b79b7f53371afed2b69a7e523619fdd1b5997d513518fcd0b4987c503417fbdfb3977b5f3316fadeb2967a5e3215f9ddb195795',
          '7178ed04876c4d33028cee8e2a11489e158c1e284bf7baf9dc46b2229616f0265f7f6fc9915bbc698728178f317407eb36c2acabfb8539e0d8d2fddd7f280b24e0a8673351bf23cd01f9c56a56642ee8048fbced182fc15f64b08a65da8a32e145cf3cd55f72b5e43b4cb442402ea8aaa2bb4f580bd147fe814eea5461393666' },
    }
    local t0 = sys.nowMs()
    for i, v in ipairs(vectors) do
        local out = rsa.encrypt(fromhex(v[1]))
        eq(#out, 128, ('vector #%d output is 128 bytes'):format(i))
        eq(tohex(out), v[2], ('m^65537 mod n vector #%d'):format(i))
    end
    local ms = (sys.nowMs() - t0) / #vectors
    check(ms < 500, ('rsa.encrypt < 500 ms (measured %.1f ms/op)'):format(ms), ms)
end)

-- ============================================================== lib.inflate
runSuite('lib.inflate', function()
    local inflate = require('lib.inflate')
    local adler32 = require('lib.adler32')

    -- PER_PACKET (Z_FINISH)
    local once = {
        { 'cb48cdc9c95748cecf2d284a2d2e4e4d512848acccc94f4c0100', 24, 0x75CE0974 },
        { '6360181ec0d1c9d9c5d5cddd6394268f0600', 520, 0xAD6355A1 },
    }
    for i, v in ipairs(once) do
        local out = inflate.once(fromhex(v[1]))
        if check(out ~= nil, ('inflate.once vector #%d returned data'):format(i)) then
            eq(#out, v[2], ('inflate.once vector #%d length'):format(i))
            eq(adler32.sum(out), v[3], ('inflate.once vector #%d content (adler32)'):format(i))
        end
    end
    eq(inflate.once('not a deflate stream at all'), nil, 'inflate.once rejects garbage')
    eq(inflate.once(fromhex('cb48cdc9c957')), nil, 'inflate.once rejects a truncated stream')

    -- STREAM (Z_SYNC_FLUSH, one persistent stream, never reset)
    local stream = {
        { '0ac94855282ccd4cce56482aca2fcf5348cbaf50c82acd2d2856c82f4b2d5228014ae72456552aa4e4a7eb29848c2a265731000000ffff', 360, 0x65318139 },
        { '1a554c27c58e9e3e00000000ffff', 364, 0x6D248263 },
    }
    local z = inflate.new()
    for i, v in ipairs(stream) do
        local out = z:inflateSyncFlush(fromhex(v[1]))
        eq(#out, v[2], ('sync-flush chunk #%d length'):format(i))
        eq(adler32.sum(out), v[3], ('sync-flush chunk #%d content (adler32)'):format(i))
    end
    -- chunk 2 is only 14 compressed bytes: it can only expand to 364 bytes by
    -- back-referencing chunk 1's window, i.e. the stream really is persistent.

    -- the same stream fed one byte at a time
    local z2 = inflate.new()
    local acc = {}
    for _, v in ipairs(stream) do
        local raw = fromhex(v[1])
        for k = 1, #raw do
            local piece = z2.inflateChunk and z2:inflateChunk(raw:sub(k, k)) or nil
            if piece and #piece > 0 then acc[#acc + 1] = piece end
        end
    end
    if z2.inflateChunk then
        eq(#table.concat(acc), 360 + 364, 'byte-at-a-time feed produces the same total output')
    end
end)

-- ================================================================== lib.sys
runSuite('lib.sys', function()
    local sys = require('lib.sys')
    local a = sys.randomBytes(16)
    local b = sys.randomBytes(16)
    eq(#a, 16, 'randomBytes(16) length')
    check(a ~= b, 'two random draws differ')
    local distinct = {}
    for i = 1, #a do distinct[a:byte(i)] = true end
    local n = 0; for _ in pairs(distinct) do n = n + 1 end
    check(n > 4, ('randomBytes is not constant (%d distinct byte values)'):format(n), n)
    local u = sys.randomU32()
    check(u >= 0 and u < 2 ^ 32 and u == math.floor(u), 'randomU32 in range', u)
    local t0 = sys.nowMs()
    sys.sleepMs(20)
    local dt = sys.nowMs() - t0
    check(dt >= 15 and dt < 200, ('nowMs is monotonic across a 20 ms sleep (%.1f ms)'):format(dt), dt)
end)

-- =============================================================== lib.events
runSuite('lib.events', function()
    local events = require('lib.events')
    local bus = events.new()
    local seen = {}
    local h1 = bus:on('tick', function(d) seen[#seen + 1] = 'a' .. tostring(d) end)
    bus:on('tick', function(d) seen[#seen + 1] = 'b' .. tostring(d) end)
    local anySeen = {}
    bus:onAny(function(name) anySeen[#anySeen + 1] = name end)
    eq(bus:emit('tick', 1), 3, 'emit invoked 2 named + 1 onAny handler')
    eq(table.concat(seen, ','), 'a1,b1', 'named handlers run in registration order')
    eq(anySeen[1], 'tick', 'onAny receives the event name')
    bus:off(h1)
    seen = {}
    bus:emit('tick', 2)
    eq(table.concat(seen, ','), 'b2', 'off() removes exactly one handler')
    eq(bus:count('tick'), 1, 'count() after off')

    -- a throwing handler must not stop the others
    io.write('    (the next ERROR line is deliberate: a throwing handler must be contained)\n')
    local reached = false
    bus:on('boom', function() error('deliberate') end)
    bus:on('boom', function() reached = true end)
    bus:emit('boom')
    check(reached, 'a throwing handler does not stall the rest')
    check(bus.errors >= 1, 'the bus counted the handler error', bus.errors)

    -- the module itself is a bus (LC.events)
    local got
    local h = events.on('x', function(d) got = d end)
    events.emit('x', 42)
    eq(got, 42, 'module-level bus works')
    events.off(h)
end)

-- ============================================================== proto.items
local items = require('proto.items')
runSuite('proto.items', function()
    items.load(ROOT .. '/assets/items1530.bin')
    eq(items.MAX_ID, 62144, 'items.MAX_ID')
    eq(items.COUNT, 43536, 'items.COUNT (ids with an appearance)')
    eq(items.CONTENT_REVISION, 42196, 'content revision in the header')
    eq(items.flags(1), 0, 'id 1 has no attribute flags')
    eq(items.flags(130), items.CUMULATIVE, 'id 130 is CUMULATIVE')
    eq(items.flags(645), items.CLASSIFY, 'id 645 is CLASSIFY')
    eq(items.flags(111), items.CONTAINER, 'id 111 is CONTAINER')
    eq(items.flags(62144), items.flags(62144), 'the last id is readable')
    raises(function() items.flags(0) end, 'out of range', 'id 0 raises')
    raises(function() items.flags(items.MAX_ID + 1) end, 'out of range', 'id > MAX_ID raises')
    -- flag bit constants must match tools/extract_appearances.py
    eq(items.CUMULATIVE, 0x01, 'CUMULATIVE bit')
    eq(items.WEAROUT, 0x02, 'WEAROUT bit')
    eq(items.EXPIRE, 0x04, 'EXPIRE bit')
    eq(items.CONTAINER, 0x08, 'CONTAINER bit')
    eq(items.CLASSIFY, 0x10, 'CLASSIFY bit')
    eq(items.PODIUM, 0x20, 'PODIUM bit')
    eq(items.DECOKIT, 0x40, 'DECOKIT bit')
end)

-- ========================================================== proto.handshake
local handshake = require('proto.handshake')
runSuite('proto.handshake', function()
    -- hwid: FNV-1a-32 over the account name, "%04X-%04X"
    local hw = {
        { '', '811C-9DC5' }, { 'a', 'E40C-292C' }, { 'testaccount', '2879-7EFC' },
        { 'arnold@l4g.dev', '99F6-9175' }, { 'zzz-not-a-real-account', '13BC-D9A0' },
    }
    for _, v in ipairs(hw) do
        eq(handshake.hwid(v[1]), v[2], ('hwid(%q)'):format(v[1]))
    end

    -- the login JSON body (nlohmann: compact, lexicographic keys)
    eq(handshake.buildLoginBody('a@b.c', 'secret', nil),
       '{"email":"a@b.c","password":"secret","stayloggedin":true,"type":"login"}',
       'login body without a token')
    eq(handshake.buildLoginBody('a@b.c', 'p"w\\x', '12345678'),
       '{"authenticatorToken":"12345678","email":"a@b.c","password":"p\\"w\\\\x","stayloggedin":true,"token":"12345678","type":"login"}',
       'login body with a token and JSON escaping')

    -- the login packet, fixed inputs -> a byte-exact prefix and a 151-byte body
    local body, key = handshake.buildLoginPacket{
        sessionKey      = 'FAKESESSIONKEY-0123456789abcdef',
        characterName   = 'TestChar',
        challengeTs     = 0x11223344,
        challengeRand   = 0x5A,
        contentRevision = 42196,
        xteaKey         = { 0x01234567, 0x89ABCDEF, 0xDEADBEEF, 0xCAFEBABE },
    }
    eq(#body, 151, 'login body is 23 prefix + 128 RSA bytes')
    eq(tohex(body:sub(1, 23)),
       '0a3d00fa05fa05000004003135333005003432313936' .. '00',
       'login prefix: 0x0A, os 61, proto 1530, cv 1530, "1530", "42196", preview 0')
    eq(key[1], 0x01234567, 'buildLoginPacket returns the key it used')
    -- the RSA tail must be deterministic for deterministic inputs
    local body2 = handshake.buildLoginPacket{
        sessionKey = 'FAKESESSIONKEY-0123456789abcdef', characterName = 'TestChar',
        challengeTs = 0x11223344, challengeRand = 0x5A, contentRevision = 42196,
        xteaKey = { 0x01234567, 0x89ABCDEF, 0xDEADBEEF, 0xCAFEBABE },
    }
    eq(tohex(body), tohex(body2), 'the login packet is deterministic')
    raises(function()
        handshake.buildLoginPacket{ sessionKey = string.rep('S', 90),
                                    characterName = string.rep('C', 20),
                                    xteaKey = { 1, 2, 3, 4 } }
    end, 'RSA block overflow', 'an over-long session key + name is rejected')

    -- httpLogin delegates to proto/login_http (no network: http.post is injected;
    -- login_http logs the URL it would use, so quiet the logger for this block)
    local log = require('lib.log')
    local prevLevel = log.getLevel()
    log.setLevel('error')
    local captured
    local fakeHttp = { post = function(url, headers, body)
        captured = { url = url, headers = headers, body = body }
        return { status = 200, headers = {}, body = [[{"session":{"sessionkey":"SK"},
            "playdata":{"worlds":[{"id":0,"name":"Gunzodus",
            "externaladdressprotected":"51.83.246.10","externalportprotected":7172}],
            "characters":[{"name":"Bot","worldid":0,"level":8}]}}]] }
    end }
    local res = handshake.httpLogin{ account = 'a@b.c', password = 'pw', http = fakeHttp }
    if check(res ~= nil, 'httpLogin returns a result table') then
        eq(res.sessionKey, 'SK', 'httpLogin sessionKey')
        eq(res.characters[1].name, 'Bot', 'httpLogin character')
        eq(res.characters[1].host, '51.83.246.10', 'httpLogin character host')
        eq(res.characters[1].worldName, 'Gunzodus', 'httpLogin character worldName alias')
        eq(res.worlds[0].port, 7172, 'httpLogin world port')
    end
    eq(captured.body, '{"email":"a@b.c","password":"pw","stayloggedin":true,"type":"login"}',
       'httpLogin put the reference body on the wire')
    eq(captured.headers['Host'], 'www.gunzodus.net', 'httpLogin Host header')

    local bad, badMsg, badCode = handshake.httpLogin{ account = 'a@b.c', password = 'pw',
        http = { post = function() return { status = 200, headers = {},
            body = '{"errorCode":6}' } end } }
    eq(bad, nil, 'httpLogin propagates a login failure')
    eq(badMsg, 'Authenticator token required.', 'httpLogin propagates the server message')
    eq(badCode, 6, 'httpLogin propagates the numeric errorCode (2FA)')
    log.setLevel(prevLevel)

    -- enter-game: TWO separate bodies
    local frames = handshake.buildEnterGameFrames('testaccount')
    eq(#frames, 2, 'buildEnterGameFrames returns two bodies')
    eq(tohex(frames[1]), '0f', 'frame 1 is [0x0F]')
    eq(tohex(frames[2]), '320a0900' .. tohex('2879-7EFC'), 'frame 2 is [0x32][0x0A][u16 9][hwid]')
end)

-- ========================================================= proto.login_http
runSuite('proto.login_http', function()
    local lh = require('proto.login_http')
    eq(lh.buildBody('a@b.c', 'secret', nil),
       '{"email":"a@b.c","password":"secret","stayloggedin":true,"type":"login"}',
       'buildBody matches the reference bytes')
    local h = lh.headers('www.gunzodus.net')
    local n = 0; for _ in pairs(h) do n = n + 1 end
    eq(n, 6, 'exactly six request headers')
    eq(h['User-Agent'], 'Mozilla/5.0', 'User-Agent')
    eq(h['Accept-Encoding'], 'br', 'Accept-Encoding')

    local res, msg, code = lh.parseResponse(200, '{"errorCode":6}')
    eq(res, nil, 'errorCode 6 -> no result')
    eq(msg, 'Authenticator token required.', 'errorCode 6 default message')
    eq(code, 6, 'errorCode 6 is reported to the caller')

    res, msg, code = lh.parseResponse(200,
        '{"errorCode":3,"errorMessage":"Account name or password is not correct."}')
    eq(msg, 'Account name or password is not correct.', 'errorCode 3 message passes through')
    eq(code, 3, 'errorCode 3')

    res, msg = lh.parseResponse(200, 'not json at all')
    eq(msg, 'Invalid response received from server (expected JSON).', 'non-JSON body')

    res, msg = lh.parseResponse(200, '{"session":{"sessionkey":"K"},"playdata":{}}')
    eq(msg, 'Missing characters or worlds.', 'missing playdata contents')

    res = lh.parseResponse(200, [[{"session":{"sessionkey":"SK","premiumuntil":123},
        "playdata":{"worlds":[{"id":0,"name":"Gunzodus","externaladdressprotected":"51.83.246.10",
        "externalportprotected":7172,"previewstate":0,"pvptype":2}],
        "characters":[{"name":"Bot","worldid":0,"level":8,"vocation":1}]}}]])
    if check(res ~= nil, 'a well-formed reply parses') then
        eq(res.sessionKey, 'SK', 'sessionKey')
        eq(res.worlds[0].host, '51.83.246.10', 'world host (externaladdressprotected)')
        eq(res.worlds[0].port, 7172, 'world port (externalportprotected)')
        eq(res.characters[1].name, 'Bot', 'character name')
        eq(res.characters[1].host, '51.83.246.10', 'character inherits the world address')
    end
end)

-- ========================================================== proto.transport
local transport = require('proto.transport')

-- A "server" transport: same framing code, no gunz compression header.
local function peerFor(t)
    local p = transport.new{ gunzOs = false, onMessage = function() end }
    if t and t.xteaOn then p:enableXtea(t.xteaKey) end
    return p
end

runSuite('proto.transport', function()
    -- 1. round trip with XTEA OFF
    local got = {}
    local t = transport.new{ onMessage = function(m) got[#got + 1] = m end }
    t._write = function() return true end
    local peer = peerFor(t)
    for len = 1, 40 do
        local body = string.rep('\7', len)
        local ok = t:feed(peer:buildFrame(body))
        if not ok then check(false, 'xtea-off frame ' .. len .. ' was rejected'); break end
        if got[#got] ~= body then
            check(false, ('xtea-off round-trip len %d'):format(len), tohex(got[#got] or ''))
            break
        end
    end
    eq(#got, 40, 'XTEA off: 40 frames delivered, padding stripped on EVERY frame')

    -- 2. round trip with XTEA ON
    got = {}
    local t2 = transport.new{ onMessage = function(m) got[#got + 1] = m end }
    t2._write = function() return true end
    t2:enableXtea({ 0x01234567, 0x89ABCDEF, 0xDEADBEEF, 0xCAFEBABE })
    local peer2 = peerFor(t2)
    for len = 1, 40 do
        local body = string.char(0x64) .. string.rep('\9', len)
        t2:feed(peer2:buildFrame(body))
        if got[#got] ~= body then
            check(false, ('xtea-on round-trip len %d'):format(len)); break
        end
    end
    eq(#got, 40, 'XTEA on: 40 frames decrypted and delivered')

    -- 3. our OWN outgoing frame, read back through the receive path
    local sent = {}
    local t3 = transport.new{ onMessage = function() end }
    t3._write = function(_, b) sent[#sent + 1] = b; return true end
    t3:enableXtea({ 1, 2, 3, 4 })
    t3:send(string.char(0x1E))
    local back = {}
    local t4 = transport.new{ gunzOs = false, onMessage = function(m) back[#back + 1] = m end }
    t4._write = function() return true end
    t4:enableXtea({ 1, 2, 3, 4 })
    t4:feed(sent[1])
    eq(tohex(back[1] or ''), '000000001e',
       'an outgoing frame decodes to [compression header][opcode]')
    eq(t3.stats.seq, 1, 'the sequence was post-incremented')

    -- 4. chunked delivery: one byte at a time, and two frames in one chunk
    got = {}
    local t5 = transport.new{ onMessage = function(m) got[#got + 1] = m end }
    t5._write = function() return true end
    local peer5 = peerFor(t5)
    local f1 = peer5:buildFrame(string.rep('A', 33))
    local f2 = peer5:buildFrame(string.rep('B', 7))
    local blob = f1 .. f2
    for k = 1, #blob do
        t5:feed(blob:sub(k, k))
        if k < #f1 then eq(#got, 0, 'nothing is emitted before a frame is complete') end
    end
    eq(#got, 2, 'two frames arrive after a byte-at-a-time feed')
    eq(got[1], string.rep('A', 33), 'first payload survived the chunking')
    eq(got[2], string.rep('B', 7), 'second payload survived the chunking')

    got = {}
    local t6 = transport.new{ onMessage = function(m) got[#got + 1] = m end }
    t6._write = function() return true end
    t6:feed(blob)                                   -- both frames in one chunk
    eq(#got, 2, 'two frames in a single chunk')

    -- 5. rejections
    local failed
    local t7 = transport.new{ onMessage = function() end,
                              onError = function(m) failed = m end }
    t7._write = function() return true end
    t7:feed('\0\0')
    eq(failed, 'invalid packet size: block count is 0', 'blocks == 0 is rejected cleanly')

    failed = nil
    local t8 = transport.new{ onMessage = function() end,
                              onError = function(m) failed = m end }
    t8._write = function() return true end
    -- 1 block, padding count 200 in an 8-byte region
    t8:feed('\1\0' .. '\0\0\0\0' .. string.char(200) .. string.rep('\0', 7))
    check(failed and failed:find('invalid padding count', 1, true),
          'an impossible padding count is rejected', failed)

    -- 6. inbound compression (bit 31) -- PER_PACKET latch
    got = {}
    local t9 = transport.new{ onMessage = function(m) got[#got + 1] = m end }
    t9._write = function() return true end
    local comp = fromhex('cb48cdc9c95748cecf2d284a2d2e4e4d512848acccc94f4c0100')
    local region = string.char(8 - (#comp % 8) - 1) .. comp
                   .. string.rep('\0', 8 - (#comp % 8) - 1)
    local frame = string.char((#region / 8) % 256, math.floor((#region / 8) / 256))
                  .. '\0\0\0\128' .. region        -- bit 31 of the dword set
    t9:feed(frame)
    eq(got[1], 'hello compressed payload', 'a bit-31 frame is inflated (PER_PACKET)')
    eq(t9.compressionMode, 'per_packet', 'the compression mode latched to PER_PACKET')

    -- 7. the login packet, framed, read back
    local body = handshake.buildLoginPacket{
        sessionKey = 'FAKESESSIONKEY-0123456789abcdef', characterName = 'TestChar',
        challengeTs = 0x11223344, challengeRand = 0x5A, contentRevision = 42196,
        xteaKey = { 0x01234567, 0x89ABCDEF, 0xDEADBEEF, 0xCAFEBABE },
    }
    local frames = {}
    local tl = transport.new{ onMessage = function() end }
    tl._write = function(_, b) frames[#frames + 1] = b; return true end
    tl:send(body)
    eq(#frames[1], 158, 'the login frame is 158 wire bytes')
    eq(frames[1]:byte(1) + frames[1]:byte(2) * 256, 19, 'block count 19')
    eq(tohex(frames[1]:sub(3, 6)), '00000000', 'the login packet carries sequence 0')
    local backl
    local tr = transport.new{ gunzOs = false, onMessage = function(m) backl = m end }
    tr._write = function() return true end
    for k = 1, #frames[1] do tr:feed(frames[1]:sub(k, k)) end
    eq(backl, body, 'the login frame de-frames back to the exact body')
end)

-- ============================================================= game.state
local state = require('game.state')
runSuite('game.state', function()
    local st = state.new()
    local pos = { x = 100, y = 100, z = 7 }
    for i = 1, 13 do
        st:addThing(pos, -2, { kind = 'item', id = 100 + i })
    end
    eq(st:thingCount(pos), 11, 'a tile keeps at most 11 things (Tile::addThing trim)')
    eq(st:tile(pos).things[1].id, 101, 'the ground item survived the trim')

    st:reset()
    eq(st:thingCount(pos), 0, 'reset() clears the map')

    local cpos = { x = 10, y = 20, z = 7 }
    st:addCreature({ id = 0x11223344, name = 'Rat', pos = cpos, healthPercent = 100 })
    local c = st:getCreature(0x11223344)
    if check(c ~= nil, 'addCreature/getCreature') then
        eq(c.name, 'Rat', 'creature name')
        eq(c.pos.x, 10, 'creature position')
    end
    st:removeCreature(0x11223344)
    eq(st:getCreature(0x11223344), nil, 'removeCreature')

    eq(st.world.awareRange.left, 8, 'default aware range left')
    eq(st.world.awareRange.bottom, 7, 'default aware range bottom')

    st:setContainer(3, { id = 3, name = 'Bag', items = {} })
    eq(st:container(3).name, 'Bag', 'containers')
    st:closeContainer(3)
    eq(st:container(3), nil, 'closeContainer')
end)

-- ============================================================= proto.parser
local parser = require('proto.parser')
runSuite('proto.parser', function()
    local st = state.new()
    local ev = {}
    local p = parser.new(st, function(name, data) ev[#ev + 1] = { name = name, data = data } end)

    local function parse(payload)
        ev = {}
        p:parse(payload)
    end
    local function evNamed(name)
        for _, e in ipairs(ev) do if e.name == name then return e.data end end
    end

    -- Every fixture is followed by a 0x1D sentinel: if the handler under- or
    -- over-consumes, the ping never fires (or the parse desyncs).
    local PING = string.char(0x1D)

    -- 0xA0 PlayerData -- exactly 60 payload bytes at 1530
    local w = buffer.writer()
    w:u8(0xA0)
    w:u32(1234):u32(2000):u32(87650):u64(123456789):u16(42):u16(4321)
    w:u16(0):u16(0):u16(0):u16(0)                       -- GameExperienceBonus block
    w:u32(300):u32(600):u8(100):u16(2400):u16(220):u16(0):u16(0)
    w:u16(0):u8(0)                                      -- cv >= 1097
    w:u32(0):u32(0)                                     -- GameDoubleHealth mana shield
    eq(#w:data(), 61, '0xA0 fixture is 1 opcode + 60 payload bytes')
    parse(w:data() .. PING)
    eq(st.player.levelPercent, 43.21, '0xA0 level percent (u16/100)')
    eq(st.player.health, 1234, '0xA0 health')
    eq(st.player.maxHealth, 2000, '0xA0 max health')
    eq(st.player.mana, 300, '0xA0 mana')
    eq(st.player.level, 42, '0xA0 level')
    eq(st.player.exp, 123456789, '0xA0 experience (u64)')
    eq(st.player.freeCapacity, 876.5, '0xA0 free capacity (/100)')
    check(evNamed('healthChange') ~= nil, '0xA0 emitted healthChange')
    check(evNamed('manaChange') ~= nil, '0xA0 emitted manaChange')
    check(evNamed('ping') ~= nil, '0xA0 consumed exactly its own bytes (sentinel reached)')

    -- 0x8C CreatureHealth
    st:addCreature({ id = 0x11223344, name = 'Rat', pos = { x = 1, y = 1, z = 7 } })
    w = buffer.writer(); w:u8(0x8C):u32(0x11223344):u8(42)
    parse(w:data() .. PING)
    eq(st:getCreature(0x11223344).healthPercent, 42, '0x8C creature health percent')
    check(evNamed('ping') ~= nil, '0x8C consumed exactly its own bytes')

    -- 0xB4 TextMessage, default branch (mode 19 = Game): a single string
    w = buffer.writer(); w:u8(0xB4):u8(19):string('You see a rat.')
    parse(w:data() .. PING)
    local tm = evNamed('textMessage')
    if check(tm ~= nil, '0xB4 emitted textMessage') then
        eq(tm.mode, 'Game', '0xB4 mode name')
        eq(tm.text, 'You see a rat.', '0xB4 text')
    end
    check(evNamed('ping') ~= nil, '0xB4 consumed exactly its own bytes')

    -- 0xB4 with an EMPTY first string: the correction says the string is re-read
    w = buffer.writer(); w:u8(0xB4):u8(25)        -- Heal: pos, value, color, text
    w:u16(100):u16(100):u8(7):u32(150):u8(30):string('')
    w:string('You healed yourself for 150 hitpoints.')
    parse(w:data() .. PING)
    tm = evNamed('textMessage')
    if check(tm ~= nil, '0xB4 Heal emitted textMessage') then
        eq(tm.text, 'You healed yourself for 150 hitpoints.',
           'the empty-string re-read produced the real text')
        eq(tm.value, 150, 'heal value')
    end
    check(evNamed('ping') ~= nil, '0xB4 Heal consumed exactly its own bytes')

    -- 0x1D / 0x1E ping pair
    parse(string.char(0x1D) .. string.char(0x1E))
    check(evNamed('ping') ~= nil, '0x1D emits ping (we must pong)')
    check(evNamed('pingBack') ~= nil, '0x1E emits pingBack (latency sample)')

    -- 0x1F challenge
    w = buffer.writer(); w:u8(0x1F):u32(0x11223344):u8(0x5A):u8(0)
    parse(w:data() .. PING)
    local ch = evNamed('challenge')
    if check(ch ~= nil, '0x1F emits challenge') then
        eq(ch.timestamp, 0x11223344, 'challenge timestamp')
        eq(ch.random, 0x5A, 'challenge random')
    end
    check(evNamed('ping') ~= nil, '0x1F consumed exactly its own bytes')

    -- 0x6F CloseContainer + 0xB5 CancelWalk (tiny fixed-size payloads)
    w = buffer.writer(); w:u8(0x6F):u8(3)
    parse(w:data() .. PING)
    check(evNamed('ping') ~= nil, '0x6F consumed exactly its own bytes')
    w = buffer.writer(); w:u8(0xB5):u8(2)
    parse(w:data() .. PING)
    check(evNamed('walkCancel') ~= nil or evNamed('ping') ~= nil, '0xB5 parsed')
    check(evNamed('ping') ~= nil, '0xB5 consumed exactly its own bytes')

    -- multiple opcodes packed into one message
    w = buffer.writer()
    w:u8(0x1D); w:u8(0x1E); w:u8(0xB5):u8(1); w:u8(0x1D)
    ev = {}
    p:parse(w:data())
    local pings = 0
    for _, e in ipairs(ev) do if e.name == 'ping' then pings = pings + 1 end end
    eq(pings, 2, 'four opcodes in one message all dispatched')

    -- desync reporting
    local p2 = parser.new(state.new(), function() end)
    local ok, err = pcall(function() p2:parse(string.char(0x1D) .. string.char(0x99)) end)
    check(not ok, 'an unreachable opcode raises')
    err = tostring(err)
    check(err:find('0x99', 1, true) ~= nil, 'the desync error names the opcode', err)
    check(err:find('offset', 1, true) ~= nil, 'the desync error names the byte offset', err)
    check(err:find('previous', 1, true) ~= nil, 'the desync error names the previous opcodes', err)

    -- non-fatal mode discards the rest of the message instead of raising
    local p3 = parser.new(state.new(), function() end)
    p3.unknownOpcodeIsFatal = false
    local ok3 = pcall(function() return p3:parse(string.char(0x1D) .. string.char(0x99)) end)
    check(ok3, 'unknownOpcodeIsFatal=false does not raise')
end)

-- ============================================================= proto.sender
runSuite('proto.sender', function()
    local sender = require('proto.sender')
    local sent = {}
    local fake = { send = function(_, b) sent[#sent + 1] = b end }
    local s = sender.new(fake)
    s:ping()
    eq(tohex(sent[#sent]), '1d', 'sendPing writes opcode 29 (ClientPing)')
    s:pingBack()
    eq(tohex(sent[#sent]), '1c', 'sendPingBack writes opcode 28 (ClientPingBackGunz, gunz OS)')
    s:logout()
    eq(tohex(sent[#sent]), '14', 'logout writes opcode 20 (ClientLeaveGame)')
    s:enterGame()
    eq(tohex(sent[#sent]), '0f', 'enterGame writes opcode 15')
    s:extendedOpcode(10, 'ABCD-1234')
    eq(tohex(sent[#sent]), '320a0900' .. tohex('ABCD-1234'),
       'extendedOpcode 10 writes [0x32][10][u16 len + text]')
    s:attack(0x11223344)
    check(#sent > 0 and sent[#sent]:byte(1) == 0xA1, 'attack writes opcode 161')
end)

-- ================================================== lib.socket + lib.sched
runSuite('lib.socket+sched', function()
    local socket = require('lib.socket')
    local sched  = require('lib.sched')
    local sys    = require('lib.sys')
    socket.init()
    sched.reset()

    local payload = string.rep('luaclient-loopback-', 500)     -- 9500 bytes
    local listener = assert(socket.listen('127.0.0.1', 0))
    local port = listener.boundPort or listener:port()
    check(port and port > 0, 'listen(127.0.0.1, 0) gave an ephemeral port', port)

    local serverGot, clientGot = {}, {}
    local done = false
    local server
    sched.onSocket(listener, function(l)
        local c = l:accept()
        if not c then return end
        server = c
        sched.onSocket(c, function(sk)
            while true do
                local d, err = sk:recv(65536)
                if d == nil then return end
                if d == '' then return end
                serverGot[#serverGot + 1] = d
                if #table.concat(serverGot) >= #payload then
                    sk:send(payload)                    -- echo it back
                    return
                end
            end
        end)
    end)

    local client = socket.tcp()
    client:connect('127.0.0.1', port)
    sched.onSocket(client, function(sk)
        while true do
            local d = sk:recv(65536)
            if d == nil or d == '' then return end
            clientGot[#clientGot + 1] = d
            if #table.concat(clientGot) >= #payload then done = true end
        end
    end)
    client.onConnected = function(ok) if ok then client:send(payload) end end

    -- timer accuracy while select() drives the loop
    local fired, t0 = nil, sys.nowMs()
    sched.after(30, function() fired = sys.nowMs() - t0 end)
    sched.every(5, function() if done and fired then sched.stop() end end)
    sched.after(3000, function() sched.stop() end)          -- watchdog
    sched.run()

    check(done, 'a 9500-byte payload made a full loopback round trip')
    eq(#table.concat(serverGot), #payload, 'the server received every byte')
    eq(table.concat(clientGot), payload, 'the echo came back byte-identical')
    check(fired and fired >= 25 and fired < 200,
          ('a 30 ms timer fired on time (%.1f ms)'):format(fired or -1), fired)

    if server then server:close() end
    client:close()
    listener:close()
    sched.reset()
end)

-- ==================================================== end-to-end (offline)
-- The exact boot sequence main.lua runs, without a socket: challenge -> login
-- packet -> XTEA -> pending -> enter-game -> gameplay packet -> ping answer.
runSuite('boot sequence (offline)', function()
    local events = require('lib.events')
    local bus = events.new()
    local st = state.new()
    local p = parser.new(st, function(n, d) bus:emit(n, d) end)
    local wire = {}
    local t = transport.new{ onMessage = function(m) p:parse(m) end }
    t._write = function(_, b) wire[#wire + 1] = b; return true end
    local s = require('proto.sender').new(t)

    bus:on('challenge', function(d)
        local body, key = handshake.buildLoginPacket{
            sessionKey = 'SESSION', characterName = 'Bot',
            challengeTs = d.timestamp, challengeRand = d.random, contentRevision = 42196,
        }
        t:send(body)
        t:enableXtea(key)
    end)
    bus:on('pending', function()
        for _, b in ipairs(handshake.buildEnterGameFrames('acct')) do t:send(b) end
    end)
    bus:on('ping', function() s:pingBack() end)

    local peer = transport.new{ gunzOs = false, onMessage = function() end }
    local w = buffer.writer(); w:u8(0x1F):u32(1000):u8(7):u8(0)
    t:feed(peer:buildFrame(w:data()))
    eq(#wire, 1, 'the challenge produced exactly one outgoing frame')
    eq(#wire[1], 158, 'that frame is the 158-byte login frame')
    check(t.xteaOn, 'XTEA is enabled after the login packet was queued')

    peer:enableXtea(t.xteaKey)
    t:feed(peer:buildFrame(string.char(0x0A)))
    eq(#wire, 3, 'pending produced the two enter-game frames')
    eq(t.stats.seq, 3, 'three sequence numbers consumed (login + 2)')

    t:feed(peer:buildFrame(string.char(0x1D)))
    eq(#wire, 4, 'the server ping was answered')
    local back
    local rx = transport.new{ gunzOs = false, onMessage = function(m) back = m end }
    rx._write = function() return true end
    rx:enableXtea(t.xteaKey)
    rx:feed(wire[4])
    eq(tohex(back), '000000001c', 'the pong is [compression header][opcode 28]')
end)

-- =================================================================== report
io.write('\n')
io.write('================ selftest ================\n')
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

local code = (totalFail == 0) and 0 or 1
pcall(function() require('lib.sys').shutdown() end)
os.exit(code)
