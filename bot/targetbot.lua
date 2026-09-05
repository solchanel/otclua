--[[============================================================================
bot/targetbot.lua -- target selection, combat behaviour, luring and the CaveBot
interlock (work item M3).

Port of `P/targetbot/{target,creature,creature_priority,creature_attack,walking}.lua`
(vBot 4.8), spec docs/vbot/targetbot.md sections 1-3.  The "## VERIFIER (Corrections)"
section of that file overrides its body and is followed here; every correction is applied
and marked `VERIFIER` in the code.  Looting lives in bot/loot.lua (section 4).

    local tb = targetbot.new(bot, config [, opts])
    tb:enable() tb:disable() tb:isOn()
    tb:tick()                       -- registered as a 100 ms macro on `bot`
    tb:reload(config)  tb:status()

Public state other modules read (target.lua:181-265):
    tb:isActive()                   -- lastAction + 300 > now   (CaveBot freezes on this)
    tb:isCaveBotActionAllowed()     -- cavebotAllowance > now    (the luring escape hatch)
    tb:allowCaveBot(ms)  tb:Danger()  tb:lootStatus()  tb:getStatus()
    tb:delay(ms)  tb:canLure()  tb:enableLuring()  tb:disableLuring()
    tb:target()                     -- the creature we are attacking, or nil
    tb:walkTo(dest, maxDist, params) / tb:walk()      -- the stepper (section 3.8)

`config` may be a parsed `{targeting=,looting=}` table, a config NAME (loaded through
bot.config:loadTargetbot), or nil (the name in storage._configs.targetbot_configs.selected).
Both real "empty" shapes are handled: `{}` and `[]` (targetbot_configs/true_asuras.json).

------------------------------------------------------------------------------
ONE TICK (target.lua:49-128), in order
------------------------------------------------------------------------------
  specs      = 13x13 same-floor box; > 10 monsters shrinks it to 7x7
  per candidate, in SPECTATOR ORDER (z, then y, then x, ALL ASCENDING -- the order is the
      tie-break and must not change): healthPercent > 0, findPath(...,7,
      {ignoreLastCreature, ignoreNonPathable, ignoreCost, ignoreCreatures}), isMonster,
      creature type < 3 (excludes summons)
  score it (calculateParams -> calculatePriority), accumulate dangerLevel, count `targets`
      for every positive score, keep the STRICT maximum (first in spectator order wins ties)
  walkTo(nil)                         -- the destination is reset EVERY tick
  looting = Looting.process(targets, dangerLevel)      -- BEFORE the attack decision
  dangerValue = dangerLevel
  a target and not in PZ  -> attack(params, targets, looting); walk(); lastAction = now
  else if looting         -> walk(); lastAction = now

------------------------------------------------------------------------------
DELIBERATE DEVIATIONS (each is a VERIFIER-flagged upstream defect or a luaclient gap)
------------------------------------------------------------------------------
1. getDistanceBetween IS CHEBYSHEV.  docs/vbot/targetbot.md 0.4 quotes
   modules/game_battle/battle.lua:1881 (xd+yd with 1 subtracted per non-zero axis), but
   mods/game_bot/executor.lua:123-125 REPLACES that global inside the bot context with
   `math.max(|dx|,|dy|)`, and the whole vBot profile runs in that context.  So
   `distanceFromPlayer`, `getMonsters(range)` and the anchor test are all Chebyshev.
   Verified by reading executor.lua; bot/world.lua made the same call.
2. `g_game.getAttackingCreature()` does not exist here.  We track `attackingId` (the id
   last handed to sender:attack) and clear it on `attackCancel` and on the target's
   `creatureDisappear`, per docs/vbot/targetbot.md section 6.  The VERIFIER's point that
   vBot RE-SENDS the attack whenever the server clears it is therefore reproduced for the
   two events luaclient can observe; a silent server-side clear is not observable.
3. `storage.extras.killUnder`: vBot reads `(x or 30)` at creature_attack.lua:151 but BARE
   `x` at :171 and :174, so an absent key RAISES there and the executor's pcall aborts the
   whole tick.  We keep `(x or 30)` verbatim in the lure guard, and when the key is absent
   we substitute 0 at :171/:174 (which is the no-op reading: `killUnder > 1` false, so no
   forced chase; `hp >= 0` true, so rePosition is not gated) and log it once.  The user's
   real profile stores killUnder = 1, so this path never runs against it.
4. `#currentDistance` on a nil path.  vBot raises; the executor's pcall then aborts the
   ENTIRE tick -- no walk, no `lastAction` refresh, so CaveBot resumes 300 ms later.  We
   reproduce that OUTCOME without an exception: creatureWalk returns 'abort', tick()
   returns immediately, and the reason is logged once every 10 s.  We do NOT invent the
   `999` fallback the pseudocode suggests (that would chase instead).
5. The stepper sends through bot/walker.lua (`walker:step(dir)`), as BOT.md requires, so
   the confirmation ledger, the refusal retry and `walkCancel` handling are shared with
   CaveBot.  `player:isWalking()` maps to `walker:isWalking()`.  Because a lost
   confirmation would otherwise wedge the ledger forever (the real client times its own
   walk out), an explicit watchdog resets the walker after
   ping + 2*stepDuration + 400 ms -- see `_walkerStuck`.
6. `TargetBot.walk()` gets the pseudocode's `#path == 0` guard.  vBot only tests
   `if path then` and can call `walk(nil)` when the destination equals the start; the
   VERIFIER says the guard is an improvement, not fidelity.  Stated here as such.
7. `rePosition` picks the best neighbour DETERMINISTICALLY.  vBot builds a table keyed by
   tile userdata and iterates it with `pairs`, so ties among equally-good tiles resolve
   arbitrarily.  We scan `getNearTiles` order with the same strict `>`, so the first best
   wins.  The branch itself still routes through the CAVEBOT walker (CaveBot.GoTo), so it
   does nothing at all when CaveBot is absent -- exactly like vBot.
8. Missing entry fields are filled with the creature-editor defaults (spec 1.2, all 27
   verified by the VERIFIER) on a COPY; `tb:save()` writes the untouched original tables
   back, so unknown keys survive.  vBot would raise on, say, a missing `maxDistance`.
9. `tick()` additionally returns early when the Config switch is off.  vBot's macro is
   gated on `macro.enabled`, which target.lua:149 keeps in step with the switch, but the two
   can disagree transiently (the VERIFIER notes this).  Gating on the switch is strictly
   more conservative and makes a directly-called `tb:tick()` behave like the macro.
10. The dead attack-spell / attack-rune block is implemented (fields the 4.8 editor never
   writes) with its exact ordering and rate limits, INCLUDING the fact that
   `useAttackItem` returns nil so `if ... then return end` never short-circuits.

11. LAST-KNOWN CREATURE POSITIONS.  `game/state.lua:_removeAt` nils `creature.pos` when the
   creature thing leaves its tile, and proto/parser.lua:411 emits `creatureDisappear` AFTER
   `state:removeCreature`, so the record handed to the handler has no position at all --
   whereas otclient's C++ Creature keeps m_position, which is exactly what vBot's corpse
   discovery reads.  Every tick's spectator scan therefore records `lastPos[id]`, and that
   is passed to the looter as the corpse tile.  The 13x13 scan box is strictly larger than
   the 6-tile discovery radius, so nothing the looter could have queued is missed.

NOT REPRODUCED (widget detail, spec section 5): every ui.* label, the debug priority
overlay, `creature:setText`, and the corpse `setMarked('#000088')`.
============================================================================]]

local worldmod = require('bot.world')
local pathmod  = require('bot.path')
local walkmod  = require('bot.walker')
local lootmod  = require('bot.loot')

local abs, max, floor = math.abs, math.max, math.floor

local targetbot = {}

local TB = {}
TB.__index = TB

-- ---------------------------------------------------------------------------
-- constants
-- ---------------------------------------------------------------------------
targetbot.MACRO_PERIOD_MS   = 100    -- target.lua:49
targetbot.CANDIDATE_RANGE   = 6      -- 13x13 (target.lua:51)
targetbot.CANDIDATE_RANGE_2 = 3      -- 7x7   (target.lua:59)
targetbot.CROWD_THRESHOLD   = 10     -- target.lua:58 (`> 10`)
targetbot.CANDIDATE_PATH    = 7      -- target.lua:70
targetbot.ACTIVE_WINDOW_MS  = 300    -- target.lua:183
targetbot.CAVEBOT_ALLOW_MS  = 150    -- creature_attack.lua:149,154,159
targetbot.REPOSITION_MS     = 500    -- creature_attack.lua:24
targetbot.SAY_SPELL_MS      = 500    -- target.lua:273
targetbot.SAY_ATTACK_MS     = 2000   -- target.lua:287
targetbot.USE_ITEM_MS       = 200    -- target.lua:301
targetbot.USE_ATTACK_MS     = 2000   -- target.lua:319
targetbot.AVOID_LOG_MS      = 10000  -- walking.lua:42
targetbot.CHASE_PATH_MAX    = 10     -- creature_attack.lua:170
targetbot.LURE_PATH_MAX     = 5      -- creature_attack.lua:161
targetbot.LURE_MARGIN_MIN   = 5
targetbot.LURE_MARGIN_MAX   = 6
targetbot.PZ_STATE          = 16384  -- PlayerStates.Pz (src/client/const.h:295)
targetbot.WALK_WATCHDOG_PAD = 400

local HOTKEY_POS = { x = 0xFFFF, y = 0, z = 0 }

-- the findPath params of target.lua:70 -- never mutated, bot/path.lua copies before use
local CANDIDATE_PARAMS = { ignoreLastCreature = true, ignoreNonPathable = true,
                           ignoreCost = true, ignoreCreatures = true }
local CHASE_SCAN_PARAMS = { ignoreCreatures = true, ignoreNonPathable = true,
                            ignoreCost = true }

-- vlib.lua:1291 / :1205.  bot/world.lua's grid parser accepts this exact text form.
targetbot.DIAMOND_ARROW_AREA = [[
    01110
    11111
    11111
    11111
    01110
]]
targetbot.LARGE_RUNE_AREA = [[
    0011100
    0111110
    1111111
    1111111
    1111111
    0111110
    0011100
]]

-- getNearTiles (vlib.lua:900-917): note the MINUS -- the list enumerates the same eight
-- tiles but in this exact order, and rePosition's "first best wins" depends on it.
local NEAR_DIRS = { { -1, 1 }, { 0, 1 }, { 1, 1 }, { -1, 0 },
                    { 1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 } }

-- creature_editor.lua:79-105 -- all 27 fields, ranges verified by the spec's VERIFIER.
local ENTRY_DEFAULTS = {
    priority = 1, danger = 1, maxDistance = 10,
    chase = true, keepDistance = false, keepDistanceRange = 1,
    anchor = false, anchorRange = 3,
    avoidAttacks = false, faceMonster = false,
    rePosition = false, rePositionAmount = 5,
    lure = false, lureCount = 1, lureCavebot = false,
    dynamicLure = false, lureMin = 1, lureMax = 3,
    dynamicLureDelay = false, lureDelay = 250, delayFrom = 2,
    closeLure = false, closeLureAmount = 3,
    dontLoot = false, diamondArrows = false, rpSafe = false,
}

-- ---------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------
-- deviation (1): Chebyshev, per executor.lua:123-125
local function cheb(a, b) return max(abs(a.x - b.x), abs(a.y - b.y)) end

local function copyPos(p) return { x = p.x, y = p.y, z = p.z } end

local function nolog() end
local function mklog(l)
    if type(l) ~= 'table' then
        return { info = nolog, warn = nolog, error = nolog, debug = nolog }
    end
    return { info = l.info or nolog, warn = l.warn or l.warning or nolog,
             error = l.error or nolog, debug = l.debug or nolog }
end

local function busOn(bus, name, fn)
    if rawget(bus, '_named') then return bus:on(name, fn) end
    return bus.on(name, fn)
end
local function busOff(bus, h)
    if rawget(bus, '_named') then return bus:off(h) end
    return bus.off(h)
end

-- ---------------------------------------------------------------------------
-- name matching (creature.lua:21-29 + :53-72)
-- ---------------------------------------------------------------------------
--- The regex builder only ever rewrites `*` -> `.*` and `?` -> `.?` and anchors each
--- comma-separated alternative with ^...$; nothing else is escaped (creature.lua:27).
function targetbot.buildRegex(name)
    local re = ''
    for part in tostring(name):gmatch('[^,]+') do
        if #re > 0 then re = re .. '|' end
        re = re .. '^'
             .. part:gsub('^%s+', ''):gsub('%s+$', ''):lower()
                    :gsub('%*', '.*'):gsub('%?', '.?')
             .. '$'
    end
    return re
end

--- Translate ONE ECMAScript alternative into a Lua pattern.
---
--- VERIFIER: the persisted `regex` must win over `name` (a hand-edited file may disagree,
--- and vBot matches on `regex` alone), so we cannot glob the `name` list directly -- but a
--- naive `string.match(name, alt)` is wrong because a monster name may contain Lua-magic
--- characters.  So the alternative is TOKENISED: `.*` and `.?` (and a bare `.`) become the
--- Lua equivalents, `\x` unescapes, and every other character is emitted as a `%`-escaped
--- literal.  Any other regex metacharacter is treated as a literal, which is exactly what
--- the 4.8 editor can produce -- documented as the one lossy case.
local luaPatCache = {}
local function altToLuaPattern(alt)
    local hit = luaPatCache[alt]
    if hit ~= nil then return hit end
    local body, anchorStart, anchorEnd = alt, false, false
    if body:sub(1, 1) == '^' then anchorStart = true; body = body:sub(2) end
    if body:sub(-1) == '$' and body:sub(-2) ~= '\\$' then
        anchorEnd = true; body = body:sub(1, -2)
    end
    local out, i, n = {}, 1, #body
    while i <= n do
        local c = body:sub(i, i)
        if c == '\\' and i < n then
            out[#out + 1] = ('%%%s'):format(body:sub(i + 1, i + 1))
            i = i + 2
        elseif c == '.' then
            local nx = body:sub(i + 1, i + 1)
            if nx == '*' then out[#out + 1] = '.*'; i = i + 2
            elseif nx == '?' then out[#out + 1] = '.?'; i = i + 2
            elseif nx == '+' then out[#out + 1] = '.+'; i = i + 2
            else out[#out + 1] = '.'; i = i + 1 end
        else
            if c:match('[%^%$%(%)%%%.%[%]%*%+%-%?]') then
                out[#out + 1] = '%' .. c
            else
                out[#out + 1] = c
            end
            i = i + 1
        end
    end
    local pat = table.concat(out)
    if anchorStart then pat = '^' .. pat end
    if anchorEnd then pat = pat .. '$' end
    luaPatCache[alt] = pat
    return pat
end
targetbot._altToLuaPattern = altToLuaPattern

--- regexMatch(name, cfg.regex)[1] -- `regex_search`, so an unanchored alternative is a
--- substring test.  Every generated alternative is anchored.
function targetbot.matchesName(lowerName, regex)
    if type(regex) ~= 'string' or #regex == 0 then return false end
    for alt in regex:gmatch('[^|]+') do
        local ok, hit = pcall(string.find, lowerName, altToLuaPattern(alt))
        if ok and hit then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
function targetbot.new(b, config, opts)
    opts = opts or {}
    local self = setmetatable({}, TB)
    self.bot    = b
    local client = (b and b.client) or opts.client or {}
    self.client = client
    self.state  = client.state
    self.sender = client.sender
    self.events = client.events
    self.log    = mklog(client.log)
    if not self.state then error('targetbot.new: client.state is required', 2) end

    self.storage = (b and b.storage) or opts.storage or {}
    if type(self.storage.extras) ~= 'table' then self.storage.extras = {} end

    -- the per-tick `now` snapshot (executor.lua:195-196).  bot/init.lua refreshes
    -- `bot.now` once per 10 ms master tick, so reading the field IS the snapshot.
    if opts.now then
        self._clock = opts.now
    elseif b and type(b.now) == 'number' then
        self._clock = function() return b.now end
    elseif b and type(b.now) == 'function' then
        self._clock = b.now
    else
        local ok, sys = pcall(require, 'lib.sys')
        self._clock = (ok and sys.nowMs) or function() return os.clock() * 1000 end
    end

    self.world  = opts.world  or (b and b.world)  or worldmod.new(client)
    self.path   = opts.path   or (b and b.path)   or pathmod.new(client, self.world)
    self.walker = opts.walker or (b and b.walker)
                  or walkmod.new(client, { world = self.world, path = self.path,
                                           config = opts.walkerConfig,
                                           now = self._clock })
    self.clientVersion = opts.clientVersion or 1530
    self.oldTibia = self.clientVersion < 960                  -- target.lua:46

    -- combat / luring state.  The INITIAL VALUES ARE LOAD-BEARING (VERIFIER on the
    -- pseudocode's TB table): lureMax starts at 0 -- truthy in Lua -- which is why
    -- `if not lureMax then return end` at creature_attack.lua:239 is DEAD CODE; and
    -- lastCall starts at `now`, so rePosition is blocked for the first 500 ms.
    self.attackingId   = nil
    self.lastAction    = 0
    self.cavebotAllow  = 0
    self.lureEnabled   = true
    self.dangerValue   = 0
    self.targets       = 0
    self.targetBotLure = false
    self.targetCount   = 0
    self.delayValue    = 0
    self.lureMax       = 0
    self.delayFrom     = nil
    self.dynamicLureDelay = false
    self.anchorPos     = nil
    self.lastRePos     = self._clock()
    self.lastSpell, self.lastAttackSpell = 0, 0
    self.lastItemUse, self.lastRuneAttack = 0, 0
    self.dest, self.maxDist, self.params = nil, nil, nil
    self.lastAvoidLog  = 0
    self.statusText    = ''
    self.delayUntil    = 0
    self.configsCache, self.cached = {}, 0
    self._loggedOnce   = {}
    self._stepAt       = nil
    self.lastPos       = {}        -- creature id -> the tile we last SAW it on (dev. 11)
    self.stats = { ticks = 0, attacks = 0, steps = 0, aborts = 0,
                   lureAllowances = 0, repositions = 0, spells = 0, runes = 0 }

    self.avoidIds = worldmod.parseIdList(
        (opts.walkerConfig and opts.walkerConfig.avoidTileIds) or self.walker.cfg.avoidTileIds)

    self.loot = lootmod.new{
        client = client, world = self.world, path = self.path,
        storage = self.storage, clientVersion = self.clientVersion,
        now      = self._clock,
        schedule = function(ms, fn)
            if b and b.schedule then return b:schedule(ms, fn) end
            return fn()
        end,
        walkTo   = function(dest, maxDist, params) return self:walkTo(dest, maxDist, params) end,
        isOn     = function() return self:isOn() end,
        isInPz   = function() return self:isInPz() end,
        calculateParams = function(c, path) return self:calculateParams(c, path) end,
    }

    self:reload(config)
    return self
end

-- ---------------------------------------------------------------------------
-- configuration
-- ---------------------------------------------------------------------------
local function normaliseEntry(raw)
    local e = {}
    for k, v in pairs(raw) do e[k] = v end
    for k, v in pairs(ENTRY_DEFAULTS) do
        if e[k] == nil then e[k] = v end
    end
    -- creature.lua:21-29: the regex is derived ONLY when absent, and is written back into
    -- the on-disk table so it persists (addConfig does the same).
    if type(raw.regex) ~= 'string' or #raw.regex == 0 then
        raw.regex = targetbot.buildRegex(raw.name or '')
    end
    e.regex = raw.regex
    e._raw = raw
    return e
end

--- reload(config).  target.lua:131-152 -- `data == nil` turns the macro OFF; otherwise the
--- creature list is rebuilt, the looter is updated (which WIPES its queue), the macro delay
--- is cleared and luring is re-enabled.
function TB:reload(config)
    local data = config
    if type(config) == 'string' then
        data = self:_loadNamed(config)
        self.configName = config
    elseif config == nil then
        local name = self:getCurrentProfile()
        if name and #name > 0 then
            data = self:_loadNamed(name)
            self.configName = name
        end
    elseif type(config) == 'table' then
        self.configName = self.configName or (self.bot and self:getCurrentProfile()) or nil
    end

    self.configsCache, self.cached = {}, 0

    if data == nil then
        -- target.lua:132-135: no data -> the macro is switched off and nothing is loaded
        self.raw = { targeting = {}, looting = {} }
        self.targeting = {}
        self.loot:update({})
        self:setOff()
        return self
    end

    if type(data) ~= 'table' then data = {} end
    local targeting = type(data.targeting) == 'table' and data.targeting or {}
    local looting   = type(data.looting)   == 'table' and data.looting   or {}
    self.raw = data
    data.targeting, data.looting = targeting, looting

    self.targeting = {}
    for i = 1, #targeting do
        local raw = targeting[i]
        if type(raw) == 'table' and type(raw.name) == 'string' then
            self.targeting[#self.targeting + 1] = normaliseEntry(raw)
        else
            self.log.warn('[TargetBot] skipping targeting entry %d (no name)', i)
        end
    end
    self.loot:update(looting)

    -- target.lua:150-151
    self.delayUntil  = 0
    self.lureEnabled = true
    if self.macro then self.macro.delay = nil end
    return self
end

function TB:_loadNamed(name)
    local cfg = self.bot and self.bot.config
    if not cfg or not cfg.loadTargetbot then return nil end
    local ok, data = pcall(cfg.loadTargetbot, cfg, name)
    if not ok or data == nil then
        self.log.error('[TargetBot] cannot load targetbot_configs/%s: %s',
                       tostring(name), tostring(data))
        return nil
    end
    -- both real "empty" shapes: `{}` and `[]`
    return data
end

--- TargetBot.save (target.lua:238-246) -- writes the ORIGINAL entry tables, so unknown
--- fields survive (BOT.md config compatibility).
function TB:save()
    local data = { targeting = {}, looting = self.raw and self.raw.looting or {} }
    for i = 1, #self.targeting do data.targeting[i] = self.targeting[i]._raw end
    self.loot:save(data.looting)
    local cfg = self.bot and self.bot.config
    if cfg and cfg.saveTargetbot and type(self.configName) == 'string' and #self.configName > 0 then
        return cfg:saveTargetbot(self.configName, data)
    end
    return data
end

function TB:getCurrentProfile()
    if self.bot and self.bot.configState then
        return self.bot:configState('targetbot_configs').selected
    end
    return self.configName
end

function TB:setCurrentProfile(name)
    if self.bot and self.bot.selectConfig then self.bot:selectConfig('targetbot_configs', name) end
    self:setOff()
    self:reload(name)
    self:setOn()
    return true
end

-- ---------------------------------------------------------------------------
-- lifecycle / the Config switch
-- ---------------------------------------------------------------------------
--- TargetBot.isOn() reads the Config WIDGET switch, not `targetbotMacro.enabled`
--- (VERIFIER "Additions"): onCreatureDisappear and onTextMessage gate on isOn() while the
--- macro gates on macro.enabled, and the two can disagree transiently.
function TB:isOn()
    if self.bot and self.bot.configState then
        return self.bot:configState('targetbot_configs').enabled == true
    end
    return self._on == true
end
function TB:isOff() return not self:isOn() end

function TB:setOn(v)
    if v == false then return self:setOff(true) end
    self._on = true
    if self.bot and self.bot.setConfigEnabled then
        self.bot:setConfigEnabled('targetbot_configs', true)
    end
    if self.macro then self.macro.setOn() end
    return true
end

function TB:setOff(v)
    if v == false then return self:setOn(true) end
    self._on = false
    if self.bot and self.bot.setConfigEnabled then
        self.bot:setConfigEnabled('targetbot_configs', false)
    end
    if self.macro then self.macro.setOff() end
    return true
end

TB.enable  = TB.setOn
TB.disable = TB.setOff

--- Register the 100 ms macro + the four event handlers.  BOT.md registration order is
--- healbot, attackbot, targetbot, cavebot, so the caller decides when this runs.
function TB:attach()
    if self._attached then return false end
    self._attached = true
    local b = self.bot
    if b and b.macro then
        -- vBot's TargetBot macro is UNNAMED (target.lua:49); bot/init.lua forces unnamed
        -- macros on at registration, and target.lua:149 then does setOn(enabled).  That is
        -- why the real profile_1.json carries the empty-string _macros key.
        self.macro = b:macro(targetbot.MACRO_PERIOD_MS, function() self:tick() end)
        if self:isOn() then self.macro.setOn() else self.macro.setOff() end
    end
    local bus = self.events
    if bus then
        self.handles = {
            busOn(bus, 'creatureDisappear', function(c) self:onCreatureDisappear(c) end),
            busOn(bus, 'containerOpen',     function(c) self.loot:onContainerOpen(c) end),
            busOn(bus, 'containerClose',    function(c) self.loot:onContainerClose(c) end),
            busOn(bus, 'textMessage',       function(m) self.loot:onTextMessage(m) end),
            busOn(bus, 'positionChange',    function(d) self:onPositionChange(d) end),
            busOn(bus, 'attackCancel',      function()  self:_setAttacking(nil) end),
        }
    end
    return true
end

function TB:detach()
    self._attached = false
    if self.handles and self.events then
        for i = 1, #self.handles do busOff(self.events, self.handles[i]) end
    end
    self.handles = nil
    if self.macro and self.macro.remove then self.macro.remove() end
    self.macro = nil
    return true
end

TB.onBotStart = function(self) if not self._attached then self:attach() end end
TB.onBotStop  = function(self) self:stopWalking() end

-- ---------------------------------------------------------------------------
-- public state (target.lua:181-265)
-- ---------------------------------------------------------------------------
function TB:now() return self._clock() end
function TB:isActive() return self.lastAction + targetbot.ACTIVE_WINDOW_MS > self:now() end
function TB:isCaveBotActionAllowed() return self.cavebotAllow > self:now() end
function TB:allowCaveBot(ms)
    self.cavebotAllow = self:now() + (ms or targetbot.CAVEBOT_ALLOW_MS)
    self.stats.lureAllowances = self.stats.lureAllowances + 1
    return self.cavebotAllow
end
function TB:Danger() return self.dangerValue end
TB.danger = TB.Danger
function TB:lootStatus() return self.loot:getStatus() end
function TB:getStatus() return self.statusText end
function TB:setStatus(s) self.statusText = s or '' end
function TB:delay(ms)
    self.delayUntil = self:now() + (ms or 0)
    if self.macro then self.macro.delay = self.delayUntil end
    return self.delayUntil
end
function TB:isDelayed() return self.delayUntil > self:now() end
function TB:canLure() return self.lureEnabled end
function TB:enableLuring()  self.lureEnabled = true  end
function TB:disableLuring() self.lureEnabled = false end
function TB:target()
    if not self.attackingId then return nil end
    return self.state.creatures[self.attackingId]
end

function TB:isInPz()
    local pl = self.state.player
    local s = pl and pl.states
    if type(s) ~= 'number' then return false end
    return floor(s / targetbot.PZ_STATE) % 2 == 1
end

--- storage.targetbotAvoidFloorChange ~= false -- default ON (walking.lua:16-18)
function TB:avoidFloorChangeEnabled()
    return self.storage.targetbotAvoidFloorChange ~= false
end

function TB:_once(key, fmt, ...)
    local now = self:now()
    local last = self._loggedOnce[key]
    if last and now - last < targetbot.AVOID_LOG_MS then return end
    self._loggedOnce[key] = now
    self.log.warn(fmt, ...)
end

-- ---------------------------------------------------------------------------
-- spectators.  g_map.getSpectatorsInRange walks z outer, y middle, x inner, ALL
-- ASCENDING (map.cpp:674-687) and that order IS the priority tie-break, so this cannot
-- delegate to world:spectators() (which iterates state.creatures with pairs()).
-- ---------------------------------------------------------------------------
function TB:spectatorsInRange(centre, r)
    local out, seen = {}, {}
    local st = self.state
    local last = self.lastPos
    for y = centre.y - r, centre.y + r do
        for x = centre.x - r, centre.x + r do
            local tile = st:tile({ x = x, y = y, z = centre.z })
            if tile then
                local things = tile.things
                for i = 1, #things do
                    local t = things[i]
                    if t.kind == 'creature' and t.creatureId and not seen[t.creatureId] then
                        local c = st.creatures[t.creatureId]
                        if c then
                            seen[t.creatureId] = true
                            out[#out + 1] = c
                            -- deviation (11): remember where we last saw it, because
                            -- game/state.lua clears creature.pos before the disappear event
                            -- fires and the looter needs the corpse tile.
                            last[t.creatureId] = { x = x, y = y, z = centre.z }
                        end
                    end
                end
            end
        end
    end
    return out
end

--- getMonsters(range) (vlib.lua:652): the FULL aware range, filtered by
--- distanceFromPlayer <= range, non-summon monsters only.
function TB:countMonstersWithin(range)
    local pl = self.state.player
    local pos = pl and pl.pos
    if not pos then return 0 end
    local n = 0
    local specs = self.world:spectators(pos, false)
    for i = 1, #specs do
        local c = specs[i]
        if c.isMonster and (self.oldTibia or (c.type or 1) < 3)
           and c.pos and cheb(c.pos, pos) <= range then
            n = n + 1
        end
    end
    return n
end

function TB:isFriend(name)
    local pl = self.storage and self.storage.playerList
    local list = type(pl) == 'table' and pl.friendList or nil
    if type(list) ~= 'table' then return false end
    for i = 1, #list do if list[i] == name then return true end end
    return false
end

--- getCreaturesInArea(posOrCreature, pattern, mode) (vlib.lua:1055-1078).  The pattern is
--- centred on the position with an INVALID direction (8), so directional cells never fire;
--- the local player is always excluded.  mode 1 = everyone, 2 = non-summon monsters,
--- anything else = players that are not friends.
function TB:countCreaturesInArea(centre, pattern, mode)
    local specs = self.world:spectatorsByPattern(centre, pattern, 8)
    local pl = self.state.player
    local myId = pl and pl.id
    local all, mons, plrs = 0, 0, 0
    for i = 1, #specs do
        local c = specs[i]
        if c.id ~= myId then
            all = all + 1
            if c.isMonster and (self.oldTibia or (c.type or 1) < 3) then
                mons = mons + 1
            elseif c.isPlayer and not self:isFriend(c.name) then
                plrs = plrs + 1
            end
        end
    end
    if mode == 1 then return all end
    if mode == 2 then return mons end
    return plrs
end

-- ---------------------------------------------------------------------------
-- config matching (creature.lua:53-72)
-- ---------------------------------------------------------------------------
function TB:getConfigs(c)
    local name = tostring(c.name or ''):gsub('^%s+', ''):gsub('%s+$', ''):lower()
    local hit = self.configsCache[name]
    if hit then return hit end
    local out = {}
    for i = 1, #self.targeting do
        local cfg = self.targeting[i]
        if targetbot.matchesName(name, cfg.regex) then out[#out + 1] = cfg end
    end
    if self.cached > 1000 then self.configsCache, self.cached = {}, 0 end
    self.configsCache[name] = out
    self.cached = self.cached + 1
    return out
end

-- ---------------------------------------------------------------------------
-- 2.2 scoring (creature_priority.lua, verbatim)
-- ---------------------------------------------------------------------------
--- INTEGRATION (bot/init.lua wiring): bot/attackbot.lua is a pure passenger on
--- `bot._attacking` (attackbot.lua:329), the field bot/api.lua's ctx.attack maintains.
--- TargetBot is the module that actually issues sender:attack, so every write of
--- attackingId must mirror into it or AttackBot never fires a single spell.
function TB:_setAttacking(id)
    self.attackingId = id
    if self.bot then self.bot._attacking = id end
end

--- HealBot's item-loop throttle is `TargetBot.isOn() and #TargetBot.Looting.getStatus() > 0`
--- (HealBot.lua:767-772, healbot.md:220).  bot/healbot.lua calls `tb:isLooting()`.
function TB:isLooting()
    if not self:isOn() then return false end
    local s = self.loot and self.loot:getStatus()
    return type(s) == 'string' and #s > 0
end

function TB:cancelAttack()
    if self.sender then self.sender:cancelAttackAndFollow() end
    self:_setAttacking(nil)
end

function TB:calculatePriority(c, cfg, pathLen)
    local priority = 0
    local isCurrent = (self.attackingId ~= nil and self.attackingId == c.id)

    -- 1. hysteresis
    if isCurrent then priority = priority + 1 end

    -- 2. range gate
    if pathLen > cfg.maxDistance then
        if cfg.rpSafe and isCurrent then self:cancelAttack() end
        return priority                          -- 0, or 1 while it is the current target
    end

    -- 3.
    priority = priority + (cfg.priority or 0)

    -- 4. distance bonus (mutually exclusive)
    if pathLen == 1 then priority = priority + 10
    elseif pathLen <= 3 then priority = priority + 5 end

    -- 5. diamond arrows.  VERIFIER: getCreaturesInArea excludes only the LOCAL PLAYER, so
    -- the target counts itself -> mobCount >= 1 -> a FLOOR of +4 on every match.
    if cfg.diamondArrows then
        priority = priority + self:countCreaturesInArea(c.pos, targetbot.DIAMOND_ARROW_AREA, 2) * 4
        if cfg.rpSafe
           and self:countCreaturesInArea(c.pos, targetbot.LARGE_RUNE_AREA, 3) > 0 then
            if isCurrent then self:cancelAttack() end
            return 0
        end
    end

    -- 6. low-HP bonus -- an if/ELSEIF chain: with chase=true a 15 % monster gets +5, never
    -- +2.5.  Independent ifs would change target selection.
    local hp = c.healthPercent or 100
    if cfg.chase and hp < 30 then priority = priority + 5
    elseif hp < 20 then priority = priority + 2.5
    elseif hp < 40 then priority = priority + 1.5
    elseif hp < 60 then priority = priority + 0.5
    elseif hp < 80 then priority = priority + 0.2 end

    return priority
end

--- calculateParams (creature.lua:74-93).  STRICT `>`: the FIRST config wins ties, so the
--- JSON array order is behaviour.  `danger` is only assigned when a config actually WINS
--- the contest -- the aggregate is not "sum of danger of all nearby monsters".
function TB:calculateParams(c, path)
    local pathLen = #path
    local priority, danger, sel = 0, 0, nil
    local cfgs = self:getConfigs(c)
    for i = 1, #cfgs do
        local cfg = cfgs[i]
        local p = self:calculatePriority(c, cfg, pathLen)
        if p > priority then
            priority = p
            danger   = cfg.danger                -- calculateDanger == config.danger
            sel      = cfg
        end
    end
    return { config = sel, creature = c, danger = danger, priority = priority }
end

-- ---------------------------------------------------------------------------
-- 3.8 the stepper (walking.lua:21-50)
-- ---------------------------------------------------------------------------
function TB:walkTo(dest, maxDist, params)
    self.dest, self.maxDist, self.params = dest, maxDist, params
    return true
end

function TB:stopWalking()
    self.dest, self.maxDist, self.params = nil, nil, nil
    if self.walker then self.walker:reset(true) end
end

--- deviation (5): a lost walk confirmation must not wedge the ledger forever.
function TB:_walkerStuck()
    if not self._stepAt then return false end
    local wk = self.walker
    local budget = wk:pingMs() + 2 * wk:stepDuration(wk.lastStepDir or 0)
                   + targetbot.WALK_WATCHDOG_PAD
    return (self:now() - self._stepAt) > budget
end

function TB:isWalking()
    local wk = self.walker
    if not wk:isWalking() then self._stepAt = nil; return false end
    if self:_walkerStuck() then
        self._once('walk-watchdog', '[TargetBot] walk confirmation timed out, resetting')
        wk:reset(true)
        self._stepAt = nil
        return false
    end
    return true
end

function TB:walk()
    local dest = self.dest
    if not dest then return end
    if self:isWalking() then return end               -- ONE confirmed step at a time
    local pl = self.state.player
    local pos = pl and pl.pos
    if not pos or pos.z ~= dest.z then return end
    local p = self.params or {}
    local dist = cheb(pos, dest)
    if p.precision and p.precision >= dist then return end
    if p.marginMin and p.marginMax and dist >= p.marginMin and dist <= p.marginMax then return end

    local dirs = self.path:getPath(pos, dest, self.maxDist, p)
    -- deviation (6): the `#dirs == 0` guard is an improvement over vBot's `walk(nil)`
    if not dirs or #dirs == 0 then return end

    if self:avoidFloorChangeEnabled() then
        local bad, why = self.world:wouldStepChangeFloor(pos, dirs[1], self.avoidIds)
        if bad then
            self:_once('avoid-floor-change',
                       '[TargetBot][AvoidFloorChange]: not stepping onto %s while chasing',
                       tostring(why))
            return
        end
    end

    local ok = self.walker:step(dirs[1])
    if ok then
        self.stats.steps = self.stats.steps + 1
        self._stepAt = self:now()
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- 3.3 spells / runes (dead in 4.8 -- fields never persisted -- but ported verbatim)
-- ---------------------------------------------------------------------------
function TB:say(text)
    if self.sender then return self.sender:talk(1, 0, nil, text) end
end

function TB:saySpell(text, delay)
    if type(text) ~= 'string' or #text < 1 then return end
    delay = delay or targetbot.SAY_SPELL_MS
    local now = self:now()
    -- VERIFIER: on protocol < 1090 the attack-spell clock is pushed BEFORE the rate check,
    -- i.e. on EVERY call, so merely calling saySpell starves attack spells.
    if self.clientVersion < 1090 then self.lastAttackSpell = now end
    if self.lastSpell + delay < now then
        self:say(text); self.lastSpell = now; return true
    end
    return false
end

function TB:sayAttackSpell(text, delay)
    if type(text) ~= 'string' or #text < 1 then return end
    delay = delay or targetbot.SAY_ATTACK_MS
    local now = self:now()
    if self.lastAttackSpell + delay < now then
        self:say(text); self.lastAttackSpell = now
        self.stats.spells = self.stats.spells + 1
        return true
    end
    return false
end

function TB:_useItemOn(itemId, subType, creature, delay, clockField)
    delay = delay or targetbot.USE_ATTACK_MS
    local now = self:now()
    if self[clockField] + delay < now then
        local it = self.client.items
        local isFluid = it and it.isFluidContainer and it.isFluidContainer(itemId)
        if not isFluid then
            -- VERIFIER: below 860 the subType is forced to 1, not left alone.
            subType = (self.clientVersion >= 860) and 0 or 1
        end
        if self.sender then
            self.sender:useOnCreature(HOTKEY_POS, itemId, 0, creature.id)
        end
        self[clockField] = now
        self.stats.runes = self.stats.runes + 1
    end
    -- returns nil, exactly like vBot: the callers' `if ... then return end` never fires.
end

function TB:useItem(itemId, subType, creature, delay)
    return self:_useItemOn(itemId, subType, creature, delay or targetbot.USE_ITEM_MS,
                           'lastItemUse')
end
function TB:useAttackItem(itemId, subType, creature, delay)
    return self:_useItemOn(itemId, subType, creature, delay or targetbot.USE_ATTACK_MS,
                           'lastRuneAttack')
end

-- ---------------------------------------------------------------------------
-- 3.1-3.3 attack (creature_attack.lua:50-113)
-- ---------------------------------------------------------------------------
local function countGroup(self, centre, radius, cfg)
    local specs = self:spectatorsInRange(centre, radius or 0)
    local myId = self.state.player and self.state.player.id
    local playersAround, monsters = false, 0
    for i = 1, #specs do
        local c = specs[i]
        -- VERIFIER: `shield <= 2` is the set that COUNTS as playersAround; what
        -- groupAttackIgnoreParty excludes is shield >= 3, i.e. real party members.
        if c.id ~= myId and c.isPlayer
           and (not cfg.groupAttackIgnoreParty or (c.shield or 0) <= 2) then
            playersAround = true
        elseif c.isMonster then
            monsters = monsters + 1
        end
    end
    return monsters, playersAround
end

function TB:attack(params, targets, isLooting)
    local cfg, c = params.config, params.creature

    -- VERIFIER: vBot tests the SERVER-confirmed attack state, so a server-side clear makes
    -- it re-send on the next tick.  We track the id and clear it on attackCancel /
    -- creatureDisappear (deviation 2).
    if self.attackingId ~= c.id then
        if self.sender then self.sender:attack(c.id) end
        self:_setAttacking(c.id)
        self.stats.attacks = self.stats.attacks + 1
    end

    if not isLooting then                       -- chase movement is suppressed while looting
        local r = self:creatureWalk(c, cfg, targets)
        if r == 'abort' then return 'abort' end
    end

    local pl = self.state.player
    local mana = (pl and pl.mana) or 0
    local pos = pl and pl.pos

    -- 1. group attack spell
    if cfg.useGroupAttack and type(cfg.groupAttackSpell) == 'string'
       and #cfg.groupAttackSpell > 1 and mana > (cfg.minManaGroup or 0) and pos then
        local monsters, playersAround = countGroup(self, pos, cfg.groupAttackRadius, cfg)
        if monsters >= (cfg.groupAttackTargets or 0)
           and (not playersAround or cfg.groupAttackIgnorePlayers) then
            if self:sayAttackSpell(cfg.groupAttackSpell, cfg.groupAttackDelay) then return end
        end
    end

    -- 2. group attack rune (the box is centred on the TARGET)
    if cfg.useGroupAttackRune and (cfg.groupAttackRune or 0) > 100 and c.pos then
        local monsters, playersAround = countGroup(self, c.pos, cfg.groupRuneAttackRadius, cfg)
        if monsters >= (cfg.groupRuneAttackTargets or 0)
           and (not playersAround or cfg.groupAttackIgnorePlayers) then
            -- returns nil -> never short-circuits, exactly like vBot
            if self:useAttackItem(cfg.groupAttackRune, 0, c, cfg.groupRuneAttackDelay) then
                return
            end
        end
    end

    -- 3. single attack spell
    if cfg.useSpellAttack and type(cfg.attackSpell) == 'string' and #cfg.attackSpell > 1
       and mana > (cfg.minMana or 0) then
        if self:sayAttackSpell(cfg.attackSpell, cfg.attackSpellDelay) then return end
    end

    -- 4. single attack rune
    if cfg.useRuneAttack and (cfg.attackRune or 0) > 100 then
        if self:useAttackItem(cfg.attackRune, 0, c, cfg.attackRuneDelay) then return end
    end
end

-- ---------------------------------------------------------------------------
-- 3.4 movement (creature_attack.lua:115-233).  First `return` wins.
-- ---------------------------------------------------------------------------
--- storage.extras.killUnder -- deviation (3).
function TB:killUnder()
    local v = self.storage.extras.killUnder
    if type(v) == 'number' then return v, v end
    self:_once('killUnder', '[TargetBot] storage.extras.killUnder is absent; using 30 for '
               .. 'the lure guard and 0 for the chase/rePosition gates (vBot raises here)')
    return 30, 0                                   -- (lureGuardValue, strictValue)
end

function TB:nearTiles(pos)
    local out = {}
    for i = 1, #NEAR_DIRS do
        local d = NEAR_DIRS[i]
        local p = { x = pos.x - d[1], y = pos.y - d[2], z = pos.z }
        if self.state:tile(p) then out[#out + 1] = p end
    end
    return out
end

local function tileHasCreatures(tile)
    local things = tile.things
    for i = 1, #things do
        if things[i].kind == 'creature' then return true end
    end
    return false
end

--- getWalkableTilesCount (creature_attack.lua:10-20): `isWalkable()` (creatures DO block,
--- the C++ default) OR `hasCreatures()`.
function TB:walkableTilesCount(pos)
    local n = 0
    for _, p in ipairs(self:nearTiles(pos)) do
        local tile = self.state:tile(p)
        if tile and (self.world:isWalkable(tile, false) or tileHasCreatures(tile)) then
            n = n + 1
        end
    end
    return n
end

--- CaveBot.GoTo(target, 0) == CaveBot.walkTo(pos, 20, {ignoreCreatures=true, precision=0})
--- (new_cavebot_lib.lua:225; 0 is truthy so precision really is 0).  This is the CAVEBOT
--- walker: with CaveBot absent or off, the whole rePosition branch does nothing -- vBot
--- behaves identically.
function TB:cavebotGoTo(pos, precision)
    local cb = self.bot and self.bot.modules and self.bot.modules.cavebot
    self.lastGoTo = { pos = copyPos(pos), precision = precision or 0 }
    if not cb then return nil end
    if cb.GoTo then return cb:GoTo(pos, precision or 0) end
    if cb.walkTo then
        return cb:walkTo(pos, 20, { ignoreCreatures = true, precision = precision or 0 })
    end
    return nil
end

function TB:rePosition(minTiles)
    minTiles = minTiles or 8
    local now = self:now()
    if now - self.lastRePos < targetbot.REPOSITION_MS then return end
    local pos = self.state.player.pos
    local mine = self:walkableTilesCount(pos)
    if mine > minTiles then return end
    -- deviation (7): deterministic scan order, same strict `>` so the first best wins
    local best, target = 0, nil
    for _, p in ipairs(self:nearTiles(pos)) do
        local tile = self.state:tile(p)
        if tile and not tileHasCreatures(tile) and self.world:isWalkable(tile, false) then
            local v = self:walkableTilesCount(p)
            if v > best and v > mine then best, target = v, p end
        end
    end
    if target then
        self.lastRePos = now
        self.stats.repositions = self.stats.repositions + 1
        return self:cavebotGoTo(target, 0)
    end
end

function TB:creatureWalk(c, cfg, targets)
    local st = self.state
    local pl = st.player
    local pos = pl and pl.pos
    local cpos = c.pos
    if not (pos and cpos) then return end

    -- (a) trapped test
    local isTrapped = true
    for i = 1, #NEAR_DIRS do
        local d = NEAR_DIRS[i]
        local tile = st:tile({ x = pos.x - d[1], y = pos.y - d[2], z = pos.z })
        if tile and self.world:isWalkable(tile, false) then isTrapped = false end
    end

    -- (b) dynamic-lure latch.  VERIFIER: only the latch is inside the dynamicLure guard;
    -- the four fields onPlayerPositionChange reads are assigned UNCONDITIONALLY, and
    -- lureMax has its own guard.
    if cfg.lureMin and cfg.lureMax and cfg.dynamicLure then
        if cfg.lureMin >= targets then self.targetBotLure = true
        elseif targets >= cfg.lureMax then self.targetBotLure = false end
    end
    self.targetCount = targets
    self.delayValue  = cfg.lureDelay
    if cfg.lureMax then self.lureMax = cfg.lureMax end
    self.dynamicLureDelay = cfg.dynamicLureDelay
    self.delayFrom = cfg.delayFrom

    -- (c) close lure
    if cfg.closeLure and (cfg.closeLureAmount or 0) <= self:countMonstersWithin(1) then
        return self:allowCaveBot(targetbot.CAVEBOT_ALLOW_MS)
    end

    local lureGuard, killUnderStrict = self:killUnder()
    local hp = c.healthPercent or 100

    -- (d) luring
    if self:canLure() and (cfg.lure or cfg.lureCavebot or cfg.dynamicLure)
       and not (hp < lureGuard) and not isTrapped then
        if self.targetBotLure then
            self.anchorPos = nil
            return self:allowCaveBot(targetbot.CAVEBOT_ALLOW_MS)
        else
            if targets < (cfg.lureCount or 0) then
                if cfg.lureCavebot then
                    self.anchorPos = nil
                    return self:allowCaveBot(targetbot.CAVEBOT_ALLOW_MS)
                else
                    if self.path:getPath(pos, cpos, targetbot.LURE_PATH_MAX,
                                         { ignoreNonPathable = true, precision = 2 }) then
                        -- classic luring holds a 5-6 tile ring
                        return self:walkTo(cpos, targetbot.CHASE_PATH_MAX,
                                           { marginMin = targetbot.LURE_MARGIN_MIN,
                                             marginMax = targetbot.LURE_MARGIN_MAX,
                                             ignoreNonPathable = true })
                    end
                end
            end
        end
    end

    local cur = self.path:getPath(pos, cpos, targetbot.CHASE_PATH_MAX, CHASE_SCAN_PARAMS)
    if not cur then
        -- deviation (4)
        self.stats.aborts = self.stats.aborts + 1
        self:_once('no-chase-path', '[TargetBot] no path to %s within %d steps -- tick '
                   .. 'aborted (vBot raises on #nil here)',
                   tostring(c.name), targetbot.CHASE_PATH_MAX)
        return 'abort'
    end
    local curLen = #cur

    -- (e) rePosition
    if (not cfg.chase or curLen == 1) and not cfg.avoidAttacks and not cfg.keepDistance
       and cfg.rePosition and hp >= killUnderStrict then
        return self:rePosition(cfg.rePositionAmount or 6)
    end

    -- (f) chase
    if ((killUnderStrict > 1 and hp < killUnderStrict) or cfg.chase)
       and not cfg.keepDistance then
        if curLen > 1 then
            return self:walkTo(cpos, targetbot.CHASE_PATH_MAX,
                               { ignoreNonPathable = true, precision = 1 })
        end

    -- (g) keep distance
    elseif cfg.keepDistance then
        if not self.anchorPos or cheb(pos, self.anchorPos) > cfg.anchorRange then
            self.anchorPos = copyPos(pos)
        end
        -- the dead band is exactly {range, range+1}
        if curLen ~= cfg.keepDistanceRange and curLen ~= cfg.keepDistanceRange + 1 then
            local p = { ignoreNonPathable = true,
                        marginMin = cfg.keepDistanceRange,
                        marginMax = cfg.keepDistanceRange + 1 }
            if cfg.anchor and self.anchorPos
               and cheb(pos, self.anchorPos) <= cfg.anchorRange * 2 then
                p.maxDistanceFrom = { self.anchorPos, cfg.anchorRange }
            end
            return self:walkTo(cpos, targetbot.CHASE_PATH_MAX, p)
        end
    end

    -- (h) avoidAttacks / (i) faceMonster.  VERIFIER: these are `if / elseif`, i.e. MUTUALLY
    -- EXCLUSIVE -- with avoidAttacks on, the faceMonster block (and its turn() fallback) is
    -- never reached even when both candidates are blocked.
    local diffx, diffy = cpos.x - pos.x, cpos.y - pos.y
    if cfg.avoidAttacks then
        local cands = {}
        if abs(diffx) == 1 and diffy == 0 then
            cands = { { x = pos.x, y = pos.y - 1, z = pos.z },
                      { x = pos.x, y = pos.y + 1, z = pos.z } }
        elseif diffx == 0 and abs(diffy) == 1 then
            cands = { { x = pos.x - 1, y = pos.y, z = pos.z },
                      { x = pos.x + 1, y = pos.y, z = pos.z } }
        end
        for _, cand in ipairs(cands) do
            local tile = st:tile(cand)
            if tile and self.world:isWalkable(tile, false) then
                return self:walkTo(cand, 2, { ignoreNonPathable = true })
            end
        end
    elseif cfg.faceMonster then
        local cands = {}
        if diffx == 1 and diffy == 1 then
            cands = { { x = pos.x + 1, y = pos.y, z = pos.z },
                      { x = pos.x, y = pos.y - 1, z = pos.z } }
        elseif diffx == -1 and diffy == 1 then
            cands = { { x = pos.x - 1, y = pos.y, z = pos.z },
                      { x = pos.x, y = pos.y - 1, z = pos.z } }
        elseif diffx == -1 and diffy == -1 then
            cands = { { x = pos.x, y = pos.y - 1, z = pos.z },
                      { x = pos.x - 1, y = pos.y, z = pos.z } }
        elseif diffx == 1 and diffy == -1 then
            cands = { { x = pos.x, y = pos.y - 1, z = pos.z },
                      { x = pos.x + 1, y = pos.y, z = pos.z } }
        else
            local dir = pl.direction
            if     diffx ==  1 and dir ~= 1 then self:turn(1)
            elseif diffx == -1 and dir ~= 3 then self:turn(3)
            elseif diffy ==  1 and dir ~= 2 then self:turn(2)
            elseif diffy == -1 and dir ~= 0 then self:turn(0) end
        end
        for _, cand in ipairs(cands) do
            local tile = st:tile(cand)
            if tile and self.world:isWalkable(tile, false) then
                return self:walkTo(cand, 2, { ignoreNonPathable = true })
            end
        end
    end
end

function TB:turn(dir)
    if self.sender then return self.sender:turn(dir) end
end

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------
function TB:onCreatureDisappear(c)
    if not c then return end
    if self.attackingId == c.id then self:_setAttacking(nil) end
    local hint = self.lastPos[c.id]
    self.loot:onCreatureDisappear(c, hint)
    self.lastPos[c.id] = nil
end

--- creature_attack.lua:236-244 -- while pulling with enough monsters behind you, EVERY
--- player step costs CaveBot `lureDelay` ms.  `if not lureMax then return end` is dead
--- code (lureMax initialises to 0, which is truthy) and is reproduced as such.
function TB:onPositionChange()
    local cb = self.bot and self.bot.modules and self.bot.modules.cavebot
    if cb and cb.isOn and not cb:isOn() then return end
    if self:isOff() then return end
    if self.lureMax == nil then return end                     -- dead in vBot
    if self.storage.TargetBotDelayWhenPlayer then return end
    if not self.dynamicLureDelay then return end
    if self.targetCount < (self.delayFrom or self.lureMax / 2) then return end
    if not self.attackingId then return end
    local v = self.delayValue or 0
    self.lastLureDelay = v
    if cb and cb.delay then cb:delay(v) end
end

-- ---------------------------------------------------------------------------
-- THE TICK (target.lua:49-128)
-- ---------------------------------------------------------------------------
function TB:tick()
    if self:isOff() then return end
    local now = self:now()
    if self.delayUntil > now then return end
    local st = self.state
    local pl = st.player
    local pos = pl and pl.pos
    if not pos then return end
    self.stats.ticks = self.stats.ticks + 1

    -- 2.1 candidate gathering
    local specs = self:spectatorsInRange(pos, targetbot.CANDIDATE_RANGE)
    local monsterCount = 0
    for i = 1, #specs do if specs[i].isMonster then monsterCount = monsterCount + 1 end end
    local cands = specs
    if monsterCount > targetbot.CROWD_THRESHOLD then
        cands = self:spectatorsInRange(pos, targetbot.CANDIDATE_RANGE_2)
    end

    local highestPriority, highestParams = 0, nil
    local dangerLevel, targets = 0, 0
    for i = 1, #cands do
        local c = cands[i]
        local hppc = c.healthPercent
        if hppc and hppc > 0 and c.pos then
            -- the path is computed BEFORE the monster test, verbatim (target.lua:70-71)
            local path = self.path:getPath(pos, c.pos, targetbot.CANDIDATE_PATH,
                                           CANDIDATE_PARAMS)
            if c.isMonster and (self.oldTibia or (c.type or 1) < 3) and path then
                local params = self:calculateParams(c, path)
                dangerLevel = dangerLevel + params.danger
                if params.priority > 0 then
                    targets = targets + 1
                    if params.priority > highestPriority then     -- STRICT: first wins ties
                        highestPriority = params.priority
                        highestParams   = params
                    end
                end
            end
        end
    end

    -- reset walking
    self:walkTo(nil)

    -- looting runs BEFORE the attack decision; its walkTo is what the stepper executes
    local looting = self.loot:process(targets, dangerLevel)
    local lootingStatus = self.loot:getStatus()
    self.dangerValue = dangerLevel
    self.targets = targets
    self.lastParams = highestParams

    if highestParams and not self:isInPz() then
        local abort = self:attack(highestParams, targets, looting)
        if abort == 'abort' then return end            -- deviation (4): the tick died
        if #lootingStatus > 0 then
            self:setStatus('Attack & ' .. lootingStatus)
        elseif self.cavebotAllow > now then
            self:setStatus('Luring using CaveBot')
        elseif self.lureEnabled then
            self:setStatus('Attacking')
        else
            self:setStatus('Attacking (luring off)')
        end
        self:walk()
        self.lastAction = now
        return
    end

    if looting then
        self:walk()
        self.lastAction = now
    end
    if #lootingStatus > 0 then self:setStatus(lootingStatus) else self:setStatus('Waiting') end
end

-- ---------------------------------------------------------------------------
-- BOT.md status object
-- ---------------------------------------------------------------------------
function TB:status()
    local t = self:target()
    local tp = nil
    if t then
        local pl = self.state.player
        tp = { id = t.id, name = t.name, hpPercent = t.healthPercent,
               distance = (pl and pl.pos and t.pos) and cheb(pl.pos, t.pos) or nil }
    end
    return {
        on       = self:isOn(),
        config   = self.configName,
        entries  = #(self.targeting or {}),
        target   = tp,
        danger   = self.dangerValue,
        targets  = self.targets,
        status   = self.statusText,
        active   = self:isActive(),
        cavebotAllowed = self:isCaveBotActionAllowed(),
        luring   = self.lureEnabled,
        lureLatch = self.targetBotLure,
        looting  = self.loot:snapshot(),
        stats    = self.stats,
    }
end

targetbot.TB = TB
targetbot.cheb = cheb
targetbot.ENTRY_DEFAULTS = ENTRY_DEFAULTS
return targetbot
