--[[============================================================================
shim/ui/helpers.lua -- the vBot UI helper surface (work item S3).

    local helpers = require('shim.ui.helpers')
    local h = helpers.install(ENV, context, { otRoot = ..., g_ui = ... })
    h.mode      -- 'real'  : the four files below were loaded FROM THE OTCLIENT TREE
                -- 'absent': the tree was not found; nothing was loaded, h.reason says so
    h.loaded    -- { 'ui.lua', 'ui_elements.lua', 'ui_legacy.lua', 'ui_windows.lua' }
    h.failed    -- { {file=, err=}, ... }
    context.UI  -- UI.createWidget / createWindow / createMiniWindow / Button / Label /
                -- Separator / TextEdit / Config / Container / DualLabel / ... (theirs)
    context.addSwitch / addButton / addLabel / addTextEdit / addSeparator /
    context.addTab / getTab / setDefaultTab / setupUI / importStyle       (theirs)

--------------------------------------------------------------------------------
THE FILES ARE RUN, NOT REIMPLEMENTED
--------------------------------------------------------------------------------
`mods/game_bot/functions/ui.lua` (33 lines), `ui_elements.lua` (408),
`ui_legacy.lua` (134) and `ui_windows.lua` (49) are pure Lua over `g_ui`, `modules`,
`Item` and `context`.  This module loads those four files VERBATIM from the read-only
otclient tree, in the same order `dofiles("functions")` gives them (alphabetical), in
the same environment they expect (the GLOBAL sandbox env, reading `G.botContext`) --
so the helper behaviour is upstream's, not this shim's, and a future vBot/game_bot
update ports over for free.  Nothing is copied, nothing is patched, nothing under
D:/Claude/otclient_mehah1530 is written (invariant I9).

If the tree is absent the module reports `mode='absent'` and installs NOTHING.  A
silent reimplementation would be exactly the drift this project exists to avoid, so
the caller (and the test suite) must skip with a printed reason instead.

--------------------------------------------------------------------------------
WHAT THIS MODULE *DOES* SUPPLY: the HOST side those four files call into
--------------------------------------------------------------------------------
These belong to `mods/game_bot/bot.lua` + `executor.lua`, which shim/executor.lua
replaces wholesale (PLAN sec.1.27).  Until that exists, `helpers.hostStubs` provides
the minimum the four ui files need, each one marked with its fidelity:

  context.tabs                    REAL   -- a UITabBar widget; addTab/getTab/tabs are
                                            the real uitabbar.lua semantics in
                                            shim/ui/widget.lua
  context.mainTab / context.panel REAL   -- tabs:addTab("Main", BotPanel).tabPanel.content
  context.configDir               REAL   -- "/bot/<config>"; context.importStyle joins it
  modules.game_interface
      .getRightPanel()            INERT  -- an orphan Panel; UI.createMiniWindow parents
                                            analyzer's 10 mini windows to it and never
                                            reads geometry back (api-ui.md sec.3)
  modules.client_textedit.edit()  BLOCKER-- a modal text editor.  Returns a dummy widget
                                            so `window.botWidget = true` cannot error;
                                            recorded.  Unreachable headless: every call
                                            site is inside an onClick (api-ui.md sec.8.1)
  context.displayGeneralBox()     BLOCKER-- same, for UI.ConfirmationWindow
  warn / info / error             REAL   -- routed to lib/log.lua
  Item                            REAL   -- shim/item.lua's factory when the sandbox has
                                            one, else widget.lua's value-object fallback

--------------------------------------------------------------------------------
KNOWN HEADLESS DIFFERENCES IN THE REAL HELPERS (api-ui.md sec.8.3 -- do not "fix")
--------------------------------------------------------------------------------
 * `UI.DualLabel` / `LabelAndTextEdit` / `SwitchAndButton` clamp a label width with
   `left:getWidth() > params.maxWidth`.  getWidth() is 0, so the clamp is skipped --
   which is the correct headless outcome, not a bug.
 * `UI.Container`'s `scrollToBottom()` is a no-op (the scrollbar is inert); it is
   already defensive about that upstream (ui_elements.lua:28-33).
 * `UI.createMiniWindow` calls `widget:setup()`; that is a recorded no-op.
 * `UI.EditorWindow` / `ConfirmationWindow` never open anything.
============================================================================]]

local widget = require('shim.ui.widget')

local ok_log, log = pcall(require, 'lib.log')
if not ok_log then log = nil end

local M = {}

--- The four files, in `dofiles("functions")` (alphabetical) order.
M.FILES = { 'ui.lua', 'ui_elements.lua', 'ui_legacy.lua', 'ui_windows.lua' }

local CANDIDATE_ROOTS = {
    'D:/Claude/otclient_mehah1530/otclient',
    '/mnt/d/Claude/otclient_mehah1530/otclient',
}

local function readable(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local d = f:read('*a'); f:close()
    return d
end

-- ===========================================================================
-- AUDITED SOURCE PATCHES  (PLAN.md sec.1.14; the tree itself is never written)
-- ===========================================================================
-- Upstream distinguishes `widget.setItems(itemsTable)` from `widget:setItems(items)`
-- by testing `type(self) == 'table'` -- which works only because a live otclient
-- widget is USERDATA.  The shim's widgets are Lua tables (api-ui.md sec.9.2 and
-- shim/ui/widget.lua), so the colon form silently discards its argument and every
-- `ui.items:setItems(data.items)` (targetbot/looting.lua:58-59, vBot/Dropper.lua:106,
-- eat_food.lua:33, tools.lua:56, depositer_config.lua:239, Containers.lua:459)
-- loads an EMPTY container.  That is the single highest-impact table-vs-userdata
-- divergence in the UI surface, and it is silent -- exactly the failure mode this
-- project is trying to avoid.
--
-- The rewrite is minimal and behaviour-preserving in the live client too: `self` is
-- the container widget only in the colon form, so comparing against the `widget`
-- upvalue is a strictly better discriminator than a type test.
--
-- Each entry FAILS LOUDLY when `expected` is not found verbatim (upstream drifted).
--
-- THE TABLE ITSELF NOW LIVES IN shim/patches.lua (PLAN sec.1.14), which is what
-- the production loader (shim/host.lua) applies.  Keeping a second copy here is
-- exactly the drift this project is avoiding, so this is a view over that one,
-- re-keyed from the loader's virtual path ('functions/ui_elements.lua') to the
-- bare file name this module loads by.
local patchmod = require('shim.patches')

M.PATCHES = {}
for _, p in ipairs(patchmod.LIST['functions/ui_elements.lua'] or {}) do
    M.PATCHES[#M.PATCHES + 1] = {
        file = 'ui_elements.lua', why = p.why,
        expected = p.expected, replacement = p.replacement,
    }
end

--- Apply the audited patches for `name`.  Returns text, applied[], and raises when a
--- patch's `expected` text is absent.
function M.applyPatches(name, text)
    local applied = {}
    for _, p in ipairs(M.PATCHES) do
        if p.file == name then
            local from, to = text:find(p.expected, 1, true)
            if not from then
                error(string.format(
                    'shim.ui.helpers: patch for %s no longer applies (upstream drifted): %s',
                    name, p.why), 0)
            end
            if text:find(p.expected, to + 1, true) then
                error(string.format('shim.ui.helpers: patch for %s matches more than once', name), 0)
            end
            text = text:sub(1, from - 1) .. p.replacement .. text:sub(to + 1)
            applied[#applied + 1] = p.why
        end
    end
    return text, applied
end

--- helpers.findRoot([hint]) -> otRoot | nil
--- Resolves the READ-ONLY otclient tree: an explicit hint first, then this checkout's
--- own sibling directory (so the identical path works on Windows and under WSL), then
--- the two absolute fall-backs.
function M.findRoot(hint)
    local cands = {}
    if hint then cands[#cands + 1] = hint end
    local src = debug.getinfo(1, 'S').source
    if src:sub(1, 1) == '@' then
        local dir = src:sub(2):match('^(.*)[/\\][^/\\]*$')
        if dir then
            cands[#cands + 1] = (dir .. '/../../../../otclient_mehah1530/otclient'):gsub('\\', '/')
        end
    end
    for _, c in ipairs(CANDIDATE_ROOTS) do cands[#cands + 1] = c end
    for _, c in ipairs(cands) do
        if readable(c .. '/mods/game_bot/functions/ui.lua') then return c end
    end
    return nil
end

--- helpers.available([hint]) -> bool, otRoot|reason
function M.available(hint)
    local root = M.findRoot(hint)
    if root then return true, root end
    return false, 'otclient tree not found (looked for mods/game_bot/functions/ui.lua)'
end

-- ===========================================================================
-- host-side stubs
-- ===========================================================================

--- helpers.hostStubs(ENV, context, g_ui) -> context
--- Everything below belongs to bot.lua/executor.lua; it is here only so the four real
--- ui files have something to run against.  Idempotent: an existing field wins, so
--- shim/executor.lua can install the real thing first and this becomes a no-op.
function M.hostStubs(ENV, context, g_ui)
    g_ui = g_ui or ENV.g_ui
    assert(type(g_ui) == 'table', 'helpers.hostStubs: g_ui is required')

    ENV.modules = ENV.modules or {}
    local modules = ENV.modules

    if not modules.game_interface then
        local rightPanel
        modules.game_interface = {
            getRightPanel = function()
                if not rightPanel then
                    rightPanel = g_ui.createWidget('Panel')
                    rightPanel:setId('gameRightPanel')
                    widget.rec('modules.game_interface.getRightPanel')
                end
                return rightPanel
            end,
        }
    end

    if not modules.client_textedit then
        modules.client_textedit = {
            -- BLOCKER: a real modal editor.  Returns a widget so the caller's
            -- `window.botWidget = true` cannot error, and never calls back.
            edit = function(text, options, callback)
                widget.rec('modules.client_textedit.edit', text)
                local w = g_ui.createWidget('MainWindow')
                w:setId('textEditWindow')
                w:hide()
                return w
            end,
            show = function(w) widget.rec('modules.client_textedit.show') end,
        }
    end

    if context.displayGeneralBox == nil then
        context.displayGeneralBox = function(title, question, buttons)
            widget.rec('displayGeneralBox', title)
            local w = g_ui.createWidget('MainWindow')
            w:setId('generalBox')
            w:hide()
            return w
        end
    end
    ENV.displayGeneralBox = ENV.displayGeneralBox or context.displayGeneralBox
    ENV.AnchorHorizontalCenter = ENV.AnchorHorizontalCenter or 6   -- const.lua

    -- log channel (bot.lua:509-517 -> msgCallback -> g_logger)
    local function msg(kind, text)
        if log then
            if kind == 'error' then log.error('[vBot] %s', tostring(text))
            elseif kind == 'warn' then log.warn('[vBot] %s', tostring(text))
            else log.info('[vBot] %s', tostring(text)) end
        end
        return text
    end
    context.info    = context.info    or function(t) return msg('info', t) end
    context.warn    = context.warn    or function(t) return msg('warn', t) end
    context.warning = context.warning or context.warn
    context.error   = context.error   or function(t) return msg('error', t) end
    ENV.warn  = ENV.warn  or context.warn
    ENV.info  = ENV.info  or context.info

    -- Item: the S1 wrapper when the sandbox has it, else the widget.lua value object.
    if ENV.Item == nil then
        ENV.Item = { create = function(id, count) return widget.makeItem(id, count) end }
    end
    context.Item = context.Item or ENV.Item

    -- the tab bar: executor.lua:24-27
    if context.tabs == nil then
        local tabs = g_ui.createWidget('TabBar')
        tabs:setId('botTabs')
        context.tabs = tabs
    end
    if context.mainTab == nil then
        context.mainTab = context.tabs:addTab('Main', g_ui.createWidget('BotPanel')).tabPanel.content
    end
    context.panel = context.panel or context.mainTab
    context.configDir = context.configDir or '/bot/vBot_4.8'
    context.storage = context.storage or {}
    context.storage._macros = context.storage._macros or {}
    context._macros = context._macros or {}
    context._hotkeys = context._hotkeys or {}

    return context
end

-- ===========================================================================
-- loading the four real files
-- ===========================================================================

--- helpers.install(ENV, context, opts) -> handle
--- opts.otRoot   explicit tree location (optional)
--- opts.g_ui     the g_ui singleton (defaults to ENV.g_ui)
--- opts.stubs    false to skip hostStubs (shim/executor.lua supplies its own)
function M.install(ENV, context, opts)
    opts = opts or {}
    assert(type(ENV) == 'table', 'helpers.install: ENV must be a table')
    assert(type(context) == 'table', 'helpers.install: context must be a table')

    local root = M.findRoot(opts.otRoot)
    if not root then
        return { mode = 'absent', loaded = {}, failed = {},
                 reason = 'otclient tree not found; mods/game_bot/functions/ui*.lua not loaded' }
    end

    if opts.stubs ~= false then M.hostStubs(ENV, context, opts.g_ui) end

    -- The files read `G.botContext` (executor.lua:171) and run in the GLOBAL env.
    ENV.G = ENV.G or {}
    local savedBotContext = ENV.G.botContext
    ENV.G.botContext = context

    local loaded, failed, patched = {}, {}, {}
    for _, name in ipairs(M.FILES) do
        local path = root .. '/mods/game_bot/functions/' .. name
        local src = readable(path)
        if not src then
            failed[#failed + 1] = { file = name, err = 'unreadable: ' .. path }
        else
            local okp, res, applied = pcall(M.applyPatches, name, src)
            if not okp then
                failed[#failed + 1] = { file = name, err = tostring(res) }
                src = nil
            else
                src = res
                for _, why in ipairs(applied) do patched[#patched + 1] = name .. ': ' .. why end
            end
        end
        if src then
            local chunk, err = loadstring(src, '@' .. path)
            if not chunk then
                failed[#failed + 1] = { file = name, err = tostring(err) }
            else
                if setfenv then setfenv(chunk, ENV) end
                local ok, e = pcall(chunk)
                if ok then loaded[#loaded + 1] = name
                else failed[#failed + 1] = { file = name, err = tostring(e) } end
            end
        end
    end

    ENV.G.botContext = savedBotContext

    return { mode = 'real', root = root, loaded = loaded, failed = failed,
             patched = patched, UI = context.UI, context = context }
end

return M
