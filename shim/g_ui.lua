--[[============================================================================
shim/g_ui.lua -- the boot-step-9 adapter for the real UI backend.

PLAN.md sec.4.1 step 9 asks for `G.g_ui`; `shim/bootstrap.lua` looks for exactly
this module and falls back to its PROVISIONAL widget stub when it is absent
(status().ui == 'provisional').  The real implementation lives in
`shim/ui/g_ui.lua` (the OTML parser + style registry + creation pipeline) and
`shim/ui/widget.lua` (the widget class); this file is the two-line glue the
bootstrap contract wants, plus the base-style import that must happen before any
profile `.otui` is read.

    G.g_ui = require('shim.g_ui').new(G, { resources = g_resources,
                                           otRoot    = '<otclient checkout>' })

Import order, and why it is that order (shim/ui/g_ui.lua X2):

  1. installBuiltinStyles()   ~104 hand-reduced base styles.  A safety net so the
                              shim boots with NO otclient tree at all; every name
                              is overwritten in step 2 when the tree is present.
  2. importBaseStyles(otRoot) the 23 REAL data/styles/*.otui plus
                              mods/game_bot/ui/*.otui.  These win.
  3. (NOT here)               the profile's own `.otui` files.
                              `mods/game_bot/executor.lua:180` imports those
                              itself, from inside the sandbox, and doing it twice
                              would double-register every style.

The returned table IS `g_ui` -- the same object vBot sees -- with two extra
fields the shim's own code (never vBot) uses:  `_styles` (the registry, for
`status()` and the suites) and `_uimod` (the module, for `parse`).
============================================================================]]

local uimod = require('shim.ui.g_ui')

local M = {}

--- new(G, opts) -> g_ui
---   G                the SHIM_G table every OTML `!expr` / `@sig` is compiled into
---   opts.resources   the shim g_resources (styles are read through it when the
---                    path is inside the write dir; base styles are read from otRoot)
---   opts.otRoot      the READ-ONLY otclient checkout; nil skips step 2
---   opts.builtins    false to skip the builtin safety net (tests)
function M.new(G, opts)
    opts = opts or {}
    local uih = uimod.new{ env = G, resources = opts.resources }
    local g_ui = uih.g_ui

    if opts.builtins ~= false then
        g_ui.installBuiltinStyles()
    end
    if opts.otRoot then
        g_ui.importBaseStyles(opts.otRoot)
    end

    g_ui._styles = uih.styles
    g_ui._uimod  = uimod
    return g_ui
end

--- The widget predicate, hoisted so callers do not have to reach into shim.ui.
M.isWidget = require('shim.ui.widget').isWidget

return M
