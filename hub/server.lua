--[[============================================================================
hub/server.lua -- the hub's HTTP + WebSocket front end.

  local server = require('hub.server').new{
      host = '127.0.0.1', port = 8777,
      panelDir = ROOT .. '/panel',
      api = api, auth = auth, tel = telemetry,
      allowInsecure = false,
  }
  local port, err = server:start()      ...      server:stop()

Routes
  POST /api/rpc      {id, cmd, args} -> {id, ok, result} | {id, ok:false, error}
  GET  /api/events   WebSocket, {event, data} frames
  GET  /api/health   liveness, no session needed, no data beyond ok/version
  everything else    static files from panelDir (index.html at '/')

--------------------------------------------------------------------------------
BINDING -- why a non-loopback bind is refused
--------------------------------------------------------------------------------
PANEL.md: "TLS is out of scope for the hub."  Everything this front end carries is
plaintext -- the session cookie, `exec` chunks, and the panel's own reply bodies.
Binding anything but a loopback address therefore publishes an unencrypted
administration console, so :start() REFUSES it unless the operator passed
--allow-insecure, and even then:
  * a warning is logged at start, once per process, naming the address;
  * `auth.session` reports `insecure = true` and the panel draws its banner;
  * the session cookie gains `Secure` whenever the bind is non-loopback, so a
    browser that later reaches the hub over https will not downgrade it.
The supported way to expose the panel is nginx/Caddy or an SSH tunnel in front.

--------------------------------------------------------------------------------
SESSION COOKIES
--------------------------------------------------------------------------------
  hub_sid   the 32-byte session token.  HttpOnly (script cannot read it, so an
            injected script cannot exfiltrate the session), SameSite=Strict (the
            browser attaches it to nothing a foreign page initiates), Path=/,
            Max-Age = the session TTL, Secure when the bind is not loopback.
  hub_csrf  the session's CSRF token.  Deliberately NOT HttpOnly: the panel reads
            it and echoes it in X-CSRF-Token.  Knowing it is useless without the
            session cookie, and same-origin policy keeps a foreign page from
            reading it.
Both are cleared with Max-Age=0 on logout.

--------------------------------------------------------------------------------
CSRF -- four independent checks on every state-changing RPC
--------------------------------------------------------------------------------
 1. CONTENT TYPE.  The body must be application/json.  A cross-site <form> can
    only send application/x-www-form-urlencoded, multipart/form-data or
    text/plain, and any other content type makes fetch/XHR preflight, which a
    foreign origin fails.  This alone blocks the classic form-POST attack.
 2. ORIGIN.  If the request carries Origin, its host (and port, when both state
    one) must equal the Host header's.  A browser always sends Origin on a
    cross-origin POST, so a mismatch is refused: 403 `csrf`.
 3. SEC-FETCH-SITE.  When present it must be `same-origin` or `none`.  Browsers
    that send it cannot be lied to by page script.
 4. TOKEN.  X-CSRF-Token, when present, must equal the session's CSRF token.
    With `csrfStrict = true` (--csrf-strict) the header becomes MANDATORY for
    every mutating command; the default leaves it optional so a panel build that
    predates the header still works, while 1-3 still hold.
Read-only commands (list/get/logs/...) skip 2-4 but still need a session.

The WebSocket has its own gate: lib/wsserver.lua's Origin check (same-origin by
default -- a WebSocket handshake is NOT subject to CORS and a browser attaches
cookies to it from any page, so this is the only thing standing between a random
page the operator visits and an authenticated `exec` stream), plus this file's
own session check, plus httpserver's allowedHosts to pin the Host header against
DNS rebinding.

Lua 5.1 / LuaJIT: no goto, math.floor for integer division.
============================================================================]]

local httpserver = require('lib.httpserver')
local wsserver   = require('lib.wsserver')
local json       = require('lib.json')
local sys        = require('lib.sys')
local sched      = require('lib.sched')

local M = {}

local floor = math.floor

M.SESSION_COOKIE = 'hub_sid'
M.CSRF_COOKIE    = 'hub_csrf'
M.CSRF_HEADER    = 'x-csrf-token'

--- Paths under --panel-dir that are never served: the development harness and
--- anything server-side that happens to live beside the panel.  Lua patterns,
--- matched against the lower-cased request path.
M.PANEL_DENY = {
  '%.lua$',                       -- devhub.lua, and any other server source
  '^/test/', '^/tests/', '^/mock/', '^/mocks/',
  '%.md$', '%.map$',
  '/%.',                          -- dotfiles and dot-directories
}

-- ================================================================== helpers ==
local function isLoopback(host)
  if not host then return true end
  host = tostring(host):lower()
  if host == 'localhost' or host == '::1' or host == '[::1]' then return true end
  if host == '127.0.0.1' then return true end
  return host:match('^127%.%d+%.%d+%.%d+$') ~= nil
end
M.isLoopback = isLoopback

--- The Host headers this hub answers to.
---
--- HOST PINNING IS NOT OPTIONAL.  It used to be applied only for a loopback
--- bind, so --bind + --allow-insecure -- precisely the configuration the warning
--- banner exists for -- left the Host header unconstrained, and checkCsrfHttp
--- then compared an attacker-supplied Origin against an attacker-supplied Host.
--- With a name the attacker controls resolving to this address, Sec-Fetch-Site
--- reads `same-origin` and all four CSRF checks pass: DNS rebinding, complete.
---
--- So a non-loopback bind gets an allow-list too: the bind address itself, plus
--- whatever names the operator declared with --allowed-host.  A name they never
--- declared is refused at the Host check, which is where rebinding dies.
function M.allowedHostsFor(host, extra)
  if isLoopback(host) then return { '127.0.0.1', 'localhost', '[::1]' } end
  local hosts = { tostring(host):lower() }
  local seen = { [hosts[1]] = true }
  for _, hname in ipairs(extra or {}) do
    local h = tostring(hname):lower()
    if h ~= '' and not seen[h] then seen[h] = true; hosts[#hosts + 1] = h end
  end
  return hosts
end

--- Split a Cookie header into a name -> value map.  Values are taken verbatim
--- (our tokens are hex), and a repeated name keeps the FIRST occurrence, which is
--- what a browser sends for the most specific path.
local function parseCookies(header)
  local out = {}
  if not header then return out end
  for piece in tostring(header):gmatch('[^;]+') do
    local k, v = piece:match('^%s*([^=%s]+)%s*=%s*(.-)%s*$')
    if k and out[k] == nil then
      if v:sub(1, 1) == '"' and v:sub(-1) == '"' then v = v:sub(2, -2) end
      out[k] = v
    end
  end
  return out
end
M.parseCookies = parseCookies

local function hostOf(authority)
  if not authority then return nil, nil end
  authority = tostring(authority)
  local h, p = authority:match('^%[([^%]]+)%]:?(%d*)$')
  if h then return h:lower(), (p ~= '' and tonumber(p) or nil) end
  h, p = authority:match('^([^:]+):(%d+)$')
  if h then return h:lower(), tonumber(p) end
  return authority:lower(), nil
end

local DEFAULT_PORT = { http = 80, https = 443, ws = 80, wss = 443 }

--- Same-origin comparison between an Origin header and a Host header.
---
--- The PORT is always part of the comparison.  Skipping it when either side
--- omitted one made `http://localhost` (port 80) and `https://localhost`
--- (port 443) both same-origin with `Host: localhost:8877` -- and because
--- cookies are not port-scoped, any other service on 80 or 443 (or an XSS in
--- one) could then read hub_csrf, get SameSite=Strict cookies attached and pass
--- every CSRF check.  So a missing Origin port is resolved from its scheme and a
--- missing Host port from the listener (`listenPort`), and the two must match.
local function sameOrigin(origin, host, listenPort)
  if not origin or origin == '' or origin == 'null' then return false end
  local scheme = origin:match('^(%a[%w+%-.]*)://')
  local auth = origin:match('^%a[%w+%-.]*://(.*)$') or origin
  local oh, op = hostOf(auth)
  local hh, hp = hostOf(host)
  if not oh or not hh then return false end
  if oh ~= hh then return false end
  local sdef = scheme and DEFAULT_PORT[scheme:lower()] or nil
  op = op or sdef
  hp = hp or listenPort or sdef
  -- Only when NEITHER side can be resolved to a number is the port dropped: that
  -- means a schemeless Origin against a portless Host, which carries no port
  -- information at all and cannot be made stricter.
  if op == nil and hp == nil then return true end
  return op == hp
end
M.sameOrigin = sameOrigin

-- --------------------------------------------------------------- trusted proxy
--[[
The hub does NOT trust X-Forwarded-For by default, and that is right: anyone who
can reach the port can put any address in that header, and a rate limiter keyed
by a forged address limits nothing.  But PANEL.md's supported deployment puts
nginx/Caddy in front, and then every request genuinely arrives from one address
and the limiter sees one bucket for the whole internet.

--trusted-proxy=CIDR names the front end.  The header is read ONLY when the real
peer is inside one of those ranges, and only its LAST hop is taken -- the entries
before it were written by the client and are worthless.  IPv4 only, deliberately:
a half-understood IPv6 matcher here would be worse than none.
]]
local function ipv4ToInt(ip)
  local a, b, c, d = tostring(ip or ''):match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
  if not a then return nil end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
  return ((a * 256 + b) * 256 + c) * 256 + d
end
M.ipv4ToInt = ipv4ToInt

--- Does `ip` fall inside `cidr` ("10.0.0.0/8", or a bare address = /32)?
local function inCidr(ip, cidr)
  local n = ipv4ToInt(ip)
  if not n then return false end
  local base, bits = tostring(cidr or ''):match('^([%d%.]+)/(%d+)$')
  if not base then base, bits = tostring(cidr or ''), '32' end
  local b = ipv4ToInt(base)
  bits = tonumber(bits)
  if not b or not bits or bits < 0 or bits > 32 then return false end
  if bits == 0 then return true end
  -- floor division rather than a bit mask: LuaJIT's bit ops are signed 32-bit
  -- and an address above 127.255.255.255 would come back negative.
  local size = 2 ^ (32 - bits)
  return floor(n / size) == floor(b / size)
end
M.inCidr = inCidr

--- The address to attribute this request to.
local function clientIp(self, req)
  local peer = req and req.remoteIp or nil
  local list = self.trustedProxies
  if not peer or not list or #list == 0 then return peer end
  local trusted = false
  for i = 1, #list do
    if inCidr(peer, list[i]) then trusted = true; break end
  end
  if not trusted then return peer end
  local xff = req:header('x-forwarded-for')
  if not xff or xff == '' then return peer end
  local last
  for piece in tostring(xff):gmatch('[^,]+') do
    local v = piece:match('^%s*(.-)%s*$')
    if v ~= '' then last = v end
  end
  -- Only an address we can actually parse; anything else falls back to the peer.
  if last and ipv4ToInt(last) then return last end
  return peer
end
M.clientIp = clientIp

local function cookieAttrs(self, maxAge)
  local a = '; Path=/; SameSite=Strict'
  if maxAge ~= nil then a = a .. '; Max-Age=' .. tostring(floor(maxAge)) end
  if self.secureCookies then a = a .. '; Secure' end
  return a
end

-- =================================================================== object ==
local S = {}
S.__index = S
M.S = S

function M.new(opts)
  opts = opts or {}
  local s = setmetatable({}, S)
  s.host = opts.host or '127.0.0.1'
  s.port = tonumber(opts.port) or 8777
  s.panelDir = opts.panelDir
  s.api   = assert(opts.api, 'hub.server: api is required')
  s.auth  = assert(opts.auth, 'hub.server: auth is required')
  s.tel   = opts.tel
  s.log   = opts.log or require('lib.log')
  s.sched = opts.sched or sched
  s.allowInsecure = opts.allowInsecure and true or false
  s.csrfStrict    = opts.csrfStrict and true or false
  s.sessionTtlMs  = opts.sessionTtlMs or (7 * 24 * 3600 * 1000)
  s.allowedOrigins = opts.allowedOrigins            -- nil = same-origin only
  -- Extra names a non-loopback bind will answer to (--allowed-host=NAME).  The
  -- bind address itself is always allowed; anything else has to be declared, so
  -- a DNS-rebinding name the operator never named is refused at the Host check.
  s.allowedHosts   = opts.allowedHosts or {}
  -- CIDRs of front ends whose X-Forwarded-For may be believed (see clientIp).
  s.trustedProxies = opts.trustedProxies or {}
  s.allowNoOrigin  = opts.allowNoOrigin and true or false
  s.maxBodyBytes   = opts.maxBodyBytes or (2 * 1024 * 1024)
  s.maxSockets     = tonumber(opts.maxSockets) or 64      -- concurrent /ws sockets
  s.maxSocketsPerUser = tonumber(opts.maxSocketsPerUser) or 8
  s.maxOutbox      = tonumber(opts.maxOutbox) or (512 * 1024)
  -- Waiters allowed in front of a password derivation.  8 x LOGIN_COST_HINT_MS
  -- is about 2.4 s of queued work, which is a reasonable worst-case wait and a
  -- hard bound on how long a burst of logins can hold the reactor.
  s.maxLoginQueue  = tonumber(opts.maxLoginQueue) or 8
  s.pwQueue        = {}
  s.pwBusy         = false
  s.version = opts.version or 'hub-1.0'
  s.insecure = not isLoopback(s.host)
  s.secureCookies = s.insecure
  -- On a published, unencrypted bind the optional CSRF token stops being
  -- optional.  Checks 1-3 all read headers the attacker influences (content
  -- type, Origin, Sec-Fetch-Site); the token is the only one that requires
  -- having READ a same-origin response, which is exactly what a rebound or
  -- cross-origin page cannot do.
  if s.insecure then s.csrfStrict = true end
  s.sockets = {}
  s.started = false
  return s
end

-- ---------------------------------------------------------------- ctx builder
function S:contextFor(req, res)
  local cookies = parseCookies(req and req:header('cookie'))
  local token = cookies[M.SESSION_COOKIE]
  local session, user
  if token and #token > 0 then
    -- authenticate() slides the expiry, re-reads the user row (so a disabled or
    -- deleted account loses its session on the very next request) and returns the
    -- LIVE session table -- which is where the CSRF token lives.
    --
    -- ON FAILURE it returns `nil, <reason string>, <code>`, so the second value is
    -- a STRING, not a user.  Taking it as one would make any cookie value look
    -- signed-in (indexing a string yields nil for every field, so the request
    -- would arrive with a nameless, roleless "user" that still passes the
    -- authentication gate).  Both halves must be tables or there is no session.
    local sess, u = self.auth:authenticate(token, req and clientIp(self, req) or nil)
    if type(sess) == 'table' and type(u) == 'table' then session, user = sess, u end
  end
  local self_ = self
  local ctx = {
    session = session, user = user,
    ip = req and (clientIp(self, req) or '') or '',
    userAgent = req and (req:header('user-agent') or '') or '',
    insecure = self.insecure,
    csrfToken = session and session.csrf or nil,
    cookies = cookies,
    setCookies = nil,
  }
  --- Called by hub/api.lua's login / bootstrap handlers with the RAW token (the
  --- only time the hub ever holds one: auth.lua keeps just its SHA-256) and the
  --- live session table.
  ctx.setSession = function(rawToken, newSession)
    ctx.session = newSession
    ctx.csrfToken = newSession and newSession.csrf or nil
    ctx.setCookies = {
      M.SESSION_COOKIE .. '=' .. tostring(rawToken) ..
        cookieAttrs(self_, floor(self_.sessionTtlMs / 1000)) .. '; HttpOnly',
      M.CSRF_COOKIE .. '=' .. tostring(newSession and newSession.csrf or '') ..
        cookieAttrs(self_, floor(self_.sessionTtlMs / 1000)),
    }
  end
  ctx.clearSession = function()
    ctx.setCookies = {
      M.SESSION_COOKIE .. '=' .. cookieAttrs(self_, 0) .. '; HttpOnly',
      M.CSRF_COOKIE .. '=' .. cookieAttrs(self_, 0),
    }
  end
  return ctx
end

-- ------------------------------------------------------------------- the CSRF
--- Returns true, or nil plus {status, code, message}.
function S:checkCsrf(req, ctx, cmd)
  local api = require('hub.api')
  if not api.isMutating(cmd) then return true end
  return self:checkCsrfHttp(req, ctx)
end

--- The four checks themselves, for a request already known to be state-changing.
function S:checkCsrfHttp(req, ctx)
  local ct = (req:header('content-type') or ''):lower()
  if not ct:match('^application/json') then
    return nil, { status = 415, code = 'csrf-invalid',
                  message = 'state-changing requests must be application/json' }
  end
  local origin = req:header('origin')
  if origin and origin ~= '' then
    if not sameOrigin(origin, req:header('host'), self.port) then
      return nil, { status = 403, code = 'csrf-invalid', message = 'cross-origin request refused' }
    end
  end
  local sfs = req:header('sec-fetch-site')
  if sfs and sfs ~= '' then
    sfs = sfs:lower()
    if sfs ~= 'same-origin' and sfs ~= 'none' then
      return nil, { status = 403, code = 'csrf-invalid', message = 'cross-site request refused' }
    end
  end
  local sent = req:header(M.CSRF_HEADER)
  local want = ctx.session and ctx.session.csrf or nil
  if sent and sent ~= '' then
    if not want or sent ~= want then
      return nil, { status = 403, code = 'csrf-invalid', message = 'bad CSRF token' }
    end
  elseif self.csrfStrict and want then
    return nil, { status = 403, code = 'csrf-invalid', message = 'missing X-CSRF-Token' }
  end
  return true
end

-- ------------------------------------------------- the password-work queue --
--[[
One PBKDF2 verification is ~270 ms of UNINTERRUPTIBLE work on this single
reactor (hub/auth.lua's own header says so and exports LOGIN_COST_HINT_MS for
sizing).  Dispatching logins inline meant N concurrent attempts blocked the
reactor for N x 270 ms: 30 valid logins from one account holder stalled an
/api/health request for over seven seconds, and every bot tick and telemetry
push with it.  Successful logins were not limited at all, so any account holder
could do it deliberately and forever.

So the password-bearing commands run ONE AT A TIME, each on its own reactor
turn, and the queue has a hard depth: past it the answer is an immediate 429
rather than a longer wait.  Serialising does not make the work cheaper -- it
bounds it, and it gives every other socket a turn between derivations.
]]
local SERIALISED = { ['auth.login'] = true, ['auth.bootstrap'] = true,
                     ['auth.changePassword'] = true }
M.SERIALISED = SERIALISED

--- Queue `fn` (which must call `done` exactly once).  Returns false when the
--- backlog is full, and the caller answers 429.
function S:runSerialised(fn)
  self.pwQueue = self.pwQueue or {}
  if #self.pwQueue >= self.maxLoginQueue then
    self.stat_loginRejected = (self.stat_loginRejected or 0) + 1
    return false
  end
  self.pwQueue[#self.pwQueue + 1] = fn
  self:_drainSerialised()
  return true
end

function S:_drainSerialised()
  if self.pwBusy then return end
  local q = self.pwQueue
  if not q or #q == 0 then return end
  local fn = table.remove(q, 1)
  self.pwBusy = true
  local self_ = self
  local finished = false
  local function done()
    if finished then return end
    finished = true
    self_.pwBusy = false
    -- next one on a LATER turn, so the reactor services other sockets between
    -- two derivations instead of running the whole backlog in one go
    self_.sched.post(function() self_:_drainSerialised() end)
  end
  -- The work itself also starts on its own turn: the request that queued it has
  -- already been parsed, and the caller's socket write should not wait behind it.
  self.sched.post(function()
    local ok, e = pcall(fn, done)
    if not ok then
      self_.log.error('hub: serialised command crashed: %s', tostring(e))
      done()
    end
  end)
end

function S:loginQueueDepth() return self.pwQueue and #self.pwQueue or 0 end

-- ------------------------------------------------------------------ RPC route
function S:handleRpc(req, res)
  if req.method ~= 'POST' then
    return res:send(405, 'method not allowed\n', { ['Allow'] = 'POST' })
  end
  local body, derr = req:json()
  if type(body) ~= 'table' then
    return res:json(400, { ok = false,
      error = { code = 'bad-request', message = 'malformed JSON body: ' .. tostring(derr) } })
  end
  local id  = body.id
  local cmd = tostring(body.cmd or '')
  local args = type(body.args) == 'table' and body.args or {}
  local ctx = self:contextFor(req, res)

  local okCsrf, why = self:checkCsrf(req, ctx, cmd)
  if not okCsrf then
    self.log.warn('hub: CSRF refusal from %s for %s (%s)', tostring(ctx.ip), cmd, why.message)
    if self.api.record then
      pcall(function() self.api:record(ctx, cmd, '', 'denied', 'csrf: ' .. why.message) end)
    end
    return res:json(why.status, { id = id, ok = false,
                                  error = { code = why.code, message = why.message } })
  end

  local self_ = self
  local function reply(ok, payload)
    local headers = nil
    if ctx.setCookies then headers = { ['Set-Cookie'] = ctx.setCookies } end
    if ok then
      -- a fresh session must reach the socket layer too
      return res:json(200, { id = id, ok = true, result = payload or {} }, headers)
    end
    local code = (type(payload) == 'table' and payload.code) or 'internal'
    local status = 400
    if code == 'unauthorized' then status = 401
    elseif code == 'forbidden' then status = 403
    elseif code == 'not-found' then status = 404
    elseif code == 'conflict' then status = 409
    elseif code == 'internal' then status = 500
    elseif code == 'unknown-command' then status = 404
    end
    return res:json(status, { id = id, ok = false, error = {
      code = code, message = (type(payload) == 'table' and payload.message) or 'request failed' } },
      headers)
  end
  if SERIALISED[cmd] then
    local queued = self:runSerialised(function(done)
      self_.api:dispatch(cmd, args, ctx, function(ok, payload)
        done()
        return reply(ok, payload)
      end)
    end)
    if not queued then
      return res:json(429, { id = id, ok = false, error = { code = 'rate-limited',
        message = 'too many sign-ins in flight -- try again in a moment' } })
    end
    return
  end
  self.api:dispatch(cmd, args, ctx, reply)
end

-- ----------------------------------------------------------------- REST route
--- The panel's own surface: one path per resource, the verb carries the intent.
--- hub/api.lua owns the route table (M.ROUTES) so the contract lives beside the
--- handlers it maps onto; this function is only the HTTP half of it -- body, CSRF,
--- cookies, status codes.
---
--- CSRF: a REST write is any verb but GET/HEAD, which is a stronger and simpler
--- rule than asking the command layer whether the handler mutates, and it means a
--- GET can never be made to change something by mislabelling it.
function S:handleRest(req, res)
  local api = require('hub.api')
  local method = tostring(req.method or 'GET'):upper()
  local mutating = not (method == 'GET' or method == 'HEAD')

  local body = nil
  if mutating then
    local raw = req.body
    if raw ~= nil and raw ~= '' then
      local ok, decoded = pcall(json.decode, raw)
      if not ok or type(decoded) ~= 'table' then
        return res:json(400, { error = { code = 'bad-request',
                                         message = 'malformed JSON body' } })
      end
      body = decoded
    else
      body = {}
    end
  end

  local ctx = self:contextFor(req, res)

  -- CSRF first: a refusal must not reach a handler, and must be audited.
  if mutating then
    local okCsrf, why = self:checkCsrfHttp(req, ctx)
    if not okCsrf then
      self.log.warn('hub: CSRF refusal from %s for %s %s (%s)',
                    tostring(ctx.ip), method, tostring(req.path), why.message)
      if self.api.record then
        pcall(function()
          self.api:record(ctx, method .. ' ' .. tostring(req.path), '', 'denied',
                          'csrf: ' .. why.message)
        end)
      end
      return res:json(why.status, { error = { code = why.code, message = why.message } })
    end
  end

  local okR, cmd, args, status405, allowed =
    pcall(api.resolveRest, method, req.path, req.query, body)
  if not okR then
    local e = cmd
    local code = (type(e) == 'table' and e.code) or 'bad-request'
    local msg  = (type(e) == 'table' and e.message) or tostring(e)
    return res:json(api.statusFor(code), { error = { code = code, message = msg } })
  end
  if not cmd then
    if status405 then
      return res:json(405, { error = { code = 'bad-request',
                                       message = 'method not allowed here' } },
                      { ['Allow'] = allowed })
    end
    return res:json(404, { error = { code = 'not-found', message = 'no such endpoint' } })
  end

  local self_ = self
  local function reply(ok, payload)
    local headers = nil
    if ctx.setCookies then headers = { ['Set-Cookie'] = ctx.setCookies } end
    if ok then return res:json(200, payload or {}, headers) end
    local code = (type(payload) == 'table' and payload.code) or 'internal'
    local msg  = (type(payload) == 'table' and payload.message) or 'request failed'
    return res:json(api.statusFor(code), { error = { code = code, message = msg } }, headers)
  end
  if SERIALISED[cmd] then
    local queued = self:runSerialised(function(done)
      self_.api:dispatch(cmd, args, ctx, function(ok, payload)
        done()
        return reply(ok, payload)
      end)
    end)
    if not queued then
      return res:json(429, { error = { code = 'rate-limited',
        message = 'too many sign-ins in flight -- try again in a moment' } })
    end
    return
  end
  self.api:dispatch(cmd, args, ctx, reply)
end

-- ------------------------------------------------------------- WebSocket route
--- opts.panelProtocol -> the /ws dialect panel/rpc.js speaks:
---   client   {type:'auth', csrf}  {type:'subscribe', logs, chat}  {type:'ping', t}
---   hub      {event:'ready'}      {event:'pong'}   {event:<name>, data}
--- and close 4401 when the auth frame does not carry this session's CSRF token.
--- /api/events keeps the older cookie-only dialect, which the hub's own tests and
--- any non-browser client use.
function S:wsOptions(panelProtocol)
  local self_ = self
  return {
    allowedOrigins = self.allowedOrigins,
    allowNoOrigin  = self.allowNoOrigin,
    -- the listener's port, so wsserver can resolve a portless Host header
    defaultPort    = self.port,
    -- An upgraded socket stops counting against httpserver's maxConnections
    -- (lib/httpserver.lua hands it over), so without a cap here /ws was
    -- effectively unlimited: one signed-in session could hold as many sockets as
    -- the process has descriptors, each with its own outbox allowance.
    maxConnections = self.maxSockets,
    maxMessage     = 256 * 1024,
    -- 4 MiB per socket x hundreds of sockets is gigabytes of buffered frames.
    -- hub/telemetry.lua already drops and reports for a slow reader, so a much
    -- smaller allowance costs nothing and bounds the worst case.
    maxOutbox      = self.maxOutbox,
    onMessage = function(ws, msg, isBinary)
      -- The socket is an EVENT channel only.  Commands go through POST /api/rpc,
      -- which is where the CSRF checks live; accepting them here would route
      -- around them.  A ping keeps the panel's own liveness check honest.
      if isBinary then return end
      local ok, frame = pcall(json.decode, msg)
      if not ok or type(frame) ~= 'table' then return end
      if not panelProtocol then
        if frame.cmd == 'ping' and self_.tel then
          self_.tel:sendTo(ws, 'pong', { t = os.time() * 1000 })
        end
        return
      end
      local ft = frame.type
      if ft == 'auth' then
        if ws.authed then return end
        -- The cookie already authenticated the handshake; the CSRF token proves
        -- the page that opened it is OUR page and not one the operator visited.
        local want = ws.csrfWant
        if want and want ~= '' and tostring(frame.csrf or '') ~= want then
          self_.log.warn('hub: /ws auth frame carried the wrong CSRF token (%s)',
                         tostring(ws.user and ws.user.userName or '?'))
          return ws:close(4401, 'authentication failed')
        end
        ws.authed = true
        if self_.tel then
          self_.tel:addSocket(ws)
          self_.tel:sendTo(ws, 'ready', {
            version = self_.version, t = os.time() * 1000,
            user = ws.user and ws.user.userName or nil,
            role = ws.user and ws.user.role or nil,
            insecure = self_.insecure })
        end
        return
      end
      if not ws.authed then return end        -- nothing counts before the auth frame
      if ft == 'subscribe' then
        if self_.tel then self_.tel:setSubs(ws, frame.logs, frame.chat) end
        return
      end
      if ft == 'ping' then
        if self_.tel then
          self_.tel:sendTo(ws, 'pong', { t = frame.t or (os.time() * 1000) })
        end
        return
      end
    end,
    onClose = function(ws)
      self_.sockets[ws] = nil
      if self_.tel then self_.tel:removeSocket(ws) end
    end,
  }
end

function S:handleEvents(req, res, panelProtocol)
  local ctx = self:contextFor(req, res)
  if not ctx.user then
    return res:json(401, { ok = false, error = { code = 'unauthorized', message = 'not signed in' } })
  end
  local accept, rej = wsserver.checkRequest(req, self:wsOptions(panelProtocol))
  if not accept then
    rej = rej or { status = 400, message = 'bad websocket request' }
    return res:send(rej.status, tostring(rej.message) .. '\n', rej.headers)
  end
  local sock, pending = res:upgrade()
  if not sock then return nil, pending end
  local opts = self:wsOptions(panelProtocol)
  opts.pending = pending
  -- The user table has to be complete BEFORE upgrade(): wsserver fires onOpen and
  -- feeds `pending` inside that call, and telemetry's visibility predicate is read
  -- from ws.user the moment the socket is registered.
  opts.user = {
    userId    = ctx.user.id,
    userName  = ctx.user.name,
    role      = ctx.user.role,
    sessionId = ctx.session and ctx.session.id or nil,
    visible   = self.api:visibilityFor(ctx.user),
  }
  local ws, err = wsserver.upgrade(sock, req, opts)
  if not ws then
    self.log.warn('hub: websocket upgrade failed: %s', tostring(err))
    return nil, err
  end
  ws.req = req
  ws.csrfWant = ctx.session and ctx.session.csrf or nil
  if panelProtocol then
    -- Registration waits for the auth frame: an unauthenticated socket must not
    -- receive one event, and a socket that never sends the frame is simply idle.
    ws.authed = false
  elseif self.tel then
    self.tel:addSocket(ws)
    self.tel:sendTo(ws, 'hello', { version = self.version, t = os.time() * 1000,
                                   user = ctx.user.name, role = ctx.user.role,
                                   insecure = self.insecure })
  end
  self.sockets[ws] = true
  return ws
end

-- ==================================================================== start ==
function S:start()
  if self.started then return nil, 'already started' end
  if not isLoopback(self.host) and not self.allowInsecure then
    return nil, string.format(
      'refusing to bind %s: the hub speaks plain HTTP and has no TLS (PANEL.md). ' ..
      'Put nginx/Caddy or an SSH tunnel in front, or pass --allow-insecure to ' ..
      'publish an unencrypted admin console deliberately.', tostring(self.host))
  end
  if self.insecure then
    self.log.warn('==================================================================')
    self.log.warn('hub: binding %s -- PLAINTEXT HTTP on a non-loopback address.', self.host)
    self.log.warn('hub: session cookies and every `exec` chunk cross the network in')
    self.log.warn('hub: the clear.  The panel will show a warning banner.')
    self.log.warn('==================================================================')
  end
  self.api.insecure = self.insecure
  if self.insecure then
    self.log.warn('hub: --allow-insecure implies --csrf-strict; X-CSRF-Token is mandatory')
  end

  local staticServe = nil
  if self.panelDir then
    -- The panel directory also holds the development harness (devhub.lua, the
    -- mock backend, panel/test/), which is not part of the shipped surface and
    -- was reachable WITHOUT a session -- a free map of the application, and a
    -- second implementation of it to look for mistakes in.  Serve only what the
    -- browser needs.
    staticServe = httpserver.static{ root = self.panelDir, index = 'index.html',
                                     cacheControl = 'no-cache',
                                     deny = M.PANEL_DENY }
  end

  local self_ = self
  local hosts = M.allowedHostsFor(self.host, self.allowedHosts)

  self.http = httpserver.new{
    host = self.host, port = self.port, sched = self.sched, log = self.log,
    allowedHosts = hosts,
    maxBodyBytes = self.maxBodyBytes,
    onRequest = function(req, res)
      local path = req.path or '/'
      if path == '/api/rpc' then return self_:handleRpc(req, res) end
      if path == '/api/events' then return self_:handleEvents(req, res, false) end
      if path == '/ws' then return self_:handleEvents(req, res, true) end
      if path == '/api/health' then
        return res:json(200, { ok = true, version = self_.version,
                               insecure = self_.insecure,
                               bootstrap = self_.auth:needsBootstrap() and true or false })
      end
      if path:sub(1, 5) == '/api/' then return self_:handleRest(req, res) end
      if staticServe then return staticServe(req, res) end
      return res:send(404, 'not found\n')
    end,
  }
  local port, err = self.http:start()
  if not port then return nil, err end
  self.port = port
  self.started = true
  self.log.info('hub: listening on http://%s:%d/  (panel %s)',
                self.host, port, self.panelDir and 'served' or 'not served')
  return port
end

function S:stop()
  if not self.started then return end
  self.started = false
  for ws in pairs(self.sockets) do pcall(function() ws:close(1001, 'hub shutting down') end) end
  self.sockets = {}
  pcall(function() wsserver.shutdown(1001, 'hub shutting down') end)
  if self.http then pcall(function() self.http:stop() end) end
end

function S:stats()
  local n = 0
  for _ in pairs(self.sockets) do n = n + 1 end
  return { http = self.http and self.http:stats() or nil, sockets = n,
           insecure = self.insecure, port = self.port }
end

return M
