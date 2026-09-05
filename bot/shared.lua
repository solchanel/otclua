--[[============================================================================
bot/shared.lua -- the cross-module state HealBot and AttackBot BOTH need.

Work item M1.  Behaviour source: docs/vbot/healbot.md and docs/vbot/attackbot.md
(their "## VERIFIER (Corrections)" sections override the spec bodies).

WHY THIS FILE EXISTS
--------------------
vBot duplicates one identical block -- `SharedUseCooldown`, `USE_COOLDOWN_MS`,
`recordLocalUseCooldown`, `getPingCompensation`, `getMultiUseCooldown`,
`SpellCooldownCache`, `getRealSpellRemaining`, `getRawPing`, plus the two
handshake globals `AttackBotFiringUntil` / `AttackBotRuneReadyUntil` -- verbatim
into HealBot.lua:20-46 and AttackBot.lua:24-50, guarded so whichever chunk loads
first wins (healbot.md Pitfalls; the VERIFIER confirms HealBot wins on this
install because _Loader.lua loads it at index 15 vs AttackBot at 17).

docs/vbot/attackbot.md Pitfalls is explicit about the port:

    "The shared 1 s use-cooldown is entirely client-side and optimistic ... It is
     duplicated verbatim in AttackBot.lua, so in a port it MUST be one module
     owned by neither -- two copies with independent expiresAt values will let a
     rune and a potion collide."

So it lives here.  `shared.attach(bot)` is idempotent: the first caller builds
the singleton on `bot._shared`, everybody else gets the same table.

WHAT IT OWNS
------------
* SharedUseCooldown        the optimistic client-side 1000 ms "use anything"
                           slot.  Written the instant a rune or potion packet
                           goes out, NEVER from a server confirmation
                           (HealBot.lua:11-19 refuses to trust one).  We DO
                           additionally honour opcode 0xA6 MultiUseDelay, which
                           luaclient decodes (parser.lua:1877-1879) -- a
                           deliberate, documented improvement, see `opts.useA6`.
* AttackBotFiringUntil     AttackBot -> HealBot handshake (AB:2697/2833/2868/
  AttackBotRuneReadyUntil  2891/2903/2927/3086, read at HealBot.lua:728/757/765)
* SpellCooldownCache       from the `spellCooldown` (0xA4) and
                           `spellGroupCooldown` (0xA5) events, keyed by the
                           spell's PROTOCOL id and by "group_"..groupId.
* getRealSpellRemaining    MAX over the spell's own remaining and EVERY group
                           remaining (HealBot.lua:95-120 / AB:104-137).
* canCast                  vlib.lua:279-306, including the `return true` tail for
                           a formula the spell DB does not know.
* say                      player.lua:90 -> gameinterface.lua:479-524: a KNOWN
                           spell goes out as talkSpell(words, aim 3) with no
                           position; anything else is a plain Say with aim 0.
* hasItemAvailable         vlib.lua:863-887, max(0xF5 server count, visible scan).
* ping                     luaclient has no g_game.getPing(); we measure the
                           0x1D/0x1E round trip, or take `state.ping` when the
                           client already tracks one.  Before the first sample
                           the value is 0, the conservative choice the spec's
                           Open Questions recommend (fire exactly on cooldown,
                           never early).

The spell database is data/spells1530.lua, generated verbatim from
modules/gamelib/spells.lua SpellInfo['Default'] by tools/extract_vbot_data.lua
(vlib.lua:278 hardcodes the 'Default' profile).  vBot's SECOND lookup path --
`vBot.customCooldowns`, learned by correlating the last self-uttered phrase with
the next 0xA4/0xA5 (vlib.lua:302-357) -- is implemented too, so custom-server
formulas become predictable after their first cast instead of staying forever
"unknown" (a VERIFIER correction against both spec bodies).
============================================================================]]

local shared = {}

local USE_COOLDOWN_MS = 1000          -- HealBot.lua:29 / AB:33, fixed & authoritative

local ok_db, SPELLDB = pcall(require, 'data.spells1530')
if not ok_db or type(SPELLDB) ~= 'table' then SPELLDB = {} end
shared.SPELLDB = SPELLDB
shared.USE_COOLDOWN_MS = USE_COOLDOWN_MS

-- ---------------------------------------------------------------------------
-- event-bus shim: LC.events is the module singleton (dot-called) while
-- lib/events.new() returns a Bus instance (colon-called).  bot/api.lua carries
-- the same shim; keep both working.
-- ---------------------------------------------------------------------------
local function evOn(ev, name, fn)
    if type(ev) ~= 'table' or type(ev.on) ~= 'function' then return nil end
    if getmetatable(ev) ~= nil then return ev:on(name, fn) end
    return ev.on(name, fn)
end
shared.evOn = evOn

-- ---------------------------------------------------------------------------
local S = {}
S.__index = S

--- shared.attach(bot [, opts]) -> the singleton
--- opts.useA6   honour opcode 0xA6 MultiUseDelay (default true; see header)
--- opts.ping    a fixed RTT in ms, for tests
function shared.attach(b, opts)
    if b._shared then return b._shared end
    opts = opts or {}

    local self = setmetatable({}, S)
    self.bot    = b
    self.state  = b.state
    self.sender = b.sender
    self.events = b.events

    self.useCooldownExpiresAt    = 0        -- SharedUseCooldown.expiresAt
    self.attackBotFiringUntil    = 0        -- AB:166
    self.attackBotRuneReadyUntil = 0        -- AB:167

    self.cdSpell = {}          -- [protocol spell id] = { dur, start }
    self.cdGroup = {}          -- [group id]          = { dur, start }
    self.custom  = {}          -- vBot.customCooldowns: [words] = { id, group }
    self.castTable = {}        -- vlib SpellCastTable:  [words] = { t, d }

    self.ping = tonumber(opts.ping) or 0
    self._pingSentAt = nil
    self.useA6 = (opts.useA6 ~= false)

    self.sends = 0             -- diagnostics only

    b._shared = self
    self:_hook()
    return self
end

function S:now()
    local b = self.bot
    -- `now` is the per-tick snapshot (executor.lua:196), which is what every
    -- vBot comparison reads.  Outside a tick (event callbacks, tests that never
    -- started the bot) fall back to the live clock.
    return b.now or b.clock()
end

-- ---------------------------------------------------------------------------
-- wire hooks
-- ---------------------------------------------------------------------------
function S:_hook()
    local ev = self.events
    if not ev then return end
    local b = self.bot

    evOn(ev, 'spellCooldown', function(d)
        if not d then return end
        local id, ms = d.spellId or d.iconId, d.delay or d.duration
        if not (id and ms) then return end
        self.cdSpell[id] = { dur = ms, start = b.clock() }
        -- vBot.customCooldowns learning (vlib.lua:309-324)
        local w = b._lastPhrase
        if w and not SPELLDB[w] then
            local e = self.custom[w]
            if not e then e = {}; self.custom[w] = e end
            e.id = id
        end
    end)

    evOn(ev, 'spellGroupCooldown', function(d)
        if not d then return end
        local id, ms = d.groupId or d.iconId, d.delay or d.duration
        if not (id and ms) then return end
        self.cdGroup[id] = { dur = ms, start = b.clock() }
        local w = b._lastPhrase
        if w and not SPELLDB[w] then
            local e = self.custom[w]
            if not e then e = {}; self.custom[w] = e end
            e.group = e.group or {}
            e.group[id] = ms
        end
    end)

    -- 0xA6 MultiUseDelay.  vBot asserts g_game.onMultiUseCooldown never fires on
    -- this build (HealBot.lua:11-19) and therefore models the slot purely
    -- optimistically; luaclient DOES decode the opcode, so when the server
    -- speaks we believe it (opts.useA6 = false restores strict vBot parity).
    evOn(ev, 'multiUseCooldown', function(d)
        if not self.useA6 or not d or not d.delay then return end
        self.useCooldownExpiresAt = math.max(self.useCooldownExpiresAt, b.clock() + d.delay)
    end)

    -- own-talk: refresh SpellCastTable and remember the phrase for the
    -- customCooldowns correlation (vlib.lua:248-256, :302-307).
    evOn(ev, 'talk', function(d)
        local p = self.state and self.state.player
        if not d or not p or not d.name or not p.name then return end
        if tostring(d.name):lower() ~= tostring(p.name):lower() then return end
        local w = tostring(d.text or ''):lower()
        b._lastPhrase = w
        local rec = self.castTable[w]
        if rec then rec.t = b.clock() end
    end)

    -- RTT measurement: luaclient has no g_game.getPing().
    evOn(ev, 'pingBack', function()
        if self._pingSentAt then
            self.ping = math.max(0, b.clock() - self._pingSentAt)
            self._pingSentAt = nil
        end
    end)
end

--- Send a Ping (0x1D) and start the stopwatch.  Optional -- nothing calls it
--- automatically; a control plane or a module opt can drive it.
function S:probePing()
    local snd = self.sender
    if not snd or not snd.ping then return false end
    self._pingSentAt = self.bot.clock()
    snd:ping()
    return true
end

--- getRawPing() -- HealBot.lua:122-126 / AB:157-161.
function S:rawPing()
    local st = self.state
    if st and type(st.ping) == 'number' then return st.ping end
    return self.ping or 0
end

--- getPingCompensation() -- HealBot.lua:48-56 / AB:52-60.
function S:pingCompensation()
    local p = self:rawPing()
    return p > 150 and (p - 30) or 0
end

-- ---------------------------------------------------------------------------
-- the shared 1 s use slot
-- ---------------------------------------------------------------------------
function S:recordLocalUseCooldown(ms)
    self.useCooldownExpiresAt = math.max(self.useCooldownExpiresAt,
                                         self:now() + (ms or USE_COOLDOWN_MS))
    return self.useCooldownExpiresAt
end

function S:getMultiUseCooldown()
    return math.max(0, self.useCooldownExpiresAt - self:now() - self:pingCompensation())
end

-- ---------------------------------------------------------------------------
-- spell data + cooldown prediction
-- ---------------------------------------------------------------------------
--- getSpellData(words) -- vlib.lua:333-360: the static table first, then the
--- runtime-learned vBot.customCooldowns (synthetic mana 1 / level 1).
function S:spellData(words)
    if type(words) ~= 'string' then return nil end
    local w = words:lower()
    local d = SPELLDB[w]
    if d then return d end
    local c = self.custom[w]
    if c and c.id then return { id = c.id, mana = 1, level = 1, group = c.group } end
    return nil
end

--- getRealSpellRemaining(words) -- HealBot.lua:95-120 / AB:104-137.
--- nil when there is no cooldown information at all.
function S:realSpellRemaining(words)
    local d = self:spellData(words)
    if not d then return nil end
    local T, rem = self:now(), nil
    local own = d.id ~= nil and self.cdSpell[d.id] or nil
    if own then rem = own.dur - (T - own.start) end
    for gid in pairs(d.group or {}) do
        local g = self.cdGroup[gid]
        if g then
            local gr = g.dur - (T - g.start)
            if not rem or gr > rem then rem = gr end     -- MAX, not min
        end
    end
    return rem
end

--- getRealGroupRemaining(gid) -- AB:150-154.
function S:realGroupRemaining(gid)
    local g = self.cdGroup[gid]
    if not g then return nil end
    return g.dur - (self:now() - g.start)
end

--- isGroupCooldownIconActive(gid).
function S:groupCooldownActive(gid)
    local r = self:realGroupRemaining(gid)
    return r ~= nil and r > 0
end

--- isCooldownIconActive(spellId).
function S:spellIconActive(spellId)
    local c = self.cdSpell[spellId]
    if not c then return false end
    return (c.dur - (self:now() - c.start)) > 0
end

--- getSpellCoolDown(words) -- vlib.lua:363-384: the spell's OWN icon plus every
--- group in its data (the VERIFIER notes the spec only mentioned the group form).
function S:spellCooldownActive(words)
    local d = self:spellData(words)
    if not d then return false end
    if d.id and self:spellIconActive(d.id) then return true end
    for gid in pairs(d.group or {}) do
        if self:groupCooldownActive(gid) then return true end
    end
    return false
end

--- canCast(spell, ignoreRL, ignoreCd) -- vlib.lua:279-306.
---   1. a cast()-managed spell -> now - t > d, or ignoreCd
---   2. a known formula        -> (ignoreCd or not on cooldown)
---                                and (ignoreRL or level/mana are met)
---   3. anything else          -> TRUE  (vlib.lua:299)
function S:canCast(spell, ignoreRL, ignoreCd)
    if type(spell) ~= 'string' then return false end
    local w = spell:lower()
    local rec = self.castTable[w]
    if rec then return (self:now() - rec.t) > rec.d or ignoreCd == true end
    local d = self:spellData(w)
    if d then
        local cdOk = (ignoreCd == true) or not self:spellCooldownActive(w)
        local rlOk = (ignoreRL == true)
        if not rlOk then
            local p = self.state and self.state.player or {}
            rlOk = (p.level or 0) >= (d.level or 1) and (p.mana or 0) >= (d.mana or 0)
        end
        return cdOk and rlOk
    end
    return true
end

-- ---------------------------------------------------------------------------
-- sends
-- ---------------------------------------------------------------------------
--- say(words) -- functions/player.lua:90-101 -> gameinterface.lua:479-524.
--- A formula the client's spell list knows goes out as an aimed spell
--- (SpellAimTarget = 3, no position appended); anything else is a plain Say
--- with aim byte 0 (VERIFIER correction against attackbot.md 3.10).
function S:say(words)
    local snd = self.sender
    if not snd or type(words) ~= 'string' or #words == 0 then return nil, 'no sender' end
    self.sends = self.sends + 1
    self.bot._lastPhrase = words:lower()
    if SPELLDB[words:lower()] then
        return snd:talkSpell(words, 3)
    end
    return snd:talk(1, 0, '', words, 0)
end

--- castSpellAt(words, pos) -- talkSpell(text, SpellAimCursor = 2, pos).
function S:sayAt(words, pos)
    local snd = self.sender
    if not snd or type(words) ~= 'string' or #words == 0 then return nil, 'no sender' end
    self.sends = self.sends + 1
    self.bot._lastPhrase = words:lower()
    return snd:talkSpell(words, 2, pos)
end

--- cast(text, delayMs) -- vlib.lua:258-277.  delay nil or < 100 => a plain say.
function S:cast(text, delayMs)
    if type(text) ~= 'string' then return nil end
    local w = text:lower()
    if not delayMs or delayMs < 100 then return self:say(w) end
    local rec = self.castTable[w]
    if not rec or rec.d ~= delayMs then
        self.castTable[w] = { t = self:now() - delayMs, d = delayMs }
        return self:say(w)
    end
    -- NOTE: vBot does NOT stamp rec.t here (vlib.lua:270-271).  The timestamp is
    -- refreshed only by the own-talk echo, so an un-echoed cast keeps re-firing
    -- every tick.  Reproduced verbatim.
    if (self:now() - rec.t) > rec.d then return self:say(w) end
    return nil
end

-- The inventory sentinel: game.cpp:900-902 sends Position(0xFFFF, 0, 0) with
-- stackpos 0 -- note y is 0, NOT the item id.
shared.INV_POS = { x = 0xFFFF, y = 0, z = 0 }

--- useInventoryItemWith(itemId, <creature>) for clientVersion >= 780.
function S:useOnCreature(itemId, creatureId)
    local snd = self.sender
    if not snd then return nil, 'no sender' end
    self.sends = self.sends + 1
    return snd:useOnCreature(shared.INV_POS, itemId, 0, creatureId)
end

--- useInventoryItemWith(itemId, <tile thing>).
function S:useOnThing(itemId, tilePos, thingId, thingStack)
    local snd = self.sender
    if not snd then return nil, 'no sender' end
    self.sends = self.sends + 1
    return snd:useWith(shared.INV_POS, itemId, 0, tilePos, thingId or 0, thingStack or 0)
end

-- ---------------------------------------------------------------------------
-- item availability -- vlib.lua:863-887
-- ---------------------------------------------------------------------------
--- The server-pushed count (opcode 0xF5 -> state.inventoryCounts, keyed
--- itemId * 256 + tier, parser.lua:1429-1448).  Counts everything CARRIED,
--- including closed containers, but not depot/inbox/stash/corpses.
function S:itemAmountFromServer(id, tier)
    local c = self.state and self.state.inventoryCounts
    if not c then return nil end
    return c[id * 256 + (tier or 0)] or 0
end

--- Player:getItemsCount -- equipped slots plus OPEN containers only.
function S:itemAmountVisible(id)
    local st = self.state
    if not st then return 0 end
    local n = 0
    local p = st.player
    for _, it in pairs((p and p.inventory) or {}) do
        if type(it) == 'table' and it.id == id then n = n + (it.count or 1) end
    end
    for _, cont in pairs(st.containers or {}) do
        for _, it in ipairs(cont.items or {}) do
            if it.id == id then n = n + (it.count or 1) end
        end
    end
    return n
end

function S:itemAmount(id, tier)
    return math.max(self:itemAmountVisible(id), self:itemAmountFromServer(id, tier) or 0)
end

function S:hasItemAvailable(id, tier)
    return self:itemAmount(id, tier) > 0
end

-- ---------------------------------------------------------------------------
-- player-state bits.  PlayerStates is the Lua table from
-- modules/gamelib/player.lua:3-40, a SUPERSET of the C++ const.h enum -- the
-- VERIFIER's first correction: NewManaShield DOES exist and is 2^26.
-- ---------------------------------------------------------------------------
shared.PlayerStates = {
    None = 0, Poison = 1, Burn = 2, Energy = 4, Drunk = 8, ManaShield = 16,
    Paralyze = 32, Haste = 64, Swords = 128, Drowning = 256, Freezing = 512,
    Dazzled = 1024, Cursed = 2048, PartyBuff = 4096, PzBlock = 8192, Pz = 16384,
    Bleeding = 32768, Hungry = 65536,
    -- above the C++ enum, present in the Lua table and used live (player.lua:163)
    NewManaShield = 67108864, Agony = 134217728, Powerless = 268435456,
    Mentored = 536870912,
}

return shared
