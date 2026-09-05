--[[============================================================================
bot/walker.lua -- stepping, confirmation, retries, floor changes, anti-lost (work item F2).

Implements the walk state machine of docs/vbot/cavebot.md section 3 (`cavebot/walking.lua`),
whose "## VERIFIER (Corrections)" section overrides the spec body and is followed here.

    local wk = walker.new(client, { world = w, path = p, config = cfg })
    wk:attach()                            -- hook positionChange / walkCancel
    wk:walkTo(pos, opts)                   -- 'arrived' | 'walking' | 'blocked' | 'nopath'
    wk:step(dir)                           -- one step with the confirmation/retry rules
    wk:stop()
    wk:onWalkCancel(data)                  -- the client's walkCancel event
    wk:onPositionChange(data)              -- the client's positionChange event

`config` is the CaveBot `config:` blob straight out of a .cfg (cavebot/config.lua defaults):
    walkDelay 10   ping 100   mapClick false   mapClickDelay 100   smoothWalk false
    avoidFloorChange true     avoidTileIds ""  skipBlocked false   ignoreFields false

THREE MOVEMENT MECHANISMS (cavebot.md 3.2), selected by config:

 1. Single step (default).  `walkTo` paths, sends path[1] raw and records it in a ledger
    (`expectedDirs`), then each later call sends ONE lookahead step while a previously sent
    step is still unconfirmed.  `positionChange` pops the ledger head when the observed
    direction matches.  Three unconfirmed steps -> drop the whole plan and re-path.
    VERIFIER: a stored path is only ever consumed as a lookahead; it is never walked to
    completion -- as soon as the ledger empties the action re-paths from scratch.  That is
    reproduced here by clearing the plan at the top of every re-path (CaveBot.resetWalking()
    runs before every action callback, cavebot.lua:163).

 2. Map click (`mapClick = true`): one autoWalk packet, `delay(mapClickDelay + 50)`.
    VERIFIER: `Game::autoWalk` REFUSES (does not truncate) a path longer than 127 dirs, and
    vBot's wrapper reports success anyway -- so the bot spins forever.  proto/sender.lua
    clamps and reports `sentSteps`; we treat a partial send as "plan consumed" and re-path.

 3. Smooth walk (`smoothWalk = true`): a FIFO of sent-but-unconfirmed steps, paced with
    `sendWindow = min(3, 1 + ceil(ping / stepDuration))` and a 50 ms minimum gap, never
    re-sent, with the documented watchdog.

REFUSED STEPS.  `sender:walk` returns nil when the transport refused the frame (API.md).
vBot's single-step branch ignores that return; its smooth branch does `CB.delay(25)`.  This
walker applies the 25 ms retry to BOTH modes: a refused step is NOT entered into the ledger
(nothing was sent, so nothing can be confirmed), the same direction is retried on the next
call, and after `maxRefusals` (3) consecutive refusals the plan is dropped and `walkTo`
answers 'blocked' with reason 'send-refused-limit'.  Without that cap a dead transport would
be reported as 'walking' forever.

TIMING (cavebot.md 3.2 + VERIFIER):
    per step          delay(walkDelay + stepDuration(dir))     -- MAX semantics, CaveBot.delay
    stepDuration      ceil((1000*groundSpeed/speed)/serverBeat)*serverBeat, x3 when the
                      creature's LAST step direction was diagonal (NOT the dir argument --
                      cavebot.md VERIFIER), then -10 ms, floored at 1; 200 ms fallback when
                      the player speed is unusable (walking.lua:217-223).
    server walk cancel  flat 200 ms retry (localplayer.cpp:178-183, pathfinding.md VERIFIER;
                        the 300/700/1200 ladder in the spec body is wrong).

ANTI-LOST.  Waypoint knowledge lives in bot/cavebot.lua, so this module owns only the parts
that are pure geometry over tiles: floor-change detection, the 60 s bounce guard, the recovery
tile search (exact fall spot, else MANHATTAN-nearest recovery tile within radius 2 -- never
wider) and the teleport-tile search within radius 6.  `bot/cavebot.lua` supplies
`isExpectedFloorChange` and drives the recovery loop.
============================================================================]]

local worldmod = require('bot.world')
local pathmod  = require('bot.path')

local abs, ceil, floor, min, max = math.abs, math.ceil, math.floor, math.min, math.max

local DIR   = worldmod.DIR
local DELTA = worldmod.DELTA
local INVALID_DIR = 8

local walker = {}

local W = {}
W.__index = W

-- ---------------------------------------------------------------------------
-- constants
-- ---------------------------------------------------------------------------
walker.MAX_UNCONFIRMED       = 3        -- walking.lua:311 (#expectedDirs >= 3 -> resetWalking)
walker.REFUSAL_DELAY_MS      = 25       -- walking.lua smooth branch `else CB.delay(25)`
walker.MAX_REFUSALS          = 3
walker.WALK_CANCEL_RETRY_MS  = 200      -- localplayer.cpp:178-183 (VERIFIER)
walker.SMOOTH_MIN_GAP_MS     = 50
walker.SMOOTH_MAX_WINDOW     = 3
walker.STEP_FALLBACK_MS      = 200      -- walking.lua:217-223
walker.SERVER_BEAT_MS        = 50       -- game.h:533
-- antilost.lua:5-11,149-151,303
walker.GIVE_UP_ATTEMPTS      = 200
walker.RETRY_DELAY           = 200
walker.RECOVERY_FREEZE_MS    = 1500
walker.STAIRS_COLOR_MIN      = 210
walker.STAIRS_COLOR_MAX      = 213
walker.LOCAL_SEARCH_RADIUS   = 2
walker.WIDE_SEARCH_RADIUS    = 6
walker.REPEAT_FALL_WINDOW_MS = 60000
walker.MAX_FLOOR_CHANGES_PER_RECOVERY = 4

-- cavebot/config.lua defaults
local CFG_DEFAULTS = {
    walkDelay = 10, ping = 100, mapClick = false, mapClickDelay = 100, useDelay = 400,
    smoothWalk = false, avoidFloorChange = true, avoidTileIds = '',
    skipBlocked = false, ignoreFields = false, wptDistance = 5,
}
walker.CONFIG_DEFAULTS = CFG_DEFAULTS

-- The near-universal vBot pathfinding flag set ("ignore fields"); callers override per site.
local DEFAULT_PARAMS = { ignoreNonPathable = true }

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
-- walker.new(client, opts)
--   opts.world   bot/world.lua instance (built from the client when absent)
--   opts.path    bot/path.lua instance  (idem)
--   opts.config  the CaveBot config: blob (merged over CFG_DEFAULTS)
--   opts.now     () -> ms, for tests; defaults to lib/sys.nowMs
function walker.new(client, opts)
    opts = opts or {}
    local self = setmetatable({}, W)
    self.client = client
    self.state  = client and client.state
    self.sender = client and client.sender
    self.events = client and client.events
    self.log    = client and client.log
    if not self.state then error('walker.new: client.state is required', 2) end

    self.world = opts.world or worldmod.new(client)
    self.path  = opts.path  or pathmod.new(client, self.world)

    self.cfg = {}
    self:configure(opts.config)

    if opts.now then
        self.now = opts.now
    elseif client and client.now then
        self.now = client.now
    else
        local ok, sys = pcall(require, 'lib.sys')
        self.now = (ok and sys.nowMs) or function() return os.clock() * 1000 end
    end

    self.maxRefusals = opts.maxRefusals or walker.MAX_REFUSALS

    self:reset(true)
    self.readyAt   = 0
    self.refusals  = 0
    self.lastStepDir = nil
    self.lastReason  = nil
    self.recentFalls = {}
    self.lastFloorChange = nil
    self.floorChangesSinceReset = 0
    self.handles = nil
    self.stats = { sent = 0, confirmed = 0, refused = 0, cancels = 0, repaths = 0,
                   voids = 0, floorChanges = 0 }
    return self
end

function W:configure(config)
    local cfg = self.cfg
    for k, v in pairs(CFG_DEFAULTS) do cfg[k] = v end
    if type(config) == 'table' then
        for k, v in pairs(config) do cfg[k] = v end
    end
    self.avoidIds = worldmod.parseIdList(cfg.avoidTileIds)
    return cfg
end

-- ---------------------------------------------------------------------------
-- event wiring
-- ---------------------------------------------------------------------------
-- lib/events.lua is BOTH a module-level singleton (dot-called: `LC.events.on(...)`) and a
-- class whose `events.new()` instances are colon-called.  A Bus instance owns `_named`.
local function busOn(bus, name, fn)
    if rawget(bus, '_named') then return bus:on(name, fn) end
    return bus.on(name, fn)
end
local function busOff(bus, handle)
    if rawget(bus, '_named') then return bus:off(handle) end
    return bus.off(handle)
end

function W:attach()
    if self.handles or not self.events then return false end
    self.handles = {
        busOn(self.events, 'positionChange', function(d) self:onPositionChange(d) end),
        busOn(self.events, 'walkCancel',     function(d) self:onWalkCancel(d) end),
    }
    return true
end

function W:detach()
    if not (self.handles and self.events) then return false end
    for i = 1, #self.handles do busOff(self.events, self.handles[i]) end
    self.handles = nil
    return true
end

-- ---------------------------------------------------------------------------
-- delay bookkeeping.  CaveBot.delay is MAX (cavebot.lua:563-565); the bot core's plain
-- delay() is an OVERWRITE (main.lua:206-211).  Both are needed and they are different.
-- ---------------------------------------------------------------------------
function W:delay(ms)
    local t = self.now() + ms
    if t > self.readyAt then self.readyAt = t end
    return self.readyAt
end

function W:setDelay(ms)
    self.readyAt = self.now() + ms
    return self.readyAt
end

function W:isDelayed()
    return self.now() < self.readyAt
end

function W:pingMs()
    local p = self.state.ping or (self.client and self.client.ping)
    if type(p) ~= 'number' or p <= 0 or p > 5000 then p = self.cfg.ping or 100 end
    return p
end

-- ---------------------------------------------------------------------------
-- Creature::getStepDuration (creature.cpp:1106-1160) reduced for a headless local player.
-- ---------------------------------------------------------------------------
function W:groundSpeedTowards(dir)
    local st = self.state
    local pp = st.player and st.player.pos
    local d = DELTA[dir]
    if not (pp and d) then return nil end
    local tile = st:tile({ x = pp.x + d[1], y = pp.y + d[2], z = pp.z })
    if not tile then return nil end
    local s = self.world:groundSpeed(tile)
    if not s or s == 0 then return nil end          -- creature.cpp: 0 -> the 150 substitute
    return s
end

function W:stepDuration(dir)
    local st = self.state
    local speed = st.player and st.player.speed
    if type(speed) ~= 'number' or speed <= 0 then return walker.STEP_FALLBACK_MS end
    local groundSpeed = self:groundSpeedTowards(dir) or 150
    local beat = st.serverBeat or walker.SERVER_BEAT_MS
    if type(beat) ~= 'number' or beat <= 0 then beat = walker.SERVER_BEAT_MS end
    local ms = ceil((1000 * groundSpeed / speed) / beat) * beat
    -- VERIFIER (cavebot.md): the diagonal multiplier follows the creature's LAST step
    -- direction, not the `dir` argument; `dir` only chooses which tile's speed is read.
    local ref = self.lastStepDir
    if ref == nil then ref = dir end
    if worldmod.isDiagonal(ref) then ms = ms * 3 end
    ms = ms - 10
    if ms < 1 then ms = 1 end
    return ms
end

-- ---------------------------------------------------------------------------
-- plan / ledger
-- ---------------------------------------------------------------------------
function W:reset(quiet)
    local hadPending = self.pending and #self.pending > 0
    self.expected  = {}
    self.walkPath  = {}
    self.iter      = 0
    if self.cfg.smoothWalk and hadPending and self.sender then
        self.sender:stop()                       -- walking.lua:250-262
    end
    self.pending     = {}
    self.pendingAuto = false
    self.smoothDest  = nil
    if not quiet then self.stats.repaths = self.stats.repaths + 1 end
    return self
end
W.resetWalking = W.reset

function W:stop()
    if self.sender then self.sender:stop() end
    self:reset(true)
    self.refusals = 0
    return true
end

function W:isWalking()
    return #self.expected > 0 or #self.pending > 0
end

-- projectedPos(): the confirmed position advanced by every in-flight step (smooth mode).
function W:projectedPos()
    local pp = self.state.player.pos
    if not pp then return nil end
    local x, y, z = pp.x, pp.y, pp.z
    local q = self.pending
    for i = 1, #q do
        local d = DELTA[q[i].dir]
        if d then x, y = x + d[1], y + d[2] end
    end
    return { x = x, y = y, z = z }
end

-- ---------------------------------------------------------------------------
-- one step, with the documented confirmation / retry rules
-- ---------------------------------------------------------------------------
-- returns true on a successful send; false, reason otherwise
--   reason 'no-sender' | 'bad-direction' | 'send-refused' | 'send-refused-limit'
function W:step(dir)
    if DELTA[dir] == nil then return false, 'bad-direction' end
    if not self.sender then return false, 'no-sender' end
    local body = self.sender:walk(dir)
    if not body then
        self.refusals = self.refusals + 1
        self.stats.refused = self.stats.refused + 1
        if self.refusals >= self.maxRefusals then
            self:reset()
            self.refusals = 0
            self:delay(walker.REFUSAL_DELAY_MS)
            return false, 'send-refused-limit'
        end
        self:delay(walker.REFUSAL_DELAY_MS)
        return false, 'send-refused'
    end
    self.refusals = 0
    self.stats.sent = self.stats.sent + 1
    local t = self.now()
    self.expected[#self.expected + 1] = dir
    self.lastSendAt  = t
    self.lastStepDir = dir
    self:delay((self.cfg.walkDelay or 0) + self:stepDuration(dir))
    return true
end

-- CaveBot.doWalking (walking.lua:307-333): at most ONE send per call, and only while a
-- previously sent step is still unconfirmed.  Returns nil when nothing is in flight,
-- otherwise 'walking' or 'blocked'.
function W:_doWalking()
    if self.cfg.mapClick then return nil end
    local n = #self.expected
    if n == 0 then return nil end
    if n >= walker.MAX_UNCONFIRMED then
        self:reset()                                     -- drop the plan, the caller re-paths
        return nil
    end
    local dir = self.walkPath[self.iter]
    if dir == nil then return 'walking' end              -- lookahead exhausted, awaiting confirm
    local ok, why = self:step(dir)
    if ok then
        self.iter = self.iter + 1
        return 'walking'
    end
    if why == 'send-refused-limit' then
        self.lastReason = why
        return 'blocked'
    end
    return 'walking'
end

-- smooth-walk pacer (walking.lua:382-469)
function W:_smoothWalking()
    local nextDir = self.walkPath[self.iter]
    if #self.pending == 0 and nextDir == nil then return nil end
    local now = self.now()

    if #self.pending > 0 then
        local head = self.pending[1]
        local ref = max(self.lastConfirmAt or 0, head.t)
        if now - ref > self:pingMs() + 2 * self:stepDuration(head.dir) + 400 then
            if self.sender then self.sender:stop() end
            self.pending, self.pendingAuto = {}, false
            self.walkPath, self.iter, self.smoothDest = {}, 0, nil
            self:delay(100)
            self.lastReason = 'smooth-watchdog'
            return nil
        end
    end

    if self.pendingAuto then return 'walking' end

    if nextDir ~= nil then
        local window = min(walker.SMOOTH_MAX_WINDOW,
                           1 + ceil(self:pingMs() / self:stepDuration(nextDir)))
        if #self.pending < window and (now - (self.lastSmoothSendAt or 0)) >= walker.SMOOTH_MIN_GAP_MS then
            local body = self.sender and self.sender:walk(nextDir)
            if body then
                self.refusals = 0
                self.stats.sent = self.stats.sent + 1
                self.pending[#self.pending + 1] = { dir = nextDir, t = now }
                self.lastSmoothSendAt = now
                self.lastSendAt = now
                self.lastStepDir = nextDir
                self.iter = self.iter + 1
                self:delay(self.cfg.walkDelay or 0)
            else
                self.refusals = self.refusals + 1
                self.stats.refused = self.stats.refused + 1
                if self.refusals >= self.maxRefusals then
                    self:reset(); self.refusals = 0
                    self.lastReason = 'send-refused-limit'
                    self:delay(walker.REFUSAL_DELAY_MS)
                    return 'blocked'
                end
                self:delay(walker.REFUSAL_DELAY_MS)
            end
        end
    end
    return 'walking'
end

-- ---------------------------------------------------------------------------
-- walkTo
-- ---------------------------------------------------------------------------
-- opts.maxDist        pathfinder step cap (default 40, the CaveBot goto value)
-- opts.params         findEveryPath params (default {ignoreNonPathable = true})
-- opts.precision      arrival tolerance in Chebyshev-per-axis terms (default 0 = exact tile)
-- opts.allowCreatures do not refuse when a creature has stepped onto the next tile
-- opts.avoidFloorChange  override the config flag for this call
function W:walkTo(dest, opts)
    opts = opts or {}
    self.lastReason = nil
    local st = self.state
    local pp = st.player and st.player.pos
    if not pp then self.lastReason = 'no-player-position'; return 'nopath' end
    if not dest then self.lastReason = 'no-destination';   return 'nopath' end

    local prec = opts.precision or 0
    if pp.z == dest.z and abs(pp.x - dest.x) <= prec and abs(pp.y - dest.y) <= prec then
        self:reset(true)
        return 'arrived'
    end
    if pp.z ~= dest.z then self.lastReason = 'different-floor'; return 'nopath' end

    if self:isDelayed() then return 'walking' end

    if self.cfg.smoothWalk then
        -- destination change while steps are still in flight (walking.lua:385-398, VERIFIER)
        if #self.pending > 0 and self.smoothDest and not worldmod.samePos(self.smoothDest, dest) then
            if self.pendingAuto then
                if self.sender then self.sender:stop() end
                self.pending, self.pendingAuto = {}, false
                self.walkPath, self.iter, self.smoothDest = {}, 0, nil
                self:delay(100 + ceil(self:pingMs() / 2))
                return 'walking'
            end
        end
        local s = self:_smoothWalking()
        if s then return s end
    else
        local s = self:_doWalking()
        if s then return s end
    end

    -- ---- re-path (CaveBot.resetWalking() before every action callback) -----------------
    self:reset()

    local from = self.cfg.smoothWalk and (self:projectedPos() or pp) or pp
    local dirs, why = self.path:getPath(from, dest, opts.maxDist or 40,
                                        opts.params or DEFAULT_PARAMS)
    if not dirs or not dirs[1] then
        self.lastReason = why or 'no-path'
        return 'nopath'
    end

    local avoid = opts.avoidFloorChange
    if avoid == nil then avoid = (self.cfg.avoidFloorChange ~= false) end
    if avoid then
        local bad, reason = self.path:crossesFloorChange(from, dest, dirs, self.avoidIds)
        if bad then
            self.lastReason = 'floor-change: ' .. tostring(reason)
            return 'blocked'
        end
    end

    -- A creature that stepped onto the next tile AFTER the search: the path is stale.
    -- (The pathfinder itself never routes through a blocking creature unless ignoreCreatures.)
    if not opts.allowCreatures then
        local d = DELTA[dirs[1]]
        local np = { x = from.x + d[1], y = from.y + d[2], z = from.z }
        local tile = st:tile(np)
        if tile and self.world:hasBlockingCreature(tile) then
            self.blockingTile = np
            self.lastReason = 'creature-blocks'
            self:delay(100)
            return 'blocked'
        end
    end
    self.blockingTile = nil

    if self.cfg.mapClick then
        local body, sent = self.sender and self.sender:autoWalk(dirs)
        if not body then self.lastReason = 'send-refused'; self:delay(walker.REFUSAL_DELAY_MS)
            return 'blocked' end
        self.stats.sent = self.stats.sent + (sent or #dirs)
        self.lastStepDir = dirs[min(sent or #dirs, #dirs)]
        self:delay((self.cfg.mapClickDelay or 100) + (self.cfg.smoothWalk and 0 or 50))
        if self.cfg.smoothWalk then
            self.pendingAuto = true
            self.lastConfirmAt = self.now()
            for i = 1, (sent or #dirs) do
                self.pending[#self.pending + 1] = { dir = dirs[i], t = self.now() }
            end
            self.smoothDest = { x = dest.x, y = dest.y, z = dest.z }
        end
        return 'walking'
    end

    if self.cfg.smoothWalk then
        self.walkPath, self.iter = dirs, 1
        self.smoothDest = { x = dest.x, y = dest.y, z = dest.z }
        local s = self:_smoothWalking()
        return s or 'walking'
    end

    local ok, whyStep = self:step(dirs[1])
    if not ok then
        if whyStep == 'send-refused-limit' then
            self.lastReason = whyStep
            return 'blocked'
        end
        self.lastReason = whyStep
        return 'walking'                          -- retried on the next call after 25 ms
    end
    self.walkPath, self.iter = dirs, 2
    return 'walking'
end

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------
-- proto/parser.lua emits positionChange as { pos = new, oldPos = old }.
function W:onPositionChange(data)
    local newPos = data and (data.pos or data.new)
    local oldPos = data and (data.oldPos or data.old)
    if not newPos then return end
    local now = self.now()

    local dir = INVALID_DIR
    if oldPos and newPos.z == oldPos.z then
        local dx, dy = newPos.x - oldPos.x, newPos.y - oldPos.y
        if dx >= -1 and dx <= 1 and dy >= -1 and dy <= 1 then
            local row = DIR[dx]
            dir = (row and row[dy]) or INVALID_DIR
        end
    end

    if #self.pending > 0 then
        if dir ~= INVALID_DIR and self.pending[1].dir == dir then
            table.remove(self.pending, 1)
            self.lastConfirmAt = now
            self.stats.confirmed = self.stats.confirmed + 1
            if #self.pending == 0 then self.pendingAuto = false end
        else
            -- teleport / push / floor change: the ledger is void, force a re-path
            self.pending, self.pendingAuto, self.smoothDest = {}, false, nil
            self.stats.voids = self.stats.voids + 1
            if self.cfg.smoothWalk then self:delay(100) end   -- VERIFIER: smooth mode only
        end
    end

    if self.expected[1] ~= nil and self.expected[1] == dir then
        table.remove(self.expected, 1)
        self.lastConfirmAt = now
        self.stats.confirmed = self.stats.confirmed + 1
    end

    if oldPos and newPos.z ~= oldPos.z then
        self:_onFloorChange(oldPos, newPos)
    end
end

-- 0xB5 WalkCancel: the server refused / undid our walk.  Drop the plan and back off a flat
-- 200 ms (localplayer.cpp:178-183; the spec body's 300/700/1200 ladder is wrong -- VERIFIER).
function W:onWalkCancel(data)
    self.stats.cancels = self.stats.cancels + 1
    self.lastCancel = { direction = data and data.direction, at = self.now() }
    self:reset()
    self:delay(walker.WALK_CANCEL_RETRY_MS)
    self.lastReason = 'walk-cancel'
    if self.onWalkCancelHook then pcall(self.onWalkCancelHook, self, data) end
    return true
end

function W:_onFloorChange(oldPos, newPos)
    self.stats.floorChanges = self.stats.floorChanges + 1
    self.floorChangesSinceReset = self.floorChangesSinceReset + 1
    self:reset(true)
    local key = oldPos.x .. ',' .. oldPos.y .. ',' .. oldPos.z .. '>' .. newPos.z
    local now = self.now()
    local last = self.recentFalls[key]
    -- VERIFIER (cavebot.md): the timestamp is written BEFORE the window is tested, so every
    -- suppressed fall refreshes the window.  Reproduced deliberately.
    self.recentFalls[key] = now
    local suppressed = (last ~= nil) and (now - last < walker.REPEAT_FALL_WINDOW_MS) or false
    self.lastFloorChange = { from = { x = oldPos.x, y = oldPos.y, z = oldPos.z },
                             to   = { x = newPos.x, y = newPos.y, z = newPos.z },
                             at = now, key = key, suppressed = suppressed }
    if self.onFloorChangeHook then pcall(self.onFloorChangeHook, self, self.lastFloorChange) end
end

function W:isFallSuppressed(oldPos, newZ)
    local key = oldPos.x .. ',' .. oldPos.y .. ',' .. oldPos.z .. '>' .. newZ
    local last = self.recentFalls[key]
    return last ~= nil and (self.now() - last < walker.REPEAT_FALL_WINDOW_MS)
end

-- ---------------------------------------------------------------------------
-- anti-lost geometry (antilost.lua:80-140).  "Nearest" is MANHATTAN while the radius itself
-- is a square box, and ties go to the first hit in the dx-then-dy scan order (VERIFIER).
-- ---------------------------------------------------------------------------
local function nearestInBox(centre, radius, accept)
    local best, bestD
    for dx = -radius, radius do
        for dy = -radius, radius do
            local p = { x = centre.x + dx, y = centre.y + dy, z = centre.z }
            if accept(p) then
                local d = abs(dx) + abs(dy)
                if bestD == nil or d < bestD then best, bestD = p, d end
            end
        end
    end
    return best, bestD
end
walker.nearestInBox = nearestInBox

-- stairs mode: EXACTLY the fall spot's x,y on the current floor when that tile is a recovery
-- tile, otherwise the nearest recovery tile within radius 2 of it.  Never a wider search --
-- a different hole would take the bot somewhere else entirely (antilost.lua:121-140).
function W:recoveryTarget(fallSpot, currentZ, ladderIds, ropeIds)
    local wl = self.world
    local exact = { x = fallSpot.x, y = fallSpot.y, z = currentZ }
    if wl:isRecoveryTile(exact, ladderIds, ropeIds) then return exact, 'exact' end
    local p = nearestInBox(exact, walker.LOCAL_SEARCH_RADIUS, function(q)
        return wl:isRecoveryTile(q, ladderIds, ropeIds) and true or false
    end)
    if p then return p, 'nearby' end
    return nil
end

-- teleport mode: the nearest tile within radius 6 whose top-use id equals the remembered id.
function W:teleportTarget(centre, teleportId, radius)
    local wl, st = self.world, self.state
    return nearestInBox(centre, radius or walker.WIDE_SEARCH_RADIUS, function(q)
        local tile = st:tile(q)
        if not tile then return false end
        local top = wl:getTopUseThing(tile)
        return top ~= nil and top.kind == 'item' and top.id == teleportId
    end)
end

-- ---------------------------------------------------------------------------
-- status (for bot:status() / the web panel)
-- ---------------------------------------------------------------------------
function W:status()
    return {
        walking     = self:isWalking(),
        expected    = #self.expected,
        pending     = #self.pending,
        planLength  = #self.walkPath,
        planIndex   = self.iter,
        readyIn     = max(0, floor(self.readyAt - self.now())),
        refusals    = self.refusals,
        lastReason  = self.lastReason,
        lastStepDir = self.lastStepDir,
        lastFloorChange = self.lastFloorChange,
        stats       = self.stats,
        itemData    = self.world.itemDataLevel,
    }
end

return walker
