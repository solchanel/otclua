--[[============================================================================
bot/stances.lua -- Stances (the buff/aura keep-alive macro), ported from vBot 4.8.

Work item N1.  Behaviour source: the real vBot/Stances.lua (profiles/bot/vBot_4.8/
vBot/Stances.lua), read in full -- it is short (450 lines) and its own header
comment states the ordering guarantee this file exists to reproduce.
CONFIGAPI.md is authoritative for the storage shape and the panel-facing
config.get/config.set contract; this file only builds the module BOT.md's
"Each module: M.new(bot, config)" contract asks for.

    local st = stances.new(bot [, cfgTree] [, opts])
    st:enable()  st:disable()  st:isOn()
    st:tick()                       -- one 200 ms pass
    st:status()  st:reload(cfgTree)

`cfgTree` is `storage.stances` -- NOT a separate file.  storage/profile_N.json
is loaded once at bot construction (bot/init.lua's `self.storage`) exactly like
macro on/off state; omit `cfgTree` and this module reads `bot.storage.stances`,
creating it (with vBot's own defaults) if absent -- byte-for-byte the same
defaulting vBot/Stances.lua:50-56 does, so a profile this module has never
touched loads identically in both clients, and a profile ONLY this module has
ever touched loads identically back into the real vBot GUI.

------------------------------------------------------------------------------
THE ORDERING GUARANTEE (read the real Stances.lua header before touching this)
------------------------------------------------------------------------------
Entries are evaluated STRICTLY TOP DOWN.  The FIRST entry whose gates match
(hp%, mana%, monster count) wins and returns for the whole tick -- even when
nothing was actually cast, because the stance is already active or the spell
is on cooldown.  A lower-priority entry must never sneak a cast in underneath
a higher one just because the higher one had nothing to do this tick.  Put the
emergency stance first (vBot's own example: Protector at 0-40% HP ahead of
Blood Rage's "4+ monsters", so low HP always wins regardless of monster count).

------------------------------------------------------------------------------
STANCES / vocation matching
------------------------------------------------------------------------------
The STANCES table (id/words/mana/needTarget/CIP vocation pair) is transcribed
verbatim from vBot/Stances.lua:28-43 (verified there against
modules/gamelib/spells.lua).  The CIP pair uses SpellInfo.vocations' OWN
numbering, which is NOT player:getVocation()'s numbering -- bot/data/spells.lua
sec.1 documents the two-numbering trap.  We go through that file's
`cipPairForClientVocation()` helper -- ITS OWN header calls this "the
documented predicate mapping (isKnight/isPaladin/isSorcerer/isDruid/isMonk),
flattened" -- instead of hand-rolling a second copy of those predicates, the
same way bot/attackbot.lua never compares vocation numbers directly either.

------------------------------------------------------------------------------
getStance() / getSecondaryStance()
------------------------------------------------------------------------------
Real vBot prefers the client's native player:getStance()/getSecondaryStance()
and falls back to a remembered "assumed" id only when the BINDING ITSELF is
missing (an old client build without the C++ methods).  bot/api.lua's
ctx.getStance()/ctx.getSecondaryStance() (added for this work item) derive the
answer from state.player.virtues via protocolgameparse.cpp:5385-5404 -- the
exact rule shim/creature.lua's local `stances()` helper also implements, so
the sandbox and this native module agree on one source of truth.  Those ctx
functions always exist in this client, so `haveNative` below is always true in
practice; the fallback branch is kept anyway so a caller that strips them
degrades exactly like vBot does, rather than throwing.

------------------------------------------------------------------------------
DEVIATIONS (each documented, none hidden)
------------------------------------------------------------------------------
 1. Monster counting goes through bot/world.lua's shared `world:monsters(pos,
    range)` (BOT.md's one spectator engine) instead of a second
    getSpectators() loop -- same Chebyshev radius, same summon exclusion
    (world.lua's isMonster() already ports AB:2559/2571's `getType() < 3`
    rule), then filtered by the entry's lowercase name list exactly like
    vBot's `table.find(nameFilter, spec:getName():lower(), true)`.
 2. RUNTIME vocation gating.  Real vBot's macro does NOT check vocation at
    all -- `stanceMatchesMyVocation` only filters the UI's dropdown, and
    nothing stops a hand-edited storage.stances entry from naming a stance the
    character's vocation cannot cast (the server would presumably reject it,
    but vBot would still burn the cast attempt every lockout window).
    CONFIGAPI.md asks for the CIP-pair predicate explicitly, so
    `canCastStance` here also refuses a vocation mismatch -- a deliberate
    safety improvement over upstream, not a divergence in the cases upstream
    actually handles (a well-formed profile never disagrees with its own
    character's vocation).
 3. No UI.  storage.stances IS the config; CONFIGAPI.md's config.get/
    config.set read and write it directly, and this module's :reload(cfg)
    re-normalises and starts using the change immediately, without a restart.
 4. DEAD / NOT-IN-GAME GATE (BOT.md, attackbot.lua deviation 1).  vBot relies
    on the whole bot being torn down off-game; a headless worker must check
    explicitly, or a dead player's 0% HP would satisfy every "HP% <" gate.
    Real vBot/Stances.lua has no such guard because it never runs off-game in
    the first place.  Mandatory, no switch.
============================================================================]]

local bit = require('bit')
local band = bit.band

local stances = {}
local ST = {}
ST.__index = ST

local floor = math.floor

local ok_world, worldmod = pcall(require, 'bot.world')
local ok_shared, shared  = pcall(require, 'bot.shared')
local ok_spells, SPELLS  = pcall(require, 'bot.data.spells')
if not ok_spells or type(SPELLS) ~= 'table' then SPELLS = nil end

-- ---------------------------------------------------------------------------
-- vBot/Stances.lua:28-43, verbatim.  voc uses the CIP vocation numbering
-- (sorc {1,5}, druid {2,6}, paladin {3,7}, knight {4,8}, monk {9,10}).
-- ---------------------------------------------------------------------------
local STANCES = {
    { id = 132, words = "utamo tempo",     name = "Protector",                mana = 200,  voc = { 4, 8 },  needTarget = false },
    { id = 133, words = "utito tempo",     name = "Blood Rage",               mana = 290,  voc = { 4, 8 },  needTarget = false },
    { id = 274, words = "utori virtu",     name = "Virtue of Harmony",        mana = 210,  voc = { 9, 10 }, needTarget = false },
    { id = 275, words = "utito virtu",     name = "Virtue of Justice",        mana = 210,  voc = { 9, 10 }, needTarget = false },
    { id = 276, words = "utura tio",       name = "Virtue of Sustain",        mana = 210,  voc = { 9, 10 }, needTarget = false },
    { id = 304, words = "uteta flam",      name = "Master of Flames",         mana = 400,  voc = { 1, 5 },  needTarget = false },
    { id = 305, words = "uteta vis",       name = "Master of Thunder",        mana = 400,  voc = { 1, 5 },  needTarget = false },
    { id = 306, words = "uteta mort",      name = "Master of Decay",          mana = 400,  voc = { 1, 5 },  needTarget = false },
    { id = 309, words = "utura sio",       name = "Shared Conservation",      mana = 400,  voc = { 2, 6 },  needTarget = false },
    { id = 311, words = "exori moe tempo", name = "Aura of Sapped Strength",  mana = 1500, voc = { 1, 5 },  needTarget = false },
    { id = 312, words = "exori kor tempo", name = "Aura of Exposed Weakness", mana = 1500, voc = { 1, 5 },  needTarget = false },
    { id = 313, words = "utori con",       name = "Sharpshooter",             mana = 250,  voc = { 3, 7 },  needTarget = true  },
    { id = 314, words = "utori hur",       name = "Divine Defiance",          mana = 250,  voc = { 3, 7 },  needTarget = true  },
    { id = 319, words = "utito dru",       name = "Elemental Synthesis",      mana = 400,  voc = { 2, 6 },  needTarget = false },
}
stances.STANCES = STANCES

local STANCE_BY_WORDS, STANCE_BY_ID = {}, {}
for _, s in ipairs(STANCES) do
    STANCE_BY_WORDS[s.words] = s
    STANCE_BY_ID[s.id] = s
end
stances.STANCE_BY_WORDS = STANCE_BY_WORDS
stances.STANCE_BY_ID = STANCE_BY_ID

-- After a cast we hold off briefly: the server needs a moment to apply the
-- stance, and without this we would re-fire every tick until it lands
-- (vBot/Stances.lua:58-60).
local CAST_LOCKOUT_MS = 1500
stances.CAST_LOCKOUT_MS = CAST_LOCKOUT_MS

--- Does `stance` belong to the player's (CLIENT-numbered) vocation?  Goes
--- through bot/data/spells.lua's cipPairForClientVocation() -- see the header
--- -- instead of comparing raw ids.  Unknown/0 client vocation, or the
--- spells module missing, matches everything (fail open, same as vBot's
--- myVocationPair() returning nil when `player` itself is unavailable).
local function stanceMatchesVocation(stance, vocClientId)
    if not SPELLS then return true end
    local pair = SPELLS.cipPairForClientVocation(vocClientId)
    if not pair then return true end
    local voc = stance.voc
    for i = 1, #voc do
        if voc[i] == pair[1] or voc[i] == pair[2] then return true end
    end
    return false
end
stances.stanceMatchesVocation = stanceMatchesVocation

-- vBot/Stances.lua:50-56, verbatim (the write-back-into-storage defaulting).
local function normalise(cfg)
    if type(cfg) ~= 'table' then cfg = {} end
    if type(cfg.entries) ~= 'table' then cfg.entries = {} end
    if type(cfg.enabled) ~= 'boolean' then cfg.enabled = false end
    if type(cfg.ignoreInPz) ~= 'boolean' then cfg.ignoreInPz = true end
    return cfg
end
stances.normalise = normalise

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
function stances.new(b, cfg, opts)
    if type(b) ~= 'table' then error('stances.new: bot instance required', 2) end
    opts = opts or {}

    local self = setmetatable({}, ST)
    self.bot    = b
    self.state  = b.state
    self.sender = b.sender
    self.log    = b.log or { info = function() end, warn = function() end,
                             error = function() end, debug = function() end }

    -- bot/shared.lua is the ONE spell-cooldown cache HealBot/AttackBot/Stances
    -- share (BOT.md); bot/world.lua is the ONE spectator engine.
    self.sh = ok_shared and shared.attach(b, opts) or nil

    self.world = opts.world or b.world
    if not self.world and ok_world then
        local ok, w = pcall(worldmod.new, b, {})
        self.world = ok and w or nil
        if self.world and not b.world then b.world = self.world end
    end

    self.enabled = (opts.enabled ~= false)   -- module master switch, separate
                                              -- from cfg.enabled (the panel's
                                              -- own on/off toggle)
    self.lastCastAt = 0
    self.assumedStanceId = 0
    self.counts = { casts = 0, blocked = 0 }

    self:reload(cfg)
    self:_registerMacros()
    return self
end

-- ---------------------------------------------------------------------------
-- config / storage
-- ---------------------------------------------------------------------------
--- :reload(cfg)  --  cfg == nil reads (and lazily creates) bot.storage.stances;
--- a cfg table is used as given (CONFIGAPI.md's config.set path) and adopted
--- as bot.storage.stances so a later bot:saveStorage() persists the change.
--- Either way, missing fields are defaulted in place -- existing keys this
--- module does not know about are NEVER touched, so a real vBot file survives
--- untouched (BOT.md: "Unknown fields must be preserved on save").
function ST:reload(cfg)
    if cfg == nil then
        local st = self.bot.storage
        if type(st) == 'table' then
            if type(st.stances) ~= 'table' then st.stances = {} end
            cfg = st.stances
        end
    end
    self.cfg = normalise(cfg)
    local st = self.bot.storage
    if type(st) == 'table' and st.stances ~= self.cfg then st.stances = self.cfg end
    return self.cfg
end

function ST:isOn()
    if not self.enabled then return false end
    return self.cfg.enabled == true
end
function ST:enable()  self.enabled = true;  return self end
function ST:disable() self.enabled = false; return self end

-- ---------------------------------------------------------------------------
-- player / world accessors
-- ---------------------------------------------------------------------------
function ST:now() return self.bot.now or (self.bot.clock and self.bot.clock()) or 0 end
function ST:player() return self.state and self.state.player or nil end

function ST:hpPercent()
    local p = self:player()
    if not p or not p.maxHealth or p.maxHealth <= 0 then return 100 end
    return floor((p.health or 0) * 100 / p.maxHealth)
end

--- player.lua:8-15's knight guard: maxMana <= 1 reads as 100%.
function ST:manaPercent()
    local p = self:player()
    if not p then return 100 end
    if not p.maxMana or p.maxMana <= 1 then return 100 end
    return floor((p.mana or 0) * 100 / p.maxMana)
end

function ST:mana()
    local p = self:player()
    return (p and p.mana) or 0
end

--- PlayerStates.Pz = 16384 (bot/shared.lua / functions/const.lua).  Mirrors
--- bot/attackbot.lua's A:hasCond/A:isInPz exactly (statesLo, or states mod
--- 2^32, since bit.band is SIGNED).
function ST:isInPz()
    local p = self:player()
    if not p then return false end
    local lo = p.statesLo
    if lo == nil then lo = (p.states or 0) % 4294967296 end
    return band(lo, 16384) ~= 0
end

function ST:hasTarget()
    return self.bot._attacking ~= nil
end

--- Deviation 4: the mandatory dead/not-in-game gate (BOT.md; see
--- bot/attackbot.lua's A:playable(), which this mirrors exactly).
function ST:playable()
    local p = self:player()
    if not p then return false end
    if p.isDead then return false end
    if (p.maxHealth or 0) > 0 and (p.health or 0) <= 0 then return false end
    if not p.pos then return false end
    if self.bot.inGame == false then return false end
    return true
end

--- Monsters within `range` of the player, optionally restricted to a
--- lowercase name whitelist -- vBot/Stances.lua's countMonsters(), built on
--- bot/world.lua's shared spectator engine instead of a second
--- getSpectators() loop (deviation 1 in the header).
function ST:countMonsters(range, nameFilter)
    local w = self.world
    local p = self:player()
    local pos = p and p.pos
    if not (w and pos) then return 0 end
    local list = w:monsters(pos, range)
    if not nameFilter then return #list end
    local found = 0
    for i = 1, #list do
        local nm = list[i].name
        if type(nm) == 'string' then
            nm = nm:lower()
            for j = 1, #nameFilter do
                if nameFilter[j] == nm then found = found + 1; break end
            end
        end
    end
    return found
end

-- ---------------------------------------------------------------------------
-- the algorithm (vBot/Stances.lua:97-450, ported 1:1)
-- ---------------------------------------------------------------------------

--- Which stances are live right now.  See the header's "getStance() /
--- getSecondaryStance()" section for why `haveNative` is always true here in
--- practice; the fallback is kept for parity with a caller that strips them.
function ST:activeStanceIds()
    local ids = {}
    local api = self.bot.api
    local haveNative = false

    if api and type(api.getStance) == 'function' then
        haveNative = true
        local primary = api.getStance()
        if primary and primary ~= 0 then ids[primary] = true end
    end
    if api and type(api.getSecondaryStance) == 'function' then
        haveNative = true
        local secondary = api.getSecondaryStance()
        if secondary and secondary ~= 0 then ids[secondary] = true end
    end

    if not haveNative and self.assumedStanceId ~= 0 then
        ids[self.assumedStanceId] = true
    end
    return ids
end

--- vBot/Stances.lua:136-156, verbatim.
function ST:entryMatches(entry, hp, mp)
    if hp < entry.minHp or hp > entry.maxHp then return false end
    if mp < (entry.minMana or 0) then return false end

    local nameFilter = (entry.monsters ~= true) and entry.monsters or nil
    local wanted = entry.count or 0

    if wanted > 0 then
        local found = self:countMonsters(entry.range or 5, nameFilter)
        if entry.orMore then
            if found < wanted then return false end
        elseif found ~= wanted then
            return false
        end
    elseif nameFilter then
        -- Named monsters but no count given: "any of these, at least one".
        if self:countMonsters(entry.range or 5, nameFilter) < 1 then return false end
    end

    return true
end

--- vBot/Stances.lua:158-164 + deviation 2 (the added vocation gate).
function ST:canCastStance(stance)
    if not stance then return false end
    if stance.needTarget and not self:hasTarget() then return false end
    local voc = self:player() and self:player().vocation or 0
    if not stanceMatchesVocation(stance, voc) then return false end
    if self:mana() < stance.mana then return false end
    if self.sh and self.sh:spellCooldownActive(stance.words) then return false end
    return true
end

--- Cast `entry.spell` via bot/shared.lua's say() -- the SAME talkSpell path
--- HealBot/AttackBot use, so a known formula goes out aimed (SpellAimTarget)
--- exactly like vBot's plain `say(entry.spell)`.
function ST:_cast(entry)
    if not self.sh then return nil, 'no shared' end
    local ok = self.sh:say(entry.spell)
    self.assumedStanceId = entry.spellId
    self.lastCastAt = self:now()
    self.counts.casts = self.counts.casts + 1
    return ok
end

--- One 200 ms pass.  Registered as an ALWAYS-ALLOWED macro (BOT.md:
--- "healbot/attackbot always allowed -- never yields"); Stances joins them,
--- since keeping a buff up is the same kind of action.
function ST:tick()
    if not self:isOn() then return end
    if not self:playable() then return end
    if self.cfg.ignoreInPz and self:isInPz() then return end
    if (self:now() - self.lastCastAt) < CAST_LOCKOUT_MS then return end

    local hp = self:hpPercent()
    local mp = self:manaPercent()

    local entries = self.cfg.entries
    for i = 1, #entries do
        local entry = entries[i]
        if entry.enabled and self:entryMatches(entry, hp, mp) then
            -- FIRST match wins and owns this tick, even when nothing gets
            -- cast below -- see the header's ordering guarantee.
            local active = self:activeStanceIds()
            if not active[entry.spellId] then
                local stance = STANCE_BY_WORDS[entry.spell]
                if self:canCastStance(stance) then
                    self:_cast(entry)
                else
                    self.counts.blocked = self.counts.blocked + 1
                end
            end
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- macro registration (constructor time, like healbot/attackbot -- BOT.md
-- "As built" #2: always-allowed modules register their own macro, they do
-- not wait for :attach())
-- ---------------------------------------------------------------------------
function ST:_registerMacros()
    local b = self.bot
    if not b.macro then return end
    self.macros = { b:macro(200, function() self:tick() end) }
    return self.macros
end

-- ---------------------------------------------------------------------------
-- status (BOT.md "Status object")
-- ---------------------------------------------------------------------------
local function idSetToSortedList(set)
    local out = {}
    for id in pairs(set) do out[#out + 1] = id end
    table.sort(out)
    return out
end

function ST:status()
    return {
        on = self:isOn(),
        enabled = self.cfg.enabled == true,
        ignoreInPz = self.cfg.ignoreInPz == true,
        entries = #self.cfg.entries,
        lastCastAt = self.lastCastAt,
        assumedStanceId = self.assumedStanceId,
        active = idSetToSortedList(self:activeStanceIds()),
        counts = self.counts,
    }
end

return stances
