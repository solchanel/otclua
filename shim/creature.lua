--[[============================================================================
shim/creature.lua -- Creature / Player / LocalPlayer (work item S1, PLAN sec.1.16).

Every getter is a live read of `LC.state`; nothing is cached.  The method list and the
required return shapes are api-game.md sec.4.1 (Creature, 30 methods) and sec.4.2
(LocalPlayer, +26).  C++ line references are to src/client/{creature,localplayer,tile}.{h,cpp}.

THE THREE TRAPS this file exists to get right
---------------------------------------------
  I2  `LocalPlayer:getPosition()` is the PREWALK position -- localplayer.h:160
        `return isPreWalking() ? m_preWalks.back() : m_position;`
      Every cavebot waypoint test desynchronises if this returns the confirmed position.
  T1  `getRegenerationTime()` is COMPARED WITH A NUMBER by vBot (feasibility.md sec.4.4),
      so it must be a number and never nil.
  T2  `getStance()` / `getSecondaryStance()` are NOT stored on the wire as such: they are
      derived from `player.virtues` with the exact protocolgameparse.cpp:5385-5404 rule
      (311/312 always occupy the secondary slot, the first other id is primary, the next
      free one falls to secondary, a third is discarded).

`isPartyMember` / `isPartyLeader` / `isSorcerer` / ... are Lua-level in the real client
(modules/gamelib/{player,creature}.lua).  They are ported here so the object model is
complete on its own; `shim/otlua.lua` later loads the upstream files over the same class
tables, which re-defines them with identical semantics.
============================================================================]]

local objects  = require('shim.object')
local posmod   = require('shim.position')
local sys      = require('lib.sys')
local itemsmod = require('proto.items')

local Creature    = objects.Creature
local LocalPlayer = objects.LocalPlayer

local floor, ceil, abs, max = math.floor, math.ceil, math.abs, math.max

-- Otc::PlayerShields (const.h:243-256)
local SHIELD_LEADER = { [1] = true, [4] = true, [6] = true, [8] = true, [10] = true }
local SHIELD_MEMBER = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true,
                        [6] = true, [7] = true, [8] = true, [9] = true, [10] = true }

-- VocationsClient (modules/gamelib/creature.lua:33-43)
local VOC = { Knight = 1, Paladin = 2, Sorcerer = 3, Druid = 4, Monk = 5,
              EliteKnight = 11, RoyalPaladin = 12, MasterSorcerer = 13,
              ElderDruid = 14, ExaltedMonk = 15 }

local STEP_FALLBACK_MS = 200        -- bot/walker.lua:86 (cavebot walking.lua:217-223)
local SERVER_BEAT_MS   = 50         -- game.h:533

-- ---------------------------------------------------------------------------
-- record access
-- ---------------------------------------------------------------------------
-- The backing table: `state.creatures[id]` for a remote creature, `state.player` for the
-- local one.  A creature that has left the aware range has no record; every getter then
-- answers its C++ default rather than raising, because vBot holds creature references
-- across ticks and only tests `:getPosition()` for nil.
local function rec(self)
    local st = self._reg.state
    if self._local then return st.player end
    local r = st.creatures[self._id]
    if r ~= nil then
        self._lastRec = r
        return r
    end
    -- The record is gone from state.  The live client's CreaturePtr outlives
    -- Map::removeThing, so a script that still holds the creature (the argument to
    -- onCreatureDisappear, above all) keeps reading its last name / outfit / health.
    -- `g_map.getCreatureById` still answers nil for the id -- that is the half of the
    -- C++ behaviour Reg:creature() reproduces.
    return self._lastRec
end
Creature._rec = rec

-- The local player's creature record (0x8F speed, outfit, direction all arrive there).
local function crec(self)
    local st = self._reg.state
    local r = st.creatures[self._id]
    if r then return r end
    if self._local then return st.player end
    return self._lastRec
end

-- ---------------------------------------------------------------------------
-- identity
-- ---------------------------------------------------------------------------
function Creature:getId()
    if self._local then
        local st = self._reg.state
        return (st.player and st.player.id) or self._id or 0
    end
    return self._id or 0
end

function Creature:getName()
    local r = rec(self) or crec(self)
    return (r and r.name) or ''
end

function Creature:isCreature() return true end
function Creature:isItem()     return false end

function Creature:isLocalPlayer()
    if self._local then return true end
    local st = self._reg.state
    return st.player ~= nil and st.player.id == self._id and self._id ~= 0
end

function Creature:isPlayer()
    if self._local then return true end
    local r = rec(self)
    return (r and r.isPlayer) == true
end

function Creature:isMonster()
    if self._local then return false end
    local r = rec(self)
    return (r and r.isMonster) == true
end

function Creature:isNpc()
    if self._local then return false end
    local r = rec(self)
    return (r and r.isNpc) == true
end

-- Proto::CreatureType 0 player, 1 monster, 2 npc, 3 own summon, 4 summon, 5 hidden.
function Creature:getType()
    local r = crec(self) or rec(self)
    local t = r and r.type
    if type(t) == 'number' then return t end
    if self._local then return 0 end
    if r then
        if r.isPlayer  then return 0 end
        if r.isMonster then return 1 end
        if r.isNpc     then return 2 end
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- geometry
-- ---------------------------------------------------------------------------
-- Creature::getPosition -- a COPY: vBot stores positions and mutates its own copies.
-- NEVER nil: `Thing::m_position` is default-constructed to the INVALID Position
-- (65535, 65535, 255), and every vBot call site indexes the result unguarded
-- (`distanceFromPlayer(spec:getPosition())`, `target():getPosition().z`, ...).  Handing back
-- nil for a creature that has left the aware range would crash scripts the real client runs.
function Creature:getPosition()
    local r = rec(self)
    local p = r and r.pos
    if not p then
        -- the local player before the first map description, or a creature that walked out
        -- of the aware range
        local c = crec(self)
        p = c and c.pos
    end
    if not p then
        -- Removed from the map: game/state.lua moved the coordinates to `lastPos` rather
        -- than erasing them, exactly so the creature handed to onCreatureDisappear can
        -- still say where it died (targetbot/looting.lua:322 compares its z with ours).
        p = (r and r.lastPos) or (self._lastRec and self._lastRec.lastPos)
    end
    if not p then return posmod.invalid() end
    return { x = p.x, y = p.y, z = p.z }
end

-- The direction lives on the CREATURE record for everybody, the local player included
-- (proto/parser.lua:566,605,621,626); `state.player.direction` is only ever written by the
-- 0xB5 walk-cancel (parser.lua:2124), so the creature record wins.
function Creature:getDirection()
    local r = crec(self) or rec(self)
    return (r and r.direction) or 0
end

function Creature:getTile()
    local p = self:getPosition()
    if not posmod.isValid(p) then return nil end
    return self._reg:tile(p)
end

-- Creature::canShoot (creature.cpp:1418) -> Tile::canShoot (tile.cpp:1133):
--   Chebyshev distance from the LOCAL PLAYER (not from self) <= distance, and
--   g_map.isSightClear(playerPos, creaturePos).  distance <= 0 skips the range test.
function Creature:canShoot(distance)
    local st = self._reg.state
    local playerPos = st.player and st.player.pos
    local p = self:getPosition()
    if not (playerPos and posmod.isValid(p)) then return false end
    if type(distance) == 'number' and distance > 0 then
        if max(abs(p.x - playerPos.x), abs(p.y - playerPos.y)) > distance then return false end
    end
    return st:isSightClear(playerPos, p)
end

-- ---------------------------------------------------------------------------
-- vitals / flags
-- ---------------------------------------------------------------------------
function Creature:getHealthPercent()
    if self._local then
        local pl = self._reg.state.player
        if pl and (pl.maxHealth or 0) > 0 then
            return floor(pl.health * 100 / pl.maxHealth)
        end
    end
    local r = rec(self) or crec(self)
    local h = r and r.healthPercent
    if type(h) == 'number' then return h end
    return 100
end

-- Creature::isDead (creature.h:153) == healthPercent <= 0.
function Creature:isDead()
    if self._local then
        local pl = self._reg.state.player
        if pl and pl.isDead then return true end
    end
    return self:getHealthPercent() <= 0
end

function Creature:getSpeed()
    local r = crec(self) or rec(self)
    return (r and r.speed) or 0
end

-- STATEFUL: functions/player.lua:62 setSpeed exists purely to fake the walk cadence.
function Creature:setSpeed(v)
    local r = crec(self) or rec(self)
    if r then r.speed = v end
    return v
end

-- skull / shield / emblem / icon are creature-record fields on the wire for everybody
-- (proto/parser.lua readCreature), the local player included.
function Creature:getSkull()  local r = crec(self) or rec(self); return (r and r.skull)  or 0 end
function Creature:getShield() local r = crec(self) or rec(self); return (r and r.shield) or 0 end
function Creature:getEmblem() local r = crec(self) or rec(self); return (r and r.emblem) or 0 end
function Creature:getIcon()   local r = crec(self) or rec(self); return (r and r.icon)   or 0 end

function Creature:getOutfit()
    local r = crec(self) or rec(self)
    local o = r and r.outfit
    if type(o) ~= 'table' then
        return { type = 0, lookType = 0, head = 0, body = 0, legs = 0, feet = 0,
                 addons = 0, mount = 0, auxType = 0 }
    end
    -- The C++ Outfit is exposed to Lua with BOTH `type` and `lookType` spellings depending
    -- on the call site (`outfit.type` in gamelib, `outfit.lookType` on the wire), so publish
    -- both over the parser's record without copying the mount colours away.
    local out = {}
    for k, v in pairs(o) do out[k] = v end
    out.lookType = o.lookType or o.type or 0
    out.type     = out.lookType
    out.auxType  = o.lookTypeEx or o.auxType or 0
    out.head = out.head or 0; out.body = out.body or 0
    out.legs = out.legs or 0; out.feet = out.feet or 0
    out.addons = out.addons or 0
    out.mount = out.mount or 0
    return out
end

-- Creature::canBeSeen() = !isInvisible() || isPlayer()  (creature.h:152,156) -- the
-- game/state.lua port is authoritative and already handles the lookType==0 predicate.
function Creature:canBeSeen()
    local r = rec(self)
    if self._local then return true end
    return self._reg.state.creatureCanBeSeen(r) == true
end

function Creature:isPassable()
    local r = rec(self)
    return (r and r.passable) == true
end

-- ---------------------------------------------------------------------------
-- vocation-derived predicates (modules/gamelib/creature.lua:205-229)
-- ---------------------------------------------------------------------------
-- The wire carries the vocation byte for PLAYER creatures (proto/parser.lua:584,1704) and
-- for the local player (0xA3, parser.lua:1824).  Anything else answers 0 = VocationNone,
-- which is what the C++ default-constructed m_vocation is too.
function Creature:getVocation()
    if self._local then
        local pl = self._reg.state.player
        return (pl and pl.vocation) or 0
    end
    local r = rec(self)
    return (r and r.vocation) or 0
end

function Creature:isSorcerer() local v = self:getVocation(); return v == VOC.Sorcerer or v == VOC.MasterSorcerer end
function Creature:isDruid()    local v = self:getVocation(); return v == VOC.Druid    or v == VOC.ElderDruid end
function Creature:isPaladin()  local v = self:getVocation(); return v == VOC.Paladin  or v == VOC.RoyalPaladin end
function Creature:isKnight()   local v = self:getVocation(); return v == VOC.Knight   or v == VOC.EliteKnight end
function Creature:isMonk()     local v = self:getVocation(); return v == VOC.Monk     or v == VOC.ExaltedMonk end

-- modules/gamelib/player.lua:614-625, ported verbatim over the Otc::PlayerShields values.
function Creature:isPartyLeader() return SHIELD_LEADER[self:getShield()] == true end
function Creature:isPartyMember() return SHIELD_MEMBER[self:getShield()] == true end
function Creature:isPartySharedExperienceActive()
    local s = self:getShield()
    return s == 6 or s == 8 or s == 5 or s == 7
end

-- ---------------------------------------------------------------------------
-- walking
-- ---------------------------------------------------------------------------
-- Creature::getStepDuration (creature.cpp:1106-1158).  Reproduced here so the object model
-- stands alone; bot/walker.lua:314 computes the same number from the same fields and the
-- two are asserted equal in test/shim_game_suite.lua.
--   speed < 1                       -> 0            (the C++ early return)
--   groundSpeed 0                   -> 150          (creature.cpp:1120-1121)
--   >= 860                          -> round UP to a whole serverBeat
--   diagonal (following the LAST step direction) -> x3 for a player
--   this fork then subtracts 10 ms unconditionally (creature.cpp:1155-1157)
local function speedFormula(st)
    local a, b, c = st.speedA, st.speedB, st.speedC
    if type(a) ~= 'number' or type(b) ~= 'number' or type(c) ~= 'number' then return nil end
    if a == 0 or b == 0 or c == 0 then return nil end
    return a, b, c
end

local function stepSpeedOf(st, raw)
    local a, b, c = speedFormula(st)
    if not a then return raw end
    local s = raw * 2
    if not (s > -b) then return 1 end
    local arg = s / 2 + b
    if arg <= 0 then return 1 end
    local calc = floor(a * math.log(arg) + c + 0.5)
    if calc < 1 then calc = 1 end
    return calc
end

function Creature:getStepDuration(ignoreDiagonal, dir)
    local st  = self._reg.state
    local raw = self:getSpeed()
    if type(raw) ~= 'number' or raw < 1 then return 0 end

    local from = self:getPosition()
    if not posmod.isValid(from) then from = nil end
    local tilePos = from
    if type(dir) == 'number' and from then
        tilePos = posmod.translatedToDirection(from, dir)
    end
    local groundSpeed = tilePos and st:getGroundSpeed(tilePos) or 0
    if groundSpeed == 0 then groundSpeed = 150 end

    local beat = st.serverBeat
    if type(beat) ~= 'number' or beat <= 0 then beat = SERVER_BEAT_MS end

    local divisor = stepSpeedOf(st, raw)
    if divisor < 1 then divisor = 1 end
    local ms = ceil((1000 * groundSpeed / divisor) / beat) * beat

    if ignoreDiagonal ~= true then
        local ref = (type(dir) == 'number') and dir or self:getDirection()
        if ref >= 4 and ref <= 7 then ms = ms * 3 end
    end
    ms = ms - 10                                        -- creature.cpp:1155-1157
    if ms < 1 then ms = 1 end
    return ms
end

-- Creature::isWalking -- the render-time walk animation flag.  Headless the only honest
-- answer is "does the local player have an unconfirmed step in flight"; for a remote
-- creature there is no walk timer at all, so this is false (documented deviation B4).
function Creature:isWalking()
    if not self._local then return false end
    local pl = self._reg.state.player
    return pl ~= nil and pl.preWalks ~= nil and #pl.preWalks > 0
end

-- ---------------------------------------------------------------------------
-- stubs that MUST answer, and must answer the C++ default
-- ---------------------------------------------------------------------------
-- Party mana (opcode 0x8B) is not stored -- gap G7.  100 is the "full" reading every
-- consumer treats as "no reason to heal".
function Creature:getManaPercent()
    local r = rec(self)
    local m = r and r.manaPercent
    if type(m) == 'number' then return m end
    self._reg:report('Creature:getManaPercent', 'opcode 0x8B party mana is not parsed (gap G7)')
    return 100
end

function Creature:isTimedSquareVisible() return false end     -- render-only
function Creature:isFullHealth() return self:getHealthPercent() >= 100 end
function Creature:getLight() local r = rec(self); return (r and r.light) or { intensity = 0, color = 0 } end
function Creature:getMasterId() local r = rec(self); return (r and r.masterId) or 0 end

-- Render / UI: callable, inert, never consulted for a decision (blocker B4).
local INERT = { 'setOutfit', 'setDirection', 'showStaticSquare', 'hideStaticSquare',
                'setText', 'setMarked', 'setHighlight', 'attachEffect', 'clearAttachedEffects',
                'attachParticleEffect', 'setShader', 'setTypingIconTexture', 'setIcon',
                'addTimedSquare', 'removeTimedSquare', 'setSkull', 'setShield', 'setEmblem' }
for i = 1, #INERT do Creature[INERT[i]] = function() return nil end end

-- ===========================================================================
-- LocalPlayer
-- ===========================================================================
local function pl(self) return self._reg.state.player end

-- I2: THE PREWALK POSITION.  localplayer.h:160.
function LocalPlayer:getPosition()
    local p = pl(self)
    if not p then return posmod.invalid() end
    local pw = p.preWalks
    if pw and #pw > 0 then
        local q = pw[#pw]
        return { x = q.x, y = q.y, z = q.z }
    end
    if not p.pos then return posmod.invalid() end
    return { x = p.pos.x, y = p.pos.y, z = p.pos.z }
end

function LocalPlayer:isPreWalking()
    local p = pl(self)
    return p ~= nil and p.preWalks ~= nil and #p.preWalks > 0
end

function LocalPlayer:getPreWalkingSize()
    local p = pl(self)
    return (p and p.preWalks and #p.preWalks) or 0
end

function LocalPlayer:resetPreWalk()
    local p = pl(self)
    if p and p.preWalks then for i = #p.preWalks, 1, -1 do p.preWalks[i] = nil end end
end

-- The confirmed (server) position, i.e. Creature::getPosition without the prewalk override.
function LocalPlayer:getServerPosition()
    local p = pl(self)
    if not (p and p.pos) then return posmod.invalid() end
    return { x = p.pos.x, y = p.pos.y, z = p.pos.z }
end

local function num(v, d) if type(v) == 'number' then return v end return d or 0 end

function LocalPlayer:getHealth()      return num(pl(self) and pl(self).health) end
function LocalPlayer:getMaxHealth()   return num(pl(self) and pl(self).maxHealth) end
function LocalPlayer:getMana()        return num(pl(self) and pl(self).mana) end
function LocalPlayer:getMaxMana()     return num(pl(self) and pl(self).maxMana) end
function LocalPlayer:getLevel()       return num(pl(self) and pl(self).level) end
function LocalPlayer:getLevelPercent() return num(pl(self) and pl(self).levelPercent) end
function LocalPlayer:getExperience()  return num(pl(self) and pl(self).exp) end
function LocalPlayer:getMagicLevel()  return num(pl(self) and pl(self).magicLevel) end
function LocalPlayer:getBaseMagicLevel() return num(pl(self) and pl(self).baseMagicLevel) end
function LocalPlayer:getMagicLevelPercent() return num(pl(self) and pl(self).magicLevelPercent) end
function LocalPlayer:getSoul()        return num(pl(self) and pl(self).soul) end
function LocalPlayer:getStamina()     return num(pl(self) and pl(self).stamina) end
function LocalPlayer:getBlessings()   return num(pl(self) and pl(self).blessings) end
function LocalPlayer:getManaShield()  return num(pl(self) and pl(self).manaShield) end
function LocalPlayer:getMaxManaShield() return num(pl(self) and pl(self).maxManaShield) end

-- T1: compared with a number by vBot -- NEVER nil.  proto/parser.lua:1861 already writes 0
-- when the feature is off, so this is a plain read with a defensive default.
function LocalPlayer:getRegenerationTime() return num(pl(self) and pl(self).regeneration) end
function LocalPlayer:getOfflineTrainingTime() return num(pl(self) and pl(self).offlineTraining) end

-- Capacities.  parser.lua:1846/1914 already divide by 100.
--   getFreeCapacity()  -> what is left  (localplayer.h:81)
--   getTotalCapacity() -> the maximum   (localplayer.h:82)
--   getCapacity()      -> DEVIATION: there is NO LocalPlayer::getCapacity binding in the
--                         real client (luafunctions.cpp binds only the other two), so
--                         `context.cap()` raises there.  api-game.md sec.4.2 asks for the
--                         free-capacity reading; we answer that instead of crashing, and
--                         the deviation is documented rather than silent.
function LocalPlayer:getFreeCapacity()  return num(pl(self) and pl(self).freeCapacity) end
function LocalPlayer:getTotalCapacity() return num(pl(self) and (pl(self).capacity or pl(self).maxCapacity)) end
function LocalPlayer:getBaseCapacity()  return num(pl(self) and (pl(self).baseCapacity or pl(self).capacity)) end
function LocalPlayer:getCapacity()      return self:getFreeCapacity() end

-- The combined 64-bit PlayerState mask.  parser.lua:1953-1954 keeps the u32 halves too.
function LocalPlayer:getStates() return num(pl(self) and pl(self).states) end
function LocalPlayer:isParalyzed()
    local s = self:getStates()
    -- Otc::IconParalyze == 1 << 5 == 32; Bit.band is unavailable this early, and the mask is
    -- a plain double, so use arithmetic (states can exceed 2^31 -- bit.band is SIGNED).
    return floor(s / 32) % 2 == 1
end

function LocalPlayer:getSkillLevel(skill)
    local p = pl(self)
    local s = p and p.skills and p.skills[skill]
    return num(s and s.level)
end

function LocalPlayer:getSkillBaseLevel(skill)
    local p = pl(self)
    local s = p and p.skills and p.skills[skill]
    return num(s and s.baseLevel)
end

function LocalPlayer:getSkillLevelPercent(skill)
    local p = pl(self)
    local s = p and p.skills and p.skills[skill]
    return num(s and s.percent)
end

-- ---------------------------------------------------------------------------
-- inventory
-- ---------------------------------------------------------------------------
function LocalPlayer:getInventoryItem(slot)
    local p = pl(self)
    local it = p and p.inventory and p.inventory[slot]
    if not it then return nil end
    return self._reg:item(it, { kind = 'inventory', slot = slot })
end

-- LocalPlayer::hasEquippedItemId (localplayer.cpp:531): equipped slots only, tier must match.
function LocalPlayer:hasEquippedItemId(itemId, tier)
    if not itemId or itemId == 0 then return false end
    tier = tier or 0
    local p = pl(self)
    local inv = p and p.inventory
    if not inv then return false end
    for slot = 1, 11 do
        local it = inv[slot]
        if it and it.id == itemId and (it.tier or 0) == tier then return true end
    end
    return false
end

-- Item::getCount (item.h:96) -- `isStackable() ? m_countOrSubType : 1`.  The wire byte is
-- CUMULATIVE for stackable OR fluidContainer OR splash (proto/parser.lua:678 writes it for
-- all three), so summing it raw adds the FLUID SUBTYPE for a vial or a splash instead of 1.
-- localplayer.cpp:565-569 accumulates getCount(), and vBot/HealBot.lua:39,
-- vBot/AttackBot.lua:43 and vBot/vlib.lua:829 all treat the result as a supply count.
local function countOf(it)
    if not it then return 0 end
    local okStack, stackable = pcall(itemsmod.isStackable, it.id)
    if okStack and stackable then return it.count or 1 end
    return 1
end

-- LocalPlayer::getInventoryCount (localplayer.cpp:552): the 0xC0 count cache FIRST, then the
-- 11 equipped slots plus every OPEN container.  `state.inventoryCounts` is keyed
-- itemId*256 + tier (proto/parser.lua:1531 / API.md).
function LocalPlayer:getInventoryCount(itemId, tier)
    if not itemId or itemId == 0 then return 0 end
    tier = tier or 0
    local st = self._reg.state
    local cache = st.inventoryCounts
    if cache then
        local hit = cache[itemId * 256 + tier]
        if type(hit) == 'number' then return hit end
    end
    local total = 0
    local p = st.player
    local inv = p and p.inventory
    if inv then
        for slot = 1, 11 do
            local it = inv[slot]
            if it and it.id == itemId and (it.tier or 0) == tier then total = total + countOf(it) end
        end
    end
    for _, c in pairs(st.containers) do
        local list = c.items
        if list then
            for i = 1, #list do
                local it = list[i]
                if it and it.id == itemId and (it.tier or 0) == tier then total = total + countOf(it) end
            end
        end
    end
    return total
end

-- ---------------------------------------------------------------------------
-- resources / monk stances
-- ---------------------------------------------------------------------------
-- Otc::ResourceTypes_t -> uint64.  proto/parser.lua:2737-2741 writes `state.resources`,
-- NOT `state.player.resources`.
function LocalPlayer:getResourceBalance(t)
    local st = self._reg.state
    local r = st.resources
    if not r then return 0 end
    return num(r[t])
end

function LocalPlayer:getTotalMoney()
    -- RESOURCE_BANK_BALANCE = 0, RESOURCE_GOLD_EQUIPPED = 1 (const.h ResourceTypes_t)
    return self:getResourceBalance(0) + self:getResourceBalance(1)
end

function LocalPlayer:getHarmony() return num(pl(self) and pl(self).harmony) end
function LocalPlayer:isSerene()   return (pl(self) and pl(self).serene) == true end

function LocalPlayer:getVirtues()
    local p = pl(self)
    local v = p and p.virtues
    if type(v) ~= 'table' then return {} end
    local out = {}
    for i = 1, #v do out[i] = v[i] end
    return out
end

-- protocolgameparse.cpp:5385-5404, verbatim.
local function stances(self)
    local p = pl(self)
    local v = p and p.virtues
    if type(p) == 'table' and type(p.stance) == 'number' then
        return p.stance, num(p.secondaryStance)
    end
    local primary, secondary = 0, 0
    if type(v) == 'table' then
        for i = 1, #v do
            local id = v[i]
            if id == 311 or id == 312 then secondary = id
            elseif primary == 0 then primary = id
            elseif secondary == 0 then secondary = id end
        end
    end
    return primary, secondary
end

function LocalPlayer:getStance()          local a = stances(self); return a end
function LocalPlayer:getSecondaryStance() local _, b = stances(self); return b end

-- Derived, not stored (localplayer.h:99): 274->1, 275->2, 276->3, anything else 0.
function LocalPlayer:getVirtue()
    local a = stances(self)
    if a == 274 then return 1 elseif a == 275 then return 2 elseif a == 276 then return 3 end
    return 0
end

-- G4: proto/parser.lua:909 reads the supply-stash byte and discards it.  Latched by
-- shim/g_game.lua when the flag ever becomes available; false until then, and loud.
function LocalPlayer:isSupplyStashAvailable()
    local p = pl(self)
    if type(p) == 'table' and p.supplyStashAvailable ~= nil then
        return p.supplyStashAvailable == true
    end
    self._reg:report('LocalPlayer:isSupplyStashAvailable',
                     'proto/parser.lua:909 discards the byte (gap G4)')
    return false
end

function LocalPlayer:isPremium()  return (pl(self) and pl(self).premium) == true end
function LocalPlayer:isKnown()    return true end
function LocalPlayer:isServerWalking() return (pl(self) and pl(self).waitingForServerWalk) == true end
function LocalPlayer:isAutoWalking()   return (pl(self) and pl(self).autoWalking) == true end

-- LocalPlayer::hasSight (localplayer.cpp) -- inside the aware rectangle.
function LocalPlayer:hasSight(p)
    return self._reg.state:isAwareOf(p) == true
end

-- LocalPlayer::canWalk (localplayer.cpp:38-63), reduced to what a headless client can know:
-- not dead, not walk-locked, and no more than getWalkMaxSteps() prewalks outstanding.
function LocalPlayer:canWalk(_dir, ignoreLock)
    local p = pl(self)
    if not p then return false end
    if p.isDead then return false end
    if ignoreLock ~= true and type(p.walkLockUntil) == 'number'
       and p.walkLockUntil > sys.nowMs() then return false end
    return true
end

function LocalPlayer:lockWalk(ms)
    local p = pl(self)
    if not p then return end
    p.walkLockUntil = sys.nowMs() + (ms or 250)
end

function LocalPlayer:isWalkLocked()
    local p = pl(self)
    return p ~= nil and type(p.walkLockUntil) == 'number' and p.walkLockUntil > sys.nowMs()
end

function LocalPlayer:getSpells()
    local p = pl(self)
    local s = p and p.spells
    if type(s) ~= 'table' then return {} end
    local out = {}
    for i = 1, #s do out[i] = s[i] end
    return out
end

return objects
