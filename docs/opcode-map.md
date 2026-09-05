# Complete server→client and client→server opcode maps for protocol/client 1530 (Gunzodus / mehah OTClient-Redemption), with 1530 feature gating and the minimum opcode set a headless Lua bot must parse to avoid stream desync.

> Full spec. All file paths absolute under `D:/Claude/otclient_mehah1530/otclient`.

Primary sources:
- `src/client/protocolcodes.h` — enums
- `src/client/protocolcodes.cpp` — message-mode maps
- `src/client/protocolgameparse.cpp` — `parseMessage` switch + all parsers
- `src/client/protocolgamesend.cpp` — all `send*`
- `modules/game_features/features.lua` — the ONLY place features are set
- `src/client/const.h` — `Otc::GameFeature`, `Otc::MessageMode`, `CLIENTOS_*`

---

## 0. Primitive encodings

`src/framework/net/inputmessage.cpp`, `outputmessage.cpp`:

| Type | Bytes | Notes |
|---|---|---|
| U8 | 1 | |
| U16 | 2 | little-endian |
| U32 | 4 | little-endian |
| U64 | 8 | little-endian unsigned |
| I64 (`get64`) | 8 | little-endian **signed** |
| STR | 2 + N | `u16 length` then raw bytes (no NUL) |
| **DOUBLE** | **5** | `u8 precision`, `u32 raw`; value `= (raw - 2147483647) / 10^precision` (inputmessage.cpp:101-106) — NOT IEEE754 |
| Position | 5 | `u16 x`, `u16 y`, `u8 z` (parse: protocolgameparse.cpp:4700; send: protocolgamesend.cpp:1571) |

`packedCount1500` (protocolgameparse.cpp:3895-3908), used only by opcode 0xF5:
```
b1 = u8
b1 < 0x40  -> b1                                (1 byte)
b1 < 0x80  -> ((b1-0x40)<<8) | u8               (2 bytes)
else       -> (u8<<16)|(u8<<8)|u8               (4 bytes total; b1 discarded)
```

---

## 1. Feature flags AT 1530 (authoritative)

`Game::setClientVersion` (game.cpp:1727-1743) does `m_features.reset()` then calls Lua
`g_game.onClientVersionChange`. `features.lua` is the entire ruleset; the C++ side enables nothing.
For **version 1530** the set is the cumulative union of every `version >= N` block with N ≤ 1530,
minus the explicit `disableFeature` calls.

### ON at 1530 (id, name)
22 GameFormatCreatureName, 122 GameAllowPreWalk, 125 GameMapCache,
79 GameSoul, 78 GameLevelU16,
42 GameLooktypeU16, 45 GameMessageStatements, 63 GameLoginPacketEncryption,
44 GamePlayerAddons, 43 GamePlayerStamina, 47 GameNewFluids, 46 GameMessageLevel,
48 GamePlayerStateU16, 49 GameNewOutfitProtocol, 51 GameWritableDate,
1 GameProtocolChecksum, 2 GameAccountNames, 6 GameDoubleFreeCapacity,
3 GameChallengeOnLogin, 61 GameMessageSizeCheck, 124 GameTileAddThingWithStackpos,
14 GameCreatureEmblems, 32 GameAttackSeq, 4 GamePenalityOnDeath,
7 GameDoubleExperience, 12 GamePlayerMounts, 23 GameSpellList,
5 GameNameOnNpcTrade, 8 GameTotalCapacity, 9 GameSkillsBase,
10 GamePlayerRegenerationTime, 11 GameChannelPlayerList,
17 GamePlayerMarket, 21 GamePurseSlot, 24 GameClientPing,
18 GameSpritesU32, 20 GameOfflineTrainingTime, 52 GameAdditionalVipInfo,
98 GameDoublePlayerGoodsMoney, 62 GamePreviewState, 64 GameClientVersion,
35 GameLoginPending, 36 GameNewSpeedLaw, 40 GameContainerPagination, 58 GameBrowseField,
41 GameThingMarks, 50 GamePVPMode, 29 GameDoubleSkills, 53 GameBaseSkillU16,
54 GameCreatureIcons, 55 GameHideNpcNames, 57 GamePremiumExpiration, 59 GameEnhancedAnimations,
68 GameUnjustifiedPoints, 66 GameExperienceBonus, 70 GameDeathType, 71 GameIdleAnimations,
60 GameOGLInformation, 65 GameContentRevision, 67 GameAuthenticator, 69 GameSessionKey,
73 GameIngameStore, 75 GameIngameStoreServiceType, 74 GameIngameStoreHighlights,
82 GamePrey, 121 GameColorizedLootValue, 83 GameThingQuickLoot, 96 GameVipGroups,
114 GameEnterGameShowAppearance, 84 GameThingQuiver, 85 GameThingPodium,
86 GameThingUpgradeClassification, 123 GamePlayerFamiliars, 90 GameSequencedPackets,
97 GameBosstiary, 88 GameThingClock, 87 GameThingCounter, 89 GameThingPodiumItemType,
39 GameDoubleShopSellAmount, 28 GameDoubleHealth, 91 GameUshortSpell, 94 GameConcotions,
95 GameAnthem, 93 GameDynamicForgeVariables, 105 GameEffectU16, 106 GameContainerTypes,
107 GameBosstiaryTracker, 108 GamePlayerStateCounter, 110 GameItemAugment,
111 GameDynamicBugReporter, 112 GameWrapKit, 113 GameContainerFilter, 119 GameForgeConvergence,
127 GameCharacterSkillStats, 130 GameVocationMonk, 135 GameProficiency,
133 GameNpcWindowRedesign, 132 GameEffectSource, 131 GameLevelPercentU16, 134 GameTaskboard,
**136 GameTacticsWithoutFightMode**.

### Explicitly DISABLED again before 1530
13 GameEnvironmentEffect (off @1281), 15 GameItemAnimationPhase (off @1281),
92 GameTournamentPackets (off @1314), 109 GameLeechAmount (off @1320),
76 GameAdditionalSkills (off @1410), 126 GameForgeSkillStats (off @1410).

### NEVER enabled — must be treated as FALSE
16 GameMagicEffectU16, 25 GameExtendedClientPing, 30 GameChangeMapAwareRange,
**31 GameMapMovePosition**, 33 GameBlueNpcNameColor, 34 GameDiagonalAnimatedText,
37 GameForceFirstAutoWalkStep, **38 GameMinimapRemove**, 56 GameSpritesAlphaChannel,
72 GameKeepUnawareTiles, 77 GameDistanceEffectU16, 80 GameMapOldEffectRendering,
81 GameMapDontCorrectCorpse, 100 GameLoadSprInsteadProtobuf, 101 GameItemShader,
102 GameCreatureShader, 103 GameCreatureAttachedEffect, **104 GameCountU16**,
115 GameSmoothWalkElevation, 116 GameNegativeOffset, 117 GameItemTooltipV8,
118 GameWingsAurasEffectsShader, 120 GameAllowCustomBotScripts, 128 GameCreaturePaperdoll,
129 GameMultiSpr.

> **Runtime override:** server opcode `0x43 GameServerFeatures` (protocolgameparse.cpp:7501-7513)
> can flip ANY of these mid-session: `u16 count`, then `count × (u8 featureId, u8 enabled)`.
> A Lua client MUST implement it and re-key its conditionals, or later packets desync.

### 1530 Gunzodus specifics (OS id 61 = `CLIENTOS_GUNZ_WINDOWS`, const.h:38-40)
`features.lua:295-306` at `version >= 1530`: `g_game.setRsa(GUNZODUS_RSA)`, `g_game.setCustomOs(61)`.
`isGunzOs := 60 <= os <= 62`, so every `isGunzOs` branch in the send file is live.

---

## 2. `parseMessage` loop (protocolgameparse.cpp:47-742)

```
while not eof:
  opcode = u8
  # GameLoginPending is ON, so the "auto processGameStart on opcode>50" branch is skipped
  readPos = pos; if luaOnOpcode(opcode,msg) then continue end; pos = readPos   # 66-71
  switch opcode ...
  default: log + skipBytes(unreadSize)   # 680-700  -- REST OF MESSAGE DISCARDED
```
1. **Multiple opcodes are packed per XTEA message**; the loop runs to `eof()` of the decrypted body.
2. **An unknown opcode is not recoverable** — line 698 throws away the whole remainder. The comment
   at 693-697 explains why `setReadPos(getMessageSize())` would busy-loop / OOM instead.
3. `GameServerStoreOffers (0xFC)` is the only case with its own try/catch that skips the rest of its
   own payload on failure (652-670).
4. Any throw hits the outer catch (704-741), which logs and **abandons the whole message**.
5. `modules/gamelib/protocolgame.lua:1-15` — the Lua `onOpcode` table is empty by default, so in a
   stock 1530 session nothing is diverted away from the C++ switch.

---

## 3. SERVER → CLIENT opcode table (complete)

`P` column: `Y` = reachable/handled at 1530; `N` = version-gated away or absent from the switch
(→ `default` → rest of message lost).

| Hex | Dec | Enum | Parser | Payload (1530 resolution) | P |
|---|---|---|---|---|---|
| 0x03 | 3 | GameServerSessionCreatureData | — | **not in switch** | N |
| 0x04 | 4 | GameServerSessionDumpStart | — | **not in switch** | N |
| 0x0A | 10 | GameServerLoginOrPendingState | `parsePendingGame` | *empty* (GameLoginPending ON) | Y |
| 0x0B | 11 | GameServerGMActions | `parseGMActions` | `STR` (>=1200 secondary-connection id; nothing else) | Y |
| 0x0F | 15 | GameServerEnterGame | `parseEnterGame` | *empty* → game start | Y |
| 0x11 | 17 | GameServerUpdateNeeded | `parseUpdateNeeded` | `STR signature` | Y |
| 0x14 | 20 | GameServerLoginError | `parseLoginError` | `STR error` + (>=1523 **and** unread>0) `u8 reason` | Y |
| 0x15 | 21 | GameServerLoginAdvice | `parseLoginAdvice` | `STR` | Y |
| 0x16 | 22 | GameServerLoginWait | `parseLoginWait` | `STR message`, `u8 time` | Y |
| 0x17 | 23 | GameServerLoginSuccess | `parseLogin` | §3.1 | Y |
| 0x18 | 24 | GameServerSessionEnd | `parseSessionEnd` | `u8 reason` | Y |
| 0x19 | 25 | GameServerStoreButtonIndicators | `parseStoreButtonIndicators` | `u8 saleBanner`, `u8 newBanner` | Y |
| 0x1A | 26 | GameServerBugReport | `parseBugReport` | `u8 canReportBugs` | Y |
| 0x1B | 27 | GameServerMultiOfflineTrainingDialog | `parseMultiOfflineTrainingDialog` | *empty* | Y |
| 0x1C | 28 | GameServerNpcChatWindow | `parseNpcChatWindow` | `u8 status`; if 0: `u8 npcCount`, npcCount×`u32`, `u8 btnCount`, btnCount×(`u8 id`,`STR text`) | Y |
| 0x1D | 29 | GameServerPingBack | `parsePing` (GameClientPing ON) | *empty*; **client must answer with a pong** | Y |
| 0x1E | 30 | GameServerPing | `parsePingBack` (GameClientPing ON) | *empty*; answer to our own ping | Y |
| 0x1F | 31 | GameServerChallenge | `parseLoginChallenge` | `u32 timestamp`, `u8 random`, **`u8 skipped` (>=1405)** → send login packet | Y |
| 0x28 | 40 | GameServerDeath | `parseDeath` | `u8 deathType`; if `==0` `u8 penalty`; `u8 canUseDeathRedemption` (>=1281) | Y |
| 0x29 | 41 | GameServerSupplyStash | `parseSupplyStash` | `u16 n`, n×(`u16 itemId`,`u32 amount`); the `u16 freeSlots` is protocol<1410 only ⇒ **absent** | Y |
| 0x2A | 42 | GameServerSpecialContainer | `parseSpecialContainer` | `u8 supplyStashAvailable`, `u8 isMarketAvailable` (protocol>=1220) | Y |
| 0x2B | 43 | GameServerPartyAnalyzer | `parsePartyAnalyzer` | `u32 startTime`,`u32 leaderId`,`u8 lootType`,`u8 members`, members×(`u32 id`,`u8 highlight`,`u64 loot`,`u64 supply`,`u64 damage`,`u64 healing`), `u8 hasNames`; if 1: `u8 n`, n×(`u32 id`,`STR name`) | Y |
| 0x2C | 44 | GameServerTeamFinderTeamLeader | — | **not in switch** | N |
| 0x2D | 45 | GameServerTeamFinderTeamMember | — | **not in switch** | N |
| 0x32 | 50 | GameServerExtendedOpcode | `parseExtendedOpcode` | `u8 subOpcode`, `STR buffer`; sub 0 → enables client extended sends; sub 2 → pong | Y |
| 0x33 | 51 | GameServerChangeMapAwareRange | `parseChangeMapAwareRange` | `u8 xRange`, `u8 yRange` → recomputes aware range | Y |
| 0x34 | 52 | GameServerAttchedEffect | `parseAttachedEffect` | `u32 creatureId`, `u16 effectId` | Y |
| 0x35 | 53 | GameServerDetachEffect | `parseDetachEffect` | `u32 creatureId`, `u16 effectId` | Y |
| 0x36 | 54 | GameServerCreatureShader | `parseCreatureShader` | `u32 creatureId`, `STR shaderName` | Y |
| 0x37 | 55 | GameServerMapShader | `parseMapShader` | `STR shaderName` | Y |
| 0x38 | 56 | GameServerCreatureTyping | `parseCreatureTyping` | `u32 creatureId`, `u8 typing` | Y |
| 0x3C | 60 | GameServerAttachedPaperdoll | `parseAttachedPaperdoll` | `u32 creatureId`, paperdoll block | Y |
| 0x3D | 61 | GameServerDetachPaperdoll | `parseDetachPaperdoll` | `u32 creatureId`, `u8 bySlot`, `u16 idOrSlot` | Y |
| 0x43 | 67 | GameServerFeatures | `parseFeatures` | `u16 n`, n×(`u8 featureId`, `u8 enabled`) — **mutates every conditional below** | Y |
| 0x4B | 75 | GameServerFloorDescription | `parseFloorDescription` | `Position(5)`, `u8 floor`, one floor description | Y |
| 0x5B | 91 | GameServerTaskBoard | `parseTaskBoardData` | `u8 subtype` (0 bounty/1 weekly/2 hunt-shop) + variable body; **throws on unknown subtype** | Y |
| 0x5C | 92 | GameServerWeaponProficiencyExperience | `parseWeaponProficiencyExperience` | `u16 itemId`, `u32 experience`, `u8 hasUnusedPerk` | Y |
| 0x5D | 93 | GameServerImbuementDurations | `parseImbuementDurations` | `u8 count` + per-item tracker records | Y |
| 0x5E | 94 | GameServerPassiveCooldown | `parsePassiveCooldown` | `u8`, `u8 type`; type0: `u32 cur`,`u32 max`,`u8 canDecay`; type1: `u8`,`u8` | Y |
| 0x5F | 95 | GameServerOpenWheelWindow | `parseOpenWheelWindow` | destiny-wheel window blob | Y |
| 0x60 | 96 | GameServerInventoryImbuements | — | **declared but NOT in the switch** | N |
| 0x61 | 97 | GameServerBosstiaryData | `parseBosstiaryData` | exactly **18 × u16** | Y |
| 0x62 | 98 | GameServerBosstiarySlots | `parseBosstiarySlots` | slot records (`u8 race`,`u32 kills`,`u16 lootBonus`,…) | Y |
| 0x63 | 99 | GameServerSendClientCheck | `parseClientCheck` | `u32 size`, then `size` raw bytes | Y |
| 0x64 | 100 | GameServerFullMap | `parseMapDescription` | `Position(5)` + full map description | Y |
| 0x65 | 101 | GameServerMapTopRow | `parseMapMoveNorth` | **no position prefix** + 1-row description | Y |
| 0x66 | 102 | GameServerMapRightRow | `parseMapMoveEast` | 1-column description | Y |
| 0x67 | 103 | GameServerMapBottomRow | `parseMapMoveSouth` | 1-row description | Y |
| 0x68 | 104 | GameServerMapLeftRow | `parseMapMoveWest` | 1-column description | Y |
| 0x69 | 105 | GameServerUpdateTile | `parseUpdateTile` | `Position(5)` + tile description | Y |
| 0x6A | 106 | GameServerCreateOnMap | `parseTileAddThing` | `Position(5)`, **`u8 stackpos`**, `Thing` | Y |
| 0x6B | 107 | GameServerChangeOnMap | `parseTileTransformThing` | `MappedThing`, `Thing` | Y |
| 0x6C | 108 | GameServerDeleteOnMap | `parseTileRemoveThing` | `MappedThing` | Y |
| 0x6D | 109 | GameServerMoveCreature | `parseCreatureMove` | `MappedThing`, `Position(5)` | Y |
| 0x6E | 110 | GameServerOpenContainer | `parseOpenContainer` | §3.2 | Y |
| 0x6F | 111 | GameServerCloseContainer | `parseCloseContainer` | `u8 containerId` | Y |
| 0x70 | 112 | GameServerCreateContainer | `parseContainerAddItem` | `u8 cid`, `u16 slot`, `Item` | Y |
| 0x71 | 113 | GameServerChangeInContainer | `parseContainerUpdateItem` | `u8 cid`, `u16 slot`, `Item` | Y |
| 0x72 | 114 | GameServerDeleteInContainer | `parseContainerRemoveItem` | `u8 cid`, `u16 slot`, `u16 lastItemId`; if `!=0` → `Item(id=lastItemId)` | Y |
| 0x73 | 115 | GameServerBosstiaryInfo | `parseBosstiaryInfo` | `u16 n`, n×(`u32 raceId`,`u8 category`,`u32 kills`,`u8`,`u8 trackerActive`(>=1320)) | Y |
| 0x74 | 116 | GameServerFriendSystemData | — | **not in switch** | N |
| 0x75 | 117 | GameServerTakeScreenshot | `parseClientEvent` | >=1521 client-event system: `u8 type` + variable | Y |
| 0x76 | 118 | GameServerCyclopediaItemDetail | `parseCyclopediaItemDetail` | `u8 windowType`,`u8 inspectionType`,`u32 creatureId` + branch | Y |
| 0x77 | 119 | GameServerInspectionState | `parseInspectionState` | `u32 creatureId`, `u8 state` | Y |
| 0x78 | 120 | GameServerSetInventory | `parseAddInventoryItem` | `u8 slot`, `Item` | Y |
| 0x79 | 121 | GameServerDeleteInventory | `parseRemoveInventoryItem` | `u8 slot` | Y |
| 0x7A | 122 | GameServerOpenNpcTrade | `parseOpenNpcTrade` | `STR npcName`, `u16 currencyId`, `STR currencyName`, `u16 n`, n×(`u16 itemId`,`u8 count`,`STR name`,`u32 weight`,`u32 buy`,`u32 sell`) | Y |
| 0x7B | 123 | GameServerPlayerGoods | `parsePlayerGoods` | (>=1281 **no money field**), `u16 n` (>=1334), n×(`u16 itemId`, `u16 amount`) | Y |
| 0x7C | 124 | GameServerCloseNpcTrade | `parseCloseNpcTrade` | *empty* | Y |
| 0x7D | 125 | GameServerOwnTrade | `parseOwnTrade` | `STR name`, `u8 n`, n×`Item` | Y |
| 0x7E | 126 | GameServerCounterTrade | `parseCounterTrade` | `STR name`, `u8 n`, n×`Item` | Y |
| 0x7F | 127 | GameServerCloseTrade | `parseCloseTrade` | *empty* | Y |
| 0x80 | 128 | GameServerCharacterTradeConfiguration | — | **not in switch** | N |
| 0x81 | 129 | GameServerReportTextUI | — | **not in switch** | N |
| 0x82 | 130 | GameServerAmbient | `parseWorldLight` | `u8 intensity`, `u8 color` | Y |
| 0x83 | 131 | GameServerGraphicalEffect | `parseMagicEffect` | protocol>=1203 loop; §3.3 | Y |
| 0x84 | 132 | GameServerTextEffect | `parseRemoveMagicEffect` (>=1320) | `Position(5)`, `u16 effectId` | Y |
| 0x85 | 133 | GameServerMissleEffect | `parseAnthem` (GameAnthem ON) | `u8 type`; if `type<=2` `u16 anthemId`. `parseDistanceMissile` **unreachable** | Y |
| 0x86 | 134 | GameServerItemClasses | `parseItemClasses` (>=1281) | forge config; `parseCreatureMark` unreachable | Y |
| 0x87 | 135 | GameServerTrappers | `parseOpenForge` (>=1281) | forge open data; `parseTrappers` unreachable | Y |
| 0x88 | 136 | GameServerBrowseForgeHistory | `parseBrowseForgeHistory` | forge history page | Y |
| 0x89 | 137 | GameServerCloseForgeWindow | `parseCloseForgeWindow` | *empty* | Y |
| 0x8A | 138 | GameServerForgeResult | `parseForgeResult` (>=1281) | `u8 action`,`u8 convergence`,`u8 success`,`u16 leftId`,`u8 leftTier`,`u16 rightId`,`u8 rightTier`, + bonus branch | Y |
| 0x8B | 139 | GameServerCreatureData | `parseCreatureData` | `u32 creatureId`, `u8 type`; **0**→`getCreature`; **11/12/13**→`u8 vocation`; **14**→icon list (§3.4); other types consume nothing | Y |
| 0x8C | 140 | GameServerCreatureHealth | `parseCreatureHealth` | `u32 creatureId`, `u8 healthPercent` | Y |
| 0x8D | 141 | GameServerCreatureLight | `parseCreatureLight` | `u32 creatureId`, `u8 intensity`, `u8 color` | Y |
| 0x8E | 142 | GameServerCreatureOutfit | `parseCreatureOutfit` | `u32 creatureId`, `Outfit` (with mount) | Y |
| 0x8F | 143 | GameServerCreatureSpeed | `parseCreatureSpeed` | `u32 creatureId`, `u16 baseSpeed` (>=1059), `u16 speed` | Y |
| 0x90 | 144 | GameServerCreatureSkull | `parseCreatureSkulls` | `u32 creatureId`, `u8 skull` | Y |
| 0x91 | 145 | GameServerCreatureParty | `parseCreatureShields` | `u32 creatureId`, `u8 shield` | Y |
| 0x92 | 146 | GameServerCreatureUnpass | `parseCreatureUnpass` | `u32 creatureId`, `u8 unpassable` | Y |
| 0x93 | 147 | GameServerCreatureMarks | `parseCreaturesMark` | `u32 creatureId`, `u8 squareType`, `u8 squareColor` (>=1076 → 2 bytes) | Y |
| 0x94 | 148 | GameServerPlayerHelpers | `parsePlayerHelpers` | `u32 creatureId`, `u16 helpers` | Y |
| 0x95 | 149 | GameServerCreatureType | `parseCreatureType` | `u32 creatureId`, `u8 type` (0 player,1 monster,2 npc,3 own summon,4 other summon,5 hidden) | Y |
| 0x96 | 150 | GameServerEditText | `parseEditText` | `u32 windowId`, `Item` (>=1010), `u16 maxLength`, `STR text`, `STR writer`, `u8 suffix`(>=1281), `STR date` | Y |
| 0x97 | 151 | GameServerEditList | `parseEditList` | `u8 doorId`, `u32 windowId`, `STR text` | Y |
| 0x98 | 152 | GameServerSendGameNews | `parseGameNews` | `u32 categoryId`, `u8 page` | Y |
| 0x99 | 153 | GameServerDepotSearchDetailList | — | **not in switch** | N |
| 0x9A | 154 | GameServerCloseDepotSearch | `parseCloseDepotSearch` | *empty* | Y |
| 0x9B | 155 | GameServerSendBlessDialog | `parseBlessDialog` | `u8 totalBless` + per-bless records + trailer | Y |
| 0x9C | 156 | GameServerBlessings | `parseBlessings` | `u16 blessingsBitmask`, `u8 visualState` (>=1200) | Y |
| 0x9D | 157 | GameServerPreset | `parsePreset` | `u32 preset` | Y |
| 0x9E | 158 | GameServerPremiumTrigger | `parsePremiumTrigger` | `u8 n`, n×`u8` | Y |
| 0x9F | 159 | GameServerPlayerDataBasic | `parsePlayerInfo` | `u8 premium`, `u32 premiumExpiration`, `u8 vocation`, `u8 preyEnabled`, `u16 spellCount`, spellCount×`u16 spellId`, `u8 magicShieldActive` (>=1281) | Y |
| 0xA0 | 160 | GameServerPlayerData | `parsePlayerStats` | §3.5 (exactly 60 bytes) | Y |
| 0xA1 | 161 | GameServerPlayerSkills | `parsePlayerSkills` | §3.6 | Y |
| 0xA2 | 162 | GameServerPlayerState | `parsePlayerState` | `u64 states` (>=1405) + `u8 iconsCounter` → **9 bytes** | Y |
| 0xA3 | 163 | GameServerClearTarget | `parsePlayerCancelAttack` | `u32 seq` + **`u32 discarded` (>=1530)** → **8 bytes** | Y |
| 0xA4 | 164 | GameServerSpellDelay | `parseSpellCooldown` | `u16 spellId`, `u32 delayMs` | Y |
| 0xA5 | 165 | GameServerSpellGroupDelay | `parseSpellGroupCooldown` | `u8 groupId`, `u32 delayMs` | Y |
| 0xA6 | 166 | GameServerMultiUseDelay | `parseMultiUseCooldown` | `u32 delayMs` | Y |
| 0xA7 | 167 | GameServerPlayerModes | `parsePlayerModes` | `u8 chaseMode`, `u8 safeMode`, `u8 pvpMode` (**no fightMode byte**) | Y |
| 0xA8 | 168 | GameServerSetStoreDeepLink | `parseSetStoreDeepLink` | `u8 serviceType` | Y |
| 0xA9 | 169 | GameServerSendRestingAreaState | `parseRestingAreaState` | `u8 zone`, `u8 state`, `STR message` | Y |
| 0xAA | 170 | GameServerTalk | `parseTalk` | §3.7 | Y |
| 0xAB | 171 | GameServerChannels | `parseChannelList` | `u8 n`, n×(`u16 channelId`, `STR name`) | Y |
| 0xAC | 172 | GameServerOpenChannel | `parseOpenChannel` | `u16 id`, `STR name`, `u16 joined`, joined×`STR`, `u16 invited`, invited×`STR` | Y |
| 0xAD | 173 | GameServerOpenPrivateChannel | `parseOpenPrivateChannel` | `STR name` | Y |
| 0xAE | 174 | GameServerRuleViolationChannel | `parseRuleViolationChannel` | `u16 channelId` | Y |
| 0xAF | 175 | GameServerRuleViolationRemove | `parseExperienceTracker` (>=1200) | **`i64 rawExp`, `i64 finalExp`** (16 bytes) | Y |
| 0xB0 | 176 | GameServerRuleViolationCancel | `parseRuleViolationCancel` | `STR name` | Y |
| 0xB1 | 177 | GameServerRuleViolationLock | `parseHighscores` (>=1310) | `u8 isEmpty`; if 0 → highscore page blob | Y |
| 0xB2 | 178 | GameServerOpenOwnChannel | `parseOpenOwnPrivateChannel` | same as 0xAC | Y |
| 0xB3 | 179 | GameServerCloseChannel | `parseCloseChannel` | `u16 channelId` | Y |
| 0xB4 | 180 | GameServerTextMessage | `parseTextMessage` | §3.8 | Y |
| 0xB5 | 181 | GameServerCancelWalk | `parseCancelWalk` | **`u8 direction`** (0 N,1 E,2 S,3 W,4 NE,5 SE,6 SW,7 NW) | Y |
| 0xB6 | 182 | GameServerWalkWait | `parseWalkWait` | `u16 millis` | Y |
| 0xB7 | 183 | GameServerUnjustifiedStats | `parseUnjustifiedStats` | **7 × u8**: killsDay, killsDayRemaining, killsWeek, killsWeekRemaining, killsMonth, killsMonthRemaining, skullTime | Y |
| 0xB8 | 184 | GameServerPvpSituations | `parsePvpSituations` | `u8 openPvpSituations` | Y |
| 0xB9 | 185 | GameServerBestiaryRefreshTracker | `parseBestiaryTracker` | `u8 trackerType` (>=1320), `u8 n`, n×records | Y |
| 0xBA | 186 | GameServerTaskHuntingBasicData | `parseTaskHuntingBasicData` | **GameTaskboard ON** → soulseal mastered-race list (NOT the legacy prey lists) | Y |
| 0xBB | 187 | GameServerTaskHuntingData | `parseTaskHuntingData` | `u8 slot`, `u8 state` + per-state branch | Y |
| 0xBC | 188 | *(undefined)* | — | no enum, no case | N |
| 0xBD | 189 | GameServerBosstiaryCooldownTimer | `parseBosstiaryCooldownTimer` | `u16 n`, n×(`u32 bossRaceId`, `u64 cooldownSeconds`) | Y |
| 0xBE | 190 | GameServerFloorChangeUp | `parseFloorChangeUp` | **no position prefix**; floor descriptions | Y |
| 0xBF | 191 | GameServerFloorChangeDown | `parseFloorChangeDown` | **no position prefix**; floor descriptions | Y |
| 0xC0 | 192 | GameServerLootContainers | `parseLootContainers` | `u8 fallbackToMain`, `u8 n`, n×(`u8 category`,`u16 lootContainerId`,`u16 obtainerContainerId`(>=1332)) | Y |
| 0xC1 | 193 | GameServerMonkData | `parseMonkData` | `u8 subtype`; harmony→`u8`; serene→`u8`; virtue→`u8 count`+count×`u16 spellId` | Y |
| 0xC2 | 194 | GameServerOpenMonsterPodiumWindow | `parseOpenMonsterPodiumWindow` | gunz-only; **bare** outfit blocks (no feature tests) + entry list | Y |
| 0xC3 | 195 | GameServerCyclopediaHouseAuctionMessage | `parseCyclopediaHouseAuctionMessage` | `u32 houseId`, `u8 type`, if `type==1` `u8`, `u8 index` | Y |
| 0xC4 | 196 | GameServerWeaponProficiencyInfo | `parseWeaponProficiencyInfo` | `u16 itemId`, `u32 exp`, `u8 perks`, perks×(`u8 level`,`u8 pos`), **`u8 detailCount` (>=1530; layout unknown)** | Y |
| 0xC5 | 197 | GameServerTournamentLeaderboard | — | **not in switch** | N |
| 0xC6 | 198 | GameServerCyclopediaHousesInfo | `parseCyclopediaHousesInfo` | `u32 houseClientId`, `u8`, … | Y |
| 0xC7 | 199 | GameServerCyclopediaHouseList | `parseCyclopediaHouseList` | house list blob | Y |
| 0xC8 | 200 | GameServerChooseOutfit | `parseOpenOutfitWindow` | `Outfit`, if mount==0 4×`u8` colours (>=1281), then outfit/mount/familiar lists | Y |
| 0xC9 | 201 | GameServerExivaSuppressed | — | **not in switch** | N |
| 0xCA | 202 | GameServerExivaRestrictions | `parseExivaRestrictions` | 6×`u8` flags, then 4 × (`u16 n`, n×`STR`) | Y |
| 0xCB | 203 | GameServerTransactionDetails | — | **not in switch** | N |
| 0xCC | 204 | GameServerSendUpdateImpactTracker | `parseUpdateImpactTracker` | `u8 type`, `u32 amount`; `type==1`→`u8 element`; `type==2`→`u8 element`,`STR target` | Y |
| 0xCD | 205 | GameServerSendItemsPrice | `parseItemsPrice` | `u16 n`, n×(`u16 itemId`, [`u8 tier` iff classification>0], `u64 price`) | Y |
| 0xCE | 206 | GameServerSendUpdateSupplyTracker | `parseUpdateSupplyTracker` | `u16 itemId` | Y |
| 0xCF | 207 | GameServerSendUpdateLootTracker | `parseUpdateLootTracker` | `Item`, `STR itemName` | Y |
| 0xD0 | 208 | GameServerQuestTracker | `parseQuestTracker` | `u8 msgType`; 1→`u8 remaining`,`u8 n`,n×(`u16 missionId`,`u16 questId`,`STR`,`STR`,`STR`); 0→`u16 questId`,`u16 missionId`,`STR`,`STR`,`STR` | Y |
| 0xD1 | 209 | GameServerKillTracker | `parseKillTracker` | `STR monsterName`, `Outfit(parseMount=false)`, `u8 n`, n×`Item` | Y |
| 0xD2 | 210 | GameServerVipAdd | `parseVipAdd` | `u32 id`,`STR name`,`STR desc`,`u32 iconId`,`u8 notifyLogin`,`u8 status`,`u8 groupCount`,groupCount×`u8` | Y |
| 0xD3 | 211 | GameServerVipState | `parseVipState` | `u32 playerId`, `u8 status` | Y |
| 0xD4 | 212 | GameServerVipLogout | `parseVipLogout` | GameVipGroups ON → `u8 n`, n×(`u8 groupId`,`STR name`,`u8 canEdit`), `u8 groupsLeft` (**NOT a u32 playerId**) | Y |
| 0xD5 | 213 | GameServerBestiaryRaces | `parseBestiaryRaces` | race list | Y |
| 0xD6 | 214 | GameServerBestiaryOverview | `parseBestiaryOverview` | overview list | Y |
| 0xD7 | 215 | GameServerBestiaryMonsterData | `parseBestiaryMonsterData` | monster detail blob | Y |
| 0xD8 | 216 | GameServerBestiaryCharmsData | `parseBestiaryCharmsData` | charm list blob | Y |
| 0xD9 | 217 | GameServerBestiaryEntryChanged | `parseBestiaryEntryChanged` | `u16 monsterId` | Y |
| 0xDA | 218 | GameServerCyclopediaCharacterInfoData | `parseCyclopediaCharacterInfo` | `u8 type`, `u8 errorCode`; if error>0 stop, else per-type blob | Y |
| 0xDB | 219 | GameServerHirelingNameChange | — | **not in switch** | N |
| 0xDC | 220 | GameServerTutorialHint | `parseTutorialHint` | `u8 id` | Y |
| 0xDD | 221 | GameServerAutomapFlag | `parseAutomapFlag` | `u8 subtype` (**must be 0 or it throws**), `Position(5)`, `u8 icon`, `STR description`; **no remove byte** | Y |
| 0xDE | 222 | GameServerSendDailyRewardCollectionState | `parseDailyRewardCollectionState` | `u8 state` | Y |
| 0xDF | 223 | GameServerCoinBalance | `parseCoinBalance` | `u8 update`; if 1: `u32 coins`,`u32 transferable`,`u32 auction`(>=1281); no tournament u32 | Y |
| 0xE0 | 224 | GameServerStoreError | `parseStoreError` | `u8 errorType`, `STR message` | Y |
| 0xE1 | 225 | GameServerRequestPurchaseData | `parseRequestPurchaseData` | `u32 transactionId`, `u8 productType` | Y |
| 0xE2 | 226 | GameServerSendOpenRewardWall | `parseOpenRewardWall` | `u8 bonusShrine`, `u32 nextRewardTime`, `u8 dayStreak`, `u8 wasTaken`, … | Y |
| 0xE3 | 227 | GameServerSendCloseRewardWall | — | **not in switch** | N |
| 0xE4 | 228 | GameServerSendDailyReward | `parseDailyReward` | daily-reward blob | Y |
| 0xE5 | 229 | GameServerSendRewardHistory | `parseRewardHistory` | history blob | Y |
| 0xE6 | 230 | GameServerSendPreyFreeRerolls **/ BosstiaryEntryChanged** | `parseBosstiaryEntryChanged` (GameBosstiary ON) | **`u32 bossId`** — the prey form (`u8`,`u16`) is **unreachable at 1530** | Y |
| 0xE7 | 231 | GameServerSendPreyTimeLeft | `parsePreyTimeLeft` | `u8 slot`, `u16 timeLeft` | Y |
| 0xE8 | 232 | GameServerSendPreyData | `parsePreyData` | `u8 slot`, `u8 state` + per-state branch | Y |
| 0xE9 | 233 | GameServerSendPreyRerollPrice | `parsePreyRerollPrice` | `u32 price`, `u8 wildcard`, `u8 directly`; **GameTaskboard ON ⇒ the 4 task-hunting price fields are NOT read** | Y |
| 0xEA | 234 | GameServerSendShowDescription | `parseShowDescription` | `u32 offerId`, `STR description` | Y |
| 0xEB | 235 | GameServerSendImbuementWindow | `parseImbuementWindow` | `u8 windowType` (>=1510) + per-type blob | Y |
| 0xEC | 236 | GameServerSendCloseImbuementWindow | `parseCloseImbuementWindow` | *empty* | Y |
| 0xED | 237 | GameServerSendError | `parseError` | `u8 code`, `STR error` | Y |
| 0xEE | 238 | GameServerResourceBalance | `parseResourceBalance` | `u8 type`; CHARM/MINOR_CHARM/MAX_CHARM/MAX_MINOR_CHARM/BOUNTY_POINTS/SOULSEALS → `u32`; **all others → `u64`** | Y |
| 0xEF | 239 | GameServerWorldTime | `parseWorldTime` | `u8 hour`, `u8 minute` | Y |
| 0xF0 | 240 | GameServerQuestLog | `parseQuestLog` | `u16 n`, n×(`u16 id`,`STR name`,`u8 completed`) | Y |
| 0xF1 | 241 | GameServerQuestLine | `parseQuestLine` | `u16 questId`, `u8 n`, n×(`u16 missionId`,`STR name`,`STR desc`) | Y |
| 0xF2 | 242 | GameServerCoinBalanceUpdating | `parseCoinBalanceUpdating` | `u8 action`; if 0 return; else `u8`,`u8`,`u32`,`u32`,`u32` | Y |
| 0xF3 | 243 | GameServerChannelEvent | `parseChannelEvent` | `u16 channelId`, `STR name`, `u8 eventType` | Y |
| 0xF4 | 244 | GameServerItemInfo | `parseItemInfo` | `u8 n`, n×(`u16 itemId`, `u8 countOrSubType`, `STR desc`) | Y |
| 0xF5 | 245 | GameServerPlayerInventory | `parsePlayerInventory` | `u16 n`, n×(`u16 itemId`, `u8 attribute`, `packedCount1500`) | Y |
| 0xF6 | 246 | GameServerMarketEnter | `parseMarketEnter` (>=1281) | market enter blob | Y |
| 0xF7 | 247 | GameServerMarketLeave | — | **not in switch** | N |
| 0xF8 | 248 | GameServerMarketDetail | `parseMarketDetail` | detail blob | Y |
| 0xF9 | 249 | GameServerMarketBrowse | `parseMarketBrowse` | browse blob | Y |
| 0xFA | 250 | GameServerModalDialog | `parseModalDialog` | §3.9 | Y |
| 0xFB | 251 | GameServerStore | `parseStore` | `u16 catCount`, per: `STR name`,`u8 state`,`u8 iconCount`,iconCount×`STR`,`STR parent`; then `u8`,`u8` (>=1332) | Y |
| 0xFC | 252 | GameServerStoreOffers | `parseStoreOffers` | large/unstable; **own try/catch skips the rest on failure** | Y |
| 0xFD | 253 | GameServerStoreTransactionHistory | `parseStoreTransactionHistory` | `u32 page`,`u32 pageCount`,`u8 n`,n×(`u32 txId`,`u32 time`,`u8 mode`,`u32 amount`,`u8 coinType`,`STR product`,`u8 details`) | Y |
| 0xFE | 254 | GameServerStoreCompletePurchase | `parseCompleteStorePurchase` | `u8`, `STR purchaseStatus` (>=1291) | Y |

### 3.1 `0x17` / login — `parseLogin` (protocolgameparse.cpp:744-792)
```
u32  playerId
u16  serverBeat
DOUBLE speedA, speedB, speedC     # GameNewSpeedLaw ON -> 3 x 5 = 15 bytes
# NO canReportBugs byte (GameDynamicBugReporter ON)
u8   canChangePvpFrame            # >=1054
u8   expertModeEnabled            # >=1058
STR  storeImagesUrl               # GameIngameStore ON
u16  coinsPacketSize
u8   exivaButtonEnabled           # >=1281
# NO tournament byte (GameTournamentPackets OFF)
```

### 3.2 `0x6E` `parseOpenContainer` (1612-1658)
```
u8 containerId ; Item container ; STR name ; u8 capacity ; u8 hasParent
u8 showSearchIcon                 # >=1281
u8 isUnlocked ; u8 hasPages ; u16 containerSize ; u16 firstIndex   # GameContainerPagination
u8 itemCount ; itemCount x Item
u8 category ; u8 categoriesSize ; categoriesSize x (u8 id, STR name)  # GameContainerFilter
# the >=1340 pair (u8 isMoveable, u8 isHolding) is NOT read at 1530
```

### 3.3 `0x83` `parseMagicEffect` — protocol >= 1203 loop (1937-2010)
```
Position(5)
loop: t = u8 ; t==0 -> end
  t 1 (DELTA) / 2 (DELAY)        -> u8
  t 4 / 5 (distance effect)      -> u16 shotId, i8 dx, i8 dy, u8 source
  t 3 (create effect)            -> u16 effectId, u8 source
  t 6 (sound main)               -> u8 source, u16 soundId
  t 7 (sound secondary)          -> u8 enum, u8 source, u16 soundId
  default                        -> nothing consumed  ### desync risk
```
(`u16` because GameEffectU16 ON; the trailing `u8 source` because GameEffectSource ON at >=1514.)

### 3.4 `0x8B` type 14 — `addCreatureIcon` (2358-2408)
```
u8 sizeIcons ; sizeIcons x ( u8 icon, u8 category, u16 count, u8 trailer )
```
**The 5th byte per entry is 1530-specific** (lines 2368-2370). The same helper runs inside
`getCreature`, so it also affects creature-appearance parsing.

### 3.5 `0xA0` `parsePlayerStats` — exact 1530 layout (2651-2740), **60 bytes**
```
u32 health ; u32 maxHealth
u32 freeCapacity                  # /100
#   NO totalCapacity   (clientVersion < 1281 only)
u64 experience
u16 level
u16 levelPercent                  # GameLevelPercentU16 (>=1520)  <-- u16, not u8
u16 baseXpGain                    # GameExperienceBonus, version > 1096
#   NO voucherAddend   (clientVersion < 1281 only)
u16 grindingAddend ; u16 storeBoostAddend ; u16 huntingBoostFactor
u32 mana ; u32 maxMana
#   NO magicLevel/base/percent  (clientVersion < 1281 only; lives in 0xA1)
u8  soul ; u16 stamina ; u16 baseSpeed ; u16 regeneration ; u16 offlineTrainingTime
u16 storeExpBoostTime ; u8 canBuyExpBoost                # >=1097
u32 manaShield ; u32 maxManaShield                       # >=1281 && GameDoubleHealth
```

### 3.6 `0xA1` `parsePlayerSkills` at 1530 (2742-2869)
```
u16 magicLevel ; u16 baseMagicLevel ; u16 loyalty ; u16 percentX100      # >=1281
7 x { u16 level ; u16 baseLevel ; u16 loyalty ; u16 percentX100 }        # Fist..Fishing
# GameAdditionalSkills OFF -> critical/leech block SKIPPED
u8 concoctions                                                           # GameConcotions
# GameForgeSkillStats OFF -> forge skill block + 2 x u32 capacity SKIPPED
# GameCharacterSkillStats ON (>=1410):
u32 capacity(/100) ; u32 baseCapacity(/100)
u16 flatDamageHealing ; u16 attackValue ; u8 attackElement
DOUBLE convertedDamage ; u8 convertedElement
DOUBLE lifeLeech ; DOUBLE manaLeech ; DOUBLE critChance ; DOUBLE critDamage ; DOUBLE onslaught
u16 defense ; u16 armor
u16 mantra                                                               # GameVocationMonk
DOUBLE mitigation ; DOUBLE dodge ; u16 damageReflection
u8 combatsCount ; combatsCount x ( u8 combatType, DOUBLE value )
DOUBLE momentum ; DOUBLE transcendence ; DOUBLE amplification
```

### 3.7 `0xAA` `parseTalk` (2939-2997)
```
u32 statementGuid                 # GameMessageStatements
STR speakerName
u8  suffix                        # only if statementGuid > 0 AND >=1281
u16 level                         # GameMessageLevel
u8  modeByte -> mode = translateMessageModeFromServer(modeByte)
  Potion,Say,Whisper,Yell,MonsterSay,MonsterYell,NpcTo,BarkLow,BarkLoud,
  Spell,NpcFromStartBlock                                  -> Position(5)
  Channel,ChannelManagement,ChannelHighlight,GamemasterChannel -> u16 channelId
  NpcFrom,PrivateTo,PrivateFrom,GamemasterBroadcast,
  GamemasterPrivateFrom,RVRAnswer,RVRContinue              -> (nothing)
  RVRChannel                                               -> u32
  anything else                                            -> THROWS
STR text
```

### 3.8 `0xB4` `parseTextMessage` (3084-3164)
```
u8 code -> mode
ChannelManagement / Guild / PartyManagement / Party -> u16 channelId, STR text
DamageDealed / DamageReceived / DamageOthers        -> Position(5), u32 v1, u8 c1, u32 v2, u8 c2, STR text
Heal / Mana / HealOthers                            -> Position(5), u32 value, u8 color, STR text
Exp / ExpOthers                                     -> Position(5), u64 value (>=1332), u8 color, STR text
MessageInvalid (unmapped code)                      -> THROWS
default                                             -> (nothing extra)
if text still empty -> STR text
```

### 3.9 `0xFA` `parseModalDialog` (3947-3984)
```
u32 windowId ; STR title ; STR message
u8 buttonCount ; buttonCount x ( STR text, u8 buttonId )
u8 choiceCount ; choiceCount x ( STR text, u8 choiceId )
u8 escapeButton ; u8 enterButton      # version > 970 -> ESCAPE FIRST
u8 priority
```

---

## 4. Message-mode map (protocolcodes.cpp:29-90, 227-242)

`buildMessageModesMap(1530)` takes the `version >= 1055` branch. Client enum → **wire byte**:

| Otc enum (const.h:300) | enum val | wire byte |
|---|---|---|
| MessageNone | 0 | 0 |
| MessageSay | 1 | 1 |
| MessageWhisper | 2 | 2 |
| MessageYell | 3 | 3 |
| MessagePrivateFrom | 4 | 4 |
| MessagePrivateTo | 5 | 5 |
| MessageChannelManagement | 6 | 6 |
| MessageChannel | 7 | 7 |
| MessageChannelHighlight | 8 | 8 |
| MessageSpell | 9 | 9 |
| MessageNpcFrom | 10 | 11 |
| MessageNpcTo | 11 | 12 |
| MessageGamemasterBroadcast | 12 | 13 |
| MessageGamemasterChannel | 13 | 14 |
| MessageGamemasterPrivateFrom | 14 | 15 |
| MessageGamemasterPrivateTo | 15 | 16 |
| MessageLogin | 16 | 17 |
| MessageWarning | 17 | 18 |
| MessageGame | 18 | 19 |
| MessageFailure | 19 | 21 |
| MessageLook | 20 | 22 |
| MessageDamageDealed | 21 | 23 |
| MessageDamageReceived | 22 | 24 |
| MessageHeal | 23 | 25 |
| MessageExp | 24 | 26 |
| MessageDamageOthers | 25 | 27 |
| MessageHealOthers | 26 | 28 |
| MessageExpOthers | 27 | 29 |
| MessageStatus | 28 | 30 |
| MessageLoot | 29 | 31 |
| MessageTradeNpc | 30 | 32 |
| MessageGuild | 31 | 33 |
| MessagePartyManagement | 32 | 34 |
| MessageParty | 33 | 35 |
| MessageBarkLow | 34 | 36 |
| MessageBarkLoud | 35 | 37 |
| MessageReport | 36 | 38 |
| MessageHotkeyUse | 37 | 39 |
| MessageTutorialHint | 38 | 40 |
| MessageThankyou | 39 | 41 |
| MessageMarket | 40 | 42 |
| MessageMana | 41 | 43 |
| MessageBeyondLast | 42 | 44 |
| MessageGameHighlight | 50 | 20 |
| MessageNpcFromStartBlock | 51 | 10 |
| MessageAttention | 52 | 48 |
| MessageBoostedCreature | 53 | 49 |
| MessageOfflineTrainning | 54 | 50 |
| MessageTransaction | 55 | 51 |
| MessagePotion | 56 | 52 |

Not in the 1530 map (⇒ `translateMessageModeToServer` returns 255 / an incoming unmapped byte
becomes `MessageInvalid` and `parseTalk` **throws**): MessageMonsterYell(43), MessageMonsterSay(44),
MessageRed(45), MessageBlue(46), MessageRVRChannel(47), MessageRVRAnswer(48), MessageRVRContinue(49).

---

## 5. CLIENT → SERVER opcode table (complete)

"—" in the send-fn column means the enum exists but **no code in this fork emits it**.

| Hex | Dec | Enum | send fn (protocolgamesend.cpp) | Payload at 1530 |
|---|---|---|---|---|
| 0x01 | 1 | ClientEnterAccount | — | unused |
| 0x0A | 10 | ClientPendingGame | `sendLoginPacket` :115 | §5.1 |
| 0x0F | 15 | ClientEnterGame | `sendEnterGame` :227 | *empty*; then a second message `0x32 0x0A STR hwid` (gunz OS, :242-248) |
| 0x14 | 20 | ClientLeaveGame | `sendLogout` :251 | *empty* |
| 0x1C | 28 | ClientPingBackGunz | `sendPingBack` :269 | *empty* — **the pong at 1530** (gunz OS && version>=1200) |
| 0x1D | 29 | ClientPing | `sendPing` :258 | *empty* (GameExtendedClientPing OFF ⇒ raw opcode) |
| 0x1E | 30 | ClientPingBack | `sendPingBack` (non-gunz) | *empty* |
| 0x28 | 40 | ClientUseStash | `sendStashWithdraw` :1804 / `sendStashStow` :1815 | withdraw: `u8 WITHDRAW`,`u16 itemId`,`u32 count`,`u8 stackpos`. stow: `u8 action`,`Position(5)`,`u16 itemId`,`u8 stackpos`,[`u32 count` iff STOW_ITEM] |
| 0x2A | 42 | ClientBestiaryTrackerStatus | `sendStatusTrackerBestiary` :1427 | `u16 raceId`, `u8 status` |
| 0x2B | 43 | ClientPartyAnalyzerAction | `sendPartyAnalyzerAction` :892 | `u8 action`; if 3: `u16 n`, n×(`u16 itemId`,`u64 price`) |
| 0x32 | 50 | ClientExtendedOpcode | `sendExtendedOpcode` :102 | `u8 subOpcode`, `STR buffer`. Refuses to send until server sent extended-op 0 |
| 0x33 | 51 | ClientChangeMapAwareRange | `sendChangeMapAwareRange` :1559 | `u8 x`,`u8 y` — **no-op at 1530** (feature OFF, early return) |
| 0x38 | 56 | ClientCreatureTyping | `sendTyping` :994 | `u8 typing` |
| 0x5F | 95 | ClientTaskBoardAction | `sendTaskBoardAction` :1846 | `u8 option` + per-option u8/u8 or u16/u16 |
| 0x60 | 96 | ClientImbuementDurations | `sendImbuementDurations` :1887 | `u8 isOpen` |
| 0x61 | 97 | ClientOpenWheel | `sendOpenWheel` :1968 | `u32 playerId` |
| 0x62 | 98 | ClientSaveWheel | `sendApplyWheelPoints` :1975 | 36×`u16`, 4×(`u8 hasGem`[+`u16 gemId`]), `u8 0` |
| 0x64 | 100 | ClientAutoWalk | `sendAutoWalk` :290 | `u8 stepCount`, stepCount×`u8 dirByte` — **E=1, NE=2, N=3, NW=4, W=5, SW=6, S=7, SE=8** |
| 0x65 | 101 | ClientWalkNorth | `sendWalkNorth` :331 | *empty* |
| 0x66 | 102 | ClientWalkEast | `sendWalkEast` :338 | *empty* |
| 0x67 | 103 | ClientWalkSouth | `sendWalkSouth` :345 | *empty* |
| 0x68 | 104 | ClientWalkWest | `sendWalkWest` :352 | *empty* |
| 0x69 | 105 | ClientStop | `sendStop` :359 | *empty* |
| 0x6A | 106 | ClientWalkNorthEast | `sendWalkNorthEast` :366 | *empty* |
| 0x6B | 107 | ClientWalkSouthEast | `sendWalkSouthEast` :373 | *empty* |
| 0x6C | 108 | ClientWalkSouthWest | `sendWalkSouthWest` :380 | *empty* |
| 0x6D | 109 | ClientWalkNorthWest | `sendWalkNorthWest` :387 | *empty* |
| 0x6E | 110 | ClientTutorialChangeVocation | `sendTutorialChangeVocation` :442 | `u8 vocationClientId` |
| 0x6F | 111 | ClientTurnNorth | `sendTurnNorth` :394 | *empty* |
| 0x70 | 112 | ClientTurnEast | `sendTurnEast` :401 | *empty* |
| 0x71 | 113 | ClientTurnSouth | `sendTurnSouth` :408 | *empty* |
| 0x72 | 114 | ClientTurnWest | `sendTurnWest` :415 | *empty* |
| 0x73 | 115 | ClientGmTeleport | `sendGmTeleport` :422 | `Position(5)` |
| 0x74 | 116 | ClientStartOfflineTraining | `sendStartOfflineTraining` :430 | `u8 skillType` (dropped if > Fishing) |
| 0x77 | 119 | ClientEquipItem | `sendEquipItemWithTier` :450 / `sendEquipItemWithCountOrSubType` :459 | tier: `u16 itemId`,`u8 tier`. count: `u16 itemId`,**`u8 count`** (GameCountU16 OFF) |
| 0x78 | 120 | ClientMove | `sendMove` :472 | `Position from(5)`,`u16 thingId`,`u8 stackpos`,`Position to(5)`,**`u8 count`** |
| 0x79 | 121 | ClientInspectNpcTrade | `sendInspectNpcTrade` :487 | `u16 itemId`, **`u8 count`** |
| 0x7A | 122 | ClientBuyItem | `sendBuyItem` :499 | `u16 itemId`,`u8 subType`,**`u16 amount`**,`u8 ignoreCapacity`,`u8 buyWithBackpack` |
| 0x7B | 123 | ClientSellItem | `sendSellItem` :514 | `u16 itemId`,`u8 subType`,**`u16 amount`**,`u8 ignoreEquipped` |
| 0x7C | 124 | ClientCloseNpcTrade | `sendCloseNpcTrade` :528 | *empty* |
| 0x7D | 125 | ClientRequestTrade | `sendRequestTrade` :535 | `Position(5)`,`u16 thingId`,`u8 stackpos`,`u32 creatureId` |
| 0x7E | 126 | ClientInspectTrade | `sendInspectTrade` :546 | `u8 counterOffer`, `u8 index` |
| 0x7F | 127 | ClientAcceptTrade | `sendAcceptTrade` :555 | *empty* |
| 0x80 | 128 | ClientRejectTrade | `sendRejectTrade` :562 | *empty* |
| 0x82 | 130 | ClientUseItem | `sendUseItem` :569 | `Position(5)`,`u16 itemId`,`u8 stackpos`,`u8 index` |
| 0x83 | 131 | ClientUseItemWith | `sendUseItemWith` :580 | `Position from(5)`,`u16 itemId`,`u8 fromStackPos`,`Position to(5)`,`u16 toThingId`,`u8 toStackPos` |
| 0x84 | 132 | ClientUseOnCreature | `sendUseOnCreature` :593 | `Position(5)`,`u16 thingId`,`u8 stackpos`,`u32 creatureId` |
| 0x85 | 133 | ClientRotateItem | `sendRotateItem` :604 | `Position(5)`,`u16 thingId`,`u8 stackpos` |
| 0x86 | 134 | ClientConfigureShowOffSocket | — | never sent |
| 0x87 | 135 | ClientCloseContainer | `sendCloseContainer` :624 | `u8 containerId` |
| 0x88 | 136 | ClientUpContainer | `sendUpContainer` :632 | `u8 containerId` |
| 0x89 | 137 | ClientEditText | `sendEditText` :640 | `u32 windowId`, `STR text` |
| 0x8A | 138 | ClientEditList | `sendEditList` :649 | `u8 doorId`, `u32 windowId`, `STR text` |
| 0x8B | 139 | ClientOnWrapItem | `sendOnWrapItem` :614 | `Position(5)`,`u16 thingId`,`u8 stackpos` |
| 0x8C | 140 | ClientLook | `sendLook` :659 | `Position(5)`,`u16 itemId`,`u8 stackpos` |
| 0x8D | 141 | ClientLookCreature | `sendLookCreature` :669 | `u32 creatureId` |
| 0x8F | 143 | ClientSendQuickLoot | `sendQuickLoot` :1895 | `u8 variant` (>=1332), `Position(5)`, if `variant != 2`: `u16 itemId`,`u8 stackpos` |
| 0x90 | 144 | ClientLootContainer | `openContainerQuickLoot` :1923 | `u8 action`; 0/4→`u8 category`,`Position(5)`,`u16 itemId`,`u8 stackpos`; 3→`u8 useMainAsFallback`; 1/2/5/6→`u8 category` |
| 0x91 | 145 | ClientQuickLootBlackWhitelist | `requestQuickLootBlackWhiteList` :1910 | `u8 filter`,`u16 size`,size×`u16 itemId` |
| 0x96 | 150 | ClientTalk | `sendTalk` :677 | §5.2 |
| 0x97 | 151 | ClientRequestChannels | `sendRequestChannels` :739 | *empty* |
| 0x98 | 152 | ClientJoinChannel | `sendJoinChannel` :746 | `u16 channelId` |
| 0x99 | 153 | ClientLeaveChannel | `sendLeaveChannel` :754 | `u16 channelId` |
| 0x9A | 154 | ClientOpenPrivateChannel | `sendOpenPrivateChannel` :762 | `STR receiver` |
| 0x9B | 155 | ClientOpenRuleViolation | `sendOpenRuleViolation` :770 | `STR reporter` |
| 0x9C | 156 | ClientCloseRuleViolation | `sendCloseRuleViolation` :778 | `STR reporter` |
| 0x9D | 157 | ClientCancelRuleViolation | `sendCancelRuleViolation` :786 | *empty* |
| 0x9E | 158 | ClientCloseNpcChannel | `sendCloseNpcChannel` :793 | *empty* |
| 0x9F | 159 | ClientSetMonsterPodium | — | never sent |
| 0xA0 | 160 | ClientChangeFightModes | `sendChangeFightModes` :800 | **`u8 chaseMode`,`u8 safeFight`,`u8 pvpMode` — fightMode byte OMITTED** |
| 0xA1 | 161 | ClientAttack | `sendAttack` :823 | `u32 creatureId`, `u32 seq` |
| 0xA2 | 162 | ClientFollow | `sendFollow` :833 | `u32 creatureId`, `u32 seq` |
| 0xA3 | 163 | ClientInviteToParty | `sendInviteToParty` :843 | `u32 creatureId` |
| 0xA4 | 164 | ClientJoinParty | `sendJoinParty` :851 | `u32 creatureId` |
| 0xA5 | 165 | ClientRevokeInvitation | `sendRevokeInvitation` :859 | `u32 creatureId` |
| 0xA6 | 166 | ClientPassLeadership | `sendPassLeadership` :867 | `u32 creatureId` |
| 0xA7 | 167 | ClientLeaveParty | `sendLeaveParty` :875 | *empty* |
| 0xA8 | 168 | ClientShareExperience | `sendShareExperience` :882 | `u8 active` |
| 0xA9 | 169 | ClientDisbandParty | — | unused |
| 0xAA | 170 | ClientOpenOwnChannel | `sendOpenOwnChannel` :910 | *empty* |
| 0xAB | 171 | ClientInviteToOwnChannel | `sendInviteToOwnChannel` :917 | `STR name` |
| 0xAC | 172 | ClientExcludeFromOwnChannel | `sendExcludeFromOwnChannel` :925 | `STR name` |
| 0xAD | 173 | ClientCyclopediaHouseAuction | `sendCyclopediaHouseAuction` :1363 | `u8 type` + per-type fields |
| 0xAE | 174 | ClientBosstiaryRequestInfo | `sendRequestBosstiaryInfo` :1404 | *empty* |
| 0xAF | 175 | ClientBosstiaryRequestSlotInfo | `sendRequestBossSlootInfo` :1411 | *empty* |
| 0xB0 | 176 | ClientBosstiaryRequestSlotAction | `sendRequestBossSlotAction` :1418 | `u8 action`, `u32 raceId` |
| 0xB1 | 177 | ClientRequestHighscore | `sendHighscoreInfo` :1831 | `u8 action`,`u8 category`,`u32 vocation`,`STR world`,`u8 worldType`,`u8 battlEye`,`u16 page`,`u8 totalPages` |
| 0xB2 | 178 | ClientImbuementWindowAction | `sendImbuementWindowAction` :1762 | `u8 type`; if SELECT_ITEM: `Position(5)`,`u16 itemId`,`u8 stackpos` |
| 0xB3 | 179 | ClientWeaponProficiency | `sendWeaponProficiencyAction` :1942 / `sendWeaponProficiencyApply` :1953 | action: `u8 actionType`[+`u16 itemId`]. apply: `u8 APPLY_PERKS`,`u16 itemId`,`u8 n`,n×(`u8 level`,`u8 perkPos`) |
| 0xBA | 186 | ClientSoulSealsAction | `sendSoulSealsAction` :933 | `u16 raceId` (dropped if 0) |
| 0xBE | 190 | ClientCancelAttackAndFollow | `sendCancelAttackAndFollow` :945 | *empty* |
| 0xBF | 191 | ClientForgeEnter | `sendForgeRequest` :1670 | `u8 actionType`; FUSION/TRANSFER: `u8 convergence`,`u16 id1`,`u8 tier1`,`u16 id2`,`u8 improveChance`,`u8 tierLoss` |
| 0xC0 | 192 | ClientForgeBrowseHistory | `sendForgeBrowseHistoryRequest` :1687 | `u8 page` |
| 0xC9 | 201 | ClientUpdateTile | — | unused |
| 0xCA | 202 | ClientRefreshContainer **/ ClientExivaRestrictions** | `sendRefreshContainer` :952 / `sendExivaRestrictions` :1694 | refresh: `u8 containerId`. exiva: 6×`u8` flags + 4×(`u16 n`, n×`STR`) — **same opcode** |
| 0xCB | 203 | ClientBrowseField | `sendBrowseField` :1247 | `Position(5)` |
| 0xCC | 204 | ClientSeekInContainer | `sendSeekInContainer` :1258 | `u8 containerId`,`u16 index`,`u8 filter=0` |
| 0xCD | 205 | ClientInspectionObject | `sendInspectionNormalObject` :1273 / `sendInspectionObject` :1282 | normal: `u8 INSPECT_NORMALOBJECT`,`Position(5)`. typed: `u8 type`,`u16 itemId`,`u8 itemCount` |
| 0xCE | 206 | ClientInspectionCharacter | `sendInspectCharacter` :1305 | **`u8 tab`, `u32 creatureId`** (tab FIRST) |
| 0xCF | 207 | ClientRequestBless | `sendRequestBless` :960 | *empty* |
| 0xD0 | 208 | ClientRequestTrackerQuestLog | `sendRequestTrackerQuestLog` :967 | `u8 n`,n×`u16 missionId`, then (>=1410) `u8 autoTrackNew`,`u8 autoUntrackDone`,`u8 extra` |
| 0xD2 | 210 | ClientRequestOutfit | `sendRequestOutfit` :987 | *empty* |
| 0xD3 | 211 | ClientChangeOutfit | `sendChangeOutfit` :1002 | §5.3 |
| 0xD4 | 212 | ClientMount | `sendMountStatus` :1055 | `u8 mount` |
| 0xD5 | 213 | ClientApplyImbuement | `sendApplyImbuement` :1735 | `u8 slot`,`u32 imbuementId` (protectionCharm byte is <1510 only ⇒ **omitted**) |
| 0xD6 | 214 | ClientClearImbuement | `sendClearImbuement` :1747 | `u8 slot` |
| 0xD7 | 215 | ClientCloseImbuingWindow | `sendCloseImbuingWindow` :1755 | *empty* |
| 0xD8 | 216 | ClientOpenRewardWall | `sendOpenRewardWall` :1777 | *empty* |
| 0xD9 | 217 | ClientOpenRewardHistory | `sendOpenRewardHistory` :1784 | *empty* |
| 0xDA | 218 | ClientGetRewardDaily | `sendGetRewardDaily` :1791 | `u8 bonusShrine`,`u8 n`,n×(`u16 itemId`,`u8 count`) |
| 0xDC | 220 | ClientAddVip | `sendAddVip` :1067 | `STR name` |
| 0xDD | 221 | ClientRemoveVip | `sendRemoveVip` :1075 | `u32 playerId` |
| 0xDE | 222 | ClientEditVip | `sendEditVip` :1083 | `u32 playerId`,`STR desc`,`u32 iconId`,`u8 notifyLogin`,`u8 groupCount`,groupCount×`u8` |
| 0xDF | 223 | ClientEditVipGroups | `sendEditVipGroups` :1100 | `u8 action`; ADD→`STR`; EDIT→`u8 id`,`STR`; REMOVE→`u8 id` |
| 0xE1 | 225 | ClientBestiaryRequest | `sendRequestBestiary` :1298 | *empty* |
| 0xE2 | 226 | ClientBestiaryRequestOverview | `sendRequestBestiaryOverview` :1314 | `u8 isSearch`; if 1: `u16 n`,n×`u16 raceId`; else `STR categoryName` |
| 0xE3 | 227 | ClientBestiaryRequestSearch | `sendRequestBestiarySearch` :1330 | `u16 raceId` |
| 0xE4 | 228 | ClientCyclopediaSendBuyCharmRune | `sendBuyCharmRune` :1338 | `u8 runeId`,`u8 action`,`u16 raceId` |
| 0xE5 | 229 | ClientCyclopediaRequestCharacterInfo | `sendCyclopediaRequestCharacterInfo` :1348 | `u32 playerId`,`u8 infoType`,[`u16 entriesPerPage`,`u16 page`] |
| 0xE6 | 230 | ClientBugReport | `sendBugReport` :1126 | `u8 category=3`, `STR comment` |
| 0xE7 | 231 | ClientWheelGemAction | `sendWheelGemAction` :1151 / `sendRuleViolation` :1137 | gem: `u8 actionType`, `u16 param` for 0/2/3 else `u8 param`, `u8 pos` if action==4 |
| 0xE8 | 232 | ClientDebugReport | `sendDebugReport` :1179 | **SUPPRESSED on gunz OS** — 232 is the store offer-description opcode there |
| 0xEB | 235 | ClientPreyAction | `sendPreyAction` :1643 | `u8 slot`,`u8 actionType`; 2/5→`u8 index`; 4→`u16 raceId` |
| 0xED | 237 | ClientPreyRequest | `sendPreyRequest` :1657 / `sendOpenPortableForge` :1664 | *empty* (both write this opcode) |
| 0xEE | 238 | ClientNpcGreet | — | never sent |
| 0xEF | 239 | ClientTransferCoins | `sendTransferCoins` :1541 | `STR recipient`, `u32 amount` |
| 0xF0 | 240 | ClientRequestQuestLog | `sendRequestQuestLog` :1200 | *empty* |
| 0xF1 | 241 | ClientRequestQuestLine | `sendRequestQuestLine` :1207 | `u16 questId` |
| 0xF2 | 242 | ClientNewRuleViolation | `sendNewNewRuleViolation` :1215 | `u8 reason`,`u8 action`,`STR name`,`STR comment`,`STR translation` |
| 0xF3 | 243 | ClientRequestItemInfo | `sendRequestItemInfo` :1227 | **`u8 subType`, `u16 itemId`, `u8 index`** (subType FIRST) |
| 0xF4 | 244 | ClientMarketLeave | `sendMarketLeave` :1578 | *empty* |
| 0xF5 | 245 | ClientMarketBrowse | `sendMarketBrowse` :1585 | `u8 browseId`; if `browseType>0`: `u16 browseType` [+`u8 tier` iff browseId==3 && classification>0] |
| 0xF6 | 246 | ClientMarketCreate | `sendMarketCreateOffer` :1607 | `u8 type`,`u16 itemId`,[`u8 tier`],`u16 amount`,`u64 price`,`u8 anonymous` |
| 0xF7 | 247 | ClientMarketCancel | `sendMarketCancelOffer` :1624 | `u32 timestamp`,`u16 counter` |
| 0xF8 | 248 | ClientMarketAccept | `sendMarketAcceptOffer` :1633 | `u32 timestamp`,`u16 counter`,`u16 amount` |
| 0xF9 | 249 | ClientAnswerModalDialog | `sendAnswerModalDialog` :1237 | **`u32 windowId`, `u8 buttonId`, `u8 choiceId`** |
| 0xFA | 250 | ClientOpenStore | `sendOpenStore` :1528 | `u8 serviceType`, `STR category` |
| 0xFB | 251 | ClientRequestStoreOffers | `sendRequestStoreOffers` :1469 + 5 siblings | `u8 storeAction` + per-action fields |
| 0xFC | 252 | ClientBuyStoreOffer | `sendBuyStoreOffer` :1436 | `u32 offerId`,`u8 action`; if 0<action<6: `STR name`; if 3\|5: `u8 type`; if 5: `STR location` |
| 0xFD | 253 | ClientOpenTransactionHistory | `sendOpenTransactionHistory` :1550 | `u8 entriesPerPage` |
| 0xFE | 254 | ClientRequestTransactionHistory | `sendRequestTransactionHistory` :1454 | `u32 page`, `u8 entriesPerPage` |
| 0xFF | 255 | ClientRewardChestCollect | — | never sent |

### 5.1 `0x0A` login packet (`sendLoginPacket`, protocolgamesend.cpp:115-225)
```
u8   0x0A
u16  os               = 61
u16  protocolVersion  = 1530
u32  clientVersion    = 1530          # GameClientVersion ON
STR  "1530"                           # >=1281
STR  decimal(contentRevision)         # >=1334; gunz parses assets.json.sha256
u8   0                                # GamePreviewState ON
--- RSA block start (offset recorded) ---
u8   0                                # first RSA byte must be 0
u32  xteaKey[0..3]                    # 16 bytes
u8   0                                # "is gm"
STR  sessionKey                       # GameSessionKey ON
STR  characterName
u32  challengeTimestamp               # GameChallengeOnLogin ON
u8   challengeRandom
u16  2                                # GUNZ-ONLY literal (OS 60..62)
STR  loginExtendedData                # gunz && >=1281 -> literal "261" when Lua supplies nothing
zero-pad up to g_crypt.rsaGetSize()
--- RSA-encrypt the block ---
enableChecksum()          # GameProtocolChecksum ON
send
enableXteaEncryption()    # GameLoginPacketEncryption ON
enabledSequencedPackets() # GameSequencedPackets ON (>=1290)
```

### 5.2 `0x96` `sendTalk` (677-737) — 1530 form
```
u8  0x96
u8  wireModeByte = translateMessageModeToServer(mode)     # §4 table
if mode in {PrivateTo, GamemasterPrivateTo, RVRAnswer}:  STR receiver
if mode in {Channel, ChannelHighlight, ChannelManagement, GamemasterChannel}: u16 channelId
STR message                                # dropped if empty or len > 255
# GUNZ + clientVersion >= 1525 -- ALWAYS APPENDED (default aimMode = 0)
u8  aimMode        # must be <= 3;  0 none, 1 crosshair, 2 cursor, 3 current target
if aimMode == 1 or aimMode == 2: Position(5)   # must be a valid position
```

### 5.3 `0xD3` `sendChangeOutfit` (1002-1053) — 1530 form
```
u8  0xD3
u8  0x00                    # >=1281 "normal outfit window"
u16 lookType                # GameLooktypeU16
u8  head; u8 body; u8 legs; u8 feet
u8  addons                  # GamePlayerAddons
u16 mount                   # GamePlayerMounts
u8 0; u8 0; u8 0; u8 0      # >=1281 mount colours
u8  hasMount                # >=1334
u16 familiar                # GamePlayerFamiliars
u8  0                       # >=1281 randomizeMount
# GameWingsAurasEffectsShader OFF -> no wing/aura/effect/shader fields
```

---

## 6. MINIMUM PARSE SET for a headless bot worker

Because the C++ `default` branch **discards the remainder of the message** and several parsers
`throw` (abandoning it entirely), a Lua reimplementation cannot cherry-pick. Partitioned by *why*
you must parse, not by whether you want the data.

### 6.1 Tier A — state you actually need
- **Login/session**: `0x0A`, `0x0F`, `0x14`, `0x16`, `0x17`, `0x18`, `0x1F`, `0x11`, `0x15`.
- **Map/position**: `0x64`, `0x65`, `0x66`, `0x67`, `0x68`, `0x4B`, `0xBE`, `0xBF`, `0x69`,
  `0x6A`, `0x6B`, `0x6C`, `0x6D`, and **`0x33`** (changes the geometry of every later map packet).
- **Creatures**: `0x8B`, `0x8C`, `0x8D`, `0x8E`, `0x8F`, `0x90`, `0x91`, `0x92`, `0x93`, `0x95`,
  `0x94`, `0x38`, `0x34`, `0x35`, `0x36`.
- **Local player**: `0x9F`, `0xA0`, `0xA1`, `0xA2`, `0xA7`, `0x9C`, `0xEE`, `0xC1`.
- **Inventory/containers**: `0x78`, `0x79`, `0x6E`, `0x6F`, `0x70`, `0x71`, `0x72`, `0xF5`,
  `0x29`, `0x2A`, `0xC0`.
- **Combat/movement**: `0xB5` (walk-cancel direction is how you resync after a rejected step),
  `0xB6`, `0xA3`, `0xA4`, `0xA5`, `0xA6`, `0x28`.
- **Chat**: `0xAA`, `0xB4`, `0xAB`, `0xAC`, `0xAD`, `0xB2`, `0xB3`, `0xF3`.
- **Keepalive**: `0x1D` (server ping → send `0x1C` pong), `0x1E` (pong to our own ping).
- **Interaction**: `0xFA` (+ answer `0xF9`), `0x96`, `0x97`, `0x7A`, `0x7B`, `0x7C`, `0x7D`,
  `0x7E`, `0x7F`, `0xD2`, `0xD3`, `0xD4`.
- **Feature negotiation**: `0x43` — highest priority; it rewrites the conditionals for everything.

### 6.2 Tier B — no useful state, but MUST be consumed byte-exactly
`0x0B`, `0x19`, `0x1A`, `0x1B`, `0x1C`, `0x2B`, `0x32`, `0x37`, `0x3C`, `0x3D`, `0x5B`, `0x5C`,
`0x5D`, `0x5E`, `0x5F`, `0x61`, `0x62`, `0x63`, `0x73`, `0x75`, `0x76`, `0x77`, `0x82`, `0x83`,
`0x84`, `0x85`, `0x86`, `0x87`, `0x88`, `0x89`, `0x8A`, `0x98`, `0x9A`, `0x9B`, `0x9D`, `0x9E`,
`0xA8`, `0xA9`, `0xAE`, `0xAF`, `0xB0`, `0xB1`, `0xB7`, `0xB8`, `0xB9`, `0xBA`, `0xBB`, `0xBD`,
`0xC2`, `0xC3`, `0xC4`, `0xC6`, `0xC7`, `0xC8`, `0xCA`, `0xCC`, `0xCD`, `0xCE`, `0xCF`, `0xD0`,
`0xD1`, `0xD5`, `0xD6`, `0xD7`, `0xD8`, `0xD9`, `0xDA`, `0xDC`, `0xDD`, `0xDE`, `0xDF`, `0xE0`,
`0xE1`, `0xE2`, `0xE4`, `0xE5`, `0xE6`, `0xE7`, `0xE8`, `0xE9`, `0xEA`, `0xEB`, `0xEC`, `0xED`,
`0xEF`, `0xF0`, `0xF1`, `0xF2`, `0xF4`, `0xF6`, `0xF8`, `0xF9`, `0xFB`, `0xFC`, `0xFD`, `0xFE`.

Highest-risk members (variable length, arrive unsolicited): `0x83`, `0xB9`, `0xBA`, `0xBB`, `0xC4`,
`0xCD`, `0xD0`, `0xD1`, `0xFB`, `0xFC`, `0xC2`, plus the two that throw on bad input: `0x5B`, `0xDD`.

### 6.3 Tier C — no case at all; if the server sends one, that message is lost
`0x03`, `0x04`, `0x2C`, `0x2D`, `0x60`, `0x74`, `0x80`, `0x81`, `0x99`, `0xBC`, `0xC5`, `0xC9`,
`0xCB`, `0xDB`, `0xE3`, `0xF7`. Log opcode + hex preview, drop the rest of the message, continue
with the next network frame — exactly what the C++ default case does.

### 6.4 Minimum SEND set for a bot
`0x0A`, `0x0F` (+ gunz hwid extended frame), `0x1C` pong, `0x1D` ping, `0x14` logout,
`0x65`-`0x6D` walk/stop, `0x6F`-`0x72` turn, `0x64` autowalk, `0x78` move,
`0x82`/`0x83`/`0x84` use/useWith/useOnCreature, `0x8C`/`0x8D` look, `0xA1` attack, `0xA2` follow,
`0xBE` cancel attack+follow, `0x96` talk (**with the trailing aim byte**),
`0xA0` fight modes (**3 bytes, no fightMode**), `0x87`/`0x88` container close/up,
`0xCC` seek-in-container, `0x77` equip, `0x7A`/`0x7B`/`0x7C` buy/sell/close,
`0xF9` answer modal dialog, `0x97`/`0x98`/`0x99` channels, `0xD2`/`0xD3` outfit.


## Pseudocode

-- ============================================================================
-- 1530 opcode dispatch skeleton (LuaJIT, standalone, no otclient).
-- Assumes a reader with: m:u8() m:u16() m:u32() m:u64() m:i64() m:str() m:pos()
--   m:dbl() m:bytes(n) m:skip(n) m:eof() m:unread()
-- and an F[] feature table (1530 defaults, mutated by opcode 0x43).
-- ============================================================================

local F = {}
local function feat(id) return F[id] == true end

local function init_features_1530()
  F = {}
  local on = {22,122,125, 79,78, 42,45,63, 44,43,47,46,48,49, 51,
              1,2,6, 3,61,124, 14, 32, 4, 7,12,23, 5,8,9,10,11,
              17,21,24, 18,20, 52, 98, 62,64, 35,36, 40,58, 41,50,
              29,53, 54,55, 57, 59, 68, 66, 70, 71, 60, 65, 67, 69,
              73,75,74, 82, 121,83,96,114, 84,85,86,
              123, 90,97,88,87,89,39, 28,91,94,95, 93,
              105,106,107,108,110,111, 112,113, 119,
              127, 130, 135, 133, 132, 131,134, 136}
  for _,id in ipairs(on) do F[id] = true end
  -- explicit disables, applied in version order:
  F[13]=nil; F[15]=nil        -- >=1281 EnvironmentEffect / ItemAnimationPhase
  F[92]=nil                   -- >=1314 TournamentPackets
  F[109]=nil                  -- >=1320 LeechAmount
  F[76]=nil; F[126]=nil       -- >=1410 AdditionalSkills / ForgeSkillStats
end

-- ---------------------------------------------------------------------------
-- Primitives that are easy to get wrong
-- ---------------------------------------------------------------------------
function Msg:dbl()                        -- 5 bytes, NOT IEEE754
  local precision = self:u8()
  local raw       = self:u32()
  return (raw - 2147483647) / (10 ^ precision)
end
function Msg:pos() return {x=self:u16(), y=self:u16(), z=self:u8()} end
function Msg:str() local n = self:u16(); return self:bytes(n) end

local function packedCount1500(m)         -- opcode 0xF5 only, protocol >= 1500
  local b1 = m:u8()
  if b1 < 0x40 then return b1 end
  if b1 < 0x80 then return ((b1 - 0x40) * 256) + m:u8() end
  local b2,b3,b4 = m:u8(), m:u8(), m:u8()
  return b2*65536 + b3*256 + b4
end

-- ---------------------------------------------------------------------------
-- Main loop (mirrors ProtocolGame::parseMessage)
-- ---------------------------------------------------------------------------
local S = {}                              -- server opcode -> parser

function parse_message(m)
  local opcode, prev = -1, -1
  local ok, err = pcall(function()
    while not m:eof() do
      opcode = m:u8()
      local fn = S[opcode]
      if fn then
        fn(m)
      else
        log_warn(("unhandled opcode 0x%02X, %d unread, prev 0x%02X")
                 :format(opcode, m:unread(), prev))
        m:skip(m:unread())                -- exactly what the C++ default does
      end
      prev = opcode
    end
  end)
  if not ok then
    log_error(("parse failed at 0x%02X (prev 0x%02X): %s"):format(opcode, prev, err))
    -- never try to resync INSIDE a message; drop it and wait for the next frame
  end
end

-- ---------------------------------------------------------------------------
-- Parsers
-- ---------------------------------------------------------------------------

S[0x43] = function(m)                     -- GameServerFeatures: parse FIRST-CLASS
  for _ = 1, m:u16() do
    local id, enabled = m:u8(), m:u8()
    F[id] = (enabled ~= 0) or nil
  end
end

S[0x0A] = function(m) state.pending = true end
S[0x0F] = function(m) state.ingame  = true end

S[0x1F] = function(m)                     -- Challenge
  local ts, rnd = m:u32(), m:u8()
  m:skip(1)                               -- clientVersion >= 1405
  send_login_packet(ts, rnd)
end

S[0x17] = function(m)                     -- LoginSuccess
  state.playerId   = m:u32()
  state.serverBeat = m:u16()
  state.speedA, state.speedB, state.speedC = m:dbl(), m:dbl(), m:dbl()
  -- no canReportBugs byte (GameDynamicBugReporter ON)
  m:u8()                                  -- canChangePvpFrame  (>=1054)
  m:u8()                                  -- expertPvpMode      (>=1058)
  state.storeUrl        = m:str()
  state.coinsPacketSize = m:u16()
  state.canExiva        = m:u8() ~= 0     -- >=1281
  -- no tournament byte
end

S[0x1D] = function(m) send_ping_back() end          -- server ping -> we pong
S[0x1E] = function(m) state.pongSeen = state.pongSeen + 1 end
S[0x18] = function(m) state.sessionEnd = m:u8() end
S[0x14] = function(m)
  local err = m:str()
  if m:unread() > 0 then m:u8() end       -- >=1523 reason, only when present
  on_login_error(err)
end
S[0x16] = function(m) on_login_wait(m:str(), m:u8()) end
S[0x11] = function(m) on_update_needed(m:str()) end
S[0x15] = function(m) on_login_advice(m:str()) end
S[0x0B] = function(m) m:str() end                    -- >=1200 secondary conn id

S[0x28] = function(m)                     -- Death
  local deathType = m:u8()
  local penalty = 100
  if deathType == 0 then penalty = m:u8() end
  m:u8()                                  -- canUseDeathRedemption (>=1281)
  on_death(deathType, penalty)
end

S[0x82] = function(m) state.worldLight = {intensity=m:u8(), color=m:u8()} end

S[0x8C] = function(m) creature_set_hp(m:u32(), m:u8()) end
S[0x8D] = function(m) local id=m:u32(); creature_set_light(id, m:u8(), m:u8()) end
S[0x8F] = function(m)
  local id, base, spd = m:u32(), m:u16(), m:u16()   -- base only at >=1059
  creature_set_speed(id, spd, base)
end
S[0x90] = function(m) creature_set_skull (m:u32(), m:u8()) end
S[0x91] = function(m) creature_set_shield(m:u32(), m:u8()) end
S[0x92] = function(m) creature_set_pass  (m:u32(), m:u8() == 0) end
S[0x95] = function(m) creature_set_type  (m:u32(), m:u8()) end
S[0x93] = function(m) local id, t, c = m:u32(), m:u8(), m:u8()
                      creature_set_mark(id, t, c) end
S[0x94] = function(m) m:u32(); m:u16() end
S[0x38] = function(m) creature_set_typing(m:u32(), m:u8() ~= 0) end
S[0x34] = function(m) m:u32(); m:u16() end
S[0x35] = function(m) m:u32(); m:u16() end
S[0x36] = function(m) m:u32(); m:str() end
S[0x37] = function(m) m:str() end
S[0x3C] = function(m) m:u32(); read_paperdoll(m) end
S[0x3D] = function(m) m:u32(); m:u8(); m:u16() end

local function read_creature_icons(m)     -- 5 bytes per entry at 1530
  local n, out = m:u8(), {}
  for i = 1, n do
    local icon, cat, count = m:u8(), m:u8(), m:u16()
    m:u8()                                -- 1530-only trailer, discarded
    out[i] = {icon=icon, category=cat, count=count}
  end
  return out
end

S[0x8B] = function(m)                     -- CreatureData
  local id, t = m:u32(), m:u8()
  if     t == 0                        then read_creature(m)
  elseif t == 11 or t == 12 or t == 13 then creature_set_vocation(id, m:u8())
  elseif t == 14                       then creature_set_icons(id, read_creature_icons(m))
  end                                     -- any other t consumes nothing
end

S[0x8E] = function(m) creature_set_outfit(m:u32(), read_outfit(m, true)) end

S[0xA0] = function(m)                     -- PlayerData -- exactly 60 bytes at 1530
  local p = state.player
  p.health = m:u32();  p.maxHealth = m:u32()
  p.freeCap = m:u32() / 100
  p.experience = m:u64()
  p.level = m:u16();   p.levelPct = m:u16()        -- levelPct is u16 at >=1520
  p.xpBase = m:u16();  p.xpGrinding = m:u16()
  p.xpStore = m:u16(); p.xpHunting = m:u16()
  p.mana = m:u32();    p.maxMana = m:u32()
  p.soul = m:u8()
  p.stamina = m:u16(); p.baseSpeed = m:u16()
  p.regen = m:u16();   p.training = m:u16()
  p.xpBoostTime = m:u16(); m:u8()
  p.manaShield = m:u32(); p.maxManaShield = m:u32()
end

S[0xA1] = function(m)                     -- PlayerSkills
  local p = state.player
  p.magicLevel = m:u16(); p.baseMagicLevel = m:u16()
  m:u16(); p.magicPct = m:u16() / 100
  for s = 0, 6 do                         -- Fist..Fishing
    local lvl, base = m:u16(), m:u16()
    m:u16(); local pct = m:u16() / 100
    p.skills[s] = {level=lvl, base=base, pct=pct}
  end
  -- GameAdditionalSkills OFF -> no critical/leech block
  m:u8()                                  -- GameConcotions
  -- GameForgeSkillStats OFF -> no forge block, no 2 x u32 capacity
  p.capacity     = m:u32() / 100
  p.baseCapacity = m:u32() / 100
  p.flatBonus    = m:u16()
  p.attackValue  = m:u16(); p.attackElem = m:u8()
  p.convDamage   = m:dbl(); p.convElem   = m:u8()
  p.lifeLeech    = m:dbl(); p.manaLeech  = m:dbl()
  p.critChance   = m:dbl(); p.critDamage = m:dbl(); p.onslaught = m:dbl()
  p.defense      = m:u16(); p.armor = m:u16()
  p.mantra       = m:u16()                -- GameVocationMonk (>=1500)
  p.mitigation   = m:dbl(); p.dodge = m:dbl()
  p.reflection   = m:u16()
  p.absorb = {}
  for _ = 1, m:u8() do local ct = m:u8(); p.absorb[ct] = m:dbl() end
  p.momentum = m:dbl(); p.transcendence = m:dbl(); p.amplification = m:dbl()
end

S[0xA2] = function(m) state.player.states = m:u64(); m:u8() end   -- 9 bytes
S[0xA3] = function(m) local seq = m:u32(); m:u32(); on_attack_cancel(seq) end
S[0xA7] = function(m) state.chaseMode = m:u8()
                      state.safeMode  = m:u8() ~= 0
                      state.pvpMode   = m:u8() end
S[0xA4] = function(m) on_spell_cd(m:u16(), m:u32()) end
S[0xA5] = function(m) on_spell_group_cd(m:u8(), m:u32()) end
S[0xA6] = function(m) on_multiuse_cd(m:u32()) end
S[0x9F] = function(m)                     -- PlayerDataBasic
  state.player.premium = m:u8() ~= 0
  m:u32()                                 -- premium expiration
  state.player.vocation = m:u8()
  m:u8()                                  -- prey enabled
  local spells = {}
  for i = 1, m:u16() do spells[i] = m:u16() end   -- GameUshortSpell
  state.player.spells = spells
  m:u8()                                  -- magic shield active (>=1281)
end
S[0x9C] = function(m) state.blessings = m:u16(); state.blessVisual = m:u8() end
S[0xEE] = function(m)                     -- ResourceBalance
  local t = m:u8()
  local v
  if RESOURCE_IS_U32[t] then v = m:u32() else v = m:u64() end
  state.resources[t] = v
end
S[0xC1] = function(m)                     -- MonkData
  local sub = m:u8()
  if     sub == HARMONY then state.player.harmony = m:u8()
  elseif sub == SERENE  then state.player.serene  = m:u8() ~= 0
  elseif sub == VIRTUE  then for _ = 1, m:u8() do m:u16() end
  end
end

S[0xB5] = function(m) on_walk_cancel(m:u8()) end
S[0xB6] = function(m) state.walkLockUntil = now() + m:u16() end
S[0xB7] = function(m) state.unjustified =
            {m:u8(),m:u8(),m:u8(),m:u8(),m:u8(),m:u8(),m:u8()} end
S[0xB8] = function(m) state.openPvpSituations = m:u8() end
S[0xEF] = function(m) state.worldTime = {hour=m:u8(), min=m:u8()} end
S[0xDC] = function(m) on_tutorial_hint(m:u8()) end
S[0xED] = function(m) on_server_error(m:u8(), m:str()) end
S[0xE0] = function(m) on_store_error(m:u8(), m:str()) end
S[0x9D] = function(m) m:u32() end
S[0xD9] = function(m) m:u16() end
S[0xE6] = function(m) m:u32() end         -- BosstiaryEntryChanged, NOT prey rerolls
S[0xE7] = function(m) m:u8(); m:u16() end
S[0xAF] = function(m) m:i64(); m:i64() end -- ExperienceTracker (>=1200)
S[0xCE] = function(m) on_supply_tracker(m:u16()) end
S[0xCF] = function(m) local it = read_item(m); on_loot_stats(it, m:str()) end
S[0xCC] = function(m)
  local t, amount = m:u8(), m:u32()
  if t == 1 then m:u8()
  elseif t == 2 then m:u8(); m:str() end
end

S[0xAA] = function(m)                     -- Talk
  local statement = m:u32()
  local name      = m:str()
  if statement > 0 then m:u8() end        -- suffix, >=1281
  local level     = m:u16()
  local modeByte  = m:u8()
  local mode      = MODE_FROM_SERVER[modeByte]
  if mode == nil then error("unknown talk mode " .. modeByte) end
  local channelId, pos = 0, nil
  if     TALK_POS_MODES[mode]     then pos       = m:pos()
  elseif TALK_CHANNEL_MODES[mode] then channelId = m:u16()
  elseif mode == "RVRChannel"     then m:u32() end
  on_talk(name, level, mode, m:str(), channelId, pos)
end

S[0xB4] = function(m)                     -- TextMessage
  local code = m:u8()
  local mode = MODE_FROM_SERVER[code]
  if mode == nil then error("unknown text message mode " .. code) end
  local text
  if mode=="ChannelManagement" or mode=="Guild"
     or mode=="PartyManagement" or mode=="Party" then
    m:u16(); text = m:str()
  elseif mode=="DamageDealed" or mode=="DamageReceived" or mode=="DamageOthers" then
    m:pos(); m:u32(); m:u8(); m:u32(); m:u8(); text = m:str()
  elseif mode=="Heal" or mode=="Mana" or mode=="HealOthers" then
    m:pos(); m:u32(); m:u8(); text = m:str()
  elseif mode=="Exp" or mode=="ExpOthers" then
    m:pos(); m:u64(); m:u8(); text = m:str()   -- u64 at >=1332
  end
  if text == nil then text = m:str() end
  on_text_message(mode, text)
end

S[0xAB] = function(m)
  local list = {}
  for i = 1, m:u8() do list[i] = {id=m:u16(), name=m:str()} end
  on_channel_list(list)
end
local function read_channel_members(m)
  for _ = 1, m:u16() do m:str() end       -- joined
  for _ = 1, m:u16() do m:str() end       -- invited
end
S[0xAC] = function(m) local id,n = m:u16(), m:str(); read_channel_members(m)
                      on_open_channel(id, n) end
S[0xB2] = function(m) local id,n = m:u16(), m:str(); read_channel_members(m)
                      on_open_own_channel(id, n) end
S[0xAD] = function(m) on_open_private_channel(m:str()) end
S[0xB3] = function(m) on_close_channel(m:u16()) end
S[0xF3] = function(m) on_channel_event(m:u16(), m:str(), m:u8()) end

S[0xFA] = function(m)                     -- ModalDialog
  local id, title, message = m:u32(), m:str(), m:str()
  local buttons, choices = {}, {}
  for _ = 1, m:u8() do local t = m:str(); buttons[#buttons+1] = {id=m:u8(), text=t} end
  for _ = 1, m:u8() do local t = m:str(); choices[#choices+1] = {id=m:u8(), text=t} end
  local escapeBtn = m:u8()                -- version > 970 -> ESCAPE FIRST
  local enterBtn  = m:u8()
  local priority  = m:u8() ~= 0
  on_modal_dialog(id, title, message, buttons, enterBtn, escapeBtn, choices, priority)
end

S[0x78] = function(m) inventory_set(m:u8(), read_item(m)) end
S[0x79] = function(m) inventory_set(m:u8(), nil) end

S[0x6E] = function(m)                     -- OpenContainer
  local cid       = m:u8()
  local item      = read_item(m)
  local name      = m:str()
  local cap       = m:u8()
  local hasParent = m:u8() ~= 0
  m:u8()                                  -- showSearchIcon (>=1281)
  local unlocked  = m:u8() ~= 0
  local hasPages  = m:u8() ~= 0
  local size      = m:u16()
  local firstIdx  = m:u16()
  local items = {}
  for i = 1, m:u8() do items[i] = read_item(m) end
  m:u8()                                  -- GameContainerFilter category
  for _ = 1, m:u8() do m:u8(); m:str() end
  -- the >=1340 (isMoveable,isHolding) pair is NOT read at 1530
  container_open(cid, item, name, cap, hasParent, items, unlocked, hasPages, size, firstIdx)
end
S[0x6F] = function(m) container_close(m:u8()) end
S[0x70] = function(m) container_add   (m:u8(), m:u16(), read_item(m)) end
S[0x71] = function(m) container_update(m:u8(), m:u16(), read_item(m)) end
S[0x72] = function(m)
  local cid, slot = m:u8(), m:u16()
  local lastId    = m:u16()
  local last      = (lastId ~= 0) and read_item(m, lastId) or nil
  container_remove(cid, slot, last)
end

S[0xF5] = function(m)                     -- PlayerInventory count cache
  local n, counts = m:u16(), {}
  for _ = 1, n do
    local itemId    = m:u16()
    local attribute = m:u8()
    local amount    = packedCount1500(m)  -- protocol >= 1500
    local tier = item_has_classification(itemId) and attribute or 0
    local key  = itemId * 256 + tier
    counts[key] = (counts[key] or 0) + amount
  end
  state.inventoryCounts = counts
end

S[0x33] = function(m)                     -- ChangeMapAwareRange
  local xr, yr = m:u8(), m:u8()
  state.aware = { left  = math.floor(xr/2) - ((xr+1) % 2),
                  top   = math.floor(yr/2) - ((yr+1) % 2),
                  right = math.floor(xr/2),
                  bottom= math.floor(yr/2) }
end

-- Map packets: NO position prefix at 1530 (GameMapMovePosition OFF)
local function HW() return state.aware.left + state.aware.right + 1 end
local function VH() return state.aware.top  + state.aware.bottom + 1 end

S[0x64] = function(m)
  local p = m:pos(); set_central(p)
  read_map_description(m, p.x-state.aware.left, p.y-state.aware.top, p.z, HW(), VH())
end
S[0x65] = function(m) local p = central(); p.y = p.y - 1
  read_map_description(m, p.x-state.aware.left, p.y-state.aware.top, p.z, HW(), 1); set_central(p) end
S[0x66] = function(m) local p = central(); p.x = p.x + 1
  read_map_description(m, p.x+state.aware.right, p.y-state.aware.top, p.z, 1, VH()); set_central(p) end
S[0x67] = function(m) local p = central(); p.y = p.y + 1
  read_map_description(m, p.x-state.aware.left, p.y+state.aware.bottom, p.z, HW(), 1); set_central(p) end
S[0x68] = function(m) local p = central(); p.x = p.x - 1
  read_map_description(m, p.x-state.aware.left, p.y-state.aware.top, p.z, 1, VH()); set_central(p) end

S[0x4B] = function(m)
  local p, floor = m:pos(), m:u8()
  if p.z == floor then set_central(p) end
  read_floor_description(m, p, floor)
end
S[0x69] = function(m) read_tile_description(m, m:pos()) end
S[0x6A] = function(m) local p = m:pos(); local sp = m:u8(); map_add(read_thing(m), p, sp) end
S[0x6B] = function(m) local old = read_mapped_thing(m); map_replace(old, read_thing(m)) end
S[0x6C] = function(m) map_remove(read_mapped_thing(m)) end
S[0x6D] = function(m) local th = read_mapped_thing(m); map_move(th, m:pos()) end
S[0xBE] = function(m) floor_change_up(m)   end   -- no position prefix
S[0xBF] = function(m) floor_change_down(m) end   -- no position prefix

function read_mapped_thing(m)
  local x = m:u16()
  if x ~= 0xFFFF then
    local y, z, sp = m:u16(), m:u8(), m:u8()
    return map_get_thing({x=x,y=y,z=z}, sp)
  end
  return creature_by_id(m:u32())
end

function read_thing(m)
  local id = m:u16()
  if id == 0 then error("invalid thing id") end
  if id == 97 or id == 98 or id == 99 then return read_creature(m, id) end
  return read_item(m, id)
end

S[0x83] = function(m)                     -- GraphicalEffect (protocol >= 1203)
  local pos = m:pos()
  local t = m:u8()
  while t ~= 0 do
    if     t == 1 or t == 2 then m:u8()
    elseif t == 4 or t == 5 then m:u16(); m:u8(); m:u8(); m:u8()  -- id, dx, dy, source
    elseif t == 3           then m:u16(); m:u8()                  -- id, source
    elseif t == 6           then m:u8();  m:u16()
    elseif t == 7           then m:u8();  m:u8(); m:u16()
    else error(("unknown magic-effect subtype %d"):format(t)) end
    t = m:u8()
  end
end
S[0x84] = function(m) m:pos(); m:u16() end                        -- RemoveMagicEffect
S[0x85] = function(m) local t = m:u8(); if t <= 2 then m:u16() end end  -- Anthem

S[0xDD] = function(m)                     -- AutomapFlag
  local subtype = m:u8()
  if subtype ~= 0 then error("unhandled cyclopedia map subtype " .. subtype) end
  local p, icon, desc = m:pos(), m:u8(), m:str()
  automap_add(p, icon, desc)              -- no remove byte (GameMinimapRemove OFF)
end

S[0x32] = function(m)                     -- ExtendedOpcode
  local sub, buf = m:u8(), m:str()
  if     sub == 0 then state.extendedEnabled = true
  elseif sub == 2 then state.pongSeen = state.pongSeen + 1
  else on_extended(sub, buf) end
end

S[0xD2] = function(m)                     -- VipAdd
  local id, name = m:u32(), m:str()
  local desc, icon, notify = m:str(), m:u32(), m:u8() ~= 0
  local status = m:u8()
  local groups = {}
  for i = 1, m:u8() do groups[i] = m:u8() end
  vip_add(id, name, status, desc, icon, notify, groups)
end
S[0xD3] = function(m) vip_state(m:u32(), m:u8()) end
S[0xD4] = function(m)                     -- VipLogout -> VIP GROUPS at 1530
  local groups = {}
  for i = 1, m:u8() do
    groups[i] = {id=m:u8(), name=m:str(), canEdit=m:u8() ~= 0}
  end
  local left = m:u8()
  vip_groups(groups, left)
end

-- ============================================================================
-- SENDERS  (C() builds a new outgoing message; send() frames + XTEA-encrypts)
-- ============================================================================

local function send_walk(dir)             -- dir 0 N,1 E,2 S,3 W,4 NE,5 SE,6 SW,7 NW
  local op = ({[0]=0x65,[1]=0x66,[2]=0x67,[3]=0x68,
               [4]=0x6A,[5]=0x6B,[6]=0x6C,[7]=0x6D})[dir]
  local o = C(); o:u8(op); send(o)
end
local function send_stop() local o=C(); o:u8(0x69); send(o) end
local function send_turn(dir)
  local o=C(); o:u8(({[0]=0x6F,[1]=0x70,[2]=0x71,[3]=0x72})[dir]); send(o)
end

local AUTOWALK_BYTE = {[1]=1,[4]=2,[0]=3,[7]=4,[3]=5,[6]=6,[2]=7,[5]=8}
local function send_autowalk(path)
  local o = C(); o:u8(0x64); o:u8(#path)
  for _, d in ipairs(path) do o:u8(AUTOWALK_BYTE[d] or 0) end
  send(o)
end

local function send_use(pos, itemId, sp, index)
  local o=C(); o:u8(0x82); o:pos(pos); o:u16(itemId); o:u8(sp); o:u8(index); send(o) end
local function send_use_with(fromPos, itemId, fromSp, toPos, toId, toSp)
  local o=C(); o:u8(0x83); o:pos(fromPos); o:u16(itemId); o:u8(fromSp)
  o:pos(toPos); o:u16(toId); o:u8(toSp); send(o) end
local function send_use_on_creature(pos, thingId, sp, cid)
  local o=C(); o:u8(0x84); o:pos(pos); o:u16(thingId); o:u8(sp); o:u32(cid); send(o) end
local function send_move(fromPos, thingId, sp, toPos, count)
  local o=C(); o:u8(0x78); o:pos(fromPos); o:u16(thingId); o:u8(sp); o:pos(toPos)
  o:u8(count)                             -- GameCountU16 OFF at 1530 -> u8
  send(o) end
local function send_look(pos, itemId, sp)
  local o=C(); o:u8(0x8C); o:pos(pos); o:u16(itemId); o:u8(sp); send(o) end
local function send_look_creature(cid) local o=C(); o:u8(0x8D); o:u32(cid); send(o) end
local function send_attack(cid, seq) local o=C(); o:u8(0xA1); o:u32(cid); o:u32(seq); send(o) end
local function send_follow(cid, seq) local o=C(); o:u8(0xA2); o:u32(cid); o:u32(seq); send(o) end
local function send_cancel_attack_follow() local o=C(); o:u8(0xBE); send(o) end

-- talk: 1530 ALWAYS appends the aim byte on Gunzodus
local function send_talk(mode, channelId, receiver, message, aimMode, aimPos)
  if message == "" or #message > 255 then return end
  aimMode = aimMode or 0
  if aimMode > 3 then return end
  local o = C(); o:u8(0x96); o:u8(MODE_TO_SERVER[mode])
  if mode=="PrivateTo" or mode=="GamemasterPrivateTo" or mode=="RVRAnswer" then
    o:str(receiver)
  elseif mode=="Channel" or mode=="ChannelHighlight"
      or mode=="ChannelManagement" or mode=="GamemasterChannel" then
    o:u16(channelId)
  end
  o:str(message)
  o:u8(aimMode)                           -- REQUIRED at >=1525 on Gunzodus
  if aimMode == 1 or aimMode == 2 then
    if not aimPos then return end
    o:pos(aimPos)
  end
  send(o)
end

local function send_fight_modes(chaseMode, safeFight, pvpMode)
  local o=C(); o:u8(0xA0)                 -- 3 bytes, NO fightMode at 1530
  o:u8(chaseMode); o:u8(safeFight and 1 or 0); o:u8(pvpMode); send(o)
end

local function send_ping()      local o=C(); o:u8(0x1D); send(o) end
local function send_ping_back() local o=C(); o:u8(0x1C); send(o) end   -- 0x1C on Gunzodus
local function send_logout()    local o=C(); o:u8(0x14); send(o) end

local function send_answer_modal(windowId, buttonId, choiceId)
  local o=C(); o:u8(0xF9); o:u32(windowId); o:u8(buttonId); o:u8(choiceId); send(o) end

local function send_close_container(cid) local o=C(); o:u8(0x87); o:u8(cid); send(o) end
local function send_up_container(cid)    local o=C(); o:u8(0x88); o:u8(cid); send(o) end
local function send_seek_in_container(cid, index)
  local o=C(); o:u8(0xCC); o:u8(cid); o:u16(index); o:u8(0); send(o) end

local function send_request_channels() local o=C(); o:u8(0x97); send(o) end
local function send_join_channel(id)   local o=C(); o:u8(0x98); o:u16(id); send(o) end
local function send_leave_channel(id)  local o=C(); o:u8(0x99); o:u16(id); send(o) end
local function send_open_private_channel(name)
  local o=C(); o:u8(0x9A); o:str(name); send(o) end
local function send_close_npc_channel() local o=C(); o:u8(0x9E); send(o) end

local function send_buy(itemId, subType, amount, ignoreCap, withBackpack)
  local o=C(); o:u8(0x7A); o:u16(itemId); o:u8(subType); o:u16(amount)
  o:u8(ignoreCap and 1 or 0); o:u8(withBackpack and 1 or 0); send(o) end
local function send_sell(itemId, subType, amount, ignoreEquipped)
  local o=C(); o:u8(0x7B); o:u16(itemId); o:u8(subType); o:u16(amount)
  o:u8(ignoreEquipped and 1 or 0); send(o) end
local function send_close_npc_trade() local o=C(); o:u8(0x7C); send(o) end
local function send_request_trade(pos, thingId, sp, cid)
  local o=C(); o:u8(0x7D); o:pos(pos); o:u16(thingId); o:u8(sp); o:u32(cid); send(o) end

local function send_equip(itemId, countOrSubType)
  local o=C(); o:u8(0x77); o:u16(itemId); o:u8(countOrSubType); send(o) end

local function send_request_outfit() local o=C(); o:u8(0xD2); send(o) end

local function send_change_outfit(ot)
  local o=C(); o:u8(0xD3)
  o:u8(0x00)                              -- >=1281 normal outfit window
  o:u16(ot.id)
  o:u8(ot.head); o:u8(ot.body); o:u8(ot.legs); o:u8(ot.feet)
  o:u8(ot.addons)
  o:u16(ot.mount)
  o:u8(0); o:u8(0); o:u8(0); o:u8(0)      -- >=1281 mount colours
  o:u8(ot.hasMount and 1 or 0)            -- >=1334
  o:u16(ot.familiar)
  o:u8(0)                                 -- >=1281 randomizeMount
  send(o)                                 -- no wings/auras block at 1530
end

local function send_inspect_character(cid, tab)
  local o=C(); o:u8(0xCE); o:u8(tab); o:u32(cid); send(o) end   -- tab FIRST

local function send_enter_game()
  local o=C(); o:u8(0x0F); send(o)
  -- Gunzodus follows enter-game with an inline extended frame (bypasses the guard)
  local h=C(); h:u8(0x32); h:u8(10); h:str(system_volume_fingerprint(accountName)); send(h)
end


## Evidence
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolcodes.h:45-255 — complete GameServerOpcodes enum; source of every hex value in the server table.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolcodes.h:257-413 — complete ClientOpcodes enum, including ClientPingBackGunz = 28 with the binary offsets that justify it.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:47-742 — parseMessage: full dispatch switch, Lua onOpcode pre-hook (66-71), StoreOffers try/catch (652-670), default branch that skips the remaining bytes (680-700).
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:117-125 — ping/pong dispatch: with GameClientPing ON, opcode 30 -> parsePingBack and opcode 29 -> parsePing (which replies).
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:693-697 — comment explaining why the default case must skipBytes rather than setReadPos (busy loop / OOM otherwise).
- D:/Claude/otclient_mehah1530/otclient/modules/game_features/features.lua:1-309 — the ONLY feature ruleset; 295-306 is the 1530 block (setRsa GUNZODUS_RSA, setCustomOs 61); 291-293 enables GameTacticsWithoutFightMode at 1525.
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:1727-1743 — Game::setClientVersion resets all features then delegates entirely to Lua onClientVersionChange; no feature is set in C++.
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:540-677 — Otc::GameFeature enum with numeric ids, needed to decode opcode 0x43.
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:300-365 — Otc::MessageMode enum values (client ids, distinct from the wire bytes).
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolcodes.cpp:29-90 — buildMessageModesMap; at 1530 the `version >= 1055` table is authoritative.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolcodes.cpp:227-242 — translateMessageModeFromServer / ToServer; unmapped values yield MessageInvalid (255), which makes parseTalk throw.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/inputmessage.cpp:76-106 — getU64/get64 (signed), getString (u16 length + bytes), and getDouble (5 bytes: u8 precision + u32 biased by INT_MAX).
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/outputmessage.cpp:76-93 — addU64 and addString (u16 length then bytes).
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:744-792 — parseLogin: 3 x getDouble (15 bytes) under GameNewSpeedLaw, no canReportBugs byte under GameDynamicBugReporter, no tournament byte at 1530.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2651-2740 — parsePlayerStats; 1530 shape is 60 fixed bytes, levelPercent is u16 under GameLevelPercentU16 (>=1520).
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2742-2869 — parsePlayerSkills; GameAdditionalSkills/GameForgeSkillStats OFF, GameCharacterSkillStats block present, mantra u16 under GameVocationMonk.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2872-2885 — parsePlayerState: u64 states (>=1405) plus the GamePlayerStateCounter byte = 9 bytes.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2887-2896 — parsePlayerCancelAttack reads an EXTRA discarded u32 at clientVersion >= 1530 (0x140549E8A).
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2358-2408 — addCreatureIcon: entries are 5 bytes at clientVersion >= 1530 (trailer read and discarded).
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2434-2457 — parseCreatureData type dispatch (0 / 11-13 / 14); other type values consume nothing.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2459-2562 — parseCreatureHealth / Light / Outfit / Speed / Skulls / Shields / Unpass exact payloads.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2939-2997 — parseTalk mode-dependent tail and the throw on an unknown mode byte.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:3084-3164 — parseTextMessage per-mode payloads; Exp/ExpOthers use u64 at >=1332.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:3167-3177 — parseCancelWalk (u8 direction) and parseWalkWait (u16 millis).
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1503-1541 — map move rows read a Position ONLY under GameMapMovePosition, which is OFF at 1530.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1549-1556 — parseTileAddThing reads the stackpos byte because GameTileAddThingWithStackpos is ON.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1612-1703 — parseOpenContainer / CloseContainer / ContainerAdd / Update / Remove; the >=1340 (isMoveable,isHolding) pair is unreachable at 1530.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1937-2010 — parseMagicEffect protocol>=1203 loop; GameEffectU16 and GameEffectSource both ON at 1530.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:3811-3833 — parseAutomapFlag throws on cyclopedia subtype != 0 and does not read a remove byte (GameMinimapRemove OFF).
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:3895-3944 — readPackedCount1500 and parsePlayerInventory (opcode 0xF5), the only user of the packed count.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:3947-3984 — parseModalDialog; escapeButton is read BEFORE enterButton at version > 970.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:3541-3595 — parseVipAdd / parseVipState / parseVipLogout; with GameVipGroups ON, 0xD4 carries a group list, not a u32 player id.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4206-4245 — getThing (97/98/99 creature markers) and getMappedThing (0xFFFF sentinel switches to a u32 creature id).
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4700-4707 — getPosition = u16 x, u16 y, u8 z.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:7501-7513 — parseFeatures (opcode 0x43): u16 count then (u8 id, u8 enabled); the server can flip any feature mid-session.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:7586-7620 — parseWeaponProficiencyInfo reads an extra u8 detail count at >=1530 whose element layout is explicitly UNVERIFIED.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:115-225 — sendLoginPacket: full field order, the gunz-only u16(2) inside the RSA block, the "261" extended-data fallback, and the checksum/XTEA/sequence enable order.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:227-249 — sendEnterGame plus the unconditional gunz hwid frame 0x32 0x0A STR, built inline to bypass the extended-opcode guard.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:258-288 — sendPing writes 0x1D (GameExtendedClientPing OFF); sendPingBack writes 0x1C on gunz OS at protocol >= 1200, else 0x1E.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:290-329 — sendAutoWalk direction byte mapping (E=1, NE=2, N=3, NW=4, W=5, SW=6, S=7, SE=8).
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:450-497 — sendEquipItem*/sendMove/sendInspectNpcTrade all fall to the u8 count branch because GameCountU16 is OFF at 1530.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:677-737 — sendTalk; the aim-mode tail at clientVersion >= 1525 on gunz OS is appended for EVERY talk, and modes 1/2 append a Position.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgame.h:78-80 — sendTalk defaults aimMode = 0, confirming a 1-byte tail on ordinary say/yell/whisper/channel.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:800-821 — sendChangeFightModes: GameTacticsWithoutFightMode omits the fightMode byte entirely at 1530.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:1002-1053 — sendChangeOutfit exact 1530 field order.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:1179-1198 — sendDebugReport is suppressed on gunz OS because opcode 232 is the store offer-description opcode there.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:1571-1576 — addPosition = u16 x, u16 y, u8 z.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:1694-1733 — sendExivaRestrictions reuses opcode 202 (ClientRefreshContainer), the one genuinely overloaded client opcode.
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:29-40 — CLIENTOS_GUNZ_LINUX=60, CLIENTOS_GUNZ_WINDOWS=61, CLIENTOS_GUNZ_MAC=62; every isGunzOs branch is live at 1530.
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:248-266 — processPing sends a pong immediately; processPingBack only counts.
- D:/Claude/otclient_mehah1530/otclient/modules/gamelib/protocolgame.lua:1-15 — the Lua onOpcode table is empty by default, so nothing is diverted away from the C++ switch in a stock 1530 session.

## Pitfalls
- An unparsed opcode is FATAL for the rest of that message, not just that opcode: the default case calls msg->skipBytes(unreadSize) (protocolgameparse.cpp:698). Multiple opcodes are packed per XTEA message, so one gap silently swallows every opcode behind it in the same frame.
- GameMapMovePosition (31) is NOT enabled at 1530. Map-row opcodes 0x65/0x66/0x67/0x68 and floor-change 0xBE/0xBF carry NO leading Position; assuming otherwise over-reads 5 bytes per packet.
- GameCountU16 (104) is NOT enabled at 1530. sendMove (0x78), sendInspectNpcTrade (0x79), sendEquipItemWithCountOrSubType (0x77) and parseItemInfo (0xF4) use a u8 count, not u16.
- GameTacticsWithoutFightMode (136) is ON at 1530: client opcode 0xA0 is 3 bytes (chase, safe, pvp) with NO fightMode byte, and server 0xA7 mirrors that. Sending the classic 4-byte form desyncs the server.
- Every talk on Gunzodus at >=1525 carries a trailing aim-mode byte (protocolgamesend.cpp:710-734), even a plain 'say'. Omitting it leaves the server one byte short for the rest of the packet.
- Opcode 0xE6 (230) is GameServerBosstiaryEntryChanged (u32) at 1530, NOT SendPreyFreeRerolls (u8+u16), because GameBosstiary is ON. Getting this wrong drifts 1 byte per packet.
- Opcode 0xAF (175) is parseExperienceTracker (two SIGNED i64 = 16 bytes) at >=1200, not the legacy rule-violation-remove STR.
- Opcode 0x85 (133) is parseAnthem (u8 + optional u16) because GameAnthem is ON; parseDistanceMissile is unreachable. Same trap on 0x84 (RemoveMagicEffect, not AnimatedText), 0x86 (ItemClasses, not CreatureMark), 0x87 (OpenForge, not Trappers), 0xB1 (Highscores, not RuleViolationLock).
- getDouble is a 5-byte OTClient-specific encoding (u8 precision + u32 biased by INT_MAX), not an 8-byte IEEE double. parseLogin consumes 15 bytes of it and parsePlayerSkills (0xA1) consumes 13 of them.
- Creature icon entries are 5 bytes at clientVersion >= 1530 (protocolgameparse.cpp:2368-2370). This affects opcode 0x8B type 14 AND the icon blocks inside getCreature during creature appearance.
- parsePlayerCancelAttack (0xA3) reads an extra discarded u32 at >=1530 — the packet is 8 bytes, not 4.
- parsePlayerInventory (0xF5) uses the variable-length packedCount1500 encoding at protocol >= 1500, so entries are 4, 5 or 7 bytes; a fixed u16 read desyncs immediately.
- Four parsers THROW on unexpected input and abandon the whole message: parseTalk (unknown mode byte), parseTextMessage (MessageInvalid code), parseAutomapFlag (cyclopedia subtype != 0), parseTaskBoardData (unknown subtype).
- parseModalDialog reads escapeButton BEFORE enterButton at version > 970 — the natural reading order is reversed.
- GameServerVipLogout (0xD4) is NOT a u32 player id at 1530: with GameVipGroups ON it is a VIP-group list plus a trailing u8.
- Opcode 202 is overloaded client-side: ClientRefreshContainer (u8 containerId) and ClientExivaRestrictions (6 flag bytes + 4 string lists) share it, disambiguated only by context.
- Opcode 232 on Gunzodus is the store offer-description opcode, not a debug report; the fork explicitly suppresses debug reports because the server cannot disambiguate them.
- GameServerFeatures (0x43) can flip ANY feature at runtime. A Lua client that hard-codes the 1530 feature set and ignores 0x43 desyncs the moment the server sends one.
- parsePreyRerollPrice (0xE9) skips the four legacy task-hunting price fields because GameTaskboard is ON at 1520+; parseTaskHuntingBasicData (0xBA) likewise switches to a completely different soulseal payload.
- Sixteen defined-but-unhandled opcodes exist (0x03, 0x04, 0x2C, 0x2D, 0x60, 0x74, 0x80, 0x81, 0x99, 0xC5, 0xC9, 0xCB, 0xDB, 0xE3, 0xF7, plus the undefined 0xBC). If Gunzodus emits one, the remainder of that message is unrecoverable — log and drop the frame rather than guessing a length.

## Open questions
- parseWeaponProficiencyInfo (0xC4) reads a u8 detail count at clientVersion >= 1530 whose element layout is explicitly UNVERIFIED in the source comment (protocolgameparse.cpp:7601-7607). A non-zero count will desync the remainder of the packet. Need a live capture from Gunzodus to determine the record shape.
- The exact numeric ids of Otc::ResourceTypes_t that take a u32 rather than a u64 in opcode 0xEE (RESOURCE_CHARM, RESOURCE_MINOR_CHARM, RESOURCE_MAX_CHARM, RESOURCE_MAX_MINOR_CHARM, RESOURCE_BOUNTY_POINTS, RESOURCE_SOULSEALS) were not read out of const.h in this pass; the pseudocode uses a placeholder RESOURCE_IS_U32 table. Confirm the values before implementing.
- Which of GameServerPing (0x1E) versus GameServerPingBack (0x1D) Gunzodus actually emits during a session is not established from the client alone — the client handles both, and the gunz pong opcode remap to 0x1C is flagged UNVERIFIED in protocolgamesend.cpp:273-278. If keepalives fail, this is the first thing to revert.
- The gunz-only u16(2) literal inside the RSA login block (protocolgamesend.cpp:188-192) has an UNVERIFIED meaning; only its position and width are known.
- Whether the enter-game hwid frame (0x32 0x0A STR) is actually enforced by Gunzodus is UNVERIFIED (protocolgamesend.cpp:233-235) — the client sends it unconditionally, so a Lua client should too, but no login symptom should be attributed to its absence.
- Frame-layer interaction between GameProtocolChecksum (enabled at 840) and GameSequencedPackets (enabled at 1290) is not covered here — sendLoginPacket calls enableChecksum() and then enabledSequencedPackets(). Which header form is actually written per message needs to come from src/framework/net/protocol.cpp (another agent's area), and it gates every opcode above.
- The internal layouts of getCreature, getItem, getOutfit, getPaperdoll, setMapDescription, setFloorDescription and setTileDescription were deliberately left to the companion agent; the tables above cite them by name only. Several Tier-B opcodes (0xC2 monster podium, 0xD1 kill tracker, 0xCF loot tracker) embed them and cannot be implemented without those layouts.
- GameServerTaskBoard (0x5B), GameServerOpenWheelWindow (0x5F), GameServerCyclopediaCharacterInfoData (0xDA) and GameServerStoreOffers (0xFC) have large sub-dispatched bodies that were only characterised at the header level here; each needs its own byte-level pass before a Lua client can survive them.

## VERIFIER (confidence 0.88)

### Corrections (AUTHORITATIVE — these override the spec above)
- **Claim**: §3.2 / table row 0x6E / pseudocode S[0x6E]: "the >=1340 pair (u8 isMoveable, u8 isHolding) is NOT read at 1530" (and the pseudocode comment "-- the >=1340 (isMoveable,isHolding) pair is NOT read at 1530").
  - **Correction**: WRONG — this is a hard 2-byte desync on EVERY container open. The gate is clientVersion >= 1340 and clientVersion is 1530, so both bytes ARE read. parseOpenContainer's correct 1530 tail is: ... u8 category, u8 categoriesSize, categoriesSize×(u8 id, STR name), u8 isMoveable, u8 isHolding.
  - Evidence: D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1653-1656:
    if (g_game.getClientVersion() >= 1340) {
        msg->getU8(); // isMoveable
        msg->getU8(); // isHolding
    }
This is the last read before processOpenContainer(...) at :1658. Compare parseBestiaryOverview :3635/:3647 and parseBestiaryMonsterData :3661, where the identical `>= 1340` gate is taken — the spec itself treats those as live, so the 0x6E claim is internally inconsistent as well.
- **Claim**: Table row 0xC8 / GameServerChooseOutfit: "`Outfit`, if mount==0 4×`u8` colours (>=1281), then outfit/mount/familiar lists".
  - **Correction**: Omits a 2-byte field. After the conditional 4 colour bytes, and still inside the same `clientVersion >= 1281` block, an UNCONDITIONAL `u16 current familiar looktype` is read before any list. Correct 1530 layout: Outfit; if outfit.mount==0 → u8 head,u8 body,u8 legs,u8 feet; u16 familiarLookType; then u16 outfitCount + entries; u16 mountCount + entries; ... A reimplementation following the spec desyncs the outfit window by 2 bytes.
  - Evidence: protocolgameparse.cpp:3233-3243:
    if (g_game.getClientVersion() >= 1281) {
        if (currentOutfit.getMount() == 0) {
            msg->getU8(); //head
            msg->getU8(); //body
            msg->getU8(); //legs
            msg->getU8(); //feet
        }

        msg->getU16(); // current familiar looktype
    }
- **Claim**: §3.4: "The same helper runs inside `getCreature`, so it also affects creature-appearance parsing." (implying one icon block inside getCreature).
  - **Correction**: Understated to the point of being wrong: at 1530 getCreature reads TWO consecutive icon lists, not one. The first is a replace list (gated >=1281), the second a merge list gated specifically on >=1530. Both use the 5-bytes-per-entry 1530 layout, so a creature-appearance parse that reads only one list will desync by at least 1 byte (the second list's count) and by 1+5N when the server sends entries. Correct order inside getCreature at 1530: ... u8 healthPercent, u8 direction, Outfit, u8 lightIntensity, u8 lightColor, u16 speed, ICONLIST(replace), ICONLIST(merge), u8 skull, u8 shield, ...
  - Evidence: protocolgameparse.cpp:4353-4360:
        if (g_game.getClientVersion() >= 1281) {
            addCreatureIcon(msg, wireCreatureId); // replace = true (0x140574697)
        }

        if (g_game.getClientVersion() >= 1530) {
            addCreatureIcon(msg, wireCreatureId, false); // second list, merged into the first (0x1405746B6)
        }
and protocolgame.h:286: `void addCreatureIcon(const InputMessagePtr& msg, const uint32_t creatureId, const bool replace = true) const;`
- **Claim**: §1: "`features.lua` is the entire ruleset; the C++ side enables nothing" / "`modules/game_features/features.lua` — the ONLY place features are set", and the NEVER-enabled list containing "37 GameForceFirstAutoWalkStep" as "must be treated as FALSE".
  - **Correction**: features.lua is not the only writer. modules/game_walk/walk.lua enables GameForceFirstAutoWalkStep (37) on every game start when `not g_game.isOfficialTibia()`, which is TRUE at 1530 because features.lua:304 installs GUNZODUS_RSA and isOfficialTibia() tests `G.currentRsa == CIPSOFT_RSA`. So feature 37 is ON in a stock 1530 session, not "never enabled". modules/game_things/things.lua:33 is a second writer (dat-load fallback; unreachable at >=1281 with protobuf assets). No wire consequence — nothing under src/ reads feature 37 — but the "ONLY place" framing is false and the 37 row of the NEVER list is factually wrong. Everything else in §1 verified exact: I recomputed the 1530 set from features.lua + const.h ids and it matched the spec's 101-entry ON list and 25-entry NEVER list with zero diff in either direction, and the six explicit disables (13,15 @1281; 92 @1314; 109 @1320; 76,126 @1410) are correct.
  - Evidence: modules/game_walk/walk.lua:317-321:
    if not g_game.isOfficialTibia() then
        g_game.enableFeature(GameForceFirstAutoWalkStep)
    else
        g_game.disableFeature(GameForceFirstAutoWalkStep)
    end
modules/gamelib/game.lua:50-52: `function g_game.isOfficialTibia() return G.currentRsa == CIPSOFT_RSA end`
modules/game_features/features.lua:304: `g_game.setRsa(GUNZODUS_RSA)`
modules/game_things/things.lua:33: `g_game.enableFeature(featureFlags[idx])`
grep for GameForceFirstAutoWalkStep under src/ returns only const.h:576 (the enum), no getFeature call.
- **Claim**: §3.3 presents the 0x83 loop as a clean consume-and-continue loop (and the pseudocode raises `error()` on an unknown subtype).
  - **Correction**: Two undocumented early-exit paths exist in the C++ that a reimplementer must know about and must NOT copy: (a) subtypes 4/5, on `!isValidDatId(shotId, ThingCategoryMissile)`, do `return;` — abandoning the whole parser mid-loop with the rest of the effect chain unconsumed, after which parseMessage reads payload bytes as opcodes; (b) subtype 3, on an invalid effect id, does `continue;` — which jumps to `while (effectType != END_LOOP)` WITHOUT reading the next type byte, so effectType is still 3 and it re-reads u16+u8 from wherever the cursor now is. Both are client bugs; the correct Lua model is "always consume the subtype's fields, then read the next type byte, and only skip the rendering". Separately, the pseudocode's `else error(...)` diverges from the C++ `default: break;` — the spec prose gets this right ("nothing consumed ### desync risk") but the pseudocode does not match it.
  - Evidence: protocolgameparse.cpp:1957-1960:
                    if (!g_things.isValidDatId(shotId, ThingCategoryMissile)) {
                        g_logger.traceError("invalid missile id {}", shotId);
                        return;
                    }
protocolgameparse.cpp:1978-1981:
                    if (!g_things.isValidDatId(effectId, ThingCategoryEffect)) {
                        g_logger.traceError("invalid effect id {}", effectId);
                        continue;
                    }
protocolgameparse.cpp:2001-2002: `default:\n                    break;` followed by :2005 `effectType = msg->getU8();`
- **Claim**: Table row 0xE2 GameServerSendOpenRewardWall: "`u8 bonusShrine`, `u32 nextRewardTime`, `u8 dayStreak`, `u8 wasTaken`, …" — the "…" is left unspecified.
  - **Correction**: The elided tail branches on isGunzOs, which is TRUE at OS 61, so the generic layout is wrong here. Exact 1530/gunz layout: u8 bonusShrine, u32 nextRewardTime, u8 dayStreakDay, u8 wasDailyRewardTaken; if wasDailyRewardTaken != 0 → STR errorMessage, u8 token (and the u16 tokens is NOT read on gunz); else → u8 flag, then u32 timeLeft ONLY if flag != 1, then u16 tokens; finally u16 dayStreakLevel in both branches. Following the non-gunz layout over-reads 2 bytes in the taken branch and 4 in the not-taken/flag==1 branch.
  - Evidence: protocolgameparse.cpp, parseOpenRewardWall:
    if (wasDailyRewardTaken != 0) {
        errorMessage = msg->getString();
        const uint8_t token = msg->getU8();
        if (!isGunzOs && token != 0) {
            tokens = msg->getU16(); // Tokens
        }
    } else {
        const uint8_t flag = msg->getU8(); // Unknown
        if (!isGunzOs || flag != 1) {
            timeLeft = msg->getU32();
        }
        tokens = msg->getU16(); // Tokens
    }
    const uint16_t dayStreakLevel = msg->getU16();
with isGunzOs computed from `osValue >= Otc::CLIENTOS_GUNZ_LINUX && osValue <= Otc::CLIENTOS_GUNZ_MAC` in the same function.
- **Claim**: §2.4: "Any throw hits the outer catch (704-741), which logs and abandons the whole message."
  - **Correction**: Only `stdext::exception` does. The outer handler is `catch (const stdext::exception& e)`; a plain `std::exception` (e.g. from std library code inside a parser) propagates out of parseMessage entirely. Note the contrast with the 0xFC handler at :661, which catches `const std::exception&`. Minor for a Lua port (pcall catches everything) but the spec states it as unconditional.
  - Evidence: protocolgameparse.cpp:704: `    } catch (const stdext::exception& e) {`
protocolgameparse.cpp:661-662: `                    } catch (const std::exception& e) {`
- **Claim**: Table row 0x7B GameServerPlayerGoods: "`u16 n` (>=1334), n×(`u16 itemId`, `u16 amount`)".
  - **Correction**: Correct on the wire, but the C++ stores the u16 count into a `uint8_t`, truncating it. A faithful Lua port that reads u16 and loops the full count is RIGHT and the C++ is buggy above 255 entries — worth stating explicitly so a reimplementer doesn't 'bug-compatibly' mask the count to 8 bits and desync in the opposite direction.
  - Evidence: protocolgameparse.cpp, parsePlayerGoods: `const uint8_t itemsListSize = g_game.getClientVersion() >= 1334 ? msg->getU16() : msg->getU8();` — getU16() consumes 2 bytes but the value is narrowed to uint8_t before the `for (auto i = 0; i < itemsListSize; ++i)` loop.

### Additions
- VERIFIED CORRECT (spot-checked line by line, no error found): §0 primitives (inputmessage.cpp:60-99 U16/U32/U64 LE, get64 signed LE, getString = u16 len + raw bytes; getDouble = u8 precision + u32 biased, 5 bytes, not IEEE754); getPosition = u16 x, u16 y, u8 z (protocolgameparse.cpp:4700-4707) and addPosition identical on send; readPackedCount1500 (:3895-3908) byte-for-byte as specified, including that the >=0x80 branch discards b1 and reads 3 more bytes. §1 feature set: I recomputed the 1530 set programmatically from features.lua + const.h and it matches the spec's ON list, DISABLED list and NEVER list exactly (0 differences). §2 loop, Lua onOpcode pre-hook, StoreOffers try/catch, default skipBytes. §3.1 parseLogin (:744-792) 15 bytes of speed doubles, no canReportBugs, no tournament byte. §3.5 parsePlayerStats = exactly 60 bytes (I counted the 1530 path field by field). §3.6 parsePlayerSkills including the 7 Fist..Fishing entries (const.h:138-144), skipped AdditionalSkills/ForgeSkillStats blocks, and the CharacterSkillStats block with mantra u16 between armor and mitigation. §3.7 parseTalk mode groups and the throw. §3.8 parseTextMessage incl. u64 Exp at >=1332. §3.9 modal dialog with escape BEFORE enter. §4 message-mode map: identical to protocolcodes.cpp:37-87 for all 57 rows, and the seven unmapped deprecated modes are correct. Ping dispatch (:117-125): with GameClientPing ON, 0x1D→parsePing (which calls processPing → sendPingBack, game.cpp:248-252) and 0x1E→parsePingBack. 0xD4 VipLogout carrying the group list rather than a u32 id. 0xDD AutomapFlag throwing on subtype != 0 and reading no remove byte. 0xA2 = 9 bytes, 0xA3 = 8 bytes (the extra >=1530 discarded u32 is real, :2890-2892), 0xB7 = 7 bytes. 0xA7 PlayerModes = 3 bytes with no fightMode. Map rows 0x65-0x68 with no Position prefix and the exact ±1 / ±range arithmetic in the pseudocode. All 14 'not in switch' rows confirmed absent from the dispatch, and 0x60 GameServerInventoryImbuements confirmed declared-but-unhandled. Send side: sendAutoWalk direction bytes E=1..SE=8, sendPing writing 0x1D, sendPingBack writing 0x1C on gunz OS at >=1200, the gunz u16(2) in the RSA block, the '261' extended-data fallback, the unconditional 0x32/0x0A/STR hwid frame after 0x0F, sendTalk's always-appended aimMode byte at >=1525 with a Position for modes 1/2, sendChangeFightModes omitting fightMode under GameTacticsWithoutFightMode, and the u8 count branches under GameCountU16 OFF.
- VERSION-FIELD AMBIGUITY the spec should make explicit: several gates read getProtocolVersion(), not getClientVersion(). Specifically 0x83 parseMagicEffect (`getProtocolVersion() >= 1203`), 0x29 supply-stash free-slots (`getProtocolVersion() < 1410`), 0x2A special container (`getProtocolVersion() >= 1220`), 0xE9 prey reroll price (`getProtocolVersion() >= 1230`), and 0xF5 packed count (`getProtocolVersion() < 1500`). At 1530 the two numbers coincide — modules/gamelib/game.lua:91-104 getClientProtocolVersion() maps only 980-1002 to different values and returns `clients[client] or client` otherwise — so every resolution in the spec is right, but a Lua port must keep the two as separate variables because the protocol version is also what goes on the wire in the login packet (protocolgamesend.cpp:127 `msg->addU16(g_game.getProtocolVersion())`, with clientVersion added separately at :129 under GameClientVersion).
- getDouble edge case worth pinning down before a Lua port: inputmessage.cpp computes `const int32_t v = getU32() - INT_MAX;` — the subtraction happens in uint32 and is then reinterpreted as int32, so raw == 0xFFFFFFFF yields -2147483648, not +2147483648 as the spec's plain `(raw - 2147483647)` would give. Also the divisor is `std::pow(10.f, precision)` — a FLOAT pow, so precision >= 8 loses accuracy relative to a double 10^precision. Both are marginal but they are the only places where a naive Lua `(raw - 2147483647) / 10^p` diverges bit-for-bit.
- Additional silent-desync early-returns the spec does not list, all of which a Lua port should replace with 'consume the payload, then decide': 0xF5 parsePlayerInventory returns without consuming anything when the u16 size exceeds 10000 (`MAX_INVENTORY_TYPES`); 0xEB parseImbuementWindow returns after reading only windowType when windowType > IMBUEMENT_WINDOW_SCROLL; 0xD0 parseQuestTracker consumes only the u8 messageType when it is neither 0 nor 1 (switch has no default); 0x84 parseRemoveMagicEffect returns after Position+u16 on an invalid effect id (harmless — everything was already consumed); 0x94 parsePlayerHelpers and all the parseCreature* handlers return after consuming their full fixed payload (harmless). Only the first three can leave bytes on the wire.
- 0x8B CreatureData type dispatch detail the spec should state: the switch has no default, so types 1-10 and >=15 consume NOTHING beyond the u32+u8 header — the spec says this correctly, but note that type 0 recursively invokes the full getCreature parser (including the two 1530 icon lists above), so the 'other types consume nothing' rule and the 'type 0 → getCreature' rule have wildly different byte costs and must not be collapsed.
- 0xB1 parseHighscores semantics: the first byte is a boolean and the parser returns when it is NON-zero (`const bool isEmpty = ...; if (isEmpty) return;`). The spec's phrasing 'u8 isEmpty; if 0 → highscore page blob' is correct but reads ambiguously; state it as 'if byte != 0, the packet ends here'.
