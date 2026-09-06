--[[============================================================================
lib/proxy.lua -- HTTP CONNECT tunnel handshake, as a pure state machine.

  * NO socket, NO clock, NO scheduler, NO module-level mutable state.  You build
    the request, you write it, you feed the module every byte that comes back,
    and it answers 'need-more' / 'connected' / 'error'.  proto/transport.lua wires
    the transport in; this file must stay usable from an offline test with a
    string literal.

  * Byte-for-byte compatible with the reference client's handshake
    (otclient/src/framework/net/connection.cpp:293-400).  Every deliberate
    deviation is listed in docs/proxy.md section 2.5 and marked "DEVIATION" here.

API (docs/proxy.md section 4):

    proxy.buildConnect(opts)      -> request, requestRedacted
    proxy.newHandshake(opts)      -> hs
      hs.request / hs.requestRedacted
      hs:feed(chunk [, nowMs])    -> status, a, b
      hs:tick(nowMs)              -> status, a, b
      hs:eof()                    -> 'error', msg, 'closed'
      hs.leftover                 -- early tunnel bytes once status == 'connected'
      hs.status hs.reason hs.statusLine hs.headers hs.headerList hs.realm
      hs.authSchemes hs.state hs.err hs.errorKind
    proxy.base64(s)               -> RFC 4648 (standard alphabet, '=' padding)
    proxy.redact(request)         -> request with the credential blob masked
    proxy.parseEndpoint(s)        -> host, port | nil, err
    proxy.parseAuth(s)            -> user, pass | nil, err
    proxy.formatTarget(host,port) -> "host:port" / "[v6]:port"

`opts` for buildConnect / newHandshake:
    host, port           the CONNECT TARGET -- the GAME server, not the proxy   (required)
    user, pass           proxy credentials; the header is emitted only when user ~= ''
                         (this matches HttpProxyConfig::hasAuth(): user-only, pass ignored)
    userAgent            default 'OTClient'; false omits the header entirely
    proxyConnection      default 'keep-alive'; false omits the header entirely
    extraHeaders         array of {name, value} appended before the blank line
newHandshake also takes:
    proxyHost, proxyPort informational -- only ever used to word error messages
    timeoutMs            default 30000 (Connection::READ_TIMEOUT); 0 disables
    maxHeaderBytes       default 32768; 0 disables    (DEVIATION: reference has no cap)
    interim              'skip' (default) | 'error'   (DEVIATION: reference rejects 1xx)
    nowMs                starts the timeout clock; otherwise the first feed() does

SECURITY: `hs.request` contains the base64 credential.  Log `hs.requestRedacted`.
No error message produced by this module contains the user or the password.
============================================================================]]

local proxy = {}

local byte, char, sub, find, format = string.byte, string.char, string.sub, string.find, string.format
local floor, concat = math.floor, table.concat

proxy.NEED_MORE = 'need-more'
proxy.CONNECTED = 'connected'
proxy.ERROR     = 'error'

proxy.DEFAULT_USER_AGENT       = 'OTClient'
proxy.DEFAULT_PROXY_CONNECTION = 'keep-alive'
proxy.DEFAULT_TIMEOUT_MS       = 30000        -- Connection::READ_TIMEOUT / WRITE_TIMEOUT
proxy.DEFAULT_MAX_HEADER_BYTES = 32768
proxy.MAX_LEADING_BLANK_LINES  = 4            -- RFC 9112 s2.2 robustness allowance
proxy.MAX_INTERIM              = 8            -- 1xx responses skipped before we give up

-- ============================================================ base64 (RFC 4648)
-- cppcodec::base64_rfc4648 as used by Crypt::base64Encode: standard alphabet,
-- '=' padding, no line breaks.  Pure arithmetic -- no bit ops, so no sign games.
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

function proxy.base64(s)
    if type(s) ~= 'string' then
        error('proxy.base64: expected a string, got ' .. type(s), 2)
    end
    local out, n, len, i = {}, 0, #s, 1
    while i + 2 <= len do
        local a, b, c = byte(s, i, i + 2)
        local v = a * 65536 + b * 256 + c
        n = n + 1
        out[n] = char(byte(B64, floor(v / 262144) + 1),
                      byte(B64, floor(v / 4096) % 64 + 1),
                      byte(B64, floor(v / 64) % 64 + 1),
                      byte(B64, v % 64 + 1))
        i = i + 3
    end
    local rem = len - i + 1
    if rem == 1 then
        local a = byte(s, i)
        out[n + 1] = char(byte(B64, floor(a / 4) + 1),
                          byte(B64, (a % 4) * 16 + 1)) .. '=='
    elseif rem == 2 then
        local a, b = byte(s, i, i + 1)
        out[n + 1] = char(byte(B64, floor(a / 4) + 1),
                          byte(B64, (a % 4) * 16 + floor(b / 16) + 1),
                          byte(B64, (b % 16) * 4 + 1)) .. '='
    end
    return concat(out)
end

-- ================================================================== helpers ==
-- Anything interpolated into the request is checked for CR/LF/NUL: without this
-- a password of "x\r\nX-Evil: 1" splices a header into the request.
-- DEVIATION: the reference validates nothing.
local function checkField(what, v)
    if type(v) ~= 'string' then
        return nil, format('proxy: %s must be a string, got %s', what, type(v))
    end
    if find(v, '[\r\n]') or find(v, '%z') then
        return nil, format('proxy: %s contains CR, LF or NUL', what)
    end
    return v
end

local function checkPort(p)
    p = tonumber(p)
    if not p or p ~= floor(p) or p < 1 or p > 65535 then
        return nil, 'proxy: port must be an integer in 1..65535'
    end
    return p
end

--- "host:port", bracketing an IPv6 literal.
--- DEVIATION: the reference emits the unbracketed "::1:7171".
function proxy.formatTarget(host, port)
    if find(host, ':', 1, true) and sub(host, 1, 1) ~= '[' then
        return '[' .. host .. ']:' .. port
    end
    return host .. ':' .. port
end

--- Replace the base64 credential in a built request with a placeholder.
--- The separators are horizontal whitespace only: `%s` matches CR and LF, so the old pattern's
--- greedy `%s+` swallowed the line terminator of a header whose credential blob was empty and
--- then ate the NEXT header, destroying a line the log was supposed to show.
function proxy.redact(request)
    if type(request) ~= 'string' then return request end
    -- "Proxy-Authorization: <scheme> <blob>" -- mask the blob, keep the scheme.
    local out = request:gsub('([Pp]roxy%-[Aa]uthorization:[ \t]*%a+[ \t]+)[^\r\n]*', '%1<redacted>')
    -- "Proxy-Authorization: <anything-not-scheme-plus-blob>" -- mask whatever is left on the
    -- line, so a shape this helper does not model cannot leak through unmasked.
    out = out:gsub('([Pp]roxy%-[Aa]uthorization:[ \t]*)([^\r\n]*)', function(head, rest)
        if rest == '' or rest:find('<redacted>', 1, true) then return head .. rest end
        return head .. '<redacted>'
    end)
    return out
end

--- "host:port" -> host, port.  Accepts "[::1]:6754".
function proxy.parseEndpoint(s)
    if type(s) ~= 'string' then return nil, 'proxy: endpoint must be a string' end
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    local host, port
    if sub(s, 1, 1) == '[' then
        host, port = s:match('^%[([^%]]+)%]:(%d+)$')
    else
        host, port = s:match('^([^:]+):(%d+)$')
    end
    if not host or host == '' then
        return nil, format('proxy: cannot parse endpoint %q (want host:port)', s)
    end
    local p, perr = checkPort(port)
    if not p then return nil, perr end
    local ok, herr = checkField('proxy host', host)
    if not ok then return nil, herr end
    return host, p
end

--- "user:pass" -> user, pass.  Splits on the FIRST colon so a password may
--- contain colons (the proxy splits it back the same way).
function proxy.parseAuth(s)
    if type(s) ~= 'string' then return nil, 'proxy: auth must be a string' end
    local i = find(s, ':', 1, true)
    if not i then
        return nil, 'proxy: auth must be user:pass'
    end
    local user, pass = sub(s, 1, i - 1), sub(s, i + 1)
    local ok, err = checkField('proxy user', user)
    if not ok then return nil, err end
    ok, err = checkField('proxy password', pass)
    if not ok then return nil, err end
    return user, pass
end

-- Error/log text may quote bytes a hostile proxy chose.  Keep it printable and short.
local function sanitise(s, cap)
    cap = cap or 200
    s = tostring(s or '')
    if #s > cap then s = sub(s, 1, cap) .. '...' end
    return (s:gsub('[^\32-\126]', '.'))
end

-- =========================================================== request builder ==
--- Build the CONNECT request.  Returns request, requestRedacted -- or nil, err.
function proxy.buildConnect(opts)
    opts = opts or {}

    local host, err = checkField('CONNECT target host', opts.host or '')
    if not host then return nil, err end
    if host == '' then return nil, 'proxy: CONNECT target host is required' end
    local port, perr = checkPort(opts.port)
    if not port then return nil, perr end

    local user, pass = opts.user or '', opts.pass or ''
    local ok
    ok, err = checkField('proxy user', user); if not ok then return nil, err end
    ok, err = checkField('proxy password', pass); if not ok then return nil, err end

    local target = proxy.formatTarget(host, port)
    local out = { 'CONNECT ' .. target .. ' HTTP/1.1\r\n', 'Host: ' .. target .. '\r\n' }
    local red = { out[1], out[2] }

    -- Header order is the reference's, exactly: request line, Host, User-Agent,
    -- Proxy-Connection, Proxy-Authorization, blank line.
    if opts.userAgent ~= false then
        local ua = opts.userAgent or proxy.DEFAULT_USER_AGENT
        ok, err = checkField('user agent', ua); if not ok then return nil, err end
        out[#out + 1] = 'User-Agent: ' .. ua .. '\r\n'
        red[#red + 1] = out[#out]
    end
    if opts.proxyConnection ~= false then
        local pc = opts.proxyConnection or proxy.DEFAULT_PROXY_CONNECTION
        ok, err = checkField('proxy-connection', pc); if not ok then return nil, err end
        out[#out + 1] = 'Proxy-Connection: ' .. pc .. '\r\n'
        red[#red + 1] = out[#out]
    end

    -- HttpProxyConfig::hasAuth() is `!m_user.empty()`: a password without a user
    -- sends NO header at all.  Reproduced deliberately.
    local hasAuth = (user ~= '')
    if hasAuth then
        out[#out + 1] = 'Proxy-Authorization: Basic ' .. proxy.base64(user .. ':' .. pass) .. '\r\n'
        red[#red + 1] = 'Proxy-Authorization: Basic <redacted>\r\n'
    end

    if opts.extraHeaders then
        for i = 1, #opts.extraHeaders do
            local h = opts.extraHeaders[i]
            local hn, hv = h[1] or h.name, h[2] or h.value
            ok, err = checkField('extra header name', hn or ''); if not ok then return nil, err end
            ok, err = checkField('extra header value', hv or ''); if not ok then return nil, err end
            out[#out + 1] = hn .. ': ' .. hv .. '\r\n'
            red[#red + 1] = out[#out]
        end
    end

    out[#out + 1] = '\r\n'
    red[#red + 1] = '\r\n'
    return concat(out), concat(red), hasAuth
end

-- ============================================================ state machine ==
local HS = {}
HS.__index = HS

-- Never let a stray tostring()/serialisation of the handshake print the request
-- (which carries the credential blob).
HS.__tostring = function(self)
    return format('proxy.handshake{ target=%s state=%s status=%s }',
                  tostring(self.target), tostring(self.state), tostring(self.status or '-'))
end

function proxy.newHandshake(opts)
    opts = opts or {}
    local request, redacted, hasAuth = proxy.buildConnect(opts)
    if not request then return nil, redacted end

    local hs = setmetatable({
        request         = request,
        requestRedacted = redacted,
        hasAuth         = hasAuth,

        target      = proxy.formatTarget(opts.host, tonumber(opts.port)),
        targetHost  = opts.host,
        targetPort  = tonumber(opts.port),
        proxyHost   = opts.proxyHost,
        proxyPort   = opts.proxyPort and tonumber(opts.proxyPort) or nil,

        state   = 'init',            -- init | reading | done | failed
        buf     = '',
        scan    = 1,
        bytesIn = 0,

        statusLine = nil, status = nil, reason = nil, httpVersion = nil,
        headers = {}, headerList = {},
        realm = nil, authSchemes = nil,
        leftover = '',
        err = nil, errorKind = nil,

        leadingBlank = 0,
        interimCount = 0,
        lastHeaderKey = nil,

        timeoutMs      = opts.timeoutMs      or proxy.DEFAULT_TIMEOUT_MS,
        maxHeaderBytes = opts.maxHeaderBytes or proxy.DEFAULT_MAX_HEADER_BYTES,
        interim        = opts.interim        or 'skip',
        startMs        = opts.nowMs,
    }, HS)
    return hs
end

function HS:_where()
    if self.proxyHost then
        return format('proxy %s', proxy.formatTarget(self.proxyHost, self.proxyPort or 0))
    end
    return 'proxy'
end

function HS:_fail(kind, msg)
    self.state, self.errorKind, self.err = 'failed', kind, msg
    return proxy.ERROR, msg, kind
end

--- Start (or restart) the timeout clock without feeding anything.
function HS:start(nowMs)
    self.startMs = nowMs
    return self
end

local function trim(s) return (s:gsub('^[ \t]+', ''):gsub('[ \t]+$', '')) end

function HS:_addHeader(line)
    -- obs-fold: a line starting with SP/HT continues the previous header value.
    local first = sub(line, 1, 1)
    if (first == ' ' or first == '\t') and self.lastHeaderKey then
        local k = self.lastHeaderKey
        self.headers[k] = self.headers[k] .. ' ' .. trim(line)
        local last = self.headerList[#self.headerList]
        if last then last[2] = last[2] .. ' ' .. trim(line) end
        return
    end
    local k, v = line:match('^([^:]+):(.*)$')
    if not k then
        -- Not a header and not a fold.  Be lenient (the reference ignores every
        -- header line), but count it so a test can see it happened.
        self.badHeaderLines = (self.badHeaderLines or 0) + 1
        return
    end
    k, v = trim(k):lower(), trim(v)
    if k == '' then
        self.badHeaderLines = (self.badHeaderLines or 0) + 1
        return
    end
    self.headerList[#self.headerList + 1] = { k, v }
    if self.headers[k] then
        self.headers[k] = self.headers[k] .. ', ' .. v      -- RFC list-combining
    else
        self.headers[k] = v
    end
    self.lastHeaderKey = k
end

function HS:_readAuthChallenge()
    local v = self.headers['proxy-authenticate']
    if not v then return end
    self.realm = v:match('[Rr][Ee][Aa][Ll][Mm]%s*=%s*"([^"]*)"')
              or v:match('[Rr][Ee][Aa][Ll][Mm]%s*=%s*([^,%s]+)')
    -- Split on TOP-LEVEL commas only: a comma inside a quoted realm ("Basic realm=\"a,b\"")
    -- is part of the value, not a challenge separator.  Truncating to the first scheme (what
    -- this did before) threw away exactly the diagnostic this module exists to recover -- the
    -- operator could not see that the proxy would also accept Digest or NTLM.
    local schemes, seen, start, inQuotes = {}, {}, 1, false
    local function addFragment(frag)
        local s = trim(frag):match('^([%a][%w%-%.%_%~%+]*)')
        -- A fragment like `realm="corp"` is a PARAMETER of the previous challenge, not a
        -- scheme: anything with an '=' before the first space is skipped.
        if s and not trim(frag):match('^[%w%-%.%_%~%+]+%s*=') then
            local key = s:lower()
            if not seen[key] then
                seen[key] = true
                schemes[#schemes + 1] = s
            end
        end
    end
    for i = 1, #v do
        local c = sub(v, i, i)
        if c == '"' then
            inQuotes = not inQuotes
        elseif c == ',' and not inQuotes then
            addFragment(sub(v, start, i - 1))
            start = i + 1
        end
    end
    addFragment(sub(v, start))
    self.authSchemes = (#schemes > 0) and schemes or nil
end

function HS:_resetResponse()
    self.statusLine, self.status, self.reason, self.httpVersion = nil, nil, nil, nil
    self.headers, self.headerList, self.lastHeaderKey = {}, {}, nil
    self.realm, self.authSchemes = nil, nil
end

--- Feed a chunk of whatever came off the socket.  `chunk` may be '' or nil.
--- Returns:
---   'need-more'
---   'connected', leftover        -- leftover = early tunnel bytes (possibly '')
---   'error', message, kind
---
--- feed() is TOTAL: it is safe to call in the unconditional loop docs/proxy.md documents, even
--- after the tunnel opened.  Late bytes are appended to `leftover` and handed back rather than
--- dropped or raised on -- the ordinary case where the 200 arrives in one TCP segment and the
--- first tunnel bytes in the next used to raise an uncaught error and kill the worker.
function HS:feed(chunk, nowMs)
    if self.state == 'done' then
        if chunk ~= nil and #chunk > 0 then
            self.leftover = self.leftover .. chunk
        end
        return proxy.CONNECTED, self.leftover
    end
    if self.state == 'failed' then
        return proxy.ERROR, self.err, self.errorKind
    end
    if self.startMs == nil then self.startMs = nowMs end
    if chunk ~= nil and #chunk > 0 then
        self.buf = self.buf .. chunk
        self.bytesIn = self.bytesIn + #chunk
    end
    self.state = 'reading'

    -- Fast rejection of an obviously non-HTTP answer (a game server, a TLS
    -- ServerHello, binary garbage).  Only while nothing has been consumed yet.
    if self.statusLine == nil and self.scan == 1 and self.leadingBlank == 0 and #self.buf >= 5 then
        local f = sub(self.buf, 1, 1)
        if f ~= '\r' and f ~= '\n' and sub(self.buf, 1, 5) ~= 'HTTP/' then
            return self:_fail('malformed', format(
                '%s: CONNECT to %s got a non-HTTP response (first bytes %q)',
                self:_where(), self.target, sanitise(sub(self.buf, 1, 32), 32)))
        end
    end

    -- The cap has to be enforced BEFORE the parse loop.  Enforced after it, a hostile or broken
    -- proxy that puts the whole block in ONE read is buffered in full and never checked at all
    -- (4 MB sailed past a 32 KiB cap).  A legitimate 200 followed by a large tunnel payload in
    -- the same segment still succeeds: what fails is the absence of a blank line within the cap.
    if self.maxHeaderBytes > 0 and #self.buf > self.maxHeaderBytes
       and not find(sub(self.buf, 1, self.maxHeaderBytes + 3), '\r?\n\r?\n') then
        return self:_fail('too-large', format(
            '%s: CONNECT to %s response header exceeds %d bytes',
            self:_where(), self.target, self.maxHeaderBytes))
    end

    while true do
        local nl = find(self.buf, '\n', self.scan, true)
        if not nl then break end

        local line = sub(self.buf, self.scan, nl - 1)
        if sub(line, -1) == '\r' then line = sub(line, 1, -2) end
        self.scan = nl + 1

        if line == '' then
            if self.statusLine == nil then
                -- Blank line(s) before the status line: tolerated, bounded.
                self.leadingBlank = self.leadingBlank + 1
                if self.leadingBlank > proxy.MAX_LEADING_BLANK_LINES then
                    return self:_fail('malformed', format(
                        '%s: CONNECT to %s answered with %d blank lines and no status line',
                        self:_where(), self.target, self.leadingBlank))
                end
            else
                -- End of a header block.
                local st = self.status
                if st >= 100 and st <= 199 then
                    if self.interim ~= 'skip' then
                        return self:_fail('rejected', format(
                            '%s: CONNECT to %s rejected -- %s',
                            self:_where(), self.target, sanitise(self.statusLine)))
                    end
                    -- DEVIATION: skip the interim response and keep reading.  Bounded, like
                    -- every other unbounded input here: the skip branch resets self.buf, so
                    -- maxHeaderBytes can never fire on a 1xx flood and a feed-only transport
                    -- (one that never runs tick()'s watchdog) would otherwise spin forever.
                    self.interimCount = self.interimCount + 1
                    if self.interimCount > proxy.MAX_INTERIM then
                        return self:_fail('malformed', format(
                            '%s: CONNECT to %s answered with %d interim (1xx) responses and no '
                            .. 'final status', self:_where(), self.target, self.interimCount))
                    end
                    self.buf, self.scan = sub(self.buf, self.scan), 1
                    self.leadingBlank = 0
                    self:_resetResponse()
                elseif st >= 200 and st <= 299 then
                    self.leftover = sub(self.buf, self.scan)
                    self.state = 'done'
                    self.buf, self.scan = '', 1
                    return proxy.CONNECTED, self.leftover
                else
                    self:_readAuthChallenge()
                    local kind = (st == 407) and 'auth-required' or 'rejected'
                    local msg = format('%s: CONNECT to %s rejected -- %s',
                                       self:_where(), self.target, sanitise(self.statusLine))
                    if st == 407 then
                        msg = msg .. format(' (proxy authentication required%s%s)',
                                            self.realm and '; realm=' or '',
                                            self.realm and format('%q', sanitise(self.realm, 120)) or '')
                    end
                    return self:_fail(kind, msg)
                end
            end
        elseif self.statusLine == nil then
            -- Status line.  DEVIATION: the reference only checks that the char
            -- after the first space is '2'.
            --
            -- The 3-digit code must be ANCHORED at both ends.  With a single trailing `[ \t]*`
            -- the `(.*)` behind it absorbed the rest of the token, so "HTTP/1.1 2000 OK" parsed
            -- as 200 and opened a tunnel onto a dead pipe, and "HTTP/1.1 4070 Nope" was reported
            -- to the operator as 407 'auth-required'.  Either real whitespace follows the code,
            -- or the code ends the line.
            local ver, code, reason = line:match('^HTTP/(%d+%.?%d*)[ \t]+(%d%d%d)[ \t]+(.*)$')
            if not ver then
                ver, code = line:match('^HTTP/(%d+%.?%d*)[ \t]+(%d%d%d)[ \t]*$')
                reason = ''
            end
            if not ver then
                return self:_fail('malformed', format(
                    '%s: CONNECT to %s got a malformed status line %q',
                    self:_where(), self.target, sanitise(line, 120)))
            end
            self.statusLine  = line
            self.httpVersion = ver
            self.status      = tonumber(code)
            self.reason      = trim(reason)
        else
            self:_addHeader(line)
        end
    end

    return proxy.NEED_MORE
end

--- Drive the timeout from the caller's clock.  Same return shape as feed().
function HS:tick(nowMs)
    if self.state == 'done'   then return proxy.CONNECTED, self.leftover end
    if self.state == 'failed' then return proxy.ERROR, self.err, self.errorKind end
    if self.startMs == nil then self.startMs = nowMs end
    if self.timeoutMs and self.timeoutMs > 0 and nowMs and self.startMs
       and (nowMs - self.startMs) > self.timeoutMs then
        return self:_fail('timeout', format(
            '%s: CONNECT to %s timed out after %d ms (%d bytes of response, no complete header)',
            self:_where(), self.target, self.timeoutMs, self.bytesIn))
    end
    return proxy.NEED_MORE
end

--- The peer closed the connection while the handshake was still in progress.
function HS:eof()
    if self.state == 'done'   then return proxy.CONNECTED, self.leftover end
    if self.state == 'failed' then return proxy.ERROR, self.err, self.errorKind end
    return self:_fail('closed', format(
        '%s: closed the connection during the CONNECT to %s (%d bytes received)',
        self:_where(), self.target, self.bytesIn))
end

function HS:isDone()   return self.state == 'done'   end
function HS:isFailed() return self.state == 'failed' end

return proxy
