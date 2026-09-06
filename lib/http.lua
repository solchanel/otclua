--[[ lib/http.lua — HTTPS POST for the login flow.  Windows + Linux.

  API (see API.md):
      http.post(url, headersTable, body [, opts]) -> {status=, body=, headers=} | nil, err
      http.backend()  -> 'winhttp' | 'curl-ffi' | 'curl-cli' | nil, err
                         the backend actually selected on this machine

      http.postAsync(url, headers, body, opts, cb)   -> handle | nil, err
      http.runAsync(fn, done)                        -> the coroutine it made

  ============================================================================
  WHY THERE IS AN ASYNC PATH
  ============================================================================
  Every backend below is BLOCKING, and the login POST is allowed 20 s.  In the
  worker that is 20 s in which lib/sched.lua does not turn: no status pushes to
  the panel, no bot tick, no keepalive, for EVERY instance in that process.
  Measured on a socket that accepts and never answers, the reactor's longest gap
  between two 10 ms timer ticks was 2033 ms for a 2 s POST -- i.e. the whole
  request.

  There is no non-blocking TLS client here to switch to, so the request is moved
  out of the process instead: `http.postAsync` spawns a short-lived child
  (`luajit lib/http.lua --http-post-child`, this very file), hands it the whole
  request on STDIN and reads one framed answer line back from its stdout, driven
  by lib/process.lua and a sched timer.  Nothing blocks; the same measurement
  drops to 26 ms, which is the child spawn on the reactor turn that starts it.

  `http.post` itself is UNCHANGED for every existing caller: it still blocks and
  still returns the response.  It only takes the async route when it is running
  inside a coroutine that `http.runAsync` created -- an explicit opt-in by a
  caller that has said it can handle being suspended (control/server.lua runs
  every worker command that way, which is what un-blocks `login`).  Yielding out
  of a pcall is a LuaJIT extension and is exactly what this relies on.

  The child gets the request on stdin -- URL, headers, timeout, backend, proxy
  credential and body -- because the body carries the account password and argv
  does not keep secrets (lib/process.lua, "SECRETS IN argv").  argv is three
  fixed words with nothing in them.

  `http.asyncChild = false` forces the in-process path back on even inside a
  runAsync coroutine.  It is there for the A/B measurement above (and for a host
  that cannot spawn), not as a normal setting.

  `headers` is a plain name->value table; the request headers are emitted in
  case-insensitive alphabetical order, which is the order the C++ reference
  (cpp-httplib, a multimap) puts them on the wire.  `res.headers` comes back
  with LOWER-CASE keys.  `opts` (optional): { timeoutMs=, backend='auto'|
  'winhttp'|'curl-ffi'|'curl-cli'|'curl', noAcceptEncodingRetry=true }.

  Backends, per docs/lua-runtime.md §3 and docs/portability.md:

     platform | primary                        | fallback        | last resort
     ---------+--------------------------------+-----------------+-------------
     Windows  | WinHTTP through FFI (~525 ms)  | curl.exe (CLI)  | —
     Linux    | libcurl.so.4 through FFI       | curl (CLI)      | error:
              | (easy interface + WRITEFUNCTION)|                | "apt install curl"

  Selection is automatic at load-time probe and cached; `http.backend()` names
  the winner for the boot log line.

  CREDENTIALS: the login body carries the account password, so it NEVER reaches
  a command line — `ps`/`/proc/<pid>/cmdline` is world-readable.  Both CLI paths
  write the body to a temp file (created 0600 on Linux, before a single byte is
  written) and pass `--data-binary @file`, then delete it.

  TLS: the C++ reference disables BOTH certificate and hostname verification
  for this POST (httplogin.cpp:410-411), so we do the same — see the
  one-line warning emitted on the first request.

  Redirects are never followed (the reference client does not follow them).

  Content-Encoding: if the response carries an encoding we cannot decode (e.g.
  `br`), the request is retried ONCE with no Accept-Encoding header.
]]

local ffi = require('ffi')
local bit = require('bit')

local IS_WINDOWS = (ffi.os == 'Windows')
local IS_LINUX   = (ffi.os == 'Linux')

-- lib/log.lua is written by another work item; degrade gracefully if absent.
local log
do
  local ok, m = pcall(require, 'lib.log')
  if ok and type(m) == 'table' and type(m.warn) == 'function' then
    log = m
  else
    local function mk(level)
      return function(fmt, ...)
        local n = select('#', ...)
        local msg = n > 0 and string.format(fmt, ...) or tostring(fmt)
        io.stderr:write('[' .. level .. '] ' .. msg .. '\n')
      end
    end
    log = { debug = mk('debug'), info = mk('info'), warn = mk('warn'), error = mk('error') }
  end
end

local http = {}

http.DEFAULT_TIMEOUT_MS = 20000
http.preferBackend = 'auto'    -- 'auto' | 'winhttp' | 'curl-ffi' | 'curl-cli'
http.curlPath = IS_WINDOWS and 'C:\\Windows\\System32\\curl.exe' or 'curl'
http.userAgent = 'Mozilla/5.0' -- only used when the caller supplies no User-Agent

---------------------------------------------------------------------- proxy ---
-- PANEL.md "Proxy support": the HTTPS login POST must leave through the SAME HTTP
-- proxy the game socket is tunnelled through, or an IP-restricted account sees two
-- different source addresses and the login is refused.
--
--   http.setProxy{ host=, port=, user=, pass= }    -- process-wide, set once at boot
--   http.setProxy(nil)                             -- clear
--   http.getProxy() -> {host=,port=,user=,hasAuth=}  (NEVER the password)
--
-- A per-call `opts.proxy` overrides it.  proto/handshake.lua does not thread options
-- through, which is why this is a module-level setting rather than a parameter.
--
-- CREDENTIALS: the proxy password never reaches a command line.  The libcurl and
-- WinHTTP paths set it in-process; the curl CLI path writes it into a 0600 curl
-- config file (`--config FILE`) and deletes the file afterwards.
local proxyCfg = nil

function http.setProxy(p)
  if p == nil or p == false then proxyCfg = nil; return true end
  if type(p) ~= 'table' then return nil, 'http.setProxy: expected a table or nil' end
  local host, port = p.host, tonumber(p.port)
  if type(host) ~= 'string' or host == '' then return nil, 'http.setProxy: host is required' end
  if not port or port < 1 or port > 65535 then return nil, 'http.setProxy: bad port' end
  -- A CR/LF/NUL in a credential would splice a header into curl's config file or into
  -- WinHTTP's option blob.  Refuse rather than sanitise.
  for _, k in ipairs({ 'host', 'user', 'pass' }) do
    local v = p[k]
    if v ~= nil and (type(v) ~= 'string' or v:find('[\r\n]') or v:find('%z')) then
      return nil, 'http.setProxy: ' .. k .. ' must be a string with no CR, LF or NUL'
    end
  end
  proxyCfg = { host = host, port = port, user = p.user, pass = p.pass }
  return true
end

function http.getProxy()
  if not proxyCfg then return nil end
  return { host = proxyCfg.host, port = proxyCfg.port, user = proxyCfg.user,
           hasAuth = (proxyCfg.user ~= nil and proxyCfg.user ~= '') }
end

local function proxyFor(opts)
  local p = opts and opts.proxy
  if p == false then return nil end
  if p == nil then return proxyCfg end
  return p
end

local function proxyAuthPair(p)
  if not p or type(p.user) ~= 'string' or p.user == '' then return nil end
  return p.user .. ':' .. (p.pass or '')
end

--------------------------------------------------------------------------- util

local function lower(s) return (s or ''):lower() end

local function parseUrl(url)
  local scheme, hostport, path = url:match('^(https?)://([^/]+)(.*)$')
  if not scheme then return nil, 'bad url: ' .. tostring(url) end
  local port = tonumber(hostport:match(':(%d+)$'))
  local host = hostport:gsub(':%d+$', '')
  if not port then port = (scheme == 'https') and 443 or 80 end
  if path == '' then path = '/' end
  return { scheme = scheme, host = host, port = port, path = path }
end

-- case-insensitive alphabetical, like cpp-httplib's multimap on the wire
local function sortedHeaderList(headers)
  local keys = {}
  for k in pairs(headers or {}) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    local la, lb = a:lower(), b:lower()
    if la ~= lb then return la < lb end
    return a < b
  end)
  local out = {}
  for i = 1, #keys do out[i] = { keys[i], tostring(headers[keys[i]]) } end
  return out
end

local function copyHeaders(h)
  local t = {}
  for k, v in pairs(h or {}) do t[k] = v end
  return t
end

local function removeHeader(h, name)
  local ln = name:lower()
  for k in pairs(h) do
    if k:lower() == ln then h[k] = nil end
  end
end

local function getHeader(h, name)
  local ln = name:lower()
  for k, v in pairs(h or {}) do
    if k:lower() == ln then return v end
  end
  return nil
end

-- Parse a raw "HTTP/1.1 200 OK\r\nName: v\r\n..." block into a lower-cased table.
local function parseRawHeaders(raw)
  local t = {}
  for line in tostring(raw or ''):gmatch('[^\r\n]+') do
    local k, v = line:match('^([%w%-_]+)%s*:%s*(.*)$')
    if k then
      k = k:lower()
      if t[k] then t[k] = t[k] .. ', ' .. v else t[k] = v end
    end
  end
  return t
end

local function looksLikeText(s)
  if s == nil or #s == 0 then return true end
  if s:find('%z') then return false end
  if s:sub(1, 2) == '\31\139' then return false end -- gzip magic
  local sample = s:sub(1, 4096)
  local bad = 0
  for i = 1, #sample do
    local b = sample:byte(i)
    if b < 9 or (b > 13 and b < 32) then bad = bad + 1 end
  end
  return bad * 20 <= #sample -- < 5% control bytes
end

-- true when the response body is still encoded with something we cannot decode
local function undecodedBody(res)
  local ce = lower(res.headers and res.headers['content-encoding'])
  if ce == '' or ce == 'identity' then return false end
  return not looksLikeText(res.body)
end

local warnedInsecure = false
local function warnInsecureOnce(u)
  if u.scheme == 'https' and not warnedInsecure then
    warnedInsecure = true
    log.warn('http: TLS certificate/hostname verification is DISABLED (matches the C++ reference client)')
  end
end

local function readFile(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local d = f:read('*a')
  f:close()
  return d
end

--------------------------------------------------------------------- WinHTTP ---
-- Windows only.  Nothing below this comment is declared on Linux: ffi.cdef is
-- process-global and a wrong-OS declaration would poison every other module.

local W = {}          -- winhttp backend namespace
local wh, k32         -- lazily loaded libraries
local whLoadError

if IS_WINDOWS then

ffi.cdef [[
typedef void*          HINTERNET;
typedef unsigned long  DWORD_;
typedef int            BOOL_;
typedef unsigned short WORD_;
typedef const wchar_t* LPCWSTR_;

HINTERNET WinHttpOpen(LPCWSTR_, DWORD_, LPCWSTR_, LPCWSTR_, DWORD_);
HINTERNET WinHttpConnect(HINTERNET, LPCWSTR_, WORD_, DWORD_);
HINTERNET WinHttpOpenRequest(HINTERNET, LPCWSTR_, LPCWSTR_, LPCWSTR_, LPCWSTR_, LPCWSTR_*, DWORD_);
BOOL_     WinHttpSendRequest(HINTERNET, LPCWSTR_, DWORD_, void*, DWORD_, DWORD_, uintptr_t);
BOOL_     WinHttpWriteData(HINTERNET, const void*, DWORD_, DWORD_*);
BOOL_     WinHttpReceiveResponse(HINTERNET, void*);
BOOL_     WinHttpQueryDataAvailable(HINTERNET, DWORD_*);
BOOL_     WinHttpReadData(HINTERNET, void*, DWORD_, DWORD_*);
BOOL_     WinHttpQueryHeaders(HINTERNET, DWORD_, LPCWSTR_, void*, DWORD_*, DWORD_*);
BOOL_     WinHttpSetTimeouts(HINTERNET, int, int, int, int);
BOOL_     WinHttpSetOption(HINTERNET, DWORD_, void*, DWORD_);
BOOL_     WinHttpCloseHandle(HINTERNET);
DWORD_    GetLastError(void);
int       MultiByteToWideChar(unsigned, DWORD_, const char*, int, wchar_t*, int);
int       WideCharToMultiByte(unsigned, DWORD_, const wchar_t*, int, char*, int, const char*, int*);
]]

local WINHTTP_FLAG_SECURE            = 0x00800000
local WINHTTP_QUERY_STATUS_CODE      = 19
local WINHTTP_QUERY_RAW_HEADERS_CRLF = 22
local WINHTTP_QUERY_FLAG_NUMBER      = 0x20000000
local WINHTTP_OPTION_SECURITY_FLAGS  = 31
local WINHTTP_OPTION_DISABLE_FEATURE = 63
local WINHTTP_OPTION_REDIRECT_POLICY = 88
local WINHTTP_DISABLE_REDIRECTS      = 0x00000002
local WINHTTP_REDIRECT_POLICY_NEVER  = 0
local ERROR_INSUFFICIENT_BUFFER      = 122
-- WinHttpOpen dwAccessType + the two proxy-credential options (winhttp.h).
local WINHTTP_ACCESS_TYPE_NAMED_PROXY = 3
local WINHTTP_OPTION_PROXY_USERNAME   = 4098
local WINHTTP_OPTION_PROXY_PASSWORD   = 4099
-- SECURITY_FLAG_IGNORE_UNKNOWN_CA|_CERT_DATE_INVALID|_CERT_CN_INVALID|_CERT_WRONG_USAGE
local IGNORE_ALL_CERT_ERRORS         = 0x00003300

local WINHTTP_ERRORS = {
  [12002] = 'timeout', [12007] = 'name not resolved', [12029] = 'cannot connect',
  [12030] = 'connection reset', [12152] = 'invalid server response',
  [12175] = 'secure channel failure', [12180] = 'autodetection failed',
}

local function whErr(what)
  local code = tonumber(k32.GetLastError())
  local name = WINHTTP_ERRORS[code]
  return string.format('%s failed (winhttp error %d%s)', what, code, name and (': ' .. name) or '')
end

function W.load()
  if wh then return true end
  if whLoadError then return false, whLoadError end
  local ok, a = pcall(ffi.load, 'winhttp')
  if not ok then whLoadError = tostring(a); return false, whLoadError end
  local ok2, b = pcall(ffi.load, 'kernel32')
  if not ok2 then whLoadError = tostring(b); return false, whLoadError end
  wh, k32 = a, b
  return true
end

local function W16(s)                                -- UTF-8 -> UTF-16LE, NUL-terminated
  local n = k32.MultiByteToWideChar(65001, 0, s, -1, nil, 0)
  local b = ffi.new('wchar_t[?]', n)
  k32.MultiByteToWideChar(65001, 0, s, -1, b, n)
  return b
end

local function A8(wbuf, wchars)                      -- UTF-16LE -> UTF-8
  local n = k32.WideCharToMultiByte(65001, 0, wbuf, wchars, nil, 0, nil, nil)
  if n <= 0 then return '' end
  local b = ffi.new('char[?]', n)
  k32.WideCharToMultiByte(65001, 0, wbuf, wchars, b, n, nil, nil)
  return ffi.string(b, n)
end

local function setDword(h, option, value)
  local v = ffi.new('DWORD_[1]', value)
  return wh.WinHttpSetOption(h, option, v, 4) ~= 0
end

-- WINHTTP_OPTION_PROXY_USERNAME / _PASSWORD take an LPWSTR whose length is measured in
-- CHARACTERS, not bytes, and not counting the terminating NUL (winhttp.h / MSDN).
local function setWideOption(h, option, s)
  -- MultiByteToWideChar's return counts the terminating NUL because we pass -1.
  local nchars = k32.MultiByteToWideChar(65001, 0, s, -1, nil, 0) - 1
  if nchars < 0 then nchars = 0 end
  local w = W16(s)
  return wh.WinHttpSetOption(h, option, w, nchars) ~= 0
end

function W.post(u, headers, body, timeoutMs, px)
  local S, Cn, R
  local function cleanup()
    if R then wh.WinHttpCloseHandle(R) end
    if Cn then wh.WinHttpCloseHandle(Cn) end
    if S then wh.WinHttpCloseHandle(S) end
  end
  local function fail(what)
    local e = whErr(what)
    cleanup()
    return nil, e
  end

  if px then
    -- WINHTTP_ACCESS_TYPE_NAMED_PROXY + "host:port"; WinHTTP CONNECT-tunnels an https
    -- request through it, which is what the reference client does for the login POST.
    S = wh.WinHttpOpen(W16(http.userAgent), WINHTTP_ACCESS_TYPE_NAMED_PROXY,
                       W16(px.host .. ':' .. tostring(px.port)), W16(''), 0)
  else
    S = wh.WinHttpOpen(W16(http.userAgent), 0, nil, nil, 0)  -- 0 = DEFAULT_PROXY
  end
  if S == nil then return fail('WinHttpOpen') end
  wh.WinHttpSetTimeouts(S, timeoutMs, timeoutMs, timeoutMs, timeoutMs)

  Cn = wh.WinHttpConnect(S, W16(u.host), u.port, 0)
  if Cn == nil then return fail('WinHttpConnect') end

  R = wh.WinHttpOpenRequest(Cn, W16('POST'), W16(u.path), nil, nil, nil,
                            u.scheme == 'https' and WINHTTP_FLAG_SECURE or 0)
  if R == nil then return fail('WinHttpOpenRequest') end

  -- Proxy credentials go on the REQUEST handle, in-process: they never reach argv.
  if px and type(px.user) == 'string' and px.user ~= '' then
    setWideOption(R, WINHTTP_OPTION_PROXY_USERNAME, px.user)
    setWideOption(R, WINHTTP_OPTION_PROXY_PASSWORD, px.pass or '')
  end

  -- never follow redirects (reference client does not)
  setDword(R, WINHTTP_OPTION_REDIRECT_POLICY, WINHTTP_REDIRECT_POLICY_NEVER)
  setDword(R, WINHTTP_OPTION_DISABLE_FEATURE, WINHTTP_DISABLE_REDIRECTS)
  -- NOTE: WINHTTP_OPTION_DECOMPRESSION is deliberately NOT set.  It makes
  -- WinHTTP rewrite our Accept-Encoding into "br, gzip, deflate" (measured
  -- against httpbin.org), which would no longer be the exact header set the
  -- reference client sends.  An encoding we cannot decode is handled by the
  -- one-shot retry without Accept-Encoding in http.post instead.

  if u.scheme == 'https' then
    -- The C++ reference disables certificate AND hostname verification for the
    -- login POST (httplogin.cpp:410-411); match it so we never fail a login the
    -- reference completes.
    warnInsecureOnce(u)
    setDword(R, WINHTTP_OPTION_SECURITY_FLAGS, IGNORE_ALL_CERT_ERRORS)
  end

  local list = sortedHeaderList(headers)
  local hs = {}
  for i = 1, #list do hs[i] = list[i][1] .. ': ' .. list[i][2] end
  local hdr = (#hs > 0) and (table.concat(hs, '\r\n') .. '\r\n') or nil

  body = body or ''
  -- dwHeadersLength 0xFFFFFFFF == -1L == "measure the wide string yourself"
  if wh.WinHttpSendRequest(R, hdr and W16(hdr) or nil, hdr and 0xFFFFFFFF or 0,
                           nil, 0, #body, 0) == 0 then
    return fail('WinHttpSendRequest')
  end
  if #body > 0 then
    local written = ffi.new('DWORD_[1]')
    if wh.WinHttpWriteData(R, body, #body, written) == 0 then
      return fail('WinHttpWriteData')
    end
  end
  if wh.WinHttpReceiveResponse(R, nil) == 0 then
    return fail('WinHttpReceiveResponse')
  end

  local code, cl = ffi.new('DWORD_[1]'), ffi.new('DWORD_[1]', 4)
  if wh.WinHttpQueryHeaders(R, bit.bor(WINHTTP_QUERY_STATUS_CODE, WINHTTP_QUERY_FLAG_NUMBER),
                            nil, code, cl, nil) == 0 then
    return fail('WinHttpQueryHeaders(status)')
  end

  -- raw response headers: size probe, then read
  local rawHeaders = ''
  local sz = ffi.new('DWORD_[1]', 0)
  wh.WinHttpQueryHeaders(R, WINHTTP_QUERY_RAW_HEADERS_CRLF, nil, nil, sz, nil)
  if tonumber(k32.GetLastError()) == ERROR_INSUFFICIENT_BUFFER and sz[0] > 0 then
    local nbytes = tonumber(sz[0])
    local wbuf = ffi.new('wchar_t[?]', math.floor(nbytes / 2) + 1)
    if wh.WinHttpQueryHeaders(R, WINHTTP_QUERY_RAW_HEADERS_CRLF, nil, wbuf, sz, nil) ~= 0 then
      rawHeaders = A8(wbuf, math.floor(tonumber(sz[0]) / 2))
    end
  end

  local parts, buf = {}, ffi.new('char[16384]')
  local avail, rd = ffi.new('DWORD_[1]'), ffi.new('DWORD_[1]')
  while true do
    avail[0] = 0
    if wh.WinHttpQueryDataAvailable(R, avail) == 0 then break end
    if avail[0] == 0 then break end
    local want = math.min(tonumber(avail[0]), 16384)
    if wh.WinHttpReadData(R, buf, want, rd) == 0 then break end
    if rd[0] == 0 then break end
    parts[#parts + 1] = ffi.string(buf, rd[0])
  end

  cleanup()
  return { status = tonumber(code[0]), body = table.concat(parts),
           headers = parseRawHeaders(rawHeaders), backend = 'winhttp' }
end

end -- IS_WINDOWS

--------------------------------------------------------------------- libcurl ---
-- Linux only.  libcurl's "easy" interface, blocking, one handle per request.

local L = {}
local curl, curlLoadError

if IS_LINUX then

ffi.cdef [[
typedef size_t (*lc_curl_write_cb)(char*, size_t, size_t, void*);
struct lc_curl_slist;
void  *curl_easy_init(void);
int    curl_easy_setopt(void*, int, ...);
int    curl_easy_perform(void*);
int    curl_easy_getinfo(void*, int, ...);
void   curl_easy_cleanup(void*);
const char *curl_easy_strerror(int);
struct lc_curl_slist *curl_slist_append(struct lc_curl_slist*, const char*);
void   curl_slist_free_all(struct lc_curl_slist*);
int    chmod(const char*, unsigned int);
]]

-- CURLOPT_*: 10000+ = pointer/string, 20000+ = function pointer, bare = long.
local CURLOPT_URL             = 10002
local CURLOPT_POSTFIELDSIZE   = 60
local CURLOPT_COPYPOSTFIELDS  = 10165
local CURLOPT_HTTPHEADER      = 10023
local CURLOPT_WRITEFUNCTION   = 20011
local CURLOPT_WRITEDATA       = 10001
local CURLOPT_HEADERFUNCTION  = 20079
local CURLOPT_HEADERDATA      = 10029
local CURLOPT_TIMEOUT_MS      = 155
local CURLOPT_CONNECTTIMEOUT_MS = 156
-- proxy (curl.h): PROXY is a string, PROXYPORT/PROXYTYPE/HTTPPROXYTUNNEL are longs,
-- PROXYUSERPWD is a "user:password" string libcurl copies into the handle.
local CURLOPT_PROXY           = 10004
local CURLOPT_PROXYPORT       = 59
local CURLOPT_PROXYUSERPWD    = 10175
local CURLOPT_PROXYTYPE       = 101
local CURLOPT_HTTPPROXYTUNNEL = 61
local CURLPROXY_HTTP          = 0
local CURLOPT_SSL_VERIFYPEER  = 64
local CURLOPT_SSL_VERIFYHOST  = 81
local CURLOPT_FOLLOWLOCATION  = 52
local CURLOPT_NOSIGNAL        = 99
local CURLOPT_NOPROGRESS      = 43
local CURLOPT_HTTP_VERSION    = 84
local CURL_HTTP_VERSION_1_1   = 2
local CURLINFO_RESPONSE_CODE  = 0x200000 + 2      -- CURLINFO_LONG | 2
local CURLE_OK                = 0

-- Several sonames: Debian/Ubuntu ship libcurl.so.4 (a symlink to .4.x.y); the
-- unversioned libcurl.so only exists with the -dev package installed.
local SONAMES = { 'libcurl.so.4', 'libcurl.so.4.8.0', 'libcurl.so.4.7.0', 'libcurl.so', 'curl' }

function L.load()
  if curl then return true end
  if curlLoadError then return false, curlLoadError end
  local tried = {}
  for i = 1, #SONAMES do
    local ok, lib = pcall(ffi.load, SONAMES[i])
    if ok then
      -- resolving one symbol proves it is really libcurl and not a stub
      local ok2 = pcall(function() return lib.curl_easy_init end)
      if ok2 then curl = lib; return true end
      tried[#tried + 1] = SONAMES[i] .. ' (no curl_easy_init)'
    else
      tried[#tried + 1] = SONAMES[i]
    end
  end
  curlLoadError = 'none of {' .. table.concat(tried, ', ') .. '} could be loaded'
  return false, curlLoadError
end

-- One accumulator + one callback pair for the whole process: http.post is
-- blocking and single-threaded, so there is never more than one live transfer.
-- (FFI callbacks are a scarce, manually-freed resource — never make them per call.)
local bodyParts, headerParts = {}, {}

local writeCb = ffi.cast('lc_curl_write_cb', function(ptr, size, nmemb, _)
  local n = tonumber(size) * tonumber(nmemb)
  if n > 0 then bodyParts[#bodyParts + 1] = ffi.string(ptr, n) end
  return n
end)

local headerCb = ffi.cast('lc_curl_write_cb', function(ptr, size, nmemb, _)
  local n = tonumber(size) * tonumber(nmemb)
  if n > 0 then headerParts[#headerParts + 1] = ffi.string(ptr, n) end
  return n
end)

-- LuaJIT passes a plain Lua number to a C vararg as a DOUBLE; libcurl reads a
-- long (or a pointer) out of the integer registers.  EVERY setopt value must
-- therefore be an explicitly typed cdata — this is the single most common way
-- to get silent garbage out of an FFI libcurl binding.
local function setoptL(h, opt, v) return curl.curl_easy_setopt(h, opt, ffi.cast('long', v)) end
local function setoptP(h, opt, v) return curl.curl_easy_setopt(h, opt, v) end

function L.post(u, headers, body, timeoutMs, px)
  local ok, err = L.load()
  if not ok then return nil, 'libcurl not loadable: ' .. tostring(err) end

  local h = curl.curl_easy_init()
  if h == nil then return nil, 'curl_easy_init() returned NULL' end

  local slist = nil
  local function cleanup()
    if slist ~= nil then curl.curl_slist_free_all(slist) end
    curl.curl_easy_cleanup(h)
  end

  body = body or ''
  local url = u.scheme .. '://' .. u.host .. ':' .. u.port .. u.path
  -- CURLOPT_URL and CURLOPT_COPYPOSTFIELDS both copy into the handle, so neither
  -- Lua string has to survive until perform() (CURLOPT_POSTFIELDS would NOT copy
  -- — that is exactly why COPYPOSTFIELDS is used here).

  setoptP(h, CURLOPT_URL, ffi.cast('const char*', url))
  setoptL(h, CURLOPT_POSTFIELDSIZE, #body)          -- must precede COPYPOSTFIELDS
  setoptP(h, CURLOPT_COPYPOSTFIELDS, ffi.cast('const char*', body))
  setoptL(h, CURLOPT_FOLLOWLOCATION, 0)             -- reference client never follows
  setoptL(h, CURLOPT_NOSIGNAL, 1)                   -- no SIGALRM/SIGPIPE from libcurl
  setoptL(h, CURLOPT_NOPROGRESS, 1)
  setoptL(h, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1)
  setoptL(h, CURLOPT_TIMEOUT_MS, timeoutMs or http.DEFAULT_TIMEOUT_MS)
  setoptL(h, CURLOPT_CONNECTTIMEOUT_MS, timeoutMs or http.DEFAULT_TIMEOUT_MS)
  -- match the C++ reference: certificate AND hostname verification off
  setoptL(h, CURLOPT_SSL_VERIFYPEER, 0)
  setoptL(h, CURLOPT_SSL_VERIFYHOST, 0)
  warnInsecureOnce(u)

  -- Proxy: an https URL through CURLPROXY_HTTP is CONNECT-tunnelled by libcurl, which is
  -- the same tunnel proto/transport.lua opens for the game socket.  PROXYUSERPWD is copied
  -- into the handle in-process, so the credential never appears in argv or in the log.
  if px then
    setoptP(h, CURLOPT_PROXY, ffi.cast('const char*', tostring(px.host)))
    setoptL(h, CURLOPT_PROXYPORT, tonumber(px.port) or 8080)
    setoptL(h, CURLOPT_PROXYTYPE, CURLPROXY_HTTP)
    setoptL(h, CURLOPT_HTTPPROXYTUNNEL, 1)
    local pair = proxyAuthPair(px)
    if pair then setoptP(h, CURLOPT_PROXYUSERPWD, ffi.cast('const char*', pair)) end
  end

  setoptP(h, CURLOPT_WRITEFUNCTION, writeCb)
  setoptP(h, CURLOPT_WRITEDATA, nil)
  setoptP(h, CURLOPT_HEADERFUNCTION, headerCb)
  setoptP(h, CURLOPT_HEADERDATA, nil)

  local list = sortedHeaderList(headers)
  for i = 1, #list do
    slist = curl.curl_slist_append(slist, list[i][1] .. ': ' .. list[i][2])
  end
  -- suppress the two headers libcurl would add on its own and the reference does
  -- not send: "Expect: 100-continue" (bodies > 1 KB) and, when the caller gave
  -- none, nothing else -- an explicit header in `headers` already overrides curl's.
  slist = curl.curl_slist_append(slist, 'Expect:')
  if slist ~= nil then setoptP(h, CURLOPT_HTTPHEADER, slist) end

  for i = #bodyParts, 1, -1 do bodyParts[i] = nil end
  for i = #headerParts, 1, -1 do headerParts[i] = nil end

  local rc = curl.curl_easy_perform(h)
  if rc ~= CURLE_OK then
    local msg = ffi.string(curl.curl_easy_strerror(rc))
    cleanup()
    return nil, string.format('libcurl request failed: %s (CURLcode %d)', msg, tonumber(rc))
  end

  local code = ffi.new('long[1]', 0)
  curl.curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, code)
  local status = tonumber(code[0])

  local resBody = table.concat(bodyParts)
  local rawHeaders = table.concat(headerParts)
  cleanup()

  if status == 0 then return nil, 'libcurl returned no HTTP status' end
  return { status = status, body = resBody,
           headers = parseRawHeaders(rawHeaders), backend = 'curl-ffi' }
end

--- Create `path` empty and make it owner-only BEFORE anything is written to it.
function L.secureCreate(path)
  local f = io.open(path, 'wb')
  if not f then return nil, 'cannot create ' .. path end
  f:close()
  if ffi.C.chmod(path, 384) ~= 0 then    -- 384 == 0600
    os.remove(path)
    return nil, 'chmod 0600 failed on ' .. path
  end
  return true
end

end -- IS_LINUX

------------------------------------------------------------------- curl CLI ---
-- Fallback on both platforms.  The request body (which contains the password)
-- is passed by FILE, never on the command line.

local C = {}

local function tempName(tag)
  local sys = require('lib.sys')
  local dir = sys.tempDir()
  local sep = IS_WINDOWS and '\\' or '/'
  return string.format('%s%slcHttp_%s_%d_%d.tmp', dir, sep, tag,
                       os.time(), math.random(100000, 999999))
end

-- Windows: cmd.exe quoting (double quotes, whole command wrapped again).
-- POSIX:   single quotes, with the '\'' escape for an embedded quote.
local function shq(s)
  if IS_WINDOWS then return '"' .. tostring(s):gsub('"', '\\"') .. '"' end
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function writeBody(path, data)
  if IS_LINUX then
    local ok, e = L.secureCreate(path)
    if not ok then return nil, e end
  end
  local f, e = io.open(path, 'wb')
  if not f then return nil, tostring(e) end
  f:write(data or '')
  f:close()
  return true
end

function C.probe()
  local p = io.popen(shq(http.curlPath) .. ' --version 2>' ..
                     (IS_WINDOWS and 'NUL' or '/dev/null'), 'r')
  if not p then return false, 'io.popen unavailable' end
  local out = p:read('*a') or ''
  p:close()
  if out:match('^curl%s') then return true end
  return false, http.curlPath .. ' not found on PATH'
end

function C.post(u, headers, body, timeoutMs, px)
  local reqFile, hdrFile, respFile = tempName('req'), tempName('hdr'), tempName('resp')
  local cfgFile = nil
  local function clean()
    os.remove(reqFile); os.remove(hdrFile); os.remove(respFile)
    if cfgFile then os.remove(cfgFile) end
  end

  local ok, e = writeBody(reqFile, body or '')
  if not ok then clean(); return nil, 'cannot write temp request file: ' .. tostring(e) end

  -- The proxy credential must not reach argv (see the header of this file and
  -- lib/process.lua's SECRETS IN argv section).  curl reads `proxy-user` out of a
  -- --config file, which is created 0600 on Linux and deleted in clean().
  local proxyPair = proxyAuthPair(px)
  if proxyPair then
    cfgFile = tempName('pxy')
    -- curl's config parser understands \\ and \" inside a double-quoted value.
    local quoted = proxyPair:gsub('\\', '\\\\'):gsub('"', '\\"')
    local okc, ec = writeBody(cfgFile, 'proxy-user = "' .. quoted .. '"\n')
    if not okc then clean(); return nil, 'cannot write temp proxy config: ' .. tostring(ec) end
  end

  -- -k: match the reference client, which disables cert+hostname verification.
  -- No -L: redirects are never followed.  The body NEVER goes on the command
  -- line (it holds the password, and argv is world-readable in /proc and in
  -- `ps`; cmd.exe would also mangle &, %VAR%, ^ and quotes) — it goes by file.
  local parts = {
    shq(http.curlPath), '-s', '-S', '--http1.1',
    '-k', '--no-keepalive',
    '--max-time', tostring(math.max(1, math.floor((timeoutMs or 20000) / 1000))),
    '-X', 'POST',
    '--data-binary', shq('@' .. reqFile),
  }
  if px then
    parts[#parts + 1] = '-x'
    parts[#parts + 1] = shq('http://' .. px.host .. ':' .. tostring(px.port))
    parts[#parts + 1] = '--proxytunnel'
    if cfgFile then
      parts[#parts + 1] = '--config'
      parts[#parts + 1] = shq(cfgFile)
    end
  end
  local list = sortedHeaderList(headers)
  for i = 1, #list do
    parts[#parts + 1] = '-H'
    parts[#parts + 1] = shq(list[i][1] .. ': ' .. list[i][2])
  end
  parts[#parts + 1] = '-H'
  parts[#parts + 1] = shq('Expect:')
  parts[#parts + 1] = '-D'
  parts[#parts + 1] = shq(hdrFile)
  parts[#parts + 1] = '-o'
  parts[#parts + 1] = shq(respFile)
  parts[#parts + 1] = '-w'
  parts[#parts + 1] = shq('%{http_code}')
  parts[#parts + 1] = shq(u.scheme .. '://' .. u.host .. ':' .. u.port .. u.path)
  parts[#parts + 1] = '2>&1'   -- capture curl's own diagnostics for the error string

  warnInsecureOnce(u)

  local cmd = table.concat(parts, ' ')
  -- cmd.exe strips the outer pair of quotes off the whole line; POSIX shells do not.
  if IS_WINDOWS then cmd = '"' .. cmd .. '"' end
  local p = io.popen(cmd, 'r')
  if not p then clean(); return nil, 'io.popen failed for ' .. http.curlPath end
  local out = p:read('*a') or ''
  p:close()

  local status = tonumber((out:match('(%d%d%d)%s*$')))
  local respBody = readFile(respFile) or ''
  local rawHeaders = readFile(hdrFile) or ''
  clean()

  if not status or status == 0 then
    return nil, 'curl CLI request failed (' .. (out ~= '' and out or 'no output') .. ')'
  end
  return { status = status, body = respBody,
           headers = parseRawHeaders(rawHeaders), backend = 'curl-cli' }
end

--------------------------------------------------------- backend selection ---

local chosen, chosenErr

local function selectBackend()
  if chosen then return chosen end
  if chosenErr then return nil, chosenErr end

  if IS_WINDOWS then
    local ok, err = W.load()
    if ok then chosen = 'winhttp'; return chosen end
    log.warn('http: winhttp.dll not loadable (%s) — falling back to curl.exe', tostring(err))
    local ok2, err2 = C.probe()
    if ok2 then chosen = 'curl-cli'; return chosen end
    chosenErr = 'no HTTP backend: winhttp.dll unusable (' .. tostring(err) ..
                ') and curl.exe unusable (' .. tostring(err2) .. ')'
    return nil, chosenErr
  end

  local ok, err = L.load()
  if ok then chosen = 'curl-ffi'; return chosen end
  log.warn('http: libcurl not loadable (%s) — falling back to the curl CLI', tostring(err))
  local ok2, err2 = C.probe()
  if ok2 then chosen = 'curl-cli'; return chosen end
  chosenErr = 'no HTTP backend available: libcurl could not be loaded (' .. tostring(err) ..
              ') and the curl CLI is not on PATH (' .. tostring(err2) ..
              ').  Install it:  apt install curl'
  return nil, chosenErr
end

--- Name of the backend this process will use ('winhttp' | 'curl-ffi' | 'curl-cli').
--- Probes once and caches; returns nil, err when no backend exists at all.
function http.backend()
  if http.preferBackend and http.preferBackend ~= 'auto' then
    return http.preferBackend
  end
  return selectBackend()
end

local function oneShot(u, headers, body, timeoutMs, backend, px)
  if backend == nil or backend == 'auto' then
    local b, err = selectBackend()
    if not b then return nil, err end
    backend = b
  end
  if backend == 'curl' then backend = IS_LINUX and 'curl-ffi' or 'curl-cli' end

  if backend == 'curl-cli' then return C.post(u, headers, body, timeoutMs, px) end

  if backend == 'curl-ffi' then
    if not IS_LINUX then return nil, 'curl-ffi backend is Linux-only' end
    local res, e = L.post(u, headers, body, timeoutMs, px)
    if res then return res end
    log.warn('http: libcurl request failed (%s) — retrying with the curl CLI', tostring(e))
    local res2, e2 = C.post(u, headers, body, timeoutMs, px)
    if res2 then return res2 end
    return nil, tostring(e) .. '; curl CLI fallback: ' .. tostring(e2)
  end

  if backend == 'winhttp' then
    if not IS_WINDOWS then return nil, 'winhttp backend is Windows-only' end
    local ok, err = W.load()
    if not ok then return nil, 'winhttp.dll not loadable: ' .. tostring(err) end
    local res, e = W.post(u, headers, body, timeoutMs, px)
    if res then return res end
    log.warn('http: WinHTTP request failed (%s) — retrying with curl.exe', tostring(e))
    local res2, e2 = C.post(u, headers, body, timeoutMs, px)
    if res2 then return res2 end
    return nil, tostring(e) .. '; curl fallback: ' .. tostring(e2)
  end

  return nil, 'unknown http backend: ' .. tostring(backend)
end

-- ===========================================================================
-- the out-of-process path (see the header)
-- ===========================================================================
-- Wire format, both directions, one line, base64 of a JSON object.  base64
-- because a request body and a response body are arbitrary bytes and a line is
-- the only framing lib/process.lua's reader offers; and because it keeps a
-- credential out of anything that greps the pipe for readable text.  Any other
-- line the child happens to write (a warning from log.warn, say) is ignored by
-- the parent, so the child does not have to be silent to be correct.
local CHILD_FLAG   = '--http-post-child'
local CHILD_MARK   = 'LCHTTP1 '
local MAX_CHILD_LINE = 24 * 1024 * 1024

http.childFlag = CHILD_FLAG

-- Required lazily: loading lib/http.lua must stay as cheap as it was, and the
-- three modules below are only needed by the out-of-process path.
local function b64()
  local ok, m = pcall(require, 'lib.base64')
  if ok and type(m) == 'table' and m.encode then return m end
  return nil
end

local function jsonMod()
  local ok, m = pcall(require, 'lib.json')
  if ok and type(m) == 'table' and m.encode then return m end
  return nil
end

local function nowMs()
  local ok, m = pcall(require, 'lib.sys')
  if ok and type(m) == 'table' and m.nowMs then return m.nowMs() end
  return os.clock() * 1000
end

--- Where this file is on disk, so the child can be spawned from it.
local SELF_PATH
do
  local src = debug.getinfo(1, 'S').source
  if src:sub(1, 1) == '@' then SELF_PATH = src:sub(2):gsub('\\', '/') end
end
http.childScript = SELF_PATH

--- The interpreter running us.  `arg[-n]` is what the shell actually invoked.
local function selfInterpreter()
  local a = rawget(_G, 'arg')
  if type(a) == 'table' then
    local i, best = -1, nil
    while a[i] do best = a[i]; i = i - 1 end
    if best then return (tostring(best):gsub('\\', '/')) end
  end
  return IS_WINDOWS and 'luajit.exe' or 'luajit'
end
http.childInterpreter = nil        -- nil = work it out from arg[-n]

--- Root of the package tree, so the child can find lib/*.lua.
local function selfRoot()
  if not SELF_PATH then return '.' end
  return SELF_PATH:match('^(.*)/[^/]*/[^/]*$') or '.'
end

--- Run the POST in a short-lived child.  cb(res, err) is called exactly once,
--- from a later reactor turn.  Returns the process handle, or nil + err when the
--- child could not even be spawned (the caller then still has the sync path).
function http.postAsync(url, headers, body, opts, cb)
  opts = opts or {}
  if type(cb) ~= 'function' then return nil, 'http.postAsync: a callback is required' end
  local u, perr = parseUrl(url)
  if not u then return nil, perr end
  local base = b64()
  if not base then return nil, 'http.postAsync: lib/base64.lua is not available' end
  local json = jsonMod()
  if not json then return nil, 'http.postAsync: lib/json.lua is not available' end
  local okp, process = pcall(require, 'lib.process')
  if not okp then return nil, 'http.postAsync: lib/process.lua is not available' end
  local oks, sched = pcall(require, 'lib.sched')
  if not oks then return nil, 'http.postAsync: lib/sched.lua is not available' end

  local px = proxyFor(opts)
  local req = {
    url = url,
    headers = copyHeaders(headers),
    body = base.encode(body or ''),
    timeoutMs = opts.timeoutMs or http.DEFAULT_TIMEOUT_MS,
    backend = opts.backend or http.preferBackend or 'auto',
    noAcceptEncodingRetry = opts.noAcceptEncodingRetry and true or false,
    curlPath = http.curlPath,
    userAgent = http.userAgent,
    proxy = px and { host = px.host, port = px.port, user = px.user, pass = px.pass } or nil,
  }
  local oke, payload = pcall(json.encode, req)
  req = nil
  if not oke then return nil, 'http.postAsync: cannot encode the request: ' .. tostring(payload) end
  local line = base.encode(payload) .. '\n'
  payload = nil                                  -- carried the password

  local answered, handle, spawnErr = false, nil, nil
  local timer
  local function finish(res, err)
    if answered then return end
    answered = true
    if timer then pcall(sched.cancel, timer); timer = nil end
    cb(res, err)
  end

  local result = nil
  handle, spawnErr = process.spawn{
    cmd = { http.childInterpreter or selfInterpreter(), SELF_PATH, CHILD_FLAG },
    cwd = selfRoot(),
    captureOutput = true,
    stdinData = line,
    closeStdinAfterData = true,
    maxLineBytes = MAX_CHILD_LINE,
    name = 'http-post',
    onLine = function(text, stream)
      if stream ~= 'stdout' then return end
      if text:sub(1, #CHILD_MARK) ~= CHILD_MARK then return end
      local okd, decoded = pcall(function()
        return json.decode(base.decode(text:sub(#CHILD_MARK + 1)))
      end)
      if okd and type(decoded) == 'table' then result = decoded end
    end,
    onExit = function(code)
      if result and result.ok and type(result.res) == 'table' then
        local r = result.res
        r.body = base.decode(r.body or '')
        r.headers = r.headers or {}
        return finish(r)
      end
      if result and not result.ok then
        return finish(nil, tostring(result.err or 'the request failed'))
      end
      finish(nil, ('the HTTP child exited (%s) without answering'):format(tostring(code)))
    end,
  }
  line = nil
  if not handle then
    return nil, 'http.postAsync: cannot spawn the request child: ' .. tostring(spawnErr)
  end

  -- The child is polled from the reactor.  Only OUR handle is polled, so this
  -- never disturbs a hub that is also polling its workers, and the timer is
  -- cancelled the moment the callback has fired.
  local deadline = nowMs() + (tonumber(opts.timeoutMs) or http.DEFAULT_TIMEOUT_MS) + 10000
  timer = sched.every(tonumber(opts.pollMs) or 10, function()
    if answered then return end
    pcall(handle.poll, handle)
    if nowMs() > deadline and not answered then
      pcall(handle.kill, handle)
      finish(nil, 'the HTTP child overran its deadline')
    end
  end)
  return handle
end

-- --------------------------------------------------------------- coroutines --
-- A coroutine created here is one whose caller has promised to cope with the
-- work finishing later, so http.post inside it may suspend instead of blocking.
-- The protocol between the two halves is one value: the coroutine yields a
-- STARTER function, and the runner calls it with a `resume` callback.
local asyncCo = setmetatable({}, { __mode = 'k' })

function http.isAsyncCoroutine(co)
  return co ~= nil and asyncCo[co] == true
end

--- Run `fn` on a coroutine that http.post may suspend.
--- done(ok, ...) receives fn's results, or false + the error it raised.
function http.runAsync(fn, done)
  local co = coroutine.create(fn)
  asyncCo[co] = true
  local step
  step = function(...)
    local r = { coroutine.resume(co, ...) }
    if not r[1] then
      asyncCo[co] = nil
      if done then done(false, r[2]) end
      return
    end
    if coroutine.status(co) == 'dead' then
      asyncCo[co] = nil
      if done then done(true, r[2], r[3], r[4], r[5]) end
      return
    end
    local starter = r[2]
    if type(starter) ~= 'function' then
      -- Somebody yielded for a reason of their own; there is nothing to wait
      -- for, so put the value straight back and keep going.
      return step(starter)
    end
    starter(function(...) step(...) end)
  end
  step()
  return co
end

--- Blocking POST.  Returns {status=, body=, headers=} or nil, err.
---
--- Inside an http.runAsync coroutine it is NOT blocking: the request goes to a
--- child process and this suspends until the answer is in.  Same signature,
--- same return values, same errors.
function http.post(url, headers, body, opts)
  opts = opts or {}
  local u, e = parseUrl(url)
  if not u then return nil, e end

  local timeoutMs = opts.timeoutMs or http.DEFAULT_TIMEOUT_MS
  local backend = opts.backend or http.preferBackend or 'auto'
  local hdrs = copyHeaders(headers)
  local px = proxyFor(opts)

  local co = coroutine.running()
  if co and asyncCo[co] and opts.async ~= false and http.asyncChild ~= false then
    local res, err = coroutine.yield(function(resume)
      local h, serr = http.postAsync(url, hdrs, body, opts, function(r, e2)
        resume(r, e2)
      end)
      if not h then
        -- No child, no problem: fall back to the in-process request.  It blocks
        -- the reactor exactly as it always did, which is the old behaviour and
        -- not a new failure.
        log.warn('http: the async request child could not start (%s) -- running it in-process',
                 tostring(serr))
        local r2, e2 = oneShot(u, hdrs, body, timeoutMs, backend, px)
        resume(r2, e2)
      end
    end)
    if not res then return nil, err end
    if undecodedBody(res) and not opts.noAcceptEncodingRetry then
      removeHeader(hdrs, 'Accept-Encoding')
      local o2 = {}
      for k, v in pairs(opts) do o2[k] = v end
      o2.noAcceptEncodingRetry = true
      return http.post(url, hdrs, body, o2)
    end
    return res
  end

  local res, err = oneShot(u, hdrs, body, timeoutMs, backend, px)
  if not res then return nil, err end

  if undecodedBody(res) and not opts.noAcceptEncodingRetry then
    local ce = getHeader(res.headers, 'content-encoding')
    log.warn('http: response uses Content-Encoding %q which we cannot decode — retrying once without Accept-Encoding',
             tostring(ce))
    removeHeader(hdrs, 'Accept-Encoding')
    local res2, err2 = oneShot(u, hdrs, body, timeoutMs, backend, px)
    if res2 then return res2 end
    return nil, 'retry without Accept-Encoding failed: ' .. tostring(err2)
  end

  return res
end

-- ===========================================================================
-- child mode:  luajit lib/http.lua --http-post-child
-- ===========================================================================
-- One request on stdin, one answer on stdout, then exit.  It runs ONLY when
-- this file is the script the interpreter was given AND the flag is present, so
-- require('lib.http') can never trip it.  Nothing is read from argv and nothing
-- is written to disk: the request (which holds the account password and, when
-- there is one, the proxy credential) exists only in this process's memory and
-- in the private pipe it arrived on.
function http._childMain()
  local base = b64()
  local json = jsonMod()
  local function out(obj)
    io.write(CHILD_MARK, base.encode(json.encode(obj)), '\n')
    io.stdout:flush()
  end
  local line = io.read('*l')
  if not line or line == '' then out{ ok = false, err = 'no request on stdin' }; return 2 end
  local okd, req = pcall(function() return json.decode(base.decode(line)) end)
  line = nil
  if not okd or type(req) ~= 'table' then
    out{ ok = false, err = 'the request did not decode: ' .. tostring(req) }
    return 2
  end
  if req.curlPath then http.curlPath = req.curlPath end
  if req.userAgent then http.userAgent = req.userAgent end
  if req.proxy then http.setProxy(req.proxy) end
  local res, err = http.post(req.url, req.headers, base.decode(req.body or ''), {
    timeoutMs = req.timeoutMs, backend = req.backend,
    noAcceptEncodingRetry = req.noAcceptEncodingRetry,
    async = false,
  })
  if not res then out{ ok = false, err = tostring(err) }; return 1 end
  out{ ok = true, res = { status = res.status, headers = res.headers,
                          backend = res.backend, body = base.encode(res.body or '') } }
  return 0
end

do
  local a = rawget(_G, 'arg')
  local invoked = (type(a) == 'table') and a[0] or nil
  local wanted = false
  if type(a) == 'table' then
    for i = 1, #a do if tostring(a[i]) == CHILD_FLAG then wanted = true end end
  end
  if wanted and invoked and SELF_PATH then
    local lhs = tostring(invoked):gsub('\\', '/')
    if lhs == SELF_PATH or lhs:sub(-#SELF_PATH) == SELF_PATH
       or SELF_PATH:sub(-#lhs) == lhs then
      -- The child is started with the package root as its cwd, but say so
      -- explicitly rather than relying on './?.lua' being on the default path.
      package.path = selfRoot() .. '/?.lua;' .. package.path
      os.exit(http._childMain() or 0)
    end
  end
end

-- exposed for tests / diagnostics
http._parseUrl = parseUrl
http._parseRawHeaders = parseRawHeaders
http._sortedHeaderList = sortedHeaderList
http._looksLikeText = looksLikeText
http._shellQuote = shq

return http
