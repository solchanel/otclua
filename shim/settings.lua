--[[============================================================================
shim/settings.lua -- `g_settings`, backed by a JSON file.

    local settings   = require('shim.settings')
    local g_settings = settings.new{ resources = g_resources,
                                     path      = '/shim_settings.json',
                                     defaults  = { profile = 1 } }

WHAT IT REPLACES
  `g_settings = makesingleton(g_configs.getSettings())` (modules/corelib/settings.lua:1)
  -- a C++ `Config` (an OTML document) wrapped by makesingleton, with the Lua sugar of
  modules/corelib/config.lua layered on the raw bindings of luafunctions.cpp:330-344
  (save, setValue, setList, getValue, getList, exists, remove, setNode, getNode,
  getNodeSize, getOrCreateNode, mergeNode, getFileName, clear).

  Because makesingleton binds every method with the object already bound, EVERY call
  site uses a DOT: `g_settings.getNumber('profile')`.  This module returns a flat
  table of closures for the same reason shim/resources.lua does.

  The backing store here is JSON rather than OTML: nothing in the executed corpus
  reads the file with anything but these accessors, the shim writes it itself, and
  lib/json.lua is already vendored.  A node ('bot', say) is a nested JSON object.

FIDELITY (docs/shim/api-platform.md section 3.1)
  * `getNumber('profile')` MUST return 1 by default.  modules/client_options/
    data_options.lua:616-618 declares `profile = {value = 1}` and the options module
    writes it into the settings at client start, so the live client always has it.
    `Config:getNumber` is `tonumber(get(k, default)) or 0`, so an unseeded shim would
    answer 0 -- and `vBot/configs.lua:20` would then point at a non-existent
    `vBot_configs/profile_0` directory and SILENTLY RESET every HealBot, AttackBot and
    Supplies config.  `settings.new` therefore seeds `profile = 1` unless the caller
    passes its own defaults, and `settings.DEFAULTS` documents the seed.
  * `Config:get(key, default)` has a side effect: when the key does not exist and a
    default was supplied it WRITES the default before returning it (config.lua:34-38).
    Reproduced -- `getNumber(k, d)` on a fresh store leaves `k` behind.
  * `Config:set` funnels through `convertSettingValue` (config.lua:2-19): a table with
    x/width/r fields becomes a point/size/rect/colour STRING, any other table is kept
    as-is, nil becomes '', everything else becomes tostring(value).  The
    point/size/rect/colour spellings need the g_ui geometry helpers, which do not
    exist headless; there are no call sites, so a geometry-shaped table raises with a
    named reason instead of being silently stored as a Lua table.
  * `getBoolean` uses corelib `toboolean` (util.lua:280-293): only the strings '1'
    and 'true' (trimmed, lowercased), the number 1, and a real boolean are true.
============================================================================]]

local json = require('lib.json')

local settings = {}

--- Seeded into every new store unless the caller overrides `defaults`.
--- profile: see the fidelity note above -- 0 would silently wipe vBot's configs.
settings.DEFAULTS = { profile = 1 }

-- ===========================================================================
-- corelib toboolean (modules/corelib/util.lua:280-293), ported verbatim
-- ===========================================================================
local function toboolean(v)
    if type(v) == 'string' then
        v = v:match('^%s*(.-)%s*$'):lower()
        if v == '1' or v == 'true' then return true end
    elseif type(v) == 'number' then
        if v == 1 then return true end
    elseif type(v) == 'boolean' then
        return v
    end
    return false
end
settings.toboolean = toboolean

-- ===========================================================================
-- corelib convertSettingValue (modules/corelib/config.lua:2-19)
-- ===========================================================================
local function convertSettingValue(value)
    if type(value) == 'table' then
        if (value.x and value.width) or value.x or value.width or value.r then
            error('g_settings: point/size/rect/colour values need the g_ui geometry '
                  .. 'helpers (recttostring/pointtostring/sizetostring/colortostring), '
                  .. 'which do not exist headless; store a plain table or a string instead', 3)
        end
        return value
    elseif value == nil then
        return ''
    else
        return tostring(value)
    end
end

-- ===========================================================================
-- the store
-- ===========================================================================

local function logline(level, fmt, ...)
    local ok, log = pcall(require, 'lib.log')
    if ok and log[level] then log[level](fmt, ...) return end
    io.stderr:write(('[%s] '):format(level), fmt:format(...), '\n')
end

--- new(opts) -> g_settings
---   opts.resources : a shim/resources g_resources; when present, `path` is a VIRTUAL
---                    path inside its sandbox and the file goes through it
---   opts.path      : virtual path (default '/shim_settings.json')
---   opts.file      : host path, used only when `resources` is absent
---   opts.defaults  : table seeded into an EMPTY store (default settings.DEFAULTS)
---   opts.load      : false to skip reading an existing file (tests)
function settings.new(opts)
    opts = opts or {}
    local res  = opts.resources
    local vpath = opts.path or '/shim_settings.json'
    local hpath = opts.file
    if not res and not hpath then
        error('settings.new: pass either opts.resources (+opts.path) or opts.file', 2)
    end
    if res then
        -- Refuse a path outside the g_resources sandbox HERE rather than at the first
        -- save(): the read below is pcall-wrapped (a missing settings file is normal),
        -- so a refusal would otherwise be swallowed and the store would look healthy
        -- right up to the moment it silently failed to persist.
        local ok, why = res._checkPath(vpath)
        if not ok then
            error(('settings.new: refusing settings path %q -- %s'):format(vpath, tostring(why)), 2)
        end
    end

    local data = {}
    local dirty = false

    local function readRaw()
        if res then
            local ok, txt = pcall(res.readFileContents, vpath)
            if ok then return txt end
            return nil
        end
        local f = io.open(hpath, 'rb')
        if not f then return nil end
        local txt = f:read('*a'); f:close()
        return txt
    end

    local function writeRaw(txt)
        if res then return res.writeFileContents(vpath, txt) and true or false end
        local f, err = io.open(hpath, 'wb')
        if not f then
            logline('error', 'g_settings.save: %s', tostring(err))
            return false
        end
        f:write(txt); f:close()
        return true
    end

    if opts.load ~= false then
        local txt = readRaw()
        if txt and txt ~= '' then
            local ok, decoded = pcall(json.decode, txt)
            if ok and type(decoded) == 'table' then
                data = decoded
            else
                logline('error', 'g_settings: %s is not valid JSON (%s) -- starting empty',
                        tostring(hpath or vpath), tostring(decoded))
            end
        end
    end

    if next(data) == nil then
        local seed = opts.defaults or settings.DEFAULTS
        for k, v in pairs(seed) do data[k] = convertSettingValue(v) end
        dirty = true
    end

    local g = {}

    -- ------------------------------------------------------- raw bindings ---
    function g.exists(key) return data[key] ~= nil end

    function g.getValue(key)
        local v = data[key]
        if type(v) == 'table' then return nil end     -- a node, not a value
        return v
    end

    function g.setValue(key, value)
        data[key] = value
        dirty = true
    end

    function g.remove(key) data[key] = nil; dirty = true end

    function g.getNode(key)
        local v = data[key]
        if type(v) == 'table' then return v end
        return nil
    end

    function g.setNode(key, node)
        if node ~= nil and type(node) ~= 'table' then
            error('g_settings.setNode: node must be a table, got ' .. type(node), 2)
        end
        data[key] = node
        dirty = true
    end

    function g.getOrCreateNode(key)
        local v = data[key]
        if type(v) ~= 'table' then v = {}; data[key] = v; dirty = true end
        return v
    end

    function g.getNodeSize(key)
        local v = data[key]
        if type(v) ~= 'table' then return 0 end
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        return n
    end

    function g.mergeNode(key, node)
        local dst = g.getOrCreateNode(key)
        for k, v in pairs(node or {}) do dst[k] = v end
        dirty = true
    end

    function g.getList(key)
        local v = data[key]
        if type(v) ~= 'table' then return {} end
        local out = {}
        for i = 1, #v do out[i] = v[i] end
        return out
    end

    function g.setList(key, list)
        local out = {}
        for i = 1, #(list or {}) do out[i] = tostring(list[i]) end
        data[key] = out
        dirty = true
    end

    function g.clear() data = {}; dirty = true end

    function g.getFileName() return hpath or vpath end

    --- C++ Config::save() returns void; we return a boolean so callers that care can
    --- see a write failure.  A no-op when nothing changed since the last save.
    function g.save(force)
        if not dirty and not force then return true end
        local ok, txt = pcall(json.encode, data)
        if not ok then
            logline('error', 'g_settings.save: cannot encode settings: %s', tostring(txt))
            return false
        end
        local wrote = writeRaw(txt)
        if wrote then dirty = false end
        return wrote
    end

    -- ------------------------------------------- corelib/config.lua sugar ---
    function g.set(key, value) g.setValue(key, convertSettingValue(value)) end

    function g.setDefault(key, value)
        if g.exists(key) then return false end
        g.set(key, value)
        return true
    end

    function g.get(key, default)
        if not g.exists(key) and default ~= nil then g.set(key, default) end
        return g.getValue(key)
    end

    function g.getString(key, default) return g.get(key, default) end
    function g.getInteger(key, default) return tonumber(g.get(key, default)) or 0 end
    function g.getNumber(key, default)  return tonumber(g.get(key, default)) or 0 end
    function g.getBoolean(key, default) return toboolean(g.get(key, default)) end

    -- ------------------------------------------------------- diagnostics ---
    --- Not part of the otclient API; the test suite and the control plane use it.
    function g._raw() return data end
    function g._dirty() return dirty end

    return g
end

return settings
