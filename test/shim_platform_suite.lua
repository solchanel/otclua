--[==[========================================================================
test/shim_platform_suite.lua -- work item S2: the platform globals and the corelib
surface.

    luajit test/shim_platform_suite.lua           (from D:/Claude/otclient_web/luaclient)
    wsl.exe -d Debian -e sh -c 'cd /mnt/d/Claude/otclient_web/luaclient && \
        luajit test/shim_platform_suite.lua'

Covers, with real assertions rather than smoke checks:

  A  shim/regex.lua        73 conformance rows covering EVERY distinct regexMatch
                           pattern in D:/.../profiles/bot/vBot_4.8 plus the nine in
                           mods/game_bot/panels and corelib/table.lua:293.  Every
                           expected row was produced by an INDEPENDENT ORACLE -- the
                           C++ regexMatch loop reimplemented on top of Python's `re`
                           over bytes, with '$' rewritten to \Z so Python's
                           "end-or-before-trailing-newline" does not diverge from
                           ECMAScript's "end only".  The generator lives in the session
                           scratchpad (cases.py); the rows below are frozen copies of
                           its output, so this suite has no Python dependency.
  B  corelib stdlib        every string/table/math extension against its otclient
                           behaviour, including the empty-string drop in split.
  C  corelib signals       connect / disconnect / signalcall, INCLUDING the rule that
                           a slot returning true stops the later slots.
  D  corelib events        scheduleEvent / cycleEvent / removeEvent / addEvent timing,
                           driven by a FAKE CLOCK so the assertions are exact.
  E  shim/platform         frame-quantised g_clock, print's four-space join, tr,
                           retranslateKeyComboDesc, g_crypt, and the recording stubs.
  F  shim/resources        '//' collapse, chunk-relative resolution, SORTED listing,
                           readFileContents RAISING on a miss, getWriteDir's trailing
                           '/', a real write/read/delete cycle in a temp dir, and the
                           sandbox refusing every traversal shape.
  G  shim/settings         round-trip, persistence across a reopen, profile == 1,
                           Config:get's write-the-default side effect, getBoolean.
  H  the user's REAL data  decodeStringPairList over all 18 cavebot .cfg files with a
                           byte-exact encode round trip, and a targetbot .json read.
                           SKIPPED WITH A PRINTED REASON when the otclient tree is not
                           present, so the suite still passes on Debian.

Nothing here touches the network, and nothing WRITES anywhere under
D:/Claude/otclient_mehah1530 -- the profile is opened read-only and every mutating
test runs in <luaclient>/.shimtmp, which is removed at the end.

Set `_G.SHIMPLATFORM_NO_EXIT = true` before dofile()ing this file and it returns
{ pass=, fail=, failures={} } instead of exiting.
==========================================================================]==]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. ROOT .. '/?/init.lua;' .. package.path
end

-- The user's REAL vBot profile -- resolved relative to this checkout first so the
-- identical file runs on Windows and under WSL.  READ ONLY.
local PROFILE_ROOT, PROFILE
do
    local candidates = {
        ROOT .. '/../../otclient_mehah1530/otclient/profiles',
        'D:/Claude/otclient_mehah1530/otclient/profiles',
        '/mnt/d/Claude/otclient_mehah1530/otclient/profiles',
    }
    for _, c in ipairs(candidates) do
        local f = io.open(c .. '/bot/vBot_4.8/_Loader.lua', 'r')
        if f then f:close(); PROFILE_ROOT = c; PROFILE = c .. '/bot/vBot_4.8'; break end
    end
end

-- ========================================================== tiny framework
local pass, fail, msgs = 0, 0, {}
local curSection = ''

local function section(name)
    curSection = name
    io.write('\n-- ', name, '\n')
end

local function check(ok, desc, detail)
    if ok then
        pass = pass + 1
    else
        fail = fail + 1
        local line = ('   FAIL [%s] %s%s'):format(curSection, desc,
                      detail and ('  -- ' .. tostring(detail)) or '')
        msgs[#msgs + 1] = line
        io.write(line, '\n')
    end
    return ok
end

local function eq(got, want, desc)
    if got == want then return check(true, desc) end
    local g, w = tostring(got), tostring(want)
    if #g > 100 then g = g:sub(1, 97) .. '...' end
    if #w > 100 then w = w:sub(1, 97) .. '...' end
    return check(false, desc, ('got %s, want %s'):format(g, w))
end

local function raises(fn, needle, desc)
    local ok, err = pcall(fn)
    if ok then return check(false, desc, 'no error was raised') end
    err = tostring(err)
    if needle and not err:find(needle, 1, true) then
        return check(false, desc, ('error %q does not contain %q'):format(err, needle))
    end
    return check(true, desc)
end

local function skip(desc, why)
    io.write(('   SKIP %s  -- %s\n'):format(desc, why))
end

-- ============================================================ modules under test
local regex    = require('shim.regex')
local corelib  = require('shim.corelib')
local platform = require('shim.platform')
local resources = require('shim.resources')
local settings = require('shim.settings')
local sys      = require('lib.sys')

--==============================================================================
-- A. shim/regex.lua
--==============================================================================
section('A. regexMatch (shim/regex.lua)')

-- Each row: { name, pattern, subject, expected }
-- expected is either an array of rows, or {rows=N, first=, last=} for the
-- long results (the C++ empty-match spin), or {invalid=true}.
local REGEX_CASES = {
    { "cavebot goto 3+opt", "\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+),?\\s*([0-9]?)", "32359,32226,7",
      { {"32359,32226,7", "32359", "32226", "7", ""} } },
    { "cavebot goto 3+opt", "\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+),?\\s*([0-9]?)", "32413,32171,7,0",
      { {"32413,32171,7,0", "32413", "32171", "7", "0"} } },
    { "cavebot goto 3+opt", "\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+),?\\s*([0-9]?)", " 100 , 200 , 8 , 1",
      { {" 100 , 200 , 8 ", "100", "200", "8", ""} } },
    { "cavebot goto 3+opt", "\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+),?\\s*([0-9]?)", "nope",
      {  } },
    { "cavebot pos3", "\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)", "32359,32226,7",
      { {"32359,32226,7", "32359", "32226", "7"} } },
    { "cavebot pos3", "\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)", "32413,32171,7,0",
      { {"32413,32171,7", "32413", "32171", "7"} } },
    { "cavebot pos3", "\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)", "x",
      {  } },
    { "cavebot pos4", "\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)", "32413,32171,7,0",
      { {"32413,32171,7,0", "32413", "32171", "7", "0"} } },
    { "cavebot pos4", "\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)", "32359,32226,7",
      {  } },
    { "antilost pos4 nolead", "([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)", "goto 32413, 32171, 7, 0",
      { {"32413, 32171, 7, 0", "32413", "32171", "7", "0"} } },
    { "antilost pos3 nolead", "([0-9]+)\\s*,\\s*([0-9]+)\\s*,\\s*([0-9]+)", "goto 32413, 32171, 7",
      { {"32413, 32171, 7", "32413", "32171", "7"} } },
    { "cavebot goto: prefix", "(?:goto:)([^,]+),([^,]+),([^,]+)", "goto:32359,32226,7",
      { {"goto:32359,32226,7", "32359", "32226", "7"} } },
    { "cavebot goto: prefix", "(?:goto:)([^,]+),([^,]+),([^,]+)", "label:start",
      {  } },
    { "cavebot goto: prefix", "(?:goto:)([^,]+),([^,]+),([^,]+)", "goto:1,2,3 goto:4,5,6",
      { {"goto:1,2,3 goto:4", "1", "2", "3 goto:4"} } },
    { "tasker loot regex", "Loot of ([a-z])* ([a-z A-Z]*):", "Loot of a cave rat: nothing",
      { {"Loot of a cave rat:", "a", "cave rat"} } },
    { "tasker loot regex", "Loot of ([a-z])* ([a-z A-Z]*):", "Loot of the Dragon Lord: a gold coin",
      { {"Loot of the Dragon Lord:", "e", "Dragon Lord"} } },
    { "tasker loot regex2", "Loot of ([a-z A-Z]*):", "Loot of a cave rat: nothing",
      { {"Loot of a cave rat:", "a cave rat"} } },
    { "targetbot name glob", "^cave rat.*$|^dragon.?$", "cave rat",
      { {"cave rat"} } },
    { "targetbot name glob", "^cave rat.*$|^dragon.?$", "cave rats",
      { {"cave rats"} } },
    { "targetbot name glob", "^cave rat.*$|^dragon.?$", "dragon",
      { {"dragon"} } },
    { "targetbot name glob", "^cave rat.*$|^dragon.?$", "dragons",
      { {"dragons"} } },
    { "targetbot name glob", "^cave rat.*$|^dragon.?$", "dragon lord",
      {  } },
    { "targetbot name glob", "^cave rat.*$|^dragon.?$", "rat",
      {  } },
    { "analyzer bossRegex", "You (?:can|may) challenge ([\\w\\W]*) again in ([\\d]*)", "You can challenge Ferumbras again in 1234 seconds",
      { {"You can challenge Ferumbras again in 1234", "Ferumbras", "1234"} } },
    { "analyzer bossRegex", "You (?:can|may) challenge ([\\w\\W]*) again in ([\\d]*)", "You may challenge The Snapper again in 60",
      { {"You may challenge The Snapper again in 60", "The Snapper", "60"} } },
    { "analyzer loot split", " ([^,|^.]+)", "Loot of a rat: a gold coin, 3 worms, a knife.",
      { {" of a rat: a gold coin", "of a rat: a gold coin"}, {" 3 worms", "3 worms"}, {" a knife", "a knife"} } },
    { "analyzer nameRegex", "Loot of (?:an |a |the |)([^:]+)", "Loot of an orc: nothing",
      { {"Loot of an orc", "orc"} } },
    { "analyzer nameRegex", "Loot of (?:an |a |the |)([^:]+)", "Loot of a rat: nothing",
      { {"Loot of a rat", "rat"} } },
    { "analyzer nameRegex", "Loot of (?:an |a |the |)([^:]+)", "Loot of the Old Widow: nothing",
      { {"Loot of the Old Widow", "Old Widow"} } },
    { "analyzer nameRegex", "Loot of (?:an |a |the |)([^:]+)", "Loot of Ferumbras: nothing",
      { {"Loot of Ferumbras", "Ferumbras"} } },
    { "analyzer paren head", "(^[^(]+)", "a gold coin (100)",
      { {"a gold coin ", "a gold coin "} } },
    { "analyzer paren head", "(^[^(]+)", "(only parens)",
      {  } },
    { "analyzer dmg regex", "You lose ([0-9]*) hitpoints due to an attack by ([a-z]*) ([a-z A-z-]*)", "You lose 120 hitpoints due to an attack by a cave rat",
      { {"You lose 120 hitpoints due to an attack by a cave rat", "120", "a", "cave rat"} } },
    { "analyzer dmg regex", "You lose ([0-9]*) hitpoints due to an attack by ([a-z]*) ([a-z A-z-]*)", "You lose 5 hitpoints due to an attack by an orc-berserker",
      { {"You lose 5 hitpoints due to an attack by an orc-berserker", "5", "an", "orc-berserker"} } },
    -- no match: "s..." needs THREE characters after the 's' and only ". " follow
    { "analyzer regex3", "\\d ([a-z A-Z]*)s...", "You see 4 gold coins. ",
      {  } },
    { "analyzer regex3", "\\d ([a-z A-Z]*)s...", "3 worms...",
      { {"3 worms...", "worm"} } },
    { "attackbot cat noparen", "^[^\\(]+", "Fire Wave (Exevo Flam Hur)",
      { {"Fire Wave "} } },
    { "attackbot cat noR", "^[^R]+", "Attack Rune Group",
      { {"Attack "} } },
    { "attackbot first word", "^[^ ]+", "exori vis",
      { {"exori"} } },
    { "attackbot first word", "^[^ ]+", " leading",
      {  } },
    { "botserver quoted", "\"(.*?)\"", "{\"a\":\"b\",\"c\":\"d\"}",
      { {"\"a\"", "a"}, {"\"b\"", "b"}, {"\"c\"", "c"}, {"\"d\"", "d"} } },
    { "botserver quoted", "\"(.*?)\"", "no quotes",
      {  } },
    { "botserver names", "\"([a-z 'A-z-]*)\"*", "[\"Bob\",\"Alice OHara\"]",
      { {"\"Bob\"", "Bob"}, {"\"Alice OHara\"", "Alice OHara"} } },
    { "combo first word", "[a-zA-Z]*", "Torkild invited you to party",
      { rows = 10000, first = {"Torkild"}, last = {""} } },
    { "combo first word", "[a-zA-Z]*", " leading space",
      { rows = 10000, first = {""}, last = {""} } },
    { "extras look", "You see ([^\\(]*) \\(Level ([0-9]*)\\)((?:.)* of the ([\\w ]*),|)", "You see Bob (Level 300). He is a sorcerer of the Black Knights, a member.",
      { {"You see Bob (Level 300). He is a sorcerer of the Black Knights,", "Bob", "300", ". He is a sorcerer of the Black Knights,", "Black Knights"} } },
    { "extras look", "You see ([^\\(]*) \\(Level ([0-9]*)\\)((?:.)* of the ([\\w ]*),|)", "You see Bob (Level 300). He is a sorcerer.",
      { {"You see Bob (Level 300)", "Bob", "300", "", ""} } },
    { "decodeStringPairList", "(?:^|\\n)([^:^\n]{1,20}):?(.*)(?:$|\\n)", "goto:32359,32226,7\nlabel:start\n",
      { {"goto:32359,32226,7\n", "goto", "32359,32226,7"}, {"label:start\n", "label", "start"} } },
    { "decodeStringPairList", "(?:^|\\n)([^:^\n]{1,20}):?(.*)(?:$|\\n)", "a:1\nb:2\n",
      { {"a:1\n", "a", "1"}, {"b:2\n", "b", "2"} } },
    { "decodeStringPairList", "(?:^|\\n)([^:^\n]{1,20}):?(.*)(?:$|\\n)", "function:[[\nreturn true\n]]\n",
      { {"function:[[\n", "function", "[["}, {"return true\n", "return true", ""}, {"]]\n", "]]", ""} } },
    { "decodeStringPairList", "(?:^|\\n)([^:^\n]{1,20}):?(.*)(?:$|\\n)", "goto:1,2,3",
      { {"goto:1,2,3", "goto", "1,2,3"} } },
    { "gamebot name:", "name:\\s*([^\n]*)$", "stuff\nname:  Rat  ",
      { {"name:  Rat  ", "Rat  "} } },
    { "gamebot name:", "name:\\s*([^\n]*)$", "name: Rat",
      { {"name: Rat", "Rat"} } },
    { "gamebot kv", "([^:^\n]+)(:?)([^\n]*)", "name:Rat\nmin:10\n",
      { {"name:Rat", "name", ":", "Rat"}, {"min:10", "min", ":", "10"} } },
    { "gamebot kv nospace", "([^:^\n^\\s]+)(:?)([^\n]*)", "name:Rat\n min:10\n",
      { {"name:Rat", "name", ":", "Rat"}, {"min:10", "min", ":", "10"} } },
    { "gamebot 3 numbers", "([0-9]+)[^0-9]+([0-9]+)[^0-9]+([0-9]+)", "32359, 32226, 7",
      { {"32359, 32226, 7", "32359", "32226", "7"} } },
    { "gamebot 4 numbers", "([0-9]+)[^0-9]+([0-9]+)[^0-9]+([0-9]+)[^0-9]+([0-9]+)", "32359, 32226, 7, 0",
      { {"32359, 32226, 7, 0", "32359", "32226", "7", "0"} } },
    { "anchors both", "^abc$", "abc",
      { {"abc"} } },
    { "anchors both", "^abc$", "abcd",
      {  } },
    { "anchors both", "^abc$", "xabc",
      {  } },
    { "word boundary", "\\bcat\\b", "a cat here",
      { {"cat"} } },
    { "word boundary", "\\bcat\\b", "concatenate",
      {  } },
    { "brace exact", "^a{3}$", "aaa",
      { {"aaa"} } },
    { "brace exact", "^a{3}$", "aa",
      {  } },
    { "brace open", "a{2,}", "aaaa",
      { {"aaaa"} } },
    { "lazy plus", "<(.+?)>", "<a><b>",
      { {"<a>", "a"}, {"<b>", "b"} } },
    { "alt empty branch", "(x|)y", "xy",
      { {"xy", "x"} } },
    { "alt empty branch", "(x|)y", "y",
      { {"y", ""} } },
    { "nested group", "((a)(b))+", "abab",
      { {"abab", "ab", "a", "b"} } },
    { "class dash ends", "[a-z-]+", "ab-cd",
      { {"ab-cd"} } },
    { "negated class", "[^0-9]+", "ab12cd",
      { {"ab"}, {"cd"} } },
    { "escaped dot", "a\\.b", "a.b",
      { {"a.b"} } },
    { "escaped dot", "a\\.b", "axb",
      {  } },
}

local function rowsEqual(got, want)
    if #got ~= #want then return false, ('row count %d vs %d'):format(#got, #want) end
    for i = 1, #want do
        if #got[i] ~= #want[i] then
            return false, ('row %d width %d vs %d'):format(i, #got[i], #want[i])
        end
        for j = 1, #want[i] do
            if got[i][j] ~= want[i][j] then
                return false, ('row %d col %d: %q vs %q'):format(i, j, got[i][j], want[i][j])
            end
        end
    end
    return true
end

local distinctPatterns = {}
for _, c in ipairs(REGEX_CASES) do distinctPatterns[c[2]] = true end
do
    local n = 0
    for _ in pairs(distinctPatterns) do n = n + 1 end
    check(n >= 35, ('%d distinct patterns under test'):format(n))
end

for _, c in ipairs(REGEX_CASES) do
    local name, pat, subj, want = c[1], c[2], c[3], c[4]
    local desc = ('%s  %q on %q'):format(name, pat, subj)
    local got = regex.match(subj, pat)
    if want.rows then
        -- long result: assert the count and the first/last row
        local ok = (#got == want.rows)
        local why = ok and nil or ('%d rows, want %d'):format(#got, want.rows)
        if ok then
            local a = rowsEqual({ got[1] }, { want.first })
            local b = rowsEqual({ got[#got] }, { want.last })
            ok = a and b
            if not ok then why = 'first/last row mismatch' end
        end
        check(ok, desc, why)
    else
        local ok, why = rowsEqual(got, want)
        check(ok, desc, why)
    end
end

-- contract edges -------------------------------------------------------------
eq(#regex.match('', 'x'), 0, 'empty subject -> {} (C++ checks s.empty() first)')
eq(#regex.match('x', ''), 0, 'empty pattern -> {}')
eq(#regex.match('abc', 'a'), 1, 'a pattern with no groups yields a one-column row')
eq(regex.match('abc', 'a')[1][1], 'a', 'the whole match is column 1')

do
    -- an invalid / unsupported pattern returns {} like the C++ catch(...) but is LOUD
    local seen = {}
    local old = regex.onUnsupported
    regex.onUnsupported = function(p, why) seen[#seen + 1] = { p, why } end
    regex.failures['(?=x)'] = nil
    regex.failures['(unclosed'] = nil
    regex.clearCache()

    eq(#regex.match('x', '(?=x)'), 0, 'unsupported lookahead -> {}')
    eq(#seen, 1, 'unsupported lookahead reported exactly once')
    check(seen[1] and seen[1][2]:find('lookahead', 1, true) ~= nil,
          'the report names lookahead', seen[1] and seen[1][2])
    eq(#regex.match('x', '(?=x)'), 0, 'a second call still returns {}')
    eq(#seen, 1, 'and does NOT report twice (once per distinct pattern)')

    eq(#regex.match('x', '(unclosed'), 0, 'unterminated group -> {}')
    eq(#seen, 2, 'unterminated group reported')

    regex.strict = true
    regex.clearCache()
    raises(function() regex.match('x', '(?=x)') end, 'not supported',
           'regex.strict = true makes an unsupported pattern RAISE')
    regex.strict = false
    regex.onUnsupported = old
    regex.clearCache()
end

eq(#regex.match('x', '\\1'), 0, 'backreference is refused (returns {})')
check(regex.failures['\\1'] ~= nil, 'and is recorded in regex.failures')

do
    -- POSIX bracket expressions.  std::regex accepts these INSIDE a character class even
    -- under the ECMAScript grammar ([re.grammar] extends ClassAtom with the class-name
    -- production).  The shim used to parse the alpha class as [[:alph plus a stray literal
    -- close-bracket and return {} with NO report at all -- and targetbot/creature.lua:62
    -- and vBot/combo.lua:232 feed USER-SUPPLIED regexes straight in, so a config that used
    -- one silently never matched.
    eq(#regex.match('A1b2', '[[:alpha:]]'), 2, 'POSIX [[:alpha:]] matches the two letters')
    eq(regex.match('A1b2', '[[:alpha:]]')[1][1], 'A', 'the first is A')
    eq(regex.match('A1b2', '[[:alpha:]]')[2][1], 'b', 'the second is b')
    eq(#regex.match('A1b2', '[[:digit:]]'), 2, '[[:digit:]] matches the two digits')
    eq(regex.match('ab12', '[[:alnum:]]+')[1][1], 'ab12', '[[:alnum:]]+ spans both')
    eq(regex.match('Deer', '^[[:upper:]][[:lower:]]+$')[1][1], 'Deer',
       'upper/lower compose with anchors')
    eq(#regex.match('a b', '[[:space:]]'), 1, '[[:space:]]')
    eq(regex.match('a,b', '[[:punct:]]')[1][1], ',', '[[:punct:]]')
    eq(regex.match('0xFf', '[[:xdigit:]]+')[1][1], '0', '[[:xdigit:]]')
    eq(regex.match('a1', '[[:^alpha:]]')[1][1], '1', 'the negated [[:^name:]] form')
    eq(regex.match('a-b', '[[:alpha:]-]+')[1][1], 'a-b',
       'a POSIX class composes with ordinary class members')
    eq(regex.match('a[b', '[[]')[1][1], '[', 'a bare [ inside a class stays a literal')

    local seenP = {}
    local oldP = regex.onUnsupported
    regex.onUnsupported = function(pp, why) seenP[#seenP + 1] = { pp, why } end
    regex.failures['[[:bogus:]]'] = nil
    regex.failures['[:alpha:]'] = nil
    regex.clearCache()
    eq(#regex.match('x', '[[:bogus:]]'), 0, 'an UNKNOWN class name returns {}')
    check(seenP[1] and seenP[1][2]:find('POSIX', 1, true) ~= nil,
          'and reports loudly instead of mis-parsing', seenP[1] and seenP[1][2])
    eq(#regex.match('x', '[:alpha:]'), 0, 'a BARE [:alpha:] (one bracket) returns {}')
    check(seenP[2] and seenP[2][2]:find('POSIX', 1, true) ~= nil,
          'and says so -- it is not a POSIX class in any dialect', seenP[2] and seenP[2][2])
    regex.onUnsupported = oldP
    regex.clearCache()
end

raises(function() regex.match(nil, 'x') end, 'subject must be a string',
       'a nil subject raises rather than silently returning {}')
raises(function() regex.match('x', nil) end, 'pattern must be a string',
       'a nil pattern raises')
eq(regex.match(12345, '[0-9]+')[1][1], '12345', 'a number subject is stringified like the C++ cast')

do  -- the compiled-pattern cache is invisible except as speed
    local before = regex.stats.compiles
    regex.match('abc', 'zzz-unique-pattern-1')
    regex.match('abc', 'zzz-unique-pattern-1')
    eq(regex.stats.compiles, before + 1, 'a pattern is compiled once and cached')
end

--==============================================================================
-- B. corelib stdlib
--==============================================================================
section('B. corelib stdlib (shim/corelib.lua)')

local G = {}
platform.install(G, { os = 'windows', version = '3.0-shim' })
local ch = corelib.install(G, {})

-- string ---------------------------------------------------------------------
do
    local r = ('a,b,c'):split(',')
    eq(#r, 3, 'split: three fields'); eq(r[1], 'a', 'split[1]'); eq(r[3], 'c', 'split[3]')
end
do
    -- C1: table.removevalue drops ONE empty field.  cavebot/actions.lua:195-197
    -- relies on "goto:" producing a table whose [2] is nil.
    local r = ('goto:'):split(':')
    eq(#r, 1, 'split drops the single empty trailing field')
    eq(r[1], 'goto', 'split("goto:")[1] == "goto"')
    eq(r[2], nil, 'split("goto:")[2] == nil -- cavebot/actions.lua depends on this')
end
do
    local r = ('a,,b,,c'):split(',')
    eq(#r, 4, 'split drops exactly ONE empty field, not all of them')
    eq(table.concat(r, '|'), 'a|b||c', 'the second empty field survives')
end
eq((' \t x y \t '):trim(), 'x y', 'trim strips both ends and keeps inner space')
eq((''):trim(), '', 'trim("") == ""')
eq(('   '):trim(), '', 'trim on all-whitespace == "" (the %s*(.*%S) match fails)')
eq(('goto:1'):starts('goto'), true, 'starts true')
eq(('goto:1'):starts('walk'), false, 'starts false')
eq(('abc'):ends('bc'), true, 'ends true')
eq(('abc'):ends(''), true, 'ends("") is true by definition upstream')
eq(('Hello World'):contains('hello') ~= nil, true, 'contains is case-insensitive by default')
eq(('Hello World'):contains('hello', true), nil, 'contains(checkCase) respects case')
eq(string.empty(nil), true, 'string.empty(nil)')
eq(string.empty(''), true, 'string.empty("")')
eq(string.empty('x'), false, 'string.empty("x")')
eq(string.capitalize('rat'), 'Rat', 'capitalize')
eq(select(1, ('cAVE rAT'):titleCase()), 'Cave Rat', 'titleCase')
-- wrap assumes 10 px per character, so ANY word longer than width/10 opens a new
-- line -- including the very first one, which is why the result can begin with '\n'.
eq(('one two'):wrap(15), '\none \ntwo ', 'wrap: a 3-letter word already exceeds width 15')
eq(('one two'):wrap(100), 'one two ', 'wrap: with room, both words stay on one line')
eq(('aaa bbb'):wrap(61), 'aaa bbb ', 'wrap: exactly inside the limit, no break')
do
    local e = ('a; b ;c'):explode(';')
    eq(#e, 3, 'explode splits'); eq(e[2], 'b', 'explode TRIMS each field (unlike split)')
end

-- table ----------------------------------------------------------------------
eq(table.find({ 'a', 'b', 'c' }, 'b'), 2, 'table.find returns the key')
eq(table.find({ 'a' }, 'z'), nil, 'table.find miss is nil')
eq(table.find({ 'Rat' }, 'rat', true), 1, 'table.find lowercase mode')
eq(table.findbykey({ x = 7 }, 'X', true), 7, 'table.findbykey lowercase mode')
eq(table.contains({ 1, 2 }, 2), true, 'table.contains')
eq(table.haskey({ a = 1 }, 'a'), true, 'table.haskey')
do
    local t = { 'a', 'b', 'a' }
    eq(table.removevalue(t, 'a'), true, 'removevalue returns true')
    eq(#t, 2, 'removevalue removed exactly one'); eq(t[1], 'b', 'the first occurrence went')
    eq(table.removevalue(t, 'zzz'), false, 'removevalue miss is false')
end
eq(table.size({ a = 1, b = 2 }), 2, 'table.size counts hash keys')
eq(table.size({}), 0, 'table.size({}) == 0')
eq(table.empty({}), true, 'table.empty({})')
eq(table.empty({ 1 }), false, 'table.empty({1})')
eq(table.empty(nil), true, 'table.empty(nil) is true upstream')
do
    local a = { x = 1, y = { z = 2 } }
    local c = table.copy(a)
    eq(c.x, 1, 'table.copy copies'); check(c.y == a.y, 'table.copy is SHALLOW')
    local d = table.recursivecopy(a)
    check(d.y ~= a.y, 'table.recursivecopy is deep'); eq(d.y.z, 2, 'and copies the value')
end
eq(table.tostring({ 'a', 'b', 'c' }), ' a, b and c', 'table.tostring joins with , and "and"')
eq(table.isList({ 1, 2 }), true, 'isList on an array')
eq(table.isList({ a = 1 }), false, 'isList on a hash')
eq(table.isList({}), false, 'isList({}) is false -- size must be > 0')
eq(table.isStringList({ 'a', 'b' }), true, 'isStringList')
eq(table.isStringPairList({ { 'a', 'b' } }), true, 'isStringPairList')
eq(table.isStringPairList({ { 'a', 1 } }), false, 'isStringPairList rejects a non-string')
eq(table.isIn({ 'a' }, 'a'), true, 'table.isIn')
eq(table.equals({ a = 1 }, { a = 1, b = 2 }), true, 'table.equals is one-directional upstream')
eq(table.equal({ a = 1 }, { a = 1, b = 2 }), false, 'table.equal is symmetric')
eq(table.compare({ 1, 2 }, { 1, 2 }), true, 'table.compare')
do
    local t = { 1, 2, 3, 4 }
    table.remove_if(t, function(_, v) return v % 2 == 0 end)
    eq(t[1] .. ',' .. t[2], '1,3', 'table.remove_if keeps the odd values')
end
do
    local t = { 1, 2 }; table.insertall(t, { 3 }); eq(#t, 3, 'table.insertall')
end
eq(table.reserve(3, 0)[3], 0, 'table.reserve')
do local t = { a = 1 }; table.clear(t); eq(next(t), nil, 'table.clear') end
eq(table.findbyfield({ { id = 1 }, { id = 2 } }, 'id', 2).id, 2, 'table.findbyfield')
check(table.serialize == nil,
      'table.serialize is ABSENT -- it does not exist in otclient corelib and vBot never calls it')
check(table.popvalue == nil,
      'table.popvalue is ABSENT -- upstream is broken (iterates an undeclared global)')
check(string.pack_custom == nil, 'string.pack_custom is ABSENT (0 call sites)')

-- StringPairList round trip --------------------------------------------------
do  -- the flat form round-trips byte for byte
    local src = 'goto:1,2,3\nlabel:start\n'
    local pl = table.decodeStringPairList(src)
    eq(#pl, 2, 'decodeStringPairList: two pairs')
    eq(pl[1][1] .. '=' .. pl[1][2], 'goto=1,2,3', 'pair 1')
    eq(pl[2][1] .. '=' .. pl[2][2], 'label=start', 'pair 2')
    eq(table.encodeStringPairList(pl), src, 'encode(decode(src)) == src, byte for byte')
    eq(table.isStringPairList(pl), true, 'the decoded list IS a string pair list')
end
do  -- the multiline form.  Upstream accumulates each row's FULL MATCH, which still
    -- carries that row's trailing newline, so the body keeps it; the closing ']]' row
    -- contributes only what precedes the brackets.  Byte-exact round tripping of a
    -- multiline block therefore depends on the blank line the real editor writes --
    -- section H proves it holds for all 18 of the user's actual .cfg files.
    local src = 'function:[[\nreturn true\n]]\n'
    local pl = table.decodeStringPairList(src)
    eq(#pl, 1, 'decodeStringPairList: one multiline pair')
    eq(pl[1][1], 'function', 'the key comes from the row that opened the block')
    eq(pl[1][2], 'return true\n', 'the body keeps the trailing newline of its own row')
    eq(#table.decodeStringPairList('a:1\nfunction:[[\nx\ny\n]]\nb:2\n'), 3,
       'a multiline block does not swallow the pairs around it')
end
do
    -- prove decodeStringPairList really goes through regexMatch (table.lua:293)
    local calls = 0
    local real = corelib.regexMatch
    corelib.regexMatch = function(...) calls = calls + 1; return real(...) end
    table.decodeStringPairList('a:1\n')
    corelib.regexMatch = real
    eq(calls, 1, 'decodeStringPairList calls regexMatch exactly once')
end

-- math -----------------------------------------------------------------------
eq(math.round(1.4), 1, 'math.round down'); eq(math.round(1.5), 2, 'math.round up')
eq(math.round(-1.5), -2, 'math.round negative rounds away from zero')
eq(math.round(1.2345, 2), 1.23, 'math.round with decimals')
eq(math.isinteger(3), true, 'math.isinteger'); eq(math.isinteger(3.5), false, 'math.isinteger false')
eq(math.isu8(255), true, 'math.isu8(255)'); eq(math.isu8(256), false, 'math.isu8(256)')
eq(math.isu16(256), true, 'math.isu16 starts at 2^8 (upstream quirk)')
eq(math.isu16(255), false, 'math.isu16(255) is FALSE upstream -- the ranges are disjoint')
eq(G.roundToTwoDecimalPlaces(1.005), 1.0, 'roundToTwoDecimalPlaces (binary float, as upstream)')

-- uninstall restores the stdlib ----------------------------------------------
do
    local hadSplit = string.split ~= nil
    ch.uninstall()
    check(hadSplit and string.split == nil,
          'uninstall() puts _G.string back exactly as it was found')
    check(table.find == nil, 'uninstall() restores _G.table too')
    ch = corelib.install(G, {})            -- re-install for the rest of the suite
    check(string.split ~= nil and table.find ~= nil, 'install() is repeatable')
end

--==============================================================================
-- C. connect / disconnect / signalcall
--==============================================================================
section('C. signals (connect / disconnect / signalcall)')

do
    local obj = {}
    local hits = {}
    local a = function() hits[#hits + 1] = 'a' end
    local b = function() hits[#hits + 1] = 'b' end

    G.connect(obj, { onThing = a })
    eq(type(obj.onThing), 'function', 'the first slot is stored as a BARE function')
    G.connect(obj, { onThing = b })
    eq(type(obj.onThing), 'table', 'the second slot promotes the field to a list')
    eq(#obj.onThing, 2, 'the list holds both slots')
    eq(obj.onThing[1], a, 'append order: the first slot stays first')

    local c = function() hits[#hits + 1] = 'c' end
    G.connect(obj, { onThing = c }, true)
    eq(obj.onThing[1], c, 'pushFront inserts at index 1')

    G.signalcall(obj.onThing)
    eq(table.concat(hits, ''), 'cab', 'signalcall fires every slot in list order')

    G.disconnect(obj, { onThing = c })
    eq(#obj.onThing, 2, 'disconnect removes one slot')
    G.disconnect(obj, { onThing = b })
    eq(type(obj.onThing), 'function', 'a one-element list collapses back to a bare function')
    G.disconnect(obj, 'onThing')
    eq(obj.onThing, nil, 'disconnect(obj, name) with no slot clears the field')
end

do
    -- C2: THE STOP-ON-TRUE RULE (luainterface / util.lua:330-353).
    local order = {}
    local slots = {
        function() order[#order + 1] = 1; return false end,
        function() order[#order + 1] = 2; return true end,
        function() order[#order + 1] = 3; return false end,
    }
    local ret = G.signalcall(slots)
    eq(ret, true, 'signalcall returns true when a slot returns truthy')
    eq(table.concat(order, ','), '1,2', 'the slot AFTER the truthy one does NOT run')
end
do
    local order = {}
    local slots = {
        function() order[#order + 1] = 1 end,
        function() order[#order + 1] = 2 end,
    }
    eq(G.signalcall(slots), false, 'all-falsy slot list returns false')
    eq(table.concat(order, ','), '1,2', 'and every slot ran')
end
do
    -- a raising slot is reported and the rest still run
    local reported, ran = 0, 0
    local oldPerror = G.perror
    G.perror = function() reported = reported + 1 end
    local ok = G.signalcall({
        function() error('boom') end,
        function() ran = ran + 1; return false end,
    })
    G.perror = oldPerror
    eq(reported, 1, 'a raising slot goes through perror')
    eq(ran, 1, 'and the following slot still runs')
    eq(ok, false, 'the raise does not count as a truthy return')
end
do
    -- a BARE function slot passes its return value through unchanged (upstream
    -- asymmetry: a LIST collapses every truthy return to exactly `true`)
    eq(G.signalcall(function() return 'payload' end), 'payload',
       'a single function slot returns its own value')
    eq(G.signalcall({ function() return 'payload' end }), true,
       'a list collapses a truthy return to `true`')
end
eq(G.signalcall(nil), false, 'signalcall(nil) is false, never a crash')
raises(function() G.signalcall(42) end, 'non function value', 'signalcall on a number raises')
eq(G.connect(nil, { x = print }), nil, 'connect(nil, ...) is a silent no-op')
do
    -- C3 / B9, precisely.  Two separate mechanisms, and only one of them is
    -- userdata-only:
    --   (a) the metatable FORWARDER (util.lua:59-66) fires only for userdata, so a
    --       plain table never gets `function(...) return signalcall(mt[sig], ...) end`;
    --   (b) plain Lua __index INHERITANCE still makes `object[signal]` non-nil, so
    --       connect promotes the INHERITED slot into a list and appends the new one --
    --       which IS the bot.lua:591-594 double-dispatch, reproduced for free.
    local plain = {}
    G.connect(plain, { onX = function() end })
    eq(type(rawget(plain, 'onX')), 'function',
       '(a) a plain table with no inherited slot gets a bare function, not a forwarder')

    local hits = {}
    local Base = { onY = function() hits[#hits + 1] = 'base' end }
    local Derived = setmetatable({}, { __index = Base })
    G.connect(Derived, { onY = function() hits[#hits + 1] = 'derived' end })
    eq(type(rawget(Derived, 'onY')), 'table',
       '(b) an INHERITED slot is promoted into a list on the derived table')
    eq(#rawget(Derived, 'onY'), 2, 'holding both the inherited and the new slot')
    G.signalcall(Derived.onY)
    eq(table.concat(hits, ','), 'base,derived',
       'so BOTH fire -- the LocalPlayer/Creature double-dispatch of B9, reproduced')
end

--==============================================================================
-- D. the event scheduler globals, under a fake clock
--==============================================================================
section('D. scheduleEvent / cycleEvent / removeEvent (fake clock)')

local function fakeSched()
    local now, seq, timers = 0, 0, {}
    local S = {}
    function S.after(ms, fn)
        seq = seq + 1; timers[seq] = { at = now + (tonumber(ms) or 0), fn = fn, id = seq }
        return seq
    end
    function S.every(ms, fn)
        seq = seq + 1
        timers[seq] = { at = now + (tonumber(ms) or 0), every = tonumber(ms) or 0, fn = fn, id = seq }
        return seq
    end
    function S.cancel(id)
        if timers[id] then timers[id] = nil; return true end
        return false
    end
    function S.advance(ms)
        local target = now + ms
        while true do
            local best
            for _, t in pairs(timers) do
                if t.at <= target and (not best or t.at < best.at
                                       or (t.at == best.at and t.id < best.id)) then best = t end
            end
            if not best then break end
            now = best.at
            if best.every then
                best.at = best.at + (best.every > 0 and best.every or 1)
            else
                timers[best.id] = nil
            end
            best.fn()
        end
        now = target
    end
    function S.pending() local n = 0; for _ in pairs(timers) do n = n + 1 end; return n end
    return S
end

do
    local S = fakeSched()
    local E = corelib.makeEvents(S)
    local n = 0
    local ev = E.scheduleEvent(function() n = n + 1 end, 100)

    check(type(ev.cancel) == 'function', 'scheduleEvent returns a handle with :cancel()')
    eq(ev._callback ~= nil, true, 'the handle holds ._callback (globals.lua keeps the GC away)')
    S.advance(99); eq(n, 0, 'not fired at t=99')
    S.advance(1);  eq(n, 1, 'fired at t=100')
    S.advance(1000); eq(n, 1, 'a one-shot never fires again')
    eq(ev:isExecuted(), true, 'the handle reports isExecuted')
    eq(ev:isCanceled(), false, 'and not isCanceled')

    -- removeEvent must TOLERATE an already-fired handle
    local okRemove = pcall(E.removeEvent, ev)
    check(okRemove, 'removeEvent on an already-fired handle does not raise')
    eq(ev._callback, nil, 'removeEvent clears ._callback')
    check(pcall(E.removeEvent, nil), 'removeEvent(nil) is tolerated')
end

do
    local S = fakeSched()
    local E = corelib.makeEvents(S)
    local n = 0
    local ev = E.scheduleEvent(function() n = n + 1 end, 100)
    E.removeEvent(ev)
    S.advance(500)
    eq(n, 0, 'a cancelled one-shot never fires')
    eq(ev:isCanceled(), true, 'and reports isCanceled')
    eq(S.pending(), 0, 'and its timer was removed from the scheduler')
end

do
    local S = fakeSched()
    local E = corelib.makeEvents(S)
    local n = 0
    local ev = E.cycleEvent(function() n = n + 1 end, 50)
    S.advance(49);  eq(n, 0, 'cycleEvent has not fired at t=49')
    S.advance(1);   eq(n, 1, 'first cycle at t=50')
    S.advance(150); eq(n, 4, 'four cycles by t=200')
    E.removeEvent(ev)
    S.advance(500); eq(n, 4, 'removeEvent stops the cycle')
    eq(S.pending(), 0, 'and drops the repeating timer')
end

do
    local S = fakeSched()
    local E = corelib.makeEvents(S)
    local order = {}
    E.scheduleEvent(function() order[#order + 1] = 'b' end, 20)
    E.scheduleEvent(function() order[#order + 1] = 'a' end, 10)
    E.addEvent(function() order[#order + 1] = '0' end)
    S.advance(100)
    eq(table.concat(order, ''), '0ab', 'events fire in deadline order; addEvent is zero-delay')
end

do
    local S = fakeSched()
    local E = corelib.makeEvents(S)
    local n = 0
    E.periodicalEvent(function() n = n + 1 end, function() return n < 3 end, 10, 5)
    S.advance(100)
    eq(n, 3, 'periodicalEvent stops when its condition turns false')
end

raises(function() corelib.makeEvents(fakeSched()).scheduleEvent('not a function', 10) end,
       'must be a function', 'scheduleEvent rejects a non-function callback loudly')

do  -- the real lib/sched, briefly, to prove the wiring is not fake-clock-only
    local sched = require('lib.sched')
    sched.reset()
    local E = corelib.makeEvents(sched)
    local fired = false
    E.scheduleEvent(function() fired = true end, 5)
    local deadline = sys.nowMs() + 500
    while not fired and sys.nowMs() < deadline do sched.tick(5) end
    check(fired, 'scheduleEvent fires on the REAL lib/sched reactor too')
    sched.reset()
end

--==============================================================================
-- E. shim/platform
--==============================================================================
section('E. platform singletons (shim/platform.lua)')

-- I5: g_clock.millis() is frame-quantised and INTEGER
do
    platform.setClock(123456)
    eq(G.g_clock.millis(), 123456, 'setClock pins millis()')
    sys.sleepMs(3)
    eq(G.g_clock.millis(), 123456, 'millis() does NOT move without beginTick (invariant I5)')
    local t = platform.beginTick()
    eq(G.g_clock.millis(), t, 'beginTick refreshes millis() and returns the new value')
    eq(G.g_clock.millis(), math.floor(G.g_clock.millis()), 'millis() is an INTEGER (ticks_t)')
    local before = G.g_clock.realMillis()
    sys.sleepMs(6)
    check(G.g_clock.realMillis() > before, 'realMillis() IS live')
    eq(G.g_clock.millis(), t, 'and the quantised clock still has not moved')
    eq(G.g_clock.micros(), t * 1000, 'micros() derives from the same quantised value')
    eq(G.g_clock.seconds(), t / 1000, 'seconds()')
end

-- print joins with FOUR spaces and goes to the log at info
do
    local log = require('lib.log')
    local lines = {}
    local sub = log.onLine(function(level, text) lines[#lines + 1] = level .. '|' .. text end)
    G.print('a', 'b', 'c')
    G.pwarning('careful')
    G.perror('bad')
    log.offLine(sub)
    eq(lines[1], 'info|a    b    c', 'print joins with FOUR spaces (corelib/util.lua:2-13)')
    eq(lines[2], 'warn|careful', 'pwarning -> warn')
    eq(lines[3], 'error|bad', 'perror -> error')
end
do
    local log = require('lib.log')
    local lines = {}
    local sub = log.onLine(function(_, text) lines[#lines + 1] = text end)
    G.print('100%')                                     -- a stray % must never raise
    G.g_logger.info('50% of 100%')
    log.offLine(sub)
    eq(lines[1], '100%', 'a message containing % is logged verbatim, not format-expanded')
    eq(lines[2], '50% of 100%', 'g_logger.info likewise')
end

eq(G.tr('%d/%d', 1, 2), '1/2', 'tr is string.format')
eq(G.tr('plain'), 'plain', 'tr with no args returns the string unchanged')
eq(G.LogInfo, 2, 'LogInfo == 2 (corelib/const.lua:24)')
eq(G.LogError, 4, 'LogError == 4')

-- retranslateKeyComboDesc
eq(G.retranslateKeyComboDesc('space'), 'Space',
   'retranslateKeyComboDesc canonicalises "space" (the profile default in extras.lua:209)')
eq(G.retranslateKeyComboDesc('SPACE'), 'Space', 'it is case-insensitive')
eq(G.retranslateKeyComboDesc('shift+ctrl+g'), 'Ctrl+Shift+G',
   'modifiers come out in canonical order Ctrl, Meta, Alt, Shift, key')
eq(G.retranslateKeyComboDesc('primary+f1'), 'Ctrl+F1', 'aliases resolve (primary -> Ctrl)')
eq(G.retranslateKeyComboDesc('cmd+a'), 'Meta+A', 'cmd -> Meta on the non-macOS branch')
eq(G.retranslateKeyComboDesc('a'), G.retranslateKeyComboDesc('A'),
   'the result is stable, which is all a table key needs')
raises(function() G.retranslateKeyComboDesc(nil) end, 'Unable to translate',
       'a nil combo raises, as upstream does')

-- g_crypt
eq(G.g_crypt.crc32('123456789'), 3421780262, 'crc32 matches the standard check value')
eq(#G.g_crypt.genUUID(), 36, 'genUUID has the RFC 4122 shape')
eq(G.g_crypt.genUUID():sub(15, 15), '4', 'and is a version-4 UUID')
check(G.g_crypt.genUUID() ~= G.g_crypt.genUUID(), 'genUUID is not constant')
eq(G.g_crypt.sha256('abc'),
   'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'sha256("abc")')
G.g_crypt.setMachineUUID('abc'); eq(G.g_crypt.getMachineUUID(), 'abc', 'machine UUID round-trips')
raises(G.g_crypt.encrypt, 'not implemented',
       'g_crypt.encrypt RAISES rather than returning a wrong ciphertext')
raises(G.g_crypt.rsaGetSize, 'not implemented', 'g_crypt.rsaGetSize raises')

-- the recording stubs
platform.resetRecord()
eq(G.g_keyboard.isKeyPressed('space'), false,
   'g_keyboard.isKeyPressed is false -- there is no keyboard (B2, Equipper condition 9)')
eq(G.g_keyboard.isCtrlPressed(), false, 'g_keyboard.isCtrlPressed is false')
eq(G.g_window.getMousePosition().x, 0, 'g_window.getMousePosition is {0,0} -- no cursor (B3)')
eq(G.g_platform.openUrl('http://x'), false, 'g_platform.openUrl is inert')
G.g_window.flash()                                   -- B6: does not exist upstream at all
G.g_window.setTitle('shim')
eq(G.g_window.getTitle(), 'shim', 'g_window.setTitle is remembered')
G.g_window.setClipboardText('copied')
eq(G.g_window.getClipboardText(), 'copied', 'clipboard is stateful')
eq(platform.record['g_keyboard.isKeyPressed'].n, 1, 'the stub recorded the isKeyPressed call')
eq(platform.record['g_window.flash'].n, 1, 'the stub recorded the flash call')
eq(platform.record['g_platform.openUrl'].last[1], 'http://x', 'and recorded its argument')
check(#platform.report() >= 5, 'platform.report() lists what could not be honoured')

-- g_sounds: SoundChannels has no `Bot` key upstream, so the live client passes nil
do
    local channel = G.g_sounds.getChannel(nil)
    check(type(channel) == 'table', 'g_sounds.getChannel(nil) still returns a channel object (B5)')
    check(pcall(channel.play, 'x.ogg', 0, 1), 'channel:play is a no-op, never a crash')
    check(pcall(channel.stop), 'channel:stop is a no-op')
    eq(channel.isEnabled(), false, 'the channel reports itself disabled')
    check(G.g_sounds.getChannel(nil) == channel, 'the same channel object comes back')
end

eq(G.g_app.getOs(), 'windows', 'g_app.getOs() == "windows" (vBot/alarms.lua:127)')
eq(G.g_app.getVersion(), '3.0-shim', 'g_app.getVersion() is configurable')
eq(G.g_app.isRunning(), true, 'g_app.isRunning()')
do
    local exited = nil
    local G2 = {}
    platform.install(G2, { onExit = function(c) exited = c end })
    G2.g_app.exit()
    eq(exited, 0, 'g_app.exit forwards to opts.onExit')
end

--==============================================================================
-- F. shim/resources
--==============================================================================
section('F. g_resources (shim/resources.lua)')

-- pure path model, no filesystem needed
do
    local r = resources.new('/nowhere/', { sourcePath = '' })
    eq(r.resolvePath('/bot/vBot_4.8//vBot/main.lua'), '/bot/vBot_4.8/vBot/main.lua',
       "'//' is collapsed -- _Loader.lua:13 + executor.lua:115 produce exactly this")
    eq(r.resolvePath('///a///b'), '/a/b', 'runs of slashes collapse too')
    eq(r.resolvePath('sounds/magnum.ogg'), '/sounds/magnum.ogg',
       'a relative path with an EMPTY source path resolves against "/" -- which is what '
       .. 'the live client does for bot chunks (they carry no "@" in their chunk name)')
    r.setCurrentSourcePath('/vBot')
    eq(r.resolvePath('sounds/magnum.ogg'), '/vBot/sounds/magnum.ogg',
       'and against the chunk directory when the source path IS known')
    eq(r.getWriteDir(), '/nowhere/', 'getWriteDir keeps its trailing slash')
    eq(resources.new('/nowhere').getWriteDir(), '/nowhere/', 'a missing trailing slash is added')
end

-- the sandbox
do
    local r = resources.new(ROOT .. '/.shimtmp')
    local traversals = {
        '/../secret',
        '/bot/../../etc/passwd',
        '/bot/vBot_4.8/../../../../../../etc/passwd',
        '/..',
    }
    for _, p in ipairs(traversals) do
        eq(r.fileExists(p), false, ('sandbox: fileExists(%q) is refused'):format(p))
        raises(function() r.readFileContents(p) end, 'refusing',
               ('sandbox: readFileContents(%q) RAISES'):format(p))
        raises(function() r.writeFileContents(p, 'x') end, 'refusing',
               ('sandbox: writeFileContents(%q) RAISES'):format(p))
    end
    raises(function() r.readFileContents('/bot\\..\\..\\x') end, 'backslash',
           'a backslash-separated path is refused (Windows separator smuggling)')
    raises(function() r.readFileContents('/C:/Windows/win.ini') end, 'drive letter',
           'a smuggled drive letter is refused')
    check(next(r.refusals()) ~= nil, 'refusals are recorded for the test suite')
    -- a '..' inside a NAME is legal, only a '..' SEGMENT is not
    check(pcall(r.fileExists, '/bot/..hidden'), 'a filename beginning with ".." is allowed')
end

-- a real write / read / list / delete cycle in a temp directory
do
    local TMP = ROOT .. '/.shimtmp'
    local r = resources.new(TMP)
    eq(r.makeDir('/deep/nested/dir'), true, 'makeDir creates parents recursively')
    eq(r.directoryExists('/deep/nested/dir'), true, 'directoryExists sees it')
    eq(r.fileExists('/deep/nested/dir'), false, 'fileExists is FALSE for a directory (bot.lua:377)')

    eq(r.writeFileContents('/deep/a.txt', 'hello'), true, 'writeFileContents')
    eq(r.readFileContents('/deep/a.txt'), 'hello', 'readFileContents round-trips')
    eq(r.fileExists('/deep/a.txt'), true, 'fileExists is TRUE for a regular file')
    eq(r.directoryExists('/deep/a.txt'), false, 'directoryExists is FALSE for a file')
    eq(r.writeFileContents('/deep/made/up/b.txt', 'x'), true,
       'writeFileContents creates missing parent directories')

    r.writeFileContents('/deep/zz.txt', '')
    r.writeFileContents('/deep/Ab.txt', '')
    local names = r.listDirectoryFiles('/deep')
    local sorted = true
    for i = 2, #names do if names[i - 1] > names[i] then sorted = false end end
    check(sorted, 'listDirectoryFiles is SORTED (resourcemanager.cpp:797, invariant I6/B12)')
    check(table.find(names, 'a.txt') ~= nil, 'the listing holds the files')
    check(table.find(names, 'made') ~= nil, 'and the subdirectories as bare entries')

    local full = r.listDirectoryFiles('/deep', true)
    check(full[1]:sub(1, 6) == '/deep/', 'fullPath = true prefixes the resolved directory')

    do  -- recursive + fullPath descends and never lists a directory as an entry
        local rec = r.listDirectoryFiles('/deep', true, false, true)
        check(table.find(rec, '/deep/made/up/b.txt') ~= nil,
              'recursive listing reaches a nested file')
        check(table.find(rec, '/deep/made') == nil,
              'and replaces the directory entry with its contents')
        local sorted = true
        for i = 2, #rec do if rec[i - 1] > rec[i] then sorted = false end end
        check(sorted, 'the recursive listing is sorted too')
    end

    eq(#r.listDirectoryFiles('/does/not/exist'), 0, 'a missing directory lists empty')

    raises(function() r.readFileContents('/deep/missing.txt') end, 'unable to open file',
           'readFileContents RAISES on a missing file (invariant I6 / B11)')
    local ok, err = pcall(r.readFileContents, '/deep/missing.txt')
    check(not ok and tostring(err):find('/deep/missing.txt', 1, true) ~= nil,
          'and the message names the resolved path, as the C++ Exception does')

    eq(r.deleteFile('/deep/a.txt'), true, 'deleteFile removes a file')
    eq(r.fileExists('/deep/a.txt'), false, 'and it is gone')
    eq(r.deleteFile('/deep/a.txt'), false, 'deleting a missing file is false, not a crash')
    eq(r.deleteFile('/deep'), true, 'deleteFile removes a populated directory tree')
    eq(r.directoryExists('/deep'), false, 'and the tree is gone')

    check(r.createArchive({}) == nil, 'createArchive is inert and returns nil, not a fake zip (B7)')
end

--==============================================================================
-- G. shim/settings
--==============================================================================
section('G. g_settings (shim/settings.lua)')

do
    local TMP = ROOT .. '/.shimtmp'
    local r = resources.new(TMP)
    r.makeDir('/cfg')
    r.deleteFile('/cfg/s.json')

    local s = settings.new{ resources = r, path = '/cfg/s.json' }
    eq(s.getNumber('profile'), 1,
       'getNumber("profile") defaults to 1 -- 0 would silently reset every vBot config')
    eq(s.exists('profile'), true, 'the default was seeded into the store')

    s.set('foo', 'bar')
    eq(s.getString('foo'), 'bar', 'set/getString round trip')
    s.set('num', 42)
    eq(s.getNumber('num'), 42, 'getNumber converts')
    eq(s.getString('num'), '42', 'values are stored as strings, like OTML')
    s.set('flag', true)
    eq(s.getBoolean('flag'), true, 'getBoolean(true)')
    s.set('flag', false)
    eq(s.getBoolean('flag'), false, 'getBoolean(false)')
    s.set('flag', '1')
    eq(s.getBoolean('flag'), true, 'toboolean("1")')
    s.set('flag', 'TRUE')
    eq(s.getBoolean('flag'), true, 'toboolean is case-insensitive')
    s.set('flag', 'yes')
    eq(s.getBoolean('flag'), false, 'toboolean("yes") is FALSE upstream')

    eq(s.getNumber('missing'), 0, 'a missing key with no default is 0 (tonumber(nil) or 0)')
    eq(s.exists('missing'), false, 'and reading it did NOT create it')
    eq(s.getNumber('seeded', 7), 7, 'a default is returned')
    eq(s.exists('seeded'), true,
       "and WRITTEN -- Config:get's side effect (corelib/config.lua:34-38)")

    eq(s.setDefault('foo', 'other'), false, 'setDefault does not overwrite')
    eq(s.getString('foo'), 'bar', 'the original value survives')
    eq(s.setDefault('fresh', 'v'), true, 'setDefault writes a missing key')

    s.setNode('bot', { char_1 = { enabled = true, config = 'vBot_4.8' } })
    eq(s.getNode('bot').char_1.config, 'vBot_4.8', 'setNode/getNode round trip')
    eq(s.getValue('bot'), nil, 'getValue on a node key is nil, not the table')
    eq(s.getNodeSize('bot'), 1, 'getNodeSize counts children')
    s.mergeNode('bot', { char_2 = {} })
    eq(s.getNodeSize('bot'), 2, 'mergeNode adds')

    s.remove('fresh')
    eq(s.exists('fresh'), false, 'remove')

    eq(s.save(), true, 'save writes the file')
    eq(r.fileExists('/cfg/s.json'), true, 'and the file is there')

    -- persistence: a brand new store over the same file
    local s2 = settings.new{ resources = r, path = '/cfg/s.json' }
    eq(s2.getString('foo'), 'bar', 'a value survives a reopen')
    eq(s2.getNumber('profile'), 1, 'profile survives a reopen')
    eq(s2.getNode('bot').char_1.config, 'vBot_4.8', 'a node survives a reopen')
    eq(s2.exists('fresh'), false, 'a removed key stays removed')

    -- the sandbox applies to settings too
    raises(function() settings.new{ resources = r, path = '/../escape.json' } end,
           'refus', 'a settings path outside the sandbox is refused AT CONSTRUCTION')

    -- corrupt file -> empty store, loudly, never a crash
    r.writeFileContents('/cfg/broken.json', '{not json')
    local s3 = settings.new{ resources = r, path = '/cfg/broken.json',
                             defaults = { profile = 1 } }
    eq(s3.getNumber('profile'), 1, 'a corrupt settings file falls back to the defaults')

    raises(function() settings.new{ resources = r, path = '/cfg/x.json' }.set('p', { x = 1, width = 2 }) end,
           'geometry helpers',
           'a point/size/rect table raises instead of being silently stored wrong')

    r.deleteFile('/cfg')
end

--==============================================================================
-- H. the user's REAL profile data (read-only; skipped when absent)
--==============================================================================
section('H. real vBot 4.8 profile data')

if not PROFILE then
    skip('all profile-backed checks', 'the otclient tree is not present on this machine')
else
    local r = resources.new(PROFILE_ROOT)

    -- listDirectoryFiles order is what _Loader.lua:4-9 depends on
    local vfiles = r.listDirectoryFiles('/bot/vBot_4.8//vBot', true, false)
    check(#vfiles > 40, ('/vBot lists %d entries'):format(#vfiles))
    do
        local sorted = true
        for i = 2, #vfiles do if vfiles[i - 1] > vfiles[i] then sorted = false end end
        check(sorted, 'the /vBot listing is sorted -- fixes the .otui import order')
        eq(vfiles[1]:sub(1, 19), '/bot/vBot_4.8/vBot/',
           "fullPath entries are prefixed with the '//'-collapsed directory")
    end
    check(table.find(vfiles, '/bot/vBot_4.8/vBot/main.lua') ~= nil, '/vBot/main.lua is listed')

    -- top level, as executor.lua:3 sees it
    local top = r.listDirectoryFiles('/bot/vBot_4.8', true, false)
    check(table.find(top, '/bot/vBot_4.8/_Loader.lua') ~= nil, '_Loader.lua is at the top level')

    -- EVERY cavebot .cfg through decodeStringPairList, with a byte-exact round trip
    local cfgDir = '/bot/vBot_4.8/cavebot_configs'
    local cfgs = r.listDirectoryFiles(cfgDir)
    check(#cfgs > 0, ('%d cavebot .cfg files found'):format(#cfgs))
    local totalPairs, multilineFiles = 0, 0
    for _, f in ipairs(cfgs) do
        if f:sub(-4) == '.cfg' then
            local txt = r.readFileContents(cfgDir .. '/' .. f)
            local pl = table.decodeStringPairList(txt)
            totalPairs = totalPairs + #pl
            check(#pl > 0, ('%s decodes to %d pairs'):format(f, #pl))
            check(table.isStringPairList(pl), ('%s decodes to a valid string pair list'):format(f))
            eq(table.encodeStringPairList(pl), txt,
               ('%s: encodeStringPairList(decode(src)) == src, byte for byte'):format(f))
            if txt:find('[[', 1, true) then multilineFiles = multilineFiles + 1 end
        end
    end
    check(totalPairs > 1000, ('%d route entries parsed in total'):format(totalPairs))
    check(multilineFiles > 0,
          ('%d of the files use the multiline function:[[ ]] form'):format(multilineFiles))

    -- targetbot .json profiles are read through the same VFS
    local tDir = '/bot/vBot_4.8/targetbot_configs'
    local tfiles = r.listDirectoryFiles(tDir)
    check(#tfiles > 0, ('%d targetbot configs found'):format(#tfiles))
    do
        local json = require('lib.json')
        local n = 0
        for _, f in ipairs(tfiles) do
            if f:sub(-5) == '.json' then
                local txt = r.readFileContents(tDir .. '/' .. f)
                local ok, decoded = pcall(json.decode, txt)
                check(ok and type(decoded) == 'table', ('%s decodes as JSON'):format(f))
                n = n + 1
            end
        end
        check(n > 0, 'at least one targetbot .json was actually read')
    end

    -- the storage file executor.lua hands to the sandbox as `context.storage`
    local sp = '/bot/vBot_4.8/storage/profile_1.json'
    if r.fileExists(sp) then
        local txt = r.readFileContents(sp)
        check(#txt > 1000, ('storage/profile_1.json is %d bytes'):format(#txt))
        local ok, decoded = pcall(require('lib.json').decode, txt)
        check(ok and type(decoded) == 'table', 'storage/profile_1.json decodes as JSON')
    else
        skip('storage/profile_1.json', 'not present in this profile')
    end

    -- the ONE relative g_resources call in the profile (vBot/alarms.lua:122)
    r.setCurrentSourcePath('/vBot')
    eq(r.fileExists('sounds/magnum.ogg'), false,
       'alarms.lua:122 fileExists("sounds/magnum.ogg") is false, exactly as in the live client')

    -- absolutely nothing was written under the profile
    check(next(r.refusals()) == nil, 'no sandbox refusal happened while reading the profile')
end

--==============================================================================
-- clean up the temp tree
--==============================================================================
do
    local r = resources.new(ROOT)
    if r.directoryExists('/.shimtmp') then
        r.deleteFile('/.shimtmp')
        check(not r.directoryExists('/.shimtmp'), 'the temp tree was removed')
    end
end
ch.uninstall()

--==============================================================================
io.write('\n================ shim platform suite ================\n')
for _, m in ipairs(msgs) do io.write(m, '\n') end
io.write(('  TOTAL: %d passed, %d failed  -> %s\n')
         :format(pass, fail, fail == 0 and 'PASS' or 'FAIL'))
io.write(('  platform: %s  luajit: %s  profile: %s\n')
         :format(sys.os, _VERSION .. (jit and (' / ' .. jit.version) or ''),
                 PROFILE or '<absent>'))

if _G.SHIMPLATFORM_NO_EXIT then return { pass = pass, fail = fail, failures = msgs } end
os.exit(fail == 0 and 0 or 1)
