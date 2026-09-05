# Player/creature state packets for protocol 1530 (Gunzodus, OS 61) — everything a healing/attacking bot reacts to

# Wire spec — player/creature state, protocol 1530 (Gunzodus, OS 61)

Reference tree: `D:/Claude/otclient_mehah1530/otclient`. All offsets below are **payload after the 1‑byte opcode**. All integers **little‑endian**.

---

## 0. Version/feature baseline

`Game::setClientVersion` (src/client/game.cpp:1727-1743) does nothing but reset `m_features` and fire the Lua hook — **every feature flag for 1530 comes from `modules/game_features/features.lua`**. `protocolVersion == clientVersion == 1530` (`getClientProtocolVersion` in modules/gamelib/game.lua:91-104 only remaps 980..1002).

### Flags that are ON at 1530 and change byte layout

| Flag (id) | Enabled at | Effect on this area |
|---|---|---|
| GameSoul (79) | ≥750 | `soul` u8 in stats |
| GameLevelU16 (78) | ≥760 | `level` u16 |
| GameLooktypeU16 (42) | ≥770 | outfit lookType u16 |
| GameMessageStatements (45) | ≥770 | Talk has u32 statement id |
| GamePlayerStamina (43) | ≥780 | `stamina` u16 |
| GamePlayerAddons (44) | ≥780 | outfit addons u8 |
| GameMessageLevel (46) | ≥780 | Talk has u16 level |
| GameDoubleFreeCapacity (6) | ≥840 | freeCapacity u32 |
| GameTileAddThingWithStackpos (124) | ≥841 | 0x6A carries stackpos u8 |
| GameCreatureEmblems (14) | ≥854 | emblem u8 for unknown creatures |
| GameAttackSeq (32) | ≥860 | attack/follow carry u32 seq; ClearTarget carries u32 |
| GamePenalityOnDeath (4) | ≥862 | Death has penalty u8 |
| GameDoubleExperience (7) | ≥870 | experience u64 |
| GamePlayerMounts (12) | ≥870 | outfit mount u16 (+4 colour bytes when ≠0 at ≥1281) |
| GameTotalCapacity (8) | ≥910 | (suppressed in stats by the ≥1281 gate — see §1) |
| GameSkillsBase (9) | ≥910 | baseSkill fields, `baseSpeed` u16 in stats |
| GamePlayerRegenerationTime (10) | ≥910 | `regeneration` u16 |
| GameChannelPlayerList (11) | ≥910 | OpenChannel/OpenOwnChannel carry player lists |
| GameClientPing (24) | ≥953 | **inverts ping opcode meaning** (see §12) |
| GameOfflineTrainingTime (20) | ≥960 | `offlineTraining` u16 |
| GameLoginPending (35) | ≥981 | opcode 0x0A = PendingGame, not Login |
| GameNewSpeedLaw (36) | ≥981 | login packet carries speedA/B/C doubles; step-duration formula |
| GameContainerPagination (40) | ≥984 | container slot indices u16 + pagination fields |
| GameThingMarks (41) | ≥1000 | creatureType u8 + mark u8 in getCreature |
| GameDoubleSkills (29) | ≥1035 | skill level u16 |
| GameBaseSkillU16 (53) | ≥1035 | skill baseLevel u16 |
| GameCreatureIcons (54) | ≥1036 | legacy `icon` u8 in getCreature |
| GameExperienceBonus (66) | ≥1054 | xp-rate block in stats |
| GameDeathType (70) | ≥1055 | Death has deathType u8 |
| GameThingQuiver (84) / GameThingPodium (85) / GameThingUpgradeClassification (86) | ≥1260/1264/1272 | item attribute blocks |
| GameSequencedPackets (90) | ≥1290 | outgoing packets use a sequence dword instead of adler checksum |
| GameThingCounter (87) / GameThingClock (88) / GameThingPodiumItemType (89) | ≥1290 | item attribute blocks |
| **GameDoubleHealth (28)** | ≥1300 | **health/maxHealth/mana/maxMana/manaShield are u32** |
| GameUshortSpell (91) | ≥1300 | spell ids u16 (cooldowns, spell list) |
| GameConcotions (94) | ≥1300 | 1 extra byte in skills packet |
| GameAnthem (95) | ≥1300 | opcode 0x85 = Anthem, not distance missile |
| GameContainerTypes (106) | ≥1320 | container attribute block form |
| **GamePlayerStateCounter (108)** | ≥1320 | **extra u8 after the state bitmask** |
| GameLeechAmount (109) | **disabled** ≥1320 | — |
| GameWrapKit (112) / GameContainerFilter (113) | ≥1321 | item / container extras |
| GameAdditionalSkills (76) | **disabled** ≥1410 | no crit/leech block in skills |
| GameForgeSkillStats (126) | **disabled** ≥1410 | no forge block in skills |
| **GameCharacterSkillStats (127)** | ≥1410 | the big skills tail (capacity, absorbs, …) |
| **GameVocationMonk (130)** | ≥1500 | `mantra` u16 inside the skills tail; 0xC1 MonkData |
| GameProficiency (135) | ≥1510 | — |
| **GameLevelPercentU16 (131)** | ≥1520 | **levelPercent is u16 centipercent** |
| GameTacticsWithoutFightMode (136) | ≥1525 | PlayerModes has no fightMode byte |
| GameFormatCreatureName (22), GameAllowPreWalk (122), GameMapCache (125) | always | — |

### Flags that are OFF at 1530 (load-bearing negatives)

`GameCountU16` (104) → **item counts are u8**; `GameMapMovePosition` (31) → **0x65..0x68 and 0xBE/0xBF carry no position prefix**; `GameExtendedClientPing` (25); `GameItemShader` (101); `GameCreatureShader` (102); `GameCreatureAttachedEffect` (103); `GameWingsAurasEffectsShader` (118); `GameCreaturePaperdoll` (128); `GameItemTooltipV8` (117); `GameMagicEffectU16` (16); `GameChangeMapAwareRange` (30); `GameItemAnimationPhase` (15) and `GameEnvironmentEffect` (13) are explicitly **disabled** at ≥1281; `GameTournamentPackets` (92) disabled at ≥1314.

`parseFeatures` (opcode **67 / 0x43**, protocolgameparse.cpp:7501-7513) can flip any flag at runtime: `u16 count`, then `count × (u8 featureId, u8 enabled)`. A Lua client must honour it.

### Wire primitives (framework/net/inputmessage.cpp:52-106)

```
u8, u16 (LE), u32 (LE), u64 (LE), i64 (LE)
string  := u16 length, then `length` raw bytes (no NUL)
double  := u8 precision, u32 raw ;  value = (raw - 2147483647) / 10^precision      -- 5 bytes
Position := u16 x, u16 y, u8 z                                                     -- 5 bytes
```

---

## 1. `0xA0` (160) GameServerPlayerData — parsePlayerStats  (protocolgameparse.cpp:2651-2740)

Exact 1530 layout, **60 bytes**, no conditionals left:

```
off size field                 note
 0   u32  health
 4   u32  maxHealth
 8   u32  freeCapacity         client does freeCapacity /= 100  (cv > 772)
12   u64  experience
20   u16  level
22   u16  levelPercent         CENTIPERCENT (GameLevelPercentU16); display = /100
24   u16  baseXpGain           EXP_BASE      (per-mille-ish rate, server units)
26   u16  grindingAddend       EXP_LOWLEVEL
28   u16  storeBoostAddend     EXP_XPBOOST
30   u16  huntingBoostFactor   EXP_STANINAMULTIPLIER
32   u32  mana
36   u32  maxMana
40   u8   soul
41   u16  stamina              minutes
43   u16  baseSpeed
45   u16  regenerationTime     seconds of food
47   u16  offlineTrainingTime  minutes
49   u16  storeExpBoostTime    seconds  (cv >= 1097)
51   u8   canBuyXpBoost        (cv >= 1097)
52   u32  manaShield           remaining  (cv >= 1281 && GameDoubleHealth)
56   u32  maxManaShield        total
```

**Absent at 1530 (do not read):**
* `totalCapacity` — gated `clientVersion < 1281 && GameTotalCapacity` (2663-2666). Total/base capacity arrive in the **skills** packet instead.
* `voucherAddend` — gated `clientVersion < 1281` (2681-2684).
* `magicLevel / baseMagicLevel / magicLevelPercent` — gated `clientVersion < 1281` (2697-2705). They arrive in the **skills** packet.
* the ≤1096 `double experienceBonus` form.

Units/scaling the client applies: `freeCapacity /= 100` (so wire is capacity×100); `levelPercent` kept raw in `m_levelPercent`, `LocalPlayer::getLevelPercent()` returns `/100` (localplayer.cpp:425-428). Health/mana are raw absolutes.

---

## 2. `0xA1` (161) GameServerPlayerSkills — parsePlayerSkills  (protocolgameparse.cpp:2742-2870)

1530 layout:

```
-- magic block (cv >= 1281)
u16 magicLevel
u16 baseMagicLevel
u16 loyaltyMagicLevel        -- read and DISCARDED ("base + loyalty bonus(?)")
u16 magicLevelPercentCenti   -- client stores /100

-- 7 skills, in enum order Fist(0) Club(1) Sword(2) Axe(3) Distance(4) Shielding(5) Fishing(6)
repeat 7 times:
    u16 level                -- GameDoubleSkills
    u16 baseLevel            -- GameSkillsBase && GameBaseSkillU16
    u16 loyaltyLevel         -- read and DISCARDED (cv >= 1281)
    u16 levelPercentCenti    -- client stores /100

-- GameAdditionalSkills block: ABSENT (disabled at >=1410)
-- GameConcotions (>=1300):
u8  concoctionsCount         -- read and discarded
-- GameForgeSkillStats block: ABSENT (disabled at >=1410)

-- GameCharacterSkillStats (>=1410):
u32    capacity              -- client /100  -> setTotalCapacity
u32    baseCapacity          -- client /100  -> setBaseCapacity
u16    flatDamageHealing
u16    attackValue
u8     attackElement
double convertedDamage       (5 bytes)
u8     convertedElement
double lifeLeech             (5)
double manaLeech             (5)
double critChance            (5)
double critDamage            (5)
double onslaught             (5)
u16    defense
u16    armor
u16    mantra                -- ONLY if GameVocationMonk (ON at 1530)
double mitigation            (5)
double dodge                 (5)
u16    damageReflection
u8     combatsCount
repeat combatsCount:
    u8     combatType
    double absorbValue       (5)
double momentum              (5)
double transcendence         (5)
double amplification         (5)
```

Fixed size = 8 + 56 + 1 + 63 + 15 = **143 bytes + 6 × combatsCount**.

Skill count at 1530 = **7** (Fist..Fishing). `Otc::Skill` (const.h:136-156): `Fist=0, Club, Sword, Axe, Distance, Shielding, Fishing, CriticalChance=7, CriticalDamage, LifeLeechChance, LifeLeechAmount, ManaLeechChance, ManaLeechAmount, Fatal=13, Dodge, Momentum, Transcendence, LastSkill=17`. Indices 7..16 are never filled from the wire at 1530.

The "loot/magic-shield extras" you asked about: at 1530 there is **no** loot/magic-shield sub-block in this packet. The magic-shield totals live in the **stats** packet (§1 offsets 52/56), and the "is magic shield active" bool lives in `0x9F` PlayerDataBasic (§14).

---

## 3. `0xA2` (162) GameServerPlayerState — parsePlayerState  (protocolgameparse.cpp:2872-2885)

```
u64 states        -- clientVersion >= 1405  => getU64()  (NOT u32!)
u8  iconsCounter  -- GamePlayerStateCounter (>=1320), read and discarded
```
Total **9 bytes**.

Bit values (`Otc::PlayerStates`, const.h:278-298, extended in modules/gamelib/player.lua:3-38):

```
0x00000001 Poison            0x00000002 Burn             0x00000004 Energy
0x00000008 Drunk             0x00000010 ManaShield(old)  0x00000020 Paralyze
0x00000040 Haste             0x00000080 Swords(logout)   0x00000100 Drowning
0x00000200 Freezing          0x00000400 Dazzled          0x00000800 Cursed
0x00001000 PartyBuff         0x00002000 PzBlock/RedSwords 0x00004000 Pz
0x00008000 Bleeding          0x00010000 Hungry / LesserHex
0x00020000 IntenseHex        0x00040000 GreaterHex       0x00080000 Rooted
0x00100000 Feared            0x00200000 GoshnarTaint1    0x00400000 GoshnarTaint2
0x00800000 GoshnarTaint3     0x01000000 GoshnarTaint4    0x02000000 GoshnarTaint5
0x04000000 NewManaShield     0x08000000 Agony            0x10000000 Powerless
0x20000000 Mentored
```
Bits above 0x20000000 are unassigned in this build but the field is 64-bit — keep it as a 64-bit value (in LuaJIT use two u32 halves or `ffi` `uint64_t`; `bit.band` only covers 32 bits).

Bot-relevant: `Paralyze` (0x20) makes the client re-issue `updateWalk` (localplayer.cpp:283-294); `NewManaShield` (0x04000000) is the modern mana-shield indicator; `PzBlock` (0x2000) blocks logout.

---

## 4. `0xA3` (163) GameServerClearTarget — parsePlayerCancelAttack  (protocolgameparse.cpp:2887-2896)

```
u32 seq       -- GameAttackSeq (ON)
u32 unknown   -- clientVersion >= 1530 ONLY; read and DISCARDED ("0x140549E8A")
```
8 bytes. Handling: `Game::processAttackCancel` cancels the attack iff `seq == 0 || seq == m_seq` (game.cpp:585-589), where `m_seq` is the counter the client sent in its own `0xA1 ClientAttack`.

---

## 5. Creature state packets

All ids are `u32`. If the creature is unknown the client logs and **returns without consuming more** — but every one of these has a fixed-size payload, so a Lua parser must always consume the full payload.

| Opcode | Name | Payload |
|---|---|---|
| `0x8B` (139) | CreatureData | `u32 id, u8 type`, then: `type==0` → full `Creature` struct (§8, the u16 discriminator is read from the stream); `type∈{11,12,13}` → `u8 vocationId`; `type==14` → icon list (§9). Any other type → nothing. (2434-2457) |
| `0x8C` (140) | CreatureHealth | `u32 id, u8 healthPercent` (0..100). (2459-2470) |
| `0x8D` (141) | CreatureLight | `u32 id, u8 intensity, u8 color`. (2473-2488) |
| `0x8E` (142) | CreatureOutfit | `u32 id, Outfit` (§7). (2490-2502) |
| `0x8F` (143) | CreatureSpeed | `u32 id, u16 baseSpeed (cv>=1059), u16 speed`. `setBaseSpeed` only applied when baseSpeed≠0. (2504-2520) |
| `0x90` (144) | CreatureSkull | `u32 id, u8 skull`. (2522-2534) |
| `0x91` (145) | CreatureParty (shield) | `u32 id, u8 shield`. (2536-2548) |
| `0x92` (146) | CreatureUnpass | `u32 id, u8 unpass`; client sets `passable = !unpass`. (2550-2562) |
| `0x93` (147) | CreatureMarks | `u32 id, u8 squareType, u8 squareColor` (cv≥1076). `squareType==0` → clear squares; `==2` → static square colour `squareColor==0 ? 1 : squareColor`; else timed square. (4015-4052) |
| `0x94` (148) | PlayerHelpers | `u32 id, u16 helpers`. (1344-1356) |
| `0x95` (149) | CreatureType | `u32 id, u8 type` (see CreatureType enum below). (4054-4066) |
| `0x6D` (109) | MoveCreature | `MappedThing` (§6) then `Position newPos`. (1591-1610) |

Enums:
* `PlayerSkulls` (const.h:232-241): `0 none, 1 yellow, 2 green, 3 white, 4 red, 5 black, 6 orange`.
* `PlayerShields` (243-257): `0 none, 1 whiteYellow(leader invite), 2 whiteBlue(member invite), 3 blue, 4 yellow, 5 blueSharedExp, 6 yellowSharedExp, 7 blueNoSharedExpBlink, 8 yellowNoSharedExpBlink, 9 blueNoSharedExp, 10 yellowNoSharedExp, 11 gray`.
* `PlayerEmblems` (259-267): `0 none, 1 green, 2 red, 3 blue, 4 member, 5 other`.
* `Proto::CreatureType` (protocolcodes.h:415-424): `0 player, 1 monster, 2 npc, 3 summonOwn, 4 summonOther, 5 hidden, 0xFF unknown`.
* `Otc::Direction` (const.h:158-169): `0 N, 1 E, 2 S, 3 W, 4 NE, 5 SE, 6 SW, 7 NW, 8 invalid`.

`Creature::setHealthPercent` (creature.cpp:854-885) only fires `onHealthPercentChange` on change and calls `onDeath()` when the value reaches 0 — that is the only "creature died" signal for non-local creatures.

---

## 6. `MappedThing` (protocolgameparse.cpp:4220-4246)

```
u16 x
if x ~= 0xFFFF then
    u16 y ; u8 z ; u8 stackpos        -- total 6 bytes; resolve tile(pos)[stackpos]
else
    u32 creatureId                    -- total 6 bytes; resolve by id
end
```
Used by `0x6D` MoveCreature, `0x6B` ChangeOnMap, `0x6C` DeleteOnMap.

---

## 7. `Outfit` (protocolgameparse.cpp:4139-4203) — 1530 form

```
u16 lookType
if lookType ~= 0 then
    u8 head ; u8 body ; u8 legs ; u8 feet ; u8 addons     -- GamePlayerAddons ON
else
    u16 lookTypeEx                                        -- item id, 0 = invisible
end
u16 mount                                                 -- GamePlayerMounts ON
if mount ~= 0 then u8 mHead ; u8 mBody ; u8 mLegs ; u8 mFeet end   -- cv >= 1281
-- wings/auras/effects/shader block ABSENT (GameWingsAurasEffectsShader OFF)
```
Sizes: 8 or 9 bytes (no mount), +4 with mount colours. `getOutfit(msg, parseMount=false)` (used by KillTracker, outfit windows) skips the mount block entirely.

---

## 8. `Creature` struct — `getCreature` (protocolgameparse.cpp:4248-4508), 1530 form

Discriminator `u16 type` (read by `getThing` at 4187-4198 or by `parseCreatureData` type 0):
`97 = UnknownCreature`, `98 = OutdatedCreature`, `99 = Creature` (protocolcodes.h:40-42).

```
if type == 98 (known) then
    u32 creatureId
elseif type == 97 (unknown) then
    u32 removeId
    u32 creatureId
    u8  creatureType                       -- cv >= 910
    if creatureType == 3 (summonOwn) then u32 masterId end   -- cv >= 1281
    string name
end
-- common tail for 97/98:
u8  healthPercent
u8  direction
Outfit outfit                              -- §7
u8  lightIntensity
u8  lightColor
u16 speed
IconList iconsPrimary                      -- cv >= 1281, REPLACE semantics  (§9)
IconList iconsSecondary                    -- cv >= 1530 ONLY, MERGE semantics (§9)
u8  skull
u8  shield
if type == 97 then u8 emblem end           -- GameCreatureEmblems, unknown-only
u8  creatureType2                          -- GameThingMarks
if creatureType2 == 3 then u32 masterId
elseif creatureType2 == 0 then u8 vocationId end     -- cv >= 1281
u8  icon                                   -- GameCreatureIcons (legacy single icon)
u8  mark                                   -- GameThingMarks; 0xFF = clear static square
                                           -- (the extra u16 "helpers" here is cv<1281 only)
u8  inspectionType                         -- cv >= 1281
u8  unpass                                 -- cv >= 854 ; passable = !unpass
-- paperdoll / shader / attached-effect blocks ABSENT (features OFF)

elseif type == 99 (turn) then
    u32 creatureId
    u8  direction
    u8  unpass                             -- cv >= 953
end
```

---

## 9. `IconList` — `addCreatureIcon` (protocolgameparse.cpp:2358-2410)

```
u8 count
repeat count:
    u8  icon
    u8  category        -- 0x00 monster, 0x01 player (comment)
    u16 count
    u8  trailer         -- clientVersion >= 1530 ONLY: entry is 5 bytes; value discarded
```
`replace=true` (the first list in getCreature, and `0x8B` type 14) overwrites the creature's icon set. `replace=false` (the **second** list, 1530-only) merges: an empty incoming list is a no-op; matching `(icon, category)` keeps the **greater** count; otherwise appended.

---

## 10. Message-mode table for 1530 (`Proto::buildMessageModesMap`, protocolcodes.cpp:29-88 + reverse lookup 227-233)

Because `version >= 1055`, the table used is the ≥1055 branch (the earlier `if (version >= 1094) messageModesMap[MessageMana] = 43;` is redundant — the same value is set again). **server byte → Otc::MessageMode:**

```
0  MessageNone(0)            1  MessageSay(1)                 2  MessageWhisper(2)
3  MessageYell(3)            4  MessagePrivateFrom(4)         5  MessagePrivateTo(5)
6  MessageChannelManagement(6) 7 MessageChannel(7)            8  MessageChannelHighlight(8)
9  MessageSpell(9)          10  MessageNpcFromStartBlock(51) 11  MessageNpcFrom(10)
12 MessageNpcTo(11)         13  MessageGamemasterBroadcast(12)
14 MessageGamemasterChannel(13) 15 MessageGamemasterPrivateFrom(14)
16 MessageGamemasterPrivateTo(15) 17 MessageLogin(16)         18  MessageWarning(17)
19 MessageGame(18)          20  MessageGameHighlight(50)     21  MessageFailure(19)
22 MessageLook(20)          23  MessageDamageDealed(21)      24  MessageDamageReceived(22)
25 MessageHeal(23)          26  MessageExp(24)               27  MessageDamageOthers(25)
28 MessageHealOthers(26)    29  MessageExpOthers(27)         30  MessageStatus(28)
31 MessageLoot(29)          32  MessageTradeNpc(30)          33  MessageGuild(31)
34 MessagePartyManagement(32) 35 MessageParty(33)            36  MessageBarkLow(34)
37 MessageBarkLoud(35)      38  MessageReport(36)            39  MessageHotkeyUse(37)
40 MessageTutorialHint(38)  41  MessageThankyou(39)          42  MessageMarket(40)
43 MessageMana(41)          44  MessageBeyondLast(42)
48 MessageAttention(52)     49  MessageBoostedCreature(53)   50  MessageOfflineTrainning(54)
51 MessageTransaction(55)   52  MessagePotion(56)
```
(bytes 45,46,47 and ≥53 are unmapped → `MessageInvalid (255)`.)
**Note:** `MessageMonsterSay/MessageMonsterYell/MessageRVR*/MessageRed/MessageBlue` are **not in the 1530 table** — the corresponding branches in `parseTalk` are dead at this version.

---

## 11. `0xB4` (180) GameServerTextMessage — parseTextMessage  (3084-3165)

```
u8 code  ->  mode = translate(code)   ; unmapped code => the client THROWS
switch mode:
  ChannelManagement(6), Guild(33), PartyManagement(34), Party(35):
        u16 channelId ; string text
  DamageDealed(23), DamageReceived(24), DamageOthers(27):
        Position pos (5)
        u32 physValue ; u8 physColor
        u32 magicValue; u8 magicColor
        string text
  Heal(25), Mana(43), HealOthers(28):
        Position pos (5) ; u32 value ; u8 color ; string text
  Exp(26), ExpOthers(29):
        Position pos (5) ; u64 value  (clientVersion >= 1332) ; u8 color ; string text
  default:
        (nothing)
end
if text == "" then string text end     -- see PITFALL
```
The 8-bit `color` is a Tibia 8-bit palette index (`Color::from8bit`).

Bot use: `DamageReceived(24)` gives the exact hit amounts and their combat colours at a position; `Heal(25)` / `Mana(43)` give the healed amount; `Failure(21)` / `Status(30)` carry "You are exhausted." style text.

---

## 12. `0xAA` (170) GameServerTalk — parseTalk  (2939-2997)

```
u32    statementId                 -- GameMessageStatements ON
string name                        -- client applies formatCreatureName (title-cases words)
if statementId > 0 then u8 suffix end          -- clientVersion >= 1281
u16    level                       -- GameMessageLevel ON
u8     modeByte  -> mode = translate(modeByte)
-- mode-dependent middle field:
   Position pos (5 bytes) for: Say(1) Whisper(2) Yell(3) Spell(9) NpcFromStartBlock(10)
                               NpcTo(12) BarkLow(36) BarkLoud(37) Potion(52)
   u16 channelId          for: ChannelManagement(6) Channel(7) ChannelHighlight(8)
                               GamemasterChannel(14)
   (nothing)              for: PrivateFrom(4) PrivateTo(5) NpcFrom(11)
                               GamemasterBroadcast(13) GamemasterPrivateFrom(15)
   -- the MessageRVRChannel (u32) and MonsterSay/Yell branches are unreachable at 1530
   anything else          -> the client THROWS "unknown message mode"
string text
```
So server byte **16** (GamemasterPrivateTo) and everything ≥17 that maps to a non-listed mode would abort the parse — worth being lenient in Lua (treat unknown modes as "no middle field" and log).

---

## 13. Channels

| Opcode | Name | Payload |
|---|---|---|
| `0xAB` (171) | Channels list (2999-3011) | `u8 count`, then `count × (u16 channelId, string name)` |
| `0xAC` (172) | OpenChannel (3013-3031) | `u16 channelId, string name`, then (GameChannelPlayerList ON) `u16 joined`, `joined × string`, `u16 invited`, `invited × string` |
| `0xAD` (173) | OpenPrivateChannel (3033-3037) | `string name` |
| `0xB2` (178) | OpenOwnChannel (3039-3056) | `u16 channelId, string name` + the same two player lists |
| `0xB3` (179) | CloseChannel (3058-3062) | `u16 channelId` |

---

## 14. Misc player packets

| Opcode | Name | Payload (1530) |
|---|---|---|
| `0x9F` (159) | PlayerDataBasic (2617-2649) | `u8 premium`, `u32 premiumExpiration` (GamePremiumExpiration), `u8 vocation`, `u8 preyEnabled` (GamePrey), `u16 spellCount`, `spellCount × u16 spellId` (GameUshortSpell), `u8 magicShieldActive` (cv≥1281) |
| `0x28` (40) | Death (1432-1450) | `u8 deathType` (GameDeathType; 0=regular,1=blessed), then **only if deathType==0** `u8 penalty` (percent), then `u8 canUseDeathRedemption` (cv≥1281) |
| `0xA4` (164) | SpellDelay (2917-2923) | `u16 spellId` (GameUshortSpell), `u32 delayMs` |
| `0xA5` (165) | SpellGroupDelay (2925-2931) | `u8 groupId`, `u32 delayMs` |
| `0xA6` (166) | MultiUseDelay (2933-2937) | `u32 delayMs` |
| `0xA7` (167) | PlayerModes (2898-2915) | GameTacticsWithoutFightMode ON ⇒ `u8 chaseMode, u8 safeMode, u8 pvpMode` (**no fightMode byte**) |
| `0xB5` (181) | CancelWalk (3167-3171) | `u8 direction` (Otc::Direction; server sends the direction the player should face) |
| `0xB6` (182) | WalkWait (3173-3177) | `u16 millis` → `LocalPlayer::lockWalk(millis)` |
| `0xAF` (175) | ExperienceTracker (5332-5336) — **cv ≥ 1200** re-uses the old RuleViolationRemove slot | `i64 rawExp, i64 finalExp` |
| `0xB1` (177) | Highscores — **cv ≥ 1310** re-uses RuleViolationLock | (long; not needed by bots) |
| `0xC1` (193) | MonkData (5359-5408) | `u8 subtype`: `0 HARMONY` → `u8 harmony`; `1 SERENE` → `u8 serene`; `2 VIRTUE` → `u8 count`, `count × u16 spellId` (ids 311/312 are always the *secondary* stance) |
| `0x5E` (94) | PassiveCooldown (5635-5648) | `u8 _, u8 type`; `type==0` → `u32 current, u32 max, u8 canDecay`; `type==1` → `u8, u8` |
| `0xA9` (169) | RestingAreaState (5706-5713) | `u8 zone, u8 state, string message` |
| `0xCC` (204) | UpdateImpactTracker (5715-5732) | `u8 analyzerType, u32 amount`; `type==1` → `u8 element`; `type==2` → `u8 element, string targetName` |
| `0x1D` (29) | server **Ping request** (with GameClientPing ON) | empty; client must reply |
| `0x1E` (30) | server **Pong** (reply to our ping) | empty |

### Ping semantics (protocolgameparse.cpp:117-127, game.cpp:248-269)
`GameClientPing` is ON at 1530, so the dispatcher inverts the classic mapping:
* opcode **0x1E (30)** → `parsePingBack` → latency sample (`m_ping = elapsed`), schedules the next outgoing ping.
* opcode **0x1D (29)** → `parsePing` → the client must immediately **send a pong**.
Outgoing: `sendPing` writes opcode **29** (`ClientPing`); `sendPingBack` writes opcode **28** (`ClientPingBackGunz`) because OS is 61 and cv≥1200 (protocolgamesend.cpp:269-286) instead of the stock 30.
`parseExtendedOpcode` with sub-opcode `2` is also routed to `parsePingBack` (3986-3998).

---

## 15. Containers & inventory

| Opcode | Name | Payload (1530) |
|---|---|---|
| `0x6E` (110) | OpenContainer (1612-1659) | `u8 containerId`, `Item containerItem`, `string name`, `u8 capacity`, `u8 hasParent`, `u8 showSearchIcon` (cv≥1281), `u8 isUnlocked`, `u8 hasPages`, `u16 containerSize`, `u16 firstIndex` (GameContainerPagination), `u8 itemCount`, `itemCount × Item`, then GameContainerFilter (ON): `u8 category`, `u8 categoriesSize`, `categoriesSize × (u8 id, string name)`; then cv≥1340 only: `u8 isMoveable, u8 isHolding` — **not read at 1530** |
| `0x6F` (111) | CloseContainer | `u8 containerId` |
| `0x70` (112) | ContainerAddItem (1667-1674) | `u8 containerId`, `u16 slot` (GameContainerPagination), `Item` |
| `0x71` (113) | ContainerUpdateItem (1676-1683) | `u8 containerId`, `u16 slot`, `Item` |
| `0x72` (114) | ContainerRemoveItem (1685-1703) | `u8 containerId`, `u16 slot`, `u16 lastItemId`; **if lastItemId ≠ 0** then the remaining `Item` attribute bytes for that id follow |
| `0x78` (120) | SetInventory (1813-1819) | `u8 slot`, `Item` |
| `0x79` (121) | DeleteInventory (1821-1825) | `u8 slot` |
| `0xF5` (245) | PlayerInventory / count cache (3910-3944) | `u16 size`, then `size × (u16 itemId, u8 attribute, packedCount)` where `packedCount` is `readPackedCount1500` because protocolVersion ≥ 1500. `attribute` is the tier when the item's ThingType has `classification > 0`, else ignored. |

`Otc::InventorySlot` (const.h:99-117): `1 head, 2 necklace, 3 backpack, 4 armor, 5 right, 6 left, 7 legs, 8 feet, 9 ring, 10 ammo, 11 purse, 12..15 ext1..4`.

`readPackedCount1500` (3895-3908):
```
b1 = u8
if b1 < 0x40 then return b1
elseif b1 < 0x80 then b2 = u8 ; return ((b1 - 0x40) << 8) | b2
else b2,b3,b4 = u8,u8,u8 ; return (b2<<16)|(b3<<8)|b4 end
```

### `Item` (getItem, protocolgameparse.cpp:4510-4698) — **GUNZ ORDER, load-bearing**
Because `g_game.getOs()` is 61 (in `[60,62]`), the gunz attribute order applies:
```
u16 id (unless already consumed as the discriminator)
if cv >= 1185 and (id == 3457 or id == 408) then RETURN (zero attribute bytes) end
-- (cv<1281 mark byte: absent at 1530)
if isStackable or isFluidContainer or isSplash then u8 count end    -- GameCountU16 is OFF -> u8
-- GameItemAnimationPhase is OFF at 1530 -> no phase byte
-- gunz order: counter, clock, [container block], tier, podium
if GameThingCounter and hasWearOut          then u32 charges ; u8 isBrandNew end
if GameThingClock   and (hasClockExpire|hasExpire|hasExpireStop) then u32 duration ; u8 isBrandNew end
if isContainer then                                   -- GameContainerTypes ON
    u8 containerType
    1 -> u32 lootFlags | 2 -> u32 ammoTotal | 3 -> u32 lootFlags, u32 obtainFlags
    4 -> (nothing)     | 8 -> u32 obtainFlags
    9 -> u32 lootFlags [, u32 obtainFlags if cv>=1332]
   11 -> u32 lootFlags, u32 ammoTotal [, u32 obtainFlags if cv>=1332]
    else -> nothing
end
if GameThingUpgradeClassification and classification>0 then u8 tier end
if GameThingPodium and isPodium then
    u16 looktype ; if ~=0 then u8 head,body,legs,feet,addons else u16 lookTypeEx end
    u16 lookmount ; if ~=0 then u8 head,body,legs,feet end
    u8 direction ; u8 visible
end
if GameWrapKit and isDecoKit then u16 end
-- GameItemShader / GameItemTooltipV8 OFF -> no trailing strings
```
**A Lua client must therefore carry an item-type table (ThingType flags: stackable, fluidContainer, splash, container, podium, decoKit, wearOut, clockExpire/expire/expireStop, classification) — otherwise item-bearing packets cannot be parsed at all.**

---

## 16. `0xFA` (250) ModalDialog — parseModalDialog (3947-3984)

```
u32 windowId
string title
string message
u8 buttonsCount ; buttonsCount × (string text, u8 buttonId)
u8 choicesCount ; choicesCount × (string text, u8 choiceId)
u8 escapeButton                 -- cv > 970 => escape FIRST
u8 enterButton
u8 priority
```

---

## 17. Walking — the state machine a Lua client must implement

### What the client sends
Single step, opcodes `ClientWalkNorth=101(0x65) East=102 South=103 West=104`, `NorthEast=106 SouthEast=107 SouthWest=108 NorthWest=109`, each **payload-less** (protocolgamesend.cpp:331-395). `ClientStop = 105 (0x69)` payload-less. Turn: `ClientTurnNorth=111(0x6F)`, East=112, South=113, West=114, payload-less.

`ClientAutoWalk = 100 (0x64)` (protocolgamesend.cpp:288-329): `u8 pathLength (≤127)`, then one byte per step using a **different encoding than `Otc::Direction`**:
```
E=1, NE=2, N=3, NW=4, W=5, SW=6, S=7, SE=8   (anything else -> 0)
```

### What the server sends when a walk is **accepted**
1. `0x6D` MoveCreature with `MappedThing{ oldPos, oldStackpos }` (or the 0xFFFF+creatureId form) and `Position newPos`.
2. Because the local player is always at the centre of the aware window, one or two map-shift packets follow to fill the newly exposed edge:
   * `0x65` MapTopRow (north), `0x66` MapRightRow (east), `0x67` MapBottomRow (south), `0x68` MapLeftRow (west) — **no position prefix** (`GameMapMovePosition` is OFF); the payload is just a tile-description strip.
   * On a floor change: `0xBE` FloorChangeUp / `0xBF` FloorChangeDown (also with no position prefix) plus their floor strips.
3. The client's own position is authoritatively taken from `0x6D` (`Map::addThing` → `Thing::setPosition` → `LocalPlayer::onPositionChange`). `Map::setCentralPosition` is only driven by `0x64/0x65..0x68/0xBE/0xBF` and, one dispatcher tick later, force-corrects the local player if it desynced (map.cpp:607-640).

### What the server sends when a walk is **refused**
* `0xB5` CancelWalk with **one byte: the direction the player should now face** (`Otc::Direction`, 0=N 1=E 2=S 3=W). This is the *facing* direction, not the rejected movement direction. `Game::processWalkCancel` → `LocalPlayer::cancelWalk(direction)` (game.cpp:592-595, localplayer.cpp:186-206).
* `0xB6` WalkWait with `u16 millis` → pure client-side walk lock (`lockWalk(millis)`), no cancellation.

### Prewalk state machine (localplayer.cpp + modules/game_walk/walk.lua)

State a Lua client must hold:
```
serverPos                -- last position confirmed by 0x6D (authoritative)
preWalks       = {}      -- FIFO deque of predicted positions
walkLockUntil  = 0       -- ms timestamp
waitingForServerWalk     -- bool, set when a step packet went out
lastWalkTime             -- ms, for the 1000 ms dropped-confirmation fallback
lastWalkDir, nextWalkDir -- queued step
speed, baseSpeed, groundSpeed(tile), speedA/B/C, serverBeat
```

**Issuing a step** (walk.lua:80-149 + `LocalPlayer::canWalk` localplayer.cpp:38-63):
1. reject if dead, or `now < walkLockUntil`.
2. if `waitingForServerWalk`: if `lastWalkTime + 1000 < now` clear the flag (dropped-confirmation fallback), else queue the direction in `nextWalkDir` and return.
3. if following → send `ClientStop` first; if auto-walking or server-walking → `ClientStop`, `lockWalk(stepDuration + 50)`, return.
4. `canWalk()` gate: `preWalks.size() > walkMaxSteps (default 1)` → false; else if `getPosition() ~= serverPos` → false; if already walking and pre-walking → false; finally require `walkTimer.elapsed >= getStepDuration()`.
5. `GameAllowPreWalk` is ON: if the destination tile is known and walkable, **push the predicted position onto `preWalks`** (this is what makes `getPosition()` return the predicted tile). If the tile is unknown/unwalkable and no floor change is possible, abort without sending.
6. send the direction opcode; set `waitingForServerWalk = true`, `lastWalkTime = now`.
7. Arm a "prewalk invalidation" timer of `min(max(stepDuration, ping) + 100, 1000)` ms; on expiry **clear `preWalks`** (localplayer.cpp:148-155). This is the safety net against a step the server silently drops.

**On `0x6D` for self** (`LocalPlayer::walk`, localplayer.cpp:66-78):
```
if preWalks is non-empty and newPos == preWalks.front() then
    preWalks:popFront()        -- prediction confirmed, nothing else changes
else
    cancel the invalidation timer ; preWalks:clear() ; serverWalk = true
    -- a real (unpredicted) server-driven move; animate from oldPos to newPos
end
serverPos = newPos
-- when the walk animation finishes: waitingForServerWalk = false; flush nextWalkDir
```
For a headless bot the animation is irrelevant: treat the arrival of `0x6D` as the confirmation, clear `waitingForServerWalk`, and immediately send `nextWalkDir` if queued (walk.lua:262-273 does this with a 50 ms delay when prewalk is on).

**On `0xB5` CancelWalk** (localplayer.cpp:186-206 + walk.lua:279-285):
```
if pre-walking then stopWalk() end     -- discard the prediction
force the invalidation timer to fire (clears preWalks)
lockWalk(250) then lockWalk(50) from Lua      -- effective: ~250 ms
retry auto-walk if one is in flight (up to 3 retries, 200/300/400 ms)
setDirection(cancelDirection)
waitingForServerWalk = false
```
Net: **position rolls back to `serverPos`**, facing is set to the byte in the packet, and stepping is blocked for ~250 ms.

**On teleport** (`0x64` FullMap, or a `0x6D` whose delta > 1 tile): clear `preWalks`, clear `waitingForServerWalk`, `lockWalk(walkTeleportDelay)` for ≥3-tile/≥2-floor jumps or `walkStairsDelay` otherwise (walk.lua:243-258).

### Step duration (`Creature::getStepDuration`, creature.cpp:1106-1158)
```
if speed < 1 then return 0 end
groundSpeed = tile(destination).groundSpeed or 150
if hasSpeedFormula() then                    -- GameNewSpeedLaw ON and speedA,B,C all != 0
    -- computed once in setSpeed (creature.cpp:964-971):
    --   s = speed * 2
    --   calculatedStepSpeed = (s > -speedB)
    --        and max(1, floor(speedA * log(s/2 + speedB) + speedC + 0.5)) or 1
    duration = 1000 * groundSpeed / calculatedStepSpeed
else
    duration = 1000 * groundSpeed / speed
end
duration = ceil(duration / serverBeat) * serverBeat        -- cv >= 860 ; serverBeat from 0x0A/0x17
if diagonal then duration = duration * 3 end               -- playerDiagonalWalkSpeed = 3
-- mehah patch: the client subtracts 10 ms from the final value (creature.cpp:1155-1157)
```
`speedA/speedB/speedC` are three `double`s (5 bytes each) in the **login/pending packet** (`0x0A` PendingGame or `0x17` LoginSuccess), `parseLogin` protocolgameparse.cpp:744-792:
```
u32 playerId ; u16 serverBeat
double speedA ; double speedB ; double speedC        -- GameNewSpeedLaw ON
-- GameDynamicBugReporter is ON at 1530 -> the canReportBugs u8 is NOT read
u8 canChangePvpFrame          -- cv >= 1054
u8 expertPvpMode              -- cv >= 1058
string storeImagesUrl ; u16 coinsPacketSize          -- GameIngameStore ON
u8 exivaEnabled               -- cv >= 1281   (the Tournament u8 is skipped: feature disabled at >=1314)
```
`serverBeat` defaults to 50 ms (game.h:533).

---

## 18. Outgoing-frame notes that affect this area

`Protocol::send` (framework/net/protocol.cpp:122-171), in order:
1. If XTEA is on **and OS ∈ [60,62]** → prepend a 4-byte compression header `[mode][0][0][0]` before the opcode. Omitting it shifts every gameplay packet by 4 bytes; login and ping still appear to work, so the failure is silent.
2. `clientVersion >= 1405` → `writePaddingAmount()` before encryption; `writeHeaderSize()` instead of `writeMessageSize()` afterwards.
3. XTEA encrypt.
4. `GameSequencedPackets` (ON at 1530) → `writeSequence(m_packetNumber++)` **instead of** the adler32 checksum.


## Pseudocode

-- =====================================================================
-- LuaJIT sketch: 1530 player/creature state parsing (readers + packets)
-- =====================================================================
local bit = require("bit")
local ffi = require("ffi")

-- ---------- feature table for 1530 (from features.lua) ----------------
local CV = 1530                          -- clientVersion == protocolVersion
local F = {
  DoubleHealth=true, DoubleFreeCapacity=true, DoubleExperience=true,
  LevelU16=true, LevelPercentU16=true, ExperienceBonus=true,
  Soul=true, PlayerStamina=true, SkillsBase=true, BaseSkillU16=true,
  DoubleSkills=true, PlayerRegenerationTime=true, OfflineTrainingTime=true,
  PlayerStateCounter=true, Concotions=true, VocationMonk=true,
  CharacterSkillStats=true, AdditionalSkills=false, ForgeSkillStats=false,
  LeechAmount=false, TotalCapacity=true,          -- suppressed by the >=1281 gate
  MessageStatements=true, MessageLevel=true, ChannelPlayerList=true,
  AttackSeq=true, UshortSpell=true, ContainerPagination=true,
  ContainerTypes=true, ContainerFilter=true, ThingMarks=true,
  CreatureIcons=true, CreatureEmblems=true, LooktypeU16=true,
  PlayerAddons=true, PlayerMounts=true, CountU16=false,
  ThingCounter=true, ThingClock=true, ThingUpgradeClassification=true,
  ThingPodium=true, ThingPodiumItemType=true, WrapKit=true,
  ItemShader=false, ItemTooltipV8=false, ItemAnimationPhase=false,
  WingsAurasEffectsShader=false, CreatureShader=false,
  CreatureAttachedEffect=false, CreaturePaperdoll=false,
  MapMovePosition=false, NewSpeedLaw=true, ClientPing=true,
  DeathType=true, PenalityOnDeath=true, PremiumExpiration=true,
  Prey=true, AllowPreWalk=true, SequencedPackets=true,
  DynamicBugReporter=true, TacticsWithoutFightMode=true,
  TileAddThingWithStackpos=true, FormatCreatureName=true,
}
local IS_GUNZ_OS = true    -- g_game.getOs() == 61, in [60,62]

-- ---------- message reader ------------------------------------------
local M = {}; M.__index = M
function M.new(buf) return setmetatable({b=buf, p=1}, M) end
function M:u8()  local v=self.b:byte(self.p); self.p=self.p+1; return v end
function M:u16() local a,b=self.b:byte(self.p,self.p+1); self.p=self.p+2
                 return a + b*256 end
function M:u32() local a,b,c,d=self.b:byte(self.p,self.p+3); self.p=self.p+4
                 return a + b*256 + c*65536 + d*16777216 end
function M:u64() -- keep exact: return an ffi uint64_t
  local lo, hi = self:u32(), self:u32()
  return ffi.new("uint64_t", hi) * 4294967296ULL + ffi.new("uint64_t", lo) end
function M:i64() local v = self:u64(); return ffi.cast("int64_t", v) end
function M:str() local n=self:u16(); local s=self.b:sub(self.p,self.p+n-1)
                 self.p=self.p+n; return s end
function M:dbl() local prec=self:u8(); local raw=self:u32()
                 return (raw - 2147483647) / (10 ^ prec) end
function M:pos() return { x=self:u16(), y=self:u16(), z=self:u8() } end

-- ---------- 0xA0 PlayerData (60 bytes) --------------------------------
local function parsePlayerStats(m, S)
  S.health      = m:u32()
  S.maxHealth   = m:u32()
  S.freeCapacity= m:u32() / 100          -- cv > 772
  -- NO totalCapacity  (clientVersion >= 1281)
  S.experience  = m:u64()
  S.level       = m:u16()
  S.levelPercentCenti = m:u16()          -- GameLevelPercentU16 -> /100 to display
  S.xpBase      = m:u16()                -- no voucher field at >=1281
  S.xpGrinding  = m:u16()
  S.xpStoreBoost= m:u16()
  S.xpHunting   = m:u16()
  S.mana        = m:u32()
  S.maxMana     = m:u32()
  -- NO magicLevel here (clientVersion >= 1281)
  S.soul        = m:u8()
  S.stamina     = m:u16()
  S.baseSpeed   = m:u16()
  S.regeneration= m:u16()
  S.offlineTraining = m:u16()
  S.storeExpBoostTime = m:u16()          -- cv >= 1097
  S.canBuyXpBoost     = m:u8()
  S.manaShield    = m:u32()              -- cv >= 1281 && DoubleHealth
  S.maxManaShield = m:u32()
  S.hpPercent = S.maxHealth > 0 and (S.health * 100 / S.maxHealth) or 0
  S.mpPercent = S.maxMana   > 0 and (S.mana   * 100 / S.maxMana)   or 0
end

-- ---------- 0xA1 PlayerSkills ----------------------------------------
local SKILL_NAMES = {"fist","club","sword","axe","distance","shielding","fishing"}
local function parsePlayerSkills(m, S)
  S.magicLevel      = m:u16()
  S.baseMagicLevel  = m:u16()
  m:u16()                                 -- loyalty magic level, discarded
  S.magicLevelPercent = m:u16() / 100
  S.skills = {}
  for i = 1, 7 do
    local lv, base = m:u16(), m:u16()
    m:u16()                               -- loyalty, discarded
    S.skills[SKILL_NAMES[i]] = { level=lv, base=base, percent=m:u16()/100 }
  end
  m:u8()                                  -- GameConcotions
  -- GameCharacterSkillStats tail
  S.totalCapacity = m:u32() / 100
  S.baseCapacity  = m:u32() / 100
  S.flatDamageHealing = m:u16()
  S.attackValue   = m:u16()
  S.attackElement = m:u8()
  S.convertedDamage  = m:dbl()
  S.convertedElement = m:u8()
  S.lifeLeech, S.manaLeech = m:dbl(), m:dbl()
  S.critChance, S.critDamage, S.onslaught = m:dbl(), m:dbl(), m:dbl()
  S.defense, S.armor = m:u16(), m:u16()
  S.mantra = m:u16()                      -- GameVocationMonk
  S.mitigation, S.dodge = m:dbl(), m:dbl()
  S.damageReflection = m:u16()
  S.absorb = {}
  for _ = 1, m:u8() do local t = m:u8(); S.absorb[t] = m:dbl() end
  S.momentum, S.transcendence, S.amplification = m:dbl(), m:dbl(), m:dbl()
end

-- ---------- 0xA2 PlayerState -----------------------------------------
local ST = { Poison=0x1, Burn=0x2, Energy=0x4, Drunk=0x8, ManaShield=0x10,
             Paralyze=0x20, Haste=0x40, Swords=0x80, Drowning=0x100,
             Freezing=0x200, Dazzled=0x400, Cursed=0x800, PartyBuff=0x1000,
             PzBlock=0x2000, Pz=0x4000, Bleeding=0x8000, Hungry=0x10000,
             LesserHex=0x10000, IntenseHex=0x20000, GreaterHex=0x40000,
             Rooted=0x80000, Feared=0x100000, NewManaShield=0x4000000,
             Agony=0x8000000, Powerless=0x10000000, Mentored=0x20000000 }
local function parsePlayerState(m, S)
  S.statesLo = m:u32()                    -- clientVersion >= 1405 => u64
  S.statesHi = m:u32()
  m:u8()                                  -- GamePlayerStateCounter, discarded
end
local function hasState(S, mask) return bit.band(S.statesLo, mask) ~= 0 end

-- ---------- 0xA3 ClearTarget -----------------------------------------
local function parseCancelAttack(m, S)
  local seq = m:u32()                     -- GameAttackSeq
  m:u32()                                 -- cv >= 1530, discarded
  if S.attackSeq == 0 or S.attackSeq == seq then S.attacking = nil end
end

-- ---------- shared sub-readers ---------------------------------------
local function readOutfit(m, parseMount)
  local o = {}
  o.lookType = m:u16()
  if o.lookType ~= 0 then
    o.head, o.body, o.legs, o.feet = m:u8(), m:u8(), m:u8(), m:u8()
    o.addons = m:u8()
  else
    o.lookTypeEx = m:u16()
  end
  if parseMount ~= false then             -- GamePlayerMounts
    o.mount = m:u16()
    if o.mount ~= 0 then m:u8(); m:u8(); m:u8(); m:u8() end   -- cv >= 1281
  end
  return o                                -- no wings/auras/shader at 1530
end

local function readIconList(m)            -- 5-byte entries at 1530
  local n, out = m:u8(), {}
  for i = 1, n do
    local icon, cat, cnt = m:u8(), m:u8(), m:u16()
    m:u8()                                -- cv >= 1530 trailer, discarded
    out[i] = { icon=icon, category=cat, count=cnt }
  end
  return out
end

local function readMappedThing(m)
  local x = m:u16()
  if x ~= 0xFFFF then
    return { kind="tile", x=x, y=m:u16(), z=m:u8(), stackpos=m:u8() }
  end
  return { kind="creature", id=m:u32() }
end

local function readCreature(m, map, localId, discriminator)
  local t = discriminator or m:u16()      -- 97 unknown / 98 known / 99 turn
  local c
  if t == 99 then
    local id = m:u32(); c = map.creatures[id] or { id=id }
    c.direction = m:u8()
    c.passable  = (m:u8() == 0)           -- cv >= 953
    return c
  end
  if t == 98 then
    local id = m:u32(); c = map.creatures[id] or { id=id }
  else                                    -- 97
    local removeId, id = m:u32(), m:u32()
    if removeId ~= id then map.creatures[removeId] = nil end
    c = map.creatures[id] or { id=id }
    c.creatureType = m:u8()               -- cv >= 910
    if c.creatureType == 3 then           -- summonOwn
      c.masterId = m:u32()                -- cv >= 1281
      if c.masterId ~= localId then c.creatureType = 4 end
    end
    c.name = m:str()
    map.creatures[id] = c
  end
  c.healthPercent = m:u8()
  c.direction     = m:u8()
  c.outfit        = readOutfit(m, true)
  c.lightIntensity, c.lightColor = m:u8(), m:u8()
  c.speed         = m:u16()
  c.icons         = readIconList(m)                    -- cv >= 1281, REPLACE
  local extra     = readIconList(m)                    -- cv >= 1530, MERGE
  for _, e in ipairs(extra) do                         -- greater-count merge
    local found
    for _, cur in ipairs(c.icons) do
      if cur.icon == e.icon and cur.category == e.category then
        if e.count > cur.count then cur.count = e.count end; found = true; break
      end
    end
    if not found then c.icons[#c.icons+1] = e end
  end
  c.skull, c.shield = m:u8(), m:u8()
  if t == 97 then c.emblem = m:u8() end                -- unknown-only
  local ctype = m:u8()                                 -- GameThingMarks
  if ctype == 3 then
    c.masterId = m:u32(); if c.masterId ~= localId then ctype = 4 end
  elseif ctype == 0 then
    c.vocation = m:u8()                                -- cv >= 1281
  end
  if ctype > 0 then c.creatureType = ctype end
  c.icon = m:u8()                                      -- GameCreatureIcons
  c.mark = m:u8()                                      -- 0xFF = clear
  m:u8()                                               -- inspection type, cv>=1281
  c.passable = (m:u8() == 0)                           -- cv >= 854
  return c
end

-- ---------- item (GUNZ attribute order) -------------------------------
-- tt = thingtype flags table looked up by item id
local function readItem(m, tt, id)
  id = id or m:u16()
  local T = tt[id] or {}
  local it = { id = id }
  if CV >= 1185 and (id == 3457 or id == 408) then return it end
  if T.stackable or T.fluidContainer or T.splash then
    it.count = m:u8()                       -- GameCountU16 is OFF
  end
  -- gunz order: counter, clock, container, tier, podium
  if T.wearOut then it.charges = m:u32(); m:u8() end
  if T.clockExpire or T.expire or T.expireStop then it.duration = m:u32(); m:u8() end
  if T.container then                       -- GameContainerTypes ON
    local ct = m:u8()
    if     ct == 1 then m:u32()
    elseif ct == 2 then m:u32()
    elseif ct == 3 then m:u32(); m:u32()
    elseif ct == 8 then m:u32()
    elseif ct == 9 then m:u32(); if CV >= 1332 then m:u32() end
    elseif ct == 11 then m:u32(); m:u32(); if CV >= 1332 then m:u32() end
    end                                     -- ct == 4 and default: nothing
  end
  if (T.classification or 0) > 0 then it.tier = m:u8() end
  if T.podium then
    local lt = m:u16()
    if lt ~= 0 then m:u8();m:u8();m:u8();m:u8();m:u8() else m:u16() end
    if m:u16() ~= 0 then m:u8();m:u8();m:u8();m:u8() end
    m:u8(); m:u8()
  end
  if T.decoKit then m:u16() end
  return it                                 -- no shader/tooltip strings at 1530
end

-- ---------- message-mode table ---------------------------------------
local MODE = { [0]="none",[1]="say",[2]="whisper",[3]="yell",[4]="privateFrom",
  [5]="privateTo",[6]="channelManagement",[7]="channel",[8]="channelHighlight",
  [9]="spell",[10]="npcFromStartBlock",[11]="npcFrom",[12]="npcTo",
  [13]="gmBroadcast",[14]="gmChannel",[15]="gmPrivateFrom",[16]="gmPrivateTo",
  [17]="login",[18]="warning",[19]="game",[20]="gameHighlight",[21]="failure",
  [22]="look",[23]="damageDealt",[24]="damageReceived",[25]="heal",[26]="exp",
  [27]="damageOthers",[28]="healOthers",[29]="expOthers",[30]="status",
  [31]="loot",[32]="tradeNpc",[33]="guild",[34]="partyManagement",[35]="party",
  [36]="barkLow",[37]="barkLoud",[38]="report",[39]="hotkeyUse",
  [40]="tutorialHint",[41]="thankyou",[42]="market",[43]="mana",
  [44]="beyondLast",[48]="attention",[49]="boostedCreature",
  [50]="offlineTraining",[51]="transaction",[52]="potion" }

local TALK_POS  = { [1]=1,[2]=1,[3]=1,[9]=1,[10]=1,[12]=1,[36]=1,[37]=1,[52]=1 }
local TALK_CHAN = { [6]=1,[7]=1,[8]=1,[14]=1 }

local function parseTalk(m)
  local t = {}
  t.statementId = m:u32()                   -- GameMessageStatements
  t.name = m:str()
  if t.statementId > 0 then m:u8() end      -- cv >= 1281 suffix
  t.level = m:u16()                         -- GameMessageLevel
  local code = m:u8(); t.mode = MODE[code] or ("unknown"..code)
  if TALK_POS[code]  then t.pos = m:pos()
  elseif TALK_CHAN[code] then t.channelId = m:u16() end
  t.text = m:str()
  return t
end

local function parseTextMessage(m)
  local code = m:u8(); local r = { code = code, mode = MODE[code] }
  if code == 6 or code == 33 or code == 34 or code == 35 then
    r.channelId = m:u16(); r.text = m:str()
  elseif code == 23 or code == 24 or code == 27 then
    r.pos = m:pos()
    r.physValue, r.physColor   = m:u32(), m:u8()
    r.magicValue, r.magicColor = m:u32(), m:u8()
    r.text = m:str()
  elseif code == 25 or code == 43 or code == 28 then
    r.pos = m:pos(); r.value = m:u32(); r.color = m:u8(); r.text = m:str()
  elseif code == 26 or code == 29 then
    r.pos = m:pos(); r.value = m:u64()      -- cv >= 1332
    r.color = m:u8(); r.text = m:str()
  else
    r.text = m:str()
  end
  -- PITFALL: the C++ client re-reads a string when the first one was "".
  -- Do NOT replicate that; the server writes exactly one string.
  return r
end

-- ---------- opcode dispatch (state-relevant subset) -------------------
local H = {}
H[0xA0]=parsePlayerStats  H[0xA1]=parsePlayerSkills
H[0xA2]=parsePlayerState  H[0xA3]=parseCancelAttack
H[0x8C]=function(m,S) local id,hp=m:u32(),m:u8()
                      local c=S.map.creatures[id]; if c then c.healthPercent=hp end end
H[0x8D]=function(m,S) local id=m:u32(); local i,c=m:u8(),m:u8()
                      local cr=S.map.creatures[id]
                      if cr then cr.lightIntensity,cr.lightColor=i,c end end
H[0x8E]=function(m,S) local id=m:u32(); local o=readOutfit(m,true)
                      local c=S.map.creatures[id]; if c then c.outfit=o end end
H[0x8F]=function(m,S) local id=m:u32(); local bs,sp=m:u16(),m:u16()  -- cv>=1059
                      local c=S.map.creatures[id]
                      if c then c.speed=sp; if bs~=0 then c.baseSpeed=bs end end end
H[0x90]=function(m,S) local id,v=m:u32(),m:u8()
                      local c=S.map.creatures[id]; if c then c.skull=v end end
H[0x91]=function(m,S) local id,v=m:u32(),m:u8()
                      local c=S.map.creatures[id]; if c then c.shield=v end end
H[0x92]=function(m,S) local id,v=m:u32(),m:u8()
                      local c=S.map.creatures[id]; if c then c.passable=(v==0) end end
H[0x93]=function(m,S) local id,ty,col=m:u32(),m:u8(),m:u8()
                      local c=S.map.creatures[id]
                      if c then c.squareType, c.squareColor = ty, col end end
H[0x94]=function(m,S) m:u32(); m:u16() end                       -- helpers
H[0x95]=function(m,S) local id,v=m:u32(),m:u8()
                      local c=S.map.creatures[id]; if c then c.creatureType=v end end
H[0x8B]=function(m,S) local id,ty=m:u32(),m:u8()
  if ty==0 then readCreature(m,S.map,S.localId)
  elseif ty==11 or ty==12 or ty==13 then
    local v=m:u8(); local c=S.map.creatures[id]; if c then c.vocation=v end
  elseif ty==14 then
    local ic=readIconList(m); local c=S.map.creatures[id]; if c then c.icons=ic end
  end end
H[0x6D]=function(m,S) local from=readMappedThing(m); local to=m:pos()
                      S:onCreatureMove(from, to) end
H[0xA4]=function(m,S) S.spellCooldown[m:u16()] = m:u32() end     -- UshortSpell
H[0xA5]=function(m,S) S.groupCooldown[m:u8()]  = m:u32() end
H[0xA6]=function(m,S) S.multiUseCooldown       = m:u32() end
H[0xB5]=function(m,S) S:onWalkCancel(m:u8()) end                 -- direction byte
H[0xB6]=function(m,S) S:lockWalk(m:u16()) end
H[0x28]=function(m,S) local dt=m:u8()                            -- DeathType ON
                      local pen=100; if dt==0 then pen=m:u8() end
                      m:u8(); S:onDeath(dt,pen) end
H[0x1D]=function(m,S) S:sendPingBack() end                       -- ClientPing feature ON
H[0x1E]=function(m,S) S:onPongReceived() end
H[0x78]=function(m,S) local slot=m:u8(); S.inventory[slot]=readItem(m,S.tt) end
H[0x79]=function(m,S) S.inventory[m:u8()]=nil end
H[0xAF]=function(m,S) S.expRaw, S.expFinal = m:i64(), m:i64() end -- cv >= 1200
H[0xC1]=function(m,S) local sub=m:u8()
  if sub==0 then S.harmony=m:u8()
  elseif sub==1 then S.serene=(m:u8()~=0)
  elseif sub==2 then
    local n=m:u8(); S.virtues={}; S.stance, S.secondaryStance = 0, 0
    for i=1,n do local sp=m:u16(); S.virtues[i]=sp
      if sp==311 or sp==312 then S.secondaryStance=sp
      elseif S.stance==0 then S.stance=sp
      elseif S.secondaryStance==0 then S.secondaryStance=sp end
    end
  end end

-- =====================================================================
-- Walk state machine
-- =====================================================================
local Walk = {}
Walk.__index = Walk
local WALK_OPCODE = { [0]=101, [1]=102, [2]=103, [3]=104,   -- N E S W
                      [4]=106, [5]=107, [6]=108, [7]=109 }  -- NE SE SW NW
local AUTOWALK_BYTE = { [1]=1, [4]=2, [0]=3, [7]=4, [3]=5, [6]=6, [2]=7, [5]=8 }
local DELTA = { [0]={0,-1},[1]={1,0},[2]={0,1},[3]={-1,0},
                [4]={1,-1},[5]={1,1},[6]={-1,1},[7]={-1,-1} }

function Walk.new(S) return setmetatable({ S=S, preWalks={},
  walkLockUntil=0, waiting=false, lastWalkTime=0, nextDir=nil,
  invalidateAt=nil, maxSteps=1 }, Walk) end

function Walk:pos()                      -- predicted position
  return #self.preWalks > 0 and self.preWalks[#self.preWalks] or self.S.serverPos end

function Walk:lock(ms) local t=now()+ms
  if t > self.walkLockUntil then self.walkLockUntil = t end end

function Walk:stepDuration(dir)
  local S = self.S
  if (S.speed or 0) < 1 then return 0 end
  local gs = S:groundSpeedAt(self:pos()) or 150
  local d
  if S.speedA ~= 0 and S.speedB ~= 0 and S.speedC ~= 0 then
    local s = S.speed * 2
    local css = (s > -S.speedB)
      and math.max(1, math.floor(S.speedA*math.log(s/2 + S.speedB) + S.speedC + 0.5))
      or 1
    d = 1000 * gs / css
  else
    d = 1000 * gs / S.speed
  end
  local beat = S.serverBeat or 50
  d = math.ceil(d / beat) * beat                        -- cv >= 860
  if dir and dir >= 4 then d = d * 3 end                -- diagonal factor 3
  return d > 10 and d - 10 or d
end

function Walk:tick()
  if self.invalidateAt and now() >= self.invalidateAt then
    self.preWalks = {}; self.invalidateAt = nil          -- prediction expired
  end
  if self.waiting and self.lastWalkTime + 1000 < now() then
    self.waiting = false                                 -- dropped-confirmation fallback
  end
  if self.nextDir and not self.waiting then
    local d = self.nextDir; self.nextDir = nil; self:step(d)
  end
end

function Walk:step(dir)
  local S = self.S
  if S.dead or now() < self.walkLockUntil then return false end
  if self.waiting then self.nextDir = dir; return false end
  if #self.preWalks > self.maxSteps then return false end
  if #self.preWalks == 0 and not samePos(self:pos(), S.serverPos) then return false end
  if now() - (self.lastStepAt or 0) < self:stepDuration(dir) then
    self.nextDir = dir; return false end

  if F.AllowPreWalk then
    local d = DELTA[dir]
    local to = { x=self:pos().x+d[1], y=self:pos().y+d[2], z=self:pos().z }
    local tile = S:tileAt(to)
    if tile and tile.walkable then
      self.preWalks[#self.preWalks+1] = to
      self.invalidateAt = now() +
        math.min(math.max(self:stepDuration(dir), S.ping or 0) + 100, 1000)
    elseif not tile then
      return false                                       -- no map data: do not step
    end
  end
  S:sendOpcode(WALK_OPCODE[dir])                         -- payload-less
  self.waiting, self.lastWalkTime, self.lastStepAt = true, now(), now()
  return true
end

function Walk:autoWalk(dirs)                             -- 0x64, <=127 steps
  local out = { string.char(100), string.char(#dirs) }
  for i, d in ipairs(dirs) do out[#out+1] = string.char(AUTOWALK_BYTE[d] or 0) end
  self.S:sendRaw(table.concat(out))
end

-- called from H[0x6D] when the moved creature is the local player
function Walk:onServerMove(newPos)
  local front = self.preWalks[1]
  if front and samePos(front, newPos) then
    table.remove(self.preWalks, 1)                       -- prediction confirmed
  else
    self.preWalks = {}; self.invalidateAt = nil          -- server-driven move
  end
  self.S.serverPos = newPos
  self.waiting = false
  if self.nextDir then
    local d = self.nextDir; self.nextDir = nil
    schedule(50, function() self:step(d) end)
  end
end

-- called from H[0xB5]
function Walk:onCancel(direction)
  self.preWalks = {}; self.invalidateAt = nil
  self.S.direction = direction                           -- facing, not movement
  self:lock(250)
  self.waiting = false
end

-- called on 0x64 FullMap / any >1-tile 0x6D delta
function Walk:onTeleport(newPos, oldPos)
  self.preWalks = {}; self.invalidateAt = nil; self.waiting = false
  self.S.serverPos = newPos
  local dx,dy,dz = math.abs(newPos.x-oldPos.x), math.abs(newPos.y-oldPos.y),
                   math.abs(newPos.z-oldPos.z)
  self:lock((dx>=3 or dy>=3 or dz>=2) and 1000 or 200)   -- teleport vs stairs delay
end


## Evidence
- D:/Claude/otclient_mehah1530/otclient/modules/game_features/features.lua:1-260 — the ONLY source of feature flags for 1530; setClientVersion just fires onClientVersionChange. 1530 arm sets GUNZODUS_RSA + setCustomOs(61)
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:1727-1743 — Game::setClientVersion resets m_features and calls the Lua hook; no C++-side feature defaults
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2651-2740 — parsePlayerStats; 2653-2656 health/maxHealth u32 via GameDoubleHealth; 2657-2661 freeCapacity u32 then /=100; 2663-2666 totalCapacity skipped at cv>=1281; 2668 experience u64; 2669-2670 level u16 + levelPercent u16
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2672-2690 — xp-rate block: baseXpGain u16, voucher u16 ONLY at cv<1281, grinding u16, storeBoost u16, huntingBoost u16
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2697-2705 — magicLevel/baseMagicLevel/magicLevelPercent are gated clientVersion<1281, i.e. ABSENT from the 1530 stats packet
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2713-2726 — cv>=1097 storeExpBoostTime u16 + u8; cv>=1281 manaShield/maxManaShield u32 each (GameDoubleHealth)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2742-2777 — parsePlayerSkills magic block (u16 x4, percent/100) and the 7-skill loop (level u16, base u16, loyalty u16 discarded, percent u16/100)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2779-2815 — GameAdditionalSkills and GameForgeSkillStats blocks; both features are DISABLED at >=1410 so neither is on the wire at 1530
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2817-2870 — GameCharacterSkillStats tail: capacity/baseCapacity u32 /100, flat bonus, attack, doubles, mantra u16 under GameVocationMonk, absorb map, forge bonuses
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2872-2885 — parsePlayerState: 'states = clientVersion >= 1405 ? msg->getU64() : msg->getU32()' plus a u8 icons counter under GamePlayerStateCounter — so 9 bytes at 1530
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2887-2896 — parsePlayerCancelAttack: u32 seq (GameAttackSeq) + an extra u32 discarded at clientVersion>=1530
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2898-2915 — parsePlayerModes: GameTacticsWithoutFightMode drops the fightMode byte at 1530
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2917-2937 — spell cooldown (u16 id via GameUshortSpell + u32), group cooldown (u8 + u32), multi-use (u32)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2939-2997 — parseTalk: u32 statement, string name, u8 suffix when statement>0 and cv>=1281, u16 level, u8 mode, mode-dependent pos/channelId, string text; unknown mode throws
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:3084-3165 — parseTextMessage: per-mode extras (channelId; pos+2x(u32,u8); pos+u32+u8; pos+u64(cv>=1332)+u8), then the 'if text.empty() read another string' fallback
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:3167-3177 — parseCancelWalk (single u8 direction) and parseWalkWait (u16 millis -> lockWalk)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2459-2562 — parseCreatureHealth/Light/Outfit/Speed/Skulls/Shields/Unpass, all u32 id + fixed tail; speed has a u16 baseSpeed prefix at cv>=1059
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2434-2457 — parseCreatureData: u32 id, u8 type; 0=full creature, 11/12/13=u8 vocation, 14=icon list
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2358-2410 — addCreatureIcon: entries are 5 bytes at cv>=1530 (extra discarded trailer); replace vs greater-count merge semantics
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4248-4508 — getCreature: full field order incl. the SECOND merged icon list added only at cv>=1530 (line 4374-4376)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4139-4203 — getOutfit: lookType u16, colours+addons, lookTypeEx, mount u16 (+4 colour bytes at cv>=1281); wings/auras block gated on a feature that is OFF
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4220-4246 — getMappedThing: u16 x, and if x!=0xFFFF then y/z/stackpos else u32 creatureId
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4510-4698 — getItem: the gunz-OS attribute ordering (counter, clock, container, tier, podium) and the id==3457/408 short-circuit at cv>=1185
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4700-4707 — getPosition = u16 x, u16 y, u8 z
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1591-1610 — parseCreatureMove = MappedThing + Position; calls allowAppearWalk so the move animates as a walk
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1612-1703 — container open/close/add/update/remove; note GameContainerFilter block and the cv>=1340 tail that 1530 does NOT read
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1813-1825 — parseAddInventoryItem (u8 slot + Item) / parseRemoveInventoryItem (u8 slot)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1432-1450 — parseDeath: deathType u8, penalty u8 only when deathType==0, plus a cv>=1281 death-redemption bool
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:3895-3908 — readPackedCount1500 variable-length count used by parsePlayerInventory at protocolVersion>=1500
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:3947-3984 — parseModalDialog; escape button is read BEFORE enter at cv>970
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4015-4066 — parseCreaturesMark (squareType/squareColor) and parseCreatureType
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:744-792 — parseLogin: u32 playerId, u16 serverBeat, three doubles speedA/B/C (GameNewSpeedLaw), and GameDynamicBugReporter suppressing the canReportBugs byte
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:117-127 — ping dispatch: with GameClientPing ON, opcode 30 is the pong and opcode 29 is the server's ping request
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:425-441 — opcode 175 is ExperienceTracker at cv>=1200 and 177 is Highscores at cv>=1310, overriding the legacy RuleViolation slots
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:7501-7513 — parseFeatures (opcode 67): u16 count then (u8 featureId, u8 enabled) pairs; server can flip any flag at runtime
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolcodes.cpp:29-88 — buildMessageModesMap; the >=1055 branch is the one in force at 1530 (MonsterSay/Yell and RVR modes are absent)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolcodes.cpp:227-233 — translateMessageModeFromServer does a reverse value lookup; unmapped bytes become MessageInvalid(255)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolcodes.h:45-254 — GameServerOpcodes enum (PlayerData=160, PlayerSkills=161, PlayerState=162, ClearTarget=163, Talk=170, TextMessage=180, CancelWalk=181, WalkWait=182, CreatureHealth=140 …)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolcodes.h:257-345 — ClientOpcodes: AutoWalk=100, WalkNorth=101..NorthWest=109, Stop=105, TurnNorth=111, Attack=161, Follow=162, PingBackGunz=28
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:136-169 — Otc::Skill (Fist..Fishing = 0..6, LastSkill=17) and Otc::Direction (0 N,1 E,2 S,3 W,4 NE,5 SE,6 SW,7 NW)
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:232-298 — PlayerSkulls, PlayerShields, PlayerEmblems and the PlayerStates bitmask (uint64_t base type)
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:300-365 — Otc::MessageMode enum values (client-side ids, distinct from the wire bytes)
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:540-677 — GameFeature enum ids, needed to interpret the runtime parseFeatures packet
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:29-40 — CLIENTOS_GUNZ_LINUX/WINDOWS/MAC = 60/61/62; the gunz behaviour switches key on this range
- D:/Claude/otclient_mehah1530/otclient/modules/gamelib/player.lua:3-38 — the extended PlayerStates bit list actually used by the UI (hexes, rooted, feared, NewManaShield=0x4000000, Agony, Powerless, Mentored)
- D:/Claude/otclient_mehah1530/otclient/src/client/localplayer.cpp:33-63 — lockWalk / canWalk: walkMaxSteps gate, position==serverPosition gate, stepDuration gate
- D:/Claude/otclient_mehah1530/otclient/src/client/localplayer.cpp:66-78 — LocalPlayer::walk pops the front pre-walk when the server-confirmed position matches, otherwise clears the queue and marks serverWalk
- D:/Claude/otclient_mehah1530/otclient/src/client/localplayer.cpp:115-133 — LocalPlayer::preWalk pushes the predicted position (and the leadingEdgeLoaded map-data gate at 89-113)
- D:/Claude/otclient_mehah1530/otclient/src/client/localplayer.cpp:148-155 — registerAdjustInvalidPosEvent: clears preWalks after min(max(stepDuration, ping)+100, 1000) ms
- D:/Claude/otclient_mehah1530/otclient/src/client/localplayer.cpp:186-206 — cancelWalk: stopWalk, force the invalidation event, lockWalk(250), retry autowalk, setDirection(cancelDirection)
- D:/Claude/otclient_mehah1530/otclient/src/client/localplayer.cpp:425-428 — getLevelPercent divides m_levelPercent by 100 when GameLevelPercentU16 (i.e. wire value is centipercent)
- D:/Claude/otclient_mehah1530/otclient/src/client/creature.cpp:854-885 — setHealthPercent: colour thresholds and onDeath() when the percent hits 0
- D:/Claude/otclient_mehah1530/otclient/src/client/creature.cpp:956-981 — setSpeed caches calculatedStepSpeed = max(1, floor(speedA*log(speed + speedB) + speedC + 0.5)) using speed*2
- D:/Claude/otclient_mehah1530/otclient/src/client/creature.cpp:1104-1158 — getStepDuration: 1000*groundSpeed/step-speed, rounded up to serverBeat at cv>=860, x3 for diagonals, minus the 10 ms mehah correction
- D:/Claude/otclient_mehah1530/otclient/src/client/creature.cpp:606-637 — onAppear decides walk vs teleport: adjacent old/new position + allowAppearWalk means walk, otherwise disappear+appear
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:585-595 — processAttackCancel (seq==0 || seq==m_seq) and processWalkCancel -> LocalPlayer::cancelWalk
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:248-269 — processPing sends a pong immediately; processPingBack records latency and schedules the next ping
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:671-712 — Game::walk/autoWalk/forceWalk; the 127-step autowalk cap and the follow-cancel rule
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:269-286 — sendPingBack uses opcode 28 (ClientPingBackGunz) for OS 60-62 at cv>=1200 instead of 30
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:288-329 — sendAutoWalk direction encoding E=1 NE=2 N=3 NW=4 W=5 SW=6 S=7 SE=8 (NOT Otc::Direction)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:331-411 — the eight payload-less walk opcodes, sendStop, and the four turn opcodes
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:822-841 — sendAttack/sendFollow: u32 creatureId + u32 seq under GameAttackSeq
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:122-171 — outgoing pipeline: gunz compression header when XTEA is on, cv>=1405 padding+header size, sequence dword instead of checksum under GameSequencedPackets
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/inputmessage.cpp:52-106 — little-endian readers; getString = u16 length + bytes; getDouble = u8 precision + u32, value = (raw - INT_MAX)/10^precision
- D:/Claude/otclient_mehah1530/otclient/modules/game_walk/walk.lua:80-149 — the outgoing-step gate: walk lock, waitingForServerWalk with a 1000 ms fallback, stop-on-autowalk, preWalk then g_game.walk
- D:/Claude/otclient_mehah1530/otclient/modules/game_walk/walk.lua:243-285 — onTeleport (clears the pending flag, applies teleport/stairs lock), onWalkFinish (clears the flag, flushes nextWalkDir after 50 ms), onCancelWalk (lockWalk(50) + clears the flag)
- D:/Claude/otclient_mehah1530/otclient/src/client/map.cpp:607-640 — setCentralPosition force-corrects the local player one dispatcher tick later if it is not on the central tile
- D:/Claude/otclient_mehah1530/otclient/src/client/gameconfig.h:97-125 — spriteSize 32, forceNewWalkingFormula true, player/creature diagonal walk speed 3
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:5359-5408 — parseMonkData (0xC1): subtype 0 harmony u8, 1 serene u8, 2 virtue list (u8 count + u16 spell ids; 311/312 always secondary stance)

## Pitfalls
- parsePlayerState is u64 at 1530, not u32. The gate is clientVersion>=1405 (protocolgameparse.cpp:2875) and GamePlayerStateCounter adds a trailing u8. Reading 4+1 bytes desyncs the whole rest of the TCP frame.
- levelPercent is CENTIPERCENT at 1530 (GameLevelPercentU16, >=1520) and is u16 — not the classic u8 0..100. Divide by 100 for display. The same centipercent convention applies to magicLevelPercent and every skill percent in the skills packet.
- freeCapacity is u32 on the wire and the client divides by 100. totalCapacity and baseCapacity are NOT in the stats packet at 1530 (suppressed by the clientVersion<1281 gate) — they arrive in the SKILLS packet, also /100.
- magicLevel/baseMagicLevel/magicLevelPercent are absent from the 1530 stats packet; they are the first four u16s of the skills packet. Bots that read them from 0xA0 will be 3 bytes off.
- The voucherXp field is only sent at clientVersion<1281. At 1530 the xp block is exactly baseXpGain, grinding, storeBoost, huntingBoost (4 x u16).
- GameCountU16 is NOT enabled at 1530, so item stack counts are u8, not u16 — despite the version being 15.30.
- getItem uses a GUNZ-SPECIFIC attribute order because getOs()==61: counter and clock come BEFORE the container block and tier comes AFTER it. Using the upstream/crystalserver order (tier, clock, counter after the container block) desyncs on any item with charges or a duration.
- getItem short-circuits with zero attribute bytes for item ids 3457 and 408 at clientVersion>=1185, but only under the gunz OS. Missing this makes browse-field packets unparseable.
- A Lua client cannot parse any item-bearing packet without a ThingType flag table (stackable/fluidContainer/splash/container/podium/decoKit/wearOut/clock flags/classification). There is no length prefix to skip over.
- parseTextMessage has a real bug: if the mode-specific branch already read the text and it happened to be the empty string, the client reads ANOTHER string (protocolgameparse.cpp:3159-3161). Do not replicate it — read exactly one string.
- parseTalk THROWS on any message mode not in its switch. At 1530 that includes server byte 16 (GamemasterPrivateTo) and every byte >=17 that maps to a mode without a case. Be lenient in Lua or a single GM message kills the connection.
- MessageMonsterSay/MessageMonsterYell and all MessageRVR* modes do not exist in the 1530 mode table, so those parseTalk branches are dead code — do not use them as a guide to the wire.
- The ping opcodes are inverted at 1530 because GameClientPing (>=953) is on: server 0x1E is the PONG for the client's ping, server 0x1D is a ping REQUEST that must be answered. The answer opcode is 28 (not 30) because of the gunz OS + cv>=1200 remap; that remap is flagged UNVERIFIED in the source.
- Creature icon list entries are 5 bytes at 1530 (a trailing byte after the u16 count), and getCreature reads TWO icon lists at 1530 — the first replaces, the second merges keeping the greater count. Reading only one list, or 4-byte entries, desyncs every creature-appear packet.
- parsePlayerCancelAttack has an extra u32 at clientVersion>=1530 that is read and discarded. Its meaning is unknown but the bytes must be consumed.
- The 0xB5 CancelWalk direction byte is the direction the player should FACE, not the direction that was rejected. It is Otc::Direction (0 N, 1 E, 2 S, 3 W), whereas the AutoWalk request encodes directions completely differently (E=1, NE=2, N=3, NW=4, W=5, SW=6, S=7, SE=8).
- GameMapMovePosition is OFF at 1530, so 0x65..0x68 and 0xBE/0xBF have NO position prefix — the payload starts directly with the tile-description strip. Reading 5 phantom bytes here corrupts the map stream.
- Creature speed from 0x8F/getCreature is a raw server speed value; the actual step time needs speedA/speedB/speedC (three doubles from the login/pending packet) plus the tile ground speed and serverBeat. Do not treat 'speed' as ms per step.
- Every accepted own-player step produces BOTH a 0x6D MoveCreature and one or two map-shift packets, because the player is always at the centre of the aware window. Track your own position from 0x6D, not from the map-shift math.
- Outgoing packets under the gunz OS need a 4-byte compression header prepended before the opcode once XTEA is on, plus (cv>=1405) padding+header-size and a sequence dword instead of the adler checksum. Getting this wrong makes login and pings appear to work while every gameplay packet is silently dropped.
- LocalPlayer::getPosition() returns the PREDICTED position while pre-walking. Anything comparing against server truth (attack range, waypoint arrival) must use the last 0x6D-confirmed position instead.
- getStepDuration in this fork subtracts 10 ms from the computed value (a deliberate mehah patch, creature.cpp:1150-1157). A byte-exact reimplementation of the protocol does not need it, but a cavebot ported from this client's timing will drift if it is not accounted for.

## Open questions
- The extra u32 discarded in parsePlayerCancelAttack at clientVersion>=1530 (protocolgameparse.cpp:2891-2893) has no known meaning; the source only cites the RE address 0x140549E8A.
- The trailing u8 on each creature-icon entry at 1530 and the existence of the SECOND (merge) icon list in getCreature come from binary RE comments (0x14055FC69, 0x1405746B6). Confirm against a live Gunzodus capture before relying on the exact byte count.
- sendPingBack using opcode 28 for the gunz OS is explicitly marked UNVERIFIED in protocolgamesend.cpp:273-279 ("Whether Gunzodus accepts 28 as a real opcode byte is UNVERIFIED"). If keepalive fails, try 30.
- The getItem short-circuit for ids 3457 and 408 is documented as UNVERIFIED semantics (protocolgameparse.cpp:4535-4539).
- Opcode 148 is GameServerPlayerHelpers in this build but is DepotSearchResults on stock 12.x+ servers; which one Gunzodus sends at 1530 is unconfirmed. The client unconditionally parses helpers (u32 + u16).
- The ordering of 0x6D relative to the 0x65..0x68 map-shift packets on an accepted walk is inferred from standard OT server behaviour and from how the client consumes them; it is not visible in the client source. Confirm with a capture.
- parsePassiveCooldown (0x5E) reads a leading u8 with no name and branches on a second u8 called 'unknownType'; the semantics of type 1 (two more discarded bytes) are unknown.
- The exact server-side units of baseXpGain / grindingAddend / storeBoostAddend / huntingBoostFactor (percent, per-mille, or raw multiplier x100) are not derivable from the client — it stores them verbatim in m_experienceRates.
- GameProficiency (135), GameTaskboard (134), GameEffectSource (132) and GameNpcWindowRedesign (133) are enabled at 1530 but do not affect any packet in this area; whether they gate additional fields in packets not covered here was not checked.
- Whether Gunzodus actually emits the GameServerFeatures packet (0x43) at 1530, and with which ids, is unknown — if it does, any of the flag assumptions above can be overridden at runtime.

## VERIFIER (confidence 0.92)

### Corrections (AUTHORITATIVE — these override the spec above)
- **Claim**: §15 OpenContainer (0x6E): "then cv≥1340 only: `u8 isMoveable, u8 isHolding` — **not read at 1530**"
  - **Correction**: WRONG — 1530 >= 1340, so these two bytes ARE read. Every container-open would desync by 2 bytes. The correct 1530 tail is: ... GameContainerFilter block, then `u8 isMoveable`, `u8 isHolding`.
  - Evidence: protocolgameparse.cpp:1653-1656 — `if (g_game.getClientVersion() >= 1340) { msg->getU8(); // isMoveable\n msg->getU8(); // isHolding }` (inside parseOpenContainer, before processOpenContainer). getClientVersion() == 1530.
- **Claim**: §11 / pseudocode: "PITFALL: the C++ client re-reads a string when the first one was \"\". Do NOT replicate that; the server writes exactly one string."
  - **Correction**: WRONG and desync-producing. `if (text.empty()) text = msg->getString();` is unconditional and is part of the wire contract. For every `default:` mode (Login/Status/Failure/Look/Loot/Game/Warning/...) it is the ONLY string read — so it must be replicated. For the channel/damage/heal/exp modes it reads a SECOND string whenever the first one is zero-length. A Lua parser that skips it will desync on any empty-text message of those modes. Replicate it verbatim.
  - Evidence: protocolgameparse.cpp:3157-3161 — `    if (text.empty()) {\n        text = msg->getString();\n    }\n\n    g_game.processTextMessage(mode, text);`
- **Claim**: §4: "`m_seq` is the counter the client sent in its own `0xA1 ClientAttack`"
  - **Correction**: WRONG at 1530. At protocolVersion >= 963 `m_seq` is set to the **target creature's id**, not an incrementing counter (the ++ counter is the <963 path only). So the ClearTarget seq must be compared against the attacked creature id. Note also that on a cancel (`creature == nullptr`) m_seq is left unchanged.
  - Evidence: game.cpp:985-989 — `if (m_protocolVersion >= 963) {\n        if (creature)\n            m_seq = creature->getId();\n    } else\n        ++m_seq;` (identical block in Game::follow at 1009-1013). Outgoing wire is protocolgamesend.cpp:823-831 `sendAttack`: `addU8(ClientAttack); addU32(creatureId); if (GameAttackSeq) addU32(seq);`
- **Claim**: §17 step duration: "mehah patch: the client subtracts 10 ms from the final value" and pseudocode `return d > 10 and d - 10 or d`
  - **Correction**: INCOMPLETE — the spec omits the addend that the −10 exists to cancel. For the local player with camera following, `duration += 10 * max(1, preWalkingSize)` is applied FIRST. With 0 or 1 queued pre-walks the net result is exactly `duration` (not `duration − 10`); with 2 queued it is `duration + 10`. The bare −10 only applies to non-local creatures or when the camera is not following the player. The pseudocode is therefore 10 ms fast on every local step.
  - Evidence: creature.cpp:1145-1158 — `if (isCameraFollowing() && isLocalPlayer()) {\n        const auto& localPlayer = static_self_cast<LocalPlayer>();\n        duration += 10 * std::max<int>(1, localPlayer->getPreWalkingSize());\n    }\n ... return duration > 10 ? duration - 10 : duration;`
- **Claim**: §17 step duration formula: `duration = 1000 * groundSpeed / calculatedStepSpeed` then `ceil(duration/serverBeat)*serverBeat`, and `if diagonal then duration = duration * 3`
  - **Correction**: Two errors. (a) The base division is INTEGER (uint32_t truncation) before the serverBeat rounding, not float: `uint32_t stepDuration = 1000 * groundSpeed; stepDuration /= m_calculatedStepSpeed;`. The pseudocode's float division can round up one beat where C++ does not. (b) The diagonal multiplier is keyed off `m_lastStepDirection` (the step already taken), NOT the direction passed in; the `dir` argument only selects which tile's groundSpeed is used. The pseudocode's `if dir >= 4 then d = d * 3` uses the wrong direction. (The factor 3 itself is right: g_gameConfig m_playerDiagonalWalkSpeed{3}, and the `>810` gate is satisfied.)
  - Evidence: creature.cpp:1126-1129 — `uint32_t stepDuration = 1000 * groundSpeed;\n        if (hasSpeedFormula()) {\n            stepDuration /= m_calculatedStepSpeed;\n        } else stepDuration /= m_speed;`; creature.cpp:1131-1133 `stepDuration = ((stepDuration + serverBeat - 1) / serverBeat) * serverBeat;`; creature.cpp:1141 `auto duration = ignoreDiagonal ? m_stepCache.duration : m_stepCache.getDuration(m_lastStepDirection);`; gameconfig.h:125 `double m_playerDiagonalWalkSpeed{ 3 };`
- **Claim**: §17 CancelWalk: "retry auto-walk if one is in flight (up to 3 retries, 200/300/400 ms)" and "setDirection(cancelDirection)"
  - **Correction**: WRONG on both counts. The retry delay is a FIXED 200 ms, and the gate is `m_autoWalkRetries <= 3`, i.e. up to 4 retries. More importantly, when a retry is scheduled `cancelWalk` returns EARLY — `setDirection(direction)` and the `onCancelWalk` Lua callback are skipped entirely in that case, so the facing byte is not applied and walk.lua's `lockWalk(50)` / `waitingForServerWalk = false` never run.
  - Evidence: localplayer.cpp:172-186 — `if (m_autoWalkRetries <= 3) { ... m_autoWalkContinueEvent = g_dispatcher.scheduleEvent(\n            [thisPtr = asLocalPlayer(), autoWalkDest = m_autoWalkDestination] { thisPtr->autoWalk(autoWalkDest, true); }, 200\n        ); m_autoWalkRetries += 1; return true; }`; localplayer.cpp:198-206 — `lockWalk();\n    if (retryAutoWalk()) return;\n\n    // turn to the cancel direction\n    if (direction != Otc::InvalidDirection)\n        setDirection(direction);\n\n    callLuaField("onCancelWalk", direction);`
- **Claim**: §17 canWalk gate 4 / pseudocode: `if #self.preWalks > self.maxSteps then return false end` followed by a separate `if ... not samePos(pos, serverPos) then return false end`
  - **Correction**: The position check is the ELSE arm of the walkMaxSteps test, not an additional condition. With the default `m_walkMaxSteps == 1` (> 0) the `getPosition() != getServerPosition()` test NEVER runs. The spec prose gets this right ("else if") but the pseudocode implements it as a second independent gate, which will refuse steps the real client allows.
  - Evidence: localplayer.cpp:47-53 — `if (g_game.getWalkMaxSteps() > 0) {\n        if (m_preWalks.size() > g_game.getWalkMaxSteps())\n            return false;\n    } else if (getPosition() != getServerPosition())\n        return false;`; game.h:531 `uint8_t m_walkMaxSteps{ 1 };`
- **Claim**: §18 outgoing frame order: "2. `clientVersion >= 1405` → `writePaddingAmount()` before encryption; `writeHeaderSize()` instead of `writeMessageSize()` afterwards. 3. XTEA encrypt. 4. sequence dword"
  - **Correction**: The numbered list mis-places the header write. Actual order in Protocol::send is: (1) prependCompressionHeader (xtea && os in [60,62]); (2) writePaddingAmount (cv>=1405); (3) xteaEncrypt; (4) writeSequence(m_packetNumber++) if m_sequencedPackets else writeChecksum; (5) writeHeaderSize (cv>=1405) else writeMessageSize. writeHeaderSize is LAST — after the sequence dword, not paired with the padding.
  - Evidence: protocol.cpp:139-170 — `if (m_xteaEncryptionEnabled) { ... prependCompressionHeader ... }` → `if (g_game.getClientVersion() >= 1405) { outputMessage->writePaddingAmount(); }` → `if (m_xteaEncryptionEnabled) { xteaEncrypt(outputMessage); }` → `if (m_sequencedPackets) { outputMessage->writeSequence(m_packetNumber++); } else if (m_checksumEnabled) { outputMessage->writeChecksum(); }` → `if (g_game.getClientVersion() >= 1405) { outputMessage->writeHeaderSize(); } else { outputMessage->writeMessageSize(); }`
- **Claim**: §17 issuing a step, item 3: "if following → send `ClientStop` first"
  - **Correction**: It is `g_game.cancelFollow()`, which emits ClientFollow (opcode 162) with creatureId 0 plus the seq dword — not ClientStop (105). ClientStop is only sent in the auto-walking / server-walking branch (`g_game.stop()`). Also missing: when the walk lock is active the client CLEARS `nextWalkDir` rather than queueing.
  - Evidence: modules/game_walk/walk.lua:88-92 — `if player:isWalkLocked() then\n        nextWalkDir = nil\n        return\n    end`; walk.lua:106-108 — `if g_game.isFollowing() then\n        g_game.cancelFollow()\n    end`; walk.lua:110-118 uses `g_game.stop()` for the autowalk/serverwalk case.
- **Claim**: §3: "Bit values (`Otc::PlayerStates`, const.h:278-298 ...)" listing bits up to 0x20000000
  - **Correction**: The C++ enum stops at `IconHungry = 65536`; every bit from 0x20000 (IntenseHex) upward exists ONLY in modules/gamelib/player.lua. Also, that Lua table contains a non-bitmask entry `Rewards = 30` (a "force icons" index, not a mask) — a port that iterates the table as bit values will produce a bogus 0x1E mask. The bit values the spec lists are otherwise correct (RedSwords/PzBlock both 8192, Pz/Pigeon both 16384, Hungry/LesserHex both 65536).
  - Evidence: const.h:276-295 — `enum PlayerStates : uint64_t { IconNone = 0, ... IconBleeding = 32768, IconHungry = 65536 };` (nothing further); modules/gamelib/player.lua:3-40 — `... Mentored = 536870912,\n-- force icons\n\tRewards = 30\n}`
- **Claim**: Wire primitives: "double := u8 precision, u32 raw ; value = (raw - 2147483647) / 10^precision"
  - **Correction**: Byte layout is right, but the arithmetic wraps: the C++ result is `(int32_t)(getU32() - INT_MAX)`, i.e. modulo 2^32 into signed 32-bit. Mathematically raw−2147483647 spans [−2147483647, +2147483648]; the single top value (raw = 0xFFFFFFFF) becomes −2147483648 in C++ but +2147483648 under the spec formula. Also the divisor is `std::pow(10.f, precision)` — float, not double, precision.
  - Evidence: framework/net/inputmessage.cpp:99-104 — `double InputMessage::getDouble()\n{\n    const uint8_t precision = getU8();\n    const int32_t v = getU32() - INT_MAX;\n    return (v / std::pow(10.f, precision));\n}`
- **Claim**: §0 flag table presented as the complete set of ON flags that "change byte layout"
  - **Correction**: Several enabled flags are missing from the table, some with wire impact just outside the listed packets: `GameEffectU16` (105, ≥1320 — distinct from GameMagicEffectU16 (16) which really is OFF; the spec's negative for id 16 is correct but the ON flag 105 is unlisted), `GameDynamicBugReporter` (111, ≥1320 — used in §17 prose but absent from the table), `GamePlayerFamiliars` (123, ≥1281), `GameItemAugment` (110, ≥1320), `GameBosstiaryTracker` (107, ≥1320), `GameDynamicForgeVariables` (93, ≥1314), `GameForgeConvergence` (119, ≥1332), `GameEffectSource` (132, ≥1514), `GameNpcWindowRedesign` (133, ≥1513), `GameTaskboard` (134, ≥1520), `GameThingQuickLoot` (83)/`GameVipGroups` (96)/`GameColorizedLootValue` (121)/`GameEnterGameShowAppearance` (114) at ≥1200, `GameDoubleShopSellAmount` (39)/`GameBosstiary` (97) at ≥1290, `GamePlayerStateU16` (48, ≥780 — harmless at 1530 since the ≥1281 branch wins), `GameProtocolChecksum` (1, ≥840 — overridden by GameSequencedPackets in Protocol::send), `GameMessageSizeCheck` (61), `GameChallengeOnLogin` (3), `GameLoginPacketEncryption` (63), `GameSpellList` (23), `GamePurseSlot` (21), `GamePrey` (82). All the feature IDs the spec DOES cite were verified correct against the enum.
  - Evidence: modules/game_features/features.lua (the 1200/1281/1290/1314/1320/1332/1513/1514/1520 arms); const.h:540-677 GameFeature enum — `GameCountU16 = 104, GameEffectU16 = 105, GameContainerTypes = 106, ...` vs `GameMagicEffectU16 = 16`.
- **Claim**: §7: "`getOutfit(msg, parseMount=false)` ... skips the mount block entirely"
  - **Correction**: Correct but incomplete: `parseMount == false` also suppresses the wings/auras/effects/shader block, because that block is gated on `GameWingsAurasEffectsShader && parseMount`. Irrelevant at 1530 (feature OFF) but load-bearing if a server flips feature 118 via parseFeatures (opcode 67), which the spec says must be honoured.
  - Evidence: protocolgameparse.cpp:4179 — `if (g_game.getFeature(Otc::GamePlayerMounts) && parseMount) {` and 4191 — `if (g_game.getFeature(Otc::GameWingsAurasEffectsShader) && parseMount) {`
- **Claim**: §15 getItem: "if cv >= 1185 and (id == 3457 or id == 408) then RETURN (zero attribute bytes)"
  - **Correction**: The short-circuit also requires the gunz OS class, not just the version: `isGunzOs && cv >= 1185 && (id == 3457 || id == 408)`. Outcome is identical at 1530/OS 61, but a Lua client that honours a runtime OS change (or reuses the reader for a non-gunz server) must carry the OS term. Same for the whole gunz attribute reordering and for the `isChargeable` count test, which the spec correctly omits for gunz but does not flag as OS-scoped.
  - Evidence: protocolgameparse.cpp:4534-4539 — `const bool isGunzOs = osValue >= Otc::CLIENTOS_GUNZ_LINUX && osValue <= Otc::CLIENTOS_GUNZ_MAC;` ... `if (isGunzOs && g_game.getClientVersion() >= 1185 && (id == 3457 || id == 408)) { return item; }`; 4546 — `if (item->isStackable() || item->isFluidContainer() || item->isSplash() || (!isGunzOs && item->isChargeable()))`

### Additions
- VERIFIED CORRECT — §1 parsePlayerStats: the 60-byte layout and every offset check out. health/maxHealth u32 (GameDoubleHealth ON), freeCapacity u32 then `/= 100` at cv>772, totalCapacity absent (`clientVersion < 1281 && GameTotalCapacity`, 2663-2666), experience u64, level u16, levelPercent u16 (GameLevelPercentU16, ON at ≥1520), voucherAddend absent (cv<1281 gate at 2679-2682), magicLevel triple absent (cv<1281 at 2697-2708), mana/maxMana u32, soul u8, stamina/baseSpeed/regeneration/offlineTraining u16, storeExpBoostTime u16 + canBuyXpBoost u8 at cv>=1097, manaShield/maxManaShield u32 each at cv>=1281 && GameDoubleHealth. Offsets sum to exactly 60. One caveat: the whole 24..32 xp-rate block sits inside `if (GameExperienceBonus)`, so a parseFeatures disable of feature 66 removes 8 bytes — the spec's "no conditionals left" is true only for the default flag set.
- VERIFIED CORRECT — §2 parsePlayerSkills: magic block (4×u16, percent = u16/100) gated cv>=1281; 7 skills `for (skill = Otc::Fist; skill <= Otc::Fishing; ++skill)` each level u16 / baseLevel u16 / discarded loyalty u16 / percent u16; GameAdditionalSkills and GameForgeSkillStats blocks both skipped (features.lua disables both at >=1410); GameConcotions u8 sits BETWEEN the additional-skills and forge blocks, i.e. after the 7 skills — as the spec says; the CharacterSkillStats tail order and widths match exactly, including `mantra` u16 between `armor` and `mitigation` under GameVocationMonk. The 143 + 6×combatsCount arithmetic is right.
- VERIFIED CORRECT — §3 parsePlayerState: `states = clientVersion >= 1405 ? msg->getU64() : msg->getU32();` inside the cv>=1281 branch, followed by the GamePlayerStateCounter u8. 9 bytes total at 1530. The pseudocode's split into statesLo/statesHi u32 halves is the right LuaJIT approach, though `hasState` only tests the low half — bits ≥ 0x100000000 are unreachable in this build so that is currently safe.
- VERIFIED CORRECT — §4 payload: `u32 seq` (GameAttackSeq) + a discarded `u32` at `clientVersion >= 1530`, 8 bytes (2887-2896). `processAttackCancel` is `if (isAttacking() && (seq == 0 || m_seq == seq)) cancelAttack();` — note the extra `isAttacking()` guard the spec omits.
- VERIFIED CORRECT — §5 creature packets: 0x8B/0x8C/0x8D/0x8E/0x8F/0x90/0x91/0x92/0x93/0x94/0x95 payloads, widths and order all match, including the cv>=1059 u16 baseSpeed prefix on 0x8F and `if (baseSpeed != 0) setBaseSpeed()`. 0x8B type 14 does call addCreatureIcon with the default `replace = true` (protocolgame.h:286 `const bool replace = true`). parseCreaturesMark's cv<1076 legacy split, squareType==0 clear / ==2 static(`squareColor != 0 ? squareColor : 1`) / else timed is exact. Opcode numbers verified against protocolcodes.h:139-149. Otc::Skill, Otc::Direction, PlayerSkulls, PlayerShields, PlayerEmblems, InventorySlot, Proto::CreatureType and ItemOpcode (97/98/99) enums all match the spec.
- VERIFIED CORRECT — §6 getMappedThing, §8 getCreature field order (including the cv>=1281 REPLACE icon list at 4374 followed by the cv>=1530 MERGE list at 4378, the unknown-only emblem, the GameThingMarks creatureType then masterId(type 3)/vocation(type 0) at cv>=1281, the GameCreatureIcons legacy icon, the mark u8 with its cv<1281-only trailing u16 helpers, the cv>=1281 inspection u8 and the cv>=854 unpass u8), §9 addCreatureIcon 5-byte entries at cv>=1530 with the exact replace/greater-count-merge semantics (empty incoming list = no-op), and §7 getOutfit. All confirmed line by line.
- VERIFIED CORRECT — §10 message-mode table: the >=1055 branch is in force and every server-byte → Otc::MessageMode pairing in the spec's table matches buildMessageModesMap plus the actual enum values (e.g. byte 10 → MessageNpcFromStartBlock(51), byte 20 → MessageGameHighlight(50), byte 48 → MessageAttention(52)). Bytes 45/46/47 and >=53 really are unmapped → MessageInvalid(255). The note that the earlier `if (version >= 1094) messageModesMap[MessageMana] = 43;` is redundant is right. The spec's §12 claim that server byte 16 (GamemasterPrivateTo) and MessageNone(0) fall to `default:` and throw is confirmed.
- VERIFIED CORRECT — §11/§12 field layouts (apart from the empty-string re-read noted above), §13 channel packets, §14 for 0x9F / 0x28 / 0xA4 / 0xA5 / 0xA6 / 0xA7 / 0xB5 / 0xB6 / 0xAF / 0xC1 / 0x5E / 0xA9 / 0xCC, §16 modal dialog (escape read before enter at cv>970), and readPackedCount1500 (gated on getProtocolVersion() < 1500, so packed at 1530). Otc::DeathRegular == 0 confirms the 0x28 penalty condition.
- VERIFIED CORRECT — ping semantics. protocolcodes.h:62-63 gives `GameServerPingBack = 29, GameServerPing = 30`, and the dispatcher at 117-127 routes `(opcode == GameServerPing && GameClientPing)` to parsePingBack, everything else to parsePing. So at 1530 opcode 30 is the latency sample and opcode 29 requires a pong — exactly as the spec states. sendPingBack emits 28 (ClientPingBackGunz) under `os in [60,62] && cv >= 1200`; sendPing emits 29 because GameExtendedClientPing is OFF. parseExtendedOpcode sub-opcode 2 → parsePingBack confirmed at 3982-3988.
- VERIFIED CORRECT — §17 outgoing walk opcodes and the ClientAutoWalk direction encoding (E=1, NE=2, N=3, NW=4, W=5, SW=6, S=7, SE=8, default 0) at protocolgamesend.cpp:289-326; the pseudocode's AUTOWALK_BYTE table maps every Otc::Direction to the right byte. Note sendAutoWalk itself does NOT clamp `path.size()` to 127 — that limit, if it exists, is imposed by the caller, so a Lua client should clamp explicitly. The 0x65..0x68 and 0xBE/0xBF handlers do take the `GameMapMovePosition ? getPosition(msg) : g_map.getCentralPosition()` branch with the feature OFF, so the spec's "no position prefix" is right (protocolgameparse.cpp:1503-1541).
- VERIFIED CORRECT — §17 login packet: parseLogin reads u32 playerId, u16 serverBeat, 3 doubles under GameNewSpeedLaw, NO canReportBugs byte (GameDynamicBugReporter ON), u8 at cv>=1054, u8 at cv>=1058, string url + u16 coinsPacketSize under GameIngameStore, u8 exiva at cv>=1281 with the Tournament byte skipped (feature disabled at >=1314). `hasSpeedFormula()` = GameNewSpeedLaw && speedA && speedB && speedC, and setSpeed's cache `s = speed*2; if (s > -speedB) max(1, floor(speedA*log(s/2. + speedB) + speedC + .5)) else 1` matches the spec verbatim (creature.cpp:964-971). Caveat: setSpeed early-returns when `speed == m_speed`, so m_calculatedStepSpeed is not recomputed if speedA/B/C arrive after a speed value.
- VERIFIED CORRECT — §0 baseline claims: Game::setClientVersion does only `m_features.reset(); m_clientVersion = version; callGlobalField("onClientVersionChange")` (game.cpp:1727-1743), so features.lua is indeed the sole source. getClientProtocolVersion only remaps 980..1002 (game.lua:91-104), so protocolVersion == clientVersion == 1530. parseFeatures at opcode 67 is `u16 count` then `count × (u8 featureId, u8 enabled)` (7501-7513). All the "OFF at 1530" negatives the spec calls load-bearing are confirmed absent from features.lua: GameCountU16(104), GameMapMovePosition(31), GameExtendedClientPing(25), GameItemShader(101), GameCreatureShader(102), GameCreatureAttachedEffect(103), GameWingsAurasEffectsShader(118), GameCreaturePaperdoll(128), GameItemTooltipV8(117), GameMagicEffectU16(16), GameChangeMapAwareRange(30); GameEnvironmentEffect(13)/GameItemAnimationPhase(15) are explicitly disabled in the >=1281 arm and GameTournamentPackets(92) in the >=1314 arm.
- MINOR / non-wire: getCreature calls `creature->setVocation(vocationId)` at protocolgameparse.cpp:4383 without the null-guard used everywhere else in that function, so a malformed "known but absent" creature with creatureType 0 would deref null. Not a parse issue for a Lua port, but worth knowing the C++ reference is not robust there.
- MINOR: §17's teleport rule "for ≥3-tile/≥2-floor jumps" is implemented as `(offsetX >= 3 or offsetY >= 3 or offsetZ >= 2)` on SIGNED offsets (walk.lua:243-247), not on absolute values — a jump of −5 tiles takes the stairs delay, not the teleport delay. Reproduce the signed comparison if byte-for-byte behavioural parity matters.
