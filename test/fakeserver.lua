--[[============================================================================
test/fakeserver.lua -- offline end-to-end proof: a fake 1530 game server that the
REAL main.lua logs into over a real TCP socket on 127.0.0.1.

This is the strongest end-to-end test available without live credentials.  It
exercises every layer the live path uses -- lib/socket, lib/sched, proto/
transport framing, XTEA, proto/handshake's login packet, proto/parser, game/
state, proto/sender and main.lua's own boot sequence -- against an independent
implementation of the wire format written here (this file does its OWN framing,
padding, sequence and XTEA handling; it does not call proto/transport, so a
framing bug cannot cancel itself out).

  luajit test/fakeserver.lua                 run the whole thing, exit 0 on PASS
  luajit test/fakeserver.lua --serve=PORT    just serve one session on PORT
                                             (it prints the client command line
                                              to run by hand in another shell)

What the server proves, in order:
  1. the raw world-name preamble is the first thing on the socket, unframed
  2. login frame: block count, sequence 0, padding byte, XTEA still OFF,
     and the full 0x0A body (os 61, protocol 1530, version 1530, version
     string, content revision, preview byte, 128 RSA bytes, nothing left over)
  3. after PendingGame the client turns XTEA ON and sends the TWO enter-game
     frames separately, sequences 1 and 2, each carrying the gunz "\0\0\0\0"
     compression header inside the encrypted region, the second one holding
     the account's hwid
  4. EnterGame / PlayerData / TextMessage all decode: the client logs the
     player line and the message text
  5. a server ping (0x1D) is answered with opcode 0x1C at sequence 3
  6. SessionEnd (0x18) makes the client exit 0

The XTEA session key cannot be recovered from the RSA block (we have no private
key), so the client is started with LUACLIENT_TEST_XTEA=<fixed key>, which is
the documented test hook in main.lua.  Everything else is the production path.
============================================================================]]

-- ------------------------------------------------------------ package.path
local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    dir = (dir or '.'):gsub('\\', '/')
    ROOT = dir:match('^(.*)/[^/]*$') or '.'          -- test/ -> project root
    package.path = ROOT .. '/?.lua;' .. ROOT .. '/?/init.lua;' .. package.path
end

local socket    = require('lib.socket')
local sys       = require('lib.sys')
local xtea      = require('lib.xtea')
local buffer    = require('lib.buffer')
local handshake = require('proto.handshake')

local floor = math.floor

-- ----------------------------------------------------------------- config
local XTEA_HEX = '0123456789abcdeffedcba9876543210'
local XTEA_KEY = {}
for i = 0, 3 do XTEA_KEY[i + 1] = tonumber(XTEA_HEX:sub(i * 8 + 1, i * 8 + 8), 16) end

local WORLD     = 'Gunzodus'
local ACCOUNT   = 'fakeserver@example.invalid'
local CHARACTER = 'Fake Tester'
local SESSIONKEY = 'FAKE-SESSION-KEY'
local MESSAGE   = 'hello from the fake server'
local IO_TIMEOUT_MS = 15000
-- --hold-ms=N keeps the session OPEN for N ms after the pong and before
-- SessionEnd.  test/hube2esuite.lua uses it so a hub-spawned worker is really
-- in-game, and the panel really reports `online`, for long enough to be observed.
-- Zero (the default) is the original behaviour: end the session at once.
local HOLD_MS = 0

-- ------------------------------------------------------------- assertions
local checks, failures = 0, {}
local function check(cond, fmt, ...)
    checks = checks + 1
    local msg = select('#', ...) > 0 and fmt:format(...) or fmt
    if cond then
        io.write('  ok   ', msg, '\n')
    else
        io.write('  FAIL ', msg, '\n')
        failures[#failures + 1] = msg
    end
    return cond and true or false
end
local function eq(got, want, what)
    return check(got == want, '%s = %s (expected %s)', what, tostring(got), tostring(want))
end
local function hex(s) return (s:gsub('.', function(c) return ('%02x'):format(c:byte()) end)) end

-- ------------------------------------------------------------ wire helpers
local function u16le(v) return string.char(v % 256, floor(v / 256) % 256) end
local function u32le(v)
    v = v % 0x100000000
    return string.char(v % 256, floor(v / 0x100) % 256,
                       floor(v / 0x10000) % 256, floor(v / 0x1000000) % 256)
end

-- Build a server->client frame, independently of proto/transport:
--   [u16 blocks][u32 dword][ blocks*8 bytes: u8 pad, body, pad zeros ]
-- The server is not a gunz OS client, so it emits NO "\0\0\0\0" compression
-- header (that prefix is client->server only).
local serverSeq = 0
local function buildFrame(body, key)
    local pad    = 8 - (#body % 8) - 1
    local region = string.char(pad) .. body .. string.rep('\0', pad)
    assert(#region % 8 == 0)
    if key then region = xtea.encrypt(key, region) end
    local frame = u16le(#region / 8) .. u32le(serverSeq) .. region
    serverSeq = serverSeq + 1
    return frame
end

-- ------------------------------------------------------------- connection
local Conn = {}
Conn.__index = Conn

local function wrap(sock) return setmetatable({ s = sock, buf = '', pos = 1 }, Conn) end

function Conn:_fill(deadline)
    while true do
        local data, err = self.s:recv(65536)
        if data == nil then return nil, tostring(err) end
        if #data > 0 then
            self.buf = self.buf:sub(self.pos) .. data
            self.pos = 1
            return true
        end
        if sys.nowMs() > deadline then return nil, 'timeout waiting for client data' end
        local r = socket.select({ self.s }, nil, 50)
        if r == nil then return nil, 'select failed' end
    end
end

function Conn:_avail() return #self.buf - self.pos + 1 end

function Conn:need(n, deadline)
    while self:_avail() < n do
        local ok, err = self:_fill(deadline)
        if not ok then return nil, err end
    end
    local s = self.buf:sub(self.pos, self.pos + n - 1)
    self.pos = self.pos + n
    return s
end

-- The world preamble is raw text terminated by '\n' -- read it byte by byte so
-- we prove nothing else is prepended to it.
function Conn:readLine(deadline)
    local out = {}
    for _ = 1, 256 do
        local c, err = self:need(1, deadline)
        if not c then return nil, err end
        if c == '\n' then return table.concat(out) end
        out[#out + 1] = c
    end
    return nil, 'no newline in the first 256 bytes of the preamble'
end

-- Read one client frame.  Returns payload, seq, info{blocks=, pad=, frameLen=}.
function Conn:readFrame(key, deadline)
    local hdr, err = self:need(2, deadline)
    if not hdr then return nil, err end
    local blocks = hdr:byte(1) + hdr:byte(2) * 256
    if blocks == 0 or blocks * 8 + 4 > 0xFFFF then
        return nil, ('bad block count %d'):format(blocks)
    end
    local body
    body, err = self:need(blocks * 8 + 4, deadline)
    if not body then return nil, err end
    local seq = body:byte(1) + body:byte(2) * 256
              + body:byte(3) * 65536 + body:byte(4) * 16777216
    local region = body:sub(5)
    if key then region = xtea.decrypt(key, region) end
    local pad = region:byte(1)
    if pad == nil or pad + 1 > #region then
        return nil, ('bad padding count %s'):format(tostring(pad))
    end
    local payload = region:sub(2, #region - pad)
    return payload, seq, { blocks = blocks, pad = pad, frameLen = 2 + 4 + blocks * 8 }
end

function Conn:write(bytes)
    local n, err = self.s:send(bytes)
    if not n then return nil, tostring(err) end
    -- lib/socket queues whatever the OS refused; push the rest out.
    local deadline = sys.nowMs() + IO_TIMEOUT_MS
    while self.s:pending() > 0 do
        if sys.nowMs() > deadline then return nil, 'timeout flushing the send outbox' end
        socket.select(nil, { self.s }, 50)
        local ok, ferr = self.s:flush()
        if ok == nil then return nil, tostring(ferr) end
    end
    return true
end

-- =============================================================== the session
local function serve(listener)
    local deadline = sys.nowMs() + 60000
    local sock
    while true do
        local s, err = listener:accept()
        if s then sock = s break end
        if err ~= 'wouldblock' then return nil, 'accept: ' .. tostring(err) end
        if sys.nowMs() > deadline then return nil, 'the client never connected' end
        socket.select({ listener }, nil, 50)
    end
    io.write('  --   client connected from ', tostring(sock.peerHost), ':',
             tostring(sock.peerPort), '\n')

    local c = wrap(sock)
    local dl = function() return sys.nowMs() + IO_TIMEOUT_MS end
    local function fail(err) sock:close(); return nil, err end

    -- 1. world-name preamble -------------------------------------------------
    local line, err = c:readLine(dl())
    if not line then return fail(err) end
    eq(line, WORLD, 'raw world preamble')

    -- 2. challenge -> login packet ------------------------------------------
    local challenge = string.char(0x1F) .. u32le(0x11223344) .. string.char(0x5A)
                      .. string.char(0x00)
    local ok
    ok, err = c:write(buildFrame(challenge, nil))
    if not ok then return fail('sending the challenge: ' .. err) end

    local payload, seq, info = c:readFrame(nil, dl())
    if not payload then return fail('reading the login frame: ' .. tostring(seq)) end
    eq(seq, 0, 'login frame sequence')
    eq(info.frameLen, 158, 'login frame length')
    eq(info.blocks, 19, 'login frame block count')
    check(info.pad >= 0 and info.pad <= 7, 'login frame padding byte = %d', info.pad)

    local R = buffer.reader(payload)
    eq(R:u8(), 0x0A, 'login opcode')
    eq(R:u16(), 61, 'os id')
    eq(R:u16(), 1530, 'protocol version')
    eq(R:u32(), 1530, 'client version')
    eq(R:string(), '1530', 'version string')
    local cr = R:string()
    check(cr:match('^%d+$') ~= nil, 'content revision string = %q', cr)
    eq(R:u8(), 0, 'preview state byte')
    eq(R:remaining(), 128, 'RSA block size')
    local rsa = R:bytes(128)
    check(rsa ~= string.rep('\0', 128), 'RSA block is not all zeroes')

    -- 3. PendingGame.  The client turns XTEA on the instant the login packet is
    --    queued, so EVERY frame from here on is encrypted in both directions.
    ok, err = c:write(buildFrame(string.char(0x0A), XTEA_KEY))
    if not ok then return fail('sending PendingGame: ' .. err) end

    payload, seq = c:readFrame(XTEA_KEY, dl())
    if not payload then return fail('reading enter-game frame 1: ' .. tostring(seq)) end
    eq(seq, 1, 'enter-game frame 1 sequence')
    check(payload:sub(1, 4) == '\0\0\0\0', 'enter-game frame 1 compression header = %s',
          hex(payload:sub(1, 4)))
    eq(payload:byte(5), 0x0F, 'enter-game frame 1 opcode')
    eq(#payload, 5, 'enter-game frame 1 payload length')

    payload, seq = c:readFrame(XTEA_KEY, dl())
    if not payload then return fail('reading enter-game frame 2: ' .. tostring(seq)) end
    eq(seq, 2, 'enter-game frame 2 sequence')
    check(payload:sub(1, 4) == '\0\0\0\0', 'enter-game frame 2 compression header = %s',
          hex(payload:sub(1, 4)))
    local R2 = buffer.reader(payload:sub(5))
    eq(R2:u8(), 0x32, 'enter-game frame 2 opcode (ExtendedOpcode)')
    eq(R2:u8(), 0x0A, 'enter-game frame 2 sub-opcode')
    local hwid = R2:string()
    eq(hwid, handshake.hwid(ACCOUNT), 'hwid')
    eq(R2:remaining(), 0, 'enter-game frame 2 has no trailing bytes')

    -- 4. EnterGame + PlayerData + TextMessage --------------------------------
    ok, err = c:write(buildFrame(string.char(0x0F), XTEA_KEY))
    if not ok then return fail('sending EnterGame: ' .. err) end

    local w = buffer.writer()
    w:u8(0xA0)
    w:u32(155):u32(185):u32(87650):u64(4242):u16(9):u16(37)
    w:u16(0):u16(0):u16(0):u16(0)
    w:u32(31):u32(62):u8(100):u16(2400):u16(220):u16(0):u16(0)
    w:u16(0):u8(0)
    w:u32(0):u32(0)
    ok, err = c:write(buildFrame(w:data(), XTEA_KEY))
    if not ok then return fail('sending PlayerData: ' .. err) end

    local tm = buffer.writer()
    tm:u8(0xB4):u8(17)                            -- mode 17 = Login (plain string)
    tm:string(MESSAGE)
    ok, err = c:write(buildFrame(tm:data(), XTEA_KEY))
    if not ok then return fail('sending TextMessage: ' .. err) end

    -- 5. server ping -> the client must pong with opcode 0x1C ----------------
    ok, err = c:write(buildFrame(string.char(0x1D), XTEA_KEY))
    if not ok then return fail('sending the ping request: ' .. err) end

    payload, seq = c:readFrame(XTEA_KEY, dl())
    if not payload then return fail('reading the pong: ' .. tostring(seq)) end
    eq(seq, 3, 'pong sequence')
    check(payload:sub(1, 4) == '\0\0\0\0', 'pong compression header = %s',
          hex(payload:sub(1, 4)))
    eq(payload:byte(5), 0x1C, 'pong opcode (ClientPingBackGunz)')
    eq(#payload, 5, 'pong payload length')

    -- 5b. optional hold: stay in-game, draining whatever the client sends, so an
    --     external observer (the hub's panel) can see a real online session.
    if HOLD_MS > 0 then
        io.write(('  --   holding the session open for %d ms\n'):format(HOLD_MS))
        io.stdout:flush()
        local until_ = sys.nowMs() + HOLD_MS
        while sys.nowMs() < until_ do
            local d = sock:recv(65536)
            if d == nil then break end          -- the client hung up
            socket.select({ sock }, nil, 50)
        end
    end

    -- 6. SessionEnd -> the client shuts down with status 0 -------------------
    ok, err = c:write(buildFrame(string.char(0x18) .. string.char(0), XTEA_KEY))
    if not ok then return fail('sending SessionEnd: ' .. err) end

    -- give the client a moment to read it before the socket disappears
    local waitUntil = sys.nowMs() + 2000
    while sys.nowMs() < waitUntil do
        local d = sock:recv(4096)
        if d == nil then break end                -- peer closed: it is done
        socket.select({ sock }, nil, 50)
    end
    sock:close()
    return true
end

-- =============================================================== the client
local function quoteWin(s) return '"' .. s .. '"' end

local function buildClientCommand(port)
    local interp = arg and arg[-1]
    if not interp or interp == '' then interp = sys.isWindows and 'luajit.exe' or 'luajit' end
    local flags = table.concat({
        '--session-key=' .. SESSIONKEY,
        '--account=' .. ACCOUNT,
        '--character=' .. quoteWin(CHARACTER),
        '--world=' .. WORLD,
        '--host=127.0.0.1:' .. port,
        '--ping=600000',
        '--log-level=info',
    }, ' ')
    -- Lua 5.1's io.popen close() cannot report a child's exit status (it only
    -- says whether pclose itself worked), so the child prints it instead.
    -- `%^ERRORLEVEL%` defeats cmd's parse-time expansion; `$?` is plain sh.
    if sys.isWindows then
        return ('set "LUACLIENT_TEST_XTEA=%s" && %s %s %s 2>&1 & call echo LC_EXIT=%%^ERRORLEVEL%%')
            :format(XTEA_HEX, quoteWin(interp:gsub('/', '\\')),
                    quoteWin((ROOT .. '/main.lua'):gsub('/', '\\')), flags)
    end
    return ("LUACLIENT_TEST_XTEA=%s '%s' '%s' %s 2>&1; echo LC_EXIT=$?")
        :format(XTEA_HEX, interp, ROOT .. '/main.lua', flags)
end

-- =============================================================== entry point
local function main(argv)
    local servePort = nil
    for _, a in ipairs(argv) do
        if a:match('^%-%-serve=%d+$') then servePort = tonumber(a:match('(%d+)$'))
        elseif a:match('^%-%-hold%-ms=%d+$') then HOLD_MS = tonumber(a:match('(%d+)$'))
        elseif a == '-h' or a == '--help' then
            io.write('usage: luajit test/fakeserver.lua [--serve=PORT]\n')
            return 0
        else
            io.write('fakeserver: unknown argument ', a, '\n'); return 1
        end
    end

    io.write('=============== fake 1530 server: end-to-end ===============\n')

    local listener, lerr = socket.listen('127.0.0.1', servePort or 0)
    if not listener then io.write('fakeserver: listen failed: ', tostring(lerr), '\n'); return 1 end
    local port = listener:port()
    io.write(('  --   listening on 127.0.0.1:%d\n'):format(port))
    io.stdout:flush()          -- a parent watching this pipe waits for THIS line

    local child, clientOut
    if servePort then
        io.write('  --   --serve mode: start the client yourself, e.g.\n         ',
                 buildClientCommand(port), '\n')
    else
        local cmd = buildClientCommand(port)
        io.write('  --   starting the real client:\n         ', cmd, '\n')
        child = io.popen(cmd, 'r')
        if not child then io.write('fakeserver: io.popen failed\n'); return 1 end
    end

    local ok, serr = pcall(serve, listener)
    listener:close()
    if not ok then
        io.write('  FAIL server error: ', tostring(serr), '\n')
        failures[#failures + 1] = 'server error: ' .. tostring(serr)
    elseif serr == nil then
        -- serve() returned nil, err
        io.write('  FAIL server aborted\n')
    end

    if child then
        clientOut = child:read('*a') or ''
        child:close()
        io.write('--------------- client output ---------------\n')
        io.write(clientOut)
        if clientOut ~= '' and clientOut:sub(-1) ~= '\n' then io.write('\n') end
        io.write('---------------------------------------------\n')

        local exit = clientOut:match('LC_EXIT=(%-?%d+)')
        check(exit == '0', 'the client process exited 0 (got %s)', tostring(exit))
        check(clientOut:find('connected to 127.0.0.1:' .. port, 1, true) ~= nil,
              'client logged the connection')
        check(clientOut:find('login packet sent', 1, true) ~= nil,
              'client logged the login packet')
        check(clientOut:find('server accepted the login (pending)', 1, true) ~= nil,
              'client saw PendingGame')
        check(clientOut:find('game started', 1, true) ~= nil,
              'client saw EnterGame and armed the keepalive')
        check(clientOut:find('hp 155/185', 1, true) ~= nil,
              'client decoded PlayerData (hp 155/185)')
        check(clientOut:find('level 9', 1, true) ~= nil,
              'client decoded PlayerData (level 9)')
        check(clientOut:find(MESSAGE, 1, true) ~= nil,
              'client printed the server text message')
        check(clientOut:find('session ended by the server', 1, true) ~= nil,
              'client honoured SessionEnd')
    end

    io.write('===========================================================\n')
    if #failures == 0 then
        io.write(('fakeserver: %d checks, 0 failed  -> PASS\n'):format(checks))
        return 0
    end
    io.write(('fakeserver: %d checks, %d FAILED  -> FAIL\n'):format(checks, #failures))
    for _, f in ipairs(failures) do io.write('  * ', f, '\n') end
    return 1
end

local rc = main(arg or {})
pcall(sys.shutdown)
os.exit(rc)
