# Map description, tile and thing serialization (ProtocolGame parse side) — protocol/client 1530, Gunzodus, OS 61

# Map / Tile / Thing wire specification — client version 1530, OS id 61 (Gunzodus)

All integers are **little-endian, unsigned**. Primitive readers (`src/framework/net/inputmessage.cpp:52-99`):

| reader | bytes | note |
|---|---|---|
| `u8` | 1 | |
| `u16` | 2 | `readULE16` |
| `u32` | 4 | `readULE32` |
| `u64` | 8 | |
| `string` | 2 + N | `u16` length prefix, then N raw bytes (no NUL) — `inputmessage.cpp:92-99` |
| `peekU16` | 0 | read `u16`, rewind 2 (`inputmessage.h:63-66`) |

---

## 0. Feature flags — resolved values for 1530

`Game::setClientVersion` (`src/client/game.cpp:1727-1743`) does `m_features.reset()` then fires the Lua hook. **All features come exclusively from `modules/game_features/features.lua`** — there is no C++ default set. A feature not listed there is **OFF** unless the server later toggles it with `GameServerFeatures` (opcode 67, `protocolgameparse.cpp:7501-7513`: `u16 count`, then `count × {u8 featureId, u8 enabled}`).

Flags that this area consults, with their 1530 value and enum id (`src/client/const.h`):

| Feature | id | 1530 | Source |
|---|---|---|---|
| `GameLooktypeU16` | 42 | **ON** (>=770) | features.lua:24 |
| `GamePlayerAddons` | 44 | **ON** (>=780) | features.lua:32 |
| `GamePlayerMounts` | 12 | **ON** (>=870) | features.lua:70 |
| `GameTileAddThingWithStackpos` | 124 | **ON** (>=841) | features.lua:53 |
| `GameCreatureEmblems` | 14 | **ON** (>=854) | features.lua:57 |
| `GameEnvironmentEffect` | 13 | **OFF** — enabled at 910, **disabled again at >=1281** | features.lua:79 then :216 |
| `GameItemAnimationPhase` | 15 | **OFF** — enabled at 910, **disabled at >=1281** | features.lua:80 then :217 |
| `GameThingMarks` | 41 | **ON** (>=1000) | features.lua:121 |
| `GameCreatureIcons` | 54 | **ON** (>=1036) | features.lua:132 |
| `GameThingQuickLoot` | 83 | ON (>=1200) but shadowed by `GameContainerTypes` | features.lua:190 |
| `GameThingQuiver` | 84 | ON (>=1260) but shadowed | features.lua:198 |
| `GameThingPodium` | 85 | **ON** (>=1264) | features.lua:202 |
| `GameThingUpgradeClassification` | 86 | **ON** (>=1272) | features.lua:206 |
| `GameThingClock` | 88 | **ON** (>=1290) | features.lua:218 |
| `GameThingCounter` | 87 | **ON** (>=1290) | features.lua:219 |
| `GameThingPodiumItemType` | 89 | **ON** (>=1290) | features.lua:220 |
| `GameContainerTypes` | 106 | **ON** (>=1320) | features.lua:239 |
| `GameWrapKit` | 112 | **ON** (>=1321) | features.lua:248 |
| `GameCountU16` | 104 | **OFF** — never enabled anywhere | absent from features.lua |
| `GameMapMovePosition` | 31 | **OFF** — never enabled | absent |
| `GameItemShader` | 101 | **OFF** | absent |
| `GameItemTooltipV8` | 117 | **OFF** | absent |
| `GameCreatureShader` | 102 | **OFF** | absent |
| `GameCreatureAttachedEffect` | 103 | **OFF** | absent |
| `GameCreaturePaperdoll` | 128 | **OFF** — commented out | features.lua:8 |
| `GameWingsAurasEffectsShader` | 118 | **OFF** — commented out | features.lua:7 |

Version predicates used directly (not features): `cv >= 854`, `>= 910`, `>= 953`, `>= 1185`, `>= 1281`, `>= 1332`, `>= 1530` — all TRUE at 1530 except none; `cv < 1281` / `cv < 1076` are FALSE.

**OS gate.** `features.lua:280-281` calls `g_game.setCustomOs(61)`. `Game::getOs()` (`game.cpp:1793-1805`) returns the custom OS when > 0, so `getOs() == 61 == Otc::CLIENTOS_GUNZ_WINDOWS` (`const.h:38-40`: GUNZ_LINUX=60, WINDOWS=61, MAC=62). Therefore in `getItem`:

```cpp
const auto osValue = static_cast<uint16_t>(g_game.getOs());
const bool isGunzOs = osValue >= Otc::CLIENTOS_GUNZ_LINUX && osValue <= Otc::CLIENTOS_GUNZ_MAC;
```
(`protocolgameparse.cpp:4531-4533`) → **`isGunzOs == true`**. This reorders the item attribute blocks (§4).

---

## 1. Geometry constants

From `data/setup.otml` → `GameConfig::loadMapNode` (`gameconfig.cpp:171-186`) and `loadTileNode` (`:190-196`):

| otml key | member | value |
|---|---|---|
| `map.viewport: 8 6` | `m_mapViewPort` | `{w=8, h=6}` |
| `map.max-z: 15` | `getMapMaxZ()` | **15** |
| `map.sea-floor: 7` | `getMapSeaFloor()` | **7** |
| `map.underground-floor: 8` | `getMapUndergroundFloorRange()` | **8** (misleading name — it is the classic `UNDERGROUND_FLOOR` constant, not a range) |
| `map.aware-underground-floor-range: 2` | `getMapAwareUndergroundFloorRange()` | **2** |
| `tile.max-things: 10` | `getTileMaxThings()` | **10** (diagnostic only, see §3) |

**Aware range** (`src/client/staticdata.h:37-51`, `Map::resetAwareRange` `map.cpp:806-813`):

```cpp
setAwareRange({ .left = viewPort.width(),      // 8
                .top  = viewPort.height(),     // 6
                .right= viewPort.width() + 1,  // 9
                .bottom=viewPort.height()+ 1 });//7
```
`horizontal() = left+right+1 = 18`, `vertical() = top+bottom+1 = 14`.

**Fixed 1530 values: left=8, top=6, right=9, bottom=7, width=18, height=14.**

The server may change this at runtime with `GameServerChangeMapAwareRange = 51` (`protocolgameparse.cpp:4000-4013`):
```
u8 xRange, u8 yRange
left  = xRange/2 - (xRange+1)%2
top   = yRange/2 - (yRange+1)%2
right = xRange/2
bottom= yRange/2
```
(For xRange=18, yRange=14 this reproduces 8/6/9/7.) A Lua client MUST keep `awareRange` as mutable state because every subsequent map packet's dimensions derive from it.

---

## 2. Full map description — `setMapDescription`

`protocolgameparse.cpp:4068-4089`:

```cpp
if (z > g_gameConfig.getMapSeaFloor()) {           // z > 7  (underground)
    startz = z - 2;                                 // AwareUndergroundFloorRange
    endz   = std::min<int>(z + 2, 15);              // MapMaxZ
    zstep  = 1;
} else {                                            // z <= 7 (surface)
    startz = 7;                                     // MapSeaFloor
    endz   = 0;
    zstep  = -1;
}
int skip = 0;
for (auto nz = startz; nz != endz + zstep; nz += zstep)
    skip = setFloorDescription(msg, x, y, nz, width, height, z - nz, skip);
```

* **Surface (`z <= 7`)**: floors are sent **7,6,5,4,3,2,1,0** — 8 floors, top-most last. Projection `offset = z - nz`.
* **Underground (`z > 7`)**: floors `z-2 … min(z+2,15)` ascending — up to 5 floors (fewer near z=14/15: e.g. z=14 → 12..15 = 4 floors; z=15 → 13..15 = 3 floors).
* `skip` is a **single run-length counter threaded through every floor of the packet** — an empty run may span a floor boundary.

`setFloorDescription` (`:4091-4105`):
```cpp
for (nx = 0; nx < width; ++nx)
  for (ny = 0; ny < height; ++ny) {
      Position tilePos(x + nx + offset, y + ny + offset, z);
      if (skip == 0) skip = setTileDescription(msg, tilePos);
      else { g_map.cleanTile(tilePos); --skip; }
  }
return skip;
```
**Iteration is X-major, Y-minor** (column by column). Both `x` and `y` get `+offset` (floor projection).

Total tiles in a full description at 1530: surface 8 × 18 × 14 = **2016**; underground 3–5 × 252.

### Packet: `GameServerFullMap = 100` (0x64) → `parseMapDescription` (`:1480-1500`)
```
Position pos      // u16 x, u16 y, u8 z
<setMapDescription(pos.x - 8, pos.y - 6, pos.z, 18, 14)>
```
Sets central position = pos.

### Packet: `GameServerFloorDescription = 75` (0x4B) → `parseFloorDescription` (`:1451-1476`)
```
Position pos      // u16 x, u16 y, u8 z
u8  floor
<setFloorDescription(pos.x - 8, pos.y - 6, floor, 18, 14, pos.z - floor, skip=0)>
```
Single floor only; when `pos.z == floor` it also re-centers the map.

---

## 3. `setTileDescription` — the per-tile stack (`:4108-4137`)

```cpp
int ProtocolGame::setTileDescription(const InputMessagePtr& msg, const Position position)
{
    g_map.cleanTile(position);
    bool gotEffect = false;
    for (auto stackPos = 0; stackPos < 256; ++stackPos) {
        if (msg->peekU16() >= 0xff00) {
            return msg->getU16() & 0xff;
        }
        if (g_game.getFeature(Otc::GameEnvironmentEffect) && !gotEffect) {
            msg->getU16(); // environment effect
            gotEffect = true;
            continue;
        }
        if (stackPos > g_gameConfig.getTileMaxThings()) {
            g_logger.traceError("...too many things...");
        }
        const auto& thing = getThing(msg);
        ...
        g_map.addThing(thing, position, stackPos);
    }
    return 0;
}
```

**Terminator / skip marker.** Peek a `u16`; if `>= 0xFF00` consume it and return `value & 0xFF`. Because the read is little-endian, on the wire this is **two bytes: `[skipCount] [0xFF]`** — byte 0 is the skip count (0..255), byte 1 is 0xFF. Legal item ids can never reach 0xFF00 (creature markers are 0x0061/0x0062/0x0063), so the discrimination is unambiguous.

**Skip semantics.** The marker is peeked *at the start of every tile's parse*, so it doubles as (a) the end-of-stack terminator for the tile just parsed and (b) a run of empty tiles:
* `setTileDescription(T)` reads things until it sees the marker, returns `N`.
* The **current tile's** description is complete; the **next `N`** tiles in the (x-major) iteration are empty and consume no bytes.
* Two adjacent non-empty tiles are separated by `[0x00][0xFF]`.
* A run of `k` leading empty tiles before a non-empty one appears as `[k-1][0xFF]` consumed while parsing the *first* of them.
* The description always ends with a marker (server writes the pending skip, which is `0` after a non-empty last tile).
* Max run per marker is 255 (server emits `[0xFF][0xFF]` and restarts when it saturates).

**Ordering inside a tile.** The wire order is the server's `GetTileDescription` order: ground item, then ground-border/on-bottom items, then on-top items, then creatures, then remaining (down) items. The client does not re-sort here — `addThing(thing, position, stackPos)` is called with the explicit loop index, and `Tile::addThing` (`tile.cpp:332-359`) only auto-places when `stackPos < 0 || stackPos == 255`; with `0 <= stackPos <= size` it inserts at exactly that index. **So for full/floor/tile descriptions, the tile array index == wire order index.** A Lua client can simply append.

**The "10 things" limit is NOT a parse bound.** `getTileMaxThings() == 10` only produces a log line (`:4124-4126`). The real loop bound is `stackPos < 256` and the real terminator is the 0xFFxx marker. A parser that stops after 10 things desyncs.

**Environment effect: absent at 1530.** `GameEnvironmentEffect` is enabled at >=910 and *disabled again* at >=1281 (`features.lua:79`, `:216`), so the `u16` at `:4119` is **never read**. (If it were on, it would be a single `u16` consumed once, before the first thing, and it does not consume a `stackPos` slot because of the `continue`.)

### Packet: `GameServerUpdateTile = 105` (0x69) → `parseUpdateTile` (`:1543-1547`)
```
Position pos      // u16,u16,u8
<setTileDescription(pos)>   // return value discarded
```
Note the returned skip is **discarded**, so this packet must be self-contained.

---

## 4. `getThing` / `getItem` / `getCreature`

### `getThing` (`:4206-4218`)
```cpp
const uint16_t id = msg->getU16();
if (id == 0) throw;                               // hard error
if (id == 97 || id == 98 || id == 99) return getCreature(msg, id);
return getItem(msg, id);
```
`Proto::UnknownCreature = 97 (0x61)`, `OutdatedCreature = 98 (0x62)`, `Creature = 99 (0x63)` (`protocolcodes.h:40-42`). (`StaticText = 96` is declared but never handled in `getThing` — id 96 falls through to `getItem`.)

### `getItem(msg, id)` — `:4510-4698` — **1530 + isGunzOs order**

Sequence (each line = a conditional read; conditions in evaluation order):

1. `if id == 0: id = u16`.
2. `Item::create(id)` → `Item::setId` (`item.cpp:267-277`) forces `id = 0` when `!g_things.isValidDatId(id, ThingCategoryItem)` (i.e. `1 <= id < appearanceCount`), and `getItem` then **throws** (`:4522-4524`). A Lua client should at minimum log/abort on ids outside its metadata table — the byte stream cannot be recovered.
3. **`:4537` — gunz early-out:** `if (isGunzOs && cv >= 1185 && (id == 3457 || id == 408)) return item;` — **zero attribute bytes** for these two ids. (3457 is the classic browse-field pseudo id; 408 unverified.)
4. `cv < 1281 && GameThingMarks` → `u8 mark`. **Not read at 1530.**
5. **Count / subtype** (`:4546-4548`): `if (isStackable() || isFluidContainer() || isSplash() || (!isGunzOs && isChargeable()))` → `GameCountU16 ? u16 : u8`. At 1530 with OS 61: **`u8`**, and `isChargeable` is *not* consulted.
6. `GameItemAnimationPhase` (**OFF**) → would read `u8` when `getAnimationPhases() > 1`. **Not read at 1530.**
7. **`readCounter()`** (`:4560-4565`, invoked at `:4582` because `isGunzOs`): `if (GameThingCounter && hasWearOut())` → `u32 charges`, `u8 isBrandNew`. → **5 bytes**.
8. **`readClock()`** (`:4567-4573`, invoked at `:4583`): `if (GameThingClock && (hasClockExpire() || hasExpire() || hasExpireStop()))` → `u32 durationTime`, `u8 isBrandNew`. → **5 bytes**.
9. **Container block** (`:4586-4645`): `if (isContainer())`. With `GameContainerTypes` ON: read `u8 containerType`, then
   | type | extra |
   |---|---|
   | 1 Loot Container | `u32` loot category flags |
   | 2 Content Counter | `u32` ammo total |
   | 3 Manager Unknown | `u32` loot flags, `u32` obtain flags |
   | 4 Loot Highlight | *(none — client-side effect only)* |
   | 8 Obtain | `u32` obtain flags |
   | 9 Manager | `u32` loot flags; **`u32` obtain flags if cv >= 1332** |
   | 11 Quiver Loot | `u32` loot flags, `u32` ammo total; **`u32` obtain flags if cv >= 1332** |
   | default (0,5,6,7,10,12+) | none |
   The `GameThingQuickLoot` / `GameThingQuiver` legacy branch (`:4629-4644`) is dead at 1530 because `GameContainerTypes` is ON.
10. **`readTier()`** (`:4575-4579`, invoked at `:4648` because `isGunzOs`): `if (GameThingUpgradeClassification && getClassification() != 0)` → `u8 tier`. Note the test is on the **value**, not on presence of the flag message.
11. **Podium block** (`:4651-4675`): `if (GameThingPodium && isPodium())`:
    ```
    u16 looktype
    if looktype != 0:  u8 head, u8 body, u8 legs, u8 feet, u8 addons
    elif GameThingPodiumItemType (ON):  u16 lookTypeEx
    u16 lookmount
    if lookmount != 0: u8 head, u8 body, u8 legs, u8 feet
    u8 direction
    u8 visible
    ```
12. `if (!isGunzOs) { readTier(); readClock(); readCounter(); }` — **skipped** for OS 61. This is the whole point of the reorder: upstream/crystalserver order is tier→clock→counter *after* the podium block; gunzotc's order is counter→clock→(container)→tier→podium.
13. **`GameWrapKit`** (`:4683-4687`): `if (isDecoKit())` → `u16`.
14. `GameItemShader` (**OFF**) → would read `string`.
15. `GameItemTooltipV8` (**OFF**) → would read `string`.

### `getCreature(msg, type)` — `:4248-4508`

`type == 0` → read `u16 type` from the wire first (`:4250-4252`; used by `parseCreatureData` subtype 0, `:4446`). Otherwise `type` is the marker already consumed by `getThing`.

`known = (type != 97)`.

#### Branch A — `type == 0x61 (97, UnknownCreature)` or `0x62 (98, OutdatedCreature)`

**A1. Identity**

*If `type == 0x62` (known):*
```
u32 creatureId
```
*If `type == 0x61` (unknown):*
```
u32 removeId          // creature to evict from the local cache
u32 id                // this creature's id
u8  creatureType      // cv >= 910; else derived from id ranges
if (cv >= 1281 && creatureType == 3 /*SummonOwn*/):  u32 masterId
string name           // u16 len + bytes
```
`Proto::CreatureType` (`protocolcodes.h:415-424`): Player=0, Monster=1, Npc=2, SummonOwn=3, SummonOther=4, Hidden=5, Unknown=0xFF. Id ranges (`:428-431`, only used when cv<910): Player `0x10000000..0x3FFFFFFF`, Monster `0x40000000..0x7FFFFFFF`, else Npc.

**A2. Common body** (both 0x61 and 0x62) — `:4343-4436`

```
u8   healthPercent                                        // :4343
u8   direction            // Otc::Direction, const.h:158-169: N=0,E=1,S=2,W=3,NE=4,SE=5,SW=6,NW=7
<Outfit>                  // getOutfit(msg, parseMount=true)   :4345  — see §5
u8   lightIntensity                                       // :4348
u8   lightColor                                           // :4349
u16  speed                                                // :4351
<CreatureIconList>        // cv >= 1281                       :4354
<CreatureIconList>        // cv >= 1530  (SECOND list)        :4358
u8   skull                                                // :4361
u8   shield                                               // :4362
if (GameCreatureEmblems && !known):  u8 emblem            // :4370-4372  ONLY for 0x61
if (GameThingMarks):                 u8 creatureType      // :4374-4376  (ON at 1530)
if (cv >= 1281):                                          // :4379-4387
    if creatureType == 3 (SummonOwn):  u32 masterId
    elif creatureType == 0 (Player):   u8 vocationId
if (GameCreatureIcons):              u8 icon              // :4389-4391  (ON at 1530)
if (GameThingMarks):                 u8 mark              // :4393-4395  (0xFF = clear square)
    if (cv < 1281):                  u16 helpers          // NOT read at 1530
if (cv >= 1281):                     u8 inspectionType    // :4406-4408
if (cv >= 854):                      u8 unpass            // :4410-4412  (passable = !unpass)
if (GameCreaturePaperdoll):  u8 size; size × <Paperdoll>  // OFF at 1530
if (GameCreatureShader):     string shader                // OFF at 1530
if (GameCreatureAttachedEffect): u8 n; n × u16 effectId   // OFF at 1530
```

**`<CreatureIconList>`** — `addCreatureIcon` (`:2358-2371`):
```
u8 count
count × {
    u8  icon
    u8  category      // 0x00 = monster, 0x01 = player?
    u16 count
    if (cv >= 1530): u8 trailer   // read and DISCARDED
}
```
At 1530 each entry is **5 bytes** and the list appears **twice** (`:4353-4359`): the first is `replace = true` (overwrites the creature's icon set), the second is `replace = false` (merge; an empty incoming list leaves the set untouched, matching on `(icon, category)` and keeping the greater `count`).

**`<Paperdoll>`** (`:7852-7860`, dead at 1530): `u16 id, u8 slot, u8 color, u8 head, u8 body, u8 legs, u8 feet, string shader`.

#### Branch B — `type == 0x63 (99, Creature)` — "creature turn" (`:4478-4497`)
```
u32 creatureId
u8  direction
if (cv >= 953):  u8 unpass
```
**Total 6 bytes** at 1530. Nothing else.

Any other `type` → `throw` (`:4504`).

---

## 5. `getOutfit(msg, parseMount)` — `:4139-4204`

```
u16 lookType                          // GameLooktypeU16 ON at 1530 (else u8)
if lookType != 0:
    u8 head
    u8 body
    u8 legs
    u8 feet
    u8 addons                         // GamePlayerAddons ON at 1530 (else absent, value 0)
else:
    u16 lookTypeEx                    // item-shaped outfit; 0 => invisible (effect id 13)

if (GamePlayerMounts && parseMount):  // ON at 1530
    u16 mount
    if (cv >= 1281 && mount != 0):  u8 mountHead, u8 mountBody, u8 mountLegs, u8 mountFeet

if (GameWingsAurasEffectsShader && parseMount):   // OFF at 1530
    u16 wings, u16 auras, u16 effects, string shader
```

**Validation only, no byte effect:** an invalid `lookType` for `ThingCategoryCreature` (or `lookTypeEx` for `ThingCategoryItem`) is clamped to 0 *after* the bytes were read — it never changes the byte count.

**Gotcha (outside this area but same helper):** `parseOpenOutfitWindow` (`:3229-3242`) calls `getOutfit`, then, when `cv >= 1281 && mount == 0`, reads the 4 mount colour bytes anyway — the outfit-window packet always carries them. Inside `getCreature` they are only present when `mount != 0`.

---

## 6. Movement / floor-change packets

`Otc::GameMapMovePosition` is **OFF** at 1530, so the four move packets and both floor-change packets carry **no leading position**; the client uses its own `centralPosition` (`:1505`, `:1515`, `:1525`, `:1535`, `:3182`, `:3206`).

Let `R = {left=8, top=6, right=9, bottom=7}`, `W = 18`, `H = 14`, and `p` = current central position.

| Opcode | Handler | New centre | Strip sent (via **`setMapDescription`**, i.e. the *full z loop* of §2) |
|---|---|---|---|
| `GameServerMapTopRow = 101` (0x65) | `parseMapMoveNorth` `:1503` | `p.y -= 1` | `x = p.x-8, y = p.y-6, z = p.z, w = 18, h = 1` — one **row** |
| `GameServerMapRightRow = 102` (0x66) | `parseMapMoveEast` `:1513` | `p.x += 1` | `x = p.x+9, y = p.y-6, w = 1, h = 14` — one **column** |
| `GameServerMapBottomRow = 103` (0x67) | `parseMapMoveSouth` `:1523` | `p.y += 1` | `x = p.x-8, y = p.y+7, w = 18, h = 1` |
| `GameServerMapLeftRow = 104` (0x68) | `parseMapMoveWest` `:1533` | `p.x -= 1` | `x = p.x-8, y = p.y-6, w = 1, h = 14` |

Note the centre is updated **before** computing the strip origin, and `setCentralPosition` is called **after** parsing. Because these go through `setMapDescription`, the strip is repeated for **every** floor in the z-window (8 floors on the surface, 3–5 underground), with `skip` threaded across all of them.

### `GameServerFloorChangeUp = 190` (0xBE) — `parseFloorChangeUp` (`:3179-3201`)
```cpp
pos = centralPosition; --pos.z;
int skip = 0;
if (pos.z == 7 /*MapSeaFloor*/) {
    for (int i = 7 - 2; i >= 0; --i)                 // i = 5,4,3,2,1,0
        skip = setFloorDescription(msg, pos.x-8, pos.y-6, i, 18, 14, 8 - i, skip);
} else if (pos.z > 7) {
    setFloorDescription(msg, pos.x-8, pos.y-6, pos.z - 2, 18, 14, 3, skip);   // return discarded
}
centralPosition = { pos.x + 1, pos.y + 1, pos.z };
```
* Surfacing (new z == 7): **6 floors, 5→0**, offsets `8-i` = 3,4,5,6,7,8; `skip` threaded across them.
* Still underground (new z > 7): **1 floor** `pos.z - 2`, offset 3.
* New z < 7 (i.e. was already at/above sea level): **no map data at all** — packet body is empty.
* The `+1/+1` on x,y is the classic diagonal stair adjustment; it is client-side bookkeeping, not bytes.

### `GameServerFloorChangeDown = 191` (0xBF) — `parseFloorChangeDown` (`:3203-3227`)
```cpp
pos = centralPosition; ++pos.z;
int skip = 0;
if (pos.z == 8 /*getMapUndergroundFloorRange()*/) {
    for (int i = pos.z, j = -1; i <= pos.z + 2; ++i, --j)   // i=8,9,10 ; j=-1,-2,-3
        skip = setFloorDescription(msg, pos.x-8, pos.y-6, i, 18, 14, j, skip);
} else if (pos.z > 8 && pos.z < 15 - 1 /*MapMaxZ-1 == 14*/) {
    setFloorDescription(msg, pos.x-8, pos.y-6, pos.z + 2, 18, 14, -3, skip);
}
centralPosition = { pos.x - 1, pos.y - 1, pos.z };
```
* Entering underground (new z == 8): **3 floors, 8→10**, offsets −1,−2,−3.
* Deeper (8 < new z < 14): **1 floor** `pos.z + 2`, offset −3.
* new z <= 7, or new z >= 14: **no map data**.

### Tile-delta packets
| Opcode | Handler | Body |
|---|---|---|
| `GameServerCreateOnMap = 106` (0x6A) | `parseTileAddThing` `:1549` | `Position pos`; `u8 stackPos` (because `GameTileAddThingWithStackpos` is ON; otherwise `-1` = auto); `<Thing>` |
| `GameServerChangeOnMap = 107` (0x6B) | `parseTileTransformThing` `:1558` | `<MappedThingRef>`; `<Thing>` |
| `GameServerDeleteOnMap = 108` (0x6C) | `parseTileRemoveThing` `:1579` | `<MappedThingRef>` |
| `GameServerMoveCreature = 109` (0x6D) | `parseCreatureMove` `:1591` | `<MappedThingRef>`; `Position newPos` |

**`<MappedThingRef>`** — `getMappedThing` (`:4220-4246`):
```
u16 x
if x != 0xFFFF:
    u16 y
    u8  z
    u8  stackpos      // index into the tile array (never 0xFF)
else:
    u32 creatureId
```

**`<Position>`** — `getPosition` (`:4700-4706`): `u16 x, u16 y, u8 z`.

Note `parseTileAddThing` passes the server's `stackPos` straight to `Tile::addThing`; because it is `>= 0` and `<= size`, it is a literal insertion index (`tile.cpp:354-359`). Only `stackPos == 255` or `< 0` triggers the priority auto-placement (`tile.cpp:332-353`, priorities from `Thing::getStackPriority`, `thing.cpp:54+`: ground=0, ground-border=1, on-bottom=2, on-top=3, creature=4, item=5; for `cv >= 854` creatures **append** rather than prepend).

---

## 7. The metadata question — the stream is **NOT** parseable without item flags

**Proof.** In `getItem` the *number of bytes consumed* is a function of `ThingType` flags that never appear on the wire:

```cpp
// protocolgameparse.cpp:4546
if (item->isStackable() || item->isFluidContainer() || item->isSplash() || (!isGunzOs && item->isChargeable()))
    item->setCountOrSubType(g_game.getFeature(Otc::GameCountU16) ? msg->getU16() : msg->getU8());
```
Two items with different ids and otherwise identical wire context differ by exactly one byte depending solely on `isStackable`. The same holds at `:4561` (`hasWearOut` → 5 bytes), `:4568-4569` (`hasClockExpire||hasExpire||hasExpireStop` → 5 bytes), `:4576` (`getClassification() != 0` → 1 byte), `:4586` (`isContainer` → 1..9 bytes), `:4652` (`isPodium` → 4..13 bytes), `:4684` (`isDecoKit` → 2 bytes). And a mis-sized item read desynchronises the whole tile/floor/map description, because tile boundaries are found by *peeking* for `0xFFxx` rather than by any length prefix.

**Therefore a pure-Lua client MUST carry an item-metadata table keyed by client id.** Minimum contents (nothing else in this area is consulted):

| field | type | consulted at | protobuf source |
|---|---|---|---|
| `stackable` | bool | `:4546` | `AppearanceFlags.cumulative = 6` (`thingtype.cpp:200-202`) |
| `fluidContainer` | bool | `:4546` | `liquidcontainer = 19` (`thingtype.cpp:252-254`) |
| `splash` | bool | `:4546` | `liquidpool = 12` (`thingtype.cpp:226-228`) |
| `wearOut` | bool | `:4561` | `wearout = 53` (`thingtype.cpp:419-421`) |
| `clockExpire` | bool | `:4568` | `clockexpire = 54` (`:423-425`) |
| `expire` | bool | `:4569` | `expire = 55` (`:427-429`) |
| `expireStop` | bool | `:4569` | `expirestop = 56` (`:431-433`) |
| `container` | bool | `:4586` | `container = 5` (`:196-198`) |
| `classification` | uint | `:4576` | `upgradeclassification = 48 → upgrade_classification = 1` (`:410-412`) |
| `podium` | bool | `:4652` | `show_off_socket = 46` (`:404-406`) |
| `decoKit` | bool | `:4684` | `deco_kit = 57` (`:435-437`) |
| `validIds` | id range | `item.cpp:269` | `1 <= id < maxAppearanceId+1` |

**Not needed at 1530:** `isChargeable` (skipped by the gunz branch, and never set at all from appearances — `ThingFlagAttrChargeable` only exists in the legacy `.dat` path, `thingtype.cpp:1112`), `getAnimationPhases` (`GameItemAnimationPhase` OFF), `isAnimateAlways`, `getMarketData`, and every render-only flag.

For **creatures** the only metadata used is `g_things.isValidDatId(lookType, ThingCategoryCreature)` / `(lookTypeEx, ThingCategoryItem)` (`:4162`, `:4183`) — validation only, **zero byte-count effect**. So creature/outfit parsing needs no metadata.

**Where to get it.** `data/things/1530/appearances-<sha256>.dat` is a protobuf `otclient.protobuf.appearances.Appearances` (`src/protobuf/appearances.proto`), loaded by `ThingTypeManager::loadAppearances` (`thingtypemanager.cpp:166-236`). Relevant field numbers: `Appearances.object = 1` (repeated `Appearance`), `Appearance.id = 1`, `Appearance.flags = 3`; then the `AppearanceFlags` field numbers in the table above. Ids are used **as array indices** (`things.resize(lastAppearanceId + 1)`, `:224-232`), so the id space is dense-ish and sparse gaps are the null ThingType (→ `isValidDatId` true but all flags false — note `isValidDatId` only bounds-checks, it does not detect holes). Practical approach for Lua: run a one-off extraction into a compact table (`id → bitmask + classification`) and load that at startup; a full protobuf parser at runtime is unnecessary since only ~11 scalar fields matter.


## Pseudocode

-- ============================================================
-- 1530 / OS 61 map-description parser (LuaJIT, pure Lua)
-- msg = { buf = <string or ffi u8*>, pos = <1-based read cursor> }
-- ============================================================

local FEAT = {                      -- resolved for cv=1530 (features.lua)
  LooktypeU16=true, PlayerAddons=true, PlayerMounts=true,
  TileAddThingWithStackpos=true, CreatureEmblems=true,
  EnvironmentEffect=false,          -- enabled@910, DISABLED@1281
  ItemAnimationPhase=false,         -- enabled@910, DISABLED@1281
  ThingMarks=true, CreatureIcons=true,
  ThingPodium=true, ThingPodiumItemType=true,
  ThingUpgradeClassification=true, ThingClock=true, ThingCounter=true,
  ContainerTypes=true, WrapKit=true,
  CountU16=false, MapMovePosition=false,
  ItemShader=false, ItemTooltipV8=false,
  CreatureShader=false, CreatureAttachedEffect=false,
  CreaturePaperdoll=false, WingsAurasEffectsShader=false,
}
local CV   = 1530
local OS   = 61
local GUNZ = (OS >= 60 and OS <= 62)          -- protocolgameparse.cpp:4531-4533

local CFG = { seaFloor=7, maxZ=15, undergroundFloor=8, awareUgRange=2, tileMaxThings=10 }
local aware = { left=8, top=6, right=9, bottom=7 }
local function AW()  return aware.left + aware.right + 1  end   -- 18
local function AH()  return aware.top  + aware.bottom + 1 end   -- 14

-- ---------- primitives (little-endian) ----------
local function u8 (m) local v=m.buf:byte(m.pos); m.pos=m.pos+1; return v end
local function u16(m) local a,b=m.buf:byte(m.pos,m.pos+1); m.pos=m.pos+2; return a+b*256 end
local function u32(m) local a,b,c,d=m.buf:byte(m.pos,m.pos+3); m.pos=m.pos+4
                      return a+b*256+c*65536+d*16777216 end
local function peek16(m) local a,b=m.buf:byte(m.pos,m.pos+1); return a+b*256 end
local function str(m) local n=u16(m); local s=m.buf:sub(m.pos,m.pos+n-1); m.pos=m.pos+n; return s end
local function pos_(m) return { x=u16(m), y=u16(m), z=u8(m) } end

-- ---------- item metadata (MANDATORY, see spec §7) ----------
-- ITEMS[id] = { stackable, fluid, splash, wearOut, clockExpire, expire,
--               expireStop, container, classification, podium, decoKit }
local ITEMS = require("appearances_flags")

-- ---------- outfit ----------
local function getOutfit(m, parseMount)
  if parseMount == nil then parseMount = true end
  local o = {}
  o.lookType = FEAT.LooktypeU16 and u16(m) or u8(m)
  if o.lookType ~= 0 then
    o.head, o.body, o.legs, o.feet = u8(m), u8(m), u8(m), u8(m)
    o.addons = FEAT.PlayerAddons and u8(m) or 0
  else
    o.lookTypeEx = u16(m)                       -- 0 => invisible effect
  end
  if FEAT.PlayerMounts and parseMount then
    o.mount = u16(m)
    if CV >= 1281 and o.mount ~= 0 then
      o.mHead, o.mBody, o.mLegs, o.mFeet = u8(m), u8(m), u8(m), u8(m)
    end
  end
  if FEAT.WingsAurasEffectsShader and parseMount then   -- OFF at 1530
    o.wings, o.aura, o.effect = u16(m), u16(m), u16(m)
    o.shader = str(m)
  end
  return o
end

-- ---------- creature icon list (5 bytes/entry at 1530) ----------
local function getIconList(m)
  local n, list = u8(m), {}
  for i = 1, n do
    local icon, cat, cnt = u8(m), u8(m), u16(m)
    if CV >= 1530 then u8(m) end                -- trailer, discarded
    list[i] = { icon=icon, category=cat, count=cnt }
  end
  return list
end

-- ---------- creature ----------
local function getCreature(m, ty)
  if ty == 0 then ty = u16(m) end
  local known = (ty ~= 0x61)
  local c = {}

  if ty == 0x61 or ty == 0x62 then
    if known then                                -- 0x62 OutdatedCreature
      c.id = u32(m)
    else                                         -- 0x61 UnknownCreature
      c.removeId = u32(m)
      c.id       = u32(m)
      c.type     = (CV >= 910) and u8(m) or nil  -- always a byte at 1530
      if CV >= 1281 and c.type == 3 then c.masterId = u32(m) end
      c.name = str(m)
    end

    c.healthPercent = u8(m)
    c.direction     = u8(m)                      -- 0=N 1=E 2=S 3=W 4=NE 5=SE 6=SW 7=NW
    c.outfit        = getOutfit(m, true)
    c.lightIntensity, c.lightColor = u8(m), u8(m)
    c.speed         = u16(m)
    if CV >= 1281 then c.icons  = getIconList(m) end   -- replace
    if CV >= 1530 then c.icons2 = getIconList(m) end   -- merge
    c.skull  = u8(m)
    c.shield = u8(m)
    if FEAT.CreatureEmblems and not known then c.emblem = u8(m) end
    if FEAT.ThingMarks then c.type2 = u8(m) end
    if CV >= 1281 then
      if     c.type2 == 3 then c.masterId2 = u32(m)
      elseif c.type2 == 0 then c.vocation  = u8(m) end
    end
    if FEAT.CreatureIcons then c.icon = u8(m) end
    if FEAT.ThingMarks then
      c.mark = u8(m)                             -- 0xFF = clear square
      if CV < 1281 then u16(m) end               -- helpers (not at 1530)
    end
    if CV >= 1281 then c.inspection = u8(m) end
    if CV >=  854 then c.unpass     = u8(m) end
    if FEAT.CreaturePaperdoll then               -- OFF at 1530
      for i = 1, u8(m) do
        u16(m); u8(m); u8(m); u8(m); u8(m); u8(m); u8(m); str(m)
      end
    end
    if FEAT.CreatureShader          then c.shader = str(m) end
    if FEAT.CreatureAttachedEffect  then
      c.effects = {}
      for i = 1, u8(m) do c.effects[i] = u16(m) end
    end

  elseif ty == 0x63 then                         -- creature turn: 6 bytes
    c.id        = u32(m)
    c.direction = u8(m)
    if CV >= 953 then c.unpass = u8(m) end
  else
    error("invalid creature opcode " .. ty)
  end
  return c
end

-- ---------- item ----------
local function getItem(m, id)
  if not id or id == 0 then id = u16(m) end
  local T = ITEMS[id]
  if not T then error(("unknown item id %d - cannot size attributes"):format(id)) end
  local it = { id = id }

  if GUNZ and CV >= 1185 and (id == 3457 or id == 408) then return it end   -- :4537
  if CV < 1281 and FEAT.ThingMarks then u8(m) end                            -- not at 1530

  if T.stackable or T.fluid or T.splash or ((not GUNZ) and T.chargeable) then
    it.count = FEAT.CountU16 and u16(m) or u8(m)                             -- :4546
  end
  if FEAT.ItemAnimationPhase and (T.animPhases or 0) > 1 then u8(m) end      -- OFF

  local function readCounter()                                              -- :4560
    if FEAT.ThingCounter and T.wearOut then it.charges = u32(m); u8(m) end
  end
  local function readClock()                                                -- :4567
    if FEAT.ThingClock and (T.clockExpire or T.expire or T.expireStop) then
      it.duration = u32(m); u8(m)
    end
  end
  local function readTier()                                                 -- :4575
    if FEAT.ThingUpgradeClassification and (T.classification or 0) ~= 0 then
      it.tier = u8(m)
    end
  end

  if GUNZ then readCounter(); readClock() end                               -- :4581-4584

  if T.container then                                                       -- :4586
    if FEAT.ContainerTypes then
      local ct = u8(m)
      if     ct == 1 then u32(m)
      elseif ct == 2 then u32(m)
      elseif ct == 3 then u32(m); u32(m)
      elseif ct == 4 then -- client-side highlight only, 0 bytes
      elseif ct == 8 then u32(m)
      elseif ct == 9 then u32(m); if CV >= 1332 then u32(m) end
      elseif ct == 11 then u32(m); u32(m); if CV >= 1332 then u32(m) end
      end
    else                                                                    -- dead at 1530
      if FEAT.ThingQuickLoot and u8(m) ~= 0 then u32(m) end
      if FEAT.ThingQuiver    and u8(m) ~= 0 then u32(m) end
    end
  end

  if GUNZ then readTier() end                                               -- :4647

  if FEAT.ThingPodium and T.podium then                                     -- :4651
    local lt = u16(m)
    if lt ~= 0 then u8(m); u8(m); u8(m); u8(m); u8(m)
    elseif FEAT.ThingPodiumItemType then u16(m) end
    local lm = u16(m)
    if lm ~= 0 then u8(m); u8(m); u8(m); u8(m) end
    u8(m)  -- direction
    u8(m)  -- visible
  end

  if not GUNZ then readTier(); readClock(); readCounter() end               -- skipped

  if FEAT.WrapKit and T.decoKit then u16(m) end                             -- :4683
  if FEAT.ItemShader     then it.shader  = str(m) end                       -- OFF
  if FEAT.ItemTooltipV8  then it.tooltip = str(m) end                       -- OFF
  return it
end

-- ---------- thing ----------
local function getThing(m)
  local id = u16(m)
  if id == 0 then error("invalid thing id") end
  if id == 0x61 or id == 0x62 or id == 0x63 then
    return { kind = "creature", data = getCreature(m, id) }
  end
  return { kind = "item", data = getItem(m, id) }
end

-- ---------- tile ----------
-- returns the run-length of FOLLOWING empty tiles
local function setTileDescription(m, p)
  map.cleanTile(p)
  local gotEffect = false
  for stackPos = 0, 255 do
    if peek16(m) >= 0xFF00 then
      return u16(m) % 256                    -- wire bytes: [skip][0xFF]
    end
    if FEAT.EnvironmentEffect and not gotEffect then   -- OFF at 1530
      u16(m); gotEffect = true
    else
      -- NOTE: tileMaxThings(10) is a WARNING only; never break here
      map.addThing(p, stackPos, getThing(m)) -- stackPos>=0 => literal index
    end
  end
  return 0
end

-- ---------- floor ----------
local function setFloorDescription(m, x, y, z, w, h, offset, skip)
  for nx = 0, w - 1 do                       -- X-major, Y-minor
    for ny = 0, h - 1 do
      local p = { x = x + nx + offset, y = y + ny + offset, z = z }
      if skip == 0 then skip = setTileDescription(m, p)
      else map.cleanTile(p); skip = skip - 1 end
    end
  end
  return skip
end

-- ---------- map ----------
local function setMapDescription(m, x, y, z, w, h)
  local startz, endz, zstep
  if z > CFG.seaFloor then                                 -- underground
    startz = z - CFG.awareUgRange
    endz   = math.min(z + CFG.awareUgRange, CFG.maxZ)
    zstep  = 1
  else                                                     -- surface
    startz, endz, zstep = CFG.seaFloor, 0, -1              -- 7,6,5,4,3,2,1,0
  end
  local skip = 0
  local nz = startz
  while nz ~= endz + zstep do
    skip = setFloorDescription(m, x, y, nz, w, h, z - nz, skip)
    nz = nz + zstep
  end
end

-- ---------- packet handlers ----------
function parseMapDescription(m)                    -- opcode 100 (0x64)
  local p = pos_(m)
  map.centralPosition = p
  setMapDescription(m, p.x - aware.left, p.y - aware.top, p.z, AW(), AH())
end

function parseFloorDescription(m)                  -- opcode 75 (0x4B)
  local p, floor = pos_(m), u8(m)
  if p.z == floor then map.centralPosition = p end
  setFloorDescription(m, p.x - aware.left, p.y - aware.top, floor, AW(), AH(), p.z - floor, 0)
end

local function movePos(m)                          -- MapMovePosition is OFF at 1530
  if FEAT.MapMovePosition then return pos_(m) end
  local c = map.centralPosition
  return { x = c.x, y = c.y, z = c.z }
end

function parseMapMoveNorth(m)                      -- 101
  local p = movePos(m); p.y = p.y - 1
  setMapDescription(m, p.x - aware.left, p.y - aware.top, p.z, AW(), 1)
  map.centralPosition = p
end
function parseMapMoveEast(m)                       -- 102
  local p = movePos(m); p.x = p.x + 1
  setMapDescription(m, p.x + aware.right, p.y - aware.top, p.z, 1, AH())
  map.centralPosition = p
end
function parseMapMoveSouth(m)                      -- 103
  local p = movePos(m); p.y = p.y + 1
  setMapDescription(m, p.x - aware.left, p.y + aware.bottom, p.z, AW(), 1)
  map.centralPosition = p
end
function parseMapMoveWest(m)                       -- 104
  local p = movePos(m); p.x = p.x - 1
  setMapDescription(m, p.x - aware.left, p.y - aware.top, p.z, 1, AH())
  map.centralPosition = p
end

function parseFloorChangeUp(m)                     -- 190 (0xBE)
  local p = movePos(m); p.z = p.z - 1
  local skip = 0
  if p.z == CFG.seaFloor then
    for i = CFG.seaFloor - CFG.awareUgRange, 0, -1 do        -- 5..0
      skip = setFloorDescription(m, p.x-aware.left, p.y-aware.top, i, AW(), AH(), 8 - i, skip)
    end
  elseif p.z > CFG.seaFloor then
    setFloorDescription(m, p.x-aware.left, p.y-aware.top,
                        p.z - CFG.awareUgRange, AW(), AH(), 3, skip)
  end
  map.centralPosition = { x = p.x + 1, y = p.y + 1, z = p.z }
end

function parseFloorChangeDown(m)                   -- 191 (0xBF)
  local p = movePos(m); p.z = p.z + 1
  local skip = 0
  if p.z == CFG.undergroundFloor then              -- == 8
    local j = -1
    for i = p.z, p.z + CFG.awareUgRange do         -- 8,9,10 ; offsets -1,-2,-3
      skip = setFloorDescription(m, p.x-aware.left, p.y-aware.top, i, AW(), AH(), j, skip)
      j = j - 1
    end
  elseif p.z > CFG.undergroundFloor and p.z < CFG.maxZ - 1 then
    setFloorDescription(m, p.x-aware.left, p.y-aware.top,
                        p.z + CFG.awareUgRange, AW(), AH(), -3, skip)
  end
  map.centralPosition = { x = p.x - 1, y = p.y - 1, z = p.z }
end

function parseUpdateTile(m)                        -- 105 (0x69)
  setTileDescription(m, pos_(m))                   -- returned skip DISCARDED
end

local function getMappedThing(m)                   -- :4220
  local x = u16(m)
  if x ~= 0xFFFF then
    return { pos = { x = x, y = u16(m), z = u8(m) }, stackpos = u8(m) }
  end
  return { creatureId = u32(m) }
end

function parseTileAddThing(m)                      -- 106 (0x6A)
  local p  = pos_(m)
  local sp = FEAT.TileAddThingWithStackpos and u8(m) or -1
  map.addThing(p, sp, getThing(m))
end
function parseTileTransformThing(m)                -- 107 (0x6B)
  local ref = getMappedThing(m); local nt = getThing(m)
  map.replaceThing(ref, nt)
end
function parseTileRemoveThing(m)                   -- 108 (0x6C)
  map.removeThing(getMappedThing(m))
end
function parseCreatureMove(m)                      -- 109 (0x6D)
  local ref = getMappedThing(m); local newPos = pos_(m)
  map.moveThing(ref, newPos)                       -- inserted with stackpos = -1 (auto)
end

function parseChangeMapAwareRange(m)               -- 51 (0x33)
  local xr, yr = u8(m), u8(m)
  aware = {
    left   = math.floor(xr/2) - ((xr + 1) % 2),
    top    = math.floor(yr/2) - ((yr + 1) % 2),
    right  = math.floor(xr/2),
    bottom = math.floor(yr/2),
  }
end

function parseFeatures(m)                          -- 67 (0x43) - may flip any flag above!
  for i = 1, u16(m) do
    local fid, on = u8(m), u8(m)
    FEATURE_BY_ID[fid] = (on ~= 0)
  end
end


## Evidence
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4068 — setMapDescription: z>seaFloor(7) => startz=z-2, endz=min(z+2,15), zstep=1; else startz=7, endz=0, zstep=-1; single `skip` threaded across all floors
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4091 — setFloorDescription: X-major/Y-minor double loop, tilePos = (x+nx+offset, y+ny+offset, z), skip consumed one tile at a time
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4113-4116 — `for (stackPos=0; stackPos<256; ++stackPos) { if (msg->peekU16() >= 0xff00) return msg->getU16() & 0xff; ...}` — the tile terminator is a LE u16 with high byte 0xFF; low byte is the empty-run length
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4118-4122 — GameEnvironmentEffect u16 (once per tile, `continue` so it does not use a stackPos slot); the feature is OFF at 1530
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4124-4126 — getTileMaxThings()==10 only produces `traceError`; it is NOT a parse bound
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4133 — `g_map.addThing(thing, position, stackPos)` with the loop index => wire order == tile array index for descriptions
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4139-4204 — getOutfit: u16 lookType (GameLooktypeU16), 4 colour bytes + addons, else u16 lookTypeEx; mount u16 + 4 colour bytes when cv>=1281 && mount!=0; wings/aura/effect/shader block gated on GameWingsAurasEffectsShader (OFF)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4206-4218 — getThing: u16 id; 0 throws; 97/98/99 -> getCreature; else getItem
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4220-4246 — getMappedThing: u16 x; if != 0xFFFF then u16 y, u8 z, u8 stackpos; else u32 creatureId
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4248-4508 — getCreature full payload; 0x61 reads removeId+id+type+(masterId)+name, 0x62 reads only id, 0x63 is id+direction+unpass
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4353-4359 — TWO creature-icon lists at 1530: cv>=1281 (replace) then cv>=1530 (merge)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2358-2371 — addCreatureIcon: u8 count, then {u8 icon, u8 category, u16 count, +u8 trailer when cv>=1530} => 5 bytes/entry at 1530
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4370-4412 — emblem only when !known; ThingMarks creatureType; cv>=1281 masterId/vocation; CreatureIcons icon; ThingMarks mark (+u16 helpers only when cv<1281); cv>=1281 inspection u8; cv>=854 unpass u8
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4531-4533 — `isGunzOs` = getOs() in [60,62]; with setCustomOs(61) this is TRUE and reorders the getItem attribute blocks
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4537 — `if (isGunzOs && cv >= 1185 && (id == 3457 || id == 408)) return item;` — zero attribute bytes for those two ids
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4546-4548 — count/subtype read gated on isStackable()||isFluidContainer()||isSplash()||(!isGunzOs && isChargeable()); GameCountU16 is OFF so it is a u8. PROOF the stream needs item metadata
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4560-4579 — readCounter (ThingCounter && hasWearOut => u32+u8), readClock (ThingClock && (hasClockExpire||hasExpire||hasExpireStop) => u32+u8), readTier (UpgradeClassification && getClassification()!=0 => u8)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4581-4584 and 4647-4649 and 4677-4681 — gunz order is counter,clock,(container),tier,podium; the upstream order (tier,clock,counter AFTER podium) is skipped when isGunzOs
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4586-4645 — container block: GameContainerTypes ON => u8 type then per-type u32s (1,2,3,4,8,9,11); cases 9 and 11 read an extra u32 when cv>=1332
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4651-4675 — podium block: u16 looktype (+5 bytes) or u16 lookTypeEx via GameThingPodiumItemType; u16 lookmount (+4 bytes); u8 direction; u8 visible
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4683-4695 — WrapKit/isDecoKit u16; GameItemShader and GameItemTooltipV8 strings (both OFF at 1530)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4700-4706 — getPosition = u16 x, u16 y, u8 z
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1480-1500 — parseMapDescription: Position then setMapDescription(pos.x-left, pos.y-top, pos.z, horizontal, vertical)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1451-1476 — parseFloorDescription (opcode 75): Position + u8 floor + one floor description with offset pos.z-floor
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1503-1541 — the four map-move handlers; each uses setMapDescription (full z loop) with a 1-tile-thin strip; GameMapMovePosition (OFF) would prefix a Position
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1549-1556 — parseTileAddThing: Position, u8 stackpos (GameTileAddThingWithStackpos ON at 1530), then a Thing
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1591-1609 — parseCreatureMove: MappedThing ref then Position; re-added with stackpos -1 (auto placement)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:3179-3201 — parseFloorChangeUp: new z==7 => floors 5..0 with offset 8-i and threaded skip; new z>7 => single floor z-2 offset 3; centre gets +1/+1
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:3203-3227 — parseFloorChangeDown: new z==8 => floors 8,9,10 offsets -1,-2,-3; 8<z<14 => single floor z+2 offset -3; centre gets -1/-1
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4000-4013 — parseChangeMapAwareRange (opcode 51): u8 xRange, u8 yRange -> left=x/2-(x+1)%2, top=y/2-(y+1)%2, right=x/2, bottom=y/2
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:7501-7513 — parseFeatures (opcode 67): u16 count then count x {u8 id, u8 enabled}; the server can flip ANY of the flags this parser depends on
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:7852-7885 — getPaperdoll: u16 id, u8 slot, u8 color, u8 head, u8 body, u8 legs, u8 feet, string shader (dead at 1530)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:2434-2456 — parseCreatureData: u32 id, u8 subtype; subtype 0 calls getCreature(msg) with type=0, which reads a u16 marker from the wire
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolcodes.h:40-42 — UnknownCreature=97, OutdatedCreature=98, Creature=99 (StaticText=96 is declared but never handled in getThing)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolcodes.h:101-109,171,190-191 — GameServerFullMap=100, MapTopRow=101, MapRightRow=102, MapBottomRow=103, MapLeftRow=104, UpdateTile=105, CreateOnMap=106, ChangeOnMap=107, DeleteOnMap=108, MoveCreature=109, FloorDescription=75, FloorChangeUp=190, FloorChangeDown=191, ChangeMapAwareRange=51
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolcodes.h:415-431 — CreatureTypePlayer=0..SummonOwn=3, SummonOther=4, Hidden=5, Unknown=0xFF; PlayerStartId=0x10000000 etc (only used when cv<910)
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:29-40 — CLIENTOS_GUNZ_LINUX=60, GUNZ_WINDOWS=61, GUNZ_MAC=62
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:158-169 — Direction: North=0, East, South, West, NorthEast, SouthEast, SouthWest, NorthWest
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:1727-1743 — setClientVersion does m_features.reset() then fires onClientVersionChange; no C++ default features, so features.lua is the whole truth
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:1793-1805 — Game::getOs returns m_clientCustomOs when > 0 => 61 for 1530
- D:/Claude/otclient_mehah1530/otclient/modules/game_features/features.lua:79-80 vs 214-218 — GameEnvironmentEffect and GameItemAnimationPhase are enabled at 910 and DISABLED again at 1281; both OFF at 1530
- D:/Claude/otclient_mehah1530/otclient/modules/game_features/features.lua:275-282 — the >=1530 block calls g_game.setRsa(GUNZODUS_RSA) and g_game.setCustomOs(61)
- D:/Claude/otclient_mehah1530/otclient/data/setup.otml — map: viewport 8 6, max-z 15, sea-floor 7, underground-floor 8, aware-underground-floor-range 2; tile max-things 10
- D:/Claude/otclient_mehah1530/otclient/src/client/gameconfig.cpp:171-196 — otml key 'underground-floor' maps to m_mapUndergroundFloorRange (value 8, used as the UNDERGROUND_FLOOR constant in parseFloorChangeDown)
- D:/Claude/otclient_mehah1530/otclient/src/client/map.cpp:806-813 — resetAwareRange: left=vp.w=8, top=vp.h=6, right=vp.w+1=9, bottom=vp.h+1=7
- D:/Claude/otclient_mehah1530/otclient/src/client/staticdata.h:37-51 — AwareRange struct; horizontal()=left+right+1=18, vertical()=top+bottom+1=14
- D:/Claude/otclient_mehah1530/otclient/src/client/tile.cpp:332-359 — Tile::addThing auto-places only when stackPos<0 or ==255; otherwise it is a literal insertion index (clamped to size)
- D:/Claude/otclient_mehah1530/otclient/src/client/thing.cpp:54-74 — getStackPriority: ground=0, groundBorder=1, onBottom=2, onTop=3, creature=4, item=5
- D:/Claude/otclient_mehah1530/otclient/src/client/item.cpp:267-277 — Item::setId forces id=0 when !isValidDatId(id, ThingCategoryItem); getItem then throws at protocolgameparse.cpp:4522
- D:/Claude/otclient_mehah1530/otclient/src/client/item.h:160 — Item::isContainer falls back to ThingType::isContainer for a freshly parsed item
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.h:111-191 — the flag accessors getItem uses: isContainer, isStackable, isFluidContainer, isSplash, isChargeable, hasWearOut, hasClockExpire, hasExpire, hasExpireStop, isPodium, isDecoKit, getClassification
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.cpp:196-437 — appearance->flag mapping: container(5)->Container, cumulative(6)->Stackable, liquidpool(12)->Splash, liquidcontainer(19)->FluidContainer, show_off_socket(46)->Podium, upgradeclassification(48).upgrade_classification->m_upgradeClassification, wearout(53), clockexpire(54), expire(55), expirestop(56), deco_kit(57)
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.cpp:1108-1139 — ThingFlagAttrChargeable is only reachable from the legacy .dat path, so isChargeable() is always false with appearances at 1530
- D:/Claude/otclient_mehah1530/otclient/src/protobuf/appearances.proto:87-93,134-211 — Appearances.object=1, Appearance{id=1, flags=3}, AppearanceFlags{container=5, cumulative=6, liquidpool=12, liquidcontainer=19, show_off_socket=46, upgradeclassification=48, wearout=53, clockexpire=54, expire=55, expirestop=56, deco_kit=57}
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtypemanager.cpp:205-236 — loadAppearances indexes ThingTypes by appearance.id (array resized to lastId+1), so client ids are direct indices
- D:/Claude/otclient_mehah1530/otclient/data/things/1530/appearances-17a72b30b5c3c9ca8c1283cfb2febd2a93a145ff8ab66916f7a412d0f1dee5a1.dat — the actual 1530 appearances protobuf shipped with this tree
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/inputmessage.cpp:52-99 — u8/u16/u32/u64 are little-endian; getString is u16 length + raw bytes
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/inputmessage.h:59-70 — peekU8/peekU16 read then rewind the cursor

## Pitfalls
- The 10-thing tile limit is a red herring. `getTileMaxThings()==10` only emits a traceError at protocolgameparse.cpp:4124; the loop runs to 256 and only the 0xFFxx marker ends a tile. Stopping at 10 desyncs immediately.
- The 0xFF marker is a little-endian u16 read, so on the wire the SKIP COUNT COMES FIRST: bytes are [skip][0xFF], not [0xFF][skip]. Writing it the other way round is the classic bug.
- The skip returned by a tile covers the tiles AFTER the current one; the current tile is already accounted for. Two adjacent non-empty tiles are separated by the two bytes 00 FF.
- `skip` is threaded across floor boundaries inside one setMapDescription call (protocolgameparse.cpp:4084-4087). An empty run can start on floor 7 and end on floor 5. Do not reset it per floor.
- parseUpdateTile (opcode 105) DISCARDS the returned skip (:1543-1547) and parseFloorChangeUp discards it in the else-branch (:3192). Do not carry it into the next packet.
- setFloorDescription iterates X-major then Y (nx outer, ny inner). Iterating rows-first transposes the whole map.
- BOTH x and y receive `+offset` in the tile position (`x + nx + offset, y + ny + offset`), not just one of them.
- The four map-move packets go through setMapDescription, i.e. the strip is repeated for EVERY floor in the z window (8 floors above sea level). A parser that reads only one floor's worth of strip desyncs on the second packet.
- GameMapMovePosition is OFF at 1530, so map-move and floor-change packets have NO leading position. If a fork enables it, every one of those handlers gains a 5-byte Position prefix.
- GameEnvironmentEffect and GameItemAnimationPhase are enabled at 910 and DISABLED AGAIN at 1281 (features.lua:79-80 vs 216-217). Reading the features file top-down without honouring the later disables adds phantom bytes.
- getItem's attribute order for OS 61 is NOT upstream's. Gunz order: count -> counter(wearOut) -> clock(expire) -> container -> tier -> podium -> decoKit. Upstream order puts tier/clock/counter AFTER podium. Getting this wrong shifts every item on the tile.
- Ids 3457 and 408 return from getItem with ZERO attribute bytes (protocolgameparse.cpp:4537) when cv>=1185 on a gunz OS. Missing this eats the next item's header.
- readTier tests `getClassification()` (the numeric value), not the presence of the upgradeclassification message. An item whose appearance carries upgradeclassification with value 0 reads NO tier byte.
- There are TWO creature-icon lists at 1530 (protocolgameparse.cpp:4353-4359), and each entry is 5 bytes, not 4 (the extra u8 is read and thrown away). Parsing one list, or 4-byte entries, desyncs every creature.
- The emblem byte is present ONLY for 0x61 (UnknownCreature). For 0x62 (known) it is absent (:4370, `&& !known`).
- There are two independent `creatureType` values in a 0x61 payload: the one before the name (:4280) and the one after skull/shield gated on GameThingMarks (:4375). Both can trigger their own masterId/vocation read; they are separate branches (:4283 and :4380).
- The mount colour bytes are conditional (`mount != 0`) inside getCreature, but parseOpenOutfitWindow (:3232-3239) reads them unconditionally when mount==0. Do not share one code path blindly.
- Item::setId silently zeroes an out-of-range id and getItem then throws (:4522). An id present on the wire but missing from your metadata table is unrecoverable - you cannot skip it, because you do not know its length.
- The container-type switch has no default payload for types 0,5,6,7,10 and >=12 - but if the server ever uses one of those with a payload, the parser silently desyncs. Log unknown container types loudly.
- AwareRange is mutable: opcode 51 rewrites it and every later map packet's width/height follow. Hard-coding 18x14 breaks on servers that send opcode 51.
- The +1/+1 (up) and -1/-1 (down) central-position adjustments in the floor-change handlers are client-side bookkeeping, not wire data; do not try to read bytes for them.
- parseCreatureData subtype 0 calls getCreature with type=0, which reads the creature marker as a u16 from the wire (:4250-4252) - unlike getThing, which passes an already-consumed marker.

## Open questions
- What is the 5th byte of each creature-icon entry at 1530 (protocolgameparse.cpp:2366)? The client reads and discards it; the in-code comment says it is 'never loaded'. Its meaning is unknown but its presence is required for correct sizing.
- What does the SECOND creature-icon list at cv>=1530 (:4358, merge semantics) actually represent - a separate icon category (e.g. status vs. quest markers)? The merge rule (match on icon+category, keep greater count) is documented but the source of the list is not.
- The semantics of the zero-attribute item ids 3457 and 408 (:4536) are explicitly marked UNVERIFIED in the tree. 3457 is presumed the browse-field pseudo item; 408 is unknown. Are there other ids on this list that this build simply does not know about?
- Does the Gunzodus server send GameServerFeatures (opcode 67) at login and, if so, does it enable any of GameItemShader(101) / GameItemTooltipV8(117) / GameCreatureShader(102) / GameCreatureAttachedEffect(103) / GameCreaturePaperdoll(128) / GameWingsAurasEffectsShader(118)? All six add bytes to getItem/getCreature. The Lua client must implement them as runtime-toggleable, not compile them out.
- Container types 0, 5, 6, 7, 10 and >=12 fall through with no extra bytes. Are any of them actually emitted by this server with a payload? Not observable from the client source.
- Does the server ever emit GameServerFloorDescription (opcode 75)? It is wired up (:171) but is not part of standard Tibia 15.30; it may be a mehah/OTCv8 extension unused by Gunzodus.
- Does the server ever send GameServerChangeMapAwareRange (51)? If it does, the 18x14 constants and every strip origin change; the handler exists but there is no evidence in the tree that Gunzodus uses it.
- GameCountU16 (104) is never enabled anywhere in this tree, so counts are u8 and a stack of 65535 cannot be represented. Confirm against a live capture that Gunzodus really sends u8 counts.
- isChargeable is unreachable with appearances-based metadata (ThingFlagAttrChargeable is only set on the legacy .dat path). Confirm no 1530 item relies on a chargeable count byte.

## VERIFIER (confidence 0.9)

### Corrections (AUTHORITATIVE — these override the spec above)
- **Claim**: §3: the GameEnvironmentEffect u16 "does not consume a stackPos slot because of the `continue`".
  - **Correction**: WRONG. A `continue` inside a C++ `for` loop still evaluates the increment expression, so `++stackPos` DOES run. If the feature were on, the first real thing would land at tile index 1, not 0. (Zero byte effect at 1530 because GameEnvironmentEffect is OFF, and the PSEUDOCODE happens to be correct because its `for stackPos = 0,255` also advances — but the prose is false and would mislead anyone re-enabling the flag or porting to cv 910-1280.)
  - Evidence: D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4113-4122 — `for (auto stackPos = 0; stackPos < 256; ++stackPos) { ... if (g_game.getFeature(Otc::GameEnvironmentEffect) && !gotEffect) { msg->getU16(); gotEffect = true; continue; }`
- **Claim**: §3: "The \"10 things\" limit is NOT a parse bound" ... "So for full/floor/tile descriptions, the tile array index == wire order index. A Lua client can simply append."
  - **Correction**: Half right, half wrong. It is correctly NOT a *byte-consumption* bound (the loop bound is `stackPos < 256`). But it IS a *storage* bound that the spec omits entirely: `Tile::addThing` trims the array after every insert, so a tile can never hold more than 11 things, and once it saturates each further insert silently deletes index 10. `size` there is the PRE-insert count, so the trim fires when the 12th thing arrives. Consequence: for a tile with >11 things, wire index != tile array index, and every later stackpos-addressed packet (0x6B ChangeOnMap, 0x6C DeleteOnMap via `getMappedThing`) will index a different thing than the C++ client. A Lua port must replicate the trim, not just append.
  - Evidence: D:/Claude/otclient_mehah1530/otclient/src/client/tile.cpp:323 `const uint8_t size = m_things.size();` … :359 `m_things.insert(m_things.begin() + stackPos, thing);` … :364-365 `if (size > g_gameConfig.getTileMaxThings()) removeThing(m_things[g_gameConfig.getTileMaxThings()]);` (getTileMaxThings()==10 from data/setup.otml:16 `max-things: 10`)
- **Claim**: §7 / PSEUDOCODE: `local T = ITEMS[id]; if not T then error(("unknown item id %d - cannot size attributes"):format(id)) end`, justified by "`Item::setId` forces `id = 0` when `!g_things.isValidDatId(...)` and `getItem` then throws".
  - **Correction**: WRONG for sparse ids — this will abort streams the C++ client parses without complaint. `isValidDatId` is a pure bounds check (`id >= 1 && id < m_thingTypes[category].size()`), and the array is `resize(lastAppearanceId + 1, m_nullThingType)`, so every hole in the id space passes validation and resolves to the null ThingType: all flags false, `getClassification()==0` -> exactly ZERO attribute bytes after the u16 id. I decoded data/things/1530/appearances-17a72b….dat: object count = 43,536 but max object id = 62,144, i.e. 18,608 ids in [1,62144] are holes. The Lua ITEMS table must therefore return an all-false record (not an error) for any id in 1..62144, and error only on id == 0 or id > 62144.
  - Evidence: D:/Claude/otclient_mehah1530/otclient/src/client/thingtypemanager.h:87 `bool isValidDatId(const uint16_t id, const ThingCategory category) const { return category < ThingLastCategory && id >= 1 && id < m_thingTypes[category].size(); }`; thingtypemanager.cpp:225 `things.resize(lastAppearanceId + 1, m_nullThingType);`; item.cpp:267-270 `void Item::setId(uint32_t id) { if (!g_things.isValidDatId(id, ThingCategoryItem)) id = 0;`
- **Claim**: PSEUDOCODE `getCreature`: `if FEAT.ThingMarks then c.type2 = u8(m) end` followed by `if CV >= 1281 then if c.type2 == 3 … elseif c.type2 == 0 then c.vocation = u8(m) end end`.
  - **Correction**: Latent desync: when `FEAT.ThingMarks` is false, `c.type2` is nil, so `c.type2 == 0` is false and the vocation byte is NOT read. The C++ declares `uint8_t creatureType = 0;` unconditionally, so with ThingMarks off and cv>=1281 it takes the `CreatureTypePlayer` branch and DOES read `u8 vocationId`. The spec itself stresses that opcode 67 (GameServerFeatures) can flip any flag at runtime, which makes this reachable. Fix: initialise `c.type2 = 0` before the ThingMarks test. Same applies to `emblem`/`icon`, which the C++ also zero-initialises (no byte effect there).
  - Evidence: D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4365-4368 `uint8_t emblem = 0; uint8_t creatureType = 0; uint8_t icon = 0; bool unpass = true;` then :4374-4376 `if (g_game.getFeature(Otc::GameThingMarks)) { creatureType = msg->getU8(); }` then :4379-4389 `if (cv >= 1281) { if (creatureType == Proto::CreatureTypeSummonOwn) {…} else if (creatureType == Proto::CreatureTypePlayer) { uint8_t vocationId = msg->getU8(); … } }`
- **Claim**: §0: "All features come exclusively from `modules/game_features/features.lua` — there is no C++ default set."
  - **Correction**: The second half is right (game.cpp:1738 `m_features.reset();`, and the only C++ `enableFeature` sites are parseFeatures at :7508 and the offline `src/tools/datdump.cpp`). The first half is false: `modules/game_things/things.lua:33` also calls `g_game.enableFeature(featureFlags[idx])` — GameSpritesU32 / GameEnhancedAnimations / GameIdleAnimations — inside the legacy `.dat` brute-force fallback. None of the three is consulted by map parsing, so there is no wire consequence, but the categorical statement is wrong and the enumeration "a feature not listed there is OFF" should be scoped to "OFF unless things.lua's .dat fallback or opcode 67 sets it".
  - Evidence: D:/Claude/otclient_mehah1530/otclient/modules/game_things/things.lua:19-33 `local featureFlags = { GameSpritesU32, GameEnhancedAnimations, GameIdleAnimations } … for _, idx in ipairs(combo) do g_game.enableFeature(featureFlags[idx]) end`
- **Claim**: §3: "The description always ends with a marker (server writes the pending skip, which is 0 after a non-empty last tile)."
  - **Correction**: Not something a parser may rely on, and the client does not. If a skip run read at tile T covers through the final tile of the final floor of the packet, the client's loop consumes zero further bytes and no trailing marker is read. The loop structure is the sole authority on where the description ends; a Lua port must NOT unconditionally consume a trailing `[00][FF]`, and must not treat its absence as an error.
  - Evidence: D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4093-4103 `if (skip == 0) { skip = setTileDescription(msg, tilePos); } else { g_map.cleanTile(tilePos); --skip; }` — the else-branch reads nothing, so an outstanding skip that spans the last tile terminates the description with no further read.
- **Claim**: §5 "Gotcha": `parseOpenOutfitWindow` "calls `getOutfit`, then, when `cv >= 1281 && mount == 0`, reads the 4 mount colour bytes anyway".
  - **Correction**: Incomplete — it under-counts by 2 bytes. The `cv >= 1281` block also reads an unconditional `u16` (current familiar looktype) after the conditional 4 colour bytes.
  - Evidence: D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:3229-3242 `const auto& currentOutfit = getOutfit(msg); if (g_game.getClientVersion() >= 1281) { if (currentOutfit.getMount() == 0) { msg->getU8(); //head … msg->getU8(); //feet } msg->getU16(); // current familiar looktype }`
- **Claim**: PSEUDOCODE `parseChangeMapAwareRange`: `left = math.floor(xr/2) - ((xr + 1) % 2)` etc., presented as an exact transcription.
  - **Correction**: Not byte-exact at the boundary. The C++ result of each expression is `static_cast<uint8_t>`, and `AwareRange`'s fields are `uint8_t`. For `xRange == 0` the expression is `0/2 - (0+1)%2 = -1`, which the cast turns into 255; the Lua yields -1. Same for `yRange == 0` -> top. Every subsequent packet dimension derives from these, so the Lua must mask: `(math.floor(xr/2) - ((xr+1)%2)) % 256`. (For all sane xRange>=1 the two agree; 18/14 correctly gives 8/6/9/7.)
  - Evidence: D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4000-4012 `g_map.setAwareRange({ .left = static_cast<uint8_t>(xRange / 2 - (xRange + 1) % 2), .top = static_cast<uint8_t>(yRange / 2 - (yRange + 1) % 2), .right = static_cast<uint8_t>(xRange / 2), .bottom = static_cast<uint8_t>(yRange / 2) });` and staticdata.h:37-43 `struct AwareRange { uint8_t left{0}; uint8_t top{0}; uint8_t right{0}; uint8_t bottom{0};`
- **Claim**: Line citations into `modules/game_features/features.lua` (§0 table).
  - **Correction**: Every features.lua citation is off by 1-9 lines. Correct lines: GameLooktypeU16 :26 (spec :24); GameEnvironmentEffect enable :80 / disable :220 (spec :79/:216); GameItemAnimationPhase enable :81 / disable :221 (spec :80/:217); GameThingMarks :122 (spec :121); GameThingQuickLoot :199 (spec :190); GameThingQuiver :206 (spec :198); GameThingPodium :210 (spec :202); GameThingUpgradeClassification :214 (spec :206); GameThingClock :227, GameThingCounter :228, GameThingPodiumItemType :229 (spec :218/:219/:220); GameContainerTypes :247 (spec :239); GameWrapKit :256 (spec :248); commented GameWingsAurasEffectsShader :6 and GameCreaturePaperdoll :7 (spec :7/:8); `g_game.setCustomOs(61)` at :305, `g_game.setRsa(GUNZODUS_RSA)` at :304 (spec ":280-281"). All the ON/OFF *values* the table derives are correct.
  - Evidence: D:/Claude/otclient_mehah1530/otclient/modules/game_features/features.lua:295-306 `if version >= 1530 then … g_game.setRsa(GUNZODUS_RSA) [:304] g_game.setCustomOs(61) [:305] end` ; :217-222 `if version >= 1281 then … g_game.disableFeature(GameEnvironmentEffect) [:220] g_game.disableFeature(GameItemAnimationPhase) [:221] end`
- **Claim**: Assorted protocolgameparse.cpp / const.h / inputmessage.cpp line citations.
  - **Correction**: Minor drift, semantics unaffected: `setFloorDescription` is at :4092 (spec :4091); `parseFloorDescription` at :1452 (spec :1451); the GameCreatureIcons `u8 icon` at :4391-4393 (spec :4389-4391); the GameThingMarks mark + legacy helpers at :4395-4400 (spec :4393-4395); `u8 inspection type` at :4411-4413 (spec :4406-4408); `u8 unpass` at :4415-4417 (spec :4410-4412); the `parseCreatureData` subtype-0 `getCreature(msg)` call is at :2445, not :4446; `InputMessage::getString` at inputmessage.cpp:91-98 (spec :92-99); `Otc::Direction` at const.h:159-170 (spec :158-169). Correct as cited: getItem's whole block (:4531, :4533, :4537, :4541, :4546-4547, :4560-4579, :4581-4584, :4586-4645, :4647-4648, :4651-4675, :4677-4681, :4683-4695), setTileDescription :4108-4137, getOutfit :4139-4204, getThing :4206-4218, getMappedThing :4220-4246, getCreature :4248-4508, getPosition :4700-4706, addCreatureIcon :2358-2371, parseFloorChangeUp/Down :3179/:3203, parseChangeMapAwareRange :4000, parseFeatures :7501, getPaperdoll :7852, const.h:38-40 GUNZ OS, game.cpp:1727/:1738/:1793.
  - Evidence: D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:4092 `int ProtocolGame::setFloorDescription(const InputMessagePtr& msg, const int x, const int y, const int z, const int width, const int height, const int offset, int skip)`; :2445 `case 0: // creature update\n            getCreature(msg);`

### Additions
- VERIFIED CORRECT (checked line by line, no changes needed): all primitive widths and LE-ness (inputmessage.cpp:52-98); peekU16 = getU16 + rewind 2 (inputmessage.h:63-66); every feature enum id in the §0 table (const.h:553-668 — GamePlayerMounts=12, GameEnvironmentEffect=13, GameCreatureEmblems=14, GameItemAnimationPhase=15, GameMapMovePosition=31, GameThingMarks=41, GameLooktypeU16=42, GamePlayerAddons=44, GameCreatureIcons=54, GameThingQuickLoot=83, GameThingQuiver=84, GameThingPodium=85, GameThingUpgradeClassification=86, GameThingCounter=87, GameThingClock=88, GameThingPodiumItemType=89, GameItemShader=101, GameCreatureShader=102, GameCreatureAttachedEffect=103, GameCountU16=104, GameContainerTypes=106, GameWrapKit=112, GameItemTooltipV8=117, GameWingsAurasEffectsShader=118, GameTileAddThingWithStackpos=124, GameCreaturePaperdoll=128); every ON/OFF resolution for 1530; GameCountU16 never enabled anywhere (only referenced at protocolgameparse.cpp:3887/:4547 and protocolgamesend.cpp:464/480/492); the OS-61 gate and isGunzOs==true; the entire gunz getItem reorder (counter -> clock -> container -> tier -> podium -> wrapkit, with the upstream tier/clock/counter block skipped); every container-type sub-case including the cv>=1332 extra u32 on types 9 and 11 and the zero-byte type 4; the whole podium block; the 3457/408 zero-byte early-out; all geometry constants from data/setup.otml (viewport 8 6, max-z 15, sea-floor 7, underground-floor 8, aware-underground-floor-range 2, tile max-things 10) and Map::resetAwareRange -> 8/6/9/7, horizontal 18, vertical 14; the surface/underground z-loop and the single threaded skip; X-major/Y-minor iteration with +offset on BOTH x and y; the 0xFFxx terminator being `[skip][0xFF]` on the wire with `& 0xff`; all four map-move strip origins including `pos.x + range.right` for East; both floor-change handlers including the hardcoded `8 - i` offset, the `pos.z < MapMaxZ - 1` (==14) guard, and the +1/+1 / -1/-1 centre fixups; getOutfit in full; getThing's 97/98/99 dispatch (protocolcodes.h:36-42, StaticText=96 indeed unhandled); getMappedThing; both creature branches including the TWO icon lists and the 5-byte-per-entry trailer at cv>=1530; the merge semantics of the second list (empty list = no-op, match on (icon,category), keep the greater count, append unmatched); getPaperdoll's field order; all opcode numbers (protocolcodes.h:80,88,89,101-110,190,191); Proto::CreatureType values; and every protobuf field number in the §7 metadata table (appearances.proto: object=1, id=1, flags=3, container=5, cumulative=6, liquidpool=12, liquidcontainer=19, show_off_socket=46, upgradeclassification=48 -> upgrade_classification=1, wearout=53, clockexpire=54, expire=55, expirestop=56, deco_kit=57).
- QUANTIFIED the §3 terminator-safety claim, which the spec asserted without evidence: I decoded data/things/1530/appearances-17a72b30….dat. Max ids are object=62144 (0xF2C0), outfit=10003, effect=343, missile=82. 62144 < 0xFF00 (65280) with 3136 ids of headroom, so the `peekU16() >= 0xff00` discrimination is provably unambiguous for THIS asset set — but it is an asset-dependent invariant, not a protocol one, and should be re-checked if assets are ever swapped.
- MISSING from §1: the aware range is not only server-mutable, it is also RESET to the 8/6/9/7 default at `Map::init` (map.cpp:78) and again in Game's reset-game-states path (game.cpp:97, alongside `m_containers.clear(); m_vips.clear(); m_gmActions.clear();`). So a server-set custom range from opcode 51 does NOT survive a logout/relogin — a Lua client must reset it at game end or it will size the first post-relogin map packet wrong.
- MISSING from §6: all four tile-delta handlers read their ENTIRE body before any validity check, so a Lua port must never early-return on a failed lookup. `parseTileTransformThing` (:1559-1561) does `getMappedThing(msg)` then `getThing(msg)` and only then tests `if (!thing)`; `parseCreatureMove` (:1592-1593) does `getMappedThing(msg)` then `getPosition(msg)` and only then tests. Aborting before the second read desynchronises the stream.
- MISSING from §3/§6: `Map::addThing` has pre-tile filters the spec's model omits — `if (thing->isItem() && thing->getId() == 0) return;` (map.cpp:186, unreachable from getItem because it throws first) and missiles are appended to `m_floors[pos.z].missiles` instead of a tile (map.cpp:189-194). Also `Tile::addThing` returns early for effects before touching `m_things`, so effects never occupy a stack index. None of these is reachable from getThing (which yields only items and creatures), but the Lua `map.addThing` shim should mirror them if it is shared with the effect/missile opcodes.
- MISSING from §4: `Tile::addThing` treats `stackPos == -2` as "append" in addition to the `< 0 || == 255` auto-placement the spec documents (tile.cpp:332-340: `// -1 or 255 => auto detect position  // -2 => append`). Not reachable from this area, but a shared Lua helper should not accidentally alias -2.
- ROBUSTNESS note the spec should carry: the C++ has a genuine null-deref at protocolgameparse.cpp:4385-4387 — `} else if (creatureType == Proto::CreatureTypePlayer) { uint8_t vocationId = msg->getU8(); creature->setVocation(vocationId); }` — with no `if (creature)` guard, unlike every other consumer in that function. It is reached when the server sends 0x62 (OutdatedCreature) for an id the client has evicted (the :4265-4268 "server said that a creature is known, but it's not" path) with creatureType==Player. The byte is still consumed, so a Lua port should read the byte and simply skip the assignment.
- SCOPE gap worth flagging to the implementer: `getItem` is shared with non-map packets (parseOpenContainer at :1608 etc.) and `getThing`/`getCreature` bytes arrive interleaved with effect/missile opcodes that this spec does not cover. Any of those parsed with the wrong width desynchronises the same shared stream, so the item-metadata table and getItem must be implemented once and reused, not duplicated per packet.
- §3's `getMappedThing` note that stackpos is "never 0xFF" rests on `assert(stackpos != UINT8_MAX);` (protocolgameparse.cpp:4229), which is compiled out in release builds — it is a debug expectation, not a protocol guarantee. In release the value is passed straight to `g_map.getThing(pos, 255)`.
