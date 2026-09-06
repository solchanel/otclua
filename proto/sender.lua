-- proto/sender.lua -- every client->server packet builder for protocol 1530 / Gunzodus OS 61.
--
-- Byte truth: docs/opcode-map.md §5 (client table + §5.2 sendTalk) and its VERIFIER
-- Corrections, cross-checked against
--   D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp
--
-- Every builder assembles its body through lib/buffer.lua's writer and hands the finished
-- string to `transport:send(body)`.  The transport owns the compression header, padding,
-- XTEA and the sequence dword (docs/framing-crypto.md); nothing here knows about them.
-- Each builder ALSO returns the body string, which is what the unit tests hex-dump.
--
-- 1530 feature resolutions that are baked in here (docs/opcode-map.md §1):
--   GameCountU16 (104)                OFF -> move/equip counts are u8
--   GameAttackSeq (32)                ON  -> attack/follow carry a u32 seq
--   GameTacticsWithoutFightMode (136) ON  -> 0xA0 omits the fightMode byte
--   GamePVPMode (50)                  ON  -> 0xA0 still carries pvpMode
--   GameExtendedClientPing (25)       OFF -> ping is the raw 0x1D opcode
--   isGunzOs (OS 61) && cv >= 1200    -> the pong opcode is 0x1C, not 0x1E
--   isGunzOs && cv >= 1525            -> EVERY 0x96 talk ends with an aimMode byte
--
-- Position on the wire is u16 x, u16 y, u8 z (protocolgamesend.cpp addPosition).

local buffer = require('lib.buffer')

local sender = {}
sender.__index = sender

-- ---------------------------------------------------------------------------
-- client opcodes actually emitted by this module (protocolcodes.h / docs §5)
-- ---------------------------------------------------------------------------
local OP = {
    EnterGame             = 0x0F,
    LeaveGame             = 0x14,
    PingBackGunz          = 0x1C,
    Ping                  = 0x1D,
    PingBack              = 0x1E,
    ExtendedOpcode        = 0x32,
    AutoWalk              = 0x64,
    WalkNorth             = 0x65,
    WalkEast              = 0x66,
    WalkSouth             = 0x67,
    WalkWest              = 0x68,
    Stop                  = 0x69,
    WalkNorthEast         = 0x6A,
    WalkSouthEast         = 0x6B,
    WalkSouthWest         = 0x6C,
    WalkNorthWest         = 0x6D,
    TurnNorth             = 0x6F,
    TurnEast              = 0x70,
    TurnSouth             = 0x71,
    TurnWest              = 0x72,
    EquipItem             = 0x77,
    Move                  = 0x78,
    UseItem               = 0x82,
    UseItemWith           = 0x83,
    UseOnCreature         = 0x84,
    CloseContainer        = 0x87,
    UpContainer           = 0x88,
    Look                  = 0x8C,
    LookCreature          = 0x8D,
    Talk                  = 0x96,
    RequestChannels       = 0x97,
    JoinChannel           = 0x98,
    LeaveChannel          = 0x99,
    ChangeFightModes      = 0xA0,
    Attack                = 0xA1,
    Follow                = 0xA2,
    CancelAttackAndFollow = 0xBE,
    SeekInContainer       = 0xCC,
    RequestOutfit         = 0xD2,
    ChangeOutfit          = 0xD3,
    BuyItem               = 0x7A,
    SellItem              = 0x7B,
    CloseNpcTrade         = 0x7C,
    AnswerModalDialog     = 0xF9,
    -- imbuements (protocolcodes.h:285,358,375-377)
    ImbuementDurations    = 0x60,
    ImbuementWindowAction = 0xB2,
    ApplyImbuement        = 0xD5,
    ClearImbuement        = 0xD6,
    CloseImbuingWindow    = 0xD7,
}
sender.OPCODES = OP

-- Otc::Direction (const.h:158-170)
local DIR = { North = 0, East = 1, South = 2, West = 3,
              NorthEast = 4, SouthEast = 5, SouthWest = 6, NorthWest = 7 }
sender.DIR = DIR

-- Otc::Direction -> single-step walk opcode (protocolgamesend.cpp:331-395)
local WALK_OP = {
    [DIR.North]     = OP.WalkNorth,
    [DIR.East]      = OP.WalkEast,
    [DIR.South]     = OP.WalkSouth,
    [DIR.West]      = OP.WalkWest,
    [DIR.NorthEast] = OP.WalkNorthEast,
    [DIR.SouthEast] = OP.WalkSouthEast,
    [DIR.SouthWest] = OP.WalkSouthWest,
    [DIR.NorthWest] = OP.WalkNorthWest,
}

-- Otc::Direction -> turn opcode.  Only the four cardinals exist (protocolgamesend.cpp:394-420).
local TURN_OP = {
    [DIR.North] = OP.TurnNorth,
    [DIR.East]  = OP.TurnEast,
    [DIR.South] = OP.TurnSouth,
    [DIR.West]  = OP.TurnWest,
}

-- ClientAutoWalk uses its OWN encoding, not Otc::Direction (protocolgamesend.cpp:289-326):
--   E=1, NE=2, N=3, NW=4, W=5, SW=6, S=7, SE=8 ; anything else -> 0
local AUTOWALK_BYTE = {
    [DIR.East]      = 1,
    [DIR.NorthEast] = 2,
    [DIR.North]     = 3,
    [DIR.NorthWest] = 4,
    [DIR.West]      = 5,
    [DIR.SouthWest] = 6,
    [DIR.South]     = 7,
    [DIR.SouthEast] = 8,
}
sender.AUTOWALK_BYTE = AUTOWALK_BYTE

-- Otc::MessageMode (const.h:300-364) -- the ENUM, which is what callers pass.
local MODE = {
    None = 0, Say = 1, Whisper = 2, Yell = 3, PrivateFrom = 4, PrivateTo = 5,
    ChannelManagement = 6, Channel = 7, ChannelHighlight = 8, Spell = 9,
    NpcFrom = 10, NpcTo = 11, GamemasterBroadcast = 12, GamemasterChannel = 13,
    GamemasterPrivateFrom = 14, GamemasterPrivateTo = 15, Login = 16, Warning = 17,
    Game = 18, Failure = 19, Look = 20, DamageDealed = 21, DamageReceived = 22,
    Heal = 23, Exp = 24, DamageOthers = 25, HealOthers = 26, ExpOthers = 27,
    Status = 28, Loot = 29, TradeNpc = 30, Guild = 31, PartyManagement = 32,
    Party = 33, BarkLow = 34, BarkLoud = 35, Report = 36, HotkeyUse = 37,
    TutorialHint = 38, Thankyou = 39, Market = 40, Mana = 41, BeyondLast = 42,
    MonsterYell = 43, MonsterSay = 44, Red = 45, Blue = 46,
    RVRChannel = 47, RVRAnswer = 48, RVRContinue = 49,
    GameHighlight = 50, NpcFromStartBlock = 51, Attention = 52, BoostedCreature = 53,
    OfflineTrainning = 54, Transaction = 55, Potion = 56, Invalid = 255,
}
sender.MODE = MODE

-- Proto::translateMessageModeToServer for the >=1055 map (docs/opcode-map.md §4).
-- enum value -> wire byte; anything absent translates to 255 (MessageInvalid).
local MODE_TO_WIRE = {
    [0] = 0, [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5, [6] = 6, [7] = 7, [8] = 8,
    [9] = 9, [10] = 11, [11] = 12, [12] = 13, [13] = 14, [14] = 15, [15] = 16,
    [16] = 17, [17] = 18, [18] = 19, [19] = 21, [20] = 22, [21] = 23, [22] = 24,
    [23] = 25, [24] = 26, [25] = 27, [26] = 28, [27] = 29, [28] = 30, [29] = 31,
    [30] = 32, [31] = 33, [32] = 34, [33] = 35, [34] = 36, [35] = 37, [36] = 38,
    [37] = 39, [38] = 40, [39] = 41, [40] = 42, [41] = 43, [42] = 44,
    [50] = 20, [51] = 10, [52] = 48, [53] = 49, [54] = 50, [55] = 51, [56] = 52,
}
sender.MODE_TO_WIRE = MODE_TO_WIRE

local function translateMode(mode)
    if type(mode) == 'string' then
        local v = MODE[mode]
        if v == nil then error("sender: unknown message mode '" .. mode .. "'", 3) end
        mode = v
    end
    if type(mode) ~= 'number' then
        error('sender: message mode must be a number or a name, got ' .. type(mode), 3)
    end
    return mode, (MODE_TO_WIRE[mode] or 255)
end

-- modes that prefix a STR receiver / a u16 channelId (protocolgamesend.cpp:690-711)
local MODE_HAS_RECEIVER = {
    [MODE.PrivateTo] = true, [MODE.GamemasterPrivateTo] = true, [MODE.RVRAnswer] = true,
}
local MODE_HAS_CHANNEL = {
    [MODE.Channel] = true, [MODE.ChannelHighlight] = true,
    [MODE.ChannelManagement] = true, [MODE.GamemasterChannel] = true,
}

-- Position::isValid() (position.h:183)
local function isValidPos(p)
    return type(p) == 'table' and type(p.x) == 'number' and type(p.y) == 'number'
       and type(p.z) == 'number' and not (p.x == 65535 and p.y == 65535 and p.z == 255)
end
sender.isValidPos = isValidPos

-- boolean | number | nil -> a byte value.  Used by every builder whose wire field is a
-- 0/1 flag or a small enum, so `true` and `1` are always interchangeable.
local function boolByte(v)
    if type(v) == 'boolean' then return v and 1 or 0 end
    if type(v) ~= 'number' then return 0 end
    return math.floor(v)
end
sender.boolByte = boolByte

-- stackpos / count / index arguments: floor them so the byte written and any later exact
-- comparison against the same value can never disagree (see sender:talk's aimMode).
local function u8arg(v, default)
    if v == nil then return default or 0 end
    if type(v) == 'boolean' then return v and 1 or 0 end
    if type(v) ~= 'number' then error('sender: expected a number, got ' .. type(v), 3) end
    return math.floor(v)
end

local function writePos(w, p)
    if type(p) ~= 'table' then error('sender: expected a position table {x=,y=,z=}', 3) end
    w:u16(p.x); w:u16(p.y); w:u8(p.z)
end

-- ---------------------------------------------------------------------------
-- construction / plumbing
-- ---------------------------------------------------------------------------
-- sender.new(transport [, opts])
--   opts.accountName -- used to derive the gunz hwid fingerprint that enterGame() appends
function sender.new(transport, opts)
    opts = opts or {}
    return setmetatable({
        transport = transport,
        accountName = opts.accountName,
        -- Game::attack/follow set m_seq to the TARGET CREATURE ID at protocolVersion >= 963
        -- (docs/state-events.md VERIFIER: "m_seq is the target creature's id, not a counter").
        -- On a cancel (creatureId == 0) the C++ leaves m_seq UNCHANGED, so we do too.
        seq = 0,
        sent = 0,
    }, sender)
end

function sender:writer()
    return buffer.writer()
end

-- Assemble + hand off.  Returns the body string so tests can assert on the bytes -- or
-- `nil, err` when the transport refused it (dead transport, failed socket write).  Silently
-- swallowing that used to make every builder report success on a connection that was already
-- gone, and count it in self.sent; the caller had no way to tell.
function sender:_send(w)
    local body = w:data()
    if self.transport then
        local ok, err = self.transport:send(body)
        if not ok then return nil, err or 'send failed' end
    end
    self.sent = self.sent + 1
    return body
end

local function op(self, code)
    local w = buffer.writer()
    w:u8(code)
    return w
end

-- ---------------------------------------------------------------------------
-- session
-- ---------------------------------------------------------------------------

-- 0x0F, empty.  gunzotc follows it immediately with [0x32][0x0A][STR hwid]
-- (protocolgamesend.cpp:227-249); pass the fingerprint to emit that second frame too.
-- proto/handshake.lua's buildEnterGameFrames() builds the same pair for the boot path.
function sender:enterGame(hwid)
    -- sendEnterGame emits BOTH frames unconditionally on a gunz OS, so the fingerprint frame
    -- must not be opt-in: the documented `s:enterGame()` call has to produce the same pair
    -- that proto/handshake.buildEnterGameFrames() does.  Pass hwid = false to suppress it.
    if hwid == nil then
        local ok, hs = pcall(require, 'proto.handshake')
        if ok and type(hs) == 'table' and hs.hwid then
            hwid = hs.hwid(self.accountName or '')
        end
    end
    local body, err = self:_send(op(self, OP.EnterGame))
    if not body then return nil, err end
    if hwid then
        local w = op(self, OP.ExtendedOpcode)
        w:u8(10)
        w:string(hwid)
        return body, self:_send(w)
    end
    return body
end

function sender:logout()
    return self:_send(op(self, OP.LeaveGame))
end

-- GameExtendedClientPing is OFF at 1530 -> the raw opcode, no extended wrapper.
function sender:ping()
    return self:_send(op(self, OP.Ping))
end

-- gunz OS (61) and cv >= 1200 -> the pong opcode is 0x1C, not 0x1E.
function sender:pingBack()
    return self:_send(op(self, OP.PingBackGunz))
end

-- 0x32: u8 subOpcode, STR buffer.  The C++ refuses to send until the server has sent
-- extended opcode 0; that gate belongs to the caller, not to the byte builder.
function sender:extendedOpcode(opcode, buf)
    local w = op(self, OP.ExtendedOpcode)
    w:u8(opcode)
    w:string(buf or '')
    return self:_send(w)
end

-- ---------------------------------------------------------------------------
-- movement
-- ---------------------------------------------------------------------------

-- 0x65/0x66/0x67/0x68/0x6A/0x6B/0x6C/0x6D, payload-less.
function sender:walk(dir)
    local code = WALK_OP[dir]
    if not code then error('sender:walk: invalid Otc::Direction ' .. tostring(dir), 2) end
    return self:_send(op(self, code))
end

-- 0x6F/0x70/0x71/0x72, payload-less.  Diagonals have no turn opcode.
function sender:turn(dir)
    local code = TURN_OP[dir]
    if not code then error('sender:turn: direction must be a cardinal (0..3), got ' .. tostring(dir), 2) end
    return self:_send(op(self, code))
end

function sender:stop()
    return self:_send(op(self, OP.Stop))
end

-- 0x64: u8 count, count x u8 (E=1..SE=8).  The C++ does not clamp; the path length field is
-- a u8 and the client-side limit is 127, so we clamp explicitly here.
function sender:autoWalk(dirs)
    if type(dirs) ~= 'table' then error('sender:autoWalk: dirs must be an array', 2) end
    local n = #dirs
    if n > 127 then n = 127 end       -- the count is a u8 and the client-side limit is 127
    local w = op(self, OP.AutoWalk)
    w:u8(n)
    for i = 1, n do
        w:u8(AUTOWALK_BYTE[dirs[i]] or 0)
    end
    -- Second return value = the number of steps actually sent.  When it is < #dirs the path
    -- was clamped and the CALLER must re-issue autoWalk for the remainder; returning the same
    -- single value as a complete send hid the truncation entirely.
    local body, err = self:_send(w)
    if not body then return nil, err end
    return body, n
end

-- ---------------------------------------------------------------------------
-- talk (0x96) -- docs/opcode-map.md §5.2
-- ---------------------------------------------------------------------------
--   u8 0x96
--   u8 wireMode
--   [STR receiver]  for PrivateTo / GamemasterPrivateTo / RVRAnswer
--   [u16 channelId] for Channel / ChannelHighlight / ChannelManagement / GamemasterChannel
--   STR message                      (dropped entirely if empty or > 255 bytes)
--   u8 aimMode                       ALWAYS, gunz && cv >= 1525 ; must be <= 3
--   [Position(5)]                    iff aimMode == 1 or 2, and the position must be valid
function sender:talk(mode, channelId, receiver, text, aimMode, aimPos)
    if type(text) ~= 'string' or #text == 0 then
        return nil, 'empty message'          -- C++ returns without sending
    end
    if #text > 255 then
        return nil, 'message too large'      -- C++ logs "message too large" and returns
    end
    local modeVal, wireMode = translateMode(mode)

    aimMode = aimMode or 0
    if type(aimMode) ~= 'number' or aimMode < 0 or aimMode > 3 then
        return nil, 'invalid spell aim mode'
    end
    -- w:u8 floors, but the "does a Position follow?" test below is an exact == 1 / == 2.
    -- Without this a fractional 1.4 would put wire byte 1 (crosshair) on the wire and OMIT
    -- the 5-byte Position, leaving the server 5 bytes short for the rest of the session.
    aimMode = math.floor(aimMode)
    if (aimMode == 1 or aimMode == 2) and not isValidPos(aimPos) then
        return nil, 'spell aim mode requires a valid map position'
    end

    local w = op(self, OP.Talk)
    w:u8(wireMode)
    if MODE_HAS_RECEIVER[modeVal] then
        w:string(receiver or '')
    elseif MODE_HAS_CHANNEL[modeVal] then
        w:u16(channelId or 0)
    end
    w:string(text)
    w:u8(aimMode)
    if aimMode == 1 or aimMode == 2 then
        writePos(w, aimPos)
    end
    return self:_send(w)
end

-- The 1525+ aimed-spell variant: same 0x96 packet, mode defaults to Say(1).
--   aimMode 0 none, 1 crosshair (+pos), 2 cursor (+pos), 3 current target
function sender:talkSpell(text, aimMode, pos, mode)
    return self:talk(mode or MODE.Say, 0, '', text, aimMode or 0, pos)
end

-- ---------------------------------------------------------------------------
-- items / world interaction
-- ---------------------------------------------------------------------------

-- 0x82: Position(5), u16 itemId, u8 stackpos, u8 index
function sender:use(pos, itemId, stackpos, index)
    local w = op(self, OP.UseItem)
    writePos(w, pos)
    w:u16(itemId)
    w:u8(u8arg(stackpos))
    w:u8(u8arg(index))
    return self:_send(w)
end

-- 0x83: Position from(5), u16 itemId, u8 fromStack, Position to(5), u16 toThingId, u8 toStack
function sender:useWith(fromPos, itemId, fromStack, toPos, toId, toStack)
    local w = op(self, OP.UseItemWith)
    writePos(w, fromPos)
    w:u16(itemId)
    w:u8(u8arg(fromStack))
    writePos(w, toPos)
    w:u16(toId)
    w:u8(u8arg(toStack))
    return self:_send(w)
end

-- 0x84: Position(5), u16 thingId, u8 stackpos, u32 creatureId
function sender:useOnCreature(pos, itemId, stackpos, creatureId)
    local w = op(self, OP.UseOnCreature)
    writePos(w, pos)
    w:u16(itemId)
    w:u8(u8arg(stackpos))
    w:u32(creatureId)
    return self:_send(w)
end

-- 0x78: Position from(5), u16 thingId, u8 stackpos, Position to(5), u8 count
-- (GameCountU16 is OFF at 1530, so the count is ONE byte.)
function sender:move(fromPos, itemId, stackpos, toPos, count)
    local w = op(self, OP.Move)
    writePos(w, fromPos)
    w:u16(itemId)
    w:u8(u8arg(stackpos))
    writePos(w, toPos)
    w:u8(u8arg(count, 1))
    return self:_send(w)
end

-- 0x8C: Position(5), u16 itemId, u8 stackpos
function sender:look(pos, itemId, stackpos)
    local w = op(self, OP.Look)
    writePos(w, pos)
    w:u16(itemId)
    w:u8(u8arg(stackpos))
    return self:_send(w)
end

-- 0x8D: u32 creatureId
function sender:lookCreature(id)
    local w = op(self, OP.LookCreature)
    w:u32(id)
    return self:_send(w)
end

-- 0x77: u16 itemId, u8 tier  (sendEquipItemWithTier).  The count sibling shares the opcode
-- and is also a u8 at 1530 because GameCountU16 is OFF.
function sender:equipItem(itemId, tier)
    local w = op(self, OP.EquipItem)
    w:u16(itemId)
    w:u8(u8arg(tier))
    return self:_send(w)
end

-- ---------------------------------------------------------------------------
-- combat
-- ---------------------------------------------------------------------------

-- 0xA1: u32 creatureId, u32 seq   (GameAttackSeq ON)
function sender:attack(creatureId)
    creatureId = creatureId or 0
    local prev = self.seq
    if creatureId ~= 0 then self.seq = creatureId end   -- cancel leaves m_seq alone
    local w = op(self, OP.Attack)
    w:u32(creatureId)
    w:u32(self.seq)
    local body, err = self:_send(w)
    -- A frame that never left must not advance the client-side m_seq, or a later 0xA3
    -- ClearTarget is compared against a target the server never learned about.
    if not body then self.seq = prev; return nil, err end
    return body
end

-- 0xA2: u32 creatureId, u32 seq
function sender:follow(creatureId)
    creatureId = creatureId or 0
    local prev = self.seq
    if creatureId ~= 0 then self.seq = creatureId end
    local w = op(self, OP.Follow)
    w:u32(creatureId)
    w:u32(self.seq)
    local body, err = self:_send(w)
    if not body then self.seq = prev; return nil, err end
    return body
end

function sender:cancelAttackAndFollow()
    return self:_send(op(self, OP.CancelAttackAndFollow))
end

-- 0xA0: GameTacticsWithoutFightMode (136) is ON at 1530, so the fightMode byte is OMITTED.
-- Field order and values (protocolgamesend.cpp:800-822):
--   u8 chaseMode  0 DontChase, 1 ChaseOpponent
--   u8 safeFight  bool -> 0/1
--   u8 pvpMode    0 WhiteDove, 1 WhiteHand, 2 YellowHand, 3 RedFist   (GamePVPMode ON)
-- `fight` (1 Offensive, 2 Balanced, 3 Defensive) is accepted for API symmetry and DISCARDED.
function sender:setFightMode(fight, chase, safe, pvp)
    local w = op(self, OP.ChangeFightModes)
    -- All three accept booleans: coercing only `safe` made the API asymmetric in a way that
    -- crashed inside w:u8 -> math.floor for anyone who passed chase = true.
    w:u8(boolByte(chase))
    w:u8(boolByte(safe))
    w:u8(boolByte(pvp))
    return self:_send(w)
end

-- ---------------------------------------------------------------------------
-- containers
-- ---------------------------------------------------------------------------

-- Game::open sends a plain 0x82 UseItem whose `index` byte carries the container id
-- (game.cpp:941 `sendUseItem(item->getPosition(), item->getId(), item->getStackPos(), id)`).
function sender:openContainer(pos, itemId, stackpos, containerId)
    return self:use(pos, itemId, stackpos, containerId or 0)
end

function sender:closeContainer(id)
    local w = op(self, OP.CloseContainer)
    w:u8(id)
    return self:_send(w)
end

function sender:upContainer(id)
    local w = op(self, OP.UpContainer)
    w:u8(id)
    return self:_send(w)
end

-- 0xCC: u8 containerId, u16 index, u8 filter (always 0 -- docs/opcode-map.md §5 row 0xCC).
-- This is how a paged container is scrolled; proto/parser.lua already decodes 0x6E's
-- hasPages/firstIndex, so without it a bot can see the pages but not turn them.
function sender:seekInContainer(containerId, index, filter)
    local w = op(self, OP.SeekInContainer)
    w:u8(u8arg(containerId))
    w:u16(math.floor(index or 0))
    w:u8(u8arg(filter))
    return self:_send(w)
end

-- ---------------------------------------------------------------------------
-- npc trade
-- ---------------------------------------------------------------------------

-- 0x7A: u16 itemId, u8 subType, u16 amount, u8 ignoreCapacity, u8 buyWithBackpack
function sender:buyItem(itemId, subType, amount, ignoreCapacity, buyWithBackpack)
    local w = op(self, OP.BuyItem)
    w:u16(itemId)
    w:u8(u8arg(subType))
    w:u16(math.floor(amount or 1))
    w:u8(boolByte(ignoreCapacity))
    w:u8(boolByte(buyWithBackpack))
    return self:_send(w)
end

-- 0x7B: u16 itemId, u8 subType, u16 amount, u8 ignoreEquipped
function sender:sellItem(itemId, subType, amount, ignoreEquipped)
    local w = op(self, OP.SellItem)
    w:u16(itemId)
    w:u8(u8arg(subType))
    w:u16(math.floor(amount or 1))
    w:u8(boolByte(ignoreEquipped))
    return self:_send(w)
end

-- 0x7C, empty
function sender:closeNpcTrade()
    return self:_send(op(self, OP.CloseNpcTrade))
end

-- ---------------------------------------------------------------------------
-- outfit
-- ---------------------------------------------------------------------------

-- 0xD2, empty
function sender:requestOutfit()
    return self:_send(op(self, OP.RequestOutfit))
end

-- 0xD3 -- docs/opcode-map.md §5.3, the 1530 form:
--   u8 0x00 (normal outfit window), u16 lookType, 4x u8 colours, u8 addons,
--   u16 mount, 4x u8 mount colours (always 0), u8 hasMount, u16 familiar, u8 randomizeMount.
-- GameWingsAurasEffectsShader is OFF at 1530, so there is no wings/auras block.
function sender:changeOutfit(outfit)
    outfit = outfit or {}
    local w = op(self, OP.ChangeOutfit)
    w:u8(0x00)
    w:u16(math.floor(outfit.id or outfit.lookType or 0))
    w:u8(u8arg(outfit.head)); w:u8(u8arg(outfit.body))
    w:u8(u8arg(outfit.legs)); w:u8(u8arg(outfit.feet))
    w:u8(u8arg(outfit.addons))
    w:u16(math.floor(outfit.mount or 0))
    w:u8(0); w:u8(0); w:u8(0); w:u8(0)
    w:u8(boolByte(outfit.hasMount))
    w:u16(math.floor(outfit.familiar or 0))
    w:u8(boolByte(outfit.randomizeMount))
    return self:_send(w)
end

-- ---------------------------------------------------------------------------
-- channels / dialogs
-- ---------------------------------------------------------------------------
function sender:requestChannels()
    return self:_send(op(self, OP.RequestChannels))
end

function sender:joinChannel(id)
    local w = op(self, OP.JoinChannel)
    w:u16(id)
    return self:_send(w)
end

function sender:leaveChannel(id)
    local w = op(self, OP.LeaveChannel)
    w:u16(id)
    return self:_send(w)
end

-- 0xF9: u32 windowId, u8 buttonId, u8 choiceId
function sender:answerModalDialog(id, button, choice)
    local w = op(self, OP.AnswerModalDialog)
    w:u32(id)
    w:u8(button)
    w:u8(choice)
    return self:_send(w)
end

-- ---------------------------------------------------------------------------
-- imbuements  (protocolgamesend.cpp:1735-1775, 1887-1893)
-- ---------------------------------------------------------------------------
-- 0xD5: u8 slot, u32 imbuementId   (the protectionCharm byte is cv < 1510 only, so it
-- is NOT written at 1530 -- sendApplyImbuement, protocolgamesend.cpp:1741-1743)
function sender:applyImbuement(slot, imbuementId, protectionCharm)
    local w = op(self, OP.ApplyImbuement)
    w:u8(u8arg(slot))
    w:u32(math.floor(imbuementId or 0))
    if (self.clientVersion or 1530) < 1510 then w:u8(boolByte(protectionCharm)) end
    return self:_send(w)
end

-- 0xD6: u8 slot
function sender:clearImbuement(slot)
    local w = op(self, OP.ClearImbuement)
    w:u8(u8arg(slot))
    return self:_send(w)
end

-- 0xD7, empty
function sender:closeImbuingWindow()
    return self:_send(op(self, OP.CloseImbuingWindow))
end

-- 0xB2: u8 type; when type == 1 (SELECT_ITEM) also Position(5), u16 itemId, u8 stackpos.
-- Otc::IMBUEMENT_WINDOW_CHOICE = 0, SELECT_ITEM = 1, SCROLL = 2 (const.h:992-994).
function sender:imbuementWindowAction(actionType, itemId, pos, stackpos)
    local w = op(self, OP.ImbuementWindowAction)
    w:u8(u8arg(actionType))
    if actionType == 1 then
        writePos(w, pos)
        w:u16(math.floor(itemId or 0))
        w:u8(u8arg(stackpos))
    end
    return self:_send(w)
end

-- 0x60: u8 isOpen  (the imbuement-tracker subscription)
function sender:imbuementDurations(isOpen)
    local w = op(self, OP.ImbuementDurations)
    w:u8(boolByte(isOpen))
    return self:_send(w)
end

return sender
