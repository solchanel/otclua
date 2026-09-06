--[[============================================================================
lib/process.lua -- child-process supervision for the hub (work item H3).

The hub spawns `luajit main.lua --headless ...` workers, one per character.  It
must know their pid, learn when they exit, read their output line-wise and stop
them cleanly -- all of it without ever blocking lib/sched.lua's reactor.

`os.execute` blocks the whole process and `io.popen` gives neither a pid nor a
non-blocking read, so this module talks to the OS directly through FFI.

    local process = require('lib.process')

    local h = process.spawn{
      cmd          = { luajitExe, 'main.lua', '--headless', '--account=x' },
      cwd          = '/opt/luaclient',
      env          = { LC_INSTANCE = '7' },      -- merged over the parent env
      captureOutput= true,
      stdinData    = password .. '\n',           -- secrets go HERE, not in cmd
      onLine       = function(line, stream) ... end,   -- stream 'stdout'|'stderr'
      onExit       = function(code, signal) ... end,
    }

    sched.every(50, process.pollAll)             -- drive it from the reactor

Handle API
----------
    h:poll()          -> 'running' | 'exited'      (call from the sched loop)
    h:isRunning()     -> bool
    h:pid()           -> number
    h:stop(graceMs)   graceful now, forceful after graceMs (NON-BLOCKING)
    h:kill()          forceful now
    h:write(data)     -> true | nil,err           queued, flushed by poll()
    h:closeStdin()    EOF to the child once the queue has drained
    h:exitCode()      -> number | nil             nil while running / if signalled
    h:exitSignal()    -> number | nil             POSIX only
    h:status()        -> 'running'|'exited'|'signalled'
    h:wait(timeoutMs) -> code | nil,'timeout'     BLOCKING; shutdown paths only
    h:uptimeMs()      -> number
    h:describe()      -> redacted command line, safe to log

Module API
----------
    process.spawn(opts) -> handle | nil, err
    process.pollAll()                     poll every live handle once
    process.list()                        array of live handles
    process.count()
    process.reapAll(graceMs)              stop + wait for everything (BLOCKING)
    process.isPidAlive(pid)               for orphan detection across hub restarts
    process.jobActive()                   Windows: is the kill-on-close job live?
    process.quoteWindowsArg(s)            exposed for tests
    process.encodeWindowsCommandLine(t)   exposed for tests
    process.isWindows / process.isLinux

Children cannot outlive the hub, on three independent levels:
  1. an exit hook (sys.atExit) calls reapAll() on a normal exit;
  2. Windows: every child is placed in a job object with
     JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE before it is resumed, so when the hub
     dies -- crash, taskkill /f, anything -- the handle closes and the kernel
     kills the whole job;
  3. Linux: every child arms prctl(PR_SET_PDEATHSIG, SIGTERM) between fork and
     exec, so the kernel signals it the moment the hub goes away.  Override with
     opts.deathSignal (a number, or false to disable).

================================================================================
SECRETS IN argv -- read this before passing a password on the command line
================================================================================
Arguments are always passed as a LIST and quoted by this module; a shell is
never involved on either OS.  That stops argument INJECTION.  It does not make
arguments SECRET.  What each OS exposes:

  Linux   /proc/<pid>/cmdline is world-readable (mode 0444).  ANY local user,
          and anything running `ps aux`, sees the full argv of every process on
          the machine for as long as it lives.  A password in argv is therefore
          effectively public on a shared host.  Note that even `hidepid=2` only
          helps if the admin mounted /proc that way -- the default does not.

  Windows The command line lives in the child's PEB.  Reading it needs
          PROCESS_QUERY_INFORMATION|PROCESS_VM_READ, i.e. the same user or an
          administrator -- so it is not world-readable the way /proc is.  It is
          still NOT secret: any process running as the same user can read it,
          administrators can read it via WMI (Win32_Process.CommandLine), and
          it is recorded in ETW process-start events, Sysmon event ID 1 and
          audit event 4688 wherever command-line auditing is enabled.

  Both    argv ends up in crash dumps and in the parent's own logs.  This module
          therefore keeps only a REDACTED copy (see opts.redact) for h:describe().

  NB  The Windows quoting here targets CommandLineToArgvW / the MSVC CRT, i.e.
      real executables -- which is all the hub spawns.  cmd.exe is NOT such a
      parser (it has its own rules and its own metacharacters), so do not route
      a command through `cmd.exe /c`: spawn the .exe directly.  The Linux side
      has no such caveat at all, because execvp never involves /bin/sh.

  =>  Pass secrets on stdin.  `stdinData` is written to a private anonymous pipe
      that has exactly two ends: this process and the child.  Nothing else on
      the machine can read it, it never reaches /proc, WMI, ETW or a crash dump
      of an unrelated process, and it leaves no trace after the child exits.
      `h:write()` does the same for anything the hub sends later.

      This is ENFORCED, not advised: process.spawn REFUSES a command line that
      carries a recognised secret (--password=, --proxy-auth=, --proxyAuth:, a
      value after a bare --token, ... -- case-insensitively, with '=' or ':' as
      the separator).  opts.allowSecretsInArgv = true overrides it deliberately.

      The proxy credential PANEL.md needs therefore travels like this:

          local h = process.spawn{
              cmd = { worker, '--headless', '--proxy=' .. host .. ':' .. port },
              stdinData = 'proxy-auth ' .. user .. ':' .. pass .. '\n',
              -- stdin stays open afterwards for the control protocol
          }

      and the worker reads that first line before anything else.  Nothing in
      argv, nothing in the environment (which is 0400 but is still inherited by
      every grandchild), nothing on disk.

      opts.secretArgs = { 5, 'somevalue' } masks argv positions / literal values
      in h:describe() outright, for the cases the denylist cannot recognise
      (`-p hunter2`): redaction by denylist is exposure by omission.

================================================================================
Platform notes
================================================================================
Windows
  * CreatePipe anonymous pipes with an inheritable child end; the parent's end
    has HANDLE_FLAG_INHERIT cleared so a second spawn cannot inherit it (which
    would keep the pipe alive after the child exits and hide EOF forever).
  * CreateProcessW (UTF-8 arguments converted with MB_ERR_INVALID_CHARS; falls
    back to CreateProcessA when a byte string is not valid UTF-8) with
    CREATE_NO_WINDOW | CREATE_SUSPENDED, then AssignProcessToJobObject, then
    ResumeThread -- suspended-first so a worker cannot fork a grandchild before
    it is inside the job.
  * Reads are non-blocking via PeekNamedPipe(avail) + ReadFile(min(avail,64K)).
  * Writes are non-blocking via SetNamedPipeHandleState(PIPE_NOWAIT) on the
    parent's stdin write handle, with the remainder kept in a Lua queue.
  * Exit detection is WaitForSingleObject(h, 0) -- NOT `GetExitCodeProcess() ~=
    STILL_ACTIVE`, because a child may legitimately exit with 259.
    GetExitCodeProcess then supplies the value; TerminateProcess is the kill.
  * There is no SIGTERM.  "Graceful" means: write opts.stopCommand (if any) to
    stdin, then close stdin (EOF).  After graceMs -> TerminateProcess.

Linux
  * pipe2(O_CLOEXEC) -- deliberately NOT O_NONBLOCK.  O_NONBLOCK is a property
    of the open file description, and pipe2 sets it on BOTH ends: the child's
    stdout write end would become non-blocking too and the child would lose
    output with EAGAIN the moment the 64K pipe buffer filled.  The parent's read
    end is a separate description, so fcntl(F_SETFL, O_NONBLOCK) is applied to
    the three parent-side fds only, after the pipes are created.
  * fork + execvp: no shell, no /bin/sh -c, no word splitting.  Everything the
    child touches (argv, envp, cwd, the fd numbers) is built as C data BEFORE
    the fork, so the child path between fork and exec performs no Lua
    allocation -- only dup2/close/chdir/execvp/_exit.
  * A dedicated O_CLOEXEC "exec status" pipe carries errno back: exec success
    closes it (EOF), exec failure writes the errno, so a bad exe reports
    "execvp: No such file or directory" instead of a mystery exit 127.
  * waitpid(WNOHANG) polling reaps as it goes, so no zombie survives a poll()
    after the child died; reapAll() drains the rest at shutdown.
  * stop() = SIGTERM (plus stdin EOF), escalating to SIGKILL after graceMs.
============================================================================]]

local ffi = require('ffi')
local sys = require('lib.sys')

local process = {}

process.isWindows = sys.isWindows
process.isLinux   = sys.isLinux

process.DEFAULT_GRACE_MS  = 5000
process.DEFAULT_MAX_LINE  = 1024 * 1024   -- a "line" longer than this is cut
local  READ_CHUNK         = 65536

-- ffi.cdef is process-global; another module may already have declared some of
-- these.  Declare one at a time so a single clash cannot take the block down.
local function cdef(s) pcall(ffi.cdef, s) end

-- ---------------------------------------------------------------- registry --
local live      = {}      -- array of handles that have not yet been reaped
local liveCount = 0

local function register(h)
    live[#live + 1] = h
    liveCount = liveCount + 1
end

local function unregister(h)
    for i = 1, #live do
        if live[i] == h then
            table.remove(live, i)
            liveCount = liveCount - 1
            return
        end
    end
end

function process.list()
    local t = {}
    for i = 1, #live do t[i] = live[i] end
    return t
end

function process.count() return #live end

-- ================================================================ helpers ==
--- Split whatever arrived on one stream into whole lines, keeping the tail.
-- Returns the new tail.  `emit(line)` is called once per line, in order.
local function feedLines(tail, chunk, maxLine, emit)
    tail = tail .. chunk
    local from = 1
    while true do
        local nl = tail:find('\n', from, true)
        if not nl then break end
        local line = tail:sub(from, nl - 1)
        if line:sub(-1) == '\r' then line = line:sub(1, -2) end
        emit(line)
        from = nl + 1
    end
    if from > 1 then tail = tail:sub(from) end
    -- A child that never emits a newline must not grow the buffer without bound.
    -- maxLine < 1 would emit '' forever without shortening the tail -- an infinite
    -- loop inside the reactor -- and 0 is a plausible spelling of "no limit".
    if not maxLine or maxLine < 1 then maxLine = 1 end
    while #tail > maxLine do
        emit(tail:sub(1, maxLine))
        tail = tail:sub(maxLine + 1)
    end
    return tail
end

local DEFAULT_REDACT = { 'password', 'passwd', 'pass', 'token', 'secret',
                         'proxy%-auth', 'auth', 'key', 'apikey', 'credential' }

--- A REFERENCE to a secret is not a secret.  `--control-token-fd=0` names a file
--- descriptor and `--proxy-auth=@/run/creds` names a path; neither publishes
--- anything through /proc/<pid>/cmdline, and refusing them would force every
--- caller to disarm the denylist for the whole command line just to pass a
--- descriptor number -- which is strictly worse than this narrow exemption.
---
--- Exempt, and ONLY these:
---   a value spelled fd:N                             fd:0
---   a value that starts with '@' (read from a path)  @/run/creds, @C:/x/creds
---   a flag whose NAME ends in fd / file / path       --control-token-file=C:/x
---   a BARE number, but only under a flag ending 'fd' --control-token-fd 0
--- `--token 123456` is therefore still a secret: the flag does not name a
--- descriptor, so the number is read as the value it looks like.
--- `--proxy-auth=user:pass` matches none of them and is still refused.
local function looksLikeReference(flag, value)
    if value == nil or value == '' then return false end
    if value:match('^[Ff][Dd]:%d+$') then return true end
    if value:sub(1, 1) == '@' and #value > 1 then return true end
    -- flag arrives with its separator, e.g. '--control-token-file='
    local name = flag:gsub('[:=]$', ''):gsub('^%-+', ''):lower()
    -- a BARE number is only a descriptor when the flag says so: `--token 123456`
    -- is a token, not a file descriptor.
    if name:match('fd$') and value:match('^%d+$') then return true end
    if name:match('fd$') or name:match('file$') or name:match('path$') then
        -- a path may legitimately contain ':' on Windows (C:/...), but never a
        -- newline, and it must not look like `user:pass` on a POSIX host
        return not value:match('^[^:/\\]+:[^:/\\]+$')
    end
    return false
end
process.looksLikeReference = looksLikeReference

--- Does `a` look like `--<something-secret><sep>VALUE`?  Returns the flag part
--- (including the separator) and the value.  Matching is case-INSENSITIVE and both
--- '=' and ':' count as separators, so --proxyAuth=u:p and --password:pw are caught
--- as well as --password=pw.  Dots are allowed inside the flag name (--proxy.pass=).
local function secretArgParts(a, patterns)
    local low = a:lower()
    for _, p in ipairs(patterns) do
        local flag = low:match('^(%-%-?[%w%-_.]*' .. p .. '[%w%-_.]*[:=])')
        if flag then return a:sub(1, #flag), a:sub(#flag + 1) end
    end
    return nil
end

--- Is `a` a bare secret-looking FLAG, i.e. the value is the next element?
local function isSecretFlag(a, patterns)
    local low = a:lower()
    for _, p in ipairs(patterns) do
        if low:match('^%-%-?[%w%-_.]*' .. p .. '[%w%-_.]*$') then return true end
    end
    return false
end

--- Build a copy of the command line with secret-looking values masked.
--- `secretArgs` (optional) is the authoritative list: array indices into cmd, and/or
--- literal values, that MUST be masked whatever they are spelled like.  The pattern
--- list is only a safety net -- redaction by denylist is exposure by omission, which
--- is why process.spawn refuses to put a recognised secret in argv at all.
local function redactCmd(cmd, patterns, secretArgs)
    local byIndex, byValue = {}, {}
    if type(secretArgs) == 'table' then
        for _, v in ipairs(secretArgs) do
            if type(v) == 'number' then byIndex[v] = true
            elseif type(v) == 'string' and v ~= '' then byValue[v] = true end
        end
    end
    local out = {}
    for i = 1, #cmd do
        local a = tostring(cmd[i])
        if byIndex[i] then
            out[i] = '***'
        elseif byValue[a] then
            out[i] = '***'
        else
            local flag, value = secretArgParts(a, patterns)
            if flag and looksLikeReference(flag, value) then
                out[i] = a               -- a descriptor or a path, not a credential
            elseif flag then
                out[i] = flag .. '***'
            elseif i > 1 and isSecretFlag(tostring(cmd[i - 1]), patterns)
                   and not byIndex[i - 1]
                   and not looksLikeReference(tostring(cmd[i - 1]) .. '=', a) then
                out[i] = '***'                  -- `--password VALUE` as two elements
            else
                -- a value that merely CONTAINS a listed secret is masked too
                local masked = a
                for v in pairs(byValue) do
                    if masked:find(v, 1, true) then masked = '***' end
                end
                out[i] = masked
            end
        end
    end
    return out
end

--- Find the first argument that would publish a secret through argv.
--- Returns the index and a description, or nil when the command line is clean.
local function secretInArgv(cmd, patterns)
    for i = 1, #cmd do
        local a = tostring(cmd[i])
        local flag, value = secretArgParts(a, patterns)
        if flag and value ~= '' and not looksLikeReference(flag, value) then
            return i, a:sub(1, #flag - 1)
        end
        if i > 1 and isSecretFlag(tostring(cmd[i - 1]), patterns) and a ~= ''
           and not looksLikeReference(tostring(cmd[i - 1]) .. '=', a) then
            return i, tostring(cmd[i - 1])
        end
    end
    return nil
end

--- Validate + normalise opts.cmd into a plain array of strings.
local function normaliseCmd(cmd)
    if type(cmd) ~= 'table' then
        return nil, 'process.spawn: cmd must be a list {exe, arg1, ...}'
    end
    local n = #cmd
    if n < 1 then return nil, 'process.spawn: cmd list is empty' end
    local out = {}
    for i = 1, n do
        local v = cmd[i]
        local t = type(v)
        if t == 'number' then v = tostring(v); t = 'string' end
        if t ~= 'string' then
            return nil, ('process.spawn: cmd[%d] is a %s, expected a string'):format(i, t)
        end
        if v:find('%z') then
            return nil, ('process.spawn: cmd[%d] contains a NUL byte'):format(i)
        end
        out[i] = v
    end
    return out
end

local function normaliseEnv(env)
    if env == nil then return nil end
    if type(env) ~= 'table' then return nil, 'process.spawn: env must be a table' end
    local out = {}
    for k, v in pairs(env) do
        if type(k) ~= 'string' then return nil, 'process.spawn: env key is not a string' end
        if k == '' or k:find('=', 1, true) or k:find('%z') then
            return nil, ('process.spawn: bad env key %q'):format(k)
        end
        v = tostring(v)
        if v:find('%z') then return nil, ('process.spawn: env %s contains a NUL byte'):format(k) end
        out[k] = v
    end
    return out
end

-- ================================================ Windows argv encoding ====
-- CommandLineToArgvW / the MSVC CRT parser, in reverse.  The rules (documented
-- at "Parsing C++ Command-Line Arguments"):
--   * 2n   backslashes followed by a quote -> n backslashes, quote toggles
--   * 2n+1 backslashes followed by a quote -> n backslashes + a LITERAL quote
--   * backslashes not followed by a quote are literal
-- so to emit a literal `"` we write `\"` preceded by a doubled backslash run,
-- and a backslash run that lands on the CLOSING quote must be doubled too.
--
-- These rules are honoured by CommandLineToArgvW, by every MSVC CRT since 2008
-- and by LuaJIT's own startup, so an argument encoded here arrives at a LuaJIT
-- child byte-identical (proved in test/processsuite.lua S6).
local WIN_NEEDS_QUOTE = '[ \t\n\v"]'

function process.quoteWindowsArg(a)
    a = tostring(a)
    if a ~= '' and not a:find(WIN_NEEDS_QUOTE) then return a end
    local out, i, n = { '"' }, 1, #a
    while i <= n do
        local nb = 0
        while i <= n and a:sub(i, i) == '\\' do nb = nb + 1; i = i + 1 end
        if i > n then
            -- run lands on the closing quote: double it so the quote stays a delimiter
            out[#out + 1] = ('\\'):rep(nb * 2)
        elseif a:sub(i, i) == '"' then
            out[#out + 1] = ('\\'):rep(nb * 2 + 1) .. '"'
            i = i + 1
        else
            out[#out + 1] = ('\\'):rep(nb) .. a:sub(i, i)
            i = i + 1
        end
    end
    out[#out + 1] = '"'
    return table.concat(out)
end

--- Join a whole argv.  argv[0] uses the simple rule (CommandLineToArgvW does
--- not apply backslash escaping to argv[0]; a Windows path cannot contain `"`).
function process.encodeWindowsCommandLine(cmd)
    local parts = {}
    local exe = tostring(cmd[1])
    if exe:find('"', 1, true) then
        return nil, 'process.spawn: the executable path may not contain a double quote'
    end
    parts[1] = exe:find('[ \t]') and ('"' .. exe .. '"') or exe
    for i = 2, #cmd do parts[#parts + 1] = process.quoteWindowsArg(cmd[i]) end
    return table.concat(parts, ' ')
end

-- ============================================================== back ends ==
local backend      -- filled in by one of the two branches below

--=============================================================================
if process.isWindows then
--=============================================================================

cdef [[ typedef unsigned short lcp_wchar; ]]
cdef [[ typedef struct lcp_SECURITY_ATTRIBUTES {
          unsigned long nLength; void* lpSecurityDescriptor; int bInheritHandle;
        } lcp_SECURITY_ATTRIBUTES; ]]
cdef [[ typedef struct lcp_STARTUPINFOW {
          unsigned long cb; void* lpReserved; void* lpDesktop; void* lpTitle;
          unsigned long dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars;
          unsigned long dwFillAttribute, dwFlags;
          unsigned short wShowWindow, cbReserved2;
          unsigned char* lpReserved2;
          void* hStdInput; void* hStdOutput; void* hStdError;
        } lcp_STARTUPINFOW; ]]
cdef [[ typedef struct lcp_PROCESS_INFORMATION {
          void* hProcess; void* hThread;
          unsigned long dwProcessId; unsigned long dwThreadId;
        } lcp_PROCESS_INFORMATION; ]]
cdef [[ typedef struct lcp_JOB_BASIC_LIMIT {
          int64_t PerProcessUserTimeLimit; int64_t PerJobUserTimeLimit;
          unsigned long LimitFlags;
          size_t MinimumWorkingSetSize; size_t MaximumWorkingSetSize;
          unsigned long ActiveProcessLimit;
          uintptr_t Affinity;
          unsigned long PriorityClass; unsigned long SchedulingClass;
        } lcp_JOB_BASIC_LIMIT; ]]
cdef [[ typedef struct lcp_IO_COUNTERS {
          uint64_t a, b, c, d, e, f;
        } lcp_IO_COUNTERS; ]]
cdef [[ typedef struct lcp_JOB_EXT_LIMIT {
          lcp_JOB_BASIC_LIMIT BasicLimitInformation;
          lcp_IO_COUNTERS     IoInfo;
          size_t ProcessMemoryLimit, JobMemoryLimit;
          size_t PeakProcessMemoryUsed, PeakJobMemoryUsed;
        } lcp_JOB_EXT_LIMIT; ]]

cdef [[ int CreatePipe(void**, void**, lcp_SECURITY_ATTRIBUTES*, unsigned long); ]]
cdef [[ int SetHandleInformation(void*, unsigned long, unsigned long); ]]
cdef [[ int CloseHandle(void*); ]]
cdef [[ int CreateProcessW(const lcp_wchar*, lcp_wchar*, void*, void*, int,
                           unsigned long, void*, const lcp_wchar*,
                           lcp_STARTUPINFOW*, lcp_PROCESS_INFORMATION*); ]]
cdef [[ int CreateProcessA(const char*, char*, void*, void*, int,
                           unsigned long, void*, const char*,
                           lcp_STARTUPINFOW*, lcp_PROCESS_INFORMATION*); ]]
cdef [[ int PeekNamedPipe(void*, void*, unsigned long, unsigned long*,
                          unsigned long*, unsigned long*); ]]
cdef [[ int ReadFile(void*, void*, unsigned long, unsigned long*, void*); ]]
cdef [[ int WriteFile(void*, const void*, unsigned long, unsigned long*, void*); ]]
cdef [[ int GetExitCodeProcess(void*, unsigned long*); ]]
cdef [[ int TerminateProcess(void*, unsigned int); ]]
cdef [[ unsigned long WaitForSingleObject(void*, unsigned long); ]]
cdef [[ unsigned long GetLastError(void); ]]
cdef [[ int SetNamedPipeHandleState(void*, unsigned long*, unsigned long*, unsigned long*); ]]
cdef [[ void* CreateJobObjectW(void*, const lcp_wchar*); ]]
cdef [[ int SetInformationJobObject(void*, int, void*, unsigned long); ]]
cdef [[ int AssignProcessToJobObject(void*, void*); ]]
cdef [[ unsigned long ResumeThread(void*); ]]
cdef [[ int MultiByteToWideChar(unsigned int, unsigned long, const char*, int,
                                lcp_wchar*, int); ]]
cdef [[ int WideCharToMultiByte(unsigned int, unsigned long, const lcp_wchar*, int,
                                char*, int, const char*, int*); ]]
cdef [[ lcp_wchar* GetEnvironmentStringsW(void); ]]
cdef [[ int FreeEnvironmentStringsW(lcp_wchar*); ]]
cdef [[ void* GetStdHandle(unsigned long); ]]
cdef [[ void* OpenProcess(unsigned long, int, unsigned long); ]]

local k32 = ffi.load('kernel32')

local HANDLE_FLAG_INHERIT    = 0x00000001
local STARTF_USESTDHANDLES   = 0x00000100
local CREATE_NO_WINDOW       = 0x08000000
local CREATE_UNICODE_ENV     = 0x00000400
local CREATE_SUSPENDED       = 0x00000004
local ERROR_BROKEN_PIPE      = 109
local ERROR_INVALID_HANDLE   = 6
local ERROR_PIPE_NOT_CONNECTED = 233
local ERROR_NO_DATA          = 232
local PIPE_NOWAIT            = 0x00000001
local JobObjectExtendedLimit = 9
local JOB_KILL_ON_JOB_CLOSE  = 0x00002000
local WAIT_OBJECT_0          = 0
local CP_UTF8                = 65001
local MB_ERR_INVALID_CHARS   = 0x00000008
local STD_OUTPUT_HANDLE      = 0xFFFFFFF5   -- (DWORD)-11
local STD_ERROR_HANDLE       = 0xFFFFFFF4   -- (DWORD)-12
local INVALID_HANDLE         = ffi.cast('void*', -1)

local NULLH = ffi.cast('void*', 0)

local function lastError() return tonumber(k32.GetLastError()) end

--- UTF-8 -> UTF-16.  Returns nil when the bytes are not valid UTF-8, which is
--- the signal to fall back to the ANSI entry points.
local function toW(s)
    if #s == 0 then
        local b = ffi.new('lcp_wchar[1]'); b[0] = 0; return b, 0
    end
    local n = k32.MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, #s, nil, 0)
    if n <= 0 then return nil end
    local b = ffi.new('lcp_wchar[?]', n + 1)
    if k32.MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, #s, b, n) <= 0 then
        return nil
    end
    b[n] = 0
    return b, n
end

--- UTF-16 (NUL-terminated) -> UTF-8.
local function fromW(w)
    local n = k32.WideCharToMultiByte(CP_UTF8, 0, w, -1, nil, 0, nil, nil)
    if n <= 0 then return nil end
    local b = ffi.new('char[?]', n)
    if k32.WideCharToMultiByte(CP_UTF8, 0, w, -1, b, n, nil, nil) <= 0 then return nil end
    return ffi.string(b, n - 1)
end

--- The parent's environment as a { NAME = value } table.
local function parentEnv()
    local blk = k32.GetEnvironmentStringsW()
    if blk == nil then return {} end
    local out, p = {}, blk
    while p[0] ~= 0 do
        local s = fromW(p)
        local len = 0
        while p[len] ~= 0 do len = len + 1 end
        if s then
            -- Windows keeps "=C:=C:\dir" drive entries whose name starts with '='.
            local k, v = s:match('^(=?[^=]*)=(.*)$')
            if k and k ~= '' then out[k] = v end
        end
        p = p + len + 1
    end
    k32.FreeEnvironmentStringsW(blk)
    return out
end

--- Build a CREATE_UNICODE_ENVIRONMENT block: "K=V\0K=V\0\0", sorted
--- case-insensitively as CreateProcess expects.
local function envBlockW(map)
    local keys = {}
    for k in pairs(map) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local la, lb = a:lower(), b:lower()
        if la == lb then return a < b end
        return la < lb
    end)
    local parts = {}
    for i = 1, #keys do parts[i] = keys[i] .. '=' .. map[keys[i]] end
    local flat = table.concat(parts, '\0')
    local w, n = toW(flat)
    if not w then return nil end
    -- rebuild with real NULs: toW stopped at nothing, MultiByteToWideChar with an
    -- explicit length keeps embedded NULs, so n already covers them.
    local blk = ffi.new('lcp_wchar[?]', n + 2)
    ffi.copy(blk, w, n * 2)
    blk[n] = 0
    blk[n + 1] = 0
    return blk
end

-- ------------------------------------------------------------ job object --
local job = nil
local jobTried = false

local function ensureJob()
    if jobTried then return job end
    jobTried = true
    local j = k32.CreateJobObjectW(nil, nil)
    if j == nil then return nil end
    local info = ffi.new('lcp_JOB_EXT_LIMIT')
    info.BasicLimitInformation.LimitFlags = JOB_KILL_ON_JOB_CLOSE
    if k32.SetInformationJobObject(j, JobObjectExtendedLimit, info,
                                   ffi.sizeof('lcp_JOB_EXT_LIMIT')) == 0 then
        k32.CloseHandle(j)
        return nil
    end
    job = j
    return job
end

-- ----------------------------------------------------------------- pipes --
local function makePipe(inheritRead, inheritWrite)
    local sa = ffi.new('lcp_SECURITY_ATTRIBUTES')
    sa.nLength = ffi.sizeof('lcp_SECURITY_ATTRIBUTES')
    sa.lpSecurityDescriptor = nil
    sa.bInheritHandle = 1
    local r = ffi.new('void*[1]')
    local w = ffi.new('void*[1]')
    if k32.CreatePipe(r, w, sa, 0) == 0 then
        return nil, 'CreatePipe failed, GetLastError=' .. lastError()
    end
    -- Clear inheritance on the end WE keep: otherwise the next CreateProcess
    -- inherits it too, the pipe never sees all write handles closed and EOF
    -- never arrives.
    if not inheritRead  then k32.SetHandleInformation(r[0], HANDLE_FLAG_INHERIT, 0) end
    if not inheritWrite then k32.SetHandleInformation(w[0], HANDLE_FLAG_INHERIT, 0) end
    return r[0], w[0]
end

backend = {}

function backend.spawn(h, opts)
    local cmd = h.cmd
    local closeMe = {}
    local function fail(msg)
        for i = 1, #closeMe do if closeMe[i] ~= nil then k32.CloseHandle(closeMe[i]) end end
        return nil, msg
    end

    -- stdin: child reads, parent writes
    local inR, inW = makePipe(true, false)
    if not inR then return nil, inW end
    closeMe[#closeMe + 1] = inR; closeMe[#closeMe + 1] = inW

    local outR, outW, errR, errW
    if h.capture then
        outR, outW = makePipe(false, true)
        if not outR then return fail(outW) end
        closeMe[#closeMe + 1] = outR; closeMe[#closeMe + 1] = outW
        errR, errW = makePipe(false, true)
        if not errR then return fail(errW) end
        closeMe[#closeMe + 1] = errR; closeMe[#closeMe + 1] = errW
    end

    -- Parent's stdin write handle: never block the reactor on a full pipe.
    -- PIPE_NOWAIT is deprecated but is the only knob that works on a handle
    -- CreatePipe produced; on failure we simply keep the queue and retry later.
    do
        local mode = ffi.new('unsigned long[1]', PIPE_NOWAIT)
        h.stdinNoWait = (k32.SetNamedPipeHandleState(inW, mode, nil, nil) ~= 0)
    end

    local si = ffi.new('lcp_STARTUPINFOW')
    si.cb = ffi.sizeof('lcp_STARTUPINFOW')
    si.dwFlags = STARTF_USESTDHANDLES
    si.hStdInput  = inR
    if h.capture then
        si.hStdOutput = outW
        si.hStdError  = errW
    else
        -- captureOutput = false: the child inherits OUR stdout/stderr, matching
        -- what fork+exec does on POSIX when the caller does not redirect.
        si.hStdOutput = k32.GetStdHandle(STD_OUTPUT_HANDLE)
        si.hStdError  = k32.GetStdHandle(STD_ERROR_HANDLE)
        if si.hStdOutput == INVALID_HANDLE then si.hStdOutput = NULLH end
        if si.hStdError  == INVALID_HANDLE then si.hStdError  = NULLH end
    end

    local pi = ffi.new('lcp_PROCESS_INFORMATION')
    local flags = CREATE_NO_WINDOW + CREATE_SUSPENDED

    local cmdline, cerr = process.encodeWindowsCommandLine(cmd)
    if not cmdline then return fail(cerr) end

    local envMap = nil
    if h.env then
        envMap = h.envReplace and {} or parentEnv()
        for k, v in pairs(h.env) do envMap[k] = v end
    end

    -- lpApplicationName is deliberately NULL: that is the only form in which
    -- CreateProcess searches PATH and appends ".exe", which is what execvp does
    -- on the other side.  argv[0] in the command line is quoted by
    -- encodeWindowsCommandLine, so the classic "C:\Program Files\..." ambiguity
    -- cannot bite.
    --
    -- Try the wide entry points first; fall back to ANSI when any component is
    -- not valid UTF-8 (a byte string from a legacy code page).
    local ok = false
    local wLine = toW(cmdline)
    local wCwd  = h.cwd and toW(h.cwd) or nil
    local wEnv  = envMap and envBlockW(envMap) or nil
    if wLine and (h.cwd == nil or wCwd) and (envMap == nil or wEnv) then
        local f = flags + (wEnv and CREATE_UNICODE_ENV or 0)
        ok = k32.CreateProcessW(nil, wLine, nil, nil, 1, f, wEnv,
                                wCwd, si, pi) ~= 0
    else
        -- ANSI block: "K=V\0...\0\0" as plain bytes.
        local aEnv = nil
        if envMap then
            local keys = {}
            for k in pairs(envMap) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return a:lower() < b:lower() end)
            local parts = {}
            for i = 1, #keys do parts[i] = keys[i] .. '=' .. envMap[keys[i]] end
            local flat = table.concat(parts, '\0') .. '\0\0'
            aEnv = ffi.new('char[?]', #flat)
            ffi.copy(aEnv, flat, #flat)
        end
        local aLine = ffi.new('char[?]', #cmdline + 1)
        ffi.copy(aLine, cmdline)
        ok = k32.CreateProcessA(nil, aLine, nil, nil, 1, flags, aEnv,
                                h.cwd, si, pi) ~= 0
    end

    if not ok then
        return fail(('CreateProcess failed for %q, GetLastError=%d')
                    :format(cmd[1], lastError()))
    end

    -- Child ends belong to the child now.
    k32.CloseHandle(inR)
    if h.capture then k32.CloseHandle(outW); k32.CloseHandle(errW) end

    local j = ensureJob()
    if j then
        h.inJob = k32.AssignProcessToJobObject(j, pi.hProcess) ~= 0
    else
        h.inJob = false
    end

    k32.ResumeThread(pi.hThread)
    k32.CloseHandle(pi.hThread)

    h.hProcess = pi.hProcess
    h.hStdin   = inW
    h.hStdout  = outR
    h.hStderr  = errR
    h._pid     = tonumber(pi.dwProcessId)
    return true
end

--- Non-blocking read.  Returns a string ('' = nothing available now), or
--- nil when the pipe reached EOF (all write ends closed).
local avail = ffi.new('unsigned long[1]')
local got   = ffi.new('unsigned long[1]')
local rbuf  = ffi.new('char[?]', READ_CHUNK)

function backend.read(h, which)
    local ph = (which == 'stdout') and h.hStdout or h.hStderr
    if ph == nil then return nil end
    avail[0] = 0
    if k32.PeekNamedPipe(ph, nil, 0, nil, avail, nil) == 0 then
        local e = lastError()
        if e == ERROR_BROKEN_PIPE or e == ERROR_INVALID_HANDLE
           or e == ERROR_PIPE_NOT_CONNECTED then return nil end
        return nil
    end
    local n = tonumber(avail[0])
    if n <= 0 then return '' end
    if n > READ_CHUNK then n = READ_CHUNK end
    got[0] = 0
    if k32.ReadFile(ph, rbuf, n, got, nil) == 0 then
        local e = lastError()
        if e == ERROR_BROKEN_PIPE then return nil end
        return nil
    end
    local c = tonumber(got[0])
    if c <= 0 then return '' end
    return ffi.string(rbuf, c)
end

function backend.closeRead(h, which)
    local f = (which == 'stdout') and 'hStdout' or 'hStderr'
    if h[f] ~= nil then k32.CloseHandle(h[f]); h[f] = nil end
end

local wrote = ffi.new('unsigned long[1]')

--- Non-blocking write.  Returns the number of bytes accepted, or nil on error.
function backend.write(h, data)
    if h.hStdin == nil then return nil, 'stdin is closed' end
    if #data == 0 then return 0 end
    wrote[0] = 0
    local n = #data
    if k32.WriteFile(h.hStdin, data, n, wrote, nil) == 0 then
        local e = lastError()
        if e == ERROR_NO_DATA then return 0 end          -- PIPE_NOWAIT, buffer full
        if e == ERROR_BROKEN_PIPE or e == ERROR_INVALID_HANDLE then
            return nil, 'child closed stdin'
        end
        return nil, 'WriteFile failed, GetLastError=' .. e
    end
    return tonumber(wrote[0])
end

function backend.closeStdin(h)
    if h.hStdin ~= nil then k32.CloseHandle(h.hStdin); h.hStdin = nil end
end

--- nil while running; otherwise code, signal.
local codeBuf = ffi.new('unsigned long[1]')

function backend.tryWait(h)
    if h.hProcess == nil then return h._code, h._signal end
    if tonumber(k32.WaitForSingleObject(h.hProcess, 0)) ~= WAIT_OBJECT_0 then
        return nil
    end
    -- WaitForSingleObject, not GetExitCodeProcess ~= STILL_ACTIVE: a child is
    -- allowed to exit with 259.
    codeBuf[0] = 0
    k32.GetExitCodeProcess(h.hProcess, codeBuf)
    local c = tonumber(codeBuf[0]) % 0x100000000
    return c, nil
end

function backend.signalGraceful(h) return false end   -- no SIGTERM on Windows

function backend.forceKill(h)
    if h.hProcess ~= nil then k32.TerminateProcess(h.hProcess, 1) end
end

function backend.release(h)
    if h.hProcess ~= nil then k32.CloseHandle(h.hProcess); h.hProcess = nil end
end

function process.jobActive() return job ~= nil end

--- Is some pid still running?  Useful to the hub for detecting an orphan left
--- behind by a previous run, and to prove a kill actually took.
function process.isPidAlive(pid)
    pid = tonumber(pid)
    if not pid or pid <= 0 then return false end
    -- PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE
    local ph = k32.OpenProcess(0x1000 + 0x00100000, 0, pid)
    if ph == nil then return false end
    local alive = tonumber(k32.WaitForSingleObject(ph, 0)) ~= WAIT_OBJECT_0
    k32.CloseHandle(ph)
    return alive
end

--=============================================================================
elseif process.isLinux then
--=============================================================================

cdef [[ int pipe2(int*, int); ]]
cdef [[ int fcntl(int, int, int); ]]
cdef [[ int fork(void); ]]
cdef [[ int execvp(const char*, char* const*); ]]
cdef [[ int execvpe(const char*, char* const*, char* const*); ]]
cdef [[ int dup2(int, int); ]]
cdef [[ int chdir(const char*); ]]
cdef [[ int kill(int, int); ]]
cdef [[ int waitpid(int, int*, int); ]]
cdef [[ void _exit(int); ]]
cdef [[ int prctl(int, unsigned long, unsigned long, unsigned long, unsigned long); ]]
cdef [[ extern char** environ; ]]
-- The post-fork hygiene set.  A signal MASK survives both fork and execve, and
-- the hub blocks SIGHUP/SIGINT/SIGTERM for its own polled signal gate
-- (hub/main.lua's installSignalGate), so without an explicit reset here every
-- worker starts with those three blocked: PR_SET_PDEATHSIG's SIGTERM is then
-- queued and never delivered, and the supervisor's graceful stop is inert too.
-- The sigset_t glibc uses is 128 bytes; sixteen unsigned longs matches it on
-- both 64- and 32-bit, and only the first word is ever touched here.
-- ffi.cdef is process-global and the FIRST declaration wins, and hub/main.lua
-- declares sigprocmask against a sigset_t struct of its own.  Declaring it here
-- too is therefore best-effort; the CALL is made through an explicitly cast
-- function pointer taking void*, which is correct under either declaration.
cdef [[ void* signal(int, void*); ]]
cdef [[ int sigprocmask(int, const void*, void*); ]]
-- close_range(2) (Linux 5.9+) closes the whole inherited range in one syscall.
-- Older kernels answer ENOSYS and the loop below does it one fd at a time.
cdef [[ int close_range(unsigned int, unsigned int, unsigned int); ]]
cdef [[ long sysconf(int); ]]
-- close/read/write are declared by other modules with the same prototypes;
-- pcall'd cdef makes a duplicate harmless either way.
cdef [[ int close(int); ]]
cdef [[ long read(int, void*, unsigned long); ]]
cdef [[ long write(int, const void*, unsigned long); ]]

local C   = ffi.C
local bit = require('bit')

-- Resolve every symbol the post-fork child path uses HERE, in the parent, and
-- keep them in locals: between fork() and exec() the child may only do
-- async-signal-safe work, and a first-time ffi.C symbol lookup is not.
local c_dup2, c_close, c_chdir, c_write, c_exit, c_execvp =
      C.dup2, C.close, C.chdir, C.write, C._exit, C.execvp
local c_execvpe = nil
pcall(function() c_execvpe = C.execvpe end)     -- glibc >= 2.11, musl; optional
local c_prctl = nil
pcall(function() c_prctl = C.prctl end)         -- Linux only; optional
local c_signal = nil
pcall(function() c_signal = C.signal end)
local c_sigprocmask = nil
pcall(function()
    c_sigprocmask = ffi.cast('int (*)(int, const void*, void*)', C.sigprocmask)
end)
local c_close_range = nil
pcall(function() c_close_range = C.close_range end)   -- glibc >= 2.34 + Linux 5.9
local c_sysconf = nil
pcall(function() c_sysconf = C.sysconf end)

local PR_SET_PDEATHSIG = 1
local SIG_SETMASK      = 2
local SIG_DFL          = ffi.cast('void*', 0)
local _SC_OPEN_MAX     = 4

-- Everything the child touches between fork() and execve() has to be allocated
-- HERE, in the parent: an allocation in the child can take a lock the fork froze.
-- glibc's sigset_t is 128 bytes; sixteen unsigned longs covers it on 32- and
-- 64-bit alike, and ffi.new zero-fills, which IS the empty set.
local emptyMask = ffi.new('unsigned long[16]')

-- How high the close sweep has to go when close_range is unavailable.  Resolved
-- once, in the parent; RLIMIT_NOFILE is normally 1024 and rarely above 1M, and a
-- pathological limit is clamped so the fallback loop stays bounded.
local OPEN_MAX = 4096
if c_sysconf then
  local ok, n = pcall(function() return tonumber(c_sysconf(_SC_OPEN_MAX)) end)
  if ok and n and n > 3 then OPEN_MAX = (n > 65536) and 65536 or n end
end
process._openMaxSweep = OPEN_MAX

local O_CLOEXEC        = 0x80000    -- 02000000 octal
local O_NONBLOCK       = 0x800      -- 04000 octal
local F_SETFL          = 4
local F_GETFL          = 3
local F_DUPFD_CLOEXEC  = 1030
local WNOHANG          = 1
local SIGTERM          = 15
local SIGKILL          = 9
local EAGAIN           = 11
local EINTR            = 4
local EPIPE            = 32
local ECHILD           = 10

local errStr = {
    [1]='EPERM', [2]='No such file or directory', [11]='EAGAIN', [12]='ENOMEM',
    [13]='Permission denied', [20]='Not a directory', [21]='Is a directory',
    [8]='Exec format error', [36]='File name too long',
}
local function strerror(e) return errStr[e] or ('errno ' .. tostring(e)) end

-- ffi.cdef is process-global and FIRST declaration wins: lib/socket.lua declares
-- fcntl as `int fcntl(int, int, ...)`, so whichever module loads first decides
-- whether the third argument travels as a vararg or as a plain int.  A Lua
-- number in a vararg slot is passed as a double, which fcntl would read out of
-- the wrong register.  Casting to `long` is correct under BOTH declarations, so
-- every fcntl call here casts -- exactly as lib/socket.lua does.
local function fcntl3(fd, cmd, val)
    return tonumber(C.fcntl(fd, cmd, ffi.cast('long', val)))
end

--- Keep the child's fds away from 0/1/2 so the dup2 dance below can never
--- overwrite a pipe end with itself.
local function ensureHigh(fd)
    if fd > 2 then return fd end
    local nfd = fcntl3(fd, F_DUPFD_CLOEXEC, 3)
    if nfd < 0 then return fd end
    C.close(fd)
    return nfd
end

local function makePipe()
    local fds = ffi.new('int[2]')
    if C.pipe2(fds, O_CLOEXEC) ~= 0 then
        return nil, 'pipe2 failed, errno=' .. tostring(ffi.errno())
    end
    return ensureHigh(fds[0]), ensureHigh(fds[1])
end

local function setNonBlock(fd)
    local fl = fcntl3(fd, F_GETFL, 0)
    if fl < 0 then fl = 0 end
    -- bit.bor is signed; both operands are small positive flags, so the result
    -- stays positive and needs no % 0x100000000 normalisation.
    return fcntl3(fd, F_SETFL, bit.bor(fl, O_NONBLOCK)) ~= -1
end

-- Writing to a child that has exited (or closed its stdin) raises SIGPIPE, whose
-- DEFAULT disposition kills the WRITER -- so a hub that sends one byte to a worker
-- which died a moment ago dies with it, taking every other worker down.  Ask for the
-- error instead: write() then fails with EPIPE and _flushStdin closes the pipe.
-- lib/socket.lua does the same inside socket.init(); doing it here too means
-- lib/process.lua is safe on its own, and setting SIG_IGN twice is harmless.
cdef 'void* signal(int, void*);'
pcall(function() C.signal(13, ffi.cast('void*', 1)) end)      -- SIGPIPE -> SIG_IGN

backend = {}

function backend.spawn(h, opts)
    local cmd = h.cmd
    local fds = {}
    local function closeAll()
        for i = 1, #fds do if fds[i] and fds[i] >= 0 then C.close(fds[i]) end end
    end

    local inR,  inW  = makePipe(); if not inR  then closeAll(); return nil, inW  end
    fds[#fds + 1] = inR; fds[#fds + 1] = inW
    local outR, outW, errR, errW
    if h.capture then
        outR, outW = makePipe(); if not outR then closeAll(); return nil, outW end
        fds[#fds + 1] = outR; fds[#fds + 1] = outW
        errR, errW = makePipe(); if not errR then closeAll(); return nil, errW end
        fds[#fds + 1] = errR; fds[#fds + 1] = errW
    end
    -- exec status channel: O_CLOEXEC, so a successful exec closes it (EOF) and a
    -- failed one leaves the errno in it.
    local xR, xW = makePipe(); if not xR then closeAll(); return nil, xW end
    fds[#fds + 1] = xR; fds[#fds + 1] = xW

    -- ---- build every C object the child needs BEFORE the fork -------------
    local keep = {}
    local argv = ffi.new('char*[?]', #cmd + 1)
    for i = 1, #cmd do
        local c = ffi.new('char[?]', #cmd[i] + 1)
        ffi.copy(c, cmd[i])
        keep[#keep + 1] = c
        argv[i - 1] = c
    end
    argv[#cmd] = nil

    local envp = nil
    if h.env then
        local map = {}
        if not h.envReplace then
            local p = C.environ
            local i = 0
            while p[i] ~= nil do
                local s = ffi.string(p[i])
                local k, v = s:match('^([^=]+)=(.*)$')
                if k then map[k] = v end
                i = i + 1
            end
        end
        for k, v in pairs(h.env) do map[k] = v end
        local list = {}
        for k, v in pairs(map) do list[#list + 1] = k .. '=' .. v end
        table.sort(list)
        envp = ffi.new('char*[?]', #list + 1)
        for i = 1, #list do
            local c = ffi.new('char[?]', #list[i] + 1)
            ffi.copy(c, list[i])
            keep[#keep + 1] = c
            envp[i - 1] = c
        end
        envp[#list] = nil
    end

    local cwdC = nil
    if h.cwd then
        cwdC = ffi.new('char[?]', #h.cwd + 1)
        ffi.copy(cwdC, h.cwd)
        keep[#keep + 1] = cwdC
    end
    local errnoBuf = ffi.new('int[1]')
    local cap = h.capture and true or false      -- plain local, not a table read
    -- PR_SET_PDEATHSIG is the POSIX counterpart of the Windows job object: the
    -- kernel signals the child when THIS process dies, so a hub that is killed
    -- -9 does not leave workers behind.  It survives execve (except for setuid
    -- images) and is inherited by nothing, so each child arms its own.
    local deathSig = h.deathSignal or 0
    local sweepMax = OPEN_MAX        -- plain local: no table read after the fork

    local pid = C.fork()
    if pid < 0 then
        local e = ffi.errno()
        closeAll()
        return nil, 'fork failed, errno=' .. tostring(e)
    end

    if pid == 0 then
        -- ================= child: async-signal-safe work only ===============
        c_dup2(inR, 0)
        if cap then
            c_dup2(outW, 1)
            c_dup2(errW, 2)
        end
        c_close(inR); c_close(inW)
        if cap then
            c_close(outR); c_close(outW); c_close(errR); c_close(errW)
        end
        c_close(xR)
        -- ---- post-fork hygiene, in this order --------------------------------
        -- 1. Close every OTHER inherited descriptor.  The three std pipes are
        --    already in place, and xW must stay open (it is CLOEXEC, so a
        --    successful exec closes it and a failed one still carries the errno),
        --    so the sweep skips exactly those four.  Without it the child gets
        --    the hub's listening socket (an orphan keeps the port bound), its
        --    audit-log append handle and every other data file -- and the child
        --    runs operator-supplied Lua.
        if xW > 2 then
            if c_close_range ~= nil then
                if c_close_range(3, xW - 1, 0) ~= 0 then
                    for fd = 3, xW - 1 do c_close(fd) end
                end
                if c_close_range(xW + 1, 0x7FFFFFFF, 0) ~= 0 then
                    for fd = xW + 1, sweepMax do c_close(fd) end
                end
            else
                for fd = 3, sweepMax do
                    if fd ~= xW then c_close(fd) end
                end
            end
        end
        -- 2. Restore a clean signal mask and the two dispositions this module
        --    changed in the parent.  A mask survives execve, so a hub that blocks
        --    SIGTERM for its own signal gate would otherwise hand every worker a
        --    permanently-blocked SIGTERM -- which makes PR_SET_PDEATHSIG below,
        --    and the supervisor's graceful stop, silently do nothing.
        if c_sigprocmask ~= nil then
            c_sigprocmask(SIG_SETMASK, emptyMask, nil)
        end
        if c_signal ~= nil then
            c_signal(13, SIG_DFL)       -- SIGPIPE: the parent set SIG_IGN
            c_signal(17, SIG_DFL)       -- SIGCHLD, in case a caller changed it
        end
        if cwdC ~= nil then
            if c_chdir(cwdC) ~= 0 then
                errnoBuf[0] = ffi.errno()
                c_write(xW, errnoBuf, 4)
                c_exit(127)
            end
        end
        if deathSig > 0 and c_prctl ~= nil then
            c_prctl(PR_SET_PDEATHSIG, deathSig, 0, 0, 0)
        end
        if envp ~= nil and c_execvpe ~= nil then
            c_execvpe(argv[0], argv, envp)
        else
            if envp ~= nil then C.environ = envp end
            c_execvp(argv[0], argv)
        end
        errnoBuf[0] = ffi.errno()
        c_write(xW, errnoBuf, 4)
        c_exit(127)
        -- ====================================================================
    end

    -- ---- parent -----------------------------------------------------------
    C.close(inR)
    if h.capture then C.close(outW); C.close(errW) end
    C.close(xW)

    setNonBlock(inW)
    if h.capture then setNonBlock(outR); setNonBlock(errR) end

    -- The exec-status pipe is the one place we accept a short blocking read:
    -- it resolves in microseconds (exec succeeded -> EOF, failed -> 4 bytes)
    -- and it is the difference between a real error message and exit 127.
    local n = tonumber(C.read(xR, errnoBuf, 4))
    while n < 0 and ffi.errno() == EINTR do n = tonumber(C.read(xR, errnoBuf, 4)) end
    C.close(xR)
    if n == 4 then
        local st = ffi.new('int[1]')
        C.waitpid(pid, st, 0)                       -- reap the failed child
        C.close(inW)
        if h.capture then C.close(outR); C.close(errR) end
        return nil, ('execvp %q: %s'):format(cmd[1], strerror(errnoBuf[0]))
    end

    h.fdStdin  = inW
    h.fdStdout = h.capture and outR or nil
    h.fdStderr = h.capture and errR or nil
    h._pid     = pid
    return true
end

local rbuf = ffi.new('char[?]', READ_CHUNK)

function backend.read(h, which)
    local fd = (which == 'stdout') and h.fdStdout or h.fdStderr
    if fd == nil then return nil end
    local n = tonumber(C.read(fd, rbuf, READ_CHUNK))
    if n > 0 then return ffi.string(rbuf, n) end
    if n == 0 then return nil end                       -- EOF
    local e = ffi.errno()
    if e == EAGAIN or e == EINTR then return '' end
    return nil
end

function backend.closeRead(h, which)
    local f = (which == 'stdout') and 'fdStdout' or 'fdStderr'
    if h[f] then C.close(h[f]); h[f] = nil end
end

function backend.write(h, data)
    if h.fdStdin == nil then return nil, 'stdin is closed' end
    if #data == 0 then return 0 end
    local n = tonumber(C.write(h.fdStdin, data, #data))
    if n >= 0 then return n end
    local e = ffi.errno()
    if e == EAGAIN or e == EINTR then return 0 end
    if e == EPIPE then return nil, 'child closed stdin' end
    return nil, 'write failed, errno=' .. tostring(e)
end

function backend.closeStdin(h)
    if h.fdStdin then C.close(h.fdStdin); h.fdStdin = nil end
end

local status = ffi.new('int[1]')

function backend.tryWait(h)
    if h._reaped then return h._code, h._signal end
    status[0] = 0
    local r = tonumber(C.waitpid(h._pid, status, WNOHANG))
    while r < 0 and ffi.errno() == EINTR do
        r = tonumber(C.waitpid(h._pid, status, WNOHANG))
    end
    if r == 0 then return nil end                       -- still running
    if r < 0 then
        -- ECHILD: already reaped by someone else; treat as gone.
        h._reaped = true
        return -1, nil
    end
    h._reaped = true
    local st = status[0]
    local low = st % 128
    if low == 0 then
        return math.floor(st / 256) % 256, nil          -- WIFEXITED
    end
    if low == 127 then return nil, nil end              -- stopped, not our case
    return nil, low                                     -- WIFSIGNALED
end

-- Both of these are last-line guards: a pid whose child has been reaped belongs to
-- the kernel again and may already have been handed to an unrelated process of this
-- user.  Never signal one.
function backend.signalGraceful(h)
    if h._reaped or h._exited then return true end
    C.kill(h._pid, SIGTERM)
    return true
end

function backend.forceKill(h)
    if h._reaped or h._exited then return end
    C.kill(h._pid, SIGKILL)
end

function backend.release(h) end

function process.jobActive() return false end

--- Is some pid still running?  A zombie is NOT alive: kill(pid, 0) succeeds for
--- one, so the /proc state is the tiebreaker.
function process.isPidAlive(pid)
    pid = tonumber(pid)
    if not pid or pid <= 0 then return false end
    if C.kill(pid, 0) ~= 0 then return false end
    local f = io.open('/proc/' .. pid .. '/stat', 'rb')
    if not f then return true end
    local s = f:read('*a')
    f:close()
    return s:match('%)%s+(%a)') ~= 'Z'
end

--=============================================================================
else
    error('lib/process.lua: unsupported platform ' .. tostring(ffi.os))
end
--=============================================================================

-- ================================================================= handle ==
local Handle = {}
Handle.__index = Handle

function Handle:pid() return self._pid end

function Handle:status()
    if not self._exited then return 'running' end
    return self._signal and 'signalled' or 'exited'
end

function Handle:isRunning() return not self._exited end

function Handle:exitCode() return self._code end

function Handle:exitSignal() return self._signal end

function Handle:uptimeMs()
    return (self._endMs or sys.nowMs()) - self._startMs
end

function Handle:describe()
    return table.concat(self.redactedCmd, ' ')
end

--- Queue data for the child's stdin.  Never blocks: what the pipe will not take
--- right now stays queued and poll() retries.
function Handle:write(data)
    if data == nil then return nil, 'process:write: nil data' end
    data = tostring(data)
    if self._stdinGone then return nil, 'stdin is closed' end
    if self._stdinClosePending then return nil, 'stdin is closing' end
    -- A worker that stops reading stdin (wedged, stopped, or merely busy) would
    -- otherwise make the hub buffer every byte it sends it, with no error and no
    -- bound.  Refuse instead, so the caller can back off or restart the worker.
    if self._stdinQLen + #data > self.maxStdinQueue then
        return nil, ('stdin queue full (%d + %d > %d bytes)')
                    :format(self._stdinQLen, #data, self.maxStdinQueue)
    end
    if #data > 0 then
        self._stdinQ[#self._stdinQ + 1] = data
        self._stdinQLen = self._stdinQLen + #data
    end
    self:_flushStdin()
    return true
end

function Handle:pendingStdin() return self._stdinQLen end

--- Close the child's stdin (EOF) once everything queued has been handed over.
function Handle:closeStdin()
    self._stdinClosePending = true
    self:_flushStdin()
    return true
end

function Handle:_flushStdin()
    if self._stdinGone then return end
    while #self._stdinQ > 0 do
        local chunk = self._stdinQ[1]
        local n, err = backend.write(self, chunk)
        if n == nil then
            self._stdinErr = err
            backend.closeStdin(self)
            self._stdinGone = true
            self._stdinQ, self._stdinQLen = {}, 0
            return
        end
        if n <= 0 then return end                    -- pipe full: try again later
        self._stdinQLen = self._stdinQLen - n
        if n >= #chunk then
            table.remove(self._stdinQ, 1)
        else
            self._stdinQ[1] = chunk:sub(n + 1)
            return
        end
    end
    if self._stdinClosePending then
        backend.closeStdin(self)
        self._stdinGone = true
    end
end

function Handle:_emit(line, stream)
    self.linesOut = self.linesOut + 1
    if self.onLine then
        local ok, err = pcall(self.onLine, line, stream, self)
        if not ok then process.onError('onLine', err) end
    end
end

--- Drain one stream as far as it will go this turn.  Returns true when the
--- stream reached EOF and was closed.
function Handle:_drain(which)
    local closed = false
    local budget = 64                       -- at most 4 MB per stream per poll
    while budget > 0 do
        budget = budget - 1
        local chunk = backend.read(self, which)
        if chunk == nil then
            closed = true
            break
        end
        if chunk == '' then break end
        self.bytesOut = self.bytesOut + #chunk
        local key = (which == 'stdout') and '_tailOut' or '_tailErr'
        local me, w = self, which
        self[key] = feedLines(self[key], chunk, self.maxLineBytes,
                              function(line) me:_emit(line, w) end)
    end
    if closed then
        local key = (which == 'stdout') and '_tailOut' or '_tailErr'
        if #self[key] > 0 then
            self:_emit(self[key], which)
            self[key] = ''
        end
        backend.closeRead(self, which)
        if which == 'stdout' then self._outEof = true else self._errEof = true end
    end
    return closed
end

--- One non-blocking supervision step.  Safe to call as often as you like.
function Handle:poll()
    if self._done then return 'exited' end

    self:_flushStdin()

    if self.capture then
        if not self._outEof then self:_drain('stdout') end
        if not self._errEof then self:_drain('stderr') end
    end

    -- Reap FIRST.  The escalation below must never fire at a pid we no longer own:
    -- once waitpid() has reaped the child the pid is free for reuse, yet the handle
    -- stays out of _done for the whole drain window (a grandchild can hold the
    -- capture pipe open), and kill(pid, SIGKILL) would then hit whatever process of
    -- this user happens to have inherited the number.
    if not self._exited then
        local code, signal = backend.tryWait(self)
        if code ~= nil or signal ~= nil then
            self._exited  = true
            self._code    = code
            self._signal  = signal
            self._endMs   = sys.nowMs()
            self._drainAt = self._endMs + self.drainMs
            self._killAt  = nil
        end
    end

    -- forceful escalation of a graceful stop
    if self._killAt and not self._killed and not self._exited and not self._reaped
       and sys.nowMs() >= self._killAt then
        self._killed = true
        backend.forceKill(self)
    end

    if self._exited then
        self._killAt = nil
        -- The process is gone but its output may still be sitting in the pipe.
        -- Keep draining until both pipes report EOF, or the drain window ends
        -- (a grandchild could hold the write end open forever).
        local pending = self.capture and (not self._outEof or not self._errEof)
        if pending and sys.nowMs() < self._drainAt then
            return 'running'
        end
        self._done = true
        if self.capture then
            if not self._outEof then self:_drain('stdout') end
            if not self._errEof then self:_drain('stderr') end
            backend.closeRead(self, 'stdout')
            backend.closeRead(self, 'stderr')
        end
        if not self._stdinGone then backend.closeStdin(self); self._stdinGone = true end
        backend.release(self)
        unregister(self)
        if self.onExit then
            local ok, err = pcall(self.onExit, self._code, self._signal, self)
            if not ok then process.onError('onExit', err) end
        end
        return 'exited'
    end

    return 'running'
end

-- The escalation from "asked to stop" to SIGKILL / TerminateProcess is applied by
-- poll().  Relying on the caller to happen to call poll() after the grace expires
-- means a child that ignores SIGTERM outlives its grace window whenever the poll
-- cadence lapses (a busy reactor turn, a hub that only polls on demand, a shutdown
-- path that stops several children and then waits).  So stop() also arms a one-shot
-- timer on lib/sched.lua when one is available: the deadline is then enforced by the
-- reactor itself, and poll() remains the fallback for a program without a reactor.
local schedMod            -- nil = not looked for yet, false = not available
local function armEscalation(h, ms)
    if h._escalationArmed then return end
    if schedMod == nil then
        local ok, m = pcall(require, 'lib.sched')
        schedMod = (ok and type(m) == 'table' and type(m.after) == 'function') and m or false
    end
    if not schedMod then return end
    h._escalationArmed = true
    local ok = pcall(schedMod.after, ms + 1, function()
        h._escalationArmed = false
        if h._done then return end
        pcall(h.poll, h)
        -- The kill itself is asynchronous: the child still has to die and be
        -- reaped, and the pipes still have to reach EOF.  Follow up a bounded
        -- number of times so the handle really leaves the registry even in a
        -- program whose only heartbeat is the reactor.
        h._escalationTicks = (h._escalationTicks or 0) + 1
        if not h._done and h._escalationTicks < 60 then armEscalation(h, 50) end
    end)
    if not ok then h._escalationArmed = false end
end

--- Ask the child to stop.  NON-BLOCKING: the forceful escalation happens on the
--- sched timer armed here, or in a later poll().  Graceful means, in order:
---   1. opts.stopCommand written to stdin (if configured)
---   2. stdin closed -> the child sees EOF        (unless closeStdinOnStop=false)
---   3. POSIX only: SIGTERM
--- and after graceMs, TerminateProcess / SIGKILL.
function Handle:stop(graceMs)
    if self._done or self._exited or self._reaped then return true end
    graceMs = tonumber(graceMs) or process.DEFAULT_GRACE_MS
    if graceMs < 0 then graceMs = 0 end
    if not self._stopping then
        self._stopping = true
        if self.stopCommand and not self._stdinGone then
            self._stdinQ[#self._stdinQ + 1] = self.stopCommand
            self._stdinQLen = self._stdinQLen + #self.stopCommand
        end
        if self.closeStdinOnStop ~= false then self._stdinClosePending = true end
        self:_flushStdin()
        backend.signalGraceful(self)
    end
    local at = sys.nowMs() + graceMs
    if not self._killAt or at < self._killAt then self._killAt = at end
    if graceMs == 0 then
        self._killed = true
        backend.forceKill(self)
    else
        armEscalation(self, graceMs)
    end
    return true
end

--- Kill now, no grace.
function Handle:kill()
    if self._done or self._exited or self._reaped then return true end
    self._stopping = true
    self._killed   = true
    backend.forceKill(self)
    return true
end

--- BLOCKING.  Only for shutdown paths and tests: pumps poll() with 1 ms sleeps.
function Handle:wait(timeoutMs)
    timeoutMs = tonumber(timeoutMs) or 10000
    local deadline = sys.nowMs() + timeoutMs
    while true do
        if self:poll() == 'exited' then return self._code, self._signal end
        if sys.nowMs() >= deadline then return nil, 'timeout' end
        sys.sleepMs(1)
    end
end

-- ================================================================== spawn ==
function process.onError(what, err)
    local ok, log = pcall(require, 'lib.log')
    if ok then log.error('process: %s: %s', what, tostring(err))
    else io.stderr:write('process: ', tostring(what), ': ', tostring(err), '\n') end
end

--- Spawn a child.  Returns a handle, or nil + an error string.
function process.spawn(opts)
    if type(opts) ~= 'table' then return nil, 'process.spawn: opts must be a table' end

    local cmd, err = normaliseCmd(opts.cmd)
    if not cmd then return nil, err end

    -- A secret in argv is not a secret: on Linux /proc/<pid>/cmdline is mode 0444, so
    -- every local user and every `ps` reads it for as long as the child lives (and
    -- h:describe()'s '***' only ever affected OUR log line, never the argv the kernel
    -- publishes).  Refuse it here so the hub cannot regress into doing it, and use
    -- the private stdin pipe instead:
    --     process.spawn{ cmd = { worker, '--proxy=host:port' },
    --                    stdinData = 'proxy-auth ' .. user .. ':' .. pass .. '\n' }
    -- opts.allowSecretsInArgv = true is the deliberate, documented override.
    local redactPatterns = opts.redact or DEFAULT_REDACT
    if not opts.allowSecretsInArgv then
        local at, which = secretInArgv(cmd, redactPatterns)
        if at then
            return nil, ('process.spawn: refusing to place a secret in argv (%s, argument %d)'
                         .. ' -- pass it on stdin with opts.stdinData'):format(which, at)
        end
    end

    local env
    env, err = normaliseEnv(opts.env)
    if opts.env ~= nil and not env then return nil, err end

    if opts.cwd ~= nil and type(opts.cwd) ~= 'string' then
        return nil, 'process.spawn: cwd must be a string'
    end

    local h = setmetatable({}, Handle)
    h.cmd               = cmd
    h.cwd               = opts.cwd
    h.env               = env
    h.envReplace        = opts.envReplace and true or false
    h.capture           = (opts.captureOutput ~= false)
    h.onLine            = opts.onLine
    h.onExit            = opts.onExit
    h.stopCommand       = opts.stopCommand
    h.closeStdinOnStop  = opts.closeStdinOnStop
    -- 0 (a plausible spelling of "no limit") used to hang the reactor in feedLines
    h.maxLineBytes      = math.max(1024, tonumber(opts.maxLineBytes)
                                         or process.DEFAULT_MAX_LINE)
    h.maxStdinQueue     = math.max(4096, tonumber(opts.maxStdinQueue) or (1024 * 1024))
    h.drainMs           = tonumber(opts.drainMs) or 2000
    h.name              = opts.name
    -- Linux only: SIGTERM when the hub dies.  opts.deathSignal = false disables,
    -- a number picks another signal (9 for a worker that might ignore SIGTERM).
    if opts.deathSignal == false then h.deathSignal = 0
    elseif type(opts.deathSignal) == 'number' then h.deathSignal = opts.deathSignal
    else h.deathSignal = 15 end
    h.redactedCmd       = redactCmd(cmd, redactPatterns, opts.secretArgs)

    h._stdinQ, h._stdinQLen = {}, 0
    h._tailOut, h._tailErr  = '', ''
    h.linesOut, h.bytesOut  = 0, 0
    h._outEof = not h.capture
    h._errEof = not h.capture
    h._startMs = sys.nowMs()

    local ok, serr = backend.spawn(h, opts)
    if not ok then return nil, serr end

    -- Only the REDACTED command line is kept on the handle: a hub that logs
    -- h.cmdline must not be able to leak an account password by accident.
    h.cmdline = table.concat(h.redactedCmd, ' ')

    register(h)

    if opts.stdinData ~= nil then
        h:write(tostring(opts.stdinData))
        if opts.closeStdinAfterData == true then h:closeStdin() end
    end

    return h
end

--- Poll every live child once.  Register this with sched.every(50, ...).
function process.pollAll()
    if #live == 0 then return 0 end
    local snapshot = {}
    for i = 1, #live do snapshot[i] = live[i] end
    local n = 0
    for i = 1, #snapshot do
        local h = snapshot[i]
        if not h._done then
            local ok, err = pcall(h.poll, h)
            if not ok then process.onError('poll', err)
            elseif err == 'running' then n = n + 1 end
        end
    end
    return n
end

--- BLOCKING.  Stop every remaining child and wait for it.  Called by the exit
--- hook so the hub cannot leak workers.  Returns how many were still alive.
function process.reapAll(graceMs)
    graceMs = tonumber(graceMs) or 2000
    local snapshot = {}
    for i = 1, #live do snapshot[i] = live[i] end
    if #snapshot == 0 then return 0 end
    for i = 1, #snapshot do pcall(snapshot[i].stop, snapshot[i], graceMs) end
    local deadline = sys.nowMs() + graceMs + 2000
    while sys.nowMs() < deadline do
        local alive = 0
        for i = 1, #snapshot do
            local h = snapshot[i]
            if not h._done then
                pcall(h.poll, h)
                if not h._done then alive = alive + 1 end
            end
        end
        if alive == 0 then return #snapshot end
        sys.sleepMs(2)
    end
    -- last resort
    for i = 1, #snapshot do
        local h = snapshot[i]
        if not h._done then pcall(h.kill, h); pcall(h.poll, h) end
    end
    return #snapshot
end

sys.atExit(function() pcall(process.reapAll, 1500) end)

-- exposed for the test suite
process._feedLines = feedLines
process._redactCmd = redactCmd
process._secretInArgv = secretInArgv
process._backend = backend       -- so a test can observe that forceKill is NOT called

return process
