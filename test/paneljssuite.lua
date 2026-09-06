-- test/paneljssuite.lua -- catch the class of panel bug that a Lua test suite
-- otherwise cannot see: a JavaScript syntax error.
--
-- Why this exists.  panel/app.js once shipped with `'... the hub's own user ...'`
-- -- an apostrophe inside a single-quoted string.  Every Lua suite passed, the
-- hub served the file with a 200, and the panel rendered a BLANK PAGE in a real
-- browser.  Nothing in the repository could see it, because nothing in the
-- repository parses JavaScript.
--
-- This is not a JavaScript parser and does not pretend to be one.  It is a
-- lexer: it walks the file tracking whether it is in code, a line comment, a
-- block comment, a single-quoted string, a double-quoted string, a template
-- literal or a regex literal, and it reports
--   * a string literal that is still open at end of line (the bug above),
--   * an unterminated block comment or template literal,
--   * unbalanced (), [] or {} in code.
-- Those three cover the mistakes a hand-edited panel actually makes.  Anything
-- deeper (ASI hazards, undeclared identifiers) needs a real engine; when node
-- is present the suite additionally shells out to `node --check`, which is a
-- complete answer, and says so in its output.
--
-- Regex-vs-division is the one genuinely ambiguous case in JavaScript lexing.
-- We resolve it the way every simple lexer does: a `/` starts a regex only when
-- the previous significant character cannot end an expression.  A false call
-- there could only produce a spurious failure, never a missed one, so the suite
-- prints which files it treated as containing regex literals.

local ROOT = (arg and arg[0] or ''):match('^(.*)[/\\][^/\\]*$') or '.'
package.path = ROOT .. '/../?.lua;' .. ROOT .. '/?.lua;' .. package.path

local ok, harness = pcall(require, 'test.harness')
local suite, check, report
if ok and harness and harness.suite then
    suite, check, report = harness.suite, harness.check, harness.report
else
    -- standalone fallback so the file runs on its own too
    local cur, pass, fail = nil, 0, 0
    local lines = {}
    _panelFailures = {}
    suite = function(name) cur = name; lines[#lines + 1] = { name = name, pass = 0, fail = 0 } end
    check = function(cond, what, detail)
        local e = lines[#lines]
        if cond then pass = pass + 1; e.pass = e.pass + 1; _panelPass = pass
        else fail = fail + 1; e.fail = e.fail + 1
            local msg = string.format('%s%s', what, detail and ('  -- ' .. tostring(detail)) or '')
            _panelFailures[#_panelFailures + 1] = 'panel JS: ' .. msg
            io.write(string.format('    FAIL  %s\n', msg))
        end
    end
    report = function()
        io.write('\n============== paneljssuite ==============\n')
        for _, e in ipairs(lines) do
            io.write(string.format('  %-46s %s  %d passed%s\n', e.name,
                e.fail == 0 and 'PASS' or 'FAIL', e.pass,
                e.fail > 0 and (', ' .. e.fail .. ' FAILED') or ''))
        end
        io.write(string.format('  TOTAL: %d passed, %d failed  -> %s\n',
            pass, fail, fail == 0 and 'PASS' or 'FAIL'))
        return fail
    end
end

local function readFile(path)
    local f = io.open(path, 'rb'); if not f then return nil end
    local s = f:read('*a'); f:close(); return s
end

-- arg[0] is test/paneljssuite.lua when this file is run directly, but main.lua
-- when test/selftest.lua dofile()s us, so ROOT lands one level apart in the two
-- cases.  Probe instead of assuming.
local PANEL
for _, cand in ipairs({ ROOT .. '/../panel', ROOT .. '/panel', './panel', '../panel' }) do
    if readFile(cand .. '/app.js') then PANEL = cand; break end
end
PANEL = PANEL or (ROOT .. '/../panel')

local function listJs(dir)
    local out = {}
    -- no directory primitive here; the panel's file set is small and known.
    for _, rel in ipairs({ 'app.js', 'api.js', 'rpc.js', 'mock/api.js' }) do
        local p = dir .. '/' .. rel
        if readFile(p) then out[#out + 1] = { rel = rel, path = p } end
    end
    return out
end

-- Returns nil on success, or (lineNumber, message) on the first problem found.
local function lint(src)
    local i, n, line = 1, #src, 1
    local depth = { ['('] = 0, ['['] = 0, ['{'] = 0 }
    local closes = { [')'] = '(', [']'] = '[', ['}'] = '{' }
    local prevSig = nil          -- previous significant character, for regex detection
    local sawRegex = false
    local byte, sub = string.byte, string.sub

    while i <= n do
        local c = sub(src, i, i)

        if c == '\n' then
            line = line + 1; i = i + 1

        elseif c == '/' and sub(src, i + 1, i + 1) == '/' then
            local nl = src:find('\n', i, true) or (n + 1)
            i = nl

        elseif c == '/' and sub(src, i + 1, i + 1) == '*' then
            local close = src:find('*/', i + 2, true)
            if not close then return line, 'unterminated block comment' end
            for _ in sub(src, i, close):gmatch('\n') do line = line + 1 end
            i = close + 2

        elseif c == '"' or c == "'" then
            local startLine, q = line, c
            local j = i + 1
            while true do
                if j > n then return startLine, 'unterminated ' .. q .. ' string' end
                local d = sub(src, j, j)
                if d == '\\' then j = j + 2
                elseif d == '\n' then
                    return startLine, 'string opened with ' .. q ..
                        ' is still open at end of line (an unescaped ' .. q .. ' inside it?)'
                elseif d == q then j = j + 1; break
                else j = j + 1 end
            end
            i = j; prevSig = q

        elseif c == '`' then
            local startLine = line
            local j = i + 1
            while true do
                if j > n then return startLine, 'unterminated template literal' end
                local d = sub(src, j, j)
                if d == '\\' then j = j + 2
                elseif d == '\n' then line = line + 1; j = j + 1
                elseif d == '`' then j = j + 1; break
                else j = j + 1 end
            end
            i = j; prevSig = '`'

        elseif c == '/' and (prevSig == nil or not prevSig:match('[%w_%)%]%}%\'"`%$]')) then
            -- regex literal
            local startLine = line
            local j, inClass = i + 1, false
            while true do
                if j > n then return startLine, 'unterminated regex literal' end
                local d = sub(src, j, j)
                if d == '\\' then j = j + 2
                elseif d == '\n' then return startLine, 'unterminated regex literal'
                elseif d == '[' then inClass = true; j = j + 1
                elseif d == ']' then inClass = false; j = j + 1
                elseif d == '/' and not inClass then j = j + 1; break
                else j = j + 1 end
            end
            while sub(src, j, j):match('[dgimsuvy]') do j = j + 1 end
            i = j; prevSig = '/'; sawRegex = true

        else
            if depth[c] then depth[c] = depth[c] + 1
            elseif closes[c] then
                local open = closes[c]
                depth[open] = depth[open] - 1
                if depth[open] < 0 then
                    return line, "unbalanced '" .. c .. "' with no matching '" .. open .. "'"
                end
            end
            if c:match('%S') then prevSig = c end
            i = i + 1
        end
    end

    for open, d in pairs(depth) do
        if d ~= 0 then
            return nil, string.format("%d unclosed '%s'", d, open)
        end
    end
    return nil, nil, sawRegex
end

-- ---------------------------------------------------------------------------
suite('panel JavaScript parses')

local files = listJs(PANEL)
check(#files >= 3, 'the panel ships its JavaScript', #files .. ' file(s) found')

for _, f in ipairs(files) do
    local src = readFile(f.path)
    local badLine, msg, sawRegex = lint(src)
    check(msg == nil, f.rel .. ' has no lexical error',
        msg and (msg .. (badLine and (' at line ' .. badLine) or '')) or nil)
    if msg == nil then
        io.write(string.format('    %-14s %6d bytes%s\n', f.rel, #src,
            sawRegex and '  (contains regex literals)' or ''))
    end
end

-- the exact bug that shipped, as a fixture: it must be caught
suite('the regression that motivated this suite')
local bad = "var s = 'the hub's own user';\n"
local l, m = lint(bad)
check(m ~= nil, 'an unescaped apostrophe in a single-quoted string is caught', m)
check(l == 1, 'and is reported on the right line', tostring(l))

local good = "var s = 'the hub\\'s own user';\nvar re = /ab['\"]c/g;\nvar t = `a ${x} b`;\n"
local _, m2 = lint(good)
check(m2 == nil, 'escaped quotes, regex literals and templates are accepted', m2)

-- a complete answer when node happens to exist
suite('node --check (when available)')
local haveNode = false
do
    local p = io.popen('node --version 2>&1')
    if p then
        local v = p:read('*l') or ''
        p:close()
        haveNode = v:match('^v%d') ~= nil
    end
end
if haveNode then
    for _, f in ipairs(files) do
        local p = io.popen('node --check "' .. f.path .. '" 2>&1')
        local out = p and p:read('*a') or ''
        local okc = p and p:close()
        check(okc and out == '', 'node --check ' .. f.rel, out ~= '' and out:sub(1, 200) or nil)
    end
else
    io.write('    node is not installed here; the lexer above is the only check.\n')
    io.write('    Install node to get a complete parse: apt-get install nodejs\n')
    check(true, 'skipped (node not present)')
end

-- test/selftest.lua embeds this suite the same way it embeds test/botsuite.lua:
-- it sets PANELJS_NO_EXIT, dofile()s us, and folds the returned counters in.
local failures = report()
if _G.PANELJS_NO_EXIT then
    return { pass = _panelPass or 0, fail = failures, failures = _panelFailures or {} }
end
os.exit(failures == 0 and 0 or 1)
