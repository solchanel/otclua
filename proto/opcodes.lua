--[[
proto/opcodes.lua -- protocol 1530 (Gunzodus, OS 61) opcode tables.

Source of truth: docs/opcode-map.md sections 3 and 5, cross-checked against
D:/Claude/otclient_mehah1530/otclient/src/client/protocolcodes.h
(enum GameServerOpcodes / enum ClientOpcodes).

  opcodes.server = { [0x0A]='PendingGame', ... }   -- value -> name
  opcodes.client = { EnterGame=0x0F, ... }         -- name  -> value
  opcodes.names  = { server=<name->value>, client=<value->name> }

Additions used by proto/parser.lua (harmless supersets of the API contract):
  opcodes.serverReachable[v] = true|false   -- 'P' column of docs/opcode-map.md §3
                                            -- false => no case in the C++ switch
  opcodes.messageMode[byte]  = 'Say' ...    -- 1530 message-mode map (docs §4)
  opcodes.messageModeByte[name] = byte      -- reverse
  opcodes.itemMarker         = { UnknownCreature=97, OutdatedCreature=98, Creature=99 }
]]

local opcodes = {}

-- ---------------------------------------------------------------------------
-- SERVER -> CLIENT  (value -> short name; the C++ enum's "GameServer" prefix
-- is dropped, so 0x0A GameServerLoginOrPendingState -> 'PendingGame' per API.md)
-- ---------------------------------------------------------------------------
opcodes.server = {
  [0x03] = 'SessionCreatureData',
  [0x04] = 'SessionDumpStart',
  [0x0A] = 'PendingGame',
  [0x0B] = 'GMActions',
  [0x0F] = 'EnterGame',
  [0x11] = 'UpdateNeeded',
  [0x14] = 'LoginError',
  [0x15] = 'LoginAdvice',
  [0x16] = 'LoginWait',
  [0x17] = 'LoginSuccess',
  [0x18] = 'SessionEnd',
  [0x19] = 'StoreButtonIndicators',
  [0x1A] = 'BugReport',
  [0x1B] = 'MultiOfflineTrainingDialog',
  [0x1C] = 'NpcChatWindow',
  [0x1D] = 'PingBack',            -- enum name; at 1530 this is the server's PING request
  [0x1E] = 'Ping',                -- enum name; at 1530 this is the PONG to our ping
  [0x1F] = 'Challenge',
  [0x28] = 'Death',
  [0x29] = 'SupplyStash',
  [0x2A] = 'SpecialContainer',
  [0x2B] = 'PartyAnalyzer',
  [0x2C] = 'TeamFinderTeamLeader',
  [0x2D] = 'TeamFinderTeamMember',
  [0x32] = 'ExtendedOpcode',
  [0x33] = 'ChangeMapAwareRange',
  [0x34] = 'AttachedEffect',
  [0x35] = 'DetachEffect',
  [0x36] = 'CreatureShader',
  [0x37] = 'MapShader',
  [0x38] = 'CreatureTyping',
  [0x3C] = 'AttachedPaperdoll',
  [0x3D] = 'DetachPaperdoll',
  [0x43] = 'Features',
  [0x4B] = 'FloorDescription',
  [0x5B] = 'TaskBoard',
  [0x5C] = 'WeaponProficiencyExperience',
  [0x5D] = 'ImbuementDurations',
  [0x5E] = 'PassiveCooldown',
  [0x5F] = 'OpenWheelWindow',
  [0x60] = 'InventoryImbuements',
  [0x61] = 'BosstiaryData',
  [0x62] = 'BosstiarySlots',
  [0x63] = 'SendClientCheck',
  [0x64] = 'FullMap',
  [0x65] = 'MapTopRow',
  [0x66] = 'MapRightRow',
  [0x67] = 'MapBottomRow',
  [0x68] = 'MapLeftRow',
  [0x69] = 'UpdateTile',
  [0x6A] = 'CreateOnMap',
  [0x6B] = 'ChangeOnMap',
  [0x6C] = 'DeleteOnMap',
  [0x6D] = 'MoveCreature',
  [0x6E] = 'OpenContainer',
  [0x6F] = 'CloseContainer',
  [0x70] = 'CreateContainer',
  [0x71] = 'ChangeInContainer',
  [0x72] = 'DeleteInContainer',
  [0x73] = 'BosstiaryInfo',
  [0x74] = 'FriendSystemData',
  [0x75] = 'ClientEvent',          -- enum GameServerTakeScreenshot, repurposed at >=1521
  [0x76] = 'CyclopediaItemDetail',
  [0x77] = 'InspectionState',
  [0x78] = 'SetInventory',
  [0x79] = 'DeleteInventory',
  [0x7A] = 'OpenNpcTrade',
  [0x7B] = 'PlayerGoods',
  [0x7C] = 'CloseNpcTrade',
  [0x7D] = 'OwnTrade',
  [0x7E] = 'CounterTrade',
  [0x7F] = 'CloseTrade',
  [0x80] = 'CharacterTradeConfiguration',
  [0x81] = 'ReportTextUI',
  [0x82] = 'Ambient',
  [0x83] = 'GraphicalEffect',
  [0x84] = 'RemoveMagicEffect',    -- enum GameServerTextEffect, repurposed at >=1320
  [0x85] = 'Anthem',               -- enum GameServerMissleEffect, repurposed (GameAnthem ON)
  [0x86] = 'ItemClasses',
  [0x87] = 'OpenForge',            -- enum GameServerTrappers, repurposed at >=1281
  [0x88] = 'BrowseForgeHistory',
  [0x89] = 'CloseForgeWindow',
  [0x8A] = 'ForgeResult',
  [0x8B] = 'CreatureData',
  [0x8C] = 'CreatureHealth',
  [0x8D] = 'CreatureLight',
  [0x8E] = 'CreatureOutfit',
  [0x8F] = 'CreatureSpeed',
  [0x90] = 'CreatureSkull',
  [0x91] = 'CreatureParty',
  [0x92] = 'CreatureUnpass',
  [0x93] = 'CreatureMarks',
  [0x94] = 'PlayerHelpers',
  [0x95] = 'CreatureType',
  [0x96] = 'EditText',
  [0x97] = 'EditList',
  [0x98] = 'SendGameNews',
  [0x99] = 'DepotSearchDetailList',
  [0x9A] = 'CloseDepotSearch',
  [0x9B] = 'SendBlessDialog',
  [0x9C] = 'Blessings',
  [0x9D] = 'Preset',
  [0x9E] = 'PremiumTrigger',
  [0x9F] = 'PlayerDataBasic',
  [0xA0] = 'PlayerData',
  [0xA1] = 'PlayerSkills',
  [0xA2] = 'PlayerState',
  [0xA3] = 'ClearTarget',
  [0xA4] = 'SpellDelay',
  [0xA5] = 'SpellGroupDelay',
  [0xA6] = 'MultiUseDelay',
  [0xA7] = 'PlayerModes',
  [0xA8] = 'SetStoreDeepLink',
  [0xA9] = 'SendRestingAreaState',
  [0xAA] = 'Talk',
  [0xAB] = 'Channels',
  [0xAC] = 'OpenChannel',
  [0xAD] = 'OpenPrivateChannel',
  [0xAE] = 'RuleViolationChannel',
  [0xAF] = 'ExperienceTracker',    -- enum GameServerRuleViolationRemove, repurposed >=1200
  [0xB0] = 'RuleViolationCancel',
  [0xB1] = 'Highscores',           -- enum GameServerRuleViolationLock, repurposed >=1310
  [0xB2] = 'OpenOwnChannel',
  [0xB3] = 'CloseChannel',
  [0xB4] = 'TextMessage',
  [0xB5] = 'CancelWalk',
  [0xB6] = 'WalkWait',
  [0xB7] = 'UnjustifiedStats',
  [0xB8] = 'PvpSituations',
  [0xB9] = 'BestiaryRefreshTracker',
  [0xBA] = 'TaskHuntingBasicData',
  [0xBB] = 'TaskHuntingData',
  [0xBD] = 'BosstiaryCooldownTimer',
  [0xBE] = 'FloorChangeUp',
  [0xBF] = 'FloorChangeDown',
  [0xC0] = 'LootContainers',
  [0xC1] = 'MonkData',
  [0xC2] = 'OpenMonsterPodiumWindow',
  [0xC3] = 'CyclopediaHouseAuctionMessage',
  [0xC4] = 'WeaponProficiencyInfo',
  [0xC5] = 'TournamentLeaderboard',
  [0xC6] = 'CyclopediaHousesInfo',
  [0xC7] = 'CyclopediaHouseList',
  [0xC8] = 'ChooseOutfit',
  [0xC9] = 'ExivaSuppressed',
  [0xCA] = 'ExivaRestrictions',
  [0xCB] = 'TransactionDetails',
  [0xCC] = 'SendUpdateImpactTracker',
  [0xCD] = 'SendItemsPrice',
  [0xCE] = 'SendUpdateSupplyTracker',
  [0xCF] = 'SendUpdateLootTracker',
  [0xD0] = 'QuestTracker',
  [0xD1] = 'KillTracker',
  [0xD2] = 'VipAdd',
  [0xD3] = 'VipState',
  [0xD4] = 'VipLogout',
  [0xD5] = 'BestiaryRaces',
  [0xD6] = 'BestiaryOverview',
  [0xD7] = 'BestiaryMonsterData',
  [0xD8] = 'BestiaryCharmsData',
  [0xD9] = 'BestiaryEntryChanged',
  [0xDA] = 'CyclopediaCharacterInfoData',
  [0xDB] = 'HirelingNameChange',
  [0xDC] = 'TutorialHint',
  [0xDD] = 'AutomapFlag',
  [0xDE] = 'SendDailyRewardCollectionState',
  [0xDF] = 'CoinBalance',
  [0xE0] = 'StoreError',
  [0xE1] = 'RequestPurchaseData',
  [0xE2] = 'SendOpenRewardWall',
  [0xE3] = 'SendCloseRewardWall',
  [0xE4] = 'SendDailyReward',
  [0xE5] = 'SendRewardHistory',
  [0xE6] = 'BosstiaryEntryChanged',  -- enum GameServerSendPreyFreeRerolls (GameBosstiary ON)
  [0xE7] = 'SendPreyTimeLeft',
  [0xE8] = 'SendPreyData',
  [0xE9] = 'SendPreyRerollPrice',
  [0xEA] = 'SendShowDescription',
  [0xEB] = 'SendImbuementWindow',
  [0xEC] = 'SendCloseImbuementWindow',
  [0xED] = 'SendError',
  [0xEE] = 'ResourceBalance',
  [0xEF] = 'WorldTime',
  [0xF0] = 'QuestLog',
  [0xF1] = 'QuestLine',
  [0xF2] = 'CoinBalanceUpdating',
  [0xF3] = 'ChannelEvent',
  [0xF4] = 'ItemInfo',
  [0xF5] = 'PlayerInventory',
  [0xF6] = 'MarketEnter',
  [0xF7] = 'MarketLeave',
  [0xF8] = 'MarketDetail',
  [0xF9] = 'MarketBrowse',
  [0xFA] = 'ModalDialog',
  [0xFB] = 'Store',
  [0xFC] = 'StoreOffers',
  [0xFD] = 'StoreTransactionHistory',
  [0xFE] = 'StoreCompletePurchase',
}

-- 'N' rows of docs/opcode-map.md §3: declared in the enum but with NO case in
-- ProtocolGame::parseMessage.  If one of these arrives the C++ client hits the
-- default branch and discards the rest of the message.
local NOT_IN_SWITCH = {
  [0x03] = true, [0x04] = true, [0x2C] = true, [0x2D] = true, [0x60] = true,
  [0x74] = true, [0x80] = true, [0x81] = true, [0x99] = true, [0xC5] = true,
  [0xC9] = true, [0xCB] = true, [0xDB] = true, [0xE3] = true, [0xF7] = true,
}
opcodes.serverReachable = {}
for v in pairs(opcodes.server) do
  opcodes.serverReachable[v] = not NOT_IN_SWITCH[v]
end

-- ---------------------------------------------------------------------------
-- CLIENT -> SERVER  (name -> value)
-- ---------------------------------------------------------------------------
opcodes.client = {
  EnterAccount               = 0x01,
  PendingGame                = 0x0A,
  EnterGame                  = 0x0F,
  LeaveGame                  = 0x14,
  PingBackGunz               = 0x1C,   -- the pong at 1530 (gunz OS && cv >= 1200)
  Ping                       = 0x1D,
  PingBack                   = 0x1E,   -- non-gunz pong
  UseStash                   = 0x28,
  BestiaryTrackerStatus      = 0x2A,
  PartyAnalyzerAction        = 0x2B,
  ExtendedOpcode             = 0x32,
  ChangeMapAwareRange        = 0x33,
  CreatureTyping             = 0x38,
  TaskBoardAction            = 0x5F,
  ImbuementDurations         = 0x60,
  OpenWheel                  = 0x61,
  SaveWheel                  = 0x62,
  AutoWalk                   = 0x64,
  WalkNorth                  = 0x65,
  WalkEast                   = 0x66,
  WalkSouth                  = 0x67,
  WalkWest                   = 0x68,
  Stop                       = 0x69,
  WalkNorthEast              = 0x6A,
  WalkSouthEast              = 0x6B,
  WalkSouthWest              = 0x6C,
  WalkNorthWest              = 0x6D,
  TutorialChangeVocation     = 0x6E,
  TurnNorth                  = 0x6F,
  TurnEast                   = 0x70,
  TurnSouth                  = 0x71,
  TurnWest                   = 0x72,
  GmTeleport                 = 0x73,
  StartOfflineTraining       = 0x74,
  EquipItem                  = 0x77,
  Move                       = 0x78,
  InspectNpcTrade            = 0x79,
  BuyItem                    = 0x7A,
  SellItem                   = 0x7B,
  CloseNpcTrade              = 0x7C,
  RequestTrade               = 0x7D,
  InspectTrade               = 0x7E,
  AcceptTrade                = 0x7F,
  RejectTrade                = 0x80,
  UseItem                    = 0x82,
  UseItemWith                = 0x83,
  UseOnCreature              = 0x84,
  RotateItem                 = 0x85,
  ConfigureShowOffSocket     = 0x86,
  CloseContainer             = 0x87,
  UpContainer                = 0x88,
  EditText                   = 0x89,
  EditList                   = 0x8A,
  OnWrapItem                 = 0x8B,
  Look                       = 0x8C,
  LookCreature               = 0x8D,
  SendQuickLoot              = 0x8F,
  LootContainer              = 0x90,
  QuickLootBlackWhitelist    = 0x91,
  Talk                       = 0x96,
  RequestChannels            = 0x97,
  JoinChannel                = 0x98,
  LeaveChannel               = 0x99,
  OpenPrivateChannel         = 0x9A,
  OpenRuleViolation          = 0x9B,
  CloseRuleViolation         = 0x9C,
  CancelRuleViolation        = 0x9D,
  CloseNpcChannel            = 0x9E,
  SetMonsterPodium           = 0x9F,
  ChangeFightModes           = 0xA0,
  Attack                     = 0xA1,
  Follow                     = 0xA2,
  InviteToParty              = 0xA3,
  JoinParty                  = 0xA4,
  RevokeInvitation           = 0xA5,
  PassLeadership             = 0xA6,
  LeaveParty                 = 0xA7,
  ShareExperience            = 0xA8,
  DisbandParty               = 0xA9,
  OpenOwnChannel             = 0xAA,
  InviteToOwnChannel         = 0xAB,
  ExcludeFromOwnChannel      = 0xAC,
  CyclopediaHouseAuction     = 0xAD,
  BosstiaryRequestInfo       = 0xAE,
  BosstiaryRequestSlotInfo   = 0xAF,
  BosstiaryRequestSlotAction = 0xB0,
  RequestHighscore           = 0xB1,
  ImbuementWindowAction      = 0xB2,
  WeaponProficiency          = 0xB3,
  SoulSealsAction            = 0xBA,
  CancelAttackAndFollow      = 0xBE,
  ForgeEnter                 = 0xBF,
  ForgeBrowseHistory         = 0xC0,
  UpdateTile                 = 0xC9,
  RefreshContainer           = 0xCA,   -- also ClientExivaRestrictions (same opcode)
  ExivaRestrictions          = 0xCA,
  BrowseField                = 0xCB,
  SeekInContainer            = 0xCC,
  InspectionObject           = 0xCD,
  InspectionCharacter        = 0xCE,
  RequestBless               = 0xCF,
  RequestTrackerQuestLog     = 0xD0,
  RequestOutfit              = 0xD2,
  ChangeOutfit               = 0xD3,
  Mount                      = 0xD4,
  ApplyImbuement             = 0xD5,
  ClearImbuement             = 0xD6,
  CloseImbuingWindow         = 0xD7,
  OpenRewardWall             = 0xD8,
  OpenRewardHistory          = 0xD9,
  GetRewardDaily             = 0xDA,
  AddVip                     = 0xDC,
  RemoveVip                  = 0xDD,
  EditVip                    = 0xDE,
  EditVipGroups              = 0xDF,
  BestiaryRequest            = 0xE1,
  BestiaryRequestOverview    = 0xE2,
  BestiaryRequestSearch      = 0xE3,
  CyclopediaSendBuyCharmRune = 0xE4,
  CyclopediaRequestCharacterInfo = 0xE5,
  BugReport                  = 0xE6,
  WheelGemAction             = 0xE7,
  DebugReport                = 0xE8,   -- suppressed on gunz OS
  PreyAction                 = 0xEB,
  PreyRequest                = 0xED,
  NpcGreet                   = 0xEE,
  TransferCoins              = 0xEF,
  RequestQuestLog            = 0xF0,
  RequestQuestLine           = 0xF1,
  NewRuleViolation           = 0xF2,
  RequestItemInfo            = 0xF3,
  MarketLeave                = 0xF4,
  MarketBrowse               = 0xF5,
  MarketCreate               = 0xF6,
  MarketCancel               = 0xF7,
  MarketAccept               = 0xF8,
  AnswerModalDialog          = 0xF9,
  OpenStore                  = 0xFA,
  RequestStoreOffers         = 0xFB,
  BuyStoreOffer              = 0xFC,
  OpenTransactionHistory     = 0xFD,
  RequestTransactionHistory  = 0xFE,
  RewardChestCollect         = 0xFF,
}

-- ---------------------------------------------------------------------------
-- reverse maps
-- ---------------------------------------------------------------------------
opcodes.names = { server = {}, client = {} }
for value, name in pairs(opcodes.server) do opcodes.names.server[name] = value end
for name, value in pairs(opcodes.client) do
  -- 0xCA has two names; keep the first alphabetically stable one
  if opcodes.names.client[value] == nil or name < opcodes.names.client[value] then
    opcodes.names.client[value] = name
  end
end

-- ---------------------------------------------------------------------------
-- Message modes (docs/opcode-map.md §4 -- buildMessageModesMap, >=1055 branch).
-- server wire byte -> Otc::MessageMode name.  Bytes 45,46,47 and >=53 are
-- unmapped: parseTalk / parseTextMessage throw on them.
-- ---------------------------------------------------------------------------
opcodes.messageMode = {
  [0]  = 'None',                [1]  = 'Say',                 [2]  = 'Whisper',
  [3]  = 'Yell',                [4]  = 'PrivateFrom',         [5]  = 'PrivateTo',
  [6]  = 'ChannelManagement',   [7]  = 'Channel',             [8]  = 'ChannelHighlight',
  [9]  = 'Spell',               [10] = 'NpcFromStartBlock',   [11] = 'NpcFrom',
  [12] = 'NpcTo',               [13] = 'GamemasterBroadcast', [14] = 'GamemasterChannel',
  [15] = 'GamemasterPrivateFrom', [16] = 'GamemasterPrivateTo', [17] = 'Login',
  [18] = 'Warning',             [19] = 'Game',                [20] = 'GameHighlight',
  [21] = 'Failure',             [22] = 'Look',                [23] = 'DamageDealed',
  [24] = 'DamageReceived',      [25] = 'Heal',                [26] = 'Exp',
  [27] = 'DamageOthers',        [28] = 'HealOthers',          [29] = 'ExpOthers',
  [30] = 'Status',              [31] = 'Loot',                [32] = 'TradeNpc',
  [33] = 'Guild',               [34] = 'PartyManagement',     [35] = 'Party',
  [36] = 'BarkLow',             [37] = 'BarkLoud',            [38] = 'Report',
  [39] = 'HotkeyUse',           [40] = 'TutorialHint',        [41] = 'Thankyou',
  [42] = 'Market',              [43] = 'Mana',                [44] = 'BeyondLast',
  [48] = 'Attention',           [49] = 'BoostedCreature',     [50] = 'OfflineTrainning',
  [51] = 'Transaction',         [52] = 'Potion',
}
opcodes.messageModeByte = {}
for byte, name in pairs(opcodes.messageMode) do opcodes.messageModeByte[name] = byte end

-- Proto::ItemOpcode (protocolcodes.h:36-42) -- the getThing discriminators.
opcodes.itemMarker = {
  StaticText       = 96,   -- declared but never handled: id 96 falls through to getItem
  UnknownCreature  = 97,
  OutdatedCreature = 98,
  Creature         = 99,
}

-- Otc::Direction (const.h:159-170)
opcodes.direction = {
  North = 0, East = 1, South = 2, West = 3,
  NorthEast = 4, SouthEast = 5, SouthWest = 6, NorthWest = 7, Invalid = 8,
}

return opcodes
