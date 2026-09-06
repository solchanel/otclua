--[[============================================================================
lib/wsserver.lua -- the server half of RFC 6455 (WebSocket), for the hub's web panel.

Non-blocking, single-threaded, driven by lib/sched.lua.  Nothing here ever blocks the
reactor: every read is a :recv() that may return '' , every write goes through
lib/socket.lua's outbox, and every timeout is a deadline checked by a shared 1 Hz timer.

---------------------------------------------------------------------------- use
The intended caller is lib/httpserver.lua, which parses the request line and headers
and then hands the connection over:

    local wsserver = require('lib.wsserver')

    -- inside the HTTP route for GET /ws
    local sock, pending = res:upgrade()      -- httpserver hands the socket over
    local ws, err = wsserver.upgrade(sock, req, {
        pending    = pending,                -- bytes httpserver read past the headers
        allowedOrigins = { 'https://panel.example' },   -- see ORIGIN below
        maxMessage = 1024 * 1024,
        onMessage  = function (ws, msg, isBinary) ... end,
        onClose    = function (ws, code, reason) ... end,
        onError    = function (ws, message) ... end,
    })

httpserver.websocketRoute(wsserver, opts) does that whole dance, and answers a refused
handshake with an ordinary HTTP status BEFORE the socket is detached.

--------------------------------------------------------------------------- ORIGIN
A browser attaches the hub's session cookie to a WebSocket handshake no matter which
page opened it, and the WebSocket handshake is NOT subject to CORS: without an Origin
check, any page the operator visits can drive an authenticated panel session (which per
PANEL.md means `exec {code}` inside every worker, `script.put`, and the game-account
credentials).  So the check is not optional here and the default is DENY:

    allowedOrigins = nil        same-origin only (the DEFAULT): the Origin's host must
                                equal the Host header's host, and their ports must
                                agree whenever both state one.  Scheme is not compared,
                                because the hub sits behind nginx/Caddy terminating TLS.
    allowedOrigins = { ... }    an explicit list; entries may be full origins
                                ('https://panel.example') or bare authorities
                                ('panel.example:8443').  Matching is case-insensitive
                                and normalises away a default port (80/443).
    allowedOrigins = function (origin, req) -> boolean       any policy you like.
    allowedOrigins = '*'        allow every origin.  Say this out loud before you use it.
    allowNoOrigin = true        allow a handshake with NO Origin header at all, i.e. a
                                non-browser client (curl, another Lua process).  Default
                                false: a browser always sends Origin, so a missing one
                                is either a native client or an attempt to dodge the
                                check, and the hub has to opt into that deliberately.

A mismatch is 403 with no upgrade.  This closes cross-site WebSocket hijacking; DNS
rebinding needs the Host header pinned as well -- httpserver's opts.allowedHosts.

`conn` only has to be socket-like: `conn:send(str)`, `conn:recv(max)`, `conn:close()`.
A lib/socket.lua socket additionally offers `.outboxLen` / `:flush()` / `.peerHost`,
which are used when present (to close only once the close frame has really left, and to
fill in `ws.remoteIp`) and quietly skipped when they are not.

`req` only has to carry `req.headers` (a name -> value map; lookup is case-insensitive
and a table value is joined with ", ").  `req.method` is checked when present.

------------------------------------------------------------------------- object
    ws:send(text)                 -> true | nil, err     (opcode 0x1, UTF-8 text)
    ws:sendBinary(bytes)          -> true | nil, err     (opcode 0x2)
    ws:sendPing(data)             ws:sendPong(data)
    ws:close(code, reason)        -- starts the closing handshake
    ws:isOpen()                   ws:pump()      ws:feed(rawBytes)
    ws.id                         monotonic integer, unique per process
    ws.remoteIp                   peer address as a string ('' when unknown)
    ws.user                       EMPTY TABLE the hub owns: session, account id, subs...
    ws.onMessage / ws.onClose / ws.onError / ws.onPing / ws.onPong
    ws.bytesIn / ws.bytesOut / ws.messagesIn / ws.messagesOut

Callbacks are `onMessage(ws, message, isBinary)`, `onClose(ws, code, reason)` (fired
exactly once, for every reason including an abnormal disconnect) and `onError(ws, msg)`.

------------------------------------------------------------------------ options
    allowedOrigins origin policy, see ORIGIN above       (default: same-origin only)
    allowNoOrigin  accept a handshake with no Origin header        (default false)
    maxConnections refuse (503) past this many live connections, 0 = no cap (default 0)
    pending        string of bytes already read from the socket   (default '')
    maxMessage     bytes, enforced per frame AND across fragments (default 1 MiB)
    frameTimeout   ms a single frame may take to arrive in full   (default 30000)
    fragmentSize   outgoing payloads larger than this are fragmented (default 64 KiB)
    pingInterval   ms of silence before an automatic ping, 0 disables (default 30000)
    pongTimeout    ms to wait for the pong before reaping the peer  (default 10000)
    idleTimeout    ms of total silence before reaping, 0 disables   (default 120000)
    closeTimeout   ms to wait for the peer's close echo             (default 5000)
    lingerTimeout  ms to wait for our own close frame to drain      (default 5000)
    maxOutbox      bytes of unsent backlog before the peer is dropped with 1008,
                   0 disables the check                             (default 8 MiB)
    protocols      array of acceptable Sec-WebSocket-Protocol tokens (default: none)
    register       false => do not touch sched; the caller pumps the socket itself
    autoTimer      false => do not install the shared sched timer (drive wsserver.tick)
    id, remoteIp   override the generated values

------------------------------------------------------------------- what is checked
Handshake: method GET, `Upgrade: websocket`, `Connection: ... upgrade ...`,
`Sec-WebSocket-Version: 13` (else 426 + the version header) and a `Sec-WebSocket-Key`
that base64-decodes to exactly 16 bytes.  The accept value is
base64(SHA1(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")) -- lib/sha1.lua exists for
this and nothing else (lib/sha2.lua is SHA-256 only).

Frames, all of which fail the connection with the RFC's code:
  * any RSV bit set                                            -> 1002
  * an opcode outside {0,1,2,8,9,10}                           -> 1002
  * a fragmented control frame, or one longer than 125 bytes   -> 1002
  * an UNMASKED client frame (RFC 6455 5.1: clients must mask) -> 1002
  * the MSB of a 64-bit length set                             -> 1002
  * a continuation with no message started, or a new data frame
    while a fragmented message is in progress                  -> 1002
  * a close frame with a 1-byte payload or a reserved code     -> 1002
  * invalid UTF-8 in a text message or in a close reason       -> 1007
  * a frame, or a fragment total, over maxMessage              -> 1009

Control frames are answered immediately, even in the middle of a fragmented message:
a ping is ponged with the same payload, a close is echoed with the same code.

------------------------------------------------------------------------- LuaJIT
Lua 5.1: no goto, `bit` for the masking, math.floor for integer division.  bit.band is
SIGNED, so every place that needs an unsigned 32-bit value normalises with
% 0x100000000; the frame lengths are plain Lua doubles (exact well past 2^32) and are
never passed through bit at all.
============================================================================]]

local bit    = require('bit')
local sha1   = require('lib.sha1')
local base64 = require('lib.base64')
local sys    = require('lib.sys')

local band, bxor  = bit.band, bit.bxor
local sbyte, schar, ssub, srep = string.byte, string.char, string.sub, string.rep
local sfind, slower, sformat   = string.find, string.lower, string.format
local concat, floor = table.concat, math.floor

local wsserver = {}

wsserver.GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

-- opcodes
local OP_CONT, OP_TEXT, OP_BIN   = 0x0, 0x1, 0x2
local OP_CLOSE, OP_PING, OP_PONG = 0x8, 0x9, 0xa
wsserver.OP_CONT, wsserver.OP_TEXT, wsserver.OP_BIN = OP_CONT, OP_TEXT, OP_BIN
wsserver.OP_CLOSE, wsserver.OP_PING, wsserver.OP_PONG = OP_CLOSE, OP_PING, OP_PONG

-- close codes we use
wsserver.CLOSE_NORMAL        = 1000
wsserver.CLOSE_GOING_AWAY    = 1001
wsserver.CLOSE_PROTOCOL      = 1002
wsserver.CLOSE_UNSUPPORTED   = 1003
wsserver.CLOSE_NO_STATUS     = 1005   -- never sent on the wire
wsserver.CLOSE_ABNORMAL      = 1006   -- never sent on the wire
wsserver.CLOSE_INVALID_DATA  = 1007
wsserver.CLOSE_POLICY        = 1008
wsserver.CLOSE_TOO_BIG       = 1009
wsserver.CLOSE_INTERNAL      = 1011

local DEFAULTS = {
    maxMessage    = 1024 * 1024,
    fragmentSize  = 64 * 1024,
    pingInterval  = 30000,
    pongTimeout   = 10000,
    idleTimeout   = 120000,
    closeTimeout  = 5000,
    lingerTimeout = 5000,
    maxOutbox     = 8 * 1024 * 1024,
    frameTimeout  = 30000,
}
wsserver.defaults = DEFAULTS

--==========================================================================================
-- UTF-8 (RFC 3629, strict: no overlongs, no surrogates, nothing above U+10FFFF)
--==========================================================================================

--- Scan `s` (optionally continuing from `pending`, the truncated tail of an earlier chunk).
--- Returns  true, remainder   when everything scanned so far is valid, `remainder` being the
--- trailing bytes of an incomplete-but-still-possible sequence (at most 3 bytes), or
--- false when the bytes can never be valid UTF-8.
local function utf8Scan(s, pending)
    if pending and #pending > 0 then s = pending .. s end
    local n, i = #s, 1
    while i <= n do
        local c = sbyte(s, i)
        if c < 0x80 then
            i = i + 1
        elseif c < 0xc2 then
            return false                       -- stray continuation, or the C0/C1 overlongs
        elseif c < 0xe0 then
            if i + 1 > n then return true, ssub(s, i) end
            local c2 = sbyte(s, i + 1)
            if c2 < 0x80 or c2 > 0xbf then return false end
            i = i + 2
        elseif c < 0xf0 then
            local lo, hi = 0x80, 0xbf
            if c == 0xe0 then lo = 0xa0                 -- no overlong 3-byte forms
            elseif c == 0xed then hi = 0x9f end         -- no UTF-16 surrogates D800..DFFF
            if i + 1 > n then return true, ssub(s, i) end
            local c2 = sbyte(s, i + 1)
            if c2 < lo or c2 > hi then return false end
            if i + 2 > n then return true, ssub(s, i) end
            local c3 = sbyte(s, i + 2)
            if c3 < 0x80 or c3 > 0xbf then return false end
            i = i + 3
        elseif c < 0xf5 then
            local lo, hi = 0x80, 0xbf
            if c == 0xf0 then lo = 0x90                 -- no overlong 4-byte forms
            elseif c == 0xf4 then hi = 0x8f end         -- nothing above U+10FFFF
            if i + 1 > n then return true, ssub(s, i) end
            local c2 = sbyte(s, i + 1)
            if c2 < lo or c2 > hi then return false end
            if i + 2 > n then return true, ssub(s, i) end
            local c3 = sbyte(s, i + 2)
            if c3 < 0x80 or c3 > 0xbf then return false end
            if i + 3 > n then return true, ssub(s, i) end
            local c4 = sbyte(s, i + 3)
            if c4 < 0x80 or c4 > 0xbf then return false end
            i = i + 4
        else
            return false                       -- 0xF5..0xFF never start a sequence
        end
    end
    return true, ''
end
wsserver.utf8Scan = utf8Scan

--- Complete-string check: valid AND not truncated.
function wsserver.validUtf8(s)
    local ok, rest = utf8Scan(s, nil)
    return ok and rest == ''
end

--==========================================================================================
-- masking
--==========================================================================================

--- XOR `s` with the 4-byte `key`.  Eight bytes at a time: 8 is a multiple of the key
--- length, so the key offsets repeat and no rotation bookkeeping is needed in the loop.
local function xorMask(s, key)
    local n = #s
    if n == 0 then return s end
    local k1, k2, k3, k4 = sbyte(key, 1, 4)
    if k1 == 0 and k2 == 0 and k3 == 0 and k4 == 0 then return s end
    local out, m, i = {}, 0, 1
    while n - i >= 7 do
        local a, b, c, d, e, f, g, h = sbyte(s, i, i + 7)
        m = m + 1
        out[m] = schar(bxor(a, k1), bxor(b, k2), bxor(c, k3), bxor(d, k4),
                       bxor(e, k1), bxor(f, k2), bxor(g, k3), bxor(h, k4))
        i = i + 8
    end
    if i <= n then
        -- at most 7 bytes left, and (i-1) is a multiple of 8, so the key is in phase
        local t, j = {}, 0
        local ring = { k1, k2, k3, k4 }
        while i <= n do
            j = j + 1
            t[j] = schar(bxor(sbyte(s, i), ring[((i - 1) % 4) + 1]))
            i = i + 1
        end
        m = m + 1
        out[m] = concat(t)
    end
    return (m == 1) and out[1] or concat(out)
end
wsserver.xorMask = xorMask

--==========================================================================================
-- frame encoding  (also usable by tests and by a future client half)
--==========================================================================================

--- Frame header for `op` / `len`.  `maskKey`, when given, must be exactly 4 bytes.
local function frameHeader(op, len, fin, maskKey)
    local b1 = (fin and 0x80 or 0) + op
    local b2 = maskKey and 0x80 or 0
    local hdr
    if len < 126 then
        hdr = schar(b1, b2 + len)
    elseif len < 65536 then
        hdr = schar(b1, b2 + 126, floor(len / 256) % 256, len % 256)
    else
        local hi = floor(len / 4294967296)
        local lo = len % 4294967296
        hdr = schar(b1, b2 + 127,
                    floor(hi / 16777216) % 256, floor(hi / 65536) % 256,
                    floor(hi / 256) % 256,      hi % 256,
                    floor(lo / 16777216) % 256, floor(lo / 65536) % 256,
                    floor(lo / 256) % 256,      lo % 256)
    end
    if maskKey then hdr = hdr .. maskKey end
    return hdr
end
wsserver.frameHeader = frameHeader

--- Complete frame.  `maskKey` may be a 4-byte string, or `true` to draw a random one
--- (that is the client behaviour; the server never masks).
function wsserver.frame(op, payload, fin, maskKey)
    payload = payload or ''
    if fin == nil then fin = true end
    if maskKey == true then maskKey = sys.randomBytes(4) end
    if maskKey then
        if #maskKey ~= 4 then error('wsserver.frame: mask key must be 4 bytes', 2) end
        return frameHeader(op, #payload, fin, maskKey) .. xorMask(payload, maskKey)
    end
    return frameHeader(op, #payload, fin, nil) .. payload
end

local function closePayload(code, reason)
    if not code then return '' end
    reason = reason or ''
    if #reason > 123 then reason = ssub(reason, 1, 123) end
    return schar(floor(code / 256) % 256, code % 256) .. reason
end

--==========================================================================================
-- incoming byte queue -- a chunk list, so byte-at-a-time delivery of a big frame stays
-- O(total) instead of the O(n^2) a growing `buf = buf .. data` string would cost.
--==========================================================================================

local Q = {}
Q.__index = Q

local function newQueue()
    return setmetatable({ c = {}, head = 1, tail = 0, off = 0, len = 0 }, Q)
end

-- One Lua array slot per push costs ~9 bytes of structural overhead per BYTE when a
-- peer dribbles its payload one byte at a time -- maxMessage bounds the declared
-- payload but not that, so a 1 MiB limit really meant ~10 MB per connection.  Small
-- pushes are therefore concatenated into the tail chunk until it reaches COALESCE
-- bytes: the slot count drops by up to COALESCE and the copying stays bounded at
-- COALESCE/2 bytes per byte received (a 64 KiB recv never copies at all).
-- Concatenating into c[tail] is safe while head == tail: `off` indexes that same
-- string from the left and the bytes before it do not move.
local COALESCE = 512
Q.COALESCE = COALESCE

function Q:push(s)
    local n = #s
    if n == 0 then return end
    local t = self.tail
    if t >= self.head then
        local last = self.c[t]
        if #last + n <= COALESCE then
            self.c[t] = last .. s
            self.len  = self.len + n
            return
        end
    end
    self.tail = t + 1
    self.c[self.tail] = s
    self.len = self.len + n
end

--- First n bytes WITHOUT consuming them (n is always a small header here), or nil.
function Q:peek(n)
    if self.len < n then return nil end
    if n == 0 then return '' end
    local first = self.c[self.head]
    if #first - self.off >= n then return ssub(first, self.off + 1, self.off + n) end
    local t, got, i, off = {}, 0, self.head, self.off
    while got < n do
        local ch = self.c[i]
        local avail = #ch - off
        local take = n - got
        if take > avail then take = avail end
        t[#t + 1] = ssub(ch, off + 1, off + take)
        got, off, i = got + take, 0, i + 1
    end
    return concat(t)
end

--- First n bytes, consumed, or nil when fewer than n are buffered.
function Q:take(n)
    if self.len < n then return nil end
    if n == 0 then return '' end
    local t, got = {}, 0
    while got < n do
        local ch = self.c[self.head]
        local avail = #ch - self.off
        local need = n - got
        if need >= avail then
            t[#t + 1] = (self.off == 0) and ch or ssub(ch, self.off + 1)
            got = got + avail
            self.c[self.head] = nil
            self.head = self.head + 1
            self.off = 0
        else
            t[#t + 1] = ssub(ch, self.off + 1, self.off + need)
            self.off = self.off + need
            got = got + need
        end
    end
    self.len = self.len - n
    if self.head > self.tail then self.c, self.head, self.tail, self.off = {}, 1, 0, 0 end
    return (#t == 1) and t[1] or concat(t)
end

wsserver._newQueue = newQueue   -- exported for the test suite

--==========================================================================================
-- handshake
--==========================================================================================

--- Case-insensitive header lookup that also accepts an array value (repeated header).
local function hget(headers, name)
    if type(headers) ~= 'table' then return nil end
    local v = headers[name]
    if v == nil then
        local want = slower(name)
        for k, vv in pairs(headers) do
            if type(k) == 'string' and slower(k) == want then v = vv; break end
        end
    end
    if type(v) == 'table' then v = concat(v, ', ') end
    if v == nil then return nil end
    return tostring(v)
end
wsserver.header = hget

--- true when the comma-separated header `v` contains `token` (case-insensitive).
local function hasToken(v, token)
    if not v then return false end
    v = slower(v)
    for part in v:gmatch('[^,]+') do
        if part:match('^%s*(.-)%s*$') == token then return true end
    end
    return false
end

--- Sec-WebSocket-Accept for a client key.  RFC 6455 4.2.2 step 5.4.
function wsserver.acceptKey(key)
    return base64.encode(sha1.sha1(key .. wsserver.GUID))
end

--==========================================================================================
-- origin policy  (see the ORIGIN block in the header comment)
--==========================================================================================

local liveCount = 0          -- defined here so checkRequest can enforce maxConnections
local liveSet                -- (assigned with the shared timer, below)

local DEFAULT_PORT = { http = '80', https = '443', ws = '80', wss = '443' }

--- "user@[::1]:8080/x" -> "[::1]", "8080".  Returns nil when there is no host.
local function splitAuthority(auth)
    if type(auth) ~= 'string' then return nil end
    auth = auth:match('^%s*(.-)%s*$'):match('^([^/?#]*)')
    if not auth or auth == '' then return nil end
    auth = auth:gsub('^[^@]*@', '')
    local host, port = auth:match('^(%[[^%]]*%]):(%d+)$')
    if not host then host, port = auth:match('^(%[[^%]]*%])$'), nil end
    if not host then host, port = auth:match('^([^:%[%]]+):(%d+)$') end
    if not host then host, port = auth:match('^([^:%[%]]+)$'), nil end
    if not host or host == '' then return nil end
    return slower(host), port or ''
end
wsserver._splitAuthority = splitAuthority

--- Normalise an origin ("https://Panel.Example:443") or a bare authority
--- ("panel.example:8443") to host, port -- with a scheme's default port removed so
--- "https://x" and "x:443" compare equal.  Returns nil when it cannot be parsed.
local function normOrigin(s)
    if type(s) ~= 'string' then return nil end
    s = s:match('^%s*(.-)%s*$')
    if s == '' or slower(s) == 'null' then return nil end
    if s:find('%s') then return nil end            -- more than one origin: refuse
    local scheme, rest = s:match('^(%a[%w+.%-]*)://(.*)$')
    local host, port = splitAuthority(rest or s)
    if not host then return nil end
    if scheme then
        scheme = slower(scheme)
        if port == '' then port = DEFAULT_PORT[scheme] or '' end
        if port ~= '' and DEFAULT_PORT[scheme] == port then port = '' end
    end
    return host, port
end
wsserver.normaliseOrigin = normOrigin

--- Decide whether this handshake's Origin may open a socket.
--- Returns true, or false plus the reason for the 403.
function wsserver.originAllowed(req, opts)
    opts = opts or {}
    local h = (type(req) == 'table') and (req.headers or req.header) or nil
    local raw = hget(h, 'origin')
    local policy = opts.allowedOrigins

    if raw == nil or raw:match('^%s*$') then
        -- No Origin at all: not a browser (or a browser told not to say).  Allowed
        -- only when the caller asked for it -- otherwise the check is trivially
        -- bypassed by omitting the header.
        if opts.allowNoOrigin then return true end
        return false, 'missing Origin header (set allowNoOrigin for non-browser clients)'
    end
    if policy == '*' or policy == true then return true end
    if type(policy) == 'function' then
        local ok, allowed = pcall(policy, raw, req)
        if ok and allowed then return true end
        return false, 'origin ' .. raw .. ' is not allowed'
    end

    local ohost, oport = normOrigin(raw)
    if not ohost then return false, 'unusable Origin header' end

    if type(policy) == 'table' then
        for i = 1, #policy do
            local ahost, aport = normOrigin(policy[i])
            if ahost == ohost and (aport == oport or aport == '' or oport == '') then
                return true
            end
        end
        return false, 'origin ' .. raw .. ' is not in the allow-list'
    end
    if policy ~= nil then return false, 'origin ' .. raw .. ' is not allowed' end

    -- default: same origin as the Host this request was addressed to
    local hostHdr = hget(h, 'host')
    if hostHdr == nil or hostHdr == '' then
        return false, 'no Host header to compare the Origin against'
    end
    local hhost, hport = splitAuthority(hostHdr)
    if not hhost then return false, 'unusable Host header' end
    if hhost ~= ohost then
        return false, 'cross-origin handshake from ' .. raw .. ' (Host is ' .. hostHdr .. ')'
    end
    -- PORTS ARE COMPARED, ALWAYS.  Skipping the comparison when either side omits
    -- a port -- which normOrigin makes common, because it removes a scheme's
    -- default -- made `http://localhost` (port 80) and `https://localhost`
    -- (port 443) same-origin with `Host: localhost:8877`.  Cookies are not
    -- port-scoped, so ANY other service on 80 or 443 (or an XSS in one) could
    -- then open an authenticated socket here.  Both sides are resolved to an
    -- explicit port instead: the Origin's from its scheme, the Host's from the
    -- listener (opts.defaultPort) or, failing that, from the Origin's scheme.
    -- The lenient behaviour a TLS terminator needs stays available, but only
    -- through an explicit allowedOrigins list above.
    local oscheme = raw:match('^(%a[%w+.%-]*)://')
    local odef = oscheme and DEFAULT_PORT[slower(oscheme)] or nil
    if oport == '' then oport = odef or '' end
    if hport == '' then
        hport = (opts.defaultPort and tostring(opts.defaultPort)) or odef or ''
    end
    if hport ~= oport then
        return false, 'cross-origin handshake from ' .. raw ..
                      ' (Host is ' .. hostHdr .. ': port ' .. tostring(hport) ..
                      ' vs ' .. tostring(oport) .. ')'
    end
    return true
end

--- Validate an upgrade request.
--- Returns  accept, chosenProtocol            on success
---          nil, { status, message, headers } on rejection
function wsserver.checkRequest(req, opts)
    opts = opts or {}
    if type(req) ~= 'table' then
        return nil, { status = 400, message = 'no request' }
    end
    local h = req.headers or req.header
    local method = req.method
    if method and slower(method) ~= 'get' then
        return nil, { status = 405, message = 'websocket upgrade requires GET',
                      headers = { Allow = 'GET' } }
    end
    if not hasToken(hget(h, 'upgrade'), 'websocket') then
        return nil, { status = 400, message = 'missing or wrong Upgrade header' }
    end
    if not hasToken(hget(h, 'connection'), 'upgrade') then
        return nil, { status = 400, message = 'missing or wrong Connection header' }
    end
    local ver = hget(h, 'sec-websocket-version')
    if ver == nil or ver:match('^%s*(.-)%s*$') ~= '13' then
        return nil, { status = 426, message = 'unsupported Sec-WebSocket-Version',
                      headers = { ['Sec-WebSocket-Version'] = '13' } }
    end
    local key = hget(h, 'sec-websocket-key')
    if key == nil then
        return nil, { status = 400, message = 'missing Sec-WebSocket-Key' }
    end
    key = key:match('^%s*(.-)%s*$')
    local raw = base64.decode(key)
    if raw == nil or #raw ~= 16 then
        return nil, { status = 400, message = 'Sec-WebSocket-Key is not 16 base64 bytes' }
    end

    -- Origin LAST among the syntax checks and BEFORE the upgrade: a browser sends the
    -- session cookie on a cross-site WebSocket and CORS does not apply, so this is the
    -- only thing standing between a page the operator visits and the panel's API.
    local originOk, why = wsserver.originAllowed(req, opts)
    if not originOk then
        return nil, { status = 403, message = why or 'origin not allowed' }
    end

    local cap = tonumber(opts.maxConnections) or 0
    if cap > 0 and liveCount >= cap then
        return nil, { status = 503, message = 'too many websocket connections' }
    end

    local chosen = nil
    if opts.protocols and #opts.protocols > 0 then
        local offered = hget(h, 'sec-websocket-protocol') or ''
        for part in offered:gmatch('[^,]+') do
            local t = part:match('^%s*(.-)%s*$')
            for i = 1, #opts.protocols do
                if opts.protocols[i] == t then chosen = t; break end
            end
            if chosen then break end
        end
        if not chosen and opts.requireProtocol then
            return nil, { status = 400, message = 'no acceptable Sec-WebSocket-Protocol' }
        end
    end
    return wsserver.acceptKey(key), chosen
end

local STATUS_TEXT = {
    [400] = 'Bad Request', [403] = 'Forbidden', [405] = 'Method Not Allowed',
    [426] = 'Upgrade Required', [500] = 'Internal Server Error',
    [503] = 'Service Unavailable',
}

local function httpError(conn, status, message, headers)
    local body = (message or 'bad request') .. '\n'
    local t = { sformat('HTTP/1.1 %d %s\r\n', status, STATUS_TEXT[status] or 'Error'),
                'Connection: close\r\n',
                'Content-Type: text/plain; charset=utf-8\r\n',
                sformat('Content-Length: %d\r\n', #body) }
    if headers then
        for k, v in pairs(headers) do t[#t + 1] = sformat('%s: %s\r\n', k, v) end
    end
    t[#t + 1] = '\r\n'
    t[#t + 1] = body
    pcall(conn.send, conn, concat(t))
end

--==========================================================================================
-- shared timer -- one sched.every() for every connection in the process, not one each
--==========================================================================================

liveSet = {}            -- ws -> true, every connection that still owns a socket
                        -- (liveSet / liveCount are declared with the origin policy)
local timerId   = nil
local schedRef  = nil

local function ensureTimer()
    if timerId then return end
    local ok, sched = pcall(require, 'lib.sched')
    if not ok then return end
    schedRef = sched
    timerId = sched.every(1000, function () wsserver.tick() end)
end

--- Install a fresh shared timer, dropping any previous one.  sched.reset() throws every
--- timer away without telling anyone, so anything that calls it (tests, a reconnect path)
--- must call this afterwards or the ping / idle / close deadlines stop being checked.
function wsserver.rearmTimer()
    if timerId and schedRef then pcall(schedRef.cancel, timerId) end
    timerId, schedRef = nil, nil
    ensureTimer()
    return timerId ~= nil
end

--- Drive every connection's ping / pong / idle / close deadlines.  Called once a second by
--- the shared sched timer; tests call it directly with a fabricated `now`.
function wsserver.tick(now)
    now = now or sys.nowMs()
    for ws in pairs(liveSet) do
        local ok, err = pcall(ws._tick, ws, now)
        if not ok then
            local h = ws.onError
            if h then pcall(h, ws, 'tick: ' .. tostring(err)) end
        end
    end
end

function wsserver.count() return liveCount end

--- Close every live connection (hub shutdown) and drop the shared timer.
function wsserver.shutdown(code, reason)
    local all = {}
    for ws in pairs(liveSet) do all[#all + 1] = ws end
    for i = 1, #all do
        pcall(all[i].close, all[i], code or wsserver.CLOSE_GOING_AWAY, reason or 'server shutdown')
        pcall(all[i]._teardown, all[i], true)
    end
    if timerId and schedRef then schedRef.cancel(timerId) end
    timerId, schedRef = nil, nil
end

--==========================================================================================
-- the connection object
--==========================================================================================

local WS = {}
WS.__index = WS
wsserver.WS = WS

local nextId = 0

local function isValidCloseCode(c)
    if c >= 3000 and c <= 4999 then return true end
    if c == 1000 or c == 1001 or c == 1002 or c == 1003 then return true end
    if c >= 1007 and c <= 1014 then return true end
    return false            -- 0..999, 1004 (unused), 1005/1006 (never on the wire),
end                         -- 1015 (TLS failure, never on the wire), 1016..2999 (reserved)

function WS:isOpen() return self.state == 'open' end

function WS:_report(msg)
    local h = self.onError
    if h then pcall(h, self, msg) end
end

--- Fire onClose exactly once.
function WS:_fireClose(code, reason)
    if self.closeFired then return end
    self.closeFired = true
    self.closeCode, self.closeReason = code, reason or ''
    local h = self.onClose
    if h then pcall(h, self, code, reason or '') end
end

--- Put a raw frame on the wire.  Never blocks: lib/socket.lua buffers the remainder.
function WS:_sendRaw(bytes)
    local c = self.conn
    if not c then return nil, 'connection is gone' end
    local n, err = c:send(bytes)
    if n == nil then
        self:_report('send failed: ' .. tostring(err))
        self:_fireClose(wsserver.CLOSE_ABNORMAL, 'send failed')
        self.state = 'closed'
        self:_teardown(true)
        return nil, err
    end
    self.bytesOut = self.bytesOut + #bytes
    -- Backpressure.  lib/socket.lua's outbox is unbounded, so a browser that stops reading
    -- would otherwise let the hub's 1 Hz telemetry grow without limit.  Drop such a peer.
    if self.maxOutbox > 0 and c.outboxLen and c.outboxLen > self.maxOutbox then
        self:_report(sformat('send backlog of %d bytes exceeds maxOutbox (%d)',
                             c.outboxLen, self.maxOutbox))
        self:destroy(wsserver.CLOSE_POLICY, 'send backlog exceeded')
        return nil, 'send backlog exceeded'
    end
    return true
end

function WS:_sendFrame(op, payload, fin)
    return self:_sendRaw(frameHeader(op, #payload, fin, nil) .. payload)
end

--- Send the close frame at most once.
function WS:_sendClose(code, reason)
    if self.closeSent then return true end
    self.closeSent = true
    return self:_sendFrame(OP_CLOSE, closePayload(code, reason), true)
end

--- Fail the connection: RFC 6455 7.1.7 -- send Close with the status code, then drop the
--- TCP connection without waiting for the peer's echo.  Always returns false so the frame
--- loop can `return self:_fail(...)`.
function WS:_fail(code, reason)
    if self.state ~= 'closed' then
        self:_sendClose(code, reason)
        self.state = 'closed'
        self:_report(sformat('protocol failure %d: %s', code, reason))
        self:_fireClose(code, reason)
        self.lingerUntil = sys.nowMs() + self.lingerTimeout
        self:_teardown(false)
    end
    return false
end

--- Peer's TCP connection went away (EOF or a socket error).
function WS:_peerGone(err)
    if self.state == 'closing' then
        self:_fireClose(self.pendingCode or wsserver.CLOSE_NORMAL, self.pendingReason or '')
    elseif self.state ~= 'closed' then
        if err and err ~= 'closed' then self:_report('socket error: ' .. tostring(err)) end
        self:_fireClose(wsserver.CLOSE_ABNORMAL, 'connection closed abnormally')
    end
    self.state = 'closed'
    self:_teardown(true)
end

--- Drop the socket.  Unless `force`, wait until our own close frame has actually left the
--- outbox (lib/socket.lua's :close() discards whatever is still queued).
function WS:_teardown(force)
    local c = self.conn
    if not c then return end
    if not force then
        if c.flush and c.outboxLen and c.outboxLen > 0 then pcall(c.flush, c) end
        if c.outboxLen and c.outboxLen > 0 then
            if not self.lingerUntil then self.lingerUntil = sys.nowMs() + self.lingerTimeout end
            return                                   -- retried from _onWritable / _tick
        end
    end
    self.conn = nil
    if self.sched then pcall(self.sched.removeSocket, c) end
    pcall(c.close, c)
    if liveSet[self] then liveSet[self] = nil; liveCount = liveCount - 1 end
end

function WS:_onWritable()
    if self.state == 'closed' then self:_teardown(false) end
end

--==========================================================================================
-- receive path
--==========================================================================================

--- Read whatever the socket has right now and feed it to the parser.  Never blocks.
function WS:pump()
    for _ = 1, 128 do
        local c = self.conn
        if not c then return end
        local data, err = c:recv(65536)
        if data == nil then
            self:_peerGone(err)
            return
        elseif data == '' then
            return
        end
        self:feed(data)
        if #data < 65536 then return end
    end
end

--- Push raw bytes into the frame parser.  Public so a caller that owns the socket (or a
--- test) can deliver bytes itself, one at a time if it likes.
function WS:feed(data)
    if data == nil or #data == 0 then return end
    self.bytesIn = self.bytesIn + #data
    if self.state == 'closed' then return end        -- discard anything after a failure
    -- NOTE: lastRecv and awaitingPong are deliberately NOT touched here.  Resetting the
    -- idle timer on every BYTE made a peer that dribbles one byte per (idleTimeout/2)
    -- immortal and stopped pongTimeout from ever firing.  Progress is a completed
    -- FRAME (stamped in _parse) and a pong is a PONG frame (cleared in _control).
    self.q:push(data)
    self:_parse()
    if self.state == 'closed' then return end
    -- Whatever is left after parsing is ONE half-delivered frame, so it is already
    -- bounded by the maxMessage check in the header validation; this is belt and
    -- braces for a parser that somehow fails to consume.
    if self.q.len > self.maxMessage + 65536 then
        return self:_fail(wsserver.CLOSE_TOO_BIG, 'receive buffer exceeded')
    end
    -- ...and a half-delivered frame gets its own deadline, so a peer that dribbles
    -- forever cannot hold maxMessage of queue for as long as it likes.
    if self.q.len > 0 then
        if not self.frameStartedAt then self.frameStartedAt = sys.nowMs() end
    else
        self.frameStartedAt = nil
    end
end

function WS:_parse()
    local q = self.q
    while self.state ~= 'closed' do
        if q.len < 2 then return end
        local b1, b2 = sbyte(q:peek(2), 1, 2)
        local fin    = band(b1, 0x80) ~= 0
        local rsv    = band(b1, 0x70)
        local op     = band(b1, 0x0f)
        local masked = band(b2, 0x80) ~= 0
        local len    = band(b2, 0x7f)

        local hlen = 2
        if len == 126 then hlen = 4 elseif len == 127 then hlen = 10 end
        local maskAt = hlen + 1
        if masked then hlen = hlen + 4 end
        if q.len < hlen then return end
        local hdr = q:peek(hlen)

        if len == 126 then
            local a, b = sbyte(hdr, 3, 4)
            len = a * 256 + b
        elseif len == 127 then
            local a, b, c, d, e, f, g, h = sbyte(hdr, 3, 10)
            if a >= 0x80 then
                return self:_fail(wsserver.CLOSE_PROTOCOL,
                                  'the most significant bit of a 64-bit length must be 0')
            end
            len = (((a * 256 + b) * 256 + c) * 256 + d) * 4294967296
                + (((e * 256 + f) * 256 + g) * 256 + h)
        end

        -- ---- header validation, before a single payload byte is buffered ----
        if rsv ~= 0 then
            return self:_fail(wsserver.CLOSE_PROTOCOL,
                              sformat('reserved bit set (RSV=0x%02x)', rsv))
        end
        if not (op == OP_CONT or op == OP_TEXT or op == OP_BIN
                or op == OP_CLOSE or op == OP_PING or op == OP_PONG) then
            return self:_fail(wsserver.CLOSE_PROTOCOL, sformat('unknown opcode 0x%x', op))
        end
        local isControl = op >= 0x8
        if isControl then
            if not fin then
                return self:_fail(wsserver.CLOSE_PROTOCOL, 'control frames must not be fragmented')
            end
            if len > 125 then
                return self:_fail(wsserver.CLOSE_PROTOCOL,
                                  sformat('control frame payload of %d bytes exceeds 125', len))
            end
        end
        if not masked then
            return self:_fail(wsserver.CLOSE_PROTOCOL, 'client frames must be masked')
        end
        if not isControl then
            if len > self.maxMessage then
                return self:_fail(wsserver.CLOSE_TOO_BIG,
                                  sformat('frame payload of %d bytes exceeds the %d byte limit',
                                          len, self.maxMessage))
            end
            if op == OP_CONT then
                if not self.fragOp then
                    return self:_fail(wsserver.CLOSE_PROTOCOL,
                                      'continuation frame with no message in progress')
                end
                if self.fragLen + len > self.maxMessage then
                    return self:_fail(wsserver.CLOSE_TOO_BIG,
                                      sformat('fragmented message exceeds the %d byte limit',
                                              self.maxMessage))
                end
            elseif self.fragOp then
                return self:_fail(wsserver.CLOSE_PROTOCOL,
                                  'a new data frame arrived while a fragmented message was open')
            end
        end

        -- ---- the whole frame has to be here before anything is consumed ----
        if q.len < hlen + len then return end
        q:take(hlen)
        local payload = q:take(len)
        local key = ssub(hdr, maskAt, maskAt + 3)
        if #payload > 0 then payload = xorMask(payload, key) end

        self.framesIn = self.framesIn + 1
        self.lastRecv = sys.nowMs()      -- a WHOLE frame arrived: that is progress
        if isControl then
            if not self:_control(op, payload) then return end
        else
            if not self:_data(op, payload, fin) then return end
        end
    end
end

--- Handle a control frame.  Returns false when the connection is finished.
function WS:_control(op, payload)
    if op == OP_PING then
        if self.state == 'open' then self:_sendFrame(OP_PONG, payload, true) end
        local h = self.onPing
        if h then pcall(h, self, payload) end
        return self.state ~= 'closed'
    end
    if op == OP_PONG then
        self.awaitingPong = false
        local h = self.onPong
        if h then pcall(h, self, payload) end
        return self.state ~= 'closed'
    end
    -- OP_CLOSE
    local code, reason = wsserver.CLOSE_NO_STATUS, ''
    if #payload == 1 then
        self:_fail(wsserver.CLOSE_PROTOCOL, 'close frame payload of exactly one byte')
        return false
    elseif #payload >= 2 then
        code   = sbyte(payload, 1) * 256 + sbyte(payload, 2)
        reason = ssub(payload, 3)
        if not isValidCloseCode(code) then
            self:_fail(wsserver.CLOSE_PROTOCOL, sformat('reserved close code %d', code))
            return false
        end
        if not wsserver.validUtf8(reason) then
            self:_fail(wsserver.CLOSE_INVALID_DATA, 'close reason is not valid UTF-8')
            return false
        end
    end

    if self.state == 'closing' then
        -- our close went out first; this is the peer's echo, the handshake is complete
        self:_fireClose(self.pendingCode or code, self.pendingReason or reason)
    else
        -- peer closed first: echo the code straight back, then drop the connection
        if #payload >= 2 then
            self:_sendClose(code, reason)
        else
            self:_sendClose(nil, nil)              -- no code in, no code out
        end
        self:_fireClose(code, reason)
    end
    self.state = 'closed'
    self.lingerUntil = sys.nowMs() + self.lingerTimeout
    self:_teardown(false)
    return false
end

--- Handle a data frame.  Returns false when the connection is finished.
function WS:_data(op, payload, fin)
    if op == OP_CONT then
        self.fragLen = self.fragLen + #payload
        self.fragN = self.fragN + 1
        self.frag[self.fragN] = payload
        if self.fragOp == OP_TEXT then
            local ok, rest = utf8Scan(payload, self.fragUtf8)
            if not ok then
                self:_fail(wsserver.CLOSE_INVALID_DATA, 'text message is not valid UTF-8')
                return false
            end
            self.fragUtf8 = rest
        end
        if not fin then return true end
        local whole = concat(self.frag, '', 1, self.fragN)
        local wasText = (self.fragOp == OP_TEXT)
        local truncated = (self.fragUtf8 ~= '')
        self.fragOp, self.frag, self.fragN, self.fragLen, self.fragUtf8 = nil, {}, 0, 0, ''
        if wasText and truncated then
            self:_fail(wsserver.CLOSE_INVALID_DATA, 'text message ends mid UTF-8 sequence')
            return false
        end
        return self:_deliver(whole, not wasText)
    end

    if not fin then
        self.fragOp, self.frag, self.fragN, self.fragLen, self.fragUtf8 = op, { payload }, 1, #payload, ''
        if op == OP_TEXT then
            local ok, rest = utf8Scan(payload, nil)
            if not ok then
                self:_fail(wsserver.CLOSE_INVALID_DATA, 'text message is not valid UTF-8')
                return false
            end
            self.fragUtf8 = rest
        end
        return true
    end

    if op == OP_TEXT and not wsserver.validUtf8(payload) then
        self:_fail(wsserver.CLOSE_INVALID_DATA, 'text message is not valid UTF-8')
        return false
    end
    return self:_deliver(payload, op == OP_BIN)
end

function WS:_deliver(message, isBinary)
    self.messagesIn = self.messagesIn + 1
    local h = self.onMessage
    if h then
        local ok, err = pcall(h, self, message, isBinary)
        if not ok then self:_report('onMessage: ' .. tostring(err)) end
    end
    return self.state ~= 'closed'
end

--==========================================================================================
-- send path
--==========================================================================================

function WS:_sendData(op, data)
    if type(data) ~= 'string' then
        return nil, 'wsserver: payload must be a string, got ' .. type(data)
    end
    if self.state ~= 'open' then return nil, 'websocket is not open' end
    local n, fs = #data, self.fragmentSize
    if n <= fs then
        local ok, err = self:_sendFrame(op, data, true)
        if ok then self.messagesOut = self.messagesOut + 1 end
        return ok, err
    end
    local i, first = 1, true
    while i <= n do
        local last  = (i + fs - 1) >= n
        local chunk = ssub(data, i, i + fs - 1)
        local ok, err = self:_sendFrame(first and op or OP_CONT, chunk, last)
        if not ok then return nil, err end
        first = false
        i = i + fs
    end
    self.messagesOut = self.messagesOut + 1
    return true
end

function WS:send(text)         return self:_sendData(OP_TEXT, text) end
function WS:sendText(text)     return self:_sendData(OP_TEXT, text) end
function WS:sendBinary(bytes)  return self:_sendData(OP_BIN, bytes) end

function WS:sendPing(data)
    if self.state ~= 'open' then return nil, 'websocket is not open' end
    data = data or ''
    if #data > 125 then return nil, 'ping payload exceeds 125 bytes' end
    return self:_sendFrame(OP_PING, data, true)
end

function WS:sendPong(data)
    if self.state ~= 'open' then return nil, 'websocket is not open' end
    data = data or ''
    if #data > 125 then return nil, 'pong payload exceeds 125 bytes' end
    return self:_sendFrame(OP_PONG, data, true)
end

--- Start the closing handshake.  onClose fires when the peer echoes, when the echo times
--- out, or when the socket dies -- whichever happens first.
function WS:close(code, reason)
    if self.state == 'closed' then return true end
    if self.state == 'closing' then return true end
    code = code or wsserver.CLOSE_NORMAL
    reason = reason or ''
    self.pendingCode, self.pendingReason = code, reason
    self.state = 'closing'
    self.closeDeadline = sys.nowMs() + self.closeTimeout
    return self:_sendClose(code, reason)
end

--- Drop the connection now, without a handshake (hub shutdown, reaping a dead peer).
function WS:destroy(code, reason)
    if self.state ~= 'closed' then
        self.state = 'closed'
        self:_fireClose(code or wsserver.CLOSE_ABNORMAL, reason or '')
    end
    self:_teardown(true)
end

--==========================================================================================
-- deadlines
--==========================================================================================

function WS:_tick(now)
    if self.state == 'closed' then
        if self.conn then
            if self.lingerUntil and now >= self.lingerUntil then self:_teardown(true)
            else self:_teardown(false) end
        end
        return
    end
    if self.state == 'closing' then
        if self.closeDeadline and now >= self.closeDeadline then
            self:_fireClose(self.pendingCode or wsserver.CLOSE_NORMAL, self.pendingReason or '')
            self.state = 'closed'
            self:_teardown(true)
        end
        return
    end
    -- open
    local silent = now - self.lastRecv
    if self.idleTimeout > 0 and silent >= self.idleTimeout then
        self:_report('idle timeout')
        self:destroy(wsserver.CLOSE_ABNORMAL, 'idle timeout')
        return
    end
    -- a frame that started arriving and never finished (a dribbling peer holding up
    -- to maxMessage of queue), independently of whether bytes keep trickling in
    if self.frameStartedAt and self.frameTimeout > 0
       and now - self.frameStartedAt > self.frameTimeout then
        self:_report('frame delivery timeout')
        self:_fail(wsserver.CLOSE_POLICY, 'frame delivery timeout')
        return
    end
    if self.awaitingPong then
        if self.pongTimeout > 0 and now - self.pingSentAt >= self.pongTimeout then
            self:_report('ping timeout')
            self:destroy(wsserver.CLOSE_ABNORMAL, 'ping timeout')
        end
        return
    end
    if self.pingInterval > 0 and silent >= self.pingInterval then
        self.awaitingPong = true
        self.pingSentAt = now
        self:sendPing('')
    end
end

--==========================================================================================
-- upgrade
--==========================================================================================

local function optNum(opts, name)
    local v = opts[name]
    if v == nil then return DEFAULTS[name] end
    return tonumber(v) or DEFAULTS[name]
end

--- Take a socket over from the HTTP server and turn it into a WebSocket connection.
--- Returns the ws object, or nil, message, status when the handshake is refused (the
--- refusal response has already been written and the socket closed).
function wsserver.upgrade(conn, req, opts)
    opts = opts or {}
    if conn == nil then return nil, 'wsserver.upgrade: no connection', 500 end

    local accept, extra = wsserver.checkRequest(req, opts)
    if not accept then
        local rej = extra or { status = 400, message = 'bad websocket request' }
        if opts.respond ~= false then
            httpError(conn, rej.status, rej.message, rej.headers)
            if opts.keepAlive ~= true then
                if conn.flush then pcall(conn.flush, conn) end
                pcall(conn.close, conn)
            end
        end
        return nil, rej.message, rej.status
    end
    local protocol = extra

    local resp = { 'HTTP/1.1 101 Switching Protocols\r\n',
                   'Upgrade: websocket\r\n',
                   'Connection: Upgrade\r\n',
                   'Sec-WebSocket-Accept: ', accept, '\r\n' }
    if protocol then resp[#resp + 1] = 'Sec-WebSocket-Protocol: ' .. protocol .. '\r\n' end
    if opts.extraHeaders then
        for k, v in pairs(opts.extraHeaders) do
            resp[#resp + 1] = sformat('%s: %s\r\n', k, v)
        end
    end
    resp[#resp + 1] = '\r\n'
    local n, serr = conn:send(concat(resp))
    if n == nil then
        pcall(conn.close, conn)
        return nil, 'wsserver.upgrade: handshake write failed: ' .. tostring(serr), 500
    end

    nextId = nextId + 1
    local ws = setmetatable({
        id       = opts.id or nextId,
        conn     = conn,
        protocol = protocol,
        remoteIp = opts.remoteIp or conn.peerHost or '',
        remotePort = conn.peerPort,
        user     = opts.user or {},          -- the hub's per-connection scratch table
        state    = 'open',
        q        = newQueue(),

        maxMessage    = optNum(opts, 'maxMessage'),
        fragmentSize  = optNum(opts, 'fragmentSize'),
        pingInterval  = optNum(opts, 'pingInterval'),
        pongTimeout   = optNum(opts, 'pongTimeout'),
        idleTimeout   = optNum(opts, 'idleTimeout'),
        closeTimeout  = optNum(opts, 'closeTimeout'),
        lingerTimeout = optNum(opts, 'lingerTimeout'),
        maxOutbox     = optNum(opts, 'maxOutbox'),
        frameTimeout  = optNum(opts, 'frameTimeout'),

        frag = {}, fragN = 0, fragLen = 0, fragOp = nil, fragUtf8 = '',
        bytesIn = 0, bytesOut = #concat(resp), framesIn = 0,
        messagesIn = 0, messagesOut = 0,
        lastRecv = sys.nowMs(), awaitingPong = false, pingSentAt = 0,
        frameStartedAt = nil,
        closeSent = false, closeFired = false,

        onMessage = opts.onMessage, onClose = opts.onClose, onError = opts.onError,
        onPing = opts.onPing, onPong = opts.onPong,
    }, WS)
    if ws.fragmentSize < 1 then ws.fragmentSize = DEFAULTS.fragmentSize end

    liveSet[ws] = true
    liveCount = liveCount + 1

    if opts.register ~= false then
        local ok, sched = pcall(require, 'lib.sched')
        if ok and require('lib.socket').fdnum(conn) then
            ws.sched = sched
            sched.onSocket(conn, function () ws:pump() end, function () ws:_onWritable() end)
            if opts.autoTimer ~= false then ensureTimer() end
        end
    end

    if opts.onOpen then pcall(opts.onOpen, ws) end
    if opts.pending and #opts.pending > 0 then ws:feed(opts.pending) end
    return ws
end

--- Convenience wrapper for lib/httpserver.lua: `wsserver.handler{...}` returns a function
--- with the shape an HTTP route hook is expected to have.
function wsserver.handler(opts)
    opts = opts or {}
    return function (conn, req, pending)
        local o = { pending = pending }
        for k, v in pairs(opts) do if o[k] == nil then o[k] = v end end
        if pending ~= nil then o.pending = pending end
        return wsserver.upgrade(conn, req, o)
    end
end

return wsserver
