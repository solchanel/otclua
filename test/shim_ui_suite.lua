--[==[========================================================================
test/shim_ui_suite.lua -- work item S3: the stateful, invisible UI model.

    luajit test/shim_ui_suite.lua              (from D:/Claude/otclient_web/luaclient)
    wsl.exe -d Debian -e sh -c 'cd /mnt/d/Claude/otclient_web/luaclient && \
        luajit test/shim_ui_suite.lua'

Covers, with read-back assertions rather than smoke checks:

  A  OTML parser        indentation, `tag: value`, block form, `|` / `|-` / `|+`
                        literals, `//` and `#` comments, `~` null, `[a,b]` lists,
                        duplicate-unique-tag merging, tab and odd-indent errors, and
                        THE rule that decides everything -- a line with a colon is a
                        PROPERTY, a line without one is a CHILD WIDGET.
  B  style registry     `Name < Base` flattening (children inherited), the lowercase
                        alias, the `UI*` auto-definition, a later base redefinition
                        NOT retro-applying, and the D1 per-style tolerance.
  C  widget exactness   every quirk Q1..Q10 in shim/ui/widget.lua, one assert each:
                        getChildByIndex(0)/(-1), getChildIndex(nil)/(foreign), setId
                        collision + numeric key, setText's dontFireLuaCall, setItemId
                        always firing, first-addOption auto-select, the setupDone gate,
                        auto-focus first/last/none, and the two DIFFERENT refocus rules
                        for destroy() vs setVisible(false).
  D  destroyed widgets  a destroyed child is gone from getChildren / getChildById /
                        the parent's Lua field / the focus, and its own subtree with it.
  E  the real trees     HealBot.lua's setupUI panel (ids 1..5 read as NUMBERS) and its
                        HealWindow; AttackBot's entryList; targetbot's TargetBotPanel
                        status/target/config/danger + list + BotContainer; and the REAL
                        cavebot/config.lua, executed unmodified, for all four row types.
  F  lists as data      the CaveBot waypoint list driven exactly as cavebot.lua drives
                        it (getFocusedChild IS the program counter) and the TargetBot
                        creature list.
  G  the real helpers   mods/game_bot/functions/{ui,ui_elements,ui_legacy,ui_windows}.lua
                        loaded VERBATIM onto this widget model, then every helper it
                        defines exercised and reported.
  H  every window style all 24 `UI.createWindow` styles in the user's profile
                        instantiated from the real .otui files.

Sections E-H need the READ-ONLY otclient tree and SKIP WITH A PRINTED REASON when it
is absent, so the suite still passes on a machine without it.  Nothing here writes
anywhere under D:/Claude/otclient_mehah1530, and nothing touches the network.

Set `_G.SHIMUI_NO_EXIT = true` before dofile()ing this file and it returns
{ pass=, fail=, skip=, failures={} } instead of exiting.
==========================================================================]==]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. ROOT .. '/?/init.lua;' .. package.path
end

local widget  = require('shim.ui.widget')
local uimod   = require('shim.ui.g_ui')
local helpers = require('shim.ui.helpers')

local OTROOT   = helpers.findRoot()
local PROFILE  = OTROOT and (OTROOT .. '/profiles/bot/vBot_4.8') or nil

-- =========================================================== tiny framework
local pass, fail, skipped = 0, 0, 0
local failures = {}
local curSection = ''

local function section(name)
    curSection = name
    io.write('\n== ', name, '\n')
end

local function check(ok, desc, detail)
    if ok then
        pass = pass + 1
    else
        fail = fail + 1
        local line = string.format('    FAIL  [%s] %s%s', curSection, desc,
                                   detail and ('  -- ' .. tostring(detail)) or '')
        failures[#failures + 1] = line
        io.write(line, '\n')
    end
    return ok
end

local function eq(got, want, desc)
    if got == want then return check(true, desc) end
    return check(false, desc, string.format('got %s, want %s', tostring(got), tostring(want)))
end

local function skip(reason)
    skipped = skipped + 1
    io.write('    SKIP  ', reason, '\n')
end

local function raises(fn, desc)
    local ok = pcall(fn)
    return check(not ok, desc, 'expected an error, got none')
end

-- ============================================================ shared fixture
--- A fresh, isolated (g_ui, styles, ENV) triple.  Every section builds its own so a
--- style imported by one cannot leak into another.
local function newUI(opts)
    opts = opts or {}
    local ENV = setmetatable({}, { __index = _G })
    ENV.tr = function(s, ...)
        if select('#', ...) > 0 then return string.format(s, ...) end
        return s
    end
    ENV.modules = {}
    local h = uimod.new{ env = ENV, resources = opts.resources }
    ENV.g_ui = h.g_ui
    h.g_ui.installBuiltinStyles()
    h.ENV = ENV
    return h
end

-- ===========================================================================
section('A  OTML parser')
-- ===========================================================================
do
    local doc = uimod.parse([[
Panel
  id: root
  height: 10

  Label
    id: hello
    text: hi

  Button
    text: go
]], '(A1)')
    local kids = doc:visibleChildren()
    eq(#kids, 1, 'A1 one top-level node')
    local panel = kids[1]
    eq(panel.tag, 'Panel', 'A1 tag')
    eq(panel.unique, false, 'A1 a colon-less line is a CHILD node (unique=false)')
    eq(panel:get('id').unique, true, 'A1 a line with a colon is a PROPERTY (unique=true)')
    eq(panel:valueAt('height'), '10', 'A1 tag: value')
    local pk = panel:visibleChildren()
    eq(#pk, 4, 'A1 four children: id, height, Label, Button')
    eq(pk[3].tag, 'Label', 'A1 declaration order preserved')
    eq(pk[3]:valueAt('text'), 'hi', 'A1 nested property')
end

do  -- comments, null, list
    local doc = uimod.parse([[
// a comment line
# another comment
Panel
  text: kept
  gone: ~
  nums: [1, 2, 3]
]], '(A2)')
    local p = doc:visibleChildren()[1]
    eq(p.tag, 'Panel', 'A2 comments skipped')
    eq(p:valueAt('text'), 'kept', 'A2 value after comments')
    eq(p:get('gone'), nil, 'A2 `~` is a null node and is invisible to children()')
    local l = nil
    for _, n in ipairs(p.children) do if n.tag == 'nums' then l = n end end
    eq(l and l.list and l.list[2], '2', 'A2 [a, b, c] parsed as a list')
end

do  -- literal blocks
    local doc = uimod.parse([[
Panel
  @onSetup: |
    self:addOption("a")
    self:addOption("b")
  @onClick: |-
    x
  @onOther: |+
    y
  after: 1
]], '(A3)')
    local p = doc:visibleChildren()[1]
    eq(p:valueAt('@onSetup'), 'self:addOption("a")\nself:addOption("b")\n',
       'A3 `|` strips trailing newlines and adds exactly one')
    eq(p:valueAt('@onClick'), 'x', 'A3 `|-` strips every trailing newline')
    eq(p:valueAt('@onOther'), 'y\n', 'A3 `|+` keeps the newlines up to the next node')
    eq(p:valueAt('after'), '1', 'A3 parsing resumes after a literal block')
end

do  -- errors
    raises(function() uimod.parse('Panel\n\tid: x\n', '(A4)') end,
           'A4 a tab indent raises')
    raises(function() uimod.parse('Panel\n   id: x\n', '(A4)') end,
           'A4 an odd indent raises')
    raises(function() uimod.parse('Panel\n      id: x\n', '(A4)') end,
           'A4 a two-level jump raises')
end

do  -- duplicate unique tag (otmlnode.cpp:86-116)
    -- The PARSER adds a node to its parent BEFORE parsing that node's children
    -- (otmlparser.cpp:455), so at addChild time the newcomer is childless and the
    -- merge branch cannot fire: a duplicate unique tag REPLACES outright.
    local doc = uimod.parse([[
Panel
  layout:
    type: verticalBox
  layout:
    fit-children: true
]], '(A5)')
    local p = doc:visibleChildren()[1]
    local n = 0
    for _, c in ipairs(p.children) do if c.tag == 'layout' then n = n + 1 end end
    eq(n, 1, 'A5 a duplicate unique tag replaces rather than appends')
    local layout = p:get('layout')
    eq(layout:valueAt('type'), nil,
       'A5 the parser cannot merge: the second `layout:` fully replaces the first')
    eq(layout:valueAt('fit-children'), 'true', 'A5 ... and keeps its own children')

    -- The merge branch DOES fire in style flattening, where clone()/merge() operate
    -- on fully-built nodes.  That is what makes a derived style inherit and extend a
    -- base style's sub-block instead of replacing it.
    local h5 = newUI()
    h5.g_ui.importStyleFromString([[
BaseBlock < UIWidget
  layout:
    type: verticalBox
Derived5 < BaseBlock
  layout:
    fit-children: true
]], '(A5b)')
    local d = h5.g_ui.getStyle('Derived5'):get('layout')
    eq(d:valueAt('type'), 'verticalBox', 'A5 style flattening MERGES a sub-block (base half)')
    eq(d:valueAt('fit-children'), 'true', 'A5 ... and the derived half')
end

-- ===========================================================================
section('B  style registry')
-- ===========================================================================
do
    local h = newUI()
    local g_ui = h.g_ui

    g_ui.importStyleFromString([[
BaseThing < UIWidget
  focusable: false
  Label
    id: caption
DerivedThing < BaseThing
  on: true
]], '(B1)')

    local base = g_ui.getStyle('BaseThing')
    local der  = g_ui.getStyle('DerivedThing')
    check(base ~= nil and der ~= nil, 'B1 both styles registered')
    eq(g_ui.getStyle('derivedthing'), der, 'B1 lowercase alias resolves to the same node')
    eq(der:valueAt('__class'), 'UIWidget', 'B1 __class inherited from the UI* auto-definition')
    eq(der:valueAt('focusable'), 'false', 'B1 base properties flattened into the derived style')
    local hasLabel = false
    for _, c in ipairs(der.children) do if c.tag == 'Label' then hasLabel = true end end
    check(hasLabel, 'B1 base CHILDREN inherited by the derived style')

    -- the auto-definition rule
    local auto = g_ui.getStyle('UIFooBar')
    eq(auto and auto:valueAt('__class'), 'UIFooBar', 'B2 an unregistered UI* name auto-defines')
    eq(g_ui.getStyle('NotAUIName'), nil, 'B2 a non-UI unknown name stays undefined')

    -- a later base redefinition does not retro-apply (flattening happens at import)
    g_ui.importStyleFromString('BaseThing < UIWidget\n  on: true\n  checked: true\n', '(B3)')
    eq(g_ui.getStyle('DerivedThing'):valueAt('checked'), nil,
       'B3 redefining a base does NOT retro-apply to already-derived styles')

    -- D1: an undefined base skips that style only
    local n = g_ui.importStyleFromString([[
Orphan < NoSuchBase
  text: x
Fine < UIWidget
  text: y
]], '(B4)')
    eq(n, 1, 'B4 the style with an undefined base is skipped, the rest still import')
    eq(g_ui.getStyle('Fine') ~= nil, true, 'B4 the later style survived')
    eq(#h.styles.failed, 1, 'B4 the skip is RECORDED in styles.failed')
end

-- ===========================================================================
section('C  widget exactness quirks')
-- ===========================================================================
do
    local h = newUI()
    local g_ui = h.g_ui
    local root = g_ui.getRootWidget()

    -- ---- Q1 getChildByIndex ------------------------------------------------
    local p = g_ui.createWidget('Panel', root)
    local a = g_ui.createWidget('Label', p)
    local b = g_ui.createWidget('Label', p)
    local c = g_ui.createWidget('Label', p)
    -- uiwidget.cpp:1509-1516: index = index<=0 and size+index or index-1, 0-based.
    -- api-ui.md sec.4.3 claims "0 -> last"; the source says 0 -> size -> OUT OF RANGE.
    eq(p:getChildByIndex(1), a, 'Q1 getChildByIndex(1) is the FIRST child (1-based)')
    eq(p:getChildByIndex(-1), c, 'Q1 getChildByIndex(-1) is the LAST child')
    eq(p:getChildByIndex(-2), b, 'Q1 getChildByIndex(-2) is the second-to-last')
    eq(p:getChildByIndex(0), nil, 'Q1 getChildByIndex(0) maps to size and is OUT OF RANGE')
    eq(p:getLastChild(), c, 'Q1 getLastChild() == getChildByIndex(-1) (uiwidget.h:722)')
    eq(p:getFirstChild(), a, 'Q1 getFirstChild')
    eq(p:getChildByIndex(99), nil, 'Q1 out of range is nil')
    eq(p:getChildCount(), 3, 'Q1 getChildCount')

    -- ---- Q2 getChildIndex --------------------------------------------------
    eq(p:getChildIndex(b), 2, 'Q2 getChildIndex(child) is 1-based')
    eq(p:getChildIndex(root), -1, 'Q2 getChildIndex(foreign) is -1')
    eq(p:getChildIndex(nil), p:getParent():getChildIndex(p),
       'Q2 getChildIndex(nil) is the widget OWN index in its parent')
    eq(b:getChildIndex(), 2, 'Q2 the same, read off the child itself')

    -- ordering is the payload: moveChildToIndex reindexes
    p:moveChildToIndex(c, 1)
    eq(p:getChildIndex(c), 1, 'Q2 moveChildToIndex moves')
    eq(p:getChildIndex(a), 2, 'Q2 moveChildToIndex reindexes the siblings')
    p:moveChildToIndex(c, 3)
    eq(p:getChildIndex(c), 3, 'Q2 move back')

    -- ---- Q3/Q4 setId -------------------------------------------------------
    a:setId('caption')
    eq(p.caption, a, 'Q3 setId installs the parent Lua field')
    eq(p:getChildById('caption'), a, 'Q3 setId fills childrenById')
    b:setId('caption')
    eq(p.caption, b, 'Q3 setId overwrites unconditionally (uiwidget.cpp:1056-1072)')
    a:setId('other')
    eq(p.caption, b, 'Q3 renaming the OLD holder does not clear the new one')
    eq(p.other, a, 'Q3 the rename installs the new field')

    local q = g_ui.createWidget('Panel', root)
    local n1 = g_ui.createWidget('Label', q)
    n1:setId('1')
    eq(q['1'], n1, 'Q4 the string key is set')
    eq(q[1], n1, 'Q4 a numeric id ALSO sets the numeric key (HealBot reads ui[1])')

    -- addChild's guarded install: a widget that already has an id, parented into a
    -- parent that already owns that field, must NOT clobber it.
    local guard = g_ui.createWidget('Panel', root)
    guard.value = 'preexisting'
    local orphan = g_ui.createWidget('Label')
    orphan:setId('value')
    guard:addChild(orphan)
    eq(guard.value, 'preexisting', 'Q3 addChild does not overwrite an existing parent field')
    eq(guard:getChildById('value'), orphan, 'Q3 ... but childrenById is ALWAYS written')

    -- ---- Q5 setText / setItemId -------------------------------------------
    local fired, gotNew, gotOld = 0, nil, nil
    local t = g_ui.createWidget('Label', p)
    t.onTextChange = function(w, new, old) fired = fired + 1; gotNew, gotOld = new, old end
    t:setText('one')
    eq(fired, 1, 'Q5 setText fires onTextChange')
    eq(gotNew, 'one', 'Q5 ... with the new text')
    eq(gotOld, '', 'Q5 ... and the old text')
    t:setText('one')
    eq(fired, 1, 'Q5 an unchanged setText fires nothing')
    t:setText('two', true)
    eq(fired, 1, 'Q5 setText(t, dontFireLuaCall) fires NOTHING (breaks CaveBot.save recursion)')
    eq(t:getText(), 'two', 'Q5 ... but the value is stored')
    t:setText(42)
    eq(t:getText(), '42', 'Q5 a number is coerced (targetbot/looting.lua:60 passes numbers)')

    local itemFired = 0
    local it = g_ui.createWidget('BotItem', p)
    it.onItemChange = function() itemFired = itemFired + 1 end
    it:setItemId(3031)
    eq(itemFired, 1, 'Q5 setItemId fires onItemChange')
    eq(it:getItemId(), 3031, 'Q5 getItemId round-trips')
    it:setItemId(3031)
    eq(itemFired, 2, 'Q5 setItemId ALWAYS fires -- there is no suppress argument')
    it:setItemId(0)
    eq(it:getItemId(), 0, 'Q5 setItemId(0) clears the item')

    -- ---- Q7 combobox -------------------------------------------------------
    local cb = g_ui.createWidget('ComboBox', p)
    eq(cb:getCurrentOption(), nil, 'Q7 an empty combobox has no current option')
    cb:addOption('Below')
    eq(cb:getCurrentOption().text, 'Below', 'Q7 the FIRST addOption auto-selects')
    eq(cb:getText(), 'Below', 'Q7 ... and sets the text')
    cb:addOption('Above')
    eq(cb:getCurrentOption().text, 'Below', 'Q7 a later addOption does not re-select')
    local optFired = 0
    cb.onOptionChange = function() optFired = optFired + 1 end
    cb:setCurrentOption('Above')
    eq(optFired, 1, 'Q7 setCurrentOption signals')
    cb:setCurrentOption('Above')
    eq(optFired, 1, 'Q7 setCurrentOption to the same option does not signal')
    cb:setCurrentOption('Below', true)
    eq(optFired, 1, 'Q7 setCurrentOption(text, dontSignal) does not signal')
    eq(cb:getCurrentOption().text, 'Below', 'Q7 ... but does change')
    cb:setCurrentIndex(1)
    eq(optFired, 2, 'Q7 setCurrentIndex ALWAYS signals, even for an unchanged index')
    cb:clearOptions()
    eq(cb:getCurrentOption(), nil, 'Q7 clearOptions')
    eq(cb:getText(), '', 'Q7 clearOptions clears the text')

    -- ---- Q6 scrollbar -----------------------------------------------------
    local sc = g_ui.createWidget('HorizontalScrollBar', p)
    eq(sc.setupDone, true, 'Q6 onSetup ran and set setupDone')
    sc:setRange(0, 100)
    local vFired, vVal, vDelta = 0, nil, nil
    sc.onValueChange = function(w, v, d) vFired = vFired + 1; vVal, vDelta = v, d end
    sc:setValue(40)
    eq(vFired, 1, 'Q6 setValue signals once setupDone')
    eq(vVal, 40, 'Q6 ... with math.round(value)')
    eq(vDelta, 40, 'Q6 ... and the delta')
    sc:setValue(40)
    eq(vFired, 1, 'Q6 an unchanged setValue does nothing')
    sc:setValue(9999)
    eq(sc:getValue(), 100, 'Q6 setValue clamps to maximum')
    sc:setValue(-5)
    eq(sc:getValue(), 0, 'Q6 setValue clamps to minimum')

    -- a scrollbar built from a style with `value:` must NOT have signalled
    h.g_ui.importStyleFromString([[
PreSetScroll < HorizontalScrollBar
  minimum: 0
  maximum: 100
  value: 33
]], '(C-scroll)')
    local pre = g_ui.createWidget('PreSetScroll', p)
    eq(pre:getValue(), 33, 'Q6 the style value: is applied')
    eq(pre.minimum, 0, 'Q6 the style minimum: is applied')
    eq(pre.maximum, 100, 'Q6 the style maximum: is applied')

    -- ---- SpinBox: setText drives setValue (vBot/supplies.lua) ---------------
    h.g_ui.importStyleFromString('SupplySpin < SpinBox\n  minimum: 0\n  maximum: 99999\n  text: 0\n',
                                 '(C-spin)')
    local sb = g_ui.createWidget('SupplySpin', p)
    eq(sb.maximum, 99999, 'SpinBox maximum: from the style')
    sb:setText(250)
    eq(sb:getValue(), 250, 'SpinBox setText(n) drives getValue() -- supplies.lua:185 -> :214')
    sb:setText(999999)
    eq(sb:getValue(), 99999, 'SpinBox setText clamps to maximum')
    sb:setValue(7)
    eq(sb:getText(), '7', 'SpinBox setValue writes the text back')

    -- ---- Q8 auto-focus -----------------------------------------------------
    h.g_ui.importStyleFromString([[
FocusableLabel < Label
  focusable: true
]], '(C-focus)')
    local lastPanel = g_ui.createWidget('UIWidget', root)     -- default policy: last
    eq(lastPanel:getAutoFocusPolicy(), 'last', 'Q8 the default policy is `last`')
    local f1 = g_ui.createWidget('FocusableLabel', lastPanel)
    local f2 = g_ui.createWidget('FocusableLabel', lastPanel)
    eq(lastPanel:getFocusedChild(), f2, 'Q8 policy `last` focuses each new focusable child')

    local firstPanel = g_ui.createWidget('Panel', root)       -- Panel: auto-focus first
    eq(firstPanel:getAutoFocusPolicy(), 'first', 'Q8 Panel declares auto-focus: first')
    local g1 = g_ui.createWidget('FocusableLabel', firstPanel)
    local g2 = g_ui.createWidget('FocusableLabel', firstPanel)
    eq(firstPanel:getFocusedChild(), g1, 'Q8 policy `first` keeps the FIRST focusable child')

    local list = g_ui.createWidget('TextList', root)          -- TextList: auto-focus none
    eq(list:getAutoFocusPolicy(), 'none', 'Q8 TextList declares auto-focus: none')
    local n1b = g_ui.createWidget('FocusableLabel', list)
    eq(list:getFocusedChild(), nil, 'Q8 policy `none` focuses nothing')
    local nonFocusable = g_ui.createWidget('Label', firstPanel)
    eq(nonFocusable:isFocusable(), false, 'Q8 a plain Label is not focusable (uilabel.lua:7)')

    -- ---- Q9 the TWO different refocus rules -------------------------------
    local L = g_ui.createWidget('UIWidget', root)             -- policy last
    local i1 = g_ui.createWidget('FocusableLabel', L)
    local i2 = g_ui.createWidget('FocusableLabel', L)
    local i3 = g_ui.createWidget('FocusableLabel', L)
    L:focusChild(i2)
    eq(L:getFocusedChild(), i2, 'Q9 focusChild')
    i2:setVisible(false)
    eq(L:getFocusedChild(), i1,
       'Q9 setVisible(false) on the focused child -> the PREVIOUS sibling')

    local L2 = g_ui.createWidget('UIWidget', root)
    local j1 = g_ui.createWidget('FocusableLabel', L2)
    local j2 = g_ui.createWidget('FocusableLabel', L2)
    local j3 = g_ui.createWidget('FocusableLabel', L2)
    L2:focusChild(j2)
    j2:destroy()
    eq(L2:getFocusedChild(), j3,
       'Q9 destroy() of the focused child -> the LAST focusable sibling (focus cleared first)')

    -- focus signals
    local order = {}
    local L3 = g_ui.createWidget('UIWidget', root)
    local k1 = g_ui.createWidget('FocusableLabel', L3)
    local k2 = g_ui.createWidget('FocusableLabel', L3)
    L3:focusChild(k1)
    k1.onFocusChange = function(w, focused) order[#order + 1] = 'k1:' .. tostring(focused) end
    k2.onFocusChange = function(w, focused) order[#order + 1] = 'k2:' .. tostring(focused) end
    L3.onChildFocusChange = function(w, new, old) order[#order + 1] = 'parent' end
    L3:focusChild(k2)
    eq(table.concat(order, ','), 'k2:true,k1:false,parent',
       'Q9 focusChild order: new onFocusChange(true), old onFocusChange(false), onChildFocusChange')

    -- ---- visibility propagation -------------------------------------------
    local outer = g_ui.createWidget('Panel', root)
    local inner = g_ui.createWidget('Panel', outer)
    local leaf  = g_ui.createWidget('Label', inner)
    local visLog = {}
    inner.onVisibilityChange = function(w, v) visLog[#visLog + 1] = 'inner:' .. tostring(v) end
    leaf.onVisibilityChange  = function(w, v) visLog[#visLog + 1] = 'leaf:' .. tostring(v) end
    eq(leaf:isVisible(), true, 'visibility: everything starts visible')
    outer:hide()
    eq(leaf:isVisible(), false, 'visibility: an ancestor hide makes descendants invisible')
    eq(inner:isExplicitlyVisible(), true, 'visibility: EXPLICIT visibility is untouched')
    -- uiwidget.cpp:1804-1817 updates the CHILDREN first and only then calls setState,
    -- which is what fires the signal: the deepest descendant signals first.
    eq(table.concat(visLog, ','), 'leaf:false,inner:false',
       'visibility: onVisibilityChange fires deepest-first on every descendant')
    outer:show()
    eq(leaf:isVisible(), true, 'visibility: show restores the subtree')

    -- ---- signals stored, never fired --------------------------------------
    local clicked = 0
    local btn = g_ui.createWidget('Button', p)
    btn.onClick = function() clicked = clicked + 1 end
    eq(clicked, 0, 'onClick is never fired by the shim')
    btn:onClick()
    eq(clicked, 1, 'onClick is CALLABLE by hand (functions/config.lua:241 needs this)')

    -- ---- connect()-shaped signal arrays -----------------------------------
    local okc, corelib = pcall(require, 'shim.corelib')
    if okc then
        local hits = {}
        local L4 = g_ui.createWidget('UIWidget', root)
        local m1 = g_ui.createWidget('FocusableLabel', L4)
        local m2 = g_ui.createWidget('FocusableLabel', L4)
        corelib.connect(L4, { onChildFocusChange = function() hits[#hits + 1] = 'a' end })
        corelib.connect(L4, { onChildFocusChange = function() hits[#hits + 1] = 'b' end })
        eq(type(L4.onChildFocusChange), 'table', 'connect() promotes the field to an array')
        L4:focusChild(m1)
        eq(table.concat(hits, ','), 'a,b',
           'a connect()-built signal array is dispatched signalcall-shaped '
           .. '(cavebot/stand_lure.lua:167)')
    else
        skip('shim/corelib.lua not loadable; connect() dispatch not checked')
    end

    -- ---- getWidth()/getHeight() are 0 ON PURPOSE (Q10) ---------------------
    eq(p:getWidth(), 0, 'Q10 getWidth() is 0 so ui_elements width clamps are skipped')
    eq(p:getLayout(), nil, 'Q10 getLayout() is nil (bot.lua:159 null-checks it)')
    eq(p:getHeight(), 0, 'Q10 getHeight() is 0')
    eq(p:getSize().width, 0, 'Q10 getSize() is a real table of zeros')
    eq(p:getRect().width, 0, 'Q10 getRect() is a real table of zeros')

    -- ---- every BLOCKER is a LOUD, RECORDED no-op ---------------------------
    widget.resetRecord()
    local blockers = {
        'recursiveGetChildByPos', 'getChildByPos', 'containsPoint', 'getTextSize',
        'ensureChildVisible', 'raise', 'setMarked', 'setImageSource', 'setFont',
    }
    for _, name in ipairs(blockers) do p[name](p) end
    local menu = g_ui.createWidget('PopupMenu')
    menu:addOption('x', function() end)
    menu:display({ x = 0, y = 0 })
    local graph = g_ui.createWidget('UIGraph', root)
    graph:createGraph(); graph:addValue(1); graph:setTitle('t')
    local recorded = 0
    for _ in pairs(widget.record) do recorded = recorded + 1 end
    eq(recorded >= #blockers + 3, true,
       'every BLOCKER / inert call is counted in widget.record (' .. recorded .. ' names)')
    eq(widget.record['UIPopupMenu:display'] ~= nil, true,
       'PopupMenu:display is a recorded no-op (api-ui.md sec.8.1)')
    eq(widget.record['recursiveGetChildByPos'] ~= nil, true,
       'recursiveGetChildByPos is a recorded no-op -- it needs real rectangles')
    eq(widget.record['UIGraph:addValue'] ~= nil, true,
       'UIGraph rendering is a recorded no-op')
    eq(p:recursiveGetChildByPos({ x = 1, y = 1 }), nil,
       'a BLOCKER returns nil rather than a plausible-looking lie')
    eq(#widget.report() >= 1, true, 'widget.report() lists them for the run summary')

    -- setStyle re-applies a REGISTERED style rather than pretending
    h.g_ui.importStyleFromString('OnByStyle < UIWidget\n  on: true\n  text: styled\n', '(C-style)')
    local st = g_ui.createWidget('UIWidget', root)
    eq(st:isOn(), false, 'setStyle: before')
    st:setStyle('OnByStyle')
    eq(st:isOn(), true, 'setStyle applies the registered style for real')
    eq(st:getText(), 'styled', 'setStyle applies its text too')
    st:setStyle('NoSuchStyleAtAll')
    eq(widget.record['setStyle(undefined)'] ~= nil, true,
       'setStyle on an undefined style is RECORDED, not silently ignored')
end

-- ===========================================================================
section('D  destruction')
-- ===========================================================================
do
    local h = newUI()
    local g_ui = h.g_ui
    local p = g_ui.createWidget('Panel', g_ui.getRootWidget())
    local a = g_ui.createWidget('Label', p); a:setId('alpha')
    local b = g_ui.createWidget('Label', p); b:setId('beta')
    local sub = g_ui.createWidget('Panel', b)
    eq(p:getChildCount(), 2, 'D setup')

    a:destroy()
    eq(a:isDestroyed(), true, 'D the widget is marked destroyed')
    eq(p:getChildCount(), 1, 'D it is gone from the child array')
    eq(p:getChildById('alpha'), nil, 'D it is gone from childrenById')
    eq(p.alpha, nil, 'D the parent Lua field is cleared')
    eq(a:getParent(), nil, 'D it is unparented')
    eq(p:getChildIndex(b), 1, 'D the surviving siblings are reindexed')
    local found = false
    for _, c in ipairs(p:getChildren()) do if c == a then found = true end end
    eq(found, false, 'D getChildren() no longer lists it')

    b:destroy()
    eq(sub:isDestroyed(), true, 'D destroying a widget destroys its subtree')
    eq(p:getChildCount(), 0, 'D the parent is empty')

    -- onDestroy order: uiwidget.cpp:2020-2055 tears the children down first, so the
    -- deepest onDestroy fires before its ancestors' (UITabBar:addTab relies on being
    -- able to touch tab.tabPanel from its own onDestroy).
    local order = {}
    local d1 = g_ui.createWidget('Panel', p)
    local d2 = g_ui.createWidget('Panel', d1)
    local d3 = g_ui.createWidget('Label', d2)
    d1.onDestroy = function() order[#order + 1] = 'd1' end
    d2.onDestroy = function() order[#order + 1] = 'd2' end
    d3.onDestroy = function() order[#order + 1] = 'd3' end
    d1:destroy()
    eq(table.concat(order, ','), 'd3,d2,d1', 'D onDestroy fires deepest-first')
    eq(d3:isVisible(), false, 'D a destroyed widget is forced invisible')
    eq(d2:getParent(), nil, 'D the whole subtree is unparented')

    -- a destroyed widget fires nothing further
    local after = 0
    d2.onTextChange = function() after = after + 1 end
    d2:setText('x')
    eq(after, 0, 'D a destroyed widget fires no more signals')

    -- destroyChildren
    local q = g_ui.createWidget('Panel', g_ui.getRootWidget())
    local c1 = g_ui.createWidget('Label', q); c1:setId('one')
    local c2 = g_ui.createWidget('Label', q)
    q:destroyChildren()
    eq(q:getChildCount(), 0, 'D destroyChildren empties the list')
    eq(q:getFocusedChild(), nil, 'D destroyChildren clears the focus')
    eq(q.one, nil, 'D destroyChildren clears the parent Lua fields')
    eq(c1:isDestroyed() and c2:isDestroyed(), true, 'D destroyChildren destroys each child')
end

-- ===========================================================================
section('E  the real vBot widget trees')
-- ===========================================================================
if not PROFILE then
    skip('otclient tree not found -- sections E, F, G, H need '
         .. 'D:/Claude/otclient_mehah1530/otclient (read-only)')
else
    local resources = require('shim.resources').new(OTROOT .. '/profiles/')
    local h = newUI{ resources = resources }
    local g_ui, ENV = h.g_ui, h.ENV
    eq(g_ui.importBaseStyles(OTROOT) >= 20, true,
       'E the real data/styles + mods/game_bot/ui .otui files import')

    -- every .otui in the user's live profile, in the sorted order _Loader/executor use
    local otuis = resources.listDirectoryFiles('/bot/vBot_4.8', true, false, true)
    local n = 0
    for _, f in ipairs(otuis) do
        if f:lower():sub(-5) == '.otui' then
            if g_ui.importStyle(f) then n = n + 1 end
        end
    end
    eq(n >= 20, true, 'E the profile .otui files import (' .. n .. ' files)')
    eq(#h.styles.failed, 0, 'E no style was skipped for an undefined base')
    ENV.setupUI = function(otml, parent)
        return g_ui.loadUIFromString(otml, parent or g_ui.getRootWidget())
    end

    -- ------------------------------------------------- E1 HealBot -----------
    do
        local panelSrc = [[
Panel
  height: 38
  BotSwitch
    id: title
    !text: tr('HealBot')
  Button
    id: settings
    text: Setup
  Button
    id: 1
    text: 1
  Button
    id: 2
    text: 2
  Button
    id: 3
    text: 3
  Button
    id: 4
    text: 4
  Button
    id: 5
    text: 5
  Label
    id: name
    text: Profile #1
]]
        local ui = ENV.setupUI(panelSrc)
        check(ui ~= nil, 'E1 HealBot side panel built by setupUI')
        ui:setId('healbot')
        eq(ui.title:getText(), 'HealBot', 'E1 !text: tr(...) evaluated at style time')
        -- HealBot.lua:290-300 -- ui[i] with a NUMBER
        local allNumeric = true
        for i = 1, 5 do
            if ui[i] == nil then allNumeric = false end
        end
        eq(allNumeric, true, 'E1 ui[1]..ui[5] resolve with numeric keys (HealBot.lua:292)')
        for i = 1, 5 do ui[i]:setColor(i == 1 and 'green' or 'white') end
        eq(ui[1]:getColor(), 'green', 'E1 setColor round-trips (display only, but stateful)')
        ui.title:setOn(true)
        eq(ui.title:isOn(), true, 'E1 ui.title:setOn / isOn -- the enabled mirror')

        local win = g_ui.createWidget('HealWindow', g_ui.getRootWidget())
        check(win ~= nil, 'E1 HealWindow created from the real HealBot.otui')
        if win then
            win:hide()
            eq(win:isVisible(), false, 'E1 healWindow:hide()')
            check(win.healer ~= nil, 'E1 healWindow.healer resolves by id')
            check(win.settings ~= nil, 'E1 healWindow.settings resolves by id')
            check(win.settingsButton ~= nil, 'E1 healWindow.settingsButton resolves by id')
            local spells = win.healer and win.healer.spells
            check(spells ~= nil and spells.spellList ~= nil,
                  'E1 healWindow.healer.spells.spellList -- the nested id path vBot uses')
            -- HealBot.lua:337-346 settingsButton behaviour, read back with isVisible
            win.healer:show(); win.settings:hide()
            eq(win.healer:isVisible(), false,
               'E1 a child of a hidden window is not effectively visible')
            win:show()
            eq(win.healer:isVisible(), true, 'E1 ... and becomes visible with the window')
            eq(win.settings:isVisible(), false, 'E1 ... while an explicitly hidden one stays hidden')
            -- the @onSetup ComboBoxes
            local src = win.healer and win.healer.spells and win.healer.spells.spellSource
            if src == nil then
                -- find any SpellSourceBox in the tree
                src = win:recursiveGetChildById('itemSource')
            end
            if src and src.getCurrentOption then
                eq(src:getCurrentOption() ~= nil, true,
                   'E1 a @onSetup ComboBox has a current option at load (api-ui.md sec.2)')
            else
                skip('E1 no SpellSourceBox instance found to check @onSetup')
            end
            -- the spell list as a data structure
            local list = spells and spells.spellList
            if list then
                for i = 1, 3 do
                    local e = g_ui.createWidget('SpellEntry', list)
                    e:setText('spell ' .. i)
                    e.params = { n = i }
                end
                eq(list:getChildCount(), 3, 'E1 spellList children')
                eq(list:getChildByIndex(2).params.n, 2,
                   'E1 arbitrary Lua fields ride on list children')
                list:getChildByIndex(2):destroy()
                eq(list:getChildCount(), 2, 'E1 HealBot.lua:388 label:destroy() removes it')
                eq(list:getChildByIndex(2):getText(), 'spell 3', 'E1 ... and reindexes')
            end
        end
    end

    -- ------------------------------------------------ E2 AttackBot ----------
    do
        local win = g_ui.createWidget('AttackBotWindow', g_ui.getRootWidget())
        check(win ~= nil, 'E2 AttackBotWindow created from the real AttackBot.otui')
        if win then
            local entryList = win:recursiveGetChildById('entryList')
            check(entryList ~= nil, 'E2 entryList found by recursiveGetChildById')
            if entryList then
                -- AttackBot.lua:2210-2221 refreshAttacks
                local rows = {}
                for i = 1, 4 do
                    local label = g_ui.createWidget('AttackEntry', entryList)
                    label.params = { name = 'atk' .. i, enabled = (i % 2 == 1) }
                    rows[i] = label
                end
                eq(entryList:getChildCount(), 4, 'E2 the attack list holds its rows')
                -- AttackBot.lua:2783 -- the attack loop iterates the WIDGET list
                local names = {}
                for _, child in ipairs(entryList:getChildren()) do
                    names[#names + 1] = child.params.name
                end
                eq(table.concat(names, ','), 'atk1,atk2,atk3,atk4',
                   'E2 ordering IS the attack priority')
                entryList:moveChildToIndex(rows[4], 1)
                names = {}
                for _, child in ipairs(entryList:getChildren()) do
                    names[#names + 1] = child.params.name
                end
                eq(table.concat(names, ','), 'atk4,atk1,atk2,atk3',
                   'E2 moveChildToIndex reorders the priority (the Move Up button)')
                -- the enabled CheckBox hung inside each AttackEntry
                local chk = rows[1]:getChildById('enabled')
                if chk then
                    chk:setChecked(true)
                    eq(chk:isChecked(), true, 'E2 AttackEntry.enabled checkbox round-trips')
                else
                    skip('E2 AttackEntry has no `enabled` child in this profile')
                end
            end
            -- settings checkboxes are read back at AttackBot.lua:2056,2130,2239
            local settings = win:recursiveGetChildById('Rotate')
            if settings then
                settings:setChecked(true)
                eq(settings:isChecked(), true, 'E2 settingsUI.Rotate:isChecked round-trips')
            else
                skip('E2 no Rotate checkbox in this profile')
            end
        end
    end

    -- --------------------------------------- E3 the REAL cavebot/config.lua --
    do
        local sandbox = setmetatable({}, { __index = ENV })
        local saves = 0
        sandbox.CaveBot = { save = function() saves = saves + 1 end }
        sandbox.warn = function(t) end
        sandbox.tr = ENV.tr
        sandbox.g_ui = g_ui
        sandbox.UI = {
            createWidget = function(name, parent)
                local w = g_ui.createWidget(name, parent or g_ui.getRootWidget())
                if w then w.botWidget = true end
                return w
            end,
            createWindow = function(name)
                local w = g_ui.createWidget(name, g_ui.getRootWidget())
                if w then w.botWidget = true; w:show(); w:raise(); w:focus() end
                return w
            end,
        }
        local src = resources.readFileContents('/bot/vBot_4.8/cavebot/config.lua')
        local chunk, err = loadstring(src, '@cavebot/config.lua')
        if not chunk then
            check(false, 'E3 cavebot/config.lua compiles', err)
        else
            if setfenv then setfenv(chunk, sandbox) end
            local ok, e = pcall(chunk)
            check(ok, 'E3 cavebot/config.lua loads unmodified', e)
            if ok then
                local ok2, e2 = pcall(sandbox.CaveBot.Config.setup)
                check(ok2, 'E3 CaveBot.Config.setup() runs on the shim widget model', e2)
                if ok2 then
                    local C = sandbox.CaveBot.Config
                    eq(C.get('ping'), 100, 'E3 a NUMBER row: default value')
                    eq(C.ui.ping.value:getText(), '100',
                       'E3 ... mirrored into the widget with setText(v, true)')
                    eq(C.get('mapClick'), false, 'E3 a BOOLEAN row: default value')
                    eq(C.ui.mapClick.value:isOn(), false, 'E3 ... mirrored with setOn(v, true)')
                    eq(C.get('antiLostRopeToolId'), 3003,
                       'E3 an ITEM row: { item = id } becomes a plain number')
                    eq(C.ui.antiLostRopeToolId.value:getItemId(), 3003,
                       'E3 ... and the BotItem carries the id')
                    eq(C.get('antiLostTeleportIds'), '1949,1950,1951,1952',
                       'E3 a STRING row: default value')

                    -- setup() must not have triggered CaveBot.save() -- config.lua's
                    -- `applyingItem` guard and the setText/setOn `true` flags exist
                    -- exactly to prevent that (setup runs before CaveBot.save exists).
                    eq(saves, 0, 'E3 building the rows fires no CaveBot.save() recursion')

                    -- the read-back path CaveBot actually uses
                    C.set('walkDelay', 55)
                    eq(C.get('walkDelay'), 55, 'E3 CaveBot.Config.set -> get')
                    eq(C.ui.walkDelay.value:getText(), '55', 'E3 ... and the widget follows')
                    eq(saves, 1, 'E3 an explicit set() DOES save')

                    -- the user-driven path: onTextChange is what a typed value hits
                    C.ui.ping.value:setText('250')
                    eq(C.get('ping'), 250,
                       'E3 the row onTextChange handler writes the value table (real logic)')

                    C.ui.mapClick.value:onClick(C.ui.mapClick.value)
                    eq(C.get('mapClick'), true,
                       'E3 the boolean row onClick handler toggles (soft blocker, called by hand)')

                    -- the item row: setItemId always fires, so the guard must hold
                    local before = saves
                    C.value_setters.antiLostRopeToolId(3003)
                    eq(saves, before,
                       'E3 the applyingItem guard suppresses the save on a programmatic set')
                    C.ui.antiLostRopeToolId.value:setItemId(3004)
                    eq(C.get('antiLostRopeToolId'), 3004,
                       'E3 a real onItemChange DOES write through')

                    eq(C.isVisible(), false, 'E3 the config window starts hidden')
                    C.show()
                    eq(C.isVisible(), true, 'E3 CaveBot.Config.show()')
                    C.hide()
                    eq(C.isVisible(), false, 'E3 CaveBot.Config.hide()')
                end
            end
        end
    end

    -- ------------------------------------------------ E4 TargetBot ----------
    do
        local panel = g_ui.createWidget('TargetBotPanel', g_ui.getRootWidget())
        check(panel ~= nil, 'E4 TargetBotPanel created from the real target.otui')
        if panel then
            -- target.lua:194 reads ui.status.right:getText() BACK
            check(panel.status ~= nil and panel.status.right ~= nil,
                  'E4 ui.status.right resolves')
            panel.status.right:setText('On')
            eq(panel.status.right:getText(), 'On',
               'E4 TargetBot.getStatus() reads its own setText back (target.lua:194)')
            eq(panel.target ~= nil and panel.config ~= nil and panel.danger ~= nil, true,
               'E4 the four TargetBotDualLabel rows all resolve by id')

            local list = panel.listPanel and panel.listPanel.list
            check(list ~= nil, 'E4 ui.listPanel.list -- the TargetBot creature list')
            if list then
                eq(list:getAutoFocusPolicy(), 'first',
                   'E4 the creature list overrides TextList auto-focus to `first`')
                -- creature.lua:15-51 addConfig
                local cfgs = { { name = 'Rat', regex = '^rat$' }, { name = 'Cave Rat' } }
                for _, cfg in ipairs(cfgs) do
                    local e = g_ui.createWidget('TargetBotEntry', list)
                    e:setText(cfg.name)
                    e.value = cfg
                end
                -- creature.lua:53-72 getConfigs -- the per-tick hot path
                local got = {}
                for _, child in ipairs(list:getChildren()) do got[#got + 1] = child.value.name end
                eq(table.concat(got, ','), 'Rat,Cave Rat',
                   'E4 getConfigs iterates the widget list and reads child.value')
                eq(list:getFocusedChild(), list:getChildByIndex(1),
                   'E4 auto-focus: first focused entry #1')
                -- creature.lua:5-8 resetConfigs
                list:destroyChildren()
                eq(list:getChildCount(), 0, 'E4 resetConfigs = destroyChildren')
            end
        end

        -- vBot/supplies.lua:211-216 is the ONE place vBot reads a number back out of
        -- the widget tree instead of a config table (api-ui.md sec.5.7), so those
        -- widgets have to be genuinely stateful.
        local sw = g_ui.createWidget('SuppliesWindow', g_ui.getRootWidget())
        check(sw ~= nil, 'E4 SuppliesWindow from the real supplies.otui')
        if sw then
            local items = sw:recursiveGetChildById('items')
            check(items ~= nil, 'E4 SuppliesWindow.items')
            if items then
                local panel = g_ui.createWidget('ItemPanel', items)
                panel.id:setItemId(3031)
                panel.min:setText(10)
                panel.max:setText(200)
                panel.avg:setText(25)
                eq(panel.id:getItemId(), 3031, 'E4 supplies: panel.id:getItemId() reads back')
                eq(panel.min:getValue(), 10, 'E4 supplies: panel.min:getValue() reads back')
                eq(panel.max:getValue(), 200, 'E4 supplies: panel.max:getValue() reads back')
                eq(panel.avg:getValue(), 25, 'E4 supplies: panel.avg:getValue() reads back')
                -- supplies.lua:363-367 does arithmetic on those values and writes back
                panel.max:setText(panel.max:getValue() + panel.avg:getValue())
                eq(panel.max:getValue(), 225, 'E4 supplies: the increment button arithmetic')
            end
        end

        -- looting.lua: the BotContainer item grid IS the source of truth
        local loot = g_ui.createWidget('BotContainer', g_ui.getRootWidget())
        check(loot ~= nil and loot.items ~= nil, 'E4 BotContainer has an `items` scroll panel')
        if loot and loot.items then
            for i = 1, 4 do g_ui.createWidget('BotItem', loot.items) end
            loot.items:getChildByIndex(1):setItemId(3031)
            loot.items:getChildByIndex(2):setItemId(3035)
            local ids = {}
            for _, c in ipairs(loot.items:getChildren()) do
                if c:getItemId() >= 100 then ids[#ids + 1] = c:getItemId() end
            end
            eq(table.concat(ids, ','), '3031,3035',
               'E4 the `getItemId() >= 100` filter in ui_elements.lua:86 works')
        end
    end
end

-- ===========================================================================
section('F  the CaveBot waypoint list as the program counter')
-- ===========================================================================
if not PROFILE then
    skip('otclient tree not found')
else
    local resources = require('shim.resources').new(OTROOT .. '/profiles/')
    local h = newUI{ resources = resources }
    local g_ui = h.g_ui
    g_ui.importBaseStyles(OTROOT)
    g_ui.importStyle('/bot/vBot_4.8/cavebot/cavebot.otui')

    local panel = g_ui.createWidget('CaveBotPanel', g_ui.getRootWidget())
    check(panel ~= nil, 'F CaveBotPanel from the real cavebot.otui')
    if panel then
        local list = panel.listPanel and panel.listPanel.list
        check(list ~= nil, 'F CaveBot.actionList = ui.listPanel.list')
        if list then
            -- actions.lua:185-227 addAction
            local wps = {
                { action = 'goto', value = '100,100,7' },
                { action = 'label', value = 'start' },
                { action = 'goto', value = '101,100,7' },
                { action = 'use',  value = '102,100,7' },
            }
            for _, wp in ipairs(wps) do
                local w = g_ui.createWidget('CaveBotAction', list)
                w:setText(wp.action .. ':' .. wp.value)
                w.action, w.value, w.stayPos = wp.action, wp.value, nil
            end
            eq(list:getChildCount(), 4, 'F four waypoints')
            eq(list:getFocusedChild(), list:getChildByIndex(1),
               'F auto-focus: first put the program counter on waypoint 1')

            -- cavebot.lua:80-203: advance = focusChild(getChildByIndex(index+1))
            local function advance()
                local cur = list:getFocusedChild()
                local idx = cur and list:getChildIndex(cur) or 0
                local nxt = idx + 1
                if nxt > list:getChildCount() then nxt = 1 end
                list:focusChild(list:getChildByIndex(nxt))
                return list:getFocusedChild()
            end
            eq(advance():getText(), 'label:start', 'F advance -> waypoint 2')
            eq(advance():getText(), 'goto:101,100,7', 'F advance -> waypoint 3')
            eq(advance():getText(), 'use:102,100,7', 'F advance -> waypoint 4')
            eq(advance():getText(), 'goto:100,100,7', 'F advance wraps to waypoint 1')

            -- cavebot.lua:214: getChildIndex(nil) when getFocusedChild() is nil
            list:focusChild(nil)
            eq(list:getFocusedChild(), nil, 'F focusChild(nil) clears the program counter')
            eq(list:getChildIndex(), list:getParent():getChildIndex(list),
               'F getChildIndex(nil) still answers with the list OWN index')

            -- cavebot.lua:578-610 CaveBot.save serialises by iterating the widgets
            local ser = {}
            for _, child in ipairs(list:getChildren()) do
                ser[#ser + 1] = child.action .. ':' .. child.value
            end
            eq(table.concat(ser, '|'),
               'goto:100,100,7|label:start|goto:101,100,7|use:102,100,7',
               'F CaveBot.save() round-trips the list through child.action/.value')

            -- string.starts(text, "goto:") matching (cavebot.lua:352-401)
            local gotos = 0
            for _, child in ipairs(list:getChildren()) do
                if child:getText():sub(1, 5) == 'goto:' then gotos = gotos + 1 end
            end
            eq(gotos, 2, 'F waypoints are also matched by their TEXT')

            -- a destroyed waypoint must not leave the list pointing at a dead widget
            list:focusChild(list:getChildByIndex(2))
            list:getChildByIndex(2):destroy()
            local f = list:getFocusedChild()
            eq(f ~= nil and not f:isDestroyed(), true,
               'F the list never points at a destroyed waypoint')
        end
    end
end

-- ===========================================================================
section('G  the REAL mods/game_bot/functions/ui*.lua on this widget model')
-- ===========================================================================
local helperReport = {}
if not PROFILE then
    skip('otclient tree not found')
else
    local resources = require('shim.resources').new(OTROOT .. '/profiles/')
    local h = newUI{ resources = resources }
    local g_ui, ENV = h.g_ui, h.ENV
    g_ui.importBaseStyles(OTROOT)
    local otuis = resources.listDirectoryFiles('/bot/vBot_4.8', true, false, true)
    for _, f in ipairs(otuis) do
        if f:lower():sub(-5) == '.otui' then g_ui.importStyle(f) end
    end

    local context = { configDir = '/bot/vBot_4.8' }
    local inst = helpers.install(ENV, context, { otRoot = OTROOT, g_ui = g_ui })
    eq(inst.mode, 'real', 'G the four helper files were loaded FROM THE TREE, not reimplemented')
    eq(#inst.loaded, 4, 'G all four loaded: ' .. table.concat(inst.loaded, ', '))
    for _, f in ipairs(inst.failed) do check(false, 'G ' .. f.file .. ' loaded', f.err) end
    eq(#inst.patched, 1, 'G exactly one audited source patch applied: '
       .. table.concat(inst.patched, '; '))

    local UI = context.UI
    check(type(UI) == 'table', 'G context.UI exists')

    local function try(name, fn)
        local ok, err = pcall(fn)
        helperReport[#helperReport + 1] = { name = name, ok = ok, err = err }
        check(ok, 'G ' .. name, err)
        return ok
    end

    if type(UI) == 'table' then
        try('UI.createWidget', function()
            local w = UI.createWidget('BotLabel')
            assert(w and w.botWidget == true, 'botWidget flag not set')
            assert(w:getParent() == context.panel, 'not parented to context.panel')
        end)
        try('UI.Label', function()
            local w = UI.Label('hello')
            assert(w:getText() == 'hello', 'text not stored')
        end)
        try('UI.Button', function()
            local hits = 0
            local w = UI.Button('go', function() hits = hits + 1 end)
            assert(w:getText() == 'go')
            w:onClick()                       -- soft blocker: callable by hand
            assert(hits == 1, 'onClick not stored')
        end)
        try('UI.Separator', function()
            local w = UI.Separator()
            assert(w ~= nil and w:getParent() == context.panel)
        end)
        try('UI.TextEdit', function()
            local seen
            local w = UI.TextEdit('abc', function(_, t) seen = t end)
            assert(w:getText() == 'abc', 'text not stored')
            assert(seen == 'abc', 'the construction-time onTextChange did not fire')
        end)
        try('UI.DualLabel', function()
            local w = UI.DualLabel('left', 'right')
            assert(w.left:getText() == 'left' and w.right:getText() == 'right')
        end)
        try('UI.LabelAndTextEdit', function()
            local p = { left = 'hotkey', right = 'F5' }
            local w = UI.LabelAndTextEdit(p, function() end)
            assert(w.right:getText() == 'F5')
            w.right:setText('F6')
            assert(p.right == 'F6', 'the onTextChange write-back did not happen')
        end)
        try('UI.SwitchAndButton', function()
            local p = { on = false, left = 'a', right = 'b' }
            local fired = 0
            local w = UI.SwitchAndButton(p, function() fired = fired + 1 end, nil, nil)
            w.left:onClick()
            assert(p.on == true, 'the switch did not toggle params.on')
            assert(w.left:isOn() == true, 'the switch widget did not follow')
            assert(fired == 1, 'callbackSwitch not called')
        end)
        try('UI.Config', function()
            local w = UI.Config()
            assert(w.list and w.switch and w.add and w.edit and w.remove,
                   'BotConfig is missing one of list/switch/add/edit/remove')
            w.switch:setOn(true)
            assert(w.switch:isOn() == true, 'switch:isOn is the CaveBot on/off truth')
            w.list:addOption('cfgA'); w.list:addOption('cfgB')
            assert(w.list:getCurrentOption().text == 'cfgA', 'the first option must auto-select')
            w.list:setCurrentIndex(2)
            assert(w.list:getCurrentOption().text == 'cfgB', 'setCurrentIndex')
        end)
        try('UI.Container', function()
            local seen
            local w = UI.Container(function(_, items) seen = items end, false)
            assert(w.items ~= nil, 'BotContainer has no items panel')
            assert(w.items:getChildCount() == 10,
                   'setItems({}) must build math.max(10, 0+2) rounded up to 10 slots, got '
                   .. w.items:getChildCount())
            w:setItems({ { id = 3031, count = 100 }, { id = 3035, count = 1 } })
            local got = w:getItems()
            assert(#got == 2, 'getItems returned ' .. #got .. ' entries')
            assert(got[1].id == 3031 and got[2].id == 3035, 'getItems ids')
            -- the onItemChange -> updateItems -> callback chain
            w.items:getChildByIndex(3):setItemId(3043)
            assert(seen ~= nil and #seen == 3,
                   'the onItemChange callback did not report the new item')
        end)
        try('UI.Container unique', function()
            local w = UI.Container(function() end, true)
            w:setItems({ { id = 3031, count = 1 }, { id = 3031, count = 5 } })
            assert(#w:getItems() == 1, 'unique=true must de-duplicate')
        end)
        try('UI.DualScrollPanel', function()
            local p = { on = false, title = 'hp', min = 20, max = 80 }
            local changed = 0
            UI.DualScrollPanel(p, function(_, np) changed = changed + 1 end)
            -- the helper returns nothing; the assertion is that it does not raise and
            -- that update(true) formatted the title without signalling
            assert(changed == 0, 'update(true) must not call the callback')
        end)
        try('UI.DualScrollItemPanel', function()
            UI.DualScrollItemPanel({ on = true, item = 3031, min = 10, max = 90 }, function() end)
        end)
        try('UI.TwoItemsAndSlotPanel', function()
            local p = { on = false, title = 't', item1 = 3031, item2 = 3035, slot = 2 }
            local w = UI.TwoItemsAndSlotPanel(p, function() end)
            assert(w.item1:getItemId() == 3031 and w.item2:getItemId() == 3035)
            assert(w.slot:getCurrentOption().text == 'Neck',
                   'setCurrentIndex(2) on a SlotComboBox should select Neck, got '
                   .. tostring(w.slot:getCurrentOption() and w.slot:getCurrentOption().text))
        end)
        try('UI.createWindow', function()
            local w = UI.createWindow('CaveBotConfigWindow')
            assert(w ~= nil and w.botWidget == true)
            assert(w:getParent() == g_ui.getRootWidget(), 'window not parented to root')
        end)
        try('UI.createMiniWindow', function()
            local w = UI.createMiniWindow('MiniWindow')
            assert(w ~= nil and w.botWidget == true)
        end)
        try('UI.EditorWindow (BLOCKER)', function()
            local w = UI.SinglelineEditorWindow('x', { title = 't' }, function() end)
            assert(w ~= nil and w.botWidget == true,
                   'must return a widget so `window.botWidget = true` cannot error')
        end)
        try('UI.ConfirmationWindow (BLOCKER)', function()
            local w = UI.ConfirmationWindow('t', 'q?', function() end)
            assert(w ~= nil and w.botWidget == true)
        end)
    end

    -- ui_legacy.lua
    try('context.setDefaultTab / addTab / getTab', function()
        context.setDefaultTab('HP')
        local hp = context.panel
        assert(hp ~= nil, 'context.panel not assigned')
        context.setDefaultTab('Tools')
        assert(context.panel ~= hp, 'a second tab must give a different panel')
        context.setDefaultTab('HP')
        assert(context.panel == hp, 'getTab must return the SAME panel for an existing tab')
        assert(#context.tabs.tabs == 3, 'Main + HP + Tools; got ' .. #context.tabs.tabs)
    end)
    try('context.addSwitch (the macro switch)', function()
        local hits = 0
        local sw = context.addSwitch('macro_0', 'Test [F5]', function(w) hits = hits + 1 end)
        assert(sw:getId() == 'macro_0' and sw:getText() == 'Test [F5]')
        sw:setOn(true); assert(sw:isOn() == true, 'setOn/isOn is storage._macros mirror')
        sw:onClick(sw); assert(hits == 1)
    end)
    try('context.addButton/addLabel/addTextEdit/addSeparator', function()
        assert(context.addButton('b', 'B', function() end):getId() == 'b')
        assert(context.addLabel('l', 'L'):getText() == 'L')
        local te = context.addTextEdit('t', 'T', function() end)
        assert(te:getText() == 'T')
        assert(context.addSeparator('s'):getId() == 's')
    end)
    try('context.setupUI', function()
        local w = context.setupUI('Panel\n  Label\n    id: x\n    text: hi\n')
        assert(w ~= nil and w.x:getText() == 'hi')
        assert(w.botWidget == true)
    end)
    try('context.importStyle', function()
        assert(context.importStyle('MyInlineStyle < UIWidget\n  on: true\n') ~= false)
        assert(g_ui.getStyle('MyInlineStyle') ~= nil)
        context.importStyle('cavebot/cavebot.otui')     -- the path branch
        assert(g_ui.getStyle('CaveBotAction') ~= nil)
    end)
    try('context._addMacroSwitch', function()
        context.storage._macros['Test'] = true
        local sw = context._addMacroSwitch('Test', 'F5')
        assert(sw:isOn() == true, 'the switch must mirror storage._macros[name]')
        sw:onClick(sw)
        assert(context.storage._macros['Test'] == false, 'the handler must flip storage')
        assert(sw:isOn() == false, 'and the widget must follow')
    end)
end

-- ===========================================================================
section('H  all 24 UI.createWindow styles instantiate')
-- ===========================================================================
if not PROFILE then
    skip('otclient tree not found')
else
    local resources = require('shim.resources').new(OTROOT .. '/profiles/')
    local h = newUI{ resources = resources }
    local g_ui = h.g_ui
    g_ui.importBaseStyles(OTROOT)
    local otuis = resources.listDirectoryFiles('/bot/vBot_4.8', true, false, true)
    for _, f in ipairs(otuis) do
        if f:lower():sub(-5) == '.otui' then g_ui.importStyle(f) end
    end

    -- `TrainingWindow` and `ContListsWindow` are NOT declared in any .otui: vBot
    -- declares them inline with g_ui.loadUIFromString([[...]]) at the top of
    -- vBot/training.lua and vBot/Containers.lua.  Feed those literal blocks through
    -- the same entry point the scripts use, and the styles must appear.
    local inlineOk = 0
    for _, rel in ipairs({ '/bot/vBot_4.8/vBot/training.lua',
                           '/bot/vBot_4.8/vBot/Containers.lua' }) do
        local src = resources.readFileContents(rel)
        local pos = 1
        while true do
            local s = src:find('loadUIFromString%s*%(%s*%[%[', pos)
            if not s then break end
            local open = src:find('%[%[', s)
            local close = src:find('%]%]', open)
            if not close then break end
            g_ui.loadUIFromString(src:sub(open + 2, close - 1), nil, rel)
            pos = close + 2
            inlineOk = inlineOk + 1
        end
    end
    eq(inlineOk >= 2, true, 'H the inline loadUIFromString style blocks parsed ('
       .. inlineOk .. ' blocks)')

    local WINDOWS = {
        'NaviBotWindow', 'FeaturesWindow', 'ConditionsWindow', 'ComboWindow',
        'BotServerWindow', 'DepositerPanel', 'ContListsWindow', 'AttackBotWindow',
        'AttackBotSpellPicker', 'AlarmsWindow', 'TargetBotCreatureEditorWindow',
        'EquipWindow', 'CaveBotConfigWindow', 'HealWindow', 'ExtrasWindow',
        'ImbuingConfigWindow', 'FriendHealer', 'VocationThresholdWindow',
        'PushMaxWindow', 'PlayerListWindow', 'SioListWindow', 'StancesWindow',
        'SuppliesWindow', 'TrainingWindow',
    }
    local root = g_ui.getRootWidget()
    local made, missing = 0, {}
    for _, name in ipairs(WINDOWS) do
        local w = g_ui.createWidget(name, root)
        if w then made = made + 1 else missing[#missing + 1] = name end
    end
    eq(made, #WINDOWS, 'H every UI.createWindow style instantiates'
       .. (#missing > 0 and (' (missing: ' .. table.concat(missing, ', ') .. ')') or ''))

    -- the panel styles every vBot file parents into
    local PANELS = { 'CaveBotPanel', 'TargetBotPanel', 'BotPanel', 'BotConfig',
                     'BotContainer', 'DualLabelPanel' }
    local pm = 0
    for _, name in ipairs(PANELS) do if g_ui.createWidget(name, root) then pm = pm + 1 end end
    eq(pm, #PANELS, 'H every helper panel style instantiates')

    -- `styles.order` counts every register() call, so a redefinition appears twice and
    -- the raw count is import-order dependent; the DISTINCT set is what must match.
    local distinct, ndistinct = {}, 0
    for _, n in ipairs(h.styles.order) do
        if not distinct[n] then distinct[n] = true; ndistinct = ndistinct + 1 end
    end
    io.write(string.format('    (%d distinct styles from %d files; %d skipped)\n',
                           ndistinct, #h.styles.files, #h.styles.failed))
    eq(ndistinct, 352,
       'H the resolved style set is byte-identical on Windows and Debian (I6 sorted listing)')
end

-- ===========================================================================
-- report
-- ===========================================================================
io.write('\n== helper coverage (section G)\n')
if #helperReport == 0 then
    io.write('    (skipped)\n')
else
    for _, r in ipairs(helperReport) do
        io.write(string.format('    %-34s %s%s\n', r.name, r.ok and 'WORKS' or 'FAILS',
                               r.ok and '' or ('  ' .. tostring(r.err))))
    end
end

io.write('\n== recorded BLOCKER / inert calls reached\n')
local rep = widget.report()
if #rep == 0 then io.write('    (none)\n') end
for _, l in ipairs(rep) do io.write('    ', l, '\n') end

io.write(string.format('\nshim_ui_suite: %d passed, %d failed, %d skipped\n', pass, fail, skipped))
for _, l in ipairs(failures) do io.write(l, '\n') end

if _G.SHIMUI_NO_EXIT then
    return { pass = pass, fail = fail, skip = skipped, failures = failures }
end
os.exit(fail == 0 and 0 or 1)
