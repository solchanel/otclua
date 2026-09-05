-- =====================================================================
-- proto/handshake.lua -- HTTPS account login + the login-handshake packets
-- for Gunzodus / protocol 1530 / OS 61 (CLIENTOS_GUNZ_WINDOWS).
--
-- Specs: docs/login-http-and-packet.md, docs/framing-crypto.md
--        (the VERIFIER "Corrections" sections are authoritative).
--
-- Everything here returns PACKET BODIES (opcode byte first). Framing,
-- padding, XTEA, the sequence number and the block count belong to
-- proto/transport.lua -- pass each body to transport:send().
-- =====================================================================

local bit = require('bit')

local handshake = {}

-- lazily required so this module loads before lib/ is fully populated
local _rsa, _http, _json, _sys, _lh
local function RSA()  if not _rsa  then _rsa  = require('lib.rsa')  end return _rsa  end
local function HTTP() if not _http then _http = require('lib.http') end return _http end
local function JSON() if not _json then _json = require('lib.json') end return _json end
local function SYS()  if not _sys  then _sys  = require('lib.sys')  end return _sys  end
local function LOGINHTTP() if not _lh then _lh = require('proto.login_http') end return _lh end

local floor  = math.floor
local schar  = string.char
local srep   = string.rep
local concat = table.concat

-- ------------------------------------------------------------- constants
handshake.CLIENT_VERSION   = 1530
handshake.PROTOCOL_VERSION = 1530
handshake.OS_ID            = 61          -- CLIENTOS_GUNZ_WINDOWS
handshake.RSA_SIZE         = 128
handshake.RSA_E            = 65537
-- GUNZODUS_RSA, modules/gamelib/const.lua:329-333 (1024-bit, 309 digits)
handshake.RSA_N =
    '1246273883242314476756177697013661178426967215489621567086238956474741743463'
 .. '0052169619083393458028702016427835941419554951092542821267669922632801272126'
 .. '9908075137544578076908574898562097520735449263292165722384481748538646580304'
 .. '4527347500039275190952490002863672832304502172217842140700326376575967800691'
 .. '18601'
-- Emitted only when the Lua getLoginExtendedData hooks are empty, which they
-- always are in the reference tree (isGunzOs && clientVersion >= 1281).
handshake.EXTENDED_DATA = '261'
-- Decimal text of data/things/1530/assets.json.sha256 in the reference
-- install. resolveContentRevision() reproduces the C++ probe; this is the
-- fallback when no file and no parameter is supplied (the C++ would send
-- "0", which the live server is documented not to expect).
handshake.DEFAULT_CONTENT_REVISION = '42196'

handshake.LOGIN_URL = 'https://www.gunzodus.net/game/login/1530'

-- --------------------------------------------------------------- writers
local function u8(v)  return schar(v % 256) end
local function u16(v) v = v % 0x10000
    return schar(v % 256, floor(v / 256)) end
local function u32(v) v = v % 0x100000000
    return schar(v % 256, floor(v / 0x100) % 256,
                 floor(v / 0x10000) % 256, floor(v / 0x1000000) % 256) end
-- OutputMessage::addString == u16 LE length + raw bytes
local function str(s) s = s or ''
    if #s > 0xFFFF then error('handshake: string too long') end
    return u16(#s) .. s end

-- =============================================================== 1. hwid
-- getSystemVolumeFingerprint (protocolgamesend.cpp:47-57):
--   uint32_t h = 2166136261; for c in accountName { h ^= c; h *= 16777619; }
--   return fmt::format("{:04X}-{:04X}", h >> 16, h & 0xFFFF);
-- The 32-bit wraparound is load-bearing. `h * 16777619` overflows a double's
-- 53-bit exact range (h < 2^32, 16777619 ~ 2^24 -> product ~ 2^56), so the
-- multiply is done on 16-bit halves (VERIFIER correction).
local FNV_PRIME = 16777619
function handshake.fnv1a32(s)
    local h = 2166136261
    for i = 1, #s do
        h = bit.bxor(h, s:byte(i)) % 0x100000000
        local lo = h % 0x10000
        local hi = floor(h / 0x10000)
        h = (lo * FNV_PRIME + (hi * FNV_PRIME % 0x10000) * 0x10000) % 0x100000000
    end
    return h
end

function handshake.hwid(accountName)
    local h = handshake.fnv1a32(accountName or '')
    return ('%04X-%04X'):format(floor(h / 0x10000), h % 0x10000)
end

-- ==================================================== 2. content revision
-- resolveGunzContentRevision (protocolgamesend.cpp:65-98): probe
-- <dir>/assets/assets.json.sha256 then <dir>/things/<clientVersion>/assets.json.sha256,
-- trim spaces and newlines, parse a u32 consuming the WHOLE string, require
-- 1 <= v <= 0xFFFF, else 0.
function handshake.resolveContentRevision(dir)
    if not dir then return 0 end
    dir = dir:gsub('[/\\]+$', '')
    local candidates = {
        dir .. '/assets/assets.json.sha256',
        dir .. '/things/' .. handshake.CLIENT_VERSION .. '/assets.json.sha256',
    }
    for _, path in ipairs(candidates) do
        local f = io.open(path, 'rb')
        if f then
            local text = f:read('*a') or ''
            f:close()
            text = text:gsub('^%s+', ''):gsub('%s+$', '')
            if text:match('^%d+$') then
                local v = tonumber(text)
                if v and v >= 1 and v <= 0xFFFF then return v end
            end
            return 0
        end
    end
    return 0
end

-- ================================================== 3. HTTPS account login
-- nlohmann::json::dump() emits object keys in LEXICOGRAPHIC order, compact.
local JSON_ESC = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}
local function jstr(s)
    s = tostring(s or '')
    s = s:gsub('[%z\1-\31"\\]', function(c)
        return JSON_ESC[c] or ('\\u%04x'):format(c:byte())
    end)
    return '"' .. s .. '"'
end

function handshake.buildLoginBody(account, password, token)
    local parts = {}
    if token and token ~= '' then
        parts[#parts + 1] = '"authenticatorToken":' .. jstr(token)
    end
    parts[#parts + 1] = '"email":' .. jstr(account)
    parts[#parts + 1] = '"password":' .. jstr(password)
    parts[#parts + 1] = '"stayloggedin":true'
    if token and token ~= '' then
        parts[#parts + 1] = '"token":' .. jstr(token)
    end
    parts[#parts + 1] = '"type":"login"'
    return '{' .. concat(parts, ',') .. '}'
end

-- handshake.httpLogin{account=, password=, token=, url=, timeoutMs=, http=}
--   -> { sessionKey=, worlds=, characters=, premiumUntil= } | nil, message, code
--
-- INTEGRATION: this is a thin delegate to proto/login_http.lua (W3), which owns
-- the byte-exact body, the exact header set, the br/gzip retry and the reference
-- client's own error strings. `code` is the server's numeric errorCode (6 =
-- authenticator token required -> prompt and retry with token=).
function handshake.httpLogin(opts)
    opts = opts or {}
    local lh = LOGINHTTP()
    local res, msg, code = lh.login{
        account   = opts.account,
        password  = opts.password,
        token     = opts.token,
        url       = opts.url or handshake.LOGIN_URL,
        timeoutMs = opts.timeoutMs,
        http      = opts.http,
    }
    if not res then return nil, msg, code end

    -- login_http exposes the world NAME as character.world; keep a .worldName
    -- alias so either spelling works for callers.
    for _, c in ipairs(res.characters or {}) do
        c.worldName = c.worldName or c.world
        if c.raw then
            c.isMain  = c.raw.ismaincharacter
            c.isHidden = c.raw.ishidden
        end
    end
    return res
end

-- =============================================== 4. the login packet (0x0A)
-- handshake.buildLoginPacket{ sessionKey=, accountName=, password=,
--     characterName=, challengeTs=, challengeRand=, contentRevision=,
--     xteaKey=, assetsDir=, extendedData= }  -> bodyString, xteaKey
--
-- accountName/password are accepted for API symmetry but are NOT sent: at
-- 1530 GameSessionKey selects the sessionKey/characterName branch and the
-- account/password/authenticator branch is dead code.
--
-- The returned body is UNFRAMED and UNENCRYPTED apart from its 128-byte RSA
-- tail. Send it with transport:send() while XTEA is still OFF (sequence 0),
-- then call transport:enableXtea(xteaKey).
function handshake.buildLoginPacket(opts)
    opts = opts or {}
    local sessionKey    = opts.sessionKey or ''
    local characterName = opts.characterName or ''
    local ts            = opts.challengeTs or 0
    local rnd           = opts.challengeRand or 0

    local cr = opts.contentRevision
    if cr == nil and opts.assetsDir then
        local v = handshake.resolveContentRevision(opts.assetsDir)
        if v ~= 0 then cr = v end
    end
    if cr == nil then cr = handshake.DEFAULT_CONTENT_REVISION end
    cr = tostring(cr)

    local key = opts.xteaKey
    if not key then
        local sys = SYS()
        key = { sys.randomU32(), sys.randomU32(), sys.randomU32(), sys.randomU32() }
    end
    if type(key) ~= 'table' or #key ~= 4 then
        error('handshake.buildLoginPacket: xteaKey must be {u32,u32,u32,u32}')
    end

    -- ---- plaintext prefix (23 bytes with a 5-char content revision)
    local head = concat{
        u8(0x0A),                                   -- ClientPendingGame
        u16(handshake.OS_ID),                       -- 61
        u16(handshake.PROTOCOL_VERSION),            -- 1530
        u32(handshake.CLIENT_VERSION),              -- GameClientVersion
        str(tostring(handshake.CLIENT_VERSION)),    -- ">= 1281" version string
        str(cr),                                    -- ">= 1334" content revision
        u8(0x00),                                   -- GamePreviewState
    }

    -- ---- RSA block: exactly 128 plaintext bytes
    local extended = opts.extendedData
    if extended == nil or extended == '' then extended = handshake.EXTENDED_DATA end
    local rsaParts = {
        u8(0x00),                                   -- first RSA byte must be 0
        u32(key[1]), u32(key[2]), u32(key[3]), u32(key[4]),
        u8(0x00),                                   -- "is gm set?"
        str(sessionKey),                            -- GameSessionKey branch
        str(characterName),
        u32(ts),                                    -- GameChallengeOnLogin
        u8(rnd),
        u16(2),                                     -- isGunzOs marker (UNVERIFIED)
    }
    -- `if (!extended.empty()) msg->addString(extended);` -- the whole field
    -- disappears when empty, it is not written as a zero-length string.
    if extended ~= '' then rsaParts[#rsaParts + 1] = str(extended) end

    local plain = concat(rsaParts)
    local fill  = handshake.RSA_SIZE - #plain
    if fill < 0 then
        error(('handshake: RSA block overflow by %d bytes (len(sessionKey)+len(characterName) must be <= 94)')
            :format(-fill))
    end
    plain = plain .. srep('\0', fill)               -- ZERO filler (not random)

    local cipher = RSA().encrypt(plain, handshake.RSA_N, handshake.RSA_E)
    if #cipher ~= handshake.RSA_SIZE then
        error('handshake: RSA output is not 128 bytes')
    end

    return head .. cipher, key
end

-- ================================================ 5. enter-game (0x0A -> )
-- ProtocolGame::sendEnterGame (protocolgamesend.cpp:227-249) sends TWO
-- SEPARATELY FRAMED packets back to back, consuming TWO sequence numbers:
--   [0x0F]
--   [0x32][0x0A][u16 len + hwid]        (OS 60..62 only, hand-built)
-- They must NOT be merged into one body. Writing them in a single socket
-- write is fine (the C++ coalesces them through its delayed-write timer).
--   for _, b in ipairs(handshake.buildEnterGameFrames(acc)) do t:send(b) end
function handshake.buildEnterGameFrames(accountName)
    local hwid = handshake.hwid(accountName)
    return {
        u8(0x0F),                                   -- ClientEnterGame
        u8(0x32) .. u8(0x0A) .. str(hwid),          -- ClientExtendedOpcode 50, sub 10
    }
end

return handshake
