--[[============================================================================
bot/healbot.lua -- HealBot + Conditions, ported from vBot 4.8.

Work item M1.  Behaviour source: docs/vbot/healbot.md.  Its
"## VERIFIER (Corrections)" section OVERRIDES the spec body, and every
correction is applied below with the citation inline.

    local hb = healbot.new(bot [, cfgTree] [, opts])
    hb:enable()  hb:disable()  hb:isOn()
    hb:tick()                   -- runs all four loops once, for tests
    hb:status()  hb:reload(cfgTree)
    hb:setActiveProfile(n)  hb:getActiveProfile()

`cfgTree` is the decoded HealBot.json (`{ currentHealBotProfile, healbot[5],
ConditionPanel }`).  Omit it and the module loads it through `bot.config`
(`<profileDir>/vBot_configs/profile_<vprofile>/HealBot.json`).  The user's real
file is consumed UNCHANGED -- including its stale `index` fields, its
misspelled `curePosion` key and its `Visible:false`.

------------------------------------------------------------------------------
THE SHAPE OF THE THING (healbot.md §0)
------------------------------------------------------------------------------
HealBot is FOUR independent, stateless-per-tick polling loops.  There is no
unified rule list, no priority number and no "condition" trigger inside HealBot
itself; PRIORITY IS ARRAY POSITION and each loop fires at most one action:

  spell loop        macro(20) -> clamped to  50 ms   HealBot.lua:687-717
  item  loop        macro(100)               100 ms  HealBot.lua:748-805
  conditions slow   macro(500)               500 ms  Conditions.lua:238-251
  conditions fast   macro(50)                 50 ms  Conditions.lua:253-259

All four register as UNNAMED macros, exactly as vBot does, so they are always
"enabled" at the runtime level and gate internally on the profile switch.  The
registration order is the intra-tick send order the VERIFIER insists on:
conditions-500 -> conditions-50 -> spells -> items.  A single 10 ms tick can
therefore emit up to five actions, and a port that serialises them would change
which action wins.

------------------------------------------------------------------------------
DELIBERATE DEVIATIONS (each one is a documented vBot defect; each has a switch)
------------------------------------------------------------------------------
 1. DEAD / NOT-IN-GAME GATE.  vBot has no isDead() check anywhere in HealBot.lua
    (healbot.md §2.3): on death healthPercent goes to 0, every `HP% <` rule
    matches, and both loops spam heals at a corpse.  We refuse to run any loop
    while `player.isDead` or the session is not playing.  BOT.md requires this
    ("must never fire while the player is dead or not in game").
    Switch: none -- this one is mandatory.
 2. `standByItems` IS DROPPED (healbot.md §2.4).  The sleep flag is only cleared
    by health/mana events, so a `burst`-origin item rule sleeps forever while
    burst damage decays with static HP/MP.  `opts.standByItems = true` restores it.
 3. BURST PRUNE IS A REVERSE LOOP.  vBot removes while FORWARD-iterating with
    ipairs (vlib.lua:54-58), skipping roughly every other stale sample, so its
    window is longer than 3 s and its DPS is systematically low (VERIFIER).
    `opts.vbotBurstPrune = true` reproduces the forward remove bug-for-bug.
    The scheduled full wipe (vlib.lua:61-63, schedule(3050)) -- the only thing
    that ever returns burstDamageValue() to 0 -- IS implemented, per the VERIFIER.
 4. COOLDOWN GATES USE THE PREDICTIVE CACHE, NOT THE COOLDOWN-WINDOW ICONS.  The
    VERIFIER shows every icon path in modules/game_cooldown returns early when
    the cooldown window is hidden (cooldown.lua:539-541, :562-565), so on a
    hidden bar vBot's group-2 gate, `getSpellCoolDown(hasteSpell)` and canCast's
    fallback NEVER block.  Using our own cache makes the port strictly MORE
    restrictive.  `opts.hiddenCooldownWindow = true` makes every icon-style gate
    read false, reproducing vBot on a client with the bar hidden.
 5. OPTIMISTIC POST-CAST MARK IS OFF BY DEFAULT.  HealBot.lua:638-643 documents
    the re-send spam as intentional (a rejected cast costs nothing, so retry
    every 50 ms until 0xA4 lands).  The VERIFIER stresses that writing a local
    cooldown at send time is a SUBSTANTIVE change -- 6000 ms for the exana cures,
    60000 ms for utura.  `opts.optimisticSpellCooldown = true` enables it.
 6. `hppercent()` -- the VERIFIER requires the server byte from 0x8C with a
    fallback of 101 (not 0), so the port fails CLOSED before the first packet.
    luaclient's 0xA0 carries absolute hp only, so the order is:
    creature.healthPercent -> floor(health*100/maxHealth) -> 101.  The middle
    step is the fallback the spec's own Open Questions authorise.
    `opts.hpPercentSource = 'server'|'derived'|'auto'` (default 'auto').
 8. BURST DAMAGE: DIVISION-BY-ZERO GUARD.  vlib.lua:66-76 has no guard, so with
    #dmgTable > 1 and `now == dmgTable[1].t` -- two "you lose" messages inside a
    single bot tick, since every `now` read in one tick is identical -- vBot
    evaluates math.ceil(d / 0) and returns `inf`, firing any `burst >` rule.  We
    return 0 there instead (fail closed).  `opts.vbotBurstInfinity = true`
    reproduces vBot's `inf` exactly.
 7. BOTH POISON KEYS ARE READ.  The ConditionPanel default table writes the
    misspelled `curePosion` (Conditions.lua:30) while every reader uses
    `curePoison`.  We read `curePoison`, and only when it is nil fall back to
    `curePosion` -- so the user's real file (which has `curePosion:false` and no
    `curePoison`) behaves identically to vBot.
============================================================================]]

local bit    = require('bit')
local shared = require('bot.shared')

local band  = bit.band
local floor = math.floor

local healbot = {}
local H = {}
H.__index = H

local PS = shared.PlayerStates

-- Conditions.lua:241-245.  Fixed table, fixed order, hardcoded words.
-- Group 2 (Healing), exhaustion 6000 for all five (gamelib/spells.lua:65,158-161).
local CURES = {
    { on = 'curePoison',    cost = 'poisonCost',    bit = PS.Poison,   words = 'exana pox'  },
    { on = 'cureCurse',     cost = 'curseCost',     bit = PS.Cursed,   words = 'exana mort' },
    { on = 'cureBleed',     cost = 'bleedCost',     bit = PS.Bleeding, words = 'exana kor'  },
    { on = 'cureBurn',      cost = 'burnCost',      bit = PS.Burn,     words = 'exana flam' },
    { on = 'cureElectrify', cost = 'electrifyCost', bit = PS.Energy,   words = 'exana vis'  },
}
healbot.CURES = CURES

-- HealBot.lua:273-277 / resetSettings :571-582
local function blankProfile(n)
    return { name = 'Profile #' .. n, enabled = false, spellTable = {}, itemTable = {},
             Visible = true, Cooldown = true, Interval = true, Conditions = true,
             Delay = true, MessageDelay = false }
end
healbot.blankProfile = blankProfile

-- Conditions.lua:28-55.  NOTE the misspelled `curePosion` -- reproduced verbatim,
-- because that is the key vBot itself writes into a fresh file.
local function defaultConditionPanel()
    return { enabled = false,
             curePosion = false,   poisonCost = 20,
             cureCurse = false,    curseCost = 80,
             cureBleed = false,    bleedCost = 45,
             cureBurn = false,     burnCost = 30,
             cureElectrify = false, electrifyCost = 22,
             cureParalyse = false, paralyseCost = 40, paralyseSpell = 'utani hur',
             holdHaste = false,    hasteCost = 40,    hasteSpell = 'utani hur',
             holdUtamo = false,    utamoCost = 40,
             holdUtana = false,    utanaCost = 440,
             holdUtura = false,    uturaType = '',    uturaCost = 100,
             ignoreInPz = true,    stopHaste = false }
end
healbot.defaultConditionPanel = defaultConditionPanel

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
function healbot.new(b, cfg, opts)
    if type(b) ~= 'table' then error('healbot.new: bot instance required', 2) end
    opts = opts or {}

    local self = setmetatable({}, H)
    self.bot    = b
    self.state  = b.state
    self.sender = b.sender
    self.events = b.events
    self.log    = b.log or { info = function() end, warn = function() end,
                             error = function() end, debug = function() end }
    self.sh     = shared.attach(b, opts)
    self.opts   = opts

    self.enabled = (opts.enabled ~= false)      -- module master switch

    self.optimisticSpellCooldown = opts.optimisticSpellCooldown == true
    self.standByItemsEnabled     = opts.standByItems == true
    self.vbotBurstPrune          = opts.vbotBurstPrune == true
    self.vbotBurstInfinity       = opts.vbotBurstInfinity == true   -- deviation 8
    self.hiddenCooldownWindow    = opts.hiddenCooldownWindow == true
    self.hpPercentSource         = opts.hpPercentSource or 'auto'

    -- runtime -----------------------------------------------------------------
    self.dmg              = {}          -- burst-damage samples
    self.lastDmgMessage   = 0
    self.lastHealItemUse  = 0
    self.standByItems     = false
    self.itemLoopBlockedUntil = 0
    self.utanaCast        = nil
    self.lastPosChange    = b.now or (b.clock and b.clock()) or 0
    self.lastAction       = nil         -- { kind, what, at }
    self.counts = { spellCasts = 0, itemUses = 0, cures = 0, holds = 0 }

    self:reload(cfg)
    self:_hookEvents()
    self:_registerMacros()
    return self
end

-- ---------------------------------------------------------------------------
-- config
-- ---------------------------------------------------------------------------
--- HealBot.lua:271-283 structural repair, reproduced exactly: a missing table, a
--- missing [1], OR a length other than 5 resets the whole array to five blanks.
local function normalise(cfg)
    if type(cfg) ~= 'table' then cfg = {} end
    if type(cfg.healbot) ~= 'table' or type(cfg.healbot[1]) ~= 'table' or #cfg.healbot ~= 5 then
        cfg.healbot = {}
        for i = 1, 5 do cfg.healbot[i] = blankProfile(i) end
    end
    for i = 1, 5 do
        local p = cfg.healbot[i]
        if type(p.spellTable) ~= 'table' then p.spellTable = {} end
        if type(p.itemTable)  ~= 'table' then p.itemTable  = {} end
    end
    local n = tonumber(cfg.currentHealBotProfile)
    if not n or n == 0 or n > 5 then cfg.currentHealBotProfile = 1 end
    if type(cfg.ConditionPanel) ~= 'table' then cfg.ConditionPanel = defaultConditionPanel() end
    return cfg
end
healbot.normalise = normalise

function H:reload(cfg)
    if cfg == nil and self.bot.config and self.bot.config.loadHealBot then
        local loaded = self.bot.config:loadHealBot()
        if type(loaded) == 'table' then cfg = loaded end
    end
    self.cfg = normalise(cfg)
    return self.cfg
end

function H:profile()  return self.cfg.healbot[self.cfg.currentHealBotProfile] end
function H:conditions() return self.cfg.ConditionPanel end
function H:getActiveProfile() return self.cfg.currentHealBotProfile end

--- HealBot.lua:612-619.  (vBot's own validation cannot actually accept numeric
--- strings -- `n < 1` on a string raises before tonumber helps -- so we take the
--- pseudocode's stricter, safer form and say so.)
function H:setActiveProfile(n)
    if type(n) ~= 'number' or n < 1 or n > 5 then
        error('[HealBot] wrong profile parameter!', 2)
    end
    self.cfg.currentHealBotProfile = n
    return n
end

function H:save()
    if self.bot.config and self.bot.config.saveHealBot then
        return self.bot.config:saveHealBot(self.cfg)
    end
    return nil, 'no config store'
end

-- ---------------------------------------------------------------------------
-- enable / disable
-- ---------------------------------------------------------------------------
function H:isOn()
    if not self.enabled then return false end
    local p = self:profile()
    return (p and p.enabled) and true or false
end
function H:enable()  self.enabled = true;  return self end
function H:disable() self.enabled = false; return self end
function H:isModuleOn() return self.enabled == true end

-- ---------------------------------------------------------------------------
-- player accessors
-- ---------------------------------------------------------------------------
function H:now() return self.bot.now or self.bot.clock() end

function H:player() return self.state and self.state.player or nil end

function H:hp()   local p = self:player(); return (p and p.health) or 0 end
function H:mana() local p = self:player(); return (p and p.mana)   or 0 end

--- manapercent() -- functions/player.lua:8-15: 100 when maxMana <= 1 (knights).
function H:manapercent()
    local p = self:player()
    if not p then return 100 end
    local mx = p.maxMana or 0
    if mx <= 1 then return 100 end
    return floor((p.mana or 0) * 100 / mx)
end

--- hppercent() -- see deviation 6 in the header.
function H:hppercent()
    local p = self:player()
    if not p then return 101 end
    local src = self.hpPercentSource
    if src ~= 'derived' then
        local c = self.state.creatures and self.state.creatures[p.id]
        local hpp = c and c.healthPercent
        if type(hpp) == 'number' then return hpp end
        if src == 'server' then return 101 end
    end
    local mx = p.maxHealth or 0
    if mx > 0 then return floor((p.health or 0) * 100 / mx) end
    return 101                       -- Creature::m_healthPercent{101}: fail CLOSED
end

--- hasCondition(bit) -- player_conditions.lua:7.  statesLo with bit.band; the
--- combined u64 double would be wrong (healbot.md Pitfalls).
function H:hasCond(mask)
    local p = self:player()
    if not p then return false end
    local lo = p.statesLo
    if lo == nil then lo = (p.states or 0) % 4294967296 end
    return band(lo, mask) ~= 0
end

function H:isInPz() return self:hasCond(PS.Pz) end

--- BOT.md: never fire while dead or not in game.
function H:playable()
    local p = self:player()
    if not p then return false end
    if p.isDead then return false end
    if (p.maxHealth or 0) > 0 and (p.health or 0) <= 0 then return false end
    if not p.pos then return false end
    if self.bot.inGame == false then return false end
    return true
end

function H:standTime() return self:now() - (self.lastPosChange or 0) end

-- ---------------------------------------------------------------------------
-- burst damage -- vlib.lua:44-78
-- ---------------------------------------------------------------------------
function H:_recordDamage(text)
    local t = tostring(text or ''):lower()
    if not t:find('you lose', 1, true) then return end
    if not t:find('due to', 1, true) then return end
    local n = tonumber(t:match('%d+'))       -- FIRST number only
    if not n then return end
    local T = self:now()
    local d = self.dmg
    if self.vbotBurstPrune then
        -- vlib.lua:54-58 verbatim: removing while forward-iterating skips entries.
        local k = 1
        while k <= #d do
            if T - d[k].t > 3000 then table.remove(d, k) end
            k = k + 1
        end
    else
        for i = #d, 1, -1 do if T - d[i].t > 3000 then table.remove(d, i) end end
    end
    d[#d + 1] = { d = n, t = T }
    self.lastDmgMessage = T
    -- vlib.lua:61-63 -- the scheduled full wipe, the ONLY thing that returns the
    -- burst value to 0 once damage stops (VERIFIER).
    self.bot:schedule(3050, function()
        if self:now() - self.lastDmgMessage > 3000 then self.dmg = {} end
    end)
end

function H:burstDamageValue()
    local d = self.dmg
    if #d < 2 then return 0 end
    local sum = 0
    for i = 1, #d do sum = sum + d[i].d end
    local dt = (self:now() - d[1].t) / 1000
    -- deviation 8: vBot divides by zero here and returns `inf`.
    if dt <= 0 then return self.vbotBurstInfinity and math.huge or 0 end
    return math.ceil(sum / dt)
end

-- ---------------------------------------------------------------------------
-- rule evaluation -- HealBot.lua:693-713 / :781-800
-- ---------------------------------------------------------------------------
function H:sourceValue(origin)
    if origin == 'HP%'   then return self:hppercent()
    elseif origin == 'HP'    then return self:hp()
    elseif origin == 'MP%'   then return self:manapercent()
    elseif origin == 'MP'    then return self:mana()
    elseif origin == 'burst' then return self:burstDamageValue()
    end
    return nil                       -- an unknown origin can never fire
end

--- The comparisons are NOT what the UI labels say: '>' is >=, '<' is <=.
function H:matches(entry)
    local v = self:sourceValue(entry.origin)
    if v == nil then return false end
    local sign, want = entry.sign, entry.value
    if sign == '='     then return v == want
    elseif sign == '>' then return v >= want          -- INCLUSIVE
    elseif sign == '<' then return v <= want          -- INCLUSIVE
    end
    return false
end

-- ---------------------------------------------------------------------------
-- cooldown gates
-- ---------------------------------------------------------------------------
--- healSpellCooldownReady -- HealBot.lua:645-669.
function H:healSpellCooldownReady(words)
    local p = self:profile()
    if not p.Cooldown then return true end               -- gating disabled entirely
    local rem = self.sh:realSpellRemaining(words)
    if rem == nil then
        -- vBot: canCast(spellText, true, false) -- ignoreRL TRUE, so the level/mana
        -- recheck is skipped on this path (VERIFIER nuance on §2.1).
        if self.hiddenCooldownWindow then return true end
        return self.sh:canCast(words, true, false)
    end
    return rem <= self.sh:rawPing()                      -- fire early by exactly one RTT
end

function H:groupCooldownActive(gid)
    if self.hiddenCooldownWindow then return false end
    return self.sh:groupCooldownActive(gid)
end

function H:spellCooldownActive(words)
    if self.hiddenCooldownWindow then return false end
    return self.sh:spellCooldownActive(words)
end

function H:canCast(words, ignoreRL, ignoreCd)
    if self.hiddenCooldownWindow then return self.sh:canCast(words, ignoreRL, true) end
    return self.sh:canCast(words, ignoreRL, ignoreCd)
end

-- ---------------------------------------------------------------------------
-- actions
-- ---------------------------------------------------------------------------
function H:_say(words, kind)
    self.lastAction = { kind = kind or 'spell', what = words, at = self:now() }
    return self.sh:say(words)
end

--- useHealItem(itemId) -- HealBot.lua:724-745.  The AttackBot gates are
--- RE-CHECKED here and recordLocalUseCooldown fires BEFORE the send.
function H:useHealItem(itemId)
    local T, sh = self:now(), self.sh
    if T < sh.attackBotFiringUntil or T < sh.attackBotRuneReadyUntil then return false end
    if T - self.lastHealItemUse < 50 then return false end      -- same-tick double-send guard
    self.lastHealItemUse = T
    sh:recordLocalUseCooldown()
    self.counts.itemUses = self.counts.itemUses + 1
    self.lastAction = { kind = 'item', what = itemId, at = T }
    local p = self:player()
    sh:useOnCreature(itemId, p and p.id or 0)
    return true
end

-- ===========================================================================
-- LOOP 1 -- spells, 50 ms (HealBot.lua:687-717)
-- ===========================================================================
function H:spellTick()
    if not self:isOn() or not self:playable() then return end
    local p = self:profile()
    local mana = self:mana()
    for i = 1, #p.spellTable do
        local e = p.spellTable[i]                          -- ARRAY ORDER == PRIORITY
        if e.enabled and (e.cost or 0) < mana then         -- STRICT <
            if self:healSpellCooldownReady(e.spell) then
                if self:matches(e) then
                    self.counts.spellCasts = self.counts.spellCasts + 1
                    self:_say(e.spell, 'spell')
                    if self.optimisticSpellCooldown then
                        local d = self.sh:spellData(e.spell)
                        if d and d.id then
                            self.sh.cdSpell[d.id] = { dur = d.exhaustion or 1000,
                                                      start = self:now() }
                        end
                    end
                    return e                               -- ONE cast per tick
                end
            end
        end
    end
end

-- ===========================================================================
-- LOOP 2 -- items, 100 ms (HealBot.lua:748-805)
-- The guard ORDER is behaviour and must be preserved: a busy slot costs a whole
-- 100 ms tick before any rule is even looked at.
-- ===========================================================================
function H:itemTick()
    if not self:isOn() or not self:playable() then return end
    local T, sh = self:now(), self.sh
    if T < self.itemLoopBlockedUntil then return end        -- executor.lua delay()
    if self.standByItemsEnabled and self.standByItems then return end
    local p = self:profile()
    if #p.itemTable == 0 then return end
    if sh:getMultiUseCooldown() > 0 then return end         -- shared 1 s slot busy
    if T < sh.attackBotFiringUntil then return end          -- AttackBot has priority
    if T < sh.attackBotRuneReadyUntil then return end       -- a rune is ready, waiting

    if self:targetBotLooting() and p.Interval then
        -- HealBot.lua:767-773.  delay() postpones the NEXT invocation only; this
        -- pass runs on.  MessageDelay = true means the SHORTER 200 ms throttle.
        self.itemLoopBlockedUntil = T + (p.MessageDelay and 200 or 700)
    end

    for i = 1, #p.itemTable do
        local e = p.itemTable[i]
        -- vBot evaluates hasItemAvailable for EVERY entry before the enabled
        -- check (HealBot.lua:779); behaviourally identical, cheaper this way.
        if e.enabled and (not p.Visible or sh:hasItemAvailable(e.item)) then
            if self:matches(e) then
                self:useHealItem(e.item)
                return e            -- the tick is consumed even when the send was refused
            end
        end
    end
    if self.standByItemsEnabled then self.standByItems = true end
end

--- TargetBot.isOn() and #TargetBot.Looting.getStatus() > 0.
function H:targetBotLooting()
    if self.opts.targetBotLooting ~= nil then
        local v = self.opts.targetBotLooting
        if type(v) == 'function' then return v() and true or false end
        return v and true or false
    end
    local tb = self.bot.modules and self.bot.modules.targetbot
    if not tb then return false end
    if tb.isOn and not tb:isOn() then return false end
    if tb.isLooting then local ok, r = pcall(tb.isLooting, tb); return ok and r or false end
    return false
end

--- TargetBot.isCaveBotActionAllowed() -- target.lua:186-188.  With no TargetBot
--- the documented default is TRUE (healbot.md Open questions), because false
--- plus stopHaste plus any target would suppress haste forever.
function H:caveBotActionAllowed()
    if self.opts.caveBotActionAllowed ~= nil then
        local v = self.opts.caveBotActionAllowed
        if type(v) == 'function' then return v() and true or false end
        return v and true or false
    end
    local tb = self.bot.modules and self.bot.modules.targetbot
    if tb and tb.isCaveBotActionAllowed then
        local ok, r = pcall(tb.isCaveBotActionAllowed, tb)
        if ok then return r and true or false end
    end
    return true
end

--- target() -- whatever the client is attacking.  bot/api.lua's ctx.attack keeps
--- `bot._attacking` in step; AttackBot writes the same field.
function H:hasTarget()
    if self.opts.hasTarget ~= nil then
        local v = self.opts.hasTarget
        if type(v) == 'function' then return v() and true or false end
        return v and true or false
    end
    local id = self.bot._attacking
    if not id then return false end
    return (self.state.creatures and self.state.creatures[id]) ~= nil
end

-- ===========================================================================
-- LOOP 3 -- conditions, slow, 500 ms (Conditions.lua:238-251)
-- TWO INDEPENDENT chains: a cure AND a utura/utana can both be said in one tick.
-- ===========================================================================
function H:conditionSlowTick()
    if not self.enabled or not self:playable() then return end
    local C = self:conditions()
    if not C.enabled then return end
    if self:groupCooldownActive(2) then return end          -- group 2 == Healing

    local fired = {}

    if self:hppercent() > 95 then                           -- cures only near full HP
        local mana = self:mana()
        for i = 1, #CURES do
            local c = CURES[i]
            local on = C[c.on]
            if c.on == 'curePoison' and on == nil then on = C.curePosion end   -- both keys
            if on and mana >= (C[c.cost] or 0) and self:hasCond(c.bit) then
                self.counts.cures = self.counts.cures + 1
                self:_say(c.words, 'cure')
                fired.cure = c.words
                break                                       -- elseif chain
            end
        end
    end

    -- SEPARATE statement -- NOT elseif-joined to the block above.
    local pzOk = (not C.ignoreInPz) or (not self:isInPz())
    local mana = self:mana()
    if pzOk and C.holdUtura and mana >= (C.uturaCost or 0)
       and self:canCast(C.uturaType) and self:hppercent() < 90 then
        -- uturaType is the dropdown TEXT with capitals; lowercase before sending.
        self.counts.holds = self.counts.holds + 1
        self:_say(tostring(C.uturaType or ''):lower(), 'hold')
        fired.hold = 'utura'
    elseif pzOk and C.holdUtana and mana >= (C.utanaCost or 0)
       and (not self.utanaCast or (self:now() - self.utanaCast > 120000)) then
        self.counts.holds = self.counts.holds + 1
        self:_say('utana vid', 'hold')
        self.utanaCast = self:now()
        fired.hold = 'utana'
    end
    return fired
end

-- ===========================================================================
-- LOOP 4 -- conditions, fast, 50 ms (Conditions.lua:253-259)
-- A STRICT elseif chain: utamo > haste > paralysis cure, exactly one per tick.
-- ===========================================================================
function H:conditionFastTick()
    if not self.enabled or not self:playable() then return end
    local C = self:conditions()
    if not C.enabled then return end
    local pzOk = (not C.ignoreInPz) or (not self:isInPz())
    local mana = self:mana()

    -- VERIFIER: PlayerStates.NewManaShield DOES exist (bit 26).  Gating on bit 16
    -- alone re-casts 'utamo vita' every 50 ms forever once the server sets it.
    local shielded = self:hasCond(PS.ManaShield) or self:hasCond(PS.NewManaShield)

    if pzOk and C.holdUtamo and mana >= (C.utamoCost or 0) and not shielded then
        self.counts.holds = self.counts.holds + 1
        self:_say('utamo vita', 'hold')
        return 'utamo'

    -- Conditions.lua:256 has the redundant pair `standTime() < 5000 ... < 3000`;
    -- only the 3000 ms bound matters, i.e. haste is recast only while moving.
    elseif pzOk and self:standTime() < 3000
       and C.holdHaste and mana >= (C.hasteCost or 0)
       and not self:hasCond(PS.Haste)
       and not self:spellCooldownActive(C.hasteSpell)
       and (not self:hasTarget() or not C.stopHaste or self:caveBotActionAllowed()) then
        self.counts.holds = self.counts.holds + 1
        self:_say(C.hasteSpell, 'hold')
        return 'haste'

    -- The paralysis cure lives HERE, third in the chain, with NO PZ gate.
    elseif C.cureParalyse and mana >= (C.paralyseCost or 0) and self:hasCond(PS.Paralyze)
       and not self:spellCooldownActive(C.paralyseSpell) then
        self.counts.cures = self.counts.cures + 1
        self:_say(C.paralyseSpell, 'cure')
        return 'paralyse'
    end
end

--- Run all four loops once, in the documented intra-tick order.  Only used by
--- tests and by `:tick()`; production drives them as four separate macros so the
--- real 500/100/50 ms cadences apply.
function H:tick()
    self:conditionSlowTick()
    self:conditionFastTick()
    self:spellTick()
    self:itemTick()
end

-- ---------------------------------------------------------------------------
-- wiring
-- ---------------------------------------------------------------------------
function H:_hookEvents()
    local ev = self.events
    if not ev then return end
    shared.evOn(ev, 'textMessage', function(d) self:_recordDamage(d and d.text) end)
    shared.evOn(ev, 'positionChange', function()
        self.lastPosChange = self:now()                     -- vlib.lua:7, :20-26
    end)
    -- standByItems is cleared by health/mana events (HealBot.lua:809-817); only
    -- meaningful when opts.standByItems restored the flag.
    shared.evOn(ev, 'healthChange', function(d)
        self.standByItems = false
        -- REVIEW FIX: proto/parser.lua sets player.isDead = true on 0x28 and NOTHING
        -- in the tree ever clears it except state:reset() (i.e. a whole new session).
        -- A resurrection / custom death message / reconnect that reuses LC.state would
        -- otherwise disable every heal loop for good, silently.  Demonstrably-alive
        -- health clears it.
        if d and (d.health or 0) > 0 then
            local p = self:player()
            if p then p.isDead = false end
        end
    end)
    shared.evOn(ev, 'manaChange',   function() self.standByItems = false end)
end

--- Registration order IS the intra-tick send order (executor.lua:199 and the
--- VERIFIER's load-order note: Conditions loads before HealBot).
function H:_registerMacros()
    local b = self.bot
    if not b.macro then return end
    self.macros = {
        b:macro(500, function() self:conditionSlowTick() end),
        b:macro(50,  function() self:conditionFastTick() end),
        b:macro(20,  function() self:spellTick() end),      -- clamped to 50 ms
        b:macro(100, function() self:itemTick() end),
    }
    return self.macros
end

-- ---------------------------------------------------------------------------
-- status (BOT.md)
-- ---------------------------------------------------------------------------
function H:status()
    local p = self:profile()
    local C = self:conditions()
    return {
        on       = self:isOn(),
        module   = self.enabled,
        profile  = self.cfg.currentHealBotProfile,
        profileName = p and p.name,
        rules    = { spells = p and #p.spellTable or 0, items = p and #p.itemTable or 0 },
        conditions = C and C.enabled or false,
        lastAction = self.lastAction,
        counts   = self.counts,
        burst    = self:burstDamageValue(),
        hpPercent = self:hppercent(),
        manaPercent = self:manapercent(),
        useSlotMs = self.sh:getMultiUseCooldown(),
    }
end

healbot.H = H
return healbot
