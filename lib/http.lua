--[[ lib/http.lua — blocking HTTPS POST for the login flow.

  API (see API.md):
      http.post(url, headersTable, body [, opts]) -> {status=, body=, headers=} | nil, err

  `headers` is a plain name->value table; the request headers are emitted in
  case-insensitive alphabetical order, which is the order the C++ reference
  (cpp-httplib, a multimap) puts them on the wire.  `res.headers` comes back
  with LOWER-CASE keys.  `opts` (optional): { timeoutMs=, backend='auto'|
  'winhttp'|'curl', noAcceptEncodingRetry=true }.

  Backends, per docs/lua-runtime.md §3:
    * WinHTTP through FFI  (primary, ~525 ms for the login POST)
    * curl.exe via io.popen (automatic fallback when winhttp.dll cannot be
      loaded, or when a WinHTTP request fails at transport level)

  TLS: the C++ reference disables BOTH certificate and hostname verification
  for this POST (httplogin.cpp:410-411), so we do the same — see the
  one-line warning emitted on the first request.

  Redirects are never followed (the reference client does not follow them).

  Content-Encoding: WinHTTP is asked to auto-decompress gzip/deflate; if the
  response still carries an encoding we cannot decode (e.g. `br`), the request
  is retried ONCE with no Accept-Encoding header.
]]

local ffi = require('ffi')
local bit = require('bit')

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
http.backend = 'auto'          -- 'auto' | 'winhttp' | 'curl'
http.curlPath = 'C:\\Windows\\System32\\curl.exe'
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

--------------------------------------------------------------------- WinHTTP ---

local W = {}          -- winhttp backend namespace
local wh, k32         -- lazily loaded libraries
local whLoadError

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
local WINHTTP_OPTION_DECOMPRESSION   = 118
local WINHTTP_DISABLE_REDIRECTS      = 0x00000002
local WINHTTP_REDIRECT_POLICY_NEVER  = 0
local WINHTTP_DECOMPRESSION_FLAG_ALL = 0x00000003
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

local function loadWinhttp()
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

local warnedInsecure = false

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
    if not warnedInsecure then
      warnedInsecure = true
      log.warn('http: TLS certificate/hostname verification is DISABLED (matches the C++ reference client)')
    end
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

------------------------------------------------------------------------ curl ---

local C = {}

local function tempName(tag)
  local dir = os.getenv('TEMP') or os.getenv('TMP') or '.'
  return string.format('%s\\lcHttp_%s_%d_%d.tmp', dir, tag,
                       os.time(), math.random(100000, 999999))
end

local function writeFile(path, data)
  local f, e = io.open(path, 'wb')
  if not f then return nil, e end
  f:write(data)
  f:close()
  return true
end

local function readFile(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local d = f:read('*a')
  f:close()
  return d
end

function C.post(u, headers, body, timeoutMs)
  local reqFile, hdrFile, respFile = tempName('req'), tempName('hdr'), tempName('resp')
  local function clean()
    os.remove(reqFile); os.remove(hdrFile); os.remove(respFile)
  end

  local ok, e = writeFile(reqFile, body or '')
  if not ok then clean(); return nil, 'cannot write temp request file: ' .. tostring(e) end

  -- -k: match the reference client, which disables cert+hostname verification.
  -- No -L: redirects are never followed.  The body NEVER goes on the command
  -- line (cmd.exe would mangle &, %VAR%, ^ and quotes) — it is passed by file.
  local parts = {
    '"' .. http.curlPath .. '"', '-s', '-S', '--http1.1',
    '-k', '--no-keepalive',
    '--max-time', tostring(math.max(1, math.floor((timeoutMs or 20000) / 1000))),
    '-X', 'POST',
    '--data-binary', '"@' .. reqFile .. '"',
  }
  local list = sortedHeaderList(headers)
  for i = 1, #list do
    parts[#parts + 1] = '-H'
    parts[#parts + 1] = '"' .. list[i][1] .. ': ' .. list[i][2]:gsub('"', '\\"') .. '"'
  end
  parts[#parts + 1] = '-D'
  parts[#parts + 1] = '"' .. hdrFile .. '"'
  parts[#parts + 1] = '-o'
  parts[#parts + 1] = '"' .. respFile .. '"'
  parts[#parts + 1] = '-w'
  parts[#parts + 1] = '"%{http_code}"'
  parts[#parts + 1] = '"' .. u.scheme .. '://' .. u.host .. ':' .. u.port .. u.path .. '"'
  parts[#parts + 1] = '2>&1'   -- capture curl's own diagnostics for the error string

  if u.scheme == 'https' and not warnedInsecure then
    warnedInsecure = true
    log.warn('http: TLS certificate/hostname verification is DISABLED (matches the C++ reference client)')
  end

  local cmd = '"' .. table.concat(parts, ' ') .. '"'
  local p = io.popen(cmd, 'r')
  if not p then clean(); return nil, 'io.popen failed for curl.exe' end
  local out = p:read('*a') or ''
  p:close()

  local status = tonumber((out:match('(%d%d%d)%s*$')))
  local respBody = readFile(respFile) or ''
  local rawHeaders = readFile(hdrFile) or ''
  clean()

  if not status or status == 0 then
    return nil, 'curl.exe request failed (' .. (out ~= '' and out or 'no output') .. ')'
  end
  return { status = status, body = respBody,
           headers = parseRawHeaders(rawHeaders), backend = 'curl' }
end

------------------------------------------------------------------------ post ---

local function oneShot(u, headers, body, timeoutMs, backend)
  if backend == 'curl' then return C.post(u, headers, body, timeoutMs) end

  local ok, err = loadWinhttp()
  if not ok then
    if backend == 'winhttp' then return nil, 'winhttp.dll not loadable: ' .. tostring(err) end
    log.warn('http: winhttp.dll not loadable (%s) — falling back to curl.exe', tostring(err))
    return C.post(u, headers, body, timeoutMs)
  end

  local res, e = W.post(u, headers, body, timeoutMs)
  if res then return res end
  if backend == 'winhttp' then return nil, e end
  log.warn('http: WinHTTP request failed (%s) — retrying with curl.exe', tostring(e))
  local res2, e2 = C.post(u, headers, body, timeoutMs)
  if res2 then return res2 end
  return nil, tostring(e) .. '; curl fallback: ' .. tostring(e2)
end

--- Blocking POST.  Returns {status=, body=, headers=} or nil, err.
function http.post(url, headers, body, opts)
  opts = opts or {}
  local u, e = parseUrl(url)
  if not u then return nil, e end

  local timeoutMs = opts.timeoutMs or http.DEFAULT_TIMEOUT_MS
  local backend = opts.backend or http.backend or 'auto'
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

return http
