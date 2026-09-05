--[[============================================================================
bot/attackbot.lua -- AttackBot (offensive spells and runes), ported from vBot 4.8.

Work item M1.  Behaviour source: docs/vbot/attackbot.md.  Its
"## VERIFIER (Corrections)" section OVERRIDES the spec body; every correction is
applied below with the citation inline.

    local ab = attackbot.new(bot [, cfgTree] [, opts])
    ab:enable()  ab:disable()  ab:isOn()
    ab:tick()                   -- one 50 ms pass
    ab:status()  ab:reload(cfgTree)
    ab:setActiveProfile(n)  ab:getActiveProfile()
    ab:setTarget(creatureOrId)  ab:target()

`cfgTree` is the decoded AttackBot.json (`{ currentBotProfile, AttackBot[5] }`);
omit it and the module loads it through `bot.config`.  The user's real file is
consumed UNCHANGED, missing keys and all -- profile 2 on disk genuinely has no
`ServerCooldown`, so the AB:1741-1757 migration defaults run on load.

------------------------------------------------------------------------------
THE SHAPE OF THE THING
------------------------------------------------------------------------------
One macro, registered as `macro(5, ...)` and therefore CLAMPED TO 50 ms
(functions/main.lua:37-39 -- every "5 ms tick" comment in AttackBot.lua is
wrong).  Each pass:

  global gates -> compass quadrant scan -> iterate attackTable IN ARRAY ORDER,
  return on the first entry that fires.

AttackBot NEVER selects a target: it is a passenger on whatever the client is
attacking (`bot._attacking`, which bot/api.lua's ctx.attack maintains and
TargetBot will write too).  With no target the whole tick returns.

Static data lives in data/attackpatterns1530.lua, extracted verbatim from
AttackBot.lua by tools/extract_vbot_data.lua: `spellPatterns[cat][id][1|2]`,
`monkDirPatterns[id][dir]`, the `posN/E/S/W` quadrant grids in both their knight
and non-knight variants, and WAVE_AUGMENTS.

------------------------------------------------------------------------------
DELIBERATE DEVIATIONS (each with a switch)
------------------------------------------------------------------------------
 1. DEAD / NOT-IN-GAME GATE (BOT.md).  vBot relies on the whole bot being torn
    down off-game; a headless worker must check.  Mandatory, no switch.
 2. THE FIVE SPELL OPTIMIZERS ARE OFF.  `opts.optimizers = true` is required
    before OptPenance/OptOutburst/OptTFB/OptThorns/OptGlacier in the JSON are
    honoured -- the work item requires the flag and requires it to default off.
    The real profile 1 on disk has three of them true, so this is load-bearing:
    with the flag off every optimized spell takes its legacy path, which the
    spec confirms always exists.
 3. `Kills` PASSES BY DEFAULT.  killsToRs() needs g_game.getUnjustifiedPoints();
    no 1530 opcode for it is parsed, and vBot has no guard at all (VERIFIER).
    We return a large number, keeping killsOk() true -- the common case.
    `opts.killsToRs = function() ... end` overrides.
 4. isSightClear FAILS OPEN exactly where bot/world.lua's item metadata is
    degraded, which is what vBot does when the g_map binding is missing
    (AB:1206-1210).  With a full item table it is the real Bresenham walk.
 5. PATTERN 8 (Large Beam) KEEPS ITS vBot BUG.  `isWave = (pattern == 2 or
    pattern == 7 or pattern >= 9)` excludes 8 (AB:3016), so Large Beam falls
    into the self-area branch where its letter grid counts zero (a position
    centre passes direction 8, disabling every letter cell) and it fires purely
    off the legacy quadrant `bestSide`.  `opts.fixLargeBeam = true` routes it
    through getWaveBestDir like pattern 7 instead.
 6. THE TWO MALFORMED UNION GRIDS ARE LEFT MALFORMED.  spellPatterns[4][13][1]
    is 3x4 and [14][2] / [16][2] are 7x6; Map::getSpectatorsByPattern logs an
    error and returns nothing for even dimensions, so our parser returning an
    empty spectator list is exact parity.  (13/14/16 only ever COUNT through
    monkDirPatterns, which are all odd.)
============================================================================]]

local bit    = require('bit')
local shared = require('bot.shared')
local world  = require('bot.world')

local band  = bit.band
local floor, abs, max = math.floor, math.abs, math.max

local ok_pat, PAT = pcall(require, 'data.attackpatterns1530')
if not ok_pat or type(PAT) ~= 'table' then
    PAT = { spellPatterns = { {}, {}, {}, {} }, monkDirPatterns = {},
            waveAugments = {}, quadrant = { knight = {}, other = {} } }
end

local attackbot = {}
local A = {}
A.__index = A

local PS = shared.PlayerStates
local USE_COOLDOWN_MS = shared.USE_COOLDOWN_MS

attackbot.PATTERNS = PAT

-- Direction spells go through getMonkBestDir (AB:2939-2954).
local MONK_DIR_PATTERNS = { [9] = true, [13] = true, [14] = true, [16] = true, [19] = true }

-- AB:1637-1652 defaults + AB:1741-1757 migration.
local function blankProfile(n)
    return { name = 'Profile #' .. n, enabled = false, attackTable = {},
             Rotate = false, Kills = false, KillsAmount = 1,
             CustomCooldown = false, ServerCooldown = true, Visible = true,
             pvpMode = false, PvpSafe = true, BlackListSafe = false,
             AntiRsRange = 5, RuneDelay = 50, RuneDelayEnabled = true,
             OptPenance = false, OptOutburst = false, OptTFB = false,
             OptThorns = false, OptGlacier = false }
end
attackbot.blankProfile = blankProfile

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
function attackbot.new(b, cfg, opts)
    if type(b) ~= 'table' then error('attackbot.new: bot instance required', 2) end
    opts = opts or {}

    local self = setmetatable({}, A)
    self.bot    = b
    self.state  = b.state
    self.sender = b.sender
    self.events = b.events
    self.log    = b.log or { info = function() end, warn = function() end,
                             error = function() end, debug = function() end }
    self.sh     = shared.attach(b, opts)
    self.opts   = opts

    -- bot/world.lua is the spectator / pattern / sight engine (BOT.md).
    self.world = opts.world or b.world
    if not self.world then
        local ok, w = pcall(world.new, b, {})
        self.world = ok and w or nil
        if self.world and not b.world then b.world = self.world end
    end

    self.enabled    = (opts.enabled ~= false)
    self.optimizers = opts.optimizers == true          -- deviation 2
    self.fixLargeBeam = opts.fixLargeBeam == true

    -- AB:842: `ek` is evaluated ONCE at chunk load, so the quadrant grids are
    -- frozen at the vocation the client reported then (VERIFIER addition).
    local p = self.state and self.state.player
    local voc = (p and p.vocation) or 0
    self.ek = (voc == 1 or voc == 11)
    self.quadrant = self.ek and PAT.quadrant.knight or PAT.quadrant.other

    self.runeDelayTimers = {}       -- [itemId] = absolute ms
    self.runeCooldowns   = {}       -- [itemId] = last fire ms  (CustomCooldown mode)
    self.suppressUntil   = 0        -- models executor.lua delay()
    self.lastSpell       = nil      -- { entry, what, dir, at }
    self.counts = { casts = 0, runes = 0, turns = 0, holds = 0 }

    self:reload(cfg)
    self:_hookEvents()
    self:_registerMacros()
    return self
end

-- ---------------------------------------------------------------------------
-- config
-- ---------------------------------------------------------------------------
--- AB:1635-1722 + the migration at :1734-1757.  VERIFIER: AntiRsRange is
--- migrated ONLY on the active profile, outside and before the 5-profile loop.
local function normalise(cfg)
    if type(cfg) ~= 'table' then cfg = {} end
    local list = cfg.AttackBot
    if type(list) ~= 'table' or type(list[1]) ~= 'table' or #list ~= 5 then
        list = {}
        for i = 1, 5 do list[i] = blankProfile(i) end
        cfg.AttackBot = list
    end
    local n = tonumber(cfg.currentBotProfile)
    if not n or n == 0 or n > 5 then cfg.currentBotProfile = 1 end

    -- AB:1734-1736 -- active profile only
    local act = list[cfg.currentBotProfile]
    if act and not act.AntiRsRange then act.AntiRsRange = 5 end

    -- AB:1741-1757 -- all five
    for i = 1, 5 do
        local p = list[i]
        if type(p.attackTable) ~= 'table' then p.attackTable = {} end
        if p.RuneDelay == nil then p.RuneDelay = 50 end
        if p.RuneDelayEnabled == nil then p.RuneDelayEnabled = true end
        if p.OptPenance  == nil then p.OptPenance  = false end
        if p.OptOutburst == nil then p.OptOutburst = false end
        if p.OptTFB      == nil then p.OptTFB      = false end
        if p.OptThorns   == nil then p.OptThorns   = false end
        if p.OptGlacier  == nil then p.OptGlacier  = false end
    end
    return cfg
end
attackbot.normalise = normalise

function A:reload(cfg)
    if cfg == nil and self.bot.config and self.bot.config.loadAttackBot then
        local loaded = self.bot.config:loadAttackBot()
        if type(loaded) == 'table' then cfg = loaded end
    end
    self.cfg = normalise(cfg)
    return self.cfg
end

function A:profile() return self.cfg.AttackBot[self.cfg.currentBotProfile] end
function A:getActiveProfile() return self.cfg.currentBotProfile end
function A:setActiveProfile(n)
    if type(n) ~= 'number' or n < 1 or n > 5 then
        error('[AttackBot] wrong profile parameter!', 2)
    end
    self.cfg.currentBotProfile = n
    local act = self.cfg.AttackBot[n]
    if act and not act.AntiRsRange then act.AntiRsRange = 5 end
    return n
end
function A:save()
    if self.bot.config and self.bot.config.saveAttackBot then
        return self.bot.config:saveAttackBot(self.cfg)
    end
    return nil, 'no config store'
end

function A:isOn()
    if not self.enabled then return false end
    local p = self:profile()
    return (p and p.enabled) and true or false
end
function A:enable()  self.enabled = true;  return self end
function A:disable() self.enabled = false; return self end

-- ---------------------------------------------------------------------------
-- player / world accessors
-- ---------------------------------------------------------------------------
function A:now() return self.bot.now or self.bot.clock() end
function A:player() return self.state and self.state.player or nil end
function A:ppos()  local p = self:player(); return p and p.pos or nil end

local function chebyshev(a, b) return max(abs(a.x - b.x), abs(a.y - b.y)) end
attackbot.distance = chebyshev

function A:distFromPlayer(p)
    local me = self:ppos()
    if not (me and p) then return math.huge end
    return chebyshev(me, p)
end

function A:manapercent()
    local p = self:player()
    if not p then return 100 end
    local mx = p.maxMana or 0
    if mx <= 1 then return 100 end
    return floor((p.mana or 0) * 100 / mx)
end

function A:hasCond(mask)
    local p = self:player()
    if not p then return false end
    local lo = p.statesLo
    if lo == nil then lo = (p.states or 0) % 4294967296 end
    return band(lo, mask) ~= 0
end
function A:isInPz() return self:hasCond(PS.Pz) end

function A:playable()
    local p = self:player()
    if not p then return false end
    if p.isDead then return false end
    if (p.maxHealth or 0) > 0 and (p.health or 0) <= 0 then return false end
    if not p.pos then return false end
    if self.bot.inGame == false then return false end
    return true
end

--- The AttackBot monster predicate: `isMonster() and getType() < 3`, i.e.
--- EXACTLY type 1 -- summons (3/4) are excluded.  game/state.lua's `isMonster`
--- includes them, so never use it here (attackbot.md Pitfalls).
local function isRealMonster(c) return c ~= nil and c.type == 1 end
attackbot.isRealMonster = isRealMonster

--- isPartyMember(): shield in {1,3,4,5,6,7,8,9,10} (gamelib/player.lua:621-626).
local PARTY_SHIELDS = { [1] = true, [3] = true, [4] = true, [5] = true, [6] = true,
                        [7] = true, [8] = true, [9] = true, [10] = true }
local function isPartyMember(c) return PARTY_SHIELDS[c.shield or 0] == true end
attackbot.isPartyMember = isPartyMember

function A:isNonPartyPlayer(c)
    if not c or not c.isPlayer then return false end
    local me = self:player()
    if me and c.id == me.id then return false end
    return not isPartyMember(c)
end

--- getSpectators() with no args: every known creature on the player's own floor
--- inside the aware-range box (functions/map.lua:8-37 -> map.h:166-169).
function A:onScreen()
    local st, out = self.state, {}
    local me = self:ppos()
    if not me then return out end
    for _, c in pairs(st.creatures) do
        if c.pos and c.pos.z == me.z and st:isAwareOf(c.pos) then out[#out + 1] = c end
    end
    return out
end

function A:spectatorsByPattern(centre, grid, dir)
    if not (self.world and centre and type(grid) == 'string') then return {} end
    return self.world:spectatorsByPattern(centre, grid, dir == nil and 8 or dir)
end

function A:isSightClear(a, b)
    if not self.world then return true end            -- fail open, like vBot
    return self.world:isSightClear(a, b)
end

-- ---------------------------------------------------------------------------
-- target
-- ---------------------------------------------------------------------------
function A:setTarget(c)
    local id = (type(c) == 'table') and c.id or c
    self.bot._attacking = id
    return id
end

--- target() -- VL:1002-1009.  A creature we no longer know about is no target.
function A:target()
    if self.opts.targetProvider then
        local ok, c = pcall(self.opts.targetProvider, self)
        if ok and c then
            if type(c) == 'number' then return self.state.creatures[c] end
            return c
        end
        return nil
    end
    local id = self.bot._attacking
    if not id then return nil end
    local c = self.state.creatures and self.state.creatures[id]
    if not c or not c.pos then return nil end
    return c
end

-- ---------------------------------------------------------------------------
-- name filter -- AB:1401-1409 / 2228-2229
-- `monsters` is `true` (any) or an array of ALREADY-LOWERCASED names.  vBot's
-- string.split does not trim, so " hydra" is stored with its leading space and
-- can never match -- a reimplementation that trims would match names vBot never
-- does, so we do NOT trim (VERIFIER).
-- ---------------------------------------------------------------------------
local function nameList(entry)
    local m = entry.monsters
    if m == true or m == nil or type(m) ~= 'table' then return {} end
    return m
end

local function inList(t, lowerName)
    if #t == 0 then return true end
    for i = 1, #t do if t[i] == lowerName then return true end end
    return false
end

-- ---------------------------------------------------------------------------
-- getMonstersInArea -- AB:2526-2576
-- ---------------------------------------------------------------------------
function A:getMonstersInArea(category, centre, grid, minHp, maxHp, safeGrid, names, sightFrom)
    local t = nameList({ monsters = names })
    local me = self:player()

    -- PVP-safe pre-check: ANY non-party player inside the safe grid vetoes.
    if safeGrid then
        local specs = self:spectatorsByPattern(centre, safeGrid, 8)
        for i = 1, #specs do
            if self:isNonPartyPlayer(specs[i]) then return 0 end
        end
    end

    if category == 1 or category == 3 or category == 4 then
        -- NON-AREA path: counts every matching monster ON SCREEN, with no
        -- spatial condition at all (attackbot.md Pitfalls).
        if category == 1 or category == 3 then
            local tg = self:target()
            if #t ~= 0 and not (tg and inList(t, tostring(tg.name or ''):lower())) then
                return 0
            end
        end
        local n = 0
        local specs = self:onScreen()
        for i = 1, #specs do
            local c = specs[i]
            local hp = c.healthPercent or 100
            if isRealMonster(c) and hp >= minHp and hp <= maxHp
               and inList(t, tostring(c.name or ''):lower()) then
                n = n + 1
            end
        end
        return n
    end

    -- AREA path (categories 2 and 5)
    local n = 0
    local specs = self:spectatorsByPattern(centre, grid, 8)
    for i = 1, #specs do
        local c = specs[i]
        local hp = c.healthPercent or 100
        if (not me or c.id ~= me.id) and isRealMonster(c)
           and hp >= minHp and hp <= maxHp
           and inList(t, tostring(c.name or ''):lower())
           and (not sightFrom or self:isSightClear(sightFrom, c.pos)) then
            n = n + 1
        end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- getBestTileByPattern -- AB:2580-2596
-- `tile:isWalkable()` with NO argument: creatures block.  Distance is strict < 4.
-- The safe pattern is evaluated centred on the CANDIDATE tile.
-- ---------------------------------------------------------------------------
function A:getBestTileByPattern(grid, minHp, maxHp, safeGrid, names)
    local st, w = self.state, self.world
    local me = self:ppos()
    if not (me and w) then return nil end
    local best = { amount = 0, pos = nil }
    for key, tile in pairs(st.map) do
        local p = tile.pos
        if not p then
            local x, y, z = tostring(key):match('^(-?%d+),(-?%d+),(-?%d+)$')
            if x then p = { x = tonumber(x), y = tonumber(y), z = tonumber(z) } end
        end
        if p and p.z == me.z and chebyshev(me, p) < 4
           and w:isWalkable(tile, false) and self:isSightClear(me, p) then
            local n = self:getMonstersInArea(2, p, grid, minHp, maxHp, safeGrid, names, p)
            if n > best.amount then best = { amount = n, pos = p } end   -- strict >, first wins
        end
    end
    return best.amount > 0 and best or nil
end

-- ---------------------------------------------------------------------------
-- direction scanners -- AB:1178-1345
-- ---------------------------------------------------------------------------
local DIR_LETTER = { [0] = 'N', [1] = 'E', [2] = 'S', [3] = 'W' }
local dirGridCache = {}

--- extractDirGrid(letterPattern, letter) -- AB:1178-1195: trim every non-empty
--- line and rewrite each character to "1" if it equals `letter`, else "0".
local function extractDirGrid(letterGrid, letter)
    local out = {}
    for line in tostring(letterGrid):gmatch('[^\n]+') do
        local trimmed = line:match('^%s*(.-)%s*$')
        if trimmed ~= '' then
            out[#out + 1] = (trimmed:gsub('.', function(ch)
                return ch == letter and '1' or '0'
            end))
        end
    end
    return '\n' .. table.concat(out, '\n') .. '\n'
end
attackbot.extractDirGrid = extractDirGrid

--- getWaveBestDir -- AB:1222-1276.  Tie-break keeps the CURRENT facing.
--- Returns bestCount, bestDir, counts (counts is 0-based over dirs 0..3).
function A:getWaveBestDir(letterGrid, minHp, maxHp, safeGrid, names)
    local zero = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }
    if type(letterGrid) ~= 'string' then return -1, 0, zero end
    local t = nameList({ monsters = names })
    local my = self:ppos()
    if not my then return -1, 0, zero end

    if safeGrid then
        local specs = self:spectatorsByPattern(my, safeGrid, 8)
        for i = 1, #specs do
            if self:isNonPartyPlayer(specs[i]) then return -1, 0, zero end
        end
    end

    local grids = dirGridCache[letterGrid]
    if not grids then
        grids = {}
        for d = 0, 3 do grids[d] = extractDirGrid(letterGrid, DIR_LETTER[d]) end
        dirGridCache[letterGrid] = grids
    end

    local me = self:player()
    local cur = (me and me.direction) or 0
    local bestCount, bestDir, counts = -1, 0, {}
    for d = 0, 3 do
        local n = 0
        local specs = self:spectatorsByPattern(my, grids[d], 8)
        for i = 1, #specs do
            local c = specs[i]
            local hp = c.healthPercent or 100
            if (not me or c.id ~= me.id) and isRealMonster(c)
               and hp >= minHp and hp <= maxHp
               and inList(t, tostring(c.name or ''):lower())
               and self:isSightClear(my, c.pos) then
                n = n + 1
            end
        end
        counts[d] = n
        if n > bestCount or (n == bestCount and d == cur) then bestCount, bestDir = n, d end
    end
    return bestCount, bestDir, counts
end

--- getMonkBestDir -- AB:1303-1345.  Reads monkDirPatterns directly (no letter
--- extraction) and evaluates the safe veto INSIDE the per-direction loop.
--- VERIFIER: on a veto every direction scores 0 and the function returns 0, not
--- the -1 getWaveBestDir returns.
function A:getMonkBestDir(patternId, minHp, maxHp, safeGrid, names)
    local t = nameList({ monsters = names })
    local my = self:ppos()
    if not my then return -1, 0 end
    local dirs = PAT.monkDirPatterns[patternId]
    if not dirs then return -1, 0 end
    local me = self:player()
    local cur = (me and me.direction) or 0
    local bestCount, bestDir = -1, 0
    for d = 0, 3 do
        local blocked = false
        if safeGrid then
            local specs = self:spectatorsByPattern(my, safeGrid, 8)
            for i = 1, #specs do
                if self:isNonPartyPlayer(specs[i]) then blocked = true; break end
            end
        end
        local n = 0
        if not blocked then
            local specs = self:spectatorsByPattern(my, dirs[d], 8)
            for i = 1, #specs do
                local c = specs[i]
                local hp = c.healthPercent or 100
                if (not me or c.id ~= me.id) and isRealMonster(c)
                   and hp >= minHp and hp <= maxHp
                   and inList(t, tostring(c.name or ''):lower())
                   and self:isSightClear(my, c.pos) then
                    n = n + 1
                end
            end
        end
        if n > bestCount or (n == bestCount and d == cur) then bestCount, bestDir = n, d end
    end
    return bestCount, bestDir
end

--- getDirectionToPos -- AB:1350-1360.
function A:directionToPos(from, to)
    local dx, dy = to.x - from.x, to.y - from.y
    if dx == 0 and dy == 0 then
        local me = self:player(); return (me and me.direction) or 0
    end
    if abs(dx) >= abs(dy) then return dx > 0 and 1 or 3 end
    return dy > 0 and 2 or 0
end

-- ---------------------------------------------------------------------------
-- profile guards -- AB:1571-1578 / VL:667-696
-- ---------------------------------------------------------------------------
function A:countGate(entry, n)
    if entry.orMore then return n >= entry.count end
    return n == entry.count                              -- orMore nil => EXACT count
end

--- getPlayers(range) -- VL:667-674.  VERIFIER: a ShieldWhiteYellow (=1) party
--- member IS counted, because the predicate is `spec:getShield() ~= 1 and
--- spec:isPartyMember()`.
function A:countPlayersNear(range)
    local me = self:player()
    local specs, n = self:onScreen(), 0
    for i = 1, #specs do
        local c = specs[i]
        if c.isPlayer and (not me or c.id ~= me.id)
           and self:distFromPlayer(c.pos) <= range
           and not (((c.shield or 0) ~= 1 and isPartyMember(c)) or (c.emblem or 0) == 1) then
            n = n + 1
        end
    end
    return n
end

--- isBlackListedPlayerInRange(range) -- VL:676-696.  Multi-floor (|dz| <= 2),
--- Chebyshev STRICTLY <, CASE-SENSITIVE name compare, empty list => falsy,
--- nil range => 10.
function A:blacklistedPlayerInRange(range)
    local list = self.opts.blackList
    if list == nil then
        local s = self.bot.storage
        list = s and s.playerList and s.playerList.blackList
    end
    if type(list) ~= 'table' or #list == 0 then return nil end
    if not range then range = 10 end
    local me = self:player()
    local mp = me and me.pos
    if not mp then return false end
    for _, c in pairs(self.state.creatures) do
        if c.isPlayer and c.pos and abs(c.pos.z - mp.z) <= 2 then
            local flat = { x = c.pos.x, y = c.pos.y, z = mp.z }
            if chebyshev(mp, flat) < range then
                for i = 1, #list do
                    if list[i] == c.name then return true end     -- case-sensitive
                end
            end
        end
    end
    return false
end

--- killsToRs() -- VL:223-228.  See deviation 3.
function A:killsToRs()
    if self.opts.killsToRs then
        local ok, v = pcall(self.opts.killsToRs, self)
        if ok and type(v) == 'number' then return v end
    end
    return math.huge
end

function A:guardsPass()
    local p = self:profile()
    if p.BlackListSafe and self:blacklistedPlayerInRange(p.AntiRsRange) then return false end
    if p.Kills and self:killsToRs() <= (p.KillsAmount or 1) then return false end
    return true
end

--- nonPartyPlayerNear(centre, r) -- AB:1475-1483.
function A:nonPartyPlayerNear(centre, r)
    local specs = self:onScreen()
    for i = 1, #specs do
        local c = specs[i]
        if self:isNonPartyPlayer(c) and c.pos and chebyshev(centre, c.pos) <= r then
            return true
        end
    end
    return false
end

--- isBuffed() -- VL:188-203.  VERIFIER: the scan seeds skillId = 0 (Fist) as the
--- incumbent, so the candidate set is skills 0..4 and Fist wins when no other
--- base level exceeds it.
function A:isBuffed()
    if not self:hasCond(PS.PartyBuff) then return false end
    local p = self:player()
    local skills = (p and p.skills) or {}
    local function lvl(i)  local s = skills[i]; return (s and s.level) or 0 end
    local function base(i) local s = skills[i]; return (s and s.baseLevel) or 0 end
    local id = 0
    for i = 1, 4 do if base(i) > base(id) then id = i end end
    local premium = lvl(id) - base(id)
    return (premium / 100) * 305 > base(id)
end

-- ---------------------------------------------------------------------------
-- readiness
-- ---------------------------------------------------------------------------
--- attackSpellCooldownReady -- AB:2612-2630.  VERIFIER: ALL THREE returns go
--- through canCast with ignoreRL = false, so the level/mana requirement is
--- always enforced for a formula the spell DB knows.
function A:attackSpellCooldownReady(words)
    local p, sh = self:profile(), self.sh
    if not p.ServerCooldown then return sh:canCast(words, false, true) end
    local rem = sh:realSpellRemaining(words)
    if rem == nil then return sh:canCast(words, false, false) end
    if rem <= sh:rawPing() then return sh:canCast(words, false, true) end
    return false
end

--- runeDelayGate(itemId) -- AB:2681-2705.
function A:runeDelayGate(itemId)
    local p, sh = self:profile(), self.sh
    if not p.RuneDelayEnabled then self.runeDelayTimers[itemId] = nil; return true end
    local d = self.runeDelayTimers[itemId]
    if not d then
        d = self:now() + max(0, (p.RuneDelay or 0) - sh:pingCompensation())
        self.runeDelayTimers[itemId] = d
    end
    sh.attackBotFiringUntil = d + 10          -- reserve the slot for the whole wait
    if self:now() < d then return false end
    self.runeDelayTimers[itemId] = nil
    return true
end

-- ---------------------------------------------------------------------------
-- sends
-- ---------------------------------------------------------------------------
--- executeAttackBotAction(category, idOrFormula, cooldown) -- AB:2632-2643.
function A:fireEntry(entry, executeCooldown)
    local cat = entry.category
    if cat == 1 or cat == 4 or cat == 5 then
        self.counts.casts = self.counts.casts + 1
        self.lastSpell = { spell = entry.spell, category = cat, at = self:now() }
        return self.sh:cast(entry.spell, executeCooldown)
    elseif cat == 3 then
        local tg = self:target()
        if not tg then return nil end
        self.counts.runes = self.counts.runes + 1
        self.lastSpell = { rune = entry.itemId, category = cat, at = self:now() }
        self.sh:recordLocalUseCooldown()
        return self.sh:useOnCreature(entry.itemId, tg.id)
    end
    return nil
end

--- autoTurnAndFire(neededDir, fireFn) -- AB:2655-2672.  The C++ client updates
--- the local direction immediately, so the cast goes out with the new facing
--- already applied: turn packet first, cast packet second, same tick, no delay.
function A:autoTurnAndFire(neededDir, fireFn)
    local me = self:player()
    if me and me.direction == neededDir then fireFn(); return true end
    if self:profile().Rotate then
        if self.sender and self.sender.turn then self.sender:turn(neededDir) end
        if me then me.direction = neededDir end
        self.counts.turns = self.counts.turns + 1
        self.lastTurn = neededDir
        fireFn()
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- optimizers (deviation 2) -- OFF unless opts.optimizers
-- ---------------------------------------------------------------------------
--- Returns handled, fired.  With the flag off nothing is ever handled, so every
--- entry takes its legacy path -- which the spec confirms always exists.
function A:tryOptimizedSpell(entry, executeCooldown)
    if not self.optimizers then return false, false end
    if self.opts.optimizerHook then
        local ok, handled, fired = pcall(self.opts.optimizerHook, self, entry, executeCooldown)
        if ok then return handled and true or false, fired and true or false end
    end
    return false, false
end

-- ===========================================================================
-- MAIN TICK -- AB:2708-3106
-- ===========================================================================
function A:tick()
    if not self:isOn() or not self:playable() then return end
    local p, sh = self:profile(), self.sh
    local T = self:now()
    if T < self.suppressUntil then return end                   -- executor delay()

    -- ---- global gates, in order (AB:2708-2733) -------------------------------
    if #p.attackTable == 0 then return end
    if self:isInPz() then return end
    local tg = self:target(); if not tg then return end
    if p.Training and tostring(tg.name or ''):lower():find('training', 1, true) then return end
    if not p.CustomCooldown and not p.ServerCooldown then
        self.suppressUntil = T + 400
    end

    -- ---- compass quadrant scan (AB:2735-2759).  Only `bestSide` is consumed,
    -- and only by pattern 8; `bestDir` is computed and never used in vBot.
    local me = self:ppos()
    local q, bestSide = {}, 0
    for d = 0, 3 do
        local n = 0
        local specs = self:spectatorsByPattern(me, self.quadrant[d], 8)
        for i = 1, #specs do
            local c = specs[i]
            if c.id ~= self:player().id and isRealMonster(c) then n = n + 1 end
        end
        q[d] = n
        if n > bestSide then bestSide = n end
    end
    self.bestSide = bestSide

    -- ---- entries, ARRAY ORDER == PRIORITY (AB:2783) --------------------------
    for idx = 1, #p.attackTable do
        local entry = p.attackTable[idx]
        local r = self:_runEntry(entry, tg, bestSide)
        if r == 'fired' or r == 'hold' then return r end
    end
end

--- One entry.  Returns 'fired' (a packet went out, stop the tick), 'hold' (the
--- tick is consumed without firing -- the rune-ready / shared-slot rule), or nil
--- (fall through to the next entry).
function A:_runEntry(entry, tg, bestSide)
    local p, sh = self:profile(), self.sh
    local T = self:now()
    local isRune = (entry.itemId or 0) > 100

    if not entry.enabled then return nil end
    if self:manapercent() < (entry.mana or 0) then return nil end

    -- VERIFIER: the nil guard is real -- every pre-2024 saved entry lacks
    -- `harmony`, and three entries in the on-disk profile 1 lack `augmented`.
    if entry.harmony and entry.harmony > 0
       and ((self:player().harmony or 0) < entry.harmony) then
        if isRune then self.runeDelayTimers[entry.itemId] = nil end
        return nil
    end

    -- entry.cooldown is MILLISECONDS on the spell path and SECONDS on the rune
    -- path (AB:2794 vs AB:2847).  ServerCooldown's 30 is < 100, so cast()
    -- degenerates to a plain say and the real gating is the readiness check.
    local executeCooldown = (p.CustomCooldown and entry.cooldown)
                         or (p.ServerCooldown and 30)
                         or 0

    -- ---- readiness ----------------------------------------------------------
    local canUse, runeReady = false, false
    if not isRune then
        canUse = self:attackSpellCooldownReady(entry.spell) and true or false
    else
        local useClear = sh:getMultiUseCooldown() <= 0
        local visOk = (not p.Visible) or sh:hasItemAvailable(entry.itemId)
        if p.ServerCooldown then
            local gr = sh:realGroupRemaining(1)                  -- group 1 == Attack
            if gr then
                local readyAt = T + gr
                if T >= readyAt - USE_COOLDOWN_MS then
                    sh.attackBotFiringUntil = max(sh.attackBotFiringUntil, readyAt + 150)
                end
                runeReady = (gr <= sh:rawPing()) and visOk
            else
                runeReady = (not sh:groupCooldownActive(1)) and visOk
            end
        elseif p.CustomCooldown then
            local readyAt = (self.runeCooldowns[entry.itemId] or 0)
                          + (entry.cooldown or 0) * 1000 - sh:pingCompensation()
            if T >= readyAt - USE_COOLDOWN_MS then
                sh.attackBotFiringUntil = max(sh.attackBotFiringUntil, readyAt + 150)
            end
            runeReady = (T >= readyAt) and visOk
        else
            runeReady = visOk
        end
        canUse = runeReady and useClear
        if runeReady then sh.attackBotRuneReadyUntil = T + 250 end
    end

    if not canUse then
        -- AB:3093-3101: a rune whose own cooldown is clear but which is waiting
        -- on the shared 1 s slot HOLDS THE WHOLE TICK, so a lower-priority entry
        -- cannot steal the slot.  Spells simply fall through.
        if isRune then
            self.runeDelayTimers[entry.itemId] = nil
            if runeReady then self.counts.holds = self.counts.holds + 1; return 'hold' end
        end
        return nil
    end

    -- ---- PvP mode short-circuit (AB:2896-2907) ------------------------------
    -- No count check, no name filter, no pattern, no BlackList/Kills guard.
    -- canShoot() here is the no-argument form: sight only, no distance limit.
    if p.pvpMode then
        local hp = tg.healthPercent or 100
        if hp >= (entry.minHp or 0) and hp <= (entry.maxHp or 100)
           and self:isSightClear(self:ppos(), tg.pos) then
            if entry.category == 2 then
                self.log.warn('[AttackBot] Area Runes cannot be used in PVP situation!')
                return 'hold'
            end
            if isRune then
                if not self:runeDelayGate(entry.itemId) then return 'hold' end
                if p.CustomCooldown then self.runeCooldowns[entry.itemId] = T end
                sh.attackBotFiringUntil = T + 150
            end
            self:fireEntry(entry, executeCooldown)
            return 'fired'
        end
    end

    -- ---- optimizers (off by default) ---------------------------------------
    local handled, fired = self:tryOptimizedSpell(entry, executeCooldown)
    if fired then return 'fired' end
    if handled then return nil end

    return self:_dispatch(entry, tg, bestSide, executeCooldown, isRune)
end

-- ---------------------------------------------------------------------------
-- the legacy per-category dispatch -- AB:2915-3090
-- ---------------------------------------------------------------------------
function A:_dispatch(entry, tg, bestSide, executeCooldown, isRune)
    local p, sh = self:profile(), self.sh
    local T = self:now()
    local cat = entry.category
    local minHp, maxHp = entry.minHp or 0, entry.maxHp or 100
    local fire = function() self:fireEntry(entry, executeCooldown) end

    -- ---- category 4: Empowerment (AB:2915-2919).  No BlackList/Kills guard. --
    if cat == 4 then
        if self:isBuffed() then return nil end
        local n = self:getMonstersInArea(4, nil, nil, minHp, maxHp, false, entry.monsters)
        if self:countGate(entry, n) and self:distFromPlayer(tg.pos) <= entry.pattern then
            fire(); return 'fired'
        end
        return nil
    end

    -- ---- categories 1 / 3: targeted spell / targeted rune (AB:2921-2930) ----
    if cat == 1 or cat == 3 then
        local n = self:getMonstersInArea(cat, nil, nil, minHp, maxHp, false, entry.monsters)
        if self:countGate(entry, n) and self:distFromPlayer(tg.pos) <= entry.pattern then
            if isRune then
                if not self:runeDelayGate(entry.itemId) then return 'hold' end
                if p.CustomCooldown then self.runeCooldowns[entry.itemId] = T end
                sh.attackBotFiringUntil = T + 150
            end
            fire(); return 'fired'
        end
        return nil
    end

    -- ---- category 5: Absolute (AB:2932-3070) --------------------------------
    if cat == 5 then
        local pCat = entry.patternCategory or 4
        local pat = entry.pattern
        if entry.augmented then
            pat = PAT.waveAugments[tostring(entry.spell or ''):lower()] or pat
        end
        local grids = (PAT.spellPatterns[pCat] or {})[pat]
        if not grids then return nil end
        local safe = (p.PvpSafe and grids[2]) or false

        -- (a) direction spells, through getMonkBestDir
        if MONK_DIR_PATTERNS[pat] then
            local n, d = self:getMonkBestDir(pat, minHp, maxHp, safe, entry.monsters)
            if self:countGate(entry, n) and self:guardsPass() then
                if self:autoTurnAndFire(d, fire) then return 'fired' end
            end
            return nil
        end

        -- (b) Thousand Fist Blows: the area is centred on the TARGET.
        --     No BlackList/Kills guard on this sub-path.
        if pat == 15 then
            local tp = tg.pos
            if not tp then return nil end
            if safe then
                local specs = self:spectatorsByPattern(tp, safe, 8)
                for i = 1, #specs do
                    if self:isNonPartyPlayer(specs[i]) then return 'hold' end
                end
            end
            local n = self:getMonstersInArea(5, tp, grids[1], minHp, maxHp, false,
                                             entry.monsters, tp)
            if self:countGate(entry, n) and self:distFromPlayer(tp) <= 5 then
                if self:autoTurnAndFire(self:directionToPos(self:ppos(), tp), fire) then
                    return 'fired'
                end
            end
            return nil
        end

        -- (c) chain spells with the optimizer off (AB:2978-3006)
        if pat == 17 or pat == 18 then
            if self:distFromPlayer(tg.pos) <= 3
               and not (p.PvpSafe and self:nonPartyPlayerNear(self:ppos(), 8)) then
                local t, n = nameList(entry), 0
                local specs = self:onScreen()
                for i = 1, #specs do
                    local c = specs[i]
                    local hp = c.healthPercent or 100
                    if isRealMonster(c) and hp >= minHp and hp <= maxHp
                       and inList(t, tostring(c.name or ''):lower())
                       and self:distFromPlayer(c.pos) <= 5 then          -- 3 + one 2-sqm jump
                        n = n + 1
                    end
                end
                if self:countGate(entry, n) and self:guardsPass() then fire(); return 'fired' end
            end
            return nil
        end

        -- (d) waves and beams.  Pattern 8 is EXCLUDED by vBot (deviation 5).
        local isWave = (pat == 2 or pat == 7 or pat >= 9)
        if self.fixLargeBeam and pat == 8 then isWave = true end
        if isWave then
            local wc, wd, counts = self:getWaveBestDir(grids[1], minHp, maxHp, safe,
                                                       entry.monsters)
            local me = self:player()
            local facing = counts[(me and me.direction) or 0] or 0
            if self:countGate(entry, facing) then
                if self:guardsPass() then fire(); return 'fired' end
            elseif self:countGate(entry, wc) and p.Rotate and self:guardsPass() then
                local blocked = false
                if safe then
                    local specs = self:spectatorsByPattern(self:ppos(), safe, 8)
                    for i = 1, #specs do
                        if self:isNonPartyPlayer(specs[i]) then blocked = true; break end
                    end
                end
                if not blocked and self:autoTurnAndFire(wd, fire) then return 'fired' end
            end
            return nil
        end

        -- (e) self-centred areas {1,3,4,5,6} plus pattern 8 (AB:3062-3068)
        local me = self:ppos()
        local n = self:getMonstersInArea(5, me, grids[1], minHp, maxHp, safe,
                                         entry.monsters, me)
        local ok
        if pat == 8 then
            ok = bestSide >= entry.count and ((not p.PvpSafe) or self:countPlayersNear(2) == 0)
        else
            ok = self:countGate(entry, n)
        end
        if ok and self:guardsPass() then fire(); return 'fired' end
        return nil
    end

    -- ---- category 2: area rune (AB:3072-3090) -------------------------------
    if cat == 2 then
        local grids = (PAT.spellPatterns[entry.patternCategory or 2] or {})[entry.pattern]
        if not grids then return nil end
        local safe = (p.PvpSafe and grids[2]) or false
        local data = self:getBestTileByPattern(grids[1], minHp, maxHp, safe, entry.monsters)
        if data and self:countGate(entry, data.amount) and self:guardsPass() then
            if not self:runeDelayGate(entry.itemId) then return 'hold' end
            if p.CustomCooldown then self.runeCooldowns[entry.itemId] = T end
            sh.attackBotFiringUntil = T + 400
            sh:recordLocalUseCooldown()                 -- the shared slot starts NOW
            local tile = self.state:tile(data.pos)
            local thing = self.world and self.world:getTopUseThing(tile) or (tile and tile.things[1])
            local stack = 0
            if tile and thing then
                for i = 1, #tile.things do
                    if tile.things[i] == thing then stack = i - 1; break end
                end
            end
            self.counts.runes = self.counts.runes + 1
            self.lastSpell = { rune = entry.itemId, category = 2, pos = data.pos,
                               amount = data.amount, at = T }
            self.sh:useOnThing(entry.itemId, data.pos, thing and thing.id or 0, stack)
            return 'fired'
        end
        return nil
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------
function A:_hookEvents()
    local ev = self.events
    if not ev then return end
    shared.evOn(ev, 'attackCancel', function() self.bot._attacking = nil end)
    shared.evOn(ev, 'creatureDisappear', function(d)
        local id = d and (d.id or (d.creature and d.creature.id))
        if id and self.bot._attacking == id then self.bot._attacking = nil end
    end)
end

function A:_registerMacros()
    local b = self.bot
    if not b.macro then return end
    -- macro(5, ...) -- clamped to 50 ms by the runtime, exactly like vBot.
    self.macros = { b:macro(5, function() self:tick() end) }
    return self.macros
end

-- ---------------------------------------------------------------------------
-- status (BOT.md)
-- ---------------------------------------------------------------------------
function A:status()
    local p = self:profile()
    local tg = self:target()
    return {
        on        = self:isOn(),
        module    = self.enabled,
        profile   = self.cfg.currentBotProfile,
        profileName = p and p.name,
        entries   = p and #p.attackTable or 0,
        lastSpell = self.lastSpell,
        counts    = self.counts,
        optimizers = self.optimizers,
        target    = tg and { id = tg.id, name = tg.name,
                             hpPercent = tg.healthPercent,
                             distance = tg.pos and self:distFromPlayer(tg.pos) or nil } or nil,
        firingUntil   = self.sh.attackBotFiringUntil,
        runeReadyUntil = self.sh.attackBotRuneReadyUntil,
        useSlotMs = self.sh:getMultiUseCooldown(),
    }
end

attackbot.A = A
return attackbot
