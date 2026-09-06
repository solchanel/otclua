--[[============================================================================
test/configschema_diff.lua -- REGRESSION test for the security review fix on
bot/configschema.lua / hub/api.lua's instance.configSet audit trail.

  luajit test/configschema_diff.lua          (from D:/Claude/otclient_web/luaclient)

Covers two review findings:

  MAJOR  hub/api.lua's instance.configSet audit `detail` used to name only the
         KIND ("kind=healbot") for every write except a cavebot function-body
         change -- never what changed.  bot/configschema.lua's new
         M.diffSummary(kind, oldData, newData) is the fix: this file proves it
         produces an admin-actionable "changed=..." summary (old->new scalars,
         array add/remove counts) for every kind's shape (plain object,
         top-level array (attackbot), and cavebot's flat {type,value} pairs),
         and degrades honestly (never errors) when no pre-image is available.

  MINOR  M.cavebotFunctionShapeChanged(oldPairs, newPairs) -- true whenever a
         function-typed waypoint's INDEX or COUNT changes shape even though
         M.cavebotFunctionBodyChanged (the security-critical canExec gate)
         reports no change, so the relocation this predicate deliberately
         allows without exec (CONFIGAPI.md: "reordering... needs only the
         normal instance-owner permission") is still visible in the audit
         trail instead of looking like an ordinary value edit.

Before this fix, bot/configschema.lua exported neither function -- every
check below fails outright (M.diffSummary/M.cavebotFunctionShapeChanged are
nil, so calling them raises "attempt to call a nil value").  After the fix
they exist and behave as asserted.  Nothing here touches the network, a real
profile directory, or a running worker -- pure-function tests only.

Exits non-zero if ANY check fails.
============================================================================]]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. package.path
end

-- =========================================================== tiny framework
local suites, cur = {}, nil
local totalPass, totalFail = 0, 0

local function suite(name)
    cur = { name = name, pass = 0, fail = 0 }
    suites[#suites + 1] = cur
    return cur
end

local function check(ok, desc, detail)
    if ok then
        cur.pass = cur.pass + 1
        totalPass = totalPass + 1
    else
        cur.fail = cur.fail + 1
        totalFail = totalFail + 1
        io.write('    FAIL  ', desc, detail and ('  -- ' .. tostring(detail)) or '', '\n')
    end
    return ok
end

local function eq(got, want, desc)
    if got == want then return check(true, desc) end
    return check(false, desc, ('got %s, want %s'):format(tostring(got), tostring(want)))
end

local function contains(hay, needle, desc)
    hay = tostring(hay)
    if hay:find(needle, 1, true) then return check(true, desc) end
    return check(false, desc, ('%q does not contain %q'):format(hay, needle))
end

local function notContains(hay, needle, desc)
    hay = tostring(hay)
    if not hay:find(needle, 1, true) then return check(true, desc) end
    return check(false, desc, ('%q unexpectedly contains %q'):format(hay, needle))
end

local function runSuite(name, fn)
    suite(name)
    local ok, err = pcall(fn)
    if not ok then check(false, 'suite crashed', err) end
end

local schema = require('bot.configschema')

-- =========================================== MAJOR finding: M.diffSummary ==
runSuite('diffSummary: healbot itemTable[i].value scalar change (the exact ' ..
         'live-probe scenario in the review finding: 40 -> 999999)', function()
    check(type(schema.diffSummary) == 'function',
          'bot/configschema.lua exports M.diffSummary')

    local oldData = {
        itemTable  = { { enabled = true, sign = '<', origin = 'HP%', item = 239, value = 40 } },
        spellTable = {},
    }
    local newData = {
        itemTable  = { { enabled = true, sign = '<', origin = 'HP%', item = 239, value = 999999 } },
        spellTable = {},
    }
    local detail = schema.diffSummary('healbot', oldData, newData)
    check(type(detail) == 'string', 'diffSummary returns a string')
    contains(detail, 'kind=healbot', '   names the kind')
    contains(detail, 'itemTable[1].value', '   names the exact changed field/index')
    contains(detail, '40', '   shows the OLD value')
    contains(detail, '999999', '   shows the NEW value')
    -- this used to be the ENTIRE detail string pre-fix -- now it must be more
    check(detail ~= 'kind=healbot', '   is not just the bare kind (pre-fix behaviour)', detail)
end)

runSuite('diffSummary: attackbot bare-array top shape, enabled toggle (the ' ..
         'review finding\'s second live-probe scenario)', function()
    local oldData = {
        { category = 1, patternCategory = 1, pattern = 1, spell = 'exori', itemId = 0,
          count = 1, minHp = 0, maxHp = 100, mana = 0, cooldown = 2000,
          monsters = { 'rat' }, enabled = true },
    }
    local newData = {
        { category = 1, patternCategory = 1, pattern = 1, spell = 'exori', itemId = 0,
          count = 1, minHp = 0, maxHp = 100, mana = 0, cooldown = 2000,
          monsters = { 'rat' }, enabled = false },
    }
    local detail = schema.diffSummary('attackbot', oldData, newData)
    contains(detail, 'kind=attackbot', '   names the kind')
    contains(detail, '[1].enabled', '   names the entry index and field')
    contains(detail, 'true', '   shows the OLD boolean')
    contains(detail, 'false', '   shows the NEW boolean')
end)

runSuite('diffSummary: cavebot flat {type,value} pairs, an ORDINARY goto ' ..
         'edit (the review finding\'s third live-probe scenario -- previously ' ..
         '"kind=cavebot name=X" with no diff at all)', function()
    local oldPairs = {
        { type = 'goto', value = '32100,32200,7' },
        { type = 'goto', value = '32101,32201,7' },
    }
    local newPairs = {
        { type = 'goto', value = '32100,32200,7' },
        { type = 'goto', value = '31000,31000,7' },
    }
    local detail = schema.diffSummary('cavebot', oldPairs, newPairs)
    contains(detail, 'kind=cavebot', '   names the kind')
    contains(detail, '[2].value', '   names the changed pair index')
    contains(detail, '32101,32201,7', '   shows the OLD coordinate string')
    contains(detail, '31000,31000,7', '   shows the NEW coordinate string')
end)

runSuite('diffSummary: array length changes are reported as added/removed, ' ..
         'not silently ignored', function()
    local oldData = { { type = 'goto', value = 'a' } }
    local newData = { { type = 'goto', value = 'a' }, { type = 'label', value = 'b' } }
    local detail = schema.diffSummary('cavebot', oldData, newData)
    contains(detail, 'added=1', '   one entry added')
    contains(detail, 'removed=0', '   none removed')

    local detail2 = schema.diffSummary('cavebot', newData, oldData)
    contains(detail2, 'added=0', '   (reverse direction) none added')
    contains(detail2, 'removed=1', '   one removed')
end)

runSuite('diffSummary: no differences -> an honest "no differences" note, ' ..
         'not a crash or an empty string', function()
    local data = { itemTable = {}, spellTable = {} }
    local detail = schema.diffSummary('healbot', data, data)
    check(type(detail) == 'string' and #detail > 0, 'still returns a non-empty string')
    contains(detail, 'no field differences', '   says so honestly')
end)

runSuite('diffSummary: a missing pre-image (oldData == nil -- config.get ' ..
         'could not be fetched) degrades gracefully instead of erroring', function()
    local ok, detail = pcall(schema.diffSummary, 'healbot', nil, { itemTable = {}, spellTable = {} })
    check(ok, 'does not raise when oldData is nil', detail)
    if ok then
        contains(detail, 'kind=healbot', '   still names the kind')
        contains(detail, 'no prior value available', '   and says why there is no diff')
    end
end)

runSuite('diffSummary: bounded size -- a huge payload never produces an ' ..
         'unbounded audit record', function()
    local oldData, newData = {}, {}
    for i = 1, 500 do
        oldData[i] = { type = 'goto', value = ('%d,%d,7'):format(i, i) }
        newData[i] = { type = 'goto', value = ('%d,%d,7'):format(i, i + 1) }  -- every entry differs
    end
    local detail = schema.diffSummary('cavebot', oldData, newData, 900)
    check(#detail <= 920, '   stays close to the requested byte budget (900 + truncation marker)',
          ('detail is %d bytes'):format(#detail))
end)

-- ================================ MINOR finding: cavebotFunctionShapeChanged
runSuite('cavebotFunctionShapeChanged: unchanged when nothing about a ' ..
         'function waypoint moved', function()
    check(type(schema.cavebotFunctionShapeChanged) == 'function',
          'bot/configschema.lua exports M.cavebotFunctionShapeChanged')

    local pairs_ = {
        { type = 'goto', value = '1,1,7' },
        { type = 'function', value = 'return true' },
        { type = 'goto', value = '2,2,7' },
    }
    eq(schema.cavebotFunctionShapeChanged(pairs_, pairs_), false,
       '   identical lists: no shape change')
end)

runSuite('cavebotFunctionShapeChanged: true when a new waypoint is inserted ' ..
         'BEFORE the function, shifting its index (an ordinary edit that ' ..
         'still relocates the function waypoint)', function()
    local oldPairs = {
        { type = 'goto', value = '1,1,7' },
        { type = 'function', value = 'return true' },
    }
    local newPairs = {
        { type = 'goto', value = '1,1,7' },
        { type = 'goto', value = '2,2,7' },       -- newly inserted, before the function
        { type = 'function', value = 'return true' },
    }
    eq(schema.cavebotFunctionBodyChanged(oldPairs, newPairs), false,
       '   sanity: the security gate correctly sees no body change (same exact text)')
    eq(schema.cavebotFunctionShapeChanged(oldPairs, newPairs), true,
       '   but the shape-change predicate flags the index move (2 -> 3)')
end)

runSuite('cavebotFunctionShapeChanged: the review finding\'s exact scenario -- ' ..
         'a non-function waypoint retyped to function reusing the BYTE-IDENTICAL ' ..
         'text of a function waypoint removed elsewhere in the same PUT (net-zero ' ..
         'occurrence count, so the exec gate correctly stays closed) must still ' ..
         'be visible as a shape change', function()
    local BODY = 'return true'
    local oldPairs = {
        { type = 'goto', value = '1,1,7' },        -- idx 1: will be retyped to function
        { type = 'goto', value = '2,2,7' },
        { type = 'function', value = BODY },       -- idx 3: will be removed
    }
    local newPairs = {
        { type = 'function', value = BODY },       -- idx 1: same body, new position
        { type = 'goto', value = '2,2,7' },
    }
    eq(schema.cavebotFunctionBodyChanged(oldPairs, newPairs), false,
       '   confirmed: net-zero occurrence count never trips the canExec gate (by design)')
    eq(schema.cavebotFunctionShapeChanged(oldPairs, newPairs), true,
       '   but the relocation (function count/position: idx 3 -> idx 1) is now detectable')
end)

runSuite('cavebotFunctionShapeChanged: a pure REORDER of two non-function ' ..
         'waypoints around a function waypoint that does not move its own ' ..
         'index reports no shape change (no false positives on ordinary edits)',
function()
    local oldPairs = {
        { type = 'function', value = 'return true' },
        { type = 'goto', value = '1,1,7' },
        { type = 'goto', value = '2,2,7' },
    }
    local newPairs = {
        { type = 'function', value = 'return true' },
        { type = 'goto', value = '2,2,7' },   -- the two gotos swapped
        { type = 'goto', value = '1,1,7' },
    }
    eq(schema.cavebotFunctionShapeChanged(oldPairs, newPairs), false,
       '   the function waypoint never moved (still index 1) -- no note needed')
end)

-- ================================================================== summary
io.write('\n================ configschema diff selftest ================\n')
for _, s in ipairs(suites) do
    io.write(('  %-70s %s  %d passed'):format(s.name:sub(1, 70), s.fail == 0 and 'PASS' or 'FAIL', s.pass))
    if s.fail > 0 then io.write((', %d FAILED'):format(s.fail)) end
    io.write('\n')
end
io.write(('  ------------------------------------------------\n  TOTAL: %d passed, %d failed  -> %s\n')
         :format(totalPass, totalFail, totalFail == 0 and 'PASS' or 'FAIL'))
os.exit(totalFail == 0 and 0 or 1)
