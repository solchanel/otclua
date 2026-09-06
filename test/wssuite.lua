--[[============================================================================
test/wssuite.lua -- lib/sha1.lua and lib/wsserver.lua (RFC 6455, server side).

  luajit test/wssuite.lua            (from D:/Claude/otclient_web/luaclient)

Exits non-zero if ANY check fails.

WHAT IS TESTED AGAINST WHAT
  SHA-1        the four RFC 3174 section 7.3 vectors, plus a length sweep and random
               inputs cross-checked against Python's hashlib (skipped with a note, not a
               failure, when no interpreter is found).
  handshake    the RFC 6455 section 1.3 example key/accept pair, and every rejection the
               spec calls for (wrong key, wrong version, missing Upgrade/Connection).
  framing      the frames in this file are built and parsed by code written HERE, byte by
               byte -- never by lib/wsserver.lua's own encoder -- so the encoder and the
               decoder are genuinely cross-checked rather than agreeing with themselves.
  live sockets everything from "handshake" down runs over a real loopback TCP connection
               driven by lib/sched.lua, through a ~40 line HTTP shim that plays the part
               lib/httpserver.lua will play (parse the request head, hand the socket over).

The socket suites cover the required list: handshake (and a wrong key rejected), text and
binary echo, a 200 KB fragmented message, byte-at-a-time frame delivery, ping/pong, the
close handshake in both directions, an unmasked client frame rejected with 1002, invalid
UTF-8 rejected with 1007, an oversized message rejected with 1009, 10 concurrent sockets,
and a 10,000 message round-trip throughput measurement.
============================================================================]]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. package.path
end

local sha1     = require('lib.sha1')
local base64   = require('lib.base64')
local wsserver = require('lib.wsserver')
local socket   = require('lib.socket')
local sched    = require('lib.sched')
local sys      = require('lib.sys')

local schar, sbyte, ssub, srep = string.char, string.byte, string.sub, string.rep
local floor, concat = math.floor, table.concat

-- ============================================================ tiny framework
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
        cur.pass = cur.pass + 1
        totalPass = totalPass + 1
    else
        cur.fail = cur.fail + 1
        totalFail = totalFail + 1
        io.write('    FAIL  ', desc, detail and ('  -- ' .. tostring(detail)) or '', '\n')
    end
    return ok
end

local function eq(got, want, desc)
    if got == want then return check(true, desc) end
    local g, w = tostring(got), tostring(want)
    if #g > 96 then g = g:sub(1, 93) .. '...' end
    if #w > 96 then w = w:sub(1, 93) .. '...' end
    return check(false, desc, 'got ' .. g .. ', want ' .. w)
end

local function note(s) notes[#notes + 1] = s end

local function unhex(h)
    return (h:gsub('%x%x', function (c) return schar(tonumber(c, 16)) end))
end

-- ============================================================== frame codec
-- Written here on purpose: lib/wsserver.lua must never be its own witness.

local function be16(n) return schar(floor(n / 256) % 256, n % 256) end
local function be64(n)
    local hi, lo = floor(n / 4294967296), n % 4294967296
    return schar(floor(hi / 16777216) % 256, floor(hi / 65536) % 256,
                 floor(hi / 256) % 256, hi % 256,
                 floor(lo / 16777216) % 256, floor(lo / 65536) % 256,
                 floor(lo / 256) % 256, lo % 256)
end

local function maskBytes(s, key)
    local t = {}
    for i = 1, #s do
        t[i] = schar(require('bit').bxor(sbyte(s, i), sbyte(key, ((i - 1) % 4) + 1)))
    end
    return concat(t)
end

--- Build a frame the way a browser would.
--- o = { fin=true, mask='\1\2\3\4' or false, rsv=0, lenBytes=7|16|64 }
local function mkFrame(op, payload, o)
    o = o or {}
    payload = payload or ''
    local fin  = (o.fin == nil) and true or o.fin
    local rsv  = o.rsv or 0
    local key  = o.mask
    if key == nil then key = '\170\085\003\250' end       -- masked by default (client rule)
    local n = #payload
    local lenBytes = o.lenBytes
    if not lenBytes then
        lenBytes = (n < 126) and 7 or ((n < 65536) and 16 or 64)
    end
    local b1 = (fin and 0x80 or 0) + rsv * 0x10 + op
    local mbit = key and 0x80 or 0
    local hdr
    if lenBytes == 7 then      hdr = schar(b1, mbit + n)
    elseif lenBytes == 16 then hdr = schar(b1, mbit + 126) .. be16(n)
    else                       hdr = schar(b1, mbit + 127) .. be64(n) end
    if key then return hdr .. key .. maskBytes(payload, key) end
    return hdr .. payload
end

--- Parse as many complete frames as `s` holds, starting at 1-based `pos`.
--- Returns  frames, newPos.  Server frames are never masked; a masked one is reported.
local function parseFrames(s, pos)
    local out = {}
    pos = pos or 1
    while true do
        local avail = #s - pos + 1
        if avail < 2 then return out, pos end
        local b1, b2 = sbyte(s, pos, pos + 1)
        local f = { fin = b1 >= 0x80, rsv = floor((b1 % 128) / 16), op = b1 % 16,
                    masked = b2 >= 0x80 }
        local len = b2 % 128
        local hl = 2
        if len == 126 then
            if avail < 4 then return out, pos end
            local a, b = sbyte(s, pos + 2, pos + 3); len = a * 256 + b; hl = 4
        elseif len == 127 then
            if avail < 10 then return out, pos end
            local n = 0
            for i = pos + 2, pos + 9 do n = n * 256 + sbyte(s, i) end
            len = n; hl = 10
        end
        local key
        if f.masked then
            if avail < hl + 4 then return out, pos end
            key = ssub(s, pos + hl, pos + hl + 3); hl = hl + 4
        end
        if avail < hl + len then return out, pos end
        local body = ssub(s, pos + hl, pos + hl + len - 1)
        if key then body = maskBytes(body, key) end
        f.payload = body
        if f.op == 0x8 and #body >= 2 then
            f.code = sbyte(body, 1) * 256 + sbyte(body, 2)
            f.reason = ssub(body, 3)
        end
        out[#out + 1] = f
        pos = pos + hl + len
    end
end

--- Reassemble data frames (with continuations) into messages.
local function messagesOf(frames)
    local msgs, buf, op = {}, nil, nil
    for _, f in ipairs(frames) do
        if f.op == 0x1 or f.op == 0x2 then
            if f.fin then msgs[#msgs + 1] = { text = (f.op == 0x1), data = f.payload }
            else buf, op = { f.payload }, f.op end
        elseif f.op == 0x0 and buf then
            buf[#buf + 1] = f.payload
            if f.fin then
                msgs[#msgs + 1] = { text = (op == 0x1), data = concat(buf) }
                buf, op = nil, nil
            end
        end
    end
    return msgs
end

-- =================================================================== SHA-1
suite('sha1 / RFC 3174 vectors')
do
    -- RFC 3174 section 7.3 ("TEST1".."TEST4") -- the canonical SHA-1 test set.
    eq(sha1.sha1hex('abc'),
       'a9993e364706816aba3e25717850c26c9cd0d89d', 'TEST1  "abc"')
    eq(sha1.sha1hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
       '84983e441c3bd26ebaae4aa1f95129e5e54670f1', 'TEST2  448-bit message')
    eq(sha1.sha1hex(srep('a', 1000000)),
       '34aa973cd4c4daa4f61eeb2bdbad27316534016f', 'TEST3  1,000,000 x "a"')
    eq(sha1.sha1hex(srep('0123456701234567012345670123456701234567012345670123456701234567', 10)),
       'dea356a2cddd90c7a7ecedc5ebb563934f460452', 'TEST4  10 x 64-char message')
    -- FIPS 180-1 / universally published extras
    eq(sha1.sha1hex(''), 'da39a3ee5e6b4b0d3255bfef95601890afd80709', 'empty string')
    eq(sha1.sha1hex('The quick brown fox jumps over the lazy dog'),
       '2fd4e1c67a2d28fced849ee1bb76e7391b93eb12', '"The quick brown fox..."')
    eq(sha1.sha1hex('The quick brown fox jumps over the lazy cog'),
       'de9f2c7fd25e1b3afad3e85a0bd17d9b100db4b3', '"...lazy cog" (one letter apart)')
    eq(#sha1.sha1('x'), 20, 'the raw digest is 20 bytes')

    -- streaming must equal one-shot for every split of a message that straddles the
    -- 55/56/63/64 padding boundaries
    local msg = srep('The rain in Spain. ', 20)
    local allSame = true
    for split = 0, #msg do
        local d = sha1.new():update(ssub(msg, 1, split)):update(ssub(msg, split + 1))
        if d:hexdigest() ~= sha1.sha1hex(msg) then allSame = false; break end
    end
    check(allSame, 'streaming update() in two parts matches the one-shot at every split')

    local d = sha1.new():update('ab')
    local mid = d:hexdigest()
    d:update('c')
    eq(mid, sha1.sha1hex('ab'), 'digest() does not disturb the object')
    eq(d:hexdigest(), sha1.sha1hex('abc'), '   and update() may continue afterwards')
    local c1 = sha1.new():update('abc')
    local c2 = c1:clone():update('def')
    eq(c1:hexdigest(), sha1.sha1hex('abc'), 'clone() leaves the original alone')
    eq(c2:hexdigest(), sha1.sha1hex('abcdef'), '   and the copy is independent')
    eq(sha1.new():update('zz'):reset():hexdigest(), sha1.sha1hex(''), 'reset() returns to the IV')
end

-- ================================================== SHA-1 vs Python hashlib
suite('sha1 / cross-check against Python hashlib')
do
    local function findPython()
        for _, cmd in ipairs({ 'python3', 'python', 'py -3' }) do
            local f = io.popen(cmd .. ' -c "print(1)" 2>&1')
            if f then
                local out = f:read('*a') or ''
                f:close()
                if out:match('^1%s*$') then return cmd end
            end
        end
        return nil
    end

    local py = findPython()
    if not py then
        note('no Python interpreter found -- the hashlib cross-check was skipped')
        check(true, 'skipped (no interpreter)')
    else
        local dir = ROOT .. '/test/.tmp'
        if package.config:sub(1, 1) == '\\' then
            local w = dir:gsub('/', '\\')
            os.execute(('if not exist "%s" mkdir "%s" >nul 2>nul'):format(w, w))
        else
            os.execute(('mkdir -p "%s" 2>/dev/null'):format(dir))
        end
        local inPath  = dir .. '/wssuite_sha1_in.txt'
        local scPath  = dir .. '/wssuite_sha1.py'

        -- inputs: every length 0..200 plus a few long random ones, hex-encoded one per line
        local inputs = {}
        math.randomseed(20260906)
        for n = 0, 200 do
            local t = {}
            for i = 1, n do t[i] = schar(math.random(0, 255)) end
            inputs[#inputs + 1] = concat(t)
        end
        for _, n in ipairs({ 1000, 4096, 65535, 65536, 200000 }) do
            local t = {}
            for i = 1, n do t[i] = schar(math.random(0, 255)) end
            inputs[#inputs + 1] = concat(t)
        end

        local fh = assert(io.open(inPath, 'wb'))
        for _, s in ipairs(inputs) do fh:write(sha1.tohex(s), '\n') end
        fh:close()

        local sc = assert(io.open(scPath, 'wb'))
        sc:write([[
import binascii, hashlib, sys
for line in open(sys.argv[1]):
    line = line.strip()
    data = binascii.unhexlify(line) if line else b''
    print(hashlib.sha1(data).hexdigest())
]])
        sc:close()

        local f = io.popen(('%s "%s" "%s"'):format(py, scPath, inPath))
        local outText = f and f:read('*a') or ''
        if f then f:close() end

        local got = {}
        for line in outText:gmatch('[^\r\n]+') do got[#got + 1] = line end
        if #got ~= #inputs then
            check(false, 'python produced one digest per input',
                  ('got %d lines for %d inputs'):format(#got, #inputs))
        else
            local bad, firstBad = 0, nil
            for i = 1, #inputs do
                if sha1.sha1hex(inputs[i]) ~= got[i] then
                    bad = bad + 1
                    firstBad = firstBad or ('length ' .. #inputs[i])
                end
            end
            check(bad == 0, ('%d random inputs (0..200 bytes and 5 long ones) match hashlib')
                            :format(#inputs), firstBad)
            note(('hashlib cross-check: %d inputs, %s'):format(#inputs, py))
        end
        os.remove(inPath); os.remove(scPath)
        check(io.open(scPath, 'rb') == nil, 'the generated script is removed afterwards')
    end
end

-- ================================================================ handshake
suite('handshake / accept key and validation')
do
    -- RFC 6455 section 1.3, the worked example.
    eq(wsserver.acceptKey('dGhlIHNhbXBsZSBub25jZQ=='), 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=',
       'RFC 6455 1.3 example: dGhlIHNhbXBsZSBub25jZQ== -> s3pPLMBiTxaQ9kYGzzhZRbK+xOo=')
    -- the same fact stated in raw bytes: the hex below IS base64-decode of the accept
    -- string the RFC prints, so this pins the SHA-1 as well as the base64 step.
    eq(sha1.sha1hex('dGhlIHNhbXBsZSBub25jZQ==' .. wsserver.GUID),
       sha1.tohex(base64.decode('s3pPLMBiTxaQ9kYGzzhZRbK+xOo=')),
       '   and the SHA-1 behind it (RFC 6455 4.2.2 step 5.4)')
    eq(sha1.sha1hex('dGhlIHNhbXBsZSBub25jZQ==' .. wsserver.GUID),
       'b37a4f2cc0624f1690f64606cf385945b2bec4ea',
       '   spelled out in hex')
    eq(wsserver.GUID, '258EAFA5-E914-47DA-95CA-C5AB0DC85B11', 'the magic GUID is verbatim')

    local key16 = base64.encode(srep('\7', 16))
    local function req(over)
        local h = { ['Host'] = 'localhost', ['Upgrade'] = 'websocket',
                    ['Origin'] = 'http://localhost',
                    ['Connection'] = 'Upgrade', ['Sec-WebSocket-Key'] = key16,
                    ['Sec-WebSocket-Version'] = '13' }
        for k, v in pairs(over or {}) do
            if v == false then h[k] = nil else h[k] = v end
        end
        return { method = 'GET', path = '/ws', headers = h }
    end

    local a = wsserver.checkRequest(req())
    eq(a, wsserver.acceptKey(key16), 'a well-formed request is accepted')

    local _, e = wsserver.checkRequest(req({ ['Sec-WebSocket-Version'] = '8' }))
    eq(e and e.status, 426, 'Sec-WebSocket-Version 8 -> 426 Upgrade Required')
    eq(e and e.headers and e.headers['Sec-WebSocket-Version'], '13',
       '   with a Sec-WebSocket-Version: 13 header')

    local _, e2 = wsserver.checkRequest(req({ ['Sec-WebSocket-Key'] = base64.encode(srep('x', 8)) }))
    eq(e2 and e2.status, 400, 'a key that decodes to 8 bytes is rejected')
    local _, e3 = wsserver.checkRequest(req({ ['Sec-WebSocket-Key'] = 'not!base64!!' }))
    eq(e3 and e3.status, 400, 'a key that is not base64 at all is rejected')
    local _, e4 = wsserver.checkRequest(req({ ['Sec-WebSocket-Key'] = false }))
    eq(e4 and e4.status, 400, 'a missing key is rejected')
    local _, e5 = wsserver.checkRequest(req({ ['Upgrade'] = 'h2c' }))
    eq(e5 and e5.status, 400, 'Upgrade: h2c is rejected')
    local _, e6 = wsserver.checkRequest(req({ ['Connection'] = 'keep-alive' }))
    eq(e6 and e6.status, 400, 'Connection without the upgrade token is rejected')
    local r7 = req(); r7.method = 'POST'
    local _, e7 = wsserver.checkRequest(r7)
    eq(e7 and e7.status, 405, 'POST is rejected with 405')

    -- header lookup must be case-insensitive and tolerate a repeated header
    local r8 = { method = 'get', headers = { ['upgrade'] = 'WebSocket',
                 ['CONNECTION'] = { 'keep-alive', 'Upgrade' },
                 ['sec-websocket-key'] = key16, ['Sec-Websocket-Version'] = ' 13 ' } }
    eq(wsserver.checkRequest(r8, { allowNoOrigin = true }), wsserver.acceptKey(key16),
       'header names are matched case-insensitively, repeats are joined, values trimmed')

    -- subprotocol negotiation
    local r9 = req({ ['Sec-WebSocket-Protocol'] = 'chat, panel.v1' })
    local a9, p9 = wsserver.checkRequest(r9, { protocols = { 'panel.v1' } })
    check(a9 ~= nil, 'a request offering a known subprotocol is accepted')
    eq(p9, 'panel.v1', '   and the server picks the one it knows')
    local _, e10 = wsserver.checkRequest(req(), { protocols = { 'panel.v1' },
                                                  requireProtocol = true })
    eq(e10 and e10.status, 400, 'requireProtocol rejects a request that offers none')
end

-- ============================================================ UTF-8 checker
suite('utf8 / strict validator (RFC 3629)')
do
    local ok = {
        { '', 'empty' },
        { 'hello', 'ASCII' },
        { unhex('c2a2'), 'U+00A2 cent sign' },
        { unhex('e282ac'), 'U+20AC euro sign' },
        { unhex('f0908d88'), 'U+10348 gothic hwair' },
        { unhex('efbfbd'), 'U+FFFD replacement char' },
        { unhex('f48fbfbf'), 'U+10FFFF, the last code point' },
        { unhex('c280'), 'U+0080, the smallest 2-byte form' },
        { unhex('eda080'):gsub('.', function () return '' end), 'n/a' },
    }
    for i = 1, 8 do
        check(wsserver.validUtf8(ok[i][1]), 'valid: ' .. ok[i][2])
    end

    local bad = {
        { unhex('80'),         'a lone continuation byte' },
        { unhex('c0af'),       'overlong "/" (C0 AF)' },
        { unhex('c1bf'),       'overlong (C1 BF)' },
        { unhex('e08080'),     'overlong 3-byte NUL' },
        { unhex('f0808080'),   'overlong 4-byte NUL' },
        { unhex('eda080'),     'U+D800, a UTF-16 surrogate' },
        { unhex('edbfbf'),     'U+DFFF, the last surrogate' },
        { unhex('f4908080'),   'U+110000, past the last code point' },
        { unhex('f5808080'),   'F5 start byte' },
        { unhex('fe'),         'FE is never legal' },
        { unhex('ff'),         'FF is never legal' },
        { unhex('c2'),         'truncated 2-byte sequence' },
        { unhex('e282'),       'truncated 3-byte sequence' },
        { unhex('f0908d'),     'truncated 4-byte sequence' },
        { unhex('c220'),       'a 2-byte lead followed by ASCII' },
        { 'ok' .. unhex('e28228') .. 'more', 'a bad sequence in the middle of good text' },
    }
    for _, b in ipairs(bad) do
        check(not wsserver.validUtf8(b[1]), 'invalid: ' .. b[2])
    end

    -- incremental scanning across a chunk boundary: the same bytes must stay valid
    local s = unhex('f0908d88') .. 'x' .. unhex('e282ac')
    local allOk = true
    for split = 0, #s do
        local o1, rest = wsserver.utf8Scan(ssub(s, 1, split), nil)
        if not o1 then allOk = false; break end
        local o2, rest2 = wsserver.utf8Scan(ssub(s, split + 1), rest)
        if not o2 or rest2 ~= '' then allOk = false; break end
    end
    check(allOk, 'incremental scan reassembles a sequence split at every one of its bytes')
end

-- ================================================== offline protocol checks
-- A fake connection: everything the frame layer needs, none of the network.
local function fakeConn()
    local c = { out = {}, mark = 0, closed = false, peerHost = '203.0.113.7' }
    function c:send(s)
        if self.closed then return nil, 'closed' end
        self.out[#self.out + 1] = s
        return #s
    end
    function c:recv() return '' end
    function c:close() self.closed = true end
    return c
end

local function newOffline(opts)
    opts = opts or {}
    local c = fakeConn()
    local key = base64.encode(srep('\11', 16))
    local o = { register = false, autoTimer = false }
    for k, v in pairs(opts) do o[k] = v end
    local ws = assert(wsserver.upgrade(c, {
        method = 'GET', path = '/ws',
        headers = { Upgrade = 'websocket', Connection = 'Upgrade',
                    Host = 'localhost', Origin = 'http://localhost',
                    ['Sec-WebSocket-Key'] = key, ['Sec-WebSocket-Version'] = '13' },
    }, o))
    c.mark = #c.out          -- everything up to here is the 101 response
    return ws, c
end

--- Frames the server has written since the last call.
local function drain(c)
    local s = concat(c.out, '', c.mark + 1, #c.out)
    c.mark = #c.out
    return (parseFrames(s, 1))
end

suite('framing / offline decode and encode')
do
    local ws, c = newOffline()
    local got = {}
    ws.onMessage = function (_, m, bin) got[#got + 1] = { m = m, bin = bin } end

    ws:feed(mkFrame(0x1, 'hello'))
    eq(#got, 1, 'a masked text frame is delivered')
    eq(got[1] and got[1].m, 'hello', '   with the payload unmasked')
    eq(got[1] and got[1].bin, false, '   and marked as text')

    ws:feed(mkFrame(0x2, unhex('00ff01fe')))
    eq(got[2] and got[2].m, unhex('00ff01fe'), 'a binary frame keeps its bytes')
    eq(got[2] and got[2].bin, true, '   and is marked binary')

    ws:feed(mkFrame(0x1, ''))
    eq(got[3] and got[3].m, '', 'an empty text frame is a message, not a no-op')

    -- 7 / 16 / 64 bit length forms all decode to the same payload
    local p200, p70000 = srep('A', 200), srep('B', 70000)
    ws:feed(mkFrame(0x1, p200, { lenBytes = 16 }))
    eq(#(got[4] and got[4].m or ''), 200, '16-bit length form')
    ws:feed(mkFrame(0x1, p200, { lenBytes = 64 }))
    eq(#(got[5] and got[5].m or ''), 200, '64-bit length form for a small payload')
    ws:feed(mkFrame(0x2, p70000))
    eq(#(got[6] and got[6].m or ''), 70000, 'a 70,000 byte payload (16-bit form overflows)')
    ws:feed(mkFrame(0x1, srep('C', 125), { lenBytes = 7 }))
    eq(#(got[7] and got[7].m or ''), 125, '7-bit length form at its 125-byte maximum')

    -- fragmentation with an interleaved control frame
    ws:feed(mkFrame(0x1, 'frag', { fin = false }))
    ws:feed(mkFrame(0x9, 'mid'))                    -- ping in the middle of the message
    ws:feed(mkFrame(0x0, 'ment', { fin = false }))
    ws:feed(mkFrame(0x0, 'ed!', { fin = true }))
    eq(got[8] and got[8].m, 'fragmented!', 'continuation frames are reassembled in order')
    local fr = drain(c)
    local pong = nil
    for _, f in ipairs(fr) do if f.op == 0xa then pong = f end end
    check(pong ~= nil, 'the interleaved ping was answered')
    eq(pong and pong.payload, 'mid', '   with the same payload')
    eq(pong and pong.masked, false, '   and the server never masks')

    -- server encoder: fragmentation of a large outgoing payload
    local ws2, c2 = newOffline({ fragmentSize = 1000 })
    local big = srep('z', 3500)
    ws2:send(big)
    local f2 = drain(c2)
    eq(#f2, 4, 'a 3500 byte message at fragmentSize 1000 goes out as 4 frames')
    eq(f2[1].op, 0x1, '   frame 1 carries the opcode')
    eq(f2[1].fin, false, '   frame 1 is not final')
    eq(f2[2].op, 0x0, '   frame 2 is a continuation')
    eq(f2[4].fin, true, '   the last frame is final')
    eq(concat({ f2[1].payload, f2[2].payload, f2[3].payload, f2[4].payload }), big,
       '   and the fragments reassemble to the original')
    local msgs = messagesOf(f2)
    eq(#msgs, 1, '   a client sees exactly one message')

    ws2:sendBinary('bin')
    local f3 = drain(c2)
    eq(f3[1].op, 0x2, 'sendBinary uses opcode 2')
    eq(f3[1].payload, 'bin', '   with the payload verbatim')

    ws2:send('')
    local f4 = drain(c2)
    eq(#f4, 1, 'an empty send is one frame')
    eq(f4[1].payload, '', '   with an empty payload')

    -- the exported encoder (wsserver.frame / frameHeader / xorMask), which the hub and a
    -- future client half will use, must agree with the parser written in this file
    do
        local cases = { { 0x1, 'short' }, { 0x2, srep('m', 200) }, { 0x2, srep('m', 70000) },
                        { 0x9, '' }, { 0x1, '' } }
        local encOk, maskOk, hdrOk = true, true, true
        for _, cse in ipairs(cases) do
            local op, pay = cse[1], cse[2]
            local plain = parseFrames(wsserver.frame(op, pay, true, nil), 1)
            if #plain ~= 1 or plain[1].op ~= op or plain[1].payload ~= pay
               or plain[1].masked or not plain[1].fin then encOk = false end
            local masked = parseFrames(wsserver.frame(op, pay, true, '\9\8\7\6'), 1)
            if #masked ~= 1 or masked[1].payload ~= pay or not masked[1].masked then
                maskOk = false
            end
            if wsserver.frameHeader(op, #pay, true, nil) ~=
               ssub(wsserver.frame(op, pay, true, nil), 1, #wsserver.frame(op, pay, true, nil) - #pay)
            then hdrOk = false end
        end
        check(encOk, 'wsserver.frame() unmasked round-trips through this file\'s parser')
        check(maskOk, 'wsserver.frame() with a mask key round-trips too')
        check(hdrOk, 'wsserver.frameHeader() is exactly the header wsserver.frame() emits')
        local key = '\255\0\170\85'
        local body = srep('\0\1\2\3\4\5\6\7\8\9', 37)   -- 370 bytes: not a multiple of 8
        eq(wsserver.xorMask(wsserver.xorMask(body, key), key), body,
           'xorMask is its own inverse across the 8-byte fast path and the tail')
        eq(wsserver.xorMask(body, key), maskBytes(body, key),
           '   and agrees with the naive per-byte masking written in this file')
        local f5 = parseFrames(wsserver.frame(0x1, 'r', true, true), 1)
        eq(#f5 == 1 and f5[1].payload or nil, 'r', 'mask key `true` draws a random key that decodes')
    end
end

suite('framing / protocol failures')
do
    local function failsWith(build, code, desc)
        local ws, c = newOffline({ maxMessage = 4096 })
        local closed = {}
        ws.onClose = function (_, cd, rs) closed.code, closed.reason = cd, rs end
        ws:feed(build(ws))
        local fr = drain(c)
        local cf = nil
        for _, f in ipairs(fr) do if f.op == 0x8 then cf = f end end
        if not cf then return check(false, desc, 'no close frame was sent') end
        if cf.code ~= code then
            return check(false, desc, ('close code %s, want %d'):format(tostring(cf.code), code))
        end
        if closed.code ~= code then
            return check(false, desc, 'onClose reported ' .. tostring(closed.code))
        end
        if not c.closed then return check(false, desc, 'the socket was left open') end
        return check(true, desc)
    end

    failsWith(function () return mkFrame(0x1, 'x', { rsv = 1 }) end, 1002, 'RSV1 set -> 1002')
    failsWith(function () return mkFrame(0x1, 'x', { rsv = 2 }) end, 1002, 'RSV2 set -> 1002')
    failsWith(function () return mkFrame(0x1, 'x', { rsv = 4 }) end, 1002, 'RSV3 set -> 1002')
    failsWith(function () return mkFrame(0x3, 'x') end, 1002, 'reserved data opcode 3 -> 1002')
    failsWith(function () return mkFrame(0xb, 'x') end, 1002, 'reserved control opcode 11 -> 1002')
    failsWith(function () return mkFrame(0x1, 'x', { mask = false }) end, 1002,
              'an UNMASKED client frame -> 1002')
    failsWith(function () return mkFrame(0x9, srep('p', 126)) end, 1002,
              'a 126-byte control frame -> 1002')
    failsWith(function () return mkFrame(0x9, 'p', { fin = false }) end, 1002,
              'a fragmented control frame -> 1002')
    failsWith(function () return mkFrame(0x0, 'x') end, 1002,
              'a continuation with no message started -> 1002')
    failsWith(function ()
        return mkFrame(0x1, 'a', { fin = false }) .. mkFrame(0x1, 'b')
    end, 1002, 'a new data frame inside a fragmented message -> 1002')
    failsWith(function ()
        -- a 64-bit length with the most significant bit set
        local key = '\1\2\3\4'
        return schar(0x81, 0x80 + 127) .. schar(0x80, 0, 0, 0, 0, 0, 0, 1) .. key .. '\0'
    end, 1002, 'the MSB of a 64-bit length set -> 1002')
    failsWith(function () return mkFrame(0x8, '\3') end, 1002,
              'a close frame with a one-byte payload -> 1002')
    failsWith(function () return mkFrame(0x8, be16(1005)) end, 1002, 'close code 1005 -> 1002')
    failsWith(function () return mkFrame(0x8, be16(1006)) end, 1002, 'close code 1006 -> 1002')
    failsWith(function () return mkFrame(0x8, be16(1004)) end, 1002, 'close code 1004 -> 1002')
    failsWith(function () return mkFrame(0x8, be16(999)) end, 1002, 'close code 999 -> 1002')
    failsWith(function () return mkFrame(0x8, be16(2999)) end, 1002, 'close code 2999 -> 1002')
    failsWith(function () return mkFrame(0x8, be16(1000) .. unhex('80')) end, 1007,
              'a close reason that is not UTF-8 -> 1007')
    failsWith(function () return mkFrame(0x1, unhex('c0af')) end, 1007,
              'invalid UTF-8 in a text frame -> 1007')
    failsWith(function ()
        return mkFrame(0x1, unhex('f0908d'), { fin = false }) .. mkFrame(0x0, '', { fin = true })
    end, 1007, 'a text message ending mid-sequence -> 1007')
    failsWith(function () return mkFrame(0x1, srep('q', 5000)) end, 1009,
              'a single frame over maxMessage -> 1009')
    failsWith(function ()
        local t = { mkFrame(0x1, srep('q', 2000), { fin = false }) }
        t[2] = mkFrame(0x0, srep('q', 2000), { fin = false })
        t[3] = mkFrame(0x0, srep('q', 2000), { fin = true })
        return concat(t)
    end, 1009, 'fragments that together exceed maxMessage -> 1009')

    -- valid close codes must NOT be rejected
    for _, code in ipairs({ 1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011,
                            3000, 3999, 4000, 4999 }) do
        local ws, c = newOffline()
        local seen
        ws.onClose = function (_, cd) seen = cd end
        ws:feed(mkFrame(0x8, be16(code) .. 'bye'))
        local fr = drain(c)
        local cf; for _, f in ipairs(fr) do if f.op == 0x8 then cf = f end end
        check(cf and cf.code == code and seen == code,
              ('close code %d is accepted and echoed'):format(code),
              cf and tostring(cf.code) or 'no close frame')
    end

    -- a close with no payload gets a payload-less echo, and onClose reports 1005
    do
        local ws, c = newOffline()
        local seen
        ws.onClose = function (_, cd) seen = cd end
        ws:feed(mkFrame(0x8, ''))
        local fr = drain(c)
        eq(#fr, 1, 'a close with no code produces one frame back')
        eq(fr[1].op, 0x8, '   which is a close frame')
        eq(fr[1].payload, '', '   with no payload of its own')
        eq(seen, 1005, '   and onClose reports 1005 (no status received)')
    end

    -- byte-at-a-time delivery of one frame, offline
    do
        local ws = newOffline()
        local got
        ws.onMessage = function (_, m) got = m end
        local raw = mkFrame(0x1, srep('byte-at-a-time ', 30), { lenBytes = 64 })
        for i = 1, #raw do
            ws:feed(ssub(raw, i, i))
            if i < #raw then
                if got ~= nil then break end
            end
        end
        eq(got, srep('byte-at-a-time ', 30),
           'a 64-bit-length frame fed one byte at a time arrives exactly once, at the last byte')
    end

    -- backpressure: a peer that stops reading must not grow the outbox without limit
    do
        local c = fakeConn()
        c.outboxLen = 0
        local realSend = c.send
        function c:send(s)
            local n = realSend(self, s)
            if n then self.outboxLen = self.outboxLen + n end   -- pretend nothing drains
            return n
        end
        local key = base64.encode(srep('\11', 16))
        local ws = assert(wsserver.upgrade(c, { method = 'GET', headers = {
            Upgrade = 'websocket', Connection = 'Upgrade',
            ['Sec-WebSocket-Key'] = key, ['Sec-WebSocket-Version'] = '13' } },
            { register = false, autoTimer = false, allowNoOrigin = true,
              maxOutbox = 4096, fragmentSize = 512 }))
        local closed, errs = {}, 0
        ws.onClose = function (_, cd, rs) closed.code, closed.reason = cd, rs end
        ws.onError = function () errs = errs + 1 end
        local n, lastErr = 0
        while ws:isOpen() and n < 200 do
            local _, e = ws:send(srep('x', 512))
            lastErr = e or lastErr
            n = n + 1
        end
        check(not ws:isOpen(), 'a peer whose outbox passes maxOutbox is dropped')
        eq(closed.code, 1008, '   with close code 1008 (policy violation)')
        eq(closed.reason, 'send backlog exceeded', '   and a reason naming the backlog')
        check(errs > 0, '   onError was told about it')
        check(c.closed, '   and the socket was closed')
        check(n < 200, '   before 200 sends of 512 bytes went out', 'n=' .. n)
    end

    -- messages must not be delivered after a failure
    do
        local ws = newOffline()
        local n = 0
        ws.onMessage = function () n = n + 1 end
        ws:feed(mkFrame(0x1, 'x', { rsv = 1 }) .. mkFrame(0x1, 'y'))
        eq(n, 0, 'nothing queued behind a protocol failure is delivered')
    end
end

-- ================================================== the HTTP shim (H1 stand-in)
-- This is the ~40 lines lib/httpserver.lua will replace: read the request head, parse it,
-- hand the socket and the parsed request to wsserver.upgrade() with the leftover bytes.

local function parseRequestHead(head)
    local firstLine, rest = head:match('^(.-)\r\n(.*)$')
    if not firstLine then return nil end
    local method, path, version = firstLine:match('^(%S+)%s+(%S+)%s+(%S+)$')
    if not method then return nil end
    local headers = {}
    for line in rest:gmatch('([^\r\n]+)') do
        local k, v = line:match('^([^:]+):%s*(.-)%s*$')
        if k then
            local lk = k:lower()
            if headers[lk] then headers[lk] = headers[lk] .. ', ' .. v else headers[lk] = v end
        end
    end
    return { method = method, path = path, version = version, headers = headers }
end

--- Start a listener that upgrades every request.  Returns a server handle.
local function startServer(wsopts, onConn)
    wsserver.rearmTimer()          -- every suite calls sched.reset(), which drops all timers
    local lst = assert(socket.listen('127.0.0.1', 0, 64))   -- backlog > the 10 concurrent test
    local srv = { listener = lst, port = lst.boundPort, conns = {}, rejected = 0 }
    sched.onSocket(lst, function ()
        while true do
            local s = lst:accept()
            if not s then return end
            local buf = ''
            sched.onSocket(s, function ()
                while true do
                    local d, err = s:recv(4096)
                    if d == nil then
                        sched.removeSocket(s); s:close(); return
                    elseif d == '' then
                        return
                    end
                    buf = buf .. d
                    local i = buf:find('\r\n\r\n', 1, true)
                    if i then
                        local req = parseRequestHead(ssub(buf, 1, i + 1))
                        local pending = ssub(buf, i + 4)
                        local o = { pending = pending }
                        for k, v in pairs(wsopts or {}) do o[k] = v end
                        o.pending = pending
                        local ws = wsserver.upgrade(s, req, o)
                        if not ws then
                            srv.rejected = srv.rejected + 1
                            sched.removeSocket(s)
                        else
                            srv.conns[#srv.conns + 1] = ws
                            if onConn then onConn(ws) end
                        end
                        return
                    end
                    if #buf > 32768 then sched.removeSocket(s); s:close(); return end
                end
            end)
        end
    end)
    function srv:stop()
        for _, ws in ipairs(self.conns) do pcall(ws.destroy, ws, 1001, 'test over') end
        sched.removeSocket(self.listener)
        self.listener:close()
    end
    return srv
end

-- ===================================================== the test-side client
local Client = {}
Client.__index = Client

local function newClient(port, opts)
    opts = opts or {}
    local s = assert(socket.tcp())
    local c = setmetatable({
        sock = s, rbuf = '', rpos = 1, frames = {}, msgs = {}, handshook = false,
        status = nil, respHeaders = {}, dead = false, key = opts.key,
        pings = 0, pongs = 0, closeFrame = nil, onMessage = opts.onMessage,
    }, Client)
    if not c.key then
        local t = {}
        for i = 1, 16 do t[i] = schar(math.random(0, 255)) end
        c.key = base64.encode(concat(t))
    end
    assert(s:connect('127.0.0.1', port))
    sched.onSocket(s, function () c:drain() end)

    local lines = {
        ('GET %s HTTP/1.1'):format(opts.path or '/ws'),
        'Host: 127.0.0.1:' .. port,
        'Upgrade: ' .. (opts.upgrade or 'websocket'),
        'Connection: ' .. (opts.connection or 'Upgrade'),
        'Sec-WebSocket-Key: ' .. c.key,
        'Sec-WebSocket-Version: ' .. (opts.version or '13'),
    }
    -- a browser always sends Origin; by default this client behaves like one that
    -- was served BY the hub, i.e. same-origin (opts.origin overrides, opts.noOrigin
    -- omits it entirely, which is what a non-browser client looks like)
    if not opts.noOrigin then
        lines[#lines + 1] = 'Origin: ' .. (opts.origin or ('http://127.0.0.1:' .. port))
    end
    if opts.protocol then lines[#lines + 1] = 'Sec-WebSocket-Protocol: ' .. opts.protocol end
    s:send(concat(lines, '\r\n') .. '\r\n\r\n')
    return c
end

function Client:drain()
    while true do
        local d, err = self.sock:recv(65536)
        if d == nil then self.dead = true; self.deadErr = err; return end
        if d == '' then break end
        self.rbuf = self.rbuf .. d
        if #d < 65536 then break end
    end
    if not self.handshook then
        local i = self.rbuf:find('\r\n\r\n', 1, true)
        if not i then return end
        local head = ssub(self.rbuf, 1, i + 1)
        self.rbuf, self.rpos = ssub(self.rbuf, i + 4), 1
        self.status = tonumber(head:match('^HTTP/1%.1 (%d+)'))
        for line in head:gmatch('([^\r\n]+)') do
            local k, v = line:match('^([^:]+):%s*(.-)%s*$')
            if k then self.respHeaders[k:lower()] = v end
        end
        self.handshook = (self.status == 101)
        if not self.handshook then return end
    end
    local frames, np = parseFrames(self.rbuf, self.rpos)
    self.rpos = np
    if self.rpos > 65536 then
        self.rbuf = ssub(self.rbuf, self.rpos)
        self.rpos = 1
    end
    for _, f in ipairs(frames) do
        self.frames[#self.frames + 1] = f
        if f.op == 0x9 then
            self.pings = self.pings + 1
            self:sendFrame(0xa, f.payload)          -- a well-behaved client pongs
        elseif f.op == 0xa then
            self.pongs = self.pongs + 1
        elseif f.op == 0x8 then
            self.closeFrame = f
        end
    end
    -- Reassembly state lives on the client, not in the batch: a fragmented reply can
    -- easily be split across several recv() calls.
    for _, f in ipairs(frames) do
        local done = nil
        if f.op == 0x1 or f.op == 0x2 then
            if f.fin then done = { text = (f.op == 0x1), data = f.payload }
            else self.fbuf, self.fop = { f.payload }, f.op end
        elseif f.op == 0x0 and self.fbuf then
            self.fbuf[#self.fbuf + 1] = f.payload
            if f.fin then
                done = { text = (self.fop == 0x1), data = concat(self.fbuf) }
                self.fbuf, self.fop = nil, nil
            end
        end
        if done then
            self.msgs[#self.msgs + 1] = done
            if self.onMessage then self.onMessage(done) end
        end
    end
end

function Client:sendFrame(op, payload, o)
    return self.sock:send(mkFrame(op, payload, o))
end

function Client:sendRaw(bytes) return self.sock:send(bytes) end
function Client:acceptOk()
    return self.respHeaders['sec-websocket-accept'] == wsserver.acceptKey(self.key)
end
function Client:close()
    sched.removeSocket(self.sock)
    self.sock:close()
end

--- Pump the reactor until `cond` is true or `ms` elapse.
local function runUntil(cond, ms)
    local deadline = sys.nowMs() + (ms or 4000)
    while sys.nowMs() < deadline do
        sched.tick(2)
        if cond() then return true end
    end
    return cond() and true or false
end

-- ============================================================ live sockets
suite('sockets / handshake over a real connection')
do
    sched.reset()
    local srv = startServer({ pingInterval = 0, idleTimeout = 0 })
    local c = newClient(srv.port)
    check(runUntil(function () return c.handshook end, 4000), 'the 101 response arrives')
    eq(c.status, 101, '   status is 101 Switching Protocols')
    eq((c.respHeaders['upgrade'] or ''):lower(), 'websocket', '   Upgrade: websocket')
    eq((c.respHeaders['connection'] or ''):lower(), 'upgrade', '   Connection: Upgrade')
    check(c:acceptOk(), '   Sec-WebSocket-Accept matches base64(sha1(key .. GUID))')
    check(srv.conns[1] ~= nil, 'the server created a connection object')
    if srv.conns[1] then
        eq(srv.conns[1].remoteIp, '127.0.0.1', '   ws.remoteIp is the peer address')
        eq(type(srv.conns[1].user), 'table', '   ws.user is a table for the hub to fill in')
        check(type(srv.conns[1].id) == 'number' and srv.conns[1].id > 0, '   ws.id is a number')
    end

    -- a request whose key is wrong (8 bytes, not 16) must be refused, not upgraded
    local bad = newClient(srv.port, { key = base64.encode(srep('k', 8)) })
    check(runUntil(function () return bad.status ~= nil end, 4000), 'the bad-key request answers')
    eq(bad.status, 400, '   with 400 Bad Request')
    eq(bad.handshook, false, '   and no upgrade happened')
    eq(srv.rejected, 1, '   the server counted one rejection')

    local wrongVer = newClient(srv.port, { version = '8' })
    check(runUntil(function () return wrongVer.status ~= nil end, 4000), 'a version-8 request answers')
    eq(wrongVer.status, 426, '   with 426 Upgrade Required')
    eq(wrongVer.respHeaders['sec-websocket-version'], '13', '   naming version 13')

    local noUp = newClient(srv.port, { upgrade = 'h2c' })
    check(runUntil(function () return noUp.status ~= nil end, 4000), 'an Upgrade: h2c request answers')
    eq(noUp.status, 400, '   with 400 Bad Request')

    -- a client that verifies the accept value catches a server that computes it wrongly
    check(wsserver.acceptKey(c.key) ~= wsserver.acceptKey(base64.encode(srep('\0', 16))),
          'a different key yields a different accept value (the check has teeth)')

    c:close(); bad:close(); wrongVer:close(); noUp:close(); srv:stop()
end

suite('sockets / echo, fragmentation and byte-at-a-time delivery')
do
    sched.reset()
    local srv = startServer({ pingInterval = 0, idleTimeout = 0, fragmentSize = 32 * 1024 },
        function (ws)
            ws.onMessage = function (w, m, bin)
                if bin then w:sendBinary(m) else w:send(m) end
            end
        end)
    local c = newClient(srv.port)
    check(runUntil(function () return c.handshook end, 4000), 'connected')

    c:sendFrame(0x1, 'hello, panel')
    check(runUntil(function () return #c.msgs >= 1 end, 4000), 'a text message is echoed')
    eq(c.msgs[1] and c.msgs[1].data, 'hello, panel', '   with the same payload')
    eq(c.msgs[1] and c.msgs[1].text, true, '   as text')

    local blob = {}
    for i = 0, 255 do blob[#blob + 1] = schar(i) end
    blob = srep(concat(blob), 4)
    c:sendFrame(0x2, blob)
    check(runUntil(function () return #c.msgs >= 2 end, 4000), 'a binary message is echoed')
    eq(c.msgs[2] and c.msgs[2].data, blob, '   byte for byte (all 256 values)')
    eq(c.msgs[2] and c.msgs[2].text, false, '   as binary')

    -- UTF-8 that is not ASCII must survive intact
    -- "zolw" with Polish diacritics (c5bc c3b3 c582 77), an emoji, and the euro sign
    local uni = unhex('c5bcc3b3c58277') .. ' ' .. unhex('f09f9880') .. ' euro ' .. unhex('e282ac')
    check(wsserver.validUtf8(uni), 'the non-ASCII test string is itself valid UTF-8')
    c:sendFrame(0x1, uni)
    check(runUntil(function () return #c.msgs >= 3 end, 4000), 'a non-ASCII text message is echoed')
    eq(c.msgs[3] and c.msgs[3].data, uni, '   with every multi-byte sequence intact')

    -- 200 KB, sent by the client as 8 KB fragments
    local big = {}
    for i = 1, 200 * 1024 do big[i] = schar(65 + (i % 26)) end
    big = concat(big)
    eq(#big, 204800, 'the fragmented test message is 200 KB')
    local nf = 0
    do
        local CH = 8192
        local i = 1
        while i <= #big do
            local last = (i + CH - 1) >= #big
            local chunk = ssub(big, i, i + CH - 1)
            c:sendFrame((i == 1) and 0x1 or 0x0, chunk, { fin = last })
            nf = nf + 1
            i = i + CH
            -- let the reactor drain the outbox so nothing balloons in memory
            sched.tick(0)
        end
    end
    eq(nf, 25, '   sent as 25 fragments')
    local before = #c.frames
    check(runUntil(function () return #c.msgs >= 4 end, 15000), 'the 200 KB message comes back')
    eq(c.msgs[4] and #c.msgs[4].data, 204800, '   at full length')
    eq(c.msgs[4] and c.msgs[4].data, big, '   and byte-identical')
    local dataFrames = 0
    for i = before + 1, #c.frames do
        local f = c.frames[i]
        if f.op == 0x1 or f.op == 0x0 then dataFrames = dataFrames + 1 end
    end
    eq(dataFrames, 7, '   the server fragmented its 200 KB reply at fragmentSize 32 KiB')

    -- byte at a time, over the real socket
    local msg = 'one byte at a time, over TCP, with a 64-bit length header'
    local raw = mkFrame(0x1, msg, { lenBytes = 64 })
    local n0 = #c.msgs
    for i = 1, #raw do
        c:sendRaw(ssub(raw, i, i))
        sched.tick(0)
    end
    check(runUntil(function () return #c.msgs > n0 end, 4000),
          'a frame delivered one byte per reactor turn is assembled')
    eq(c.msgs[n0 + 1] and c.msgs[n0 + 1].data, msg, '   with the exact payload')

    -- a frame split so the header itself straddles two TCP writes
    local raw2 = mkFrame(0x2, srep('S', 300), { lenBytes = 16 })
    local n1 = #c.msgs
    c:sendRaw(ssub(raw2, 1, 3))
    sched.tick(2)
    c:sendRaw(ssub(raw2, 4))
    check(runUntil(function () return #c.msgs > n1 end, 4000),
          'a frame whose 16-bit length header is split across two writes is assembled')
    eq(c.msgs[n1 + 1] and #c.msgs[n1 + 1].data, 300, '   with the right length')

    c:close(); srv:stop()
end

suite('sockets / ping, pong and the idle reaper')
do
    sched.reset()
    local srv = startServer({ pingInterval = 0, idleTimeout = 0 })
    local c = newClient(srv.port)
    check(runUntil(function () return c.handshook end, 4000), 'connected')
    local ws = srv.conns[1]

    -- client ping -> server pong, same payload
    c:sendFrame(0x9, 'are-you-there')
    check(runUntil(function () return c.pongs >= 1 end, 4000), 'the server pongs a client ping')
    local pong
    for _, f in ipairs(c.frames) do if f.op == 0xa then pong = f end end
    eq(pong and pong.payload, 'are-you-there', '   echoing the ping payload exactly')
    eq(pong and pong.masked, false, '   unmasked, as a server frame must be')

    -- server ping -> the client pongs -> ws.awaitingPong clears
    ws:sendPing('hb')
    check(runUntil(function () return c.pings >= 1 end, 4000), 'the client receives a server ping')

    -- automatic ping from the shared timer
    ws.pingInterval = 1
    ws.lastRecv = sys.nowMs() - 1000
    ws.awaitingPong = false
    local pingsBefore = c.pings
    wsserver.tick(sys.nowMs())
    check(runUntil(function () return c.pings > pingsBefore end, 4000),
          'the idle timer sends an automatic ping')
    check(runUntil(function () return ws.awaitingPong == false end, 4000),
          '   and the client pong clears awaitingPong')

    -- a peer that never answers is reaped
    ws.pingInterval, ws.pongTimeout = 0, 0
    ws.idleTimeout = 10
    ws.lastRecv = sys.nowMs() - 5000
    local closed = {}
    ws.onClose = function (_, code, reason) closed.code, closed.reason = code, reason end
    wsserver.tick(sys.nowMs())
    eq(closed.code, 1006, 'a silent peer is reaped past idleTimeout')
    eq(closed.reason, 'idle timeout', '   with the reason recorded')
    check(runUntil(function () return c.dead end, 4000), '   and the socket really goes away')

    c:close(); srv:stop()
end

suite('sockets / close handshake in both directions')
do
    -- (a) the client closes first
    sched.reset()
    local srv = startServer({ pingInterval = 0, idleTimeout = 0 })
    local c = newClient(srv.port)
    check(runUntil(function () return c.handshook end, 4000), 'connected')
    local ws = srv.conns[1]
    local seen = {}
    ws.onClose = function (_, code, reason) seen.code, seen.reason = code, reason end

    c:sendFrame(0x8, be16(1000) .. 'client done')
    check(runUntil(function () return c.closeFrame ~= nil end, 4000),
          'the server answers the client close with a close of its own')
    eq(c.closeFrame and c.closeFrame.code, 1000, '   echoing the code')
    eq(c.closeFrame and c.closeFrame.masked, false, '   unmasked')
    eq(seen.code, 1000, '   onClose reports the peer code')
    eq(seen.reason, 'client done', '   and the peer reason')
    check(runUntil(function () return c.dead end, 4000), '   the server then drops the TCP socket')
    c:close(); srv:stop()

    -- (b) the server closes first
    sched.reset()
    local srv2 = startServer({ pingInterval = 0, idleTimeout = 0 })
    local c2 = newClient(srv2.port)
    check(runUntil(function () return c2.handshook end, 4000), 'connected again')
    local ws2 = srv2.conns[1]
    local seen2 = {}
    ws2.onClose = function (_, code, reason) seen2.code, seen2.reason = code, reason end
    ws2:close(1001, 'going away')
    check(runUntil(function () return c2.closeFrame ~= nil end, 4000),
          'the client receives the server-initiated close')
    eq(c2.closeFrame and c2.closeFrame.code, 1001, '   with the code the server chose')
    eq(c2.closeFrame and c2.closeFrame.reason, 'going away', '   and the reason')
    eq(seen2.code, nil, '   onClose has not fired yet -- the handshake is unfinished')
    c2:sendFrame(0x8, be16(1001) .. 'ok')
    check(runUntil(function () return seen2.code ~= nil end, 4000),
          'the client close echo completes the handshake')
    eq(seen2.code, 1001, '   onClose reports the code the server sent')
    check(runUntil(function () return c2.dead end, 4000), '   and the socket is dropped')

    -- a second close() is a no-op, and send() after close is refused
    eq(ws2:close(1000, 'again'), true, 'a second close() is harmless')
    local ok, err = ws2:send('too late')
    eq(ok, nil, 'send() after close is refused')
    check(err ~= nil, '   with an error message', err)

    c2:close(); srv2:stop()

    -- (c) the server closes and the client never answers -> closeTimeout fires
    sched.reset()
    local srv3 = startServer({ pingInterval = 0, idleTimeout = 0, closeTimeout = 30 })
    local c3 = newClient(srv3.port)
    check(runUntil(function () return c3.handshook end, 4000), 'connected a third time')
    local ws3 = srv3.conns[1]
    local seen3 = {}
    ws3.onClose = function (_, code) seen3.code = code end
    ws3:close(1000, 'bye')
    check(runUntil(function ()
        wsserver.tick(sys.nowMs())
        return seen3.code ~= nil
    end, 4000), 'an unanswered close is completed by closeTimeout')
    eq(seen3.code, 1000, '   reporting the code we sent')
    c3:close(); srv3:stop()
end

suite('sockets / RFC failures over the wire')
do
    local function liveFail(build, code, desc, opts)
        sched.reset()
        local o = { pingInterval = 0, idleTimeout = 0 }
        for k, v in pairs(opts or {}) do o[k] = v end
        local srv = startServer(o)
        local c = newClient(srv.port)
        if not runUntil(function () return c.handshook end, 4000) then
            c:close(); srv:stop()
            return check(false, desc, 'handshake never completed')
        end
        local ws = srv.conns[1]
        local seen = {}
        ws.onClose = function (_, cd, rs) seen.code, seen.reason = cd, rs end
        c:sendRaw(build())
        local got = runUntil(function () return c.closeFrame ~= nil end, 4000)
        local okAll = true
        if not got then
            okAll = check(false, desc, 'no close frame arrived')
        elseif c.closeFrame.code ~= code then
            okAll = check(false, desc,
                          ('close code %s, want %d'):format(tostring(c.closeFrame.code), code))
        elseif seen.code ~= code then
            okAll = check(false, desc, 'onClose reported ' .. tostring(seen.code))
        else
            okAll = check(true, desc)
        end
        if okAll then
            check(runUntil(function () return c.dead end, 4000), desc .. ' -- socket dropped')
        end
        c:close(); srv:stop()
    end

    liveFail(function () return mkFrame(0x1, 'unmasked!', { mask = false }) end, 1002,
             'an UNMASKED client frame is refused with 1002')
    liveFail(function () return mkFrame(0x1, unhex('48656c6c6fc0af')) end, 1007,
             'invalid UTF-8 in a text frame is refused with 1007')
    liveFail(function () return mkFrame(0x2, srep('X', 40000)) end, 1009,
             'an oversized message is refused with 1009',
             { maxMessage = 8192 })
    liveFail(function () return mkFrame(0x1, 'x', { rsv = 1 }) end, 1002,
             'a frame with RSV1 set is refused with 1002')
    liveFail(function () return mkFrame(0x7, 'x') end, 1002,
             'a reserved opcode is refused with 1002')
    liveFail(function ()
        local t = {}
        for i = 1, 5 do t[i] = mkFrame((i == 1) and 0x2 or 0x0, srep('Y', 3000), { fin = i == 5 }) end
        return concat(t)
    end, 1009, 'fragments that together exceed maxMessage are refused with 1009',
        { maxMessage = 8192 })
end

suite('sockets / 10 concurrent connections')
do
    sched.reset()
    local N = 10
    local srv = startServer({ pingInterval = 0, idleTimeout = 0 }, function (ws)
        ws.user.seen = 0
        ws.onMessage = function (w, m, bin)
            w.user.seen = w.user.seen + 1
            w:send(('#%d/%d:%s'):format(w.id, w.user.seen, m))
        end
    end)

    local cs = {}
    for i = 1, N do cs[i] = newClient(srv.port) end
    check(runUntil(function ()
        for i = 1, N do if not cs[i].handshook then return false end end
        return true
    end, 8000), ('all %d clients complete the handshake'):format(N))
    eq(#srv.conns, N, ('the server holds %d connection objects'):format(N))

    local ids = {}
    local uniq = true
    for _, ws in ipairs(srv.conns) do
        if ids[ws.id] then uniq = false end
        ids[ws.id] = true
    end
    check(uniq, 'every connection got a distinct ws.id')

    local PER = 20
    for round = 1, PER do
        for i = 1, N do cs[i]:sendFrame(0x1, ('c%d-r%d'):format(i, round)) end
        sched.tick(0)
    end
    check(runUntil(function ()
        for i = 1, N do if #cs[i].msgs < PER then return false end end
        return true
    end, 20000), ('every client receives all %d replies'):format(PER))

    local mixOk, orderOk = true, true
    for i = 1, N do
        for r = 1, math.min(PER, #cs[i].msgs) do
            local body = cs[i].msgs[r].data:match(':(.*)$')
            if body ~= ('c%d-r%d'):format(i, r) then mixOk = false end
            local seq = tonumber(cs[i].msgs[r].data:match('^#%d+/(%d+):'))
            if seq ~= r then orderOk = false end
        end
    end
    check(mixOk, 'no client ever received another client\'s payload')
    check(orderOk, 'per-connection state (ws.user) counted independently and in order')

    for i = 1, N do cs[i]:close() end
    srv:stop()
end

-- ================================================================ throughput
local throughput = nil
suite('sockets / throughput, 10,000 small messages')
do
    sched.reset()
    local N = 10000
    local received = 0
    local srv = startServer({ pingInterval = 0, idleTimeout = 0 }, function (ws)
        ws.onMessage = function (w, m) w:send(m) end
    end)
    local c = newClient(srv.port, { onMessage = function () received = received + 1 end })
    check(runUntil(function () return c.handshook end, 4000), 'connected')

    local payload = 'msg-0000000000-abcdefgh'          -- 23 bytes, 29 on the wire
    local sent = 0
    local t0 = sys.nowMs()
    local deadline = t0 + 120000
    while received < N and sys.nowMs() < deadline do
        while sent < N and (sent - received) < 2000 do
            c:sendFrame(0x1, payload)
            sent = sent + 1
        end
        sched.tick(0)
    end
    local dt = sys.nowMs() - t0

    eq(sent, N, ('all %d messages were sent'):format(N))
    eq(received, N, ('all %d echoes came back'):format(N))
    local ws = srv.conns[1]
    if ws then
        eq(ws.messagesIn, N, '   the server counted every inbound message')
        eq(ws.messagesOut, N, '   and every outbound one')
    end
    if dt <= 0 then dt = 1 end
    throughput = {
        n = N, ms = dt,
        rps = N * 1000 / dt,
        mib = (ws and (ws.bytesIn + ws.bytesOut) or 0) / 1048576,
    }
    note(('throughput: %d echo round-trips in %d ms = %.0f msg/s round-trip ' ..
          '(%.0f frames/s in+out), %.2f MiB moved')
         :format(N, dt, throughput.rps, throughput.rps * 2, throughput.mib))

    c:close(); srv:stop()
end

-- ================================================ review regressions (hub) ==
-- BLOCKER 2: the handshake never looked at Origin.  A browser attaches the hub's
-- session cookie to a cross-site WebSocket and CORS does not apply, so without this
-- any page the operator visits could drive an authenticated panel session.
suite('origin policy (blocker)')
do
    local key16 = base64.encode(srep('\3', 16))
    local function req(over)
        local h = { Host = 'panel.example:8443', Upgrade = 'websocket',
                    Connection = 'Upgrade', ['Sec-WebSocket-Key'] = key16,
                    ['Sec-WebSocket-Version'] = '13',
                    Origin = 'https://panel.example:8443' }
        for k, v in pairs(over or {}) do if v == false then h[k] = nil else h[k] = v end end
        return { method = 'GET', path = '/ws', headers = h }
    end
    local function status(r, o)
        local a, e = wsserver.checkRequest(r, o)
        if a then return 101 end
        return e and e.status, e and e.message
    end

    -- the DEFAULT is same-origin, not allow-all
    eq(status(req()), 101, 'default policy: a same-origin handshake is accepted')
    eq(status(req({ Origin = 'https://evil.example' })), 403,
       'default policy: a foreign Origin is refused with 403')
    eq(status(req({ Origin = 'https://panel.example.evil.com' })), 403,
       '   a suffix of the real host is still foreign')
    eq(status(req({ Origin = 'https://panel.example:9999' })), 403,
       '   the same host on another port is another origin')
    eq(status(req({ Origin = 'null' })), 403, '   Origin: null (a sandboxed frame) is refused')
    eq(status(req({ Origin = 'https://a.example https://b.example' })), 403,
       '   two origins in one header are refused')

    -- a missing Origin is a non-browser client: allowed only when asked for
    eq(status(req({ Origin = false })), 403, 'a missing Origin is refused by default')
    eq(status(req({ Origin = false }), { allowNoOrigin = true }), 101,
       '   and accepted with allowNoOrigin = true')
    eq(status(req({ Origin = '' })), 403, '   an empty Origin counts as missing')

    -- explicit allow-lists
    eq(status(req({ Origin = 'https://panel.example' }),
              { allowedOrigins = { 'https://panel.example' } }), 101,
       'allowedOrigins list: a listed origin is accepted')
    eq(status(req({ Origin = 'https://Panel.Example:443' }),
              { allowedOrigins = { 'https://panel.example' } }), 101,
       '   case and the default port are normalised away')
    eq(status(req({ Origin = 'http://localhost:8080' }),
              { allowedOrigins = { 'localhost:8080' } }), 101,
       '   a bare authority is a valid list entry')
    eq(status(req({ Origin = 'https://evil.example' }),
              { allowedOrigins = { 'https://panel.example' } }), 403,
       '   anything else is 403 even when it matches Host')
    eq(status(req({ Origin = 'https://evil.example', Host = 'evil.example' }),
              { allowedOrigins = { 'https://panel.example' } }), 403,
       '   including a request whose Host agrees with the foreign Origin')

    -- predicate and the explicit wildcard
    eq(status(req({ Origin = 'https://x.internal' }),
              { allowedOrigins = function (o) return o:find('%.internal$') ~= nil end }), 101,
       'allowedOrigins predicate: accepted')
    eq(status(req({ Origin = 'https://x.example' }),
              { allowedOrigins = function (o) return o:find('%.internal$') ~= nil end }), 403,
       '   refused')
    eq(status(req({ Origin = 'https://anything.example' }), { allowedOrigins = '*' }), 101,
       "allowedOrigins = '*' opts out of the check deliberately")

    -- the Origin check runs before the upgrade and nothing is upgraded
    eq(status(req({ Origin = 'https://evil.example', Host = false })), 403,
       'no Host to compare against is also a refusal, not a pass')

    -- and the refusal is a real HTTP response on the socket, with no 101
    local c = fakeConn()
    local ws, msg, st = wsserver.upgrade(c, req({ Origin = 'https://evil.example' }),
                                         { register = false, autoTimer = false })
    eq(ws, nil, 'wsserver.upgrade refuses a cross-origin handshake')
    eq(st, 403, '   with status 403')
    local wire = concat(c.out)
    check(wire:find('403', 1, true) ~= nil, '   and writes a 403 response', wire:sub(1, 40))
    check(wire:find('101', 1, true) == nil, '   and never a 101')
    check(msg and msg:find('evil.example', 1, true) ~= nil, '   naming the origin', msg)

    -- maxConnections is a cap the hub can lean on now that upgraded sockets no
    -- longer count against httpserver's own maxConnections
    local held = newOffline()                  -- one registered live connection
    local n = wsserver.count()
    check(n >= 1, 'there is at least one live connection to count', n)
    eq(status(req(), { maxConnections = n + 1 }), 101, 'maxConnections: below the cap, accepted')
    eq(status(req(), { maxConnections = n }), 503, '   at the cap, refused with 503')
    held:destroy(1000, 'done')
    eq(status(req(), { maxConnections = n }), 101, '   and accepted again once one is freed')
end

suite('origin policy over a real connection')
do
    sched.reset()
    local srv = startServer({ pingInterval = 0, idleTimeout = 0 })
    local ok = newClient(srv.port)
    check(runUntil(function () return ok.handshook end, 4000),
          'a same-origin browser handshake is upgraded')
    eq(ok.status, 101, '   101 Switching Protocols')

    local evil = newClient(srv.port, { origin = 'https://evil.example' })
    check(runUntil(function () return evil.status ~= nil end, 4000), 'the foreign origin answers')
    eq(evil.status, 403, '   with 403 Forbidden')
    eq(evil.handshook, false, '   and no upgrade happened')
    eq(srv.rejected, 1, '   the server counted the rejection')

    local nonBrowser = newClient(srv.port, { noOrigin = true })
    check(runUntil(function () return nonBrowser.status ~= nil end, 4000),
          'a client with no Origin at all answers')
    eq(nonBrowser.status, 403, '   403 by default (allowNoOrigin is opt-in)')

    ok:close(); evil:close(); nonBrowser:close(); srv:stop()

    sched.reset()
    local srv2 = startServer({ pingInterval = 0, idleTimeout = 0, allowNoOrigin = true })
    local cli = newClient(srv2.port, { noOrigin = true })
    check(runUntil(function () return cli.handshook end, 4000),
          'allowNoOrigin = true lets a non-browser client in')
    cli:close(); srv2:stop()
end

-- MAJOR: WS:feed() reset the idle timer (and cleared awaitingPong) on every BYTE,
-- so a peer dribbling one byte per (idleTimeout/2) was immortal and could hold a
-- half-delivered frame of up to maxMessage for as long as it liked.
suite('idle and ping deadlines measure PROGRESS, not bytes')
do
    -- a controlled clock: wsserver reads sys.nowMs() through the module table
    local realNow = sys.nowMs
    local fake = realNow()
    sys.nowMs = function () return fake end

    local okAll, err = pcall(function ()
        -- 1. dribbling one byte per 100 ms with a 300 ms idle timeout
        local ws = newOffline({ idleTimeout = 300, pingInterval = 0, frameTimeout = 0 })
        local closed = {}
        ws.onClose = function (_, code, reason) closed.code, closed.reason = code, reason end
        for _ = 1, 30 do
            fake = fake + 100
            ws:feed('\x82')                      -- one byte of a frame header
            ws:_tick(fake)
            if ws.state == 'closed' then break end
        end
        eq(ws.state, 'closed', 'a peer that only dribbles bytes is reaped by the idle timeout')
        eq(closed.reason, 'idle timeout', '   with the idle-timeout reason')

        -- 2. a complete frame IS progress and keeps the connection alive
        local ws2, c2 = newOffline({ idleTimeout = 300, pingInterval = 0, frameTimeout = 0 })
        local got = {}
        ws2.onMessage = function (_, m) got[#got + 1] = m end
        for _ = 1, 10 do
            fake = fake + 100
            ws2:feed(mkFrame(0x1, 'tick'))
            ws2:_tick(fake)
        end
        eq(ws2.state, 'open', 'a peer that completes frames stays open')
        eq(#got, 10, '   and every message was delivered')
        drain(c2)

        -- 3. a half-delivered frame gets its own deadline
        local ws3 = newOffline({ idleTimeout = 0, pingInterval = 0, frameTimeout = 500 })
        local closed3 = {}
        ws3.onClose = function (_, code, reason) closed3.code, closed3.reason = code, reason end
        local big = mkFrame(0x1, srep('x', 400))
        ws3:feed(ssub(big, 1, 20))               -- the frame starts but never finishes
        fake = fake + 200
        ws3:_tick(fake)
        eq(ws3.state, 'open', 'a frame still inside its delivery window is left alone')
        fake = fake + 400
        ws3:feed(ssub(big, 21, 30))              -- more bytes must not reset the deadline
        ws3:_tick(fake)
        eq(ws3.state, 'closed', 'a frame that never finishes is failed after frameTimeout')
        eq(closed3.code, 1008, '   with 1008 (policy violation)')

        -- 4. awaitingPong is cleared by a PONG, not by any inbound byte
        local ws4 = newOffline({ idleTimeout = 0, pingInterval = 100, pongTimeout = 300,
                                 frameTimeout = 0 })
        local closed4 = {}
        ws4.onClose = function (_, code, reason) closed4.code, closed4.reason = code, reason end
        fake = fake + 150
        ws4:_tick(fake)
        eq(ws4.awaitingPong, true, 'the automatic ping went out')
        fake = fake + 100
        ws4:feed('\x8a')                         -- one byte: NOT a pong frame
        ws4:_tick(fake)
        eq(ws4.awaitingPong, true, '   a stray byte does not count as a pong')
        fake = fake + 300
        ws4:_tick(fake)
        eq(ws4.state, 'closed', '   so the pong timeout still fires')
        eq(closed4.reason, 'ping timeout', '   with the ping-timeout reason')

        -- 5. and a real PONG does clear it
        local ws5 = newOffline({ idleTimeout = 0, pingInterval = 100, pongTimeout = 300,
                                 frameTimeout = 0 })
        fake = fake + 150
        ws5:_tick(fake)
        eq(ws5.awaitingPong, true, 'ping sent')
        ws5:feed(mkFrame(0xa, ''))
        eq(ws5.awaitingPong, false, '   a PONG frame clears it')
        fake = fake + 400
        ws5:_tick(fake)
        eq(ws5.state, 'open', '   and the connection survives')
    end)
    sys.nowMs = realNow
    check(okAll, 'the deadline block ran', err)
end

-- MINOR: one Lua array slot per push meant ~9 bytes of structural overhead per
-- BYTE when a peer delivered its payload one byte at a time.
suite('the receive queue coalesces byte-at-a-time delivery')
do
    local q = wsserver._newQueue()
    local N = 60000
    for i = 1, N do q:push(schar(i % 256)) end
    local slots = q.tail - q.head + 1
    eq(q.len, N, 'every byte is accounted for')
    check(slots <= N / 100, ('%d bytes are held in %d chunks, not %d'):format(N, slots, N),
          slots)
    -- and the bytes still come out in exactly the right order across the chunks
    local head = q:peek(5)
    eq(head, schar(1, 2, 3, 4, 5), 'peek() reads across coalesced chunks')
    local all = q:take(N)
    eq(#all, N, 'take() returns everything')
    local wrong = 0
    for i = 1, N do if sbyte(all, i) ~= i % 256 then wrong = wrong + 1 end end
    eq(wrong, 0, '   byte for byte')
    eq(q.len, 0, '   and the queue is empty afterwards')

    -- a large push is never copied into the tail chunk
    local q2 = wsserver._newQueue()
    q2:push('ab')
    q2:push(srep('z', 4096))
    eq(q2.tail - q2.head + 1, 2, 'a 4 KB push gets its own slot (no quadratic copying)')
end

-- BLOCKER 1, end to end: lib/httpserver.lua hands a real socket over and forgets it.
suite('end to end: httpserver upgrades to a websocket')
do
    sched.reset()
    wsserver.rearmTimer()
    local httpserver = require('lib.httpserver')
    local live, closes = {}, {}
    local wsopts = {
        pingInterval = 0, idleTimeout = 0,
        onOpen = function (ws) live[#live + 1] = ws end,
        onMessage = function (ws, m) ws:send('echo:' .. m) end,
        onClose = function (ws, code) closes[#closes + 1] = code end,
    }
    local route = httpserver.websocketRoute(wsserver, wsopts)
    local hs = httpserver.new{
        host = '127.0.0.1', port = 0, sched = sched,
        idleTimeoutMs = 250, headerTimeoutMs = 250, requestTimeoutMs = 250, sweepMs = 40,
        log = { debug = function () end, info = function () end,
                warn = function () end, error = function () end },
        onRequest = function (req, res)
            if req.path == '/ws' then return route(req, res) end
            return res:text(200, 'plain')
        end,
    }
    local port = assert(hs:start())

    local c = newClient(port)
    check(runUntil(function () return c.handshook end, 4000),
          'the HTTP server upgraded the connection')
    eq(c.status, 101, '   101 Switching Protocols')
    check(c:acceptOk(), '   with a correct Sec-WebSocket-Accept')
    eq(#live, 1, '   and wsserver owns one connection')
    eq(hs:stats().connections, 0, 'the upgraded socket is gone from the HTTP stats')
    eq(hs:stats().upgrades, 1, '   counted as an upgrade instead')

    c:sendFrame(0x1, 'hello')
    check(runUntil(function () return #c.msgs > 0 end, 4000), 'a message round-trips')
    eq(c.msgs[1] and c.msgs[1].data, 'echo:hello', '   through the handed-over socket')

    -- the whole point: survive far longer than the HTTP idle timeout (250 ms)
    runUntil(function () return false end, 1200)
    eq(live[1] and live[1].state, 'open', 'still open 1.2 s later (5x idleTimeoutMs)')
    eq(#closes, 0, '   and onClose never fired behind wsserver back')
    check(not c.dead, '   the client still has a live socket')
    check((c.rbuf or ''):find('408', 1, true) == nil,
          '   and no 408 was injected into the frame stream')
    c:sendFrame(0x1, 'again')
    check(runUntil(function () return #c.msgs > 1 end, 4000), '   and it still echoes')

    -- a refused handshake is answered on the HTTP layer, before any detach
    local evil = newClient(port, { origin = 'https://evil.example' })
    check(runUntil(function () return evil.status ~= nil end, 4000), 'a foreign origin answers')
    eq(evil.status, 403, '   403 from the HTTP layer')
    eq(hs:stats().upgrades, 1, '   and nothing was detached for it')

    -- closing from the websocket side, then stopping the server: no double close
    live[1]:close(1000, 'bye')
    check(runUntil(function () return c.closeFrame ~= nil end, 4000),
          'the close frame reaches the peer over the handed-over socket')
    c:sendFrame(0x8, be16(1000) .. 'bye')                -- the peer echoes it
    check(runUntil(function () return #closes > 0 end, 4000), 'the close handshake completes')
    eq(closes[1], 1000, '   with the code we sent')
    c:close(); evil:close()
    hs:stop()
    runUntil(function () return false end, 60)
    check(true, 'server stop after an upgrade is clean')
end

suite('cleanup')
do
    wsserver.shutdown()
    eq(wsserver.count(), 0, 'no websocket connection is left registered')
    sched.reset()
    check(true, 'the reactor is reset')
end

-- =================================================================== report
io.write('\n')
io.write('=============== wssuite ===============\n')
local width = 0
for _, s in ipairs(suites) do if #s.name > width then width = #s.name end end
for _, s in ipairs(suites) do
    io.write(('  %-' .. width .. 's  %s  %d passed'):format(
        s.name, s.fail == 0 and 'PASS' or 'FAIL', s.pass))
    if s.fail > 0 then io.write((', %d FAILED'):format(s.fail)) end
    io.write('\n')
end
io.write(('  %s\n'):format(('-'):rep(width + 20)))
for _, n in ipairs(notes) do io.write('  note: ', n, '\n') end
io.write(('  TOTAL: %d passed, %d failed  -> %s\n'):format(
    totalPass, totalFail, totalFail == 0 and 'PASS' or 'FAIL'))

local code = (totalFail == 0) and 0 or 1
pcall(function () sys.shutdown() end)
os.exit(code)
