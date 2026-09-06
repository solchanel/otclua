--[==[==========================================================================
bot/cavebot.lua -- the waypoint engine (work item M2).

Behaviour source: docs/vbot/cavebot.md (`<P>/cavebot/*.lua`), whose
"## VERIFIER (Corrections)" section OVERRIDES the spec body and is followed here.
Config format of record: the user's real `cavebot_configs/*.cfg` files, consumed unchanged
through bot/config.lua (ordered key:value pairs, `[[`/`]]` multi-line values, the three
reserved trailing keys `config` / `extensions` / `staypositions`).

    local cb = cavebot.new(bot, route)     -- route = Profile:loadCavebot(name), a name, or nil
    cb:enable() cb:disable() cb:isOn()
    cb:tick()                              -- registered as a 50 ms macro by :enable()
    cb:status() cb:reload(route)

MAIN LOOP (cavebot.lua:80-203, section 2.1) -- reproduced verbatim:

    1 TargetBot gate  : isActive() and not isCaveBotActionAllowed() -> resetWalking, return
    2 doWalking()     : a step is in flight -> return
    3 empty list      -> return
    4 current = focused (here: self.index)
    5 Stay-Path pre-walk gate (2.4) -- may return without running the action
    6 resetWalking(); run the action inside pcall
    7 "retry" -> retries++, hold position
      boolean -> retries = 0, prevResult = result, positionedBySelfNav latch
      anything else -> warn
    8 focus changed during the action -> re-read, reset retries/prevResult
    9 index = index + 1, wrapping to 1

`false` ADVANCES.  Only the literal string "retry" holds position (cavebot.md pitfalls).

DELAY.  vBot has exactly ONE field (`cavebotMacro.delay`) written by two functions with
different rules: `CaveBot.delay(ms)` takes the MAX, plain `delay(ms)` OVERWRITES
(cavebot.lua:563-565 vs main.lua:206-211).  Both are reproduced (`cb:delay` / `cb:setDelay`)
over one field, and bot/walker.lua's own delay methods are rebound onto that same field at
construction so a walker step and a CaveBot.delay cannot drift apart.  The field is mirrored
onto the macro record, so bot/init.lua's `_invoke` skips the body WITHOUT advancing
`lastExecution` -- which is what makes a delayed macro resume on the next 10 ms host tick
instead of 50 ms later (cavebot.md VERIFIER on section 0).

TICK PERIOD.  50 ms, the floor `macro()` clamps cavebot.lua:80's declared 20 to.

WALKING.  bot/walker.lua owns the ledger, the step timing and the floor-change geometry.
`cb:doWalking()` and `cb:walkTo()` are the vBot-shaped wrappers over it, because the two
differ from walker:walkTo in ways that are load bearing:
  * vBot's `CaveBot.walkTo` returns FALSE when the path is `{}` (already standing on the
    destination) -- walker:walkTo answers 'arrived'.  Every goto branch tests that boolean.
  * vBot's `doWalking` returns FALSE once the stored lookahead is exhausted, so the action
    re-paths from scratch; walker:_doWalking holds instead (VERIFIER: "a stored path is never
    walked to completion").

UNKNOWN WAYPOINTS.  `warn("Invalid cavebot action: <type>")` ONCE per type, then the
dispatcher's nil result advances the index.  A bad line never aborts the route.
KNOWN-BUT-UNIMPLEMENTED types (the ones blocked on protocol builders luaclient does not have
yet: forge / imbuing / tasker / rushlure, and the stash half of stowdeposit) log once and
return false, i.e. they are skipped exactly like a failed waypoint.
==========================================================================]==]

local worldmod   = require('bot.world')
local pathmod    = require('bot.path')
local walkermod  = require('bot.walker')
local suppliesmod= require('bot.supplies')

local abs, ceil, floor, min, max = math.abs, math.ceil, math.floor, math.min, math.max

local DELTA = worldmod.DELTA

local cavebot = {}

local CB = {}
CB.__index = CB

-- ---------------------------------------------------------------------------
-- constants
-- ---------------------------------------------------------------------------
cavebot.TICK_MS            = 50      -- cavebot.lua:80 declares 20; macro() floors it to 50
cavebot.ANTILOST_TICK_MS   = 200     -- antilost.lua:589

-- cavebot/config.lua:26-59 + the three appended by walking.lua:31-37
cavebot.CONFIG_DEFAULTS = {
    ping = 100, walkDelay = 10, mapClick = false, mapClickDelay = 100,
    ignoreFields = false, skipBlocked = false, useDelay = 400, wptDistance = 5,
    antiLostEnabled = true,
    antiLostTeleportIds = '1949,1950,1951,1952',
    antiLostLadderIds = '1948,1968,5542,7771,9116,20474,20475,21365,28656,31129,31130,'
                     .. '31262,33770,34243,35908,43374,48493,48494,50122,50123,50564,'
                     .. '50565,435,7750,21221,21298',
    antiLostRopeIds = '386,7762,12935,12936,13381,33051',
    antiLostRopeToolId = 3003,
    stayPathEnabled = true, waypointHud = false,
    smoothWalk = false, avoidFloorChange = true, avoidTileIds = '',
    -- WORK ITEM W.  Not a vBot key; a .cfg may still override it (config blobs are merged
    -- over these defaults verbatim).  ON means: at most ONE walk packet outstanding, and the
    -- next one waits for the server's position update OR the computed step duration,
    -- whichever is later.  vBot can afford its lookahead because it runs inside the C++
    -- client, where LocalPlayer::canWalk() refuses a second step while a pre-walk is
    -- outstanding; a headless client has no such gate and out-paces the server without this.
    strictPacing = true,
}

-- actions.lua:139-175
cavebot.STAYPATH_EXCLUDED = {
    ['goto'] = true, use = true, usewith = true, label = true, gotolabel = true,
    delay = true, follow = true, walkdelay = true, depositor = true, stowdeposit = true,
    bank = true, buysupplies = true, sellall = true, travel = true, imbuing = true,
    inwithdraw = true, dpwithdraw = true, withdraw = true, cleartile = true,
    opendoors = true,
}
-- cavebot.lua:17-21
cavebot.STAYPATH_SELF_NAV = {
    follow = true, sellall = true, buysupplies = true, bank = true, travel = true,
    depositor = true, stowdeposit = true, withdraw = true, dpwithdraw = true,
    inwithdraw = true, imbuing = true, cleartile = true, opendoors = true,
}

cavebot.STAYPATH_MAX_DRIFT = 15      -- cavebot.lua:34
cavebot.STAYPATH_STUCK_MS  = 3000    -- cavebot.lua:8
cavebot.STAYPATH_LOOKBACK  = 12      -- cavebot.lua:37-56

cavebot.STAIRS_COLOR_MIN = 210
cavebot.STAIRS_COLOR_MAX = 213

cavebot.PZ_STATE = 16384             -- PlayerStates.Pz (src/client/const.h:295)

cavebot.LOCKERS_LIST   = { 3497, 3498, 3499, 3500 }
cavebot.LOCKER_OFFSETS = { [3497] = { 0, -1 }, [3498] = { 1, 0 },
                           [3499] = { 0, 1 },  [3500] = { -1, 0 } }
cavebot.DEPOT_CHEST_ID = 3502
cavebot.INBOX_ID       = 12902
cavebot.ROPE_FALLBACK  = 3003        -- antilost.lua rope-tool fallback below id 100

-- ---------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------
local function nolog() end
local function mklog(l)
    if type(l) ~= 'table' then
        return { info = nolog, warn = nolog, error = nolog, debug = nolog }
    end
    return { info  = l.info  or nolog, warn = l.warn  or nolog,
             error = l.error or nolog, debug = l.debug or nolog }
end

local function trim(s) return (tostring(s):gsub('^%s+', ''):gsub('%s+$', '')) end
cavebot.trim = trim

--- Split on a literal separator, trimming each field (vBot's string.split(value, ",")).
--- "a,b" -> {"a","b"};  "a," -> {"a",""};  "" -> {""}.  The field COUNT matters: `bank`
--- validates `#d` and `poscheck` reads an optional 6th field.
local function split(value, sep)
    sep = sep or ','
    local s, out, start = tostring(value), {}, 1
    while true do
        local i = s:find(sep, start, true)
        if not i then out[#out + 1] = trim(s:sub(start)); break end
        out[#out + 1] = trim(s:sub(start, i - 1))
        start = i + #sep
    end
    return out
end
cavebot.split = split

local function cheb(a, b)
    if not (a and b) then return math.huge end
    return max(abs(a.x - b.x), abs(a.y - b.y))
end
cavebot.cheb = cheb

local function manhattan(a, b) return abs(a.x - b.x) + abs(a.y - b.y) end

local function copyPos(p) return p and { x = p.x, y = p.y, z = p.z } or nil end

local function samePos(a, b)
    return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

--- The goto value grammar (actions.lua:347): "x,y,z" with an OPTIONAL 4th precision field.
--- Presence of that field -- even ",0" -- is the "precision marker".
function cavebot.parseGoto(value)
    local x, y, z, prec = tostring(value):match('^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+),?%s*(%d?)')
    if not x then return nil end
    return { x = tonumber(x), y = tonumber(y), z = tonumber(z) },
           (prec ~= nil and prec ~= ''), tonumber(prec)
end

--- "x,y,z" anywhere in the value (use / previousRoutePosition).
local function firstXYZ(value)
    local x, y, z = tostring(value):match('(%d+)%s*,%s*(%d+)%s*,%s*(%d+)')
    if not x then return nil end
    return { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
end

--- "id,x,y,z" (usewith).
local function idXYZ(value)
    local id, x, y, z = tostring(value):match('(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)')
    if not id then return nil end
    return tonumber(id), { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
end

local DIR_NAMES = { north = 0, east = 1, south = 2, west = 3 }

-- ===========================================================================
-- construction
-- ===========================================================================
--- cavebot.new(bot, route, opts)
---   bot    the bot/init.lua instance
---   route  one of
---            * a table from bot/config.lua `Profile:loadCavebot(name)`
---            * `{ waypoints = {{action=,value=,stayPos=},…}, config = {...} }`
---            * a string route name (loaded through bot.config)
---            * nil -> the name in storage._configs.cavebot_configs.selected
---   opts   { world=, path=, walker=, supplies=, now= }
function cavebot.new(bot, route, opts)
    opts = opts or {}
    local self = setmetatable({}, CB)
    self.bot    = bot
    self.client = (bot and bot.client) or bot
    self.state  = bot and bot.state
    self.sender = bot and bot.sender
    self.events = bot and bot.events
    self.log    = mklog(bot and bot.log)
    if not self.state then error('cavebot.new: bot.state is required', 2) end

    self.now = opts.now or (bot and function() return bot.now end)
               or function() return 0 end

    self.world  = opts.world or worldmod.new(self.client)
    self.path   = opts.path  or pathmod.new(self.client, self.world)

    self.enabled     = false
    self.index       = 1
    self.retries     = 0
    self.prevResult  = true
    self.positionedBySelfNav = false
    self.lastLabel   = ''
    self.noPath      = 0          -- actions.lua:5 -- ONE counter shared by every goto
    self.readyAt     = 0
    self.waypoints   = {}
    self.cfg         = {}
    self._warned     = {}         -- "log once" registry (unknown + unimplemented types)
    self._stayWarnAt = 0
    self._floorLogAt = {}
    self.currentAction = nil
    self.lastStatus  = 'idle'
    self.stats = { ticks = 0, actions = 0, retries = 0, skips = 0, arrivals = 0,
                   labelJumps = 0, unknown = 0, laps = 0, blocked = 0 }

    -- per-action scratch (all vBot file-locals)
    self.noProgress   = 0         -- buy_supplies.lua
    self.sellAllCap   = 0         -- sell_all.lua
    self.sellAllNoProgress = 0    -- rounds that sold nothing (REVIEW FIX)
    self.lastRoomMove = 0         -- actions.lua:39 `lastMoved`, the 200 ms throttle
    self.exaniStartZ  = nil       -- route_tools.lua
    self.posCheck     = { value = nil, count = 0 }
    self.stowFallback = {}

    self.supplies = opts.supplies or suppliesmod.new(bot)

    self.walker = opts.walker or walkermod.new(self.client, {
        world = self.world, path = self.path, now = self.now })
    self:_bindWalkerDelay()
    self.walker:attach()
    self.walker.onFloorChangeHook = function(_, info) self:_onFloorChange(info) end
    -- bank transfer scrapes the balance out of an NPC talk (bank.lua:87-91)
    self._talkHandle = self:_busOn('talk', function(d) self:onTalk(d) end)
    -- actions.lua:38-66 -- the unconditional "There is not enough room." anti-stuck hook.
    -- It is NOT part of the waypoint loop: it fires off the text message alone whenever
    -- CaveBot is on (REVIEW FIX; docs/vbot/cavebot.md 2.3, last paragraph).
    self._roomHandle = self:_busOn('textMessage', function(d) self:onNotEnoughRoom(d) end)

    -- antilost state (antilost.lua)
    self.al = { recovering = false, mode = nil, fallSpot = nil, tpId = nil,
                target = nil, attempts = 0, floorChanges = 0 }

    self.actions = {}
    self:_registerActions()

    self:reload(route)
    return self
end

-- lib/events.lua is BOTH a module singleton (dot-called) and a class whose instances are
-- colon-called; a Bus instance owns `_named`.
function CB:_busOn(name, fn)
    local bus = self.events
    if not bus then return nil end
    if rawget(bus, '_named') then return bus:on(name, fn) end
    if type(bus.on) == 'function' then return bus.on(name, fn) end
    return nil
end

function CB:_busOff(handle)
    local bus = self.events
    if not (bus and handle) then return end
    if rawget(bus, '_named') then return bus:off(handle) end
    if type(bus.off) == 'function' then return bus.off(handle) end
end

--- vBot has ONE `macro.delay` field; walker.lua keeps its own `readyAt`.  Rebind the
--- walker's three delay methods onto ours so every `CaveBot.delay` in walking.lua and every
--- `CaveBot.delay` in actions.lua write the same number, as upstream.
function CB:_bindWalkerDelay()
    local cb = self
    local wk = self.walker
    function wk:delay(ms)    return cb:delay(ms) end
    function wk:setDelay(ms) return cb:setDelay(ms) end
    function wk:isDelayed()  return cb:isDelayed() end
    -- keep the field readable for status()/tests
    wk.readyAtOwner = self
end

-- ===========================================================================
-- route loading
-- ===========================================================================
local function normaliseWaypoints(route)
    local wps = {}
    local stay = route.staypositions
    if type(stay) ~= 'table' then stay = nil end
    local src = route.waypoints or route.wps or {}
    for i = 1, #src do
        local w = src[i]
        local action = tostring(w.action or w[1] or ''):lower()   -- actions.lua:186
        local value  = tostring(w.value or w[2] or '')
        local sp = w.stayPos
        if sp == nil and stay then
            local s = stay[tostring(i)] or stay[i]
            if type(s) == 'table' and s.x and s.y and s.z then
                sp = { x = tonumber(s.x), y = tonumber(s.y), z = tonumber(s.z) }
            end
        end
        wps[#wps + 1] = { action = action, value = value, stayPos = sp, index = i }
    end
    return wps
end
cavebot.normaliseWaypoints = normaliseWaypoints

--- reload(route) -- cavebot.lua:279-284: on (re)load the pending delay is cleared,
--- actionRetries = 0, prevActionResult = true, positionedBySelfNav = false and
--- CaveBot.resetWalking() runs.  Config.onConfigChange restores every DEFAULT before
--- applying the file blob, so a key missing from the .cfg really does revert (config.lua:80-90).
function CB:reload(route)
    if type(route) == 'string' then
        route = self:_loadNamed(route)
    elseif route == nil then
        local sel = self.bot and self.bot.storage and self.bot.storage._configs
                    and self.bot.storage._configs.cavebot_configs
        if type(sel) == 'table' and type(sel.selected) == 'string' and #sel.selected > 0 then
            route = self:_loadNamed(sel.selected)
        end
    end
    route = route or { waypoints = {} }

    self.route      = route
    self.routeName  = route.name or self.routeName
    self.waypoints  = normaliseWaypoints(route)

    local cfg = {}
    for k, v in pairs(cavebot.CONFIG_DEFAULTS) do cfg[k] = v end
    if type(route.config) == 'table' then
        for k, v in pairs(route.config) do cfg[k] = v end
    end
    self.cfg = cfg
    self.walker:configure(cfg)
    self.avoidIds  = worldmod.parseIdList(cfg.avoidTileIds)
    -- antilost.lua:41-59: an EMPTY csv falls back to the built-in default list, so `""`
    -- does not disable a recovery mode.
    self.ladderIds   = self:_idList(cfg.antiLostLadderIds,   'antiLostLadderIds')
    self.ropeIds     = self:_idList(cfg.antiLostRopeIds,     'antiLostRopeIds')
    self.teleportIds = self:_idList(cfg.antiLostTeleportIds, 'antiLostTeleportIds')

    self.index, self.retries, self.prevResult = 1, 0, true
    self.positionedBySelfNav = false
    self.noPath   = 0
    self.readyAt  = 0
    self:_syncMacroDelay()
    self.walker:reset(true)
    self.stayTarget, self.stayBest, self.stayBestAt = nil, nil, 0
    return self
end

function CB:_idList(v, key)
    local list = worldmod.parseIdList(v)
    if #list == 0 then
        list = worldmod.parseIdList(cavebot.CONFIG_DEFAULTS[key])
    end
    return list
end

function CB:_loadNamed(name)
    local prof = self.bot and self.bot.config
    if not (prof and prof.loadCavebot) then
        self.log.warn('[CaveBot] cannot load route %s: no profile directory', tostring(name))
        return nil
    end
    local r, err = prof:loadCavebot(name)
    if not r then
        self.log.warn('[CaveBot] route %s: %s', tostring(name), tostring(err))
        return nil
    end
    return r
end

-- ===========================================================================
-- delay plumbing (cavebot.lua:563-565 vs main.lua:206-211)
-- ===========================================================================
--- CaveBot.delay(ms): MAX.  Never shortens a delay another action already set this tick.
function CB:delay(ms)
    local t = self.now() + (tonumber(ms) or 0)
    if t > self.readyAt then self.readyAt = t end
    self:_syncMacroDelay()
    return self.readyAt
end

--- plain delay(ms): OVERWRITE.  This one CAN shorten (CaveBot.PingDelay uses it).
function CB:setDelay(ms)
    self.readyAt = self.now() + (tonumber(ms) or 0)
    self:_syncMacroDelay()
    return self.readyAt
end

function CB:isDelayed() return self.now() < self.readyAt end

--- Mirror onto the macro record so bot/init.lua's `_invoke` skips the body without
--- advancing lastExecution -- the 10 ms resume the VERIFIER requires.
function CB:_syncMacroDelay()
    if self._macro then self._macro.delay = self.readyAt end
end

--- new_cavebot_lib.lua:142-148 -- a NO-OP unless the real ping exceeds 150 ms, and it uses
--- the OVERWRITE delay, so at low ping every "PingDelay" in the depot code does nothing.
function CB:pingDelay(mult)
    local p = self:pingMs(true)
    if type(p) ~= 'number' or p <= 150 then return false end
    self:setDelay(min(p * (mult or 1), 2000))
    return true
end

--- walking.lua:209-215 -- the measured ping, replaced by the CONFIG value when it is not a
--- usable number.  `raw` asks for the measured value only (PingDelay's gate).
function CB:pingMs(raw)
    local p = self.state.ping or (self.client and self.client.ping)
    if type(p) ~= 'number' or p <= 0 or p > 5000 then
        if raw then return 0 end
        p = tonumber(self.cfg.ping) or 100
    end
    return p
end

--- talkDelay: bot storage extras (default 1000).
function CB:talkDelay()
    local e = self.supplies:extras()
    return tonumber(e.talkDelay) or 1000
end

--- storage.extras.gotoMaxDistance -- NOT a route-config key (VERIFIER).  actions.lua:385
--- defaults to 40; the two waypoint scanners read it with NO fallback.
function CB:gotoMaxDistance(withFallback)
    local e = self.supplies:extras()
    local v = tonumber(e.gotoMaxDistance)
    if v then return v end
    if withFallback == false then return nil end
    return 40
end

-- ===========================================================================
-- walking wrappers (vBot-shaped, over bot/walker.lua)
-- ===========================================================================
function CB:resetWalking() self.walker:reset(true); return self end

--- CaveBot.doWalking (walking.lua:307-333) -> true while a step is in flight.
--- VERIFIER: at most ONE send per tick, only while a previously sent step is still
--- unconfirmed, and FALSE once the lookahead is exhausted so the action re-paths.
function CB:doWalking()
    local wk = self.walker
    if self.cfg.smoothWalk then
        return wk:_smoothWalking() ~= nil
    end
    if self.cfg.mapClick then return false end
    -- Resolve the outstanding step against the server's position FIRST.  Before work item W
    -- this function reported "not walking" whenever the stored lookahead was exhausted even
    -- though a step was still in flight; CB:tick() then fell through to the action, which
    -- re-pathed from the STALE position and re-sent the same direction.  That is what put two
    -- steps on the wire per server beat and made the character overshoot its waypoint.
    wk:pollConfirm()
    local n = #wk.expected
    if n == 0 then return false end
    if wk.cfg.strictPacing then
        -- One step outstanding, full stop.  Holding here (rather than returning false) is
        -- what stops CB:tick() from re-pathing while the step is unconfirmed.
        return true
    end
    if n >= walkermod.MAX_UNCONFIRMED then
        wk:reset()                 -- walkPath is cleared, so the next line finds nil
        return false
    end
    local dir = wk.walkPath[wk.iter]
    if dir == nil then
        wk:_dbg('[walk] CB:doWalking t=%d lookahead exhausted with %d outstanding -> %s',
                self.now(), n, 'false (tick falls through to the action)')
        return false
    end
    local ok, why = wk:step(dir)
    if ok then
        wk.iter = wk.iter + 1
        return true
    end
    if why == 'send-refused-limit' then return false end
    return true                     -- a refused send is retried after 25 ms
end

--- CaveBot.walkTo(dest, maxDist, params) -> boolean, exactly like vBot's.
--- FALSE means "no usable path" -- including "we are already standing there", because
--- getPath returns `{}` and vBot tests `path[1]`.
function CB:walkTo(dest, maxDist, params)
    local wk = self.walker
    local st = self.state
    local pp = st.player and st.player.pos
    if not (pp and dest) then return false end
    if pp.z ~= dest.z then return false end

    local from = self.cfg.smoothWalk and (wk:projectedPos() or pp) or pp
    local dirs = self.path:getPath(from, dest, maxDist, params or {})
    if not dirs or not dirs[1] then
        if self.cfg.smoothWalk and #wk.pending > 0 then self:delay(50); return true end
        return false
    end

    if self.cfg.avoidFloorChange ~= false then
        local bad, why = self.path:crossesFloorChange(from, dest, dirs, self.avoidIds)
        if bad then
            self:_logFloorRefusal(why)
            return false
        end
    end

    if self.cfg.mapClick then
        local body, sent = self.sender and self.sender:autoWalk(dirs)
        if not body then return false end
        wk.stats.sent = wk.stats.sent + (sent or #dirs)
        wk.lastStepDir = dirs[min(sent or #dirs, #dirs)]
        self:delay((tonumber(self.cfg.mapClickDelay) or 100)
                   + (self.cfg.smoothWalk and 0 or 50))
        if self.cfg.smoothWalk then
            wk.pendingAuto = true
            wk.lastConfirmAt = self.now()
            for i = 1, (sent or #dirs) do
                wk.pending[#wk.pending + 1] = { dir = dirs[i], t = self.now() }
            end
            wk.smoothDest = copyPos(dest)
        end
        return true
    end

    if self.cfg.smoothWalk then
        wk.walkPath, wk.iter = dirs, 1
        wk.smoothDest = copyPos(dest)
        wk:_smoothWalking()
        return true
    end

    local ok = wk:step(dirs[1])
    if not ok then return false end
    wk.walkPath, wk.iter = dirs, 2
    return true
end

-- walking.lua log throttle: one message per tile per 10 s.
function CB:_logFloorRefusal(why)
    local k = tostring(why)
    local t = self.now()
    if (self._floorLogAt[k] or -1e9) + 10000 <= t then
        self._floorLogAt[k] = t
        self.log.info('[CaveBot] path refused: %s', k)
    end
end

--- new_cavebot_lib.lua:225-231 -- maxDist is a hard 20 and it does NOT pass
--- ignoreNonPathable, so it refuses to path across fields.
function CB:goTo(pos, precision)
    return self:walkTo(pos, 20, { ignoreCreatures = true, precision = precision or 3 })
end

--- new_cavebot_lib.lua:213-218
function CB:matchPosition(pos, distance)
    local pp = self.state.player and self.state.player.pos
    if not (pp and pos) then return false end
    if pp.z ~= pos.z then return false end
    return cheb(pp, pos) <= (distance or 1)
end

--- new_cavebot_lib.lua:242-279 -- long range: a normal walkTo; within 3 tiles: wait out any
--- in-flight step, then send EXACTLY ONE step and delay(stepDuration + ping + 50).
function CB:preciseGoTo(pos, precision)
    local pp = self.state.player and self.state.player.pos
    if not (pp and pos) then return false end
    if cheb(pp, pos) > 3 then
        return self:walkTo(pos, 20, { ignoreCreatures = true, precision = precision or 1 })
    end
    if self.walker:isWalking() then self:delay(50); return true end
    local dirs = self.path:getPath(pp, pos, 10,
                                   { ignoreNonPathable = true, precision = precision or 0 })
    if not (dirs and dirs[1]) then return false end
    local ok = self.walker:step(dirs[1])
    if not ok then return false end
    self:delay(self.walker:stepDuration(dirs[1]) + self:pingMs() + 50)
    return true
end

-- ===========================================================================
-- label / waypoint navigation
-- ===========================================================================
--- CaveBot.gotoLabel (cavebot.lua:567-576): case-insensitive scan for the FIRST `label`
--- waypoint whose value matches; focus it.  The dispatcher then advances +1, so execution
--- resumes at the waypoint AFTER the label (cavebot.md pitfalls).
function CB:gotoLabel(name)
    local want = tostring(name):lower()
    for i = 1, #self.waypoints do
        local w = self.waypoints[i]
        if w.action == 'label' and tostring(w.value):lower() == want then
            self.index = i
            self.stats.labelJumps = self.stats.labelJumps + 1
            return true
        end
    end
    return false
end

--- CaveBot.gotoNextWaypointInRange (cavebot.lua:352-401).  Scan forward from the current
--- index, then a second pass from 1 THROUGH the current index (VERIFIER: it includes the
--- current waypoint), for the first reachable same-floor goto within gotoMaxDistance.
--- Focus index-1 so the loop's +1 lands on it; a match at i == 1 unfocuses the list, and the
--- loop then falls back to the first child and advances to 2 -- reproduced here as index 1
--- with a flag that makes the advance land on 2.
function CB:gotoNextWaypointInRange()
    local pp = self.state.player and self.state.player.pos
    if not pp then return false end
    local maxDist = self:gotoMaxDistance(false)
    if maxDist == nil then
        self.log.warn('[CaveBot] gotoNextWaypointInRange: storage.extras.gotoMaxDistance is unset')
        return false
    end
    local function try(i)
        local w = self.waypoints[i]
        if not (w and w.action == 'goto') then return false end
        local dest = cavebot.parseGoto(w.value)
        if not (dest and dest.z == pp.z) then return false end
        if cheb(pp, dest) > maxDist then return false end
        local dirs = self.path:getPath(pp, dest, maxDist, { ignoreNonPathable = true })
        if not dirs then return false end
        if i == 1 then
            -- focusChild(getChildByIndex(0)) unfocuses; the loop restarts at 1 and
            -- advances to 2.
            self.index = 1
            self._skipToSecond = true
        else
            self.index = i - 1
        end
        return true
    end
    for i = self.index + 1, #self.waypoints do if try(i) then return true end end
    for i = 1, min(self.index, #self.waypoints) do if try(i) then return true end end
    return false
end

--- CaveBot.gotoFirstPreviousReachableWaypoint (cavebot.lua:422-455).
--- VERIFIER: the index is decremented CUMULATIVELY (`for i=0,100 do index = index - i`), so
--- the inspected offsets are the triangular numbers 0,1,3,6,10,... and the loop breaks as
--- soon as |index - current| > 100.  It therefore examines ~14 waypoints, and the FIRST one
--- examined (i = 0) is the current waypoint itself.
function CB:gotoFirstPreviousReachableWaypoint()
    local pp = self.state.player and self.state.player.pos
    if not pp then return false end
    local maxDist = self:gotoMaxDistance(false)
    if maxDist == nil then
        self.log.warn('[CaveBot] gotoFirstPreviousReachableWaypoint: gotoMaxDistance is unset')
        return false
    end
    local start = self.index
    local index = start
    for i = 0, 100 do
        index = index - i
        if abs(index - start) > 100 then break end
        local w = (index >= 1) and self.waypoints[index] or nil
        if w and w.action == 'goto' then
            local dest = cavebot.parseGoto(w.value)
            -- REVIEW FIX: cavebot.lua:439-445 checks ONLY the floor and the halved
            -- gotoMaxDistance -- there is no findPath there (unlike
            -- gotoNextWaypointInRange).  The extra reachability test made the anti-lost
            -- last resort fail in exactly the situation it exists for.
            if dest and dest.z == pp.z and cheb(pp, dest) <= maxDist / 2 then
                self.index = index
                return true
            end
        end
    end
    return false
end

--- pathfinder() (actions.lua:119-134): a no-op unless storage.extras.pathfinding, and it
--- only fires once noPath has reached 10.  The `#Unibase` profile toggle is deliberately
--- NOT ported (it depends on a getConfigFromName hook this client does not have).
function CB:pathfinder()
    local e = self.supplies:extras()
    if not e.pathfinding then return false end
    if self.noPath < 10 then return false end
    self.noPath = 0
    return self:gotoNextWaypointInRange()
end

function CB:_noPathStrike()
    self.noPath = self.noPath + 1
    self:pathfinder()
end

-- ===========================================================================
-- Stay Path (cavebot.lua:97-156)
-- ===========================================================================
--- previousRoutePosition (cavebot.lua:37-56): up to 12 rows back, the position of a
--- goto/node/use ("x,y,z") or usewith ("id,x,y,z") waypoint.
function CB:previousRoutePosition(i)
    for j = i - 1, max(1, i - cavebot.STAYPATH_LOOKBACK), -1 do
        local w = self.waypoints[j]
        if w then
            if w.action == 'goto' or w.action == 'node' or w.action == 'use' then
                local p = firstXYZ(w.value)
                if p then return p end
            elseif w.action == 'usewith' then
                local _, p = idXYZ(w.value)
                if p then return p end
            end
        end
    end
    return nil
end

--- Returns true when the action must NOT run yet (we are still walking to the stayPos).
function CB:_stayPathGate(w)
    if not self.cfg.stayPathEnabled then return false end
    if not w.stayPos then return false end
    if self.positionedBySelfNav then return false end
    if cavebot.STAYPATH_EXCLUDED[w.action] then return false end

    local sp = w.stayPos
    local pp = self.state.player and self.state.player.pos
    if not pp then return false end

    -- staleness filter
    local ref = self:previousRoutePosition(self.index)
    if ref then
        local drift = max(abs(ref.x - sp.x), abs(ref.y - sp.y))
        if ref.z ~= sp.z or drift > cavebot.STAYPATH_MAX_DRIFT then
            if not w._staleLogged then
                w._staleLogged = true
                self.log.info('[CaveBot] stay position for waypoint %d is stale, ignored',
                              self.index)
            end
            self.stayTarget = nil
            return false
        end
    end

    if pp.z ~= sp.z or (abs(pp.x - sp.x) <= 2 and abs(pp.y - sp.y) <= 2) then
        self.stayTarget = nil
        return false
    end

    local d = cheb(pp, sp)
    local t = self.now()
    if self.stayTarget ~= w then
        self.stayTarget, self.stayBest, self.stayBestAt = w, d, t
    elseif d < (self.stayBest or d) then
        self.stayBest, self.stayBestAt = d, t          -- STRICT improvement only
    end

    if t - (self.stayBestAt or t) < cavebot.STAYPATH_STUCK_MS then
        if not self:walkTo(sp, 40, { ignoreNonPathable = true, precision = 2 }) then
            if t - self._stayWarnAt >= cavebot.STAYPATH_STUCK_MS then
                self._stayWarnAt = t
                self.log.warn('[CaveBot] cannot reach the stay position of waypoint %d',
                              self.index)
            end
        end
        return true                                   -- do not run the action yet
    end
    -- 3 s without improvement: FAIL OPEN and run the action from wherever we are.
    return false
end

-- ===========================================================================
-- the tick (cavebot.lua:80-203)
-- ===========================================================================
function CB:tick()
    if not self.enabled then return end
    if self:isDelayed() then return end
    self.stats.ticks = self.stats.ticks + 1

    -- 1) TargetBot owns the character while it is fighting or looting
    if self.bot and self.bot.isActionAllowed and not self.bot:isActionAllowed('cavebot') then
        self:resetWalking()
        self.lastStatus = 'yield:targetbot'
        return
    end

    -- 2) a step is in flight
    if self:doWalking() then
        self.lastStatus = 'walking'
        return
    end

    -- 3) empty route
    local wps = self.waypoints
    if #wps == 0 then self.lastStatus = 'no-route'; return end

    -- 4) current waypoint
    if self.index < 1 or self.index > #wps then self.index = 1 end
    local before = self.index
    local w = wps[self.index]

    -- 5) Stay Path pre-walk
    if self:_stayPathGate(w) then
        self.lastStatus = 'staypath'
        return
    end

    -- 6) dispatch
    self:resetWalking()                       -- ALWAYS, before the callback (cavebot.lua:163)
    self.currentAction = w.action
    self.stats.actions = self.stats.actions + 1
    local fn = self.actions[w.action]
    local result
    if fn then
        local ok, r = pcall(fn, self, w.value, self.retries, self.prevResult, w)
        if ok then
            result = r
        else
            self.log.warn('[CaveBot] action %s error: %s', w.action, tostring(r))
            result = nil
        end
    else
        self:_warnOnce(w.action, 'Invalid cavebot action: ' .. tostring(w.action))
        self.stats.unknown = self.stats.unknown + 1
        result = nil
    end

    -- 7) result handling
    if result == 'retry' then
        self.retries = self.retries + 1
        self.stats.retries = self.stats.retries + 1
        self.lastStatus = 'retry:' .. w.action
        return
    end
    if type(result) == 'boolean' then
        self.retries, self.prevResult = 0, result
        if not result then self.stats.skips = self.stats.skips + 1 end
        -- positionedBySelfNav latch (cavebot.lua:173-177)
        if w.action == 'goto' or w.action == 'node' then
            self.positionedBySelfNav = false
        elseif result == true and cavebot.STAYPATH_SELF_NAV[w.action] then
            self.positionedBySelfNav = true
        end
    elseif result ~= nil then
        self.log.warn('[CaveBot] action %s returned %s', w.action, tostring(result))
    end

    -- 8) an action that jumped the focus (gotoLabel / poscheck / pathfinder)
    if self.index ~= before then
        self.retries, self.prevResult = 0, true
    end

    -- 9) advance
    if self._skipToSecond then
        self._skipToSecond = nil
        self.index = 2
    else
        self.index = self.index + 1
    end
    if self.index > #wps then
        self.index = 1
        self.stats.laps = self.stats.laps + 1
    end
    self.lastStatus = 'ok:' .. w.action
end

function CB:_warnOnce(key, msg)
    if self._warned[key] then return false end
    self._warned[key] = true
    self.log.warn('[CaveBot] %s', msg)
    return true
end

-- ===========================================================================
-- lifecycle
-- ===========================================================================
--- Register the two macros WITHOUT touching the on/off flag.  Split out of enable() by the
--- integration work item so bot/init.lua's wireModules can fix the registration order
--- (healbot, attackbot, targetbot, cavebot) independently of which modules start enabled.
--- Idempotent; `CB.onBotStart` calls it, so a bot that never enables CaveBot still holds the
--- macro slots in the documented priority order.
function CB:attach()
    if self._macro or not (self.bot and self.bot.macro) then return false end
    local cb = self
    self._macro = self.bot:macro(cavebot.TICK_MS, 'CaveBot', function() cb:tick() end)
    self._macro.enabled = true
    self._antiLostMacro = self.bot:macro(cavebot.ANTILOST_TICK_MS, 'CaveBot AntiLost',
                                         function() cb:antiLostTick() end)
    self._antiLostMacro.enabled = true
    self:_syncMacroDelay()
    return true
end

CB.onBotStart = function(self) self:attach() end
CB.onBotStop  = function(self) self:resetWalking() end

function CB:enable()
    if self.enabled then return false end
    self.enabled = true
    self:attach()
    if self.bot and self.bot.setConfigEnabled then
        self.bot:setConfigEnabled('cavebot_configs', true)
    end
    return true
end

function CB:disable()
    self.enabled = false
    self:resetWalking()
    self.al.recovering = false
    if self.bot and self.bot.setConfigEnabled then
        self.bot:setConfigEnabled('cavebot_configs', false)
    end
    return true
end

function CB:isOn() return self.enabled == true end
function CB:setOn(v)  if v == false then return self:disable() end return self:enable() end
function CB:setOff(v) if v == false then return self:enable()  end return self:disable() end

-- ===========================================================================
-- anti-lost (antilost.lua)
-- ===========================================================================
--- isExpectedFloorChange (antilost.lua:279-361).  VERIFIER: after {current, prev} there is
--- an EARLY HARD EXIT -- if the current waypoint has a position and the fall did not happen
--- within 1 tile of it, the change is accidental immediately and the 6-waypoint lookahead
--- never runs.
function CB:isExpectedFloorChange(newZ, oldPos)
    local function actionPosition(w)
        if not w then return nil end
        if w.action == 'goto' or w.action == 'node' or w.action == 'use' then
            return firstXYZ(w.value)
        elseif w.action == 'usewith' then
            local _, p = idXYZ(w.value); return p
        end
        return w.stayPos
    end
    local function nearXY(a, b, r)
        return a and b and abs(a.x - b.x) <= r and abs(a.y - b.y) <= r
    end
    local function explains(w)
        if not w then return false end
        local a = w.action
        if a == 'use' or a == 'usewith' or a == 'exanihur' then return true end
        if a == 'goto' or a == 'node' then
            local dest, marker = cavebot.parseGoto(w.value)
            if not dest then return false end
            if dest.z == newZ then return true end
            if nearXY(dest, oldPos, 1) then
                if marker then return true end
                local c = self.world:mapColorAt(dest)
                if c >= cavebot.STAIRS_COLOR_MIN and c <= cavebot.STAIRS_COLOR_MAX then
                    return true
                end
            end
        end
        return false
    end

    local cur  = self.waypoints[self.index]
    local prev = self.waypoints[self.index - 1]
    if explains(cur) or explains(prev) then return true end

    local curPos = actionPosition(cur)
    if curPos and not nearXY(curPos, oldPos, 1) then return false end   -- VERIFIER

    for i = self.index + 1, min(self.index + 6, #self.waypoints) do
        local w = self.waypoints[i]
        if explains(w) then return true end
        local p = actionPosition(w)
        if p and not nearXY(p, oldPos, 1) then return false end
    end
    return false
end

--- Driven from walker.onFloorChangeHook, which already applied the 60 s bounce guard with
--- the write-before-test ordering the VERIFIER demands.
function CB:_onFloorChange(info)
    if not self.enabled or not self.cfg.antiLostEnabled then return end
    if self.al.recovering then
        self.al.target = nil
        self.al.floorChanges = self.al.floorChanges + 1
        if self.al.floorChanges > walkermod.MAX_FLOOR_CHANGES_PER_RECOVERY then
            self:giveUpToCaveBot()
        end
        return
    end
    if self:isExpectedFloorChange(info.to.z, info.from) then return end
    if info.suppressed then return end                       -- bounce guard

    local tile = self.state:tile(info.from)
    local top  = tile and self.world:getTopUseThing(tile)
    local topId = top and top.kind == 'item' and top.id or nil

    self.al.fallSpot = copyPos(info.from)
    self.al.recovering = true
    self.al.target, self.al.attempts, self.al.floorChanges = nil, 0, 0
    if topId and worldmod.idListHas(self.teleportIds, topId) then
        self.al.mode, self.al.tpId = 'teleport', topId
    else
        self.al.mode, self.al.tpId = 'stairs', nil
    end
    self.log.warn('[CaveBot] unexpected floor change %d -> %d, recovering (%s)',
                  info.from.z, info.to.z, self.al.mode)
    self:delay(walkermod.RECOVERY_FREEZE_MS)
end

--- isBackOnTrack (antilost.lua:192-241): the current waypoint's own position must be on our
--- floor and reachable.  A position-less waypoint counts as OK.
function CB:isBackOnTrack(pp)
    local w = self.waypoints[self.index]
    if not w then return true end
    local p
    if w.action == 'goto' or w.action == 'node' or w.action == 'use' then
        p = firstXYZ(w.value)
    elseif w.action == 'usewith' then
        local _, q = idXYZ(w.value); p = q
    else
        p = w.stayPos
    end
    if not p then return true end
    if p.z ~= pp.z then return false end
    local dirs = self.path:getPath(pp, p, self:gotoMaxDistance(),
                                   { ignoreNonPathable = true, precision = 1,
                                     ignoreCreatures = true, allowUnseen = true,
                                     allowOnlyVisibleTiles = false })
    return dirs ~= nil
end

function CB:giveUpToCaveBot()
    self.al.recovering = false
    self.al.target = nil
    if self:gotoNextWaypointInRange() then return true end
    return self:gotoFirstPreviousReachableWaypoint()
end

--- The 200 ms recovery loop.  VERIFIER: the freeze is applied BEFORE isBackOnTrack, so the
--- pass that ends recovery still leaves CaveBot frozen for up to 1500 ms.
function CB:antiLostTick()
    if not self.enabled or not self.cfg.antiLostEnabled then
        self.al.recovering = false
        return
    end
    if not self.al.recovering then return end
    local pp = self.state.player and self.state.player.pos
    if not pp then return end

    self:delay(walkermod.RECOVERY_FREEZE_MS)
    if self:isBackOnTrack(pp) then
        self.al.recovering = false
        self.log.info('[CaveBot] recovered')
        return
    end
    if self.al.fallSpot and pp.z == self.al.fallSpot.z then
        self:giveUpToCaveBot()
        return
    end
    self.al.attempts = self.al.attempts + 1
    if self.al.attempts > walkermod.GIVE_UP_ATTEMPTS then
        self:giveUpToCaveBot()
        return
    end
    if self.al.mode == 'teleport' then
        self:_recoverTeleport(pp)
    else
        self:_recoverStairs(pp)
    end
end

function CB:_recoverTeleport(pp)
    local t = self.al.target
    if not t then
        t = self.walker:teleportTarget(pp, self.al.tpId, walkermod.WIDE_SEARCH_RADIUS)
        if not t then return self:giveUpToCaveBot() end
        self.al.target = t
    end
    if cheb(pp, t) > 1 then
        if not self:walkTo(t, 30, { ignoreNonPathable = true, precision = 0 }) then
            self.al.target = nil
        end
        return
    end
    self:walkTo(t, 5, { ignoreNonPathable = true, precision = 0 })
end

function CB:_recoverStairs(pp)
    local t = self.al.target
    if not t then
        t = self.walker:recoveryTarget(self.al.fallSpot, pp.z, self.ladderIds, self.ropeIds)
        if not t then return self:giveUpToCaveBot() end
        self.al.target = t
    end
    if cheb(pp, t) > 1 then
        if not self:walkTo(t, 30, { ignoreNonPathable = true, precision = 0 }) then
            self.al.target = nil
        end
        return
    end
    -- adjacent / on it: dispatch in the documented order (antilost.lua:544-585)
    local tile = self.state:tile(t)
    local top  = tile and self.world:getTopUseThing(tile)
    if not (top and top.kind == 'item') then
        self.al.target = nil
        return
    end
    if worldmod.idListHas(self.ladderIds, top.id) then
        self:_useThing(t, top)
    elseif worldmod.idListHas(self.ropeIds, top.id) then
        local tool = tonumber(self.cfg.antiLostRopeToolId) or cavebot.ROPE_FALLBACK
        if tool < 100 then tool = cavebot.ROPE_FALLBACK end
        self:_useWithThing(tool, t, top)
    elseif self:_itemFlag('isUsable', top.id, false) then
        self:_useThing(t, top)
    else
        -- a plain hole: standing ON it, step off first so a later pass can re-enter it
        if cheb(pp, t) == 0 then
            self:walkTo({ x = t.x + 1, y = t.y, z = t.z }, 3,
                        { ignoreNonPathable = true, precision = 0 })
        else
            self:walkTo(t, 5, { ignoreNonPathable = true, precision = 0 })
        end
    end
end

-- ===========================================================================
-- low-level senders used by several actions
-- ===========================================================================
--- bot/world.lua's `f` table only carries the 13 pathfinding accessors of gaps.md P0-1.
--- Everything else (isUsable / isNotMoveable / isStackable) lives on proto/items.lua itself
--- and may be absent in degraded mode, so it is read defensively with a stated default.
function CB:_itemFlag(name, id, dflt)
    local it = self.world.items
    local fn = it and it[name]
    if type(fn) ~= 'function' or id == nil then return dflt end
    local ok, r = pcall(fn, id)
    if not ok then return dflt end
    return r
end

function CB:_useThing(pos, thing)
    if not self.sender then return nil end
    return self.sender:use(pos, thing.id or 0, thing.stackPos or 0, 0)
end

function CB:_useWithThing(itemId, pos, thing)
    if not self.sender then return nil end
    return self.sender:useWith({ x = 0xFFFF, y = 0, z = 0 }, itemId, 0,
                               pos, thing.id or 0, thing.stackPos or 0)
end

--- The 0-based stack index of a thing inside its tile (the wire's stackpos).
function CB:_stackPosOf(tile, thing)
    for i = 1, #(tile.things or {}) do
        if tile.things[i] == thing then return i - 1 end
    end
    return 0
end

function CB:_creatureStackPos(tile, creatureId)
    for i = 1, #(tile.things or {}) do
        local t = tile.things[i]
        if t.kind == 'creature' and t.creatureId == creatureId then return i - 1 end
    end
    return 0
end

--- The tile's top-use thing plus its stackpos, or nil.
function CB:topUseAt(pos)
    local tile = self.state:tile(pos)
    if not tile then return nil end
    local t = self.world:getTopUseThing(tile)
    if not (t and t.kind == 'item') then return nil end
    return t, self:_stackPosOf(tile, t), tile
end

--- Every loaded tile on a floor.  g_map.getTiles(z) has no luaclient equivalent; state.map
--- only ever holds the aware window, so an O(n) sweep over it is the same set of tiles.
function CB:tilesOnFloor(z)
    local out = {}
    for _, tile in pairs(self.state.map or {}) do
        if tile.pos and tile.pos.z == z then out[#out + 1] = tile end
    end
    return out
end

-- ===========================================================================
-- NPC helpers (new_cavebot_lib.lua)
-- ===========================================================================
function CB:creatureByName(name)
    local want = tostring(name):lower()
    local pp = self.state.player and self.state.player.pos
    for _, c in pairs(self.state.creatures or {}) do
        if c.pos and pp and c.pos.z == pp.z and tostring(c.name or ''):lower() == want then
            return c
        end
    end
    return nil
end

--- CaveBot.ReachNPC(name): true when we are within 3 sqm, otherwise walk and answer false
--- (the caller returns "retry").
function CB:reachNPC(name)
    local npc = self:creatureByName(name)
    if not npc or not npc.pos then return false end
    local pp = self.state.player and self.state.player.pos
    if pp and cheb(pp, npc.pos) <= 3 then return true end
    self:walkTo(npc.pos, 20, { ignoreCreatures = true, precision = 3 })
    return false
end

--- Conversation("hi","trade",…): one phrase per talkDelay, on the NPC channel.
function CB:conversation(...)
    local phrases = { ... }
    if not self.sender then return false end
    local d = self:talkDelay()
    for i = 1, #phrases do
        local text = tostring(phrases[i])
        if i == 1 then
            self.sender:talk(11, 0, '', text)
        elseif self.bot and self.bot.schedule then
            self.bot:schedule(d * (i - 1), function()
                if self.sender then self.sender:talk(11, 0, '', text) end
            end)
        end
    end
    return true
end

function CB:npcTradeOpen()
    return self.state.npcTrade ~= nil and self.state.npcTrade.open ~= false
end

function CB:npcOffers()
    local t = self.state.npcTrade
    if type(t) ~= 'table' then return nil end
    return t.items or t.offers
end

function CB:getContainerByName(name)
    local want = tostring(name):lower()
    for _, c in pairs(self.state.containers or {}) do
        if tostring(c.name or ''):lower() == want then return c end
    end
    return nil
end

function CB:findContainerMatching(pattern)
    for _, c in pairs(self.state.containers or {}) do
        if tostring(c.name or ''):lower():find(pattern, 1, true) then return c end
    end
    return nil
end

--- The {0xFFFF, 0x40|containerId, slot} pseudo-position every container move uses.
function CB.slotPosition(container, slot)
    return { x = 0xFFFF, y = 0x40 + (container.id or 0), z = slot or 0 }
end

function CB:containerIsFull(c)
    if not c then return true end
    local cap = tonumber(c.capacity) or 0
    if cap <= 0 then return false end
    return #(c.items or {}) >= cap
end

-- ===========================================================================
-- the action table
-- ===========================================================================
function CB:registerAction(name, fn)
    self.actions[tostring(name):lower()] = fn      -- actions.lua:262 lower-cases too
    return self
end

function CB:_unimplemented(name, reason)
    self:registerAction(name, function(cb)
        cb:_warnOnce('unimpl:' .. name,
                     ("waypoint '%s' is not implemented in luaclient (%s); skipping")
                     :format(name, reason))
        return false
    end)
end

function CB:_registerActions()
    local A = function(n, f) self:registerAction(n, f) end

    -- ---- markers ---------------------------------------------------------
    A('label', function(cb, v)
        cb.lastLabel = v
        return true
    end)

    A('gotolabel', function(cb, v) return cb:gotoLabel(v) end)

    -- ---- delay (actions.lua:281-305) ------------------------------------
    -- On retries == 0 the delay is applied and "retry" returned; on the next entry the
    -- waypoint completes.  math.random with non-integer bounds is implementation defined in
    -- LuaJIT (it floors), so both bounds are floored explicitly -- stated rounding.
    A('delay', function(cb, v, retries)
        if retries == 0 then
            local d = split(v)
            local ms = tonumber(d[1])
            if not ms then
                cb.log.warn('[CaveBot] bad delay value: %s', tostring(v))
                return false
            end
            local final = ms
            local pct = tonumber(d[2])
            if pct then
                local diff = ms / 100 * pct
                final = math.random(floor(ms - diff), floor(ms + diff))
            end
            cb:delay(final)
            cb._lastDelay = final
            return 'retry'
        end
        return true
    end)

    -- ---- goto ------------------------------------------------------------
    A('goto', function(cb, v, retries) return cb:_actionGoto(v, retries) end)
    -- legacy routes may still carry `node`; vBot warns, but the parsing branches survive.
    A('node', function(cb, v, retries) return cb:_actionGoto(v, retries) end)

    -- ---- use / usewith ---------------------------------------------------
    A('use', function(cb, v)
        local pos = cavebot.parseGoto(v)
        if not pos then
            local id = tonumber(trim(v))
            if not id then
                cb.log.warn('[CaveBot] bad use value: %s', tostring(v))
                return false
            end
            -- a bare item id: inventory use, no delay at all (actions.lua:545-580)
            if cb.sender then cb.sender:use({ x = 0xFFFF, y = 0, z = 0 }, id, 0, 0) end
            return true
        end
        local pp = cb.state.player and cb.state.player.pos
        if not pp or pos.z ~= pp.z then return false end
        if cheb(pp, pos) > 7 then return false end
        local thing, stack = cb:topUseAt(pos)
        if not thing then return false end
        if cb.sender then cb.sender:use(pos, thing.id or 0, stack or 0, 0) end
        -- VERIFIER: the ping term is ALWAYS the raw CONFIG value here, never the measured one.
        cb:delay((tonumber(cb.cfg.useDelay) or 400) + (tonumber(cb.cfg.ping) or 100))
        return true
    end)

    A('usewith', function(cb, v)
        local itemId, pos = idXYZ(v)
        if not itemId then
            cb.log.warn('[CaveBot] bad usewith value: %s', tostring(v))
            return false
        end
        local pp = cb.state.player and cb.state.player.pos
        if not pp or pos.z ~= pp.z then return false end
        if cheb(pp, pos) > 7 then return false end
        local thing, stack = cb:topUseAt(pos)
        if not thing then return false end
        if cb.sender then
            cb.sender:useWith({ x = 0xFFFF, y = 0, z = 0 }, itemId, 0,
                              pos, thing.id or 0, stack or 0)
        end
        cb:delay((tonumber(cb.cfg.useDelay) or 400) + (tonumber(cb.cfg.ping) or 100))
        return true
    end)

    -- ---- talking ---------------------------------------------------------
    A('say', function(cb, v)
        if cb.sender then cb.sender:talk(1, 0, '', tostring(v)) end   -- MessageSay
        return true
    end)

    A('npcsay', function(cb, v)
        if cb.sender then cb.sender:talk(11, 0, '', tostring(v)) end  -- MessageNpcTo
        return true
    end)

    -- ---- follow (actions.lua:307-323) -----------------------------------
    A('follow', function(cb, v)
        local c = cb:creatureByName(trim(v))
        if not c then
            cb.log.info('[CaveBot] follow: creature %s not found', tostring(v))
            return false
        end
        local pp = cb.state.player and cb.state.player.pos
        if pp and c.pos and cheb(pp, c.pos) < 2 then
            if cb.sender then cb.sender:follow(0) end
            return true
        end
        if cb.sender then cb.sender:follow(c.id) end
        cb:setDelay(200)
        return 'retry'
    end)

    -- ---- function --------------------------------------------------------
    A('function', function(cb, v, retries, prev) return cb:_actionFunction(v, retries, prev) end)

    -- ---- route tools -----------------------------------------------------
    A('walkdelay', function(cb, v)
        local n = tonumber(trim(v))
        if not n or n < 0 or n > 10000 then
            cb.log.warn('[CaveBot] walkdelay out of range: %s', tostring(v))
            return false
        end
        cb.cfg.walkDelay = n
        cb.walker:configure(cb.cfg)
        return true
    end)

    A('turn', function(cb, v)
        local s = trim(v):lower()
        local d = DIR_NAMES[s] or tonumber(s)
        if type(d) ~= 'number' or d < 0 or d > 3 then
            cb.log.warn('[CaveBot] bad turn value: %s', tostring(v))
            return false
        end
        if cb.sender then cb.sender:turn(d) end
        return true
    end)

    A('exanihur', function(cb, v, retries) return cb:_actionExaniHur(v, retries) end)
    A('poscheck', function(cb, v) return cb:_actionPosCheck(v) end)
    A('opendoors', function(cb, v, retries) return cb:_actionOpenDoors(v, retries) end)
    A('cleartile', function(cb, v, retries) return cb:_actionClearTile(v, retries) end)

    A('lure', function(cb, v)
        local tb = cb.bot and cb.bot.modules and cb.bot.modules.targetbot
        local mode = trim(v):lower()
        local function set(on)
            if not tb then return end
            if on and tb.setOn then tb:setOn() elseif tb.setOff then tb:setOff() end
        end
        if mode == 'start' then set(false)          -- start luring = TargetBot OFF
        elseif mode == 'stop' then set(true)
        elseif mode == 'toggle' then
            local on = tb and tb.isOn and tb:isOn() or false
            set(not on)
        end
        return true                                  -- invalid values still return true
    end)

    -- ---- supplies / refill ----------------------------------------------
    A('supplycheck', function(cb, v) return cb:_actionSupplyCheck(v) end)
    A('buysupplies', function(cb, v, retries) return cb:_actionBuySupplies(v, retries) end)
    A('sellall',     function(cb, v, retries) return cb:_actionSellAll(v, retries) end)
    A('depositor',   function(cb, v, retries) return cb:_actionDepositor(v, retries, false) end)
    A('stowdeposit', function(cb, v, retries) return cb:_actionDepositor(v, retries, true) end)
    A('bank',        function(cb, v, retries) return cb:_actionBank(v, retries) end)
    A('travel',      function(cb, v, retries) return cb:_actionTravel(v, retries) end)

    -- ---- known but blocked on protocol builders luaclient does not have --
    self:_unimplemented('forge',      'g_game.forgeRequest has no proto/sender.lua builder')
    self:_unimplemented('imbuing',    'the imbuing opcodes have no proto/sender.lua builders')
    self:_unimplemented('tasker',     'needs the NPC task dialogue + Loot-of message counter')
    self:_unimplemented('rushlure',   'needs TargetBot lure arbitration (work item M3)')
    self:_unimplemented('withdraw',   'needs the depot-box withdraw primitives')
    self:_unimplemented('dpwithdraw', 'needs the depot-box withdraw primitives')
    self:_unimplemented('inwithdraw', 'needs the inbox withdraw primitives')
end

-- ---------------------------------------------------------------------------
-- goto: the full control flow (actions.lua:345-543, spec section 2.3)
-- ---------------------------------------------------------------------------
function CB:_actionGoto(value, retries)
    local dest, marker, precision = cavebot.parseGoto(value)
    if not dest then
        self.log.warn('[CaveBot] bad goto value: %s', tostring(value))
        return false
    end
    local pp = self.state.player and self.state.player.pos
    if not pp then return false end
    local maxDist = self:gotoMaxDistance()
    local cfg = self.cfg

    -- 1) the retry ceiling is checked FIRST
    local ceilN = (cfg.mapClick and not marker) and 5 or 100
    if retries >= ceilN then self:_noPathStrike(); return false end
    -- 2) another floor
    if dest.z ~= pp.z then self:_noPathStrike(); return false end
    -- 3) MANHATTAN range (actions.lua:387 -- a different metric from every other distance)
    if manhattan(dest, pp) > maxDist then self:_noPathStrike(); return false end

    local color  = self.world:mapColorAt(dest)
    local stairs = color >= cavebot.STAIRS_COLOR_MIN and color <= cavebot.STAIRS_COLOR_MAX

    -- 4) arrival (section 2.2) -- two different tests
    if stairs or marker then
        local p = precision or 0
        if abs(dest.x - pp.x) <= p and abs(dest.y - pp.y) <= p then
            self.noPath = 0
            self.stats.arrivals = self.stats.arrivals + 1
            return true
        end
        -- 5) FINAL APPROACH: one confirmed step at a time
        if cheb(dest, pp) <= 3 then
            -- REVIEW FIX: CB:tick calls self:resetWalking() before every action callback,
            -- which empties walker.expected/pending -- so walker:isWalking() was always
            -- false here and the guard was dead.  The outstanding-step ledger (stepTo /
            -- lastSendAt) survives that reset, so test THAT instead: it is what makes the
            -- block's promise ("overshoot becomes impossible") actually hold.
            if self:_stepInFlight() then self:delay(50); return 'retry' end
            local sp = self.path:getPath(pp, dest, 10,
                                         { ignoreNonPathable = true, precision = 0 })
            if sp and sp[1] then
                self.walker:step(sp[1])
                self:delay(self.walker:stepDuration(sp[1]) + self:pingMs() + 50)
                return 'retry'
            end
        end
    elseif abs(dest.x - pp.x) == 0 and abs(dest.y - pp.y) <= (precision or 1) then
        -- the asymmetric plain-goto test (almost certainly a vBot bug; reproduced)
        self.noPath = 0
        self.stats.arrivals = self.stats.arrivals + 1
        return true
    end

    -- 6) a creature-ignoring path must exist at all
    local path = self.path:getPath(pp, dest, maxDist,
                                   { ignoreNonPathable = true, precision = 1,
                                     ignoreCreatures = true, allowUnseen = true,
                                     allowOnlyVisibleTiles = false })
    if not path then
        if self:breakFurniture(dest) then self:delay(1000); return 'retry' end
        self:_noPathStrike(); return false
    end

    -- 7) creatures in the way
    local path2 = self.path:getPath(pp, dest, maxDist,
                                    { ignoreNonPathable = true, precision = 1 })
    if not path2 then
        local found = self:_attackBlockingMonster(pp, path)
        if not found then
            if marker or stairs then self:delay(200); return 'retry' end
            self.stats.blocked = self.stats.blocked + 1
            return false
        end
        -- actions.lua:472 `retries = 0 -- reset retries, we are trying to unclog the
        -- cavebot`.  `retries` is the callback's own parameter, so steps 10/11/13 below
        -- MUST see 0 or a plain waypoint is skipped while we fight our way through.
        retries = 0
    end

    -- 8) respect fields first
    if not cfg.ignoreFields and self:walkTo(dest, 40) then return 'retry' end
    -- 9) ignore fields
    if self:walkTo(dest, maxDist, { ignoreNonPathable = true, allowUnseen = true,
                                    allowOnlyVisibleTiles = false }) then return 'retry' end
    -- 10) widening precision
    if retries >= 3 then
        local p = (stairs or marker) and 0 or (retries - 1)
        if self:walkTo(dest, 50, { ignoreNonPathable = true, precision = p,
                                   allowUnseen = true, allowOnlyVisibleTiles = false }) then
            return 'retry'
        end
    end
    -- 11) plain waypoints give up after 5
    if (not cfg.mapClick) and retries >= 5 and not marker and not stairs then
        self:_noPathStrike(); return false
    end
    -- 12) skipBlocked
    if cfg.skipBlocked and not marker and not stairs then
        self:_noPathStrike(); return false
    end
    -- 13) last resort
    if not self:walkTo(dest, maxDist, { ignoreNonPathable = true, precision = 1,
                                        ignoreCreatures = true, allowUnseen = true,
                                        allowOnlyVisibleTiles = false }) then
        self:delay(min(100 + retries * 50, 500))
    end
    return 'retry'
end

--- goto step 7 (actions.lua:452-479).  VERIFIER: only the FIRST creature on each tile is
--- examined (`tile:getCreatures()[1]`), so a player stacked first hides a monster behind it.
--- The player-position aliasing bug is NOT reproduced (luaclient's st.player.pos is a LIVE
--- table -- copying the alias would corrupt it); see the report's contract deviations.
function CB:_attackBlockingMonster(pp, path)
    local np = { x = pp.x, y = pp.y, z = pp.z }
    for i = 1, #path do
        local d = DELTA[path[i]]
        if not d then break end
        np.x, np.y = np.x + d[1], np.y + d[2]
        local tile = self.state:tile(np)
        local c = tile and self:_firstCreatureOn(tile)
        if c and c.isMonster and (c.healthPercent or 0) > 0 and (c.type or 0) < 3 then
            local reach = self.path:getPath(pp, c.pos, 7,
                                            { ignoreNonPathable = true, precision = 1 })
            if reach then
                if (self.bot and self.bot._attacking) ~= c.id then
                    if cheb(pp, c.pos) > 3 then
                        self:walkTo(c.pos, 7, { ignoreNonPathable = true, precision = 1 })
                    elseif self.sender then
                        self.sender:attack(c.id)
                        if self.bot then self.bot._attacking = c.id end
                    end
                end
                if self.sender then self.sender:setFightMode(nil, 1, nil, nil) end
                self:delay(100)
                return true
            end
        end
    end
    return false
end

--- isInPz() -- PlayerStates.Pz (src/client/const.h:295), the same bit bot/targetbot.lua
--- and bot/healbot.lua read.  REVIEW FIX: CaveBot had no PZ probe at all.
function CB:isInPz()
    local pl = self.state.player
    local s = pl and pl.states
    if type(s) ~= 'number' then return false end
    return floor(s / cavebot.PZ_STATE) % 2 == 1
end

--- Is one of OUR walk packets still unconfirmed?  vBot's guard here is
--- `player:isWalking() or player:isPreWalking()` (actions.lua:414), which reads the
--- CLIENT's own walk state.  CB:tick calls resetWalking() before every action callback,
--- which empties walker.expected/pending AND the step ledger, so `walker:isWalking()` is
--- unconditionally false by the time the goto callback runs -- the guard was dead code.
--- `lastSendAt` is the one thing the reset does not touch, so it is what answers this.
--- REVIEW FIX.
function CB:_stepInFlight()
    local wk = self.walker
    if not wk or not wk.lastSendAt then return false end
    local ok, timeout = pcall(wk.confirmTimeoutMs, wk, wk.lastStepDir or 0)
    if not ok or type(timeout) ~= 'number' then timeout = 1000 end
    return (self.now() - wk.lastSendAt) < timeout
end

--- getNearTiles(pos) -- vlib.lua:900-915, the 8 neighbours (never the centre).
function CB:_nearTiles(pos)
    local out = {}
    for dir = 0, 7 do
        local dd = DELTA[dir]
        local q = { x = pos.x + dd[1], y = pos.y + dd[2], z = pos.z }
        local t = self.state:tile(q)
        if t then out[#out + 1] = t end
    end
    return out
end

--- REVIEW FIX: the unconditional "There is not enough room." anti-stuck hook
--- (actions.lua:38-66).  Independent of the waypoint loop: on that text message, with
--- CaveBot on, find an adjacent tile with no creature, walkable and more than 9 items;
--- outside PZ disintegrate its top thing, inside PZ move that thing to another walkable
--- neighbour, throttled to one move per 200 ms.
function CB:onNotEnoughRoom(d)
    local text = type(d) == 'table' and d.text or d
    if tostring(text or '') ~= 'There is not enough room.' then return false end
    if not self:isOn() then return false end
    local pp = self.state.player and self.state.player.pos
    if not pp then return false end
    local inPz = self:isInPz()
    for _, tile in ipairs(self:_nearTiles(pp)) do
        local things = tile.things or {}
        local nItems = 0
        local hasCreature = false
        for i = 1, #things do
            if things[i].kind == 'creature' then hasCreature = true
            else nItems = nItems + 1 end
        end
        if not hasCreature and nItems > 9 and self.world:isWalkable(tile, true) then
            local top = things[#things]
            if top then
                if not inPz then
                    self:_useWithThing(3197, tile.pos, top)      -- disintegrate
                    return true
                end
                if self.now() < (self.lastRoomMove or 0) + 200 then return false end
                for _, nb in ipairs(self:_nearTiles(tile.pos)) do
                    if not samePos(nb.pos, pp) and self.world:isWalkable(nb, true) then
                        self.lastRoomMove = self.now()
                        if self.sender then
                            self.sender:move(tile.pos, top.id or 0,
                                             self:_stackPosOf(tile, top), nb.pos,
                                             top.count or 1)
                        end
                        return true
                    end
                end
            end
        end
    end
    return false
end

function CB:_firstCreatureOn(tile)
    for i = 1, #(tile.things or {}) do
        local t = tile.things[i]
        if t.kind == 'creature' then
            local c = self.state:getCreature(t.creatureId)
            if c then return c end
            return nil
        end
    end
    return nil
end

--- breakFurniture (actions.lua:69-101).  Never in PZ.  OMISSION from the VERIFIER: the
--- candidate distance starts at 100 and the comparison is strict `<`.
function CB:breakFurniture(destPos)
    -- REVIEW FIX: actions.lua:71 `if isInPz() then return false end`.  The doc-comment
    -- above already promised it; the guard itself was missing.
    if self:isInPz() then return false end
    local pp = self.state.player and self.state.player.pos
    if not pp then return false end
    local bestDist, best, bestPos = 100, nil, nil
    for _, tile in ipairs(self:tilesOnFloor(pp.z)) do
        -- REVIEW FIX: actions.lua:73-83 reads the TILE's top thing and the TILE's own
        -- walkability, not a "top USE thing" and the item's own NOT_WALKABLE flag.
        local things = tile.things or {}
        local top = things[#things]
        if top and top.kind == 'item' then
            local isWall   = (top.id == 2130)
            local walkable = self.world:isWalkable(tile, true)
            local movable  = (not walkable)
                             and not self:_itemFlag('isNotMoveable', top.id, false)
            if (isWall or movable) and top.id ~= 2986 then
                local d = cheb(destPos, tile.pos)
                if d < bestDist then
                    local reach = self.path:getPath(pp, tile.pos, 7,
                                                    { ignoreNonPathable = true, precision = 1 })
                    if reach then bestDist, best, bestPos = d, top, tile.pos end
                end
            end
        end
    end
    if not best then return false end
    self:_useWithThing(3197, bestPos, best)          -- destroy field / disintegrate rune
    return true
end

-- ---------------------------------------------------------------------------
-- function waypoint (actions.lua:325-343)
-- ---------------------------------------------------------------------------
--- vBot scripts call these with a DOT (`TargetBot.setOn()`, `CaveBot.delay(500)`) because
--- upstream CaveBot/TargetBot are plain tables of functions.  Ours are OO instances, so a
--- dot call would pass the first argument as `self`.  This proxy binds the receiver and
--- still tolerates a colon call, so both spellings work inside a `function` waypoint.
--- (The user's real routes use `TargetBot.setOn()` / `TargetBot.setOff()` -- 8 sites.)
local function dotProxy(obj)
    if type(obj) ~= 'table' then return nil end
    return setmetatable({}, {
        __index = function(_, k)
            local v = obj[k]
            if type(v) ~= 'function' then return v end
            return function(...)
                if select('#', ...) > 0 and select(1, ...) == obj then return v(...) end
                return v(obj, ...)
            end
        end,
        __newindex = function(_, k, v) obj[k] = v end,
    })
end
cavebot.dotProxy = dotProxy

function CB:_actionFunction(src, retries, prev)
    local ctx = self.bot and self.bot.api
    local cb = self
    local env = setmetatable({
        retries   = retries,
        prev      = prev,
        delay     = function(ms) return cb:delay(ms) end,
        gotoLabel = function(n) return cb:gotoLabel(n) end,
        macro     = function() cb.log.warn('[CaveBot] macro() is not available inside a '
                                           .. 'function waypoint') end,
        CaveBot   = dotProxy(cb),
        TargetBot = dotProxy(cb.bot and cb.bot.modules and cb.bot.modules.targetbot) or {
            setOn = function() end, setOff = function() end, isOn = function() return false end,
        },
    }, { __index = function(_, k)
        if ctx and ctx[k] ~= nil then return ctx[k] end
        return _G[k]
    end })

    local chunk, err = loadstring(tostring(src), 'cavebot function waypoint')
    if not chunk then
        self.log.warn('[CaveBot] function waypoint compile error: %s', tostring(err))
        return false
    end
    setfenv(chunk, env)
    local ok, r = pcall(chunk)
    if not ok then
        self.log.warn('[CaveBot] function waypoint error: %s', tostring(r))
        return false
    end
    return r                                     -- the return value IS the action's result
end

-- ---------------------------------------------------------------------------
-- exanihur (route_tools.lua:126-175)
-- ---------------------------------------------------------------------------
function CB:_actionExaniHur(value, retries)
    local d = split(value)
    local mode = tostring(d[1] or ''):lower()
    if mode ~= 'up' and mode ~= 'down' then
        self.log.warn('[CaveBot] bad exanihur mode: %s', tostring(value))
        return false
    end
    local pp = self.state.player and self.state.player.pos
    if not pp then return false end
    if retries == 0 then self.exaniStartZ = pp.z end
    local startZ = self.exaniStartZ or pp.z
    local dz = pp.z - startZ
    if (mode == 'up' and dz < 0) or (mode == 'down' and dz > 0) then return true end
    if retries >= 20 then
        local fallback = d[3]
        if fallback and #fallback > 0 then return self:gotoLabel(fallback) end
        return false
    end
    local face = d[2] and (DIR_NAMES[tostring(d[2]):lower()] or tonumber(d[2]))
    if type(face) == 'number' and self.state.player.direction ~= face and self.sender then
        self.sender:turn(face)
    end
    if self.sender then self.sender:talk(1, 0, '', 'exani hur ' .. mode) end
    self:delay(1000)
    return 'retry'
end

-- ---------------------------------------------------------------------------
-- poscheck (pos_check.lua:6-63)
-- ---------------------------------------------------------------------------
function CB:_actionPosCheck(value)
    local d = split(value)
    local label = d[1]
    local dist  = tonumber(d[2])
    local x, y, z = tonumber(d[3]), tonumber(d[4]), tonumber(d[5])
    if not (label and dist and x and y and z) then
        self.log.warn('[CaveBot] bad poscheck value: %s', tostring(value))
        return false
    end
    local maxRetries = 10
    local m = d[6]
    if m and #m > 0 then
        local ml = m:lower()
        if ml == 'inf' or ml == 'infinity' then maxRetries = math.huge
        else
            local n = tonumber(m)
            if not n or n <= 0 then
                self.log.warn('[CaveBot] bad poscheck maxRetries: %s', tostring(m))
                return false
            end
            maxRetries = n
        end
    end

    -- the counter resets whenever the VALUE STRING changes
    if self.posCheck.value ~= value then
        self.posCheck.value, self.posCheck.count = value, 0
    end
    -- the ceiling is checked BEFORE the position test
    if self.posCheck.count >= maxRetries then
        self.posCheck.count = 0
        self.log.info('[CaveBot] poscheck gave up after %s tries, proceeding', tostring(maxRetries))
        return false
    end
    local pp = self.state.player and self.state.player.pos
    if pp and pp.z == z and cheb(pp, { x = x, y = y, z = z }) <= dist then
        self.posCheck.count = 0                 -- pos_check.lua:48, consecutive failures
        return true
    end

    self.posCheck.count = self.posCheck.count + 1
    if tostring(label):lower() == 'last' then
        self:gotoFirstPreviousReachableWaypoint()
    else
        self:gotoLabel(label)
    end
    return false
end

-- ---------------------------------------------------------------------------
-- opendoors (doors.lua:4-49)
-- ---------------------------------------------------------------------------
function CB:_actionOpenDoors(value, retries)
    if retries >= 5 then return false end
    local d = split(value)
    local x, y, z = tonumber(d[1]), tonumber(d[2]), tonumber(d[3])
    local keyId = tonumber(d[4])
    if not (x and y and z) then
        self.log.warn('[CaveBot] bad opendoors value: %s', tostring(value))
        return false
    end
    local pos = { x = x, y = y, z = z }
    local tile = self.state:tile(pos)
    if not tile then return false end
    -- VERIFIER: Tile:isWalkable() is called with NO argument, so any non-passable creature
    -- standing in the doorway makes the tile "not walkable".
    if self.world:isWalkable(tile, false) then return true end
    local thing, stack = self:topUseAt(pos)
    if thing and self.sender then
        if keyId then
            self.sender:useWith({ x = 0xFFFF, y = 0, z = 0 }, keyId, 0,
                                pos, thing.id or 0, stack or 0)
        else
            self.sender:use(pos, thing.id or 0, stack or 0, 0)
        end
    end
    self:setDelay(200)
    return 'retry'
end

-- ---------------------------------------------------------------------------
-- cleartile (clear_tile.lua:4-118)
-- ---------------------------------------------------------------------------
function CB:_actionClearTile(value, retries)
    if retries >= 20 then return false end
    local d = split(value)
    local x, y, z = tonumber(d[1]), tonumber(d[2]), tonumber(d[3])
    if not (x and y and z) then
        self.log.warn('[CaveBot] bad cleartile value: %s', tostring(value))
        return false
    end
    local doorsFlag, standFlag = false, false
    for i = 4, #d do
        local t = tostring(d[i]):lower()
        if t == 'doors' then doorsFlag = true elseif t == 'stand' then standFlag = true end
    end
    local tPos = { x = x, y = y, z = z }
    local pp = self.state.player and self.state.player.pos
    if not pp then return false end
    if cheb(pp, tPos) == 0 and pp.z == z then return true end
    local tile = self.state:tile(tPos)
    if not tile then return false end

    local thing, stack = self:topUseAt(tPos)
    local creature = self:_firstCreatureOn(tile)
    local immovable = thing and self:_itemFlag('isNotMoveable', thing.id, false)
    if self.world:isWalkable(tile, true) and (thing == nil or immovable)
       and not creature and not doorsFlag then
        if standFlag and not (pp.z == z and cheb(pp, tPos) == 0) then
            self:goTo(tPos, 0)
            return 'retry'
        end
        return true
    end

    if pp.z ~= z or cheb(pp, tPos) > 3 then
        self:goTo(tPos, 3)
        return 'retry'
    end
    if retries > 0 then self:setDelay(1100) end

    if creature and creature.isMonster then
        if self.sender then self.sender:attack(creature.id) end
        return 'retry'
    end
    if thing and not immovable then
        if self.sender then
            self.sender:move(tPos, thing.id or 0, stack or 0, pp, thing.count or 1)
        end
        return 'retry'
    end
    if creature and creature.isPlayer then
        -- REVIEW FIX: clear_tile.lua:88 keeps neighbours `d == 1 and tPos ~= pPos`, i.e.
        -- it refuses to push the player onto the tile the BOT is standing on.  The old
        -- `not samePos(q, tPos)` was dead code (DELTA never yields (0,0)) and let the bot
        -- pick its own position, which the server rejects until retries >= 20.
        local cands = {}
        for dir = 0, 7 do
            local dd = DELTA[dir]
            local q = { x = tPos.x + dd[1], y = tPos.y + dd[2], z = z }
            if not samePos(q, pp) then
                local qt = self.state:tile(q)
                if qt and self.world:isWalkable(qt, true) then cands[#cands + 1] = q end
            end
        end
        if #cands == 0 then return false end
        local q = cands[math.random(1, #cands)]      -- upstream picks at random too
        if self.sender then
            self.sender:move(tPos, 0x63, self:_creatureStackPos(tile, creature.id), q, 1)
        end
        return 'retry'
    end
    if doorsFlag and thing then
        if self.sender then self.sender:use(tPos, thing.id or 0, stack or 0, 0) end
        return 'retry'
    end
    return 'retry'
end

-- ---------------------------------------------------------------------------
-- supplycheck (supply_check.lua:60-157)
-- ---------------------------------------------------------------------------
function CB:_actionSupplyCheck(value)
    local d = split(value)
    local label = d[1]
    local sup = self.supplies
    if not label or #label == 0 then
        self.log.warn('[CaveBot] bad supplycheck value: %s', tostring(value))
        return false
    end

    -- position guard (only when x,y,z were given)
    -- supply_check.lua:68 `if #data == 4 then` -- a 5-field value does NOT activate it.
    if #d == 4 then
        local pos = { x = tonumber(d[2]), y = tonumber(d[3]), z = tonumber(d[4]) }
        if pos.x and pos.y and pos.z then
            if sup.missedChecks >= 4 then
                sup.missedChecks, sup.supplyRetries = 0, 0
                self.log.info('[CaveBot] supplycheck: missed 5 times, proceeding to refill')
                return true
            end
            local pp = self.state.player and self.state.player.pos
            -- supply_check.lua:77 is getDistanceBetween(), i.e. Chebyshev over x/y ONLY:
            -- z is deliberately NOT part of the test.
            if not pp or cheb(pp, pos) > 10 then
                sup.missedChecks = sup.missedChecks + 1
                -- returns the RESULT of gotoLabel: true if the label exists, false otherwise
                return self:gotoLabel(label)
            end
        end
    end

    local reason = sup:checkRound()
    if reason then
        sup:refillStarted()
        self.lastRefillReason = reason
        self.log.info('[CaveBot] supplycheck -> refill (%s)', reason)
        return false                       -- fall through into the refill branch
    end
    sup:roundCompleted()
    return self:gotoLabel(label)           -- keep hunting
end

-- ---------------------------------------------------------------------------
-- buysupplies (buy_supplies.lua:14-99)
-- ---------------------------------------------------------------------------
function CB:_actionBuySupplies(value, retries)
    local d = split(value)
    local npcName = d[1]
    local waitMs  = tonumber(d[2])
    if retries == 0 then self.noProgress = 0 end
    local npc = self:creatureByName(npcName)
    if not npc then
        self.log.info('[CaveBot] buysupplies: npc %s not found', tostring(npcName))
        self.noProgress = 0                     -- buy_supplies.lua:43
        return false
    end
    if waitMs then self:setDelay(waitMs) end
    if self.noProgress > suppliesmod.STUCK_ROUNDS or retries > suppliesmod.MAX_ROUNDS then
        self.noProgress = 0
        self.log.warn('[CaveBot] buysupplies gave up (no progress)')
        return false
    end
    if not self:reachNPC(npcName) then
        self.noProgress = self.noProgress + 1
        return 'retry'
    end
    if not self:npcTradeOpen() then
        self:conversation('hi', 'trade')
        self:delay(self:talkDelay() * 2)
        self.noProgress = self.noProgress + 1
        return 'retry'
    end

    local offers = self:npcOffers()
    -- buy_supplies.lua:70-76 builds possibleItems from NPC.getBuyItems(); an unknown or
    -- empty offer list means `table.find` never hits, so NOTHING is bought and the action
    -- reports "bought everything, proceeding".  Never issue blind buyItem packets.
    local function sells(id)
        if offers == nil then return false end
        for _, o in ipairs(offers) do
            if (o.id or o.itemId) == id then return true end
        end
        return false
    end

    for _, entry in ipairs(self.supplies:buyList()) do
        if sells(entry.id) then
            if self.sender then
                self.sender:buyItem(entry.id, 0, entry.amount, false, false)
            end
            self.noProgress = 0
            return 'retry'
        end
    end
    self.noProgress = 0
    return true
end

-- ---------------------------------------------------------------------------
-- sellall (sell_all.lua:5-81)
-- ---------------------------------------------------------------------------
--- `modules.game_npctrade.sellAll` is a client-module routine, not a packet.  It is
--- replaced here by the explicit per-item loop the cavebot.md open questions call for: one
--- 0x7B per distinct id found in an open, carried container, skipping the exception list.
--- The "free capacity stopped changing" termination test is kept verbatim.
function CB:_actionSellAll(value, retries)
    local d = split(value)
    local npcName = d[1]
    local withDelay = false
    local exceptions = {}
    for i = 2, #d do
        local t = tostring(d[i]):lower()
        if t == 'yes' then withDelay = true
        else
            local n = tonumber(t)
            if n then exceptions[n] = true end
        end
    end
    local sell = self.bot and self.bot.storage and self.bot.storage.cavebotSell
    if type(sell) == 'table' then
        for _, id in ipairs(sell) do exceptions[id] = true end
    end

    local npc = self:creatureByName(npcName)
    if not npc then return false end
    -- REVIEW FIX: upstream's `retries > 10` guarded a handful of round trips because
    -- modules.game_npctrade.sellAll() emptied the backpacks in ONE call.  We sell one id
    -- per invocation, so charging every sale to the same budget capped a whole visit at
    -- ~11 items.  Count rounds that made NO progress instead (as buy_supplies.lua does).
    if retries == 0 then self.sellAllNoProgress = 0 end
    if (self.sellAllNoProgress or 0) > 10 or retries > suppliesmod.MAX_ROUNDS then
        self.sellAllNoProgress = 0
        return false
    end

    local cap = self.supplies:freeCap()
    if cap == self.sellAllCap then
        self.sellAllCap = 0
        self.sellAllNoProgress = 0
        return true
    end
    self:setDelay(800)                               -- sell_all.lua:38, a PLAIN delay()
    if not self:reachNPC(npcName) then
        self.sellAllNoProgress = (self.sellAllNoProgress or 0) + 1
        return 'retry'
    end
    if not self:npcTradeOpen() then
        self:conversation('hi', 'trade')
        self:setDelay(self:talkDelay() * 2)          -- sell_all.lua:45, a PLAIN delay()
        self.sellAllNoProgress = (self.sellAllNoProgress or 0) + 1
        return 'retry'
    end
    self.sellAllCap = cap

    for _, c in pairs(self.state.containers or {}) do
        local n = tostring(c.name or ''):lower()
        if not (n:find('depot') or n:find('locker') or n:find('inbox')) then
            for _, it in ipairs(c.items or {}) do
                if it.id and not exceptions[it.id] then
                    if self.sender then
                        self.sender:sellItem(it.id, 0, it.count or 1, true)
                    end
                    if withDelay then self:setDelay(self:talkDelay()) end
                    self.sellAllNoProgress = 0
                    return 'retry'
                end
            end
        end
    end
    self.sellAllNoProgress = (self.sellAllNoProgress or 0) + 1
    return 'retry'
end

-- ---------------------------------------------------------------------------
-- depositor / stowdeposit (depositor.lua:34-130, 168-285)
-- ---------------------------------------------------------------------------
--- The loot id list comes from the TARGETBOT config, never from the cavebot one
--- (new_cavebot_lib.lua:25-33).
function CB:lootList()
    if self._lootList then return self._lootList end
    local out, containers = {}, {}
    local prof = self.bot and self.bot.config
    local sel  = self.bot and self.bot.storage and self.bot.storage._configs
                 and self.bot.storage._configs.targetbot_configs
    local name = type(sel) == 'table' and sel.selected or nil
    if prof and prof.loadTargetbot and name then
        local t = prof:loadTargetbot(name)
        local looting = type(t) == 'table' and t.looting or nil
        if type(looting) == 'table' then
            for _, it in ipairs(looting.items or {}) do
                local id = tonumber(it.id or it)
                if id then out[id] = true end
            end
            for _, c in ipairs(looting.containers or {}) do
                local id = tonumber(c.id or c)
                if id then containers[id] = true end
            end
        end
    end
    self._lootList, self._lootContainers = out, containers
    return out
end

function CB:resetLootCache()
    self._lootList, self._lootContainers = nil, nil
    -- resetCache() also consumes the back* flags (depositor.lua:8-29)
    local cb = self.supplies:caveBotFlags()
    if cb.backStop then
        cb.backStop = false
        self:disable()
    elseif cb.backTrainers then
        cb.backTrainers = false
        self:gotoLabel('toTrainers')
    elseif cb.backOffline then
        cb.backOffline = false
        self:gotoLabel('toOfflineTraining')
    end
end

function CB:_actionDepositor(value, retries, stow)
    if stow then
        self:_warnOnce('stow', 'stowdeposit: g_game.stashStowItem has no proto/sender.lua '
                       .. 'builder, falling back to the plain depot pass')
    end
    local loot = self:lootList()
    if next(loot) == nil then
        self.log.info('[CaveBot] depositor: the loot list is empty, nothing to deposit')
        self:resetLootCache()
        return true
    end
    self:setDelay(70)                                    -- depositor.lua:49 (OVERWRITE)

    if retries == 0 and not self:_hasLootItems(loot) then
        self:resetLootCache()
        return true
    end
    if retries > 400 then
        self.log.warn('[CaveBot] depositor gave up')
        self:resetLootCache()
        return true
    end
    if not self:reachAndOpenDepot() then return 'retry' end
    self:pingDelay(2)

    local destination = self:getContainerByName('Depot chest')
    if not destination then return 'retry' end

    for _, c in pairs(self.state.containers or {}) do
        local n = tostring(c.name or ''):lower()
        if not (n:find('depot') or n:find('your inbox')) then
            for idx, it in ipairs(c.items or {}) do
                if it.id and loot[it.id] then
                    local index = self:_stashingIndex(it.id)
                    if index == nil then
                        index = self:_itemFlag('isStackable', it.id, false) and 1 or 0
                    end
                    local slot = (c.firstIndex or 0) + idx - 1
                    if self.sender then
                        self.sender:move({ x = 0xFFFF, y = 0x40 + c.id, z = slot },
                                         it.id, slot,
                                         CB.slotPosition(destination, index),
                                         it.count or 1)
                    end
                    return 'retry'
                end
            end
        end
    end
    self:resetLootCache()
    return true
end

function CB:_hasLootItems(loot)
    for _, c in pairs(self.state.containers or {}) do
        local n = tostring(c.name or ''):lower()
        if not (n:find('depot') or n:find('your inbox')) then
            for _, it in ipairs(c.items or {}) do
                if it.id and loot[it.id] then return true end
            end
        end
    end
    return false
end

--- getStashingIndex(id) (depositer_config.lua:117-123): storage.specialDeposit.items is
--- `[{id=, index=<1-based depot box>}]` and the function returns index - 1.
function CB:_stashingIndex(id)
    local s = self.bot and self.bot.storage and self.bot.storage.specialDeposit
    if type(s) ~= 'table' then return nil end
    for _, e in ipairs(s.items or {}) do
        if tonumber(e.id) == id then return (tonumber(e.index) or 1) - 1 end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- depot reach / open primitives (new_cavebot_lib.lua:307-496)
-- ---------------------------------------------------------------------------
function CB:reachDepot()
    local pp = self.state.player and self.state.player.pos
    if not pp then return false end
    if self.walker:isWalking() then self:delay(50); return false end

    -- already adjacent to a locker?
    for dx = -1, 1 do
        for dy = -1, 1 do
            local q = { x = pp.x + dx, y = pp.y + dy, z = pp.z }
            local tile = self.state:tile(q)
            if tile then
                for _, t in ipairs(tile.things or {}) do
                    if t.kind == 'item' and cavebot.LOCKER_OFFSETS[t.id] then return true end
                end
            end
        end
    end

    local best, bestDist
    for _, tile in ipairs(self:tilesOnFloor(pp.z)) do
        for _, t in ipairs(tile.things or {}) do
            local off = t.kind == 'item' and cavebot.LOCKER_OFFSETS[t.id]
            if off then
                local access = { x = tile.pos.x + off[1], y = tile.pos.y + off[2], z = pp.z }
                local at = self.state:tile(access)
                if at and not self.world:hasBlockingCreature(at) then
                    local dirs = self.path:getPath(pp, access, 20,
                                                   { ignoreNonPathable = false, precision = 1,
                                                     ignoreCreatures = true })
                    if dirs then
                        local d = cheb(pp, access)
                        if bestDist == nil or d < bestDist then best, bestDist = access, d end
                    end
                end
            end
        end
    end
    if not best then return false end
    self:preciseGoTo(best, 1)
    return false
end

function CB:openDepotChest()
    if self:getContainerByName('Depot chest') then return true end
    local locker = self:getContainerByName('Locker')
    if not locker then
        -- open the locker item on an adjacent tile
        local pp = self.state.player and self.state.player.pos
        if not pp then return false end
        for dx = -1, 1 do
            for dy = -1, 1 do
                local q = { x = pp.x + dx, y = pp.y + dy, z = pp.z }
                local tile = self.state:tile(q)
                if tile then
                    for i, t in ipairs(tile.things or {}) do
                        if t.kind == 'item' and cavebot.LOCKER_OFFSETS[t.id] then
                            if self.sender then
                                self.sender:openContainer(q, t.id, i - 1, 0)
                            end
                            self:delay(200)
                            return false
                        end
                    end
                end
            end
        end
        return false
    end
    for idx, it in ipairs(locker.items or {}) do
        if it.id == cavebot.DEPOT_CHEST_ID then
            local slot = (locker.firstIndex or 0) + idx - 1
            if self.sender then
                self.sender:openContainer({ x = 0xFFFF, y = 0x40 + locker.id, z = slot },
                                          it.id, slot, 0)
            end
            self:delay(200)
            return false
        end
    end
    return false
end

function CB:reachAndOpenDepot()
    return self:reachDepot() and self:openDepotChest()
end

-- ---------------------------------------------------------------------------
-- bank (bank.lua:6-78) and travel (travel.lua:4-33)
-- ---------------------------------------------------------------------------
function CB:_actionBank(value, retries)
    local d = split(value)
    local kind = tostring(d[1] or ''):lower()
    if #d < 2 or #d > 4 then return false end
    if kind ~= 'withdraw' and kind ~= 'deposit' and kind ~= 'transfer' then return false end
    -- bank.lua:32-38: a withdraw whose amount is not a number is rejected before anything
    -- is said to the NPC.
    if kind == 'withdraw' and not tonumber(d[3]) then
        self.log.warn('[CaveBot] bank: incorrect amount value, should be a number, is: %s',
                      tostring(d[3]))
        return false
    end
    if retries > 5 then return false end
    local npcName = d[2]
    if not self:creatureByName(npcName) then return false end
    if not self:reachNPC(npcName) then return 'retry' end
    local td = self:talkDelay()
    if kind == 'deposit' then
        self:conversation('hi', 'deposit all', 'yes')
        self:delay(td * 3)
        return true
    elseif kind == 'withdraw' then
        self:conversation('hi', 'withdraw', d[3], 'yes')
        self:delay(td * 4)
        return true
    end
    -- transfer: the balance has to be scraped from the NPC's reply first
    self:conversation('hi', 'balance')
    local cb = self
    local targetName, balanceLeft = d[3], tonumber(d[4]) or 0
    if self.bot and self.bot.schedule then
        self.bot:schedule(5000, function()
            local bal = cb.bankBalance
            if type(bal) ~= 'number' then
                cb.log.warn('[CaveBot] bank transfer: no balance reply, aborting')
                return
            end
            local amount = bal - balanceLeft
            if amount <= 0 then
                cb.log.warn('[CaveBot] bank transfer: nothing to transfer')
                return
            end
            cb:conversation('hi', 'transfer', tostring(amount), targetName, 'yes')
        end)
    end
    self:delay(td * 11)
    return true
end

function CB:_actionTravel(value, retries)
    local d = split(value)
    -- travel.lua:6-9 -- without a destination CB:conversation would tostring(nil) and the
    -- character would say the literal "nil" to the NPC on the NPC channel.
    if #d < 2 or not d[2] or #tostring(d[2]) == 0 then
        self.log.warn('[CaveBot] incorrect travel value: %s', tostring(value))
        return false
    end
    if retries > 5 then return false end
    local npcName, dest = d[1], d[2]
    if not self:creatureByName(npcName) then return false end
    if not self:reachNPC(npcName) then return 'retry' end
    self:conversation('hi', dest, 'yes')
    self:setDelay(self:talkDelay() * 3)              -- travel.lua:29, a PLAIN delay()
    return true
end

--- Hook the client's `talk` event so `bank transfer` can read the balance
--- (bank.lua:87-91: mode 51 containing "Your account balance is").
function CB:onTalk(data)
    if not data then return end
    local text = tostring(data.text or '')
    if text:find('Your account balance is', 1, true) then
        local n = text:gsub('%.', ''):match('(%d+)')
        if n then self.bankBalance = tonumber(n) end
    end
end

-- ===========================================================================
-- status
-- ===========================================================================
function CB:status()
    local w = self.waypoints[self.index]
    return {
        on             = self:isOn(),
        config         = self.routeName,
        waypointIndex  = self.index,
        waypointCount  = #self.waypoints,
        currentAction  = w and (w.action .. ':' .. tostring(w.value):gsub('\n', ' '):sub(1, 40))
                          or nil,
        status         = self.lastStatus,
        retries        = self.retries,
        label          = self.lastLabel,
        noPath         = self.noPath,
        recovering     = self.al.recovering,
        recoveryMode   = self.al.mode,
        delayedFor     = max(0, floor(self.readyAt - self.now())),
        positionedBySelfNav = self.positionedBySelfNav,
        lastRefill     = self.lastRefillReason,
        walker         = self.walker:status(),
        stats          = self.stats,
    }
end

cavebot.CB = CB
return cavebot
