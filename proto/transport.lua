-- =====================================================================
-- proto/transport.lua -- socket framing + crypto state machine.
-- Byte-exact port of otclient_mehah1530 (clientVersion 1530, OS 61).
-- Knows nothing about opcodes.
--
-- Spec: docs/framing-crypto.md (VERIFIER Corrections are authoritative).
--
-- PROXY (opts.proxy = {host, port, user, pass}): the TCP connection is made to the
-- proxy and lib/proxy.lua's HTTP CONNECT handshake runs to completion BEFORE any game
-- byte -- including the raw world-name preamble -- is written, which is exactly the
-- order the reference client uses (connection.cpp:293-400).  State machine:
--   idle -> connecting -> [proxying] -> connected.
-- Bytes the proxy has already buffered past its 200 response (`hs.leftover`) are game
-- bytes and are fed straight into the frame accumulator.
--
-- OUTGOING (Protocol::send, protocol.cpp:122-188), in order:
--   1. compression header "\0\0\0\0"  -- ONLY when XTEA is already on and
--                                        60 <= os <= 62 (always true here).
--                                        Goes INSIDE the encrypted region,
--                                        ahead of the opcode.
--   2. padding: p = 8 - (M % 8) - 1 ; prepend u8 p, append p zero bytes.
--      (gate is clientVersion >= 1405, NOT xteaEnabled -- so the login
--       packet carries it too.)
--   3. XTEA over the whole padded region (multiple of 8) when enabled.
--   4. u32 LE sequence, plaintext, post-incremented (starts at 0).
--      Sequence wins over checksum, so no adler32 is ever emitted.
--   5. u16 LE BLOCK COUNT = (messageSize - 4) / 8 = #region / 8;
--      it excludes itself AND the 4-byte dword.
--   Wire: [u16 blocks][u32 seq][ 8*blocks bytes ]
--
-- INCOMING (Protocol::recv / internalRecvHeader / internalRecvData):
--   read 2 -> blocks; remaining = blocks*8 + 4; read remaining.
--   REJECT blocks == 0 (the C++ has a latent uncaught throw there -- see the
--   VERIFIER correction) and blocks*8+4 > 0xFFFF.
--   dword bit 31 = "this packet is zlib-compressed"; the other 31 bits are
--   NOT validated. XTEA decrypt first, THEN inflate.
--   Padding strip: leading u8 count + that many trailing bytes. Applied on
--   every frame while XTEA is off as well (VERIFIER correction: the C++
--   only does it for m_firstRecv, which desyncs on a second pre-login
--   packet -- we do it always, which is the correct behaviour).
-- =====================================================================

local transport = {}

-- lazily required so this module loads before lib/ is fully populated
local _xtea, _inflate, _socket, _sched, _proxy
local function XTEA()    if not _xtea    then _xtea    = require('lib.xtea')    end return _xtea    end
local function INFLATE() if not _inflate then _inflate = require('lib.inflate') end return _inflate end
local function SOCKET()  if not _socket  then _socket  = require('lib.socket')  end return _socket  end
local function SCHED()   if not _sched   then _sched   = require('lib.sched')   end return _sched   end
local function PROXY()   if not _proxy   then _proxy   = require('lib.proxy')   end return _proxy   end

-- monotonic clock; falls back to os.time() when lib/sys is unavailable (never on either
-- supported platform, but the transport must stay loadable in a bare interpreter).
local _nowFn
local function NOWMS()
    if not _nowFn then
        local ok, sys = pcall(require, 'lib.sys')
        if ok and type(sys) == 'table' and sys.nowMs then _nowFn = sys.nowMs
        else _nowFn = function() return os.time() * 1000 end end
    end
    return _nowFn()
end

local floor  = math.floor
local schar  = string.char
local ssub   = string.sub
local sbyte  = string.byte
local srep   = string.rep
local concat = table.concat

local MAX_WIRE   = 0xFFFF          -- remainingSize > 0xFFFF is rejected
local MAX_BLOCKS = 8191            -- (0xFFFF - 4) / 8, floored

-- ------------------------------------------------------------- endianness
local function le_u16(v)
    return schar(v % 256, floor(v / 256) % 256)
end

local function le_u32(v)
    v = v % 0x100000000
    return schar(v % 256, floor(v / 0x100) % 256,
                 floor(v / 0x10000) % 256, floor(v / 0x1000000) % 256)
end

local function rd_u16(s, i)
    return sbyte(s, i) + sbyte(s, i + 1) * 256
end

-- ================================================================= class
local Transport = {}
Transport.__index = Transport

local function noop() end

function transport.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Transport)
    self.host      = opts.host
    self.port      = opts.port
    self.worldName = opts.worldName
    self.onMessage = opts.onMessage or noop
    self.onError   = opts.onError   or noop
    self.onConnect = opts.onConnect or noop
    self.recvChunk = opts.recvChunk or 65536
    -- Connection::READ_TIMEOUT == WRITE_TIMEOUT == 30 s (connection.h:36-39,
    -- docs/framing-crypto.md §0).  0 or false disables the watchdog.
    self.connectTimeoutMs = opts.connectTimeoutMs or 30000
    self.readTimeoutMs    = opts.readTimeoutMs    or 30000

    -- HTTP CONNECT tunnel (work item B1 / PANEL.md "Proxy support").  When set, the TCP
    -- connection is made to the PROXY and lib/proxy.lua's handshake runs to completion
    -- BEFORE a single game byte -- including the raw world-name preamble -- is written.
    -- opts.proxy = { host=, port=, user=, pass=, timeoutMs=, userAgent= }
    if opts.proxy then
        local p = opts.proxy
        if type(p) ~= 'table' or not p.host or not p.port then
            error('transport: opts.proxy needs {host=, port=}')
        end
        self.proxy = { host = p.host, port = tonumber(p.port),
                       user = p.user, pass = p.pass,
                       timeoutMs = p.timeoutMs, userAgent = p.userAgent }
    end

    -- crypto / framing state
    self.xteaOn   = false
    self.xteaKey  = nil
    self.seq      = 0                 -- m_packetNumber, starts at 0
    self.gunzOs   = (opts.gunzOs ~= false)   -- OS 61 -> compression header

    -- receive accumulator (handles arbitrary chunk boundaries)
    self.rbuf     = ''
    self.rpos     = 1
    self.rq       = {}
    self.rqlen    = 0
    self.needBody = nil               -- nil = waiting for the 2-byte header

    -- inbound zlib mode latch: nil = UNKNOWN, 'per_packet', 'stream'
    self.compressionMode = nil
    self.zstream         = nil

    self.state = 'idle'               -- idle|connecting|proxying|connected|closed|error
    self.dead  = false

    self.stats = { sent = 0, recv = 0, bytesIn = 0, bytesOut = 0, seq = 0 }
    return self
end

-- ------------------------------------------------------------ error path
function Transport:_fail(msg)
    if self.dead then return nil, msg end
    self.dead  = true
    self.state = 'error'
    self.lastError = msg
    -- stop driving a socket we are never going to read again
    if self._sched then
        if self._pollTimer then self._sched.cancel(self._pollTimer); self._pollTimer = nil end
        if self._watchTimer then self._sched.cancel(self._watchTimer); self._watchTimer = nil end
        if self.sock then pcall(function() self._sched.removeSocket(self.sock) end) end
    end
    -- and close it: unregistering from the reactor alone leaks the fd on every error path.
    if self.sock then
        pcall(function() self.sock:close() end)
        self.sock = nil
    end
    self.onError(msg)
    return nil, msg
end

-- =============================================================== OUTGOING

-- Build the complete wire frame for `body` (opcode byte first, no framing).
-- Consumes one sequence number. Pure apart from the sequence counter.
function Transport:buildFrame(body)
    local out = body

    -- 1. compression header: only once XTEA is on, and only for OS 60..62.
    if self.xteaOn and self.gunzOs then
        out = '\0\0\0\0' .. out
    end

    -- 2. padding amount (clientVersion >= 1405: always, encrypted or not)
    local m   = #out
    local pad = 8 - (m % 8) - 1                 -- 0..7; m%8==0 -> 7
    out = schar(pad) .. out .. srep('\0', pad)
    if #out % 8 ~= 0 then
        error('transport: padded region is not a multiple of 8')
    end

    -- 3. XTEA (ECB, whole padded region)
    if self.xteaOn then
        out = XTEA().encrypt(self.xteaKey, out)
    end

    -- 5. size == BLOCK COUNT, excludes itself and the dword
    local blocks = #out / 8
    if blocks < 1 or blocks > MAX_BLOCKS then
        error(('transport: outgoing block count out of range (%d)'):format(blocks))
    end

    -- 4. sequence (plaintext, LE, post-increment). Checksum branch is dead.
    local seq = self.seq
    self.seq  = (self.seq + 1) % 0x100000000
    self.stats.seq = self.seq

    return le_u16(blocks) .. le_u32(seq) .. out
end

-- Frame and write `body`.
function Transport:send(body)
    if self.dead then return nil, self.lastError or 'transport is dead' end
    local frame = self:buildFrame(body)
    self.stats.sent     = self.stats.sent + 1
    self.stats.bytesOut = self.stats.bytesOut + #frame
    return self:_write(frame)
end

-- Raw, completely unframed write. Used ONLY for the world-name preamble:
-- no size, no sequence, no padding, no XTEA -- and it does NOT consume a
-- sequence number, which is why the login packet is sequence 0.
function Transport:sendRaw(bytes)
    if self.dead then return nil, self.lastError or 'transport is dead' end
    self.stats.bytesOut = self.stats.bytesOut + #bytes
    return self:_write(bytes)
end

function Transport:_write(bytes)
    if not self.sock then return nil, 'not connected' end
    local n, err = self.sock:send(bytes)
    if not n then return self:_fail('send failed: ' .. tostring(err)) end
    return true
end

function Transport:enableXtea(key4)
    if type(key4) ~= 'table' or #key4 ~= 4 then
        error('transport:enableXtea expects {u32,u32,u32,u32}')
    end
    self.xteaKey = { key4[1], key4[2], key4[3], key4[4] }
    self.xteaOn  = true
end

-- =============================================================== INCOMING

-- available unread bytes across the merged buffer + pending chunks
function Transport:_avail()
    return (#self.rbuf - self.rpos + 1) + self.rqlen
end

-- Merge pending chunks into rbuf. Reads always go through self.rpos, so this
-- is only needed when new chunks arrived: at most one copy per feed() call,
-- however many frames that chunk contains.
function Transport:_merge()
    if self.rqlen == 0 then return end
    local head = (self.rpos > 1) and ssub(self.rbuf, self.rpos) or self.rbuf
    self.rbuf  = head .. concat(self.rq)
    self.rq    = {}
    self.rqlen = 0
    self.rpos  = 1
end

-- Feed an arbitrary chunk of socket bytes. Emits zero or more onMessage
-- callbacks. Returns true, or nil+err on a fatal protocol error.
function Transport:feed(data)
    if self.dead then return nil, self.lastError or 'transport is dead' end
    if data == nil or #data == 0 then return true end
    self.rq[#self.rq + 1] = data
    self.rqlen = self.rqlen + #data
    self.stats.bytesIn = self.stats.bytesIn + #data

    while true do
        if self.needBody == nil then
            if self:_avail() < 2 then return true end
            self:_merge()
            local blocks = rd_u16(self.rbuf, self.rpos)
            self.rpos = self.rpos + 2
            -- The C++ transforms BEFORE the test, so its `== 0` arm is
            -- unreachable and a blocks==0 frame throws out of the asio
            -- handler. We reject cleanly instead.
            if blocks == 0 then
                return self:_fail('invalid packet size: block count is 0')
            end
            local remaining = blocks * 8 + 4
            if remaining > MAX_WIRE then
                return self:_fail(('invalid packet size: %d bytes'):format(remaining))
            end
            self.needBody = remaining
        end

        if self:_avail() < self.needBody then return true end
        self:_merge()
        local n    = self.needBody
        local body = ssub(self.rbuf, self.rpos, self.rpos + n - 1)
        self.rpos     = self.rpos + n
        self.needBody = nil

        local ok, err = self:_handleBody(body)
        if not ok then return nil, err end
        if self.dead then return true end
    end
end

-- body = [u32 seq/flags][blocks*8 encrypted-or-plain bytes]
function Transport:_handleBody(body)
    -- Only bit 31 of the dword is meaningful; the sequence is never validated.
    local compressed = sbyte(body, 4) >= 0x80
    local enc = ssub(body, 5)

    if #enc % 8 ~= 0 then
        return self:_fail('invalid encrypted network message (not a multiple of 8)')
    end

    local region
    if self.xteaOn then
        region = XTEA().decrypt(self.xteaKey, enc)
    else
        -- XTEA off: the padding byte is still there (the >=1405 gate is on
        -- the client version, not on xtea). Strip on EVERY such frame.
        region = enc
    end

    local padCount = sbyte(region, 1)
    if padCount == nil or padCount + 1 > #region then
        return self:_fail(('invalid padding count %s in a %d byte region')
            :format(tostring(padCount), #region))
    end
    local payload = ssub(region, 2, #region - padCount)

    if compressed then
        local out, err = self:_inflate(payload)
        if not out then return self:_fail(err) end
        payload = out
    end

    self.stats.recv = self.stats.recv + 1
    self.onMessage(payload)
    return true
end

-- Inbound zlib: RAW deflate (windowBits -15) applied to the DECRYPTED
-- payload. The mode is autodetected once and then latched forever
-- (protocol.cpp:278-316). A later failure in the latched mode is a fatal
-- protocol error here, not a silent drop.
function Transport:_inflate(payload)
    local inf = INFLATE()

    if self.compressionMode == nil or self.compressionMode == 'per_packet' then
        local out = inf.once(payload)
        if out and #out > 0 then
            self.compressionMode = 'per_packet'
            return out
        end
        if self.compressionMode == 'per_packet' then
            return nil, 'failed to decompress message (PER_PACKET mode)'
        end
        -- mode was UNKNOWN -> fall through and latch STREAM
        self.compressionMode = 'stream'
    end

    if not self.zstream then self.zstream = inf.new() end
    local ok, out = pcall(function() return self.zstream:inflateSyncFlush(payload) end)
    if not ok or not out then
        return nil, 'failed to decompress message (STREAM mode): ' .. tostring(out)
    end
    return out
end

-- ================================================================ SOCKET

-- Restore EVERY per-connection field to its post-construction value.  A Transport object may
-- be reconnected by a supervisor loop after close() or an error, and each of these outlives a
-- session if it is not reset: `dead` would make the new socket unreadable and unsendable, the
-- receive accumulator would splice the previous session's half-frame onto the new stream, and
-- the crypto/zlib latches would decode the new (plaintext) handshake with the old XTEA key.
-- self.stats.sent/recv/bytesIn/bytesOut stay CUMULATIVE across reconnects on purpose; only
-- stats.seq is per-connection, because it mirrors the wire sequence counter.
function Transport:_resetSession()
    self.dead, self.lastError = false, nil
    self.rbuf, self.rpos, self.rq, self.rqlen, self.needBody = '', 1, {}, 0, nil
    self.xteaOn, self.xteaKey = false, nil
    self.compressionMode, self.zstream = nil, nil
    self.seq, self.stats.seq = 0, 0     -- m_packetNumber restarts on every login
    self.lastReadMs, self.connectStartMs = nil, nil
end

function Transport:connect()
    if self.sock then return nil, 'already connected' end
    -- The FIRST bytes on the game socket are the world name plus '\n', raw and unframed
    -- (docs/lua-runtime.md VERIFIER).  An empty world name puts a bare '\n' on the wire and
    -- desynchronises the login before the 0x1F challenge, so refuse here rather than
    -- silently substituting ''.  (transport.new stays permissive: offline framing tests
    -- build Transports they never connect.)
    if type(self.worldName) ~= 'string' or self.worldName == '' then
        return nil, 'transport: worldName is required before connect()'
    end
    self:_resetSession()
    local socket = SOCKET()
    socket.init()

    -- With a proxy the TCP connection goes to the PROXY; `self.host/port` become the
    -- CONNECT target.  The handshake object is built here so a bad endpoint/credential
    -- is a connect()-time error rather than a mid-poll surprise.
    local dialHost, dialPort = self.host, self.port
    if self.proxy then
        local hs, herr = PROXY().newHandshake{
            host = self.host, port = self.port,
            proxyHost = self.proxy.host, proxyPort = self.proxy.port,
            user = self.proxy.user, pass = self.proxy.pass,
            userAgent = self.proxy.userAgent,
            timeoutMs = self.proxy.timeoutMs or self.connectTimeoutMs,
        }
        if not hs then return nil, tostring(herr) end
        self._proxyHs   = hs
        self._proxySent = false
        dialHost, dialPort = self.proxy.host, self.proxy.port
    end

    local s = socket.tcp()
    local ok, err = s:connect(dialHost, dialPort)
    if not ok then
        self.sock = s
        return self:_fail('connect failed: ' .. tostring(err))
    end
    self.sock  = s
    self.state = 'connecting'

    local sok, sched = pcall(SCHED)
    if sok and sched then
        self.connectStartMs = self:_nowMs()
        self._pollTimer = sched.every(10, function() self:poll() end)
        self._watchTimer = sched.every(1000, function() self:checkTimeouts() end)
        self._sched = sched
    end
    return true
end

function Transport:_nowMs()
    return NOWMS()
end

-- Connection::READ_TIMEOUT / WRITE_TIMEOUT (30 s): a black-holed SYN must not leave us in
-- state 'connecting' forever, and a half-open session after login must surface as an error
-- rather than as a client that simply stops receiving.
function Transport:checkTimeouts(now)
    if self.dead or not self.sock then return end
    now = now or self:_nowMs()
    if self.state == 'connecting' and self.connectTimeoutMs and self.connectTimeoutMs > 0
       and self.connectStartMs and (now - self.connectStartMs) > self.connectTimeoutMs then
        return self:_fail(('connect timeout (%d ms)'):format(self.connectTimeoutMs))
    end
    if self.state == 'connected' and self.readTimeoutMs and self.readTimeoutMs > 0
       and self.lastReadMs and (now - self.lastReadMs) > self.readTimeoutMs then
        return self:_fail(('read timeout (%d ms)'):format(self.readTimeoutMs))
    end
end

-- Drives connect completion and reads. Safe to call repeatedly; the
-- scheduler calls it every 10 ms until the socket is registered for reads.
-- The TCP connection is up (directly, or the CONNECT tunnel has been established):
-- hand the socket to the reactor, write the raw world-name preamble and tell the caller.
function Transport:_enterConnected()
    self.state = 'connected'
    self.lastReadMs = self:_nowMs()          -- arm the read watchdog
    if self._sched and self._pollTimer then
        self._sched.cancel(self._pollTimer)
        self._pollTimer = nil
        self._sched.onSocket(self.sock, function() self:pump() end)
    end
    -- The very first bytes on the socket: world name + '\n', raw.
    local ok = self:sendRaw((self.worldName or '') .. '\n')
    if not ok then return end
    self.onConnect()
    return true
end

function Transport:poll()
    if self.dead or not self.sock then return end
    if self.state == 'connecting' then
        if self.sock:isConnected() then
            if self._proxyHs then
                -- The proxy speaks first: CONNECT host:port, then its status line.  NOTHING
                -- of the game protocol -- not even the world-name preamble -- may go out
                -- until the tunnel answers 200, or the proxy would parse it as a request.
                self.state = 'proxying'
                self.proxyStartMs = self:_nowMs()
                if not self._proxySent then
                    local ok = self:_write(self._proxyHs.request)
                    if not ok then return end
                    self._proxySent = true
                end
                return self:_pumpProxy()
            end
            return self:_enterConnected()
        elseif self.sock.state == 'error' or self.sock.state == 'closed' then
            return self:_fail(tostring(self.sock.err or ('socket ' .. self.sock.state)))
        end
    elseif self.state == 'proxying' then
        self:_pumpProxy()
    elseif self.state == 'connected' then
        self:pump()
    end
end

-- Read the proxy's answer.  lib/proxy.lua is a pure state machine: we only own the
-- socket and the clock.  On success the tunnel bytes it already buffered (`leftover`)
-- are fed to the frame accumulator, because they are game bytes, not proxy bytes.
function Transport:_pumpProxy()
    local proxy = PROXY()
    local hs = self._proxyHs
    if not hs then return end
    self.sock:flush()
    local data, err = self.sock:recv(self.recvChunk)
    local status, a, b
    if data == nil then
        if err == 'closed' then status, a, b = hs:eof()
        else return self:_fail('proxy: recv failed: ' .. tostring(err)) end
    elseif #data > 0 then
        status, a, b = hs:feed(data, self:_nowMs())
    else
        status, a, b = hs:tick(self:_nowMs())
    end

    if status == proxy.ERROR then
        return self:_fail(('proxy %s:%s: %s'):format(tostring(self.proxy.host),
                          tostring(self.proxy.port), tostring(a)) ..
                          (b and (' [' .. tostring(b) .. ']') or ''))
    end
    if status ~= proxy.CONNECTED then return end          -- need-more: try again next poll

    self._proxyHs = nil
    self.proxyEstablished = true
    local leftover = a or ''
    if not self:_enterConnected() then return end
    if #leftover > 0 then return self:feed(leftover) end
end

-- Read everything currently available and feed it to the accumulator.
function Transport:pump()
    while not self.dead do
        local data, err = self.sock:recv(self.recvChunk)
        if data == nil then
            return self:_fail('recv failed: ' .. tostring(err))
        end
        if data == '' then return true end
        self.lastReadMs = self:_nowMs()
        local ok, ferr = self:feed(data)
        if not ok then return nil, ferr end
    end
end

function Transport:close()
    if self._sched then
        if self._pollTimer then self._sched.cancel(self._pollTimer); self._pollTimer = nil end
        if self._watchTimer then self._sched.cancel(self._watchTimer); self._watchTimer = nil end
        if self.sock then pcall(function() self._sched.removeSocket(self.sock) end) end
    end
    if self.sock then pcall(function() self.sock:close() end) end
    self.sock  = nil
    self.state = 'closed'
    self.dead  = true
end

transport.MAX_BLOCKS = MAX_BLOCKS
transport.Transport  = Transport

return transport
