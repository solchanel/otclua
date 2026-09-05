# Asset metadata (appearances protobuf) required by a pure-Lua 1530/Gunzodus protocol client, and how to extract it once into a compact table

# Asset metadata for a pure-Lua Gunzodus 1530 client

## 0. TL;DR

A byte-exact Lua protocol client needs **exactly one 62,145-byte lookup table** derived from
`appearances-<hash>.dat`, plus **three integers** (max valid id for outfit/effect/missile), plus
**one short ASCII string** read straight from `assets.json.sha256`.

It needs **no sprites, no sprite sheets, no sound files, no staticdata, no proficiencies JSON,
no frame groups, no animation data**.

---

## 1. Where the asset metadata comes from (load path)

`modules/game_things/things.lua:44-58` — on `onClientVersionChange(1530)`:

```lua
if version >= 1281 and not g_game.getFeature(GameLoadSprInsteadProtobuf) then
    local filePath = resolvepath(string.format('/data/things/%d/', version))
    g_things.loadAppearances(filePath)   -- <- the only call that matters for protocol
    g_things.loadStaticData(filePath)    -- monster races: UI only, no wire effect
    if g_game.getFeature(GameProficiency) then g_things.resolveProficienciesFile(filePath) end
end
```

`GameLoadSprInsteadProtobuf` (= 100, `src/client/const.h:640`) is **never enabled anywhere in the
tree** (it appears only in `modules/gamelib/const.lua:196` as a constant and in `getFeature`
tests). So for 1530 it is **false**, and the protobuf branch is always taken.

### 1.1 `loadAppearances` (`src/client/thingtypemanager.cpp:166-256`)

1. `src/client/thingtypemanager.cpp:171` reads the **asset identifier**:
   `readFileContents(resolvePath(guessFilePath(file + "assets", "json.sha256")))`
   → `data/things/1530/assets.json.sha256`. On failure it falls back to the literal string
   `"appearancesHash"` (line 174). *(For Gunzodus this value is NOT what the login packet sends —
   see §5.)*
2. `getCatalogContent` (`thingtypemanager.cpp:46-56`) parses
   `data/things/1530/catalog-content.json` as a **JSON array of objects**, each with a `"type"`.
   The loader iterates it (`thingtypemanager.cpp:181-197`):
   * `type == "appearances"` → `appearancesFile = obj["file"]` (a bare filename, later
     concatenated as `fmt::format("{}{}", file, appearancesFile)` at line 204).
   * `type == "sprite"` → builds a `SpriteSheet` from
     `firstspriteid`/`lastspriteid`/`spritetype`/`file`. **Sprites only.** Discard.
   * every other type (`staticdata`, `staticmapdata`, `fullmap`, `map`, `proficiencies`) is ignored
     by `loadAppearances`.
3. `thingtypemanager.cpp:204-208` reads the chosen `.dat` **verbatim** and calls
   `appearances::Appearances::ParseFromIstream`. The file is **raw, uncompressed protobuf** — no
   header, no magic, no gzip. Verified: the real file starts
   `0a 93 01 08 64 12 78 ...` = tag `0x0A` (field 1 = `object`, LEN), len `147`, then
   `08 64` = `id = 100` (the first item id, as expected).
4. Category → protobuf field mapping (`thingtypemanager.cpp:210-218`):

   | `ThingCategory` (`const.h:1167-1176`) | value | `Appearances` field |
   |---|---|---|
   | `ThingCategoryItem`     | 0 | `object`  (field 1) |
   | `ThingCategoryCreature` | 1 | `outfit`  (field 2) |
   | `ThingCategoryEffect`   | 2 | `effect`  (field 3) |
   | `ThingCategoryMissile`  | 3 | `missile` (field 4) |

5. **Indexing.** `thingtypemanager.cpp:219-232`:
   ```cpp
   // fix for custom asserts, where ids are not sorted.
   uint32_t lastAppearanceId = 0;
   for (const auto& appearance : *appearances)
       if (appearance.id() > lastAppearanceId) lastAppearanceId = appearance.id();
   things.clear();
   things.resize(lastAppearanceId + 1, m_nullThingType);
   for (const auto& appearance : *appearances) {
       const uint16_t id = appearance.id();          // NOTE: truncated to uint16_t
       type->unserializeAppearance(id, category, appearance);
       m_thingTypes[category][id] = type;
   }
   ```
   So the array is **dense, sized `maxId+1`, sparse in content** (ids are NOT contiguous and NOT
   guaranteed sorted). `id` is truncated to `uint16_t` when used as the index — irrelevant here
   because the real max is 62144 < 65536.

6. Validity predicate (`thingtypemanager.h:87`):
   ```cpp
   bool isValidDatId(id, category) const { return category < ThingLastCategory && id >= 1 && id < m_thingTypes[category].size(); }
   ```
   i.e. **`1 <= id <= maxId`**, regardless of whether that slot actually holds an appearance.

### 1.2 Measured contents of the real 1530 asset set

`D:/Claude/otclient_mehah1530/otclient/data/things/1530/`
(5,109 `sprites-*.bmp.lzma` sheets + the files below)

```
appearances-17a72b30b5c3c9ca8c1283cfb2febd2a93a145ff8ab66916f7a412d0f1dee5a1.dat   5,017,714 B
assets.json.sha256                                                                        5 B
backdrop_map-4806...jpg  catalog-content.json  map-9659...dat
proficiencies-97e5...json  staticdata-b198...dat  staticmapdata-0967...dat
```

Parsed counts (my own minimal protobuf reader over the real file):

| category | protobuf field | appearance count | **max id** | array size (`maxId+1`) |
|---|---|---|---|---|
| object (item)     | 1 | **43,536** | **62,144** | 62,145 |
| outfit (creature) | 2 | 1,475  | 10,003 | 10,004 |
| effect            | 3 | 243    | 343    | 344 |
| missile           | 4 | 76     | 82     | 83 |

Note how sparse outfits are: 1,475 entries spread over ids 1..10003.

---

## 2. Feature-flag values for 1530 (needed to know which asset fields are consulted)

From `modules/game_features/features.lua` (`onClientVersionChange`), evaluated cumulatively for
version 1530. Flag numbers from `src/client/const.h`.

| flag | # | 1530 value | set at | effect on `getItem` |
|---|---|---|---|---|
| `GameLoadSprInsteadProtobuf` | 100 | **false** (never enabled) | — | protobuf path taken |
| `GameThingMarks` | 41 | true (>=1000, features.lua:122) | but gated by `clientVersion < 1281` at `protocolgameparse.cpp:4541` → **no mark byte** |
| `GameItemAnimationPhase` | 15 | **false** — enabled at >=910, **disabled at >=1281** (features.lua:221) | → **animation phase byte never read; frame-group / phase data NOT needed** |
| `GameCountU16` | 104 | **false** (never enabled) | count/subtype is **u8** |
| `GameThingQuiver` | 84 | true (>=1260) | dead: shadowed by `GameContainerTypes` |
| `GameThingPodium` | 85 | **true** (>=1264, features.lua:209) | podium block read |
| `GameThingUpgradeClassification` | 86 | **true** (>=1272, features.lua:213) | tier byte read |
| `GameThingClock` | 88 | **true** (>=1290, features.lua:224) | duration block read |
| `GameThingCounter` | 87 | **true** (>=1290) | charges block read |
| `GameThingPodiumItemType` | 89 | **true** (>=1290) | podium `lookTypeEx` u16 |
| `GameContainerTypes` | 106 | **true** (>=1320, features.lua:245) | container-type switch |
| `GameWrapKit` | 112 | **true** (>=1321, features.lua:255) | deco-kit u16 |
| `GameProficiency` | 135 | **true** (>=1510, features.lua:274) | asset-side only (`m_proficiencyId`), no wire bytes in `getItem` |
| `GameItemShader` | 101 | **false** (never enabled) | no trailing shader string |
| `GameItemTooltipV8` | 117 | **false** (never enabled) | no trailing tooltip string |
| `GameContentRevision` | 65 | true (>=1071) | superseded by the `>= 1334` string branch |

1530 also sets `g_game.setRsa(GUNZODUS_RSA)` and `g_game.setCustomOs(61)` (features.lua:295-306),
which puts the client in the **`isGunzOs`** class (`osValue ∈ [60,62]`, `const.h:38-40`).

---

## 3. (1) EXACT asset attributes the protocol parser consults

### 3.1 Per **item** id — the complete list, in `getItem()` order

`ProtocolGame::getItem` — `src/client/protocolgameparse.cpp:4508-4699`. Read order for
`isGunzOs == true`, `clientVersion == 1530`:

| step | asset predicate | flag bit source | bytes consumed |
|---|---|---|---|
| a | *(id validity)* `isValidDatId(id, Item)` via `Item::setId` (`item.cpp:267-270`) — invalid id is clamped to 0 and `getItem` then **throws** (`protocolgameparse.cpp:4517-4523`) | array size | — |
| b | `id == 3457 or id == 408` (gunz + cv>=1185) → **return immediately, zero attribute bytes** (`protocolgameparse.cpp:4536-4539`) | hardcoded, not asset data | — |
| c | `isStackable() or isFluidContainer() or isSplash()` | `cumulative` / `liquidcontainer` / `liquidpool` | **u8** count/subtype (`GameCountU16` false) |
| d | `hasWearOut()` | `wearout` | **u32** charges + **u8** isBrandNew |
| e | `hasClockExpire() or hasExpire() or hasExpireStop()` | `clockexpire`/`expire`/`expirestop` | **u32** duration + **u8** isBrandNew |
| f | `isContainer()` | `container` | **u8** containerType + 0/4/8 more bytes (see switch below) |
| g | `getClassification() != 0` | `upgradeclassification.upgrade_classification` | **u8** tier |
| h | `isPodium()` | `show_off_socket` | u16 looktype (+5×u8 if ≠0, else u16 lookTypeEx) + u16 lookmount (+4×u8 if ≠0) + u8 dir + u8 visible |
| i | `isDecoKit()` | `deco_kit` | **u16** |

**Order note (load-bearing).** Upstream/crystalserver order is tier → clock → counter *after* the
container block; gunzotc runs **counter → clock → container → tier → podium**. The code encodes
this with `isGunzOs`:
```
protocolgameparse.cpp:4583-4586   if (isGunzOs) { readCounter(); readClock(); }
protocolgameparse.cpp:4586        if (item->isContainer()) { ... }
protocolgameparse.cpp:4643-4645   if (isGunzOs) { readTier(); }
protocolgameparse.cpp:4647        podium block
protocolgameparse.cpp:4677-4681   if (!isGunzOs) { readTier(); readClock(); readCounter(); }
```
Since OS 61 ⇒ `isGunzOs`, **use the gunz order**.

Container-type switch (`protocolgameparse.cpp:4587-4626`), after the u8 `containerType`:
`1`→u32, `2`→u32, `3`→u32+u32, `4`→nothing, `8`→u32, `9`→u32 (+u32 if cv≥1332 ⇒ yes), `11`→u32+u32
(+u32 if cv≥1332 ⇒ yes), default→nothing.

**`isChargeable` is a trap.** `protocolgameparse.cpp:4545-4546`:
```cpp
// isChargeable (1<<9) is never tested by gunzotc (0x140575992 - 0x1405759E8)
if (item->isStackable() || item->isFluidContainer() || item->isSplash() || (!isGunzOs && item->isChargeable())) {
```
and separately, `ThingFlagAttrChargeable` is **never set by `applyAppearanceFlags`** at all — it
only comes from legacy `.dat` `ThingAttrChargeable = 254` (`const.h:1243`,
`thingtype.cpp` `unserialize`). With protobuf assets it is always 0. **Ignore it entirely.**

### 3.2 Per-item attributes consulted **outside** `getItem` (still byte-consuming)

* `getClassification() > 0` → read one u8 tier:
  * `parsePlayerInventory` (`protocolgameparse.cpp:3929-3932`) — *not* byte-consuming (the
    attribute byte is read unconditionally), only reinterpreted as tier.
  * `parseItemsPrice` (`protocolgameparse.cpp:5741-5750`) — **byte-consuming** `msg->getU8()`.
  * `readMarketItemTier` (`protocolgameparse.cpp:7005-7018`) and the market/forge/imbuement
    parsers at lines 5991, 6009, 6030, 6048, 6066, 6946, 7210 — **byte-consuming**.
  * Send direction: `protocolgamesend.cpp:1595-1596` and `:1613-1614` add a tier u8.
* `getMarketData().category` (`protocolgameparse.cpp:7608-7618`, weapon-proficiency 0xC4) —
  **not** byte-consuming, only picks a UI category. Optional.

**So the classification bit is required in two independent code paths; it is not optional.**

### 3.3 Per **outfit / effect / missile** — what's needed

**Nothing but the array size.** No per-appearance flag of a creature/effect/missile appearance is
ever consulted while reading bytes. The only uses are bounds checks:

```
protocolgameparse.cpp:1956  isValidDatId(shotId,   ThingCategoryMissile)
protocolgameparse.cpp:1978  isValidDatId(effectId, ThingCategoryEffect)
protocolgameparse.cpp:2018  isValidDatId(effectId, ThingCategoryEffect)   parseMagicEffect
protocolgameparse.cpp:2034  isValidDatId(effectId, ThingCategoryEffect)   parseRemoveMagicEffect
protocolgameparse.cpp:2073  isValidDatId(shotId,   ThingCategoryMissile)  parseDistanceMissile
protocolgameparse.cpp:3381  isValidDatId(lookType, ThingCategoryCreature) getOutfit
protocolgameparse.cpp:3398  isValidDatId(lookTypeEx, ThingCategoryItem)
protocolgameparse.cpp:4153/4170  same pair in the second outfit reader
```
All of these only *log and skip*; **none changes the number of bytes read** (they occur after the
last read of their packet). A Lua client may skip them entirely, or keep them to reject garbage.
Required constants: `creatureMaxId = 10003`, `effectMaxId = 343`, `missileMaxId = 82`,
`itemMaxId = 62144`.

### 3.4 `animate_always` — measured absent

`animate_always` (field 29) → `ThingFlagAttrAnimateAlways` (`thingtype.cpp:311-313`). It is a
**pure rendering** flag (`Item::calculateAnimationPhase`); no parser reads it. And in this actual
1530 asset file **field 29 occurs 0 times**. Do not extract it.

### 3.5 Recommended optional extras (not protocol, but a bot wants them)

Cheap to add and every one is a single protobuf field:

| purpose | flag | field | measured |
|---|---|---|---|
| pathability (`Tile::isWalkable`, `tile.cpp:1000`) | `unpass` → NotWalkable | 13 | 16,697 items |
| avoid / not-pathable | `avoid` | 16 | 2,055 |
| block projectile | `unsight` | 15 | 5,925 |
| ground + walk speed | `bank.waypoints` | 1→1 | 3,354 items, speed 0..1200 (u16) |
| stack ordering | `clip`(2)/`bottom`(3)/`top`(4) | 2,3,4 | 6,312 / 11,212 / 1,267 |
| minimap colour | `automap.color` | 30→1 | 15,777 items, 0..215 (u8) |
| elevation | `height.elevation` | 27→1 | 2,194 items, 0..24 (u8) |
| pickup / move | `take`(18), `unmove`(14) | 18, 14 | 7,221 / 31,818 |
| corpse / lying | `lying_object` | 28 | 1,890 |
| item name (for `look`, GUI) | `Appearance.name` | 4 (string) | — |

**Beware `has_*`-only semantics.** For `bank`, `bottom`, `top`, `write`, `write_once`, `light`,
`shift`, `height`, `automap`, `lenshelp`, `clothes`, `market`, `default_action`, `cyclopediaitem`,
`upgradeclassification`, `proficiency`, `skillwheel_gem`, `imbueable`, `minimum_level`,
`weapon_type` the C++ tests **presence only** (`if (flags.has_bottom())` — `thingtype.cpp:187`,
`:191`, `:179`, …), so a present-but-zero field still sets the flag. For the boolean flags it
tests `has_x() && x()` (presence **and** truth). Reproduce whichever form applies per field.

---

## 4. (2) Protobuf wire path to every needed field

`syntax = "proto2"`, package `otclient.protobuf.appearances`
(`src/protobuf/appearances.proto`). Tag byte(s) = varint of `(field_number << 3) | wire_type`.
`wt 0` = varint, `wt 2` = length-delimited.

### 4.1 Top level
```
message Appearances {                       // src/protobuf/appearances.proto:87-93
    repeated Appearance object  = 1;   tag 0x0A
    repeated Appearance outfit  = 2;   tag 0x12
    repeated Appearance effect  = 3;   tag 0x1A
    repeated Appearance missile = 4;   tag 0x22
    optional SpecialMeaningAppearanceIds special_meaning_appearance_ids = 5;  tag 0x2A  // UNUSED by the client
}
```
`special_meaning_appearance_ids` has **zero references** anywhere in `src/` or `modules/` (grep) —
skip it.

### 4.2 `Appearance` (proto:134-140)
```
optional uint32 id          = 1;   tag 0x08  (varint)      <- REQUIRED
repeated FrameGroup frame_group = 2; tag 0x12 (LEN)        <- SKIP ENTIRELY (sprites only)
optional AppearanceFlags flags = 3; tag 0x1A (LEN)         <- REQUIRED
optional string name        = 4;   tag 0x22 (LEN)          <- optional (m_name)
optional string description = 5;   tag 0x2A (LEN)          <- optional (m_description)
```
Note the tag collision hazard: top-level `outfit` and nested `frame_group` are both `0x12`. A
reader must respect message nesting, not scan globally.

### 4.3 `AppearanceFlags` — protocol-relevant fields only

| field | proto name | # | wire type | tag bytes | → ThingType |
|---|---|---|---|---|---|
| container | `container` | 5 | varint(bool) | `0x28` | `ThingFlagAttrContainer` (`thingtype.cpp:196`) |
| stackable | `cumulative` | 6 | varint(bool) | `0x30` | `ThingFlagAttrStackable` (`thingtype.cpp:200`) |
| splash | `liquidpool` | 12 | varint(bool) | `0x60` | `ThingFlagAttrSplash` (`thingtype.cpp:226`) |
| fluid container | `liquidcontainer` | 19 | varint(bool) | `0x98 0x01` | `ThingFlagAttrFluidContainer` (`thingtype.cpp:252`) |
| podium | `show_off_socket` | 46 | varint(bool) | `0xB0 0x02` | `ThingFlagAttrPodium` (`thingtype.cpp:404`) |
| tier/classification | `upgradeclassification` | 48 | LEN (msg) | `0x82 0x03` | `m_upgradeClassification` (`thingtype.cpp:410`) |
| ↳ inside | `AppearanceFlagUpgradeClassification.upgrade_classification` | 1 | varint(uint32) | `0x08` | value 1..4 in this asset set |
| charges | `wearout` | 53 | varint(bool) | `0xA8 0x03` | `ThingFlagAttrWearOut` (`thingtype.cpp:419`) |
| duration | `clockexpire` | 54 | varint(bool) | `0xB0 0x03` | `ThingFlagAttrClockExpire` (`:423`) |
| duration | `expire` | 55 | varint(bool) | `0xB8 0x03` | `ThingFlagAttrExpire` (`:427`) |
| duration | `expirestop` | 56 | varint(bool) | `0xC0 0x03` | `ThingFlagAttrExpireStop` (`:431`) |
| wrap kit | `deco_kit` | 57 | varint(bool) | `0xC8 0x03` | `ThingFlagAttrDecoKit` (`:435`) |
| *(not needed)* | `animate_always` | 29 | varint(bool) | `0xE8 0x01` | 0 occurrences in this file |

Optional extras (same message):
```
bank            = 1  tag 0x0A  LEN  -> AppearanceFlagBank { waypoints = 1 (varint) }   // ground speed
clip            = 2  tag 0x10  bool
bottom          = 3  tag 0x18  bool   (has_ only)
top             = 4  tag 0x20  bool   (has_ only)
unpass          = 13 tag 0x68  bool
unmove          = 14 tag 0x70  bool
unsight         = 15 tag 0x78  bool
avoid           = 16 tag 0x80 0x01 bool
take            = 18 tag 0x90 0x01 bool
hang            = 20 tag 0xA0 0x01 bool
shift           = 26 tag 0xD2 0x01 LEN -> { x=1, y=2 }
height          = 27 tag 0xDA 0x01 LEN -> { elevation=1 }
lying_object    = 28 tag 0xE0 0x01 bool
automap         = 30 tag 0xF2 0x01 LEN -> { color=1 }
fullbank        = 32 tag 0x82 0x02 bool
market          = 36 tag 0xA2 0x02 LEN -> { category=1 (enum ITEM_CATEGORY), trade_as_object_id=2, show_as_object_id=3, name=4, restrict_to_profession=5, minimum_level=6 }
```

### 4.4 Minimal pure-Lua protobuf reader (only what's needed)

You need **varint** and **length-delimited** only, plus skip for wt 5 (fixed32) and wt 1 (fixed64)
— neither occurs in this file, but handle them defensively. Groups (wt 3/4) do not occur.

Measured field-usage histogram over all 43,536 objects (proves nothing exotic appears):
fields 1-64 only; no wt 5 / wt 1 anywhere; fields 65-69 are `reserved` and absent; 70/71/72
(`hook_south`, `hook_east`, `transparencylevel`) absent from this asset set.

---

## 5. (3) Concrete extraction plan and file format

### 5.1 Recommendation: **dense binary flag table, one byte per item id**

Because item ids run 1..62,144 and the parser needs O(1) lookup on every single item byte-read,
a dense `string` of 62,145 bytes indexed with `s:byte(id+1)` is both the smallest sane option and
the fastest (no hash, no ffi required).

```
offset  size  content
0       4     magic  "GZA1"
4       1     format version = 1
5       1     reserved = 0
6       2     u16 LE  contentRevision (42196)      -- convenience copy of assets.json.sha256
8       4     u32 LE  itemArrayLen    = 62145      -- valid item ids are 1 .. itemArrayLen-1
12      4     u32 LE  creatureArrayLen= 10004
16      4     u32 LE  effectArrayLen  = 344
20      4     u32 LE  missileArrayLen = 83
24      N     itemArrayLen bytes, one flag byte per item id (index 0 = id 0 = always 0x00)
```

**Flag byte layout (7 bits used, 1 spare) — chosen so each bit maps 1:1 to a read decision:**

| bit | mask | meaning | source protobuf fields |
|---|---|---|---|
| 0 | `0x01` | READ_COUNT — read u8 count/subtype | `cumulative(6) OR liquidcontainer(19) OR liquidpool(12)` |
| 1 | `0x02` | READ_CHARGES — u32 + u8 | `wearout(53)` |
| 2 | `0x04` | READ_DURATION — u32 + u8 | `clockexpire(54) OR expire(55) OR expirestop(56)` |
| 3 | `0x08` | READ_CONTAINER — u8 type + switch | `container(5)` |
| 4 | `0x10` | READ_TIER — u8 | `upgradeclassification(48).upgrade_classification > 0` |
| 5 | `0x20` | READ_PODIUM — podium block | `show_off_socket(46)` |
| 6 | `0x40` | READ_DECOKIT — u16 | `deco_kit(57)` |
| 7 | `0x80` | *spare* | — |

**Measured with this exact encoding:** 7,486 of 62,145 slots non-zero; table = **62,145 bytes**;
whole file = **62,169 bytes (≈ 61 KB)**. zlib-9 of the table alone is 3,006 bytes if you want it
compressed on disk (decompress at startup — but 61 KB raw is not worth compressing).

Alternative sparse form: 7,486 × `(u16 id, u8 flags)` = **22,458 bytes**, but needs a binary
search or a Lua hash table of 7,486 entries built at startup (~1 MB of Lua table memory). **Dense
wins**; the 61 KB string is a single `f:read("*a")` and zero per-entry allocation.

`luajit -b` is **not** recommended for the flag table: escaping 62 KB of arbitrary bytes into a
Lua source literal inflates the source ~3× and buys nothing over `io.open`+`read`. Use `luajit -b`
only if you also want the *names* table (see 5.3).

### 5.2 The extractor (one-time, offline)

Pseudocode in §pseudocode. Run once against
`data/things/1530/appearances-<hash>.dat`; re-run whenever `assets.json.sha256` changes.
Verified working against the real file (my throwaway parser is at
`C:/Users/solch/AppData/Local/Temp/claude/D--Claude/d2316c51-2c9d-4dca-8ccb-196012c2a787/scratchpad/extract.py`
and `gen2.py`, output `items_flags.bin`; nothing was written into the reference tree).

Loader side (Lua):
```lua
local f  = assert(io.open("assets/items1530.bin","rb"))
local hd = f:read(24)
assert(hd:sub(1,4) == "GZA1")
local u32 = function(s,o) local a,b,c,d = s:byte(o,o+3) return a+b*256+c*65536+d*16777216 end
local itemLen = u32(hd, 9)
local FLAGS   = f:read(itemLen)          -- one 62 KB Lua string, never copied again
f:close()
local function itemFlags(id) return FLAGS:byte(id+1) or 0 end
```

### 5.3 Optional second table (extras from §3.5)

Ship as a **separate** file so the protocol core stays 61 KB:
* `items1530_map.bin` — 1 byte per id (unpass/avoid/unsight/clip/bottom/top/take/lying) = 61 KB
* `items1530_ground.bin` — sparse `(u16 id, u16 speed)` × 3,354 = 13,416 B
* `items1530_automap.bin` — dense u8 per id = 61 KB, or sparse `(u16,u8)` × 15,777 = 47 KB
* `items1530_elev.bin` — sparse `(u16 id, u8 elev)` × 2,194 = 6,582 B
* `items1530_names.lua` (precompile with `luajit -b`) — only if you want look-text; 43,536 strings
  is ~1.5 MB of source and is by far the biggest thing here. Keep it out of the default load.

---

## 6. (4) The content-revision string sent in the login packet

**Yes — read it from the file at runtime; no protobuf involvement whatsoever.**

`data/things/1530/assets.json.sha256` is 5 bytes and contains, verbatim (hexdump):
```
00000000: 34 32 31 39 36        "42196"
```
No trailing newline, no BOM. Despite the filename it is **a decimal content revision, not a hash**.

### 6.1 Exact runtime algorithm — `resolveGunzContentRevision`, `src/client/protocolgamesend.cpp:65-97`

```cpp
// In a gunzotc install assets.json.sha256 holds a decimal content revision, not a hash.
// ProtocolGame::resolveContentRevision (0x1405007A0) probes "assets/assets.json.sha256"
// (0x14050081F), then "things/<clientVersion>/assets.json.sha256" (0x14050085F), trims the
// contents (sub_1402B87D0), parses a u32 (sub_1405102B0) and requires 1 <= v <= 0xFFFF
// (0x140500AE1); anything else logs and yields 0. There is no cache ...
```
1. Probe, in order: `assets/assets.json.sha256`, then
   `things/<clientVersion>/assets.json.sha256` (= `things/1530/assets.json.sha256`).
   First one that exists **and reads non-empty** wins.
2. `trimSpacesAndNewlines`.
3. `std::from_chars` → `uint32_t`; require **the whole string consumed** *and* `1 <= v <= 0xFFFF`.
   Anything else ⇒ **0** (and an error log). `42196 ≤ 65535`, so it is accepted.
4. Return `uint16_t`.

### 6.2 What goes on the wire — `sendLoginPacket`, `protocolgamesend.cpp:137-146`

```cpp
if (g_game.getClientVersion() >= 1334) {
    // gunzotc sends the decimal text of a content revision parsed out of assets.json.sha256
    // (0x140501789), not the file's contents; every other server gets the upstream hash string.
    if (isGunzOs)
        msg->addString(std::to_string(resolveGunzContentRevision()));
    else
        msg->addString(g_things.getAssetIdentifier());
} else if (g_game.getFeature(Otc::GameContentRevision)) {
    msg->addU16(g_things.getContentRevision());
}
```
1530 ≥ 1334 and OS 61 ⇒ **`isGunzOs` branch**. `addString`
(`src/framework/net/outputmessage.cpp:84-94`) emits **`u16 LE length` then the raw bytes**.

**Exact bytes for this install:**
```
05 00 34 32 31 39 36      ; u16 len=5, "42196"
```

Note the round-trip: file text → integer → decimal text. If the file ever held e.g. `"042196"` or
`"42196\n"`, the wire string would still be `"42196"` (leading zeros dropped, whitespace trimmed).
If the file held something unparsable or > 65535, the wire string would be **`"0"`**
(`02 00 30`... no — `01 00 30`, u16 len=1, `'0'`). So: **parse it, don't blit it.**

`ThingTypeManager::m_assetIdentifier` (the literal file contents, or `"appearancesHash"` on read
failure, `thingtypemanager.cpp:171-176`) is **dead for Gunzodus** — it is only used on the
non-gunz branch. `getContentRevision()` (`thingtypemanager.h:83`) is only populated by
`loadDat` (the legacy `.dat` path, `thingtypemanager.cpp:105-106`) and is **0** on the protobuf
path — harmless because the `>= 1334` branch is taken first.

---

## 7. (5) Sprites and sounds are NOT needed — confirmed

* **Sounds:** `grep "g_sounds"` over `src/client/protocolgameparse.cpp` returns **zero hits**.
  Sounds are loaded from `data/sounds/<version>/` by `modules/game_things/things.lua:92`, after
  `loaded` is already true, and the comment there says failing to load them "will not block
  logging into game". No packet length depends on them.
* **Sprites:** `grep "g_spriteAppearances\|g_sprites\."` over `protocolgameparse.cpp` returns
  **zero hits**. Sprite data enters `ThingType` in exactly two places, both purely visual:
  * `m_size` from `g_spriteAppearances.getSheetBySpriteId(...)->getSpriteSize()`
    (`thingtype.cpp:88-90`) — used only by rendering/`isTall`/`isTopGround`.
  * `m_animationPhases` / `m_spritesIndex` / `m_animator` from `frame_group`
    (`thingtype.cpp:64-175`) — the only parser touch-point is
    `if (item->getAnimationPhases() > 1) msg->getU8()` at `protocolgameparse.cpp:4555-4563`,
    **guarded by `GameItemAnimationPhase`, which features.lua:221 explicitly `disableFeature`s at
    version >= 1281.** For 1530 that block never runs.

  ⇒ **Do not parse `frame_group` at all.** This also removes any need for the 5,109
  `sprites-*.bmp.lzma` sheets, the LZMA decoder, and the `catalog-content.json` sprite entries.
* **`staticdata-*.dat`** (monster races): consumed only by `loadStaticData` and read back by
  `getAllRaces()` / `getRaceData()` in taskboard/bestiary UI builders
  (`protocolgameparse.cpp:4806`, `:4878`, `:4893`) — these **build Lua tables from already-read
  bytes**; they never call `msg->getU*`. Not needed for protocol correctness.
* **`proficiencies-*.json`**: `resolveProficienciesFile` only stores a path for the UI. Not needed.
* **`map-*.dat` / `staticmapdata-*.dat` / `backdrop_map-*.jpg`**: minimap/backdrop art. Not needed.
* **`catalog-content.json`**: needed **only** to learn the `appearances-<hash>.dat` filename at
  extraction time. The Lua client never needs it at runtime once the flag table is baked (and even
  at extraction time you can just glob `appearances-*.dat`).

## Pseudocode

-- ============================================================================
-- PART A. One-time extractor (run offline; Lua or Python, logic identical).
--         Input : data/things/1530/appearances-<hash>.dat  (raw protobuf, 5,017,714 B)
--         Output: assets/items1530.bin                     (62,169 B)
-- ============================================================================

-- ---- minimal protobuf primitives -------------------------------------------
-- b = the whole file as a Lua string; i = 1-based cursor.

local function readVarint(b, i)
  local r, s = 0, 0
  repeat
    local c = b:byte(i); i = i + 1
    r = r + (c % 128) * (2 ^ s)        -- use bit ops / ffi uint64 if values can exceed 2^53
    s = s + 7
  until c < 128
  return r, i
end

-- iterate fields of the region [i, stop)
-- yields: field_number, wire_type, varint_value_or_nil, sub_start, sub_stop
local function fields(b, i, stop)
  return coroutine.wrap(function()
    while i < stop do
      local key; key, i = readVarint(b, i)
      local fn, wt = math.floor(key / 8), key % 8
      if wt == 0 then
        local v; v, i = readVarint(b, i)
        coroutine.yield(fn, wt, v, nil, nil)
      elseif wt == 2 then
        local ln; ln, i = readVarint(b, i)
        coroutine.yield(fn, wt, nil, i, i + ln)
        i = i + ln
      elseif wt == 5 then i = i + 4    -- fixed32: never occurs in this file
      elseif wt == 1 then i = i + 8    -- fixed64: never occurs in this file
      else error("unsupported wire type " .. wt) end
    end
  end)
end

-- ---- pass over the file ----------------------------------------------------
local b = io.open(PATH, "rb"):read("*a")

local maxId   = { [1]=0, [2]=0, [3]=0, [4]=0 }   -- 1=object 2=outfit 3=effect 4=missile
local itemFlg = {}                                -- [id] = flag byte

for topField, _, _, s, e in fields(b, 1, #b + 1) do
  if topField >= 1 and topField <= 4 then         -- object / outfit / effect / missile
    local id, flagsStart, flagsStop = 0, nil, nil
    for f, wt, v, ss, se in fields(b, s, e) do
      if     f == 1 and wt == 0 then id = v                      -- Appearance.id
      elseif f == 3 and wt == 2 then flagsStart, flagsStop = ss, se  -- Appearance.flags
      end
      -- f == 2 (frame_group) : DELIBERATELY SKIPPED, sprites only
      -- f == 4 (name) / f == 5 (description) : optional extras
    end
    if id > maxId[topField] then maxId[topField] = id end

    if topField == 1 and flagsStart then          -- items only
      local bits = 0
      for f, wt, v, ss, se in fields(b, flagsStart, flagsStop) do
        -- boolean flags: C++ tests has_x() && x()  => presence AND truth
        if     f ==  6 and v ~= 0 then bits = bits | 0x01   -- cumulative      -> count u8
        elseif f == 19 and v ~= 0 then bits = bits | 0x01   -- liquidcontainer -> count u8
        elseif f == 12 and v ~= 0 then bits = bits | 0x01   -- liquidpool      -> count u8
        elseif f == 53 and v ~= 0 then bits = bits | 0x02   -- wearout    -> u32+u8
        elseif f == 54 and v ~= 0 then bits = bits | 0x04   -- clockexpire
        elseif f == 55 and v ~= 0 then bits = bits | 0x04   -- expire
        elseif f == 56 and v ~= 0 then bits = bits | 0x04   -- expirestop -> u32+u8
        elseif f ==  5 and v ~= 0 then bits = bits | 0x08   -- container
        elseif f == 46 and v ~= 0 then bits = bits | 0x20   -- show_off_socket -> podium
        elseif f == 57 and v ~= 0 then bits = bits | 0x40   -- deco_kit -> u16
        elseif f == 48 then                                  -- upgradeclassification (submessage)
          -- C++ tests has_upgradeclassification() only, then uses the value;
          -- the read decision is `getClassification() != 0`, so require value > 0.
          local cls = 0
          for g, gwt, gv in fields(b, ss, se) do
            if g == 1 and gwt == 0 then cls = gv end
          end
          if cls > 0 then bits = bits | 0x10 end
        end
      end
      itemFlg[id] = bits
    end
  end
end

-- measured: maxId = {62144, 10003, 343, 82}; 43536 objects; 7486 non-zero flag bytes

-- ---- emit --------------------------------------------------------------
local N = maxId[1] + 1                              -- 62145
local out = { "GZA1", string.char(1), string.char(0),
              u16le(42196),                         -- contentRevision, see PART C
              u32le(N), u32le(maxId[2]+1), u32le(maxId[3]+1), u32le(maxId[4]+1) }
local t = {}
for id = 0, N - 1 do t[id + 1] = string.char(itemFlg[id] or 0) end
out[#out+1] = table.concat(t)
io.open("assets/items1530.bin", "wb"):write(table.concat(out))


-- ============================================================================
-- PART B. Runtime use inside the Lua client's getItem()
--         (gunz ordering: counter -> clock -> container -> tier -> podium)
-- ============================================================================

local F_COUNT, F_CHARGES, F_DURATION = 0x01, 0x02, 0x04
local F_CONTAINER, F_TIER, F_PODIUM, F_DECOKIT = 0x08, 0x10, 0x20, 0x40

function proto.getItem(msg, id)
  if not id or id == 0 then id = msg:getU16() end
  -- Item::setId clamps an out-of-range id to 0, and getItem then throws.
  if id < 1 or id >= ITEM_ARRAY_LEN then error("invalid item id " .. id) end

  local item = { id = id }

  -- gunzotc short-circuit, cv >= 1185 (protocolgameparse.cpp:4536-4539)
  if id == 3457 or id == 408 then return item end

  -- cv 1530 >= 1281 => the GameThingMarks mark byte is NOT read

  local fl = FLAGS:byte(id + 1)

  if fl & F_COUNT ~= 0 then
    item.count = msg:getU8()                    -- GameCountU16 is FALSE for 1530
  end

  -- GameItemAnimationPhase is DISABLED at >=1281 -> no phase byte, ever

  if fl & F_CHARGES ~= 0 then                   -- readCounter()
    item.charges = msg:getU32(); msg:getU8()    -- isBrandNew
  end

  if fl & F_DURATION ~= 0 then                  -- readClock()
    item.duration = msg:getU32(); msg:getU8()   -- isBrandNew
  end

  if fl & F_CONTAINER ~= 0 then                 -- GameContainerTypes = true (>=1320)
    local ct = msg:getU8()
    if     ct == 1 then msg:getU32()
    elseif ct == 2 then msg:getU32()
    elseif ct == 3 then msg:getU32(); msg:getU32()
    elseif ct == 4 then -- nothing (loot-highlight visual only)
    elseif ct == 8 then msg:getU32()
    elseif ct == 9 then msg:getU32(); msg:getU32()            -- 2nd u32: cv >= 1332
    elseif ct == 11 then msg:getU32(); msg:getU32(); msg:getU32()  -- 3rd: cv >= 1332
    end
  end

  if fl & F_TIER ~= 0 then                      -- readTier(), gunz position
    item.tier = msg:getU8()
  end

  if fl & F_PODIUM ~= 0 then                    -- GameThingPodium = true (>=1264)
    local lt = msg:getU16()
    if lt ~= 0 then
      msg:getU8(); msg:getU8(); msg:getU8(); msg:getU8(); msg:getU8()   -- head/body/legs/feet/addons
    else
      msg:getU16()                              -- lookTypeEx (GameThingPodiumItemType, >=1290)
    end
    local lm = msg:getU16()
    if lm ~= 0 then msg:getU8(); msg:getU8(); msg:getU8(); msg:getU8() end
    msg:getU8()                                 -- direction
    msg:getU8()                                 -- visible
  end

  if fl & F_DECOKIT ~= 0 then msg:getU16() end  -- GameWrapKit = true (>=1321)

  -- GameItemShader  = FALSE for 1530 -> no trailing string
  -- GameItemTooltipV8 = FALSE for 1530 -> no trailing string
  return item
end

-- Same table gates the standalone tier reads elsewhere:
local function readMarketItemTier(msg, itemId)          -- protocolgameparse.cpp:7005-7018
  if itemId < 1 or itemId >= ITEM_ARRAY_LEN then return 0 end
  if FLAGS:byte(itemId + 1) & F_TIER == 0 then return 0 end
  return msg:getU8()
end


-- ============================================================================
-- PART C. Content revision for sendLoginPacket (protocolgamesend.cpp:65-146)
-- ============================================================================

local function resolveGunzContentRevision()
  for _, p in ipairs { "assets/assets.json.sha256",
                       "things/" .. CLIENT_VERSION .. "/assets.json.sha256" } do
    local f = io.open(p, "rb")
    if f then
      local s = f:read("*a"); f:close()
      if s and #s > 0 then
        s = s:match("^%s*(.-)%s*$")             -- trimSpacesAndNewlines
        local v = s:match("^%d+$") and tonumber(s)
        if v and v >= 1 and v <= 0xFFFF then return v end
        return 0                                -- unparsable / out of range -> 0
      end
    end
  end
  return 0
end

-- inside sendLoginPacket, after addU32(clientVersion) and addString("1530"):
--   cv 1530 >= 1334 and OS 61 in [60,62] => gunz branch
msg:addString(tostring(resolveGunzContentRevision()))
-- addString = u16 LE length + raw bytes  (outputmessage.cpp:84-94)
-- For this install: 05 00 34 32 31 39 36   ("42196")

## Evidence
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtypemanager.cpp:166 — bool ThingTypeManager::loadAppearances(const std::string& file): the only asset entry point used at 1530
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtypemanager.cpp:171 — m_assetIdentifier = readFileContents(guessFilePath(file + "assets", "json.sha256")); fallback literal "appearancesHash" at :174
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtypemanager.cpp:46-56 — getCatalogContent(): parses <path>catalog-content.json with nlohmann::json, caches by path
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtypemanager.cpp:181-197 — catalog loop: type=="appearances" -> appearancesFile; type=="sprite" -> SpriteSheet(firstspriteid,lastspriteid,spritetype,file); all other types ignored here
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtypemanager.cpp:203-208 — readFileStream(fmt::format("{}{}", file, appearancesFile)) then appearancesLib.ParseFromIstream(&fin): raw uncompressed protobuf, no wrapper
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtypemanager.cpp:210-218 — category switch: Item->object(), Creature->outfit(), Effect->effect(), Missile->missile()
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtypemanager.cpp:219-232 — "fix for custom asserts, where ids are not sorted": scan for max id, resize(lastAppearanceId+1, null), then index by appearance.id() truncated to uint16_t
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtypemanager.h:87 — isValidDatId: category < ThingLastCategory && id >= 1 && id < m_thingTypes[category].size()
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtypemanager.h:83-84 — getContentRevision() (only set by loadDat, i.e. 0 on the protobuf path) and getAssetIdentifier()
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.cpp:54-64 — unserializeAppearance sets m_name/m_description, calls applyAppearanceFlags, then the whole frame_group/sprite block is inside `if (!getFeature(GameLoadSprInsteadProtobuf))`
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.cpp:177-489 — applyAppearanceFlags: complete protobuf-field -> ThingType flag/attribute mapping
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.cpp:196 — has_container() && container() -> ThingFlagAttrContainer
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.cpp:200 — has_cumulative() && cumulative() -> ThingFlagAttrStackable
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.cpp:226 — has_liquidpool() && liquidpool() -> ThingFlagAttrSplash
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.cpp:252 — has_liquidcontainer() && liquidcontainer() -> ThingFlagAttrFluidContainer
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.cpp:311 — has_animate_always() && animate_always() -> ThingFlagAttrAnimateAlways (rendering only; 0 occurrences in the real file)
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.cpp:404 — has_show_off_socket() && show_off_socket() -> ThingFlagAttrPodium
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.cpp:410-412 — has_upgradeclassification() (presence only) -> m_upgradeClassification = upgradeclassification().upgrade_classification()
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.cpp:419-437 — wearout/clockexpire/expire/expirestop/deco_kit -> ThingFlagAttrWearOut/ClockExpire/Expire/ExpireStop/DecoKit
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.cpp:179-181 — has_bank() (presence only) -> m_groundSpeed = bank().waypoints(), ThingFlagAttrGround
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.cpp:187-194 — has_bottom() / has_top() tested by PRESENCE only, value ignored (same for write, light, shift, height, automap, lenshelp, clothes, market, default_action, cyclopediaitem, proficiency, skillwheel_gem, imbueable, minimum_level, weapon_type)
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.h:261 — uint64_t m_flags; the 53 ThingFlagAttr bits live here
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:1247-1303 — enum ThingFlagAttr: Stackable=1<<5, Chargeable=1<<9, FluidContainer=1<<11, Splash=1<<12, Container=1<<4, WearOut=1<<38, ClockExpire=1<<39, Expire=1<<40, ExpireStop=1<<41, Podium=1<<42, DecoKit=1<<45
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:1167-1176 — ThingCategoryItem=0, Creature=1, Effect=2, Missile=3, ThingLastCategory=4
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:38-40 — CLIENTOS_GUNZ_LINUX=60, CLIENTOS_GUNZ_WINDOWS=61, CLIENTOS_GUNZ_MAC=62
- D:/Claude/otclient_mehah1530/otclient/src/protobuf/appearances.proto:87-93 — message Appearances { object=1, outfit=2, effect=3, missile=4, special_meaning_appearance_ids=5 }
- D:/Claude/otclient_mehah1530/otclient/src/protobuf/appearances.proto:134-140 — message Appearance { id=1, frame_group=2, flags=3, name=4, description=5 }
- D:/Claude/otclient_mehah1530/otclient/src/protobuf/appearances.proto:147-199 — AppearanceFlags: container=5, cumulative=6, liquidpool=12, liquidcontainer=19, animate_always=29, show_off_socket=46, upgradeclassification=48, wearout=53, clockexpire=54, expire=55, expirestop=56, deco_kit=57
- D:/Claude/otclient_mehah1530/otclient/src/protobuf/appearances.proto:203-205 — AppearanceFlagUpgradeClassification { upgrade_classification = 1 }
- D:/Claude/otclient_mehah1530/otclient/src/protobuf/appearances.proto:298-306 — SpecialMeaningAppearanceIds: zero references anywhere in src/ or modules/
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4508-4699 — ProtocolGame::getItem, the complete attribute-block reader
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4532-4533 — isGunzOs = osValue >= CLIENTOS_GUNZ_LINUX && osValue <= CLIENTOS_GUNZ_MAC
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4536-4539 — gunz + cv>=1185: ids 3457 and 408 return with ZERO attribute bytes
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4541-4543 — mark byte only when clientVersion < 1281; skipped at 1530
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4545-4548 — "isChargeable (1<<9) is never tested by gunzotc"; count read is `getFeature(GameCountU16) ? getU16() : getU8()`
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4550-4558 — animation-phase byte, guarded by GameItemAnimationPhase (disabled at >=1281)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4560-4580 — readCounter (wearout: u32+u8), readClock (clock/expire/expirestop: u32+u8), readTier (classification: u8)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4583-4586 + 4643-4645 + 4677-4681 — gunz block order: counter, clock, container, tier, podium; non-gunz: container, podium, tier, clock, counter
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4587-4626 — GameContainerTypes switch: 1->u32, 2->u32, 3->u32+u32, 4->none, 8->u32, 9->u32(+u32 cv>=1332), 11->u32+u32(+u32 cv>=1332)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4647-4674 — podium block layout (looktype u16 / 5 u8, or lookTypeEx u16; lookmount u16 / 4 u8; dir u8; visible u8)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4683-4695 — GameWrapKit deco_kit u16; GameItemShader and GameItemTooltipV8 strings (both features off at 1530)
- D:/Claude/otclient_mehah1530/otclient/src/client/item.cpp:267-276 — Item::setId clamps to 0 when !isValidDatId(id, ThingCategoryItem); combined with protocolgameparse.cpp:4517-4523 an out-of-range id makes getItem throw
- D:/Claude/otclient_mehah1530/otclient/src/client/item.cpp:42-48 — Item::create is just setId; no other asset lookup
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:5741-5750 — parseItemsPrice: `if (item->getClassification() > 0) msg->getU8();` — a second byte-consuming tier site
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:7005-7018 — readMarketItemTier: cv>=1281 + getClassification()>0 -> getU8()
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:3929-3932 — parsePlayerInventory: classification only reinterprets an already-read attribute byte (not byte-consuming)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1956,1978,2018,2034,2073,3381,3398,4153,4170 — the ONLY uses of creature/effect/missile appearance data: isValidDatId bounds checks that log-and-skip, never changing byte counts
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:7608-7618 — weapon-proficiency 0xC4 uses itemType->getMarketData().category for a Lua callback only (no bytes)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4806,4878,4893 — taskboard/soulseal use g_things.getAllRaces()/getRaceData(): pure UI table building, no msg->getU*; staticdata not needed
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:65-97 — resolveGunzContentRevision: probe assets/assets.json.sha256 then things/<cv>/assets.json.sha256, trim, from_chars u32, require full consume and 1<=v<=0xFFFF, else 0; no cache
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:137-146 — cv>=1334: isGunzOs -> addString(to_string(resolveGunzContentRevision())), else addString(getAssetIdentifier()); older -> addU16(getContentRevision())
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/outputmessage.cpp:84-94 — addString = addU16(len) + raw bytes
- D:/Claude/otclient_mehah1530/otclient/modules/game_things/things.lua:44-58 — version>=1281 and !GameLoadSprInsteadProtobuf -> loadAppearances('/data/things/1530/'), loadStaticData, resolveProficienciesFile
- D:/Claude/otclient_mehah1530/otclient/modules/game_features/features.lua:217-222 — version>=1281: disableFeature(GameEnvironmentEffect); disableFeature(GameItemAnimationPhase)  <- kills the phase byte and the need for frame groups
- D:/Claude/otclient_mehah1530/otclient/modules/game_features/features.lua:209,213,224-230,245-252,255-257 — GameThingPodium(1264), GameThingUpgradeClassification(1272), GameThingClock/Counter/PodiumItemType(1290), GameContainerTypes(1320), GameWrapKit(1321)
- D:/Claude/otclient_mehah1530/otclient/modules/game_features/features.lua:274-276 — version>=1510: enableFeature(GameProficiency)
- D:/Claude/otclient_mehah1530/otclient/modules/game_features/features.lua:295-306 — version>=1530: setRsa(GUNZODUS_RSA); setCustomOs(61) (the comment explains the ordering constraint vs chooseRsa)
- D:/Claude/otclient_mehah1530/otclient/modules/gamelib/const.lua:196-213 — GameLoadSprInsteadProtobuf=100, GameItemShader=101, GameCountU16=104, GameItemTooltipV8=117: defined but NEVER enabled anywhere (grep over src/ + modules/), i.e. false at 1530
- D:/Claude/otclient_mehah1530/otclient/data/things/1530/assets.json.sha256 — 5 bytes, exactly `34 32 31 39 36` = "42196", no newline; a decimal revision despite the filename
- D:/Claude/otclient_mehah1530/otclient/data/things/1530/catalog-content.json — 1,116,468 B; type histogram {sprite:5109, appearances:1, staticdata:1, staticmapdata:1, fullmap:1, map:1, proficiencies:1}
- D:/Claude/otclient_mehah1530/otclient/data/things/1530/appearances-17a72b30b5c3c9ca8c1283cfb2febd2a93a145ff8ab66916f7a412d0f1dee5a1.dat — 5,017,714 B raw protobuf; first bytes 0a 93 01 08 64 12 78 (field1 LEN 147, id=100)
- MEASURED (own minimal parser over the real .dat): object 43,536 appearances maxid 62,144 | outfit 1,475 maxid 10,003 | effect 243 maxid 343 | missile 76 maxid 82
- MEASURED flag-field usage among the 43,536 objects: container(5)=3381, cumulative(6)=2593, liquidpool(12)=12, liquidcontainer(19)=48, animate_always(29)=0, market(36)=5099, show_off_socket(46)=5, upgradeclassification(48)=1016, wearout(53)=92, clockexpire(54)=10, expire(55)=187, expirestop(56)=141, deco_kit(57)=1; fields 65-72 absent
- MEASURED: upgrade_classification value histogram {1:311, 2:294, 3:88, 4:323} — always >0 when the submessage is present
- MEASURED: 7,486 item ids carry at least one protocol-relevant bit; dense 1-byte table = 62,145 B (zlib-9 3,006 B); sparse (u16 id,u8 flags) = 22,458 B
- MEASURED extras: bank/ground 3,354 items speed 0..1200 (u16); height.elevation 2,194 items 0..24 (u8); automap.color 15,777 items 0..215 (u8); unpass 16,697; unmove 31,818; unsight 5,925; avoid 2,055; take 7,221; clip 6,312; bottom 11,212; top 1,267; lying_object 1,890
- grep(g_sounds|g_spriteAppearances|g_sprites.) over src/client/protocolgameparse.cpp — zero hits: sounds and sprites are never consulted while reading bytes
- Scratch files (outside the reference tree): C:/Users/solch/AppData/Local/Temp/claude/D--Claude/d2316c51-2c9d-4dca-8ccb-196012c2a787/scratchpad/{extract.py,gen.py,gen2.py,items_flags.bin}

## Pitfalls
- ORDER: gunzotc reads the item attribute blocks as counter -> clock -> container -> tier -> podium; upstream/crystalserver reads container -> podium -> tier -> clock -> counter. OS 61 puts you in the gunz class, so use the gunz order (protocolgameparse.cpp:4583/4643/4677). Getting this wrong silently desyncs the whole stream on the first charged/timed container item.
- GameCountU16 (104) is NEVER enabled anywhere in the tree, so the count/subtype byte is a u8, not a u16, at 1530. Do not assume a modern protocol implies u16.
- GameItemAnimationPhase is explicitly DISABLED at version >= 1281 (features.lua:221) after being enabled at >= 910. If you only grep for enableFeature you will wrongly read a phase byte for every multi-phase item. This also means you never need frame_group / sprite data.
- GameItemShader (101) and GameItemTooltipV8 (117) are defined in modules/gamelib/const.lua but never enabled, so getItem has NO trailing shader/tooltip strings at 1530. Same class of trap as GameCountU16.
- isChargeable is a phantom: ThingFlagAttrChargeable is never set by applyAppearanceFlags (it only comes from the legacy .dat attribute 254), AND the gunz branch excludes it from the count test anyway. Never extract or test it.
- GameThingMarks is enabled at >= 1000 but its read is gated by `clientVersion < 1281` (protocolgameparse.cpp:4541), so no mark byte at 1530. Feature-enabled != byte-read.
- Item ids 3457 and 408 short-circuit with ZERO attribute bytes under gunz + cv >= 1185 (protocolgameparse.cpp:4536-4539), even if their appearance carries container/stackable flags. Hardcode this before consulting the flag table.
- An item id outside 1..62144 makes Item::setId clamp to 0 and getItem THROW (item.cpp:269, protocolgameparse.cpp:4517). You must know the array length (maxId+1), not just the set of ids that exist.
- Appearance ids are NOT sorted and NOT contiguous — the loader explicitly scans for the max ('fix for custom asserts, where ids are not sorted', thingtypemanager.cpp:219). Do not assume ordering when parsing or when building a sparse table.
- Outfit ids are extremely sparse: 1,475 appearances over ids 1..10003. isValidDatId only checks id < size, so an id pointing at an empty slot is 'valid'. Reproduce the size check, not an existence check, if you want identical behaviour.
- proto2 has_ semantics: for bank, bottom, top, write, write_once, light, shift, height, automap, lenshelp, clothes, market, default_action, cyclopediaitem, upgradeclassification, proficiency, skillwheel_gem, imbueable, minimum_level and weapon_type the C++ tests PRESENCE ONLY — a present field encoding false/0 still sets the flag. For the plain bools it tests has_x() && x(). Mixing these up mostly matters for the map/render extras, and for upgradeclassification (where the read decision is the VALUE != 0, not presence).
- assets.json.sha256 is NOT a hash for Gunzodus — it holds the decimal string '42196'. Do not blit the file contents onto the wire: the client parses it to a uint32, validates 1 <= v <= 0xFFFF, and re-stringifies. Whitespace, a trailing newline, leading zeros, or an out-of-range value all change the transmitted bytes (an invalid value transmits the literal '0').
- There is NO caching of the content revision (the comment at protocolgamesend.cpp:69-73 notes the single xref with no writer) — the probe re-runs on every sendLoginPacket. Harmless, but do not assume a cached value if you mirror the behaviour.
- Tag collision when writing a hand-rolled protobuf reader: top-level Appearances.outfit and nested Appearance.frame_group both encode as 0x12. Track nesting; never byte-scan for tags globally.
- Item classification is consulted in at least three independent byte-consuming places (getItem readTier, parseItemsPrice at :5745, readMarketItemTier at :7012, plus the forge/imbuement sites at 5991/6009/6030/6048/6066/6946/7210). One shared flag-table lookup must back all of them.
- staticdata-*.dat needs a version-dependent schema (Staticdata1530 vs the legacy layout, thingtypemanager.cpp:305-315 — 1530 inserted raceCategories at field 2 and shifted the rest). Do not try to parse it 'just in case'; it contributes nothing to the wire and will fail with the wrong schema.

## Open questions
- The semantics of the two hardcoded short-circuit ids 3457 and 408 (protocolgameparse.cpp:4536-4539) are marked UNVERIFIED in the source. 3457 is the classic browse-field pseudo id; 408 is unexplained. If the server ever sends a real item with id 408 carrying attributes, the Lua client will desync exactly like the C++ one. Worth confirming against a live capture.
- Whether the sub-1185 behaviour matters: the short-circuit is gated on cv >= 1185, so it is unconditional at 1530 — but the exact gunzotc binary offsets cited (0x140575720-0x140575745) were not re-verified here.
- container type codes 5, 6, 7 and 10 fall through the switch's `default: break;` (protocolgameparse.cpp:4624) with zero extra bytes. It is unclear whether the server can emit them and whether they really carry no payload, or whether upstream simply never implemented them. A capture showing any of these would settle it.
- The 1530-only trailing detail list on the weapon-proficiency packet (protocolgameparse.cpp:7595-7601, `detailCount` u8 with a 'layout unknown' warning) is unrelated to asset metadata but sits next to the market-category lookup; if that list is ever non-empty the packet desyncs regardless of asset data.
- AppearanceFlags fields 70 (hook_south), 71 (hook_east) and 72 (transparencylevel) are declared in the .proto but occur ZERO times in this asset file, and 70/71 are never read by applyAppearanceFlags at all (only the field-21 `hook` submessage is). Whether a future Gunzodus asset drop starts using them is unknown; a defensive extractor should log unknown field numbers rather than silently skip.
- upgrade_classification values observed are only 1..4. Whether the server can send a tier byte for an item whose classification the client thinks is 0 (which would desync) has not been tested; the C++ client would desync identically, so this is a shared risk rather than a Lua-specific one.
- GameItemShader/GameItemTooltipV8 are mehah extensions that a server could theoretically negotiate on via an extended opcode. Nothing in this tree enables them for 1530, but if Gunzodus ever turns them on, getItem grows two trailing strings.

## VERIFIER (confidence 0.92)

### Corrections (AUTHORITATIVE — these override the spec above)
- **Claim**: §4.3: `show_off_socket` (field 46, varint bool) has tag bytes `0xB0 0x02`.
  - **Correction**: Wrong tag. Field 46 with wire type 0 encodes key = (46<<3)|0 = 368, whose varint is `0xF0 0x02`. `0xB0 0x02` decodes to key 304 = field 38 wire type 0 = `unwrap`, a completely different flag. A hand-written reader that matches on raw tag bytes (rather than decoding the key varint) would set READ_PODIUM from `unwrap` and miss every real podium item — 5 items in this asset set carry field 46, and each of them costs 4..11 attribute bytes in getItem, so this is a guaranteed desync on the first podium item.
  - Evidence: D:/Claude/otclient_mehah1530/otclient/src/protobuf/appearances.proto:191 — `optional bool show_off_socket = 46;`. (46<<3)|0 = 368 → varint 0xF0 0x02. Verified by computation and by decoding the real file: 5 objects carry field 46 (bit 5 of the spec's own flag byte).
- **Claim**: §4.3 optional extras: `fullbank = 32  tag 0x82 0x02  bool`.
  - **Correction**: Wrong tag. Field 32 with wire type 0 encodes key = 256, whose varint is `0x80 0x02`. `0x82 0x02` is key 258 = field 32 wire type **2** (length-delimited), which fullbank is not.
  - Evidence: D:/Claude/otclient_mehah1530/otclient/src/protobuf/appearances.proto:177 — `optional bool fullbank = 32;` → tag 0x80 0x02. Non-protocol field, so no wire impact, but it is wrong as written.
- **Claim**: §3.3: "All of these only *log and skip*; **none changes the number of bytes read** (they occur after the last read of their packet). A Lua client may skip them entirely."
  - **Correction**: False for two of the nine cited sites, both inside the batched magic-effects loop of `parseMagicEffect` (protocol >= 1203, i.e. taken at 1530). Both alter how many bytes are consumed, so `effectMaxId = 343` and `missileMaxId = 82` are load-bearing and MUST be implemented. (a) protocolgameparse.cpp:1956-1959, missile bound check inside `case MAGIC_EFFECTS_CREATE_DISTANCEEFFECT / _REVERSED`, executes `return;` — it abandons the whole while-loop mid-packet, leaving the remaining entries and the MAGIC_EFFECTS_END_LOOP terminator unconsumed. (b) protocolgameparse.cpp:1978-1981, effect bound check inside `case MAGIC_EFFECTS_CREATE_EFFECT`, executes `continue;` — the `effectType = msg->getU8();` that advances the loop sits at line 2006, at the *end* of the while body, so `continue` re-enters the switch with the same effectType and consumes another effect id (+ GameEffectSource byte) without reading a new type byte. Both behaviours must be replicated verbatim to stay byte-aligned with the reference client.
  - Evidence: protocolgameparse.cpp:1956 `if (!g_things.isValidDatId(shotId, ThingCategoryMissile)) { g_logger.traceError(...); return; }`; protocolgameparse.cpp:1978 `if (!g_things.isValidDatId(effectId, ThingCategoryEffect)) { g_logger.traceError(...); continue; }`; protocolgameparse.cpp:1942 `while (effectType != Otc::MAGIC_EFFECTS_END_LOOP) {` ... protocolgameparse.cpp:2006 `effectType = msg->getU8();`
- **Claim**: §2 / §7: the feature set is fully determined by `modules/game_features/features.lua`; `GameLoadSprInsteadProtobuf`, `GameCountU16`, `GameItemShader`, `GameItemTooltipV8` are "never enabled anywhere in the tree", therefore no count-u16, no shader/tooltip strings, and no frame_group parsing is ever needed.
  - **Correction**: Incomplete. The server can flip ANY feature bit at runtime via the `parseFeatures` opcode handler, which is missing from the spec entirely. If Gunzodus ever sends it, every §2 conclusion inverts: GameCountU16 turns the count into u16, GameItemShader/GameItemTooltipV8 append trailing strings to every item, and GameItemAnimationPhase (15) re-enables `if (item->getAnimationPhases() > 1) msg->getU8();` at protocolgameparse.cpp:4551, which would require frame_group phase counts the spec deliberately discards. The spec must at minimum state that the Lua client has to implement this opcode and either honour or explicitly refuse the toggles.
  - Evidence: protocolgameparse.cpp:7500-7512 — `void ProtocolGame::parseFeatures(const InputMessagePtr& msg) { const uint16_t features = msg->getU16(); for (auto i = 0; i < features; ++i) { const auto feature = static_cast<Otc::GameFeature>(msg->getU8()); const auto enabled = static_cast<bool>(msg->getU8()); if (enabled) g_game.enableFeature(feature); else g_game.disableFeature(feature); } }`
- **Claim**: §3.2: the byte-consuming standalone tier sites are "parseItemsPrice ... readMarketItemTier (protocolgameparse.cpp:7005-7018) and the market/forge/imbuement parsers at lines 5991, 6009, 6030, 6048, 6066, 6946, 7210".
  - **Correction**: Under-enumerated and mis-numbered. `readMarketItemTier` is a helper at protocolgameparse.cpp:7001-7017 with THREE call sites the spec never lists — :7028 (parseMarketEnter depot list), :7158 and :7179 (readMarketOffer) — each of which conditionally eats a u8. The imbuement site is :6951 (not 6946), and parseMarketBrowse has an inline copy at :7207-7213 (the spec's "7210"). Complete list of byte-consuming classification gates: 4576 (getItem readTier), 5745 (parseItemsPrice), 5991 / 6009 / 6030 / 6048 / 6066 (five CYCLOPEDIA_CHARACTERINFO_ITEMSUMMARY loops), 6951 (IMBUEMENT_WINDOW_SELECT_ITEM), 7016 via 7028/7158/7179, and 7211.
  - Evidence: protocolgameparse.cpp:7001 `static uint8_t readMarketItemTier(const InputMessagePtr& msg, uint16_t itemId, int clientVersion)`; call sites at :7028, :7158, :7179. protocolgameparse.cpp:6951 `const uint16_t classification = thing->getClassification();` inside `case Otc::IMBUEMENT_WINDOW_SELECT_ITEM`.
- **Claim**: Pseudocode PART C / §6.1: `readMarketItemTier`-style guard `if itemId < 1 or itemId >= ITEM_ARRAY_LEN then return 0 end`, and §3.2's framing that out-of-range ids are what makes these sites return 0.
  - **Correction**: The observable result is right but the stated rule is wrong, and one gate is missing. `ThingTypeManager::getThingType` NEVER returns null — out-of-range ids log an error and return `m_nullThingType` — so the `if (!thing) return 0;` branch in readMarketItemTier is dead; the only real predicate is `getClassification() > 0`, which is 0 both for out-of-range ids and for in-range-but-empty slots. Also `readMarketItemTier` has a `if (clientVersion < 1281) return 0;` early-out the spec omits (harmless at 1530). Additionally, sites using `Item::create()` go through `isValidDatId` (which requires `id >= 1`) while sites using `getThingType()` accept id 0 — no wire difference, but the spec should not present `id < 1` as the governing rule.
  - Evidence: thingtypemanager.cpp:414-421 — `const ThingTypePtr& ThingTypeManager::getThingType(const uint16_t id, const ThingCategory category) { if (category >= ThingLastCategory || id >= m_thingTypes[category].size()) { g_logger.error(...); return m_nullThingType; } return m_thingTypes[category][id]; }`; protocolgameparse.cpp:7002-7014.
- **Claim**: Pseudocode PART A: boolean flag extraction written as `if f == 6 and v ~= 0 then ... elseif f == 5 and v ~= 0 then ...`
  - **Correction**: Latent bug: the spec's own `fields()` iterator yields `v = nil` for wire-type-2 fields, and in Lua `nil ~= 0` evaluates to **true**. Any of fields 5, 6, 12, 19, 46, 53, 54, 55, 56, 57 appearing as length-delimited would set the corresponding read bit. Every such field is wire type 0 in this specific file (I verified: only wire types 0 and 2 occur, and all ten of those fields are wt 0), so it does not bite today — but the guard should be `f == N and wt == 0 and v ~= 0`. The same iterator hands `ss/se = nil` for wire-type-0, so the `f == 48` branch's nested `fields(b, ss, se)` would throw if field 48 ever arrived as a varint.
  - Evidence: The spec's own `fields()` definition: `if wt == 0 then ... coroutine.yield(fn, wt, v, nil, nil) elseif wt == 2 then ... coroutine.yield(fn, wt, nil, i, i + ln)`. Measured wire-type histogram over all 43,536 object flag messages: {wt0: 121375, wt2: 59596} — no wt 1 or wt 5, confirming the defensive skips are untested paths.
- **Claim**: §0 TL;DR: "...plus **one short ASCII string** read straight from `assets.json.sha256`."
  - **Correction**: Contradicts §6, which is the correct account. The wire string is NOT the file contents; it is `std::to_string()` of the u32 parsed out of the trimmed contents, and is `"0"` if the parse fails or the value is outside [1, 0xFFFF]. Anyone implementing from the TL;DR alone would blit the file bytes and be right only by coincidence for this particular install. §6 states this correctly ("parse it, don't blit it"); the TL;DR should not say "read straight from".
  - Evidence: protocolgamesend.cpp:88-97 — `const auto result = std::from_chars(begin, end, revision); if (result.ec == std::errc{} && result.ptr == end && revision >= 1 && revision <= 0xFFFF) return static_cast<uint16_t>(revision); ... return 0;` and protocolgamesend.cpp:143 `msg->addString(std::to_string(resolveGunzContentRevision()));`
- **Claim**: Numerous file:line citations, e.g. "features.lua:209 GameThingPodium", "features.lua:213 UpgradeClassification", "features.lua:224 GameThingClock", "features.lua:245 GameContainerTypes", "features.lua:255 GameWrapKit", "features.lua:274 GameProficiency"; "protocolgameparse.cpp:4508-4699 getItem", "4583-4586 counter/clock", "4643-4645 tier", "4647 podium"; "things.lua:44-58".
  - **Correction**: Systematic small line drift (mostly +1 to +4). Correct values: features.lua:210 (GameThingPodium), :214 (GameThingUpgradeClassification), :227 (GameThingClock, GameThingCounter at :228, GameThingPodiumItemType at :229), :247 (GameContainerTypes), :256 (GameWrapKit), :275 (GameProficiency), :305 (setCustomOs(61)); protocolgameparse.cpp getItem spans 4510-4698, isGunzOs at :4533, 3457/408 short-circuit at :4537-4539, mark at :4541, count at :4546, readCounter/readClock/readTier lambdas at :4560/:4567/:4575, gunz `if (isGunzOs) { readCounter(); readClock(); }` at :4581-4584, isContainer at :4586, container switch :4588-4626, gunz readTier at :4647-4649, podium at :4651-4675, `if (!isGunzOs)` at :4677-4681, WrapKit at :4683, shader :4689, tooltip :4693; things.lua load() is 43-101 with the protobuf branch at :47-57. The claims themselves are all correct — only the anchors are off, which matters because the reimplementer will have no C++ access to re-locate them.
  - Evidence: grep -n over the reference tree; e.g. protocolgameparse.cpp:4510 `ItemPtr ProtocolGame::getItem(const InputMessagePtr& msg, int id)`, :4581 `if (isGunzOs) {`, :4647 `if (isGunzOs) {`, :4651 `if (g_game.getFeature(Otc::GameThingPodium)) {`; features.lua:227 `g_game.enableFeature(GameThingClock)`.
- **Claim**: §3.1 table steps d/e/g list only the asset predicate: "d | `hasWearOut()`", "e | `hasClockExpire() or hasExpire() or hasExpireStop()`", "g | `getClassification() != 0`".
  - **Correction**: Each of these three reads is a two-term conjunction with a feature flag, not the asset predicate alone: `GameThingCounter && hasWearOut()`, `GameThingClock && (hasClockExpire() || hasExpire() || hasExpireStop())`, `GameThingUpgradeClassification && getClassification()`. All three features are true at 1530 so there is no wire difference today, but combined with the runtime `parseFeatures` opcode (see above) the conjunction is not decorative, and §3.1 is the table an implementer will code from.
  - Evidence: protocolgameparse.cpp:4561 `if (g_game.getFeature(Otc::GameThingCounter) && item->hasWearOut()) {`; :4568-4569 `if (g_game.getFeature(Otc::GameThingClock) && (item->hasClockExpire() || item->hasExpire() || item->hasExpireStop())) {`; :4576 `if (g_game.getFeature(Otc::GameThingUpgradeClassification) && item->getClassification()) {`
- **Claim**: §3.3 lists `protocolgameparse.cpp:2018  isValidDatId(effectId, ThingCategoryEffect)  parseMagicEffect` as a live bounds check.
  - **Correction**: Dead code at 1530. Line 2018 sits in the legacy tail of `parseMagicEffect`, after the `if (g_game.getProtocolVersion() >= 1203) { ... return; }` block that unconditionally returns at line 2008. At protocol 1530 that tail is never reached. Harmless, but it inflates the list of checks an implementer thinks they need.
  - Evidence: protocolgameparse.cpp:1940 `if (g_game.getProtocolVersion() >= 1203) {` ... :2008 `return;` ... :2011 `uint16_t effectId = g_game.getFeature(Otc::GameMagicEffectU16) ? msg->getU16() : msg->getU8();` :2017 `if (!g_things.isValidDatId(effectId, ThingCategoryEffect)) {`

### Additions
- VERIFIED CORRECT — every measured number in the spec reproduces exactly against D:/Claude/otclient_mehah1530/otclient/data/things/1530/appearances-17a72b30b5c3c9ca8c1283cfb2febd2a93a145ff8ab66916f7a412d0f1dee5a1.dat (5,017,714 B): object/outfit/effect/missile counts 43,536 / 1,475 / 243 / 76; max ids 62,144 / 10,003 / 343 / 82; 7,486 non-zero flag bytes under the spec's exact bit encoding; `animate_always` (field 29) 0 occurrences; no wire type 1 or 5 anywhere; no flag field number above 64; no duplicate object ids; no id >= 65536; id 0 absent; file head `0a 93 01 08 64 12 78` = field 1 LEN len=147, id=100. §3.5's extras counts are also exact: unpass 16697, unmove 31818, unsight 5925, avoid 2055, take 7221, clip 6312, bottom 11212, top 1267, lying_object 1890, bank 3354 (waypoints 0..1200), automap 15777 (color 0..215), height 2194 (elevation 0..24).
- VERIFIED CORRECT — assets.json.sha256 is exactly 5 bytes `34 32 31 39 36` = "42196", no newline, no BOM; 42196 <= 65535 so it is accepted; the wire bytes `05 00 34 32 31 39 36` are right, and `addString` is u16 LE length + raw bytes (framework/net/outputmessage.cpp:84-94, `addU16(len)` then `memcpy`). The isGunzOs branch is taken: features.lua:305 `g_game.setCustomOs(61)` and Game::getOs (game.cpp:1793-1796) returns m_clientCustomOs when > CLIENTOS_NONE, so osValue == 61 ∈ [60,62].
- VERIFIED CORRECT — the gunz block ORDER (counter → clock → container → tier → podium → decokit) and the container-type switch (1→u32, 2→u32, 3→u32+u32, 4→no bytes, 8→u32, 9→u32 +u32 at cv>=1332, 11→u32+u32 +u32 at cv>=1332, default→none) match protocolgameparse.cpp:4581-4649 byte for byte. The podium layout (u16 looktype; if !=0 five u8; else u16 lookTypeEx under GameThingPodiumItemType; u16 lookmount; if !=0 four u8; u8 dir; u8 visible) matches :4651-4675. `isChargeable` really is unreachable on the protobuf path — `ThingFlagAttrChargeable` is only ever produced from legacy `ThingAttrChargeable = 254` in ThingType::unserialize (thingtype.cpp:534, :1112, :1186); applyAppearanceFlags never sets it.
- VERIFIED CORRECT — the has_-only vs has_&&value distinction is exactly as the spec states. Presence-only: bank (thingtype.cpp:179), bottom (:187), top (:191), write (:217), write_once (:222), light (:280), shift (:298), height (:303), automap (:315), lenshelp (:320), clothes (:333), market (:341), default_action (:369), cyclopediaitem (:397), upgradeclassification (:410), proficiency (:449, additionally gated on GameProficiency), skillwheel_gem (:456), imbueable (:468), minimum_level (:477), weapon_type (:482). Presence AND truth: clip, container, cumulative, liquidpool, liquidcontainer, unpass, unmove, unsight, avoid, take, hang, lying_object, animate_always, fullbank, show_off_socket, wearout, clockexpire, expire, expirestop, deco_kit.
- VERIFIED CORRECT — §7 holds. `grep g_sounds|g_spriteAppearances|g_sprites\.` over protocolgameparse.cpp returns zero hits. `special_meaning_appearance_ids` has zero references in src/ and modules/ (it IS present once in the real file as top-level tag 5 wire type 2, so a top-level iterator must skip it — the spec's `if topField >= 1 and topField <= 4` does). `parsePlayerInventory` (protocolgameparse.cpp:3923-3934) is genuinely non-byte-consuming: itemId u16, attribute u8, amount are all read unconditionally and classification only reinterprets `attribute` as tier. The weapon-proficiency site (:7610) is likewise non-byte-consuming.
- USEFUL EXTRA DATA for the extractor's self-check: per-bit population of the spec's flag byte over the real file — bit0 READ_COUNT 2,653; bit1 READ_CHARGES 92; bit2 READ_DURATION 338; bit3 READ_CONTAINER 3,381; bit4 READ_TIER 1,016; bit5 READ_PODIUM 5; bit6 READ_DECOKIT 1. Total non-zero slots 7,486, matching the spec. `upgradeclassification` is present on 1,016 objects and its `upgrade_classification` value is never 0 (distribution: 1→311, 2→294, 3→88, 4→323), so the has_-only-vs-value>0 ambiguity the spec flags is moot for this asset set — but the spec's `value > 0` rule is the correct one to code, since getItem tests `item->getClassification()` (the value), not presence. Also note items 3457 and 408 both have flag byte 0x00, so the hardcoded short-circuit is not masking any attribute bytes here.
- MISSING FORMULA, should the animation-phase gate ever be re-enabled by parseFeatures: `m_animationPhases` is NOT a protobuf field — it is `sum over frame_group of max(1, sprite_phase_count)`, where sprite_phase is FrameGroup(2).sprite_info(3).animation(6).sprite_phase(6). See thingtype.cpp:69-83: `const int groupPhases = std::max<int>(1, spritesPhases.size()); m_animationPhases += groupPhases;`. Extracting a 1-byte-per-id `phases > 1` table would cost the same 62 KB as the flag table and would make the client robust to a server-side GameItemAnimationPhase toggle; today it is genuinely unused.
- AMBIGUITY in §5.1 vs §6: the header bakes `u16 LE contentRevision (42196)` into items1530.bin at extraction time, while §6/PART C re-parses assets.json.sha256 at runtime. If the asset set is updated and only one of the two is refreshed they disagree silently, and the login packet would be wrong. Either drop the header field or state explicitly that the runtime parse is authoritative and the header copy is diagnostic only.
- MINOR — §6.1's probe order is right but worth restating precisely: the loop is `for each path: if (!fileExists(path)) continue; try contents = readFileContents(path); catch { contents.clear(); } if (!contents.empty()) break;`. So a path that exists but reads empty or throws falls through to the next candidate, and if both fail `contents` stays empty and from_chars yields ec != {} → return 0. The spec's Lua PART C is behaviourally equivalent, including trim semantics (stdext::trimSpacesAndNewlines uses std::isspace, the same set Lua's %s matches) and the whole-string-consumed requirement (`result.ptr == end` ≡ `^%d+$`). protocolgamesend.cpp:65-97.
- MINOR — §6.2's parenthetical is self-contradictory as printed: "the wire string would be **`"0"`** (`02 00 30`... no — `01 00 30`, u16 len=1, `'0'`)". The correct bytes are `01 00 30`; the stray `02 00 30` should be deleted before anyone codes from it.
- MINOR — the §1 quotation of things.lua is a paraphrase, not the source. The real code checks each return value and accumulates an error list; on any failure it shows an error box and calls `g_game.setClientVersion(0)` / `setProtocolVersion(0)`. Sounds load at things.lua:92 only after `loaded` is true, exactly as the spec says. Also `getCatalogContent` caches by resolved path in a member (thingtypemanager.cpp:46-56), irrelevant to a Lua reimplementation that reads the file once offline.
