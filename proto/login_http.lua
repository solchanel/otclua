--[[ proto/login_http.lua — the HTTPS half of the Gunzodus 1530 login.

  Spec: docs/login-http-and-packet.md §1 (+ its VERIFIER corrections).

    POST https://www.gunzodus.net/game/login/1530
    Accept: */*                     (cpp-httplib default)
    Accept-Encoding: br             (vcpkg httplib build: BROTLI=TRUE)
    Connection: close
    Content-Type: application/json
    Host: www.gunzodus.net
    User-Agent: Mozilla/5.0
    {"email":"…","password":"…","stayloggedin":true,"type":"login"}

  nlohmann::json::dump() emits object keys in LEXICOGRAPHIC order, compact, no
  spaces; with a 2FA token the body therefore is
    {"authenticatorToken":"…","email":"…","password":"…","stayloggedin":true,"token":"…","type":"login"}
  The body is written by hand (never with Lua's %q, which is not JSON quoting —
  see the VERIFIER correction on the pseudocode) so the byte order is fixed.

  API:
    login_http.login{account=, password=, token=, url=, timeoutMs=}
        -> { sessionKey=, worlds=, characters=, premiumUntil= }
         | nil, message, code
    login_http.buildBody(account, password, token) -> string      (testable)
    login_http.headers(host)                       -> table       (testable)
    login_http.parseResponse(status, body)         -> result | nil, message, code

  Returned structure (API.md `handshake.httpLogin`):
    result.sessionKey                  session.sessionkey
    result.worlds[id] = { id, name, host, port, previewState, pvpType, raw }
                                       host = externaladdressprotected
                                       port = externalportprotected
    result.characters[i] = { name, worldId, level, vocation,
                             world, host, port, raw }
  `code` is the server's numeric errorCode when it sent one (6 = authenticator
  token required → ask for the token and retry), otherwise nil.
]]

local json = require('lib.json')
local http = require('lib.http')

local log
do
  local ok, m = pcall(require, 'lib.log')
  if ok and type(m) == 'table' and type(m.warn) == 'function' then
    log = m
  else
    log = setmetatable({}, { __index = function() return function() end end })
  end
end

local login_http = {}

login_http.URL = 'https://www.gunzodus.net/game/login/1530'
login_http.USER_AGENT = 'Mozilla/5.0'
login_http.ACCEPT_ENCODING = 'br'
login_http.ERROR_TOKEN_REQUIRED = 6

--------------------------------------------------------------- JSON encoding --

-- Exactly nlohmann::json's string escaping: " and \ escaped, the five short
-- escapes, every other control byte < 0x20 as \u00XX, everything else raw
-- (UTF-8 passes through untouched).
local ESCAPES = {
  ['"'] = '\\"', ['\\'] = '\\\\',
  ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function jsonString(s)
  s = tostring(s or '')
  local out = s:gsub('[%z\1-\31"\\]', function(c)
    local e = ESCAPES[c]
    if e then return e end
    return string.format('\\u%04x', c:byte())
  end)
  return '"' .. out .. '"'
end

--- Build the login JSON body byte-for-byte like the reference client.
function login_http.buildBody(account, password, token)
  if token == '' then token = nil end
  local parts = {}
  if token then
    parts[#parts + 1] = '"authenticatorToken":' .. jsonString(token)
  end
  parts[#parts + 1] = '"email":' .. jsonString(account)
  parts[#parts + 1] = '"password":' .. jsonString(password)
  parts[#parts + 1] = '"stayloggedin":true'
  if token then
    parts[#parts + 1] = '"token":' .. jsonString(token)
  end
  parts[#parts + 1] = '"type":"login"'
  return '{' .. table.concat(parts, ',') .. '}'
end

--- The exact header set the reference client puts on the wire.
function login_http.headers(host)
  return {
    ['Accept'] = '*/*',
    ['Accept-Encoding'] = login_http.ACCEPT_ENCODING,
    ['Connection'] = 'close',
    ['Content-Type'] = 'application/json',
    ['Host'] = host,
    ['User-Agent'] = login_http.USER_AGENT,
  }
end

------------------------------------------------------------------- response ---

local function num(v)
  if type(v) == 'number' then return v end
  if type(v) == 'string' then return tonumber(v) end
  return nil
end

local function str(v)
  if type(v) == 'string' then return v end
  if type(v) == 'number' then return tostring(v) end
  return nil
end

--- Turn a raw (status, body) into the login structure or (nil, message, code).
function login_http.parseResponse(status, body)
  local ok, doc = pcall(json.decode, body or '')
  if not ok or type(doc) ~= 'table' then
    if status and status ~= 200 then
      return nil, string.format('HTTP %d (%s)', status,
                                'Invalid response received from server (expected JSON).'), nil
    end
    return nil, 'Invalid response received from server (expected JSON).', nil
  end

  -- errorCode / errorMessage (httplogin.cpp:506-511)
  local code = num(doc.errorCode)
  if code and code ~= 0 then
    local msg = str(doc.errorMessage)
    if not msg or msg == '' then msg = 'Authenticator token required.' end
    return nil, msg, code
  end

  if status and status ~= 200 then
    return nil, string.format('HTTP %d', status), nil
  end

  if type(doc.session) ~= 'table' or type(doc.playdata) ~= 'table' then
    return nil, 'Missing session or playdata.', nil
  end
  local playdata = doc.playdata
  if type(playdata.characters) ~= 'table' or type(playdata.worlds) ~= 'table' then
    return nil, 'Missing characters or worlds.', nil
  end

  local sessionKey = str(doc.session.sessionkey)
  if not sessionKey or sessionKey == '' then
    return nil, 'Missing session.sessionkey.', nil
  end

  local worlds = {}
  for k, w in pairs(playdata.worlds) do
    if type(w) == 'table' then
      local id = num(w.id) or num(k)
      if id then
        worlds[id] = {
          id           = id,
          name         = str(w.name),
          host         = str(w.externaladdressprotected),
          port         = num(w.externalportprotected),
          previewState = num(w.previewstate) == 1,
          pvpType      = num(w.pvptype),
          raw          = w,
        }
      end
    end
  end

  local characters = {}
  for _, c in ipairs(playdata.characters) do
    if type(c) == 'table' then
      local worldId = num(c.worldid)
      local w = worldId and worlds[worldId]
      characters[#characters + 1] = {
        name     = str(c.name),
        worldId  = worldId,
        level    = num(c.level),
        vocation = num(c.vocation) or str(c.vocation),
        world    = w and w.name or nil,
        host     = w and w.host or nil,
        port     = w and w.port or nil,
        raw      = c,
      }
    end
  end

  return {
    sessionKey   = sessionKey,
    worlds       = worlds,
    characters   = characters,
    premiumUntil = num(doc.session.premiumuntil),
  }
end

---------------------------------------------------------------------- login ---

--- Blocking HTTPS account login.
--  opts = { account=, password=, token=, url=, timeoutMs=, http= }
--  -> result | nil, message, code
function login_http.login(opts)
  opts = opts or {}
  local account = opts.account or opts.email
  local password = opts.password
  if type(account) ~= 'string' or account == '' then
    return nil, 'account (email) is required', nil
  end
  if type(password) ~= 'string' then
    return nil, 'password is required', nil
  end

  local url = opts.url or login_http.URL
  local client = opts.http or http
  local u, e = http._parseUrl(url)
  if not u then return nil, e, nil end

  local body = login_http.buildBody(account, password, opts.token)
  local headers = login_http.headers(u.host)

  log.info('login: POST %s (%d byte body)', url, #body)   -- never log the body
  local res, err = client.post(url, headers, body, { timeoutMs = opts.timeoutMs })
  if not res then
    return nil, 'login request failed: ' .. tostring(err), nil
  end
  log.info('login: HTTP %d, %d bytes', res.status, #(res.body or ''))

  return login_http.parseResponse(res.status, res.body)
end

-- exposed for tests
login_http._jsonString = jsonString

return login_http
