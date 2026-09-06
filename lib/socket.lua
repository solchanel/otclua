-- lib/socket.lua -- non-blocking TCP, Windows (ws2_32) and Linux (libc) from one
-- file.  No blocking calls anywhere: connect returns immediately, send never blocks
-- (an internal outbox absorbs whatever the OS did not accept and is drained on
-- writability by lib/sched.lua).
--
-- API (API.md) -- identical on both platforms:
--   socket.init()                        WSAStartup(2.2) / SIGPIPE guard, idempotent
--   local s = socket.tcp()
--   s:connect(host, port)                getaddrinfo + non-blocking connect
--                                        -> true (maybe still connecting) | nil, err
--   s:isConnected() -> bool              (polls SO_ERROR when still connecting)
--   s:send(str)     -> bytes | nil, err  never blocks; buffers the remainder
--   s:recv(max)     -> str | '' | nil,'closed' | nil, err
--   s:close()
--   s:fd()                               raw handle for select
--   socket.select(readFds, writeFds, timeoutMs [, exceptFds]) -> readySet | nil, err
--   socket.listen(host, port [, backlog]) -> listener ; listener:accept() -> sock|nil,err
--
-- `socket.select` keeps its name on BOTH platforms even though Linux implements it
-- with poll(2) -- the contract in API.md is the public surface, the syscall is not.
--
-- readySet shape (a single table, as the contract names it):
--   readySet.read / .write / .except  = arrays of the *entries the caller passed in*
--                                       (socket objects or raw fds) that are ready
--   readySet.r / .w / .e              = maps  tonumber(fd) -> true
-- Both socket objects and raw handles are accepted in the input lists.
--
-- ============================ platform differences ==========================
--                    | Windows                     | Linux
--   library          | ffi.load('ws2_32')          | ffi.C (libc)
--   startup          | WSAStartup(2.2)             | none (+ SIGPIPE -> SIG_IGN)
--   handle           | SOCKET = uintptr_t, bad=~0  | int fd, bad = -1
--   close            | closesocket()               | close()
--   non-blocking     | ioctlsocket(FIONBIO, 1)     | fcntl(F_SETFL, |O_NONBLOCK)
--   last error       | WSAGetLastError()           | errno (ffi.errno())
--   would block      | WSAEWOULDBLOCK 10035        | EAGAIN 11
--   connect pending  | WSAEWOULDBLOCK 10035        | EINPROGRESS 115
--   interrupted      | never                       | EINTR 4 -> retry the call
--   readiness        | select() + fd_set{n,SOCKET[64]} | poll() (no FD_SETSIZE cap)
--   failed connect   | reported in exceptfds ONLY  | POLLOUT (+POLLERR/POLLHUP)
--                    |                             | then getsockopt(SO_ERROR)
--   addrinfo layout  | ai_canonname BEFORE ai_addr | ai_addr BEFORE ai_canonname
--   SIGPIPE on send  | n/a                         | send(..., MSG_NOSIGNAL)
--   SOL_SOCKET       | 0xFFFF                      | 1
--
-- Gotchas honoured here (docs/lua-runtime.md + its VERIFIER corrections):
--   * a Windows SOCKET is uintptr_t cdata -- NEVER a table key; always tonumber(fd).
--   * a FAILED non-blocking connect is reported in *exceptfds* on Windows, never in
--     writefds, so connect-pending sockets are always placed in the except set too.
--     On Linux the same socket becomes POLLOUT-ready (usually with POLLERR|POLLHUP)
--     and the verdict comes from getsockopt(SO_ERROR) -- the same _settleConnect()
--     code path drives both.
--   * Winsock select() with all three sets empty returns WSAEINVAL instead of
--     sleeping; socket.select() falls back to a plain sleep in that case (Linux's
--     poll(NULL,0,ms) would sleep correctly, but the uniform path is simpler).
--   * struct timeval uses 32-bit long on Windows; fd_set is {count, SOCKET[64]},
--     not a bitmask.
--   * send() returning WOULDBLOCK after 0 bytes is NOT an error -- the ambiguous
--     "return total, 'partial'" contract from the sketch is not used; :send() reports
--     the full byte count it took ownership of and queues the rest.

local ffi = require('ffi')
local bit = require('bit')

local socket = {}

local IS_WINDOWS = (ffi.os == 'Windows')
local IS_LINUX   = (ffi.os == 'Linux')
if not (IS_WINDOWS or IS_LINUX) then
  error('lib/socket.lua: unsupported platform ' .. tostring(ffi.os))
end
socket.os = ffi.os

-- ffi.cdef is process-global; declare one item at a time and never a symbol that
-- belongs to the other OS.
local function cdef(s) pcall(ffi.cdef, s) end

-- sockaddr / sockaddr_in are byte-identical on both platforms, so they are shared.
cdef [[ struct lc_sockaddr    { unsigned short sa_family; char sa_data[14]; }; ]]
cdef [[ struct lc_in_addr     { unsigned int s_addr; }; ]]
cdef [[ struct lc_sockaddr_in { unsigned short sin_family; unsigned short sin_port;
                                struct lc_in_addr sin_addr; char sin_zero[8]; }; ]]

local AF_INET, SOCK_STREAM, IPPROTO_TCP = 2, 1, 6

local P = {}            -- the platform layer: everything below it is shared code
local E                 -- error-number table (per platform)

-- ======================================================== Windows ===========
if IS_WINDOWS then

  cdef [[ typedef uintptr_t LC_SOCKET; ]]
  cdef [[ struct lc_timeval { long tv_sec; long tv_usec; }; ]]
  cdef [[ typedef struct lc_fd_set { unsigned int fd_count; LC_SOCKET fd_array[64]; } lc_fd_set; ]]
  -- Windows addrinfo: ai_canonname comes BEFORE ai_addr (reverse of glibc).
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
  -- kernel32 for the handle-inheritance flags; ffi.C already resolves them in a
  -- LuaJIT built against msvcrt, but loading the DLL explicitly is what makes
  -- this work under every toolchain.
  cdef [[ int SetHandleInformation(void*, unsigned long, unsigned long); ]]
  cdef [[ int GetHandleInformation(void*, unsigned long*); ]]
  local k32 = ffi.load('kernel32')
  local k32NoInherit          = k32.SetHandleInformation
  local k32GetHandleInformation = k32.GetHandleInformation

  local FIONBIO = -2147195266     -- 0x8004667E as a signed long
  local SD_SEND = 1

  P.INVALID = ffi.cast('LC_SOCKET', -1)
  P.SOL_SOCKET, P.SO_ERROR    = 0xFFFF, 0x1007
  P.SO_REUSEADDR              = 0x0004
  P.SO_SNDBUF, P.SO_RCVBUF    = 0x1001, 0x1002
  P.IPPROTO_TCP, P.TCP_NODELAY = IPPROTO_TCP, 1

  E = {
    WOULDBLOCK = 10035, INPROGRESS = 10036, ALREADY = 10037, NOTSOCK = 10038,
    ADDRINUSE = 10048, CONNABORTED = 10053, CONNRESET = 10054, ISCONN = 10056,
    NOTCONN = 10057, SHUTDOWN = 10058, TIMEDOUT = 10060, CONNREFUSED = 10061,
    HOSTUNREACH = 10065, INTR = -1,   -- Windows never reports EINTR
  }

  P.errPrefix = 'WSAE'

  function P.lastErr() return ws2.WSAGetLastError() end

  function P.startup()
    local wsadata = ffi.new('char[?]', 512)
    local rc = ws2.WSAStartup(0x0202, wsadata)          -- MAKEWORD(2,2)
    if rc ~= 0 then return nil, 'WSAStartup failed: ' .. tostring(rc) end
    return true
  end

  function P.cleanup() ws2.WSACleanup() end

  -- A Winsock SOCKET is a kernel handle and is INHERITABLE by default, and
  -- lib/process.lua calls CreateProcess with bInheritHandles = TRUE (it has to,
  -- to hand the child its three std pipes).  Every socket this process holds
  -- would therefore be duplicated into every worker: the hub's listener (so an
  -- orphan keeps the port bound) and every accepted panel connection -- and a
  -- browser waiting for `Connection: close` then sees no EOF until the WORKER
  -- exits, because the child still holds a copy of the socket.  Clearing
  -- HANDLE_FLAG_INHERIT is the Windows counterpart of SOCK_CLOEXEC.
  local HANDLE_FLAG_INHERIT = 0x1
  local function noInherit(fd)
    if fd == nil then return fd end
    pcall(function()
      k32NoInherit(ffi.cast('void*', fd), HANDLE_FLAG_INHERIT, 0)
    end)
    return fd
  end

  --- Is this socket handle marked inheritable?  Exported so a test can assert
  --- the invariant instead of trusting that the flag was cleared.
  function P.isCloexec(fd)
    if fd == nil then return nil end
    local out = ffi.new('unsigned long[1]')
    local ok = pcall(function()
      return k32GetHandleInformation(ffi.cast('void*', fd), out)
    end)
    if not ok then return nil end
    return bit.band(tonumber(out[0]), HANDLE_FLAG_INHERIT) == 0
  end

  -- NOTE on error codes: WSAGetLastError() IS GetLastError(), so a
  -- SetHandleInformation call on a failed accept would overwrite WSAEWOULDBLOCK
  -- with ERROR_INVALID_HANDLE and the accept loop would treat "nothing pending"
  -- as a fatal error.  Only ever touch the flag on a handle we really got.
  function P.socket()
    local s = ws2.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    if s ~= P.INVALID then noInherit(s) end
    return s
  end
  function P.close(fd) return ws2.closesocket(fd) end
  function P.connect(fd, sa, len) return ws2.connect(fd, ffi.cast('struct lc_sockaddr*', sa), len) end
  function P.bind(fd, sa, len) return ws2.bind(fd, ffi.cast('struct lc_sockaddr*', sa), len) end
  function P.listen(fd, backlog) return ws2.listen(fd, backlog) end
  function P.shutdownSend(fd) return ws2.shutdown(fd, SD_SEND) end
  function P.htons(v) return ws2.htons(v) end
  function P.ntohs(v) return tonumber(ws2.ntohs(v)) end

  function P.accept(fd, sa)
    local l = ffi.new('int[1]', ffi.sizeof('struct lc_sockaddr_in'))
    -- accept() does not inherit the listener's flag: clear it on the child too,
    -- but ONLY when there really is one (see the error-code note above).
    local c = ws2.accept(fd, ffi.cast('struct lc_sockaddr*', sa), l)
    if c ~= P.INVALID then noInherit(c) end
    return c
  end

  function P.getsockname(fd, sa)
    local l = ffi.new('int[1]', ffi.sizeof('struct lc_sockaddr_in'))
    return ws2.getsockname(fd, ffi.cast('struct lc_sockaddr*', sa), l)
  end

  function P.send(fd, ptr, len) return tonumber(ws2.send(fd, ptr, len, 0)) end
  function P.recv(fd, buf, len) return tonumber(ws2.recv(fd, buf, len, 0)) end

  function P.setNonBlocking(fd)
    local v = ffi.new('unsigned long[1]', 1)
    return ws2.ioctlsocket(fd, FIONBIO, v) == 0
  end

  function P.setsockoptInt(fd, level, opt, value)
    local v = ffi.new('int[1]', value)
    return ws2.setsockopt(fd, level, opt, ffi.cast('const char*', v), 4) == 0
  end

  function P.getsockoptInt(fd, level, opt)
    local v = ffi.new('int[1]', 0)
    local l = ffi.new('int[1]', 4)
    if ws2.getsockopt(fd, level, opt, ffi.cast('char*', v), l) ~= 0 then return nil end
    return tonumber(v[0])
  end

  function P.resolve(host, port)
    local hints = ffi.new('struct lc_addrinfo')
    hints.ai_family   = AF_INET
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    local res = ffi.new('struct lc_addrinfo*[1]')
    local rc = ws2.getaddrinfo(host, tostring(port or 0), hints, res)
    if rc ~= 0 or res[0] == nil then
      return nil, string.format('getaddrinfo(%s) failed: %s', tostring(host), socket.errstr(rc))
    end
    local addr = ffi.cast('struct lc_sockaddr_in*', res[0].ai_addr).sin_addr.s_addr
    ws2.freeaddrinfo(res[0])
    return addr
  end

  ------------------------------------------------------------------ select ----
  local rset = ffi.new('lc_fd_set')
  local wset = ffi.new('lc_fd_set')
  local eset = ffi.new('lc_fd_set')
  local tval = ffi.new('struct lc_timeval')

  local function fill(set, list, rawfd)
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

  --- Wait for readiness. Returns count, isReady(kind, rawfd) or nil, err.
  function P.wait(readFds, writeFds, exceptFds, timeoutMs, rawfd)
    local nr = fill(rset, readFds, rawfd)
    local nw = fill(wset, writeFds, rawfd)
    local ne = fill(eset, exceptFds, rawfd)

    local tv = nil
    if timeoutMs then
      if timeoutMs < 0 then timeoutMs = 0 end
      tval.tv_sec  = math.floor(timeoutMs / 1000)
      tval.tv_usec = math.floor((timeoutMs % 1000) * 1000)
      tv = tval
    end

    local n = ws2.select(0, nr > 0 and rset or nil, nw > 0 and wset or nil,
                         ne > 0 and eset or nil, tv)
    if n == -1 then return nil, 'select(): ' .. socket.errstr(P.lastErr()) end
    return tonumber(n), function(kind, fd)
      if kind == 'r' then return isSet(rset, fd) end
      if kind == 'w' then return isSet(wset, fd) end
      return isSet(eset, fd)
    end
  end

-- ========================================================== Linux ===========
else

  cdef [[ typedef int LC_SOCKET; ]]
  cdef [[ struct lc_pollfd { int fd; short events; short revents; }; ]]
  -- glibc addrinfo: ai_addr comes BEFORE ai_canonname (reverse of Windows), and
  -- ai_addrlen is a 32-bit socklen_t (the following pointer re-aligns to 8).
  cdef [[ struct lc_addrinfo { int ai_flags; int ai_family; int ai_socktype; int ai_protocol;
                               unsigned int ai_addrlen;
                               struct lc_sockaddr *ai_addr; char *ai_canonname;
                               struct lc_addrinfo *ai_next; }; ]]
  cdef [[ int     socket(int,int,int); ]]
  cdef [[ int     close(int); ]]
  cdef [[ int     connect(int, const struct lc_sockaddr*, unsigned int); ]]
  cdef [[ int     bind(int, const struct lc_sockaddr*, unsigned int); ]]
  cdef [[ int     listen(int, int); ]]
  cdef [[ int     accept(int, struct lc_sockaddr*, unsigned int*); ]]
  cdef [[ int     getsockname(int, struct lc_sockaddr*, unsigned int*); ]]
  cdef [[ long    send(int, const void*, size_t, int); ]]
  cdef [[ long    recv(int, void*, size_t, int); ]]
  cdef [[ int     fcntl(int, int, ...); ]]
  cdef [[ int     setsockopt(int,int,int,const void*,unsigned int); ]]
  cdef [[ int     getsockopt(int,int,int,void*,unsigned int*); ]]
  cdef [[ int     poll(struct lc_pollfd*, unsigned long, int); ]]
  cdef [[ int     shutdown(int,int); ]]
  cdef [[ unsigned short htons(unsigned short); ]]
  cdef [[ unsigned short ntohs(unsigned short); ]]
  cdef [[ int     getaddrinfo(const char*, const char*, const struct lc_addrinfo*,
                              struct lc_addrinfo**); ]]
  cdef [[ void    freeaddrinfo(struct lc_addrinfo*); ]]
  cdef [[ const char *gai_strerror(int); ]]
  cdef [[ void   *signal(int, void*); ]]

  local C = ffi.C

  local F_GETFL, F_SETFL, O_NONBLOCK = 3, 4, 0x800   -- O_NONBLOCK == 04000 octal
  -- CLOEXEC: a descriptor this module hands out must NOT survive into a child
  -- the process forks later.  A hub that spawns workers would otherwise give
  -- every worker its listening socket (an orphan then holds the port and the
  -- next hub start fails with EADDRINUSE) and every accepted client socket.
  -- lib/process.lua also sweeps fds > 2 in the child; this is the half that
  -- works even when the fork happens somewhere else entirely.
  local F_GETFD, F_SETFD, FD_CLOEXEC = 1, 2, 1
  local SOCK_CLOEXEC = 0x80000        -- 02000000 octal, Linux socket()/accept4()
  local MSG_NOSIGNAL = 0x4000
  local SHUT_WR      = 1
  local SIGPIPE, SIG_IGN = 13, ffi.cast('void*', 1)

  local POLLIN, POLLOUT   = 0x001, 0x004
  local POLLERR, POLLHUP  = 0x008, 0x010
  local POLLNVAL          = 0x020

  P.INVALID = -1
  P.SOL_SOCKET, P.SO_ERROR    = 1, 4
  P.SO_REUSEADDR              = 2
  P.SO_SNDBUF, P.SO_RCVBUF    = 7, 8
  P.IPPROTO_TCP, P.TCP_NODELAY = IPPROTO_TCP, 1

  E = {
    WOULDBLOCK = 11,  INPROGRESS = 115, ALREADY = 114, NOTSOCK = 88,
    ADDRINUSE = 98,   CONNABORTED = 103, CONNRESET = 104, ISCONN = 106,
    NOTCONN = 107,    SHUTDOWN = 108,   TIMEDOUT = 110, CONNREFUSED = 111,
    HOSTUNREACH = 113, INTR = 4, PIPE = 32, AGAIN = 11,
  }

  P.errPrefix = 'E'

  function P.lastErr() return ffi.errno() end

  function P.startup()
    -- MSG_NOSIGNAL is passed on every send(), but a stray SIGPIPE from anywhere
    -- else (a library, a pipe) would still kill the process; ignore it once.
    C.signal(SIGPIPE, SIG_IGN)
    return true
  end

  function P.cleanup() end

  --- Set FD_CLOEXEC on an already-open descriptor.  Used as the fallback when
  --- SOCK_CLOEXEC is not honoured (a pre-2.6.27 kernel answers EINVAL) and after
  --- accept(), whose portable form has no flags argument.  Best effort: a failure
  --- here is not worth losing the connection over, and lib/process.lua's own
  --- post-fork sweep still closes it.
  local function setCloexec(fd)
    if fd == nil or fd < 0 then return fd end
    local fl = C.fcntl(fd, F_GETFD, ffi.cast('long', 0))
    if fl < 0 then fl = 0 end
    C.fcntl(fd, F_SETFD, ffi.cast('long', bit.bor(fl, FD_CLOEXEC)))
    return fd
  end
  P._setCloexec = setCloexec

  --- Is FD_CLOEXEC set?  Exported so a test can assert the invariant rather than
  --- trusting that the flag was requested.
  function P.isCloexec(fd)
    if fd == nil or fd < 0 then return nil end
    local fl = tonumber(C.fcntl(fd, F_GETFD, ffi.cast('long', 0)))
    if not fl or fl < 0 then return nil end
    return bit.band(fl, FD_CLOEXEC) ~= 0
  end

  function P.socket()
    -- SOCK_CLOEXEC closes the race a separate fcntl() leaves open (a fork in
    -- another thread between the two calls inherits the descriptor).  Older
    -- kernels reject the flag with EINVAL; fall back and set it explicitly.
    local fd = C.socket(AF_INET, bit.bor(SOCK_STREAM, SOCK_CLOEXEC), IPPROTO_TCP)
    if fd < 0 then
      fd = C.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
      if fd >= 0 then setCloexec(fd) end
      return fd
    end
    -- A kernel that ignored the flag rather than failing still has to be covered.
    if P.isCloexec(fd) == false then setCloexec(fd) end
    return fd
  end
  function P.close(fd) return C.close(fd) end
  function P.connect(fd, sa, len) return C.connect(fd, ffi.cast('struct lc_sockaddr*', sa), len) end
  function P.bind(fd, sa, len) return C.bind(fd, ffi.cast('struct lc_sockaddr*', sa), len) end
  function P.listen(fd, backlog) return C.listen(fd, backlog) end
  function P.shutdownSend(fd) return C.shutdown(fd, SHUT_WR) end
  function P.htons(v) return C.htons(v) end
  function P.ntohs(v) return tonumber(C.ntohs(v)) end

  function P.accept(fd, sa)
    local l = ffi.new('unsigned int[1]', ffi.sizeof('struct lc_sockaddr_in'))
    local c
    repeat
      c = C.accept(fd, ffi.cast('struct lc_sockaddr*', sa), l)
    until c >= 0 or ffi.errno() ~= E.INTR
    -- accept() does NOT inherit the listener's FD_CLOEXEC, so an accepted panel
    -- or control connection would otherwise land in the next worker we spawn.
    if c >= 0 then setCloexec(c) end
    return c
  end

  function P.getsockname(fd, sa)
    local l = ffi.new('unsigned int[1]', ffi.sizeof('struct lc_sockaddr_in'))
    return C.getsockname(fd, ffi.cast('struct lc_sockaddr*', sa), l)
  end

  function P.send(fd, ptr, len)
    local n
    repeat
      n = tonumber(C.send(fd, ptr, len, MSG_NOSIGNAL))
    until n >= 0 or ffi.errno() ~= E.INTR
    return n
  end

  function P.recv(fd, buf, len)
    local n
    repeat
      n = tonumber(C.recv(fd, buf, len, 0))
    until n >= 0 or ffi.errno() ~= E.INTR
    return n
  end

  function P.setNonBlocking(fd)
    local fl = C.fcntl(fd, F_GETFL, ffi.cast('long', 0))
    if fl < 0 then fl = 0 end
    return C.fcntl(fd, F_SETFL, ffi.cast('long', bit.bor(fl, O_NONBLOCK))) ~= -1
  end

  function P.setsockoptInt(fd, level, opt, value)
    local v = ffi.new('int[1]', value)
    return C.setsockopt(fd, level, opt, v, 4) == 0
  end

  function P.getsockoptInt(fd, level, opt)
    local v = ffi.new('int[1]', 0)
    local l = ffi.new('unsigned int[1]', 4)
    if C.getsockopt(fd, level, opt, v, l) ~= 0 then return nil end
    return tonumber(v[0])
  end

  function P.resolve(host, port)
    local hints = ffi.new('struct lc_addrinfo')
    hints.ai_family   = AF_INET
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    local res = ffi.new('struct lc_addrinfo*[1]')
    local rc = C.getaddrinfo(host, tostring(port or 0), hints, res)
    if rc ~= 0 or res[0] == nil then
      local msg = rc ~= 0 and ffi.string(C.gai_strerror(rc)) or 'no address returned'
      return nil, string.format('getaddrinfo(%s) failed: %s (%d)', tostring(host), msg, rc)
    end
    local addr = ffi.cast('struct lc_sockaddr_in*', res[0].ai_addr).sin_addr.s_addr
    C.freeaddrinfo(res[0])
    return addr
  end

  -------------------------------------------------------------------- poll ----
  -- One growable pollfd array, one fd -> slot map, both reused every turn.
  local pfds, pcap = nil, 0
  local slot, revents = {}, {}

  local function grow(n)
    if n <= pcap then return end
    local cap = pcap > 0 and pcap or 16
    while cap < n do cap = cap * 2 end
    pfds, pcap = ffi.new('struct lc_pollfd[?]', cap), cap
  end

  local function addEvents(list, mask, rawfd, order)
    if not list then return end
    for i = 1, #list do
      local f = rawfd(list[i])
      if f ~= nil then
        local k = tonumber(f)
        local s = slot[k]
        if s == nil then
          order[#order + 1] = k
          slot[k] = { fd = k, ev = mask }
        else
          s.ev = bit.bor(s.ev, mask)
        end
      end
    end
  end

  --- Wait for readiness with poll(2). Returns count, isReady(kind, rawfd) or nil,err.
  function P.wait(readFds, writeFds, exceptFds, timeoutMs, rawfd)
    for k in pairs(slot) do slot[k] = nil end
    for k in pairs(revents) do revents[k] = nil end
    local order = {}
    addEvents(readFds,   POLLIN,  rawfd, order)
    addEvents(writeFds,  POLLOUT, rawfd, order)
    -- exceptFds needs no event bit at all: POLLERR/POLLHUP/POLLNVAL are always
    -- reported in revents, whatever was requested.  That is the Linux replacement
    -- for Winsock's exceptfds, and it is why a failed connect surfaces here too.
    addEvents(exceptFds, 0,       rawfd, order)

    local n = #order
    grow(n > 0 and n or 1)
    for i = 1, n do
      local s = slot[order[i]]
      pfds[i - 1].fd      = s.fd
      pfds[i - 1].events  = s.ev
      pfds[i - 1].revents = 0
    end

    local timeout = timeoutMs and math.floor(timeoutMs < 0 and 0 or timeoutMs) or -1
    local rc
    repeat
      rc = C.poll(pfds, n, timeout)
      -- EINTR: poll was cut short by a signal; the caller's deadline is a hint,
      -- so retrying with the same timeout is correct (and this process ignores
      -- the only signal it can expect, SIGPIPE).
    until rc >= 0 or ffi.errno() ~= E.INTR
    if rc < 0 then
      return nil, 'poll(): ' .. socket.errstr(P.lastErr())
    end

    for i = 1, n do
      local re = tonumber(pfds[i - 1].revents)
      if re ~= 0 then revents[tonumber(pfds[i - 1].fd)] = re end
    end

    return rc, function(kind, fd)
      local re = revents[tonumber(fd)]
      if not re then return false end
      if kind == 'r' then
        -- POLLHUP means "peer closed": recv() must run to see the EOF.
        return bit.band(re, bit.bor(POLLIN, POLLHUP)) ~= 0
      elseif kind == 'w' then
        -- A failed non-blocking connect reports POLLOUT|POLLERR|POLLHUP; the
        -- verdict itself comes from getsockopt(SO_ERROR) in _settleConnect().
        return bit.band(re, bit.bor(POLLOUT, POLLERR, POLLHUP)) ~= 0
      end
      return bit.band(re, bit.bor(POLLERR, POLLHUP, POLLNVAL)) ~= 0
    end
  end
end

-- ============================================ shared: errors and helpers =====
local ENAME = {}
for k, v in pairs(E) do if v >= 0 then ENAME[v] = k end end
socket.E = E

function socket.errstr(code)
  code = tonumber(code) or -1
  local n = ENAME[code]
  if n then return string.format('%s%s (%d)', P.errPrefix, n, code) end
  if IS_WINDOWS then return string.format('WSA error %d', code) end
  return string.format('errno %d', code)
end
local errstr = socket.errstr

local function lastErr() return P.lastErr() end

-- --------------------------------------------------------------- startup ----
local started = false

function socket.init()
  if started then return true end
  local ok, err = P.startup()
  if not ok then return nil, err end
  started = true
  local sys = require('lib.sys')
  sys.atExit(function() socket.cleanup() end)
  return true
end

function socket.cleanup()
  if not started then return end
  started = false
  P.cleanup()
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

--- Is this socket's descriptor marked close-on-exec?  POSIX only; nil elsewhere
--- (Windows handles are not inherited unless a spawn explicitly asks, which
--- lib/process.lua's Windows backend does only for the three std pipes).
function socket.isCloexec(x)
  if not P.isCloexec then return nil end
  local f = fdnum(x)
  if f == nil then return nil end
  return P.isCloexec(f)
end

local function sockaddrOf(netaddr, port)
  local sa = ffi.new('struct lc_sockaddr_in')
  sa.sin_family = AF_INET
  sa.sin_port = P.htons(port)
  sa.sin_addr.s_addr = netaddr
  return sa
end

--- Resolve host to a network-order IPv4 address (uint32 cdata).
function socket.resolve(host, port)
  socket.init()
  return P.resolve(host, port)
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

local function isInvalid(fd)
  if IS_WINDOWS then return fd == P.INVALID end
  return tonumber(fd) < 0
end

--- Create an unconnected non-blocking TCP socket.
function socket.tcp()
  local ok, err = socket.init()
  if not ok then return nil, err end
  local fd = P.socket()
  if isInvalid(fd) then return nil, 'socket(): ' .. errstr(lastErr()) end
  P.setNonBlocking(fd)
  P.setsockoptInt(fd, P.IPPROTO_TCP, P.TCP_NODELAY, 1)
  return newSock(fd, 'new')
end

function Sock:fd() return self.sock end

function Sock:isClosed() return self.state == 'closed' end

--- Read SO_ERROR and settle a pending connect.  Returns true when connected.
function Sock:_settleConnect()
  if self.state ~= 'connecting' then return self.state == 'connected' end
  local e = P.getsockoptInt(self.sock, P.SOL_SOCKET, P.SO_ERROR)
  if e == nil then
    self.state, self.err = 'error', 'getsockopt(SO_ERROR): ' .. errstr(lastErr())
  elseif e == 0 then
    self.state = 'connected'
  else
    self.state, self.err = 'error', 'connect failed: ' .. errstr(e)
  end
  local cb = self.onConnected
  self.onConnected = nil
  if cb then pcall(cb, self.state == 'connected', self.err) end
  return self.state == 'connected'
end

--- Poll the pending connect without blocking (0 ms wait on write+except).
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
  local rc
  repeat
    rc = P.connect(self.sock, sa, ffi.sizeof(sa))
  until rc == 0 or lastErr() ~= E.INTR
  if rc == 0 then
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
    local n = P.send(self.sock, p, len)
    if n < 0 then
      local e = lastErr()
      if e == E.WOULDBLOCK then return false end
      self.err = 'send(): ' .. errstr(e)
      self.state = 'error'
      return nil, self.err
    end
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
---   ''           nothing available yet (EWOULDBLOCK / WSAEWOULDBLOCK)
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
  local n = P.recv(self.sock, recvBuf, max)
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
  if sendBytes then
    if not P.setsockoptInt(self.sock, P.SOL_SOCKET, P.SO_SNDBUF, sendBytes) then
      return nil, 'SO_SNDBUF: ' .. errstr(lastErr())
    end
  end
  if recvBytes then
    if not P.setsockoptInt(self.sock, P.SOL_SOCKET, P.SO_RCVBUF, recvBytes) then
      return nil, 'SO_RCVBUF: ' .. errstr(lastErr())
    end
  end
  return true
end

function Sock:shutdownSend()
  if self.sock and self.state ~= 'closed' then P.shutdownSend(self.sock) end
end

function Sock:close()
  if self.sock and self.state ~= 'closed' then
    P.close(self.sock)
  end
  self.state = 'closed'
  self.outbox, self.obHead, self.obTail, self.obOff, self.outboxLen = {}, 1, 0, 0, 0
  self.onConnected = nil
end

--- Local "ip:port" of a bound socket.
function Sock:localAddr()
  local sa = ffi.new('struct lc_sockaddr_in')
  if P.getsockname(self.sock, sa) ~= 0 then
    return nil, errstr(lastErr())
  end
  return socket.ipString(sa.sin_addr.s_addr), P.ntohs(sa.sin_port)
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
  local c  = P.accept(self.sock, sa)
  if isInvalid(c) then
    local e = lastErr()
    if e == E.WOULDBLOCK then return nil, 'wouldblock' end
    return nil, 'accept(): ' .. errstr(e)
  end
  P.setNonBlocking(c)
  P.setsockoptInt(c, P.IPPROTO_TCP, P.TCP_NODELAY, 1)
  local s = newSock(c, 'connected')
  s.peerHost = socket.ipString(sa.sin_addr.s_addr)
  s.peerPort = P.ntohs(sa.sin_port)
  return s
end

--- Bind + listen. port 0 asks the OS for an ephemeral port (read it back with :port()).
function socket.listen(host, port, backlog)
  local ok, err = socket.init()
  if not ok then return nil, err end
  local addr, aerr = socket.resolve(host or '127.0.0.1', port or 0)
  if not addr then return nil, aerr end
  local fd = P.socket()
  if isInvalid(fd) then return nil, 'socket(): ' .. errstr(lastErr()) end
  if IS_LINUX then
    -- Linux leaves the port in TIME_WAIT after a close; Windows SO_REUSEADDR has
    -- completely different (hijacking) semantics, so it is set on Linux only.
    P.setsockoptInt(fd, P.SOL_SOCKET, P.SO_REUSEADDR, 1)
  end
  local sa = sockaddrOf(addr, port or 0)
  if P.bind(fd, sa, ffi.sizeof(sa)) ~= 0 then
    local e = lastErr(); P.close(fd)
    return nil, 'bind(): ' .. errstr(e)
  end
  if P.listen(fd, backlog or 8) ~= 0 then
    local e = lastErr(); P.close(fd)
    return nil, 'listen(): ' .. errstr(e)
  end
  P.setNonBlocking(fd)
  local s = newSock(fd, 'listening')
  s.bindHost  = host or '127.0.0.1'
  s.boundPort = s:port()
  return s
end

-- ---------------------------------------------------------------- select ----
--- Readiness over three lists.  Entries may be socket objects or raw handles.
--- Windows uses select(), Linux uses poll(); the contract is identical.
--- Returns a readySet (see the header) or nil, err.
function socket.select(readFds, writeFds, timeoutMs, exceptFds)
  -- Count entries that actually carry a handle: a list of closed sockets is the
  -- same as an empty list, and handing Winsock three empty sets is an error.
  local function usable(list)
    if not list then return 0 end
    local n = 0
    for i = 1, #list do if rawfd(list[i]) ~= nil then n = n + 1 end end
    return n
  end
  local nr, nw, ne = usable(readFds), usable(writeFds), usable(exceptFds)
  local ready = { read = {}, write = {}, except = {}, r = {}, w = {}, e = {}, count = 0 }

  if nr + nw + ne == 0 then
    -- Winsock select() with three empty sets returns WSAEINVAL instead of sleeping
    -- (poll(NULL,0,ms) would sleep, but one path for both keeps the semantics equal).
    if timeoutMs and timeoutMs > 0 then require('lib.sys').sleepMs(timeoutMs) end
    return ready
  end

  local n, isReady = P.wait(readFds, writeFds, exceptFds, timeoutMs, rawfd)
  if n == nil then return nil, isReady end
  ready.count = n
  if n == 0 then return ready end

  if readFds then
    for i = 1, #readFds do
      local f = rawfd(readFds[i])
      if f ~= nil and isReady('r', f) then
        ready.read[#ready.read + 1] = readFds[i]
        ready.r[tonumber(f)] = true
      end
    end
  end
  if writeFds then
    for i = 1, #writeFds do
      local f = rawfd(writeFds[i])
      if f ~= nil and isReady('w', f) then
        ready.write[#ready.write + 1] = writeFds[i]
        ready.w[tonumber(f)] = true
      end
    end
  end
  if exceptFds then
    for i = 1, #exceptFds do
      local f = rawfd(exceptFds[i])
      if f ~= nil and isReady('e', f) then
        ready.except[#ready.except + 1] = exceptFds[i]
        ready.e[tonumber(f)] = true
      end
    end
  end
  return ready
end

return socket
