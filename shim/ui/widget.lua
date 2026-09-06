--[[============================================================================
shim/ui/widget.lua -- the stateful, invisible UIWidget (work item S3, PLAN sec.1.11).

    local widget = require('shim.ui.widget')
    local w = widget.new('UIWidget', 'Panel')    -- class, style name
    widget.isWidget(w)                            -- true
    widget.report()                               -- what BLOCKER methods were reached

Nothing renders.  Every value vBot writes into a widget and later READS BACK is real
state on a real parent/child tree; everything that needs a pixel, a font metric, a
mouse or a key is a RECORDED no-op (widget.record), never a plausible-looking lie.

--------------------------------------------------------------------------------
WHY THE STATE LIVES IN `w.__s` AND NOT IN PLAIN FIELDS
--------------------------------------------------------------------------------
In otclient a widget's state lives in C++; the Lua table holds only (a) child
references installed by `setId`, (b) signal handlers, and (c) whatever arbitrary
fields a script hangs on it.  vBot exploits all three, and the names collide head-on
with the obvious field names for widget state:

    mods/game_bot/ui/panels.otui:37   BotTextEdit  id: text    ->  widget.text is a CHILD
    cavebot/config.otui:60            BotTextEdit  id: value   ->  panel.value is a CHILD
    cavebot/actions.lua:185-227       widget.action / widget.value / widget.stayPos
    vBot/AttackBot.lua:2210           label.params = entry
    vBot/supplies.otui:38             BotItem      id: id      ->  panel.id is a CHILD

So a widget's own text/value/id CANNOT be stored as `w.text` / `w.value` / `w.id`.
They live in the private table `w.__s`.  The exceptions are the handful of fields
that are plain Lua fields UPSTREAM TOO, because upstream implements those classes in
Lua, and vBot reads them raw:

    UIComboBox  options currentIndex mouseScroll menuScroll menuHeight menuScrollStep
                                       (uicombobox.lua:4-14; bot.lua:214 reads .options,
                                        ui_elements.lua:253 reads widget.slot.currentIndex)
    UIScrollBar value minimum maximum step setupDone orientation pixelsScroll ...
                                       (uiscrollbar.lua:154-175)
    UISpinBox   value minimum maximum step firstchange displayButtons
                                       (uispinbox.lua:4-18)
    UITabBar    tabs buttonsPanel currentTab contentWidget   (uitabbar.lua:16-21)

Those four are reproduced with their upstream field names, upstream defaults and
upstream collision hazards -- deviating would be the drift, not the fidelity.

--------------------------------------------------------------------------------
SIGNAL DISPATCH -- the one piece of real cleverness
--------------------------------------------------------------------------------
`UIWidget::callLuaField(name, ...)` resolves through LuaInterface::luaObjectGetEvent
(luainterface.cpp:200-240): an OBJECT FIELD SHADOWS THE CLASS METHOD, and the object
is always pushed as the first argument.  That is why `spinbox.onTextChange = f`
silently disables `UISpinBox:onTextChange`'s value tracking in the live client.

    w:fire('onTextChange', text, old)
      handler = rawget(w, 'onTextChange') or CLASS[w.class].handlers.onTextChange
      signalcall(handler, w, text, old)

`signalcall` comes from shim/corelib.lua, so a signal field may hold a bare function
OR the array `connect()` builds, and a slot returning truthy stops the rest -- exactly
what `modules.game_bot.connect(CaveBotList(), {onChildFocusChange=...})`
(cavebot/stand_lure.lua:167) needs.

--------------------------------------------------------------------------------
WHAT IS FIRED AND WHAT IS ONLY STORED  (api-ui.md sec.7)
--------------------------------------------------------------------------------
FIRED   onTextChange onValueChange onItemChange onOptionChange onCheckChange
        onVisibilityChange onFocusChange onChildFocusChange onSetup onCreate
        onStyleApply onIdChange onEnabled onDestroy
STORED  onClick onDoubleClick onMousePress/Release/Move/Wheel onDragEnter/Move/Drop
        onHoverChange onKeyDown/Press/Up onEscape onEnter onGeometryChange onClose
        -- callable by hand (functions/config.lua:241 `widget.switch:onClick()` is how
        CaveBot.setOn() works), never fired by the shim: nothing headless generates
        input or geometry.

--------------------------------------------------------------------------------
EXACTNESS QUIRKS COPIED VERBATIM FROM THE C++ (each has a test)
--------------------------------------------------------------------------------
 Q1 getChildByIndex(i): `index = index <= 0 ? size + index : index - 1` then a 0-based
    lookup (uiwidget.cpp:1509-1516).  So `1` is the first child, `-1` is the LAST
    (`getLastChild()` is literally `getChildByIndex(-1)`, uiwidget.h:722), `-2` the
    second-to-last -- and `0` maps to `size`, which is OUT OF RANGE and returns nil.
    NOTE: docs/shim/api-ui.md sec.4.3 says "`0`->last"; that is off by one against the
    source.  This shim follows the source; see the section-C asserts.
 Q2 getChildIndex(nil) -> the widget's OWN index in ITS parent   (uiwidget.h:524)
    getChildIndex(foreign) -> -1
 Q3 setId installs the parent Lua field UNCONDITIONALLY (uiwidget.cpp:1056-1072);
    the `if (!hasLuaField())` guard is in addChild (uiwidget.cpp:222-227) and only
    fires for a widget that ALREADY had an id when it was parented.
 Q4 an id that is a number string also gets the NUMERIC key -- HealBot.otui:219-255
    declares `id: 1`..`id: 5` and HealBot.lua:292-299 reads `ui[i]` with a number.
 Q5 setText(t, dontFireLuaCall): the 2nd arg breaks the CaveBot.save() recursion
    (cavebot/config.lua:108,138).  setItemId has NO such argument and ALWAYS fires
    onItemChange (uiitem.cpp:107-122) -- config.lua:159-175 works around it.
 Q6 setValue on a scrollbar only signals when `setupDone` (uiscrollbar.lua:380),
    which UIScrollBar:onSetup sets -- i.e. `value:` in a style never signals.
 Q7 the first addOption auto-selects (uicombobox.lua:90-100); that is the only reason
    getCurrentOption() is non-nil at load.
 Q8 auto-focus, evaluated ONCE at the end of the first applyStyle
    (uiwidget.cpp:727-736); default policy `last`, Panel/ScrollablePanel `first`,
    TextList `none`.
 Q9 setVisible(false) on the FOCUSED child -> parent:focusPreviousChild(rotate=true)
    with the child still focused => the PREVIOUS sibling (uiwidget.cpp:1277-1280).
    destroy() of the focused child -> focusChild(nil) FIRST, then remove, then
    focusPreviousChild(rotate=true) with no anchor => the LAST focusable sibling
    (uiwidget.cpp:304-350).  The two are genuinely different; both are asserted.
Q10 getWidth()/getHeight() return 0 on purpose: ui_elements.lua:303,328,373 use them
    only to decide whether to clamp a width, and `0 > 88` is false, so the clamp is
    correctly skipped.  A fake number would silently resize labels.
============================================================================]]

local M = {}

-- ---------------------------------------------------------------------------
-- signalcall: reuse shim/corelib.lua's so `connect()`-built arrays and the
-- stop-at-first-truthy rule are identical.  Falls back to a bare pcall dispatch so
-- this module can be required on its own.
-- ---------------------------------------------------------------------------
local signalcall
do
    local ok, corelib = pcall(require, 'shim.corelib')
    if ok and type(corelib) == 'table' and type(corelib.signalcall) == 'function' then
        signalcall = corelib.signalcall
    else
        signalcall = function(param, ...)
            if type(param) == 'function' then
                local st, ret = pcall(param, ...)
                if st then return ret end
                io.stderr:write('shim.ui.widget signal error: ' .. tostring(ret) .. '\n')
            elseif type(param) == 'table' then
                for _, v in pairs(param) do
                    local st, ret = pcall(v, ...)
                    if st then if ret then return true end
                    else io.stderr:write('shim.ui.widget signal error: ' .. tostring(ret) .. '\n') end
                end
            elseif param ~= nil then
                error('attempt to call a non function value')
            end
            return false
        end
    end
end
M.signalcall = signalcall

-- ---------------------------------------------------------------------------
-- recording: every BLOCKER / inert method that vBot actually reached.  A test can
-- prove a path was taken, and report() lists what this process could not do.
-- ---------------------------------------------------------------------------
M.record = {}
local function rec(name, ...)
    local e = M.record[name]
    if not e then e = { n = 0 }; M.record[name] = e end
    e.n = e.n + 1
    e.last = { n = select('#', ...), ... }
    return e
end
M.rec = rec

function M.resetRecord() M.record = {} end

--- Sorted "name  count" lines for the BLOCKER / inert methods that were reached.
function M.report()
    local names = {}
    for k in pairs(M.record) do names[#names + 1] = k end
    table.sort(names)
    local out = {}
    for i = 1, #names do
        out[i] = string.format('%-32s %d', names[i], M.record[names[i]].n)
    end
    return out
end

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local function isWidget(v)
    return type(v) == 'table' and rawget(v, '__s') ~= nil and rawget(v, '__w') == true
end
M.isWidget = isWidget

local function S(w) return rawget(w, '__s') end

--- C++ setText/setTooltip take std::string; the Lua binding coerces numbers.  nil is
--- an error upstream; here it is recorded and coerced, because UISpinBox:onTextChange
--- itself can reach `self:setText(nil)` (uispinbox.lua:130) on unparseable input.
local function str(v, where)
    local t = type(v)
    if t == 'string' then return v end
    if t == 'number' or t == 'boolean' then return tostring(v) end
    if v == nil then rec(where .. '(nil)'); return '' end
    rec(where .. '(' .. t .. ')')
    return tostring(v)
end

local function indexOf(arr, v)
    for i = 1, #arr do if arr[i] == v then return i end end
    return nil
end

-- ===========================================================================
-- 1. the method table
-- ===========================================================================
local W = {}
M.methods = W

-- --------------------------------------------------------------- dispatch ---

--- UIWidget::callLuaField -- object field shadows class method, self is arg #1.
function W:fire(name, ...)
    local s = S(self)
    if s.destroyed and name ~= 'onDestroy' then return false end
    local h = rawget(self, name)
    if h == nil then
        local cls = M.CLASS[s.class]
        h = cls and cls.handlers and cls.handlers[name]
    end
    if h == nil then return false end
    local ht = type(h)
    if ht ~= 'function' and ht ~= 'table' then
        -- a widget id or a script field collided with a signal name; upstream's
        -- callLuaField would raise here.  Record it instead of taking the tree down.
        rec('signalFieldNotCallable:' .. name, ht)
        return false
    end
    return signalcall(h, self, ...)
end
W.callLuaField = W.fire

-- ------------------------------------------------------------- identity -----

function W:getId() return S(self).id end
function W:getStyleName() return S(self).styleName end
function W:getClassName() return S(self).class end
function W:getSource() return S(self).styleName end

--- uiwidget.cpp:1056-1072.  Q3/Q4.
function W:setId(id)
    local s = S(self)
    id = str(id, 'setId')
    if id == s.id then return self end
    local p = s.parent
    if p then
        local ps = S(p)
        if s.id ~= '' then
            if rawget(p, s.id) == self then rawset(p, s.id, nil) end
            local oldn = tonumber(s.id)
            if oldn and rawget(p, oldn) == self then rawset(p, oldn, nil) end
            if ps.childrenById[s.id] == self then ps.childrenById[s.id] = nil end
        end
        rawset(p, id, self)
        local n = tonumber(id)
        if n then rawset(p, n, self) end          -- Q4: HealBot reads ui[1]
        ps.childrenById[id] = self
    end
    s.id = id
    s.customId = true
    self:fire('onIdChange', id)
    return self
end

-- ----------------------------------------------------------------- tree -----

--- uiwidget.cpp:195-235.
function W:addChild(child)
    if not isWidget(child) then rec('addChild(non-widget)', child); return self end
    local s, cs = S(self), S(child)
    if cs.parent == self then return self end
    if cs.parent then cs.parent:removeChild(child) end

    s.children[#s.children + 1] = child
    s.childrenById[cs.id] = child
    cs.childIndex = #s.children
    cs.parent = self

    -- Q3: the guarded install -- only for a child that ALREADY carried an id.
    if cs.customId and cs.id ~= '' and rawget(self, cs.id) == nil then
        rawset(self, cs.id, child)
        local n = tonumber(cs.id)
        if n and rawget(self, n) == nil then rawset(self, n, child) end
    end

    child:updateStates()
    return self
end

function W:insertChild(index, child)
    if not isWidget(child) then rec('insertChild(non-widget)', child); return self end
    local s, cs = S(self), S(child)
    if cs.parent then cs.parent:removeChild(child) end
    index = tonumber(index) or 1
    if index <= 0 then index = #s.children + index + 1 end
    if index < 1 then index = 1 end
    if index > #s.children + 1 then index = #s.children + 1 end
    table.insert(s.children, index, child)
    s.childrenById[cs.id] = child
    cs.parent = self
    for i = index, #s.children do S(s.children[i]).childIndex = i end
    if cs.customId and cs.id ~= '' and rawget(self, cs.id) == nil then
        rawset(self, cs.id, child)
        local n = tonumber(cs.id)
        if n and rawget(self, n) == nil then rawset(self, n, child) end
    end
    child:updateStates()
    return self
end

--- uiwidget.cpp:300-352.  Q9 (the destroy half).
function W:removeChild(child)
    local s = S(self)
    local idx = indexOf(s.children, child)
    if not idx then return self end
    local cs = S(child)

    local focusAnother = false
    if s.focusedChild == child then
        self:focusChild(nil, 'active')
        focusAnother = true
    end

    table.remove(s.children, idx)
    if s.childrenById[cs.id] == child then s.childrenById[cs.id] = nil end
    for i = idx, #s.children do S(s.children[i]).childIndex = i end
    cs.childIndex = -1
    cs.parent = nil

    if cs.customId and cs.id ~= '' then
        if rawget(self, cs.id) == child then rawset(self, cs.id, nil) end
        local n = tonumber(cs.id)
        if n and rawget(self, n) == child then rawset(self, n, nil) end
    end

    child:updateStates()
    if s.autoFocus ~= 'none' and focusAnother and s.focusedChild == nil then
        self:focusPreviousChild('active', true)
    end
    return self
end

function W:getParent() return S(self).parent end

function W:getRootParent()
    local w = self
    while S(w).parent do w = S(w).parent end
    return w
end

--- A COPY, like the C++ by-value UIWidgetList: vBot destroys children while
--- iterating (targetbot/target.lua:176).
function W:getChildren()
    local s, out = S(self), {}
    for i = 1, #s.children do out[i] = s.children[i] end
    return out
end

function W:getChildCount() return #S(self).children end

function W:getChildById(id)
    if id == nil then return nil end
    return S(self).childrenById[id] or S(self).childrenById[tostring(id)]
end

--- uiwidget.cpp:1528-1541: own map first, then depth-first through the children.
function W:recursiveGetChildById(id)
    local found = self:getChildById(id)
    if found then return found end
    local s = S(self)
    for i = 1, #s.children do
        found = s.children[i]:recursiveGetChildById(id)
        if found then return found end
    end
    return nil
end

--- Q1: uiwidget.cpp:1509-1516.  1-based for i>0; i<=0 counts from the end (0 -> last).
function W:getChildByIndex(index)
    local s = S(self)
    index = tonumber(index)
    if not index then return nil end
    local n = #s.children
    local i = (index <= 0) and (n + index) or (index - 1)      -- 0-based
    if i >= 0 and i < n then return s.children[i + 1] end
    return nil
end

--- Q2: uiwidget.h:524.
function W:getChildIndex(child)
    if child == nil then return S(self).childIndex end
    if not isWidget(child) then return -1 end
    local cs = S(child)
    if cs.parent ~= self then return -1 end
    return cs.childIndex
end

function W:getFirstChild() return self:getChildByIndex(1) end
function W:getLastChild()  return self:getChildByIndex(-1) end

function W:getNextSibling()
    local p = S(self).parent
    if not p then return nil end
    local i = S(self).childIndex
    if p:getChildCount() > i then return p:getChildByIndex(i + 1) end
    return nil
end

function W:getPrevSibling()
    local p = S(self).parent
    if not p then return nil end
    local i = S(self).childIndex
    if i > 1 then return p:getChildByIndex(i - 1) end
    return nil
end

--- uiwidget.cpp:552-575.  1-based target index; reindexes the siblings.
function W:moveChildToIndex(child, index)
    local s = S(self)
    local from = indexOf(s.children, child)
    if not from then return self end
    index = tonumber(index) or 1
    if index < 1 then index = 1 end
    if index > #s.children then index = #s.children end
    if index == from then return self end
    table.remove(s.children, from)
    table.insert(s.children, index, child)
    local lo, hi = math.min(from, index), math.max(from, index)
    for i = lo, hi do S(s.children[i]).childIndex = i end
    return self
end

function W:hasChild(child) return indexOf(S(self).children, child) ~= nil end

function W:isDestroyed() return S(self).destroyed end

--- uiwidget.cpp:2020-2055.  Children are torn down (and fire THEIR onDestroy) before
--- the widget fires its own; visible/enabled are forced false.
local function internalDestroy(w)
    local s = S(w)
    s.destroyed = true
    s.explicitVisible, s.visible = false, false
    s.explicitEnabled, s.effEnabled = false, false
    s.focusedChild = nil
    s.parent = nil
    s.childIndex = -1
    s.childrenById = {}
    local kids = s.children
    s.children = {}
    for i = 1, #kids do internalDestroy(kids[i]) end
    w:fire('onDestroy')
end

--- uiwidget.cpp:280-296: mark destroyed, detach from the parent (which is what
--- triggers the Q9 refocus), then internalDestroy.
function W:destroy()
    local s = S(self)
    if s.destroyed then rec('destroy(twice)', s.id); return self end
    s.destroyed = true
    if s.parent then s.parent:removeChild(self) end
    internalDestroy(self)
    return self
end

--- uiwidget.cpp:352-... : focus is cleared WITHOUT signalling and every child is
--- unparented before being destroyed, so no per-child refocus storm happens.
function W:destroyChildren()
    local s = S(self)
    s.focusedChild = nil
    s.childrenById = {}
    local kids = s.children
    s.children = {}
    for i = 1, #kids do
        local child = kids[i]
        local cs = S(child)
        cs.parent = nil
        cs.childIndex = -1
        if cs.customId and cs.id ~= '' then
            if rawget(self, cs.id) == child then rawset(self, cs.id, nil) end
            local n = tonumber(cs.id)
            if n and rawget(self, n) == child then rawset(self, n, nil) end
        end
        child:destroy()
    end
    return self
end

-- ---------------------------------------------------------------- states ----

local function effectiveVisible(w)
    local x = w
    while x do
        local xs = S(x)
        if not xs.explicitVisible then return false end
        x = xs.parent
    end
    return true
end

local function effectiveEnabled(w)
    local x = w
    while x do
        local xs = S(x)
        if not xs.explicitEnabled then return false end
        x = xs.parent
    end
    return true
end

--- uiwidget.cpp:1780-1818: recompute, propagate to children only when it CHANGED,
--- and fire onVisibilityChange on every transition.  The C++ updates the CHILDREN
--- FIRST (`if (updateChildren) for(child) child->updateState(state)`) and only then
--- calls `setState`, which is what fires the signal -- so the deepest descendant
--- signals before its ancestors.  Order matters: HealBot.lua:321 and
--- AttackBot.lua:1781 hang save logic off a window's onVisibilityChange and read
--- their children while it runs.
local function updateHidden(w)
    local s = S(w)
    local vis = effectiveVisible(w)
    if vis == s.visible then return end
    s.visible = vis
    local kids = s.children
    for i = 1, #kids do updateHidden(kids[i]) end
    w:fire('onVisibilityChange', vis)
end

local function updateDisabled(w)
    local s = S(w)
    local en = effectiveEnabled(w)
    if en == s.effEnabled then return end
    s.effEnabled = en
    local kids = s.children
    for i = 1, #kids do updateDisabled(kids[i]) end
end

function W:updateStates()
    updateHidden(self)
    updateDisabled(self)
    return self
end

--- uiwidget.cpp:1269-1290.  Q9 (the setVisible half): the refocus happens BEFORE the
--- onVisibilityChange signal, and while `self` is still the parent's focused child.
function W:setVisible(visible)
    visible = visible and true or false
    local s = S(self)
    if s.explicitVisible == visible then return self end
    s.explicitVisible = visible
    if not visible and s.parent and S(s.parent).focusedChild == self then
        s.parent:focusPreviousChild('active', true)
    end
    updateHidden(self)
    return self
end

function W:show() return self:setVisible(true) end
function W:hide() return self:setVisible(false) end
function W:isVisible() return S(self).visible end
function W:isHidden() return not S(self).visible end
function W:isExplicitlyVisible() return S(self).explicitVisible end

function W:setEnabled(enabled)
    enabled = enabled and true or false
    local s = S(self)
    if s.explicitEnabled == enabled then return self end
    s.explicitEnabled = enabled
    updateDisabled(self)
    self:fire('onEnabled', enabled)
    return self
end

function W:enable()  return self:setEnabled(true)  end
function W:disable() return self:setEnabled(false) end
function W:isEnabled() return S(self).effEnabled end
function W:isExplicitlyEnabled() return S(self).explicitEnabled end

--- uiwidget.cpp:1297-1300: setOn fires NOTHING.  The 2nd argument at
--- cavebot/config.lua:123 is ignored by the C++ too.
function W:setOn(on) S(self).on = on and true or false; return self end
function W:setOff()  return self:setOn(false) end
function W:isOn()    return S(self).on end

--- uiwidget.cpp:1302-1306: fires onCheckChange ON CHANGE.
function W:setChecked(checked)
    checked = checked and true or false
    local s = S(self)
    if s.checked == checked then return self end
    s.checked = checked
    self:fire('onCheckChange', checked)
    return self
end
function W:isChecked() return S(self).checked end

function W:setPhantom(p) S(self).phantom = p and true or false; return self end
function W:isPhantom() return S(self).phantom end

function W:setTooltip(t) S(self).tooltip = str(t, 'setTooltip'); return self end
function W:getTooltip() return S(self).tooltip end
function W:removeTooltip() S(self).tooltip = ''; return self end

-- ----------------------------------------------------------------- text -----

--- uiwidgettext.cpp:366-393.  Q5.
function W:setText(text, dontFireLuaCall)
    local s = S(self)
    text = str(text, 'setText')
    if s.text == text then return self end
    local old = s.text
    s.text = text
    if not dontFireLuaCall then self:fire('onTextChange', text, old) end
    return self
end

function W:getText() return S(self).text end
function W:setColoredText(t, dontFire) rec('setColoredText'); return self:setText(t, dontFire) end
function W:clearText() return self:setText('') end
function W:getTextSize() rec('getTextSize'); return { width = 0, height = 0 } end

-- ---------------------------------------------------------------- focus -----

--- uiwidget.cpp:357-390.
function W:focusChild(child, reason)
    local s = S(self)
    if s.destroyed then return self end
    if child == s.focusedChild then return self end
    if child ~= nil and not self:hasChild(child) then
        rec('focusChild(foreign)')
        return self
    end
    local old = s.focusedChild
    s.focusedChild = child
    reason = reason or 'active'
    if child then
        S(child).lastFocusReason = reason
        child:fire('onFocusChange', true, reason)
    end
    if old then
        S(old).lastFocusReason = reason
        old:fire('onFocusChange', false, reason)
    end
    self:fire('onChildFocusChange', child, old, reason)
    return self
end

function W:getFocusedChild() return S(self).focusedChild end

--- uiwidget.cpp:858-868: destroyed and non-focusable widgets refuse to take focus.
function W:focus(reason)
    local s = S(self)
    if s.destroyed or not s.focusable then return self end
    if not s.parent then return self end
    s.parent:focusChild(self, reason or 'active')
    return self
end

function W:isFocused()
    local p = S(self).parent
    return p ~= nil and S(p).focusedChild == self
end

local function focusable(child)
    local cs = S(child)
    return cs.focusable and cs.explicitEnabled and cs.visible
end

--- uiwidget.cpp:392-432.
function W:focusNextChild(reason, rotate)
    local s = S(self)
    if s.destroyed then return self end
    local list = {}
    for i = 1, #s.children do list[i] = s.children[i] end
    local toFocus
    if rotate then
        if s.focusedChild then
            local i = indexOf(list, s.focusedChild)
            if i then
                local r = {}
                for k = i + 1, #list do r[#r + 1] = list[k] end
                for k = 1, i - 1 do r[#r + 1] = list[k] end
                list = r
            end
        end
        for i = 1, #list do if focusable(list[i]) then toFocus = list[i]; break end end
    else
        local start = 1
        if s.focusedChild then start = indexOf(list, s.focusedChild) or 1 end
        for i = start, #list do
            if list[i] ~= s.focusedChild and focusable(list[i]) then toFocus = list[i]; break end
        end
    end
    if toFocus and toFocus ~= s.focusedChild then self:focusChild(toFocus, reason or 'active') end
    return self
end

--- uiwidget.cpp:434-476.  The rotate branch reverses FIRST, then rotates past the
--- focused child -- so with a focused child it lands on the PREVIOUS sibling, and
--- with none it lands on the LAST focusable child.  Q9 depends on both.
function W:focusPreviousChild(reason, rotate)
    local s = S(self)
    if s.destroyed then return self end
    local list = {}
    for i = #s.children, 1, -1 do list[#list + 1] = s.children[i] end   -- reversed
    local toFocus
    if rotate then
        if s.focusedChild then
            local i = indexOf(list, s.focusedChild)
            if i then
                local r = {}
                for k = i + 1, #list do r[#r + 1] = list[k] end
                for k = 1, i - 1 do r[#r + 1] = list[k] end
                list = r
            end
        end
        for i = 1, #list do if focusable(list[i]) then toFocus = list[i]; break end end
    else
        local start = 1
        if s.focusedChild then start = indexOf(list, s.focusedChild) or 1 end
        for i = start, #list do
            if list[i] ~= s.focusedChild and focusable(list[i]) then toFocus = list[i]; break end
        end
    end
    if toFocus and toFocus ~= s.focusedChild then self:focusChild(toFocus, reason or 'active') end
    return self
end

--- uiwidget.cpp:1310-1330.
function W:setFocusable(f)
    f = f and true or false
    local s = S(self)
    if s.focusable == f then return self end
    s.focusable = f
    local p = s.parent
    if p then
        if not f and S(p).focusedChild == self then
            p:focusPreviousChild('active', true)
        elseif f and S(p).focusedChild == nil and S(p).autoFocus ~= 'none' then
            self:focus()
        end
    end
    return self
end
function W:isFocusable() return S(self).focusable end

local AUTOFOCUS = { first = 'first', last = 'last', none = 'none' }
function W:setAutoFocusPolicy(p)
    S(self).autoFocus = AUTOFOCUS[tostring(p):lower()] or 'last'
    return self
end
function W:getAutoFocusPolicy() return S(self).autoFocus end

--- uiwidget.cpp:727-736.  Q8.  Called once, at the end of the FIRST applyStyle.
function W:applyAutoFocus()
    local s = S(self)
    if not s.firstOnStyle then return self end
    local p = s.parent
    if s.focusable and s.explicitVisible and s.explicitEnabled and p then
        local ps = S(p)
        if (ps.focusedChild == nil and ps.autoFocus == 'first') or ps.autoFocus == 'last' then
            self:focus()
        end
    end
    return self
end

-- ===========================================================================
-- 2. inert / recorded methods  (api-ui.md sec.4.7 and sec.9.4)
-- ===========================================================================

-- Q10: these RETURN 0 on purpose.  ui_elements.lua:303,328,373 compare them against
-- a max width and skip the clamp when 0.
local ZERO = { 'getWidth', 'getHeight', 'getX', 'getY', 'getPaddingLeft', 'getPaddingRight',
               'getPaddingTop', 'getPaddingBottom', 'getMarginTop', 'getMarginLeft',
               'getMarginRight', 'getMarginBottom', 'getContentHeight', 'getContentWidth',
               'getOpacity', 'getChildrenHeight' }
for i = 1, #ZERO do W[ZERO[i]] = function() return 0 end end

function W:getSize()       return { width = 0, height = 0 } end
function W:getRect()       return { x = 0, y = 0, width = 0, height = 0 } end
function W:getMarginRect() return { x = 0, y = 0, width = 0, height = 0 } end
function W:getPosition()   return { x = 0, y = 0 } end
function W:getLayout()     return nil end            -- bot.lua:159 null-checks it
function W:getColor()      return S(self).color end
function W:getBackgroundColor() return S(self).backgroundColor end
function W:getImageSource() return S(self).imageSource end
function W:getFont()       return S(self).font end
function W:containsPoint() rec('containsPoint'); return false end
function W:getChildByPos() rec('getChildByPos'); return nil end
function W:recursiveGetChildByPos() rec('recursiveGetChildByPos'); return nil end

-- Stateful-but-inert setters: they REMEMBER (so a getter round-trips) and do nothing.
local STORE = {
    setColor = 'color', setBackgroundColor = 'backgroundColor', setImageSource = 'imageSource',
    setFont = 'font', setTTFFont = 'font', setImageColor = 'imageColor',
    setTextAlign = 'textAlign', setIcon = 'icon', setIconSource = 'icon',
}
for m, field in pairs(STORE) do
    W[m] = function(self, v) S(self)[field] = v; rec(m); return self end
end

-- Pure no-ops that must exist and return self.
local INERT = {
    'setImageClip', 'setImageSize', 'setImageOffset', 'setImageBorder', 'setImageRect',
    'setImageFixedRatio', 'setImageRepeated', 'setImageSmooth', 'setImageAutoResize',
    'setWidth', 'setHeight', 'setSize', 'setPosition', 'setX', 'setY', 'setRect',
    'setMinWidth', 'setMaxWidth', 'setMinHeight', 'setMaxHeight', 'setFixedSize',
    'setMarginTop', 'setMarginLeft', 'setMarginRight', 'setMarginBottom', 'setMargin',
    'setPaddingTop', 'setPaddingLeft', 'setPaddingRight', 'setPaddingBottom', 'setPadding',
    'setTextOffset', 'setTextWrap', 'setTextAutoResize', 'setTextVerticalAutoResize',
    'setTextHorizontalAutoResize', 'setTextOnlyUpperCase', 'setDraggable',
    'setBorderWidth', 'setBorderColor', 'setOpacity', 'setRotation', 'setClipping',
    'raise', 'lower', 'breakAnchors', 'addAnchor', 'removeAnchor', 'fill', 'centerIn',
    'addAnchoredWidget', 'updateLayout', 'updateParentLayout', 'bindRectToParent',
    'ensureChildVisible', 'scrollToChild', 'setLayout', 'lockChild', 'unlockChild',
    'setMarked', 'setChildrenLocked', 'repaint', 'setShader', 'setCursor',
    'setValidCharacters', 'setCursorPos', 'setMaxLength', 'setEditable', 'setMultiline',
    'setSelection', 'clearSelection', 'setShowCount', 'setVirtual', 'setItemVisible',
    'setShowId', 'setAlwaysShowCount', 'setFlipDirection', 'setMouseScroll',
    'setScrollbarStep', 'setVerticalScrollBar', 'setHorizontalScrollBar',
    'setInverted', 'setPixelsScroll', 'setDefaultScroll', 'setSymbol',
    'display', 'setGameMenu', 'addSeparator', 'setPercentVisible',
}
for i = 1, #INERT do
    local name = INERT[i]
    W[name] = function(self, ...) rec(name, ...); return self end
end

function W:getCursorPos() return 0 end
function W:isTextEditable() return true end
function W:clone() rec('clone'); return M.new(S(self).class, S(self).styleName) end

--- uiwidget.cpp:1234-1258.  Re-applies a REGISTERED style by name -- real behaviour
--- when g_ui is wired (shim/ui/g_ui.lua sets widget.g_ui), recorded no-op otherwise.
--- 0 vBot call sites; api-ui.md sec.9.4 lists it, so it must exist and not lie.
function W:setStyle(styleName)
    rec('setStyle', styleName)
    local g = M.g_ui
    if not g then return self end
    local node = g.getStyle(styleName)
    if not node then
        rec('setStyle(undefined)', styleName)
        return self
    end
    S(self).styleName = styleName
    g.applyStyle(self, node:clone())
    return self
end

function W:setStyleFromNode(node)
    rec('setStyleFromNode')
    local g = M.g_ui
    if g and node then g.applyStyle(self, node) end
    return self
end

--- The public `applyStyle(table)` overload vBot could reach; the OTML-node form is
--- driven by g_ui's creation pipeline, not by scripts.
function W:applyStyle(t)
    rec('applyStyle')
    if type(t) == 'table' and getmetatable(t) == nil then return self:mergeStyle(t) end
    local g = M.g_ui
    if g and t then g.applyStyle(self, t) end
    return self
end

--- mergeStyle takes a plain Lua table upstream too (uitabbar.lua:65).  Only the
--- semantic keys are honoured; everything else is dropped, loudly-countable.
function W:mergeStyle(t)
    rec('mergeStyle')
    if type(t) ~= 'table' then return self end
    if t.id ~= nil then self:setId(t.id) end
    if t.text ~= nil then self:setText(t.text) end
    if t.on ~= nil then self:setOn(t.on) end
    if t.checked ~= nil then self:setChecked(t.checked) end
    if t.visible ~= nil then self:setVisible(t.visible) end
    if t.enabled ~= nil then self:setEnabled(t.enabled) end
    return self
end

-- ===========================================================================
-- 3. per-class behaviour  (mixins selected at creation time)
-- ===========================================================================
-- Each entry: init(w) sets the upstream-visible plain fields; methods are merged
-- into that class's __index; handlers are the CLASS-LEVEL signal handlers that an
-- instance field shadows.
M.CLASS = {}
local CLASS = M.CLASS

-- ------------------------------------------------------------- UIWidget ----
CLASS.UIWidget = { methods = {}, handlers = {} }

-- --------------------------------------------------------------- UILabel ---
-- uilabel.lua:6-7  setPhantom(true) + setFocusable(false)
CLASS.UILabel = { init = function(w) S(w).focusable = false; S(w).phantom = true end }

-- Widgets whose Lua create() turns focus off.
for _, cls in ipairs({ 'UIButton', 'UICheckBox', 'UIComboBox', 'UIProgressBar',
                       'UIScrollBar', 'UISpinBox', 'UITabBar', 'UISplitter',
                       'UIResizeBorder', 'UIMoveableTabBar' }) do
    CLASS[cls] = CLASS[cls] or {}
    local prev = CLASS[cls].init
    CLASS[cls].init = function(w) S(w).focusable = false; if prev then prev(w) end end
end

-- ---------------------------------------------------------------- UIItem ---
-- src/client/uiitem.cpp:107-160.  Q5: EVERY setter fires onItemChange; there is no
-- suppress argument, which is why cavebot/config.lua:159-175 needs `applyingItem`.
local ItemM = {}
CLASS.UIItem = { methods = ItemM, init = function(w) S(w).item = nil end }

--- Duck-typed: any object exposing getId/getCount works, so the S1 Item wrapper,
--- a shim Item.create() result and a plain {id=,count=} all round-trip.
local function itemId(it)
    if it == nil then return 0 end
    if type(it) == 'table' then
        if type(it.getId) == 'function' then local ok, v = pcall(it.getId, it); if ok then return v or 0 end end
        return tonumber(it.id) or 0
    end
    return 0
end
local function itemCount(it)
    if it == nil then return 0 end
    if type(it) == 'table' then
        if type(it.getCount) == 'function' then local ok, v = pcall(it.getCount, it); if ok then return v or 0 end end
        return tonumber(it.count) or 0
    end
    return 0
end
local function itemCountOrSub(it)
    if it == nil then return 0 end
    if type(it) == 'table' then
        if type(it.getCountOrSubType) == 'function' then
            local ok, v = pcall(it.getCountOrSubType, it); if ok then return v or 0 end
        end
        if type(it.getItemCountOrSubType) == 'function' then
            local ok, v = pcall(it.getItemCountOrSubType, it); if ok then return v or 0 end
        end
        return tonumber(it.count) or tonumber(it.subType) or 0
    end
    return 0
end

--- The synthetic item the shim fabricates when only an id/count is known.  It is a
--- VALUE, not a game Thing: no position, no stack pos.  `Item.create` from
--- shim/item.lua is preferred and used whenever the sandbox provides it.
local function makeItem(id, count)
    local mk = rawget(_G, 'Item')
    if type(mk) == 'table' and type(mk.create) == 'function' then
        local ok, v = pcall(mk.create, id, count)
        if ok and v ~= nil then return v end
    end
    if M.ItemFactory then
        local ok, v = pcall(M.ItemFactory, id, count)
        if ok and v ~= nil then return v end
    end
    local it = { id = id, count = count or 1, subType = count or 0 }
    function it:getId() return self.id end
    function it:getCount() return self.count end
    function it:getSubType() return self.subType end
    function it:getCountOrSubType() return self.count end
    function it:isItem() return true end
    function it:isCreature() return false end
    return it
end
M.makeItem = makeItem

function ItemM:setItemId(id)
    local s = S(self)
    id = tonumber(id) or 0
    if id == 0 then s.item = nil
    else s.item = makeItem(id, itemCount(s.item) > 0 and itemCount(s.item) or 1) end
    self:fire('onItemChange')
    return self
end

function ItemM:setItem(item)
    S(self).item = item
    self:fire('onItemChange')
    return self
end

function ItemM:setItemCount(n)
    local s = S(self)
    if s.item then
        if type(s.item.setCount) == 'function' then pcall(s.item.setCount, s.item, n) end
        if type(s.item) == 'table' then s.item.count = tonumber(n) or s.item.count end
    end
    self:fire('onItemChange')
    return self
end

function ItemM:setItemSubType(n)
    local s = S(self)
    if s.item and type(s.item) == 'table' then s.item.subType = tonumber(n) or 0 end
    self:fire('onItemChange')
    return self
end

function ItemM:getItem()               return S(self).item end
function ItemM:getItemId()             return itemId(S(self).item) end
function ItemM:getItemCount()          return itemCount(S(self).item) end
function ItemM:getItemSubType()
    local it = S(self).item
    if it and type(it.getSubType) == 'function' then
        local ok, v = pcall(it.getSubType, it); if ok then return v or 0 end
    end
    return (type(it) == 'table' and tonumber(it.subType)) or 0
end
function ItemM:getItemCountOrSubType() return itemCountOrSub(S(self).item) end
function ItemM:clearItem()             return self:setItemId(0) end

-- ------------------------------------------------------------ UIComboBox ---
-- uicombobox.lua verbatim.  Q7.
local ComboM = {}
CLASS.UIComboBox = {
    methods = ComboM,
    init = function(w)
        S(w).focusable = false
        w.options = {}
        w.currentIndex = -1
        w.mouseScroll = true
        w.menuScroll = false
        w.menuHeight = 100
        w.menuScrollStep = 0
    end,
}

function ComboM:clearOptions()
    self.options = {}
    self.currentIndex = -1
    self:clearText()
    return self
end
ComboM.clear = ComboM.clearOptions

function ComboM:isOption(text)
    if not self.options then return false end
    for _, v in ipairs(self.options) do if v.text == text then return true end end
    return false
end

function ComboM:setCurrentOption(text, dontSignal)
    if not self.options then return self end
    for i, v in ipairs(self.options) do
        if v.text == text and self.currentIndex ~= i then
            self.currentIndex = i
            self:setText(text)
            if not dontSignal then self:fire('onOptionChange', text, v.data) end
            return self
        end
    end
    return self
end
ComboM.setOption = ComboM.setCurrentOption

function ComboM:setCurrentOptionByData(data, dontSignal)
    if not self.options then return self end
    for i, v in ipairs(self.options) do
        if v.data == data and self.currentIndex ~= i then
            self.currentIndex = i
            self:setText(v.text)
            if not dontSignal then self:fire('onOptionChange', v.text, v.data) end
            return self
        end
    end
    return self
end

--- uicombobox.lua:75-82: ALWAYS signals, even when the index is unchanged.
function ComboM:setCurrentIndex(index)
    index = tonumber(index)
    if not index then return self end
    if index >= 1 and index <= #self.options then
        local v = self.options[index]
        self.currentIndex = index
        self:setText(v.text)
        self:fire('onOptionChange', v.text, v.data)
    end
    return self
end

function ComboM:getCurrentIndex() return self.currentIndex end

function ComboM:getCurrentOption()
    local i = self.currentIndex
    if type(i) == 'number' and self.options and self.options[i] then return self.options[i] end
    return nil
end

--- Q7: the FIRST option auto-selects.
function ComboM:addOption(text, data)
    self.options = self.options or {}
    table.insert(self.options, { text = text, data = data })
    local index = #self.options
    if index == 1 then self:setCurrentOption(text) end
    return index
end
ComboM.addOptionFromHtml = ComboM.addOption

function ComboM:removeOption(text)
    for i, v in ipairs(self.options) do
        if v.text == text then
            table.remove(self.options, i)
            if self.currentIndex == i then self:setCurrentIndex(1)
            elseif self.currentIndex > i then self.currentIndex = self.currentIndex - 1 end
            return self
        end
    end
    return self
end

function ComboM:getOptionsCount() return #(self.options or {}) end

-- ----------------------------------------------------------- UIScrollBar ---
-- uiscrollbar.lua:154-383.  Q6.
local ScrollM = {}
CLASS.UIScrollBar = {
    methods = ScrollM,
    init = function(w)
        S(w).focusable = false
        w.value = 0
        w.minimum = -999999
        w.maximum = 999999
        w.step = 1
        w.setupDone = false
        w.orientation = 'vertical'
        w.pixelsScroll = false
        w.mouseScroll = true
        w.incrementValue = 1
    end,
    handlers = {
        onSetup = function(w) w.setupDone = true end,
        onStyleApply = function(w, _, node)
            if type(node) ~= 'table' then return end
            for name, value in pairs(node) do
                if name == 'maximum' then w:setMaximum(tonumber(value))
                elseif name == 'minimum' then w:setMinimum(tonumber(value))
                elseif name == 'step' then w:setStep(tonumber(value))
                elseif name == 'orientation' then w.orientation = value
                elseif name == 'value' then w:setValue(tonumber(value) or 0)
                elseif name == 'pixels-scroll' then w.pixelsScroll = true
                elseif name == 'mouse-scroll' then w.mouseScroll = value
                elseif name == 'increment' then w.incrementValue = value
                end
            end
        end,
    },
}

local function round(n) return math.floor(n + 0.5) end

function ScrollM:setValue(value)
    value = tonumber(value) or 0
    value = math.max(math.min(value, self.maximum), self.minimum)
    if self.value == value then return self end
    local delta = value - self.value
    self.value = value
    if self.setupDone then self:fire('onValueChange', round(value), delta) end
    return self
end

function ScrollM:getValue()   return round(self.value) end
function ScrollM:getMinimum() return self.minimum end
function ScrollM:getMaximum() return self.maximum end
function ScrollM:setStep(s)   self.step = tonumber(s) or self.step; return self end
function ScrollM:getStep()    return self.step end
function ScrollM:setOrientation(o) self.orientation = o; return self end

function ScrollM:setMaximum(maximum)
    maximum = tonumber(maximum)
    if maximum == nil or maximum == self.maximum then return self end
    self.maximum = maximum
    if self.minimum > maximum then self:setMinimum(maximum) end
    if self.value > maximum then self:setValue(maximum) end
    return self
end

function ScrollM:setMinimum(minimum)
    minimum = tonumber(minimum)
    if minimum == nil or minimum == self.minimum then return self end
    self.minimum = minimum
    if self.maximum < minimum then self:setMaximum(minimum) end
    if self.value < minimum then self:setValue(minimum) end
    return self
end

function ScrollM:setRange(a, b) self:setMinimum(a); self:setMaximum(b); return self end

-- ------------------------------------------------------------- UISpinBox ---
-- uispinbox.lua:4-150.  A SpinBox is NOT a ScrollBar: no setupDone gate, no rounding,
-- and setText() drives setValue() through the class onTextChange -- which is exactly
-- how vBot/supplies.lua:185-187 writes and :214-216 reads back.
local SpinM = {}
CLASS.UISpinBox = {
    methods = SpinM,
    init = function(w)
        S(w).focusable = false
        w.minimum = 0
        w.maximum = 1
        w.value = 0
        w.step = 1
        w.firstchange = true
        w.displayButtons = true
        w.mouseScroll = true
        S(w).text = '1'
        w.value = 1
    end,
    handlers = {
        onStyleApply = function(w, _, node)
            if type(node) ~= 'table' then return end
            -- upstream defers these through addEvent(); the shim applies them inline
            -- because there is no frame to defer to and the order (min before max
            -- before the style's own `text:`) is preserved by parseBaseStyle.
            if node.minimum ~= nil then w:setMinimum(tonumber(node.minimum)) end
            if node.maximum ~= nil then w:setMaximum(tonumber(node.maximum)) end
        end,
        onTextChange = function(w, text)
            if #text == 0 then return w:setValue(w.minimum) end
            local number = tonumber(text)
            if not number then return w:setText('') end
            if number < w.minimum then return w:setText(w.minimum) end
            if number > w.maximum then return w:setText(w.maximum) end
            return w:setValue(number)
        end,
    },
}

function SpinM:setValue(value, dontSignal)
    value = tonumber(value) or 0
    value = math.max(math.min(self.maximum, value), self.minimum)
    if value == self.value then return self end
    self.value = value
    if #self:getText() > 0 then self:setText(value) end
    if not dontSignal then self:fire('onValueChange', value) end
    return self
end

function SpinM:getValue()   return self.value end
function SpinM:getMinimum() return self.minimum end
function SpinM:getMaximum() return self.maximum end
function SpinM:setStep(s)   self.step = tonumber(s) or self.step; return self end
function SpinM:getStep()    return self.step end

function SpinM:setMinimum(minimum)
    minimum = tonumber(minimum) or 0
    self.minimum = minimum
    if self.minimum > self.maximum then self.maximum = self.minimum end
    if self.value < minimum then self:setValue(minimum) end
    return self
end

function SpinM:setMaximum(maximum)
    maximum = tonumber(maximum) or 0
    self.maximum = maximum
    if self.value > maximum then self:setValue(maximum) end
    return self
end

function SpinM:setRange(a, b) self:setMinimum(a); self:setMaximum(b); return self end
function SpinM:upSpin()   return self:setValue(self.value + self.step) end
function SpinM:downSpin() return self:setValue(self.value - self.step) end
function SpinM:showButtons() self.displayButtons = true; return self end
function SpinM:hideButtons() self.displayButtons = false; return self end

-- --------------------------------------------------------- UIProgressBar ---
local ProgM = {}
CLASS.UIProgressBar = {
    methods = ProgM,
    init = function(w) S(w).focusable = false; w.percent = 0; w.minimum = 0; w.maximum = 100 end,
}
function ProgM:setPercent(p) self.percent = math.max(0, math.min(100, tonumber(p) or 0)); return self end
function ProgM:getPercent()  return self.percent end
function ProgM:setValue(value, minimum, maximum)
    if minimum then self.minimum = minimum end
    if maximum then self.maximum = maximum end
    local range = self.maximum - self.minimum
    self.percent = (range > 0) and math.max(0, math.min(100, ((value - self.minimum) / range) * 100)) or 0
    return self
end
function ProgM:getProgress() return self.percent / 100 end
function ProgM:setMinimum(v) self.minimum = v; return self end
function ProgM:setMaximum(v) self.maximum = v; return self end

-- --------------------------------------------------------------- UIWindow --
local WinM = {}
CLASS.UIWindow = { methods = WinM }
function WinM:setTitle(t) return self:setText(t) end
function WinM:getTitle()  return self:getText() end

-- ----------------------------------------------------------- UIMiniWindow --
-- api-ui.md sec.3: only setup/close/open/setContentMaximumHeight are ever called and
-- none of them is read back.  INERT, but recorded.
local MiniM = {}
CLASS.UIMiniWindow = { methods = MiniM }
for _, name in ipairs({ 'setup', 'open', 'close', 'minimize', 'maximize', 'setContentWidget',
                        'setContentHeight', 'setContentMaximumHeight', 'setContentMinimumHeight',
                        'saveParent', 'restoreParent', 'setSettings' }) do
    MiniM[name] = function(self, ...) rec('UIMiniWindow:' .. name, ...); return self end
end
function MiniM:isOpen() return true end
-- MainWindow / plain widgets get the same names so a mis-styled window cannot crash.
for _, name in ipairs({ 'setup', 'open', 'close', 'minimize', 'maximize', 'setContentWidget',
                        'setContentHeight', 'setContentMaximumHeight' }) do
    if W[name] == nil then
        W[name] = function(self, ...) rec('widget:' .. name, ...); return self end
    end
end

-- --------------------------------------------------------------- UITabBar --
-- uitabbar.lua:16-105.  ui_legacy.lua's addTab/getTab/setDefaultTab -- the way EVERY
-- vBot file picks its parent panel -- runs on exactly this.
local TabM = {}
CLASS.UITabBar = {
    methods = TabM,
    init = function(w) S(w).focusable = false; w.tabs = {} end,
    handlers = { onSetup = function(w) w.buttonsPanel = w:getChildById('buttonsPanel') end },
}

function TabM:setContentWidget(widget)
    self.contentWidget = widget
    if #self.tabs > 0 then self.contentWidget:addChild(self.tabs[1].tabPanel) end
    return self
end

function TabM:addTab(text, panel, icon)
    local g_ui = M.g_ui or rawget(_G, 'g_ui')
    if panel == nil then
        panel = g_ui.createWidget(self:getStyleName() .. 'Panel')
        panel:setId('tabPanel')
    end
    local tabsParent = self.buttonsPanel or self
    local tab = g_ui.createWidget(self:getStyleName() .. 'Button', tabsParent)
    panel.isTab = true
    tab.tabPanel = panel
    tab.tabBar = self
    tab:setId('tab')
    tab:setText(text)
    tab.onDestroy = function()
        if not tab.tabPanel:isDestroyed() then tab.tabPanel:destroy() end
    end
    table.insert(self.tabs, tab)
    if #self.tabs == 1 then self:selectTab(tab) end
    tab:mergeStyle({ ['icon-source'] = icon })
    return tab
end

function TabM:getTab(text)
    for _, tab in pairs(self.tabs) do
        if tab:getText():lower() == tostring(text):lower() then return tab end
    end
    return nil
end

function TabM:selectTab(tab)
    if self.currentTab == tab then return self end
    if self.contentWidget then
        local sel = self.contentWidget:getLastChild()
        if sel and sel.isTab then self.contentWidget:removeChild(sel) end
        self.contentWidget:addChild(tab.tabPanel)
    end
    if self.currentTab then self.currentTab:setOn(false) end
    self.currentTab = tab
    tab:setOn(true)
    self:fire('onTabChange', tab)
    return self
end

function TabM:getCurrentTab() return self.currentTab end
function TabM:getTabPanel(tab) return tab and tab.tabPanel or (self.currentTab and self.currentTab.tabPanel) end
function TabM:getTabs() return self.tabs end

function TabM:removeTab(tab)
    local index = indexOf(self.tabs, tab)
    if not index then return self end
    if self.currentTab == tab then self.currentTab = nil end
    table.remove(self.tabs, index)
    tab:destroy()
    return self
end

-- ---------------------------------------------------------------- UIGraph --
-- vBot/analyzer.lua only.  BLOCKER (rendering) -- loud, recorded, harmless.
local GraphM = {}
CLASS.UIGraph = { methods = GraphM, init = function(w) w.graphs = 0 end }
function GraphM:createGraph()   rec('UIGraph:createGraph');  self.graphs = self.graphs + 1; return self.graphs end
function GraphM:getGraphsCount() return self.graphs end
for _, name in ipairs({ 'addValue', 'setLineWidth', 'setLineColor', 'setCapacity', 'setTitle',
                        'setShowLabels', 'setGraphVisible', 'clear', 'setInfoText' }) do
    GraphM[name] = function(self, ...) rec('UIGraph:' .. name, ...); return self end
end

-- ------------------------------------------------------------- UICreature --
local CreaM = {}
CLASS.UICreature = { methods = CreaM }
function CreaM:setCreature(c) S(self).creature = c; return self end
function CreaM:getCreature()  return S(self).creature end
function CreaM:setOutfit(o)   S(self).outfit = o; return self end

-- ------------------------------------------------------------ UIPopupMenu --
-- api-ui.md sec.8.1: reachable only from a mouse handler.  Loud no-op.
local MenuM = {}
CLASS.UIPopupMenu = {
    methods = MenuM,
    init = function(w) S(w).menuOptions = {} end,
}
function MenuM:addOption(text, cb)
    local s = S(self)
    s.menuOptions[#s.menuOptions + 1] = { text = text, callback = cb }
    rec('UIPopupMenu:addOption', text)
    return self
end
function MenuM:addSeparator() rec('UIPopupMenu:addSeparator'); return self end
function MenuM:display(pos)   rec('UIPopupMenu:display', pos); return self end
function MenuM:getOptions()   return S(self).menuOptions end
CLASS.UIPopupScrollMenu = CLASS.UIPopupMenu

-- Aliases: classes with no distinct behaviour.
CLASS.UIScrollArea = CLASS.UIScrollArea or {}
CLASS.UITextEdit   = CLASS.UITextEdit   or {}
CLASS.UIButton     = CLASS.UIButton     or {}
CLASS.UICheckBox   = CLASS.UICheckBox   or {}

-- ===========================================================================
-- 4. construction
-- ===========================================================================
local mtCache = {}

local function metatableFor(class)
    local mt = mtCache[class]
    if mt then return mt end
    local idx = {}
    for k, v in pairs(W) do idx[k] = v end
    local cls = CLASS[class]
    if cls and cls.methods then
        for k, v in pairs(cls.methods) do idx[k] = v end
    end
    mt = {
        __index = idx,
        __tostring = function(w)
            local s = S(w)
            return string.format('UIWidget<%s/%s%s>', s.class, s.styleName,
                                 s.id ~= '' and (' #' .. s.id) or '')
        end,
    }
    mtCache[class] = mt
    return mt
end
M.metatableFor = metatableFor

--- widget.new(class, styleName) -- `class` is the OTUI `__class` value.
function M.new(class, styleName)
    class = class or 'UIWidget'
    if CLASS[class] == nil then
        -- Unknown UI* class: behaves as a plain widget.  Recorded so an unexpected
        -- one shows up in the report instead of silently degrading.
        rec('unknownWidgetClass:' .. tostring(class))
        CLASS[class] = {}
        mtCache[class] = nil
    end
    local w = setmetatable({}, metatableFor(class))
    rawset(w, '__w', true)
    rawset(w, '__s', {
        class = class,
        styleName = styleName or class,
        id = '',
        customId = false,
        parent = nil,
        children = {},
        childrenById = {},
        childIndex = -1,
        destroyed = false,
        text = '',
        tooltip = '',
        on = false,
        checked = false,
        explicitEnabled = true,
        effEnabled = true,
        explicitVisible = true,
        visible = true,
        focusable = true,           -- uiwidget.cpp:UIWidget() PropFocusable = true
        autoFocus = 'last',         -- uiwidget.h:373 AutoFocusLast
        focusedChild = nil,
        firstOnStyle = true,
        phantom = false,
        item = nil,
    })
    local cls = CLASS[class]
    if cls and cls.init then cls.init(w) end
    return w
end

return M
