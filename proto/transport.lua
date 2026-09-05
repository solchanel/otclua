-- =====================================================================
-- proto/transport.lua -- socket framing + crypto state machine.
-- Byte-exact port of otclient_mehah1530 (clientVersion 1530, OS 61).
-- Knows nothing about opcodes.
--
-- Spec: docs/framing-crypto.md (VERIFIER Corrections are authoritative).
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
local _xtea, _inflate, _socket, _sched
local function XTEA()    if not _xtea    then _xtea    = require('lib.xtea')    end return _xtea    end
local function INFLATE() if not _inflate then _inflate = require('lib.inflate') end return _inflate end
local function SOCKET()  if not _socket  then _socket  = require('lib.socket')  end return _socket  end
local function SCHED()   if not _sched   then _sched   = require('lib.sched')   end return _sched   end

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

    self.state = 'idle'               -- idle|connecting|connected|closed|error
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
        if self.sock then pcall(function() self._sched.removeSocket(self.sock) end) end
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

function Transport:connect()
    if self.sock then return nil, 'already connected' end
    local socket = SOCKET()
    socket.init()
    local s = socket.tcp()
    local ok, err = s:connect(self.host, self.port)
    if not ok then
        self.sock = s
        return self:_fail('connect failed: ' .. tostring(err))
    end
    self.sock  = s
    self.state = 'connecting'
    self.seq   = 0                    -- m_packetNumber restarts on every login
    self.stats.seq = 0

    local sok, sched = pcall(SCHED)
    if sok and sched then
        self._pollTimer = sched.every(10, function() self:poll() end)
        self._sched = sched
    end
    return true
end

-- Drives connect completion and reads. Safe to call repeatedly; the
-- scheduler calls it every 10 ms until the socket is registered for reads.
function Transport:poll()
    if self.dead or not self.sock then return end
    if self.state == 'connecting' then
        if self.sock:isConnected() then
            self.state = 'connected'
            if self._sched and self._pollTimer then
                self._sched.cancel(self._pollTimer)
                self._pollTimer = nil
                self._sched.onSocket(self.sock, function() self:pump() end)
            end
            -- The very first bytes on the socket: world name + '\n', raw.
            local ok = self:sendRaw((self.worldName or '') .. '\n')
            if not ok then return end
            self.onConnect()
        elseif self.sock.state == 'error' or self.sock.state == 'closed' then
            return self:_fail(tostring(self.sock.err or ('socket ' .. self.sock.state)))
        end
    elseif self.state == 'connected' then
        self:pump()
    end
end

-- Read everything currently available and feed it to the accumulator.
function Transport:pump()
    while not self.dead do
        local data, err = self.sock:recv(self.recvChunk)
        if data == nil then
            return self:_fail('recv failed: ' .. tostring(err))
        end
        if data == '' then return true end
        local ok, ferr = self:feed(data)
        if not ok then return nil, ferr end
    end
end

function Transport:close()
    if self._sched then
        if self._pollTimer then self._sched.cancel(self._pollTimer); self._pollTimer = nil end
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
