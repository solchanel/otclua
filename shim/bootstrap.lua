--[[============================================================================
shim/bootstrap.lua -- SHIM_G and the boot sequence  (work item S4, PLAN sec.1.1/4.1).

Installs the otclient globals into a CLEAN environment, in the order
docs/shim/api-platform.md sec.7.3 prescribes, then hands control to shim/host.lua,
which runs the user's real vBot tree on top.

    local shim = require('shim.bootstrap')
    local h = shim.start(LC, { otRoot = '.../otclient', config = 'vBot_4.8' })
    shim.status()
    shim.stop()

Boot order (each step's numbering matches PLAN sec.4.1; a step that fails is
RECORDED in status().boot and does not abort the ones that can still run, because
a partial boot with an honest table is more useful than an exception):

  1  G = newG()                     a fresh globals table + the Lua base library
  2  corelib.install(G)             string/table/math patches, connect/signalcall,
                                    scheduleEvent/removeEvent, json, base64, G.G
                                    -- MUST precede executor.lua, which copies the
                                    GLOBAL string/table tables onto the sandbox
  3  G.regexMatch                   installed by corelib (table.decodeStringPairList
                                    calls it, so it must exist before step 8)
  4  platform.install(G)            g_clock (frame-quantised), g_logger, print, tr,
                                    g_window/g_keyboard/g_mouse/g_sounds/g_app/g_platform
     G.g_resources = resources.new(<otRoot>/profiles/)
     G.g_settings  = settings.new{ profile = 1 }     -- 0 resets every vBot config
  7  objects/g_game/g_map/g_things  the game layer + the class tables Creature,
                                    Item, Tile, Container, ... which MUST exist
                                    before step 8
  8  otlua                          otclient's own pure Lua, loaded VERBATIM:
                                    corelib/{const,bitwise}, gamelib/{const,position,
                                    player,creature,textmessages,spells,items,thing,
                                    tile,util}, game_spelllist/spelllist (data).
                                    Supplies SpellInfo/Spells/SpelllistSettings,
                                    PlayerStates, Directions, the Shield*/Skull*
                                    constants and getDistanceBetween.
  9  g_ui                           the UI backend (see below)
 10  modules.build(G, deps)         the modules.* graph; also `package.loaded`
 11  host:start()                   mods/game_bot/executor.lua + functions/ + panels/
                                    + /bot/<config>/_Loader.lua

THE UI BACKEND.  `shim/g_ui.lua` (work item S2) owns the real OTML parser, style
registry and stateful UIWidget.  Until it lands, this file ships a PROVISIONAL
backend: real state for the ~30 methods vBot reads back (id/text/value/on/checked/
item/options/children/focus, api-ui.md sec.9.3) and a permissive memoised
"anything" for every other key, which is what let the A4 probe import all 74 files.
It is selected automatically and reported as `status().ui == 'provisional'`; the
moment `shim/g_ui.lua` exists it is used instead and the field says 'shim.g_ui'.
A provisional widget has NO style tree, so a widget declared only in an .otui is
an anything rather than a real child -- which is exactly why this is provisional
and why status() says so out loud.
============================================================================]]

local bootstrap = {}

-- ===========================================================================
-- 1. SHIM_G
-- ===========================================================================
-- The real client's global env IS _G, so SHIM_G legitimately carries the Lua
-- base library.  It is a COPY, not a metatable to _G: the shim must never be
-- able to reach package/io/require from a bot script by accident, and a stray
-- assignment must land here rather than in the host process's _G.

local BASE_NAMES = {
    'assert', 'error', 'ipairs', 'pairs', 'next', 'pcall', 'xpcall', 'select',
    'setmetatable', 'getmetatable', 'rawget', 'rawset', 'rawequal', 'tonumber',
    'tostring', 'type', 'unpack', 'load', 'loadstring', 'collectgarbage', 'gcinfo',
    'string', 'table', 'math', 'os', 'debug', 'coroutine', '_VERSION', 'jit',
}

function bootstrap.newG()
    local G = {}
    for _, n in ipairs(BASE_NAMES) do G[n] = _G[n] end
    G._G = G
    -- corelib/globals.lua:7 -- the cross-reload table every functions/*.lua reads
    -- as `local context = G.botContext`.  corelib.install refreshes it.
    G.G = {}
    return G
end

-- ===========================================================================
-- 2. PROVISIONAL UI BACKEND
-- ===========================================================================
-- Replaced wholesale by shim/g_ui.lua when that module exists.

-- The `anything`: indexable (memoised, so identity is stable), callable (an
-- unimplemented method is a no-op), assignable (`w.onClick = fn` sticks).
--
-- Its bookkeeping lives OUT OF BAND in a weak side table, never as raw fields on
-- the object: Lua 5.1's pairs/ipairs/# are RAW, so an anything must iterate ZERO
-- times.  vBot/Containers.lua:466 does `for i, child in pairs(x:getChildren())`
-- and calls `child:destroy()`, which would blow up on a leaked '__path' string.
-- Leaf-name -> value for anything calls whose result is USED rather than chained.
-- Grown from the crashes it prevents, each one named.
local ANY_EMPTY_TABLE = {}
local ANY_RETURNS = {
    getWidth = 0, getHeight = 0, getX = 0, getY = 0, getPercent = 0, getStep = 0,
    getValue = 0, getMinimum = 0, getMaximum = 0, getCount = 0, getChildCount = 0,
    getItemId = 0, getItemCount = 0, getItemCountOrSubType = 0, getItemSubType = 0,
    getCurrentIndex = 0, getOptionsCount = 0, getOpacity = 1, getId = '',
    getText = '', getColoredText = '', getTooltip = '', getStyleName = '',
    getClassName = 'UIWidget', getMarginTop = 0, getMarginLeft = 0,
    getMarginRight = 0, getMarginBottom = 0,
    isOn = false, isChecked = false, isVisible = false, isHidden = false,
    isEnabled = false, isFocused = false, isDestroyed = false, isOff = true,
    getChildren = ANY_EMPTY_TABLE, getItems = ANY_EMPTY_TABLE,
    getChildrenByType = ANY_EMPTY_TABLE,
}
-- Shapes whose FIELDS are read: a bare {} would turn `getPosition().x` into a nil
-- arithmetic error.
local ANY_SHAPES = {
    getPosition = function() return { x = 0, y = 0, z = 0 } end,
    getSize     = function() return { width = 0, height = 0 } end,
    getRect     = function() return { x = 0, y = 0, width = 0, height = 0 } end,
    getMarginRect = function() return { x = 0, y = 0, width = 0, height = 0 } end,
}

local anyMT
local anyInfo = setmetatable({}, { __mode = 'k' })

local function mkany(path)
    local t = setmetatable({}, anyMT)
    anyInfo[t] = { path = path, kids = {} }
    return t
end
anyMT = {
    __index = function(t, k)
        local info = anyInfo[t]
        local key = tostring(k)
        local c = info.kids[key]
        if c == nil then
            c = mkany(info.path .. '.' .. key)
            info.kids[key] = c
        end
        return c
    end,
    __newindex = function(t, k, v) rawset(t, k, v) end,
    -- Some calls MUST NOT return an anything: a number compared with a number
    -- (functions/ui_elements.lua:303 `widget.left:getWidth() > params.maxWidth`
    -- raises "attempt to compare number with table"), a string compared with ==,
    -- a table that gets ipairs'd.  api-ui.md sec.9.4 lists the read-back shapes.
    __call = function(t, ...)
        local path = anyInfo[t].path
        local leaf = path:match('([%w_]+)$')
        local shape = leaf and ANY_SHAPES[leaf]
        if shape then return shape() end
        local r = leaf and ANY_RETURNS[leaf]
        if r ~= nil then
            -- A PERMISSIVE empty list: raw-iterates zero times (Lua 5.1 pairs/ipairs/#
            -- are raw) yet answers any index with an anything.  vBot/playerlist.lua:237
            -- does `TabBar.buttonsPanel:getChildren()[v]` -- an index past the array
            -- part that a plain {} turns into a nil-index crash (api-platform.md
            -- sec.3.5).
            if r == ANY_EMPTY_TABLE then
                return setmetatable({}, { __index = function(_, k)
                    return mkany(path .. '()[' .. tostring(k) .. ']')
                end })
            end
            return r
        end
        return mkany(path .. '()')
    end,
    __tostring = function(t) return '<any:' .. anyInfo[t].path .. '>' end,
    __len = function() return 0 end,
    __concat = function(a, b) return tostring(a) .. tostring(b) end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __unm = function() return 0 end,
    __lt = function() return false end, __le = function() return true end,
}
bootstrap.mkany = mkany

local Wmt          -- widget metatable (forward)
local Wm = {}      -- widget methods

-- Widget state lives OUT OF BAND, for the same reason the anything's does: a real
-- otclient widget is userdata, so `pairs(widget)` yields nothing.  With the state
-- as raw fields, `for k, v in pairs(someWidget)` would hand vBot '_children',
-- '_byId' and friends.  Weak keys so a destroyed widget is collectable.
local WI = setmetatable({}, { __mode = 'k' })
local function rg(w, k) local i = WI[w]; return i and i[k] end
local function rs(w, k, v) local i = WI[w]; if i then i[k] = v end end

local function isWidget(v)
    return type(v) == 'table' and getmetatable(v) == Wmt
end

local function newWidget(styleName, parent)
    local w = setmetatable({}, Wmt)
    WI[w] = {}
    rs(w, '_f', {})              -- assignable fields (ids, signal slots, flags)
    rs(w, '_kids', {})           -- anything cache for unknown keys
    rs(w, '_children', {})
    rs(w, '_byId', {})
    rs(w, '_style', styleName or 'UIWidget')
    rs(w, '_id', '')
    rs(w, '_text', '')
    rs(w, '_value', 0)
    rs(w, '_options', {})
    rs(w, '_visible', true)
    -- The real client flips this after applyStyle; the provisional backend has no
    -- style pass, so a widget is "set up" from birth and setValue fires normally.
    rs(w, '_setupDone', true)
    if parent and isWidget(parent) then Wm.addChild(parent, w) end
    return w
end

--- signalcall shape (corelib/util.lua:330-353): a field holds a bare function OR
--- an array of functions; every slot is pcall'd, and a truthy return stops the
--- rest.  api-ui.md sec.7 / PLAN I8.
local function fire(w, name, ...)
    local slot = rg(w, '_f')[name]
    if slot == nil then return false end
    if type(slot) == 'function' then
        local ok, r = pcall(slot, w, ...)
        if not ok then return false end
        return r and true or false
    end
    if type(slot) == 'table' then
        for _, f in ipairs(slot) do
            local ok, r = pcall(f, w, ...)
            if ok and r then return true end
        end
    end
    return false
end

-- ---- identity / text / value ----------------------------------------------
function Wm.getClassName(w) return rg(w, '_style') end
function Wm.getStyleName(w) return rg(w, '_style') end
function Wm.getId(w) return rg(w, '_id') end
function Wm.setId(w, id)
    id = tostring(id)
    rs(w, '_id', id)
    local p = rg(w, '_parent')
    if p then
        rg(p, '_byId')[id] = w
        -- api-ui.md sec.9.3: the parent field is installed ONLY when the parent has
        -- no field of that name (otherwise a child called "text" would shadow a real
        -- one), and a numeric id ALSO lands on the numeric key -- HealBot.lua:292-299
        -- reads ui[1].
        local f = rg(p, '_f')
        if f[id] == nil then f[id] = w end
        local n = tonumber(id)
        if n and f[n] == nil then f[n] = w end
    end
    return w
end
function Wm.getText(w) return rg(w, '_text') end
function Wm.setText(w, t, dontFire)
    local old = rg(w, '_text')
    rs(w, '_text', tostring(t == nil and '' or t))
    -- the 2nd arg exists to break a CaveBot.save() recursion
    if not dontFire and old ~= rg(w, '_text') then fire(w, 'onTextChange', rg(w, '_text'), old) end
    return w
end
Wm.setColoredText = Wm.setText
function Wm.getValue(w) return rg(w, '_value') end
function Wm.setValue(w, v)
    v = tonumber(v) or 0
    local lo, hi = rg(w, '_min'), rg(w, '_max')
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    local old = rg(w, '_value')
    rs(w, '_value', v)
    if rg(w, '_setupDone') and old ~= v then fire(w, 'onValueChange', v) end
    return w
end
function Wm.setMinimum(w, v) rs(w, '_min', tonumber(v)); return w end
function Wm.setMaximum(w, v) rs(w, '_max', tonumber(v)); return w end
function Wm.getMinimum(w) return rg(w, '_min') or 0 end
function Wm.getMaximum(w) return rg(w, '_max') or 0 end
function Wm.setRange(w, lo, hi) rs(w, '_min', lo); rs(w, '_max', hi); return w end

-- ---- switches --------------------------------------------------------------
function Wm.isOn(w) return rg(w, '_on') == true end
function Wm.setOn(w, v, _extra)
    v = v and true or false            -- I4: setOn(v, true) is a real call shape
    local old = rg(w, '_on') == true
    rs(w, '_on', v)
    if old ~= v then fire(w, 'onCheckChange', v) end
    return w
end
function Wm.setOff(w) return Wm.setOn(w, false) end
function Wm.isChecked(w) return rg(w, '_checked') == true end
function Wm.setChecked(w, v)
    v = v and true or false
    local old = rg(w, '_checked') == true
    rs(w, '_checked', v)
    if old ~= v then fire(w, 'onCheckChange', v) end
    return w
end

-- ---- items -----------------------------------------------------------------
function Wm.getItemId(w) return rg(w, '_itemId') or 0 end
function Wm.setItemId(w, id)
    rs(w, '_itemId', tonumber(id) or 0)
    fire(w, 'onItemChange')            -- ALWAYS fires; there is no suppress arg
    return w
end
function Wm.getItem(w) return rg(w, '_item') end
function Wm.setItem(w, item)
    rs(w, '_item', item)
    if type(item) == 'table' and item.getId then
        local ok, id = pcall(item.getId, item)
        if ok then rs(w, '_itemId', id) end
    end
    fire(w, 'onItemChange')
    return w
end
function Wm.getItemCount(w) return rg(w, '_itemCount') or 0 end
function Wm.setItemCount(w, n) rs(w, '_itemCount', tonumber(n) or 0); return w end
Wm.getItemCountOrSubType = Wm.getItemCount
function Wm.setItemSubType(w, n) rs(w, '_itemSub', tonumber(n) or 0); return w end
function Wm.getItemSubType(w) return rg(w, '_itemSub') or 0 end

-- ---- combo boxes -----------------------------------------------------------
function Wm.addOption(w, text, data)
    local o = rg(w, '_options')
    o[#o + 1] = { text = tostring(text), data = data }
    if #o == 1 then                       -- the first option auto-selects
        rs(w, '_current', 1)
        fire(w, 'onOptionChange', o[1].text, o[1].data)
    end
    return w
end
function Wm.getCurrentOption(w)
    local o = rg(w, '_options')
    return o[rg(w, '_current') or 0]
end
function Wm.setCurrentOption(w, text)
    local o = rg(w, '_options')
    for i, e in ipairs(o) do
        if e.text == text then
            if rg(w, '_current') ~= i then
                rs(w, '_current', i)
                fire(w, 'onOptionChange', e.text, e.data)
            end
            return w
        end
    end
    return w
end
function Wm.setCurrentIndex(w, i)
    local o = rg(w, '_options')
    if o[i] then
        rs(w, '_current', i)
        fire(w, 'onOptionChange', o[i].text, o[i].data)
    end
    return w
end
function Wm.getCurrentIndex(w) return rg(w, '_current') or 0 end
function Wm.getOptionsCount(w) return #rg(w, '_options') end
function Wm.clearOptions(w) rs(w, '_options', {}); rs(w, '_current', nil); return w end

-- ---- tree ------------------------------------------------------------------
function Wm.addChild(w, c)
    if not isWidget(c) then return w end
    local kids = rg(w, '_children')
    kids[#kids + 1] = c
    rs(c, '_parent', w)
    local id = rg(c, '_id')
    if id and id ~= '' then Wm.setId(c, id) end
    return w
end
Wm.insertChild = function(w, index, c) return Wm.addChild(w, c) end
function Wm.removeChild(w, c)
    local kids = rg(w, '_children')
    for i = 1, #kids do
        if kids[i] == c then
            table.remove(kids, i)
            local id = rg(c, '_id')
            if id and id ~= '' then
                rg(w, '_byId')[id] = nil
                if rg(w, '_f')[id] == c then rg(w, '_f')[id] = nil end
            end
            rs(c, '_parent', nil)
            -- destroying/hiding the focused child re-focuses the PREVIOUS sibling
            if rg(w, '_focused') == c then
                rs(w, '_focused', kids[math.max(1, i - 1)])
                fire(w, 'onChildFocusChange', rg(w, '_focused'), c)
            end
            return w
        end
    end
    return w
end
-- PROVISIONAL DEVIATION: the returned list answers an out-of-range index with an
-- anything instead of nil.  vBot/playerlist.lua:237 does
-- `TabBar.buttonsPanel:getChildren()[v]` on a tab bar whose buttons come from an
-- .otui tree this backend cannot build (api-platform.md sec.3.5).  It is a COPY,
-- so `#`, ipairs and pairs still see exactly the real children.
local CHILDREN_VIEW_MT = {
    __index = function(t, k) return mkany('getChildren()[' .. tostring(k) .. ']') end,
}
function Wm.getChildren(w)
    local src = rg(w, '_children')
    local out = {}
    for i = 1, #src do out[i] = src[i] end
    return setmetatable(out, CHILDREN_VIEW_MT)
end
function Wm.getChildCount(w) return #rg(w, '_children') end
function Wm.getChildById(w, id) return rg(w, '_byId')[tostring(id)] end
function Wm.recursiveGetChildById(w, id)
    local hit = rg(w, '_byId')[tostring(id)]
    if hit then return hit end
    for _, c in ipairs(rg(w, '_children')) do
        local r = Wm.recursiveGetChildById(c, id)
        if r then return r end
    end
    return nil
end
function Wm.getChildByIndex(w, i)
    local kids = rg(w, '_children')
    -- 1-based; i <= 0 counts from the end, so 0 is the LAST child
    if i <= 0 then i = #kids + i end
    return kids[i]
end
function Wm.getChildIndex(w, child)
    if child == nil then
        -- the widget's OWN index in its parent (cavebot/cavebot.lua:214)
        local p = rg(w, '_parent')
        if not p then return -1 end
        for i, c in ipairs(rg(p, '_children')) do if c == w then return i end end
        return -1
    end
    for i, c in ipairs(rg(w, '_children')) do if c == child then return i end end
    return -1
end
function Wm.getFirstChild(w) return rg(w, '_children')[1] end
function Wm.getLastChild(w) local k = rg(w, '_children'); return k[#k] end
-- PROVISIONAL DEVIATION: an orphan widget answers with an `anything` instead of
-- nil.  vBot/new_healer.lua:711-712 does `widget:getParent():getParent().title` on
-- widgets whose real parents come from an .otui tree this backend cannot build, and
-- a nil there is an import-time crash.  shim/g_ui.lua must return nil for a real
-- root.  (getChildIndex(nil) reads `_parent` raw, so it is unaffected.)
function Wm.getParent(w)
    local p = rg(w, '_parent')
    if p ~= nil then return p end
    local ghost = rg(w, '_ghostParent')
    if ghost == nil then
        ghost = mkany(rg(w, '_style') .. '.<detached-parent>')
        rs(w, '_ghostParent', ghost)
    end
    return ghost
end
function Wm.moveChildToIndex(w, c, i)
    Wm.removeChild(w, c)
    table.insert(rg(w, '_children'), i, c)
    rs(c, '_parent', w)
    return w
end
function Wm.destroyChildren(w)
    local kids = rg(w, '_children')
    for i = #kids, 1, -1 do Wm.destroy(kids[i]) end
    return w
end
Wm.clear = Wm.destroyChildren
function Wm.destroy(w)
    local p = rg(w, '_parent')
    if p then Wm.removeChild(p, w) end
    rs(w, '_destroyed', true)
    return w
end
function Wm.isDestroyed(w) return rg(w, '_destroyed') == true end

-- ---- focus -----------------------------------------------------------------
function Wm.focus(w)
    local p = rg(w, '_parent')
    if p then return Wm.focusChild(p, w) end
    return w
end
function Wm.focusChild(w, c, reason)
    local old = rg(w, '_focused')
    if old == c then return w end
    rs(w, '_focused', c)
    if c then fire(c, 'onFocusChange', true) end
    if old then fire(old, 'onFocusChange', false) end
    fire(w, 'onChildFocusChange', c, old, reason)
    return w
end
function Wm.getFocusedChild(w) return rg(w, '_focused') end
function Wm.focusNextChild(w)
    local kids = rg(w, '_children')
    local i = Wm.getChildIndex(w, rg(w, '_focused'))
    return Wm.focusChild(w, kids[(i < 1 and 1 or i) + 1] or kids[1])
end
function Wm.focusPreviousChild(w)
    local kids = rg(w, '_children')
    local i = Wm.getChildIndex(w, rg(w, '_focused'))
    return Wm.focusChild(w, kids[i - 1] or kids[#kids])
end

-- ---- visibility ------------------------------------------------------------
function Wm.isVisible(w) return rg(w, '_visible') ~= false end
function Wm.setVisible(w, v)
    v = v and true or false
    local old = rg(w, '_visible') ~= false
    rs(w, '_visible', v)
    if old ~= v then fire(w, 'onVisibilityChange', v) end
    if not v then
        local p = rg(w, '_parent')
        if p and rg(p, '_focused') == w then Wm.focusPreviousChild(p) end
    end
    return w
end
function Wm.show(w) return Wm.setVisible(w, true) end
function Wm.hide(w) return Wm.setVisible(w, false) end
function Wm.setEnabled(w, v) rs(w, '_enabled', v and true or false); return w end
function Wm.isEnabled(w) return rg(w, '_enabled') ~= false end
Wm.enable  = function(w) return Wm.setEnabled(w, true) end
Wm.disable = function(w) return Wm.setEnabled(w, false) end

-- ---- geometry: stored, never real (api-ui.md sec.9.4) ----------------------
local ZERO_GETTERS = {
    getWidth = 0, getHeight = 0, getX = 0, getY = 0, getPercent = 0, getStep = 0,
    getMarginTop = 0, getMarginLeft = 0, getMarginRight = 0, getMarginBottom = 0,
    getOpacity = 1,
}
for name, v in pairs(ZERO_GETTERS) do Wm[name] = function() return v end end
function Wm.getSize() return { width = 0, height = 0 } end
function Wm.getRect() return { x = 0, y = 0, width = 0, height = 0 } end
function Wm.getPosition() return { x = 0, y = 0 } end
function Wm.getLayout() return nil end     -- bot.lua:159 null-checks it
function Wm.getTooltip(w) return rg(w, '_tooltip') or '' end
function Wm.setTooltip(w, t) rs(w, '_tooltip', t); return w end

Wmt = {
    __index = function(t, k)
        local f = rg(t, '_f')[k]
        if f ~= nil then return f end
        local m = Wm[k]
        if m ~= nil then return m end
        local kids = rg(t, '_kids')
        local c = kids[k]
        if c == nil then
            -- Unknown key.  In the real client this is a CHILD WIDGET installed by
            -- setId while the .otui style tree was built; this backend has no style
            -- engine, so it mints the child on first access.  A real widget rather
            -- than an anything, because the code that reaches for these does real
            -- work with them -- functions/config.lua:154-160 calls
            -- `widget.list:clear() / :addOption(k) / :setCurrentIndex(i) /
            -- :getCurrentOption().text` and stores the RESULT in the user's bot
            -- storage.  With an anything there, `storage._configs[dir].selected`
            -- becomes a stub object and every later config read is poisoned.
            c = newWidget(rg(t, '_style') .. '.' .. tostring(k))
            rs(c, '_id', tostring(k))
            rs(c, '_parent', t)
            kids[k] = c
        end
        return c
    end,
    __newindex = function(t, k, v) rg(t, '_f')[k] = v end,
    -- An unknown key mints a child widget, and `w:someUnimplementedMethod()` then
    -- CALLS that child.  Calling a widget is the cosmetic-no-op path (api-ui.md
    -- sec.9.4: raise/lower/setColor/setImageSource/... may return self and do
    -- nothing), so it returns the receiver and keeps the `w:setX():setY()` chain
    -- alive.
    __call = function(t, ...) return t end,
    __tostring = function(t)
        return ('W<%s#%s>'):format(rg(t, '_style'), rg(t, '_id'))
    end,
    __len = function(t) return #rg(t, '_children') end,
}

local function provisionalUI()
    local root = newWidget('UIWidget')
    Wm.setId(root, 'root')
    local styles = {}
    local ui = {}
    function ui.createWidget(style, parent)
        local w = newWidget(tostring(style), parent)
        fire(w, 'onCreate')
        return w
    end
    function ui.loadUIFromString(otml, parent)
        -- No OTML parser here (that is shim/g_ui.lua's job).  Return a real widget
        -- so `:setId()` / indexing works; its declared children do not exist.
        return newWidget('fromString', parent)
    end
    function ui.loadUI(path, parent) return newWidget('fromFile', parent) end
    function ui.displayUI(path, parent) return newWidget('fromFile', parent) end
    function ui.importStyle(path) styles[#styles + 1] = tostring(path); return true end
    function ui.importStyleFromString(text) return true end
    function ui.getRootWidget() return root end
    function ui.isWidget(v) return isWidget(v) end
    ui._styles = styles
    ui._newWidget = newWidget
    return ui, root
end
bootstrap.provisionalUI = provisionalUI
bootstrap.isWidget = isWidget

-- ===========================================================================
-- 3. otclient's own pure Lua  (PLAN sec.1.13)
-- ===========================================================================
-- Loaded VERBATIM and IN ORDER.  Everything here is data or pure helpers; the
-- class tables (Creature/Item/Tile/...) must already be in G, which is why this
-- runs at step 8 and not earlier (A4 blocker #5).

local OTLUA = {
    'modules/corelib/const.lua',
    'modules/corelib/bitwise.lua',
    'modules/gamelib/const.lua',
    'modules/gamelib/position.lua',
    'modules/gamelib/player.lua',
    'modules/gamelib/creature.lua',
    'modules/gamelib/textmessages.lua',
    'modules/gamelib/spells.lua',
    'modules/gamelib/items.lua',
    'modules/gamelib/thing.lua',
    'modules/gamelib/tile.lua',
    'modules/gamelib/util.lua',
}

local function readHostFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('*a'); f:close(); return s
end

local function loadOtLua(G, otRoot, report)
    for _, rel in ipairs(OTLUA) do
        local src = readHostFile(otRoot .. '/' .. rel)
        if not src then
            report[#report + 1] = { name = rel, ok = false, err = 'not found' }
        else
            local f, err = load(src, '@' .. rel, 't', G)
            if not f then
                report[#report + 1] = { name = rel, ok = false, err = 'compile: ' .. tostring(err) }
            else
                local ok, e = pcall(f)
                report[#report + 1] = { name = rel, ok = ok, err = (not ok) and tostring(e) or nil }
            end
        end
    end
end

-- game_spelllist/spelllist.lua is loaded into ITS OWN sandbox env, which then
-- becomes modules.game_spelllist -- that is how getSpelllistProfile() is real
-- rather than a constant.  Its ~600 remaining lines are widget code that only
-- runs from the spell-list window, which never opens headless.
local function loadSpelllist(G, otRoot, report)
    local rel = 'modules/game_spelllist/spelllist.lua'
    local src = readHostFile(otRoot .. '/' .. rel)
    if not src then
        report[#report + 1] = { name = rel, ok = false, err = 'not found' }
        return nil
    end
    local env = setmetatable({}, { __index = G })
    local f, err = load(src, '@' .. rel, 't', env)
    if not f then
        report[#report + 1] = { name = rel, ok = false, err = 'compile: ' .. tostring(err) }
        return nil
    end
    local ok, e = pcall(f)
    report[#report + 1] = { name = rel, ok = ok, err = (not ok) and tostring(e) or nil }
    return ok and env or nil
end

-- ===========================================================================
-- 4. start / stop / status
-- ===========================================================================

local current = nil       -- the single live boot; PLAN I10 -- one engine at a time

--- start(LC, opts) -> handle | nil, err
---   opts.otRoot    the otclient checkout (READ-ONLY)   default D:/Claude/otclient_mehah1530/otclient
---   opts.writeDir  the g_resources root                default <otRoot>/profiles
---   opts.config    the /bot/<dir> name                 default 'vBot_4.8'
---   opts.profile   g_settings.getNumber('profile')     default 1
---   opts.tickMs    the executor tick                   default 10
---   opts.readOnly  refuse every g_resources write      default true
---   opts.arm       arm the sched timer                 default false (tests tick by hand)
---   opts.strict    unimplemented APIs raise            default false
---   opts.storage   override the decoded bot storage    (tests)
function bootstrap.start(LC, opts)
    opts = opts or {}
    if current then return nil, 'shim already started; call shim.stop() first' end
    if type(LC) ~= 'table' or type(LC.state) ~= 'table' then
        error('shim.start: LC.state is required', 2)
    end

    local otRoot = (opts.otRoot or 'D:/Claude/otclient_mehah1530/otclient'):gsub('\\', '/'):gsub('/+$', '')
    local writeDir = opts.writeDir or (otRoot .. '/profiles')
    local log = opts.log or LC.log or require('lib.log')
    local boot = {}     -- ordered { step, ok, err }
    local function step(name, fn)
        local ok, err = pcall(fn)
        boot[#boot + 1] = { step = name, ok = ok, err = (not ok) and tostring(err) or nil }
        if not ok and log and log.error then
            log.error('shim/bootstrap: step %s failed: %s', name, tostring(err))
        end
        return ok
    end

    local S = { LC = LC, otRoot = otRoot, writeDir = writeDir, boot = boot,
                otlua = {}, log = log, config = opts.config or 'vBot_4.8' }

    -- 1 ----------------------------------------------------------------------
    local G = bootstrap.newG()
    S.G = G

    -- 2/3 --------------------------------------------------------------------
    step('corelib', function()
        local corelib = require('shim.corelib')
        S.corelib = corelib.install(G, { sched = LC.sched or require('lib.sched') })
    end)

    -- 4 ----------------------------------------------------------------------
    step('platform', function()
        local platform = require('shim.platform')
        S.platform = platform
        platform.install(G, {
            os = 'windows',
            onTitle = opts.onTitle,
            onExit  = opts.onExit,
        })
    end)
    step('resources', function()
        local resources = require('shim.resources')
        G.g_resources = resources.new(writeDir)
        S.resources = G.g_resources
    end)
    step('settings', function()
        local settings = require('shim.settings')
        G.g_settings = settings.new({
            resources = G.g_resources,
            path = '/shim_settings.json',
            load = false,                 -- never read or write the user's client config
            defaults = { profile = tonumber(opts.profile) or 1 },
        })
    end)

    -- 7 ----------------------------------------------------------------------
    step('game-layer', function()
        local objects = require('shim.object')
        require('shim.creature'); require('shim.tile')
        require('shim.item');     require('shim.container')
        local reg = objects.new(LC, { strict = opts.strict })
        S.reg = reg
        -- Order matters: g_map's getMinimapColor falls back to g_minimap for a tile
        -- the client does not hold, so g_minimap has to exist first (S1 boot order).
        -- Both default to LC.minimap, which main.lua loads from the reference
        -- client's profiles/minimap.otmm before it calls shim.start -- without it
        -- every long-range CaveBot goto has no path at all (risk B1).
        local mopts = {}
        for k, v in pairs(opts) do mopts[k] = v end
        mopts.known   = opts.known or LC.minimap
        mopts.minimap = opts.minimap or LC.minimap
        G.g_minimap = require('shim.g_minimap').new(LC, reg, mopts)
        mopts.gMinimap = G.g_minimap
        G.g_map     = require('shim.g_map').new(LC, reg, mopts)
        G.g_game    = require('shim.g_game').new(LC, reg, opts)
        G.g_things  = require('shim.g_things').new(LC, reg, opts)
        -- The class tables executor.lua copies onto the sandbox (executor.lua:139-150).
        G.Thing, G.Creature, G.Player = objects.Thing, objects.Creature, objects.Player
        G.LocalPlayer, G.Monster, G.Npc = objects.LocalPlayer, objects.Monster, objects.Npc
        G.Item, G.Tile, G.Container = objects.Item, objects.Tile, objects.Container
        G.ThingType = objects.ThingType
        -- Present-but-inert: 0 live call sites, but executor.lua reads the names.
        G.Effect, G.Missile, G.StaticText = {}, {}, {}
        G.OutputMessage, G.HTTP = nil, nil
    end)

    -- 8 ----------------------------------------------------------------------
    step('otlua', function()
        loadOtLua(G, otRoot, S.otlua)
        S.spelllistEnv = loadSpelllist(G, otRoot, S.otlua)
        for _, e in ipairs(S.otlua) do
            if not e.ok and log and log.warn then
                log.warn('shim/bootstrap: %s did not load: %s', e.name, tostring(e.err))
            end
        end
    end)

    -- 9 ----------------------------------------------------------------------
    step('g_ui', function()
        local ok, real = pcall(require, 'shim.g_ui')
        if ok and type(real) == 'table' and type(real.new) == 'function' then
            G.g_ui = real.new(G, { resources = G.g_resources, otRoot = otRoot })
            S.ui = 'shim.g_ui'
        else
            local ui, root = provisionalUI()
            G.g_ui = ui
            S.uiRoot = root
            S.ui = 'provisional'
            if log and log.warn then
                log.warn('shim/bootstrap: shim/g_ui.lua is absent -- using the PROVISIONAL '
                         .. 'widget backend; widgets declared only in .otui files are '
                         .. 'permissive stubs, not real children')
            end
        end
        G.rootWidget = G.g_ui.getRootWidget and G.g_ui.getRootWidget() or nil
        -- `container.itemsPanel` (modules/game_containers/containers.lua:1073) is a
        -- Lua field the container WINDOW installs, and vBot/analyzer.lua:1111 reads
        -- it for every open container.  Give the registry a factory so the panel is
        -- a real widget tree over the container's real items.
        if S.reg then
            S.reg.mkItemsPanel = function(_, style)
                return G.g_ui.createWidget(style or 'UIWidget')
            end
        end
    end)

    -- 10 ---------------------------------------------------------------------
    step('modules', function()
        local mods = require('shim.modules')
        local tbl, ctl = mods.build(G, {
            config = S.config,
            LC = LC, log = log, strict = opts.strict,
            g_game = G.g_game,
            spelllistEnv = S.spelllistEnv,
            -- Every modules.* leaf is a REAL widget when a UI backend is present.
            -- It has to be: shim/modules.lua's recording newLeaf answers EVERY
            -- unknown key with a no-op function, and `vBot/quiver_label.lua:2`
            -- reads `modules.game_inventory.getSlot5().count` expecting nil for an
            -- absent child -- a function there defeats the `label = label or
            -- g_ui.loadUIFromString(...)` fallback and the file dies at line 32.
            -- A real widget returns nil for an absent field, so the fallback runs.
            -- The leaf paths ('game_interface.mapPanel') are NOT style names -- they
            -- are dotted module paths -- so a bare UIWidget is minted and given the
            -- last path component as its id.  Asking g_ui for the dotted name first
            -- would only produce one "not a defined style" warning per leaf.
            -- The cost is that leaf calls are not counted in status().stubs, which
            -- therefore reports module-level stubs only.
            widget = function(name)
                local w = G.g_ui.createWidget('UIWidget')
                if w and w.setId then pcall(w.setId, w, (name:match('([^.]+)$') or name)) end
                return w
            end,
            onForceExit = opts.onForceExit,
            onRelog     = opts.onRelog,
            options     = opts.clientOptions,
        })
        G.modules = tbl
        S.modules = tbl
        S.modulesCtl = ctl
    end)

    -- 11 ---------------------------------------------------------------------
    local host = require('shim.host')
    S.host = host.new({
        G = G, LC = LC, resources = G.g_resources, otRoot = otRoot,
        config = S.config, profile = tonumber(opts.profile) or 1,
        readOnly = opts.readOnly ~= false,
        storage = opts.storage,
        log = log,
        mkWidget = function(style) return G.g_ui.createWidget(style) end,
        onMessage = opts.onMessage,
        saveEvery = opts.saveEvery,
        clock = opts.clock,
    })
    -- The sell-exception hand-over, BEFORE the tree loads.  vBot/depositer_config
    -- .lua:228 mirrors modules.game_npctrade's list into `storage.cavebotSell` at
    -- load time; with an empty list that silently wipes the user's own list, and a
    -- later save persists the loss.  See shim/modules.lua:seedSellExceptions.
    step('sell-exceptions', function()
        local ctl = S.modulesCtl
        if not (ctl and ctl.npctrade and ctl.npctrade.seedSellExceptions) then return end
        local ok2, storage = pcall(S.host.loadStorage, S.host)
        if ok2 and type(storage) == 'table' then
            ctl.npctrade.seedSellExceptions(storage.cavebotSell)
        end
    end)

    local ok, err = S.host:start()
    boot[#boot + 1] = { step = 'host', ok = ok, err = (not ok) and tostring(err) or nil }

    -- 12 ---------------------------------------------------------------------
    -- LC.events -> the executor's callback dispatchers.  Without this every
    -- onTalk / onCreatureAppear / onContainerOpen in the user's tree registers and
    -- never fires, so the bot only ever reacts to polled state.
    if ok and opts.callbacks ~= false then
        step('callbacks', function()
            local cbmod = require('shim.callbacks')
            local h, cerr = cbmod.install(LC, S.host.exec and S.host.exec.callbacks, {
                reg = S.reg, g_game = G.g_game, log = log,
                cooldown = S.modulesCtl and S.modulesCtl.cooldown,
                modules = G.modules,
                -- the imbuement family and onGameEditText are g_game SIGNALS, not
                -- executor dispatchers: cavebot/imbuing.lua:151 does
                -- connect(g_game, { onUpdateImbuementTracker = ... }).  The bridge needs
                -- corelib's own signalcall so a connected slot list dispatches the way
                -- modules/corelib/util.lua:42-119 does.
                signalcall = G.signalcall,
                G = G,
            })
            if not h then error(tostring(cerr), 0) end
            S.callbacks = h
        end)
    end

    if ok and opts.arm then S.host:arm(opts.tickMs or 10) end

    current = S
    return S, (not ok) and err or nil
end

--- One manual tick (tests, and the reactor when opts.arm is false).
--- Wrap every macro with a run counter (see host:instrumentMacros).  Call it
--- after start() and before the first tick.
function bootstrap.instrumentMacros(opts)
    if not current or not current.host then return 0 end
    return current.host:instrumentMacros(opts)
end

function bootstrap.tick()
    if not current or not current.host then return false, 'not started' end
    return current.host:tick()
end

function bootstrap.stop()
    if not current then return false, 'not started' end
    local S = current
    if S.callbacks then pcall(function() S.callbacks:remove() end); S.callbacks = nil end
    if S.host then S.host:stop() end
    if S.G and S.G.g_game and S.G.g_game._shutdown then pcall(S.G.g_game._shutdown) end
    if S.corelib and S.corelib.uninstall then S.corelib.uninstall() end
    if S.reg and S.reg.detach then pcall(S.reg.detach, S.reg) end
    current = nil
    return true
end

--- status() -> the deliverable table: what booted, what loaded, what ticked.
function bootstrap.status()
    if not current then return { started = false } end
    local S = current
    local st = S.host and S.host:status() or {}
    st.started  = st.started or false
    st.ui       = S.ui
    st.boot     = S.boot
    st.otlua    = S.otlua
    st.otRoot   = S.otRoot
    st.writeDir = S.writeDir
    st.stubs    = S.modulesCtl and S.modulesCtl.report() or {}
    -- NOT `st.callbacks` -- host:status() already uses that name for the COUNT of
    -- sandbox callbacks vBot registered.  This is the bridge's dispatch census.
    st.callbackBridge = S.callbacks and S.callbacks:stats() or nil
    st.hotkeyList = S.host and S.host:hotkeys() or {}
    return st
end

--- Every registered hotkey, by key description (blocker B2 diagnostics).
function bootstrap.hotkeys()
    if not current or not current.host then return {} end
    return current.host:hotkeys()
end

--- Fire a registered hotkey by its key description, e.g. shim.pressHotkey('Ctrl+F1').
--- There is no keyboard headless, so this is the ONLY way a hotkey or a hotkey-bound
--- macro switch can ever run; it drives the executor's real onKeyDown/onKeyPress/onKeyUp
--- path, so everything downstream behaves as if the user had pressed the key.
--- Returns true when something was bound to the combo, false when nothing was.
function bootstrap.pressHotkey(desc, opts)
    if not current or not current.host then return nil, 'not started' end
    return current.host:pressHotkey(desc, opts)
end

function bootstrap.handle() return current end
function bootstrap.G() return current and current.G end
function bootstrap.context() return current and current.host and current.host.context end

return bootstrap
