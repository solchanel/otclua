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
--       idleTimeoutMs  = 30000,
--       maxRequests    = 100,                  -- keep-alive requests per connection
--       maxWriteBacklog = 4 * 1024 * 1024,     -- per connection, then the peer is dropped
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
--            Sending twice never raises: it is logged and returns nil, err.
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
--   * header values written back have CR/LF stripped (no response splitting).
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

local function headBlock(res, status, hdrs, bodyLen)
  local conn = res.conn
  local lines = { string.format('HTTP/1.1 %d %s', status, STATUS[status] or 'Status') }
  local seen = {}
  local function put(n, v)
    lines[#lines + 1] = sanitize(n) .. ': ' .. sanitize(v)
    seen[tostring(n):lower()] = true
  end
  local function merge(t)
    if not t then return end
    for k, v in pairs(t) do
      if type(v) == 'table' then
        for i = 1, #v do put(k, v[i]) end
      else
        put(k, v)
      end
    end
  end
  merge(res._headers)
  merge(hdrs)
  if not seen['date'] then put('Date', httpDate()) end
  if not seen['server'] then put('Server', conn.server.serverName) end
  local noBody = (status == 204 or status == 304 or (status >= 100 and status < 200))
  if bodyLen and not noBody and not seen['content-length'] then
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
    state     = 'head',        -- head | body | chunk-size | chunk-data | chunk-crlf
                               -- | chunk-trailer | dispatch | drain
    requests  = 0,
    last      = server.now(),
    bodyParts = nil,
    bodyBytes = 0,
  }, Conn)
end

function Conn:touch() self.last = self.server.now() end

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
  if not res.keepAlive then
    -- linger when the peer still has bytes in flight (a pipelined request we will
    -- never answer, or a body we stopped reading): an abrupt close would RST them
    -- and could destroy the response we just wrote.
    return self:closeWhenDrained('response complete', #self.inbuf > 0)
  end
  self.state = 'head'
  self.req, self.res = nil, nil
  self.bodyParts, self.bodyBytes = nil, 0
  if #self.inbuf > 0 then
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

--- Parse the request line + header block.  Returns req fields or nil, status, msg.
local function parseHead(head)
  local lines = {}
  local pos = 1
  while true do
    local e = head:find('\n', pos, true)
    local line
    if e then line = head:sub(pos, e - 1); pos = e + 1
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

    if st == 'dispatch' or st == 'drain' or st == 'linger' then
      return                                       -- waiting on the handler / on close

    elseif st == 'head' then
      -- tolerate leading blank lines from a previous message
      local trimmed = self.inbuf:match('^[\r\n]*()')
      if trimmed and trimmed > 1 then self.inbuf = self.inbuf:sub(trimmed) end
      local e1 = self.inbuf:find('\r\n\r\n', 1, true)
      local e2 = self.inbuf:find('\n\n', 1, true)
      local headEnd, skip
      if e1 and (not e2 or e1 <= e2) then headEnd, skip = e1 - 1, e1 + 3
      elseif e2 then headEnd, skip = e2 - 1, e2 + 1 end
      if not headEnd then
        -- cap enforced against what is buffered, so an oversized single segment
        -- is rejected without ever being parsed
        if #self.inbuf > server.maxHeaderBytes then
          return self:fail(431, 'header block exceeds ' .. server.maxHeaderBytes .. ' bytes')
        end
        return
      end
      if headEnd > server.maxHeaderBytes then
        return self:fail(431, 'header block exceeds ' .. server.maxHeaderBytes .. ' bytes')
      end
      local head = self.inbuf:sub(1, headEnd)
      self.inbuf = self.inbuf:sub(skip + 1)
      local parsed, status, msg = parseHead(head)
      if not parsed then return self:fail(status, msg) end
      local ok = self:beginRequest(parsed)
      if not ok then return end
      progress = true

    elseif st == 'body' then
      local need = self.contentLength - self.bodyBytes
      if need <= 0 then
        self:finishBody(); progress = true
      elseif #self.inbuf > 0 then
        local take = #self.inbuf < need and #self.inbuf or need
        self.bodyParts[#self.bodyParts + 1] = self.inbuf:sub(1, take)
        self.bodyBytes = self.bodyBytes + take
        self.inbuf = self.inbuf:sub(take + 1)
        if self.bodyBytes >= self.contentLength then self:finishBody() end
        progress = true
      else
        return
      end

    elseif st == 'chunk-size' then
      local e = self.inbuf:find('\n', 1, true)
      if not e then
        if #self.inbuf > 4096 then return self:fail(400, 'chunk size line too long') end
        return
      end
      local line = self.inbuf:sub(1, e - 1):gsub('\r$', '')
      self.inbuf = self.inbuf:sub(e + 1)
      local hex = line:match('^(%x+)')
      if not hex then return self:fail(400, 'malformed chunk size') end
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
      if #self.inbuf == 0 then return end
      local take = #self.inbuf < self.chunkRemaining and #self.inbuf or self.chunkRemaining
      self.bodyParts[#self.bodyParts + 1] = self.inbuf:sub(1, take)
      self.bodyBytes = self.bodyBytes + take
      self.inbuf = self.inbuf:sub(take + 1)
      self.chunkRemaining = self.chunkRemaining - take
      if self.bodyBytes > server.maxBodyBytes then
        return self:fail(413, 'body exceeds ' .. server.maxBodyBytes .. ' bytes')
      end
      if self.chunkRemaining == 0 then self.state = 'chunk-crlf' end
      progress = true

    elseif st == 'chunk-crlf' then
      if #self.inbuf < 1 then return end
      if self.inbuf:sub(1, 2) == '\r\n' then self.inbuf = self.inbuf:sub(3)
      elseif self.inbuf:sub(1, 1) == '\n' then self.inbuf = self.inbuf:sub(2)
      elseif self.inbuf:sub(1, 1) == '\r' and #self.inbuf < 2 then return
      else return self:fail(400, 'chunk not terminated by CRLF') end
      self.state = 'chunk-size'
      progress = true

    elseif st == 'chunk-trailer' then
      -- read trailer lines until an empty one
      local e = self.inbuf:find('\n', 1, true)
      if not e then
        self.trailerBytes = #self.inbuf
        if self.trailerBytes > server.maxHeaderBytes then
          return self:fail(431, 'trailer block too large')
        end
        return
      end
      local line = self.inbuf:sub(1, e - 1):gsub('\r$', '')
      self.inbuf = self.inbuf:sub(e + 1)
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

  if parsed.vmaj == 1 and parsed.vmin >= 1 and not h.host then
    self:fail(400, 'missing Host header'); return false
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
    -- duplicated Content-Length headers are merged as "a, b" by parseHead
    local first
    for part in cl:gmatch('[^,]+') do
      local v = part:match('^%s*(%d+)%s*$')
      if not v then self:fail(400, 'malformed Content-Length'); return false end
      v = tonumber(v)
      if first == nil then first = v
      elseif first ~= v then self:fail(400, 'conflicting Content-Length'); return false end
    end
    contentLength = first or 0
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
      acceptErrors = 0, inflight = 0,
    },
  }, Server)
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
    if self.state == 'head' and #self.inbuf == 0 then
      return self:destroy(err == 'closed' and 'peer closed' or tostring(err))
    end
    return self:destroy('peer closed mid-request')
  end
  if data == '' then return end
  self.server.stat.bytesIn = self.server.stat.bytesIn + #data
  self.inbuf = self.inbuf .. data
  self:touch()
  if #self.inbuf > self.server.maxInputBacklog then
    self.server.log.warn('httpserver: #%d input backlog %d bytes, dropping',
                         self.id, #self.inbuf)
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
    elseif now - conn.last > limit then
      self.stat.timeouts = self.stat.timeouts + 1
      if conn.state == 'head' and #conn.inbuf == 0 then
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

M.Server, M.Conn, M.Req, M.Res = Server, Conn, Req, Res

return M
