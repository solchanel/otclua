-- lib/sys.lua -- process runtime primitives (FFI).  Windows and Linux from one file.
--
-- The OS is detected ONCE (`ffi.os`) and every declaration lives inside its own
-- branch: ffi.cdef is process-global, so declaring the other platform's symbols
-- would poison the namespace for every other module.
--
-- API (API.md) -- identical on both platforms:
--   sys.nowMs()          monotonic double ms
--   sys.randomBytes(n)   string from the OS CSPRNG; hard error if unavailable
--   sys.randomU32()      number 0..2^32-1
--   sys.sleepMs(ms)
--   sys.getEnv(name)
--
-- Extras used by lib/sched.lua and main.lua:
--   sys.tickCount()      coarse ms since boot
--   sys.timerRes(on)     Windows: timeBeginPeriod(1)/timeEndPeriod(1); Linux: no-op
--   sys.atExit(fn)       run fn on normal interpreter shutdown (GC sentinel)
--   sys.shutdown()       run the atExit list now (idempotent)
--   sys.os               'Windows' | 'Linux' | ...  (== ffi.os)
--   sys.isWindows / sys.isLinux
--   sys.clockSource()    name of the monotonic clock actually in use
--   sys.randomSource()   name of the CSPRNG actually in use ('getrandom',
--                        '/dev/urandom', 'BCryptGenRandom', 'RtlGenRandom')
--
-- Per-platform mapping (docs/portability.md):
--
--            | Windows                      | Linux
--   clock    | QueryPerformanceCounter      | clock_gettime(CLOCK_MONOTONIC)
--   sleep    | Sleep(ms)                    | nanosleep(), retried on EINTR
--   CSPRNG   | BCryptGenRandom -> RtlGenRandom | getrandom(2) -> /dev/urandom
--   timerRes | timeBeginPeriod(1)           | n/a (tickless kernel, ~50 us waits)
--
-- NOTE (docs/lua-runtime.md 5.1): on Windows, without timeBeginPeriod(1) every wait
-- rounds up to the 15.6 ms scheduler tick (select(10ms) measured 15.95 ms).  This
-- module raises the timer resolution at load and lowers it again on shutdown.  Linux
-- needs nothing: nanosleep/poll already honour millisecond timeouts.

local ffi = require('ffi')

local sys = {}

sys.os        = ffi.os
sys.isWindows = (ffi.os == 'Windows')
sys.isLinux   = (ffi.os == 'Linux')

-- Declared one at a time: another module may already have declared some of these
-- symbols, and a single clash must not take the whole block down.
local function cdef(s) pcall(ffi.cdef, s) end

local clockSource, randomSource
local nowRaw          -- () -> monotonic milliseconds, unbiased
local sleepRawMs      -- (ms) -> nil
local randomRaw       -- (n) -> string | nil, err

-- =========================================================== Windows =========
if sys.isWindows then

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

  ---------------------------------------------------------------------- clock --
  local qpf = ffi.new('int64_t[1]')
  if k32.QueryPerformanceFrequency(qpf) == 0 or tonumber(qpf[0]) == 0 then
    error('sys: QueryPerformanceFrequency failed')
  end
  local QPF = tonumber(qpf[0])
  local qpc = ffi.new('int64_t[1]')
  clockSource = 'QueryPerformanceCounter'

  nowRaw = function()
    k32.QueryPerformanceCounter(qpc)
    return tonumber(qpc[0]) * 1000.0 / QPF
  end

  function sys.tickCount() return tonumber(k32.GetTickCount64()) end

  sleepRawMs = function(ms) k32.Sleep(ms) end

  ---------------------------------------------------------------- timer period --
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

  --------------------------------------------------------------------- CSPRNG --
  local RNG_PREFERRED = 0x00000002 -- BCRYPT_USE_SYSTEM_PREFERRED_RNG

  randomRaw = function(n)
    local b = ffi.new('unsigned char[?]', n)
    if bcrypt then
      local st = bcrypt.BCryptGenRandom(nil, b, n, RNG_PREFERRED)
      if st == 0 then
        randomSource = 'BCryptGenRandom'
        return ffi.string(b, n)
      end
      if not advapi then
        return nil, string.format('BCryptGenRandom NTSTATUS=0x%08X', st % 0x100000000)
      end
    end
    if advapi then
      if advapi.SystemFunction036(b, n) ~= 0 then
        randomSource = 'RtlGenRandom'
        return ffi.string(b, n)
      end
      return nil, 'RtlGenRandom failed'
    end
    return nil, 'no CSPRNG available (bcrypt.dll and advapi32.dll both unusable)'
  end

-- ============================================================= Linux =========
elseif sys.isLinux then

  -- struct tags are prefixed lc_ so they can never collide with a declaration
  -- made by another module; the ABI (two 64-bit fields) is what matters.
  cdef [[ struct lc_timespec { long tv_sec; long tv_nsec; }; ]]
  cdef [[ int clock_gettime(int, struct lc_timespec*); ]]
  cdef [[ int nanosleep(const struct lc_timespec*, struct lc_timespec*); ]]

  local C = ffi.C
  local CLOCK_MONOTONIC = 1
  local EINTR = 4

  ---------------------------------------------------------------------- clock --
  local ts = ffi.new('struct lc_timespec')
  if C.clock_gettime(CLOCK_MONOTONIC, ts) ~= 0 then
    error('sys: clock_gettime(CLOCK_MONOTONIC) failed, errno=' .. tostring(ffi.errno()))
  end
  clockSource = 'clock_gettime(CLOCK_MONOTONIC)'

  nowRaw = function()
    C.clock_gettime(CLOCK_MONOTONIC, ts)
    -- tv_sec is a 64-bit int64_t cdata: tonumber() first, then scale, so the
    -- seconds never overflow the multiply.
    return tonumber(ts.tv_sec) * 1000.0 + tonumber(ts.tv_nsec) / 1e6
  end

  function sys.tickCount() return math.floor(nowRaw()) end

  local req, rem = ffi.new('struct lc_timespec'), ffi.new('struct lc_timespec')
  sleepRawMs = function(ms)
    req.tv_sec  = math.floor(ms / 1000)
    req.tv_nsec = math.floor((ms % 1000) * 1e6)
    -- EINTR: nanosleep writes the unslept remainder into rem; resume with it.
    while C.nanosleep(req, rem) ~= 0 do
      if ffi.errno() ~= EINTR then break end
      req.tv_sec, req.tv_nsec = rem.tv_sec, rem.tv_nsec
    end
  end

  ---------------------------------------------------------------- timer period --
  -- Linux has no equivalent knob (and needs none).  Kept so callers stay portable.
  function sys.timerRes(_) return false end

  --------------------------------------------------------------------- CSPRNG --
  -- Preference order: getrandom(2) when glibc exports it (>= 2.25), else
  -- /dev/urandom.  getrandom is preferred because it cannot fail on a missing
  -- fd table entry, chroot or fd exhaustion.
  local getrandom = nil
  -- LUACLIENT_NO_GETRANDOM=1 forces the /dev/urandom path (used to prove the
  -- fallback actually works on a machine whose glibc does export getrandom).
  if not os.getenv('LUACLIENT_NO_GETRANDOM') then
    cdef [[ long getrandom(void*, size_t, unsigned int); ]]
    local ok, fn = pcall(function() return C.getrandom end)
    if ok and fn ~= nil then
      -- resolve does not prove it works (a seccomp filter or a pre-3.17 kernel
      -- returns ENOSYS); draw one byte to be sure.
      local probe = ffi.new('unsigned char[1]')
      local okc, r = pcall(fn, probe, 1, 0)
      if okc and tonumber(r) == 1 then getrandom = fn end
    end
  end

  local urandom = nil
  local function openUrandom()
    if urandom then return urandom end
    local f = io.open('/dev/urandom', 'rb')
    if f then urandom = f end
    return urandom
  end

  randomRaw = function(n)
    if getrandom then
      local b = ffi.new('unsigned char[?]', n)
      local got = 0
      while got < n do
        local r = tonumber(getrandom(b + got, n - got, 0))
        if r <= 0 then
          if ffi.errno() == EINTR then
            -- retry
          else
            got = -1
            break
          end
        else
          got = got + r
        end
      end
      if got == n then
        randomSource = 'getrandom'
        return ffi.string(b, n)
      end
    end
    local f = openUrandom()
    if f then
      local d = f:read(n)
      if d and #d == n then
        randomSource = '/dev/urandom'
        return d
      end
    end
    return nil, 'no CSPRNG available (getrandom(2) unusable and /dev/urandom unreadable)'
  end

-- =========================================================== unsupported =====
else
  error('lib/sys.lua: unsupported platform ' .. tostring(ffi.os) ..
        ' (only Windows and Linux are implemented)')
end

-- ============================================================ common =========

local base = nil

--- Monotonic milliseconds since the first call, as a double.
function sys.nowMs()
  local t = nowRaw()
  if not base then base = t end
  return t - base
end

function sys.sleepMs(ms)
  ms = tonumber(ms) or 0
  if ms < 0 then ms = 0 end
  sleepRawMs(math.floor(ms + 0.5))
end

function sys.clockSource() return clockSource end

--- Name of the CSPRNG that actually produced the last draw (nil before the first).
function sys.randomSource() return randomSource end

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
--- Cryptographically strong random bytes.  Errors (never returns weak bytes).
function sys.randomBytes(n)
  n = tonumber(n) or 0
  if n <= 0 then return '' end
  local s, err = randomRaw(n)
  if not s then error('sys.randomBytes: ' .. tostring(err)) end
  return s
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

--- Directory for temporary files, without a trailing separator.
function sys.tempDir()
  local d
  if sys.isWindows then
    d = (os.getenv('TEMP') or os.getenv('TMP') or '.'):gsub('[\\/]+$', '')
  else
    d = (os.getenv('TMPDIR') or '/tmp'):gsub('/+$', '')
  end
  if d == '' then d = sys.isWindows and '.' or '/tmp' end
  return d
end

return sys
