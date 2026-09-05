--[[============================================================================
bot/api.lua -- the vBot-compatible script surface, implemented over LC.state and
LC.sender.

Work item F3.  Names and semantics come from BOT.md "bot/api.lua" and
docs/vbot/bot-core.md §3 (the "## VERIFIER (Corrections)" section overrides the
body above it).  The point of this file is that a vBot snippet ported over keeps
working: `if hppercent() < 60 and canCast("exura gran") then say("exura gran") end`.

    local ctx = api.new(bot)     -- bot = the bot/init.lua instance
    ctx.hppercent()  ctx.say("exura")  ctx.findItem(3031)  ...

`now` and `time` are LIVE NUMBERS, not functions: vBot scripts write
`now - lastThing > 500`, so they must read as the per-tick frame clock.  They are
served from the ctx metatable's __index, so they are always the value the current
tick sampled (bot-core §1.3: "context.now is sampled once per tick; every macro
in that tick sees the identical now").  `ctx.nowMs()` is the function form.

------------------------------------------------------------------------------
DELIBERATE STUBS -- functions that exist, log once, and return a sensible default
------------------------------------------------------------------------------
  depositItems(...)   the depot/deposit-all flow is a CaveBot waypoint action
                      built on NPC conversation + container moves; it belongs to
                      bot/supplies.lua + bot/cavebot.lua, not to this surface.
                      Returns false.
  withdrawItems(...)  same; returns false.
These are the only two.  Everything else in BOT.md's list is implemented.

Not part of BOT.md's list and therefore NOT provided here (documented so nobody
looks for them): every UI factory (`UI.*`, `addSwitch`, `addTextEdit`, `addIcon`,
`displayGeneralBox`, sound, screenshots, `getMapView`), the `HTTP`/`BotServer`
external I/O surface, `loadRemoteScript`, `g_ui`/`g_window`/`g_mouse` handles,
and the hotkey/keyboard dispatch -- all classified [U] or [X] in bot-core §3.6-3.7.
`bot:command()` in bot/init.lua is the headless replacement for `hotkey()`.
============================================================================]]

local api = {}

local ok_bit, bit = pcall(require, 'bit')
if not ok_bit then bit = nil end

local ok_sys, sys = pcall(require, 'lib.sys')
local realMs = (ok_sys and sys and sys.nowMs) or function() return os.clock() * 1000 end

-- ---------------------------------------------------------------------------
-- constants restated for the sandbox (functions/const.lua:3-10, 12-18, 20-33 --
-- the VERIFIER points out that a port restating only the directions leaves
-- SpellAim* and InventorySlot* nil, breaking castSpellAt and player_inventory)
-- ---------------------------------------------------------------------------
api.Directions = {
    North = 0, East = 1, South = 2, West = 3,
    NorthEast = 4, SouthEast = 5, SouthWest = 6, NorthWest = 7,
}

api.SpellAim = { None = 0, Crosshair = 1, Cursor = 2, Target = 3 }

api.InventorySlot = {
    Head = 1, Neck = 2, Back = 3, Body = 4, Right = 5, Left = 6,
    Leg = 7, Feet = 8, Finger = 9, Ammo = 10, Purse = 11,
}
api.INVENTORY_FIRST, api.INVENTORY_LAST = 1, 10       -- Purse (11) is EXCLUDED

-- modules/gamelib/player.lua:3-38
api.PlayerStates = {
    None = 0, Poison = 1, Burn = 2, Energy = 4, Drunk = 8, ManaShield = 16,
    Paralyze = 32, Haste = 64, Swords = 128, Drowning = 256, Freezing = 512,
    Dazzled = 1024, Cursed = 2048, PartyBuff = 4096, PzBlock = 8192,
    Pz = 16384, Bleeding = 32768, Hungry = 65536,
}

-- talk modes (docs/opcode-map.md / Game::talk)
local MODE = { Say = 1, Whisper = 2, Yell = 3, PrivateTo = 5, Channel = 7, NpcTo = 11 }
api.TalkMode = MODE

local INVENTORY_POS = { x = 0xFFFF, y = 0, z = 0 }

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local function band(a, b)
    if bit then
        local v = bit.band(a or 0, b or 0) % 0x100000000      -- bit.band is SIGNED
        return v
    end
    -- pure-Lua fallback (only reachable if require('bit') failed)
    local r, bitv = 0, 1
    a, b = a or 0, b or 0
    while a > 0 and b > 0 do
        if (a % 2 == 1) and (b % 2 == 1) then r = r + bitv end
        a, b, bitv = math.floor(a / 2), math.floor(b / 2), bitv * 2
    end
    return r
end

local function chebyshev(a, b)
    if not a or not b then return math.huge end
    return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y))
end

-- ===========================================================================
-- api.new(bot) -> ctx
-- ===========================================================================
function api.new(b)
    local ctx = {}
    local stubbed = {}

    local function stub(name, ret)
        if not stubbed[name] then
            stubbed[name] = true
            b:warn('api.%s is not implemented in luaclient (no-op)', name)
        end
        return ret
    end

    local function st()     return b.state end
    local function player() local s = b.state; return s and s.player or nil end
    local function snd()    return b.sender end

    -- live `now` / `time`; everything else is a plain field lookup
    setmetatable(ctx, { __index = function(_, k)
        if k == 'now' or k == 'time' then return b.now end
        return nil
    end })

    ctx.bot     = b
    ctx.storage = b.storage
    ctx.nowMs   = function() return b.now end
    ctx.realMs  = realMs

    -- ---- constants into the sandbox ---------------------------------------
    for k, v in pairs(api.Directions)    do ctx[k] = v end
    ctx.SpellAimNone, ctx.SpellAimCrosshair = 0, 1
    ctx.SpellAimCursor, ctx.SpellAimTarget  = 2, 3
    for k, v in pairs(api.InventorySlot)  do ctx['InventorySlot' .. k] = v end
    ctx.InventorySlotFirst, ctx.InventorySlotLast = 1, 10
    ctx.PlayerStates = api.PlayerStates

    -- =======================================================================
    -- engine passthrough (bot/init.lua owns the semantics)
    -- =======================================================================
    ctx.macro    = function(...) return b:macro(...) end
    ctx.schedule = function(ms, fn) return b:schedule(ms, fn) end
    ctx.delay    = function(ms) return b:delay(ms) end
    ctx.isDelayed= function(r) return b:isDelayed(r) end
    ctx.info     = function(s) b:info('%s', tostring(s)) end
    ctx.warn     = function(s) b:warn('%s', tostring(s)) end
    ctx.warning  = ctx.warn
    ctx.error    = function(s) b:error('%s', tostring(s)) end

    -- getDistanceBetween: Chebyshev, IGNORES z (executor.lua:124-126)
    ctx.getDistanceBetween = chebyshev

    -- =======================================================================
    -- player state  (functions/player.lua:3-52)
    -- =======================================================================
    ctx.getPlayer = function() return player() end
    ctx.player    = function() return player() end

    ctx.name = function() local p = player(); return p and p.name or '' end
    ctx.pos  = function() local p = player(); return p and p.pos or nil end
    ctx.posx = function() local p = ctx.pos(); return p and p.x or 0 end
    ctx.posy = function() local p = ctx.pos(); return p and p.y or 0 end
    ctx.posz = function() local p = ctx.pos(); return p and p.z or 0 end

    ctx.hp       = function() local p = player(); return p and p.health or 0 end
    ctx.maxhp    = function() local p = player(); return p and p.maxHealth or 0 end
    ctx.hpmax    = ctx.maxhp
    -- hppercent() is the SERVER-SENT percent in vBot; luaclient's 0xA0 carries
    -- absolute hp only, so we derive it -- and clamp maxHealth <= 0 to 100 the
    -- same way manapercent() guards knights (player.lua:8-15).
    ctx.hpPercent = function()
        local p = player()
        if not p or not p.maxHealth or p.maxHealth <= 0 then return 100 end
        return math.floor((p.health or 0) * 100 / p.maxHealth)
    end
    ctx.hppercent = ctx.hpPercent

    ctx.mana     = function() local p = player(); return p and p.mana or 0 end
    ctx.maxmana  = function() local p = player(); return p and p.maxMana or 0 end
    ctx.manamax  = ctx.maxmana
    ctx.manaPercent = function()
        local p = player()
        if not p then return 100 end
        -- player.lua:8-15: returns 100 when maxMana <= 1 (knights)
        if not p.maxMana or p.maxMana <= 1 then return 100 end
        return math.floor((p.mana or 0) * 100 / p.maxMana)
    end
    ctx.manapercent = ctx.manaPercent

    ctx.level  = function() local p = player(); return p and p.level or 0 end
    ctx.lvl    = ctx.level
    ctx.exp    = function() local p = player(); return p and p.exp or 0 end
    ctx.mlev   = function() local p = player(); return p and p.magicLevel or 0 end
    ctx.magic  = ctx.mlev
    ctx.mlevel = ctx.mlev
    ctx.soul   = function() local p = player(); return p and p.soul or 0 end
    ctx.stamina= function() local p = player(); return p and p.stamina or 0 end
    ctx.voc    = function() local p = player(); return p and p.vocation or 0 end
    ctx.vocation = ctx.voc
    ctx.bless  = function() local p = player(); return p and p.blessings or 0 end
    ctx.blessings = ctx.bless
    ctx.direction = function() local p = player(); return p and p.direction or 0 end
    ctx.speed  = function() local p = player(); return p and p.speed or 0 end

    ctx.cap     = function() local p = player(); return p and p.capacity or 0 end
    ctx.freecap = ctx.cap
    ctx.maxcap  = function() local p = player(); return p and p.maxCapacity or 0 end
    ctx.capmax  = ctx.maxcap

    -- ---- conditions (player_conditions.lua:7-33) ---------------------------
    ctx.hasCondition = function(mask)
        local p = player()
        if not p then return false end
        return band(p.states or 0, mask or 0) > 0
    end
    local S = api.PlayerStates
    ctx.isPoisioned      = function() return ctx.hasCondition(S.Poison) end
    ctx.isPoisoned       = ctx.isPoisioned
    ctx.isBurning        = function() return ctx.hasCondition(S.Burn) end
    ctx.isEnergized      = function() return ctx.hasCondition(S.Energy) end
    ctx.isDrunk          = function() return ctx.hasCondition(S.Drunk) end
    ctx.hasManaShield    = function() return ctx.hasCondition(S.ManaShield) end
    ctx.isParalyzed      = function() return ctx.hasCondition(S.Paralyze) end
    ctx.hasHaste         = function() return ctx.hasCondition(S.Haste) end
    ctx.hasSwords        = function() return ctx.hasCondition(S.Swords) end
    ctx.isInFight        = function() return ctx.hasCondition(S.Swords) end
    -- VERIFIER: canLogout is the NEGATION of the Swords bit, not an alias
    ctx.canLogout        = function() return not ctx.hasCondition(S.Swords) end
    ctx.isDrowning       = function() return ctx.hasCondition(S.Drowning) end
    ctx.isFreezing       = function() return ctx.hasCondition(S.Freezing) end
    ctx.isDazzled        = function() return ctx.hasCondition(S.Dazzled) end
    ctx.isCursed         = function() return ctx.hasCondition(S.Cursed) end
    ctx.hasPartyBuff     = function() return ctx.hasCondition(S.PartyBuff) end
    ctx.hasPzLock        = function() return ctx.hasCondition(S.PzBlock) end
    ctx.hasPzBlock       = ctx.hasPzLock
    ctx.isPzLocked       = ctx.hasPzLock
    ctx.isPzBlocked      = ctx.hasPzLock
    ctx.isInPz           = function() return ctx.hasCondition(S.Pz) end
    ctx.isInProtectionZone = ctx.isInPz
    ctx.hasPz            = ctx.isInPz
    ctx.isBleeding       = function() return ctx.hasCondition(S.Bleeding) end
    ctx.isHungry         = function() return ctx.hasCondition(S.Hungry) end

    ctx.isDead = function()
        local p = player()
        if not p then return false end
        if p.isDead then return true end
        return (p.maxHealth or 0) > 0 and (p.health or 0) <= 0
    end

    -- isWalking: the walk model in game/state.lua (serverPos/preWalks/walkLockUntil)
    ctx.isWalking = function()
        local p = player()
        if not p then return false end
        if p.preWalks and #p.preWalks > 0 then return true end
        if p.waitingForServerWalk then return true end
        return (p.walkLockUntil or 0) > b.now
    end

    -- =======================================================================
    -- talking  (functions/player.lua:64-160)
    -- =======================================================================
    ctx.say = function(text, aimMode, aimPos)
        local s = snd(); if not s then return nil, 'no sender' end
        if aimMode and aimMode ~= 0 then
            return s:talkSpell(text, aimMode, aimPos)
        end
        return s:talk(MODE.Say, 0, '', text)
    end
    ctx.talk = ctx.say

    ctx.castSpell = function(text, aimMode, pos)
        return ctx.say(text, aimMode, pos)
    end
    ctx.castSpellAt = function(text, pos)
        return ctx.say(text, api.SpellAim.Cursor, pos)          -- talkSpell(text, 2, pos)
    end

    ctx.yell = function(text)
        local s = snd(); if not s then return nil, 'no sender' end
        return s:talk(MODE.Yell, 0, '', text)
    end

    ctx.talkPrivate = function(to, text)
        local s = snd(); if not s then return nil, 'no sender' end
        return s:talk(MODE.PrivateTo, 0, to, text)
    end
    ctx.sayPrivate = ctx.talkPrivate

    ctx.talkChannel = function(channelId, text)
        local s = snd(); if not s then return nil, 'no sender' end
        return s:talk(MODE.Channel, channelId, '', text)
    end
    ctx.sayChannel = ctx.talkChannel

    -- version >= 810 => MessageNpcTo (11) -- 1530 always takes that branch
    ctx.talkNpc = function(text)
        local s = snd(); if not s then return nil, 'no sender' end
        return s:talk(MODE.NpcTo, 0, '', text)
    end
    ctx.sayNpc, ctx.sayNPC, ctx.talkNPC = ctx.talkNpc, ctx.talkNpc, ctx.talkNpc

    -- saySpell: ONE global rate limit shared by every caller (player.lua:139-155)
    ctx.saySpell = function(text, timeout)
        timeout = timeout or 1000
        if (b._lastSpellAt or -math.huge) + timeout > b.now then return false end
        b._lastSpellAt = b.now
        ctx.say(text)
        return true
    end
    ctx.setSpellTimeout = function() b._lastSpellAt = b.now end

    -- =======================================================================
    -- spell cooldowns + canCast  (vlib.lua:279-384; the "UI trap" is fixed:
    -- luaclient feeds spellCooldown / spellGroupCooldown straight into two
    -- absolute-deadline tables with no widget gating -- same API, strictly more
    -- correct.  We pick the NUMERIC model deliberately, as the VERIFIER asks.)
    -- =======================================================================
    b._cooldownUntil      = b._cooldownUntil      or {}   -- [iconId]  = absolute ms
    b._groupCooldownUntil = b._groupCooldownUntil or {}   -- [groupId] = absolute ms
    b._spellCastTable     = b._spellCastTable     or {}   -- cast() managed spells
    b._customCooldowns    = b._customCooldowns    or {}   -- [words] = {id=, group=}

    -- LC.events is the module singleton (dot-called); lib/events.new() returns a
    -- Bus instance (colon-called).  Support both without guessing.
    local function evOn(ev, name, fn)
        if type(ev) ~= 'table' or type(ev.on) ~= 'function' then return nil end
        if getmetatable(ev) ~= nil then return ev:on(name, fn) end
        return ev.on(name, fn)
    end

    if b.events and b.events.on and not b._cooldownHooked then
        b._cooldownHooked = true
        evOn(b.events, 'spellCooldown', function(d)
            if not d then return end
            local id, ms = d.spellId or d.iconId, d.delay or d.duration
            if id and ms then b._cooldownUntil[id] = b.clock() + ms end
            local words = b._lastPhrase
            if words and id and not b._customCooldowns[words] then
                b._customCooldowns[words] = { id = id }
            end
        end)
        evOn(b.events, 'spellGroupCooldown', function(d)
            if not d then return end
            local id, ms = d.groupId or d.iconId, d.delay or d.duration
            if id and ms then b._groupCooldownUntil[id] = b.clock() + ms end
            local words = b._lastPhrase
            local e = words and b._customCooldowns[words]
            if e and id then e.group = e.group or {}; e.group[id] = ms end
        end)
        evOn(b.events, 'talk', function(d)
            local p = player()
            if not d or not p or not d.name or not p.name then return end
            if d.name:lower() == tostring(p.name):lower() then
                b._lastPhrase = tostring(d.text or ''):lower()
                local rec = b._spellCastTable[b._lastPhrase]
                if rec then rec.t = b.now end          -- server-confirmed utterance
            end
        end)
    end

    ctx.isCooldownIconActive = function(id)
        return (b._cooldownUntil[id] or 0) > b.clock()
    end
    ctx.isGroupCooldownIconActive = function(id)
        return (b._groupCooldownUntil[id] or 0) > b.clock()
    end
    -- vlib.lua reaches these through `modules.game_cooldown` (VERIFIER); expose
    -- the same handle so ported snippets resolve.
    ctx.modules = { game_cooldown = { isCooldownIconActive = ctx.isCooldownIconActive,
                                      isGroupCooldownIconActive = ctx.isGroupCooldownIconActive } }

    ctx.getSpellData = function(words)
        if type(words) ~= 'string' then return false end
        local e = b._customCooldowns[words:lower()]
        if e then return { id = e.id, mana = 1, level = 1, group = e.group } end
        return false
    end

    ctx.getSpellCoolDown = function(words)
        local data = ctx.getSpellData(words)
        if not data then return false end
        if data.id and ctx.isCooldownIconActive(data.id) then return true end
        for gid in pairs(data.group or {}) do
            if ctx.isGroupCooldownIconActive(gid) then return true end
        end
        return false
    end

    --- canCast(spell, ignoreRL, ignoreCd)  (vlib.lua:279-300)
    ---  1. a cast()-managed spell -> now - t > d, or ignoreCd
    ---  2. a known spell          -> (ignoreCd or not on cooldown) and level/mana ok
    ---  3. otherwise              -> TRUE (an unknown spell is assumed castable)
    ctx.canCast = function(spell, ignoreRL, ignoreCd)
        if type(spell) ~= 'string' then return end
        spell = spell:lower()
        local rec = b._spellCastTable[spell]
        if rec then return (b.now - rec.t) > rec.d or ignoreCd == true end
        local data = ctx.getSpellData(spell)
        if data then
            local cdOk = ignoreCd == true or not ctx.getSpellCoolDown(spell)
            local rlOk = ignoreRL == true or
                         (ctx.level() >= (data.level or 1) and ctx.mana() >= (data.mana or 1))
            return cdOk and rlOk
        end
        return true
    end

    --- cast(text, delay): delay nil or < 100 -> a plain say.  Otherwise register
    --- `t = now - delay` so the first cast fires immediately (vlib.lua:258-271).
    ctx.cast = function(text, delayMs)
        if type(text) ~= 'string' then return end
        text = text:lower()
        if not delayMs or delayMs < 100 then return ctx.say(text) end
        local rec = b._spellCastTable[text]
        if not rec or rec.d ~= delayMs then
            -- first registration (or a changed delay) casts IMMEDIATELY
            b._spellCastTable[text] = { t = b.now - delayMs, d = delayMs }
            return ctx.say(text)
        end
        if (b.now - rec.t) > rec.d then return ctx.say(text) end
        -- inside the cooldown: upstream falls off the end, returning nil
    end

    -- =======================================================================
    -- items
    -- =======================================================================
    ctx.getInventoryItem = function(slot)
        local p = player()
        return p and p.inventory and p.inventory[slot] or nil
    end
    ctx.getSlot = ctx.getInventoryItem
    ctx.getHead   = function() return ctx.getInventoryItem(1) end
    ctx.getNeck   = function() return ctx.getInventoryItem(2) end
    ctx.getBack   = function() return ctx.getInventoryItem(3) end
    ctx.getBody   = function() return ctx.getInventoryItem(4) end
    ctx.getRight  = function() return ctx.getInventoryItem(5) end
    ctx.getLeft   = function() return ctx.getInventoryItem(6) end
    ctx.getLeg    = function() return ctx.getInventoryItem(7) end
    ctx.getFeet   = function() return ctx.getInventoryItem(8) end
    ctx.getFinger = function() return ctx.getInventoryItem(9) end
    ctx.getAmmo   = function() return ctx.getInventoryItem(10) end
    ctx.getPurse  = function() return ctx.getInventoryItem(11) end

    ctx.getContainers = function()
        local s = st()
        local out = {}
        if not s or not s.containers then return out end
        local ids = {}
        for id in pairs(s.containers) do ids[#ids + 1] = id end
        table.sort(ids)                    -- container-id order, like std::map
        for i, id in ipairs(ids) do out[i] = s.containers[id] end
        return out
    end
    ctx.getContainer = function(i) return ctx.getContainers()[i] end

    --- getBackpacks(): open containers, minus the ones that are not carried
    --- (depot/loot channels keep their own names).  A container the server
    --- reports without a name is included.
    ctx.getBackpacks = function()
        local out = {}
        for _, c in ipairs(ctx.getContainers()) do
            local n = tostring(c.name or ''):lower()
            if not (n:find('depot') or n:find('locker') or n:find('mailbox')) then
                out[#out + 1] = c
            end
        end
        return out
    end

    --- findItem(itemId, [subType=-1], [tier])  (gamelib/game.lua:5-17)
    --- Slots 1..10 first (Purse EXCLUDED), matching id and subType only -- the
    --- equipped scan IGNORES tier, while the container scan REQUIRES
    --- `item.tier == (tier or 0)`.  That asymmetry is real (VERIFIER on §3.5):
    --- findItem(id) returns a tiered equipped item but never a tiered one out of
    --- a container.
    ctx.findItem = function(itemId, subType, tier)
        subType = subType or -1
        local p = player()
        if p and p.inventory then
            for slot = api.INVENTORY_FIRST, api.INVENTORY_LAST do
                local it = p.inventory[slot]
                if it and it.id == itemId and
                   (subType == -1 or (it.count or 0) == subType) then
                    it = setmetatable({}, { __index = it })
                    it.slot, it.inventorySlot = slot, slot
                    it.pos = { x = 0xFFFF, y = slot, z = 0 }
                    it.stackPos = 0
                    return it
                end
            end
        end
        tier = tier or 0
        for _, c in ipairs(ctx.getContainers()) do
            for idx, it in ipairs(c.items or {}) do
                if it.id == itemId and (subType == -1 or (it.count or 0) == subType)
                   and (it.tier or 0) == tier then
                    local wrapped = setmetatable({}, { __index = it })
                    wrapped.containerId = c.id
                    wrapped.slot = (c.firstIndex or 0) + idx - 1
                    wrapped.stackPos = wrapped.slot
                    wrapped.pos = { x = 0xFFFF, y = 0x40 + c.id, z = wrapped.slot }
                    return wrapped
                end
            end
        end
        return nil
    end

    --- Total count of an item across equipment + every OPEN container.
    --- Non-cumulative items count 1 each.
    ctx.findItemCount = function(itemId, subType)
        subType = subType or -1
        local total = 0
        local p = player()
        if p and p.inventory then
            for slot = api.INVENTORY_FIRST, api.INVENTORY_LAST do
                local it = p.inventory[slot]
                if it and it.id == itemId and (subType == -1 or (it.count or 0) == subType) then
                    total = total + (it.count or 1)
                end
            end
        end
        for _, c in ipairs(ctx.getContainers()) do
            for _, it in ipairs(c.items or {}) do
                if it.id == itemId and (subType == -1 or (it.count or 0) == subType) then
                    total = total + (it.count or 1)
                end
            end
        end
        return total
    end
    ctx.itemAmount = function(itemId, subType) return ctx.findItemCount(itemId, subType) end

    -- ---- use / usewith ----------------------------------------------------
    local function thingPos(thing)
        if type(thing) ~= 'table' then return nil end
        if thing.pos then return thing.pos end
        if thing.x and thing.y then return thing end
        return nil
    end

    --- use(thing|itemId, [subtype])
    ---   number  -> useInventoryItem: sendUseItem({0xFFFF,0,0}, id, 0, 0)
    ---   object  -> sendUseItem(pos, id, stackpos, 0)
    ctx.use = function(thing, subtype)
        local s = snd(); if not s then return nil, 'no sender' end
        if type(thing) == 'number' then
            return s:use(INVENTORY_POS, thing, 0, 0)
        end
        local pos = thingPos(thing)
        if not pos then return nil, 'use: not a thing' end
        return s:use(pos, thing.id or 0, thing.stackPos or 0, 0)
    end

    --- usePos(pos, [stackpos]): use whatever is on that tile.  Picks the topmost
    --- item in state's tile stack when no explicit stackpos is given.
    ctx.usePos = function(pos, stackpos)
        local s = snd(); if not s then return nil, 'no sender' end
        local id = 0
        local tile = st() and st():tile(pos)
        if tile and tile.things then
            for i = #tile.things, 1, -1 do
                local t = tile.things[i]
                if t.kind == 'item' then
                    id = t.id
                    stackpos = stackpos or (i - 1)
                    break
                end
            end
        end
        return s:use(pos, id, stackpos or 0, 0)
    end

    ctx.useOnCreature = function(item, creature)
        local s = snd(); if not s then return nil, 'no sender' end
        local id = type(item) == 'number' and item or (item and item.id) or 0
        local cid = type(creature) == 'number' and creature or (creature and creature.id) or 0
        local pos, stack = INVENTORY_POS, 0
        if type(item) == 'table' then
            pos = thingPos(item) or INVENTORY_POS
            stack = item.stackPos or 0
        end
        return s:useOnCreature(pos, id, stack, cid)
    end

    --- useWith(thing, target, [subtype]).  A creature target routes to
    --- sendUseOnCreature, anything else to sendUseItemWith (Game::useWith).
    ctx.useWith = function(thing, target, subtype)
        local s = snd(); if not s then return nil, 'no sender' end
        local isCreature = type(target) == 'table' and target.id and
                           (target.isMonster ~= nil or target.isPlayer ~= nil or
                            target.healthPercent ~= nil)
        if isCreature then return ctx.useOnCreature(thing, target) end
        local fromPos, fromId, fromStack = INVENTORY_POS, 0, 0
        if type(thing) == 'number' then
            fromId = thing
        else
            fromPos  = thingPos(thing) or INVENTORY_POS
            fromId   = thing and thing.id or 0
            fromStack= thing and thing.stackPos or 0
        end
        local toPos = thingPos(target)
        if not toPos then return nil, 'useWith: no target position' end
        return s:useWith(fromPos, fromId, fromStack, toPos,
                         (type(target) == 'table' and target.id) or 0,
                         (type(target) == 'table' and target.stackPos) or 0)
    end
    ctx.usewith = ctx.useWith

    ctx.moveItem = function(item, toPos, count)
        local s = snd(); if not s then return nil, 'no sender' end
        if type(item) == 'number' then item = ctx.findItem(item) end
        if not item then return nil, 'moveItem: item not found' end
        local fromPos = thingPos(item)
        if not fromPos then return nil, 'moveItem: no source position' end
        -- count == nil defaults to the FULL stack (player_inventory.lua:34-45)
        return s:move(fromPos, item.id or 0, item.stackPos or 0, toPos,
                      count or item.count or 1)
    end

    ctx.moveToSlot = function(item, slot, count)
        return ctx.moveItem(item, { x = 0xFFFF, y = slot, z = 0 }, count)
    end

    -- ---- containers -------------------------------------------------------
    ctx.openContainer = function(item, parentContainerId)
        local s = snd(); if not s then return nil, 'no sender' end
        if type(item) == 'number' then item = ctx.findItem(item) end
        if not item then return nil, 'openContainer: item not found' end
        local pos = thingPos(item) or INVENTORY_POS
        return s:openContainer(pos, item.id or 0, item.stackPos or 0,
                               parentContainerId or 0)
    end

    ctx.closeContainer = function(container)
        local s = snd(); if not s then return nil, 'no sender' end
        local id = type(container) == 'number' and container or
                   (type(container) == 'table' and container.id) or nil
        if not id then return nil, 'closeContainer: no container id' end
        return s:closeContainer(id)
    end

    -- ---- deliberate no-ops (see the header) --------------------------------
    ctx.depositItems  = function() return stub('depositItems',  false) end
    ctx.withdrawItems = function() return stub('withdrawItems', false) end

    -- =======================================================================
    -- world / spectators
    -- =======================================================================
    -- These delegate to bot/world.lua when it has been wired up (it owns the
    -- aware-range and pattern semantics); the fallbacks below are plain scans
    -- over state.creatures so this surface is usable on its own.
    -- bot/world.lua is an INSTANCE with colon methods (world.new(client) ->
    -- w:spectators(pos, multifloor)); BOT.md writes them dot-style.  Bind either
    -- shape so wiring `bot.world = world.new(LC)` works without touching this file.
    local function W(name)
        local w = b.world
        if type(w) ~= 'table' or type(w[name]) ~= 'function' then return nil end
        if getmetatable(w) ~= nil then
            return function(...) return w[name](w, ...) end
        end
        return w[name]
    end

    local function creatures()
        local s = st()
        local out = {}
        if not s or not s.creatures then return out end
        for _, c in pairs(s.creatures) do out[#out + 1] = c end
        table.sort(out, function(x, y) return (x.id or 0) < (y.id or 0) end)
        return out
    end

    --- getSpectators([pos|creature|true], [multifloor])
    --- Upstream sniffs its arguments in two SEQUENTIAL if blocks (VERIFIER on
    --- §3.4), so `getSpectators(pos, creature)` ends up centred on the CREATURE.
    --- We keep the same outcome without the confusion: the last positional hint
    --- wins.
    ctx.getSpectators = function(param1, param2)
        local s = st()
        if not s then return {} end
        local centre, multifloor = nil, false
        if type(param1) == 'table' then
            if param1.x and param1.y then centre = param1
            elseif param1.pos then centre = param1.pos end
            param1 = param2
        end
        if type(param1) == 'table' and param1.pos then centre = param1.pos end
        if param1 == true or param2 == true then multifloor = true end
        centre = centre or ctx.pos()
        if not centre then return {} end

        local f = W('spectators')
        if f then return f(centre, multifloor) end
        local out = {}
        for _, c in ipairs(creatures()) do
            local p = c.pos
            if p and (multifloor or p.z == centre.z) then
                if s.isAwareOf == nil or s:isAwareOf(p, centre) then out[#out + 1] = c end
            end
        end
        return out
    end

    --- Linear scan over getSpectators, exactly like map.lua:39-78 -- so a
    --- creature outside the aware range is NOT found even though state may still
    --- hold it.
    ctx.getCreatureById = function(id, multifloor)
        if not id then return nil end
        for _, c in ipairs(ctx.getSpectators(nil, multifloor)) do
            if c.id == id then return c end
        end
        return nil
    end

    ctx.getCreatureByName = function(name, multifloor)
        if type(name) ~= 'string' then return nil end
        name = name:lower()
        for _, c in ipairs(ctx.getSpectators(nil, multifloor)) do
            if tostring(c.name or ''):lower() == name then return c end
        end
        return nil
    end
    ctx.getPlayerByName = function(name, multifloor)
        local c = ctx.getCreatureByName(name, multifloor)
        if c and c.isPlayer then return c end
        return nil
    end

    ctx.distanceFromPlayer = function(pos)
        local p = ctx.pos()
        if type(pos) == 'table' and pos.pos then pos = pos.pos end
        return chebyshev(p, pos)
    end

    local function filtered(pred, range, multifloor)
        local out = {}
        local me = player()
        local myId = me and me.id or 0
        local p = ctx.pos()
        for _, c in ipairs(ctx.getSpectators(nil, multifloor)) do
            if c.id ~= myId and pred(c) then
                if not range or (p and c.pos and chebyshev(p, c.pos) <= range) then
                    out[#out + 1] = c
                end
            end
        end
        return out
    end

    ctx.getMonsters = function(range, multifloor)
        local f = W('monsters'); if f then return f(ctx.pos(), range) end
        return filtered(function(c) return c.isMonster == true end, range, multifloor)
    end
    ctx.getPlayers = function(range, multifloor)
        local f = W('players'); if f then return f(ctx.pos(), range) end
        return filtered(function(c) return c.isPlayer == true end, range, multifloor)
    end
    ctx.getNpcs = function(range, multifloor)
        local f = W('npcs'); if f then return f(ctx.pos(), range) end
        return filtered(function(c) return c.isNpc == true end, range, multifloor)
    end

    -- =======================================================================
    -- movement / combat
    -- =======================================================================
    ctx.walk = function(dir)
        local s = snd(); if not s then return nil, 'no sender' end
        return s:walk(dir)
    end
    ctx.turn = function(dir)
        local s = snd(); if not s then return nil, 'no sender' end
        return s:turn(dir)
    end
    ctx.stopWalk = function()
        local s = snd(); if not s then return nil, 'no sender' end
        return s:stop()
    end
    ctx.stop = ctx.stopWalk
    ctx.autoWalk = function(dirs)
        local s = snd(); if not s then return nil, 'no sender' end
        return s:autoWalk(dirs)
    end

    local function creatureId(c)
        if type(c) == 'number' then return c end
        if type(c) == 'table' then return c.id end
        return nil
    end

    ctx.attack = function(c)
        local s = snd(); if not s then return nil, 'no sender' end
        local id = creatureId(c)
        if not id then return nil, 'attack: no creature' end
        b._attacking = id
        return s:attack(id)
    end
    ctx.follow = function(c)
        local s = snd(); if not s then return nil, 'no sender' end
        local id = creatureId(c)
        if not id then return nil, 'follow: no creature' end
        b._following = id
        return s:follow(id)
    end
    ctx.cancelAttack = function()
        local s = snd(); if not s then return nil, 'no sender' end
        b._attacking = nil
        return s:cancelAttackAndFollow()
    end
    ctx.cancelFollow = function()
        local s = snd(); if not s then return nil, 'no sender' end
        b._following = nil
        return s:cancelAttackAndFollow()
    end
    ctx.cancelAttackAndFollow = function()
        local s = snd(); if not s then return nil, 'no sender' end
        b._attacking, b._following = nil, nil
        return s:cancelAttackAndFollow()
    end
    ctx.g_attacking = function()
        return b._attacking and ctx.getCreatureById(b._attacking) or nil
    end

    ctx.logout = function()
        local s = snd(); if not s then return nil, 'no sender' end
        return s:logout()
    end
    ctx.safeLogout = ctx.logout

    ctx.setFightMode = function(fight, chase, safe, pvp)
        local s = snd(); if not s then return nil, 'no sender' end
        return s:setFightMode(fight, chase, safe, pvp)
    end

    ctx.setOutfit = function(outfit)
        local s = snd(); if not s then return nil, 'no sender' end
        s:requestOutfit()
        -- the 100 ms gap is required by the protocol handshake (player.lua:54-60)
        b:schedule(100, function() s:changeOutfit(outfit) end)
        return true
    end
    ctx.changeOutfit = ctx.setOutfit

    -- =======================================================================
    -- channels
    -- =======================================================================
    ctx.getChannels = function() local s = st(); return s and s.channels or {} end
    ctx.getChannelId = function(name)
        if type(name) ~= 'string' then return nil end
        name = name:lower()
        for id, n in pairs(ctx.getChannels()) do
            if tostring(n):lower() == name then return id end
        end
        return nil
    end
    ctx.getChannel = ctx.getChannelId

    return ctx
end

return api
