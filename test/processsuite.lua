--[[============================================================================
test/processsuite.lua -- proof for work item H3 (lib/process.lua).

  luajit test/processsuite.lua          (from D:/Claude/otclient_web/luaclient)

Every child is the LuaJIT interpreter that is running this suite, driven with
`-e <chunk>`; no extra binary, no shell, no fixture file.  (`luajit -e CODE a b`
runs CODE first and only then tries to open `a` as a script, so a chunk that
ends in os.exit() sees its extra arguments at arg[0], arg[1], ... -- that is how
S6 gets the child to print its own argv.)

  S1  Windows argv encoding: the CommandLineToArgvW rules, unit-tested
  S2  line splitting: \n, \r\n, partial tails, an oversized line
  S3  argv redaction for h:describe()
  S4  1000 stdout lines: none lost, none reordered, stderr kept separate
  S5  a non-zero exit code is reported exactly
  S6  argv round trip: spaces, quotes, backslashes, tabs, empty -> byte-identical
  S7  stdin round trip, and a secret delivered on stdin instead of argv
  S8  stop(): graceful path -- a child that reacts to EOF exits on its own
  S9  stop(): forceful path -- a child that ignores everything is killed
  S10 kill() is immediate
  S11 cwd and env reach the child
  S12 a bad executable reports a real error and leaks no handle
  S13 10 concurrent children
  S14 driven from lib/sched.lua: the reactor never stalls
  S15 reapAll() -- the leak-prevention path the exit hook uses
  S16 a grandchild dies with its parent (job object / PR_SET_PDEATHSIG)
  S17 pipe flags (Linux): the parent ends are non-blocking, the child ends are not
  S18 no zombies remain (Linux), the registry is empty, no globals
============================================================================]]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. package.path
end

-- lib/socket.lua FIRST, on purpose.  ffi.cdef is process-global and the first
-- declaration of a symbol wins: socket.lua declares fcntl as varargs, and the
-- hub will always have loaded it before lib/process.lua.  Requiring it here
-- means the suite exercises the same, more hazardous, declaration order.
require('lib.socket')

local process = require('lib.process')
local sys     = require('lib.sys')
local json    = require('lib.json')

-- The interpreter running this suite: the lowest negative index of `arg`.
local LUAJIT
do
    local i = -1
    while arg[i - 1] ~= nil do i = i - 1 end
    LUAJIT = arg[i]
end

-- --------------------------------------------------------------- framework
local pass, fail, msgs = 0, 0, {}
local function check(ok, desc, detail)
    if ok then pass = pass + 1 else
        fail = fail + 1
        local line = '    FAIL  ' .. desc .. (detail and ('  -- ' .. tostring(detail)) or '')
        msgs[#msgs + 1] = line
        io.write(line, '\n')
    end
    io.stdout:flush()
    return ok
end
local function eq(got, want, desc)
    if got == want then return check(true, desc) end
    return check(false, desc, ('got %s, want %s'):format(tostring(got), tostring(want)))
end
local function head(t) io.write('\n== ', t, ' ==\n'); io.stdout:flush() end
local function note(s) io.write('     ', s, '\n'); io.stdout:flush() end

--- Pump every live child until `pred` is true or the deadline passes.
local function pumpUntil(pred, timeoutMs, each)
    local deadline = sys.nowMs() + (timeoutMs or 20000)
    while true do
        process.pollAll()
        if each then each() end
        if pred() then return true end
        if sys.nowMs() >= deadline then
            process.pollAll()
            return pred() and true or false
        end
        sys.sleepMs(1)
    end
end

note('platform   : ' .. (process.isWindows and 'Windows' or 'Linux'))
note('interpreter: ' .. tostring(LUAJIT))

-- ============================================================ child chunks =
-- Kept as long strings so the quoting layer has to carry real quotes and
-- backslashes through to the child on Windows.

local C_FLOOD = [==[
local n = tonumber(os.getenv('LCP_N')) or 1000
for i = 1, n do io.write('L', i, ' ', string.rep('x', 90), '\n') end
io.stdout:flush()
io.stderr:write('E-first\n')
io.stderr:write('E-second\n')
io.stderr:flush()
os.exit(0)
]==]

local C_EXIT42 = [==[
io.write('about to leave\n') io.stdout:flush()
os.exit(42)
]==]

local C_ARGV = [==[
package.path = os.getenv('LCP_ROOT') .. '/?.lua;' .. package.path
local json = require('lib.json')
local t, i = {}, 0
while arg[i] ~= nil do t[#t + 1] = arg[i]; i = i + 1 end
io.write(json.encode(t), '\n')
io.stdout:flush()
os.exit(0)
]==]

local C_STDIN = [==[
while true do
  local l = io.read('*l')
  if l == nil then io.write('EOF\n') io.stdout:flush() break end
  if l == 'QUIT' then io.write('QUITTING\n') io.stdout:flush() break end
  io.write('echo[', #l, ']=', l, '\n')
  io.stdout:flush()
end
os.exit(7)
]==]

-- Ignores SIGTERM, but still exits when stdin reaches EOF -> the graceful path.
local C_EOFEXIT = [==[
pcall(function()
  local ffi = require('ffi')
  ffi.cdef[[void* signal(int, void*);]]
  ffi.C.signal(15, ffi.cast('void*', 1))
end)
io.write('ready\n') io.stdout:flush()
io.read('*a')
io.write('bye\n') io.stdout:flush()
os.exit(3)
]==]

-- Ignores SIGTERM and never reads stdin -> only a hard kill ends it.
local C_STUBBORN = [==[
pcall(function()
  local ffi = require('ffi')
  ffi.cdef[[void* signal(int, void*);]]
  ffi.C.signal(15, ffi.cast('void*', 1))
  ffi.C.signal(2,  ffi.cast('void*', 1))
end)
io.write('ready\n') io.stdout:flush()
local t0 = os.time()
while os.time() - t0 < 30 do local x = 0 for i = 1, 200000 do x = x + i end end
os.exit(0)
]==]

local C_CWDENV = [==[
local f = io.open('lcp-marker.txt', 'rb')
io.write('marker=', f and f:read('*a') or 'MISSING', '\n')
if f then f:close() end
io.write('var=', tostring(os.getenv('LCP_MYVAR')), '\n')
io.write('inherited=', tostring(os.getenv('LCP_PARENT_ONLY')), '\n')
io.stdout:flush()
os.exit(0)
]==]

local C_SECRET = [==[
local secret = io.read('*l')
io.write('secretlen=', #secret, '\n')
io.write('secret=', secret, '\n')
io.stdout:flush()
os.exit(0)
]==]

-- A miniature "hub": spawns a long-lived grandchild through lib/process.lua and
-- then hangs around, so the suite can kill it and watch what happens.
local C_HUB = [==[
package.path = os.getenv('LCP_ROOT') .. '/?.lua;' .. package.path
local process = require('lib.process')
local h = assert(process.spawn{
  cmd = { os.getenv('LCP_LJ'), '-e', os.getenv('LCP_CHUNK') },
  captureOutput = false,
})
io.write('grandchild=', h:pid(), '\n')
io.stdout:flush()
local t0 = os.time()
while os.time() - t0 < 60 do local x = 0 for i = 1, 200000 do x = x + i end end
os.exit(0)
]==]

-- The grandchild: plain, no signal handlers, just long-lived.
local C_SLEEPER = [==[
local t0 = os.time()
while os.time() - t0 < 60 do local x = 0 for i = 1, 200000 do x = x + i end end
os.exit(0)
]==]

local C_WORKER = [==[
local id = os.getenv('LCP_ID')
for i = 1, 200 do io.write(id, ':', i, '\n') end
io.stdout:flush()
os.exit(tonumber(id))
]==]

--=============================================================================
head('S1  Windows argv encoding (CommandLineToArgvW rules)')
do
    local q = process.quoteWindowsArg
    eq(q('plain'),          'plain',              'no metacharacters -> no quotes')
    eq(q(''),               '""',                 'the empty argument becomes ""')
    eq(q('with space'),     '"with space"',       'a space forces quotes')
    eq(q('a\tb'),           '"a\tb"',             'a tab forces quotes')
    eq(q('a"b'),            '"a\\"b"',            'an embedded quote becomes \\"')
    eq(q('a\\b'),           'a\\b',               'a lone backslash is literal')
    eq(q('a\\b c'),         '"a\\b c"',           '   and stays literal inside quotes')
    -- The doubling rule only exists to stop a backslash run from escaping the
    -- CLOSING quote, so it applies only when the argument had to be quoted.
    eq(q('a\\'),            'a\\',                'an unquoted trailing backslash is left alone')
    eq(q('a b\\'),          '"a b\\\\"',          'a trailing backslash inside quotes is doubled')
    eq(q('a b\\\\'),        '"a b\\\\\\\\"',      '   two trailing backslashes -> four')
    eq(q('a\\"b'),          '"a\\\\\\"b"',        'n backslashes before " -> 2n+1 + \\"')
    eq(q('a\\\\"b'),        '"a\\\\\\\\\\"b"',    '   two before " -> five')
    eq(q('"'),              '"\\""',              'a bare quote')

    local cl = process.encodeWindowsCommandLine{ 'C:/Program Files/lj.exe', 'a b', 'c"d' }
    eq(cl, '"C:/Program Files/lj.exe" "a b" "c\\"d"',
       'argv[0] uses the simple rule, the rest the escaping rule')
    local bad, err = process.encodeWindowsCommandLine{ 'we"ird.exe' }
    eq(bad, nil, 'a quote in the executable path is refused')
    check(type(err) == 'string', '   and gives a reason', err)
end

--=============================================================================
head('S2  line splitting')
do
    local out = {}
    local emit = function(l) out[#out + 1] = l end
    local tail = ''
    tail = process._feedLines(tail, 'one\ntw', 1000, emit)
    eq(#out, 1, 'a complete line is emitted immediately')
    eq(out[1], 'one', '   with the newline stripped')
    eq(tail, 'tw', '   and the partial line kept as the tail')
    tail = process._feedLines(tail, 'o\r\nthree\n', 1000, emit)
    eq(out[2], 'two', 'the tail joins the next chunk')
    eq(out[3], 'three', '   and \\r\\n loses the \\r too')
    eq(tail, '', 'nothing left over')

    out, tail = {}, ''
    tail = process._feedLines(tail, string.rep('z', 25), 10, emit)
    eq(#out, 2, 'a line longer than maxLineBytes is cut, not buffered forever')
    eq(#out[1], 10, '   at exactly maxLineBytes')
    eq(#tail, 5, '   with the remainder still pending')

    out, tail = {}, ''
    tail = process._feedLines(tail, 'a\n\nb\n', 100, emit)
    eq(#out, 3, 'an empty line is a line')
    eq(out[2], '', '   and it is empty')
end

--=============================================================================
head('S3  argv redaction')
do
    local r = process._redactCmd({ 'luajit', 'main.lua', '--account=bob',
                                   '--password=hunter2', '--proxy-auth=u:p',
                                   '--token', '123456', '--character=Bob' },
                                 { 'password', 'token', 'proxy%-auth' })
    eq(r[3], '--account=bob',   'ordinary flags survive untouched')
    eq(r[4], '--password=***',  '--password= is masked')
    eq(r[5], '--proxy-auth=***', '--proxy-auth= is masked')
    eq(r[7], '***',             'the value AFTER a bare --token flag is masked')
    eq(r[8], '--character=Bob', 'and nothing else is')
end

--=============================================================================
head('S4  1000 stdout lines: no loss, no reordering')
do
    local N = 1000
    local lines, errs = {}, {}
    local exitCode, exitFired = nil, 0
    local h, err = process.spawn{
        cmd = { LUAJIT, '-e', C_FLOOD },
        env = { LCP_N = tostring(N) },
        captureOutput = true,
        onLine = function(line, stream)
            if stream == 'stdout' then lines[#lines + 1] = line
            else errs[#errs + 1] = line end
        end,
        onExit = function(code) exitCode = code; exitFired = exitFired + 1 end,
    }
    if not check(h ~= nil, 'spawn succeeded', err) then
        note('cannot continue without a child')
    else
        eq(type(h:pid()), 'number', 'the handle reports a pid')
        check(h:pid() > 0, '   and it is positive', h:pid())
        local ok = pumpUntil(function() return not h:isRunning() end, 30000)
        check(ok, 'the child exited within the timeout')
        eq(exitFired, 1, 'onExit fired exactly once')
        eq(exitCode, 0, '   with code 0')
        eq(#lines, N, ('all %d stdout lines arrived'):format(N))
        local ordered, badAt = true, nil
        for i = 1, math.min(#lines, N) do
            local idx = lines[i]:match('^L(%d+) ')
            if tonumber(idx) ~= i then ordered = false; badAt = i; break end
            if #lines[i] ~= #('L' .. i .. ' ') + 90 then ordered = false; badAt = i; break end
        end
        check(ordered, 'every line is intact and in order', badAt and ('first bad index ' .. badAt))
        eq(#errs, 2, 'stderr was delivered separately')
        eq(errs[1], 'E-first', '   in order (1)')
        eq(errs[2], 'E-second', '   in order (2)')
        note(('bytes captured: %d  (pipe buffer is 64K, so this drained live)'):format(h.bytesOut))
        check(h.bytesOut > 65536, 'more than one pipe buffer went through', h.bytesOut)
        eq(h:status(), 'exited', 'status() says exited')
        eq(process.count(), 0, 'the handle left the live registry')
    end
end

--=============================================================================
head('S5  a non-zero exit code is reported exactly')
do
    local last
    local h, err = process.spawn{
        cmd = { LUAJIT, '-e', C_EXIT42 },
        onLine = function(l) last = l end,
        onExit = function(code, sig) last = ('code=%s sig=%s'):format(tostring(code), tostring(sig)) end,
    }
    check(h ~= nil, 'spawn succeeded', err)
    if h then
        pumpUntil(function() return not h:isRunning() end, 20000)
        eq(h:exitCode(), 42, 'exitCode() is 42')
        eq(h:exitSignal(), nil, 'no signal')
        eq(last, 'code=42 sig=nil', 'onExit saw the same')
    end
end

--=============================================================================
head('S6  argv round trip (spaces, quotes, backslashes, tabs, empty)')
do
    -- No element may start with '-': LuaJIT would parse it as one of its own
    -- options before the -e chunk gets to run.
    local ARGS = {
        'plain',
        'with space',
        'quote"inside',
        'back\\slash',
        'trailing\\',
        'two\\\\slashes',
        'mixed \\"weird\\" \\\\ end',
        'tab\there',
        '',
        'ends with backslash\\\\',
        '"fully quoted"',
        'unicode zolw',
        'a b\\" c',
    }
    local cmd = { LUAJIT, '-e', C_ARGV }
    for i = 1, #ARGS do cmd[#cmd + 1] = ARGS[i] end

    local out = {}
    local h, err = process.spawn{
        cmd = cmd,
        env = { LCP_ROOT = ROOT },
        onLine = function(l, s) if s == 'stdout' then out[#out + 1] = l end end,
    }
    check(h ~= nil, 'spawn succeeded', err)
    if h then
        pumpUntil(function() return not h:isRunning() end, 20000)
        eq(h:exitCode(), 0, 'the child exited cleanly')
        local raw = table.concat(out, '')
        local okd, got = pcall(json.decode, raw)
        if not check(okd and type(got) == 'table', 'the child printed a JSON argv', raw) then
            note('raw: ' .. tostring(raw))
        else
            eq(#got, #ARGS, ('the child saw all %d arguments'):format(#ARGS))
            local allSame, firstBad = true, nil
            for i = 1, #ARGS do
                if got[i] ~= ARGS[i] then allSame = false; firstBad = i; break end
            end
            check(allSame, 'every argument arrived byte-identical',
                  firstBad and ('#%d: sent %q, got %q'):format(firstBad, ARGS[firstBad],
                                                               tostring(got[firstBad])))
            if allSame then
                for i = 1, #ARGS do note(('  arg[%2d] = %q  OK'):format(i, ARGS[i])) end
            end
        end
    end
end

--=============================================================================
head('S7  stdin round trip, and a secret that never touches argv')
do
    local out = {}
    local h, err = process.spawn{
        cmd = { LUAJIT, '-e', C_STDIN },
        onLine = function(l, s) if s == 'stdout' then out[#out + 1] = l end end,
    }
    check(h ~= nil, 'spawn succeeded', err)
    if h then
        eq(h:write('hello\n'), true, 'write() accepts data')
        h:write('a longer line with spaces\n')
        pumpUntil(function() return #out >= 2 end, 15000)
        eq(out[1], 'echo[5]=hello', 'the first line came back')
        eq(out[2], 'echo[25]=a longer line with spaces', 'the second line came back')
        h:write('QUIT\n')
        pumpUntil(function() return not h:isRunning() end, 15000)
        eq(out[3], 'QUITTING', 'the child acted on the last line')
        eq(h:exitCode(), 7, 'and exited with its own code')
        local werr = select(2, h:write('too late\n'))
        check(werr ~= nil, 'writing to a dead child fails cleanly', werr)
    end

    -- stdinData: the password is never an argument.
    local SECRET = 'correct horse battery staple'
    local got = {}
    local h2, err2 = process.spawn{
        cmd = { LUAJIT, '-e', C_SECRET, 'benign', 'args', 'only' },
        stdinData = SECRET .. '\n',
        onLine = function(l, s) if s == 'stdout' then got[#got + 1] = l end end,
    }
    check(h2 ~= nil, 'spawn with stdinData succeeded', err2)
    if h2 then
        pumpUntil(function() return not h2:isRunning() end, 15000)
        eq(got[1], 'secretlen=' .. #SECRET, 'the child read the secret from stdin')
        eq(got[2], 'secret=' .. SECRET, '   byte-identical')
        check(not h2:describe():find(SECRET, 1, true),
              'the secret appears nowhere in the recorded command line', h2:describe())
    end

    -- and when a password IS passed in argv, describe() masks it
    local h3 = process.spawn{
        cmd = { LUAJIT, '-e', 'os.exit(0)', 'account=x' },
        redact = { 'password' },
    }
    if h3 then
        pumpUntil(function() return not h3:isRunning() end, 15000)
        eq(h3:describe():find('os.exit', 1, true) ~= nil, true,
           'describe() still shows the benign part')
    end
    local masked = process._redactCmd({ 'lj', 'main.lua', '--password=hunter2' },
                                      { 'password' })
    check(not table.concat(masked, ' '):find('hunter2', 1, true),
          'a password given in argv is masked in the handle we would log')
end

--=============================================================================
head('S8  stop(): the graceful path is enough for a well-behaved child')
do
    local out = {}
    local h, err = process.spawn{
        cmd = { LUAJIT, '-e', C_EOFEXIT },
        onLine = function(l, s) if s == 'stdout' then out[#out + 1] = l end end,
    }
    check(h ~= nil, 'spawn succeeded', err)
    if h then
        pumpUntil(function() return out[1] == 'ready' end, 15000)
        eq(out[1], 'ready', 'the child is up and ignoring SIGTERM')
        local t0 = sys.nowMs()
        h:stop(4000)
        local dt0 = sys.nowMs() - t0
        check(dt0 < 50, ('stop() returned immediately, %.1f ms (non-blocking)'):format(dt0))
        pumpUntil(function() return not h:isRunning() end, 15000)
        local dt = sys.nowMs() - t0
        eq(h:exitCode(), 3, 'the child exited on its own terms (stdin EOF -> exit 3)')
        eq(h:exitSignal(), nil, '   not by a signal')
        check(dt < 3500, ('and well before the 4000 ms grace expired (%.0f ms)'):format(dt))
        eq(out[#out], 'bye', 'its farewell line was still captured after it exited')
    end
end

--=============================================================================
head('S9  stop(): a child that ignores everything gets killed after the grace')
do
    local out = {}
    local h, err = process.spawn{
        cmd = { LUAJIT, '-e', C_STUBBORN },
        onLine = function(l, s) if s == 'stdout' then out[#out + 1] = l end end,
    }
    check(h ~= nil, 'spawn succeeded', err)
    if h then
        pumpUntil(function() return out[1] == 'ready' end, 15000)
        eq(out[1], 'ready', 'the stubborn child is up')
        local t0 = sys.nowMs()
        h:stop(400)
        pumpUntil(function() return not h:isRunning() end, 15000)
        local dt = sys.nowMs() - t0
        check(not h:isRunning(), 'stop() terminated it')
        check(dt >= 350, ('the grace period was honoured first (%.0f ms)'):format(dt))
        check(dt < 5000, ('   and the escalation was prompt (%.0f ms)'):format(dt))
        if process.isLinux then
            eq(h:exitSignal(), 9, 'killed by SIGKILL (SIGTERM was ignored)')
            eq(h:status(), 'signalled', 'status() says signalled')
        else
            eq(h:exitCode(), 1, 'TerminateProcess exit code')
            eq(h:status(), 'exited', 'status() says exited (Windows has no signals)')
        end
    end
end

--=============================================================================
head('S10 kill() is immediate')
do
    local out = {}
    local h = process.spawn{
        cmd = { LUAJIT, '-e', C_STUBBORN },
        onLine = function(l, s) if s == 'stdout' then out[#out + 1] = l end end,
    }
    if check(h ~= nil, 'spawn succeeded') then
        pumpUntil(function() return out[1] == 'ready' end, 15000)
        local t0 = sys.nowMs()
        h:kill()
        pumpUntil(function() return not h:isRunning() end, 15000)
        local dt = sys.nowMs() - t0
        check(not h:isRunning(), 'the child is gone')
        check(dt < 2500, ('with no grace period (%.0f ms)'):format(dt))
        if process.isLinux then eq(h:exitSignal(), 9, 'SIGKILL') end
    end
end

--=============================================================================
head('S11 cwd and env reach the child')
do
    local dir = sys.tempDir()
    local f = assert(io.open(dir .. '/lcp-marker.txt', 'wb'))
    f:write('HELLO-FROM-' .. tostring(sys.tickCount()))
    f:close()
    local want = assert(io.open(dir .. '/lcp-marker.txt', 'rb')):read('*a')

    local out = {}
    local h, err = process.spawn{
        cmd = { LUAJIT, '-e', C_CWDENV },
        cwd = dir,
        env = { LCP_MYVAR = 'set-by-the-hub' },
        onLine = function(l, s) if s == 'stdout' then out[#out + 1] = l end end,
    }
    check(h ~= nil, 'spawn with cwd + env succeeded', err)
    if h then
        pumpUntil(function() return not h:isRunning() end, 20000)
        eq(out[1], 'marker=' .. want, 'the child ran in the requested cwd')
        eq(out[2], 'var=set-by-the-hub', 'the env override reached it')
        eq(out[3], 'inherited=nil', 'and an unset variable is still unset')
    end

    -- the parent's environment must be MERGED, not replaced
    local out2 = {}
    local h2 = process.spawn{
        cmd = { LUAJIT, '-e', C_CWDENV },
        cwd = dir,
        env = { LCP_MYVAR = 'second' },
        onLine = function(l, s) if s == 'stdout' then out2[#out2 + 1] = l end end,
    }
    if h2 then
        pumpUntil(function() return not h2:isRunning() end, 20000)
        eq(out2[2], 'var=second', 'a second child gets its own override')
    end
    os.remove(dir .. '/lcp-marker.txt')
end

--=============================================================================
head('S12 a bad executable reports a real error')
do
    local before = process.count()
    local h, err = process.spawn{ cmd = { 'lcp-definitely-not-a-real-binary-xyz', 'a' } }
    eq(h, nil, 'spawn refused')
    check(type(err) == 'string' and #err > 0, 'with a message', err)
    note('error: ' .. tostring(err))
    eq(process.count(), before, 'and nothing was added to the live registry')

    local h2, e2 = process.spawn{ cmd = {} }
    eq(h2, nil, 'an empty cmd list is refused')
    check(type(e2) == 'string', '   with a message', e2)
    local h3, e3 = process.spawn{ cmd = { LUAJIT, 42, {} } }
    eq(h3, nil, 'a non-string argument is refused')
    check(type(e3) == 'string' and e3:find('cmd%[3%]'), '   naming the index', e3)
    local h4, e4 = process.spawn{ cmd = { LUAJIT, 'a\0b' } }
    eq(h4, nil, 'a NUL byte in an argument is refused')
    check(type(e4) == 'string', '   with a message', e4)
end

--=============================================================================
head('S13 10 concurrent children')
local S13pids = {}
do
    local N = 10
    local hs, lines, codes = {}, {}, {}
    for id = 1, N do
        lines[id] = 0
        local h, err = process.spawn{
            cmd = { LUAJIT, '-e', C_WORKER },
            env = { LCP_ID = tostring(id) },
            onLine = function(l, s)
                if s == 'stdout' then
                    local who, i = l:match('^(%d+):(%d+)$')
                    if tonumber(who) == id then
                        lines[id] = lines[id] + 1
                        if tonumber(i) ~= lines[id] then lines[id] = -1 end
                    else
                        lines[id] = -2       -- cross-talk between pipes
                    end
                end
            end,
            onExit = function(code) codes[id] = code end,
        }
        if not h then check(false, 'spawn #' .. id, err) end
        hs[id] = h
        if h then S13pids[#S13pids + 1] = h:pid() end
    end
    eq(#S13pids, N, 'all 10 children started')
    eq(process.count(), N, 'the live registry holds 10 handles')

    local ok = pumpUntil(function()
        for i = 1, N do if hs[i] and hs[i]:isRunning() then return false end end
        return true
    end, 40000)
    check(ok, 'all 10 exited within the timeout')

    local allLines, allCodes = true, true
    for i = 1, N do
        if lines[i] ~= 200 then allLines = false; note(('child %d: %s lines'):format(i, lines[i])) end
        if codes[i] ~= i then allCodes = false; note(('child %d: code %s'):format(i, tostring(codes[i]))) end
    end
    check(allLines, 'each child delivered its own 200 lines, in order, on its own pipe')
    check(allCodes, 'each child reported its own exit code')
    eq(process.count(), 0, 'the registry drained')
end

--=============================================================================
head('S14 driven from lib/sched.lua: the reactor never stalls')
do
    local sched = require('lib.sched')
    sched.reset()

    local N, PER = 6, 3000              -- ~1.7 MB of stdout across 6 pipes
    local done, lines = 0, 0
    for id = 1, N do
        local h = process.spawn{
            cmd = { LUAJIT, '-e', C_FLOOD },
            env = { LCP_N = tostring(PER) },
            onLine = function(_, s) if s == 'stdout' then lines = lines + 1 end end,
            onExit = function() done = done + 1 end,
        }
        if not h then check(false, 'spawn under sched #' .. id) end
    end

    local last, maxGap, ticks, busyTicks, busyGap = sys.nowMs(), 0, 0, 0, 0
    sched.every(10, process.pollAll)
    sched.every(5, function()
        local now = sys.nowMs()
        local gap = now - last
        if gap > maxGap then maxGap = gap end
        last = now
        ticks = ticks + 1
        if done < N then
            busyTicks = busyTicks + 1
            if gap > busyGap then busyGap = gap end
        end
        -- keep the loop turning past the last child so the tick count itself
        -- proves the reactor stayed alive rather than the test ending early
        if done >= N and ticks >= 40 then sched.stop() end
    end)
    sched.after(60000, function() sched.stop() end)
    last = sys.nowMs()
    sched.run()

    eq(done, N, 'every child was reaped by the sched-driven pollAll')
    eq(lines, N * PER, 'and every one of the ' .. (N * PER) .. ' lines arrived')
    check(ticks >= 40, 'the 5 ms timer kept firing throughout', ticks)
    check(busyTicks >= 3, 'the loop ticked repeatedly WHILE the children were flooding',
          busyTicks)
    note(('%d ticks total, %d of them while %d children flooded stdout'):format(ticks, busyTicks, N))
    note(('worst reactor gap: %.1f ms overall, %.1f ms while busy'):format(maxGap, busyGap))
    check(maxGap < 250, 'no poll ever stalled the loop (a blocking spawn would show seconds)',
          ('%.1f ms'):format(maxGap))
    sched.reset()
end

--=============================================================================
head('S15 reapAll(): the leak-prevention path the exit hook uses')
do
    local pids, ready = {}, 0
    for i = 1, 3 do
        local h = process.spawn{
            cmd = { LUAJIT, '-e', C_STUBBORN },
            onLine = function(l) if l == 'ready' then ready = ready + 1 end end,
        }
        if h then pids[#pids + 1] = h:pid() end
    end
    eq(#pids, 3, 'three stubborn children are running')
    pumpUntil(function() return ready >= 3 end, 20000)
    eq(ready, 3, 'all three reported ready')
    for _, p in ipairs(pids) do
        check(process.isPidAlive(p), 'pid ' .. p .. ' is alive before reapAll()')
    end

    local t0 = sys.nowMs()
    local n = process.reapAll(300)
    local dt = sys.nowMs() - t0
    eq(n, 3, 'reapAll() reports the three it had to deal with')
    eq(process.count(), 0, 'the registry is empty afterwards')
    check(dt < 6000, ('and it finished promptly (%.0f ms)'):format(dt))
    local anyAlive = false
    for _, p in ipairs(pids) do
        if process.isPidAlive(p) then anyAlive = true; note('still alive: ' .. p) end
    end
    check(not anyAlive, 'none of the three survived -- the exit hook cannot leak a worker')
end

--=============================================================================
head('S16 a grandchild dies with its parent')
do
    local out = {}
    local h, err = process.spawn{
        cmd = { LUAJIT, '-e', C_HUB },
        env = { LCP_ROOT = ROOT, LCP_LJ = LUAJIT, LCP_CHUNK = C_SLEEPER },
        onLine = function(l, s) out[#out + 1] = s .. '|' .. l end,
    }
    check(h ~= nil, 'the miniature hub started', err)
    if h then
        pumpUntil(function()
            for _, l in ipairs(out) do if l:find('grandchild=') then return true end end
            return false
        end, 25000)
        local gpid
        for _, l in ipairs(out) do gpid = tonumber(l:match('grandchild=(%d+)')) or gpid end
        if not check(gpid ~= nil, 'it reported its grandchild pid',
                     table.concat(out, ' / ')) then
            h:kill(); pumpUntil(function() return not h:isRunning() end, 10000)
        else
            note('hub pid ' .. h:pid() .. ', grandchild pid ' .. gpid)
            check(process.isPidAlive(gpid), 'the grandchild is running')
            h:kill()                       -- hard kill: no cleanup code can run
            pumpUntil(function() return not h:isRunning() end, 15000)
            check(not h:isRunning(), 'the hub process is gone')
            -- give the kernel a moment to act on the job / PDEATHSIG
            local gone = false
            local deadline = sys.nowMs() + 8000
            while sys.nowMs() < deadline do
                if not process.isPidAlive(gpid) then gone = true; break end
                sys.sleepMs(20)
            end
            check(gone, process.isWindows
                  and 'the grandchild died with it (JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)'
                  or  'the grandchild died with it (prctl PR_SET_PDEATHSIG)')
            if not gone then
                note('LEAKED grandchild ' .. gpid .. ' -- killing it so the suite leaves nothing')
                if process.isLinux then os.execute('kill -9 ' .. gpid) end
            end
        end
    end
end

--=============================================================================
head('S17 pipe flags (Linux): parent ends non-blocking, CHILD ends blocking')
if process.isLinux then
    local bit = require('bit')
    local O_NONBLOCK = 0x800
    local function fdFlags(path)
        local f = io.open(path, 'rb')
        if not f then return nil end
        local s = f:read('*a'); f:close()
        return tonumber(s:match('flags:%s*(%d+)'), 8)
    end

    local out = {}
    local h = process.spawn{
        cmd = { LUAJIT, '-e', C_STUBBORN },
        onLine = function(l) out[#out + 1] = l end,
    }
    if check(h ~= nil, 'spawn succeeded') then
        pumpUntil(function() return out[1] == 'ready' end, 15000)
        for _, f in ipairs{ 'fdStdin', 'fdStdout', 'fdStderr' } do
            local fl = fdFlags('/proc/self/fdinfo/' .. h[f])
            check(fl and bit.band(fl, O_NONBLOCK) ~= 0,
                  ('the parent end %s is O_NONBLOCK'):format(f),
                  fl and ('flags=0%o'):format(fl))
        end
        -- The whole reason pipe2 is called with O_CLOEXEC and NOT O_NONBLOCK:
        -- O_NONBLOCK is a property of the open file description, and pipe2 sets
        -- it on both ends.  A non-blocking stdout in the child means EAGAIN and
        -- lost output as soon as the 64K pipe buffer fills (see S4).
        local base = '/proc/' .. h:pid() .. '/fdinfo/'
        for fd, name in pairs{ [0] = 'stdin', [1] = 'stdout', [2] = 'stderr' } do
            local fl = fdFlags(base .. fd)
            check(fl and bit.band(fl, O_NONBLOCK) == 0,
                  ("the CHILD's %s is still blocking"):format(name),
                  fl and ('flags=0%o'):format(fl) or 'no fdinfo')
        end
        h:kill()
        pumpUntil(function() return not h:isRunning() end, 15000)
    end
else
    note('Linux-only: Windows anonymous pipes carry no shared O_NONBLOCK flag')
    note('(the parent side uses PeekNamedPipe + SetNamedPipeHandleState(PIPE_NOWAIT))')
end

--=============================================================================
head('S18 no zombies, an empty registry, no globals')
do
    eq(process.count(), 0, 'no handle is still registered')
    eq(process.reapAll(200), 0, 'reapAll() has nothing left to do')

    if process.isLinux then
        local zombies, checked = {}, 0
        for _, pid in ipairs(S13pids) do
            local f = io.open('/proc/' .. pid .. '/stat', 'rb')
            if f then
                local s = f:read('*a'); f:close()
                checked = checked + 1
                local st = s:match('%)%s+(%a)')
                if st == 'Z' then zombies[#zombies + 1] = pid end
            end
        end
        check(#zombies == 0, ('no zombie remains (%d of %d pids still had a /proc entry)')
              :format(checked, #S13pids), table.concat(zombies, ','))
        note('checked /proc/<pid>/stat directly for each of the 10 S13 pids')
    else
        note('zombie check is a POSIX concern; Windows handles are closed by release()')
        check(process.jobActive(), 'the kill-on-close job object was created')
    end

    local created = {}
    setmetatable(_G, { __newindex = function(t, k, v)
        created[#created + 1] = tostring(k); rawset(t, k, v)
    end })
    package.loaded['lib.process'] = nil
    local fresh = require('lib.process')
    fresh.quoteWindowsArg('a b"c\\')
    fresh.encodeWindowsCommandLine{ 'x.exe', 'y z' }
    fresh._feedLines('', 'a\nb', 100, function() end)
    fresh._redactCmd({ 'a', '--password=b' }, { 'password' })
    fresh.pollAll()
    fresh.count()
    fresh.list()
    setmetatable(_G, nil)
    check(#created == 0, 'lib/process.lua touches no globals', table.concat(created, ', '))
end

--=============================================================================
io.write('\n================ process H3 ================\n')
for _, m in ipairs(msgs) do io.write(m, '\n') end
io.write(('  TOTAL: %d passed, %d failed -> %s\n'):format(pass, fail,
         fail == 0 and 'PASS' or 'FAIL'))
io.stdout:flush()
if _G.PROCESS_H3_NO_EXIT then return { pass = pass, fail = fail, failures = msgs } end
os.exit(fail == 0 and 0 or 1)
