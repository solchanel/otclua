-- lib/httpserver.lua -- a non-blocking HTTP/1.1 server for the hub / web panel.
--
-- Runs entirely on lib/sched.lua's single-threaded reactor: nothing in this file
-- ever blocks.  Reads are incremental (a request split byte-by-byte parses exactly
-- like one delivered in a single segment), writes go through lib/socket.lua's
-- outbox and are drained on writability, and a large file is streamed in chunks
-- that are only queued while the connection's backlog is below the high-water mark.
--
--   local httpserver = require('lib.httpserver')
--   local s = httpserver.new{
--       host = '127.0.0.1', port = 0,          -- 0 = ephemeral, :start() returns it
--       sched = require('lib.sched'),          -- default: lib.sched
--       onRequest = function(req, res) ... end,
--       maxHeaderBytes = 32768,                -- request line + header block
--       maxBodyBytes   = 4 * 1024 * 1024,
--       idleTimeoutMs  = 30000,                -- silence, sliding
--       headerTimeoutMs = 10000,               -- ABSOLUTE: first byte of a head -> last
--       requestTimeoutMs = 30000,              -- ABSOLUTE: head parsed -> response started
--       maxRequests    = 100,                  -- keep-alive requests per connection
--       maxWriteBacklog = 4 * 1024 * 1024,     -- per connection, then the peer is dropped
--       allowedHosts   = { '127.0.0.1', 'localhost' },  -- nil = any (see below)
--       allowBareLF    = false,                -- true = tolerate LF-only framing
--   }
--   local port, err = s:start()   ...   s:stop()   ...   s:stats()
--
-- Request  : .method .path .rawPath .target .rawQuery .query .headers .body
--            .remoteIp .remotePort .version .keepAlive .id
--            :header(name) -> value            (case-insensitive)
--            :json()       -> table | nil, err (decoded body)
-- Response : :send(status, body, headers)  :json(status, tbl)  :text(status, s, hdrs)
--            :file(path, contentType, opts) :redirect(location, status)
--            :status(code) -> self           :header(name [, value])
--            :upgrade() -> sock, pending     (protocol hand-over, see below)
--            Sending twice never raises: it is logged and returns nil, err.
--
-- Protocol upgrade (WebSocket):
--   local sock, pending = res:upgrade()
--   -- the socket is now OURS to hand on: the HTTP server has forgotten it, so it is
--   -- no longer swept, counted in stats() or charged against maxConnections, and
--   -- NOTHING here will ever write to it again (that used to inject a 408 into the
--   -- middle of an established WebSocket stream).  `pending` is whatever the peer
--   -- already sent past the header block; give it to the new owner.
--   wsserver.upgrade(sock, req, { pending = pending, ... })
-- httpserver.websocketRoute(wsserver, opts) wires that up (and answers a refused
-- handshake -- a foreign Origin, say -- on the HTTP layer, before detaching).
--
-- Static files:
--   local serve = httpserver.static{ root = ROOT .. '/panel', index = 'index.html' }
--   -- serve(req, res) -> true when it answered (it always answers: 200/304/404/405)
-- Content types cover html/js/css/svg/png/woff2 and friends; ETag + If-None-Match
-- revalidation is built in; there is no directory listing (a directory is a 404).
--
-- Safety rules enforced here:
--   * the header cap is checked against the bytes buffered so far, so a 1 MB blob
--     arriving in ONE segment is rejected (431) without ever being parsed;
--   * Content-Length > maxBodyBytes is rejected (413) before a single body byte is
--     buffered, and a chunked body is measured as it is decoded;
--   * an unsupported Transfer-Encoding is 501, a bad chunk framing 400;
--   * percent-decoding refuses malformed escapes and %00;
--   * httpserver.safePath() refuses '..', backslashes, encoded slashes, ':' and NUL,
--     so a URL cannot address anything outside the document root;
--   * header values written back have CR/LF stripped (no response splitting);
--   * message framing is CRLF only.  A bare LF is NOT a line terminator anywhere
--     (head, header lines, chunk size, chunk terminator, trailers): a front end that
--     requires CRLF and a hub that accepts LF disagree about where a message ends,
--     which is request smuggling (RFC 9112 2.2).  opts.allowBareLF re-enables it;
--   * a chunk-size line must be `<hex>` optionally followed by `;ext` -- a prefix
--     match let "0x5" mean "last chunk" and smuggle the rest as a new request;
--   * a repeated Content-Length / Transfer-Encoding / Host is 400, not a merge;
--   * the response's Content-Length is written by the server and cannot be
--     overridden by a handler, and a single-valued response header set twice is
--     emitted once (last writer wins) -- both are response-desync primitives;
--   * every request carries an ABSOLUTE deadline as well as the sliding idle timer,
--     so a slow-loris drip cannot hold a connection (and its memory) forever.
--
-- Lua 5.1 / LuaJIT dialect: no goto, no integer division.

local socket = require('lib.socket')
local json   = require('lib.json')

local M = {}

M.VERSION      = '1.0'
M.SERVER_NAME  = 'luaclient-hub/1.0'

-- =========================================================== status texts ====
local STATUS = {
  [100] = 'Continue',
  [200] = 'OK', [201] = 'Created', [202] = 'Accepted', [204] = 'No Content',
  [206] = 'Partial Content',
  [301] = 'Moved Permanently', [302] = 'Found', [303] = 'See Other',
  [304] = 'Not Modified', [307] = 'Temporary Redirect', [308] = 'Permanent Redirect',
  [400] = 'Bad Request', [401] = 'Unauthorized', [403] = 'Forbidden',
  [404] = 'Not Found', [405] = 'Method Not Allowed', [408] = 'Request Timeout',
  [409] = 'Conflict', [411] = 'Length Required', [412] = 'Precondition Failed',
  [413] = 'Payload Too Large', [414] = 'URI Too Long',
  [415] = 'Unsupported Media Type', [426] = 'Upgrade Required',
  [429] = 'Too Many Requests', [431] = 'Request Header Fields Too Large',
  [500] = 'Internal Server Error', [501] = 'Not Implemented',
  [502] = 'Bad Gateway', [503] = 'Service Unavailable', [505] = 'HTTP Version Not Supported',
}
M.STATUS = STATUS

-- ================================================================== mime =====
local MIME = {
  html = 'text/html; charset=utf-8',   htm  = 'text/html; charset=utf-8',
  js   = 'text/javascript; charset=utf-8', mjs = 'text/javascript; charset=utf-8',
  css  = 'text/css; charset=utf-8',
  json = 'application/json; charset=utf-8',
  txt  = 'text/plain; charset=utf-8',  md   = 'text/plain; charset=utf-8',
  csv  = 'text/csv; charset=utf-8',
  xml  = 'application/xml; charset=utf-8',
  svg  = 'image/svg+xml',              ico  = 'image/x-icon',
  png  = 'image/png',                  gif  = 'image/gif',
  jpg  = 'image/jpeg',                 jpeg = 'image/jpeg',
  webp = 'image/webp',                 avif = 'image/avif',
  bmp  = 'image/bmp',
  woff2 = 'font/woff2',                woff = 'font/woff',
  ttf  = 'font/ttf',                   otf  = 'font/otf',
  wasm = 'application/wasm',
  map  = 'application/json; charset=utf-8',
  lua  = 'text/plain; charset=utf-8',
  pdf  = 'application/pdf',            zip  = 'application/zip',
}
M.MIME = MIME
M.DEFAULT_MIME = 'application/octet-stream'

function M.mimeType(path)
  local ext = tostring(path):match('%.([%w]+)$')
  if not ext then return M.DEFAULT_MIME end
  return MIME[ext:lower()] or M.DEFAULT_MIME
end

-- ================================================================= dates =====
local dateCacheSec, dateCacheStr = nil, nil
local function httpDate()
  local t = os.time()
  if t ~= dateCacheSec then
    dateCacheSec = t
    dateCacheStr = os.date('!%a, %d %b %Y %H:%M:%S GMT', t)
  end
  return dateCacheStr
end
M.httpDate = httpDate

-- ====================================================== percent-decoding =====
--- Strict percent-decoding.  '%' must be followed by two hex digits; %00 and a raw
--- NUL are refused.  plusIsSpace turns '+' into ' ' (query strings only).
function M.percentDecode(s, plusIsSpace)
  if type(s) ~= 'string' then return nil, 'not a string' end
  if s:find('\0', 1, true) then return nil, 'NUL byte in input' end
  if not s:find('%', 1, true) then
    if plusIsSpace then return (s:gsub('%+', ' ')) end
    return s
  end
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == '%' then
      local h = s:sub(i + 1, i + 2)
      if #h < 2 or not h:match('^%x%x$') then
        return nil, 'malformed percent-escape at byte ' .. i
      end
      local b = tonumber(h, 16)
      if b == 0 then return nil, 'NUL percent-escape at byte ' .. i end
      out[#out + 1] = string.char(b)
      i = i + 3
    elseif c == '+' and plusIsSpace then
      out[#out + 1] = ' '
      i = i + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

--- Parse a query string.  Repeated keys collect into an array (in wire order).
--- Returns a table, or nil, err when an escape is malformed.
function M.parseQuery(qs)
  local q = {}
  if not qs or qs == '' then return q end
  for pair in tostring(qs):gmatch('[^&]+') do
    local k, v = pair:match('^([^=]*)=(.*)$')
    if not k then k, v = pair, '' end
    if k ~= '' then
      local dk, e1 = M.percentDecode(k, true)
      if not dk then return nil, 'bad query key: ' .. tostring(e1) end
      local dv, e2 = M.percentDecode(v, true)
      if not dv then return nil, 'bad query value: ' .. tostring(e2) end
      local cur = q[dk]
      if cur == nil then
        q[dk] = dv
      elseif type(cur) == 'table' then
        cur[#cur + 1] = dv
      else
        q[dk] = { cur, dv }
      end
    end
  end
  return q
end

-- ====================================================== path normalisation ===
--- Map a URL path onto a file under `root` without ever leaving it.
--- Returns absolutePath, relativePath  or  nil, reason.
function M.safePath(root, urlPath)
  if type(urlPath) ~= 'string' or urlPath == '' then return nil, 'empty path' end
  if urlPath:sub(1, 1) ~= '/' then return nil, 'path must start with /' end
  if urlPath:find('\0', 1, true) then return nil, 'NUL byte in path' end
  if urlPath:find('\\', 1, true) then return nil, 'backslash in path' end
  local low = urlPath:lower()
  -- encoded separators are refused BEFORE decoding, so %2f can never become '/'
  if low:find('%%2f', 1, true) or low:find('%%5c', 1, true)
     or low:find('%%00', 1, true) then
    return nil, 'encoded separator in path'
  end
  local segs = {}
  for seg in urlPath:gmatch('[^/]+') do
    local d, err = M.percentDecode(seg)
    if not d then return nil, err end
    if d == '..' then return nil, 'parent-directory segment' end
    if d ~= '.' then
      if d:find('[/\\]') then return nil, 'separator inside a path segment' end
      if d:find(':', 1, true) then return nil, 'colon in a path segment' end
      segs[#segs + 1] = d
    end
  end
  if #segs == 0 then return nil, 'empty path' end
  local rel = table.concat(segs, '/')
  local base = tostring(root):gsub('[/\\]+$', '')
  return base .. '/' .. rel, rel
end

-- =============================================================== logging =====
local function defaultLog()
  local ok, log = pcall(require, 'lib.log')
  if ok then return log end
  local function noop() end
  return { debug = noop, info = noop, warn = noop, error = noop }
end

-- ============================================================== request ======
local Req = {}
Req.__index = Req

function Req:header(name)
  if type(name) ~= 'string' then return nil end
  return self.headers[name:lower()]
end

function Req:json()
  if self.body == nil or self.body == '' then return nil, 'empty body' end
  local ok, res = pcall(json.decode, self.body)
  if not ok then return nil, tostring(res) end
  return res
end

--- The connection's peer address, for logging / rate limiting.
function Req:peer()
  return (self.remoteIp or '?') .. ':' .. tostring(self.remotePort or 0)
end

-- ============================================================= response ======
local Res = {}
Res.__index = Res

local function sanitize(v)
  return (tostring(v):gsub('[\r\n]', ' '))
end

function Res:status(code)
  self._status = tonumber(code) or 200
  return self
end

--- Getter (one arg) / setter (two args) for a response header.
function Res:header(name, value)
  if value == nil then return self._headers[name] end
  self._headers[name] = value
  return self
end

-- The response headers a recipient is allowed to see more than once.  Everything
-- else is single-valued: emitting it twice is a real hazard (browsers honour the
-- FIRST Content-Type, so a stray res:header('Content-Type','text/html') in front of
-- res:json() renders an API reply as HTML -- stored XSS in an authenticated page).
local REPEATABLE = {
  ['set-cookie'] = true, ['www-authenticate'] = true, ['proxy-authenticate'] = true,
  ['vary'] = true, ['link'] = true,
}
M.REPEATABLE_HEADERS = REPEATABLE

local function headBlock(res, status, hdrs, bodyLen)
  local conn = res.conn
  local lines = { string.format('HTTP/1.1 %d %s', status, STATUS[status] or 'Status') }
  local seen = {}                     -- lower-case name -> index into `lines`
  local function put(n, v)
    local key = tostring(n):lower()
    local line = sanitize(n) .. ': ' .. sanitize(v)
    local at = seen[key]
    if at and not REPEATABLE[key] then
      lines[at] = line                -- last writer wins, exactly one line on the wire
    else
      lines[#lines + 1] = line
      seen[key] = #lines
    end
  end
  local function merge(t)
    if not t then return end
    for k, v in pairs(t) do
      -- Framing is the server's business.  A handler that sets Content-Length itself
      -- could make the wire disagree with the bytes actually sent, and on a keep-alive
      -- connection the peer then resynchronises on the body as if it were the next
      -- response.  Res:file passes a real size through `bodyLen` instead.
      if tostring(k):lower() ~= 'content-length' then
        if type(v) == 'table' then
          for i = 1, #v do put(k, v[i]) end
        else
          put(k, v)
        end
      end
    end
  end
  merge(res._headers)
  merge(hdrs)
  if not seen['date'] then put('Date', httpDate()) end
  if not seen['server'] then put('Server', conn.server.serverName) end
  local noBody = (status == 204 or status == 304 or (status >= 100 and status < 200))
  if bodyLen and not noBody then
    put('Content-Length', tostring(bodyLen))
  end
  if not seen['connection'] then
    put('Connection', res.keepAlive and 'keep-alive' or 'close')
  end
  if res.keepAlive and not seen['keep-alive'] then
    put('Keep-Alive', string.format('timeout=%d, max=%d',
        math.floor(conn.server.idleTimeoutMs / 1000),
        math.max(0, conn.server.maxRequests - conn.requests)))
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = ''
  return table.concat(lines, '\r\n')
end

local function alreadySent(res, what)
  local conn = res.conn
  conn.server.stat.doubleSend = conn.server.stat.doubleSend + 1
  conn.server.log.error('httpserver: %s called after the response was already sent (%s %s)',
                        what, tostring(res.req and res.req.method),
                        tostring(res.req and res.req.rawPath))
  return nil, 'response already sent'
end

--- Send a complete response.  body may be nil.
function Res:send(status, body, headers)
  if self.done then return alreadySent(self, 'res:send') end
  status = tonumber(status) or self._status or 200
  body = body and tostring(body) or ''
  local noBody = (status == 204 or status == 304 or (status >= 100 and status < 200))
  if noBody then body = '' end
  if not headers or not headers['Content-Type'] then
    if not self._headers['Content-Type'] and #body > 0 then
      self._headers['Content-Type'] = 'text/plain; charset=utf-8'
    end
  end
  local head = headBlock(self, status, headers, #body)
  self.done, self.status_ = true, status
  self.conn:write(head)
  if #body > 0 and self.req.method ~= 'HEAD' then self.conn:write(body) end
  self.conn:responseFinished(self)
  return true
end

function Res:json(status, tbl, headers)
  if self.done then return alreadySent(self, 'res:json') end
  local ok, enc = pcall(json.encode, tbl)
  if not ok then
    self.conn.server.log.error('httpserver: json encode failed: %s', tostring(enc))
    return self:send(500, 'json encode failed')
  end
  headers = headers or {}
  headers['Content-Type'] = headers['Content-Type'] or MIME.json
  return self:send(status, enc, headers)
end

function Res:text(status, body, headers)
  headers = headers or {}
  headers['Content-Type'] = headers['Content-Type'] or MIME.txt
  return self:send(status, body, headers)
end

function Res:html(status, body, headers)
  headers = headers or {}
  headers['Content-Type'] = headers['Content-Type'] or MIME.html
  return self:send(status, body, headers)
end

function Res:redirect(location, status, headers)
  if self.done then return alreadySent(self, 'res:redirect') end
  status = tonumber(status) or 302
  headers = headers or {}
  headers['Location'] = location
  headers['Content-Type'] = headers['Content-Type'] or MIME.txt
  return self:send(status, 'Redirecting to ' .. sanitize(location) .. '\n', headers)
end

--- Stream a file.  Never reads more than one chunk while the connection's write
--- backlog is above the high-water mark, so a 1 GB file costs one chunk of memory
--- and never stalls the reactor.
---   opts = { status=, etag=, size=, handle=, headers=, chunkBytes= }
function Res:file(path, contentType, opts)
  if self.done then return alreadySent(self, 'res:file') end
  opts = opts or {}
  local f, err = opts.handle, nil
  if not f then
    f, err = io.open(path, 'rb')
    if not f then return self:send(404, 'not found\n') end
  end
  local size = opts.size
  if not size then
    local ok, sz = pcall(function() local e = f:seek('end'); f:seek('set', 0); return e end)
    if not ok or not sz then f:close(); return self:send(404, 'not found\n') end
    size = sz
  end
  local headers = opts.headers or {}
  headers['Content-Type'] = headers['Content-Type'] or contentType or M.mimeType(path)
  if opts.etag then headers['ETag'] = opts.etag end
  local status = tonumber(opts.status) or 200
  local head = headBlock(self, status, headers, size)
  self.done, self.status_ = true, status
  self.conn:write(head)
  if self.req.method == 'HEAD' or size == 0 then
    f:close()
    self.conn:responseFinished(self)
    return true
  end
  self.conn:startStream(f, size, tonumber(opts.chunkBytes) or 65536, self)
  return true
end

--- Hand the connection's socket to another protocol (WebSocket).
--- Returns  sock, pending  -- `pending` is every byte the peer already sent past the
--- header block -- or nil, err.  Afterwards this server has forgotten the connection
--- completely: it is not swept, not counted in stats(), not charged against
--- maxConnections, and nothing here will write to the socket or close it again.
--- The caller owns the socket from that moment on, including closing it.
--- No HTTP response is written: the 101 (or whatever the new protocol wants) is the
--- new owner's job.  Refuse the upgrade BEFORE calling this if you want to answer it
--- with a normal HTTP status on a connection that stays usable.
function Res:upgrade()
  if self.done then return alreadySent(self, 'res:upgrade') end
  local conn = self.conn
  if not conn or conn.dead then return nil, 'connection is gone' end
  local sock, pending = conn:detach()
  if not sock then return nil, pending end
  self.done, self.status_, self.upgraded = true, 101, true
  return sock, pending
end

-- =========================================================== connection ======
local Conn = {}
Conn.__index = Conn

local function newConn(server, sock, id)
  local ip, port = sock.peerHost, sock.peerPort
  return setmetatable({
    server    = server,
    sock      = sock,
    id        = id,
    remoteIp  = ip or '0.0.0.0',
    remotePort = port or 0,
    inbuf     = '',
    inpos     = 1,             -- read offset into inbuf; see Conn:consume()
    state     = 'head',        -- head | body | chunk-size | chunk-data | chunk-crlf
                               -- | chunk-trailer | dispatch | drain | detached
    requests  = 0,
    last      = server.now(),
    headDeadline = nil,        -- armed by the first byte of a request head
    reqDeadline  = nil,        -- armed when the head is parsed
    bodyParts = nil,
    bodyBytes = 0,
  }, Conn)
end

function Conn:touch() self.last = self.server.now() end

-- ------------------------------------------------------------- input buffer --
-- The parser reads from inbuf at inpos and never rebuilds the string per token.
-- (It used to do `inbuf = inbuf:sub(n+1)` once per chunk-size line, once per data
-- take and once per chunk terminator, which is O(bytes^2 / chunkSize): a 4 MB body
-- of 1-byte chunks took 58 seconds of the single reactor thread.  Now the only
-- copying is the amortised compaction below, i.e. O(bytes).)

--- Bytes buffered but not yet parsed.
function Conn:avail() return #self.inbuf - self.inpos + 1 end

--- Everything not yet parsed, as a string (only used on hand-over / teardown).
function Conn:rest()
  if self.inpos > #self.inbuf then return '' end
  return self.inbuf:sub(self.inpos)
end

function Conn:consume(n)
  self.inpos = self.inpos + n
  if self.inpos > #self.inbuf then self.inbuf, self.inpos = '', 1 end
end

--- Append what just arrived, compacting the consumed prefix at most once per
--- doubling so the total copying stays linear in the bytes received.
function Conn:appendIn(data)
  if self.inpos > 1 then
    if self.inpos > #self.inbuf then
      self.inbuf, self.inpos = '', 1
    elseif self.inpos > 65536 or (self.inpos - 1) * 2 > #self.inbuf then
      self.inbuf = self.inbuf:sub(self.inpos)
      self.inpos = 1
    end
  end
  self.inbuf = self.inbuf .. data
end

function Conn:write(str)
  if self.dead or not str or #str == 0 then return end
  local n, err = self.sock:send(str)
  if not n then
    self.server.log.debug('httpserver: write failed on #%d: %s', self.id, tostring(err))
    return self:destroy('write error')
  end
  self.server.stat.bytesOut = self.server.stat.bytesOut + #str
  self:touch()
  local pending = self.sock.outboxLen or 0
  if pending > self.server.maxWriteBacklog then
    self.server.stat.backlogDrops = self.server.stat.backlogDrops + 1
    self.server.log.warn('httpserver: dropping #%d, write backlog %d > %d bytes',
                         self.id, pending, self.server.maxWriteBacklog)
    return self:destroy('write backlog')
  end
end

function Conn:destroy(reason)
  if self.dead then return end
  self.dead = true
  self.reason = reason
  if self.lingerTimer then self.server.sched.cancel(self.lingerTimer); self.lingerTimer = nil end
  if self.stream and self.stream.f then pcall(function() self.stream.f:close() end) end
  self.stream = nil
  self.server.sched.removeSocket(self.sock)
  pcall(function() self.sock:close() end)
  if self.server.conns[self.id] then
    self.server.conns[self.id] = nil
    self.server.stat.active = self.server.stat.active - 1
  end
  self.server.stat.closed = self.server.stat.closed + 1
  self.server.log.debug('httpserver: closed #%d (%s)', self.id, tostring(reason))
end

--- Give the socket away (see Res:upgrade).  Unregisters the connection from the
--- server -- the sweep, the stats and maxConnections all stop seeing it -- WITHOUT
--- closing anything, and marks it dead so every later callback (onReadable,
--- onWritable, sweep, fail, destroy) is a no-op: no 408 written into someone else's
--- protocol, no double close.
function Conn:detach()
  if self.dead or self.detached then return nil, 'connection is gone' end
  local sock = self.sock
  local pending = self:rest()
  self.detached, self.dead = true, true
  self.reason = 'upgraded'
  self.state  = 'detached'
  self.inbuf, self.inpos = '', 1
  self.headDeadline, self.reqDeadline = nil, nil
  if self.lingerTimer then self.server.sched.cancel(self.lingerTimer); self.lingerTimer = nil end
  if self.stream and self.stream.f then pcall(function() self.stream.f:close() end) end
  self.stream = nil
  self.server.sched.removeSocket(sock)      -- the new owner installs its own callbacks
  if self.server.conns[self.id] then
    self.server.conns[self.id] = nil
    self.server.stat.active = self.server.stat.active - 1
  end
  self.server.stat.upgrades = self.server.stat.upgrades + 1
  self.sock = nil
  self.server.log.debug('httpserver: detached #%d (%d pending bytes)', self.id, #pending)
  return sock, pending
end

--- Close as soon as everything queued has left the box.
--- `linger`: half-close first and keep draining the peer's leftovers for
--- lingerMs before closing the socket for real.  Without it, closing while the
--- peer is still sending makes the stack answer with RST, and an RST throws away
--- data the peer has received but not yet read -- which is exactly how a client
--- loses the 413/431 that told it to stop.
function Conn:closeWhenDrained(reason, linger)
  if self.dead then return end
  self.closeAfterDrain = reason or 'close'
  self.wantLinger = linger and not self.peerClosed
  if (self.sock.outboxLen or 0) == 0 then return self:beginClose() end
  self.state = 'drain'
end

function Conn:beginClose()
  if self.dead then return end
  if not self.wantLinger or self.peerClosed then
    return self:destroy(self.closeAfterDrain or 'close')
  end
  self.wantLinger = false
  self.state = 'linger'
  pcall(function() self.sock:shutdownSend() end)
  local conn = self
  self.lingerTimer = self.server.sched.after(self.server.lingerMs, function()
    conn.lingerTimer = nil
    conn:destroy((conn.closeAfterDrain or 'close') .. ' (linger expired)')
  end)
end

-- ---------------------------------------------------------------- streaming --
function Conn:startStream(f, size, chunkBytes, res)
  if self.dead then
    pcall(function() f:close() end)
    return
  end
  -- the request is answered; the write side is governed by maxWriteBacklog now
  self.reqDeadline = nil
  self.stream = { f = f, remaining = size, chunk = chunkBytes, res = res }
  self:pumpStream()
end

function Conn:pumpStream()
  local st = self.stream
  if not st or self.dead then return end
  local high = self.server.streamHighWater
  while st.remaining > 0 and (self.sock.outboxLen or 0) < high do
    local want = st.remaining < st.chunk and st.remaining or st.chunk
    local data = st.f:read(want)
    if not data or #data == 0 then
      -- the file shrank underneath us: the Content-Length can no longer be met
      self.server.log.warn('httpserver: short read streaming to #%d (%d bytes left)',
                           self.id, st.remaining)
      pcall(function() st.f:close() end)
      self.stream = nil
      return self:destroy('short file read')
    end
    st.remaining = st.remaining - #data
    self:write(data)
    if self.dead then return end
  end
  if st.remaining <= 0 then
    pcall(function() st.f:close() end)
    local res = st.res
    self.stream = nil
    self:responseFinished(res)
  end
end

-- ------------------------------------------------------- response lifecycle --
function Conn:responseFinished(res)
  if self.dead then return end
  self.server.stat.responses = self.server.stat.responses + 1
  self:touch()
  self.reqDeadline = nil
  if not res.keepAlive then
    -- linger when the peer still has bytes in flight (a pipelined request we will
    -- never answer, or a body we stopped reading): an abrupt close would RST them
    -- and could destroy the response we just wrote.
    return self:closeWhenDrained('response complete', self:avail() > 0)
  end
  self.state = 'head'
  self.req, self.res = nil, nil
  self.bodyParts, self.bodyBytes = nil, 0
  -- The next head gets its own absolute deadline, armed by its first byte: an idle
  -- keep-alive connection is governed by idleTimeoutMs, not by headerTimeoutMs.
  self.headDeadline = (self:avail() > 0) and (self.server.now() + self.server.headerTimeoutMs)
                      or nil
  if self:avail() > 0 then
    local conn = self
    self.server.sched.post(function() conn:step() end)
  end
end

-- ------------------------------------------------------------ error replies --
--- Send a plain error and close.  Used for protocol-level failures where the rest
--- of the stream can no longer be trusted.
function Conn:fail(status, message)
  if self.dead then return end
  self.server.stat.badRequests = self.server.stat.badRequests + 1
  local body = string.format('%d %s\n%s\n', status, STATUS[status] or 'Error',
                             message and tostring(message) or '')
  local head = table.concat({
    string.format('HTTP/1.1 %d %s', status, STATUS[status] or 'Error'),
    'Date: ' .. httpDate(),
    'Server: ' .. self.server.serverName,
    'Content-Type: text/plain; charset=utf-8',
    'Content-Length: ' .. #body,
    'Connection: close', '', '' }, '\r\n')
  self.server.log.debug('httpserver: #%d %d %s', self.id, status, tostring(message))
  self:write(head)
  if not self.dead then self:write(body) end
  if not self.dead then self:closeWhenDrained('error ' .. status, true) end
end

-- ================================================== incremental head parse ===
local TOKEN = "^[%w!#%$%%&'%*%+%-%.%^_`|~]+$"

-- Headers that carry the message framing (or the authority the framing is checked
-- against).  RFC 9112 6.3 makes a repeated one a reason to reject the message
-- outright, and merging them into "5, 5" hands every handler a value that
-- tonumber() cannot read.
local SINGLE_VALUED = {
  ['content-length'] = true, ['transfer-encoding'] = true, ['host'] = true,
}

--- Parse the request line + header block.  Returns req fields or nil, status, msg.
--- Framing is CRLF: a bare LF inside the head is refused unless allowBareLF.
local function parseHead(head, allowBareLF)
  local lines = {}
  local pos = 1
  while true do
    local e = head:find('\n', pos, true)
    local line
    if e then
      if not allowBareLF and head:sub(e - 1, e - 1) ~= '\r' then
        return nil, 400, 'bare LF in the header block'
      end
      line = head:sub(pos, e - 1); pos = e + 1
    else line = head:sub(pos); pos = #head + 1 end
    if line:sub(-1) == '\r' then line = line:sub(1, -2) end
    lines[#lines + 1] = line
    if pos > #head then break end
  end
  if #lines == 0 or lines[1] == '' then return nil, 400, 'empty request line' end

  local method, target, vmaj, vmin =
      lines[1]:match('^(%S+) (%S+) HTTP/(%d+)%.(%d+)$')
  if not method then return nil, 400, 'malformed request line' end
  if not method:match(TOKEN) then return nil, 400, 'malformed method' end
  vmaj, vmin = tonumber(vmaj), tonumber(vmin)
  if vmaj ~= 1 then return nil, 505, 'only HTTP/1.x is supported' end

  local headers, order = {}, {}
  for i = 2, #lines do
    local line = lines[i]
    if line ~= '' then
      if line:sub(1, 1) == ' ' or line:sub(1, 1) == '\t' then
        return nil, 400, 'obsolete header line folding'
      end
      local name, value = line:match('^([^:]+):[ \t]*(.-)[ \t]*$')
      if not name or not name:match(TOKEN) then
        return nil, 400, 'malformed header line'
      end
      local key = name:lower()
      order[#order + 1] = { key, value }
      local cur = headers[key]
      if cur == nil then headers[key] = value
      elseif SINGLE_VALUED[key] then return nil, 400, 'duplicate ' .. key .. ' header'
      else headers[key] = cur .. ', ' .. value end
    end
  end
  return { method = method, target = target, vmaj = vmaj, vmin = vmin,
           headers = headers, order = order }
end

--- Split a request target into raw path and raw query.
local function splitTarget(target)
  local q = target:find('?', 1, true)
  if not q then return target, nil end
  return target:sub(1, q - 1), target:sub(q + 1)
end

-- =============================================== the connection state machine =
--- Run the parser over whatever is buffered.  Returns when it needs more bytes,
--- when a handler is running, or when the connection is gone.
function Conn:step()
  if self.dead then return end
  local server = self.server
  local progress = true
  while progress and not self.dead do
    progress = false
    local st = self.state

    if st == 'dispatch' or st == 'drain' or st == 'linger' or st == 'detached' then
      return                                       -- waiting on the handler / on close

    elseif st == 'head' then
      -- tolerate leading blank lines from a previous message
      local trimmed = self.inbuf:match('^[\r\n]*()', self.inpos)
      if trimmed and trimmed > self.inpos then self:consume(trimmed - self.inpos) end
      local e1 = self.inbuf:find('\r\n\r\n', self.inpos, true)
      -- A bare "\n\n" is NOT a head terminator: recognising it lets a request that a
      -- CRLF-only front end reads as one message be read here as two (smuggling).
      local e2 = server.allowBareLF and self.inbuf:find('\n\n', self.inpos, true) or nil
      local headEnd, skip
      if e1 and (not e2 or e1 <= e2) then headEnd, skip = e1 - 1, e1 + 3
      elseif e2 then headEnd, skip = e2 - 1, e2 + 1 end
      if not headEnd then
        -- cap enforced against what is buffered, so an oversized single segment
        -- is rejected without ever being parsed
        if self:avail() > server.maxHeaderBytes then
          return self:fail(431, 'header block exceeds ' .. server.maxHeaderBytes .. ' bytes')
        end
        return
      end
      if headEnd - self.inpos + 1 > server.maxHeaderBytes then
        return self:fail(431, 'header block exceeds ' .. server.maxHeaderBytes .. ' bytes')
      end
      local head = self.inbuf:sub(self.inpos, headEnd)
      self:consume(skip + 1 - self.inpos)
      local parsed, status, msg = parseHead(head, server.allowBareLF)
      if not parsed then return self:fail(status, msg) end
      local ok = self:beginRequest(parsed)
      if not ok then return end
      progress = true

    elseif st == 'body' then
      local need = self.contentLength - self.bodyBytes
      local have = self:avail()
      if need <= 0 then
        self:finishBody(); progress = true
      elseif have > 0 then
        local take = have < need and have or need
        self.bodyParts[#self.bodyParts + 1] = self.inbuf:sub(self.inpos, self.inpos + take - 1)
        self.bodyBytes = self.bodyBytes + take
        self:consume(take)
        if self.bodyBytes >= self.contentLength then self:finishBody() end
        progress = true
      else
        return
      end

    elseif st == 'chunk-size' then
      local e = self.inbuf:find('\n', self.inpos, true)
      if not e then
        if self:avail() > 4096 then return self:fail(400, 'chunk size line too long') end
        return
      end
      if not server.allowBareLF and self.inbuf:sub(e - 1, e - 1) ~= '\r' then
        return self:fail(400, 'chunk size line not terminated by CRLF')
      end
      local line = self.inbuf:sub(self.inpos, e - 1):gsub('\r$', '')
      self:consume(e + 1 - self.inpos)
      -- A PREFIX match here ("^(%x+)") accepts "5junk" as 5 and reads "0x5" as 0,
      -- i.e. as the LAST chunk -- after which the real chunk data is swallowed as
      -- trailer lines and whatever follows is dispatched as a pipelined request.
      -- RFC 9112 7.1: chunk-size is followed by CRLF or by a ';'-introduced ext.
      local hex, ext = line:match('^(%x+)(.*)$')
      if not hex or (#ext > 0 and ext:sub(1, 1) ~= ';') then
        return self:fail(400, 'malformed chunk size')
      end
      if #hex > 16 then return self:fail(400, 'chunk size out of range') end
      local size = tonumber(hex, 16)
      if not size then return self:fail(400, 'malformed chunk size') end
      if size == 0 then
        self.state = 'chunk-trailer'
        self.trailerBytes = 0
      else
        if self.bodyBytes + size > server.maxBodyBytes then
          return self:fail(413, 'body exceeds ' .. server.maxBodyBytes .. ' bytes')
        end
        self.chunkRemaining = size
        self.state = 'chunk-data'
      end
      progress = true

    elseif st == 'chunk-data' then
      local have = self:avail()
      if have == 0 then return end
      local take = have < self.chunkRemaining and have or self.chunkRemaining
      self.bodyParts[#self.bodyParts + 1] = self.inbuf:sub(self.inpos, self.inpos + take - 1)
      self.bodyBytes = self.bodyBytes + take
      self:consume(take)
      self.chunkRemaining = self.chunkRemaining - take
      if self.bodyBytes > server.maxBodyBytes then
        return self:fail(413, 'body exceeds ' .. server.maxBodyBytes .. ' bytes')
      end
      if self.chunkRemaining == 0 then self.state = 'chunk-crlf' end
      progress = true

    elseif st == 'chunk-crlf' then
      local have = self:avail()
      if have < 1 then return end
      local two = self.inbuf:sub(self.inpos, self.inpos + 1)
      if two == '\r\n' then self:consume(2)
      elseif server.allowBareLF and two:sub(1, 1) == '\n' then self:consume(1)
      elseif two == '\r' and have < 2 then return
      else return self:fail(400, 'chunk not terminated by CRLF') end
      self.state = 'chunk-size'
      progress = true

    elseif st == 'chunk-trailer' then
      -- read trailer lines until an empty one
      local e = self.inbuf:find('\n', self.inpos, true)
      if not e then
        self.trailerBytes = self:avail()
        if self.trailerBytes > server.maxHeaderBytes then
          return self:fail(431, 'trailer block too large')
        end
        return
      end
      if not server.allowBareLF and self.inbuf:sub(e - 1, e - 1) ~= '\r' then
        return self:fail(400, 'bare LF in the trailer section')
      end
      local line = self.inbuf:sub(self.inpos, e - 1):gsub('\r$', '')
      self:consume(e + 1 - self.inpos)
      if line == '' then
        self:finishBody()
      else
        self.trailerBytes = (self.trailerBytes or 0) + #line
        if self.trailerBytes > server.maxHeaderBytes then
          return self:fail(431, 'trailer block too large')
        end
      end
      progress = true

    else
      return self:destroy('bad internal state ' .. tostring(st))
    end
  end
end

--- Validate a parsed head and decide how the body arrives.
function Conn:beginRequest(parsed)
  local server = self.server
  local h = parsed.headers
  self.requests = self.requests + 1
  server.stat.requests = server.stat.requests + 1

  self.headDeadline = nil
  self.reqDeadline  = server.now() + server.requestTimeoutMs

  if parsed.vmaj == 1 and parsed.vmin >= 1 and not h.host then
    self:fail(400, 'missing Host header'); return false
  end
  -- Host allow-list.  A loopback-bound hub is reachable through DNS rebinding: a
  -- page the operator visits points a hostname it controls at 127.0.0.1, which
  -- makes the request same-SITE (so the session cookie is sent) and same-ORIGIN
  -- (so an Origin check passes).  Pinning the Host header is what closes that.
  -- Off by default because the right list depends on the deployment; the hub is
  -- expected to set it (see docs/hub-primitives.md).
  if server.allowedHosts and h.host then
    local hostOnly = h.host:match('^%[([^%]]*)%]') or h.host:match('^([^:]*)')
    if not server.allowedHosts[(hostOnly or ''):lower()] then
      self:fail(400, 'Host header is not allowed'); return false
    end
  end

  -- keep-alive decision
  local connHdr = (h.connection or ''):lower()
  local keepAlive
  if parsed.vmin >= 1 then keepAlive = not connHdr:find('close', 1, true)
  else keepAlive = connHdr:find('keep%-alive') ~= nil end
  if self.requests >= server.maxRequests then keepAlive = false end
  if server.stopping then keepAlive = false end

  -- framing
  local te = h['transfer-encoding']
  local cl = h['content-length']
  local chunked = false
  if te and te ~= '' then
    local lower = te:lower():gsub('%s', '')
    if lower == 'chunked' then
      chunked = true
    elseif lower == 'identity' then
      chunked = false
    else
      self:fail(501, 'unsupported Transfer-Encoding: ' .. te); return false
    end
    if cl then self:fail(400, 'both Content-Length and Transfer-Encoding'); return false end
  end

  local contentLength = 0
  if not chunked and cl then
    -- a repeated Content-Length was already rejected with 400 by parseHead, so the
    -- value handlers see is exactly the value the framing used
    local v = cl:match('^%s*(%d+)%s*$')
    if not v then self:fail(400, 'malformed Content-Length'); return false end
    contentLength = tonumber(v)
    if contentLength > server.maxBodyBytes then
      -- rejected before a single body byte is buffered
      self:fail(413, 'body of ' .. contentLength .. ' bytes exceeds ' .. server.maxBodyBytes)
      return false
    end
  end

  local rawPath, rawQuery = splitTarget(parsed.target)
  if rawPath == '' then rawPath = '/' end
  if rawPath:sub(1, 1) ~= '/' and parsed.method ~= 'OPTIONS' and parsed.method ~= 'CONNECT' then
    -- absolute-form targets ("http://host/x") are accepted by stripping the origin
    local stripped = rawPath:match('^https?://[^/]*(/.*)$')
    if stripped then rawPath = stripped
    else self:fail(400, 'unsupported request target'); return false end
  end

  local path, perr = M.percentDecode(rawPath)
  if not path then self:fail(400, 'bad percent-escape in path'); return false end
  local query, qerr = M.parseQuery(rawQuery)
  if not query then self:fail(400, tostring(qerr)); return false end

  local req = setmetatable({
    method = parsed.method:upper(),
    target = parsed.target,
    rawPath = rawPath,
    path = path,
    rawQuery = rawQuery,
    query = query,
    headers = h,
    headerOrder = parsed.order,
    version = string.format('HTTP/%d.%d', parsed.vmaj, parsed.vmin),
    vmaj = parsed.vmaj, vmin = parsed.vmin,
    keepAlive = keepAlive,
    remoteIp = self.remoteIp,
    remotePort = self.remotePort,
    connId = self.id,
    id = server.stat.requests,
    body = '',
    startedMs = server.now(),
  }, Req)
  self.req = req
  self.keepAlive = keepAlive
  self.contentLength = contentLength
  self.bodyParts, self.bodyBytes = {}, 0

  -- 100-continue: only once the body has been accepted by the caps above
  local expect = (h.expect or ''):lower()
  if expect:find('100-continue', 1, true) and parsed.vmin >= 1 then
    self:write('HTTP/1.1 100 Continue\r\n\r\n')
    if self.dead then return false end
    server.stat.continues = server.stat.continues + 1
  end

  if chunked then
    self.state = 'chunk-size'
  elseif contentLength > 0 then
    self.state = 'body'
  else
    self.state = 'body'          -- finishes immediately on the next loop turn
  end
  return true
end

function Conn:finishBody()
  local req = self.req
  req.body = table.concat(self.bodyParts or {})
  self.bodyParts = nil
  self.state = 'dispatch'
  self:dispatch()
end

function Conn:dispatch()
  local server = self.server
  local req = self.req
  local res = setmetatable({
    conn = self, req = req, _headers = {}, _status = 200,
    keepAlive = self.keepAlive, done = false,
  }, Res)
  self.res = res
  server.stat.inflight = server.stat.inflight + 1
  local ok, err = pcall(server.onRequest, req, res)
  server.stat.inflight = server.stat.inflight - 1
  if not ok then
    server.stat.handlerErrors = server.stat.handlerErrors + 1
    server.log.error('httpserver: handler error for %s %s: %s',
                     tostring(req.method), tostring(req.rawPath), tostring(err))
    if not res.done and not self.dead then
      res:send(500, '500 Internal Server Error\n')
    end
  end
  -- a handler that returned without answering is treated as asynchronous: the
  -- response may arrive from a later reactor turn, the idle timeout is the backstop
end

-- ============================================================== the server ===
local Server = {}
Server.__index = Server

--- Create a server.  Nothing is bound until :start().
function M.new(opts)
  opts = opts or {}
  if type(opts.onRequest) ~= 'function' then
    error('httpserver.new: onRequest must be a function', 2)
  end
  local sched = opts.sched or require('lib.sched')
  local log = opts.log or defaultLog()
  local nowFn = opts.now
  if not nowFn then
    local sys = require('lib.sys')
    nowFn = sys.nowMs
  end
  local s = setmetatable({
    host = opts.host or '127.0.0.1',
    port = tonumber(opts.port) or 0,
    sched = sched,
    log = log,
    now = nowFn,
    onRequest = opts.onRequest,
    serverName = opts.serverName or M.SERVER_NAME,
    maxHeaderBytes = tonumber(opts.maxHeaderBytes) or 32768,
    maxBodyBytes   = tonumber(opts.maxBodyBytes) or (4 * 1024 * 1024),
    idleTimeoutMs  = tonumber(opts.idleTimeoutMs) or 30000,
    -- Absolute deadlines.  idleTimeoutMs is a SLIDING window that any byte resets,
    -- so one byte per (idleTimeout/2) held a connection -- and up to maxBodyBytes of
    -- buffered body -- forever, until maxConnections was exhausted and the hub
    -- stopped answering anybody.  These two are wall-clock caps that no traffic
    -- can push back: head delivery, and head-parsed -> response-started.
    headerTimeoutMs  = tonumber(opts.headerTimeoutMs) or 10000,
    requestTimeoutMs = tonumber(opts.requestTimeoutMs) or 30000,
    allowBareLF    = opts.allowBareLF and true or false,
    maxRequests    = tonumber(opts.maxRequests) or 100,
    maxWriteBacklog = tonumber(opts.maxWriteBacklog) or (4 * 1024 * 1024),
    maxConnections = tonumber(opts.maxConnections) or 256,
    streamHighWater = tonumber(opts.streamHighWater) or (256 * 1024),
    sendBufferBytes = tonumber(opts.sendBufferBytes),   -- SO_SNDBUF on accepted sockets
    recvBufferBytes = tonumber(opts.recvBufferBytes),   -- SO_RCVBUF on accepted sockets
    backlog = tonumber(opts.backlog) or 64,
    sweepMs = tonumber(opts.sweepMs) or 500,
    lingerMs = tonumber(opts.lingerMs) or 300,
    conns = {},
    nextConnId = 1,
    stat = {
      accepted = 0, closed = 0, active = 0, requests = 0, responses = 0,
      bytesIn = 0, bytesOut = 0, badRequests = 0, handlerErrors = 0,
      timeouts = 0, backlogDrops = 0, doubleSend = 0, continues = 0,
      acceptErrors = 0, inflight = 0, deadlines = 0, upgrades = 0,
    },
  }, Server)
  -- Host allow-list (nil = any host), stored lower-cased as a set.
  if opts.allowedHosts then
    local set = {}
    for _, hname in ipairs(opts.allowedHosts) do set[tostring(hname):lower()] = true end
    s.allowedHosts = set
  end
  -- the absolute amount of unparsed input tolerated per connection
  s.maxInputBacklog = s.maxHeaderBytes + s.maxBodyBytes + 65536
  return s
end

function Server:start()
  if self.listener then return self.boundPort end
  local ok, err = socket.init()
  if not ok then return nil, err end
  local l, lerr = socket.listen(self.host, self.port, self.backlog)
  if not l then return nil, lerr end
  self.listener = l
  self.boundPort = l.boundPort or l:port()
  self.stopping = false
  local server = self
  self.sched.onSocket(l, function() server:onAcceptable() end)
  self.sweepId = self.sched.every(self.sweepMs, function() server:sweep() end)
  self.log.info('httpserver: listening on %s:%d', self.host, self.boundPort)
  return self.boundPort
end

function Server:onAcceptable()
  -- drain the accept queue, but never more than a bounded burst per turn
  for _ = 1, 32 do
    local c, err = self.listener:accept()
    if not c then
      if err ~= 'wouldblock' then
        self.stat.acceptErrors = self.stat.acceptErrors + 1
        self.log.debug('httpserver: accept failed: %s', tostring(err))
      end
      return
    end
    self.stat.accepted = self.stat.accepted + 1
    if self.stat.active >= self.maxConnections or self.stopping then
      pcall(function() c:close() end)
      self.stat.closed = self.stat.closed + 1
    else
      if self.sendBufferBytes or self.recvBufferBytes then
        c:setBufferSize(self.sendBufferBytes, self.recvBufferBytes)
      end
      local id = self.nextConnId
      self.nextConnId = id + 1
      local conn = newConn(self, c, id)
      self.conns[id] = conn
      self.stat.active = self.stat.active + 1
      self.sched.onSocket(c,
        function() conn:onReadable() end,
        function() conn:onWritable() end)
      self.log.debug('httpserver: accepted #%d from %s', id, conn.remoteIp)
    end
  end
end

function Conn:onReadable()
  if self.dead then return end
  if self.state == 'linger' then
    -- half-closed: swallow whatever the peer still had in flight, close on its FIN
    local d = self.sock:recv(65536)
    if d == nil then self:destroy((self.closeAfterDrain or 'close') .. ' (peer done)') end
    return
  end
  if self.peerClosed then return end
  local data, err = self.sock:recv(65536)
  if data == nil then
    -- orderly shutdown or a socket error: nothing more will arrive on this socket
    self.peerClosed = true
    self.keepAlive = false
    if self.res then self.res.keepAlive = false end
    if self.state == 'dispatch' or self.state == 'drain' or self.stream then
      -- a half-close while a response is in flight: finish writing it, then close
      -- (the idle sweep is the backstop if the handler never answers)
      return
    end
    if self.state == 'head' and self:avail() == 0 then
      return self:destroy(err == 'closed' and 'peer closed' or tostring(err))
    end
    return self:destroy('peer closed mid-request')
  end
  if data == '' then return end
  self.server.stat.bytesIn = self.server.stat.bytesIn + #data
  self:appendIn(data)
  self:touch()
  -- arm the absolute head deadline on the FIRST byte of a request, so an idle
  -- keep-alive connection is still governed by idleTimeoutMs alone
  if self.state == 'head' and not self.headDeadline and self:avail() > 0 then
    self.headDeadline = self.server.now() + self.server.headerTimeoutMs
  end
  if self:avail() > self.server.maxInputBacklog then
    self.server.log.warn('httpserver: #%d input backlog %d bytes, dropping',
                         self.id, self:avail())
    return self:destroy('input backlog')
  end
  self:step()
end

function Conn:onWritable()
  if self.dead then return end
  self:touch()
  if self.stream then return self:pumpStream() end
  if self.closeAfterDrain and (self.sock.outboxLen or 0) == 0 then
    return self:beginClose()
  end
end

--- Idle sweep: closes connections that went quiet and finishes drained closes.
function Server:sweep()
  local now = self.now()
  local limit = self.idleTimeoutMs
  for id, conn in pairs(self.conns) do
    if conn.dead then
      self.conns[id] = nil
    elseif conn.state == 'linger' then
      -- half-closed already; its own linger timer (or the peer's FIN) closes it
    elseif conn.closeAfterDrain and (conn.sock.outboxLen or 0) == 0 then
      conn:beginClose()
    elseif conn.headDeadline and now > conn.headDeadline then
      self.stat.timeouts = self.stat.timeouts + 1
      self.stat.deadlines = self.stat.deadlines + 1
      conn:fail(408, 'header deadline exceeded')
    elseif conn.reqDeadline and now > conn.reqDeadline then
      self.stat.timeouts = self.stat.timeouts + 1
      self.stat.deadlines = self.stat.deadlines + 1
      conn:fail(408, 'request deadline exceeded')
    elseif now - conn.last > limit then
      self.stat.timeouts = self.stat.timeouts + 1
      if conn.state == 'head' and conn:avail() == 0 then
        conn:destroy('idle timeout')            -- between requests: just close
      else
        conn:fail(408, 'request timed out')     -- mid-request: tell the client
      end
    end
  end
end

function Server:stop()
  self.stopping = true
  if self.sweepId then self.sched.cancel(self.sweepId); self.sweepId = nil end
  if self.listener then
    self.sched.removeSocket(self.listener)
    pcall(function() self.listener:close() end)
    self.listener = nil
  end
  for id, conn in pairs(self.conns) do
    conn:destroy('server stopped')
    self.conns[id] = nil
  end
  self.stat.active = 0
  self.log.info('httpserver: stopped (%d requests served)', self.stat.responses)
  return true
end

function Server:stats()
  local t = {}
  for k, v in pairs(self.stat) do t[k] = v end
  t.port = self.boundPort
  t.host = self.host
  t.listening = self.listener ~= nil
  t.connections = t.active
  return t
end

--- Number of live connections (cheap accessor for tests / the panel).
function Server:connectionCount() return self.stat.active end

-- ========================================================= static file serving
local function sha256hex(s)
  local sha2 = require('lib.sha2')
  return sha2.sha256hex(s)
end

local function etagMatches(ifNoneMatch, etag)
  if not ifNoneMatch or not etag then return false end
  if ifNoneMatch:find('*', 1, true) then return true end
  local bare = etag:gsub('^W/', '')
  for tok in ifNoneMatch:gmatch('[^,]+') do
    local t = tok:match('^%s*(.-)%s*$'):gsub('^W/', '')
    if t == bare then return true end
  end
  return false
end
M.etagMatches = etagMatches

--- Build a GET/HEAD static-file handler rooted at opts.root.
---   opts = { root=, index='index.html', cacheControl='no-cache', hashMaxBytes=8MB,
---            headers={extra response headers}, notFound=function(req,res) }
--- No directory listing: a directory (or anything unreadable) is a 404.
function M.static(opts)
  opts = opts or {}
  local root = assert(opts.root, 'httpserver.static: root is required')
  local index = opts.index or 'index.html'
  local cacheControl = opts.cacheControl or 'no-cache'
  local hashMax = tonumber(opts.hashMaxBytes) or (8 * 1024 * 1024)
  local extra = opts.headers
  local cache = {}                 -- abs -> { size=, etag= }

  return function(req, res)
    if req.method ~= 'GET' and req.method ~= 'HEAD' then
      return res:send(405, 'method not allowed\n', { ['Allow'] = 'GET, HEAD' })
    end
    local urlPath = req.rawPath                 -- raw: encoded slashes stay refused
    if urlPath:sub(-1) == '/' then urlPath = urlPath .. index end
    local abs, why = M.safePath(root, urlPath)
    if not abs then
      return res:send(403, 'forbidden: ' .. tostring(why) .. '\n')
    end
    local f = io.open(abs, 'rb')
    if not f then
      if opts.notFound then return opts.notFound(req, res) end
      return res:send(404, 'not found\n')
    end
    local okSize, size = pcall(function() local e = f:seek('end'); f:seek('set', 0); return e end)
    if not okSize or not size then
      f:close()
      return res:send(404, 'not found\n')
    end
    -- a directory opens on POSIX but cannot be read: treat it as absent.
    -- (read(0) is nil at EOF too, so an empty file must not take this branch)
    if size > 0 then
      local okProbe, probe = pcall(function() return f:read(0) end)
      if not okProbe or probe == nil then
        f:close()
        if opts.notFound then return opts.notFound(req, res) end
        return res:send(404, 'not found\n')
      end
      f:seek('set', 0)
    end

    local ent = cache[abs]
    if not ent or ent.size ~= size then
      local etag
      if size <= hashMax then
        local content = f:read('*a') or ''
        etag = '"' .. sha256hex(content):sub(1, 32) .. '"'
        f:seek('set', 0)
      else
        etag = string.format('W/"%x"', size)
      end
      ent = { size = size, etag = etag }
      cache[abs] = ent
    end

    local headers = { ['Cache-Control'] = cacheControl, ['ETag'] = ent.etag }
    if extra then for k, v in pairs(extra) do headers[k] = v end end

    if etagMatches(req:header('if-none-match'), ent.etag) then
      f:close()
      return res:send(304, nil, headers)
    end
    return res:file(abs, M.mimeType(abs),
                    { size = size, handle = f, etag = ent.etag, headers = headers })
  end
end

-- ======================================================== websocket routing ==
--- Build a route handler that hands the connection to `ws` (lib/wsserver.lua).
---   local route = httpserver.websocketRoute(require('lib.wsserver'), {
---       allowedOrigins = { 'https://panel.example' },   -- REQUIRED reading: see wsserver
---       onMessage = ..., onClose = ..., onOpen = ...,
---   })
--- A refused handshake (wrong version, a foreign Origin, ...) is answered on the
--- HTTP layer with the status wsserver asked for, on a connection that stays a
--- perfectly ordinary keep-alive HTTP connection.  Only an ACCEPTED handshake
--- detaches the socket, and the 101 is then written by wsserver.
--- Returns the ws object (a route usually just ignores it: the callbacks drive it).
function M.websocketRoute(ws, opts)
  if type(ws) ~= 'table' or type(ws.upgrade) ~= 'function' then
    error('httpserver.websocketRoute: pass the lib.wsserver module', 2)
  end
  opts = opts or {}
  return function(req, res)
    local accept, rej = ws.checkRequest(req, opts)
    if not accept then
      rej = rej or { status = 400, message = 'bad websocket request' }
      return res:send(rej.status, tostring(rej.message) .. '\n', rej.headers)
    end
    local sock, pending = res:upgrade()
    if not sock then return nil, pending end
    local o = { pending = pending }
    for k, v in pairs(opts) do if o[k] == nil then o[k] = v end end
    o.pending = pending
    return ws.upgrade(sock, req, o)
  end
end

M.Server, M.Conn, M.Req, M.Res = Server, Conn, Req, Res

return M
