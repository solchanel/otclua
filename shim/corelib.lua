--[[============================================================================
shim/corelib.lua -- otclient's `modules/corelib` surface: the stdlib extensions, the
signal primitives, the event scheduler globals, and the small data globals.

    local corelib = require('shim.corelib')
    local h = corelib.install(G, { sched = require('lib.sched') })
    ...
    h.uninstall()          -- puts _G.string / _G.table / _G.math back exactly as found

WHY THE GLOBAL TABLES ARE PATCHED IN PLACE
  `mods/game_bot/executor.lua:92` copies the GLOBAL `string` and `table` tables onto the
  bot sandbox context.  The sandbox has no `__index` to _G (invariant I7), so whatever
  those tables hold at the moment the context is built is all vBot will ever see.  The
  patches therefore have to be on the real `_G.string` / `_G.table` / `_G.math`, and
  they have to be installed BEFORE the executor builds the context (PLAN.md section
  7.3, install step 3 before step 11).
  `install` snapshots every key it is about to touch and warns at debug level when it
  overwrites a pre-existing implementation; `uninstall` restores the snapshot, so the
  rest of luaclient is never left with a mutated stdlib after a test.

WHAT IS PORTED VERBATIM FROM otclient (MIT, same licence as this tree)
  modules/corelib/string.lua   split starts ends trim explode contains wrap empty
                               titleCase capitalize
  modules/corelib/table.lua    dump isIn reserve clear copy recursivecopy
                               selectivecopy merge find findbykey contains findkey
                               haskey removevalue compare empty permute findbyfield
                               size tostring collect insertall equals equal isList
                               isStringList isStringPairList encodeStringPairList
                               decodeStringPairList remove_if
  modules/corelib/math.lua     round isu8 isu16 isu32 isu64 isinteger
                               + the global roundToTwoDecimalPlaces
  modules/corelib/util.lua     connect disconnect signalcall protectedcall toboolean
  modules/corelib/globals.lua  scheduleEvent addEvent cycleEvent deferEvent
                               periodicalEvent removeEvent, and the cross-reload `G`

DELIBERATELY NOT PORTED
  string.pack_custom / string.unpack_custom (string.lua:88-189) -- ~100 lines of
      format-string parsing with ZERO call sites anywhere in the executed corpus.
      Absent, so a future call fails loudly instead of silently misparsing.
  table.popvalue (table.lua:128-140) -- BROKEN UPSTREAM: its body iterates a global
      `t` that the function never declares or receives, so calling it raises
      "bad argument #1 to 'pairs' (table expected, got nil)" in the live client too.
      Zero call sites.  Reproducing a crash adds nothing; omitting it produces a
      clearer one.
  table.serialize -- DOES NOT EXIST in otclient corelib and is called nowhere in
      vBot 4.8 or mods/game_bot (verified by grep over both trees).  Not invented:
      an invented serialiser whose format nobody agrees on is exactly the
      "silently wrong" failure this shim is trying to avoid.
  string.split's sibling `string:explode` is ported, but note it TRIMS each field
      while `split` does not -- they are different functions upstream and vBot uses
      only `split`.

THE THREE SEMANTICS THAT ARE LOAD-BEARING

  C1  `string:split(delim)` uses a PLAIN find and then `table.removevalue(results,'')`,
      which drops the FIRST empty field only (removevalue removes one occurrence).
      `cavebot/actions.lua:195-197` has an explicit comment relying on that drop
      making `[1]` nil for a bare "goto:".  38 live call sites.

  C2  `signalcall(param, ...)` STOPS AT THE FIRST SLOT THAT RETURNS TRUTHY and returns
      `true` (util.lua:330-353).  A slot that raises is reported through `perror` and
      the remaining slots still run.  A bare function's return value is passed through
      as-is (so a function slot can return a non-boolean); a LIST of slots collapses
      every truthy return to exactly `true`.  This asymmetry is upstream's and is
      relied on by the widget layer.

  C3  `connect(object, {sig = slot}, pushFront)` promotes a field from nil -> function
      -> array, in that order, and installs a metatable FORWARDER first when the field
      is nil and the object is USERDATA (util.lua:59-66).  The shim's game objects are
      plain Lua tables, so that branch never fires here.  CONSEQUENCE, recorded as
      docs/shim/api-platform.md B9: in the live client `connect(LocalPlayer, ...)` on a
      signal that `Creature` also lists turns Creature's single slot into a two-entry
      list and every local-player emit fires TWICE (bot.lua:591-594 documents the trap).
      Under this shim LocalPlayer signals fire ONCE.  That is a divergence, it is
      deliberate, and `corelib.forwarderTypes` is the single switch that would change
      it if the class layer ever grows real userdata-like proxies.
============================================================================]]

local json   = require('lib.json')
local b64    = require('lib.base64')
local regex  = require('shim.regex')

local corelib = {}

--- Which Lua types get the metatable forwarder in `connect` (C3).  Upstream is
--- exactly {'userdata'}; the shim keeps that so behaviour is identical for every
--- object it actually has.
corelib.forwarderTypes = { userdata = true }

-- ===========================================================================
-- 0. diagnostics
-- ===========================================================================

local G_ref                     -- set by install(), used by perror below

local function logline(level, fmt, ...)
    local ok, log = pcall(require, 'lib.log')
    if ok and log[level] then
        if select('#', ...) > 0 then log[level](fmt, ...) else log[level](fmt) end
        return
    end
    io.stderr:write(('[%s] '):format(level), fmt, '\n')
end

--- corelib's perror, resolved late so platform.install may run in either order.
local function perror(msg)
    if G_ref and G_ref.perror then return G_ref.perror(msg) end
    logline('error', tostring(msg))
end

-- ===========================================================================
-- 1. string extensions  (modules/corelib/string.lua)
-- ===========================================================================

local STRING_EXT = {}

-- C1: plain find, no pattern magic; the trailing remainder is always appended; then
-- ONE empty field is removed by table.removevalue.
function STRING_EXT.split(self, delim)
    local start = 1
    local results = {}
    while true do
        local pos = string.find(self, delim, start, true)
        if not pos then break end
        table.insert(results, string.sub(self, start, pos - 1))
        start = pos + string.len(delim)
    end
    table.insert(results, string.sub(self, start))
    -- upstream calls the GLOBAL table.removevalue; the local fallback keeps split
    -- working when install() ran with patchGlobals = false
    local removevalue = table.removevalue or corelib.TABLE_EXT.removevalue
    removevalue(results, '')
    return results
end

function STRING_EXT.starts(self, start)
    return string.sub(self, 1, #start) == start
end

function STRING_EXT.ends(self, test)
    return test == '' or string.sub(self, -string.len(test)) == test
end

function STRING_EXT.trim(self)
    return string.match(self, '^%s*(.*%S)') or ''
end

function STRING_EXT.explode(self, sep, limit)
    if type(sep) ~= 'string' or tostring(self):len() == 0 or sep:len() == 0 then
        return {}
    end
    local i, pos, tmp, t = 0, 1, '', {}
    for s, e in function() return string.find(self, sep, pos) end do
        tmp = STRING_EXT.trim(self:sub(pos, s - 1))
        table.insert(t, tmp)
        pos = e + 1
        i = i + 1
        if limit ~= nil and i == limit then break end
    end
    tmp = STRING_EXT.trim(self:sub(pos))
    table.insert(t, tmp)
    return t
end

function STRING_EXT.contains(self, str, checkCase, start, plain)
    if not checkCase then
        self = self:lower()
        str = str:lower()
    end
    return string.find(self, str, start and start or 1, plain == nil and true or false)
end

function STRING_EXT.wrap(self, width)
    local wrapped = ''
    local lineWidth = 0
    for word in self:gmatch('%S+') do
        local wordWidth = #word * 10        -- upstream assumes 10 px per character
        if lineWidth + wordWidth > width then
            wrapped = wrapped .. '\n' .. word .. ' '
            lineWidth = wordWidth + 1
        else
            wrapped = wrapped .. word .. ' '
            lineWidth = lineWidth + wordWidth + 1
        end
    end
    return wrapped
end

function STRING_EXT.empty(str)
    return str == nil or str == '' or #str == 0
end

function STRING_EXT.titleCase(self)
    return self:gsub("(%a)([%w_']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end)
end

function STRING_EXT.capitalize(str)
    if not str or str == '' then return str end
    return str:sub(1, 1):upper() .. str:sub(2)
end

-- ===========================================================================
-- 2. table extensions  (modules/corelib/table.lua)
-- ===========================================================================

local TABLE_EXT = {}

function TABLE_EXT.dump(t, depth)
    depth = depth or 0
    for k, v in pairs(t) do
        local str = (' '):rep(depth * 2) .. tostring(k) .. ': '
        if type(v) ~= 'table' then
            (G_ref and G_ref.print or print)(str .. tostring(v))
        else
            (G_ref and G_ref.print or print)(str)
            TABLE_EXT.dump(v, depth + 1)
        end
    end
end

function TABLE_EXT.isIn(tbl, val)
    for _, v in ipairs(tbl) do if v == val then return true end end
    return false
end

function TABLE_EXT.reserve(count, default)
    local t = {}
    for i = 1, count do t[i] = default end
    return t
end

function TABLE_EXT.clear(t)
    for k in pairs(t) do t[k] = nil end
end

function TABLE_EXT.copy(t)
    local res = {}
    for k, v in pairs(t) do res[k] = v end
    return res
end

function TABLE_EXT.recursivecopy(t)
    local res = {}
    for k, v in pairs(t) do
        if type(v) == 'table' then res[k] = TABLE_EXT.recursivecopy(v) else res[k] = v end
    end
    return res
end

function TABLE_EXT.selectivecopy(t, keys)
    local res = {}
    for _, v in ipairs(keys) do res[v] = t[v] end
    return res
end

function TABLE_EXT.merge(t, src)
    for k, v in pairs(src) do t[k] = v end
end

-- 80 live call sites -- the most used corelib extension in vBot.
function TABLE_EXT.find(t, value, lowercase)
    for k, v in pairs(t) do
        if lowercase and type(value) == 'string' and type(v) == 'string' then
            if v:lower() == value:lower() then return k end
        end
        if v == value then return k end
    end
end

function TABLE_EXT.findbykey(t, key, lowercase)
    for k, v in pairs(t) do
        if lowercase and type(key) == 'string' and type(k) == 'string' then
            if k:lower() == key:lower() then return v end
        end
        if k == key then return v end
    end
end

function TABLE_EXT.contains(t, value, lowercase)
    return TABLE_EXT.find(t, value, lowercase) ~= nil
end

function TABLE_EXT.findkey(t, key)
    if t and type(t) == 'table' then
        for k in pairs(t) do if k == key then return k end end
    end
end

function TABLE_EXT.haskey(t, key)
    return TABLE_EXT.findkey(t, key) ~= nil
end

-- Removes ONE occurrence (returns immediately).  string:split depends on that.
function TABLE_EXT.removevalue(t, value)
    for k, v in pairs(t) do
        if v == value then
            table.remove(t, k)
            return true
        end
    end
    return false
end

function TABLE_EXT.compare(t, other)
    if #t ~= #other then return false end
    for k, v in pairs(t) do if v ~= other[k] then return false end end
    return true
end

function TABLE_EXT.empty(t)
    if t and type(t) == 'table' then return next(t) == nil end
    return true
end

function TABLE_EXT.permute(t, n, count)
    n = n or #t
    for i = 1, count or n do
        local j = math.random(i, n)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

function TABLE_EXT.findbyfield(t, fieldname, fieldvalue)
    for _, subt in pairs(t) do
        if subt[fieldname] == fieldvalue then return subt end
    end
    return nil
end

function TABLE_EXT.size(t)
    local size = 0
    for _ in pairs(t) do size = size + 1 end
    return size
end

function TABLE_EXT.tostring(t)
    local maxn = #t
    local str = ''
    for k, v in pairs(t) do
        v = tostring(v)
        if k == maxn and k ~= 1 then str = str .. ' and ' .. v
        elseif maxn > 1 and k ~= 1 then str = str .. ', ' .. v
        else str = str .. ' ' .. v end
    end
    return str
end

function TABLE_EXT.collect(t, func)
    local res = {}
    for k, v in pairs(t) do
        local a, b = func(k, v)
        if a and b then res[a] = b
        elseif a ~= nil then table.insert(res, a) end
    end
    return res
end

function TABLE_EXT.insertall(t, s)
    for _, v in pairs(s) do table.insert(t, v) end
end

function TABLE_EXT.equals(t, comp)
    if type(t) == 'table' and type(comp) == 'table' then
        for k, v in pairs(t) do if v ~= comp[k] then return false end end
    end
    return true
end

function TABLE_EXT.equal(t1, t2, ignore_mt)
    local ty1, ty2 = type(t1), type(t2)
    if ty1 ~= ty2 then return false end
    if ty1 ~= 'table' and ty2 ~= 'table' then return t1 == t2 end
    local mt = getmetatable(t1)
    if not ignore_mt and mt and mt.__eq then return t1 == t2 end
    for k1, v1 in pairs(t1) do
        local v2 = t2[k1]
        if v2 == nil or not TABLE_EXT.equal(v1, v2) then return false end
    end
    for k2, v2 in pairs(t2) do
        local v1 = t1[k2]
        if v1 == nil or not TABLE_EXT.equal(v1, v2) then return false end
    end
    return true
end

function TABLE_EXT.isList(t)
    local size = #t
    return TABLE_EXT.size(t) == size and size > 0
end

function TABLE_EXT.isStringList(t)
    if not TABLE_EXT.isList(t) then return false end
    for _, v in ipairs(t) do if type(v) ~= 'string' then return false end end
    return true
end

function TABLE_EXT.isStringPairList(t)
    if not TABLE_EXT.isList(t) then return false end
    for _, v in ipairs(t) do
        if type(v) ~= 'table' or #v ~= 2 or type(v[1]) ~= 'string' or type(v[2]) ~= 'string' then
            return false
        end
    end
    return true
end

function TABLE_EXT.encodeStringPairList(t)
    local ret = ''
    for _, v in ipairs(t) do
        if v[2]:find('\n') then
            ret = ret .. v[1] .. ':[[\n' .. v[2] .. '\n]]\n'
        else
            ret = ret .. v[1] .. ':' .. v[2] .. '\n'
        end
    end
    return ret
end

-- The cavebot `.cfg` parser.  Goes through regexMatch (table.lua:293), which is why
-- shim/regex.lua has to be installed before this ever runs.
local DECODE_PATTERN = '(?:^|\\n)([^:^\n]{1,20}):?(.*)(?:$|\\n)'

function TABLE_EXT.decodeStringPairList(l)
    local ret = {}
    local r = corelib.regexMatch(l, DECODE_PATTERN)
    local multiline = ''
    local multilineKey = ''
    local multilineActive = false
    for _, v in ipairs(r) do
        if multilineActive then
            local endPos = v[1]:find('%]%]')
            if endPos then
                if endPos > 1 then
                    table.insert(ret, { multilineKey, multiline .. '\n' .. v[1]:sub(1, endPos - 1) })
                else
                    table.insert(ret, { multilineKey, multiline })
                end
                multilineActive = false
                multiline = ''
                multilineKey = ''
            else
                if multiline:len() == 0 then multiline = v[1]
                else multiline = multiline .. '\n' .. v[1] end
            end
        else
            local bracketPos = v[3]:find('%[%[')
            if bracketPos == 1 then                       -- multiline begin
                multiline = v[3]:sub(bracketPos + 2)
                multilineActive = true
                multilineKey = v[2]
            elseif v[2]:len() > 0 and v[3]:len() > 0 then
                table.insert(ret, { v[2], v[3] })
            end
        end
    end
    return ret
end

function TABLE_EXT.remove_if(t, fnc)
    local j, n = 1, #t
    for i = 1, n do
        if not fnc(i, t[i]) then
            if i ~= j then t[j] = t[i]; t[i] = nil end
            j = j + 1
        else
            t[i] = nil
        end
    end
    return t
end

-- ===========================================================================
-- 3. math extensions  (modules/corelib/math.lua)
-- ===========================================================================

local U8, U16, U32, U64 = 2 ^ 8, 2 ^ 16, 2 ^ 32, 2 ^ 64

local MATH_EXT = {}

function MATH_EXT.round(num, idp)
    local mult = 10 ^ (idp or 0)
    if num >= 0 then return math.floor(num * mult + 0.5) / mult end
    return math.ceil(num * mult - 0.5) / mult
end

function MATH_EXT.isinteger(num)
    return (type(num) == 'number') and (num == math.floor(num))
end
function MATH_EXT.isu8(num)  return MATH_EXT.isinteger(num) and num >= 0   and num < U8  end
function MATH_EXT.isu16(num) return MATH_EXT.isinteger(num) and num >= U8  and num < U16 end
function MATH_EXT.isu32(num) return MATH_EXT.isinteger(num) and num >= U16 and num < U32 end
function MATH_EXT.isu64(num) return MATH_EXT.isinteger(num) and num >= U32 and num < U64 end

-- ===========================================================================
-- 4. connect / disconnect / signalcall  (modules/corelib/util.lua:42-119, 330-353)
-- ===========================================================================

local function signalcall(param, ...)
    if type(param) == 'function' then
        local status, ret = pcall(param, ...)
        if status then return ret end
        perror(ret)
    elseif type(param) == 'table' then
        for _, v in pairs(param) do
            local status, ret = pcall(v, ...)
            if status then
                if ret then return true end          -- C2: stop at the first truthy slot
            else
                perror(ret)
            end
        end
    elseif param ~= nil then
        error('attempt to call a non function value')
    end
    return false
end

local function connect(object, arg1, arg2, arg3)
    if not object then return end

    local signalsAndSlots, pushFront
    if type(arg1) == 'string' then
        signalsAndSlots = { [arg1] = arg2 }
        pushFront = arg3
    else
        signalsAndSlots = arg1
        pushFront = arg2
    end

    for signal, slot in pairs(signalsAndSlots) do
        -- C3: the class-level forwarder.  Upstream restricts it to userdata; so do we.
        if not object[signal] then
            local mt = getmetatable(object)
            if mt and corelib.forwarderTypes[type(object)] then
                object[signal] = function(...) return signalcall(mt[signal], ...) end
            end
        end

        if not object[signal] then
            object[signal] = slot
        elseif type(object[signal]) == 'function' then
            object[signal] = { object[signal] }
        end

        if type(slot) ~= 'function' then
            perror(debug.traceback('unable to connect a non function value'))
        end

        if type(object[signal]) == 'table' then
            if pushFront then
                table.insert(object[signal], 1, slot)
            else
                table.insert(object[signal], #object[signal] + 1, slot)
            end
        end
    end
end

local function disconnect(object, arg1, arg2)
    local signalsAndSlots
    if type(arg1) == 'string' then
        if arg2 == nil then
            object[arg1] = nil
            return
        end
        signalsAndSlots = { [arg1] = arg2 }
    elseif type(arg1) == 'table' then
        signalsAndSlots = arg1
    else
        perror(debug.traceback('unable to disconnect'))
        return
    end

    for signal, slot in pairs(signalsAndSlots) do
        if not object[signal] then                       -- nothing connected
        elseif type(object[signal]) == 'function' then
            if object[signal] == slot then object[signal] = nil end
        elseif type(object[signal]) == 'table' then
            for k, func in pairs(object[signal]) do
                if func == slot then
                    table.remove(object[signal], k)
                    -- a one-element list collapses back to a bare function
                    if #object[signal] == 1 then object[signal] = object[signal][1] end
                    break
                end
            end
        end
    end
end

-- corelib/util.lua:280-293.  Only '1'/'true' (trimmed, lowercased), the number 1 and
-- a real boolean are true.  shim/settings.lua keeps an identical private copy so it
-- can be required without corelib.
local function toboolean(v)
    if type(v) == 'string' then
        v = STRING_EXT.trim(v):lower()
        if v == '1' or v == 'true' then return true end
    elseif type(v) == 'number' then
        if v == 1 then return true end
    elseif type(v) == 'boolean' then
        return v
    end
    return false
end
corelib.toboolean = toboolean

local function protectedcall(func, ...)
    local status, ret = pcall(func, ...)
    if status then return ret end
    perror(ret)
    return false
end

corelib.connect, corelib.disconnect = connect, disconnect
corelib.signalcall, corelib.protectedcall = signalcall, protectedcall

-- ===========================================================================
-- 5. the event scheduler globals  (modules/corelib/globals.lua:23-115)
-- ===========================================================================
-- The real ones return a C++ ScheduledEvent with :cancel() / :isCanceled() /
-- :isExecuted(); globals.lua parks the callback on `._callback` so the GC cannot
-- collect it, and `removeEvent` cancels then clears that field, TOLERATING nil.
-- Here the handle is a Lua table over one lib/sched timer id.

local Event = {}
Event.__index = Event

function Event:cancel()
    if self._canceled or self._executed then return false end
    self._canceled = true
    if self._id ~= nil then self._sched.cancel(self._id) end
    return true
end
function Event:isCanceled() return self._canceled == true end
function Event:isExecuted() return self._executed == true end
--- Not in otclient; lets a caller ask whether the handle is still live.
function Event:isActive() return not (self._canceled or self._executed) end

local function newEvent(sched, callback)
    return setmetatable({ _sched = sched, _callback = callback,
                          _canceled = false, _executed = false }, Event)
end

--- Build the four event globals over any scheduler exposing after/every/cancel.
--- Exposed separately so the test suite can drive them from a fake clock.
function corelib.makeEvents(sched)
    local E = {}

    function E.scheduleEvent(callback, delay)
        if type(callback) ~= 'function' then
            error('scheduleEvent: callback must be a function, got ' .. type(callback), 2)
        end
        local ev = newEvent(sched, callback)
        ev._id = sched.after(tonumber(delay) or 0, function()
            ev._executed = true
            ev._id = nil
            if ev._canceled then return end
            callback()
        end)
        return ev
    end

    --- addEvent(cb, front): otclient runs it on the NEXT dispatcher pass.  With one
    --- reactor the closest equivalent is a zero-delay timer; `front` has no meaning
    --- because lib/sched has no priority queue, and there are 0 call sites.
    function E.addEvent(callback, front)
        if front then
            local ok, log = pcall(require, 'lib.log')
            if ok then log.debug('addEvent(front=true): lib/sched has no front queue; '
                                 .. 'ordering is FIFO. 0 call sites in the executed corpus.') end
        end
        return E.scheduleEvent(callback, 0)
    end

    function E.cycleEvent(callback, interval)
        if type(callback) ~= 'function' then
            error('cycleEvent: callback must be a function, got ' .. type(callback), 2)
        end
        local ev = newEvent(sched, callback)
        ev._cycle = true
        ev._id = sched.every(tonumber(interval) or 0, function()
            if ev._canceled then return end
            callback()
        end)
        return ev
    end

    function E.deferEvent(callback)
        if not callback then return end
        E.scheduleEvent(callback, 0)
    end

    function E.periodicalEvent(eventFunc, conditionFunc, delay, autoRepeatDelay)
        delay = delay or 30
        autoRepeatDelay = autoRepeatDelay or delay
        local func
        func = function()
            if conditionFunc and not conditionFunc() then func = nil; return end
            eventFunc()
            E.scheduleEvent(func, delay)
        end
        E.scheduleEvent(function() func() end, autoRepeatDelay)
    end

    --- removeEvent(event) -- tolerates nil AND an already-fired handle, exactly like
    --- globals.lua:110-115 (Event::cancel on an executed C++ event is a no-op).
    function E.removeEvent(event)
        if event then
            event:cancel()
            event._callback = nil
        end
    end

    return E
end

-- ===========================================================================
-- 6. regexMatch indirection
-- ===========================================================================
-- table.decodeStringPairList calls the GLOBAL regexMatch upstream.  The shim has no
-- real _G global, so the binding lives here and `install` points it at the engine.
-- Tests swap it to prove decodeStringPairList really goes through regexMatch.

corelib.regexMatch = regex.match

-- ===========================================================================
-- 7. install / uninstall
-- ===========================================================================

local installed = nil

local function patch(target, name, ext, snapshot, kind)
    for k, v in pairs(ext) do
        local old = rawget(target, k)
        snapshot[#snapshot + 1] = { t = target, k = k, v = old }
        if old ~= nil and old ~= v then
            logline('debug', 'shim/corelib: %s.%s already existed and is being replaced '
                          .. 'by the otclient %s implementation', name, k, kind)
        end
        target[k] = v
    end
end

--- install(G [, opts]) -> handle
---   opts.sched         : scheduler with after/every/cancel  (default lib.sched)
---   opts.regexMatch    : override the regex engine (tests)
---   opts.patchGlobals  : false to skip patching _G.string/_G.table/_G.math
--- Returns { uninstall = fn, events = {...}, G = <cross-reload table> }.
function corelib.install(G, opts)
    opts = opts or {}
    if type(G) ~= 'table' then error('corelib.install: G must be a table', 2) end
    if installed then
        -- boot is documented as idempotent (PLAN.md 1.1): put the stdlib back the way
        -- it was found, then install cleanly on top of it.
        logline('debug', 'shim/corelib: re-installing over a previous install')
        installed.uninstall()
    end

    G_ref = G
    if opts.regexMatch then corelib.regexMatch = opts.regexMatch end

    local snapshot = {}
    if opts.patchGlobals ~= false then
        -- table BEFORE string: string.split calls table.removevalue at run time, and
        -- table.decodeStringPairList needs regexMatch, which is set just above.
        patch(table,  'table',  TABLE_EXT,  snapshot, 'table')
        patch(string, 'string', STRING_EXT, snapshot, 'string')
        patch(math,   'math',   MATH_EXT,   snapshot, 'math')
    end

    local sched = opts.sched or require('lib.sched')
    local events = corelib.makeEvents(sched)

    G.connect, G.disconnect = connect, disconnect
    G.signalcall, G.protectedcall = signalcall, protectedcall
    G.scheduleEvent  = events.scheduleEvent
    G.removeEvent    = events.removeEvent
    G.cycleEvent     = events.cycleEvent
    G.addEvent       = events.addEvent
    G.deferEvent     = events.deferEvent
    G.periodicalEvent = events.periodicalEvent

    G.regexMatch = corelib.regexMatch
    G.json       = json
    G.base64     = corelib.base64
    G.toboolean  = toboolean
    G.gcinfo     = _G.gcinfo
    G.bit        = require('bit')

    -- corelib/math.lua's one global
    G.roundToTwoDecimalPlaces = function(value) return math.floor(value * 100 + 0.5) / 100 end

    -- the tables the executor copies onto the sandbox context
    G.string, G.table, G.math, G.os = string, table, math, os

    -- globals.lua:7 -- `G = G or {}`, kept across a config reload
    G.G = G.G or {}

    installed = {
        events = events,
        G = G.G,
        uninstall = function()
            for i = #snapshot, 1, -1 do
                local e = snapshot[i]
                e.t[e.k] = e.v
            end
            installed = nil
            G_ref = nil
        end,
    }
    return installed
end

function corelib.isInstalled() return installed ~= nil end

-- ===========================================================================
-- 8. base64 (modules/corelib/base64.lua -> lib/base64.lua)
-- ===========================================================================
-- `executor.lua:122` puts this on the sandbox; there are ZERO vBot call sites.
-- lib/base64.decode is strict by default and returns nil,err; the corelib one is
-- lenient and returns a (possibly wrong) string.  We use lenient decoding so a real
-- caller gets bytes back, and RAISE on input that is not base64 at all rather than
-- returning nil, because a nil would flow silently into a concatenation.
corelib.base64 = {
    encode = function(s) return b64.encode(tostring(s)) end,
    decode = function(s)
        local out, err = b64.decode(tostring(s), { lenient = true, anyAlphabet = true })
        if out == nil then error('base64.decode: ' .. tostring(err), 2) end
        return out
    end,
    urlencode = function(s, pad) return b64.urlencode(tostring(s), pad) end,
    urldecode = function(s)
        local out, err = b64.urldecode(tostring(s))
        if out == nil then error('base64.urldecode: ' .. tostring(err), 2) end
        return out
    end,
    isValid = b64.isValid,
}

corelib.STRING_EXT, corelib.TABLE_EXT, corelib.MATH_EXT = STRING_EXT, TABLE_EXT, MATH_EXT

return corelib
