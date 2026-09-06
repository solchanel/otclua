--[==[============================================================================
bot/config.lua -- load + save the user's REAL vBot 4.8 config files, unchanged.

Work item F3.  Behaviour source: docs/vbot/bot-core.md  §2, §4 and the
"Configuration format" / "VERIFIER (Corrections)" sections; the on-disk truth is
D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\.

Five stores (BOT.md "Config compatibility"):

  vBot_configs/profile_<N>/HealBot.json      healing rules + ConditionPanel
  vBot_configs/profile_<N>/AttackBot.json    attack entries
  vBot_configs/profile_<N>/Supplies.json     supply thresholds
  cavebot_configs/<name>.cfg                 "type:value" per line, route order
  targetbot_configs/<name>.json              { targeting = [...], looting = {...} }
  storage/profile_<N>.json                   persisted runtime storage

------------------------------------------------------------------------------
WHY THIS FILE HAS ITS OWN JSON CODEC
------------------------------------------------------------------------------
lib/json.lua is rxi/json.lua -- exactly the same file otclient ships as
modules/corelib/json.lua, so `json.encode(t, 2)` in vBot really does emit
COMPACT json (the second argument is ignored; every real config file on disk is
one single line).  We match that byte for byte.

rxi's encoder however loses two things a "preserve unknown fields" contract
needs:

  * key ORDER  -- pairs() order, so a decode->encode round trip reshuffles every
    object and the user's file churns on every save;
  * the ARRAY / OBJECT distinction for EMPTY tables -- `{}` always comes back out
    as `[]`, so `targetbot_configs/true_asuras.json` ("{}" , 2 bytes on disk)
    would be rewritten as "[]".

So this module carries a small decoder/encoder pair that records, per decoded
table, its key order and whether it came from `{}` or `[]`.  That metadata lives
in a WEAK-KEYED side table (`shape`), never in the value itself: consumer modules
(healbot/attackbot/cavebot/targetbot) see plain Lua tables with no metatable and
may mutate them freely.  Keys added after the decode are appended after the
recorded ones, sorted, so output stays deterministic.  A table this module has
never seen falls back to rxi's own rule (array when `t[1] ~= nil` or `t` is
empty), which is what vBot would have written for a freshly built table.

Numbers are formatted with "%.14g" and strings escaped with rxi's exact escape
map, so re-encoding an untouched decoded value reproduces the original bytes.

------------------------------------------------------------------------------
.cfg  (table.encodeStringPairList / decodeStringPairList)
------------------------------------------------------------------------------
modules/corelib/table.lua:279-326.  A list of {key, value} pairs, one
"key:value\n" per pair; a value containing a newline is written as
"key:[[\n<value>\n]]\n".  The real decoder is regex driven:

    (?:^|\n)([^:^\n]{1,20}):?(.*)(?:$|\n)

fed to regexMatch (framework/luafunctions.cpp:95), which re-slices the subject to
`m.suffix()` after every match -- so `^` re-anchors at each remaining line.
Consequences reproduced here (VERIFIER, "Decoder regex caps the KEY at 20 chars"):

  * a key is at most 20 characters and may not contain ':', '^' or '\n'
    (the character class is [^:^\n] -- '^' is forbidden too);
  * a pair with an empty key OR an empty value is DROPPED
    (`elseif v[2]:len() > 0 and v[3]:len() > 0`), so a `stand:` line does not
    survive a round trip;
  * "key:[[" opens a multi-line value, terminated by a line containing "]]".

DELIBERATE DEVIATION (one, and it is stated): the original accumulates
multi-line bodies as `multiline .. "\n" .. v[1]` where v[1] is the FULL regex
match -- which still carries its own trailing newline.  Every load->save cycle in
real vBot therefore inserts one extra blank line between every pair of lines in a
`function:` waypoint body; the growth is visible in the user's own
cavebot_configs/vegge_casserole.cfg, whose Lua body is already double spaced.
Reproducing that would corrupt the user's routes a little more on every save, so
`decodeCfg` joins body lines with a single "\n" and `encodeCfg` writes them back
verbatim.  The result is byte-exact and idempotent.  Pass
`{ vbotCompat = true }` to `decodeCfg` to get the original, newline-growing
behaviour instead.

------------------------------------------------------------------------------
API
------------------------------------------------------------------------------
  -- codecs (pure, no I/O)
  config.jsonDecode(str)          -> value | nil, err
  config.jsonEncode(value[, ind]) -> string | nil, err       (ind: nil/0 = compact)
  config.decodeCfg(text[, opts])  -> { {key, value}, ... }
  config.encodeCfg(pairs)         -> string
  config.shapeOf(t) / config.setShape(t, kind[, order])

  -- filesystem helpers
  config.readFile(p) config.writeFileAtomic(p, s) config.fileExists(p)
  config.listDir(p) -> sorted names        config.mkdirp(p)
  config.listConfigs(dir)                  -- Config.list(dir) semantics

  -- profile object
  local c = config.new{ profileDir = "...", vprofile = 1, log = LC.log }
  c:loadHealBot()   c:saveHealBot(t)
  c:loadAttackBot() c:saveAttackBot(t)
  c:loadSupplies()  c:saveSupplies(t)
  c:loadStorage()   c:saveStorage(t)
  c:listCavebots()  c:loadCavebot(name)   c:saveCavebot(name, data)
  c:listTargetbots() c:loadTargetbot(name) c:saveTargetbot(name, t)
  c:summary()       -- counts, for the report / web panel
============================================================================]==]

local config = {}

local ok_sys, sys = pcall(require, 'lib.sys')
if not ok_sys then sys = nil end

local sfmt, srep, sbyte, ssub = string.format, string.rep, string.byte, string.sub
local tconcat, tsort = table.concat, table.sort

-- ===========================================================================
-- 0. shape registry (key order + array/object kind for decoded tables)
-- ===========================================================================
local shape = setmetatable({}, { __mode = 'k' })

--- config.shapeOf(t) -> { kind = 'object'|'array', order = {key,...} } | nil
function config.shapeOf(t) return shape[t] end

--- Tag a table so jsonEncode emits it as an object/array with the given key order.
function config.setShape(t, kind, order)
    if type(t) ~= 'table' then return t end
    shape[t] = { kind = kind, order = order }
    return t
end

function config.markArray(t)  return config.setShape(t, 'array') end
function config.markObject(t, order) return config.setShape(t, 'object', order) end

-- A distinguishable JSON null.  No file in the reference profile contains one,
-- but a decoder that silently drops keys is not a "preserve unknown fields"
-- decoder, so nulls survive the round trip.
config.null = setmetatable({}, { __tostring = function() return 'null' end })

-- ===========================================================================
-- 1. JSON decode (order + shape preserving)
-- ===========================================================================
local function jerr(str, idx, msg)
    local line, col = 1, 1
    for i = 1, math.min(idx - 1, #str) do
        if sbyte(str, i) == 10 then line, col = line + 1, 1 else col = col + 1 end
    end
    error(sfmt('json: %s at line %d col %d (offset %d)', msg, line, col, idx), 0)
end

local WS = { [32] = true, [9] = true, [10] = true, [13] = true }

local function skipWs(s, i)
    while i <= #s and WS[sbyte(s, i)] do i = i + 1 end
    return i
end

local ESC = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f',
              n = '\n', r = '\r', t = '\t' }

local function utf8enc(n)
    if n < 0x80 then return string.char(n) end
    if n < 0x800 then
        return string.char(0xC0 + math.floor(n / 0x40), 0x80 + (n % 0x40))
    end
    if n < 0x10000 then
        return string.char(0xE0 + math.floor(n / 0x1000),
                           0x80 + (math.floor(n / 0x40) % 0x40), 0x80 + (n % 0x40))
    end
    return string.char(0xF0 + math.floor(n / 0x40000),
                       0x80 + (math.floor(n / 0x1000) % 0x40),
                       0x80 + (math.floor(n / 0x40) % 0x40), 0x80 + (n % 0x40))
end

local parseValue

local function parseString(s, i)
    i = i + 1                              -- skip the opening quote
    local out, start = {}, i
    while true do
        if i > #s then jerr(s, i, 'unterminated string') end
        local c = sbyte(s, i)
        if c == 34 then                    -- '"'
            out[#out + 1] = ssub(s, start, i - 1)
            return tconcat(out), i + 1
        elseif c == 92 then                -- '\'
            out[#out + 1] = ssub(s, start, i - 1)
            local e = ssub(s, i + 1, i + 1)
            if e == 'u' then
                local hex = ssub(s, i + 2, i + 5)
                local n = tonumber(hex, 16)
                if not n or #hex < 4 then jerr(s, i, 'bad \\u escape') end
                i = i + 6
                -- surrogate pair
                if n >= 0xD800 and n <= 0xDBFF and ssub(s, i, i + 1) == '\\u' then
                    local lo = tonumber(ssub(s, i + 2, i + 5), 16)
                    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                        n = 0x10000 + (n - 0xD800) * 0x400 + (lo - 0xDC00)
                        i = i + 6
                    end
                end
                out[#out + 1] = utf8enc(n)
            else
                local r = ESC[e]
                if not r then jerr(s, i, 'bad escape \\' .. tostring(e)) end
                out[#out + 1] = r
                i = i + 2
            end
            start = i
        else
            i = i + 1
        end
    end
end

local function parseNumber(s, i)
    local j = i
    while j <= #s do
        local c = ssub(s, j, j)
        if c:match('[%d%+%-%.eE]') then j = j + 1 else break end
    end
    local text = ssub(s, i, j - 1)
    local n = tonumber(text)
    if not n then jerr(s, i, 'bad number ' .. text) end
    return n, j
end

local function parseArray(s, i)
    local t = {}
    shape[t] = { kind = 'array' }
    i = skipWs(s, i + 1)
    if ssub(s, i, i) == ']' then return t, i + 1 end
    local n = 0
    while true do
        local v
        v, i = parseValue(s, i)
        n = n + 1
        t[n] = v
        i = skipWs(s, i)
        local c = ssub(s, i, i)
        if c == ',' then i = skipWs(s, i + 1)
        elseif c == ']' then return t, i + 1
        else jerr(s, i, "expected ',' or ']'") end
    end
end

local function parseObject(s, i)
    local t, order = {}, {}
    shape[t] = { kind = 'object', order = order }
    i = skipWs(s, i + 1)
    if ssub(s, i, i) == '}' then return t, i + 1 end
    while true do
        if ssub(s, i, i) ~= '"' then jerr(s, i, 'expected a string key') end
        local k
        k, i = parseString(s, i)
        i = skipWs(s, i)
        if ssub(s, i, i) ~= ':' then jerr(s, i, "expected ':'") end
        i = skipWs(s, i + 1)
        local v
        v, i = parseValue(s, i)
        if t[k] == nil then order[#order + 1] = k end
        t[k] = v
        i = skipWs(s, i)
        local c = ssub(s, i, i)
        if c == ',' then i = skipWs(s, i + 1)
        elseif c == '}' then return t, i + 1
        else jerr(s, i, "expected ',' or '}'") end
    end
end

parseValue = function(s, i)
    i = skipWs(s, i)
    local c = ssub(s, i, i)
    if c == '"' then return parseString(s, i) end
    if c == '{' then return parseObject(s, i) end
    if c == '[' then return parseArray(s, i) end
    if c == 't' then
        if ssub(s, i, i + 3) ~= 'true' then jerr(s, i, 'bad literal') end
        return true, i + 4
    end
    if c == 'f' then
        if ssub(s, i, i + 4) ~= 'false' then jerr(s, i, 'bad literal') end
        return false, i + 5
    end
    if c == 'n' then
        if ssub(s, i, i + 3) ~= 'null' then jerr(s, i, 'bad literal') end
        return config.null, i + 4
    end
    if c:match('[%d%-]') then return parseNumber(s, i) end
    jerr(s, i, "unexpected character '" .. c .. "'")
end

--- config.jsonDecode(str) -> value | nil, err
function config.jsonDecode(str)
    if type(str) ~= 'string' then return nil, 'jsonDecode: expected a string' end
    local ok, v, i = pcall(parseValue, str, 1)
    if not ok then return nil, tostring(v) end
    i = skipWs(str, i)
    if i <= #str then return nil, sfmt('json: trailing garbage at offset %d', i) end
    return v
end

-- ===========================================================================
-- 2. JSON encode (compact by default -- exactly what vBot writes)
-- ===========================================================================
-- rxi/json.lua's escape map, verbatim (lib/json.lua:36-51).
local ESCMAP = { ['\\'] = '\\\\', ['"'] = '\\"', ['\b'] = '\\b', ['\f'] = '\\f',
                 ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function escChar(c)
    return ESCMAP[c] or sfmt('\\u%04x', sbyte(c))
end

local function encString(v)
    return '"' .. v:gsub('[%z\1-\31\\"]', escChar) .. '"'
end

local function encNumber(v)
    if v ~= v or v <= -math.huge or v >= math.huge then
        error("json: unexpected number value '" .. tostring(v) .. "'", 0)
    end
    return sfmt('%.14g', v)
end

local encValue

local function objectKeys(t)
    local sh = shape[t]
    local keys, seen = {}, {}
    if sh and sh.order then
        for _, k in ipairs(sh.order) do
            if t[k] ~= nil and not seen[k] then
                seen[k] = true
                keys[#keys + 1] = k
            end
        end
    end
    local extra = {}
    for k in pairs(t) do
        if not seen[k] then
            if type(k) ~= 'string' then
                error('json: invalid table: mixed or invalid key types', 0)
            end
            extra[#extra + 1] = k
        end
    end
    tsort(extra)
    for _, k in ipairs(extra) do keys[#keys + 1] = k end
    return keys
end

local function isArrayTable(t)
    local sh = shape[t]
    if sh then return sh.kind == 'array' end
    -- rxi's rule, so freshly built tables serialise the way vBot would write them
    return rawget(t, 1) ~= nil or next(t) == nil
end

encValue = function(v, indent, depth, stack)
    local tv = type(v)
    if v == config.null then return 'null' end
    if v == nil then return 'null' end
    if tv == 'boolean' then return tostring(v) end
    if tv == 'number' then return encNumber(v) end
    if tv == 'string' then return encString(v) end
    if tv ~= 'table' then error("json: unexpected type '" .. tv .. "'", 0) end

    if stack[v] then error('json: circular reference', 0) end
    stack[v] = true

    local nl, pad, pad2, colon = '', '', '', ':'
    if indent and indent > 0 then
        nl    = '\n'
        pad   = srep(' ', indent * (depth + 1))
        pad2  = srep(' ', indent * depth)
        colon = ': '
    end

    local out
    if isArrayTable(v) then
        local n = #v
        if n == 0 then
            out = '[]'
        else
            local parts = {}
            for i = 1, n do
                parts[i] = pad .. encValue(v[i], indent, depth + 1, stack)
            end
            out = '[' .. nl .. tconcat(parts, ',' .. nl) .. nl .. pad2 .. ']'
        end
    else
        local keys = objectKeys(v)
        if #keys == 0 then
            out = '{}'
        else
            local parts = {}
            for i = 1, #keys do
                local k = keys[i]
                parts[i] = pad .. encString(k) .. colon ..
                           encValue(v[k], indent, depth + 1, stack)
            end
            out = '{' .. nl .. tconcat(parts, ',' .. nl) .. nl .. pad2 .. '}'
        end
    end

    stack[v] = nil
    return out
end

--- config.jsonEncode(value[, indent]) -> string | nil, err
--- indent nil/0 => compact, which is what otclient's json.encode(t, 2) actually
--- produces (the indent argument of rxi/json.lua is ignored).
function config.jsonEncode(value, indent)
    local ok, res = pcall(encValue, value, indent, 0, {})
    if not ok then return nil, tostring(res) end
    return res
end

-- ===========================================================================
-- 3. string-pair list (.cfg)
-- ===========================================================================
local KEY_MAX = 20                      -- [^:^\n]{1,20}

-- Is byte b legal inside a key?  ':' (58), '^' (94) and '\n' (10) are not.
local function keyChar(b)
    return b ~= nil and b ~= 58 and b ~= 94 and b ~= 10
end

-- Split into lines WITHOUT losing information: returns an array of lines and a
-- flag telling whether the text ended with a newline.
local function splitLines(text)
    local lines, i, n = {}, 1, #text
    if n == 0 then return lines, false end
    while i <= n + 1 do
        local j = text:find('\n', i, true)
        if not j then
            if i <= n then lines[#lines + 1] = ssub(text, i) end
            return lines, false
        end
        lines[#lines + 1] = ssub(text, i, j - 1)
        i = j + 1
        if i == n + 1 then return lines, true end
    end
    return lines, false
end

-- Split one line into (key, value) with the regex's exact rules.
local function splitPair(line)
    local n = #line
    local k = 0
    while k < KEY_MAX and k < n and keyChar(sbyte(line, k + 1)) do k = k + 1 end
    if k == 0 then return '', line end
    local key = ssub(line, 1, k)
    local rest = ssub(line, k + 1)
    if ssub(rest, 1, 1) == ':' then rest = ssub(rest, 2) end
    return key, rest
end

--- config.decodeCfg(text[, opts]) -> { {key, value}, ... }
--- opts.vbotCompat = true reproduces the upstream newline-growing multiline bug.
function config.decodeCfg(text, opts)
    opts = opts or {}
    local out = {}
    if type(text) ~= 'string' or #text == 0 then return out end
    local lines = splitLines(text)

    local active, mlKey, buf = false, nil, nil
    for _, line in ipairs(lines) do
        if active then
            local endPos = line:find(']]', 1, true)
            if endPos then
                if endPos > 1 then buf[#buf + 1] = ssub(line, 1, endPos - 1) end
                out[#out + 1] = { mlKey, tconcat(buf, '\n') }
                active, mlKey, buf = false, nil, nil
            else
                buf[#buf + 1] = line
            end
        else
            local key, value = splitPair(line)
            if ssub(value, 1, 2) == '[[' then
                active, mlKey, buf = true, key, {}
                local head = ssub(value, 3)
                if #head > 0 then buf[1] = head end
            elseif #key > 0 and #value > 0 then
                -- the original DROPS empty keys and empty values
                out[#out + 1] = { key, value }
            end
        end
    end
    -- An unterminated [[ block: keep what we have rather than losing the action.
    if active and buf then out[#out + 1] = { mlKey, tconcat(buf, '\n') } end

    if opts.vbotCompat then
        -- Upstream joins with an extra newline per line (see the header note).
        for _, p in ipairs(out) do
            if p[2]:find('\n', 1, true) then p[2] = p[2]:gsub('\n', '\n\n') .. '\n' end
        end
    end
    return out
end

--- config.encodeCfg(pairs) -> string   (table.encodeStringPairList, verbatim)
function config.encodeCfg(pairs_)
    local out = {}
    for _, p in ipairs(pairs_ or {}) do
        local k, v = tostring(p[1] or p.key or ''), tostring(p[2] or p.value or '')
        if v:find('\n', 1, true) then
            out[#out + 1] = k .. ':[[\n' .. v .. '\n]]\n'
        else
            out[#out + 1] = k .. ':' .. v .. '\n'
        end
    end
    return tconcat(out)
end

-- backwards-compatible aliases matching the corelib names
config.decodeStringPairList = config.decodeCfg
config.encodeStringPairList = config.encodeCfg

-- ===========================================================================
-- 4. filesystem
-- ===========================================================================
local isWindows = (sys and sys.isWindows) or (package.config:sub(1, 1) == '\\')

local function norm(p)
    return (tostring(p or ''):gsub('\\', '/'):gsub('//+', '/'))
end
config.norm = norm

function config.join(...)
    local parts = {}
    for i = 1, select('#', ...) do
        local p = select(i, ...)
        if p ~= nil and p ~= '' then parts[#parts + 1] = norm(p):gsub('/+$', '') end
    end
    return norm(tconcat(parts, '/'))
end

function config.readFile(path)
    local f, err = io.open(path, 'rb')
    if not f then return nil, err or ('cannot open ' .. tostring(path)) end
    local data = f:read('*a')
    f:close()
    return data or ''
end

function config.fileExists(path)
    local f = io.open(path, 'rb')
    if f then f:close(); return true end
    return false
end

-- ---- directory listing -----------------------------------------------------
-- FFI first (no subprocess), io.popen as the fallback.  Both return names only,
-- sorted alphabetically -- the same guarantee resourcemanager.cpp's files.sort()
-- gives Config.list().
local listDirFFI
do
    local ok_ffi, ffi = pcall(require, 'ffi')
    if ok_ffi then
        local function cdef(s) pcall(ffi.cdef, s) end
        if isWindows then
            cdef [[
                typedef struct { unsigned long dwLowDateTime, dwHighDateTime; } LC_FILETIME;
                typedef struct {
                    unsigned long dwFileAttributes;
                    LC_FILETIME ftCreationTime, ftLastAccessTime, ftLastWriteTime;
                    unsigned long nFileSizeHigh, nFileSizeLow;
                    unsigned long dwReserved0, dwReserved1;
                    char cFileName[260];
                    char cAlternateFileName[14];
                } LC_WIN32_FIND_DATAA;
                void* FindFirstFileA(const char*, LC_WIN32_FIND_DATAA*);
                int   FindNextFileA(void*, LC_WIN32_FIND_DATAA*);
                int   FindClose(void*);
                int   CreateDirectoryA(const char*, void*);
            ]]
            local INVALID = ffi.cast('void*', -1)
            listDirFFI = function(path)
                -- void*, not LC_WIN32_FIND_DATAA*: the cdef above is a pcall, so
                -- whichever module declared FindFirstFileA FIRST owns the
                -- prototype (shim/resources.lua:114 declares the same call with
                -- its own byte-identical typedef).  void* converts to any
                -- pointer type, so this works under either declaration.
                local fd = ffi.new('LC_WIN32_FIND_DATAA')
                local fdp = ffi.cast('void*', fd)
                local h = ffi.C.FindFirstFileA(norm(path):gsub('/', '\\') .. '\\*', fdp)
                if h == INVALID then return nil, 'FindFirstFileA failed' end
                local out = {}
                repeat
                    local n = ffi.string(fd.cFileName)
                    if n ~= '.' and n ~= '..' then out[#out + 1] = n end
                until ffi.C.FindNextFileA(h, fdp) == 0
                ffi.C.FindClose(h)
                return out
            end
            config._mkdir = function(p)
                return ffi.C.CreateDirectoryA(norm(p):gsub('/', '\\'), nil) ~= 0
            end
        else
            cdef [[
                typedef struct __dirstream LC_DIR;
                struct lc_dirent {
                    uint64_t d_ino; int64_t d_off; unsigned short d_reclen;
                    unsigned char d_type; char d_name[256];
                };
                LC_DIR *opendir(const char *);
                struct lc_dirent *readdir(LC_DIR *);
                int closedir(LC_DIR *);
                int mkdir(const char *, unsigned int);
            ]]
            listDirFFI = function(path)
                local d = ffi.C.opendir(norm(path))
                if d == nil then return nil, 'opendir failed' end
                local out = {}
                while true do
                    local e = ffi.C.readdir(d)
                    if e == nil then break end
                    local n = ffi.string(e.d_name)
                    if n ~= '.' and n ~= '..' then out[#out + 1] = n end
                end
                ffi.C.closedir(d)
                return out
            end
            config._mkdir = function(p) return ffi.C.mkdir(norm(p), 493) == 0 end   -- 0755
        end
    end
end

local function listDirPopen(path)
    local cmd
    if isWindows then
        cmd = 'cmd /c dir /b "' .. norm(path):gsub('/', '\\') .. '" 2>nul'
    else
        cmd = 'ls -1 "' .. norm(path) .. '" 2>/dev/null'
    end
    local p = io.popen(cmd, 'r')
    if not p then return nil, 'io.popen failed' end
    local out = {}
    for line in p:lines() do
        line = line:gsub('\r$', '')
        if #line > 0 then out[#out + 1] = line end
    end
    p:close()
    return out
end

--- config.listDir(path) -> sorted array of entry names (never nil; {} on failure)
function config.listDir(path)
    local names
    if listDirFFI then names = listDirFFI(path) end
    if not names then names = listDirPopen(path) end
    names = names or {}
    tsort(names)
    return names
end

function config.mkdirp(path)
    path = norm(path)
    local parts, acc = {}, ''
    for seg in path:gmatch('[^/]+') do parts[#parts + 1] = seg end
    for i = 1, #parts do
        if i == 1 and parts[i]:match('^%a:$') then acc = parts[i]
        elseif acc == '' then acc = (ssub(path, 1, 1) == '/' and '/' or '') .. parts[i]
        else acc = acc .. '/' .. parts[i] end
        if config._mkdir then config._mkdir(acc)
        else os.execute((isWindows and 'mkdir "' .. acc:gsub('/', '\\') .. '" 2>nul'
                                    or 'mkdir -p "' .. acc .. '" 2>/dev/null')) end
    end
    return true
end

--- Whole-file overwrite via temp + rename.  vBot writes the target directly
--- (bot.lua:298-321) and a crash mid-write corrupts a storage file that then
--- ABORTS bot startup; docs/vbot/bot-core.md §2.2 explicitly recommends this fix.
function config.writeFileAtomic(path, text)
    path = norm(path)
    local dir = path:match('^(.*)/[^/]*$')
    if dir and not config.fileExists(path) then config.mkdirp(dir) end
    local tmp = path .. '.tmp'
    local f, err = io.open(tmp, 'wb')
    if not f then return nil, err or ('cannot write ' .. path) end
    local wok, werr = f:write(text)
    f:close()
    if not wok then os.remove(tmp); return nil, tostring(werr) end
    -- REVIEW FIX: `os.remove(path); os.rename(tmp, path)` leaves a window in which NO file
    -- exists at all -- strictly worse than the whole-file overwrite this function replaces,
    -- since a vanished storage/profile_N.json loses every macro flag and config selection.
    -- Keep the previous contents under `.bak` across the swap and restore them on failure.
    -- (Windows os.rename refuses an existing target, hence the dance rather than a plain
    -- rename over the top.)
    local bak = path .. '.bak'
    local hadOld = config.fileExists(path)
    if hadOld then
        os.remove(bak)
        if not os.rename(path, bak) then os.remove(path); hadOld = false end
    end
    local rok, rerr = os.rename(tmp, path)
    if not rok then
        -- last resort: direct write (the target may be locked)
        local g = io.open(path, 'wb')
        if not g then
            if hadOld then os.rename(bak, path) end       -- put the old file back
            os.remove(tmp)
            return nil, tostring(rerr)
        end
        g:write(text); g:close(); os.remove(tmp)
    end
    if hadOld then os.remove(bak) end
    return true
end

-- ---- Config.list(dir) ------------------------------------------------------
-- functions/config.lua:28-33 strips the extension with UNANCHORED Lua patterns
-- (`v:gsub(".json",""):gsub(".cfg","")`) and keeps only entries whose name
-- CHANGED.  The VERIFIER calls this out explicitly: "backup.json.bak" becomes
-- "backup.bak" and is kept.  Reproduced exactly -- anchoring would change which
-- files appear in the list and under what names.
function config.stripConfigExt(name)
    local s = name:gsub('.json', ''):gsub('.cfg', '')
    if s == name then return nil end
    return s
end

function config.listConfigs(dir)
    local out = {}
    for _, name in ipairs(config.listDir(dir)) do
        local s = config.stripConfigExt(name)
        if s and #s > 0 then out[#out + 1] = s end
    end
    tsort(out)
    return out
end

-- ===========================================================================
-- 5. the profile object
-- ===========================================================================
local Profile = {}
Profile.__index = Profile

local RESERVED_CFG = { config = true, extensions = true, staypositions = true }
config.RESERVED_CFG_KEYS = RESERVED_CFG

local function nolog() end
local function mklog(l)
    if type(l) == 'table' then
        return { info  = l.info  or nolog, warn = l.warn or nolog,
                 error = l.error or nolog, debug = l.debug or nolog }
    end
    return { info = nolog, warn = nolog, error = nolog, debug = nolog }
end

--- config.new{ profileDir=, vprofile=1, log= }
function config.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Profile)
    self.dir      = opts.profileDir and norm(opts.profileDir) or nil
    self.vprofile = tonumber(opts.vprofile) or 1
    self.log      = mklog(opts.log)
    return self
end

function Profile:path(...)
    if not self.dir then return nil end
    return config.join(self.dir, ...)
end

function Profile:vprofileDir() return self:path('vBot_configs', 'profile_' .. self.vprofile) end
function Profile:healBotPath()   return self:path('vBot_configs', 'profile_' .. self.vprofile, 'HealBot.json') end
function Profile:attackBotPath() return self:path('vBot_configs', 'profile_' .. self.vprofile, 'AttackBot.json') end
function Profile:suppliesPath()  return self:path('vBot_configs', 'profile_' .. self.vprofile, 'Supplies.json') end
function Profile:storagePath()   return self:path('storage', 'profile_' .. self.vprofile .. '.json') end
function Profile:cavebotDir()    return self:path('cavebot_configs') end
function Profile:targetbotDir()  return self:path('targetbot_configs') end

-- Config.load semantics (VERIFIER): BOTH branches are pcall'd; a parse failure
-- LOGS and returns {} -- it does NOT raise.  Only a genuinely missing file is an
-- error.  Reproduced, because TargetBot depends on the "corrupt json => empty,
-- non-nil data" behaviour (target.lua:131-135).
function Profile:_loadJson(path, what)
    if not path then return nil, 'no profileDir configured' end
    local text, err = config.readFile(path)
    if not text then return nil, err end
    if #text < 2 then return config.markObject({}, {}) end     -- "content < 2 chars -> {}"
    local v, derr = config.jsonDecode(text)
    if v == nil then
        self.log.error('bot/config: %s (%s) failed to parse: %s -- using {}',
                       what or 'config', path, tostring(derr))
        return config.markObject({}, {})
    end
    return v
end

function Profile:_saveJson(path, value, what)
    if not path then return nil, 'no profileDir configured' end
    local text, err = config.jsonEncode(value)          -- compact: what vBot writes
    if not text then
        self.log.error('bot/config: cannot encode %s: %s', what or 'config', tostring(err))
        return nil, err
    end
    if #text > 100 * 1024 * 1024 then                   -- bot.lua:316-318
        self.log.error('bot/config: %s is too big, above 100MB', what or 'config')
        return nil, 'too big'
    end
    return config.writeFileAtomic(path, text)
end

-- ---- the three vBot_configs files -----------------------------------------
function Profile:loadHealBot()    return self:_loadJson(self:healBotPath(),   'HealBot.json') end
function Profile:saveHealBot(t)   return self:_saveJson(self:healBotPath(),   t, 'HealBot.json') end
function Profile:loadAttackBot()  return self:_loadJson(self:attackBotPath(), 'AttackBot.json') end
function Profile:saveAttackBot(t) return self:_saveJson(self:attackBotPath(), t, 'AttackBot.json') end
function Profile:loadSupplies()   return self:_loadJson(self:suppliesPath(),  'Supplies.json') end
function Profile:saveSupplies(t)  return self:_saveJson(self:suppliesPath(),  t, 'Supplies.json') end

-- ---- storage ---------------------------------------------------------------
-- bot.lua:266-282: a JSON parse error ABORTS bot start.  We keep that signal by
-- returning nil + err (the caller decides), but a MISSING file is simply "{}".
function Profile:loadStorage()
    local path = self:storagePath()
    if not path then return {} end
    -- REVIEW FIX: writeFileAtomic keeps the previous contents under `.bak` while it swaps;
    -- if a crash landed exactly there, the .bak is the newest intact copy.
    if not config.fileExists(path) and config.fileExists(path .. '.bak') then
        path = path .. '.bak'
    end
    if not config.fileExists(path) then return config.markObject({}, {}) end
    local text, err = config.readFile(path)
    if not text then return nil, err end
    if #text < 2 then return config.markObject({}, {}) end
    local v, derr = config.jsonDecode(text)
    if v == nil then return nil, 'storage parse error: ' .. tostring(derr) end
    return v
end

function Profile:saveStorage(t) return self:_saveJson(self:storagePath(), t, 'storage') end

-- ---- cavebot ---------------------------------------------------------------
function Profile:listCavebots()   return config.listConfigs(self:cavebotDir()) end
function Profile:listTargetbots() return config.listConfigs(self:targetbotDir()) end

--- Profile:loadCavebot(name) -> {
---     name, pairs = {{key,value},...},         -- EVERYTHING, in file order
---     waypoints = {{action=,value=,index=},…}, -- pairs minus the reserved trailing keys
---     config, extensions, staypositions,       -- decoded JSON blobs (may be nil)
---     raw = <file text> }
--- The `pairs` list is what saveCavebot writes back, so unknown waypoint types
--- and unknown trailing keys survive untouched.
function Profile:loadCavebot(name)
    local path = self:path('cavebot_configs', name .. '.cfg')
    if not path then return nil, 'no profileDir configured' end
    local text, err = config.readFile(path)
    if not text then return nil, err end
    local pairs_ = config.decodeCfg(text)
    local out = { name = name, pairs = pairs_, waypoints = {}, raw = text, path = path }
    for _, p in ipairs(pairs_) do
        local k, v = p[1], p[2]
        if RESERVED_CFG[k] then
            local decoded = config.jsonDecode(v)
            if decoded == nil then
                self.log.warn("bot/config: cavebot '%s': unparsable %s blob, kept as text",
                              name, k)
            else
                out[k == 'staypositions' and 'staypositions' or k] = decoded
            end
        else
            out.waypoints[#out.waypoints + 1] =
                { action = k, value = v, index = #out.waypoints + 1 }
        end
    end
    return out
end

--- Profile:saveCavebot(name, data)
--- `data` may be (a) the table loadCavebot returned, (b) a bare pair list, or
--- (c) { waypoints=…, config=…, extensions=…, staypositions=… }.
--- The three reserved pairs are appended in vBot's order, and `config` is
--- CONDITIONAL (cavebot.lua:590-609 -- a loader must tolerate two trailing pairs).
function Profile:saveCavebot(name, data)
    local path = self:path('cavebot_configs', name .. '.cfg')
    if not path then return nil, 'no profileDir configured' end

    local pairs_
    if data and data.pairs and not data.waypoints then
        pairs_ = data.pairs
    elseif data and data.waypoints then
        pairs_ = {}
        for _, w in ipairs(data.waypoints) do
            pairs_[#pairs_ + 1] = { w.action or w[1], w.value or w[2] }
        end
        if data.config ~= nil then
            pairs_[#pairs_ + 1] = { 'config', (config.jsonEncode(data.config)) }
        end
        if data.extensions ~= nil then
            pairs_[#pairs_ + 1] = { 'extensions', (config.jsonEncode(data.extensions)) }
        end
        if data.staypositions ~= nil then
            pairs_[#pairs_ + 1] = { 'staypositions', (config.jsonEncode(data.staypositions)) }
        end
    else
        pairs_ = data or {}
    end
    return config.writeFileAtomic(path, config.encodeCfg(pairs_))
end

--- Byte-preserving variant: writes exactly the pair list handed in.
function Profile:saveCavebotRaw(name, pairs_)
    local path = self:path('cavebot_configs', name .. '.cfg')
    if not path then return nil, 'no profileDir configured' end
    return config.writeFileAtomic(path, config.encodeCfg(pairs_))
end

-- ---- targetbot -------------------------------------------------------------
function Profile:loadTargetbot(name)
    return self:_loadJson(self:path('targetbot_configs', name .. '.json'),
                          'targetbot_configs/' .. tostring(name))
end

function Profile:saveTargetbot(name, t)
    return self:_saveJson(self:path('targetbot_configs', name .. '.json'), t,
                          'targetbot_configs/' .. tostring(name))
end

-- ---- summary (for the report + the web panel) ------------------------------
local function len(t) return type(t) == 'table' and #t or 0 end

function Profile:summary()
    local s = { profileDir = self.dir, vprofile = self.vprofile,
                healbot = {}, attackbot = {}, supplies = {},
                cavebots = {}, targetbots = {}, storage = {} }

    local hb = self:loadHealBot()
    if type(hb) == 'table' then
        s.healbot.profiles = len(hb.healbot)
        s.healbot.current  = hb.currentHealBotProfile
        s.healbot.rules    = 0
        s.healbot.perProfile = {}
        for i, p in ipairs(hb.healbot or {}) do
            local n = len(p.spellTable) + len(p.itemTable)
            s.healbot.rules = s.healbot.rules + n
            s.healbot.perProfile[i] = { name = p.name, enabled = p.enabled,
                                        spells = len(p.spellTable), items = len(p.itemTable) }
        end
        s.healbot.conditions = hb.ConditionPanel and true or false
    end

    local ab = self:loadAttackBot()
    if type(ab) == 'table' then
        s.attackbot.profiles = len(ab.AttackBot)
        s.attackbot.current  = ab.currentBotProfile
        s.attackbot.entries  = 0
        s.attackbot.perProfile = {}
        for i, p in ipairs(ab.AttackBot or {}) do
            local n = len(p.attackTable)
            s.attackbot.entries = s.attackbot.entries + n
            s.attackbot.perProfile[i] = { entries = n }
        end
    end

    local sp = self:loadSupplies()
    if type(sp) == 'table' and type(sp.supplies) == 'table' then
        s.supplies.current = sp.supplies.currentProfile
        s.supplies.profiles = {}
        for k, v in pairs(sp.supplies) do
            if type(v) == 'table' then
                local items = 0
                for _ in pairs(v.items or {}) do items = items + 1 end
                s.supplies.profiles[k] = items
            end
        end
    end

    for _, name in ipairs(self:listCavebots()) do
        local cb = self:loadCavebot(name)
        s.cavebots[#s.cavebots + 1] = {
            name = name,
            waypoints = cb and #cb.waypoints or 0,
            hasConfig = cb and cb.config ~= nil or false,
            stayPositions = cb and cb.staypositions and (function()
                local n = 0; for _ in pairs(cb.staypositions) do n = n + 1 end; return n
            end)() or 0,
        }
    end

    for _, name in ipairs(self:listTargetbots()) do
        local tb = self:loadTargetbot(name)
        local loot = tb and tb.looting or nil
        s.targetbots[#s.targetbots + 1] = {
            name = name,
            creatures = tb and len(tb.targeting) or 0,
            lootItems = loot and len(loot.items) or 0,
            lootContainers = loot and len(loot.containers) or 0,
        }
    end

    local st = self:loadStorage()
    if type(st) == 'table' then
        local n = 0
        for _ in pairs(st) do n = n + 1 end
        s.storage.keys = n
        local m = 0
        for _ in pairs(st._macros or {}) do m = m + 1 end
        s.storage.macros = m
        s.storage.configs = st._configs
    end

    return s
end

config.Profile = Profile
return config
