-- lib/events.lua -- the single event bus the parser feeds (API.md "LC.events").
--
-- Contract (API.md):
--   events.on(name, fn)  -> handle
--   events.off(handle)
--   events.emit(name, data)
--   events.onAny(fn)     -> handle
--
-- Semantics:
--   * every handler runs inside pcall; a throwing handler is logged and the remaining
--     handlers still run (one bad listener must never stall the parser).
--   * emit() iterates a snapshot of the listener list, so a handler may on()/off() during
--     the dispatch without corrupting the walk.
--   * onAny handlers receive (name, data) and run AFTER the named handlers.
--
-- The module itself IS a bus (so `LC.events.on(...)` works directly).  `events.new()`
-- returns an independent bus, which is what the unit tests use.
--
-- lib/log.lua is loaded lazily and optionally: this module must stay usable before the
-- logger exists (and inside tests that do not want log output).

local M = {}

local logger  -- resolved once, lazily
local function logError(fmt, ...)
    if logger == nil then
        local ok, mod = pcall(require, 'lib.log')
        logger = (ok and type(mod) == 'table' and mod) or false
    end
    local text = string.format(fmt, ...)
    if logger and logger.error then
        logger.error('%s', text)
    else
        io.stderr:write('[error] ' .. text .. '\n')
    end
end

local Bus = {}
Bus.__index = Bus

local function newBus()
    return setmetatable({
        _named   = {},   -- [name] = { handle, ... }
        _any     = {},   -- { handle, ... }
        _nextId  = 1,
        _depth   = 0,    -- emit re-entrancy depth (diagnostics only)
        errors   = 0,    -- count of handler errors seen since reset
    }, Bus)
end

-- on(name, fn) -> handle
function Bus:on(name, fn)
    if type(name) ~= 'string' then
        error('events.on: name must be a string, got ' .. type(name), 2)
    end
    if type(fn) ~= 'function' then
        error('events.on: fn must be a function, got ' .. type(fn), 2)
    end
    local list = self._named[name]
    if not list then
        list = {}
        self._named[name] = list
    end
    local handle = { id = self._nextId, name = name, fn = fn, bus = self, dead = false }
    self._nextId = self._nextId + 1
    list[#list + 1] = handle
    return handle
end

-- onAny(fn) -> handle ; fn(name, data)
function Bus:onAny(fn)
    if type(fn) ~= 'function' then
        error('events.onAny: fn must be a function, got ' .. type(fn), 2)
    end
    local handle = { id = self._nextId, name = nil, fn = fn, bus = self, dead = false, any = true }
    self._nextId = self._nextId + 1
    self._any[#self._any + 1] = handle
    return handle
end

-- off(handle) -> true if it was live
function Bus:off(handle)
    if type(handle) ~= 'table' or handle.bus ~= self or handle.dead then
        return false
    end
    handle.dead = true
    local list = handle.any and self._any or self._named[handle.name]
    if list then
        for i = 1, #list do
            if list[i] == handle then
                table.remove(list, i)
                break
            end
        end
        if not handle.any and #list == 0 then
            self._named[handle.name] = nil
        end
    end
    return true
end

-- how many live listeners for `name` (nil => the onAny listeners)
function Bus:count(name)
    if name == nil then return #self._any end
    local list = self._named[name]
    return list and #list or 0
end

-- clear() must MARK the dropped handles dead, not just forget the lists: emit() walks a
-- snapshot and skips only handles whose `dead` flag is set, so without this a handler that
-- calls clear() mid-dispatch would still see the rest of that emit run, and a later
-- off(handle) on an already-cleared handle would wrongly report "it was live".
function Bus:clear()
    for _, list in pairs(self._named) do
        for i = 1, #list do list[i].dead = true end
    end
    for i = 1, #self._any do self._any[i].dead = true end
    self._named = {}
    self._any   = {}
    self.errors = 0
end

-- emit(name, data) -> number of handlers invoked (named + any)
function Bus:emit(name, data)
    if type(name) ~= 'string' then
        error('events.emit: name must be a string, got ' .. type(name), 2)
    end
    self._depth = self._depth + 1

    local invoked = 0
    local list = self._named[name]
    if list and #list > 0 then
        -- snapshot: handlers may add/remove listeners while we dispatch
        local snap, n = {}, #list
        for i = 1, n do snap[i] = list[i] end
        for i = 1, n do
            local h = snap[i]
            if not h.dead then
                invoked = invoked + 1
                local ok, err = pcall(h.fn, data)
                if not ok then
                    self.errors = self.errors + 1
                    logError("events: handler #%d for '%s' failed: %s", h.id, name, tostring(err))
                end
            end
        end
    end

    local anyList = self._any
    if #anyList > 0 then
        local snap, n = {}, #anyList
        for i = 1, n do snap[i] = anyList[i] end
        for i = 1, n do
            local h = snap[i]
            if not h.dead then
                invoked = invoked + 1
                local ok, err = pcall(h.fn, name, data)
                if not ok then
                    self.errors = self.errors + 1
                    logError("events: onAny handler #%d failed while emitting '%s': %s",
                             h.id, name, tostring(err))
                end
            end
        end
    end

    self._depth = self._depth - 1
    return invoked
end

-- ---------------------------------------------------------------------------
-- module-level singleton bus (this is what `_G.LC.events` points at)
-- ---------------------------------------------------------------------------
M.new = newBus

local default = newBus()
M.default = default

function M.on(name, fn)   return default:on(name, fn) end
function M.onAny(fn)      return default:onAny(fn) end
function M.off(handle)    return default:off(handle) end
function M.emit(name, d)  return default:emit(name, d) end
function M.count(name)    return default:count(name) end
function M.clear()        return default:clear() end

return M
