--[[ lib/http.lua — blocking HTTPS POST for the login flow.  Windows + Linux.

  API (see API.md):
      http.post(url, headersTable, body [, opts]) -> {status=, body=, headers=} | nil, err
      http.backend()  -> 'winhttp' | 'curl-ffi' | 'curl-cli' | nil, err
                         the backend actually selected on this machine

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

function W.post(u, headers, body, timeoutMs)
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

  S = wh.WinHttpOpen(W16(http.userAgent), 0, nil, nil, 0)  -- 0 = DEFAULT_PROXY
  if S == nil then return fail('WinHttpOpen') end
  wh.WinHttpSetTimeouts(S, timeoutMs, timeoutMs, timeoutMs, timeoutMs)

  Cn = wh.WinHttpConnect(S, W16(u.host), u.port, 0)
  if Cn == nil then return fail('WinHttpConnect') end

  R = wh.WinHttpOpenRequest(Cn, W16('POST'), W16(u.path), nil, nil, nil,
                            u.scheme == 'https' and WINHTTP_FLAG_SECURE or 0)
  if R == nil then return fail('WinHttpOpenRequest') end

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

function L.post(u, headers, body, timeoutMs)
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

function C.post(u, headers, body, timeoutMs)
  local reqFile, hdrFile, respFile = tempName('req'), tempName('hdr'), tempName('resp')
  local function clean()
    os.remove(reqFile); os.remove(hdrFile); os.remove(respFile)
  end

  local ok, e = writeBody(reqFile, body or '')
  if not ok then clean(); return nil, 'cannot write temp request file: ' .. tostring(e) end

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

local function oneShot(u, headers, body, timeoutMs, backend)
  if backend == nil or backend == 'auto' then
    local b, err = selectBackend()
    if not b then return nil, err end
    backend = b
  end
  if backend == 'curl' then backend = IS_LINUX and 'curl-ffi' or 'curl-cli' end

  if backend == 'curl-cli' then return C.post(u, headers, body, timeoutMs) end

  if backend == 'curl-ffi' then
    if not IS_LINUX then return nil, 'curl-ffi backend is Linux-only' end
    local res, e = L.post(u, headers, body, timeoutMs)
    if res then return res end
    log.warn('http: libcurl request failed (%s) — retrying with the curl CLI', tostring(e))
    local res2, e2 = C.post(u, headers, body, timeoutMs)
    if res2 then return res2 end
    return nil, tostring(e) .. '; curl CLI fallback: ' .. tostring(e2)
  end

  if backend == 'winhttp' then
    if not IS_WINDOWS then return nil, 'winhttp backend is Windows-only' end
    local ok, err = W.load()
    if not ok then return nil, 'winhttp.dll not loadable: ' .. tostring(err) end
    local res, e = W.post(u, headers, body, timeoutMs)
    if res then return res end
    log.warn('http: WinHTTP request failed (%s) — retrying with curl.exe', tostring(e))
    local res2, e2 = C.post(u, headers, body, timeoutMs)
    if res2 then return res2 end
    return nil, tostring(e) .. '; curl fallback: ' .. tostring(e2)
  end

  return nil, 'unknown http backend: ' .. tostring(backend)
end

--- Blocking POST.  Returns {status=, body=, headers=} or nil, err.
function http.post(url, headers, body, opts)
  opts = opts or {}
  local u, e = parseUrl(url)
  if not u then return nil, e end

  local timeoutMs = opts.timeoutMs or http.DEFAULT_TIMEOUT_MS
  local backend = opts.backend or http.preferBackend or 'auto'
  local hdrs = copyHeaders(headers)

  local res, err = oneShot(u, hdrs, body, timeoutMs, backend)
  if not res then return nil, err end

  if undecodedBody(res) and not opts.noAcceptEncodingRetry then
    local ce = getHeader(res.headers, 'content-encoding')
    log.warn('http: response uses Content-Encoding %q which we cannot decode — retrying once without Accept-Encoding',
             tostring(ce))
    removeHeader(hdrs, 'Accept-Encoding')
    local res2, err2 = oneShot(u, hdrs, body, timeoutMs, backend)
    if res2 then return res2 end
    return nil, 'retry without Accept-Encoding failed: ' .. tostring(err2)
  end

  return res
end

-- exposed for tests / diagnostics
http._parseUrl = parseUrl
http._parseRawHeaders = parseRawHeaders
http._sortedHeaderList = sortedHeaderList
http._looksLikeText = looksLikeText
http._shellQuote = shq

return http
