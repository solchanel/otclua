-- lib/sys.lua -- Windows process runtime primitives (FFI).
--
-- API (docs/API.md):
--   sys.nowMs()          monotonic double ms (QueryPerformanceCounter)
--   sys.randomBytes(n)   string, BCryptGenRandom; hard error if unavailable
--   sys.randomU32()      number 0..2^32-1
--   sys.sleepMs(ms)
--   sys.getEnv(name)
--
-- Extras used by lib/sched.lua and main.lua:
--   sys.tickCount()      GetTickCount64 (coarse, since boot)
--   sys.timerRes(on)     timeBeginPeriod(1)/timeEndPeriod(1); called with true at load
--   sys.atExit(fn)       run fn on normal interpreter shutdown (GC sentinel)
--   sys.shutdown()       run the atExit list now (idempotent)
--
-- NOTE (docs/lua-runtime.md 5.1): without timeBeginPeriod(1) every wait rounds up to
-- the 15.6 ms Windows scheduler tick (select(10ms) measured 15.95 ms).  This module
-- raises the timer resolution at load and lowers it again on shutdown.

local ffi = require('ffi')

local sys = {}

-- ---------------------------------------------------------------- cdefs ----
-- Declared one at a time: another module may already have declared some of these
-- symbols, and a single clash must not take the whole block down.
local function cdef(s)
  local ok, err = pcall(ffi.cdef, s)
  if not ok and not tostring(err):find('redefine') then
    -- keep going; resolvability is asserted below
  end
end

cdef [[ int   QueryPerformanceCounter(int64_t*); ]]
cdef [[ int   QueryPerformanceFrequency(int64_t*); ]]
cdef [[ uint64_t GetTickCount64(void); ]]
cdef [[ void  Sleep(unsigned long); ]]
cdef [[ unsigned int timeBeginPeriod(unsigned int); ]]
cdef [[ unsigned int timeEndPeriod(unsigned int); ]]
cdef [[ long  BCryptGenRandom(void*, unsigned char*, unsigned long, unsigned long); ]]
cdef [[ unsigned char SystemFunction036(void*, unsigned long); ]]

local k32   = ffi.load('kernel32')
local winmm = ffi.load('winmm')

local bcrypt_ok, bcrypt = pcall(ffi.load, 'bcrypt')
if not bcrypt_ok then bcrypt = nil end
local advapi_ok, advapi = pcall(ffi.load, 'advapi32')
if not advapi_ok then advapi = nil end

-- ---------------------------------------------------------------- clock ----
local qpf = ffi.new('int64_t[1]')
if k32.QueryPerformanceFrequency(qpf) == 0 or tonumber(qpf[0]) == 0 then
  error('sys: QueryPerformanceFrequency failed')
end
local QPF  = tonumber(qpf[0])
local qpc  = ffi.new('int64_t[1]')
local base = nil

--- Monotonic milliseconds since the first call, as a double (0.0001 ms resolution).
function sys.nowMs()
  k32.QueryPerformanceCounter(qpc)
  local t = tonumber(qpc[0]) * 1000.0 / QPF
  if not base then base = t end
  return t - base
end

--- Coarse milliseconds since boot (GetTickCount64).
function sys.tickCount()
  return tonumber(k32.GetTickCount64())
end

function sys.sleepMs(ms)
  ms = tonumber(ms) or 0
  if ms < 0 then ms = 0 end
  k32.Sleep(math.floor(ms + 0.5))
end

-- ---------------------------------------------------------- timer period ----
local timerRaised = false

function sys.timerRes(on)
  if on and not timerRaised then
    timerRaised = (winmm.timeBeginPeriod(1) == 0)
    return timerRaised
  elseif (not on) and timerRaised then
    winmm.timeEndPeriod(1)
    timerRaised = false
    return true
  end
  return timerRaised
end

-- ------------------------------------------------------------- shutdown ----
local exitFns, exitDone = {}, false

function sys.atExit(fn)
  exitFns[#exitFns + 1] = fn
end

function sys.shutdown()
  if exitDone then return end
  exitDone = true
  for i = #exitFns, 1, -1 do pcall(exitFns[i]) end
  sys.timerRes(false)
end

-- GC sentinel: LuaJIT runs finalizers at lua_close(), so a normal exit lowers the
-- timer resolution even if main.lua forgets to call sys.shutdown().
local sentinel = ffi.new('int[1]')
ffi.gc(sentinel, function() pcall(sys.shutdown) end)
sys._sentinel = sentinel

sys.timerRes(true)

-- ----------------------------------------------------------------- CSPRNG --
local RNG_PREFERRED = 0x00000002 -- BCRYPT_USE_SYSTEM_PREFERRED_RNG

--- Cryptographically strong random bytes.  Errors (never returns weak bytes).
function sys.randomBytes(n)
  n = tonumber(n) or 0
  if n <= 0 then return '' end
  local b = ffi.new('unsigned char[?]', n)
  if bcrypt then
    local st = bcrypt.BCryptGenRandom(nil, b, n, RNG_PREFERRED)
    if st == 0 then return ffi.string(b, n) end
    if not advapi then
      error(string.format('sys.randomBytes: BCryptGenRandom NTSTATUS=0x%08X', st % 0x100000000))
    end
  end
  if advapi then
    if advapi.SystemFunction036(b, n) ~= 0 then return ffi.string(b, n) end
    error('sys.randomBytes: RtlGenRandom failed')
  end
  error('sys.randomBytes: no CSPRNG available (bcrypt.dll and advapi32.dll both unusable)')
end

--- Uniform 32-bit value as a plain (unsigned) Lua number.
function sys.randomU32()
  local s = sys.randomBytes(4)
  local a, b, c, d = s:byte(1, 4)
  return a + b * 256 + c * 65536 + d * 16777216
end

-- ------------------------------------------------------------------- env ----
function sys.getEnv(name)
  return os.getenv(name)
end

return sys
