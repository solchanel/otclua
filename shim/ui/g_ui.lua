--[[============================================================================
shim/ui/g_ui.lua -- OTML/OTUI parsing, the style registry and `g_ui`
(work item S3; PLAN.md sec.1.9/1.10/1.12 folded into one file because this agent owns
shim/ui/ only -- see CROSS-FILE REQUESTS at the bottom).

    local ui = require('shim.ui.g_ui')
    local h  = ui.new{ env = SHIM_G, resources = g_resources }   -- both optional
    h.g_ui                       -- the singleton to put in SHIM_G
    h.styles                     -- the style registry (introspectable)
    h.g_ui.installBuiltinStyles()-- the ~55 base styles, no otclient tree needed
    h.g_ui.importStyle(path)     -- the real .otui files, which OVERRIDE the builtins

Nothing renders.  The parser exists because 638 `id:` declarations across 24 profile
`.otui` files build the trees vBot then addresses by name
(`healWindow.healer.spells.spellList`) -- api-ui.md sec.0.1.

--------------------------------------------------------------------------------
WHAT THE PARSER IMPLEMENTS  (src/framework/otml/otmlparser.cpp)
--------------------------------------------------------------------------------
 * indentation => tree; exactly 2 spaces per level; a tab raises
 * `tag: value`, `tag:` + block, `- item` list entries, bare `tag`
 * `|`, `|-`, `|+` literal blocks with the upstream trailing-newline rules
 * `//` and `#` line comments (upstream skips BOTH; note this makes the
   `#Style < Base` "unique style" syntax unreachable in this fork -- documented,
   not emulated)
 * `~` => null node (dropped from children(), like OTMLNode::children)
 * `[a, b, c]` => a list node
 * THE RULE THAT DECIDES EVERYTHING: `node->setUnique(dotsPos != npos)`
   (otmlparser.cpp:435).  A line CONTAINING A COLON is a PROPERTY; a line without
   one is a CHILD WIDGET.  That is why `layout:`, `anchors.fill:`, `$on:` and
   `@onSetup:` are never instantiated as widgets while `Panel` and
   `HorizontalSeparator` are.
 * OTMLNode::addChild's merge-on-duplicate-unique-tag rule (otmlnode.cpp:86-116),
   which is what makes `Name < Base` flattening produce the right children.

NOT implemented (and not needed by any file in this tree): `$`-variable expansion
(otmlparser.cpp:130-210 -- vBot uses `&x` only as a Lua field, never as `$x`), the
`http://` URL-key special case, and OTML document includes.

--------------------------------------------------------------------------------
WHAT applyStyle APPLIES AND WHAT IT DROPS  (api-ui.md sec.2)
--------------------------------------------------------------------------------
APPLIED (semantic)
    id  text  !text  tooltip  !tooltip  on  checked  visible  enabled  focusable
    auto-focus  phantom  item-id  item-count  minimum  maximum  step  value
    @<signal> (compiled as `function(self) ... end`, once, on the first style)
    &<field>  (evaluated as a Lua expression and set as a plain Lua field)
STORED BUT INERT (a getter round-trips; nothing else happens)
    color  background-color  image-source  font  text-align  icon / icon-source
DROPPED, and COUNTED in `styles.ignored` so "what we ignore" is measurable
    anchors.*  margin-*  padding*  width/height/size  image-*  text-offset
    text-wrap  layout  vertical-scrollbar  pixels-scroll  fit-children  opacity
    border-*  virtual  multiline  capacity  flow  cell-*  num-columns  ...
    every `$state:` sub-block  (api-ui.md sec.2 proves no vBot code reads one back)

--------------------------------------------------------------------------------
DELIBERATE DEVIATIONS (loud, not silent)
--------------------------------------------------------------------------------
 D1 `importStyle` on a file whose Nth style has an undefined base does NOT abort the
    whole file the way the C++ OTMLException does; that style is skipped, recorded in
    `styles.failed` and logged at warn level, and the rest of the file is imported.
    Rationale: the shim imports data/styles/*.otui piecemeal, so forward references
    between files are normal, and aborting would silently lose 40 later styles.
 D2 `setId` also installs the NUMERIC key when the id is a number string (widget.lua
    Q4).  Upstream stores only the string key and `ui[1]` works through the C++ field
    lookup; there is no Lua-side equivalent.
 D3 `loadUI` / `displayUI` are inert: bot.lua (their only two call sites) is replaced
    wholesale by shim/executor.lua.
============================================================================]]

local widget = require('shim.ui.widget')

local ok_log, log = pcall(require, 'lib.log')
if not ok_log then log = nil end

local M = {}

local function warn(fmt, ...)
    if log then log.warn(fmt, ...) else io.stderr:write('shim.ui: ' .. string.format(fmt, ...) .. '\n') end
end

-- ===========================================================================
-- 1. OTML node
-- ===========================================================================
local Node = {}
Node.__index = Node

local function newNode(tag, value)
    return setmetatable({ tag = tag or '', value = value or '', unique = false,
                          null = false, source = '', children = {} }, Node)
end
M.newNode = newNode

local function isNode(v) return getmetatable(v) == Node end

function Node:hasTag() return self.tag ~= nil and self.tag ~= '' end

--- otmlnode.cpp:86-116.  A duplicate tag where EITHER side is unique replaces the
--- old node in place, merging children first, and removes every other same-tag node.
function Node:addChild(child)
    if child:hasTag() then
        for i = 1, #self.children do
            local n = self.children[i]
            if n.tag == child.tag and (n.unique or child.unique) then
                child.unique = true
                if #n.children > 0 and #child.children > 0 then
                    local tmp = n:clone()
                    tmp:merge(child)
                    child:copyFrom(tmp)
                end
                self.children[i] = child
                for k = #self.children, 1, -1 do
                    if self.children[k] ~= child and self.children[k].tag == child.tag then
                        table.remove(self.children, k)
                    end
                end
                return child
            end
        end
    end
    self.children[#self.children + 1] = child
    return child
end

function Node:removeChild(child)
    for i = 1, #self.children do
        if self.children[i] == child then table.remove(self.children, i); return true end
    end
    return false
end

function Node:clone()
    local c = newNode(self.tag, self.value)
    c.unique, c.null, c.source = self.unique, self.null, self.source
    if self.list then c.list = { unpack and unpack(self.list) or table.unpack(self.list) } end
    for i = 1, #self.children do c:addChild(self.children[i]:clone()) end
    return c
end

function Node:copyFrom(other)
    self.tag, self.value = other.tag, other.value
    self.unique, self.null, self.source = other.unique, other.null, other.source
    self.children = {}
    for i = 1, #other.children do self:addChild(other.children[i]:clone()) end
end

--- otmlnode.cpp:149-156.
function Node:merge(other)
    for i = 1, #other.children do self:addChild(other.children[i]:clone()) end
    self.tag = other.tag
    self.source = other.source
end

function Node:get(tag)
    for i = 1, #self.children do
        if self.children[i].tag == tag and not self.children[i].null then return self.children[i] end
    end
    return nil
end

function Node:valueAt(tag, dflt)
    local n = self:get(tag)
    if n then return n.value end
    return dflt
end

--- otmlnode.cpp:168-176: null children are invisible to children().
function Node:visibleChildren()
    local out = {}
    for i = 1, #self.children do
        if not self.children[i].null then out[#out + 1] = self.children[i] end
    end
    return out
end

-- ===========================================================================
-- 2. the parser
-- ===========================================================================
local function ltrimCount(s)
    local n = 0
    while s:sub(n + 1, n + 1) == ' ' do n = n + 1 end
    return n
end

local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end
local function rtrim(s) return (s:gsub('[ \t\r]+$', '')) end

local function splitLines(text)
    local lines = {}
    for line in (text:gsub('\r\n', '\n') .. '\n'):gmatch('([^\n]*)\n') do
        lines[#lines + 1] = line
    end
    -- a trailing '' produced by the final newline carries no information
    if #lines > 0 and lines[#lines] == '' then lines[#lines] = nil end
    return lines
end

--- otmlparser.cpp:266-293
local function lineDepth(line, source, lineNo)
    if trim(line) == '' then return 0 end
    local spaces = ltrimCount(line)
    if spaces >= #line then spaces = #line - 1 end
    local ch = line:sub(spaces + 1, spaces + 1)
    if ch == '\t' then
        error(string.format('%s:%d: indentation with tabs are not allowed', source, lineNo), 0)
    end
    if spaces % 2 ~= 0 then
        error(string.format('%s:%d: must indent every 2 spaces', source, lineNo), 0)
    end
    return math.floor(spaces / 2)
end

--- otml.parse(text, source) -> root Node
function M.parse(text, source)
    source = source or '(string)'
    local lines = splitLines(tostring(text or ''))
    local root = newNode('')
    root.source = source

    local currentParent, previousNode = root, root
    local currentDepth = 0
    local parentMap = setmetatable({}, { __mode = 'k' })
    parentMap[root] = nil

    local i = 1
    while i <= #lines do
        local raw = lines[i]
        local lineNo = i
        i = i + 1

        local depth = lineDepth(raw, source, lineNo)
        local line = trim(raw)
        if line ~= '' and line:sub(1, 2) ~= '//' and line:sub(1, 1) ~= '#' then
            if depth == currentDepth + 1 then
                currentParent = previousNode
            elseif depth < currentDepth then
                for _ = 1, currentDepth - depth do
                    currentParent = parentMap[currentParent] or root
                end
            elseif depth ~= currentDepth then
                error(string.format('%s:%d: invalid indentation depth, are you indenting correctly?',
                                    source, lineNo), 0)
            end
            currentDepth = depth

            -- ------------------------------------------------ parseNode ---
            local l = rtrim(line)
            local tag, value = '', ''
            local dotsPos = l:find(':', 1, true)
            if l:sub(1, 1) == '-' then
                value = trim(l:sub(2))
            elseif dotsPos then
                tag = l:sub(1, dotsPos - 1)
                value = l:sub(dotsPos + 1)
            else
                tag = l
            end
            tag, value = trim(tag), trim(value)

            if value == '|' or value == '|-' or value == '|+' then
                local mode = value
                local parts = {}
                while i <= #lines do
                    local nl = lines[i]
                    local d = lineDepth(nl, source, i)
                    if d > currentDepth then
                        parts[#parts + 1] = nl:sub((currentDepth + 1) * 2 + 1)
                        i = i + 1
                    else
                        if trim(nl) ~= '' then break end
                        parts[#parts + 1] = ''
                        i = i + 1
                    end
                end
                local data = table.concat(parts, '\n') .. '\n'
                if mode == '|' or mode == '|-' then
                    data = data:gsub('\n+$', '')
                    if mode == '|' then data = data .. '\n' end
                end
                value = data
            end

            local node = newNode(tag, value)
            node.unique = dotsPos ~= nil
            node.source = source .. ':' .. lineNo
            if value == '~' then
                node.null = true
                node.value = ''
            elseif value:sub(1, 1) == '[' and value:sub(-1) == ']' then
                node.list = {}
                for tok in value:sub(2, -2):gmatch('[^,]+') do
                    node.list[#node.list + 1] = trim(tok)
                end
            end

            currentParent:addChild(node)
            parentMap[node] = currentParent
            previousNode = node
        end
    end
    return root
end

-- ===========================================================================
-- 3. value coercion
-- ===========================================================================
local function toBool(v)
    if type(v) == 'boolean' then return v end
    if type(v) == 'number' then return v ~= 0 end
    v = trim(tostring(v or '')):lower()
    return v == 'true' or v == '1' or v == 'yes' or v == 'on'
end
M.toBool = toBool

-- ===========================================================================
-- 4. the g_ui instance
-- ===========================================================================

--- The style properties that carry meaning headless.  Anything not listed here is
--- counted in `styles.ignored` and dropped.
local SEMANTIC = {
    ['id'] = true, ['text'] = true, ['tooltip'] = true, ['on'] = true,
    ['checked'] = true, ['visible'] = true, ['visibility'] = true, ['enabled'] = true,
    ['focusable'] = true, ['auto-focus'] = true, ['phantom'] = true,
    ['item-id'] = true, ['item-count'] = true, ['item-subtype'] = true,
    ['minimum'] = true, ['maximum'] = true, ['step'] = true, ['value'] = true,
    ['__class'] = true, ['__unique'] = true,
}

--- Cosmetic props that are REMEMBERED so a getter round-trips (api-ui.md sec.4.7).
local COSMETIC = {
    ['color'] = 'setColor', ['background-color'] = 'setBackgroundColor',
    ['background'] = 'setBackgroundColor', ['image-source'] = 'setImageSource',
    ['font'] = 'setFont', ['text-align'] = 'setTextAlign',
    ['icon'] = 'setIcon', ['icon-source'] = 'setIconSource',
}

--- ui.new{ env=, resources=, log= } -> { g_ui=, styles=, root= }
function M.new(opts)
    opts = opts or {}
    local ENV = opts.env                       -- SHIM_G; nil => the real _G
    local resources = opts.resources           -- shim/resources.lua g_resources

    local styles = {
        byName = {},          -- exact + lowercase, both pointing at the same node
        order = {},           -- import order, for introspection
        ignored = {},         -- property tag -> count of times dropped
        failed = {},          -- {name=, base=, source=} for D1
        files = {},           -- imported file paths, in order
    }

    local g_ui = {}
    local rootWidget

    -- ------------------------------------------------------- Lua snippets ---
    local function chunkEnv()
        return ENV or _G
    end

    --- `!tag: expr` -> tostring(expr).   uiwidget.cpp:711-721
    local function evaluateExpression(expr, origin)
        local f, err = loadstring('return ' .. expr, origin)
        if not f then
            warn('shim.ui: bad OTML expression at %s: %s', tostring(origin), tostring(err))
            return nil
        end
        if setfenv then setfenv(f, chunkEnv()) end
        local ok, v = pcall(f)
        if not ok then
            warn('shim.ui: OTML expression failed at %s: %s', tostring(origin), tostring(v))
            return nil
        end
        return v
    end

    --- `@sig: body` -> function(self) body end.   luainterface.cpp loadFunction
    local function loadFunction(body, origin)
        local src
        if body:match('^%s*function') then src = 'return ' .. body
        else src = 'return function(self)\n' .. body .. '\nend' end
        local f, err = loadstring(src, origin)
        if not f then
            warn('shim.ui: bad OTML @function at %s: %s', tostring(origin), tostring(err))
            return nil
        end
        if setfenv then setfenv(f, chunkEnv()) end
        local ok, fn = pcall(f)
        if not ok then
            warn('shim.ui: OTML @function failed to load at %s: %s', tostring(origin), tostring(fn))
            return nil
        end
        return fn
    end

    -- ------------------------------------------------------ style registry ---
    local function register(name, node)
        styles.byName[name] = node
        styles.byName[name:lower()] = node
        styles.order[#styles.order + 1] = name
    end

    --- uimanager.cpp:527-547.  Exact, then lowercase, then the `UI*` auto-definition.
    local function getStyle(name)
        if type(name) ~= 'string' then return nil end
        local n = styles.byName[name]
        if n then return n end
        n = styles.byName[name:lower()]
        if n then return n end
        if name:sub(1, 2) == 'UI' then
            local node = newNode(name)
            node:addChild((function() local c = newNode('__class', name); c.unique = true; return c end)())
            register(name, node)
            return node
        end
        return nil
    end
    g_ui.getStyle = getStyle
    g_ui.getStyleName = function(n) local s = getStyle(n); return s and s.tag or '' end
    g_ui.getStyleClass = function(n) local s = getStyle(n); return s and s:valueAt('__class', '') or '' end

    --- uimanager.cpp:467-513.  `Name < Base` flattened at IMPORT time.
    local function importStyleFromNode(node)
        local tag = node.tag
        local lt, gt = tag:find('<', 1, true)
        if not lt then return false, 'not a valid style declaration' end
        local name = trim(tag:sub(1, lt - 1))
        local base = trim(tag:sub(lt + 1))
        if name == '' or base == '' then return false, 'not a valid style declaration' end

        local unique = false
        if name:sub(1, 1) == '#' then
            name = name:sub(2)
            unique = true
            node.tag = name
            local u = newNode('__unique', 'true'); u.unique = true
            node:addChild(u)
        end

        local old = styles.byName[name]
        if old and toBool(old:valueAt('__unique', 'false')) and not unique then
            return true                      -- a unique style is never redefined
        end

        local originalStyle = getStyle(base)
        if not originalStyle then
            return false, string.format("base style '%s' is not defined", base)
        end
        local style = originalStyle:clone()
        style:merge(node)
        style.tag = name
        register(name, style)
        return true
    end
    M.importStyleFromNode = importStyleFromNode

    --- D1: per-style tolerance instead of the C++ per-file abort.
    local function importDocument(doc, source)
        local n = 0
        for _, node in ipairs(doc:visibleChildren()) do
            if node.tag:find('<', 1, true) then
                local ok, err = importStyleFromNode(node)
                if ok then n = n + 1
                else
                    styles.failed[#styles.failed + 1] = { name = node.tag, source = source, err = err }
                    warn("shim.ui: skipped style '%s' from %s: %s", node.tag, tostring(source), tostring(err))
                end
            end
        end
        return n
    end

    local function readFile(path)
        if resources and resources.readFileContents then
            return resources.readFileContents(path)      -- raises on a miss (I6)
        end
        local f, err = io.open(path, 'rb')
        if not f then error('unable to read ' .. tostring(path) .. ': ' .. tostring(err), 0) end
        local data = f:read('*a'); f:close()
        return data
    end

    function g_ui.importStyleFromString(text, source)
        local doc = M.parse(text, source or '(string)')
        return importDocument(doc, source or '(string)')
    end

    function g_ui.importStyle(path)
        if type(path) ~= 'string' then return false end
        if path:find('\n') then return g_ui.importStyleFromString(path) end
        local ok, data = pcall(readFile, path)
        if not ok then
            warn('shim.ui: importStyle could not read %s: %s', path, tostring(data))
            return false
        end
        styles.files[#styles.files + 1] = path
        local ok2, err = pcall(g_ui.importStyleFromString, data, path)
        if not ok2 then
            warn('shim.ui: importStyle failed on %s: %s', path, tostring(err))
            return false
        end
        return true
    end

    -- --------------------------------------------------------- applyStyle ---
    local function applyBaseProps(w, node)
        -- 1. @functions (only on the first style) and &fields.  parseBaseStyle:251-277
        local firstOnStyle = rawget(w, '__s').firstOnStyle
        for _, n in ipairs(node:visibleChildren()) do
            local t = n.tag
            if t:sub(1, 1) == '@' then
                if firstOnStyle then
                    local fn = loadFunction(n.value, '@' .. n.source .. ': [' .. t .. ']')
                    if fn then rawset(w, t:sub(2), fn) end
                end
            elseif t:sub(1, 1) == '&' then
                local field = t:sub(2)
                local v = trim(n.value)
                if v:sub(1, 1) == '#' then
                    rawset(w, field, v)
                else
                    rawset(w, field, evaluateExpression(v, '@' .. n.source .. ': [' .. t .. ']'))
                end
            end
        end

        -- 2. `id` first (uiwidget.cpp:1917-1919)
        local idNode = node:get('id')
        if idNode then w:setId(idNode.value) end

        -- 3. the semantic properties, in declaration order.  Only UNIQUE nodes are
        -- properties (otmlparser.cpp:435): a node whose line had no colon is a CHILD
        -- WIDGET and is instantiated by the caller instead.
        for _, n in ipairs(node:visibleChildren()) do
            local t = n.tag
            local c1 = t:sub(1, 1)
            if not n.unique then                                       -- a child widget
            elseif c1 == '@' or c1 == '&' or c1 == '$' then            -- handled / dropped
                if c1 == '$' then styles.ignored[t] = (styles.ignored[t] or 0) + 1 end
            elseif t == 'id' or t == '__class' or t == '__unique' then -- already done
            elseif t == 'text' then w:setText(n.value)
            elseif t == 'tooltip' then w:setTooltip(n.value)
            elseif t == 'on' then w:setOn(toBool(n.value))
            elseif t == 'checked' then w:setChecked(toBool(n.value))
            elseif t == 'visible' then w:setVisible(toBool(n.value))
            elseif t == 'visibility' then w:setVisible(trim(n.value) == 'visible')
            elseif t == 'enabled' then w:setEnabled(toBool(n.value))
            elseif t == 'focusable' then w:setFocusable(toBool(n.value))
            elseif t == 'auto-focus' then w:setAutoFocusPolicy(n.value)
            elseif t == 'phantom' then w:setPhantom(toBool(n.value))
            elseif t == 'pointer-events' then w:setPhantom(trim(n.value) == 'none')
            elseif t == 'item-id' then
                if w.setItemId then w:setItemId(tonumber(n.value) or 0) end
            elseif t == 'item-count' then
                if w.setItemCount then w:setItemCount(tonumber(n.value) or 0) end
            elseif t == 'item-subtype' then
                if w.setItemSubType then w:setItemSubType(tonumber(n.value) or 0) end
            elseif COSMETIC[t] then
                local setter = w[COSMETIC[t]]
                if setter then setter(w, n.value) end
            elseif SEMANTIC[t] then                                    -- min/max/step/value
                -- applied by the class-level onStyleApply below, like upstream
            else
                styles.ignored[t] = (styles.ignored[t] or 0) + 1
            end
        end
    end

    --- uiwidget.cpp:707-745.  `!` translation, the C++ virtual, the Lua onStyleApply,
    --- then the one-shot auto-focus rule.
    local function applyStyle(w, node)
        local s = rawget(w, '__s')
        if s.destroyed then return end

        -- `!tag: expr` -> tag with tostring(expr)
        for _, n in ipairs(node.children) do
            if n.tag:sub(1, 1) == '!' then
                local v = evaluateExpression('tostring(' .. n.value .. ')',
                                             '@' .. n.source .. ': [' .. n.tag .. ']')
                n.tag = n.tag:sub(2)
                n.value = (v == nil) and '' or tostring(v)
            end
        end

        applyBaseProps(w, node)

        -- the Lua-side class handler (UIScrollBar / UISpinBox min/max/step/value).
        -- It receives a FLAT name->value table, exactly what `pairs(styleNode)` gives
        -- the upstream Lua handlers.
        local flat = {}
        for _, n in ipairs(node:visibleChildren()) do
            if n.unique and #n.children == 0 then flat[n.tag] = n.value end
        end
        w:fire('onStyleApply', node.tag, flat)

        w:applyAutoFocus()
        s.firstOnStyle = false
    end
    g_ui.applyStyle = applyStyle

    -- ------------------------------------------------------ createWidget ---
    --- uimanager.cpp:706-742 verbatim, including "children before onSetup".
    local function createWidgetFromNode(widgetNode, parent)
        local original = getStyle(widgetNode.tag)
        if not original then
            error(string.format("'%s' is not a defined style", tostring(widgetNode.tag)), 0)
        end
        local node = original:clone()
        node:merge(widgetNode)

        local class = node:valueAt('__class', 'UIWidget')
        if class == '' then class = 'UIWidget' end

        local w = widget.new(class, node.tag)
        if parent then parent:addChild(w) end
        w:fire('onCreate')
        applyStyle(w, node)

        for _, childNode in ipairs(node:visibleChildren()) do
            -- a `- item` list entry has an empty tag and is not a widget; upstream
            -- would throw "'' is not a defined style" here, which loses the parent too.
            if not childNode.unique and childNode.tag ~= '' then
                createWidgetFromNode(childNode, w)
            end
        end

        w:fire('onSetup')
        return w
    end
    g_ui.createWidgetFromNode = createWidgetFromNode

    function g_ui.createWidget(styleName, parent)
        local node = newNode(styleName)
        local ok, w = pcall(createWidgetFromNode, node, parent)
        if not ok then
            warn("shim.ui: failed to create widget from style '%s': %s", tostring(styleName), tostring(w))
            return nil
        end
        return w
    end

    --- uimanager.cpp:663-692.  `&`-tags are skipped, `<`-tags import styles, and at
    --- most one plain tag becomes the widget.
    function g_ui.loadUIFromString(data, parent, source)
        source = source or '(string)'
        local ok, doc = pcall(M.parse, data, source)
        if not ok then
            warn('shim.ui: failed to load UI from string: %s', tostring(doc))
            return nil
        end
        local w
        for _, node in ipairs(doc:visibleChildren()) do
            local tag = node.tag
            if tag:sub(1, 1) == '&' then                    -- skip
            elseif tag:find('<', 1, true) then
                local ok2, err = importStyleFromNode(node)
                if not ok2 then
                    styles.failed[#styles.failed + 1] = { name = tag, source = source, err = err }
                    warn("shim.ui: skipped style '%s' from %s: %s", tag, source, tostring(err))
                end
            else
                if w then
                    warn('shim.ui: cannot have multiple main widgets in otui files (%s)', source)
                    return w
                end
                local ok3, res = pcall(createWidgetFromNode, node, parent)
                if not ok3 then
                    warn('shim.ui: failed to load UI from string: %s', tostring(res))
                    return nil
                end
                w = res
            end
        end
        return w
    end

    function g_ui.loadUI(name, parent)
        widget.rec('g_ui.loadUI', name)                     -- D3
        return nil
    end
    function g_ui.displayUI(name, parent)
        widget.rec('g_ui.displayUI', name)                  -- D3
        return nil
    end

    -- -------------------------------------------------------- root widget ---
    function g_ui.getRootWidget()
        if not rootWidget then
            rootWidget = widget.new('UIWidget', 'UIWidget')
            rootWidget:setId('root')
        end
        return rootWidget
    end
    function g_ui.setRootWidget(w) rootWidget = w; return w end

    -- inert singleton members vBot / corelib touch
    g_ui.isMouseGrabbed        = function() return false end
    g_ui.getDraggingWidget     = function() return nil end
    g_ui.getHoveredWidget      = function() return nil end
    g_ui.getKeyboardReceiver   = function() return g_ui.getRootWidget() end
    g_ui.getMouseReceiver      = function() return g_ui.getRootWidget() end
    g_ui.clearStyles           = function() styles.byName = {}; styles.order = {} end
    g_ui.getStyles             = function() return styles end

    -- ---------------------------------------------------- builtin styles ---
    --- The base styles every vBot `.otui` derives from, reduced to the properties
    --- that carry meaning headless.  Sources: data/styles/10-*.otui, 20-*.otui,
    --- 30-miniwindow.otui and mods/game_bot/ui/*.otui.  The ONLY non-cosmetic facts
    --- in those files are `__class`, `focusable`, `auto-focus`, `phantom` and the
    --- SlotComboBox `@onSetup` -- everything else is geometry or paint.  Importing
    --- the real files afterwards simply re-registers these names with the full
    --- (still mostly ignored) property set.
    local BUILTIN = [[
Label < UILabel
FlatLabel < UILabel
GameLabel < UILabel
MenuLabel < Label
Button < UIButton
TabButton < UIButton
TextButton < UIButton
ImageButton < UIButton
AddButton < UIButton
NextButton < UIButton
PreviousButton < UIButton
SmallButton < UIButton
CheckBox < UICheckBox
ThickCheckBox < UICheckBox
CheckBoxCircle < UICheckBox
ButtonBox < UICheckBox
QtCheckBox < UICheckBox
ColorBox < UICheckBox
TextEdit < UITextEdit
PasswordTextEdit < TextEdit
MultilineTextEdit < TextEdit
TextQtEdit < UITextEdit
SpinBox < TextEdit
  __class: UISpinBox
ComboBox < UIComboBox
ComboBoxRounded < ComboBox
ComboBoxPopupMenu < UIPopupMenu
ComboBoxPopupMenuButton < UIButton
ComboBoxPopupScrollMenu < UIPopupScrollMenu
ComboBoxPopupScrollMenuButton < UIButton
PopupMenu < UIPopupMenu
PopupMenuButton < UIButton
PopupMenuSeparator < UIWidget
PopupMenuShortcutLabel < Label
PopupScrollMenu < UIPopupScrollMenu
PopupScrollMenuButton < UIButton
PopupScrollMenuSeparator < UIWidget
Panel < UIWidget
  phantom: true
  auto-focus: first
ScrollablePanel < UIScrollArea
  phantom: true
  auto-focus: first
FlatPanel < Panel
ScrollableFlatPanel < ScrollablePanel
LightFlatPanel < Panel
TextList < UIScrollArea
  auto-focus: none
HorizontalList < UIScrollArea
VerticalList < UIScrollArea
HorizontalSeparator < UIWidget
  focusable: false
VerticalSeparator < UIWidget
  focusable: false
ScrollBarSlider < UIButton
ScrollBarValueLabel < Label
VerticalScrollBarSlider < ScrollBarSlider
HorizontalScrollBarSlider < ScrollBarSlider
VerticalScrollBar < UIScrollBar
  orientation: vertical
HorizontalScrollBar < UIScrollBar
  orientation: horizontal
VerticalQtScrollBar < UIScrollBar
  orientation: vertical
HorizontalQtScrollBar < UIScrollBar
  orientation: horizontal
SmallScrollBar < UIScrollBar
  orientation: vertical
ProgressBar < UIProgressBar
ThickProgressBar < ProgressBar
LifeProgressBar < UIProgressBar
HealthBar < ProgressBar
ManaBar < ProgressBar
Item < UIItem
Creature < UICreature
Splitter < UISplitter
ResizeBorder < UIResizeBorder
Window < UIWindow
HeadlessWindow < UIWindow
MainWindow < Window
StaticWindow < Window
StaticMainWindow < StaticWindow
MiniWindow < UIMiniWindow
  focusable: false
  &minimizedHeight: 20
MiniWindowContents < ScrollablePanel
PhantomMiniWindow < UIMiniWindow
  focusable: false
TabBar < UITabBar
TabBarPanel < Panel
TabBarButton < UIButton
MoveableTabBar < UIMoveableTabBar
TabBarRounded < TabBar
TabBarRoundedPanel < TabBarPanel
TabBarRoundedButton < TabBarButton
MoveableTabBarPanel < Panel
MoveableTabBarButton < UIButton
]]

    --- mods/game_bot/ui/*.otui, again reduced to the semantic half.  These five files
    --- are read verbatim from the tree when it is present (bot.lua:25-29 does exactly
    --- that); the copy here is what lets the shim and its tests run without it.
    local BUILTIN_BOT = [[
BotButton < Button
BotSwitch < Button
SmallBotSwitch < Button
BotLabel < Label
BotItem < Item
  virtual: true
  &selectable: true
  &editable: true
BotTextEdit < TextEdit
  focusable: false
BotSeparator < HorizontalSeparator
BotSmallScrollBar < SmallScrollBar
BotPanel < Panel
  ScrollablePanel
    id: content
    layout:
      type: verticalBox
  BotSmallScrollBar
    id: botPanelScroll
CaveBotLabel < Label
  focusable: true
SlotComboBoxPopupMenu < ComboBoxPopupMenu
SlotComboBoxPopupMenuButton < ComboBoxPopupMenuButton
SlotComboBox < ComboBox
  @onSetup: |
    self:addOption("Head")
    self:addOption("Neck")
    self:addOption("Back")
    self:addOption("Body")
    self:addOption("Right")
    self:addOption("Left")
    self:addOption("Leg")
    self:addOption("Feet")
    self:addOption("Finger")
    self:addOption("Ammo")
    self:addOption("Purse")
BotConfig < Panel
  ComboBox
    id: list
    &menuScroll: true
    &menuHeight: 450
    &menuScrollStep: 100
    &parentWidth: true
  Button
    id: switch
  Button
    id: add
    text: Add
  Button
    id: edit
    text: Edit
  Button
    id: remove
    text: Remove
BotContainer < Panel
  ScrollablePanel
    id: items
    layout:
      type: grid
  BotSmallScrollBar
    id: scroll
    step: 10
DualLabelPanel < Panel
  Label
    id: left
  Label
    id: right
LabelAndTextEditPanel < Panel
  Label
    id: left
  BotTextEdit
    id: right
SwitchAndButtonPanel < Panel
  SmallBotSwitch
    id: left
  BotButton
    id: right
DualScrollPanel < Panel
  SmallBotSwitch
    id: title
  HorizontalScrollBar
    id: scroll1
    minimum: 0
    maximum: 100
    step: 1
  HorizontalScrollBar
    id: scroll2
    minimum: 0
    maximum: 100
    step: 1
  BotTextEdit
    id: text
SingleScrollItemPanel < Panel
  BotItem
    id: item
  SmallBotSwitch
    id: title
  HorizontalScrollBar
    id: scroll
    minimum: 0
    maximum: 100
    step: 1
DualScrollItemPanel < Panel
  BotItem
    id: item
  SmallBotSwitch
    id: title
  HorizontalScrollBar
    id: scroll1
    minimum: 0
    maximum: 100
    step: 1
  HorizontalScrollBar
    id: scroll2
    minimum: 0
    maximum: 100
    step: 1
TwoItemsAndSlotPanel < Panel
  BotItem
    id: item1
  BotItem
    id: item2
  SlotComboBox
    id: slot
  SmallBotSwitch
    id: title
BotIcon < UIWidget
]]

    local builtinDone = false
    function g_ui.installBuiltinStyles()
        if builtinDone then return 0 end
        builtinDone = true
        local n = g_ui.importStyleFromString(BUILTIN, '(builtin-base)')
        n = n + g_ui.importStyleFromString(BUILTIN_BOT, '(builtin-game_bot)')
        return n
    end
    g_ui.builtinSource = { base = BUILTIN, bot = BUILTIN_BOT }

    --- Import the real base styles from a read-only otclient tree, in the order
    --- bot.lua:25-29 and the client's own module loader use.  Returns how many files
    --- were read; 0 means the tree is absent and the builtins stand alone.
    function g_ui.importBaseStyles(otRoot)
        if type(otRoot) ~= 'string' then return 0 end
        local files = {
            '/data/styles/10-labels.otui', '/data/styles/10-buttons.otui',
            '/data/styles/10-panels.otui', '/data/styles/10-separators.otui',
            '/data/styles/10-listboxes.otui', '/data/styles/10-scrollbars.otui',
            '/data/styles/20-smallscrollbar.otui', '/data/styles/10-checkboxes.otui',
            '/data/styles/10-textedits.otui', '/data/styles/20-popupmenus.otui',
            '/data/styles/10-comboboxes.otui', '/data/styles/20-spinboxes.otui',
            '/data/styles/10-progressbars.otui', '/data/styles/10-items.otui',
            '/data/styles/10-creatures.otui', '/data/styles/10-windows.otui',
            '/data/styles/20-tabbars.otui', '/data/styles/30-miniwindow.otui',
            '/mods/game_bot/ui/basic.otui', '/mods/game_bot/ui/panels.otui',
            '/mods/game_bot/ui/config.otui', '/mods/game_bot/ui/container.otui',
            '/mods/game_bot/ui/icons.otui',
        }
        local n = 0
        for _, rel in ipairs(files) do
            local path = otRoot .. rel
            local f = io.open(path, 'rb')
            if f then
                local data = f:read('*a'); f:close()
                styles.files[#styles.files + 1] = path
                local ok = pcall(g_ui.importStyleFromString, data, path)
                if ok then n = n + 1 end
            end
        end
        return n
    end

    widget.g_ui = g_ui           -- UITabBar:addTab needs it without a global
    return { g_ui = g_ui, styles = styles, parse = M.parse,
             getRootWidget = function() return g_ui.getRootWidget() end }
end

--[[--------------------------------------------------------------------------
CROSS-FILE REQUESTS  (owned by other work items; nothing here depends on them
being done, but the shim is not finished until they are)

 X1 PLAN.md sec.1.9/1.10 place the OTML parser in `shim/otml.lua` and the style
    registry in `shim/styles.lua`.  Work item S3 owns only `shim/ui/*`, so both live
    here: `uimod.parse` IS `otml.parse`, and the registry is the closure inside
    `M.new`.  If those two files are created later, make them wrappers around
    `M.parse` / `M.importStyleFromNode` rather than second implementations -- two
    OTML parsers is exactly the drift this project is trying to avoid.

 X2 `shim/init.lua` boot step 9 should be:
        local uimod  = require('shim.ui.g_ui')
        local uih    = uimod.new{ env = G, resources = G.g_resources }
        G.g_ui = uih.g_ui
        uih.g_ui.installBuiltinStyles()          -- always: the safety net
        uih.g_ui.importBaseStyles(opts.otRoot)   -- then the real files, which win
    `mods/game_bot/executor.lua:180` already imports every profile `.otui`, so the
    shim must NOT import those itself.

 X3 `shim/executor.lua` owns `context.tabs`, `context.mainTab`, `context.configDir`,
    `context.storage`, the msgCallback log channel and the `modules.*` graph.
    `shim/ui/helpers.lua:hostStubs` provides throwaway versions of exactly those, and
    every one of them yields to a pre-existing field, so executor.lua can install the
    real thing first and call `helpers.install(ENV, context, {stubs = false})`.

 X4 `shim/patches.lua` (PLAN sec.1.14) should absorb the audited patch currently held
    in `shim/ui/helpers.lua:M.PATCHES` -- the `type(self) == 'table'` widget-vs-items
    test at `mods/game_bot/functions/ui_elements.lua:60`, which is the SAME
    table-vs-userdata class of bug as the existing `functions/map.lua:22` entry.
    A SECOND instance of it exists at `profiles/bot/vBot_4.8/vBot/training.lua:511`
    and is NOT patched here (this work item does not load profile scripts): without a
    patch, `vBot/training.lua:507,554 widget:setItems(items)` silently loads an empty
    container.  Those are the only three `type(x) == 'table'/'userdata'` widget tests
    in the whole tree (verified by ripgrep over mods/game_bot and the profile).

 X5 `Item` must be in `SHIM_G` before any `UI.Container` is built: `ui_elements.lua:74`
    calls `Item.create(id, count)` and feeds the result to `setItem()`.  The widget
    model duck-types it (getId/getCount/getCountOrSubType, else `.id`/`.count`), so
    `shim/item.lua`'s wrapper drops straight in.
----------------------------------------------------------------------------]]

return M
