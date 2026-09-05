--[[----------------------------------------------------------------------------
  shim_probe.lua  --  THROWAWAY feasibility harness (work item A4)

  Goal: run the REAL vBot 4.8 sources, unmodified, under plain LuaJIT, on top of
  an auto-generated permissive shim, and record EXACTLY which otclient APIs are
  load-bearing at import time (as opposed to at tick time).

  Not a shim.  Not production.  Its only product is the log.

  Usage (from D:/Claude/otclient_web/luaclient), luajit.exe being
  <otclient>/build/win-local/vcpkg_installed/x64-windows-static-release/tools/luajit/luajit.exe:

    luajit tools/shim_probe.lua               -- import + 5 forced ticks, full report
    luajit tools/shim_probe.lua --no-tick     -- import only
    luajit tools/shim_probe.lua --trace       -- also stream every touched API path
    luajit tools/shim_probe.lua --strict      -- ANY unimplemented call raises
                                              --   (proves the widget layer is the
                                              --    first thing you hit: executor.lua:24)
    luajit tools/shim_probe.lua --strict-api  -- only NON-widget calls raise; this is
                                              --   how the IMPORT_REQUIRED table in
                                              --   section 5b was enumerated

  Results (2026-09-06): 74/74 vBot files + 27/27 game_bot runtime files import
  clean, 48 macros register, 5 forced ticks run with 45/48 macros error-free.

  Everything under D:/Claude/otclient_mehah1530 is READ-ONLY.
--------------------------------------------------------------------------------]]

local OT      = "D:/Claude/otclient_mehah1530/otclient"
local BOTMOD  = OT .. "/mods/game_bot"
local CORELIB = OT .. "/modules/corelib"
local CONFIG  = "vBot_4.8"

local ARGS = {}
for _, a in ipairs({ ... }) do ARGS[a] = true end
local TRACE  = ARGS["--trace"]
local NOTICK = ARGS["--no-tick"]
local STRICT = ARGS["--strict"]   -- unknown API calls raise instead of returning an anything
local STRICTAPI = ARGS["--strict-api"]  -- same, but only for NON-widget paths (g_*, modules.*, Item, ...)

--==============================================================================
-- 0. tiny io helpers (ffi so we do not depend on a shell)
--==============================================================================
local ffi = require("ffi")
local bit = require("bit")

ffi.cdef [[
typedef struct { unsigned long dwLowDateTime, dwHighDateTime; } FILETIME_;
typedef struct {
  unsigned long dwFileAttributes;
  FILETIME_ ftCreationTime, ftLastAccessTime, ftLastWriteTime;
  unsigned long nFileSizeHigh, nFileSizeLow;
  unsigned long dwReserved0, dwReserved1;
  char cFileName[260];
  char cAlternateFileName[14];
} WIN32_FIND_DATAA_;
void* FindFirstFileA(const char* lpFileName, WIN32_FIND_DATAA_* lpFindFileData);
int   FindNextFileA(void* hFindFile, WIN32_FIND_DATAA_* lpFindFileData);
int   FindClose(void* hFindFile);
unsigned long GetTickCount(void);
]]
local C = ffi.C
local INVALID = ffi.cast("void*", -1)
local FILE_ATTRIBUTE_DIRECTORY = 0x10

local function listDir(dir)
  local out = {}
  local fd = ffi.new("WIN32_FIND_DATAA_")
  local h = C.FindFirstFileA(dir .. "/*", fd)
  if h == INVALID then return out end
  repeat
    local name = ffi.string(fd.cFileName)
    if name ~= "." and name ~= ".." then
      out[#out + 1] = {
        name = name,
        dir  = bit.band(fd.dwFileAttributes, FILE_ATTRIBUTE_DIRECTORY) ~= 0
      }
    end
  until C.FindNextFileA(h, fd) == 0
  C.FindClose(h)
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

local function readFile(p)
  local f = io.open(p, "rb"); if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end
local function exists(p)
  local f = io.open(p, "rb"); if f then f:close(); return true end
  -- maybe a directory
  local fd = ffi.new("WIN32_FIND_DATAA_")
  local h = C.FindFirstFileA(p, fd)
  if h ~= INVALID then C.FindClose(h); return true end
  return false
end

--==============================================================================
-- 1. the log -- THE deliverable
--==============================================================================
local LOG = {
  phase     = "boot",            -- boot | functions | panels | import:<file> | tick
  touched   = {},                -- "g_game.getSpells()" -> {n=, phases={}}
  order     = {},                -- first-touch order
  real      = {},                -- api -> n     (calls that hit a REAL impl)
  files     = {},                -- {name=, ok=, err=, ms=}
  widgets   = {},                -- widget method name -> n
  styles    = {},                -- imported otui
  notes     = {},
}

local function note(path, kind)
  local e = LOG.touched[path]
  if not e then
    e = { n = 0, first = LOG.phase, kinds = {} }
    LOG.touched[path] = e
    LOG.order[#LOG.order + 1] = path
  end
  e.n = e.n + 1
  e.kinds[kind or "?"] = true
  if TRACE then io.write("  [touch:", LOG.phase, "] ", path, "\n") end
end
local function real(api)
  LOG.real[api] = (LOG.real[api] or 0) + 1
end

--==============================================================================
-- 2. the "anything" object
--   * indexable  -> memoised child (so identity is stable across accesses)
--   * callable   -> method call; return value looked up in RETURNS by leaf name
--   * assignable -> rawset, so `w.onClick = fn` sticks
--   Lua 5.1 semantics help us: ipairs/pairs/# are RAW, so an anything object
--   iterates zero times instead of looping forever.
--==============================================================================
local anyMT
local function isAny(v) return type(v) == "table" and getmetatable(v) == anyMT end

-- leaf-name -> value (or function(path, ...) -> value) for calls that MUST NOT
-- return an anything object.  Grown empirically, one crash at a time.
local RETURNS = {}

local function mkany(path)
  local kids = {}
  local t = { __path = path, __kids = kids }
  return setmetatable(t, anyMT)
end

anyMT = {
  __index = function(t, k)
    if k == "__path" then return rawget(t, "__path") end
    local kids = rawget(t, "__kids")
    local key = tostring(k)
    local c = kids[key]
    if c == nil then
      local p = rawget(t, "__path") .. "." .. key
      note(p, "index")
      c = mkany(p)
      kids[key] = c
    end
    return c
  end,
  __newindex = function(t, k, v) rawset(t, k, v) end,
  __call = function(t, ...)
    local p = rawget(t, "__path")
    note(p .. "()", "call")
    local leaf = p:match("([%w_]+)$") or p
    if RETURNS[leaf] == nil then
      local widgetish = p:match("^W#") or p:match("^style") or p:match("loadUIFromString%(%)")
      if STRICT or (STRICTAPI and not widgetish) then
        error("STRICT: no implementation for " .. p .. "()", 2)
      end
    end
    local r = RETURNS[leaf]
    if r ~= nil then
      if type(r) == "function" then return r(p, ...) end
      return r
    end
    return mkany(p .. "()")
  end,
  __tostring = function(t) return "<any:" .. rawget(t, "__path") .. ">" end,
  __concat = function(a, b)
    local s = function(v) return isAny(v) and tostring(v) or tostring(v) end
    return s(a) .. s(b)
  end,
  __len = function() return 0 end,
  __eq  = function(a, b) return rawequal(a, b) end,
  __lt  = function() return false end,
  __le  = function() return true end,
  __add = function(a, b) return 0 end,
  __sub = function(a, b) return 0 end,
  __mul = function(a, b) return 0 end,
  __div = function(a, b) return 0 end,
  __unm = function() return 0 end,
  __metatable = false,
}

--==============================================================================
-- 3. real-ish implementations
--==============================================================================

-- ---- virtual filesystem -----------------------------------------------------
local function vfs(p)
  p = tostring(p):gsub("\\", "/"):gsub("//+", "/")
  if p:sub(1, 1) ~= "/" then p = "/" .. p end
  local cands = {
    OT .. "/profiles" .. p, -- /bot/vBot_4.8/...
    OT .. p,                -- /mods/... /modules/...
    OT .. "/modules" .. p,
    OT .. "/data" .. p,
    BOTMOD .. p,
  }
  for _, c in ipairs(cands) do if exists(c) then return c end end
  return OT .. "/profiles" .. p
end

local g_resources = mkany('g_resources')
g_resources.fileExists = function(p) real("g_resources.fileExists"); return exists(vfs(p)) end
g_resources.directoryExists = function(p) real("g_resources.directoryExists"); return exists(vfs(p)) end
local MISSES = {}
g_resources.readFileContents = function(p)
  real("g_resources.readFileContents")
  local s = readFile(vfs(p))
  if not s then
    -- a .lua miss is fatal (we would silently skip a script); anything else is
    -- soft, because it is data the headless client will supply differently.
    if tostring(p):match("%.lua$") then
      error("readFileContents: missing " .. tostring(p) .. " -> " .. vfs(p), 2)
    end
    MISSES[tostring(p)] = (MISSES[tostring(p)] or 0) + 1
    return ""
  end
  return s
end
g_resources.writeFileContents = function(p, d) real("g_resources.writeFileContents"); return true end
g_resources.makeDir = function() real("g_resources.makeDir"); return true end
g_resources.getWorkDir = function() real("g_resources.getWorkDir"); return OT .. "/" end
g_resources.getWriteDir = function() real("g_resources.getWriteDir"); return OT .. "/" end
g_resources.getRealDir = function(p) real("g_resources.getRealDir"); return vfs(p) end
g_resources.listDirectoryFiles = function(dirPath, fullPath, raw, recursive)
  real("g_resources.listDirectoryFiles")
  dirPath = tostring(dirPath or "")
  local base = vfs(dirPath)
  local out = {}
  for _, e in ipairs(listDir(base)) do
    if e.dir then
      if recursive then
        for _, s in ipairs(g_resources.listDirectoryFiles(dirPath .. "/" .. e.name, fullPath, raw, true)) do
          out[#out + 1] = s
        end
      end
    else
      out[#out + 1] = fullPath and (dirPath .. "/" .. e.name) or e.name
    end
  end
  return out
end

-- ---- corelib pure-lua libs we can reuse verbatim ---------------------------
-- string/table/math extensions + json.  These ARE otclient Lua, loaded as-is.
local function loadCore(name)
  local src = readFile(CORELIB .. "/" .. name .. ".lua")
  if not src then error("corelib missing " .. name) end
  local f = assert(loadstring(src, "@corelib/" .. name .. ".lua"))
  local ok, err = pcall(f)
  if not ok then LOG.notes[#LOG.notes + 1] = ("corelib/%s.lua failed: %s"):format(name, err) end
end

-- ---- fake widget ------------------------------------------------------------
-- Widgets are just anything-objects rooted at "ui:<style>" plus a RETURNS table
-- that gives the getters a plausible scalar.
local widgetSeq = 0
local function mkwidget(style, parent)
  widgetSeq = widgetSeq + 1
  local w = mkany("W#" .. widgetSeq .. "<" .. tostring(style) .. ">")
  return w
end

-- widget getters that must not be anything-objects
local function W(name, v) RETURNS[name] = v end
W("getText", "");            W("getId", "probe");        W("getTooltip", "")
W("getStyleName", "");       W("getSource", "");         W("getImageSource", "")
W("isOn", false);            W("isChecked", false);      W("isVisible", true)
W("isHidden", false);        W("isEnabled", true);       W("isFocused", false)
W("isDestroyed", false);     W("isDragging", false);     W("hasChildren", false)
W("getValue", 0);            W("getMinimum", 0);         W("getMaximum", 100)
W("getChildCount", 0);       W("getWidth", 100);         W("getHeight", 20)
W("getX", 0);                W("getY", 0);               W("getOptionsCount", 0)
-- getChildren()[i] is indexed with arbitrary keys by vBot; give back a table
-- that is EMPTY for ipairs/# but yields a widget for any explicit index.
local function widgetList()
  return setmetatable({}, { __index = function(t, k)
    local w = mkwidget("child:" .. tostring(k)); rawset(t, k, w); return w
  end })
end
W("getChildren", function() return widgetList() end)
W("recursiveGetChildren", function() return widgetList() end)
W("getCurrentOption", function() return { text = CONFIG, data = CONFIG } end)
W("getOption", function() return { text = CONFIG, data = CONFIG } end)

local g_ui = mkany('g_ui')
g_ui.createWidget = function(style, parent) real("g_ui.createWidget"); return mkwidget(style, parent) end
g_ui.displayUI = function(style, parent) real("g_ui.displayUI"); return mkwidget(style, parent) end
g_ui.loadUI = function(style, parent) real("g_ui.loadUI"); return mkwidget(style, parent) end
g_ui.getRootWidget = function() real("g_ui.getRootWidget"); return mkwidget("root") end
g_ui.importStyle = function(p)
  real("g_ui.importStyle")
  LOG.styles[#LOG.styles + 1] = tostring(p)
  return true
end
g_ui.importStyleFromString = function() real("g_ui.importStyleFromString"); return true end
g_ui.getStyle = function() real("g_ui.getStyle"); return mkany("style") end
g_ui.getStyleClass = function() return "" end
g_ui.isMouseGrabbed = function() return false end

-- ---- clock ------------------------------------------------------------------
local T0 = tonumber(C.GetTickCount())
local CLOCK_SKEW = 0            -- the probe fast-forwards this to make macros due
local g_clock = mkany('g_clock')
local g_clock_impl = {
  millis  = function() return tonumber(C.GetTickCount()) - T0 + CLOCK_SKEW end,
  micros  = function() return (tonumber(C.GetTickCount()) - T0 + CLOCK_SKEW) * 1000 end,
  seconds = function() return math.floor((tonumber(C.GetTickCount()) - T0) / 1000) end,
  realMillis = function() return tonumber(C.GetTickCount()) end,
}
for k, v in pairs(g_clock_impl) do rawset(g_clock, k, v) end

-- ---- game / map / things ----------------------------------------------------
local POS = { x = 32369, y = 32241, z = 7 }
local function mkpos(x, y, z) return { x = x, y = y, z = z } end

local localPlayer -- forward
local function mkcreature(name, id)
  local c = mkany("Creature<" .. name .. ">")
  rawset(c, "getName", function() return name end)
  rawset(c, "getId", function() return id or 1 end)
  rawset(c, "getPosition", function() return mkpos(POS.x, POS.y, POS.z) end)
  rawset(c, "getHealthPercent", function() return 100 end)
  rawset(c, "isLocalPlayer", function() return id == 1 end)
  rawset(c, "isPlayer", function() return true end)
  rawset(c, "isMonster", function() return false end)
  rawset(c, "isNpc", function() return false end)
  rawset(c, "getType", function() return 0 end)
  rawset(c, "getDirection", function() return 2 end)
  rawset(c, "getSpeed", function() return 300 end)
  rawset(c, "getOutfit", function() return { type = 128, head = 0, body = 0, legs = 0, feet = 0, addons = 0 } end)
  return c
end

localPlayer = mkcreature("ProbeChar", 1)
rawset(localPlayer, "getLevel", function() return 100 end)
rawset(localPlayer, "getHealth", function() return 1000 end)
rawset(localPlayer, "getMaxHealth", function() return 1000 end)
rawset(localPlayer, "getMana", function() return 1000 end)
rawset(localPlayer, "getMaxMana", function() return 1000 end)
rawset(localPlayer, "getStates", function() return 0 end)
rawset(localPlayer, "getSkillLevel", function() return 100 end)
rawset(localPlayer, "getVocation", function() return 1 end)
rawset(localPlayer, "getInventoryItem", function() return nil end)
rawset(localPlayer, "getCapacity", function() return 1000 end)
rawset(localPlayer, "getFreeCapacity", function() return 1000 end)
rawset(localPlayer, "getTotalCapacity", function() return 1000 end)
rawset(localPlayer, "getSoul", function() return 100 end)
rawset(localPlayer, "getStamina", function() return 2400 end)
rawset(localPlayer, "getExperience", function() return 100000 end)
rawset(localPlayer, "getBlessings", function() return 0 end)
rawset(localPlayer, "isPlayer", function() return true end)
rawset(localPlayer, "isLocalPlayer", function() return true end)

local g_game = mkany("g_game")
rawset(g_game, "getLocalPlayer", function() real("g_game.getLocalPlayer"); return localPlayer end)
rawset(g_game, "isOnline", function() real("g_game.isOnline"); return true end)
rawset(g_game, "getClientVersion", function() real("g_game.getClientVersion"); return 1530 end)
rawset(g_game, "getProtocolVersion", function() real("g_game.getProtocolVersion"); return 1530 end)
rawset(g_game, "getFeature", function() real("g_game.getFeature"); return true end)
rawset(g_game, "getCharacterName", function() return "ProbeChar" end)
rawset(g_game, "getWorldName", function() return "Gunzodus" end)
rawset(g_game, "getContainers", function() real("g_game.getContainers"); return {} end)
rawset(g_game, "getContainer", function() return nil end)
rawset(g_game, "getSpectators", function() real("g_game.getSpectators"); return {} end)
rawset(g_game, "getAttackingCreature", function() return nil end)
rawset(g_game, "getFollowingCreature", function() return nil end)
rawset(g_game, "getChaseMode", function() return 0 end)
rawset(g_game, "getFightMode", function() return 2 end)
rawset(g_game, "getPVPMode", function() return 0 end)
rawset(g_game, "isSafeFight", function() return true end)
rawset(g_game, "getPing", function() return 30 end)
rawset(g_game, "getVipList", function() return {} end)
rawset(g_game, "getGameFeature", function() return true end)

local g_map = mkany("g_map")
rawset(g_map, "getTile", function() real("g_map.getTile"); return nil end)
rawset(g_map, "getTiles", function() real("g_map.getTiles"); return {} end)
rawset(g_map, "getSpectators", function() real("g_map.getSpectators"); return {} end)
rawset(g_map, "getSpectatorsInRange", function() return {} end)
rawset(g_map, "getSpectatorsInRangeEx", function() return {} end)
rawset(g_map, "findPath", function() real("g_map.findPath"); return {} end)
rawset(g_map, "getCentralPosition", function() return mkpos(POS.x, POS.y, POS.z) end)
rawset(g_map, "isLookPossible", function() return true end)
rawset(g_map, "isSightClear", function() return true end)

local g_things = mkany("g_things")
rawset(g_things, "getThingType", function() real("g_things.getThingType"); return mkany("ThingType") end)
rawset(g_things, "isValidDatId", function() return true end)
rawset(g_things, "isLoaded", function() return true end)

-- ---- settings ---------------------------------------------------------------
local settingsStore = {}
local g_settings = mkany('g_settings')
local g_settings_impl = {
  get        = function(k, d) real("g_settings.get"); return settingsStore[k] or d or "" end,
  getString  = function(k, d) real("g_settings.getString"); return settingsStore[k] or d or "" end,
  getNumber  = function(k, d) real("g_settings.getNumber"); return tonumber(settingsStore[k]) or d or 0 end,
  getBoolean = function(k, d) real("g_settings.getBoolean"); if settingsStore[k] == nil then return d or false end return settingsStore[k] end,
  getNode    = function(k) real("g_settings.getNode"); return settingsStore[k] end,
  getList    = function(k) return settingsStore[k] or {} end,
  set        = function(k, v) real("g_settings.set"); settingsStore[k] = v end,
  setNode    = function(k, v) real("g_settings.setNode"); settingsStore[k] = v end,
  remove     = function(k) settingsStore[k] = nil end,
  exists     = function(k) return settingsStore[k] ~= nil end,
  save       = function() end,
  load       = function() end,
}
for k, v in pairs(g_settings_impl) do rawset(g_settings, k, v) end

--==============================================================================
-- 4. install globals
--==============================================================================
local AUTO = {
  "g_app", "g_window", "g_mouse", "g_keyboard", "g_sounds", "g_platform",
  "g_dispatcher", "g_logger", "g_modules", "g_configs", "g_graphics",
  "g_textures", "g_fonts", "g_shaders", "g_effects", "g_minimap", "g_lua",
  "g_crypt", "g_proxy", "g_http", "g_extras", "g_stats", "g_adaptiveRenderer",
  "g_drawPool", "g_menu", "g_towns", "g_creatures", "g_sprites", "g_particles",
  "Item", "Creature", "ThingType", "Effect", "Missile", "Player", "Monster",
  "Npc", "Thing", "StaticText", "AnimatedText", "Tile", "Container", "OutputMessage",
  "InputMessage", "UIWidget", "UIButton", "UITextEdit", "UICheckBox",
  "UIComboBox", "UIScrollBar", "UIWindow", "UIMiniWindow", "UIItem",
  "UICreatureButton", "UIProgressBar", "UIPopupMenu", "UIMessageBox",
  "MiniWindow", "Position", "Outfit", "MarketCategory", "Skill",
}
for _, n in ipairs(AUTO) do _G[n] = mkany(n) end

_G.g_resources = g_resources
_G.g_ui        = g_ui
_G.g_clock     = g_clock
_G.g_game      = g_game
_G.g_map       = g_map
_G.g_things    = g_things
_G.g_settings  = g_settings

local CAPTURED_CTX = nil
_G.G = setmetatable({}, { __newindex = function(t, k, v)
  if k == "botContext" and type(v) == "table" then CAPTURED_CTX = v end
  rawset(t, k, v)
end })
_G.modules = mkany("modules")
_G.rootWidget = mkwidget("root")

-- corelib extensions to string/table/math (pure Lua, loaded verbatim)
loadCore("string"); loadCore("table"); loadCore("math")
-- json.lua defines the `json` global (pure Lua)
loadCore("json")
if type(_G.json) ~= "table" then _G.json = mkany("json") end

-- (otclient pure-Lua libs are loaded further down, once the globals they
--  reference -- tr, Thing, ... -- exist)


-- globals otclient defines in C++ / corelib that the sandbox reads
_G.scheduleEvent = function(cb, delay) real("scheduleEvent"); return mkany("Event") end
_G.addEvent      = function(cb, ...) real("addEvent"); if type(cb) == "function" then end return mkany("Event") end
_G.removeEvent   = function(e) real("removeEvent") end
_G.cycleEvent    = function(cb, d) real("cycleEvent"); return mkany("Event") end
_G.connect       = function(obj, sigs, ...) real("connect") end
_G.disconnect    = function(obj, sigs, ...) real("disconnect") end
_G.signalcall    = function(fn, ...) real("signalcall"); if type(fn) == "function" then return fn(...) end end
_G.tr            = function(s) return s end
_G.gcinfo        = _G.gcinfo or function() return 0 end
_G.regexMatch    = function(s, p) real("regexMatch"); return {} end
_G.base64        = _G.base64 or mkany("base64")
_G.HTTP          = mkany("HTTP")
_G.Directions    = { [0] = { x = 0, y = -1 }, { x = 1, y = 0 }, { x = 0, y = 1 }, { x = -1, y = 0 } }
_G.determineKeyComboDesc = function(k, m) return tostring(k) end
_G.retranslateKeyComboDesc = function(s) return s end
_G.postoTable = function(p) return { x = p.x, y = p.y, z = p.z } end
_G.toPosition = function(t) return t end
_G.print = print

-- corelib/const.lua + bitwise.lua, and the pure-Lua half of gamelib: these
-- define the hundreds of enum globals (PlayerStates, SpellInfo, Position,
-- MessageModes, ...) that vBot reads at LOAD time.  All are plain Lua and can
-- be reused verbatim by a real shim.
local LOADED_OTLUA, FAILED_OTLUA = {}, {}
local function loadOtLua(rel)
  local src = readFile(OT .. "/modules/" .. rel)
  if not src then FAILED_OTLUA[#FAILED_OTLUA + 1] = rel .. " (missing)"; return end
  local f, err = loadstring(src, "@" .. rel)
  if not f then FAILED_OTLUA[#FAILED_OTLUA + 1] = rel .. " compile: " .. tostring(err); return end
  local ok, e = pcall(f)
  if ok then LOADED_OTLUA[#LOADED_OTLUA + 1] = rel
  else FAILED_OTLUA[#FAILED_OTLUA + 1] = rel .. ": " .. tostring(e) end
end
loadOtLua("corelib/const.lua")
loadOtLua("corelib/bitwise.lua")
loadOtLua("gamelib/const.lua")
loadOtLua("gamelib/position.lua")
loadOtLua("gamelib/player.lua")
loadOtLua("gamelib/creature.lua")
loadOtLua("gamelib/textmessages.lua")
loadOtLua("gamelib/spells.lua")
loadOtLua("gamelib/items.lua")
loadOtLua("gamelib/thing.lua")
loadOtLua("gamelib/tile.lua")
loadOtLua("gamelib/util.lua")

-- `dofiles(dir)` -- otclient C++ builtin: load every .lua in dir, alphabetically,
-- relative to the *currently executing module's* directory (here: game_bot).
_G.dofiles = function(dir)
  real("dofiles")
  local base = BOTMOD .. "/" .. dir
  for _, e in ipairs(listDir(base)) do
    if not e.dir and e.name:match("%.lua$") then
      local p = base .. "/" .. e.name
      local src = readFile(p)
      local f, err = loadstring(src, "@" .. dir .. "/" .. e.name)
      if not f then
        LOG.files[#LOG.files + 1] = { name = dir .. "/" .. e.name, ok = false, err = "compile: " .. tostring(err) }
      else
        local ok, e2 = pcall(f)
        LOG.files[#LOG.files + 1] = { name = dir .. "/" .. e.name, ok = ok, err = (not ok) and tostring(e2) or nil }
        if not ok then io.write("    !! ", dir, "/", e.name, ": ", tostring(e2), "\n") end
      end
    end
  end
end
_G.dofile = function(p)
  local src = g_resources.readFileContents(p)
  return assert(loadstring(src, "@" .. p))()
end

--==============================================================================
-- 5. modules.game_bot -- the one module vBot really reaches into at load time
--==============================================================================
do
  local gb = mkany("modules.game_bot")
  local cp = mkany("modules.game_bot.contentsPanel")
  local cfgw = mkany("modules.game_bot.contentsPanel.config")
  rawset(cfgw, "getCurrentOption", function() real("contentsPanel.config:getCurrentOption"); return { text = CONFIG, data = CONFIG } end)
  rawset(cp, "config", cfgw)
  rawset(gb, "contentsPanel", cp)
  rawset(_G.modules, "game_bot", gb)

  local gi = mkany("modules.game_interface")
  rawset(gi, "getRightPanel", function() real("game_interface.getRightPanel"); return mkwidget("rightPanel") end)
  rawset(gi, "getLeftPanel", function() return mkwidget("leftPanel") end)
  rawset(gi, "getMapPanel", function() return mkwidget("mapPanel") end)
  rawset(gi, "getRootPanel", function() return mkwidget("rootPanel") end)
  rawset(_G.modules, "game_interface", gi)
end

--==============================================================================
-- 6. instrumented import of executor.lua and the vBot tree
--==============================================================================
local function banner(s)
  io.write("\n", string.rep("=", 78), "\n", s, "\n", string.rep("=", 78), "\n")
end

--==============================================================================
-- 5b. NON-UI APIs that are load-bearing AT IMPORT TIME.
-- Discovered mechanically: run with --strict-api, add whatever it names, repeat.
-- The ORDER of this list is the order the probe hit them; the VALUE is the
-- weakest return that still lets import finish.  This table is the A4 answer to
-- "what must the shim implement first".
--==============================================================================
local IMPORT_REQUIRED = {
  -- name                          weakest value that unblocks import
  enableTileThingLuaCallback       = false,   -- g_game.enableTileThingLuaCallback
  isGroupCooldownIconActive        = false,   -- modules.game_cooldown.isGroupCooldownIconActive
  getMiniMapUi                     = function() return mkwidget('MiniMapUi') end, -- modules.game_minimap.getMiniMapUi (MUST be a widget)
  isCooldownIconActive             = false,   -- modules.game_cooldown.isCooldownIconActive
  create                           = function() return mkany('Item') end, -- Item.create (MUST be an object with setId/setCount/...)
  isDead                           = false,   -- Creature:isDead()
  loadUIFromString                 = function() return mkwidget('fromString') end, -- g_ui.loadUIFromString (MUST be a widget)
  getSlot5                         = function() return mkwidget('InvSlot5') end, -- modules.game_inventory.getSlot5 (MUST be a widget)
  cancelAttackAndFollow            = false,   -- g_game.cancelAttackAndFollow
  displayGameMessage               = false,   -- modules.game_textmessage.displayGameMessage
  destroy                          = false,   -- modules.game_buttons.buttonsWindow.contentsPanel.buttons.botAnalyzersButton.destroy
  addToggleButton                  = function() return mkwidget('ToggleButton') end, -- modules.game_mainpanel.addToggleButton (MUST be a widget)
  getPercent                       = 0,       -- modules.game_skills....level.percent:getPercent()
  getSellExceptions                = function() return {} end, -- modules.game_npctrade.getSellExceptions (MUST be a table)
  setSellExceptionsListener        = false,   -- modules.game_npctrade.setSellExceptionsListener
}
for k, v in pairs(IMPORT_REQUIRED) do if RETURNS[k] == nil then RETURNS[k] = v end end

banner("PHASE 1 -- load mods/game_bot/executor.lua")
LOG.phase = "boot"
do
  local src = assert(readFile(BOTMOD .. "/executor.lua"), "no executor.lua")
  local f, err = loadstring(src, "@executor.lua")
  if not f then error("executor.lua compile error: " .. tostring(err)) end
  local ok, e = pcall(f)
  io.write(ok and "  executor.lua: compiled+ran OK (defines executeBot)\n"
              or ("  executor.lua FAILED: " .. tostring(e) .. "\n"))
  LOG.files[#LOG.files + 1] = { name = "mods/game_bot/executor.lua", ok = ok, err = (not ok) and tostring(e) or nil }
end

-- Per-file verdicts for the vBot tree.
-- executor.lua compiles every bot script with `load(src, chunkname, nil, context)`,
-- so wrapping the global `load` gives us an exact enter/exit record per file,
-- including the nesting created by _Loader.lua's dofile().
local currentFile = nil
local rawRead = rawget(g_resources, "readFileContents")
rawset(g_resources, "readFileContents", function(p)
  currentFile = tostring(p)
  return rawRead(p)
end)

local VBOT = {}          -- ordered per-file verdicts
local VBOTBY = {}
local depth = 0
local rawLoad = _G.load
_G.load = function(chunk, name, mode, env)
  local f, err = rawLoad(chunk, name, mode, env)
  if not f then return f, err end
  local label = tostring(name or "?"):gsub("^@", "")
  if not label:match("^/") then return f end   -- only instrument bot scripts
  return function(...)
    local rec = VBOTBY[label]
    if not rec then
      rec = { name = label, ok = false, depth = depth, bytes = #tostring(chunk) }
      VBOTBY[label] = rec
      VBOT[#VBOT + 1] = rec
    end
    local prevPhase, prevDepth = LOG.phase, depth
    LOG.phase = label:match("([^/]+)%.lua$") or label
    depth = depth + 1
    local t = g_clock.millis()
    local r = { pcall(f, ...) }
    depth = prevDepth
    LOG.phase = prevPhase
    rec.ms = g_clock.millis() - t
    if r[1] then
      rec.ok = true
      return unpack(r, 2)
    end
    rec.ok = false
    rec.err = tostring(r[2])
    error(r[2], 0)
  end
end

banner("PHASE 2 -- executeBot('" .. CONFIG .. "')")
LOG.phase = "functions"

local storage = {}
do -- feed the user's REAL saved storage, like the running bot would
  local s = readFile(OT .. "/profiles/bot/" .. CONFIG .. "/storage/profile_1.json")
  if s and type(json) == "table" and json.decode then
    local ok, t = pcall(json.decode, s)
    if ok and type(t) == "table" then storage = t; io.write("  loaded real storage/profile_1.json (", #s, " bytes)\n") end
  end
end

local msgs = { info = 0, warn = 0, error = 0 }
local msgSamples = {}
local function msgCallback(kind, text)
  msgs[kind] = (msgs[kind] or 0) + 1
  if #msgSamples < 40 then msgSamples[#msgSamples + 1] = ("[%s] %s"):format(kind, tostring(text)) end
  if kind == "error" then io.write("    <bot error> ", tostring(text), "\n") end
end

local tabs = mkwidget("BotTabs")

local t0 = g_clock.millis()
local ok, res = xpcall(function()
  return executeBot(CONFIG, storage, tabs, msgCallback, function() end, function() end, {})
end, function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end)
local t1 = g_clock.millis()

if not ok then
  banner("IMPORT FAILED after " .. (t1 - t0) .. " ms")
  io.write(res, "\n")
  io.write("\nlast file read via g_resources.readFileContents: ", tostring(currentFile), "\n")
else
  banner("IMPORT OK in " .. (t1 - t0) .. " ms")
end

--==============================================================================
-- 7. one tick
--==============================================================================
local TICKMACROS = {}
if ok and res and not NOTICK then
  banner("PHASE 3 -- ticks (res.script())")
  LOG.phase = "tick"

  -- Reach into the context the executor built so we can report on the macros
  -- and force them all to fire at least once.  (G.botContext was cleared, so
  -- we recover the context through one of the closures the executor returned.)
  local ctx = CAPTURED_CTX
  local macros = ctx and rawget(ctx, "_macros")
  local sched  = ctx and rawget(ctx, "_scheduler")
  io.write(("  context recovered: %s   macros=%d  scheduler=%d  hotkeys=%d  callbacks(sum)=%d\n")
    :format(tostring(ctx ~= nil), macros and #macros or -1, sched and #sched or -1,
            (function() local n = 0; for _ in pairs(rawget(ctx, "_hotkeys") or {}) do n = n + 1 end; return n end)(),
            (function() local n = 0; for _, l in pairs(rawget(ctx, "_callbacks") or {}) do n = n + #l end; return n end)()))

  if macros then
    for _, m in ipairs(macros) do
      TICKMACROS[#TICKMACROS + 1] = { name = m.name, timeout = m.timeout, enabled = m.enabled and true or false }
      m.enabled = true          -- force every macro to run at least once
      m.lastExecution = 0
      local cb, rec = m.callback, TICKMACROS[#TICKMACROS]
      rec.runs, rec.fails = 0, 0
      m.callback = function(...)
        rec.runs = rec.runs + 1
        local r = { pcall(cb, ...) }
        if not r[1] then rec.fails = rec.fails + 1; rec.err = rec.err or tostring(r[2]) end
        return r[1] and r[2] or nil
      end
    end
  end

  for tick = 1, 5 do
    CLOCK_SKEW = CLOCK_SKEW + 700000   -- > the longest macro timeout (600000)
    local before = msgs.error or 0
    local tok, terr = xpcall(res.script, function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end)
    io.write(("  tick %d: %s   (new bot-level errors: %d)\n")
      :format(tick, tok and "OK" or ("HARD FAIL: " .. tostring(terr)), (msgs.error or 0) - before))
    if not tok then break end
  end
end

--==============================================================================
-- 8. report
--==============================================================================
banner("REPORT")

io.write("bot messages: info=", msgs.info or 0, " warn=", msgs.warn or 0, " error=", msgs.error or 0, "\n")
for _, m in ipairs(msgSamples) do io.write("   ", m, "\n") end

io.write("\n-- files loaded via dofiles() (game_bot/functions, game_bot/panels) --\n")
local nok, nfail = 0, 0
for _, f in ipairs(LOG.files) do
  if f.ok then nok = nok + 1 else nfail = nfail + 1 end
  io.write(("  %-42s %s%s\n"):format(f.name, f.ok and "OK" or "FAIL", f.err and ("  " .. f.err:gsub("\n.*", "")) or ""))
end
io.write(("  -> %d ok, %d failed\n"):format(nok, nfail))

io.write("\n-- vBot 4.8 sources, in load order --\n")
local vok, vfail = 0, 0
for _, r in ipairs(VBOT) do
  if r.ok then vok = vok + 1 else vfail = vfail + 1 end
  io.write(("  %s%-46s %-4s %5dB %4dms%s\n"):format(("  "):rep(r.depth), r.name,
    r.ok and "OK" or "FAIL", r.bytes or 0, r.ms or 0,
    r.err and ("  " .. r.err:gsub("\n.*", "")) or ""))
end
io.write(("  -> %d ok, %d failed, %d total\n"):format(vok, vfail, #VBOT))

io.write("\n-- macros registered at import time --\n")
for _, m in ipairs(TICKMACROS) do
  io.write(("  %-40s every %6dms  %-3s runs=%-3d fails=%-3d %s\n"):format(
    (m.name ~= nil and m.name ~= "" and tostring(m.name)) or "(anonymous)",
    m.timeout or -1, m.enabled and "ON" or "off", m.runs or 0, m.fails or 0,
    m.err and m.err:gsub("[\r\n].*", "") or ""))
end
io.write(("  -> %d macros\n"):format(#TICKMACROS))

io.write("\n-- non-lua files the bot asked for but the probe could not supply --\n")
do
  local mk = {}
  for k in pairs(MISSES) do mk[#mk + 1] = k end
  table.sort(mk)
  for _, k in ipairs(mk) do io.write(("  %4d  %s\n"):format(MISSES[k], k)) end
  if #mk == 0 then io.write("  (none)\n") end
end

io.write("\n-- otclient pure-Lua libs reused verbatim --\n")
io.write("  loaded: ", table.concat(LOADED_OTLUA, ", "), "\n")
for _, f in ipairs(FAILED_OTLUA) do io.write("  FAILED: ", f, "\n") end

io.write("\n-- otui styles importStyle()'d --\n")
io.write("  ", #LOG.styles, " files\n")

io.write("\n-- REAL implementations that were actually exercised --\n")
local rk = {}
for k in pairs(LOG.real) do rk[#rk + 1] = k end
table.sort(rk, function(a, b) return LOG.real[a] > LOG.real[b] end)
for _, k in ipairs(rk) do io.write(("  %6d  %s\n"):format(LOG.real[k], k)) end

io.write("\n-- SINGLETON / GLOBAL APIs reached through the permissive shim --\n")
io.write("   these are the ones a real shim MUST provide.  [phase] = first touch\n")
local function isWidgetPath(k) return k:match("^W#") or k:match("^style") or k:match("loadUIFromString%(%)") or k:match("^root") end
do
  local n, first = {}, {}
  for k, v in pairs(LOG.touched) do
    if v.kinds.call and not isWidgetPath(k) then
      local sig = k:gsub("%(%)%.", ":")
      n[sig] = (n[sig] or 0) + v.n
      if first[sig] == nil or first[sig] == "tick" then first[sig] = v.first end
    end
  end
  local ks = {}
  for k in pairs(n) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b) if n[a] ~= n[b] then return n[a] > n[b] end return a < b end)
  for _, k in ipairs(ks) do io.write(("  %6d  [%-12s] %s\n"):format(n[k], tostring(first[k]), k)) end
  io.write(("  -> %d distinct global API call paths\n"):format(#ks))
end

io.write("\n-- WIDGET METHODS called on shim widgets (aggregated by method name) --\n")
do
  local n, first = {}, {}
  for k, v in pairs(LOG.touched) do
    if v.kinds.call and isWidgetPath(k) then
      local leaf = k:match("([%w_]+)%(%)$")
      if leaf then
        n[leaf] = (n[leaf] or 0) + v.n
        if first[leaf] == nil or first[leaf] == "tick" then first[leaf] = v.first end
      end
    end
  end
  local ks = {}
  for k in pairs(n) do ks[#ks + 1] = k end
  table.sort(ks, function(a, b) if n[a] ~= n[b] then return n[a] > n[b] end return a < b end)
  local line = {}
  for _, k in ipairs(ks) do line[#line + 1] = ("%s(%d)"):format(k, n[k]) end
  io.write("  ", table.concat(line, "  "), "\n")
  io.write(("  -> %d distinct widget methods\n"):format(#ks))
end

io.write("\n-- API paths FIRST touched during the tick phase (never at import) --\n")
do
  local t = {}
  for k, v in pairs(LOG.touched) do
    if v.kinds.call and v.first == "tick" and not isWidgetPath(k) then t[#t + 1] = k end
  end
  table.sort(t, function(a, b) return LOG.touched[a].n > LOG.touched[b].n end)
  for _, k in ipairs(t) do io.write(("  %6d  %s\n"):format(LOG.touched[k].n, k)) end
  io.write(("  -> %d tick-only API paths\n"):format(#t))
end
io.write(("\n  (%d distinct touched paths total)\n"):format(#LOG.order))


-- machine-readable dump for the write-up
local out = io.open("D:/Claude/otclient_web/luaclient/docs/shim/probe_touched.txt", "w")
if out then
  for _, k in ipairs(LOG.order) do
    local v = LOG.touched[k]
    out:write(("%d\t%s\t%s\t%s\n"):format(v.n, v.first, v.kinds.call and "call" or "index", k))
  end
  out:close()
  io.write("\nwrote docs/shim/probe_touched.txt\n")
end
