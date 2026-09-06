--[[============================================================================
shim/patches.lua -- the audited in-memory source rewrites  (PLAN.md sec.1.14)

INVARIANT I9: the otclient tree at D:/Claude/otclient_mehah1530 is READ-ONLY.
Nothing here writes a file.  A vendored file that needs a fix is rewritten IN
MEMORY on the way from `readFileContents` to `load`, and every rewrite FAILS
LOUDLY when its `expected` text is no longer present verbatim -- that is the
upstream-drift detector, and it is the reason these are literal strings rather
than patterns.

WHY THERE ARE ANY AT ALL.  All three entries are the SAME bug class: upstream
identifies a live otclient widget or game object by its Lua TYPE, because in the
real client those are `userdata`.  Every shim object is a Lua TABLE, so the test
silently picks the wrong branch.  Silently -- which is exactly the failure mode
this project is trying to avoid (PLAN sec.0, "runs and is silently wrong").

A ripgrep over `mods/game_bot` and the whole `profiles/bot/vBot_4.8` tree finds
exactly three `type(x) == 'table'` / `'userdata'` widget-or-object tests, and all
three are here:

  1. mods/game_bot/functions/map.lua:17,22   getSpectators(param1) overload
  2. mods/game_bot/functions/ui_elements.lua:60   UI.Container setItems
  3. profiles/bot/vBot_4.8/vBot/training.lua:511  a private copy of (2)

KEYS.  A key is the *virtual path* the loader sees:
  * `functions/<name>.lua` / `panels/<name>.lua` for `dofiles()` (shim/host.lua's
    dofiles hook, which is rooted at `<otRoot>/mods/game_bot`), and
  * the leading-slash chunk name for a profile script -- `/vBot/training.lua` --
    because `mods/game_bot/executor.lua:115` compiles those as
    `load(src, file, nil, context)` with `file` exactly as `_Loader.lua` wrote it.

Usage:
    local patches = require('shim.patches')
    src = patches.apply(src, 'functions/map.lua', notes)   -- raises on drift
    src, notes = patches.tryApply(src, '/vBot/training.lua')  -- never raises
============================================================================]]

local patches = {}

--- The table.  `expected` must occur EXACTLY ONCE in the upstream file.
patches.LIST = {

    -- ---------------------------------------------------------------- 1 ----
    -- `getSpectators(param1)` takes either a position or a creature.  Upstream
    -- tests `type(param1) == 'table'` for the position form FIRST and
    -- `type(param1) == 'userdata'` for the creature form second.  A shim
    -- Creature is a table, so the first branch swallows it and reads `.x/.y/.z`
    -- off a creature -- silently scanning the wrong tile.  Discriminate on the
    -- method instead of on the Lua type.  api-game.md sec.0.4.
    ['functions/map.lua'] = {
        {
            expected = "  if type(param1) == 'table' then\n",
            replacement = "  if type(param1) == 'table' and param1.getPosition == nil then\n",
            why = 'a shim Creature is a table; keep the position branch for POSITIONS only',
        },
        {
            expected = "  if type(param1) == 'userdata' then\n",
            replacement = "  if type(param1) == 'table' and param1.getPosition ~= nil then\n",
            why = 'shim objects are tables, never userdata -- api-game.md sec.0.4',
        },
    },

    -- ---------------------------------------------------------------- 2 ----
    -- `UI.Container`'s `setItems` supports both `widget.setItems(items)` (dot,
    -- items in arg #1) and `widget:setItems(items)` (colon, widget in arg #1).
    -- Upstream discriminates with `type(self) == 'table'`, true ONLY for the dot
    -- form in the live client because a widget is userdata there.  With table
    -- widgets the colon form takes the dot branch and `items = self` throws the
    -- caller's list away, so every `ui.items:setItems(data.items)` loads an
    -- EMPTY container -- targetbot/looting.lua:58-59, vBot/Dropper.lua:106,
    -- eat_food.lua:33, tools.lua:56, depositer_config.lua:239,
    -- Containers.lua:459.  Comparing against the `widget` upvalue is a strictly
    -- better discriminator and is correct in the live client too.
    -- api-ui.md sec.5.6.
    ['functions/ui_elements.lua'] = {
        {
            expected = [[
  widget.setItems = function(self, items)
    if type(self) == 'table' then
      items = self
    end]],
            replacement = [[
  widget.setItems = function(self, items)
    if type(self) == 'table' and self ~= widget then
      items = self
    end]],
            why = 'table-vs-userdata: widget:setItems(t) silently discarded t (api-ui.md sec.5.6)',
        },
    },

    -- ---------------------------------------------------------------- 3 ----
    -- The user's own `vBot/training.lua` carries a private copy of (2) for its
    -- Items-Container row; `training.lua:507` and `:554` call it with the colon
    -- form.  Same rewrite, same reason.  The indentation differs from (2), so
    -- this cannot share the entry.
    ['/vBot/training.lua'] = {
        {
            expected = [[
  widget.setItems = function(self, items)
    if type(self) == 'table' then
      items = self
    end
    ]],
            replacement = [[
  widget.setItems = function(self, items)
    if type(self) == 'table' and self ~= widget then
      items = self
    end
    ]],
            why = 'table-vs-userdata: the training-window container loaded no items',
        },
    },
}

--- Normalise a chunk name into a patch key.  `@/vBot/x.lua` -> `/vBot/x.lua`.
function patches.key(name)
    if type(name) ~= 'string' then return nil end
    return (name:gsub('^@', ''))
end

function patches.has(virtualPath)
    return patches.LIST[virtualPath] ~= nil
end

--- apply(src, virtualPath, notes) -> src
--- RAISES when a patch no longer applies (upstream drifted) or matches twice.
--- `notes` (optional array) collects one human-readable line per applied patch.
function patches.apply(src, virtualPath, notes)
    local list = patches.LIST[virtualPath]
    if not list or type(src) ~= 'string' then return src end
    for _, p in ipairs(list) do
        local from, to = src:find(p.expected, 1, true)
        if not from then
            error(('shim/patches: the patch for %s no longer applies -- the expected text is '
                   .. 'absent.  Upstream drifted; re-audit before running. (%s)')
                  :format(virtualPath, p.why), 0)
        end
        if src:find(p.expected, to + 1, true) then
            error(('shim/patches: the patch for %s matches more than once; it is no longer '
                   .. 'unambiguous. (%s)'):format(virtualPath, p.why), 0)
        end
        src = src:sub(1, from - 1) .. p.replacement .. src:sub(to + 1)
        if notes then notes[#notes + 1] = virtualPath .. ': ' .. p.why end
    end
    return src
end

--- tryApply(src, virtualPath, notes) -> src, err
--- Never raises: on drift it returns the ORIGINAL source plus the error string,
--- so the caller can log loudly and keep going rather than bricking the boot.
function patches.tryApply(src, virtualPath, notes)
    local ok, res = pcall(patches.apply, src, virtualPath, notes)
    if ok then return res, nil end
    return src, tostring(res)
end

return patches
