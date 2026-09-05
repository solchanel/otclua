--[[
  vbot_compat_check.lua - round-trip safety harness for the REAL vBot 4.8 config files.

  Purpose
  -------
  The luaclient reads AND WRITES the very same files the user's real
  otclient+vBot GUI keeps using.  This tool proves, against the real files,
  that our read/write path is byte-compatible with vBot's own.  It is
  deliberately standalone: plain LuaJIT (or Lua 5.1), Windows or Linux, no
  dependency on any other luaclient module, so it can be run before, during
  and after the bot layer exists.

  Usage (CLI)
  -----------
    luajit tools/vbot_compat_check.lua [dir] [--verbose] [--json <json.lua>]
    (default dir: D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8)
    Exits 0 if every file passes, 1 otherwise.

  Usage (library)
  ---------------
    local compat = dofile("tools/vbot_compat_check.lua")
    compat.parseCfg(path)        -> { waypoints={{type=,value=},..}, config={},
                                      extensions={}, stayPositions={}, ... }
    compat.serializeCfg(parsed)  -> string  (byte-compatible with vBot)
    compat.parseJson(path)       -> table
    compat.serializeJson(tbl)    -> string  (vBot's json.encode semantics)
    compat.compare(a, b)         -> ok, diffDescription
    compat.checkDirectory(dir)   -> report

  ===========================================================================
  PROVENANCE OF THE PARSER  (read this before changing anything below)
  ===========================================================================
  vBot never parses .cfg itself.  The chain is:

    cavebot/cavebot.lua:207            config = Config.setup("cavebot_configs", w, "cfg", cb)
    game_bot/functions/config.lua:70   -- load .cfg
    game_bot/functions/config.lua:72     table.decodeStringPairList(g_resources.readFileContents(file))
    game_bot/functions/config.lua:105  -- save: table.isStringPairList(value) and forcedExtension ~= "json"
    game_bot/functions/config.lua:106     g_resources.writeFileContents(file..".cfg", table.encodeStringPairList(value))

  table.encodeStringPairList / decodeStringPairList / isStringPairList live in
    modules/corelib/table.lua:269-328
  and decodeStringPairList calls the C++ global regexMatch, bound in
    src/framework/luafunctions.cpp:95-114

  Because regexMatch is std::regex (C++), it cannot be loaded from Lua.  The
  two encode/decode functions below are therefore TRANSCRIBED EXACTLY from
  modules/corelib/table.lua:279-328 (see the marked blocks), and regexMatch is
  re-implemented for the ONE fixed pattern decodeStringPairList uses, following
  luafunctions.cpp:95-114 semantics literally (leftmost match, then
  `s = m.suffix()`, 10000-match limit, no match_prev_avail so `^` re-anchors at
  the start of every remaining suffix).

  Everything else - JSON - uses the REAL rxi json.lua straight off disk
  (modules/corelib/json.lua), loaded at runtime.  Nothing is transcribed there.
]]

local M = {}

M.VERSION = "1.0.0"
M.DEFAULT_DIR = "D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8"
M.DEFAULT_JSON_LUA = "D:/Claude/otclient_mehah1530/otclient/modules/corelib/json.lua"

-- ---------------------------------------------------------------------------
-- platform / path helpers
-- ---------------------------------------------------------------------------

local IS_WINDOWS = (package.config:sub(1, 1) == "\\")

local function normalizePath(p)
  p = tostring(p or ""):gsub("\\", "/")
  p = p:gsub("//+", "/")
  p = p:gsub("/$", "")
  return p
end

local function joinPath(a, b)
  a = normalizePath(a)
  if a == "" then return b end
  return a .. "/" .. b
end

local function nativePath(p)
  if IS_WINDOWS then return (p:gsub("/", "\\")) end
  return p
end

local function baseName(p)
  return (normalizePath(p):match("([^/]+)$")) or p
end

-- read a whole file as raw bytes ("rb": never let Windows eat a \r)
local function readFile(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err or ("cannot open " .. tostring(path)) end
  local data = f:read("*a")
  f:close()
  return data or ""
end

local function fileExists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

-- Directory listing without LuaFileSystem.  Tries lfs first (if the host
-- happens to have it), then falls back to the shell.
local haveLfs, lfs = pcall(require, "lfs")

local function listDir(dir)
  local out = {}
  if haveLfs and lfs and lfs.dir then
    local ok, iter = pcall(lfs.dir, dir)
    if ok then
      for name in iter do
        if name ~= "." and name ~= ".." then out[#out + 1] = name end
      end
      table.sort(out)
      return out
    end
  end
  local cmd
  if IS_WINDOWS then
    cmd = 'dir /b "' .. nativePath(dir) .. '" 2>nul'
  else
    cmd = "ls -1 '" .. dir .. "' 2>/dev/null"
  end
  local p = io.popen(cmd, "r")
  if not p then return out end
  for line in p:lines() do
    line = line:gsub("[\r\n]+$", "")
    if line ~= "" then out[#out + 1] = line end
  end
  p:close()
  table.sort(out)
  return out
end

local function isDir(path)
  if haveLfs and lfs and lfs.attributes then
    local a = lfs.attributes(path)
    return a ~= nil and a.mode == "directory"
  end
  -- io.open on a directory fails on Windows and succeeds-but-fails-to-read
  -- on Linux; probe with the shell instead.
  local cmd
  if IS_WINDOWS then
    cmd = 'if exist "' .. nativePath(path) .. '\\*" (echo yes) else (echo no)'
  else
    cmd = "test -d '" .. path .. "' && echo yes || echo no"
  end
  local p = io.popen(cmd, "r")
  if not p then return false end
  local r = p:read("*l") or ""
  p:close()
  return r:match("yes") ~= nil
end

-- ---------------------------------------------------------------------------
-- the REAL json.lua (rxi) loaded off disk - modules/corelib/json.lua
-- ---------------------------------------------------------------------------

local realJson = nil
local realJsonPath = nil

-- json.lua is self-contained (no otclient globals): it only assigns the global
-- `json` and returns it (modules/corelib/json.lua:24, :377).  We capture the
-- return value and put the previous global `json` back so we do not leak into
-- a host that already has one.
function M.loadJson(path)
  path = normalizePath(path or os.getenv("VBOT_JSON_LUA") or M.DEFAULT_JSON_LUA)
  if not fileExists(path) then
    return nil, "json.lua not found at " .. path ..
      " (set VBOT_JSON_LUA or pass --json <path>)"
  end
  local chunk, err = loadfile(path)
  if not chunk then return nil, "cannot load json.lua: " .. tostring(err) end
  local prev = rawget(_G, "json")
  local ok, result = pcall(chunk)
  local produced = rawget(_G, "json")
  rawset(_G, "json", prev)
  if not ok then return nil, "error running json.lua: " .. tostring(result) end
  local j = (type(result) == "table" and result) or produced
  if type(j) ~= "table" or type(j.encode) ~= "function" or type(j.decode) ~= "function" then
    return nil, "json.lua did not provide encode/decode"
  end
  realJson, realJsonPath = j, path
  return j
end

local function J()
  if realJson then return realJson end
  local j, err = M.loadJson(nil)
  if not j then error(err, 0) end
  return j
end

M.jsonSourcePath = function() return realJsonPath end

-- ---------------------------------------------------------------------------
-- regexMatch emulation
-- ---------------------------------------------------------------------------
-- Faithful re-implementation of src/framework/luafunctions.cpp:95-114 for the
-- SINGLE pattern used by table.decodeStringPairList (modules/corelib/table.lua:293):
--
--     (?:^|\n)([^:^\n]{1,20}):?(.*)(?:$|\n)
--
-- Semantics reproduced, item by item:
--   * std::regex ECMAScript.  `.` does NOT match a line terminator; MSVC's and
--     libstdc++'s narrow-char implementations exclude '\n' and '\r'.
--   * `[^:^\n]` - the FIRST '^' negates the class, the SECOND is a literal, so
--     the class is "any char except ':', '^' and '\n'".  {1,20} caps the key at
--     20 characters, greedily.
--   * `$` (no std::regex::multiline flag) matches only at end of subject.
--   * The C++ loop does `regex_search(s, m, e); s = m.suffix().str();` WITHOUT
--     match_prev_avail, so on every iteration `^` re-anchors at index 0 of the
--     remaining suffix.  That is why a body line of a [[ ]] block matches with
--     an empty `^` prefix and, after a blank line, with a leading '\n' - which
--     is exactly how the blank lines in a saved function body come about.
--   * Each result row is {whole match, group1, group2}, i.e. Lua v[1]/v[2]/v[3].
--   * limit = 10000 matches, then it stops (luafunctions.cpp:96, :110-111).
--
-- No backtracking is implemented because none is reachable: once the key
-- (>= 1 char) matched, ':?' is optional, '(.*)' stops at the first '\n' or at
-- end of subject, and '(?:$|\n)' then always succeeds at that spot.
local REGEX_LIMIT = 10000

local function keyCharAllowed(c)
  return c ~= "" and c ~= ":" and c ~= "^" and c ~= "\n"
end

-- Find the leftmost match in `s`; returns start, stopExclusive, key, value.
local function searchOnce(s)
  local n = #s
  for p = 1, n do
    -- (?:^|\n) - alternation order matters: '^' is tried before '\n'
    for alt = 1, 2 do
      local cur
      if alt == 1 then
        cur = (p == 1) and p or nil          -- '^' only at index 0 of the subject
      else
        cur = (s:sub(p, p) == "\n") and (p + 1) or nil
      end
      if cur then
        -- ([^:^\n]{1,20}) greedy
        local q, k = cur, 0
        while k < 20 and keyCharAllowed(s:sub(q, q)) do
          q = q + 1; k = k + 1
        end
        if k >= 1 then
          -- ':?' greedy
          local q2 = q
          if s:sub(q2, q2) == ":" then q2 = q2 + 1 end
          -- '(.*)' greedy, stops before a line terminator
          local q3 = q2
          while true do
            local c = s:sub(q3, q3)
            if c == "" or c == "\n" or c == "\r" then break end
            q3 = q3 + 1
          end
          -- '(?:$|\n)'
          local q4
          if q3 > n then
            q4 = q3                          -- '$' at end of subject
          elseif s:sub(q3, q3) == "\n" then
            q4 = q3 + 1
          end
          if q4 then
            return p, q4, s:sub(cur, q - 1), s:sub(q2, q3 - 1)
          end
        end
      end
    end
  end
  return nil
end

-- regexMatch(s, "(?:^|\n)([^:^\n]{1,20}):?(.*)(?:$|\n)") -> { {whole,g1,g2}, ... }
function M.regexMatchPairs(s)
  local ret = {}
  if s == nil or s == "" then return ret end
  local limit = REGEX_LIMIT
  while true do
    local a, b, g1, g2 = searchOnce(s)
    if not a then break end
    ret[#ret + 1] = { s:sub(a, b - 1), g1, g2 }
    s = s:sub(b)                              -- s = m.suffix().str()
    limit = limit - 1
    if limit == 0 then break end
  end
  return ret
end

-- ---------------------------------------------------------------------------
-- table.decodeStringPairList / encodeStringPairList / isStringPairList
-- ---------------------------------------------------------------------------
-- >>> EXACT TRANSCRIPTION of modules/corelib/table.lua:269-328.
--     Only `regexMatch` is swapped for M.regexMatchPairs above; the control
--     flow, the string arithmetic and the drop conditions are unchanged.
--     Do not "clean up" this block - its quirks ARE the file format.

-- modules/corelib/table.lua:269-277
function M.isStringPairList(t)
  if type(t) ~= "table" then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  if n ~= #t then return false end            -- table.isList(t)
  for _, v in ipairs(t) do
    if type(v) ~= "table" or #v ~= 2 or type(v[1]) ~= "string" or type(v[2]) ~= "string" then
      return false
    end
  end
  return true
end

-- modules/corelib/table.lua:279-289
function M.encodeStringPairList(t)
  local ret = ""
  for _, v in ipairs(t) do
    if v[2]:find("\n") then
      ret = ret .. v[1] .. ":[[\n" .. v[2] .. "\n]]\n"
    else
      ret = ret .. v[1] .. ":" .. v[2] .. "\n"
    end
  end
  return ret
end

-- modules/corelib/table.lua:291-328
function M.decodeStringPairList(l)
  local ret = {}
  local r = M.regexMatchPairs(l)              -- regexMatch(l, "(?:^|\\n)([^:^\n]{1,20}):?(.*)(?:$|\\n)")
  local multiline = ""
  local multilineKey = ""
  local multilineActive = false
  for _, v in ipairs(r) do
    if multilineActive then
      local endPos = v[1]:find("%]%]")
      if endPos then
        if endPos > 1 then
          table.insert(ret, { multilineKey, multiline .. "\n" .. v[1]:sub(1, endPos - 1) })
        else
          table.insert(ret, { multilineKey, multiline })
        end
        multilineActive = false
        multiline = ""
        multilineKey = ""
      else
        if multiline:len() == 0 then
          multiline = v[1]
        else
          multiline = multiline .. "\n" .. v[1]
        end
      end
    else
      local bracketPos = v[3]:find("%[%[")
      if bracketPos == 1 then                 -- multiline begin
        multiline = v[3]:sub(bracketPos + 2)
        multilineActive = true
        multilineKey = v[2]
      elseif v[2]:len() > 0 and v[3]:len() > 0 then
        table.insert(ret, { v[2], v[3] })
      end
    end
  end
  return ret
end
-- <<< end of transcription

-- Diagnostic mirror of the state machine above (same control flow, no output
-- table) that records the rows decodeStringPairList SILENTLY DISCARDS: the
-- `elseif v[2]:len() > 0 and v[3]:len() > 0` guard at table.lua:322 throws away
-- any line with an empty key or an empty value.  A waypoint written as
-- "stand:" therefore vanishes on the next load - in the real GUI too - so the
-- harness has to point at it rather than silently agree with the loss.
function M.findDroppedRows(text)
  local dropped = {}
  local multilineActive = false
  local lineNo = 1
  for _, v in ipairs(M.regexMatchPairs(text)) do
    if multilineActive then
      if v[1]:find("%]%]") then multilineActive = false end
    else
      local bracketPos = v[3]:find("%[%[")
      if bracketPos == 1 then
        multilineActive = true
      elseif not (v[2]:len() > 0 and v[3]:len() > 0) then
        dropped[#dropped + 1] = { line = lineNo, key = v[2], value = v[3], whole = v[1] }
      end
    end
    for _ in v[1]:gmatch("\n") do lineNo = lineNo + 1 end
  end
  return dropped
end

-- ---------------------------------------------------------------------------
-- CaveBot .cfg  <->  structured form
-- ---------------------------------------------------------------------------
-- The pair list is turned into waypoints + the three reserved rows exactly the
-- way cavebot/cavebot.lua does it:
--   load : cavebot/cavebot.lua:220-272   (staypositions pre-scan, then
--          "config" / "extensions" / "staypositions" / everything-else)
--   save : cavebot/cavebot.lua:578-611   (waypoints in order, then
--          {"config", json.encode(...)}, {"extensions", ...}, {"staypositions", ...})

local RESERVED = { config = true, extensions = true, staypositions = true }

-- Decode one reserved row's JSON the way cavebot.lua does (pcall'd json.decode,
-- cavebot.lua:226-228 / :241-243 / :250-252).  Returns table, rawText, err.
local function decodeReserved(raw)
  local ok, res = pcall(function() return J().decode(raw) end)
  if ok and type(res) == "table" then return res, raw, nil end
  return {}, raw, (ok and "not a table" or tostring(res))
end

function M.parseCfgString(text, sourceName)
  local pairsList = M.decodeStringPairList(text)
  local parsed = {
    waypoints = {},
    config = {},
    extensions = {},
    stayPositions = {},
    -- extras, for byte-exact re-serialisation and for honest reporting
    pairs = pairsList,
    present = { config = false, extensions = false, stayPositions = false },
    raw = { config = nil, extensions = nil, stayPositions = nil },
    warnings = {},
    source = sourceName,
  }
  local function warn(msg) parsed.warnings[#parsed.warnings + 1] = msg end
  parsed.jsonError = false

  for _, v in ipairs(pairsList) do
    local key, value = v[1], v[2]
    if key == "config" then
      local t, raw, err = decodeReserved(value)
      if err then warn("config: json.decode failed (" .. err .. ")"); parsed.jsonError = true end
      parsed.config, parsed.raw.config, parsed.present.config = t, raw, true
    elseif key == "extensions" then
      local t, raw, err = decodeReserved(value)
      if err then warn("extensions: json.decode failed (" .. err .. ")"); parsed.jsonError = true end
      parsed.extensions, parsed.raw.extensions, parsed.present.extensions = t, raw, true
    elseif key == "staypositions" then
      local t, raw, err = decodeReserved(value)
      if err then warn("staypositions: json.decode failed (" .. err .. ")"); parsed.jsonError = true end
      parsed.stayPositions, parsed.raw.stayPositions, parsed.present.stayPositions = t, raw, true
    else
      parsed.waypoints[#parsed.waypoints + 1] = { type = key, value = value }
    end
  end

  -- cavebot.lua:265-271: the stayPos of waypoint N is stayPositions[tostring(N)]
  for i, wp in ipairs(parsed.waypoints) do
    local sp = parsed.stayPositions[tostring(i)]
    if type(sp) == "table" then
      wp.stayPos = { x = tonumber(sp.x), y = tonumber(sp.y), z = tonumber(sp.z) }
    end
  end

  return parsed
end

function M.parseCfg(path)
  local data, err = readFile(path)
  if not data then error(err, 0) end
  return M.parseCfgString(data, path)
end

-- Rebuild the exact byte stream vBot writes.
--   opts.preserveRaw (default true): when a reserved row's JSON was read from
--   disk and still decodes to a table semantically equal to the in-memory one,
--   re-emit the ORIGINAL text.  rxi's encode_table walks `pairs()`, so key
--   order is not reproducible; without this, a pure read-modify-nothing-write
--   would churn the file even though nothing changed.  Set it to false to see
--   what a genuine vBot re-save would look like.
function M.serializeCfg(parsed, opts)
  opts = opts or {}
  local preserveRaw = opts.preserveRaw ~= false
  local jsonEncode = function(t) return M.serializeJson(t) end

  local list = {}
  for _, wp in ipairs(parsed.waypoints or {}) do
    list[#list + 1] = { tostring(wp.type), tostring(wp.value) }
  end

  local present = parsed.present or { config = true, extensions = true, stayPositions = true }
  local raw = parsed.raw or {}

  local function reserved(key, tbl, rawText, isPresent)
    if isPresent == false then return end
    if tbl == nil then return end
    if preserveRaw and rawText then
      local ok, decoded = pcall(function() return J().decode(rawText) end)
      if ok and type(decoded) == "table" and M.compare(decoded, tbl) then
        list[#list + 1] = { key, rawText }
        return
      end
    end
    list[#list + 1] = { key, jsonEncode(tbl) }
  end

  reserved("config", parsed.config, raw.config, present.config)
  reserved("extensions", parsed.extensions, raw.extensions, present.extensions)
  reserved("staypositions", parsed.stayPositions, raw.stayPositions, present.stayPositions)

  return M.encodeStringPairList(list)
end

-- ---------------------------------------------------------------------------
-- JSON files
-- ---------------------------------------------------------------------------
-- targetbot_configs/*.json and the Config.edit path go through
--   game_bot/functions/config.lua:57-67 (load) - note the `data:len() < 2`
--   short-circuit at :60, which turns a 0/1-byte file into {}.
-- vBot_configs/profile_N/*.json go through vBot/configs.lua:31-61 (plain
--   json.decode, no length guard).
-- storage/profile_N.json goes through game_bot/bot.lua:274-282 (plain decode).
-- Every writer is json.encode(t, 2) - and rxi's json.encode ignores its second
-- argument (modules/corelib/json.lua:126-128), so output is always compact.

function M.parseJsonString(text, opts)
  opts = opts or {}
  if opts.lengthGuard ~= false and #text < 2 then
    return {}                                 -- functions/config.lua:60
  end
  return J().decode(text)
end

function M.parseJson(path, opts)
  local data, err = readFile(path)
  if not data then error(err, 0) end
  return M.parseJsonString(data, opts)
end

function M.serializeJson(t)
  return J().encode(t)                        -- json.encode(t, 2); arg 2 is ignored
end

-- Canonical (key-sorted) rendering, for order-insensitive byte comparison.
-- Uses json.lua's own number/string encoders via single-value encode calls, so
-- the scalar spelling is byte-identical to what vBot writes.
local function canonical(v, seen)
  local t = type(v)
  if t ~= "table" then return M.serializeJson(v) end
  seen = seen or {}
  if seen[v] then error("circular reference") end
  seen[v] = true
  local isArray = (rawget(v, 1) ~= nil or next(v) == nil)
  local out
  if isArray then
    local parts = {}
    for _, e in ipairs(v) do parts[#parts + 1] = canonical(e, seen) end
    out = "[" .. table.concat(parts, ",") .. "]"
  else
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = M.serializeJson(tostring(k)) .. ":" .. canonical(v[k], seen)
    end
    out = "{" .. table.concat(parts, ",") .. "}"
  end
  seen[v] = nil
  return out
end
M.canonicalJson = function(v) return canonical(v) end

-- ---------------------------------------------------------------------------
-- deep semantic comparison
-- ---------------------------------------------------------------------------
-- Rules asked for:
--   * an empty table equals an empty table regardless of {} / [] encoding
--     (json.lua encodes any empty table as "[]" - json.lua:70,87 - so a config
--     saved as {} comes back as [] and must still compare equal)
--   * integer and float compare equal when numerically equal (2 == 2.0)
-- Plus: a value that is nil on one side and an empty table on the other is NOT
-- equal (that would hide a dropped key), but JSON `null` decodes to nil in
-- rxi's json.lua (json.lua:156) so a null key legitimately disappears.

local function isEmptyTable(t)
  return type(t) == "table" and next(t) == nil
end

local function deepCompare(a, b, path, diffs, maxDiffs)
  if #diffs >= maxDiffs then return end
  local ta, tb = type(a), type(b)

  if ta == "number" and tb == "number" then
    if a ~= b then
      diffs[#diffs + 1] = path .. ": number " .. tostring(a) .. " ~= " .. tostring(b)
    end
    return
  end

  if ta ~= tb then
    -- empty table on both sides is handled below; anything else is a type diff
    if not (isEmptyTable(a) and isEmptyTable(b)) then
      diffs[#diffs + 1] = path .. ": type " .. ta .. " ~= " .. tb ..
        " (" .. tostring(a) .. " / " .. tostring(b) .. ")"
    end
    return
  end

  if ta ~= "table" then
    if a ~= b then
      diffs[#diffs + 1] = path .. ": " .. string.format("%q", tostring(a)) ..
        " ~= " .. string.format("%q", tostring(b))
    end
    return
  end

  if isEmptyTable(a) and isEmptyTable(b) then return end   -- {} == []

  local keys, seenKey = {}, {}
  for k in pairs(a) do keys[#keys + 1] = k; seenKey[k] = true end
  for k in pairs(b) do if not seenKey[k] then keys[#keys + 1] = k end end
  table.sort(keys, function(x, y)
    if type(x) == type(y) then
      if type(x) == "number" then return x < y end
      return tostring(x) < tostring(y)
    end
    return type(x) < type(y)
  end)

  for _, k in ipairs(keys) do
    local av, bv = a[k], b[k]
    local kp = path .. "." .. tostring(k)
    if av == nil then
      diffs[#diffs + 1] = kp .. ": missing on left (right = " .. tostring(bv) .. ")"
    elseif bv == nil then
      diffs[#diffs + 1] = kp .. ": missing on right (left = " .. tostring(av) .. ")"
    else
      deepCompare(av, bv, kp, diffs, maxDiffs)
    end
    if #diffs >= maxDiffs then return end
  end
end

function M.compare(a, b, opts)
  opts = opts or {}
  local diffs = {}
  local ok, err = pcall(deepCompare, a, b, opts.path or "$", diffs, opts.maxDiffs or 12)
  if not ok then return false, "compare error: " .. tostring(err) end
  if #diffs == 0 then return true, nil end
  return false, table.concat(diffs, "; ")
end

-- ---------------------------------------------------------------------------
-- per-file checks
-- ---------------------------------------------------------------------------

local function newResult(path, kind)
  return {
    path = path, name = baseName(path), kind = kind,
    parsed = false, roundTrip = false, byteIdentical = false, lossy = false,
    bytes = 0, notes = {}, diff = nil,
  }
end

local function note(r, s) r.notes[#r.notes + 1] = s end

function M.checkCfgFile(path)
  local r = newResult(path, "cavebot.cfg")
  local data, err = readFile(path)
  if not data then note(r, "read failed: " .. tostring(err)); return r end
  r.bytes = #data
  if data:find("\r") then
    note(r, "CRLF/CR bytes present - std::regex '.' excludes \\r, parsing may drift")
  end

  local ok, parsed = pcall(M.parseCfgString, data, path)
  if not ok then note(r, "parse error: " .. tostring(parsed)); return r end
  r.parsed = true
  r.detail = {
    waypoints = #parsed.waypoints,
    configKeys = 0, extensionKeys = 0, stayPositions = 0,
    multiline = 0,
  }
  for _ in pairs(parsed.config) do r.detail.configKeys = r.detail.configKeys + 1 end
  for _ in pairs(parsed.extensions) do r.detail.extensionKeys = r.detail.extensionKeys + 1 end
  for _ in pairs(parsed.stayPositions) do r.detail.stayPositions = r.detail.stayPositions + 1 end
  for _, wp in ipairs(parsed.waypoints) do
    if wp.value:find("\n") then r.detail.multiline = r.detail.multiline + 1 end
  end
  for _, w in ipairs(parsed.warnings) do note(r, w) end
  if parsed.jsonError then
    r.lossy = true
    note(r, "a reserved row's JSON does not decode - vBot warns and REPLACES it on the next save")
  end

  -- Rows decodeStringPairList throws away (table.lua:322): empty key or value.
  for _, d in ipairs(M.findDroppedRows(data)) do
    r.lossy = true
    note(r, ("line ~%d %q:%q is DROPPED by decodeStringPairList (empty key or value)")
      :format(d.line, d.key, d.value))
  end

  -- Hazards that would silently corrupt the user's file on the next save.
  for i, wp in ipairs(parsed.waypoints) do
    if #wp.type > 20 then
      note(r, ("waypoint #%d key %q is >20 chars - decodeStringPairList truncates it")
        :format(i, wp.type))
    end
    if #wp.value == 0 then
      note(r, ("waypoint #%d (%s) has an empty value - it is DROPPED on reload")
        :format(i, wp.type))
    end
    if wp.type:find("[:%^\n]") then
      note(r, ("waypoint #%d key %q contains ':' '^' or newline - unparseable"):format(i, wp.type))
    end
  end

  -- round trip 1: bytes
  local ok2, ser = pcall(M.serializeCfg, parsed)
  if not ok2 then note(r, "serialize error: " .. tostring(ser)); return r end
  r.byteIdentical = (ser == data)
  if not r.byteIdentical then
    -- locate the first differing byte for the report
    local n = math.min(#ser, #data)
    local at = n + 1
    for i = 1, n do
      if ser:sub(i, i) ~= data:sub(i, i) then at = i break end
    end
    local line = 1
    for _ in data:sub(1, math.min(at, #data)):gmatch("\n") do line = line + 1 end
    note(r, ("re-serialised bytes differ at offset %d (line ~%d); %d -> %d bytes")
      :format(at, line, #data, #ser))
  end

  -- round trip 2: semantics (parse -> serialize -> parse)
  local ok3, reparsed = pcall(M.parseCfgString, ser, path .. "<roundtrip>")
  if not ok3 then note(r, "reparse error: " .. tostring(reparsed)); return r end
  local function shape(p)
    return { waypoints = p.waypoints, config = p.config,
             extensions = p.extensions, stayPositions = p.stayPositions }
  end
  local same, diff = M.compare(shape(parsed), shape(reparsed))
  r.roundTrip = same
  r.diff = diff

  -- round trip 3: what a genuine vBot re-save (fresh json.encode) would do -
  -- key order changes, so only the semantics can be checked.
  local ok4, serFresh = pcall(M.serializeCfg, parsed, { preserveRaw = false })
  if ok4 then
    local ok5, reFresh = pcall(M.parseCfgString, serFresh, path .. "<vbotsave>")
    if ok5 then
      local same2, diff2 = M.compare(shape(parsed), shape(reFresh))
      if not same2 then
        r.roundTrip = false
        r.diff = (r.diff and (r.diff .. " | ") or "") .. "vbot-save: " .. tostring(diff2)
      end
    else
      r.roundTrip = false
      note(r, "vbot-save reparse error: " .. tostring(reFresh))
    end
  end

  return r
end

function M.checkJsonFile(path, kind, lengthGuard)
  local r = newResult(path, kind)
  local data, err = readFile(path)
  if not data then note(r, "read failed: " .. tostring(err)); return r end
  r.bytes = #data

  local ok, parsed = pcall(M.parseJsonString, data, { lengthGuard = lengthGuard })
  if not ok then note(r, "parse error: " .. tostring(parsed)); return r end
  r.parsed = true
  if type(parsed) ~= "table" then
    note(r, "top level is " .. type(parsed) .. ", vBot expects a table")
  end

  local topKeys = 0
  if type(parsed) == "table" then for _ in pairs(parsed) do topKeys = topKeys + 1 end end
  r.detail = { topKeys = topKeys }

  local ok2, ser = pcall(M.serializeJson, parsed)
  if not ok2 then note(r, "encode error: " .. tostring(ser)); return r end
  r.byteIdentical = (ser == data)

  local ok3, reparsed = pcall(M.parseJsonString, ser, { lengthGuard = lengthGuard })
  if not ok3 then note(r, "reparse error: " .. tostring(reparsed)); return r end

  local same, diff = M.compare(parsed, reparsed)
  r.roundTrip = same
  r.diff = diff

  -- Order-insensitive byte proof: canonical form must be identical, which also
  -- catches any %.14g precision loss on numbers (json.lua:107).
  local okc1, c1 = pcall(M.canonicalJson, parsed)
  local okc2, c2 = pcall(M.canonicalJson, reparsed)
  if okc1 and okc2 then
    if c1 ~= c2 then
      r.roundTrip = false
      r.diff = (r.diff and (r.diff .. " | ") or "") .. "canonical json differs"
    elseif not r.byteIdentical then
      note(r, "byte diff is key order only (canonical form identical)")
    end
  end
  return r
end

-- ---------------------------------------------------------------------------
-- directory sweep
-- ---------------------------------------------------------------------------

function M.enumerate(dir)
  dir = normalizePath(dir or M.DEFAULT_DIR)
  local files = {}
  local function add(path, kind, guard)
    files[#files + 1] = { path = path, kind = kind, lengthGuard = guard }
  end

  local cav = joinPath(dir, "cavebot_configs")
  if isDir(cav) then
    for _, n in ipairs(listDir(cav)) do
      if n:lower():match("%.cfg$") then add(joinPath(cav, n), "cavebot.cfg") end
    end
  end

  local tgt = joinPath(dir, "targetbot_configs")
  if isDir(tgt) then
    for _, n in ipairs(listDir(tgt)) do
      -- Config.load applies the `< 2 bytes -> {}` guard here (config.lua:60)
      if n:lower():match("%.json$") then add(joinPath(tgt, n), "targetbot.json", true) end
    end
  end

  local vb = joinPath(dir, "vBot_configs")
  if isDir(vb) then
    for _, p in ipairs(listDir(vb)) do
      local pdir = joinPath(vb, p)
      if p:match("^profile_%d+$") and isDir(pdir) then
        for _, n in ipairs(listDir(pdir)) do
          -- vBot/configs.lua:31-61 - plain json.decode, no length guard
          if n:lower():match("%.json$") then add(joinPath(pdir, n), "vBot_configs.json", false) end
        end
      end
    end
  end

  local st = joinPath(dir, "storage")
  if isDir(st) then
    for _, n in ipairs(listDir(st)) do
      -- game_bot/bot.lua:274-282 - plain json.decode, no length guard
      if n:lower():match("%.json$") then add(joinPath(st, n), "storage.json", false) end
    end
  end

  return files
end

function M.checkDirectory(dir)
  dir = normalizePath(dir or M.DEFAULT_DIR)
  local report = {
    dir = dir,
    jsonSource = nil,
    files = {},
    counts = { total = 0, pass = 0, fail = 0, byteIdentical = 0 },
    ok = true,
  }
  local j, err = M.loadJson(nil)
  if not j then
    report.ok = false
    report.error = err
    return report
  end
  report.jsonSource = realJsonPath

  if not isDir(dir) then
    report.ok = false
    report.error = "not a directory: " .. dir
    return report
  end

  for _, f in ipairs(M.enumerate(dir)) do
    local r
    if f.kind == "cavebot.cfg" then
      r = M.checkCfgFile(f.path)
      -- For .cfg the bar is byte identity: vBot's writer is deterministic
      -- (encodeStringPairList just concatenates in list order, table.lua:279)
      -- and every one of the user's real files satisfies it, so anything less
      -- means our write would change the file the GUI reads back.
      r.pass = r.parsed and r.roundTrip and r.byteIdentical and not r.lossy
    else
      r = M.checkJsonFile(f.path, f.kind, f.lengthGuard)
      -- For .json byte identity is impossible: rxi's encode_table walks pairs()
      -- (json.lua:89), so key order is not reproducible.  The canonical-form
      -- comparison inside checkJsonFile is the byte-level proof instead.
      r.pass = r.parsed and r.roundTrip
    end
    r.rel = normalizePath(r.path):sub(#dir + 2)
    report.files[#report.files + 1] = r
    report.counts.total = report.counts.total + 1
    if r.pass then report.counts.pass = report.counts.pass + 1
    else report.counts.fail = report.counts.fail + 1; report.ok = false end
    if r.byteIdentical then report.counts.byteIdentical = report.counts.byteIdentical + 1 end
  end

  if report.counts.total == 0 then
    report.ok = false
    report.error = "no config files found under " .. dir
  end
  return report
end

-- ---------------------------------------------------------------------------
-- CLI
-- ---------------------------------------------------------------------------

local function pad(s, n)
  s = tostring(s)
  if #s >= n then return s end
  return s .. string.rep(" ", n - #s)
end

local function lpad(s, n)
  s = tostring(s)
  if #s >= n then return s end
  return string.rep(" ", n - #s) .. s
end

function M.printReport(report, verbose)
  local out = io.stdout
  out:write("vbot_compat_check ", M.VERSION, "\n")
  out:write("dir       : ", tostring(report.dir), "\n")
  out:write("json.lua  : ", tostring(report.jsonSource), "\n")
  if report.error then
    out:write("ERROR     : ", report.error, "\n")
  end
  out:write("\n")

  local w = 34
  for _, r in ipairs(report.files) do
    if #r.rel > w then w = #r.rel end
  end
  if w > 46 then w = 46 end

  local header = pad("RESULT", 6) .. "  " .. pad("FILE", w) .. "  " .. pad("KIND", 18) .. "  " ..
    lpad("BYTES", 7) .. "  " .. pad("PARSE", 6) .. "  " ..
    pad("RTRIP", 6) .. "  " .. pad("BYTE-EQ", 8) .. "  DETAIL"
  out:write(header, "\n")
  out:write(string.rep("-", #header), "\n")

  for _, r in ipairs(report.files) do
    local rel = r.rel
    if #rel > w then rel = "..." .. rel:sub(#rel - w + 4) end
    local detail = ""
    if r.kind == "cavebot.cfg" and r.detail then
      detail = ("wpt=%d cfg=%d ext=%d stay=%d ml=%d"):format(
        r.detail.waypoints, r.detail.configKeys, r.detail.extensionKeys,
        r.detail.stayPositions, r.detail.multiline)
    elseif r.detail then
      detail = ("keys=%d"):format(r.detail.topKeys)
    end
    out:write(pad(r.pass and "PASS" or "FAIL", 6), "  ",
      pad(rel, w), "  ", pad(r.kind, 18), "  ", lpad(r.bytes, 7), "  ",
      pad(r.parsed and "PASS" or "FAIL", 6), "  ",
      pad(r.roundTrip and "PASS" or "FAIL", 6), "  ",
      pad(r.byteIdentical and "same" or "differ", 8), "  ", detail, "\n")
    if r.diff then
      out:write(string.rep(" ", 4), "diff: ", tostring(r.diff), "\n")
    end
    for _, n in ipairs(r.notes) do
      if verbose or not n:find("^byte diff is key order only") then
        out:write(string.rep(" ", 4), "note: ", n, "\n")
      end
    end
  end

  out:write(string.rep("-", #header), "\n")
  out:write(("%d files: %d PASS, %d FAIL, %d byte-identical on re-serialise\n"):format(
    report.counts.total, report.counts.pass, report.counts.fail, report.counts.byteIdentical))
  out:write(report.ok and "RESULT: OK\n" or "RESULT: FAILURES\n")
end

local function main(argv)
  local dir, verbose, jsonPath = nil, false, nil
  local i = 1
  while argv[i] do
    local a = argv[i]
    if a == "--verbose" or a == "-v" then
      verbose = true
    elseif a == "--json" then
      i = i + 1; jsonPath = argv[i]
    elseif a == "--help" or a == "-h" then
      print("usage: luajit vbot_compat_check.lua [dir] [--json <json.lua>] [--verbose]")
      print("default dir: " .. M.DEFAULT_DIR)
      return 0
    elseif a:sub(1, 1) == "-" then
      io.stderr:write("unknown option: ", a, "\n")
      return 2
    else
      dir = a
    end
    i = i + 1
  end
  if jsonPath then
    local ok, err = M.loadJson(jsonPath)
    if not ok then io.stderr:write(tostring(err), "\n"); return 2 end
  end
  local report = M.checkDirectory(dir or M.DEFAULT_DIR)
  M.printReport(report, verbose)
  return report.ok and 0 or 1
end

-- Run as a script only when invoked directly (arg[0] is this file and there is
-- no enclosing require/dofile consumer expecting the table back).
local invokedDirectly = false
do
  local a0 = rawget(_G, "arg") and _G.arg[0]
  if a0 then
    local me = normalizePath(a0):lower()
    if me:match("vbot_compat_check%.lua$") then invokedDirectly = true end
  end
end

if invokedDirectly then
  local code = main(rawget(_G, "arg") or {})
  os.exit(code)
end

return M
