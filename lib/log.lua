-- lib/log.lua -- levelled logging with printf formatting, optional per-line-flushed
-- file sink and line subscribers (used by the control plane).
--
-- API (docs/API.md):
--   log.setLevel(name)      'debug'|'info'|'warn'|'error'
--   log.debug(fmt, ...)  log.info(...)  log.warn(...)  log.error(...)
--   log.hex(prefix, str)    debug-level hexdump, max 512 bytes
--   log.onLine(fn)          fn(level, text, ms); multiple subscribers allowed
--   log.setFile(path)       append + flush every line
--
-- Formatting: if extra arguments are supplied the first argument is a string.format
-- pattern; with no extra arguments it is used verbatim (so a message containing a
-- stray '%' can never raise).  Non-string first arguments go through tostring().

local sys = require('lib.sys')

local log = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local NAMES  = { 'DEBUG', 'INFO ', 'WARN ', 'ERROR' }

local threshold = LEVELS.info
local fileHandle, filePath = nil, nil
local subscribers = {}

log.levels = LEVELS

function log.setLevel(name)
  local lv = LEVELS[tostring(name):lower()]
  if not lv then return nil, 'unknown log level: ' .. tostring(name) end
  threshold = lv
  return true
end

function log.getLevel()
  for k, v in pairs(LEVELS) do if v == threshold then return k end end
end

function log.setFile(path)
  if fileHandle then fileHandle:close(); fileHandle = nil; filePath = nil end
  if not path then return true end
  local f, err = io.open(path, 'a')
  if not f then return nil, err end
  fileHandle, filePath = f, path
  return true
end

function log.getFile() return filePath end

--- Register a line subscriber. Returns the fn so it can be passed to log.offLine.
function log.onLine(fn)
  if type(fn) ~= 'function' then return nil, 'log.onLine expects a function' end
  subscribers[#subscribers + 1] = fn
  return fn
end

function log.offLine(fn)
  for i = #subscribers, 1, -1 do
    if subscribers[i] == fn then table.remove(subscribers, i) end
  end
end

local function format(fmt, ...)
  if select('#', ...) == 0 then return type(fmt) == 'string' and fmt or tostring(fmt) end
  local ok, s = pcall(string.format, tostring(fmt), ...)
  if ok then return s end
  -- bad format string: never let logging blow up the caller
  local parts = { tostring(fmt) }
  for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  return table.concat(parts, ' ')
end

local function emit(lv, text)
  if lv < threshold then return end
  local ms = sys.nowMs()
  local line = string.format('[%10.1f] %s %s', ms, NAMES[lv], text)
  io.stdout:write(line, '\n')
  io.stdout:flush()
  if fileHandle then
    fileHandle:write(line, '\n')
    fileHandle:flush()
  end
  if #subscribers > 0 then
    local name = NAMES[lv]:lower():gsub('%s+$', '')
    for i = 1, #subscribers do
      pcall(subscribers[i], name, text, ms)
    end
  end
end

function log.debug(fmt, ...) if threshold <= 1 then emit(1, format(fmt, ...)) end end
function log.info (fmt, ...) if threshold <= 2 then emit(2, format(fmt, ...)) end end
function log.warn (fmt, ...) if threshold <= 3 then emit(3, format(fmt, ...)) end end
function log.error(fmt, ...) if threshold <= 4 then emit(4, format(fmt, ...)) end end

--- Debug-level hexdump; at most 512 bytes are shown (the rest is summarised).
function log.hex(prefix, str)
  if threshold > 1 then return end
  str = str or ''
  local total = #str
  local shown = math.min(total, 512)
  emit(1, string.format('%s (%d bytes%s)', tostring(prefix), total,
                        shown < total and (', first %d shown'):format(shown) or ''))
  for off = 0, shown - 1, 16 do
    local chunk = str:sub(off + 1, math.min(off + 16, shown))
    local hexs, asc = {}, {}
    for i = 1, #chunk do
      local b = chunk:byte(i)
      hexs[i] = string.format('%02X', b)
      asc[i]  = (b >= 32 and b < 127) and string.char(b) or '.'
    end
    emit(1, string.format('  %04X  %-47s  %s', off,
                          table.concat(hexs, ' '), table.concat(asc)))
  end
end

return log
