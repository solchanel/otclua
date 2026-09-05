--[[
proto/parser.lua -- server -> client packet parser for protocol 1530
                    (Gunzodus fork of mehah OTClient-Redemption, OS id 61).

  local p = parser.new(state, emit)
  p:parse(payloadString)          -- payload = one decrypted message, opcode byte first
  p.unknownOpcodeIsFatal = true   -- default

Byte-level authority, in this order:
  docs/opcode-map.md   (VERIFIER Corrections override the spec body)
  docs/map-parsing.md  (ditto)
  docs/state-events.md (ditto)
and, only where those are silent about a payload's exact shape,
D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp.

The whole point of this module is that EVERY byte of EVERY message is consumed.
Tile boundaries in map descriptions are found by peeking for a 0xFFxx marker,
not by any length prefix, so a single mis-sized item read corrupts the rest of
the stream.  When something does go wrong we raise a desync error naming the
opcode, the byte offset and the previous three opcodes handled.

The three Corrections that a naive reading of the spec body gets wrong, and
which are implemented here:
  * 0x6E OpenContainer DOES read the (isMoveable, isHolding) pair at 1530.
  * getCreature reads TWO icon lists (replace @>=1281, merge @>=1530).
  * 0xB4 TextMessage's `if text == "" then text = str() end` is unconditional
    and is the ONLY string read for every default-branch mode.
Plus the sparse-id rule: an item id inside [1, maxObjectId] that has no
appearance entry carries ZERO attribute bytes (items.flags returns 0); only
id == 0 or id > maxObjectId is an error.
]]

local buffer = require('lib.buffer')
local opcodes = require('proto.opcodes')

-- proto/items.lua is written by a different work item; tolerate its absence so
-- this module always loads (tests inject a stub through `p.items`).
local defaultItems
do
  local ok, mod = pcall(require, 'proto.items')
  if ok and type(mod) == 'table' and type(mod.flags) == 'function' then
    defaultItems = mod
  else
    defaultItems = {
      MAX_ID = 65535, COUNT = 0,
      CUMULATIVE = 0x01, WEAROUT = 0x02, EXPIRE = 0x04, CONTAINER = 0x08,
      CLASSIFY = 0x10, PODIUM = 0x20, DECOKIT = 0x40,
      flags = function() return 0 end,
      _stub = true,
    }
  end
end

local parser = {}
local P = {}
P.__index = P

-- ===========================================================================
-- Feature ids (Otc::GameFeature, const.h:540-677) that change a byte layout
-- ===========================================================================
local F_PENALITY_ON_DEATH        = 4
local F_NAME_ON_NPC_TRADE        = 5
local F_PLAYER_MOUNTS            = 12
local F_ENVIRONMENT_EFFECT       = 13
local F_CREATURE_EMBLEMS         = 14
local F_ITEM_ANIMATION_PHASE     = 15
local F_INGAME_STORE             = 73
local F_ATTACK_SEQ               = 32
local F_NEW_SPEED_LAW            = 36
local F_DOUBLE_SHOP_SELL_AMOUNT  = 39
local F_CONTAINER_PAGINATION     = 40
local F_THING_MARKS              = 41
local F_LOOKTYPE_U16             = 42
local F_PLAYER_ADDONS            = 44
local F_MESSAGE_STATEMENTS       = 45
local F_MESSAGE_LEVEL            = 46
local F_NEW_OUTFIT_PROTOCOL      = 49
local F_WRITABLE_DATE            = 51
local F_ADDITIONAL_VIP_INFO      = 52
local F_CREATURE_ICONS           = 54
local F_PREMIUM_EXPIRATION       = 57
local F_EXPERIENCE_BONUS         = 66
local F_DEATH_TYPE               = 70
local F_INGAME_STORE_HIGHLIGHTS  = 74
local F_ADDITIONAL_SKILLS        = 76
local F_PREY                     = 82
local F_THING_QUICK_LOOT         = 83
local F_THING_QUIVER             = 84
local F_THING_PODIUM             = 85
local F_THING_UPGRADE_CLASSIF    = 86
local F_THING_COUNTER            = 87
local F_THING_CLOCK              = 88
local F_THING_PODIUM_ITEM_TYPE   = 89
local F_USHORT_SPELL             = 91
local F_TOURNAMENT_PACKETS       = 92
local F_DYNAMIC_FORGE_VARIABLES  = 93
local F_CONCOCTIONS              = 94
local F_ANTHEM                   = 95
local F_VIP_GROUPS               = 96
local F_BOSSTIARY                = 97
local F_ITEM_SHADER              = 101
local F_CREATURE_SHADER          = 102
local F_CREATURE_ATTACHED_EFFECT = 103
local F_COUNT_U16                = 104
local F_EFFECT_U16               = 105
local F_CONTAINER_TYPES          = 106
local F_PLAYER_STATE_COUNTER     = 108
local F_ITEM_AUGMENT             = 110
local F_WRAP_KIT                 = 112
local F_CONTAINER_FILTER         = 113
local F_ITEM_TOOLTIP_V8          = 117
local F_WINGS_AURAS              = 118
local F_FORGE_CONVERGENCE        = 119
local F_PLAYER_FAMILIARS         = 123
local F_TILE_ADD_THING_STACKPOS  = 124
local F_FORGE_SKILL_STATS        = 126
local F_CHARACTER_SKILL_STATS    = 127
local F_CREATURE_PAPERDOLL       = 128
local F_VOCATION_MONK            = 130
local F_LEVEL_PERCENT_U16        = 131
local F_EFFECT_SOURCE            = 132
local F_TASKBOARD                = 134
local F_MAP_MOVE_POSITION        = 31
local F_MINIMAP_REMOVE           = 38
local F_CHANNEL_PLAYER_LIST      = 11

-- docs/opcode-map.md §1 "ON at 1530", minus the six explicit disables.
local FEATURES_ON_1530 = {
  22,122,125, 79,78, 42,45,63, 44,43,47,46,48,49, 51,
  1,2,6, 3,61,124, 14, 32, 4, 7,12,23, 5,8,9,10,11,
  17,21,24, 18,20, 52, 98, 62,64, 35,36, 40,58, 41,50,
  29,53, 54,55, 57, 59, 68, 66, 70, 71, 60, 65, 67, 69,
  73,75,74, 82, 121,83,96,114, 84,85,86,
  123, 90,97,88,87,89,39, 28,91,94,95, 93,
  105,106,107,108,110,111, 112,113, 119,
  127, 130, 135, 133, 132, 131,134, 136,
}

local CV = 1530   -- clientVersion
local PV = 1530   -- protocolVersion (kept separate: several gates read this one)
local OS_ID = 61
local IS_GUNZ = (OS_ID >= 60 and OS_ID <= 62)

-- data/setup.otml geometry (docs/map-parsing.md §1)
local SEA_FLOOR         = 7
local MAP_MAX_Z         = 15
local UNDERGROUND_FLOOR = 8
local AWARE_UG_RANGE    = 2
local TILE_MAX_THINGS   = 10

-- Otc::ResourceTypes_t values read as u32 rather than u64 by parseResourceBalance
-- (const.h:800-816 + protocolgameparse.cpp:885-895).  Everything else is u64.
local RESOURCE_IS_U32 = { [30]=true, [31]=true, [32]=true, [33]=true, [86]=true, [87]=true }

-- parseTalk middle-field groups, keyed by SERVER WIRE BYTE (docs/state-events.md §12)
local TALK_POS_BYTES     = { [1]=true,[2]=true,[3]=true,[9]=true,[10]=true,[12]=true,
                             [36]=true,[37]=true,[52]=true }
local TALK_CHANNEL_BYTES = { [6]=true,[7]=true,[8]=true,[14]=true }
local TALK_NONE_BYTES    = { [4]=true,[5]=true,[11]=true,[13]=true,[15]=true }

-- Otc::MarketItemDescription (const.h:832-863); at cv>=1510 the range is 1..26
local MARKET_DESC_FIRST  = 1
local MARKET_DESC_LAST   = 26
local MARKET_DESC_AUGMENT = 16

-- ===========================================================================
-- reader helpers
-- ===========================================================================
-- Peek a little-endian u16 without consuming it (the tile terminator test).
-- lib/buffer.lua offers peek16; fall back to the API.md-documented pos/setPos.
local function peek16(R)
  if R.peek16 then return R:peek16() end
  local p = R:pos()
  local v = R:u16()
  R:setPos(p)
  return v
end

local function rpos(R) return { x = R:u16(), y = R:u16(), z = R:u8() } end

local function i8(R)
  local v = R:u8()
  if v >= 128 then return v - 256 end
  return v
end

-- InputMessage::get64 -- little-endian SIGNED 64.  Decoded from raw bytes so we
-- never depend on the reader's u64 sign handling.
local function i64(R)
  local s = R:bytes(8)
  local b1,b2,b3,b4,b5,b6,b7,b8 = s:byte(1,8)
  local lo = b1 + b2*256 + b3*65536 + b4*16777216
  local hi = b5 + b6*256 + b7*65536 + b8*16777216
  if hi >= 2147483648 then          -- negative
    return -((4294967295 - hi) * 4294967296 + (4294967296 - lo))
  end
  return hi * 4294967296 + lo
end

-- readPackedCount1500 (protocolgameparse.cpp:3895-3908); protocolVersion >= 1500
local function packedCount1500(R)
  local b1 = R:u8()
  if b1 < 0x40 then return b1 end
  if b1 < 0x80 then return (b1 - 0x40) * 256 + R:u8() end
  local b2, b3, b4 = R:u8(), R:u8(), R:u8()
  return b2 * 65536 + b3 * 256 + b4
end

local function posKey(p) return p.x .. ',' .. p.y .. ',' .. p.z end

-- ===========================================================================
-- construction
-- ===========================================================================
function parser.new(state, emit)
  local self = setmetatable({}, P)
  self.state = state
  self.emit  = emit or function() end
  self.items = defaultItems
  self.unknownOpcodeIsFatal = true
  self.clientVersion   = CV
  self.protocolVersion = PV
  self.os = OS_ID
  self.isGunzOs = IS_GUNZ

  self.features = {}
  for _, id in ipairs(FEATURES_ON_1530) do self.features[id] = true end

  self.history = {}          -- last opcodes handled (most recent last)
  self.opcodeCount = 0
  self.central = nil         -- Map::m_centralPosition
  self.pendingGame = false
  self.ingame = false
  self.extendedEnabled = false
  self.pongSeen = 0

  -- aware range lives in state.world; keep the 1530 default if the state has none
  local w = state and state.world
  if w then
    w.awareRange = w.awareRange or { left = 8, top = 6, right = 9, bottom = 7 }
    self.aware = w.awareRange
  else
    self.aware = { left = 8, top = 6, right = 9, bottom = 7 }
  end
  return self
end

function P:feat(id) return self.features[id] == true end

-- ===========================================================================
-- desync reporting -- the single most valuable debugging aid in this module
-- ===========================================================================
local function opName(op)
  return opcodes.server[op] or '?'
end

function P:historyText()
  local n = #self.history
  if n == 0 then return '(none -- this was the first opcode of the session)' end
  local parts = {}
  for i = math.max(1, n - 2), n do
    local h = self.history[i]
    parts[#parts + 1] = string.format('0x%02X %s', h.op, opName(h.op))
  end
  return table.concat(parts, ' -> ')
end

function P:desync(op, opOffset, R, cause)
  return string.format(
    'PARSER DESYNC: opcode 0x%02X (%s) at offset %d of %d (%d byte(s) unread); ' ..
    'previous 3 opcodes handled: %s; cause: %s',
    op, opName(op), opOffset, self.payloadSize or -1,
    R and R:remaining() or -1, self:historyText(), tostring(cause))
end

function P:push(op, offset)
  local h = self.history
  h[#h + 1] = { op = op, offset = offset }
  if #h > 8 then table.remove(h, 1) end
  self.opcodeCount = self.opcodeCount + 1
end

-- ===========================================================================
-- state helpers (game/state.lua is touched only through its documented shape)
-- ===========================================================================
function P:player()
  local st = self.state
  st.player = st.player or {}
  st.player.skills = st.player.skills or {}
  st.player.inventory = st.player.inventory or {}
  return st.player
end

function P:creature(id, create)
  local st = self.state
  st.creatures = st.creatures or {}
  local c = st.getCreature and st:getCreature(id) or st.creatures[id]
  if not c and create then
    if st.addCreature then
      c = st:addCreature({ id = id })
    else
      c = { id = id }
      st.creatures[id] = c
    end
  end
  return c
end

function P:tileAt(p)
  local st = self.state
  if st.tile then return st:tile(p) end
  st.map = st.map or {}
  return st.map[posKey(p)]
end

function P:setTileAt(p, tile)
  local st = self.state
  if st.setTile then st:setTile(p, tile) return end
  st.map = st.map or {}
  st.map[posKey(p)] = tile
end

function P:cleanTile(p)
  local st = self.state
  if st.cleanTile then st:cleanTile(p) return end
  st.map = st.map or {}
  st.map[posKey(p)] = nil
end

-- Tile::addThing (tile.cpp:323-365).  stackPos >= 0 and <= size is a literal
-- insertion index; -1 / 255 auto-places (only creatures reach that path at
-- 1530, and creatures APPEND at cv >= 854).  After every insert the array is
-- trimmed to 11 entries: `if (preInsertSize > 10) removeThing(m_things[10])`.
--
-- game/state.lua implements exactly this (with the full stack-priority
-- auto-placement and its own creature bookkeeping), so delegate when it is
-- there; the inline version below is the fallback for the API.md minimum.
function P:addThing(p, stackPos, thing)
  local st = self.state
  if st.addThing then return st:addThing(p, stackPos, thing) end
  local tile = self:tileAt(p)
  if not tile then tile = { things = {} }; self:setTileAt(p, tile) end
  tile.things = tile.things or {}
  local things = tile.things
  local preSize = #things
  local idx
  if stackPos == nil or stackPos < 0 or stackPos == 255 then
    idx = preSize + 1
  else
    idx = stackPos + 1
    if idx > preSize + 1 then idx = preSize + 1 end
    if idx < 1 then idx = 1 end
  end
  table.insert(things, idx, thing)
  if preSize > TILE_MAX_THINGS then
    table.remove(things, TILE_MAX_THINGS + 1)   -- 0-based index 10
  end
  return stackPos
end

function P:getThingAt(p, stackPos)
  local st = self.state
  if st.getThing then return st:getThing(p, stackPos) end
  local tile = self:tileAt(p)
  return tile and tile.things and tile.things[stackPos + 1] or nil
end

function P:removeThingAt(p, stackPos)
  local st = self.state
  if st.removeThing then return st:removeThing(p, stackPos) end
  local tile = self:tileAt(p)
  if not tile or not tile.things then return nil end
  return table.remove(tile.things, stackPos + 1)
end

function P:dropCreature(id)
  local st = self.state
  local c = self:creature(id)
  if not c then return nil end
  if st.removeCreature then st:removeCreature(id) else st.creatures[id] = nil end
  self.emit('creatureDisappear', c)
  return c
end

function P:setCentral(p)
  self.central = { x = p.x, y = p.y, z = p.z }
  local pl = self:player()
  local old = pl.pos
  pl.pos = { x = p.x, y = p.y, z = p.z }
  if not old or old.x ~= p.x or old.y ~= p.y or old.z ~= p.z then
    self.emit('positionChange', { pos = pl.pos, oldPos = old })
  end
end

function P:centralPos()
  if self.central then
    return { x = self.central.x, y = self.central.y, z = self.central.z }
  end
  local pl = self.state.player
  if pl and pl.pos then return { x = pl.pos.x, y = pl.pos.y, z = pl.pos.z } end
  error('map packet before any central position was established', 0)
end

-- ===========================================================================
-- shared sub-readers: Outfit / IconList / Creature / Item / Thing / MappedThing
-- ===========================================================================

-- getOutfit (protocolgameparse.cpp:4139-4204), docs/map-parsing.md §5
function P:readOutfit(R, parseMount)
  if parseMount == nil then parseMount = true end
  local o = {}
  o.lookType = self:feat(F_LOOKTYPE_U16) and R:u16() or R:u8()
  if o.lookType ~= 0 then
    o.head, o.body, o.legs, o.feet = R:u8(), R:u8(), R:u8(), R:u8()
    o.addons = self:feat(F_PLAYER_ADDONS) and R:u8() or 0
  else
    o.lookTypeEx = R:u16()
  end
  if self:feat(F_PLAYER_MOUNTS) and parseMount then
    o.mount = R:u16()
    if self.clientVersion >= 1281 and o.mount ~= 0 then
      o.mountHead, o.mountBody, o.mountLegs, o.mountFeet = R:u8(), R:u8(), R:u8(), R:u8()
    end
  end
  -- gated on (GameWingsAurasEffectsShader && parseMount) -- OFF at 1530
  if self:feat(F_WINGS_AURAS) and parseMount then
    o.wings, o.auras, o.effects = R:u16(), R:u16(), R:u16()
    o.shader = R:string()
  end
  return o
end

-- addCreatureIcon (protocolgameparse.cpp:2358-2371): 5 bytes per entry at 1530
function P:readIconList(R)
  local n = R:u8()
  local out = {}
  for i = 1, n do
    local icon, category, count = R:u8(), R:u8(), R:u16()
    if self.clientVersion >= 1530 then R:u8() end   -- trailer, discarded
    out[i] = { icon = icon, category = category, count = count }
  end
  return out
end

-- replace = false merge semantics (docs/state-events.md §9)
local function mergeIcons(dst, src)
  if not src or #src == 0 then return dst end
  dst = dst or {}
  for _, e in ipairs(src) do
    local found
    for _, d in ipairs(dst) do
      if d.icon == e.icon and d.category == e.category then found = d break end
    end
    if found then
      if e.count > found.count then found.count = e.count end
    else
      dst[#dst + 1] = { icon = e.icon, category = e.category, count = e.count }
    end
  end
  return dst
end

-- getPaperdoll (protocolgameparse.cpp:7852-7860) -- dead at 1530 but shared
local function readPaperdoll(R)
  R:u16(); R:u8(); R:u8(); R:u8(); R:u8(); R:u8(); R:u8(); R:string()
end

-- getCreature (protocolgameparse.cpp:4248-4508), docs/map-parsing.md §4
function P:readCreature(R, ty)
  if ty == nil or ty == 0 then ty = R:u16() end
  local cv = self.clientVersion
  local known = (ty ~= 97)
  local c = { wireType = ty }

  if ty == 97 or ty == 98 then
    if known then
      c.id = R:u32()
    else
      c.removeId = R:u32()
      c.id       = R:u32()
      c.protoType = (cv >= 910) and R:u8() or 0
      if cv >= 1281 and c.protoType == 3 then c.masterId = R:u32() end
      c.name = R:string()
    end

    c.healthPercent = R:u8()
    c.direction     = R:u8()
    c.outfit        = self:readOutfit(R, true)
    c.lightIntensity = R:u8()
    c.lightColor     = R:u8()
    c.speed          = R:u16()
    if cv >= 1281 then c.icons  = self:readIconList(R) end   -- replace list
    if cv >= 1530 then c.icons2 = self:readIconList(R) end   -- merge list
    c.skull  = R:u8()
    c.shield = R:u8()
    if self:feat(F_CREATURE_EMBLEMS) and not known then c.emblem = R:u8() end
    -- creatureType is zero-INITIALISED in C++; keeping 0 here is load-bearing
    -- (docs/map-parsing.md Correction #4) so the cv>=1281 branch still reads
    -- the vocation byte when GameThingMarks is flipped off at runtime.
    local creatureType = 0
    if self:feat(F_THING_MARKS) then creatureType = R:u8() end
    c.type = creatureType
    if cv >= 1281 then
      if creatureType == 3 then c.masterId = R:u32()
      elseif creatureType == 0 then c.vocation = R:u8() end
    end
    if self:feat(F_CREATURE_ICONS) then c.icon = R:u8() end
    if self:feat(F_THING_MARKS) then
      c.mark = R:u8()
      if cv < 1281 then R:u16() end          -- helpers; not read at 1530
    end
    if cv >= 1281 then c.inspection = R:u8() end
    if cv >= 854  then c.unpass = R:u8() end
    if self:feat(F_CREATURE_PAPERDOLL) then
      for _ = 1, R:u8() do readPaperdoll(R) end
    end
    if self:feat(F_CREATURE_SHADER) then c.shader = R:string() end
    if self:feat(F_CREATURE_ATTACHED_EFFECT) then
      c.effects = {}
      for i = 1, R:u8() do c.effects[i] = R:u16() end
    end
    c.turnOnly = false

  elseif ty == 99 then                          -- creature turn: 6 bytes
    c.id = R:u32()
    c.direction = R:u8()
    if cv >= 953 then c.unpass = R:u8() end
    c.turnOnly = true
  else
    error(string.format('invalid creature marker %d', ty), 0)
  end

  self:applyCreature(c)
  return c
end

function P:applyCreature(c)
  local st = self.state
  local isNew = (self:creature(c.id) == nil)
  local rec = { id = c.id }
  if c.turnOnly then
    rec.direction = c.direction
    if c.unpass ~= nil then rec.passable = (c.unpass == 0) end
  else
    if c.name then rec.name = c.name end
    rec.healthPercent = c.healthPercent
    rec.direction     = c.direction
    rec.outfit        = c.outfit
    rec.light         = { intensity = c.lightIntensity, color = c.lightColor }
    rec.speed         = c.speed
    rec.type          = c.type
    local existing = self:creature(c.id)
    rec.icons = c.icons
    if c.icons2 then rec.icons = mergeIcons(rec.icons or (existing and existing.icons), c.icons2) end
    rec.skull  = c.skull
    rec.shield = c.shield
    if c.emblem ~= nil then rec.emblem = c.emblem end
    if c.vocation ~= nil then rec.vocation = c.vocation end
    if c.masterId ~= nil then rec.masterId = c.masterId end
    if c.icon ~= nil then rec.icon = c.icon end
    if c.mark ~= nil then rec.mark = c.mark end
    if c.unpass ~= nil then rec.passable = (c.unpass == 0) end
    -- Proto::CreatureType: 0 player, 1 monster, 2 npc, 3 own summon, 4 summon, 5 hidden
    rec.isPlayer  = (c.type == 0)
    rec.isMonster = (c.type == 1 or c.type == 3 or c.type == 4)
    rec.isNpc     = (c.type == 2)
  end

  local cr
  if st.addCreature then
    cr = st:addCreature(rec)
  else
    cr = self:creature(c.id, true)
    for k, v in pairs(rec) do cr[k] = v end
  end

  -- 0x61 UnknownCreature carries the id the server wants evicted from the cache
  if c.removeId and c.removeId ~= 0 and c.removeId ~= c.id then
    self:dropCreature(c.removeId)
  end
  if isNew then self.emit('creatureAppear', cr) end
  return cr
end

-- getItem (protocolgameparse.cpp:4510-4698) -- GUNZ ORDER, docs/map-parsing.md §4
function P:readItem(R, id)
  local IT = self.items
  if not id or id == 0 then id = R:u16() end
  local flags = IT.flags(id)                -- 0 for sparse holes: NO attribute bytes
  local it = { kind = 'item', id = id }
  local cv = self.clientVersion

  -- :4537 gunz early-out: zero attribute bytes for these two pseudo ids
  if self.isGunzOs and cv >= 1185 and (id == 3457 or id == 408) then return it end

  if cv < 1281 and self:feat(F_THING_MARKS) then R:u8() end   -- not read at 1530

  -- :4546  count / subtype (stackable | fluidContainer | splash); GameCountU16 OFF => u8
  if flags % 2 == 1 then                                       -- items.CUMULATIVE (0x01)
    it.count = self:feat(F_COUNT_U16) and R:u16() or R:u8()
  end
  if self:feat(F_ITEM_ANIMATION_PHASE) then
    -- would read u8 when animationPhases > 1; feature OFF at 1530
    it.animationPhase = nil
  end

  local hasWearOut  = math.floor(flags / IT.WEAROUT)   % 2 == 1
  local hasExpire   = math.floor(flags / IT.EXPIRE)    % 2 == 1
  local isContainer = math.floor(flags / IT.CONTAINER) % 2 == 1
  local hasClassif  = math.floor(flags / IT.CLASSIFY)  % 2 == 1
  local isPodium    = math.floor(flags / IT.PODIUM)    % 2 == 1
  local isDecoKit   = math.floor(flags / IT.DECOKIT)   % 2 == 1

  local function readCounter()   -- :4560
    if self:feat(F_THING_COUNTER) and hasWearOut then
      it.charges = R:u32(); it.isBrandNew = R:u8()
    end
  end
  local function readClock()     -- :4567
    if self:feat(F_THING_CLOCK) and hasExpire then
      it.duration = R:u32(); it.durationBrandNew = R:u8()
    end
  end
  local function readTier()      -- :4575
    if self:feat(F_THING_UPGRADE_CLASSIF) and hasClassif then it.tier = R:u8() end
  end

  if self.isGunzOs then readCounter(); readClock() end          -- :4581-4584

  if isContainer then                                            -- :4586
    if self:feat(F_CONTAINER_TYPES) then
      local ct = R:u8()
      it.containerType = ct
      if     ct == 1  then R:u32()
      elseif ct == 2  then R:u32()
      elseif ct == 3  then R:u32(); R:u32()
      elseif ct == 4  then -- client-side highlight only: 0 bytes
      elseif ct == 8  then R:u32()
      elseif ct == 9  then R:u32(); if cv >= 1332 then R:u32() end
      elseif ct == 11 then R:u32(); R:u32(); if cv >= 1332 then R:u32() end
      end
    else                                                         -- dead at 1530
      if self:feat(F_THING_QUICK_LOOT) and R:u8() ~= 0 then R:u32() end
      if self:feat(F_THING_QUIVER)     and R:u8() ~= 0 then R:u32() end
    end
  end

  if self.isGunzOs then readTier() end                           -- :4647

  if self:feat(F_THING_PODIUM) and isPodium then                 -- :4651
    local lt = R:u16()
    if lt ~= 0 then R:u8(); R:u8(); R:u8(); R:u8(); R:u8()
    elseif self:feat(F_THING_PODIUM_ITEM_TYPE) then R:u16() end
    local lm = R:u16()
    if lm ~= 0 then R:u8(); R:u8(); R:u8(); R:u8() end
    R:u8()   -- direction
    R:u8()   -- visible
  end

  if not self.isGunzOs then readTier(); readClock(); readCounter() end

  if self:feat(F_WRAP_KIT) and isDecoKit then R:u16() end        -- :4683
  if self:feat(F_ITEM_SHADER)    then it.shader  = R:string() end
  if self:feat(F_ITEM_TOOLTIP_V8) then it.tooltip = R:string() end
  return it
end

-- getThing (protocolgameparse.cpp:4206-4218)
function P:readThing(R)
  local id = R:u16()
  if id == 0 then error('invalid thing id 0', 0) end
  if id == 97 or id == 98 or id == 99 then
    local c = self:readCreature(R, id)
    return { kind = 'creature', creatureId = c.id, id = id, creature = c }
  end
  return self:readItem(R, id)
end

-- getMappedThing (protocolgameparse.cpp:4220-4246)
function P:readMappedThing(R)
  local x = R:u16()
  if x ~= 0xFFFF then
    local y, z, sp = R:u16(), R:u8(), R:u8()
    return { pos = { x = x, y = y, z = z }, stackpos = sp }
  end
  return { creatureId = R:u32() }
end

-- Resolve a MappedThing to (thing, creature).  Never called before both of the
-- packet's reads have happened: all four tile-delta handlers read their ENTIRE
-- body before any validity check (docs/map-parsing.md Additions).
function P:resolveMapped(ref)
  if ref.creatureId then
    return nil, self:creature(ref.creatureId)
  end
  local thing = self:getThingAt(ref.pos, ref.stackpos)
  local cr
  if thing and thing.creatureId then cr = self:creature(thing.creatureId) end
  return thing, cr
end

-- ===========================================================================
-- map description: tile / floor / map  (docs/map-parsing.md §2-3)
-- ===========================================================================
function P:setTileDescription(R, p)
  self:cleanTile(p)
  local gotEffect = false
  for stackPos = 0, 255 do
    if peek16(R) >= 0xFF00 then
      return R:u16() % 256                    -- wire bytes: [skip][0xFF]
    end
    if self:feat(F_ENVIRONMENT_EFFECT) and not gotEffect then
      R:u16()
      gotEffect = true
      -- NOTE: the C++ `continue` still runs ++stackPos (Correction #1)
    else
      self:addThing(p, stackPos, self:readThing(R))
    end
  end
  return 0
end

function P:setFloorDescription(R, x, y, z, w, h, offset, skip)
  for nx = 0, w - 1 do                        -- X-major, Y-minor
    for ny = 0, h - 1 do
      local p = { x = x + nx + offset, y = y + ny + offset, z = z }
      if skip == 0 then
        skip = self:setTileDescription(R, p)
      else
        self:cleanTile(p)
        skip = skip - 1
      end
    end
  end
  return skip
end

function P:setMapDescription(R, x, y, z, w, h)
  local startz, endz, zstep
  if z > SEA_FLOOR then
    startz = z - AWARE_UG_RANGE
    endz   = math.min(z + AWARE_UG_RANGE, MAP_MAX_Z)
    zstep  = 1
  else
    startz, endz, zstep = SEA_FLOOR, 0, -1
  end
  local skip = 0
  local nz = startz
  while nz ~= endz + zstep do
    skip = self:setFloorDescription(R, x, y, nz, w, h, z - nz, skip)
    nz = nz + zstep
  end
end

function P:AW() return self.aware.left + self.aware.right + 1 end
function P:AH() return self.aware.top + self.aware.bottom + 1 end

-- GameMapMovePosition is OFF at 1530: the move/floor-change packets carry no
-- leading position and the client uses its own central position.
function P:movePos(R)
  if self:feat(F_MAP_MOVE_POSITION) then return rpos(R) end
  return self:centralPos()
end

-- ===========================================================================
-- handler table
-- ===========================================================================
local S = {}

-- --- login / session -------------------------------------------------------
S[0x0A] = function(self, R)                       -- PendingGame (empty)
  self.pendingGame = true
  self.emit('pending', {})
end

S[0x0B] = function(self, R)                       -- GMActions / secondary conn id
  R:string()
end

S[0x0F] = function(self, R)                       -- EnterGame (empty)
  self.ingame = true
  self.emit('gameStart', {})
end

S[0x11] = function(self, R)                       -- UpdateNeeded
  self.emit('updateNeeded', { signature = R:string() })
end

S[0x14] = function(self, R)                       -- LoginError
  local msg = R:string()
  local reason
  if self.clientVersion >= 1523 and R:remaining() > 0 then reason = R:u8() end
  self.emit('loginError', { message = msg, reason = reason })
end

S[0x15] = function(self, R)                       -- LoginAdvice
  self.emit('loginAdvice', { message = R:string() })
end

S[0x16] = function(self, R)                       -- LoginWait
  local msg = R:string()
  self.emit('loginWait', { message = msg, time = R:u8() })
end

S[0x17] = function(self, R)                       -- LoginSuccess (parseLogin)
  local d = {}
  d.playerId   = R:u32()
  d.serverBeat = R:u16()
  if self:feat(F_NEW_SPEED_LAW) then
    d.speedA, d.speedB, d.speedC = R:double(), R:double(), R:double()
  end
  -- NO canReportBugs byte (GameDynamicBugReporter ON)
  if self.clientVersion >= 1054 then d.canChangePvpFrame = R:u8() end
  if self.clientVersion >= 1058 then d.expertModeEnabled = R:u8() end
  if self:feat(F_INGAME_STORE) then
    d.storeImagesUrl  = R:string()
    d.coinsPacketSize = R:u16()
  end
  if self.clientVersion >= 1281 then d.exivaButtonEnabled = R:u8() end
  -- NO tournament byte (GameTournamentPackets OFF)
  local pl = self:player()
  pl.id = d.playerId
  self.serverBeat = d.serverBeat
  self.speedA, self.speedB, self.speedC = d.speedA, d.speedB, d.speedC
  self.emit('login', d)
end

S[0x18] = function(self, R)                       -- SessionEnd
  self.emit('sessionEnd', { reason = R:u8() })
end

S[0x19] = function(self, R) R:u8(); R:u8() end    -- StoreButtonIndicators
S[0x1A] = function(self, R) R:u8() end            -- BugReport (canReportBugs)
S[0x1B] = function(self, R) end                   -- MultiOfflineTrainingDialog (empty)

S[0x1C] = function(self, R)                       -- NpcChatWindow
  local status = R:u8()
  if status ~= 0 then return end
  for _ = 1, R:u8() do R:u32() end                -- npc ids
  for _ = 1, R:u8() do R:u8(); R:string() end     -- buttons
end

-- GameClientPing is ON, so the dispatcher is inverted (docs/state-events.md §14):
S[0x1D] = function(self, R) self.emit('ping', {}) end        -- server PING -> we pong
S[0x1E] = function(self, R)                                   -- PONG to our own ping
  self.pongSeen = self.pongSeen + 1
  self.emit('pingBack', { count = self.pongSeen })
end

S[0x1F] = function(self, R)                       -- Challenge
  local ts  = R:u32()
  local rnd = R:u8()
  if self.clientVersion >= 1405 then R:u8() end   -- skipped byte
  self.emit('challenge', { timestamp = ts, random = rnd })
end

S[0x28] = function(self, R)                       -- Death
  local deathType, penalty = 0, 100
  if self:feat(F_DEATH_TYPE) then deathType = R:u8() end
  if self:feat(F_PENALITY_ON_DEATH) and deathType == 0 then penalty = R:u8() end
  if self.clientVersion >= 1281 then R:u8() end   -- canUseDeathRedemption
  self:player().isDead = true
  self.emit('death', { deathType = deathType, penalty = penalty })
end

S[0x29] = function(self, R)                       -- SupplyStash
  local n = R:u16()
  local items = {}
  for i = 1, n do items[i] = { id = R:u16(), amount = R:u32() } end
  if self.protocolVersion < 1410 then R:u16() end -- free slots: absent at 1530
  self.state.supplyStash = items
end

S[0x2A] = function(self, R)                       -- SpecialContainer
  R:u8()                                          -- supplyStashAvailable
  if self.protocolVersion >= 1220 then R:u8() end -- isMarketAvailable
end

S[0x2B] = function(self, R)                       -- PartyAnalyzer
  R:u32(); R:u32(); R:u8()
  for _ = 1, R:u8() do
    R:u32(); R:u8(); R:u64(); R:u64(); R:u64(); R:u64()
  end
  if R:u8() ~= 0 then
    for _ = 1, R:u8() do R:u32(); R:string() end
  end
end

S[0x32] = function(self, R)                       -- ExtendedOpcode
  local sub = R:u8()
  local buf = R:string()
  if sub == 0 then
    self.extendedEnabled = true
  elseif sub == 2 then
    self.pongSeen = self.pongSeen + 1
    self.emit('pingBack', { count = self.pongSeen })
  else
    self.emit('extendedOpcode', { opcode = sub, buffer = buf })
  end
end

S[0x33] = function(self, R)                       -- ChangeMapAwareRange
  local xr, yr = R:u8(), R:u8()
  -- the C++ casts each expression to uint8_t (map-parsing Correction #7)
  local a = {
    left   = (math.floor(xr / 2) - ((xr + 1) % 2)) % 256,
    top    = (math.floor(yr / 2) - ((yr + 1) % 2)) % 256,
    right  = math.floor(xr / 2) % 256,
    bottom = math.floor(yr / 2) % 256,
  }
  self.aware = a
  if self.state.world then self.state.world.awareRange = a end
  self.emit('awareRangeChange', a)
end

S[0x34] = function(self, R) R:u32(); R:u16() end  -- AttachedEffect
S[0x35] = function(self, R) R:u32(); R:u16() end  -- DetachEffect
S[0x36] = function(self, R) R:u32(); R:string() end -- CreatureShader
S[0x37] = function(self, R) R:string() end        -- MapShader

S[0x38] = function(self, R)                       -- CreatureTyping
  local id, typing = R:u32(), R:u8()
  local c = self:creature(id)
  if c then c.typing = (typing ~= 0) end
end

S[0x3C] = function(self, R) R:u32(); readPaperdoll(R) end            -- AttachedPaperdoll
S[0x3D] = function(self, R) R:u32(); R:u8(); R:u16() end             -- DetachPaperdoll

S[0x43] = function(self, R)                       -- Features -- rewrites every gate
  local n = R:u16()
  local changed = {}
  for _ = 1, n do
    local id, enabled = R:u8(), R:u8()
    self.features[id] = (enabled ~= 0) or nil
    changed[#changed + 1] = { id = id, enabled = enabled ~= 0 }
  end
  self.emit('features', changed)
end

-- --- map -------------------------------------------------------------------
S[0x4B] = function(self, R)                       -- FloorDescription
  local p = rpos(R)
  local floor = R:u8()
  if p.z == floor then self:setCentral(p) end
  self:setFloorDescription(R, p.x - self.aware.left, p.y - self.aware.top,
                           floor, self:AW(), self:AH(), p.z - floor, 0)
  self.emit('mapDescription', { pos = p, floor = floor })
end

S[0x64] = function(self, R)                       -- FullMap
  local p = rpos(R)
  self:setCentral(p)
  self:setMapDescription(R, p.x - self.aware.left, p.y - self.aware.top, p.z,
                         self:AW(), self:AH())
  self.emit('mapDescription', { pos = p, full = true })
end

S[0x65] = function(self, R)                       -- MapTopRow (north)
  local p = self:movePos(R); p.y = p.y - 1
  self:setMapDescription(R, p.x - self.aware.left, p.y - self.aware.top, p.z, self:AW(), 1)
  self:setCentral(p)
end
S[0x66] = function(self, R)                       -- MapRightRow (east)
  local p = self:movePos(R); p.x = p.x + 1
  self:setMapDescription(R, p.x + self.aware.right, p.y - self.aware.top, p.z, 1, self:AH())
  self:setCentral(p)
end
S[0x67] = function(self, R)                       -- MapBottomRow (south)
  local p = self:movePos(R); p.y = p.y + 1
  self:setMapDescription(R, p.x - self.aware.left, p.y + self.aware.bottom, p.z, self:AW(), 1)
  self:setCentral(p)
end
S[0x68] = function(self, R)                       -- MapLeftRow (west)
  local p = self:movePos(R); p.x = p.x - 1
  self:setMapDescription(R, p.x - self.aware.left, p.y - self.aware.top, p.z, 1, self:AH())
  self:setCentral(p)
end

S[0x69] = function(self, R)                       -- UpdateTile
  local p = rpos(R)
  self:setTileDescription(R, p)                   -- returned skip DISCARDED
  self.emit('tileUpdate', { pos = p, tile = self:tileAt(p) })
end

S[0x6A] = function(self, R)                       -- CreateOnMap
  local p = rpos(R)
  local sp = self:feat(F_TILE_ADD_THING_STACKPOS) and R:u8() or -1
  local thing = self:readThing(R)
  self:addThing(p, sp, thing)
  if thing.kind == 'creature' then
    local cr = self:creature(thing.creatureId, true)
    cr.pos = { x = p.x, y = p.y, z = p.z }
  end
  self.emit('tileUpdate', { pos = p, tile = self:tileAt(p), added = thing })
end

S[0x6B] = function(self, R)                       -- ChangeOnMap
  -- BOTH reads happen before any validity check (map-parsing Additions)
  local ref   = self:readMappedThing(R)
  local thing = self:readThing(R)
  if ref.pos then
    local old = self:getThingAt(ref.pos, ref.stackpos)
    if old then
      self:removeThingAt(ref.pos, ref.stackpos)
      self:addThing(ref.pos, ref.stackpos, thing)
    end
    self.emit('tileUpdate', { pos = ref.pos, tile = self:tileAt(ref.pos), changed = thing })
  end
end

S[0x6C] = function(self, R)                       -- DeleteOnMap
  local ref = self:readMappedThing(R)
  if ref.pos then
    local removed = self:removeThingAt(ref.pos, ref.stackpos)
    if removed and removed.kind == 'creature' and removed.creatureId then
      self:dropCreature(removed.creatureId)
    end
    self.emit('tileUpdate', { pos = ref.pos, tile = self:tileAt(ref.pos) })
  else
    self:dropCreature(ref.creatureId)
  end
end

S[0x6D] = function(self, R)                       -- MoveCreature
  local ref    = self:readMappedThing(R)
  local newPos = rpos(R)                          -- read BEFORE any lookup
  local st = self.state

  local creatureId = ref.creatureId
  if not creatureId then
    local thing = self:getThingAt(ref.pos, ref.stackpos)
    if thing and thing.kind == 'creature' then creatureId = thing.creatureId end
  end
  -- parseCreatureMove drops the packet when the mapped thing is not a creature
  if not creatureId then
    self.emit('tileUpdate', { pos = ref.pos, tile = ref.pos and self:tileAt(ref.pos) })
    return
  end

  local from = ref.pos
  local creature = self:creature(creatureId)
  if not from and creature then from = creature.pos end

  if st.moveCreature then
    st:moveCreature(creatureId, ref.pos, ref.stackpos, newPos)
  else
    local thing
    if ref.pos then thing = self:removeThingAt(ref.pos, ref.stackpos) end
    thing = thing or { kind = 'creature', creatureId = creatureId, id = 99 }
    self:addThing(newPos, -1, thing)              -- auto-place
    creature = self:creature(creatureId, true)
    creature.pos = { x = newPos.x, y = newPos.y, z = newPos.z }
  end

  creature = self:creature(creatureId)
  local pl = st.player
  if pl and pl.id == creatureId then self:setCentral(newPos) end
  self.emit('creatureMove',
            { creature = creature, from = from, to = { x = newPos.x, y = newPos.y, z = newPos.z } })
end

S[0xBE] = function(self, R)                       -- FloorChangeUp
  local p = self:movePos(R); p.z = p.z - 1
  local skip = 0
  if p.z == SEA_FLOOR then
    for i = SEA_FLOOR - AWARE_UG_RANGE, 0, -1 do   -- 5..0, offsets 8-i
      skip = self:setFloorDescription(R, p.x - self.aware.left, p.y - self.aware.top,
                                      i, self:AW(), self:AH(), 8 - i, skip)
    end
  elseif p.z > SEA_FLOOR then
    self:setFloorDescription(R, p.x - self.aware.left, p.y - self.aware.top,
                             p.z - AWARE_UG_RANGE, self:AW(), self:AH(), 3, skip)
  end
  self:setCentral({ x = p.x + 1, y = p.y + 1, z = p.z })
end

S[0xBF] = function(self, R)                       -- FloorChangeDown
  local p = self:movePos(R); p.z = p.z + 1
  local skip = 0
  if p.z == UNDERGROUND_FLOOR then
    local j = -1
    for i = p.z, p.z + AWARE_UG_RANGE do           -- 8,9,10 ; offsets -1,-2,-3
      skip = self:setFloorDescription(R, p.x - self.aware.left, p.y - self.aware.top,
                                      i, self:AW(), self:AH(), j, skip)
      j = j - 1
    end
  elseif p.z > UNDERGROUND_FLOOR and p.z < MAP_MAX_Z - 1 then
    self:setFloorDescription(R, p.x - self.aware.left, p.y - self.aware.top,
                             p.z + AWARE_UG_RANGE, self:AW(), self:AH(), -3, skip)
  end
  self:setCentral({ x = p.x - 1, y = p.y - 1, z = p.z })
end

-- --- misc windows / trackers (Tier B: consume exactly, emit nothing) -------
S[0x5B] = function(self, R)                       -- TaskBoard
  local sub = R:u8()
  if sub == 0 then                                -- bounty
    local offers = R:u8()
    for _ = 1, offers do
      R:u8(); R:u16(); R:u16(); R:u32(); R:u8(); R:u16(); R:u8(); R:u8()
    end
    R:u8(); R:u8(); R:u8()                        -- rerollPoints, rerollMode, difficulty
    for _ = 1, 4 do                               -- TASK_BOARD_TALISMAN_PATHS
      R:u8(); R:u8(); R:u8(); R:u16()
    end
    local slots = R:u8()
    for _ = 1, slots do R:u8(); R:u16(); R:u16() end
  elseif sub == 1 then                            -- weekly
    R:u16(); R:u16()                              -- anyCreature total / current
    local kills = R:u8()
    for _ = 1, kills do R:u16(); R:u16(); R:u16() end
    local delivery = R:u8()
    for _ = 1, delivery do
      R:u8(); R:u16(); R:u8(); R:u8(); R:u32(); R:u32(); R:u8()
    end
    R:u8(); R:u32(); R:u32(); R:u8(); R:u8(); R:u8(); R:u8(); R:u32(); R:u8()
    R:u32(); R:u32()
  elseif sub == 2 then                            -- hunt shop
    local offers = R:u8()
    for _ = 1, offers do
      local t = R:u8()
      if t == 4 then                              -- BONUS_PROMOTION
        R:u16(); R:u32(); R:u8()
      else
        R:string(); R:string(); R:u32()
        if t == 2 then R:u8() end                 -- OUTFIT addons
        if t == 3 then R:u32() end                -- ITEM_DOUBLE second id
        R:u32(); R:u8()
      end
    end
  else
    error(string.format('unknown TaskBoard subtype %d', sub), 0)
  end
end

S[0x5C] = function(self, R) R:u16(); R:u32(); R:u8() end   -- WeaponProficiencyExperience

S[0x5D] = function(self, R)                       -- ImbuementDurations
  local n = R:u8()
  for _ = 1, n do
    R:u8()                                        -- slot
    self:readItem(R)
    local slots = R:u8()
    for _ = 1, slots do
      if R:u8() ~= 0 then
        R:string(); R:u16(); R:u32(); R:u8()
      end
    end
  end
end

S[0x5E] = function(self, R)                       -- PassiveCooldown
  R:u8()
  local t = R:u8()
  if t == 0 then
    local cur, max, canDecay = R:u32(), R:u32(), R:u8()
    self.emit('passiveCooldown', { current = cur, max = max, canDecay = canDecay ~= 0 })
  elseif t == 1 then
    R:u8(); R:u8()
  end
end

S[0x5F] = function(self, R)                       -- OpenWheelWindow
  R:u32()                                         -- playerId
  if R:u8() == 0 then return end                  -- canView == 0 -> packet ends
  R:u8(); R:u8()                                  -- changeState, vocationId
  R:u16(); R:u16()                                -- points, extraPoints
  for _ = 1, 36 do R:u16() end                    -- point invested per slot
  local scrolls = R:u16()
  for _ = 1, scrolls do
    R:u16()
    -- gunz reads ONLY the u16 here; the crystalserver extra u8 is non-gunz
    if (not self.isGunzOs) and self.protocolVersion >= 1500 and R:remaining() > 0 then R:u8() end
  end
  if self:feat(F_VOCATION_MONK) and R:remaining() > 0 then R:u8() end
  if self:feat(F_TASKBOARD) then R:u16() end
  for _ = 1, R:u8() do R:u16() end                -- equipped gems
  local revealed = R:u16()
  for _ = 1, revealed do
    R:u16(); R:u8(); R:u8()
    local gemType = R:u8()
    R:u8()                                        -- lesserBonus
    if gemType >= 1 then R:u8() end               -- WheelGemQuality_Regular
    if gemType >= 2 then R:u8() end               -- WheelGemQuality_Greater
  end
  for _ = 1, R:u8() do R:u8(); R:u8() end         -- basic upgrades
  for _ = 1, R:u8() do R:u8(); R:u8() end         -- supreme upgrades
  -- gunz reads the trailing byte only when EXACTLY one byte is left in the frame
  if self.protocolVersion >= 1510 and R:remaining() == 1 then R:u8() end
end

S[0x61] = function(self, R) for _ = 1, 18 do R:u16() end end  -- BosstiaryData

S[0x62] = function(self, R)                       -- BosstiarySlots
  local function slot() R:u8(); R:u32(); R:u16(); R:u8(); R:u8(); R:u32(); R:u8() end
  R:u32(); R:u32(); R:u16(); R:u16()
  local unlocked1, boss1 = R:u8(), R:u32()
  if unlocked1 ~= 0 and boss1 ~= 0 then slot() end
  local unlocked2, boss2 = R:u8(), R:u32()
  if unlocked2 ~= 0 and boss2 ~= 0 then slot() end
  local unlockedT, bossT = R:u8(), R:u32()
  if unlockedT ~= 0 and bossT ~= 0 then slot() end
  if R:u8() ~= 0 then
    local n = R:u16()
    for _ = 1, n do R:u32(); R:u8() end
  end
end

S[0x63] = function(self, R)                       -- SendClientCheck
  local size = R:u32()
  R:bytes(size)
end

S[0x73] = function(self, R)                       -- BosstiaryInfo
  local n = R:u16()
  for _ = 1, n do
    R:u32(); R:u8(); R:u32(); R:u8()
    if self.clientVersion >= 1320 then R:u8() end
  end
end

S[0x75] = function(self, R)                       -- ClientEvent (>=1521)
  if self.clientVersion < 1521 then R:u8() return end
  local t = R:u8()
  if     t == 1  then R:u8()                      -- SIMPLE
  elseif t == 2 or t == 3 then R:string()         -- ACHIEVEMENT / TITLE
  elseif t == 4  then R:u16()                     -- LEVEL
  elseif t == 5  then R:u8(); R:u16()             -- SKILL
  elseif t == 6 or t == 7 then R:u16(); R:u8()    -- BESTIARY / BOSSTIARY
  elseif t == 8  then R:string(); R:u8()          -- QUEST
  elseif t == 9  then R:u16(); R:string(); R:u8() -- COSMETIC
  elseif t == 10 then R:u16(); R:string()         -- PROFICIENCY
  elseif t == 11 then R:u16()                     -- BOUNTY_TASK
  elseif t == 12 then R:u16()                     -- WEEKLY_TASK
  elseif t == 13 then R:u32()                     -- SPELL_UNLOCKED
  end                                             -- default: nothing consumed
end

local function readInspectionDescriptions(R, count)
  for _ = 1, count do R:string(); R:string() end
end

function P:readCyclopediaInspection(R, inventoryCount)
  for _ = 1, inventoryCount do
    R:u8()                                        -- slot
    R:string()                                    -- name
    self:readItem(R)
    for _ = 1, R:u8() do R:u16() end              -- imbuements
    readInspectionDescriptions(R, R:u8())
  end
  R:string()                                      -- player name
  self:readOutfit(R, false)
  if self:feat(F_WINGS_AURAS) then
    R:u16(); R:u16(); R:u16(); R:string()
  end
  readInspectionDescriptions(R, R:u8())
end

S[0x76] = function(self, R)                       -- CyclopediaItemDetail
  local windowType = R:u8()
  R:u8()                                          -- inspectionType
  R:u32()                                         -- creatureId
  if windowType == 1 then
    self:readCyclopediaInspection(R, R:u8())
    return
  end
  R:u8()                                          -- 0x01 constant
  R:string()                                      -- name
  self:readItem(R)
  for _ = 1, R:u8() do R:u16() end                -- imbuements
  readInspectionDescriptions(R, R:u8())
end

S[0x77] = function(self, R)                       -- InspectionState
  local id, st = R:u32(), R:u8()
  local c = self:creature(id)
  if c then c.inspectionState = st end
end

-- --- inventory / containers -----------------------------------------------
S[0x78] = function(self, R)                       -- SetInventory
  local slot = R:u8()
  local item = self:readItem(R)
  self:player().inventory[slot] = item
  self.emit('inventoryChange', { slot = slot, item = item })
end

S[0x79] = function(self, R)                       -- DeleteInventory
  local slot = R:u8()
  self:player().inventory[slot] = nil
  self.emit('inventoryChange', { slot = slot, item = nil })
end

S[0x6E] = function(self, R)                       -- OpenContainer
  local cid       = R:u8()
  local item      = self:readItem(R)
  local name      = R:string()
  local capacity  = R:u8()
  local hasParent = R:u8() ~= 0
  if self.clientVersion >= 1281 then R:u8() end   -- showSearchIcon
  local isUnlocked, hasPages, size, firstIndex = false, false, 0, 0
  if self:feat(F_CONTAINER_PAGINATION) then
    isUnlocked = R:u8() ~= 0
    hasPages   = R:u8() ~= 0
    size       = R:u16()
    firstIndex = R:u16()
  end
  local items = {}
  for i = 1, R:u8() do items[i] = self:readItem(R) end
  if self:feat(F_CONTAINER_FILTER) then
    R:u8()                                        -- category
    for _ = 1, R:u8() do R:u8(); R:string() end   -- category id + name
  end
  -- CORRECTION (both docs): 1530 >= 1340, so these two bytes ARE read.
  if self.clientVersion >= 1340 then
    R:u8()                                        -- isMoveable
    R:u8()                                        -- isHolding
  end
  local st = self.state
  st.containers = st.containers or {}
  local c = {
    id = cid, name = name, capacity = capacity, hasPages = hasPages,
    firstIndex = firstIndex, size = size, items = items,
    hasParent = hasParent, isUnlocked = isUnlocked, item = item,
  }
  if st.setContainer then st:setContainer(cid, c) else st.containers[cid] = c end
  self.emit('containerOpen', c)
end

S[0x6F] = function(self, R)                       -- CloseContainer
  local cid = R:u8()
  local st = self.state
  local c
  if st.closeContainer then
    c = st:closeContainer(cid)
  else
    c = st.containers and st.containers[cid]
    if st.containers then st.containers[cid] = nil end
  end
  self.emit('containerClose', c or { id = cid })
end

S[0x70] = function(self, R)                       -- ContainerAddItem
  local cid  = R:u8()
  local slot = self:feat(F_CONTAINER_PAGINATION) and R:u16() or 0
  local item = self:readItem(R)
  local st = self.state
  local c = st.container and st:container(cid) or (st.containers and st.containers[cid])
  if c then
    table.insert(c.items, 1, item)
    if c.capacity and #c.items > c.capacity then table.remove(c.items) end
  end
  self.emit('containerAddItem', { containerId = cid, slot = slot, item = item })
end

S[0x71] = function(self, R)                       -- ContainerUpdateItem
  local cid  = R:u8()
  local slot = self:feat(F_CONTAINER_PAGINATION) and R:u16() or 0
  local item = self:readItem(R)
  local st = self.state
  local c = st.container and st:container(cid) or (st.containers and st.containers[cid])
  if c then
    local idx = slot - (c.firstIndex or 0) + 1
    if idx >= 1 and idx <= #c.items then c.items[idx] = item end
  end
  self.emit('containerUpdateItem', { containerId = cid, slot = slot, item = item })
end

S[0x72] = function(self, R)                       -- ContainerRemoveItem
  local cid  = R:u8()
  local slot = self:feat(F_CONTAINER_PAGINATION) and R:u16() or 0
  local lastId = R:u16()
  local last
  if lastId ~= 0 then last = self:readItem(R, lastId) end
  local st = self.state
  local c = st.container and st:container(cid) or (st.containers and st.containers[cid])
  if c then
    local idx = slot - (c.firstIndex or 0) + 1
    if idx >= 1 and idx <= #c.items then table.remove(c.items, idx) end
    if last then c.items[#c.items + 1] = last end
  end
  self.emit('containerRemoveItem',
            { containerId = cid, slot = slot, lastItem = last })
end

S[0xF5] = function(self, R)                       -- PlayerInventory (count cache)
  local size = R:u16()
  -- The C++ returns here when size > MAX_INVENTORY_TYPES (10000) WITHOUT consuming
  -- the entries -- one of the silent-desync early-returns the docs tell a Lua port
  -- to replace with "consume the payload, then decide" (opcode-map Additions).
  local overflow = size > 10000
  local IT = self.items
  local counts = {}
  for _ = 1, size do
    local itemId    = R:u16()
    local attribute = R:u8()
    local amount    = (self.protocolVersion < 1500) and R:u16() or packedCount1500(R)
    local tier = 0
    if math.floor(IT.flags(itemId) / IT.CLASSIFY) % 2 == 1 then tier = attribute end
    local key = itemId * 256 + tier
    counts[key] = (counts[key] or 0) + amount
  end
  if overflow then return end                     -- consumed, but discarded like the C++
  self.state.inventoryCounts = counts
end

-- --- npc trade / trade -----------------------------------------------------
S[0x7A] = function(self, R)                       -- OpenNpcTrade
  if self:feat(F_NAME_ON_NPC_TRADE) then R:string() end
  if self.clientVersion >= 1281 then R:u16(); R:string() end
  local n = (self.clientVersion >= 900) and R:u16() or R:u8()
  for _ = 1, n do
    R:u16(); R:u8(); R:string(); R:u32(); R:u32(); R:u32()
  end
end

S[0x7B] = function(self, R)                       -- PlayerGoods
  if self.clientVersion < 1281 then
    if self:feat(98) then R:u64() else R:u32() end
  end
  local n = (self.clientVersion >= 1334) and R:u16() or R:u8()
  for _ = 1, n do
    R:u16()
    if self:feat(F_DOUBLE_SHOP_SELL_AMOUNT) then R:u16() else R:u8() end
  end
end

S[0x7C] = function(self, R) end                   -- CloseNpcTrade (empty)

S[0x7D] = function(self, R)                       -- OwnTrade
  R:string()
  for _ = 1, R:u8() do self:readItem(R) end
end
S[0x7E] = S[0x7D]                                 -- CounterTrade
S[0x7F] = function(self, R) end                   -- CloseTrade (empty)

-- --- effects / ambience ----------------------------------------------------
S[0x82] = function(self, R)                       -- Ambient (world light)
  local intensity, color = R:u8(), R:u8()
  self.state.world = self.state.world or {}
  self.state.world.light = { intensity = intensity, color = color }
end

S[0x83] = function(self, R)                       -- GraphicalEffect (protocol >= 1203)
  local p = rpos(R)
  local t = R:u8()
  while t ~= 0 do
    if t == 1 or t == 2 then                      -- DELTA / DELAY
      R:u8()
    elseif t == 4 or t == 5 then                  -- distance effect (+ reversed)
      local shotId = self:feat(F_EFFECT_U16) and R:u16() or R:u8()
      local dx, dy = i8(R), i8(R)
      local source = self:feat(F_EFFECT_SOURCE) and R:u8() or 0
      self.emit('distanceEffect', { pos = p, id = shotId, dx = dx, dy = dy,
                                    source = source, reversed = (t == 5) })
    elseif t == 3 then                            -- create effect
      local effectId = self:feat(F_EFFECT_U16) and R:u16() or R:u8()
      local source = self:feat(F_EFFECT_SOURCE) and R:u8() or 0
      self.emit('magicEffect', { pos = p, id = effectId, source = source })
    elseif t == 6 then                            -- sound main
      R:u8(); R:u16()
    elseif t == 7 then                            -- sound secondary
      R:u8(); R:u8(); R:u16()
    else
      -- the C++ `default: break;` consumes NOTHING and re-reads, which walks
      -- the cursor over payload bytes.  Refuse instead of corrupting the stream.
      error(string.format('unknown magic-effect subtype %d', t), 0)
    end
    t = R:u8()
  end
end

S[0x84] = function(self, R) rpos(R); R:u16() end  -- RemoveMagicEffect

S[0x85] = function(self, R)                       -- Anthem (GameAnthem ON)
  local t = R:u8()
  if t <= 2 then R:u16() end
end

-- --- forge -----------------------------------------------------------------
S[0x86] = function(self, R)                       -- ItemClasses (forge config)
  local classes = R:u8()
  for _ = 1, classes do
    R:u8()
    for _ = 1, R:u8() do R:u8(); R:u64() end
  end
  if self:feat(F_DYNAMIC_FORGE_VARIABLES) then
    for _ = 1, R:u8() do R:u8(); R:u8() end       -- fusion grades
    if self:feat(F_FORGE_CONVERGENCE) then
      for _ = 1, R:u8() do R:u8(); R:u64() end    -- convergence fusion prices
      for _ = 1, R:u8() do R:u8(); R:u64() end    -- convergence transfer prices
    end
    if self.clientVersion >= 1530 then R:u8()     -- whole dust tail collapses to 1 byte
    else
      R:u8(); R:u8(); R:u8(); R:u8()
      if self.clientVersion >= 1316 then R:u16(); R:u16() else R:u8(); R:u8() end
      R:u8(); if self:feat(F_FORGE_CONVERGENCE) then R:u8() end
      R:u8(); if self:feat(F_FORGE_CONVERGENCE) then R:u8() end
      R:u8(); R:u8(); R:u8()
    end
  elseif self.clientVersion >= 1530 then
    R:u8()
  else
    local total = (self.clientVersion >= 1316) and 13 or 11
    if self:feat(F_FORGE_CONVERGENCE) then total = total + 2 end
    for _ = 1, total do R:u8() end
  end
end

S[0x87] = function(self, R)                       -- OpenForge
  local fusion = R:u16()
  for _ = 1, fusion do R:u8(); R:u16(); R:u8(); R:u16() end
  local convFusion = R:u16()
  for _ = 1, convFusion do
    for _ = 1, R:u8() do R:u16(); R:u8(); R:u16() end
  end
  local function transferBlock()
    for _ = 1, R:u16() do R:u16(); R:u8(); R:u16() end   -- donors
    for _ = 1, R:u16() do R:u16(); R:u16() end           -- receivers
  end
  for _ = 1, R:u8() do transferBlock() end
  for _ = 1, R:u8() do transferBlock() end
  -- the trailing field shrinks back to a u8 at 1530
  if self.clientVersion >= 1530 then R:u8() else R:u16() end
end

S[0x88] = function(self, R)                       -- BrowseForgeHistory
  R:u16(); R:u16()
  for _ = 1, R:u8() do R:u32(); R:u8(); R:string(); R:u8() end
end

S[0x89] = function(self, R) end                   -- CloseForgeWindow (empty)

S[0x8A] = function(self, R)                       -- ForgeResult
  local action = R:u8()
  R:u8(); R:u8(); R:u16(); R:u8(); R:u16(); R:u8()
  if action == 1 then
    R:u8()
  else
    local bonus = R:u8()
    if bonus == 2 then R:u8()
    elseif bonus >= 4 and bonus <= 8 then R:u16(); R:u8() end
  end
end

-- --- creatures -------------------------------------------------------------
S[0x8B] = function(self, R)                       -- CreatureData
  local id = R:u32()
  local t  = R:u8()
  if t == 0 then
    self:readCreature(R, 0)                       -- reads its own u16 discriminator
  elseif t == 11 or t == 12 or t == 13 then
    local v = R:u8()
    local c = self:creature(id)
    if c then
      if t == 11 then c.manaPercent = v
      elseif t == 12 then c.showStatus = v
      else c.vocation = v end
    end
  elseif t == 14 then
    local icons = self:readIconList(R)
    local c = self:creature(id)
    if c then c.icons = icons end                 -- replace = true
  end                                             -- any other type consumes nothing
end

S[0x8C] = function(self, R)                       -- CreatureHealth
  local id, hp = R:u32(), R:u8()
  local c = self:creature(id, true)
  local old = c.healthPercent
  c.healthPercent = hp
  if old ~= hp then self.emit('creatureHealth', { creature = c, healthPercent = hp }) end
end

S[0x8D] = function(self, R)                       -- CreatureLight
  local id = R:u32()
  local intensity, color = R:u8(), R:u8()
  local c = self:creature(id)
  if c then c.light = { intensity = intensity, color = color } end
end

S[0x8E] = function(self, R)                       -- CreatureOutfit
  local id = R:u32()
  local o = self:readOutfit(R, true)
  local c = self:creature(id)
  if c then c.outfit = o end
end

S[0x8F] = function(self, R)                       -- CreatureSpeed
  local id = R:u32()
  local base = (self.clientVersion >= 1059) and R:u16() or 0
  local speed = R:u16()
  local c = self:creature(id)
  if c then
    c.speed = speed
    if base ~= 0 then c.baseSpeed = base end
  end
end

S[0x90] = function(self, R)                       -- CreatureSkull
  local id, v = R:u32(), R:u8()
  local c = self:creature(id); if c then c.skull = v end
end
S[0x91] = function(self, R)                       -- CreatureParty (shield)
  local id, v = R:u32(), R:u8()
  local c = self:creature(id); if c then c.shield = v end
end
S[0x92] = function(self, R)                       -- CreatureUnpass
  local id, v = R:u32(), R:u8()
  local c = self:creature(id); if c then c.passable = (v == 0) end
end
S[0x93] = function(self, R)                       -- CreatureMarks
  local id = R:u32()
  local squareType, squareColor
  if self.clientVersion < 1076 then
    squareType, squareColor = 0, R:u8()
  else
    squareType, squareColor = R:u8(), R:u8()
  end
  local c = self:creature(id)
  if c then c.squareType, c.squareColor = squareType, squareColor end
end
S[0x94] = function(self, R) R:u32(); R:u16() end  -- PlayerHelpers
S[0x95] = function(self, R)                       -- CreatureType
  local id, t = R:u32(), R:u8()
  local c = self:creature(id)
  if c then
    c.type = t
    c.isPlayer, c.isMonster, c.isNpc = (t == 0), (t == 1), (t == 2)
  end
end

S[0x96] = function(self, R)                       -- EditText
  R:u32()                                         -- windowId
  if self.clientVersion >= 1010 or self:feat(F_ITEM_SHADER) then
    self:readItem(R)
  else
    R:u16()
  end
  R:u16()                                         -- maxLength
  R:string()                                      -- text
  R:string()                                      -- writer
  if self.clientVersion >= 1281 then R:u8() end   -- suffix
  if self:feat(F_WRITABLE_DATE) then R:string() end
end

S[0x97] = function(self, R) R:u8(); R:u32(); R:string() end   -- EditList
S[0x98] = function(self, R) R:u32(); R:u8() end               -- SendGameNews
S[0x9A] = function(self, R) end                               -- CloseDepotSearch (empty)

S[0x9B] = function(self, R)                       -- SendBlessDialog
  local n = R:u8()
  for _ = 1, n do R:u16(); R:u8(); R:u8() end
  for _ = 1, 9 do R:u8() end                      -- premium..aol
  for _ = 1, R:u8() do R:u32(); R:u8(); R:string() end
end

S[0x9C] = function(self, R)                       -- Blessings
  local mask = R:u16()
  local visual
  if self.clientVersion >= 1200 then visual = R:u8() end
  local pl = self:player()
  pl.blessings = mask
  pl.blessingsVisual = visual
end

S[0x9D] = function(self, R) R:u32() end           -- Preset
S[0x9E] = function(self, R)                       -- PremiumTrigger
  for _ = 1, R:u8() do R:u8() end
  if self.clientVersion <= 1096 then R:u8() end
end

-- --- local player ----------------------------------------------------------
S[0x9F] = function(self, R)                       -- PlayerDataBasic
  local pl = self:player()
  pl.premium = R:u8() ~= 0
  if self:feat(F_PREMIUM_EXPIRATION) then R:u32() end
  pl.vocation = R:u8()
  if self:feat(F_PREY) then R:u8() end
  local spells = {}
  local n = R:u16()
  for i = 1, n do
    spells[i] = self:feat(F_USHORT_SPELL) and R:u16() or R:u8()
  end
  pl.spells = spells
  if self.clientVersion >= 1281 then pl.magicShieldActive = R:u8() ~= 0 end
end

S[0xA0] = function(self, R)                       -- PlayerData (exactly 60 bytes)
  local pl = self:player()
  local oldHp, oldMp = pl.health, pl.mana
  pl.health      = R:u32()
  pl.maxHealth   = R:u32()
  pl.freeCapacity = R:u32() / 100
  pl.exp         = R:u64()
  pl.level       = R:u16()
  pl.levelPercent = self:feat(F_LEVEL_PERCENT_U16) and (R:u16() / 100) or R:u8()
  if self:feat(F_EXPERIENCE_BONUS) then
    pl.baseXpGain      = R:u16()
    pl.grindingAddend  = R:u16()
    pl.storeBoostAddend = R:u16()
    pl.huntingBoostFactor = R:u16()
  end
  pl.mana        = R:u32()
  pl.maxMana     = R:u32()
  pl.soul        = R:u8()
  pl.stamina     = R:u16()
  pl.baseSpeed   = R:u16()
  pl.regeneration = R:u16()
  pl.offlineTrainingTime = R:u16()
  if self.clientVersion >= 1097 then
    pl.storeExpBoostTime = R:u16()
    pl.canBuyXpBoost = R:u8() ~= 0
  end
  if self.clientVersion >= 1281 and self:feat(28) then   -- GameDoubleHealth
    pl.manaShield    = R:u32()
    pl.maxManaShield = R:u32()
  end
  if oldHp ~= pl.health then
    self.emit('healthChange', { health = pl.health, maxHealth = pl.maxHealth, old = oldHp })
  end
  if oldMp ~= pl.mana then
    self.emit('manaChange', { mana = pl.mana, maxMana = pl.maxMana, old = oldMp })
  end
end

S[0xA1] = function(self, R)                       -- PlayerSkills
  local pl = self:player()
  if self.clientVersion >= 1281 then
    pl.magicLevel     = R:u16()
    pl.baseMagicLevel = R:u16()
    R:u16()                                       -- loyalty magic level, discarded
    pl.magicLevelPercent = R:u16() / 100
  end
  pl.skills = {}
  for i = 0, 6 do                                 -- Otc::Fist .. Otc::Fishing
    local level, base = R:u16(), R:u16()
    R:u16()                                       -- loyalty, discarded
    pl.skills[i] = { level = level, baseLevel = base, percent = R:u16() / 100 }
  end
  -- GameAdditionalSkills OFF -> no critical/leech block
  if self:feat(F_ADDITIONAL_SKILLS) then
    for _ = 1, 5 do R:u16(); R:u16() end
  end
  if self:feat(F_CONCOCTIONS) then R:u8() end
  -- GameForgeSkillStats OFF -> no forge block, no 2 x u32 capacity
  if self:feat(F_FORGE_SKILL_STATS) then
    local last = (self.clientVersion >= 1332) and 11 or 6
    for _ = 1, last do R:u16(); R:u16() end
    R:u32(); R:u32()
  end
  if self:feat(F_CHARACTER_SKILL_STATS) then
    pl.capacity     = R:u32() / 100   -- total capacity
    pl.maxCapacity  = pl.capacity     -- API.md name for the same number
    pl.baseCapacity = R:u32() / 100
    pl.flatDamageHealing = R:u16()
    pl.attackValue   = R:u16()
    pl.attackElement = R:u8()
    pl.convertedDamage  = R:double()
    pl.convertedElement = R:u8()
    pl.lifeLeech  = R:double()
    pl.manaLeech  = R:double()
    pl.critChance = R:double()
    pl.critDamage = R:double()
    pl.onslaught  = R:double()
    pl.defense = R:u16()
    pl.armor   = R:u16()
    if self:feat(F_VOCATION_MONK) then pl.mantra = R:u16() end
    pl.mitigation = R:double()
    pl.dodge      = R:double()
    pl.damageReflection = R:u16()
    pl.absorb = {}
    for _ = 1, R:u8() do
      local ct = R:u8()
      pl.absorb[ct] = R:double()
    end
    pl.momentum      = R:double()
    pl.transcendence = R:double()
    pl.amplification = R:double()
  end
  self.emit('skillsChange', { skills = pl.skills })
end

S[0xA2] = function(self, R)                       -- PlayerState (9 bytes)
  local pl = self:player()
  local lo, hi
  if self.clientVersion >= 1405 then
    lo, hi = R:u32(), R:u32()
  else
    lo, hi = R:u32(), 0
  end
  pl.statesLo, pl.statesHigh = lo, hi
  pl.states = lo + hi * 4294967296
  if self:feat(F_PLAYER_STATE_COUNTER) then R:u8() end
  self.emit('statesChange', { states = pl.states, lo = lo, hi = hi })
end

S[0xA3] = function(self, R)                       -- ClearTarget (8 bytes)
  local seq = self:feat(F_ATTACK_SEQ) and R:u32() or 0
  if self.clientVersion >= 1530 then R:u32() end  -- discarded
  self.emit('attackCancel', { seq = seq })
end

S[0xA4] = function(self, R)                       -- SpellDelay
  local id = self:feat(F_USHORT_SPELL) and R:u16() or R:u8()
  self.emit('spellCooldown', { spellId = id, delay = R:u32() })
end
S[0xA5] = function(self, R)                       -- SpellGroupDelay
  local g = R:u8()
  self.emit('spellGroupCooldown', { groupId = g, delay = R:u32() })
end
S[0xA6] = function(self, R)                       -- MultiUseDelay
  self.emit('multiUseCooldown', { delay = R:u32() })
end

S[0xA7] = function(self, R)                       -- PlayerModes (3 bytes, no fightMode)
  local st = self.state
  st.chaseMode = R:u8()
  st.safeMode  = R:u8() ~= 0
  st.pvpMode   = R:u8()
end

S[0xA8] = function(self, R) R:u8() end            -- SetStoreDeepLink
S[0xA9] = function(self, R) R:u8(); R:u8(); R:string() end   -- RestingAreaState

-- --- chat ------------------------------------------------------------------
S[0xAA] = function(self, R)                       -- Talk
  local statementId = self:feat(F_MESSAGE_STATEMENTS) and R:u32() or 0
  local name = R:string()
  if statementId > 0 and self.clientVersion >= 1281 then R:u8() end  -- suffix
  local level = self:feat(F_MESSAGE_LEVEL) and R:u16() or 0
  local modeByte = R:u8()
  local mode = opcodes.messageMode[modeByte]
  local channelId, pos = 0, nil
  if TALK_POS_BYTES[modeByte] then
    pos = rpos(R)
  elseif TALK_CHANNEL_BYTES[modeByte] then
    channelId = R:u16()
  elseif TALK_NONE_BYTES[modeByte] then
    -- nothing
  else
    error(string.format('unknown talk mode byte %d (%s)', modeByte, tostring(mode)), 0)
  end
  local text = R:string()
  self.emit('talk', { statementId = statementId, name = name, level = level,
                      mode = mode, modeByte = modeByte, text = text,
                      channelId = channelId, pos = pos })
end

S[0xB4] = function(self, R)                       -- TextMessage
  local code = R:u8()
  local mode = opcodes.messageMode[code]
  if mode == nil then
    error(string.format('unknown text-message mode byte %d', code), 0)
  end
  local d = { mode = mode, modeByte = code }
  local text
  if code == 6 or code == 33 or code == 34 or code == 35 then
    d.channelId = R:u16(); text = R:string()
  elseif code == 23 or code == 24 or code == 27 then
    d.pos = rpos(R)
    d.value = R:u32(); d.color = R:u8()
    d.value2 = R:u32(); d.color2 = R:u8()
    text = R:string()
  elseif code == 25 or code == 43 or code == 28 then
    d.pos = rpos(R); d.value = R:u32(); d.color = R:u8(); text = R:string()
  elseif code == 26 or code == 29 then
    d.pos = rpos(R)
    d.value = (self.clientVersion >= 1332) and R:u64() or R:u32()
    d.color = R:u8()
    text = R:string()
  end
  -- CORRECTION: unconditional, and the ONLY string read for every default mode.
  if text == nil or text == '' then text = R:string() end
  d.text = text
  self.emit('textMessage', d)
end

S[0xAB] = function(self, R)                       -- Channels list
  local list = {}
  self.state.channels = self.state.channels or {}
  for i = 1, R:u8() do
    local id = R:u16()
    local name = R:string()
    list[i] = { id = id, name = name }
    self.state.channels[id] = name
  end
  self.emit('channelList', list)
end

local function readChannelMembers(self, R)
  if not self:feat(F_CHANNEL_PLAYER_LIST) then return end
  for _ = 1, R:u16() do R:string() end             -- joined
  for _ = 1, R:u16() do R:string() end             -- invited
end

S[0xAC] = function(self, R)                       -- OpenChannel
  local id = R:u16()
  local name = R:string()
  readChannelMembers(self, R)
  self.state.channels = self.state.channels or {}
  self.state.channels[id] = name
  self.emit('openChannel', { id = id, name = name })
end

S[0xAD] = function(self, R)                       -- OpenPrivateChannel
  self.emit('openChannel', { id = -1, name = R:string(), private = true })
end

S[0xAE] = function(self, R) R:u16() end           -- RuleViolationChannel

S[0xAF] = function(self, R)                       -- ExperienceTracker (>=1200)
  local raw, final = i64(R), i64(R)
  self.emit('experienceTracker', { rawExp = raw, finalExp = final })
end

S[0xB0] = function(self, R) R:string() end        -- RuleViolationCancel

S[0xB1] = function(self, R)                       -- Highscores (>=1310)
  if R:u8() ~= 0 then return end                  -- non-zero => packet ends here
  R:u8()                                          -- skip 0x01
  R:string(); R:string(); R:u8(); R:u8()          -- serverName, world, worldType, battlEye
  local sizeVocation = R:u8()
  R:u32(); R:string()                             -- 0xFFFFFFFF + "All vocations"
  for _ = 1, sizeVocation - 1 do R:u32(); R:string() end
  R:u32()                                         -- params.vocation
  for _ = 1, R:u8() do R:u8(); R:string() end     -- categories
  R:u8()                                          -- params.category
  R:u16(); R:u16()                                -- page, totalPages
  for _ = 1, R:u8() do
    R:u32(); R:string(); R:string(); R:u8(); R:string(); R:u16(); R:u8(); R:u64()
  end
  R:u8(); R:u8(); R:u8(); R:u32()
end

S[0xB2] = function(self, R)                       -- OpenOwnChannel
  local id = R:u16()
  local name = R:string()
  readChannelMembers(self, R)
  self.state.channels = self.state.channels or {}
  self.state.channels[id] = name
  self.emit('openChannel', { id = id, name = name, own = true })
end

S[0xB3] = function(self, R)                       -- CloseChannel
  local id = R:u16()
  if self.state.channels then self.state.channels[id] = nil end
  self.emit('closeChannel', { id = id })
end

-- --- walking / combat ------------------------------------------------------
S[0xB5] = function(self, R)                       -- CancelWalk
  local dir = R:u8()
  local pl = self:player()
  if dir < 8 then pl.direction = dir end
  self.emit('walkCancel', { direction = dir })
end

S[0xB6] = function(self, R)                       -- WalkWait
  local ms = R:u16()
  self.emit('walkWait', { millis = ms })
end

S[0xB7] = function(self, R)                       -- UnjustifiedStats (7 x u8)
  self.state.unjustified = {
    killsDay = R:u8(), killsDayRemaining = R:u8(),
    killsWeek = R:u8(), killsWeekRemaining = R:u8(),
    killsMonth = R:u8(), killsMonthRemaining = R:u8(),
    skullTime = R:u8(),
  }
end

S[0xB8] = function(self, R) self.state.openPvpSituations = R:u8() end

S[0xB9] = function(self, R)                       -- BestiaryRefreshTracker
  if self.clientVersion >= 1320 then R:u8() end
  for _ = 1, R:u8() do
    R:u16(); R:u32(); R:u16(); R:u16(); R:u16(); R:u8()
  end
end

S[0xBA] = function(self, R)                       -- TaskHuntingBasicData
  if self:feat(F_TASKBOARD) then
    for _ = 1, R:u16() do R:u16() end             -- mastered race ids
  else
    for _ = 1, R:u16() do R:u16(); R:u8() end
    for _ = 1, R:u8() do R:u8(); R:u8(); R:u16(); R:u16(); R:u16(); R:u16() end
  end
end

S[0xBB] = function(self, R)                       -- TaskHuntingData
  R:u8()                                          -- slot
  local state = R:u8()
  if state == 0 then                              -- LOCKED
    R:u8()
  elseif state == 1 then                          -- INACTIVE
  elseif state == 2 or state == 3 then            -- SELECTION / LIST_SELECTION
    for _ = 1, R:u16() do R:u16(); R:u8() end
  elseif state == 4 then                          -- ACTIVE
    R:u16(); R:u8(); R:u16(); R:u16(); R:u8()
  elseif state == 5 then                          -- COMPLETED
    R:u16(); R:u8(); R:u16(); R:u16()
    if self.clientVersion >= 1285 then R:u8() end
  end
  R:u32()                                         -- next free roll
end

S[0xBD] = function(self, R)                       -- BosstiaryCooldownTimer
  for _ = 1, R:u16() do R:u32(); R:u64() end
end

S[0xC0] = function(self, R)                       -- LootContainers
  R:u8()                                          -- fallbackToMain
  for _ = 1, R:u8() do
    R:u8(); R:u16()
    if self.clientVersion >= 1332 then R:u16() end
  end
end

S[0xC1] = function(self, R)                       -- MonkData
  local sub = R:u8()
  local pl = self:player()
  if sub == 0 then
    pl.harmony = R:u8()
  elseif sub == 1 then
    pl.serene = R:u8() ~= 0
  elseif sub == 2 then
    local n = R:u8()
    local virtues = {}
    for i = 1, n do virtues[i] = R:u16() end
    pl.virtues = virtues
  end
end

S[0xC2] = function(self, R)                       -- OpenMonsterPodiumWindow (gunz-only)
  -- BARE outfit blocks: no feature tests, mount is a plain u16 with no colours.
  local function podiumOutfit(withMount)
    local lt = R:u16()
    if lt ~= 0 then R:u8(); R:u8(); R:u8(); R:u8(); R:u8()
    else R:u16() end
    if withMount then R:u16() end
  end
  podiumOutfit(true)
  local detailed = R:u8() ~= 0
  local n = R:u16()
  for _ = 1, n do
    R:u16()                                       -- raceId
    if detailed then R:string(); podiumOutfit(false) end
  end
  rpos(R); R:u16(); R:u8(); R:u8(); R:u8(); R:u8()
end

S[0xC3] = function(self, R)                       -- CyclopediaHouseAuctionMessage
  R:u32()
  if R:u8() == 1 then R:u8() end
  R:u8()
end

S[0xC4] = function(self, R)                       -- WeaponProficiencyInfo
  R:u16(); R:u32()
  for _ = 1, R:u8() do R:u8(); R:u8() end
  if self.clientVersion >= 1530 then
    local detailCount = R:u8()
    if detailCount ~= 0 then
      -- gunzotc reads the count and logs it without parsing any list; the entry
      -- layout is UNVERIFIED, so a non-zero count WILL desync. Fail loudly.
      error(string.format(
        'WeaponProficiencyInfo (0xC4) detail list count=%d but the entry layout is unknown ' ..
        '(docs/opcode-map.md marks it UNVERIFIED)', detailCount), 0)
    end
  end
end

S[0xC6] = function(self, R)                       -- CyclopediaHousesInfo
  R:u32(); R:u8(); R:u8(); R:u8(); R:u8(); R:u8(); R:u8(); R:u8(); R:u32()
  for _ = 1, R:u16() do R:u32() end
end

S[0xC7] = function(self, R)                       -- CyclopediaHouseList
  for _ = 1, R:u16() do
    R:u32(); R:u8()
    local t = R:u8()
    if t == 0 then                                -- AVAILABLE
      local bidder = R:string()
      local isBidder = R:u8() ~= 0
      R:u8()                                      -- disableIndex
      if #bidder > 0 then
        R:u32(); R:u64()
        if isBidder then R:u64() end
      end
    elseif t == 2 then                            -- RENTED
      R:string(); R:u32()
      if R:u8() ~= 0 then R:u8(); R:u8() end
    elseif t == 3 then                            -- TRANSFER
      R:string(); R:u32()
      local isOwner = R:u8() ~= 0
      if isOwner then R:u8(); R:u8() end
      R:u32(); R:string(); R:u8(); R:u64()
      if R:u8() ~= 0 then R:u8(); R:u8() end      -- isNewOwner
      if isOwner then R:u8() end
    elseif t == 4 then                            -- MOVEOUT
      R:string(); R:u32()
      if R:u8() ~= 0 then R:u8(); R:u8(); R:u32(); R:u8()
      else R:u32() end
    end
  end
end

S[0xC8] = function(self, R)                       -- ChooseOutfit
  local current = self:readOutfit(R, true)
  if self.clientVersion >= 1281 then
    if (current.mount or 0) == 0 then R:u8(); R:u8(); R:u8(); R:u8() end
    R:u16()                                       -- CORRECTION: familiar looktype
  end
  if self:feat(F_NEW_OUTFIT_PROTOCOL) then
    local n = (self.clientVersion >= 1281) and R:u16() or R:u8()
    for _ = 1, n do
      R:u16(); R:string(); R:u8()
      if self.clientVersion >= 1281 then
        if R:u8() == 1 then R:u32() end
      end
    end
  else
    if self:feat(F_LOOKTYPE_U16) then R:u16(); R:u16() else R:u8(); R:u8() end
  end
  if self:feat(F_PLAYER_MOUNTS) then
    local n = (self.clientVersion >= 1281) and R:u16() or R:u8()
    for _ = 1, n do
      R:u16(); R:string()
      if self.clientVersion >= 1281 then
        if R:u8() == 1 then R:u32() end
      end
    end
  end
  if self:feat(F_PLAYER_FAMILIARS) then
    for _ = 1, R:u16() do
      R:u16(); R:string()
      if R:u8() == 1 then R:u32() end
    end
  end
  if self.clientVersion >= 1281 then R:u8(); R:u8(); R:u8() end
  if self:feat(F_WINGS_AURAS) then
    for _ = 1, 4 do
      for _ = 1, R:u8() do R:u16(); R:string() end
    end
  end
end

S[0xCA] = function(self, R)                       -- ExivaRestrictions
  for _ = 1, 6 do R:u8() end
  for _ = 1, 4 do
    for _ = 1, R:u16() do R:string() end
  end
end

S[0xCC] = function(self, R)                       -- UpdateImpactTracker
  local t = R:u8()
  R:u32()
  if t == 1 then R:u8()
  elseif t == 2 then R:u8(); R:string() end
end

S[0xCD] = function(self, R)                       -- SendItemsPrice
  local IT = self.items
  for _ = 1, R:u16() do
    local id = R:u16()
    if self.clientVersion >= 1281 then
      if math.floor(IT.flags(id) / IT.CLASSIFY) % 2 == 1 then R:u8() end
      R:u64()
    else
      R:u32()
    end
  end
end

S[0xCE] = function(self, R) R:u16() end           -- SendUpdateSupplyTracker
S[0xCF] = function(self, R)                       -- SendUpdateLootTracker
  self:readItem(R); R:string()
end

S[0xD0] = function(self, R)                       -- QuestTracker
  local t = R:u8()
  if t == 1 then
    R:u8()                                        -- remaining quests
    for _ = 1, R:u8() do
      R:u16()                                     -- missionId
      if self.clientVersion >= 1410 then R:u16() end
      R:string(); R:string(); R:string()
    end
  elseif t == 0 then
    if self.clientVersion >= 1410 then R:u16() end
    R:u16()
    if self.clientVersion >= 1410 then R:string() end
    R:string(); R:string()
  end
  -- any other messageType consumes nothing (the switch has no default)
end

S[0xD1] = function(self, R)                       -- KillTracker
  R:string()
  self:readOutfit(R, false)
  for _ = 1, R:u8() do self:readItem(R) end
end

S[0xD2] = function(self, R)                       -- VipAdd
  local id = R:u32()
  local name = R:string()
  if self:feat(F_ADDITIONAL_VIP_INFO) then R:string(); R:u32(); R:u8() end
  R:u8()                                          -- status
  if self:feat(F_VIP_GROUPS) then
    for _ = 1, R:u8() do R:u8() end
  end
  self.state.vips = self.state.vips or {}
  self.state.vips[id] = name
end

S[0xD3] = function(self, R) R:u32(); R:u8() end   -- VipState

S[0xD4] = function(self, R)                       -- VipLogout -> VIP GROUPS at 1530
  if self:feat(F_VIP_GROUPS) then
    for _ = 1, R:u8() do R:u8(); R:string(); R:u8() end
    R:u8()                                        -- groups left
  else
    R:u32()
  end
end

S[0xD5] = function(self, R)                       -- BestiaryRaces
  for _ = 1, R:u16() do R:string(); R:u16(); R:u16() end
end

S[0xD6] = function(self, R)                       -- BestiaryOverview
  R:string()
  for _ = 1, R:u16() do
    R:u16()
    if self.clientVersion >= 1530 then R:u8() end
    local progress = R:u8()
    if progress > 0 then
      R:u8()
      if self.clientVersion >= 1530 then R:u8() end
    end
    if self.clientVersion >= 1340 then R:u16() end
  end
  if self.clientVersion >= 1340 then R:u16() end
end

S[0xD7] = function(self, R)                       -- BestiaryMonsterData
  R:u16(); R:string()
  local currentLevel = R:u8()
  if self.clientVersion >= 1340 then R:u16(); R:u16() end
  R:u32(); R:u16(); R:u16(); R:u16(); R:u8(); R:u8()
  if self.clientVersion >= 1530 then R:u8() end
  for _ = 1, R:u8() do
    local itemId = R:u16()
    R:u8(); R:u8()
    if itemId ~= 0 then R:string(); R:u8() end
  end
  if currentLevel > 1 then
    R:u16(); R:u8(); R:u8(); R:u32(); R:u32(); R:u16(); R:u16(); R:double()
  end
  if currentLevel > 2 then
    for _ = 1, R:u8() do R:u8(); R:u16() end
    if R:u16() > 0 then R:string() end
  end
  if self.clientVersion < 1410 and currentLevel > 3 then
    if R:u8() ~= 0 then R:u8(); R:u32() else R:u8() end
  end
end

S[0xD8] = function(self, R)                       -- BestiaryCharmsData
  local cv = self.clientVersion
  if cv >= 1410 then R:u64() else R:u32() end
  for _ = 1, R:u8() do
    R:u8()                                        -- charm id
    local unlocked
    if cv >= 1410 then
      R:u8()                                      -- tier
      unlocked = R:u8() == 1
    else
      R:string(); R:string(); R:u8(); R:u16()
      unlocked = R:u8() == 1
    end
    if unlocked then
      local assigned = true
      if cv < 1410 then assigned = R:u8() ~= 0 end
      if assigned then R:u16(); R:u32() end
    elseif cv < 1410 then
      R:u8()
    end
  end
  R:u8()                                          -- availableCharmSlots / unknown
  for _ = 1, R:u16() do
    if cv >= 1410 then R:u32() else R:u16() end
  end
end

S[0xD9] = function(self, R) R:u16() end           -- BestiaryEntryChanged

-- 0xDA CyclopediaCharacterInfoData -- see the per-type helpers below
local CYCLO = {}
S[0xDA] = function(self, R)
  local t = R:u8()
  local errorCode = R:u8()
  if errorCode > 0 then return end
  local fn = CYCLO[t]
  if fn then fn(self, R) end
  -- types 5 (ACHIEVEMENTS) and 12 (WHEEL) consume nothing; unknown types too
end

CYCLO[0] = function(self, R)                      -- BASEINFORMATION
  R:string(); R:string(); R:u16()
  self:readOutfit(R, false)
  R:u8()
  if self:feat(F_TOURNAMENT_PACKETS) then R:u8() end
  R:string()
end

CYCLO[1] = function(self, R)                      -- GENERALSTATS
  R:u64(); R:u16()
  if self:feat(F_LEVEL_PERCENT_U16) then R:u16() else R:u8() end
  R:u16()
  if self:feat(F_TOURNAMENT_PACKETS) then R:u32() end
  R:u16(); R:u16(); R:u16(); R:u16(); R:u8()
  R:u32(); R:u32(); R:u32(); R:u32(); R:u8()
  R:u16(); R:u16(); R:u16(); R:u16(); R:u16()
  R:u32(); R:u32(); R:u32()
  R:u8(); R:u8()
  R:u16(); R:u16(); R:u16(); R:u16()
  for _ = 1, 7 do R:u8(); R:u16(); R:u16(); R:u16(); R:u16() end
  for _ = 1, R:u8() do R:u8(); R:u16() end
end

CYCLO[2] = function(self, R)                      -- COMBATSTATS
  if self:feat(F_ADDITIONAL_SKILLS) then
    for _ = 1, 5 do R:u16(); R:u16() end
  end
  if self:feat(F_FORGE_SKILL_STATS) then
    local last = (self.clientVersion >= 1332) and 11 or 6
    for _ = 1, last do R:u16(); R:u16() end
  end
  R:u16(); R:u16(); R:u16()
  for _ = 1, 5 do R:u16() end
  R:u16()
  R:u8(); R:u8()
  R:u16(); R:u8(); R:u8(); R:u8(); R:u16(); R:u16(); R:double()
  for _ = 1, R:u8() do R:u8(); R:u16() end
  for _ = 1, R:u8() do R:u16(); R:u16() end
end

CYCLO[3] = function(self, R)                      -- RECENTDEATHS
  R:u16(); R:u16()
  for _ = 1, R:u16() do R:u32(); R:string() end
end

CYCLO[4] = function(self, R)                      -- RECENTPVPKILLS
  R:u16(); R:u16()
  for _ = 1, R:u16() do R:u32(); R:string(); R:u8() end
end

CYCLO[6] = function(self, R)                      -- ITEMSUMMARY
  local IT = self.items
  local function block()
    for _ = 1, R:u16() do
      local id = R:u16()
      if math.floor(IT.flags(id) / IT.CLASSIFY) % 2 == 1 then R:u8() end
      R:u32()
    end
  end
  block(); block(); block(); block(); block()     -- inventory/store/stash/depot/inbox
end

CYCLO[7] = function(self, R)                      -- OUTFITSMOUNTS
  local outfits = R:u16()
  for _ = 1, outfits do R:u16(); R:string(); R:u8(); R:u8(); R:u32() end
  if outfits > 0 then R:u8(); R:u8(); R:u8(); R:u8() end
  local mounts = R:u16()
  for _ = 1, mounts do R:u16(); R:string(); R:u8(); R:u32() end
  if mounts > 0 then R:u8(); R:u8(); R:u8(); R:u8() end
  for _ = 1, R:u16() do R:u16(); R:string(); R:u8(); R:u32() end
end

CYCLO[8] = function(self, R)                      -- STORESUMMARY
  R:u32(); R:u32()
  for _ = 1, R:u8() do R:string(); R:u8() end
  R:u8(); R:u8()
  if self:feat(F_TASKBOARD) then R:u8() end
  R:u8(); R:u8(); R:u8()
  for _ = 1, R:u8() do R:u8() end                 -- hireling skills
  for _ = 1, R:u8() do R:u8() end                 -- hireling outfits
  for _ = 1, R:u16() do R:u16(); R:string(); R:u8() end
end

CYCLO[9] = function(self, R)                      -- INSPECTION
  self:readCyclopediaInspection(R, R:u8())
end

CYCLO[10] = function(self, R)                     -- BADGES
  R:u8(); R:u8(); R:u8(); R:string()
  for _ = 1, R:u8() do R:u32(); R:string() end
end

CYCLO[11] = function(self, R)                     -- TITLES
  R:u8()
  for _ = 1, R:u8() do R:string(); R:string(); R:u8(); R:u8() end
end

CYCLO[13] = function(self, R)                     -- OFFENCESTATS
  local cv = self.clientVersion
  R:double(); R:double()
  if cv >= 1510 then R:double() end
  R:double(); R:double(); R:double()
  R:double(); R:double()
  if cv >= 1510 then R:double() end
  R:double(); R:double(); R:double()
  for _ = 1, 5 do R:double() end                  -- life leech block
  for _ = 1, 5 do R:double() end                  -- mana leech block
  for _ = 1, 4 do R:double() end                  -- onslaught block
  R:double()                                      -- cleave percent
  local limit = (cv >= 1510) and 7 or 5
  for _ = 1, limit do R:u16() end
  R:u16(); R:u16(); R:u16()
  R:u16(); R:u16(); R:u16(); R:u8(); R:u16(); R:u16(); R:u8()
  R:double(); R:u8()
  for _ = 1, R:u8() do R:u8(); R:double() end     -- accuracy
  if cv >= 1510 then
    R:double()
    for _ = 1, R:u16() do R:string(); R:double() end
    for _ = 1, R:u8() do R:u8(); R:double() end
    R:double(); R:double()
    for _ = 1, R:u8() do R:u8(); R:double() end
    R:double(); R:double()
    R:u16(); R:u16(); R:u16(); R:u16()
    for _ = 1, R:u8() do R:u8(); R:double(); R:double() end
    for _ = 1, R:u8() do R:u8(); R:double(); R:double() end
    for _ = 1, R:u8() do R:u8(); R:double(); R:double() end
  end
  if cv >= 1521 then
    R:double(); R:double(); R:double()
    for _ = 1, R:u8() do R:u8(); R:double() end
  end
end

CYCLO[14] = function(self, R)                     -- DEFENCESTATS
  local cv = self.clientVersion
  R:double(); R:double(); R:double(); R:double(); R:double()
  R:u32(); R:u16(); R:double()
  R:u16(); R:u16()
  if self:feat(F_VOCATION_MONK) then R:u16() end
  R:u16(); R:u16(); R:u8(); R:u16(); R:u16()
  if cv < 1525 then R:u16() end
  R:double(); R:double(); R:double(); R:double(); R:double()
  if cv < 1525 then R:double() end
  for _ = 1, R:u8() do
    if R:u8() == 0x04 then R:u8(); R:double() end
  end
end

CYCLO[15] = function(self, R)                     -- MISCSTATS
  for _ = 1, 5 do R:double() end                  -- momentum block
  for _ = 1, 4 do R:double() end                  -- dodge block
  for _ = 1, 3 do R:double() end                  -- reflection block
  R:u8(); R:u8()
  for _ = 1, R:u8() do R:u16(); R:u8(); R:u8(); R:u32() end   -- concoctions
  for _ = 1, R:u8() do R:u16(); R:u8(); R:u8(); R:u32() end   -- active foods
  for _ = 1, R:u8() do R:u16(); R:u8(); R:double() end        -- proficiency augments
  for _ = 1, R:u8() do R:u16(); R:u8(); R:double() end        -- wheel augments
  for _ = 1, R:u8() do R:u16(); R:u8(); R:double() end        -- equipped augments
end

S[0xDC] = function(self, R) R:u8() end            -- TutorialHint

S[0xDD] = function(self, R)                       -- AutomapFlag
  if self.clientVersion >= 1200 then
    local sub = R:u8()
    if sub ~= 0 then
      error(string.format('unhandled cyclopedia map data subtype %d', sub), 0)
    end
  end
  local p = rpos(R)
  local icon = R:u8()
  local desc = R:string()
  if self:feat(F_MINIMAP_REMOVE) then R:u8() end  -- OFF at 1530
  self.emit('automapFlag', { pos = p, icon = icon, description = desc })
end

S[0xDE] = function(self, R) R:u8() end            -- DailyRewardCollectionState

S[0xDF] = function(self, R)                       -- CoinBalance
  if R:u8() ~= 0 then
    R:u32(); R:u32()
    if self.clientVersion >= 1281 then
      R:u32()
      if self:feat(F_TOURNAMENT_PACKETS) then R:u32() end
    end
  end
end

S[0xE0] = function(self, R)                       -- StoreError
  self.emit('storeError', { errorType = R:u8(), message = R:string() })
end

S[0xE1] = function(self, R) R:u32(); R:u8() end   -- RequestPurchaseData

S[0xE2] = function(self, R)                       -- SendOpenRewardWall (gunz layout)
  R:u8(); R:u32(); R:u8()
  local wasTaken = R:u8()
  if wasTaken ~= 0 then
    R:string()
    local token = R:u8()
    if (not self.isGunzOs) and token ~= 0 then R:u16() end
  else
    local flag = R:u8()
    if (not self.isGunzOs) or flag ~= 1 then R:u32() end
    R:u16()
  end
  R:u16()                                         -- dayStreakLevel
end

local function readRewardDay(R)
  local mode = R:u8()
  if mode == 1 then
    R:u8()                                        -- itemsToSelect
    for _ = 1, R:u8() do R:u16(); R:string(); R:u32() end
  elseif mode == 2 then
    for _ = 1, R:u8() do
      local bundleType = R:u8()
      if bundleType == 1 then R:u16(); R:string(); R:u8()
      elseif bundleType == 2 then R:u8()
      elseif bundleType == 3 then R:u16() end
    end
  end
end

S[0xE4] = function(self, R)                       -- SendDailyReward
  local days = R:u8()
  for _ = 1, days do readRewardDay(R); readRewardDay(R) end
  for _ = 1, R:u8() do R:string(); R:u8() end     -- bonuses
  R:u8()                                          -- maxUnlockableDragons
end

S[0xE5] = function(self, R)                       -- SendRewardHistory
  for _ = 1, R:u8() do R:u32(); R:u8(); R:string(); R:u16() end
end

S[0xE6] = function(self, R)                       -- BosstiaryEntryChanged (GameBosstiary ON)
  if self:feat(F_BOSSTIARY) then R:u32() else R:u8(); R:u16() end
end

S[0xE7] = function(self, R) R:u8(); R:u16() end   -- SendPreyTimeLeft

local function readPreyMonster(self, R)
  R:string()
  self:readOutfit(R, false)
end
local function readPreyMonsters(self, R)
  for _ = 1, R:u8() do readPreyMonster(self, R) end
end
local function readPreyTail(self, R, withWildcards)
  if self.clientVersion > 1149 then
    R:u32()
    if withWildcards then R:u8() end
  else
    R:u16()
  end
end

S[0xE8] = function(self, R)                       -- SendPreyData
  R:u8()                                          -- slot
  local state = R:u8()
  if state == 0 then                              -- LOCKED
    R:u8()
    readPreyTail(self, R, true)
  elseif state == 1 then                          -- INACTIVE
    readPreyTail(self, R, true)
  elseif state == 2 then                          -- ACTIVE
    readPreyMonster(self, R)
    R:u8(); R:u16(); R:u8(); R:u16()
    if self.clientVersion > 1149 then R:u32(); R:u8() else R:u16() end
  elseif state == 3 then                          -- SELECTION
    readPreyMonsters(self, R)
    readPreyTail(self, R, true)
  elseif state == 4 then                          -- SELECTION_CHANGE_MONSTER
    R:u8(); R:u16(); R:u8()
    readPreyMonsters(self, R)
    readPreyTail(self, R, true)
  elseif state == 5 then                          -- LIST_SELECTION
    for _ = 1, R:u16() do R:u16() end
    readPreyTail(self, R, true)
  elseif state == 6 then                          -- WILDCARD_SELECTION
    R:u8(); R:u16(); R:u8()
    for _ = 1, R:u16() do R:u16() end
    readPreyTail(self, R, true)
  end
end

S[0xE9] = function(self, R)                       -- SendPreyRerollPrice
  R:u32()
  if self.protocolVersion >= 1230 then
    R:u8(); R:u8()
    if not self:feat(F_TASKBOARD) then
      R:u32(); R:u32(); R:u8(); R:u8()
    end
  end
end

S[0xEA] = function(self, R) R:u32(); R:string() end   -- SendShowDescription

function P:readImbuementInfo(R)
  local cv = self.clientVersion
  R:u32(); R:string(); R:string()
  if cv >= 1510 then R:u8() else R:string() end
  R:u16(); R:u32()
  if cv < 1510 then R:u8() end                    -- premiumOnly
  for _ = 1, R:u8() do R:u16(); R:string(); R:u16() end
  R:u32()                                         -- cost
  if cv < 1510 then R:u8(); R:u32() end
end

S[0xEB] = function(self, R)                       -- SendImbuementWindow
  local modern = self.clientVersion >= 1510
  local windowType = 1                            -- IMBUEMENT_WINDOW_SELECT_ITEM
  if modern then
    windowType = R:u8()
    if windowType > 2 then return end             -- nothing more is consumed
  end
  local IT = self.items
  if windowType == 0 then                         -- CHOICE
    if modern then R:u8() end
    R:u16(); R:u32()
  elseif windowType == 2 then                     -- SCROLL
    R:u8(); R:u8()
    if modern then R:u8() end
    for _ = 1, R:u16() do self:readImbuementInfo(R) end
    for _ = 1, R:u32() do R:u16(); R:u16() end
  elseif windowType == 1 then                     -- SELECT_ITEM
    if modern then R:u8() end
    local itemId = R:u16()
    if math.floor(IT.flags(itemId) / IT.CLASSIFY) % 2 == 1 then R:u8() end
    local slots = R:u8()
    for _ = 1, slots do
      if R:u8() == 0x01 then
        self:readImbuementInfo(R); R:u32(); R:u32()
      end
    end
    for _ = 1, R:u16() do self:readImbuementInfo(R) end
    for _ = 1, R:u32() do R:u16(); R:u16() end
  end
end

S[0xEC] = function(self, R) end                   -- CloseImbuementWindow (empty)

S[0xED] = function(self, R)                       -- SendError
  self.emit('serverError', { code = R:u8(), message = R:string() })
end

S[0xEE] = function(self, R)                       -- ResourceBalance
  local t = R:u8()
  local v = RESOURCE_IS_U32[t] and R:u32() or R:u64()
  self.state.resources = self.state.resources or {}
  self.state.resources[t] = v
end

S[0xEF] = function(self, R)                       -- WorldTime
  self.state.world = self.state.world or {}
  self.state.world.worldTime = { hour = R:u8(), minute = R:u8() }
end

S[0xF0] = function(self, R)                       -- QuestLog
  for _ = 1, R:u16() do R:u16(); R:string(); R:u8() end
end

S[0xF1] = function(self, R)                       -- QuestLine
  R:u16()
  for _ = 1, R:u8() do
    if self.clientVersion >= 1200 then R:u16() end
    R:string(); R:string()
  end
end

S[0xF2] = function(self, R)                       -- CoinBalanceUpdating
  if self.clientVersion >= 1291 then
    if R:u8() == 0 then return end
    R:u8(); R:u8(); R:u32(); R:u32()
    if self.clientVersion >= 1281 then R:u32() end
    if self:feat(F_TOURNAMENT_PACKETS) then R:u32() end
  else
    R:u8()
  end
end

S[0xF3] = function(self, R)                       -- ChannelEvent
  self.emit('channelEvent', { channelId = R:u16(), name = R:string(), eventType = R:u8() })
end

S[0xF4] = function(self, R)                       -- ItemInfo
  for _ = 1, R:u8() do
    R:u16()
    if self:feat(F_COUNT_U16) then R:u16() else R:u8() end
    R:string()
  end
end

-- --- market ----------------------------------------------------------------
function P:readMarketItemTier(R, itemId)
  if self.clientVersion < 1281 then return 0 end
  local IT = self.items
  if math.floor(IT.flags(itemId) / IT.CLASSIFY) % 2 ~= 1 then return 0 end
  return R:u8()
end

S[0xF6] = function(self, R)                       -- MarketEnter
  R:u8()                                          -- offers
  for _ = 1, R:u16() do
    local id = R:u16()
    self:readMarketItemTier(R, id)
    R:u16()                                       -- count
  end
end

S[0xF8] = function(self, R)                       -- MarketDetail
  local itemId = R:u16()
  self:readMarketItemTier(R, itemId)
  for attr = MARKET_DESC_FIRST, MARKET_DESC_LAST do
    local skip = (attr == MARKET_DESC_AUGMENT) and not self:feat(F_ITEM_AUGMENT)
    if not skip then
      if peek16(R) ~= 0 then R:string() else R:u16() end
    end
  end
  local pricesAreU64 = self.clientVersion >= 1281
  for _ = 1, 2 do                                 -- purchase stats, then sale stats
    for _ = 1, R:u8() do
      R:u32()
      if pricesAreU64 then R:u64(); R:u64(); R:u64()
      else R:u32(); R:u32(); R:u32() end
    end
  end
end

S[0xF9] = function(self, R)                       -- MarketBrowse
  local var
  if self.clientVersion >= 1281 then
    var = R:u8()
    if var == 3 then
      var = R:u16()
      self:readMarketItemTier(R, var)
    end
  else
    var = R:u16()
  end
  local ownOffers  = (var == 0xFFFE or var == 2)
  local ownHistory = (var == 0xFFFF or var == 1)
  local function offer()
    R:u32(); R:u16()                              -- timestamp, counter
    if ownOffers or ownHistory then
      local id = R:u16()
      self:readMarketItemTier(R, id)
    end
    R:u16()                                       -- amount
    if self.clientVersion >= 1281 then R:u64() else R:u32() end
    if ownHistory then R:u8()
    elseif ownOffers then -- nothing
    else R:string() end
  end
  for _ = 1, R:u32() do offer() end               -- buy offers
  for _ = 1, R:u32() do offer() end               -- sell offers
end

-- --- modal dialog ----------------------------------------------------------
S[0xFA] = function(self, R)                       -- ModalDialog
  local d = {}
  d.id = R:u32()
  d.title = R:string()
  d.message = R:string()
  d.buttons = {}
  for i = 1, R:u8() do
    local text = R:string()
    d.buttons[i] = { text = text, id = R:u8() }
  end
  d.choices = {}
  for i = 1, R:u8() do
    local text = R:string()
    d.choices[i] = { text = text, id = R:u8() }
  end
  d.escapeButton = R:u8()                         -- cv > 970: ESCAPE FIRST
  d.enterButton  = R:u8()
  d.priority     = R:u8() ~= 0
  self.emit('modalDialog', d)
end

-- --- store -----------------------------------------------------------------
S[0xFB] = function(self, R)                       -- Store (categories)
  if self.clientVersion <= 1100 then
    if R:u8() ~= 0 then R:u32(); R:u32() end
  end
  for _ = 1, R:u16() do
    R:string()                                    -- name
    if self.clientVersion < 1291 then R:string() end
    if self:feat(F_INGAME_STORE_HIGHLIGHTS) then R:u8() end
    for _ = 1, R:u8() do R:string() end           -- icons
    R:string()                                    -- parent
  end
  if self.clientVersion >= 1332 then R:u8(); R:u8() end
end

local function parseStoreOffersBody(self, R)
  local cv = self.clientVersion
  if cv < 1291 then
    R:string()                                    -- categoryName
    for _ = 1, R:u16() do
      R:u32(); R:string(); R:string(); R:u32()
      local highlight = R:u8()
      if highlight == 2 and self:feat(F_INGAME_STORE_HIGHLIGHTS) and cv >= 1097 then
        R:u32(); R:u32()
      end
      local disabled = R:u8() == 1
      if self:feat(F_INGAME_STORE_HIGHLIGHTS) and disabled then R:string() end
      for _ = 1, R:u8() do R:string() end
      for _ = 1, R:u16() do
        R:string(); R:string()
        for _ = 1, R:u8() do R:string() end
        R:string()
      end
    end
    return
  end

  local categoryName = R:string()
  R:u32()                                         -- redirectId
  R:u8()                                          -- sort order
  for _ = 1, R:u8() do R:string() end             -- drop menu entries
  R:bytes(R:u16())                                -- opaque string/blob
  if cv >= 1310 then
    for _ = 1, R:u16() do R:string() end          -- disable reasons
  end
  local offersCount = R:u16()

  if categoryName == 'Home' then
    for _ = 1, offersCount do
      R:string(); R:u8(); R:u32(); R:u16(); R:u32(); R:u8()
      if R:u8() == 1 then
        R:skip(1)
        if cv >= 1300 then R:u16() else R:string() end
      end
      R:u8()
      local t = R:u8()
      if t == 0 then R:string()
      elseif t == 1 then R:u16()
      elseif t == 2 then R:u16()
      elseif t == 3 then R:u16(); R:u8(); R:u8(); R:u8(); R:u8() end
      R:u8()                                      -- tryOnType
      R:string()                                  -- collection
      R:u16(); R:u32(); R:u8(); R:u16()
    end
    for _ = 1, R:u8() do                          -- banners
      R:string(); R:u8(); R:u32(); R:u8(); R:u8()
    end
    R:u8()                                        -- bannerDelay
    return
  end

  for _ = 1, offersCount do
    R:string()                                    -- offer name
    for _ = 1, R:u8() do                          -- sub offers
      R:u32(); R:u16(); R:u32(); R:u8()
      local disabled = R:u8() == 1
      if disabled then
        for _ = 1, R:u8() do
          if cv >= 1300 then R:u16() else R:string() end
        end
      end
      local state = R:u8()
      if state == 1 then R:u32(); R:u32() end     -- STATE_SALE
    end
    local t = R:u8()
    if t == 0 then R:string()
    elseif t == 1 then R:u16()
    elseif t == 2 then R:u16()
    elseif t == 3 then R:u16(); R:u8(); R:u8(); R:u8(); R:u8()
    elseif t == 4 then R:u8(); R:u16(); R:u16(); R:u8(); R:u8(); R:u8(); R:u8() end
    R:u8()                                        -- tryOnType
    R:string()                                    -- collection
    R:u16(); R:u32(); R:u8()
    local productsCapacity = R:u16()
    for _ = 1, productsCapacity do R:string(); R:u8(); R:u16() end
  end
  if categoryName == 'Search' then R:u8() end
end

S[0xFC] = function(self, R)                       -- StoreOffers
  -- The only case in the C++ switch with its own try/catch: on failure it skips
  -- the rest of its own payload instead of abandoning the whole message.
  local ok, err = pcall(parseStoreOffersBody, self, R)
  if not ok then
    self.emit('parseWarning', {
      opcode = 0xFC, message = 'StoreOffers parse failed, skipping rest of message: ' .. tostring(err),
    })
    R:skip(R:remaining())
  end
end

S[0xFD] = function(self, R)                       -- StoreTransactionHistory
  if self.clientVersion <= 1096 then R:u16(); R:u8()
  else R:u32(); R:u32() end
  for _ = 1, R:u8() do
    if self.clientVersion >= 1291 then
      R:u32(); R:u32(); R:u8(); R:u32(); R:u8(); R:string(); R:u8()
    else
      R:u32(); R:u8(); R:u32(); R:string()
    end
  end
end

S[0xFE] = function(self, R)                       -- StoreCompletePurchase
  if self.clientVersion >= 1291 then
    R:u8(); R:string()
  else
    R:u8(); R:string(); R:u32(); R:u32()
  end
end

parser.handlers = S

-- ===========================================================================
-- the loop
-- ===========================================================================
function P:parse(payload)
  local R = buffer.reader(payload)
  self.payloadSize = #payload
  self.reader = R

  while not R:eof() do
    local opOffset = R:pos()
    local op = R:u8()
    local fn = S[op]
    if not fn then
      local reason = opcodes.serverReachable[op] == false
        and 'opcode has no case in the 1530 dispatch switch (Tier C)'
        or 'no handler implemented for this opcode'
      if self.unknownOpcodeIsFatal then
        error(self:desync(op, opOffset, R, reason), 0)
      end
      -- non-fatal: mirror the C++ default branch -- discard the whole remainder
      self.emit('parseWarning', {
        opcode = op, offset = opOffset,
        message = self:desync(op, opOffset, R, reason),
      })
      R:skip(R:remaining())
      self:push(op, opOffset)
      return false
    end

    local ok, err = pcall(fn, self, R)
    if not ok then
      error(self:desync(op, opOffset, R, err), 0)
    end
    self:push(op, opOffset)
  end

  if not R:eof() then
    error(string.format('PARSER DESYNC: %d unconsumed byte(s) at end of message; %s',
                        R:remaining(), self:historyText()), 0)
  end
  return true
end

return parser
