-- lib/socket.lua -- non-blocking TCP over ws2_32 (FFI).  No blocking calls anywhere:
-- connect returns immediately, send never blocks (an internal outbox absorbs whatever
-- the OS did not accept and is drained on writability by lib/sched.lua).
--
-- API (docs/API.md):
--   socket.init()                        WSAStartup(2.2), idempotent
--   local s = socket.tcp()
--   s:connect(host, port)                getaddrinfo + non-blocking connect
--                                        -> true (maybe still connecting) | nil, err
--   s:isConnected() -> bool              (polls SO_ERROR when still connecting)
--   s:send(str)     -> bytes | nil, err  never blocks; buffers the remainder
--   s:recv(max)     -> str | '' | nil,'closed' | nil, err
--   s:close()
--   s:fd()                               raw SOCKET (cdata) for select
--   socket.select(readFds, writeFds, timeoutMs [, exceptFds]) -> readySet | nil, err
--   socket.listen(host, port [, backlog]) -> listener ; listener:accept() -> sock|nil,err
--
-- readySet shape (a single table, as the contract names it):
--   readySet.read / .write / .except  = arrays of the *entries the caller passed in*
--                                       (socket objects or raw fds) that are ready
--   readySet.r / .w / .e              = maps  tonumber(fd) -> true
-- Both socket objects and raw SOCKET cdata are accepted in the input lists.
--
-- Gotchas honoured here (docs/lua-runtime.md + its VERIFIER corrections):
--   * a SOCKET is uintptr_t cdata -- NEVER a table key; always tonumber(fd).
--   * a FAILED non-blocking connect is reported in *exceptfds* on Windows, not in
--     writefds, so connect-pending sockets are always placed in the except set too.
--   * Winsock select() with all three sets empty returns WSAEINVAL instead of
--     sleeping; socket.select() falls back to Sleep() in that case.
--   * struct timeval uses 32-bit long on Windows; addrinfo puts ai_canonname BEFORE
--     ai_addr (reverse of glibc); fd_set is {count, SOCKET[64]}, not a bitmask.
--   * send() returning WSAEWOULDBLOCK after 0 bytes is NOT an error -- the ambiguous
--     "return total, 'partial'" contract from the sketch is not used; :send() reports
--     the full byte count it took ownership of and queues the rest.

local ffi = require('ffi')

local socket = {}

-- ---------------------------------------------------------------- cdefs ----
local function cdef(s) pcall(ffi.cdef, s) end

cdef [[ typedef uintptr_t LC_SOCKET; ]]
cdef [[ struct lc_sockaddr    { unsigned short sa_family; char sa_data[14]; }; ]]
cdef [[ struct lc_in_addr     { unsigned long s_addr; }; ]]
cdef [[ struct lc_sockaddr_in { short sin_family; unsigned short sin_port;
                                struct lc_in_addr sin_addr; char sin_zero[8]; }; ]]
cdef [[ struct lc_timeval     { long tv_sec; long tv_usec; }; ]]
cdef [[ typedef struct lc_fd_set { unsigned int fd_count; LC_SOCKET fd_array[64]; } lc_fd_set; ]]
cdef [[ struct lc_addrinfo { int ai_flags; int ai_family; int ai_socktype; int ai_protocol;
                             size_t ai_addrlen; char *ai_canonname;
                             struct lc_sockaddr *ai_addr; struct lc_addrinfo *ai_next; }; ]]
cdef [[ int    WSAStartup(unsigned short, void*); ]]
cdef [[ int    WSACleanup(void); ]]
cdef [[ int    WSAGetLastError(void); ]]
cdef [[ LC_SOCKET socket(int,int,int); ]]
cdef [[ int    closesocket(LC_SOCKET); ]]
cdef [[ int    connect(LC_SOCKET, const struct lc_sockaddr*, int); ]]
cdef [[ int    bind(LC_SOCKET, const struct lc_sockaddr*, int); ]]
cdef [[ int    listen(LC_SOCKET, int); ]]
cdef [[ LC_SOCKET accept(LC_SOCKET, struct lc_sockaddr*, int*); ]]
cdef [[ int    getsockname(LC_SOCKET, struct lc_sockaddr*, int*); ]]
cdef [[ int    send(LC_SOCKET, const char*, int, int); ]]
cdef [[ int    recv(LC_SOCKET, char*, int, int); ]]
cdef [[ int    ioctlsocket(LC_SOCKET, long, unsigned long*); ]]
cdef [[ int    setsockopt(LC_SOCKET,int,int,const char*,int); ]]
cdef [[ int    getsockopt(LC_SOCKET,int,int,char*,int*); ]]
cdef [[ int    select(int, lc_fd_set*, lc_fd_set*, lc_fd_set*, const struct lc_timeval*); ]]
cdef [[ int    shutdown(LC_SOCKET,int); ]]
cdef [[ unsigned short htons(unsigned short); ]]
cdef [[ unsigned short ntohs(unsigned short); ]]
cdef [[ int    getaddrinfo(const char*, const char*, const struct lc_addrinfo*,
                           struct lc_addrinfo**); ]]
cdef [[ void   freeaddrinfo(struct lc_addrinfo*); ]]

local ws2 = ffi.load('ws2_32')

-- ------------------------------------------------------------ constants ----
local AF_INET, SOCK_STREAM, IPPROTO_TCP = 2, 1, 6
local FIONBIO         = -2147195266     -- 0x8004667E as a signed long
local INVALID_SOCKET  = ffi.cast('LC_SOCKET', -1)
local SOCKET_ERROR    = -1
local SOL_SOCKET, SO_ERROR, SO_REUSEADDR, TCP_NODELAY = 0xFFFF, 0x1007, 0x0004, 1
local SO_SNDBUF, SO_RCVBUF = 0x1001, 0x1002
local SD_SEND         = 1

local E = {
  WOULDBLOCK = 10035, INPROGRESS = 10036, ALREADY = 10037, NOTSOCK = 10038,
  ADDRINUSE = 10048, CONNABORTED = 10053, CONNRESET = 10054, ISCONN = 10056,
  NOTCONN = 10057, SHUTDOWN = 10058, TIMEDOUT = 10060, CONNREFUSED = 10061,
  HOSTUNREACH = 10065,
}
local ENAME = {}
for k, v in pairs(E) do ENAME[v] = k end
socket.E = E

local function errstr(code)
  local n = ENAME[code]
  if n then return string.format('WSAE%s (%d)', n, code) end
  return string.format('WSA error %d', code)
end
socket.errstr = errstr

local function lastErr() return ws2.WSAGetLastError() end

-- --------------------------------------------------------------- startup ----
local started = false

function socket.init()
  if started then return true end
  local wsadata = ffi.new('char[?]', 512)
  local rc = ws2.WSAStartup(0x0202, wsadata) -- MAKEWORD(2,2)
  if rc ~= 0 then return nil, 'WSAStartup failed: ' .. tostring(rc) end
  started = true
  local sys = require('lib.sys')
  sys.atExit(function() socket.cleanup() end)
  return true
end

function socket.cleanup()
  if not started then return end
  started = false
  ws2.WSACleanup()
end

-- --------------------------------------------------------------- helpers ----
local function rawfd(x)
  if type(x) == 'table' then return x.sock end
  return x
end

local function fdnum(x)
  local f = rawfd(x)
  if f == nil then return nil end
  return tonumber(f)
end
socket.fdnum = fdnum

local function setNonBlocking(fd, on)
  local v = ffi.new('unsigned long[1]', on and 1 or 0)
  return ws2.ioctlsocket(fd, FIONBIO, v) == 0
end

local function sockaddrOf(netaddr, port)
  local sa = ffi.new('struct lc_sockaddr_in')
  sa.sin_family = AF_INET
  sa.sin_port = ws2.htons(port)
  sa.sin_addr.s_addr = netaddr
  return sa
end

--- Resolve host to a network-order IPv4 address (uint32 cdata).
function socket.resolve(host, port)
  socket.init()
  local hints = ffi.new('struct lc_addrinfo')
  hints.ai_family   = AF_INET
  hints.ai_socktype = SOCK_STREAM
  hints.ai_protocol = IPPROTO_TCP
  local res = ffi.new('struct lc_addrinfo*[1]')
  local rc = ws2.getaddrinfo(host, tostring(port or 0), hints, res)
  if rc ~= 0 or res[0] == nil then
    return nil, string.format('getaddrinfo(%s) failed: %s', tostring(host), errstr(rc))
  end
  local addr = ffi.cast('struct lc_sockaddr_in*', res[0].ai_addr).sin_addr.s_addr
  ws2.freeaddrinfo(res[0])
  return addr
end

--- Human-readable "a.b.c.d" for a network-order uint32.
function socket.ipString(netaddr)
  local n = tonumber(netaddr) % 0x100000000
  local b0 = n % 256
  local b1 = math.floor(n / 256) % 256
  local b2 = math.floor(n / 65536) % 256
  local b3 = math.floor(n / 16777216) % 256
  return string.format('%d.%d.%d.%d', b0, b1, b2, b3)
end

-- ---------------------------------------------------------- socket object ----
local Sock = {}
Sock.__index = Sock
socket.Sock = Sock

local recvBuf = ffi.new('char[65536]')

local function newSock(fd, state)
  return setmetatable({
    sock      = fd,
    state     = state or 'new',   -- new|connecting|connected|listening|closed|error
    outbox    = {},               -- queued chunks (head at obHead)
    obHead    = 1,
    obTail    = 0,
    obOff     = 0,                -- bytes of outbox[obHead] already written
    outboxLen = 0,
    bytesIn   = 0,
    bytesOut  = 0,
    err       = nil,
    onConnected = nil,            -- optional fn(ok, err), fired once
  }, Sock)
end

--- Create an unconnected non-blocking TCP socket.
function socket.tcp()
  local ok, err = socket.init()
  if not ok then return nil, err end
  local fd = ws2.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
  if fd == INVALID_SOCKET then return nil, 'socket(): ' .. errstr(lastErr()) end
  setNonBlocking(fd, true)
  local v = ffi.new('int[1]', 1)
  ws2.setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, ffi.cast('const char*', v), 4)
  return newSock(fd, 'new')
end

function Sock:fd() return self.sock end

function Sock:isClosed() return self.state == 'closed' end

--- Read SO_ERROR and settle a pending connect.  Returns true when connected.
function Sock:_settleConnect()
  if self.state ~= 'connecting' then return self.state == 'connected' end
  local v = ffi.new('int[1]', 0)
  local l = ffi.new('int[1]', 4)
  if ws2.getsockopt(self.sock, SOL_SOCKET, SO_ERROR, ffi.cast('char*', v), l) ~= 0 then
    self.state, self.err = 'error', 'getsockopt(SO_ERROR): ' .. errstr(lastErr())
  elseif v[0] == 0 then
    self.state = 'connected'
  else
    self.state, self.err = 'error', 'connect failed: ' .. errstr(tonumber(v[0]))
  end
  local cb = self.onConnected
  self.onConnected = nil
  if cb then pcall(cb, self.state == 'connected', self.err) end
  return self.state == 'connected'
end

--- Poll the pending connect without blocking (0 ms select on write+except).
function Sock:pollConnect()
  if self.state ~= 'connecting' then return self.state == 'connected' end
  local ready = socket.select(nil, { self }, 0, { self })
  if ready and (ready.w[fdnum(self)] or ready.e[fdnum(self)]) then
    return self:_settleConnect()
  end
  return false
end

function Sock:isConnected()
  if self.state == 'connecting' then self:pollConnect() end
  return self.state == 'connected'
end

--- Non-blocking connect. Returns true immediately (poll :isConnected()) or nil, err.
function Sock:connect(host, port)
  if self.state ~= 'new' then return nil, 'socket already used (state=' .. self.state .. ')' end
  local addr, err = socket.resolve(host, port)
  if not addr then return nil, err end
  self.peerHost, self.peerPort, self.addr = host, port, addr
  local sa = sockaddrOf(addr, port)
  if ws2.connect(self.sock, ffi.cast('struct lc_sockaddr*', sa), ffi.sizeof(sa)) == 0 then
    self.state = 'connected'
    local cb = self.onConnected; self.onConnected = nil
    if cb then pcall(cb, true, nil) end
    return true
  end
  local e = lastErr()
  if e == E.WOULDBLOCK or e == E.INPROGRESS or e == E.ALREADY then
    self.state = 'connecting'
    return true
  end
  if e == E.ISCONN then
    self.state = 'connected'
    return true
  end
  self.state, self.err = 'error', 'connect(): ' .. errstr(e)
  return nil, self.err
end

--- true while there is buffered output (or an unfinished connect) to wait on.
function Sock:wantWrite()
  return self.state == 'connecting' or (self.outboxLen > 0 and self.state == 'connected')
end

function Sock:pending() return self.outboxLen end

--- Push whatever the OS will take right now. Returns true when the outbox is empty,
--- false while data remains, or nil, err on a hard socket error.
function Sock:flush()
  if self.state == 'connecting' then
    if not self:_settleConnect() then
      if self.state == 'error' then return nil, self.err end
      return false
    end
  end
  if self.state ~= 'connected' then
    return nil, self.err or ('socket not connected (state=' .. self.state .. ')')
  end
  while self.obHead <= self.obTail do
    local chunk = self.outbox[self.obHead]
    local len = #chunk - self.obOff
    local p = ffi.cast('const char*', chunk) + self.obOff
    local n = ws2.send(self.sock, p, len, 0)
    if n == SOCKET_ERROR then
      local e = lastErr()
      if e == E.WOULDBLOCK then return false end
      self.err = 'send(): ' .. errstr(e)
      self.state = 'error'
      return nil, self.err
    end
    n = tonumber(n)
    self.outboxLen = self.outboxLen - n
    self.bytesOut  = self.bytesOut + n
    if n < len then
      self.obOff = self.obOff + n
      return false                      -- socket buffer full; wait for writability
    end
    self.outbox[self.obHead] = nil
    self.obHead = self.obHead + 1
    self.obOff = 0
  end
  self.obHead, self.obTail, self.obOff = 1, 0, 0
  return true
end

--- Queue str and push as much of it as the OS accepts. Never blocks.
--- Returns the number of bytes taken ownership of (== #str), or nil, err.
function Sock:send(str)
  if str == nil or #str == 0 then return 0 end
  if self.state == 'closed' or self.state == 'error' then
    return nil, self.err or 'socket closed'
  end
  if self.state == 'listening' then return nil, 'cannot send on a listening socket' end
  self.obTail = self.obTail + 1
  self.outbox[self.obTail] = str
  self.outboxLen = self.outboxLen + #str
  local ok, err = self:flush()
  if ok == nil then return nil, err end
  return #str
end

--- Read up to max bytes.
---   'str'        data
---   ''           nothing available yet (WSAEWOULDBLOCK)
---   nil,'closed' orderly peer shutdown
---   nil,err      real error
function Sock:recv(max)
  if self.state == 'closed' then return nil, 'closed' end
  if self.state == 'connecting' then
    self:_settleConnect()
    if self.state == 'connecting' then return '' end
    if self.state ~= 'connected' then return nil, self.err or 'connect failed' end
  end
  max = math.min(tonumber(max) or 65536, 65536)
  if max <= 0 then return '' end
  local n = tonumber(ws2.recv(self.sock, recvBuf, max, 0))
  if n > 0 then
    self.bytesIn = self.bytesIn + n
    return ffi.string(recvBuf, n)
  end
  if n == 0 then
    self.state = 'closed'
    return nil, 'closed'
  end
  local e = lastErr()
  if e == E.WOULDBLOCK then return '' end
  self.err = 'recv(): ' .. errstr(e)
  self.state = 'error'
  return nil, self.err
end

--- Set SO_SNDBUF / SO_RCVBUF (either may be nil).  Mostly a test hook: shrinking the
--- send buffer is the only reliable way to force partial sends on loopback.
function Sock:setBufferSize(sendBytes, recvBytes)
  local v = ffi.new('int[1]')
  if sendBytes then
    v[0] = sendBytes
    if ws2.setsockopt(self.sock, SOL_SOCKET, SO_SNDBUF, ffi.cast('const char*', v), 4) ~= 0 then
      return nil, 'SO_SNDBUF: ' .. errstr(lastErr())
    end
  end
  if recvBytes then
    v[0] = recvBytes
    if ws2.setsockopt(self.sock, SOL_SOCKET, SO_RCVBUF, ffi.cast('const char*', v), 4) ~= 0 then
      return nil, 'SO_RCVBUF: ' .. errstr(lastErr())
    end
  end
  return true
end

function Sock:shutdownSend()
  if self.sock and self.state ~= 'closed' then ws2.shutdown(self.sock, SD_SEND) end
end

function Sock:close()
  if self.sock and self.state ~= 'closed' then
    ws2.closesocket(self.sock)
  end
  self.state = 'closed'
  self.outbox, self.obHead, self.obTail, self.obOff, self.outboxLen = {}, 1, 0, 0, 0
  self.onConnected = nil
end

--- Local "ip:port" of a bound socket.
function Sock:localAddr()
  local sa = ffi.new('struct lc_sockaddr_in')
  local l  = ffi.new('int[1]', ffi.sizeof(sa))
  if ws2.getsockname(self.sock, ffi.cast('struct lc_sockaddr*', sa), l) ~= 0 then
    return nil, errstr(lastErr())
  end
  return socket.ipString(sa.sin_addr.s_addr), tonumber(ws2.ntohs(sa.sin_port))
end

function Sock:port()
  local _, p = self:localAddr()
  return p
end

--- Accept one pending connection on a listening socket.
---   sock       | nil,'wouldblock' (nothing pending) | nil, err
function Sock:accept()
  if self.state ~= 'listening' then return nil, 'not a listening socket' end
  local sa = ffi.new('struct lc_sockaddr_in')
  local l  = ffi.new('int[1]', ffi.sizeof(sa))
  local c  = ws2.accept(self.sock, ffi.cast('struct lc_sockaddr*', sa), l)
  if c == INVALID_SOCKET then
    local e = lastErr()
    if e == E.WOULDBLOCK then return nil, 'wouldblock' end
    return nil, 'accept(): ' .. errstr(e)
  end
  setNonBlocking(c, true)
  local v = ffi.new('int[1]', 1)
  ws2.setsockopt(c, IPPROTO_TCP, TCP_NODELAY, ffi.cast('const char*', v), 4)
  local s = newSock(c, 'connected')
  s.peerHost = socket.ipString(sa.sin_addr.s_addr)
  s.peerPort = tonumber(ws2.ntohs(sa.sin_port))
  return s
end

--- Bind + listen. port 0 asks the OS for an ephemeral port (read it back with :port()).
function socket.listen(host, port, backlog)
  local ok, err = socket.init()
  if not ok then return nil, err end
  local addr, aerr = socket.resolve(host or '127.0.0.1', port or 0)
  if not addr then return nil, aerr end
  local fd = ws2.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
  if fd == INVALID_SOCKET then return nil, 'socket(): ' .. errstr(lastErr()) end
  local sa = sockaddrOf(addr, port or 0)
  if ws2.bind(fd, ffi.cast('struct lc_sockaddr*', sa), ffi.sizeof(sa)) ~= 0 then
    local e = lastErr(); ws2.closesocket(fd)
    return nil, 'bind(): ' .. errstr(e)
  end
  if ws2.listen(fd, backlog or 8) ~= 0 then
    local e = lastErr(); ws2.closesocket(fd)
    return nil, 'listen(): ' .. errstr(e)
  end
  setNonBlocking(fd, true)
  local s = newSock(fd, 'listening')
  s.bindHost  = host or '127.0.0.1'
  s.boundPort = s:port()
  return s
end

-- ---------------------------------------------------------------- select ----
local rset = ffi.new('lc_fd_set')
local wset = ffi.new('lc_fd_set')
local eset = ffi.new('lc_fd_set')
local tval = ffi.new('struct lc_timeval')

local function fill(set, list)
  set.fd_count = 0
  if not list then return 0 end
  for i = 1, #list do
    local f = rawfd(list[i])
    if f ~= nil and set.fd_count < 64 then
      set.fd_array[set.fd_count] = f
      set.fd_count = set.fd_count + 1
    end
  end
  return tonumber(set.fd_count)
end

local function isSet(set, fd)
  for i = 0, tonumber(set.fd_count) - 1 do
    if set.fd_array[i] == fd then return true end
  end
  return false
end

--- select() over three lists.  Entries may be socket objects or raw SOCKET cdata.
--- Returns a readySet (see the header) or nil, err.
function socket.select(readFds, writeFds, timeoutMs, exceptFds)
  local nr = fill(rset, readFds)
  local nw = fill(wset, writeFds)
  local ne = fill(eset, exceptFds)
  local ready = { read = {}, write = {}, except = {}, r = {}, w = {}, e = {}, count = 0 }

  if nr + nw + ne == 0 then
    -- Winsock select() with three empty sets returns WSAEINVAL instead of sleeping.
    if timeoutMs and timeoutMs > 0 then require('lib.sys').sleepMs(timeoutMs) end
    return ready
  end

  local tv = nil
  if timeoutMs then
    if timeoutMs < 0 then timeoutMs = 0 end
    tval.tv_sec  = math.floor(timeoutMs / 1000)
    tval.tv_usec = math.floor((timeoutMs % 1000) * 1000)
    tv = tval
  end

  local n = ws2.select(0,
                       nr > 0 and rset or nil,
                       nw > 0 and wset or nil,
                       ne > 0 and eset or nil,
                       tv)
  if n == SOCKET_ERROR then
    return nil, 'select(): ' .. errstr(lastErr())
  end
  ready.count = tonumber(n)
  if ready.count == 0 then return ready end

  if readFds then
    for i = 1, #readFds do
      local f = rawfd(readFds[i])
      if f ~= nil and isSet(rset, f) then
        ready.read[#ready.read + 1] = readFds[i]
        ready.r[tonumber(f)] = true
      end
    end
  end
  if writeFds then
    for i = 1, #writeFds do
      local f = rawfd(writeFds[i])
      if f ~= nil and isSet(wset, f) then
        ready.write[#ready.write + 1] = writeFds[i]
        ready.w[tonumber(f)] = true
      end
    end
  end
  if exceptFds then
    for i = 1, #exceptFds do
      local f = rawfd(exceptFds[i])
      if f ~= nil and isSet(eset, f) then
        ready.except[#ready.except + 1] = exceptFds[i]
        ready.e[tonumber(f)] = true
      end
    end
  end
  return ready
end

return socket
