# gap analysis — what D:/Claude/otclient_web/luaclient is missing to host a headless reimplementation of vBot 4.8 (CaveBot, TargetBot+Looting, HealBot, AttackBot)

# Gap analysis: luaclient → bot host

Scope of what already exists (verified by reading the code, not API.md alone):

* `proto/parser.lua` (3049 lines) consumes **every** opcode of 1530/OS61 and already maintains
  `state.player`, `state.creatures`, `state.map`, `state.containers`, `state.channels`,
  `state.inventoryCounts`, `state.resources`, `state.unjustified`, `state.fightMode/chaseMode/safeMode/pvpMode`,
  `parser.serverBeat/speedA/speedB/speedC`.
* `proto/sender.lua` (631 lines) has 30 builders covering walk/turn/autowalk/talk/use/useWith/useOnCreature/
  move/look/attack/follow/fight-modes/containers/seek/buy/sell/closeTrade/equip/outfit/channels/modal.
* `game/state.lua` (568 lines) reproduces `Tile::addThing` stack semantics, the 11-thing trim,
  `Map::setCentralPosition` + `removeUnawareThings`, and `Map::isAwareOfPosition`.
* `lib/events.lua` is a working bus; `lib/sched.lua` gives 10 ms timers — enough to host the vBot
  executor model (`mods/game_bot/executor.lua:196-215`: a ~20 ms tick that fires macros whose
  `lastExecution + timeout <= now`, then drains a scheduler queue).

Everything below is what is **not** there. Ordered P0 (bot cannot function) → P3 (nice to have).
"Behaviour" vs "widget detail" is called out per gap.

---

## P0-1 — Item metadata: `items1530.bin` carries only protocol-parsing flags

**Missing.** `proto/items.lua:60-67` + `tools/extract_appearances.py:82-116` extract exactly 7 bits
(`CUMULATIVE WEAROUT EXPIRE CONTAINER CLASSIFY PODIUM DECOKIT`) — the bits `ProtocolGame::getItem`
needs and nothing else. `tools/extract_appearances.py:19-21` says frame_group/name/description are
"deliberately NOT parsed". `game/state.lua:86-99` and `game/state.lua:517-536` both document this as
the reason `walkableAt` cannot see a wall and `stackPriorityOf` cannot tell ground from a common item.

**Who needs it.**

| Bot feature | Needs |
|---|---|
| CaveBot pathfinding (`cavebot/walking.lua`, `mods/game_bot/functions/map.lua:80`) | `unpass` (NOT_WALKABLE), `avoid` (NOT_PATHABLE), `bank.waypoints` (ground speed → Dijkstra edge cost), `automap.color` (stairs test), `bank` presence (isGround) |
| CaveBot floor-change avoidance (`cavebot/walking.lua:116-150`) | `lenshelp.id` (1100/1102/1104/1105 = ladder/rope-spot/stairs/hole), `isGround`, `isNotPathable`, minimap colour 210-213 |
| TargetBot looting (`targetbot/looting.lua:174,215,285`) | `container` (already have), `take` (pickupable), `cumulative` (stackable — have), `getTopUseThing` needs `forceuse/bank/clip/bottom/top/liquidpool` |
| Looting/analyzer name display, supply lists (`vBot/analyzer.lua:401,1191`, `vBot/depositer_config.lua:42`) | `Appearance.name` (field 4) |
| Equipper (`vBot/Equipper.lua`), `g_game.equipItemId` (`game.cpp:1530`) | `upgradeclassification` (have) + `clothes.slot` |
| AttackBot rune use (`vBot/AttackBot.lua`) | `multiuse`, `usable` |
| `getTopMoveThing` / push logic (`vBot/pushmax.lua`) | `unmove` (NOT_MOVEABLE), `isCommon` (= not ground/border/bottom/top/creature) |
| Step-duration formula (`creature.cpp:1106-1146`) | `bank.waypoints` per ground item |

**How to close it.** Bump `assets/items1530.bin` to **version 2** with a section directory (exact
layout in `configFormat`). Both `tools/extract_appearances.py` and `proto/items.lua` carry the format
comment verbatim today (`proto/items.lua:14-46`, `tools/extract_appearances.py:23-63`) — keep that
discipline.

Protobuf fields to add to `BOOL_FIELD_TO_BIT` / a new `SUBMSG_FIELD` table in
`tools/extract_appearances.py` (numbers from `src/protobuf/appearances.proto:142-211`, semantics from
`src/client/thingtype.cpp:176-390`):

| proto field | # | wire | C++ flag | new bit / column |
|---|---|---|---|---|
| `bank` (submsg, inner `waypoints`=1) | 1 | LEN | `ThingFlagAttrGround` + `m_groundSpeed` | FLAGS2 bit0 `GROUND` **and** `groundSpeed[id]` u16 |
| `clip` | 2 | varint | `ThingFlagAttrGroundBorder` | FLAGS2 bit1 |
| `bottom` (presence only!) | 3 | LEN/varint | `ThingFlagAttrOnBottom` | FLAGS2 bit2 |
| `top` (presence only!) | 4 | LEN/varint | `ThingFlagAttrOnTop` | FLAGS2 bit3 |
| `unpass` | 13 | varint | `ThingFlagAttrNotWalkable` | FLAGS2 bit4 |
| `avoid` | 16 | varint | `ThingFlagAttrNotPathable` | FLAGS2 bit5 |
| `unmove` | 14 | varint | `ThingFlagAttrNotMoveable` | FLAGS2 bit6 |
| `unsight` | 15 | varint | `ThingFlagAttrBlockProjectile` | FLAGS2 bit7 |
| `take` | 18 | varint | `ThingFlagAttrPickupable` | FLAGS3 bit0 |
| `usable` | 7 | varint | `ThingFlagAttrUsable` | FLAGS3 bit1 |
| `multiuse` | 9 | varint | `ThingFlagAttrMultiUse` | FLAGS3 bit2 |
| `forceuse` | 8 | varint | `ThingFlagAttrForceUse` | FLAGS3 bit3 |
| `liquidcontainer` | 19 | varint | `ThingFlagAttrFluidContainer` | FLAGS3 bit4 (also already OR'd into CUMULATIVE) |
| `liquidpool` | 12 | varint | `ThingFlagAttrSplash` | FLAGS3 bit5 |
| `hang` | 20 | varint | `ThingFlagAttrHangable` | FLAGS3 bit6 |
| `write` / `write_once` | 10/11 | LEN | `ThingFlagAttrWritable(Once)` | FLAGS3 bit7 |
| `rotate` | 22 | varint | `ThingFlagAttrRotateable` | FLAGS4 bit0 |
| `fullbank` | 32 | varint | `ThingFlagAttrFullGround` | FLAGS4 bit1 |
| `ignore_look` | 33 | varint | `ThingFlagAttrLook` | FLAGS4 bit2 |
| `corpse` | 42 | varint | (no C++ flag; used by loot heuristics) | FLAGS4 bit3 |
| `player_corpse` | 43 | varint | — | FLAGS4 bit4 |
| `lying_object` | 28 | varint | `ThingFlagAttrLyingCorpse` | FLAGS4 bit5 |
| `wrap` / `unwrap` | 37/38 | varint | Wrapable/Unwrapable | FLAGS4 bit6/7 |
| `height` (inner `elevation`=1) | 27 | LEN | `m_elevation` | `elevation[id]` u8 (max observed 24) |
| `automap` (inner `color`=1) | 30 | LEN | `m_minimapColor` | `minimapColor[id]` u8 (max observed 215) |
| `lenshelp` (inner `id`=1) | 31 | LEN | `m_lensHelp` | `lensHelp[id]` u16 (max observed 1112) |
| `clothes` (inner `slot`=1) | 34 | LEN | `m_clothSlot` | `clothSlot[id]` u8 |
| `Appearance.name` | 4 (of `Appearance`) | LEN | `m_name`, and `market.name = m_name` | sparse NAMEIDX + NAMEBLOB |

Measured over the real `appearances-17a72b30…dat` (43 536 objects, max id 62 144):
`unmove` 31 818, `unpass` 16 697, `automap` 15 777, `bottom` 11 212, `usable` 10 883, `take` 7 221,
`clip` 6 312, `unsight` 5 925, `bank` 3 354, `container` 3 381, `multiuse` 2 675, `cumulative` 2 593,
`height` 2 194, `avoid` 2 055, `clothes` 1 984, `top` 1 267, `forceuse` 1 057, `lenshelp` 981,
`hang` 540, `liquidcontainer` 48, `liquidpool` 12, `write` 12, `write_once` 84.
**Only 8 951 objects carry a `name`** (149 730 bytes of UTF-8), so a dense name array would be waste —
use a sparse index.

Note two traps found in `thingtype.cpp`:
* `bottom`/`top` are tested with **`has_bottom()` / `has_top()` only** (`thingtype.cpp:188-196`) — presence,
  not truth. Every other boolean is `has_x() && x()`.
* `bank` is `has_bank()` presence too (`thingtype.cpp:179`), and `m_groundSpeed = flags.bank().waypoints()`;
  a bank with `waypoints` absent → speed 0, and `Tile::getGroundSpeed()` then substitutes 100
  (`tile.cpp:563-569`) while `Creature::getStepDuration` substitutes 150 (`creature.cpp:1120-1121`).
  Keep both fallbacks; they differ on purpose.
* `ThingFlagAttrFloorChange` (`const.h:1298`) comes only from the legacy `.dat` path
  (`thingtype.cpp:1096`), so `Tile::hasFloorChange()` is **always false at 1530** — that is exactly why
  `cavebot/walking.lua:116-128` reimplements floor-change detection from `lenshelp` + `isGround` +
  `isNotPathable` + minimap colour. Do not try to extract a "floor change" bit; there isn't one.

New API on `proto/items.lua` (all O(1) reads off preloaded strings/ffi arrays):

```
items.flags(id)          -- unchanged, FLAGS1 (do not break the parser)
items.flags2(id) items.flags3(id) items.flags4(id)
items.groundSpeed(id) items.minimapColor(id) items.elevation(id)
items.lensHelp(id) items.clothSlot(id) items.name(id)
-- predicates (thin, used by everything else):
items.isGround isGroundBorder isOnBottom isOnTop isNotWalkable isNotPathable
items.isNotMoveable isBlockProjectile isPickupable isUsable isMultiUse isForceUse
items.isFluidContainer isSplash isContainer isStackable isCommon
--   isCommon(id) == not (isGround or isGroundBorder or isOnBottom or isOnTop)
```

---

## P0-2 — No pathfinder, and no minimap store to path across unseen tiles

**Missing.** Nothing in `luaclient` implements `g_map.findEveryPath`. CaveBot calls it via
`mods/game_bot/functions/map.lua:80-114` (`findAllPaths`) and `:143-220` (`findPath`, which does the
margin/precision candidate search in Lua on top of it). `targetbot/looting.lua:169,313` and
`cavebot/walking.lua` are unusable without it.

The C++ algorithm (`src/client/map.cpp:1316-1473`) is fully specified and is a plain Dijkstra:

* Node cost of entering a neighbour = `tile groundSpeed` (default 1000 when the tile is unknown,
  100 when the tile exists but has no ground — see `tile.cpp:563`), times
  `g_gameConfig.getPlayerDiagonalWalkSpeed()` = **3** (`data/setup.otml:29`) for diagonal steps.
  `ignoreCost` → cost 1.
* Per-neighbour predicates: `wasSeen`, `hasCreature = tile:hasBlockingCreature()`,
  `isNotWalkable = not tile:isWalkable(true)`, `isNotPathable = not tile:isPathable()`,
  `mapColor = tile:getMinimapColorByte()`, `speed = tile:getGroundSpeed()`.
* **When the tile is outside the aware range** (`isAwareOfPosition` false) and `allowOnlyVisibleTiles`
  is off, the C++ falls back to `g_minimap.getTile()` for `wasSeen / NotWalkable / NotPathable /
  color / speed` (`map.cpp:1415-1424`). **luaclient has no minimap at all**, and worse,
  `state:setCentralPosition` (`game/state.lua:409-436`) *deletes* every tile that leaves the aware
  range, so a headless client forgets the map behind it and can never path home.
* Reject rule (`map.cpp:1429-1441`):
  `hasStairs = isNotPathable and 210 <= mapColor <= 213`;
  skip if `(not wasSeen and not allowUnseen)` or `(hasStairs and not ignoreStairs and neighbor ~= dest)`
  or `(isNotPathable and not ignoreNonPathable and neighbor ~= dest)` or `(isNotWalkable and not ignoreNonWalkable)`
  or `maxDistanceFrom` exceeded. A blocking creature is skipped unless `ignoreCreatures`, but with
  `ignoreLastCreature` the destination entry is still recorded at `cost+100`.
* Result map: `["x,y,z"] = {totalCost, distance, dirFromPrev, prevKeyString}`; `dirFromPrev` is
  `Position::getDirectionFromPosition` (an `Otc::Direction`, `-1` for the start node).
  `map.lua:116-141` walks the `prev` chain backwards to a direction list — reproduce the tuple layout
  exactly or that helper breaks.

**How to close it.** Two new modules:

* `game/minimap.lua` — a persistent `{x,y,z} → {color u8, speed u16, flags u8}` store, written from
  `tileUpdate`/`mapDescription` events *before* `setCentralPosition` evicts the tile, and optionally
  loaded/saved as OTMM. Flags: `WasSeen 1, NotWalkable 2, NotPathable 4, Empty 8` (matching
  `MinimapTileWasSeen` etc.). `MinimapTile::getSpeed()` stores `groundSpeed/10` in the C++; store the
  raw value and be done.
* `game/pathfinder.lua` — `pathfinder.findEveryPath(state, start, maxDist, params)` returning the same
  tuple map, plus `pathfinder.findPath(...)` doing the margin/precision search of `map.lua:143-220`.
  Needs `state:tileFlags(pos)` (below) and `minimap` as fallback.
* Hook: in `proto/parser.lua` `P:setCentral` (line 415), call `minimap.absorb(state, oldTiles)` before
  `st:setCentralPosition`, or make `state:cleanTile` publish to the minimap.

**Behaviour vs widget:** all behaviour. The only widget part of vBot's pathing is the waypoint HUD
(`cavebot cfg key "waypointHud"`), which a headless client ignores.

---

## P0-3 — Tile derived queries the bot uses ~250 times do not exist

`g_map.getTile` is called 97×, `getTiles` 49×, and on the returned tile the bot calls
`isWalkable` 44×, `getTopUseThing` 60×, `hasCreatures` 22×, `getGround` 6×, `getTopThing` 8×,
`isPathable`/`isNotPathable` 4×, `hasFloorChange` 4×, `getTopMoveThing` 2×, `canShoot` 2×.

`game/state.lua:538-560` has only `walkableAt`, and it *documents* that it cannot check item blocking
(returns the sentinel `'items-unknown'`). With P0-1 done, replace it.

**How to close it.** New `game/tile.lua` (or methods on `state`) implementing, against
`items.flags2/3/4`:

* `state:tileFlags(pos)` — fold every item on the tile once into a bitmask cache
  (`NOT_WALKABLE|NOT_PATHABLE|BLOCK_PROJECTILE|HAS_CREATURE|HAS_GROUND|FULL_GROUND|HAS_COMMON|...`),
  invalidated in `addThing`/`_removeAt`/`cleanTile`. This is `Tile::m_thingTypeFlag`
  (`tile.cpp:933-1010`).
* `state:isWalkable(pos, ignoreCreatures)` — `tile.cpp:708-725`:
  `not (flags & NOT_WALKABLE) and hasGround` and, unless `ignoreCreatures`, no non-passable creature.
* `state:isPathable(pos)` — `tile.h:77`: `(flags & NOT_PATHABLE) == 0`.
* `state:hasBlockingCreature(pos)` — `tile.cpp:838-844`: a creature that is not passable **and is not
  the local player**.
* `state:getGround(pos)` — `tile.cpp:537`: `things[0]` if `items.isGround(id)`, else nil.
* `state:getGroundSpeed(pos)` — `tile.cpp:563-569`: ground's `groundSpeed`, else **100**.
* `state:getMinimapColorByte(pos)` — `tile.cpp:571-585`: reverse-iterate things, skip creatures and
  `isCommon` items, first non-zero `minimapColor`, else **255**.
* `state:getTopUseThing(pos)` — `tile.cpp:600-617`: first thing that `isForceUse` **or**
  (not ground and not groundBorder and not onBottom and not onTop and not creature and not splash);
  else scan backwards from the end for the first non-splash non-creature; else `things[0]`.
  **This is what looting uses to find the corpse** (`targetbot/looting.lua:174,313`).
* `state:getTopMoveThing(pos)` — `tile.cpp:654-675`: first `isCommon` thing; if it is at index > 0 and
  `isNotMoveable`, return the thing *before* it; else first creature; else `things[0]`.
* `state:getTopCreature(pos)` — `tile.cpp:619-630`: first non-local-player creature, else local player.
* `state:isSightClear(from, to)` — `map.cpp:1181-1225` (the exact Bresenham-ish loop) using
  `BLOCK_PROJECTILE`. Needed by `canShoot` (`map.lua:249`) and by AttackBot line-of-sight.

Also fix `state:addThing`'s priority fallback (`game/state.lua:89-99, 224`): with FLAGS2 available,
`stackPriorityOf` can finally return the real `Thing::getStackPriority`
(ground 0, groundBorder 1, onBottom 2, onTop 3, creature 4, common 5), which makes auto-stackpos
insertion (`stackPos` nil/-1/255) correct instead of heuristic.

---

## P0-4 — Container model diverges from `Container::onAddItem`; slot arithmetic is wrong

**This one silently loots the wrong item.** `targetbot/looting.lua:290,299` moves loot to
`container:getSlotPosition(slot-1)` = `{x=0xFFFF, y = containerId | 0x40, z = slot}`
(`src/client/container.h:37`). Any slot drift moves the wrong stack.

`proto/parser.lua:1378-1389` (`S[0x70]` ContainerAddItem) does
`table.insert(c.items, 1, item)` — always at index 1 — and pops the tail only when
`#items > capacity`. The C++ (`container.cpp:45-67`) does:

```
slot -= m_firstIndex
if hasPages and slot > capacity      -> only ++m_size, item NOT stored, return
if #m_items == capacity              -> onRemoveItem(firstIndex + capacity - 1, nil); ++m_size
m_items.insert(begin + slot, item);  ++m_size
```
and `onRemoveItem` (`container.cpp:99-128`) does `slot -= firstIndex`, guards
`hasPages and slot >= #items` (size-only change), erases, and if `lastItem` is present re-adds it at
`firstIndex + capacity - 1` (which decrements size once more).

`S[0x72]` (`parser.lua:1406-1427`) appends `last` at the end instead of `firstIndex+capacity-1`, and
neither handler maintains `c.size`, which `hasPages` paging depends on.

**How to close it.** Rewrite `S[0x70]/S[0x71]/S[0x72]` in `proto/parser.lua` to the C++ algorithm
above, maintain `c.size`, and emit `containerAddItem/RemoveItem` with the **normalised slot**
(`slot - firstIndex`). Add to `game/state.lua`:

```
state:containerSlotPos(containerId, slot0)  -> {x=0xFFFF, y=bit.bor(containerId,0x40), z=slot0}
state:inventorySlotPos(slot)                -> {x=0xFFFF, y=slot, z=0}
state:findPlayerItem(itemId, subType, tier) -- game.cpp:909-933: inventory slots
                                            -- Head(1)..LastInventorySlot, then open containers
state:findEmptyContainerId()                -- game.cpp:1786-1791: lowest id with no open container
```
`findEmptyContainerId` is load-bearing: `Game::open` and `Game::use` put it in the `index` byte of
0x82 (`game.cpp:850, 940`), and `sender:openContainer(pos,id,stack,containerId)`
(`proto/sender.lua:517`) has no default for it.

Also add `state:itemAmount(itemId)` reading `state.inventoryCounts` (parser already builds it at
`S[0xF5]`, `parser.lua:1429-1449`, keyed `itemId*256 + tier`) — that is `player:getInventoryCount()`,
used 18× (supply checks, AttackBot/HealBot item availability).

---

## P0-5 — No walk controller: no `getStepDuration`, `isWalking`, `isPreWalking`, `getPing`

`cavebot/walking.lua` is built entirely on these:
`player:getStepDuration(false, dir)` (lines 218, 328, 499), `player:isPreWalking()` (line 420),
`g_game.getPing()` (line 210), `g_game.walk(dir,false)` return value, `g_game.stop()`, `g_game.autoWalk()`.
`state.player` declares `serverPos, preWalks, walkLockUntil, waitingForServerWalk, lastWalkTime`
(`game/state.lua:127-129`) but **nothing writes them**.

`Creature::getStepDuration` (`creature.cpp:1106-1151`):

```
if speed < 1 -> 0
groundSpeed = tile(destination or current):getGroundSpeed(); if 0 -> 150
stepDuration = 1000 * groundSpeed / (hasSpeedFormula() ? calculatedStepSpeed : speed)
if cv >= 860: stepDuration = ceil(stepDuration / serverBeat) * serverBeat      -- serverBeat from 0x17
diagonal (cv > 810): stepDuration *= 3        -- playerDiagonalWalkSpeed, data/setup.otml:29
hasSpeedFormula() = GameNewSpeedLaw && speedA,B,C all non-zero                 -- creature.cpp:1104
calculatedStepSpeed = max(1, floor(speedA*log((speed*2)/2 + speedB) + speedC + 0.5))  -- creature.cpp:965-971
```
`serverBeat` defaults to 50 (`game.h:533`) and comes from opcode 0x17 — **already stored** by
`parser.lua:857` (`self.serverBeat`, `self.speedA/B/C`); they just are not exposed on `state`.

`getPing()` does not exist at all: `main.lua:313-318` answers 0x1D and counts 0x1E pongs but never
timestamps them.

**How to close it.**
* `game/walker.lua`: keeps `pending` steps, applies them optimistically (pre-walk), reconciles on
  `positionChange`, rolls back on `walkCancel` (0xB5) and `walkWait` (0xB6, `parser.lua:2032`).
  Exposes `walker.stepDuration(dir)`, `walker.isWalking()`, `walker.isPreWalking()`.
* In `main.lua`, record `LC.pingSentAt = sys.nowMs()` in the keepalive timer (line 302) and set
  `LC.ping = nowMs() - pingSentAt` in the `pingBack` handler (line 316); expose `state.ping`.
  CaveBot's `pingMs()` falls back to the cfg `"ping"` value (default 100) when it is bogus.
* Copy `state.serverBeat/speedA/speedB/speedC` from the parser into `state` in `S[0x17]`.

---

## P0-6 — NPC trade is consume-and-ignore in the parser

`parser.lua:1451-1471`: `S[0x7A]` reads the whole buy/sell list into nothing
(`R:u16(); R:u8(); R:string(); R:u32(); R:u32(); R:u32()` per entry) and `S[0x7B]` PlayerGoods
likewise. `sender.lua` already has `buyItem/sellItem/closeNpcTrade` — so the bot can *act* but not
*see*.

CaveBot `buy_supplies.lua:63-88` calls `NPC.isTrading()` then `NPC.getBuyItems()` and buys by id;
`sell_all.lua:43` and `cavebot/bank.lua`/`depositor.lua` need the same.
`mods/game_bot/functions/npc.lua:24-62` shows the exact record shape the bot expects:
`{id, count, name, subType, weight (=wire/100), price}`.

Wire (verified `protocolgameparse.cpp:1827-1886`):

```
0x7A: [STR npcName if GameNameOnNpcTrade] [u16 currencyId, STR currencyName if cv>=1281]
      u16 listCount, then per entry: u16 itemId, u8 countOrSubType, STR name,
      u32 weight, u32 buyPrice, u32 sellPrice    (0xFFFFFFFF price normalises to 0)
0x7B: (cv>=1281: no money field — money comes from 0xEE ResourceBalance)
      u16 listSize (cv>=1334), then per entry: u16 itemId, u16 amount (GameDoubleShopSellAmount)
```

**How to close it.** In `proto/parser.lua`, store `state.npcTrade = {open=true, npcName=,
currency=, items={...}}` on 0x7A, `state.npcGoods = {[itemId]=amount}` on 0x7B, clear both on 0x7C, and
emit `npcTradeOpen`, `npcGoods`, `npcTradeClose`. Then `state:npcBuyItems()` = trade items with
`buyPrice > 0`, `state:npcSellItems()` = trade items with `sellPrice > 0` **and** present in
`npcGoods` (that is what `game_npctrader.lua:178-222` does), and `state:npcSellQuantity(id)` =
`npcGoods[id]`.

---

## P0-7 — Spell/exhaust cooldown tracking (no timers derived from 0xA4/0xA5/0xA6)

`parser.lua:1869-1879` emits `spellCooldown{spellId, delay}`, `spellGroupCooldown{groupId, delay}`,
`multiUseCooldown{delay}` and stores **nothing**. `vlib.lua:279-307` (`canCast`) and
`vlib.lua:361-379` (`getSpellCoolDown`) are the gate for every HealBot/AttackBot cast, and they call
`modules.game_cooldown.isCooldownIconActive(id)` / `isGroupCooldownIconActive(groupId)`.

The client-side model to copy (`modules/game_cooldown/cooldown.lua:63-67, 521-537, 583-588`):

```
on 0xA4 (spellId, delay): cooldown[spellId]      = nowMs + delay
on 0xA5 (groupId, delay): groupCooldown[groupId] = nowMs + delay
isCooldownIconActive(id)      = type(cooldown[id]) == 'number' and nowMs < cooldown[id]
isGroupCooldownIconActive(gid)= type(groupCooldown[gid]) == 'number' and nowMs < groupCooldown[gid]
```
(The `tierUpgradeFeatureEnabled` branch is the 1530 branch; the boolean branch is legacy.)

The `spellId` on the wire is `SpellInfo[...].id`, **not** `clientId` — proven by
`cooldown.lua:252` → `Spells.getSpellByIcon(iconId)` → `modules/gamelib/spells.lua:460-469`
(`spell.id == iconId`).

Three separate exhaust clocks the bot models, all behaviour:

1. **Server spell cooldown** — per spell id, from 0xA4.
2. **Server spell-group cooldown** — per group id, from 0xA5. `SpellInfo` group field is a map
   `{[groupId] = ms}`, e.g. `{[2]=1000}` for healing, `{[1]=2000}` attack, `{[3]=2000}` support.
3. **Client-side "use anything" exhaust** — `vBot/AttackBot.lua:29-35`: a fixed **1000 ms**
   `USE_COOLDOWN_MS` shared reservation between AttackBot runes and HealBot potions, plus 0xA6
   `multiUseCooldown` from the server. Purely client-side bookkeeping; reproduce as a
   `state.useReadyAt` number.
4. **Talk-confirm fallback** — `vlib.lua:248-270` (`SpellCastTable`): when a spell has no known id, the
   bot times the cooldown itself from the moment the server echoes its own `talk` back with
   `name == player:getName()` (`vlib.lua:249-253`), which the parser already emits (`talk` event,
   `parser.lua:1918`). And `vlib.lua:309-323` *learns* the icon id: the next 0xA4 after our own talk
   is attributed to `lastPhrase`.

**How to close it.** New `game/cooldowns.lua`:
`cd.onSpell(id, ms) cd.onGroup(g, ms) cd.onMultiUse(ms) cd.spellReady(id) cd.groupReady(g)
cd.reserveUse(ms) cd.useReady()`, wired in `main.lua` to the three events; plus
`data/spells.lua` — a straight port of `modules/gamelib/spells.lua:34+` `SpellInfo.Default`
(`{id, name, words, level, mana, soul, group={[gid]=ms}, exhaustion, vocations, ...}`),
indexed by lowercased `words`. Without that table `canCast` has no level/mana gate at all.

---

## P1-1 — Attack/follow target is never tracked

`g_game.getAttackingCreature` is used 21×, `isAttacking` 10×, `getFollowingCreature` 2×.
`sender:attack` (`sender.lua:464-476`) sends and maintains `m_seq` but nothing records the target;
`S[0xA3] ClearTarget` (`parser.lua:1863-1867`) emits `attackCancel{seq}` and clears nothing.

**Close:** `state.attackingId` / `state.followingId`, set in `sender:attack/follow`, cleared on
`attackCancel` when `seq == self.seq` (that is the whole point of the seq), on `creatureDisappear` of
that id, and on `death`. Expose `state:getAttackingCreature()`.

## P1-2 — No spectator query

`getSpectators` / `getSpectatorsInRange` / `getSpectatorsByPattern` are the TargetBot and
AttackBot/HealBot primitive (`map.lua:8-36`; 8 + 4 + 1 call sites).
`Map::getSpectatorsInRangeEx` (`map.cpp:651-700`, defaults `map.h:166-178`): scan the rectangle
`[cx-left, cx+right] × [cy-top, cy+bottom]` on floor `cz`, or floors
`firstAwareFloor(cz)..lastAwareFloor(cz)` when `multiFloor`; dedupe by creature id.
`state.lua:392-397` already exports `firstAwareFloor/lastAwareFloor` and `state.world.awareRange`.

**Close:** `state:getSpectators(centerPos, multiFloor)` and
`state:getSpectatorsInRange(pos, multiFloor, xRange, yRange)` in `game/state.lua`.

## P1-3 — Missing outgoing packets

Present in `proto/opcodes.lua:243+` but with **no builder** in `proto/sender.lua`:

| Need | Opcode | Bytes (from `protocolgamesend.cpp`) | Used by |
|---|---|---|---|
| `stashStow(pos,itemId,count,stackpos,action)` | 0x28 | `u8 action, Position(5), u16 itemId, u8 stackpos, [u32 count if action==0]`; actions 0 STOW_ITEM, 1 STOW_CONTAINER, 2 STOW_STACK, 3 WITHDRAW (`const.h:891-894`, `:1815-1829`) | `g_game.stashStowItem` ×4 (depositer) |
| `stashWithdraw(itemId,count,stackpos)` | 0x28 | `u8 3, u16 itemId, u32 count, u8 stackpos` (`:1804-1813`) | supply withdraw |
| `browseField(pos)` | 0xCB | `Position(5)` (`:1247-1256`) | tile inspection |
| `refreshContainer(id)` | 0xCA | `u8 containerId` (`:952-958`) | container resync |
| `inviteToParty/joinParty/revokeInvitation/passLeadership/leaveParty` | 0xA3–0xA7 | `u32 creatureId` (`:843-...`) | `partyInvite`, `partyJoin` |
| `applyImbuement(slot,id,protectionCharm)` | — `ClientApplyImbuement` | `u8 slot, u32 imbuementId, [u8 charm if cv<1510]` (`:1735-1745`) | `cavebot/imbuing.lua` |
| `clearImbuement(slot)` / `closeImbuingWindow()` | — | `u8 slot` / empty (`:1747-1760`) | imbuing |
| `imbuementWindowAction(type,itemId,pos,stackpos)` | 0xB2 | `u8 type; if type==1: Position(5), u16 itemId, u8 stackpos` (`:1762-1773`) | `g_game.selectImbuementItem` |
| `imbuementDurations(isOpen)` | 0x60 | u8 | `g_game.imbuementDurations` ×4 |
| `forgeRequest` | 0xBF | — | `g_game.forgeRequest` ×2 |
| `safeLogout` | 0x0F variant / `LeaveGame` 0x14 | `sender:logout()` exists but there is no *safe* vs *force* distinction | `safeLogout` ×3 |
| `rotateItem(pos,id,stack)` | 0x85 | Position(5), u16, u8 | misc |

Also add convenience wrappers that mirror `Game::` semantics rather than raw bytes, because that is
what bot scripts call:
* `sender:useThing(thing)` → `use(pos, id, stackpos, state:findEmptyContainerId())` (`game.cpp:839-853`)
* `sender:useInventoryItem(itemId)` → `use({x=0xFFFF,y=0,z=0}, itemId, 0, 0)` (`game.cpp:855-864`)
* `sender:useInventoryItemWith(itemId, target)` → `useOnCreature`/`useWith` from `{0xFFFF,0,0}`,
  stackpos 0 (`game.cpp:883-907`)
* `sender:moveThing(thing, toPos, count)` → thingId is `99` (`Proto::Creature`) for creatures,
  stackpos is `pos.z` when `pos.x == 0xFFFF` (`thing.cpp:94-104`), count defaults to 1 (`game.cpp:802-812`)
* `sender:moveToParentContainer(thing,count)` → toPos `{pos.x,pos.y,254}` (`game.cpp:814-821`)
* `sender:cancelAttack()` = `attack(0)`, `sender:cancelFollow()` = `follow(0)`
* `sender:openParent(id)` = existing `upContainer`

## P1-4 — Missing / incomplete events

The parser emits nearly everything the bot's callback table needs
(`mods/game_bot/functions/callbacks.lua`). Concretely mapped:

| vBot callback | luaclient event | status |
|---|---|---|
| `onTalk(name,level,mode,text,channelId,pos)` | `talk` | OK (`parser.lua:1918`) |
| `onTextMessage(mode,text)` | `textMessage` | OK, but `mode` is a **string name**; vBot compares against `MessageModes.*` numbers → expose `modeByte` (already present) and keep both |
| `onCreatureAppear/Disappear` | `creatureAppear`/`creatureDisappear` | OK (`parser.lua:615, 411`) |
| `onCreaturePositionChange(creature,new,old)` | `creatureMove{creature,from,to}` | OK (`parser.lua:1093`) |
| `onPlayerPositionChange` | `positionChange{pos,oldPos}` | OK (`parser.lua:425`) |
| `onCreatureHealthPercentChange` | `creatureHealth` | OK (`parser.lua:1622`) |
| `onContainerOpen/Close/UpdateItem/AddItem/RemoveItem` | `containerOpen/Close/UpdateItem/AddItem/RemoveItem` | present, **slot semantics wrong** — see P0-4. Also `onContainerOpen(container, previousContainer)` gets a *previous* argument the parser never supplies (the "did the container I asked for actually open" test at `targetbot/looting.lua:302-307` needs it) |
| `onInventoryChange` | `inventoryChange` | OK (`parser.lua:1320`) |
| `onInventoryItemsUpdate` (0xF5) | **missing** | `S[0xF5]` writes `state.inventoryCounts` but emits nothing — add `inventoryCountsChange` |
| `onSpellCooldown` / `onGroupSpellCooldown` | `spellCooldown`/`spellGroupCooldown` | OK, unconsumed (P0-7) |
| `onStatesChange` | `statesChange` | OK (`parser.lua:1860`) |
| `onManaChange` | `manaChange` | OK |
| `onAttackingCreatureChange` | **missing** | needs P1-1 |
| `onUse` / `onUseWith` | **missing** | C++ fires these from `Game::use`/`useWith` (`game.cpp:852, 880`), not from the wire — `vlib.lua:386-400` uses them for the "is the player busy" flag. Emit them from `proto/sender.lua` |
| `onAddThing` / `onRemoveThing(tile, thing)` | partially `tileUpdate` | `tileUpdate` carries `added`/`changed` on 0x6A/0x6B only; 0x69/0x6C give no per-thing delta. Add `thing` + `removed` payloads |
| `onWalk` / `onTurn` | derivable from `creatureMove` + direction change | add `creatureTurn` |
| `onMissle` / `onAnimatedText` / `onStaticText` | `distanceEffect` / — / — | 0x83 emits `distanceEffect`/`magicEffect` (`parser.lua:1497-1502`); **animated/static text at 1530 arrive as 0xB4 TextMessage modes 23-29 with a position**, which the parser decodes (`parser.lua:1930-1945`) but never re-emits as `animatedText`/`staticText` — API.md lists both event names. Add them |
| `onModalDialog` | `modalDialog` | listed in API.md; confirm `S[0xFA]` emits it |
| `onLoginAdvice` | `loginAdvice` | OK |
| `onChannelList/OpenChannel/CloseChannel/ChannelEvent` | present | OK |
| `onGameEditText` | 0x96 EditText | `parser.lua:1683` — check it emits |
| `onImbuementWindow` | 0xEB | `parser.lua:2700` consumes; emits nothing |

## P1-5 — Player fields the bot reads that are not surfaced

`mods/game_bot/functions/player.lua` reads: `getExperience` (parser sets `pl.exp` ✓),
`getFreeCapacity` (`pl.freeCapacity` ✓, but API.md documents `capacity/maxCapacity` — three different
names for two numbers: `pl.capacity`/`pl.maxCapacity` come from 0xA1 `CHARACTER_SKILL_STATS`
(`parser.lua:1836-1838`) while `pl.freeCapacity` comes from 0xA0 — document which is which),
`getSoul` ✓, `getStamina` ✓, `getVocation` ✓ (0x9F), `getBlessings` ✓ (0x9C),
`getSkull` — **only on `state.creatures[playerId].skull`**, not on `state.player`; the local player's
own creature record and `state.player` are two objects (`parser.lua:571-615` vs `P:player()`).
Merge them or mirror `skull/shield/emblem/direction/speed/outfit` onto `state.player`.
`getStates` ✓ (`pl.states`, u64 as a Lua number; masks in `const.h:278-298`:
Poison 1, Burn 2, Energy 4, Drunk 8, ManaShield 16, Paralyze 32, Haste 64, Swords 128, Drowning 256,
Freezing 512, Dazzled 1024, Cursed 2048, PartyBuff 4096, PzBlock 8192, Pz 16384, Bleeding 32768,
Hungry 65536). Add `state:hasCondition(mask)`.

## P2-1 — Parser handlers that are "consume exactly, emit nothing" but a bot wants

| Opcode | Currently | Wanted by |
|---|---|---|
| 0x7A/0x7B NPC trade | discarded (`parser.lua:1451-1470`) | **P0-6** |
| 0xF5 PlayerInventory | stored, not emitted (`:1429`) | supply checks |
| 0x5D ImbuementDurations | fully discarded (`:1173-1186`) | `cavebot/imbuing.lua`, `g_game.imbuementDurations` |
| 0xEB ImbuementWindow | discarded (`:2700-2730`) | `onImbuementWindow` |
| 0xC0 LootContainers | discarded (`:2085-2091`) | quick-loot config awareness |
| 0x29 SupplyStash | stored as `state.supplyStash` ✓ (`:899`) | depositer — fine |
| 0x2A SpecialContainer | discarded (`:908`) | `isSupplyStashAvailable()` (2 call sites) |
| 0xF4 ItemInfo | discarded (`:2776`) | look responses |
| 0x7D/0x7E OwnTrade/CounterTrade | items parsed, discarded (`:1473-1477`) | player-trade scripts |
| 0x96 EditText | parsed (`:1683`) | `onGameEditText` |
| 0xB6 WalkWait | emits `walkWait{millis}` ✓ | **the walker must honour it** (P0-5) |
| 0x8B CreatureData | `:1597` | creature mana/name updates for party healing |
| 0x93 CreatureMarks / 0x95 CreatureType | `:1663/1675` | TargetBot summon/master filtering (`masterId`) |

## P2-2 — Bot configuration loader

vBot reads settings from widgets, but every value is persisted on disk (see `configFormat`). A
headless host needs a `bot/config.lua` that loads:
* `profiles/bot/<name>/storage/profile_<N>.json` → the global `storage` table (HealBot, AttackBot,
  Conditions, Equipper, supplies, `extras`, `moneyItems`, `foodItems`, …).
* `profiles/bot/<name>/targetbot_configs/<cfg>.json` → `{looting = {...}, targeting = [...]}`.
* `profiles/bot/<name>/cavebot_configs/<cfg>.cfg` → line-oriented waypoint list + a `config:` JSON line.
`lib/json.lua` already exists, so this is pure plumbing. **All of it is behaviour**; the `.otui` files
and every `ui.*`/`UI.Container`/`setOn`/`getText` call in the bot sources are widget detail with a
1:1 JSON counterpart (e.g. `ui.everyItem:isOn()` ⇄ `looting.everyItem`,
`ui.maxDangerPanel.value:getText()` ⇄ `looting.maxDanger`, `targetbot/looting.lua:75-81`).

## P2-3 — `Item.create(id)` equivalent

The bot constructs virtual items constantly (`Item.create(id)` in npc.lua, depositer_config, analyzer).
With P0-1 this becomes a trivial table factory:
`items.virtual(id [, countOrSubType, tier])` → `{kind='item', id=, count=, tier=}` plus the predicate
functions taking that table.

## P3-1 — `getSpectatorsByPattern`, `isTrapped`, `canShoot`

`map.lua:249-271` and one call to `g_map.getSpectatorsByPattern`. Low value; `isTrapped` and
`canShoot` fall out of P0-3 (`isWalkable` + `isSightClear`) for free.

## P3-2 — Diagnostics parity

`g_game.getUnjustifiedPoints` (15 call sites) → `state.unjustified` already exists
(`parser.lua:2037-2045`), just needs an accessor. `g_game.getClientVersion/getProtocolVersion`
(70 + 2 call sites) → expose `parser.clientVersion/protocolVersion` on `state`.
`g_game.isOnline` → `LC.inGame` (`main.lua:299`).

---

## Summary table (priority → effort)

| # | Gap | New/changed file | Effort |
|---|---|---|---|
| P0-1 | extended item metadata v2 | `tools/extract_appearances.py`, `proto/items.lua`, `assets/items1530.bin` | M |
| P0-2 | pathfinder + minimap store | `game/pathfinder.lua`, `game/minimap.lua`, hook in `parser.lua:415` | L |
| P0-3 | tile derived queries | `game/state.lua` (`tileFlags`, `isWalkable`, `isPathable`, `getTopUseThing`, `getMinimapColorByte`, `getGroundSpeed`, `isSightClear`) | M |
| P0-4 | container slot semantics + slot positions | `proto/parser.lua` S[0x70/0x71/0x72], `game/state.lua` | S |
| P0-5 | walk controller + step duration + ping | `game/walker.lua`, `main.lua` | M |
| P0-6 | NPC trade state | `proto/parser.lua` S[0x7A/0x7B/0x7C], `game/state.lua` | S |
| P0-7 | cooldown/exhaust tracker + spell table | `game/cooldowns.lua`, `data/spells.lua` | M |
| P1-1 | attack/follow target tracking | `proto/sender.lua`, `proto/parser.lua` S[0xA3] | S |
| P1-2 | spectators | `game/state.lua` | S |
| P1-3 | missing senders (stash/party/imbuement/browseField + Game:: wrappers) | `proto/sender.lua` | S |
| P1-4 | missing events (onUse, onAddThing, animatedText, inventoryCounts, containerOpen prev) | `proto/parser.lua`, `proto/sender.lua` | S |
| P1-5 | player field consolidation | `game/state.lua` | S |
| P2-1 | un-emitted parses (imbuement, loot containers, F5, stash availability) | `proto/parser.lua` | S |
| P2-2 | bot config loader | `bot/config.lua` | S |
| P2-3 | virtual items | `proto/items.lua` | XS |

## Configuration format

## 1. `assets/items1530.bin` — proposed **version 2** (replaces the v1 layout at `proto/items.lua:14-46` / `tools/extract_appearances.py:23-63`)

All little-endian, unsigned. The comment block must be duplicated verbatim in both
`tools/extract_appearances.py` and `proto/items.lua`, exactly as v1 does today.

```
 off  size  field              value for this asset set
   0     4  magic              "LCIT"
   4     1  version            2                      (v1 = 1; loader must accept both)
   5     1  headerSize         40
   6     2  categoryCount      4
   8     4  itemArrayLen       62145   (maxItemId+1; valid ids 1..62144)
  12     4  creatureArrayLen   10004
  16     4  effectArrayLen       344
  20     4  missileArrayLen       83
  24     4  objectCount        43536
  28     2  contentRevision    42196   (diagnostic only)
  30     2  reserved           0
  32     1  sectionCount       11
  33     3  reserved           0,0,0
  36     4  sectionTableOff    40
  40  12*11 section directory
 ...        section payloads (in directory order, 4-byte aligned)

 SECTION DIRECTORY ENTRY (12 bytes)
   0  1  sectionId
   1  1  elemSize        bytes per item id (0 for blob/index sections)
   2  2  reserved        0
   4  4  offset          absolute byte offset in the file
   8  4  byteLength

 SECTIONS
   id  name          elemSize  length                 content
    1  FLAGS1           1      itemArrayLen  62145    v1 bits, UNCHANGED (parser depends on them)
    2  FLAGS2           1      itemArrayLen  62145    movement / stack-priority bits
    3  FLAGS3           1      itemArrayLen  62145    interaction bits
    4  FLAGS4           1      itemArrayLen  62145    misc bits
    5  GROUNDSPEED      2      2*itemArrayLen 124290  bank.waypoints (0 = not a ground)
    6  MINIMAPCOLOR     1      itemArrayLen  62145    automap.color (0 = none)
    7  ELEVATION        1      itemArrayLen  62145    height.elevation (0..24 observed)
    8  LENSHELP         2      2*itemArrayLen 124290  lenshelp.id (0 = none; 1100/1102/1104/1105 matter)
    9  CLOTHSLOT        1      itemArrayLen  62145    clothes.slot (0 = none)
   10  NAMEIDX          6      6*8951 = 53706         sparse, ASCENDING by id:
                                                        u16 itemId, u32 offsetIntoNameBlob
   11  NAMEBLOB         1      158681                 concatenated NUL-terminated UTF-8

 total file = 40 + 132 + 683595 + 53706 + 158681 = 896154 bytes  (~875 KB; v1 was 62177)

 FLAGS1 (unchanged from v1 -- do not renumber)
   0x01 CUMULATIVE   cumulative(6) | liquidcontainer(19) | liquidpool(12)
   0x02 WEAROUT      wearout(53)
   0x04 EXPIRE       clockexpire(54) | expire(55) | expirestop(56)
   0x08 CONTAINER    container(5)
   0x10 CLASSIFY     upgradeclassification(48).upgrade_classification > 0
   0x20 PODIUM       show_off_socket(46)
   0x40 DECOKIT      deco_kit(57)
   0x80 (spare)

 FLAGS2 -- movement / stack priority   (proto field #, thingtype.cpp line)
   0x01 GROUND            has_bank()               #1   PRESENCE ONLY   :179
   0x02 GROUND_BORDER     clip                     #2   has && value    :184
   0x04 ON_BOTTOM         has_bottom()             #3   PRESENCE ONLY   :188
   0x08 ON_TOP            has_top()                #4   PRESENCE ONLY   :192
   0x10 NOT_WALKABLE      unpass                   #13  has && value    :230
   0x20 NOT_PATHABLE      avoid                    #16  has && value    :244
   0x40 NOT_MOVEABLE      unmove                   #14  has && value    :234
   0x80 BLOCK_PROJECTILE  unsight                  #15  has && value    :239

 FLAGS3 -- interaction
   0x01 PICKUPABLE        take                     #18  :250
   0x02 USABLE            usable                   #7   :215
   0x04 MULTIUSE          multiuse                 #9   :207
   0x08 FORCE_USE         forceuse                 #8   :211
   0x10 FLUID_CONTAINER   liquidcontainer          #19  :254
   0x20 SPLASH            liquidpool               #12  :226
   0x40 HANGABLE          hang                     #20  :258
   0x80 WRITABLE          has_write() | has_write_once()  #10/#11  :219/:224

 FLAGS4 -- misc
   0x01 ROTATEABLE        rotate                   #22  :288
   0x02 FULL_GROUND       fullbank                 #32  :323
   0x04 IGNORE_LOOK       ignore_look              #33  :327
   0x08 CORPSE            corpse                   #42  (no C++ flag; loot heuristic)
   0x10 PLAYER_CORPSE     player_corpse            #43
   0x20 LYING_OBJECT      lying_object             #28  :305
   0x40 WRAPABLE          wrap                     #37  :361
   0x80 UNWRAPABLE        unwrap                   #38  :365

 NOTE 1: `bottom`, `top` and `bank` are PRESENCE tests in C++ -- do not require value != 0.
         Every other boolean is proto2 has_x() && x().
 NOTE 2: there is NO floor-change bit at 1530. ThingFlagAttrFloorChange (const.h:1298) is only
         ever set from the legacy .dat path (thingtype.cpp:1096), so Tile::hasFloorChange() is
         permanently false. Floor changes are inferred from LENSHELP + GROUND + NOT_PATHABLE +
         MINIMAPCOLOR 210..213, exactly as cavebot/walking.lua:116-150 does.
 NOTE 3: bank present but waypoints absent -> groundSpeed 0. Tile::getGroundSpeed() then returns
         100 (tile.cpp:563-569) while Creature::getStepDuration() substitutes 150
         (creature.cpp:1120-1121). Keep BOTH fallbacks at their respective call sites.
```

### Real records, decoded from `appearances-17a72b30b5c3c9ca8c1283cfb2febd2a93a145ff8ab66916f7a412d0f1dee5a1.dat`

```
id 3031  "gold coin"
  raw flags: cumulative(6), take(18)
  FLAGS1=0x01  FLAGS2=0x00  FLAGS3=0x01  FLAGS4=0x00
  groundSpeed=0  minimapColor=0  elevation=0  lensHelp=0  clothSlot=0

id 2854  "backpack"
  raw flags: container(5), usable(7), take(18), clothes{slot=3}
  FLAGS1=0x08  FLAGS2=0x00  FLAGS3=0x03  FLAGS4=0x00
  groundSpeed=0  minimapColor=0  elevation=0  lensHelp=0  clothSlot=3

id 3160  "ultimate healing rune"
  raw flags: cumulative(6), usable(7), multiuse(9), take(18)
  FLAGS1=0x01  FLAGS2=0x00  FLAGS3=0x07  FLAGS4=0x00

id 103   (unnamed grass/ground)
  raw flags: bank{waypoints=110}, unmove(14), automap{color=129}, fullbank(32)
  FLAGS1=0x00  FLAGS2=0x41 (GROUND|NOT_MOVEABLE)  FLAGS3=0x00  FLAGS4=0x02 (FULL_GROUND)
  groundSpeed=110  minimapColor=129

id 4526  (unnamed ground)
  bank{150}, unmove, automap{24}, fullbank
  FLAGS2=0x41  groundSpeed=150  minimapColor=24

id 386   (rope spot -- listed in the cavebot cfg key "antiLostRopeIds")
  bank{waypoints=120}, usable(7), forceuse(8), unmove(14), automap{color=210}, lenshelp{id=1102}, fullbank
  FLAGS1=0x00  FLAGS2=0x41  FLAGS3=0x0A (USABLE|FORCE_USE)  FLAGS4=0x02
  groundSpeed=120  minimapColor=210  lensHelp=1102

id 1948  (ladder -- listed in the cfg key "antiLostLadderIds")
  bottom(3), usable(7), forceuse(8), unmove(14), automap{color=210}, lenshelp{id=1100}
  FLAGS1=0x00  FLAGS2=0x44 (ON_BOTTOM|NOT_MOVEABLE)  FLAGS3=0x0A  FLAGS4=0x00
  minimapColor=210  lensHelp=1100

id 9596  "squeezing gear of girlpower"  (cfg key "machete": 9596)
  usable(7), multiuse(9), take(18)  ->  FLAGS3=0x07
```

---

## 2. vBot configuration on disk (what a headless host reads instead of widgets)

Root: `D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/`

### 2a. `storage/profile_<N>.json` — the whole `storage` global, one JSON object (44 975 bytes on disk)

Real excerpt (verbatim head of `storage/profile_1.json`):

```json
{"combobot":{"onCastEnabled":false,"attackItemToggle":false,"sayPhrase":"","onSayEnabled":false,
 "serverEnabled":false,"serverLeader":"","serverTriggers":true,"onShootEnabled":false,
 "shootLeader":"","followLeaderEnabled":false,"sayLeader":"","castLeader":"","attackSpellEnabled":false,
 "commandsEnabled":true,"spell":"","attackLeaderTargetEnabled":false,"attack":"",
 "serverLeaderTarget":false,"follow":"","item":3155,"enabled":false},
 "_icons":{"looter":{"y":0.25,"enabled":false,"x":0.01}, ...},
 "autoEquip":[{"on":true,"slot":9,"item1":3097,"item2":3099,"title":"Auto Equip"},
              {"on":false,"slot":2,"item1":815,"item2":815,"title":"Auto Equip"}],
 "newHealer":{"enabled":true,
   "settings":[{"type":"HealItem","text":"Mana Item ","value":268},
               {"type":"HealScroll","text":"Item Range: ","value":6},
               {"type":"HealItem","text":"Health Item ","value":3160},
               {"type":"HealScroll","text":"Heal Friend at: ","value":80},
               {"type":"HealScroll","text":"Min Player HP%: ","value":90},
               {"type":"HealScroll","text":"Min Player MP%: ","value":30}],
   "conditions":{"friends":false,"druids":true,"sorcerers":true,"paladins":true,"knights":true,
                 "monks":true,"party":true,"botserver":false,"guild":false,"friendListOnly":false},
   "priorities":[{"name":"Custom Spell","enabled":false,"custom":true},
                 {"name":"Exura Gran Mas Res","enabled":true,"area":true},
                 {"normal":true,"enabled":true,"name":"Exura Sio"}]},
 "moneyItems":[{"count":1,"id":3031},{"count":1,"id":3035}],
 "extras":{"bless":true,"antiKick":true,"lootLast":true,"pathfinding":true,"reUse":false,
           "gotoMaxDistance":64,"suppliesControl":false,"autoOpenDoors":true,"nextBackpack":true,
           "machete":9596,"stake":false,"oberon":true,"holdMwHot":"F5","holdWgHot":"F6", ...}}
```

Keys the four modules read at runtime (behaviour, not widget):
`storage.extras.looting` (loot search radius, default 40), `storage.extras.lootDelay` (default 200 ms),
`storage.extras.lootLast` (loot the newest corpse first), `storage.foodItems` (`[{id=,count=}]`),
`storage.moneyItems`, `storage.newHealer.*`, `storage.combobot.*`, `storage.autoEquip[]`,
`storage.alarms.*`, `storage.stances.*`, `storage.AutoTrainingWeapon.*`.

### 2b. `targetbot_configs/<name>.json` — one TargetBot profile

Verbatim `targetbot_configs/def.json`:

```json
{"looting":{"everyItem":false,"maxDanger":10,"minCapacity":100,
            "containers":[{"count":0,"id":2854}],
            "items":[{"count":0,"id":9084}]},
 "targeting":[{"name":"*","regex":"^.*$","priority":1,"danger":1,
               "chase":false,"keepDistance":false,"keepDistanceRange":1,
               "maxDistance":10,"anchor":false,"anchorRange":3,
               "lure":false,"lureMin":1,"lureMax":3,"lureCount":1,"lureDelay":250,
               "dynamicLure":false,"dynamicLureDelay":false,"lureCavebot":false,
               "closeLure":false,"closeLureAmount":3,
               "rePosition":false,"rePositionAmount":5,
               "faceMonster":false,"avoidAttacks":false,"diamondArrows":false,
               "rpSafe":false,"delayFrom":2,"dontLoot":true}]}
```

Field ⇄ widget mapping (so a headless client needs no UI):
`looting.everyItem` ⇄ `ui.everyItem:isOn()`; `looting.maxDanger` ⇄ `ui.maxDangerPanel.value:getText()`;
`looting.minCapacity` ⇄ `ui.minCapacityPanel.value:getText()`; `looting.items`/`containers` ⇄
`ui.items:getItems()` / `ui.containers:getItems()` (`targetbot/looting.lua:75-81`).
Item entries are `{id = <clientId>, count = <n>}`; `count` is display-only.

### 2c. `cavebot_configs/<name>.cfg` — line-oriented waypoints + one JSON config line

Verbatim `cavebot_configs/test.cfg`:

```
goto:33218,32434,7,0
exanihur:up,north
exanihur:down,south
config:{"ignoreFields":false,"skipBlocked":false,"antiLostLadderIds":"1948,1968,5542,7771,9116,20474,20475,21365,28656,31129,31130,31262,33770,34243,35908,43374,48493,48494,50122,50123,50564,50565,435,7750,21221,21298","ping":100,"antiLostRopeToolId":9596,"stayPathEnabled":true,"waypointHud":false,"walkDelay":10,"avoidTileIds":"","avoidFloorChange":true,"mapClickDelay":100,"useDelay":400,"wptDistance":5,"antiLostTeleportIds":"1949,1950,1951,1952","mapClick":false,"smoothWalk":false,"antiLostRopeIds":"386,7762,12935,12936,13381,33051","antiLostEnabled":true}
extensions:[]
staypositions:{"3":{"x":33218,"y":32433,"z":6},"2":{"x":33218,"y":32434,"z":7}}
```

Grammar: each line is `<action>:<value>`. Waypoint actions are the ones in `cavebot/*.lua`
(`goto`, `use`, `usewith`, `label`, `gotolabel`, `delay`, `say`, `function`, `depositer`, `travel`,
`buy_supplies`, `sell_all`, `withdraw`, `imbuing`, `lure`, `stand_lure`, `clear_tile`, `pos_check`, …)
plus per-installation extension actions (`exanihur` above). Three lines are **not** waypoints and must
be recognised specially: `config:` (JSON, the `CaveBot.Config.values` table used by
`cavebot/walking.lua:210,245` for `ping`/`walkDelay`/`smoothWalk`/`mapClick`), `extensions:` (JSON
array) and `staypositions:` (JSON map keyed by waypoint index string).

`goto` payload is `x,y,z[,precision]`. `waypointHud` is the only widget-only key in the block.

## Pseudocode

-- ===========================================================================
-- 1. tools/extract_appearances.py  (v2 writer)  -- additions only
-- ===========================================================================
BOOL_FIELD_TO_BIT2 = {                     # -> FLAGS2
    13: NOT_WALKABLE,  16: NOT_PATHABLE, 14: NOT_MOVEABLE, 15: BLOCK_PROJECTILE,
    2 : GROUND_BORDER,                                        # clip: has && value
}
PRESENCE_FIELD_TO_BIT2 = { 1: GROUND, 3: ON_BOTTOM, 4: ON_TOP }   # has_x() only!
BOOL_FIELD_TO_BIT3 = { 18:PICKUPABLE, 7:USABLE, 9:MULTIUSE, 8:FORCE_USE,
                       19:FLUID_CONTAINER, 12:SPLASH, 20:HANGABLE }
PRESENCE_FIELD_TO_BIT3 = { 10: WRITABLE, 11: WRITABLE }
BOOL_FIELD_TO_BIT4 = { 22:ROTATEABLE, 32:FULL_GROUND, 33:IGNORE_LOOK,
                       42:CORPSE, 43:PLAYER_CORPSE, 28:LYING_OBJECT, 37:WRAPABLE, 38:UNWRAPABLE }
SUBMSG = { 1:('groundSpeed',1,'u16'), 27:('elevation',1,'u8'),
           30:('minimapColor',1,'u8'), 31:('lensHelp',1,'u16'), 34:('clothSlot',1,'u8') }

def flags_of_region(buf, s, e):            # extend the existing function
    f1=f2=f3=f4=0 ; cols = {}
    for fn, wt, v, ss, se in iter_fields(buf, s, e):
        if wt == 0:
            if fn in BOOL_FIELD_TO_BIT and v: f1 |= BOOL_FIELD_TO_BIT[fn]
            if fn in BOOL_FIELD_TO_BIT2 and v: f2 |= BOOL_FIELD_TO_BIT2[fn]
            if fn in BOOL_FIELD_TO_BIT3 and v: f3 |= BOOL_FIELD_TO_BIT3[fn]
            if fn in BOOL_FIELD_TO_BIT4 and v: f4 |= BOOL_FIELD_TO_BIT4[fn]
            if fn in PRESENCE_FIELD_TO_BIT2: f2 |= PRESENCE_FIELD_TO_BIT2[fn]   # varint form
            if fn in PRESENCE_FIELD_TO_BIT3: f3 |= PRESENCE_FIELD_TO_BIT3[fn]
        elif wt == 2:
            if fn == 48:  ...existing CLASSIFY...
            if fn in PRESENCE_FIELD_TO_BIT2: f2 |= PRESENCE_FIELD_TO_BIT2[fn]   # LEN form
            if fn in PRESENCE_FIELD_TO_BIT3: f3 |= PRESENCE_FIELD_TO_BIT3[fn]
            if fn in SUBMSG:
                col, inner_fn, _ = SUBMSG[fn]
                cols[col] = first_varint(buf, ss, se, inner_fn) or 0
    return f1,f2,f3,f4,cols
-- parse_appearances(): also capture Appearance.name (field 4) ALWAYS (only 8951 exist).
-- writer(): emit header(v2) + 11 directory entries + payloads; NAMEIDX sorted ascending by id.

-- ===========================================================================
-- 2. proto/items.lua  (v2 loader)
-- ===========================================================================
function items.load(path)
  ... read whole file into `blob` ...
  assert(blob:sub(1,4)=='LCIT')
  local version = blob:byte(5)
  if version == 1 then                      -- legacy: only FLAGS1 present at offset 32
      SEC[FLAGS1] = {off=32, elem=1}
  else
      local n = blob:byte(33); local dirOff = u32le(blob, 37)
      for i=0,n-1 do
          local o = dirOff + i*12
          SEC[blob:byte(o+1)] = { elem=blob:byte(o+2), off=u32le(blob,o+5), len=u32le(blob,o+9) }
      end
      -- name table -> plain Lua map, built once (8951 entries)
      local ix, blobOff = SEC[NAMEIDX], SEC[NAMEBLOB].off
      for i=0, ix.len/6 - 1 do
          local id  = u16le(blob, ix.off + i*6 + 1)
          local off = u32le(blob, ix.off + i*6 + 3)
          local e   = blob:find('\0', blobOff + off + 1, true)
          NAMES[id] = blob:sub(blobOff + off + 1, e - 1)
      end
  end
end

local function col1(sec, id)  local s=SEC[sec]; if not s then return 0 end
                              if id<1 or id>items.MAX_ID then return 0 end
                              return blob:byte(s.off + id + 1) end
local function col2(sec, id)  local s=SEC[sec]; if not s then return 0 end
                              return u16le(blob, s.off + id*2 + 1) end

function items.flags (id) return col1(FLAGS1, id) end   -- UNCHANGED contract
function items.flags2(id) return col1(FLAGS2, id) end
function items.flags3(id) return col1(FLAGS3, id) end
function items.flags4(id) return col1(FLAGS4, id) end
function items.groundSpeed (id) return col2(GROUNDSPEED, id) end
function items.minimapColor(id) return col1(MINIMAPCOLOR, id) end
function items.elevation   (id) return col1(ELEVATION, id) end
function items.lensHelp    (id) return col2(LENSHELP, id) end
function items.clothSlot   (id) return col1(CLOTHSLOT, id) end
function items.name        (id) return NAMES[id] end

local band = bit.band
function items.isGround(id)         return band(items.flags2(id), 0x01) ~= 0 end
function items.isGroundBorder(id)   return band(items.flags2(id), 0x02) ~= 0 end
function items.isOnBottom(id)       return band(items.flags2(id), 0x04) ~= 0 end
function items.isOnTop(id)          return band(items.flags2(id), 0x08) ~= 0 end
function items.isNotWalkable(id)    return band(items.flags2(id), 0x10) ~= 0 end
function items.isNotPathable(id)    return band(items.flags2(id), 0x20) ~= 0 end
function items.isNotMoveable(id)    return band(items.flags2(id), 0x40) ~= 0 end
function items.isBlockProjectile(id)return band(items.flags2(id), 0x80) ~= 0 end
function items.isPickupable(id)     return band(items.flags3(id), 0x01) ~= 0 end
function items.isUsable(id)         return band(items.flags3(id), 0x02) ~= 0 end
function items.isMultiUse(id)       return band(items.flags3(id), 0x04) ~= 0 end
function items.isForceUse(id)       return band(items.flags3(id), 0x08) ~= 0 end
function items.isFluidContainer(id) return band(items.flags3(id), 0x10) ~= 0 end
function items.isSplash(id)         return band(items.flags3(id), 0x20) ~= 0 end
function items.isContainer(id)      return band(items.flags (id), 0x08) ~= 0 end
function items.isStackable(id)      return band(items.flags (id), 0x01) ~= 0 end
function items.isCommon(id)         -- Thing::isCommon
  local f = items.flags2(id); return band(f, 0x01+0x02+0x04+0x08) == 0 end
function items.stackPriority(id)    -- Thing::getStackPriority (thing.cpp:54-77)
  if items.isGround(id)       then return 0 end
  if items.isGroundBorder(id) then return 1 end
  if items.isOnBottom(id)     then return 2 end
  if items.isOnTop(id)        then return 3 end
  return 5                                        -- creatures are 4, handled by the caller
end

-- ===========================================================================
-- 3. game/state.lua -- tile flag cache + derived queries  (replaces walkableAt)
-- ===========================================================================
local TF = { NOT_WALKABLE=1, NOT_PATHABLE=2, BLOCK_PROJ=4, HAS_CREATURE=8,
             HAS_GROUND=16, FULL_GROUND=32, HAS_COMMON=64 }

function state:_recomputeTileFlags(tile)          -- tile.cpp:920-1010
  local f, ground = 0, nil
  for i = 1, #tile.things do
    local t = tile.things[i]
    if t.kind == 'creature' then f = bor(f, TF.HAS_CREATURE)
    else
      local id = t.id
      if items.isNotWalkable(id)     then f = bor(f, TF.NOT_WALKABLE) end
      if items.isNotPathable(id)     then f = bor(f, TF.NOT_PATHABLE) end
      if items.isBlockProjectile(id) then f = bor(f, TF.BLOCK_PROJ)   end
      if items.isCommon(id)          then f = bor(f, TF.HAS_COMMON)   end
      if i == 1 and items.isGround(id) then ground = t; f = bor(f, TF.HAS_GROUND) end
      if band(items.flags4(id), 0x02) ~= 0 then f = bor(f, TF.FULL_GROUND) end
    end
  end
  tile._flags, tile._ground = f, ground
  return f
end
-- invalidate tile._flags = nil in addThing / _removeAt / setTile / cleanTile.

function state:tileFlags(pos)
  local t = self.map[tileKey(pos)]; if not t then return nil end
  return t._flags or self:_recomputeTileFlags(t)
end

function state:isWalkable(pos, ignoreCreatures)            -- tile.cpp:708-725
  local f = self:tileFlags(pos); if not f then return false, 'unknown-tile' end
  if band(f, TF.NOT_WALKABLE) ~= 0 then return false, 'item' end
  if band(f, TF.HAS_GROUND)   == 0 then return false, 'no-ground' end
  if not ignoreCreatures and band(f, TF.HAS_CREATURE) ~= 0 then
    for _, t in ipairs(self.map[tileKey(pos)].things) do
      if t.kind == 'creature' then
        local c = self.creatures[t.creatureId]
        if not (c and c.passable) then return false, 'creature' end   -- unpass default = blocks
      end
    end
  end
  return true
end

function state:isPathable(pos)                             -- tile.h:77
  local f = self:tileFlags(pos); return f ~= nil and band(f, TF.NOT_PATHABLE) == 0 end

function state:hasBlockingCreature(pos)                    -- tile.cpp:838-844
  local t = self.map[tileKey(pos)]; if not t then return false end
  for _, th in ipairs(t.things) do
    if th.kind == 'creature' and th.creatureId ~= self.player.id then
      local c = self.creatures[th.creatureId]
      if not (c and c.passable) then return true end
    end
  end
  return false
end

function state:getGroundSpeed(pos)                         -- tile.cpp:563-569
  local t = self.map[tileKey(pos)]; if not t then return 100 end
  if not t._flags then self:_recomputeTileFlags(t) end
  if not t._ground then return 100 end
  local s = items.groundSpeed(t._ground.id); return s ~= 0 and s or 100
end

function state:getMinimapColorByte(pos)                    -- tile.cpp:571-585
  local t = self.map[tileKey(pos)]; if not t then return 0 end
  for i = #t.things, 1, -1 do
    local th = t.things[i]
    if th.kind ~= 'creature' and not items.isCommon(th.id) then
      local c = items.minimapColor(th.id); if c ~= 0 then return c end
    end
  end
  return 255
end

function state:getTopUseThing(pos)                         -- tile.cpp:600-617
  local t = self.map[tileKey(pos)]; if not t or #t.things == 0 then return nil end
  for _, th in ipairs(t.things) do
    if th.kind ~= 'creature' then
      local id = th.id
      if items.isForceUse(id) or (items.isCommon(id) and not items.isSplash(id)) then return th end
    end
  end
  for i = #t.things, 2, -1 do
    local th = t.things[i]
    if th.kind ~= 'creature' and not items.isSplash(th.id) then return th end
  end
  return t.things[1]
end

function state:getTopMoveThing(pos)                        -- tile.cpp:654-675
  local t = self.map[tileKey(pos)]; if not t or #t.things == 0 then return nil end
  for i, th in ipairs(t.things) do
    if th.kind ~= 'creature' and items.isCommon(th.id) then
      if i > 1 and items.isNotMoveable(th.id) then return t.things[i-1] end
      return th
    end
  end
  for _, th in ipairs(t.things) do if th.kind == 'creature' then return th end end
  return t.things[1]
end

function state:isSightClear(fromPos, toPos)                -- map.cpp:1181-1225
  if samePos(fromPos, toPos) then return true end
  local start = (fromPos.z > toPos.z) and copyPos(toPos) or copyPos(fromPos)
  local dest  = (fromPos.z > toPos.z) and fromPos or toPos
  local mx = start.x < dest.x and 1 or (start.x == dest.x and 0 or -1)
  local my = start.y < dest.y and 1 or (start.y == dest.y and 0 or -1)
  local A, B = dest.y - start.y, start.x - dest.x
  local C = -(A*dest.x + B*dest.y)
  while start.x ~= dest.x or start.y ~= dest.y do
    local h = math.abs(A*(start.x+mx) + B*start.y      + C)
    local v = math.abs(A*start.x      + B*(start.y+my) + C)
    local x = math.abs(A*(start.x+mx) + B*(start.y+my) + C)
    if start.y ~= dest.y and (start.x == dest.x or h > v or h > x) then start.y = start.y + my end
    if start.x ~= dest.x and (start.y == dest.y or v > h or v > x) then start.x = start.x + mx end
    local f = self:tileFlags(start)
    if f and band(f, TF.BLOCK_PROJ) ~= 0 then return false end   -- Tile::isLookPossible
  end
  while start.z ~= dest.z do
    if self:thingCount(start) > 0 then return false end
    start.z = start.z + 1
  end
  return true
end

-- container / inventory addressing (container.h:37, thing.cpp:94-104, game.cpp:1786-1791)
function state:containerSlotPos(cid, slot0) return {x=0xFFFF, y=bit.bor(cid,0x40), z=slot0} end
function state:inventorySlotPos(slot)       return {x=0xFFFF, y=slot, z=0} end
function state:findEmptyContainerId()
  local id = 0; while self.containers[id] do id = id + 1 end; return id end
function state:findPlayerItem(itemId, subType, tier)          -- game.cpp:909-933
  for slot = 1, 10 do                                          -- Head..Ammo
    local it = self.player.inventory[slot]
    if it and it.id == itemId and (subType == -1 or (it.count or 0) == subType) then
      return it, self:inventorySlotPos(slot), 0
    end
  end
  for cid, c in pairs(self.containers) do
    for i, it in ipairs(c.items) do
      if it.id == itemId and (subType == -1 or (it.count or 0) == subType)
         and (it.tier or 0) == (tier or 0) then
        return it, self:containerSlotPos(cid, i-1), i-1
      end
    end
  end
end
function state:itemAmount(itemId, tier)                        -- 0xF5 cache
  local n = 0
  for key, amount in pairs(self.inventoryCounts or {}) do
    if math.floor(key/256) == itemId and (tier == nil or key % 256 == tier) then n = n + amount end
  end
  return n
end
function state:getSpectators(center, multiFloor)               -- map.cpp:651-700
  local a = self.world.awareRange
  return self:getSpectatorsInRangeEx(center, multiFloor, a.left, a.right, a.top, a.bottom)
end
function state:getSpectatorsInRangeEx(c, multi, l, r, t, b)
  local z0, z1 = c.z, c.z
  if multi then z0, z1 = state.firstAwareFloor(c.z), state.lastAwareFloor(c.z) end
  local out, seen = {}, {}
  for z = z0, z1 do for y = c.y - t, c.y + b do for x = c.x - l, c.x + r do
    local tile = self.map[x..','..y..','..z]
    if tile then for _, th in ipairs(tile.things) do
      if th.kind == 'creature' and not seen[th.creatureId] then
        seen[th.creatureId] = true; out[#out+1] = self.creatures[th.creatureId]
      end
    end end
  end end end
  return out
end

-- ===========================================================================
-- 4. game/pathfinder.lua  -- Map::findEveryPath (map.cpp:1316-1473)
-- ===========================================================================
local DIAGONAL = 3                              -- data/setup.otml:29 player diagonal-walk-speed
function pathfinder.findEveryPath(st, mm, start, maxDistance, p)
  local ret, nodes, pq = {}, {}, minheap()      -- key = totalCost
  local init = {cost=1, totalCost=0, pos=start, prev=nil, distance=0, unseen=0}
  nodes[key(start)] = init ; pq:push(init)
  local destPos, hasMargin = p.destination, (p.marginMin or p.marginMax) ~= nil
  while not pq:empty() do
    local node = pq:pop()
    ret[key(node.pos)] = { node.totalCost, node.distance,
                           node.prev and dirFromTo(node.prev.pos, node.pos) or -1,
                           node.prev and key(node.prev.pos) or "" }
    if destPos and samePos(node.pos, destPos) then
      if hasMargin then maxDistance = math.min(node.distance + 4, maxDistance) else break end
    end
    if node.distance < maxDistance then
      for i = -1, 1 do for j = -1, 1 do if not (i==0 and j==0) then
        local nb = {x=node.pos.x+i, y=node.pos.y+j, z=node.pos.z}
        if nb.x >= 0 and nb.y >= 0 then
          local k = key(nb) ; local ent = nodes[k]
          if ent == nil then
            local wasSeen, hasCreature = false, false
            local notWalk, notPath, mapColor, speed = true, true, 0, 1000
            if st:isAwareOf(nb) and st:tile(nb) then
              wasSeen   = true
              hasCreature = st:hasBlockingCreature(nb)
              notWalk   = not st:isWalkable(nb, true)
              notPath   = not st:isPathable(nb)
              mapColor  = st:getMinimapColorByte(nb)
              speed     = st:getGroundSpeed(nb)
            elseif not p.allowOnlyVisibleTiles then
              local mt = mm:get(nb)                       -- game/minimap.lua fallback
              wasSeen = mt.wasSeen; notWalk = mt.notWalkable; notPath = mt.notPathable
              mapColor = mt.color; speed = mt.speed
              if notWalk or notPath then wasSeen = true end
            end
            local hasStairs = notPath and mapColor >= 210 and mapColor <= 213
            local tooFar = p.maxDistanceFrom and distance(p.maxDistanceFromPos, nb) > p.maxDistanceFrom
            if (not wasSeen and not p.allowUnseen)
               or (hasStairs and not p.ignoreStairs and not samePos(nb, destPos))
               or (notPath  and not p.ignoreNonPathable and not samePos(nb, destPos))
               or (notWalk  and not p.ignoreNonWalkable) or tooFar then
              nodes[k] = false
            elseif hasCreature and not p.ignoreCreatures then
              nodes[k] = false
              if p.ignoreLastCreature then
                ret[k] = { node.totalCost + 100, node.distance + 1,
                           dirFromTo(node.pos, nb), key(node.pos) }
              end
            else
              nodes[k] = {cost=speed, totalCost=1e7, pos=nb, prev=node,
                          distance=node.distance+1, unseen = wasSeen and 0 or 1}
            end
            ent = nodes[k]
          end
          if ent then
            local diagonal = (i == 0 or j == 0) and 1 or DIAGONAL
            local cost = p.ignoreCost and 1 or (ent.cost * diagonal)
            if node.totalCost + cost < ent.totalCost then
              ent.totalCost = node.totalCost + cost ; ent.prev = node
              if ent.unseen ~= 0 then ent.unseen = node.unseen + 1 end
              ent.distance = node.distance + 1 ; pq:push(ent)
            end
          end
        end
      end end end
    end
  end
  return ret                       -- ["x,y,z"] = {totalCost, distance, dirFromPrev, prevKey}
end
-- pathfinder.findPath(): port mods/game_bot/functions/map.lua:143-220 verbatim (margin/precision
-- candidate scan + translateAllPathsToPath walking the prev chain backwards).

-- ===========================================================================
-- 5. game/cooldowns.lua  (cooldown.lua:63-67, 521-537; vlib.lua:279-379)
-- ===========================================================================
local cd = { spell = {}, group = {}, useReadyAt = 0, multiUseUntil = 0 }
function cd.onSpell(id, ms)      cd.spell[id]  = now() + ms end     -- 0xA4
function cd.onGroup(gid, ms)     cd.group[gid] = now() + ms end     -- 0xA5
function cd.onMultiUse(ms)       cd.multiUseUntil = now() + ms end  -- 0xA6
function cd.spellReady(id)       local t = cd.spell[id];  return not (t and now() < t) end
function cd.groupReady(gid)      local t = cd.group[gid]; return not (t and now() < t) end
function cd.reserveUse(ms)       cd.useReadyAt = math.max(cd.useReadyAt, now() + (ms or 1000)) end
function cd.useReady()           return now() >= cd.useReadyAt and now() >= cd.multiUseUntil end

-- vlib.lua:279-307 canCast, reproduced verbatim in behaviour:
function canCast(words, ignoreRL, ignoreCd)
  words = words:lower()
  local t = SpellCastTable[words]                         -- talk-confirm fallback
  if t then return ignoreCd or (now() - t.t > t.d) end
  local d = spells.byWords(words) or customCooldowns[words]
  if not d then return true end                           -- unknown spell -> allow
  local onCd = (not cd.spellReady(d.id))
  for gid in pairs(d.group or {}) do if not cd.groupReady(gid) then onCd = true end end
  return (ignoreCd or not onCd)
     and (ignoreRL  or (state.player.level >= d.level and state.player.mana >= d.mana))
end
-- vlib.lua:309-323 icon learning: on `talk` where name == player.name -> lastPhrase = text:lower()
-- then on the NEXT spellCooldown event (schedule 1 tick later) bind customCooldowns[lastPhrase] = {id=}
-- and on the next spellGroupCooldown bind .group = {[gid]=delay}.

-- ===========================================================================
-- 6. proto/parser.lua  -- container handlers rewritten (container.cpp:45-128)
-- ===========================================================================
S[0x70] = function(self, R)                       -- ContainerAddItem
  local cid  = R:u8()
  local wire = self:feat(F_CONTAINER_PAGINATION) and R:u16() or 0
  local item = self:readItem(R)
  local c = self.state.containers[cid]
  if c then
    local slot = wire - (c.firstIndex or 0)
    if c.hasPages and slot > c.capacity then
      c.size = (c.size or 0) + 1                       -- next page: NOT stored
    else
      if #c.items == c.capacity then
        table.remove(c.items)                          -- drops firstIndex+capacity-1
        c.size = (c.size or 0) + 1
      end
      table.insert(c.items, slot + 1, item)
      c.size = (c.size or 0) + 1
    end
  end
  self.emit('containerAddItem', {containerId=cid, slot=wire, item=item})
end
S[0x72] = function(self, R)                       -- ContainerRemoveItem
  local cid = R:u8() ; local wire, last
  if self:feat(F_CONTAINER_PAGINATION) then
    wire = R:u16() ; local lastId = R:u16()
    if lastId ~= 0 then last = self:readItem(R, lastId) end
  else wire = R:u8() end
  local c = self.state.containers[cid]
  if c then
    local slot = wire - (c.firstIndex or 0)
    if c.hasPages and slot >= #c.items then c.size = (c.size or 0) - 1
    elseif slot >= 0 and slot < #c.items then
      table.remove(c.items, slot + 1)
      if last then                                       -- re-add at firstIndex+capacity-1
        if #c.items == c.capacity then table.remove(c.items) ; c.size = c.size + 1 end
        table.insert(c.items, c.capacity, last) ; c.size = c.size            -- net 0
      end
      c.size = (c.size or 0) - 1
    end
  end
  self.emit('containerRemoveItem', {containerId=cid, slot=wire, lastItem=last})
end
-- S[0x6E] must also remember the previous container at that id and pass it as
-- `previous` in the containerOpen payload (targetbot/looting.lua:302-307 needs it).

-- ===========================================================================
-- 7. proto/parser.lua  -- NPC trade (protocolgameparse.cpp:1827-1886)
-- ===========================================================================
S[0x7A] = function(self, R)
  local d = { open = true, items = {} }
  if self:feat(F_NAME_ON_NPC_TRADE) then d.npcName = R:string() end
  if self.clientVersion >= 1281 then d.currencyId = R:u16(); d.currencyName = R:string() end
  local n = (self.clientVersion >= 900) and R:u16() or R:u8()
  for i = 1, n do
    local id, sub = R:u16(), R:u8()
    local name, weight = R:string(), R:u32()
    local buy, sell = R:u32(), R:u32()
    if buy  == 0xFFFFFFFF then buy  = 0 end
    if sell == 0xFFFFFFFF then sell = 0 end
    d.items[i] = { id=id, count=sub, subType=sub, name=name,
                   weight=weight/100, buyPrice=buy, sellPrice=sell }
  end
  self.state.npcTrade = d ; self.emit('npcTradeOpen', d)
end
S[0x7B] = function(self, R)
  if self.clientVersion < 1281 then if self:feat(98) then R:u64() else R:u32() end end
  local goods = {}
  local n = (self.clientVersion >= 1334) and R:u16() or R:u8()
  for _ = 1, n do
    local id = R:u16()
    goods[id] = self:feat(F_DOUBLE_SHOP_SELL_AMOUNT) and R:u16() or R:u8()
  end
  self.state.npcGoods = goods ; self.emit('npcGoods', goods)
end
S[0x7C] = function(self)
  self.state.npcTrade = nil ; self.state.npcGoods = nil ; self.emit('npcTradeClose', {})
end

-- ===========================================================================
-- 8. game/walker.lua  (creature.cpp:1106-1151; cavebot/walking.lua:210-300)
-- ===========================================================================
function walker.stepDuration(st, dir, ignoreDiagonal)
  local speed = st.player.speed ; if speed < 1 then return 0 end
  local dest  = translate(st.player.pos, dir)
  local gs    = st:getGroundSpeed(st:tile(dest) and dest or st.player.pos)
  if gs == 0 then gs = 150 end                              -- creature.cpp:1120 (NOT 100 here)
  local base
  if st.speedA and st.speedA ~= 0 and st.speedB ~= 0 and st.speedC ~= 0 then
    local calc = math.max(1, math.floor(st.speedA*math.log(speed + st.speedB) + st.speedC + 0.5))
    base = 1000 * gs / calc
  else base = 1000 * gs / speed end
  local beat = st.serverBeat or 50
  base = math.ceil(base / beat) * beat                       -- cv >= 860
  if not ignoreDiagonal and isDiagonal(dir) then base = base * 3 end
  return base
end

function walker:step(dir)                                   -- optimistic pre-walk
  local body = LC.sender:walk(dir) ; if not body then return false end
  self.pending[#self.pending+1] = { dir = dir, t = now() }
  self.lastSendAt = now() ; return true
end
LC.events.on('positionChange', function(d)                  -- confirm / reconcile
  local dir = dirFromTo(d.oldPos, d.pos)
  if walker.pending[1] and walker.pending[1].dir == dir then table.remove(walker.pending, 1)
  else walker.pending = {} end                              -- teleport / floor change
  walker.lastConfirmAt = now()
end)
LC.events.on('walkCancel', function(d) walker.pending = {} ; walker.blockedUntil = now() + 100 end)
LC.events.on('walkWait',   function(d) walker.blockedUntil = now() + d.millis end)
function walker.isPreWalking() return #walker.pending > 0 end
-- sendWindow (cavebot/walking.lua:245): min(3, 1 + ceil(ping / stepDuration(dir)))
-- watchdog  (cavebot/walking.lua:266): if now - max(lastConfirmAt, pending[1].t)
--                                        > ping + 2*stepDuration + 400 then stop() + clear.

-- ===========================================================================
-- 9. main.lua -- ping RTT + attack target + new modules
-- ===========================================================================
LC.pingSentAt = nil
sched.every(cfg.pingMs, function() LC.pingSentAt = sys.nowMs() ; LC.sender:ping() end)
events.on('pingBack', function()
  if LC.pingSentAt then LC.state.ping = sys.nowMs() - LC.pingSentAt ; LC.pingSentAt = nil end
end)
events.on('attackCancel', function(d)
  if d.seq == LC.sender.seq then LC.state.attackingId = nil end
end)
-- in proto/sender.lua attack()/follow(): on success set transport-owner state
--   self.state.attackingId = (creatureId ~= 0) and creatureId or nil
-- and emit 'attackingCreatureChange'; use()/useWith() emit 'use'/'useWith' (game.cpp:852,880).

## Evidence
- D:/Claude/otclient_web/luaclient/API.md:118-135 — items.lua contract lists ONLY the 7 protocol-parsing flag bits (CUMULATIVE/WEAROUT/EXPIRE/CONTAINER/CLASSIFY/PODIUM/DECOKIT)
- D:/Claude/otclient_web/luaclient/proto/items.lua:14-46 — items1530.bin v1 layout: header 32 B + itemArrayLen flag bytes; verified on disk = 62177 bytes, itemArrayLen 62145, objectCount 43536, contentRevision 42196
- D:/Claude/otclient_web/luaclient/tools/extract_appearances.py:19-21 — 'frame_group (2), name (4) and description (5) are deliberately NOT parsed'
- D:/Claude/otclient_web/luaclient/tools/extract_appearances.py:96-116 — BOOL_FIELD_TO_BIT covers only fields 5,6,12,19,46,48,53,54,55,56,57
- D:/Claude/otclient_web/luaclient/game/state.lua:86-99 — stackPriorityOf falls back to CREATURE(4)/COMMON(5) because items1530.bin carries no ground/border/bottom/top bits
- D:/Claude/otclient_web/luaclient/game/state.lua:517-536 — walkableAt's own comment: cannot see blocking items, isGround, blockPathfind, elevation or ground speed
- D:/Claude/otclient_web/luaclient/game/state.lua:409-436 — setCentralPosition evicts every tile outside the aware range; nothing persists them, so there is no minimap fallback
- D:/Claude/otclient_web/luaclient/proto/parser.lua:1378-1389 — S[0x70] does table.insert(c.items,1,item): ignores firstIndex, ignores hasPages, does not maintain c.size
- D:/Claude/otclient_web/luaclient/proto/parser.lua:1406-1427 — S[0x72] appends lastItem at the end instead of firstIndex+capacity-1
- D:/Claude/otclient_web/luaclient/proto/parser.lua:1451-1471 — S[0x7A] OpenNpcTrade and S[0x7B] PlayerGoods read every field into nothing
- D:/Claude/otclient_web/luaclient/proto/parser.lua:1869-1879 — S[0xA4]/S[0xA5]/S[0xA6] emit spellCooldown/spellGroupCooldown/multiUseCooldown and store nothing
- D:/Claude/otclient_web/luaclient/proto/parser.lua:1429-1449 — S[0xF5] builds state.inventoryCounts keyed itemId*256+tier but emits no event
- D:/Claude/otclient_web/luaclient/proto/parser.lua:1863-1867 — S[0xA3] ClearTarget emits attackCancel{seq} and clears no target (there is no target field)
- D:/Claude/otclient_web/luaclient/proto/parser.lua:857 — S[0x17] already stores serverBeat/speedA/speedB/speedC on the parser, but not on state
- D:/Claude/otclient_web/luaclient/proto/parser.lua:1173-1186 — S[0x5D] ImbuementDurations fully discarded; :2700-2730 S[0xEB] imbuement window discarded; :2085-2091 S[0xC0] loot containers discarded; :908 S[0x2A] supply-stash availability discarded
- D:/Claude/otclient_web/luaclient/proto/sender.lua:218-631 — 30 builders; no stash, party, imbuement, browseField, rotate, refreshContainer, and no Game::-level wrappers (useInventoryItem/useInventoryItemWith/moveThing/findEmptyContainerId)
- D:/Claude/otclient_web/luaclient/proto/sender.lua:517-519 — openContainer takes containerId with no default: Game::open uses findEmptyContainerId()
- D:/Claude/otclient_web/luaclient/main.lua:298-318 — keepalive ping and pong handler exist but nothing timestamps them: no getPing()
- D:/Claude/otclient_web/luaclient/game/state.lua:127-129 — player.serverPos/preWalks/walkLockUntil/waitingForServerWalk/lastWalkTime are declared and never written
- D:/Claude/otclient_mehah1530/otclient/src/protobuf/appearances.proto:134-211 — Appearance{id=1,frame_group=2,flags=3,name=4}; AppearanceFlags field numbers bank=1 clip=2 bottom=3 top=4 container=5 cumulative=6 usable=7 forceuse=8 multiuse=9 write=10 write_once=11 liquidpool=12 unpass=13 unmove=14 unsight=15 avoid=16 take=18 liquidcontainer=19 hang=20 rotate=22 height=27 lying_object=28 automap=30 lenshelp=31 fullbank=32 ignore_look=33 clothes=34 market=36 wrap=37 unwrap=38 corpse=42 player_corpse=43 show_off_socket=46 upgradeclassification=48 wearout=53
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.cpp:176-390 — applyAppearanceFlags: has_bank()/has_bottom()/has_top() are PRESENCE-only; m_groundSpeed=bank().waypoints(); m_minimapColor=automap().color(); m_lensHelp=lenshelp().id(); m_elevation=height().elevation(); m_clothSlot=clothes().slot()
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:1298 + thingtype.cpp:1096 — ThingFlagAttrFloorChange comes only from the legacy .dat attribute path, so hasFloorChange() is always false at 1530
- D:/Claude/otclient_mehah1530/otclient/src/client/map.cpp:1316-1473 — findEveryPath: full Dijkstra, cost = groundSpeed * (diagonal ? 3 : 1), minimap fallback at :1415-1424, stairs rule 'isNotPathable && 210<=color<=213' at :1429, result tuple {totalCost, distance, dirFromPrev, prevKeyString} at :1380
- D:/Claude/otclient_mehah1530/otclient/src/client/map.cpp:1168-1179 — getMinimapColor: tile colour first, then the persistent minimap
- D:/Claude/otclient_mehah1530/otclient/src/client/map.cpp:1181-1225 — isSightClear line walk using Tile::isLookPossible
- D:/Claude/otclient_mehah1530/otclient/src/client/map.cpp:651-700 + map.h:166-178 — getSpectators uses the aware-range rectangle; multiFloor spans firstAwareFloor..lastAwareFloor
- D:/Claude/otclient_mehah1530/otclient/src/client/tile.cpp:537,563-569,571-585,600-617,654-675,708-725,838-844 — getGround / getGroundSpeed(default 100) / getMinimapColorByte(default 255) / getTopUseThing / getTopMoveThing / isWalkable / hasBlockingCreature
- D:/Claude/otclient_mehah1530/otclient/src/client/tile.h:77 — isPathable() = (m_thingTypeFlag & NOT_PATHABLE) == 0
- D:/Claude/otclient_mehah1530/otclient/src/client/creature.cpp:1106-1151 — getStepDuration: 1000*groundSpeed/speed, ground-speed default 150, serverBeat rounding at cv>=860, diagonal *= playerDiagonalWalkSpeed; :956-971 speed formula; :1104 hasSpeedFormula
- D:/Claude/otclient_mehah1530/otclient/data/setup.otml:22-30 — player diagonal-walk-speed 3, tile max-things 10; src/client/game.h:533 — m_serverBeat default 50
- D:/Claude/otclient_mehah1530/otclient/src/client/container.h:37 — getSlotPosition(slot) = {0xffff, m_id | 0x40, slot}
- D:/Claude/otclient_mehah1530/otclient/src/client/container.cpp:45-134 — onAddItem/onRemoveItem/updateItemsPositions: slot -= firstIndex, hasPages next-page branch, evict firstIndex+capacity-1 when full
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:802-812,839-864,883-907,909-933,935-944,1518-1543,1786-1791,2119-2125 — move/use/useInventoryItem/useInventoryItemWith/findPlayerItem/findItemInContainers/open/equipItem(Id)/findEmptyContainerId/stashStowItem
- D:/Claude/otclient_mehah1530/otclient/src/client/thing.cpp:94-104 — getStackPos returns m_position.z for items inside a container (x == 0xFFFF)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1827-1886 — parseOpenNpcTrade item record {u16 id, u8 count, STR name, u32 weight, u32 buy, u32 sell} with UINT32_MAX -> 0; parsePlayerGoods {u16 id, u16 amount}
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:843-880,952-958,1247-1256,1735-1773,1804-1829 — sendInviteToParty/JoinParty/RefreshContainer/BrowseField/ApplyImbuement/ClearImbuement/CloseImbuingWindow/ImbuementWindowAction/StashWithdraw/StashStow byte layouts
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:278-298 — PlayerStates masks Poison1..Hungry65536; :891-894 SUPPLY_STASH_ACTION_{STOW_ITEM=0,STOW_CONTAINER=1,STOW_STACK=2,WITHDRAW=3}
- D:/Claude/otclient_mehah1530/otclient/modules/game_cooldown/cooldown.lua:63-67,521-537 — cooldown[iconId] = g_clock.millis() + duration; isCooldownIconActive/isGroupCooldownIconActive compare against now
- D:/Claude/otclient_mehah1530/otclient/modules/gamelib/spells.lua:34+,460-469 — SpellInfo.Default entries {id, words, level, mana, group={[gid]=ms}, exhaustion, vocations}; getSpellByIcon matches spell.id == the 0xA4 spellId
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/vlib.lua:248-270,279-307,309-323,361-379 — cast/SpellCastTable talk-confirm, canCast, icon-id learning from onSpellCooldown, getSpellCoolDown
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/AttackBot.lua:29-35 — USE_COOLDOWN_MS = 1000, a purely client-side shared 'use anything' reservation between AttackBot and HealBot
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/cavebot/walking.lua:116-150,210-300,420 — isFloorChangeTile (lensHelp 1104/1105, isGround+isNotPathable, minimap 210-213 + not pathable), pingMs, stepMs, sendWindow=min(3,1+ceil(ping/step)), watchdog ping+2*step+400, isPreWalking
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/targetbot/looting.lua:174,186-232,284-300,302-307 — getTopUseThing for the corpse, getLootContainers, move to getSlotPosition(slot-1) / getSlotPosition(getItemsCount()), onContainerOpen(container, previousContainer)
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/cavebot/buy_supplies.lua:63-88 — NPC.isTrading() + NPC.getBuyItems() + NPC.buy(id, n)
- D:/Claude/otclient_mehah1530/otclient/mods/game_bot/functions/npc.lua:24-62 — expected NPC item record {item, id, count, name, subType, weight = wire/100, price}
- D:/Claude/otclient_mehah1530/otclient/mods/game_bot/functions/map.lua:8-36,80-114,143-220,223-238,249-271 — getSpectators, findAllPaths params, findPath margin/precision, autoWalk, canShoot, isTrapped
- D:/Claude/otclient_mehah1530/otclient/mods/game_bot/functions/callbacks.lua:63-280 — the full callback list the bot registers (onTalk/onTextMessage/onAddThing/onCreature*/onContainer*/onSpellCooldown/onGroupSpellCooldown/onInventoryChange/onInventoryItemsUpdate/onAttackingCreatureChange/onUse/onUseWith/onMissle/onAnimatedText/onStaticText/onStatesChange)
- D:/Claude/otclient_mehah1530/otclient/mods/game_bot/functions/player_conditions.lua:7 — hasCondition = Bit.band(player:getStates(), mask) > 0
- D:/Claude/otclient_mehah1530/otclient/mods/game_bot/executor.lua:196-215 — the bot tick: macros fire when lastExecution + timeout <= now, then the scheduler queue drains; bot.lua:342 refreshes every 20 ms
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/storage/profile_1.json — 44975-byte JSON storage table (combobot/newHealer/autoEquip/moneyItems/extras/alarms/stances/AutoTrainingWeapon)
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/targetbot_configs/def.json — {looting:{everyItem,maxDanger,minCapacity,containers[],items[]}, targeting:[{name,regex,priority,danger,...}]}
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/cavebot_configs/test.cfg — goto:x,y,z,prec lines plus config:{...} / extensions:[] / staypositions:{} JSON lines
- measured over appearances-17a72b30b5c3c9ca8c1283cfb2febd2a93a145ff8ab66916f7a412d0f1dee5a1.dat: unmove 31818, unpass 16697, automap 15777, bottom 11212, usable 10883, take 7221, clip 6312, unsight 5925, market 5099, corpse 3744, container 3381, bank 3354, fullbank 2958, multiuse 2675, cumulative 2593, height 2194, wrap 2148, avoid 2055, clothes 1984, lying_object 1890, ignore_look 1687, top 1267, rotate 1156, forceuse 1057, lenshelp 981, hang 540, write_once 84, liquidcontainer 48, player_corpse 17, write 12, liquidpool 12, unwrap 2; names present on 8951 objects = 149730 bytes; max groundSpeed 1200, max automap colour 215, max elevation 24, max lensHelp 1112

## Pitfalls
- items1530.bin v1 must keep working: FLAGS1 bit values and semantics are load-bearing for proto/parser.lua's readItem (parser.lua:620-702). Add sections, never renumber bits, and have items.load() accept version 1 (FLAGS1 at fixed offset 32) as well as version 2.
- `bank`, `bottom` and `top` are tested with has_x() ONLY in thingtype.cpp:179/188/192 — not has_x() && x(). Every other boolean uses proto2 presence AND truth. Getting this backwards mislabels ~12k items' stack priority and breaks auto-stackpos insertion.
- Ground speed has TWO different fallbacks and they are not interchangeable: Tile::getGroundSpeed() returns 100 when there is no ground (tile.cpp:568) but Creature::getStepDuration() substitutes 150 when the tile reports 0 (creature.cpp:1120). The pathfinder uses the former, step timing the latter, and an unknown tile in findEveryPath uses 1000 (map.cpp:1405).
- There is no floor-change flag at 1530. Anyone porting `Tile::hasFloorChange()` will get a permanent false. Floor changes must be inferred from lensHelp (1100 ladder, 1102 rope spot, 1104/1105 stairs/hole) + isGround + isNotPathable + minimap colour 210-213, and the CaveBot rule is that yellow ALONE is not enough — it must also be not-pathable (map.cpp:1425-1429 and the comment there).
- The stairs rule excludes the destination tile: `hasStairs && !ignoreStairs && neighbor != destPos`. Dropping the destination exemption makes every staircase waypoint unreachable.
- Container slot arithmetic is the highest-consequence bug surface: looting moves items to {0xFFFF, containerId|0x40, slot}. The wire slot is absolute and must have firstIndex subtracted; a full container evicts the item at firstIndex+capacity-1 BEFORE the insert; and with hasPages a slot > capacity is a size-only update with no item stored. The current S[0x70] gets all three wrong.
- Thing::getStackPos() returns m_position.z for anything whose position.x == 0xFFFF (thing.cpp:94-104). A move/use of a container item must send stackpos = slot, not a tile stack index.
- g_game.open/g_game.use put findEmptyContainerId() in the `index` byte of 0x82 (game.cpp:850, 940). Sending 0 there re-uses container id 0 and silently closes whatever was open in it.
- The 0xA4 spellId is SpellInfo.id, NOT SpellInfo.clientId (cooldown.lua:252 -> Spells.getSpellByIcon -> spell.id == iconId). Indexing the spell table by clientId makes every cooldown check miss.
- Spell group cooldowns are a SEPARATE clock from spell cooldowns and a spell can be gated by several groups (SpellInfo group is a map {[gid]=ms}). vlib.lua:368-379 tolerates a nil group table — a straight port must too or it throws on every tick for learned custom cooldowns.
- 0xB4 TextMessage modes 23-29 carry a position and are what animated/static damage text arrives as at 1530; API.md promises `animatedText`/`staticText` events that parser.lua never emits. Bots that count damage or read 'you are not the owner' rely on TextMessage (targetbot/looting.lua:270-276).
- state.player and state.creatures[player.id] are two different objects in parser.lua (P:player() vs applyCreature). skull/shield/direction/speed/outfit land only on the creature record; hp/mana/level/cap only on the player record. Bot code reads both off `player`.
- state:setCentralPosition deletes tiles as the player walks. Any minimap/pathfinding memory must be written BEFORE eviction (hook parser.lua:415 P:setCentral), or the client permanently forgets the route it just walked.
- Creature::isPassable defaults to FALSE — an unknown creature blocks. state.lua:552-558 already gets this right; keep it when rewriting isWalkable, and remember hasBlockingCreature additionally excludes the local player (tile.cpp:841) while isWalkable does not.
- 0xF5 PlayerInventory is the ONLY source of counts for items inside closed containers. It arrives on every add/remove of any carried item, so the derived itemAmount() cache must be invalidated per packet, not cached per session.
- findEveryPath's `nodes` map stores an explicit nil/false for rejected neighbours so they are never re-evaluated. A Lua port using `nodes[k] == nil` as 'unvisited' will re-test (and re-reject) blocked tiles forever inside the 8-neighbour loop — store `false`.
- The vBot executor swallows every macro error in pcall and keeps going (executor.lua:200-208). A headless host that lets one handler kill the tick loop will behave very differently under the same scripts; lib/events.lua already pcalls handlers, keep that property in the macro runner too.
- CaveBot's `smoothWalk` path only advances its ledger when g_game.walk() did NOT return false (walking.lua:293). sender:walk must therefore keep returning nil,err on a refused frame — do not 'helpfully' make it return true.

## Open questions
- Does the target client want a persistent minimap on disk (OTMM, as otclient writes) or an in-memory-only store? findEveryPath's unseen-tile fallback needs at least the current session's history; cross-session pathing to a bank/depot needs the file. The OTMM reader/writer is a separate work item either way.
- Section 10/11 (NAMEIDX/NAMEBLOB) roughly doubles the asset from 683 KB to 875 KB for 8951 names. Confirm names are actually wanted: loot/deposit/supply configs are all id-keyed on disk, and only vBot/analyzer.lua (a statistics UI) and depositer_config.lua (a widget label) read getMarketData().name. If the headless host does not log item names, sections 10-11 can be dropped.
- AppearanceFlags.market (field 36) also carries category / trade_as_object_id / show_as_object_id / restrict_to_profession / minimum_level. Only `name` is used by the bot today. Extract the rest, or leave it?
- `state.player.capacity` is written from 0xA1 CHARACTER_SKILL_STATS (total capacity) while `freeCapacity` comes from 0xA0; API.md names them capacity/maxCapacity. Which name should be canonical before bot code is written against it? TargetBot looting reads player:getFreeCapacity() against the config key minCapacity (default 100).
- Is GameNewSpeedLaw actually ON for this server? parser.lua gates speedA/B/C behind F_NEW_SPEED_LAW at S[0x17], and Creature::hasSpeedFormula additionally requires all three non-zero. If the server sends zeros the step-duration formula degenerates to 1000*groundSpeed/speed, which is fine — but it should be confirmed against a real capture before the walker is tuned.
- Should the walk model be prewalk (optimistic, client applies the step immediately and reconciles) or strictly server-confirmed? state.player already declares prewalk fields, and CaveBot's smooth mode assumes prewalk exists (isPreWalking at walking.lua:420), but a headless client has no rendering reason to prewalk and server-confirmed is far simpler to keep consistent.
- How faithful must the bot port be to the vBot UI-derived configuration? Several settings are read straight off widgets each tick (e.g. ui.everyItem:isOn(), ui.maxDangerPanel.value:getText()) rather than from the storage table, so a headless host has to decide whether it re-reads the JSON on change or snapshots it at load.
- Does the target client need player-trade (0x7D/0x7E) and market (0xF6-0xF9) state, or only NPC trade? The four bot modules in scope only need NPC trade; some vBot extras (analyzer price lookups) touch market data.

## VERIFIER (confidence 0.88)

### Corrections (AUTHORITATIVE)
- **Claim**: game/minimap.lua flags: "WasSeen 1, NotWalkable 2, NotPathable 4, Empty 8 (matching MinimapTileWasSeen etc.)"
  - **Correction**: NotWalkable and NotPathable are SWAPPED. Real bits: MinimapTileWasSeen=1, MinimapTileNotPathable=2, MinimapTileNotWalkable=4, MinimapTileEmpty=8. Implementing the spec's order inverts every walkable/pathable decision for tiles outside the aware range, which is precisely where the minimap fallback is the ONLY source — so hasStairs (needs isNotPathable) and the isNotWalkable reject clause both fire on the wrong tiles.
  - Evidence: src/client/minimap.h:35-38 — enum MinimapTileFlags { MinimapTileWasSeen = 1, MinimapTileNotPathable = 2, MinimapTileNotWalkable = 4, MinimapTileEmpty = 8 };
- **Claim**: NOTE 3 / state:getGroundSpeed pseudocode: "bank present but waypoints absent -> groundSpeed 0. Tile::getGroundSpeed() then returns 100 (tile.cpp:563-569)", implemented as `local s = items.groundSpeed(t._ground.id); return s ~= 0 and s or 100`
  - **Correction**: Wrong. Tile::getGroundSpeed() returns 100 ONLY when there is no ground at all; a ground item whose bank has no waypoints returns 0 verbatim. The spec's `s ~= 0 and s or 100` substitutes 100 for the speed-0 ground, which the C++ never does. Consequence: wrong Dijkstra edge cost (100 instead of 0) and, via Creature::getStepDuration, the 150 substitution never triggers because the caller already got 100.
  - Evidence: src/client/tile.cpp:562-569 — `int Tile::getGroundSpeed() { if (const auto& ground = getGround()) return ground->getGroundSpeed(); return 100; }`. There is no zero-check on the ground's own speed.
- **Claim**: getStepDuration formula: `stepDuration = 1000 * groundSpeed / (hasSpeedFormula() ? calculatedStepSpeed : speed); if cv>=860 ceil to serverBeat; diagonal *= 3`
  - **Correction**: Three load-bearing pieces are missing. (1) The local player gets `duration += 10 * max(1, getPreWalkingSize())` when camera-following. (2) The function returns `duration > 10 ? duration - 10 : duration` — a deliberate 10 ms subtraction (this build carries a patch comment explaining it prevents cavebot waypoint overshoot). (3) calculatedStepSpeed has a guard the spec drops: `speed *= 2; if (speed > -speedB) calculated = max(1, floor(speedA*log(speed/2. + speedB) + speedC + .5)); else calculated = 1;`. Also, the diagonal multiplier is selected by `m_stepCache.getDuration(m_lastStepDirection)` — the `dir` ARGUMENT only chooses which tile supplies groundSpeed, it does not choose the diagonal factor. CaveBot calls `CaveBot.delay(walkDelay + stepDuration)` directly off this value at walking.lua:328 and :499, so every one of these changes step pacing.
  - Evidence: src/client/creature.cpp:1106-1160 (getStepDuration, incl. the `duration > 10 ? duration - 10 : duration` return and the isCameraFollowing padding) and creature.cpp:965-971 (setSpeed's `if (speed > -speedB)` guard).
- **Claim**: pathfinder pseudocode: `if st:isAwareOf(nb) and st:tile(nb) then <live tile> elseif not p.allowOnlyVisibleTiles then <minimap fallback> end`
  - **Correction**: The C++ nesting is different and this changes results. Real structure: `if (isAwareOfPosition(neighbor)) { if (tile) {...} }  else if (!allowOnlyVisibleTiles) { minimap }`. A position that IS inside the aware range but has no tile object never consults the minimap — it keeps the defaults wasSeen=false, isNotWalkable=true, isNotPathable=true, mapColor=0, speed=1000. The spec's `and` collapses the two branches so aware-but-unloaded tiles get remembered minimap data, which the real pathfinder refuses. This is exactly the band at the viewport edge that CaveBot paths through most often.
  - Evidence: src/client/map.cpp:1404-1424 — the `if (g_map.isAwareOfPosition(neighbor)) { if (const TilePtr& tile = getTile(neighbor)) {...} } else if (!allowOnlyVisibleTiles) { const MinimapTile& mtile = g_minimap.getTile(neighbor); ... }` block.
- **Claim**: "MinimapTile::getSpeed() stores groundSpeed/10 in the C++; store the raw value and be done."
  - **Correction**: Storing the raw value is fine, but the spec never states the DEFAULTS, and an unknown minimap tile is the common case in the fallback branch. MinimapTile is default-constructed as `{flags = 0, color = 255, speed = 10}` and `getSpeed()` returns `speed * 10`. So an unrecorded tile yields wasSeen=false, color=255, speed=100 — not color 0 and not speed 1000. With allowUnseen set, every unknown tile therefore costs 100, not 1000, and its colour 255 (never in 210..213) can never be read as stairs.
  - Evidence: src/client/minimap.h:42-51 — `uint8_t flags{0}; uint8_t color{255}; uint8_t speed{10}; int getSpeed() const { return speed * 10; }`
- **Claim**: `items.isStackable(id) return band(items.flags(id), 0x01) ~= 0` presented as the isStackable predicate
  - **Correction**: FLAGS1 bit 0 is a PROTOCOL-READ bit, not ThingType::isStackable. Per the format comment it is `cumulative(6) | liquidcontainer(19) | liquidpool(12)`, whereas C++ ThingFlagAttrStackable comes from `cumulative` alone. targetbot/looting.lua:285 branches on `item:isStackable()` to decide whether to merge loot into an existing stack capped at count<100; with the spec's alias, 48 fluid containers and 12 splashes become stackable and get merged. Either add a separate CUMULATIVE-only bit or exclude fields 19 and 12 from the isStackable predicate.
  - Evidence: proto/items.lua:35 and tools/extract_appearances.py BOOL_FIELD_TO_BIT (6, 19, 12 all -> F_CUMULATIVE); src/client/thingtype.cpp:200-202 sets ThingFlagAttrStackable only from `has_cumulative() && cumulative()`; profiles/bot/vBot_4.8/targetbot/looting.lua:285 `if item:isStackable() then`.
- **Claim**: `state:findPlayerItem(itemId, subType, tier)` -- "game.cpp:909-933: inventory slots Head(1)..LastInventorySlot", pseudocode `for slot = 1, 10`
  - **Correction**: Two errors. (1) The loop is `for (slot = InventorySlotHead; slot < LastInventorySlot; ++slot)` with InventorySlotHead=1 and LastInventorySlot=16 — that is slots 1..15, including Purse(11) and Ext1..Ext4(12..15), not 1..10. (2) Game::findPlayerItem takes only (itemId, subType); there is no tier parameter, and the container search hardcodes tier 0 via findItemInContainers(itemId, subType, 0). Container::findItemById then requires `item->getTier() == tier`, i.e. tier must equal 0.
  - Evidence: src/client/const.h:99-117 (InventorySlotHead=1 ... InventorySlotPurse=11, InventorySlotExt1..4, LastInventorySlot=16); src/client/game.cpp:908-921 (`ItemPtr Game::findPlayerItem(const uint32_t itemId, const int subType)` -> findItemInContainers(itemId, subType, 0)); src/client/container.cpp:68-74.
- **Claim**: canCast pseudocode: `local d = spells.byWords(words) or customCooldowns[words]; ... state.player.level >= d.level and state.player.mana >= d.mana`
  - **Correction**: getSpellData does not return the raw customCooldowns entry; for a custom hit it synthesises `{id = v.id, mana = 1, level = 1, group = v.group}`. Reading `d.level`/`d.mana` off the raw customCooldowns table (which only ever has `id` and optionally `group`) yields nil and either errors or silently mis-gates every learned spell. Also getSpellData resolves SpellInfo by a linear scan for `v.words == spell`, not by an index, and the custom lookup is a second linear scan over vBot.customCooldowns.
  - Evidence: profiles/bot/vBot_4.8/vBot/vlib.lua getSpellData: `c = {id = v.id, mana = 1, level = 1, group = v.group}` in the customCooldowns branch; canCast then uses getSpellData(spell).level / .mana.
- **Claim**: "The client-side model to copy: on 0xA4 (spellId, delay): cooldown[spellId] = nowMs + delay; on 0xA5: groupCooldown[groupId] = nowMs + delay"
  - **Correction**: Neither table is written unconditionally. onSpellCooldown early-returns on `if not cooldownWindow:isVisible() then return end` and again if loadIcon(iconId) fails; only then does it reach startSpellCooldownProgress -> trackSpellCooldown, which is the sole writer of cooldown[iconId]. onSpellGroupCooldown early-returns on `not cooldownWindow:isVisible()` and on `not SpellGroups[groupId]`, and writes groupCooldown[groupId] only inside `if progressRect then`. So in the real client canCast can return true for a spell that IS on server cooldown whenever the cooldown widget is hidden. The unconditional model is a reasonable headless simplification but must be labelled as a deliberate divergence, not as "the model to copy".
  - Evidence: modules/game_cooldown/cooldown.lua:538-563 (onSpellCooldown) and :565-593 (onSpellGroupCooldown); the only writer of `cooldown[]` is trackSpellCooldown at :57-68.
- **Claim**: "Client-side 'use anything' exhaust -- a fixed 1000 ms USE_COOLDOWN_MS ... plus 0xA6 multiUseCooldown from the server"; `cd.useReady() return now() >= cd.useReadyAt and now() >= cd.multiUseUntil`
  - **Correction**: The real bot deliberately does NOT use the 0xA6 server signal. AttackBot.lua states in a header comment that g_game.onMultiUseCooldown does not fire on this build and is never hooked anywhere, on purpose; the 1 s window is armed purely client-side by recordLocalUseCooldown() at send time. Including multiUseUntil in useReady() adds a gate the real bot has never had. Two further pieces are missing: getPingCompensation() (returns ping-30 when ping>150, else 0) is SUBTRACTED in getMultiUseCooldown() = max(0, expiresAt - now - pingCompensation); and checkInventoryConsumption(itemId) arms the cooldown whenever player:getInventoryCount(itemId, 0) drops below the previous sample.
  - Evidence: profiles/bot/vBot_4.8/vBot/AttackBot.lua:15-24 ("g_game.onMultiUseCooldown does NOT fire on this OTClient build, so we never hook or rely on it anywhere, on purpose"), :29-36 (USE_COOLDOWN_MS/recordLocalUseCooldown), :38-49 (checkInventoryConsumption), :51-66 (getPingCompensation/getMultiUseCooldown).
- **Claim**: "lenshelp.id (1100/1102/1104/1105 = ladder/rope-spot/stairs/hole)" and CONFIG NOTE 2 "Floor changes are inferred from LENSHELP + GROUND + NOT_PATHABLE + MINIMAPCOLOR 210..213, exactly as cavebot/walking.lua:116-150 does"
  - **Correction**: Only 1104 and 1105 are floor-change lenshelp ids. cavebot/walking.lua defines `FLOOR_CHANGE_LENSHELP = { [1104] = true, [1105] = true }` and the comment directly above explains that 1100/1102 (ladders, rope spots) are excluded on purpose because you have to use() them and standing on them is harmless. Treating 1100/1102 as floor changes will make avoidFloorChange refuse every path across a ladder or rope spot. The real isFloorChangeTile also has three tests the spec omits: minimap colour 210..213 must be combined with `not tile:isPathable()`; `ground:isGround() and thingType:isNotPathable()`; the same test applied to `tile:getTopUseThing()`; plus the cfg `avoidTileIds` list checked against both ground and top item.
  - Evidence: profiles/bot/vBot_4.8/cavebot/walking.lua:102 `local FLOOR_CHANGE_LENSHELP = { [1104] = true, [1105] = true }` with the preceding comment; itemChangesFloor() and isFloorChangeTile() at :117-160.
- **Claim**: "Looting/analyzer name display, supply lists (vBot/analyzer.lua:401,1191, vBot/depositer_config.lua:42) needs Appearance.name (field 4)" and "market.name = m_name"
  - **Correction**: The bot reads `Item.create(id):getMarketData().name`, and m_market.name is assigned m_name only INSIDE `if (flags.has_market())`. Measured over the real asset: 8,951 objects carry Appearance.name but only 5,099 carry a market block, and every market-carrying object also has a name. So a plain Appearance.name table hands back names for 3,852 items where the real client returns the empty string. Gold coin (3031) is one of them — it has no field 36 — which is exactly why analyzer.lua hardcodes `id == 3031 and "gold coin" or id == 3035 ... or Item.create(id):getMarketData().name`. Either gate NAMEIDX on market presence or document the divergence.
  - Evidence: src/client/thingtype.cpp:340-357 (`if (flags.has_market()) { ... m_market.name = m_name; ... }`); profiles/bot/vBot_4.8/vBot/analyzer.lua:401 and :1191, vBot/depositer_config.lua:42 all use getMarketData().name; measured counts via tools/extract_appearances.py's own iter_fields over appearances-17a72b30...dat: objects 43536, names 8951, market 5099, name&market 5099; `--dump 3031` shows raw fields `6=1, 18=1, 44{1=3031}` with no field 36.
- **Claim**: Section table: `11 NAMEBLOB 1 158681 concatenated NUL-terminated UTF-8`; `total file = 40 + 132 + 683595 + 53706 + 158681 = 896154 bytes`
  - **Correction**: The blob size is wrong and contradicts the spec's own prose ("149 730 bytes of UTF-8"). Measured: the 8,951 name strings total 140,779 raw UTF-8 bytes, so with one NUL each the blob is exactly 149,730 bytes. Correct total = 40 + 132 + 683595 + 53706 + 149730 = 887,203 bytes (~866 KB), not 896,154. The other section lengths check out: FLAGS1..4 = 4x62145 = 248580, GROUNDSPEED+LENSHELP = 2x124290, MINIMAPCOLOR+ELEVATION+CLOTHSLOT = 3x62145, summing to 683,595; NAMEIDX = 6x8951 = 53,706.
  - Evidence: Summed field-4 payload lengths over appearances-17a72b30...dat: 140,779 bytes across 8,951 names; +8,951 NULs = 149,730.
- **Claim**: `state:getSpectatorsInRangeEx` pseudocode: `if multi then z0, z1 = state.firstAwareFloor(c.z), state.lastAwareFloor(c.z) end`
  - **Correction**: The C++ derives the floor range from the MAP's central position, not from the query centre. Map::getSpectatorsInRangeEx computes `minZRange = centerPos.z - getFirstAwareFloor(); maxZRange = getLastAwareFloor() - centerPos.z;` where getFirstAwareFloor()/getLastAwareFloor() read m_centralPosition.z. Passing c.z diverges whenever the spectator centre is on a different floor from the player (which is the whole point of multiFloor). Additionally minZRange/maxZRange are uint8_t, so when centerPos.z < getFirstAwareFloor() the subtraction wraps and the scan explodes — reproduce or explicitly clamp.
  - Evidence: src/client/map.cpp:660-668 and map.cpp:815-829 (`uint8_t Map::getFirstAwareFloor() const { if (m_centralPosition.z <= g_gameConfig.getMapSeaFloor()) return 0; return m_centralPosition.z - g_gameConfig.getMapAwareUndergroundFloorRange(); }`).
- **Claim**: `state:isWalkable(pos, ignoreCreatures)` -- tile.cpp:708-725: `not (flags & NOT_WALKABLE) and hasGround` and, unless ignoreCreatures, no non-passable creature
  - **Correction**: The creature clause is `if (!creature->isPassable() && creature->canBeSeen()) return false;` — a creature that cannot be seen does NOT block isWalkable. The spec's pseudocode drops canBeSeen(). Note the deliberate asymmetry the spec should call out: Tile::isWalkable checks canBeSeen but does NOT exclude the local player (so your own tile is not walkable), whereas Tile::hasBlockingCreature excludes the local player but does NOT check canBeSeen. The pathfinder uses isWalkable(true) and hasBlockingCreature() separately, so both behaviours matter.
  - Evidence: src/client/tile.cpp:708-725 (isWalkable) vs tile.cpp:838-844 (`thing->isCreature() && !...->isPassable() && !thing->isLocalPlayer()`).
- **Claim**: `state:getMinimapColorByte(pos)` -- tile.cpp:571-585: reverse-iterate things, skip creatures and isCommon items, first non-zero minimapColor, else 255
  - **Correction**: Missing the first clause: `if (m_minimapColor != 0) return m_minimapColor;` — a per-tile override settable via Tile::overwriteMinimapColor. Separately, the spec conflates two functions: cavebot/walking.lua calls `g_map.getMinimapColor(p)`, which is Map::getMinimapColor — it takes Tile::getMinimapColorByte() and, if that is 0, falls back to `g_minimap.getTile(pos).color`. The spec's pseudocode returns 0 for a missing tile, which is neither function's contract.
  - Evidence: src/client/tile.cpp:571-586 (m_minimapColor early return) and tile.h:133 (overwriteMinimapColor); src/client/map.cpp:1168-1179 (Map::getMinimapColor); profiles/bot/vBot_4.8/cavebot/walking.lua:145 `local color = g_map.getMinimapColor(p)`.
- **Claim**: "onContainerOpen(container, previousContainer) gets a previous argument the parser never supplies (the 'did the container I asked for actually open' test at targetbot/looting.lua:302-307 needs it)"
  - **Correction**: False. looting.lua declares the parameter but never reads it; the test is `container:getContainerItem():getId() == waitingForContainer`, comparing an ITEM id against the value stored at looting.lua:181 from the tile item's getId(). No file in profiles/bot/vBot_4.8 reads previousContainer in a body — the only consumers anywhere are mods/game_bot/panels/attacking.lua:1021 and panels/looting.lua:313, which copy `autoLooting`, and those are the built-in panels, not vBot. Supplying previousContainer is still nice for parity, but it is not required by the cited test and should not be listed as load-bearing.
  - Evidence: grep of `previousContainer|prevContainer` across profiles/bot/vBot_4.8 + mods/game_bot: every vBot occurrence is in a `function(container, previousContainer)` signature only; targetbot/looting.lua:303-307 body uses only `container`.
- **Claim**: NPC trade record shape `{id, count, name, subType, weight (=wire/100), price}` and "0x7A ... u16 listCount, then per entry: u16 itemId, u8 countOrSubType, ..."
  - **Correction**: Three issues. (1) listCount is `cv >= 900 ? getU16() : getU8()`, not an unconditional u16 (harmless at 1530 but the spec presents it as unconditional). (2) `count` and `subType` are the SAME wire byte routed through Item::setCountOrSubType: getCount() returns it only for stackables (else 1) and getSubType() returns it only for splash/fluid-container (else 0 at cv>862). Storing the raw byte into both fields diverges from what NPC.getBuyItems/getSellItems hand the bot. (3) The bot's record has a single `price` field plus `item = item.ptr`; the spec's npcBuyItems/npcSellItems never say to project buyPrice into `price` for buys and sellPrice into `price` for sells, which is what game_npctrade does.
  - Evidence: src/client/protocolgameparse.cpp:1826-1860 (parseOpenNpcTrade, `g_game.getClientVersion() >= 900 ? msg->getU16() : msg->getU8()`, `item->setCountOrSubType(itemCount)`); src/client/item.cpp:102-108 (Item::getSubType); mods/game_bot/functions/npc.lua:21-52.
- **Claim**: "Equipper (vBot/Equipper.lua), g_game.equipItemId (game.cpp:1530) | upgradeclassification (have) + clothes.slot"
  - **Correction**: clothes.slot is not needed for this. Game::equipItemId branches only on `thing->getClassification() > 0` (GameThingUpgradeClassification) to pick sendEquipItemWithTier vs sendEquipItemWithCountOrSubType; it never touches m_clothSlot. And getClothSlot has ZERO call sites across profiles/bot/vBot_4.8 and mods/game_bot. Keep the CLOTHSLOT column if you want parity, but drop the Equipper justification. Same overstatement applies to getGroundSpeed and getElevation (0 Lua call sites each — they are needed only internally by the pathfinder / step duration, not by any bot script).
  - Evidence: src/client/game.cpp:1530-1543 (equipItemId); grep across profiles/bot/vBot_4.8 + mods/game_bot: getClothSlot 0, getGroundSpeed 0, getElevation 0, isCommon 0, isForceUse 0, isSplash 0, isOnBottom 0, isOnTop 0, isGroundBorder 0, isNotWalkable 0, isBlockProjectile 0. Actually used: getMinimapColor 17, isStackable 12, isNotMoveable 12, isUsable 4, isPickupable 4, isFluidContainer 4, getLensHelp 2, isMultiUse 2, isNotPathable 2, isGround 2.
- **Claim**: "pathfinder.findPath(...) doing the margin/precision search of map.lua:143-220" / `hasMargin = (p.marginMin or p.marginMax) ~= nil`
  - **Correction**: Three details will break a verbatim port. (1) findPath returns nil immediately unless `startPos.z == destPos.z`, and defaults maxDist to 100 when it is not a number. (2) The Lua side accepts ALIASES: `marginMin = params.marginMin or params.minMargin`, `marginMax = params.marginMax or params.maxMargin`, but the C++ hasMargin test looks only for the literal keys "marginMin"/"marginMax" — so passing minMargin/maxMargin gives a candidate scan WITHOUT the `distance+4` search extension. (3) C++ hasMargin is pure key presence (`params.find(...) != end`), unlike the ignore* flags which additionally require the value not be "0" or "". The Lua `(p.marginMin or p.marginMax) ~= nil` also mis-handles a literal false.
  - Evidence: mods/game_bot/functions/map.lua:141-215 (findPath: the z guard, maxDist default 100, the marginMin/minMargin aliasing); src/client/map.cpp:1343-1347 (hasMargin presence-only test).
- **Claim**: findEveryPath params / maxDistanceFrom, with `distance(p.maxDistanceFromPos, nb) > p.maxDistanceFrom` and no statement of the metric or of how params reach C++
  - **Correction**: Two unstated things that change results. (1) Position::distance is EUCLIDEAN and ignores z: `sqrt(pow(pos.x - x, 2) + pow(pos.y - y, 2))`. A Chebyshev implementation admits a different neighbour set. (2) findAllPaths marshals params before the call: every false/nil value is rewritten to 0 and every true to 1, and a table maxDistanceFrom is stringified to "x,y,z,range"; the C++ then treats "0" and "" as off. A reimplementation taking Lua booleans directly must replicate that truthiness, and must accept maxDistanceFrom in both the {pos, range} and {x,y,z,range} forms.
  - Evidence: src/client/position.h:184 (`double distance(const Position& pos) const { return sqrt(std::pow<int32_t>(pos.x - x, 2) + std::pow<int32_t>(pos.y - y, 2)); }`); src/client/map.cpp:1441 (maxDistanceFromPos.distance(neighbor)); mods/game_bot/functions/map.lua:94-110.
- **Claim**: "lib/sched.lua gives 10 ms timers -- enough to host the vBot executor model (mods/game_bot/executor.lua:196-215: a ~20 ms tick that fires macros whose lastExecution + timeout <= now, then drains a scheduler queue)"
  - **Correction**: Two behaviours the summary omits and a reimplementation will get wrong. The macro must also be `enabled`, and — critically — `macro.lastExecution = context.now` is assigned ONLY when `macro.callback(macro)` returns truthy. A macro whose callback returns nil/false is retried on the very next tick regardless of its timeout. Every callback is wrapped in pcall so a throwing macro does not kill the executor.
  - Evidence: mods/game_bot/executor.lua:199-210 — `if macro.lastExecution + macro.timeout <= context.now and macro.enabled then local status, result = pcall(function() if macro.callback(macro) then macro.lastExecution = context.now end end) ...`
- **Claim**: "with FLAGS2 available, stackPriorityOf can finally return the real Thing::getStackPriority (ground 0, groundBorder 1, onBottom 2, onTop 3, creature 4, common 5), which makes auto-stackpos insertion (stackPos nil/-1/255) correct instead of heuristic"
  - **Correction**: The priority values are right but the insertion RULE is the part that decides placement, and the spec never states it: `append = (priority <= 3)`, then `if (clientVersion >= 854 && priority == 4) append = !append;` (so creatures append at 1530); the scan then breaks on `(append && otherPriority > priority) || (!append && otherPriority >= priority)`. game/state.lua:246-258 already implements this correctly — the gap is only stackPriorityOf's flag input, not the algorithm, so the spec overstates what changes. Also note Thing::getStackPriority's first clause `if (getClientVersion() <= 800 && isSplash()) return GROUND;` is dead at 1530 and the spec's items.stackPriority correctly omits it.
  - Evidence: src/client/tile.cpp:330-353 (the append/scan block) vs D:/Claude/otclient_web/luaclient/game/state.lua:246-258; src/client/thing.cpp:53-77.
- **Claim**: "Rewrite S[0x70]/S[0x71]/S[0x72] in proto/parser.lua to the C++ algorithm above ... and emit containerAddItem/RemoveItem with the normalised slot (slot - firstIndex)"
  - **Correction**: S[0x71] and S[0x72] ALREADY normalise by firstIndex (`local idx = slot - (c.firstIndex or 0) + 1` in both). The genuinely broken handler is S[0x70], which ignores `slot` and `firstIndex` entirely and does `table.insert(c.items, 1, item)`. Scoping the rewrite as "all three are wrong on slots" overstates it. The spec's summary of onRemoveItem also drops the second guard: after the hasPages branch there is `if (slot < 0 || slot >= m_items.size()) { traceError; return; }` — a no-op that does NOT decrement m_size.
  - Evidence: D:/Claude/otclient_web/luaclient/proto/parser.lua S[0x70] (`table.insert(c.items, 1, item)`), S[0x71] and S[0x72] (both compute `slot - (c.firstIndex or 0) + 1`); src/client/container.cpp:106-110.
- **Claim**: "animated/static text at 1530 arrive as 0xB4 TextMessage modes 23-29 with a position"
  - **Correction**: Incomplete: the position-bearing message codes in the existing handler are 23, 24, 25, 26, 27, 28, 29 AND 43. Code 43 is grouped with 25 and 28 (pos, u32 value, u8 color, string). Emitting animatedText/staticText for 23-29 only would silently drop mode 43.
  - Evidence: D:/Claude/otclient_web/luaclient/proto/parser.lua S[0xB4]: `elseif code == 25 or code == 43 or code == 28 then d.pos = rpos(R); d.value = R:u32(); d.color = R:u8(); text = R:string()`.
- **Claim**: "state:getTopCreature(pos) -- tile.cpp:619-630: first non-local-player creature, else local player"
  - **Correction**: Incomplete. Tile::getTopCreature first returns nullptr when `!hasCreatures()`, then prefers the first non-local creature (remembering the local player as a fallback), then falls back to `m_walkingCreatures.back()`, and finally — when checkAround is true (the default) — scans the 8 surrounding tiles for a creature that isWalking(), whose getLastStepFromPosition() == this tile, and whose getStepProgress() < 0.75. A headless port can drop the walking-creature clauses, but that must be a stated simplification.
  - Evidence: src/client/tile.cpp:617-651.
- **Claim**: "canShoot 2 [call sites]" / "P3-1 ... isTrapped and canShoot fall out of P0-3 (isWalkable + isSightClear) for free"
  - **Correction**: The count is wrong (26 occurrences of `:canShoot` across profiles/bot/vBot_4.8 + mods/game_bot, not 2 — this is a widely used AttackBot/TargetBot primitive, not a P3 nicety), and it does not fall out for free. context.canShoot(pos, distance) defaults distance to 5, and Tile::canShoot(distance) first rejects on Chebyshev distance from the LOCAL PLAYER (`max(|tile.x - player.x|, |tile.y - player.y|) > distance`) before calling isSightClear(playerPos, tilePos). The player-relative gate is not derivable from isSightClear alone.
  - Evidence: mods/game_bot/functions/map.lua:249-256; src/client/tile.cpp:1133-1141.
- **Claim**: Line citations in the P0-1 protobuf table ("semantics from src/client/thingtype.cpp:176-390", per-field :179 :184 :188 :192 :207 :211 :215 :219 :224 :226 :230 :234 :239 :244 :250 :254 :258 :288 :305 :323 :327 :361 :365)
  - **Correction**: Several are off by 1-3 lines, which matters because the spec asks the reimplementer to verify against them. Actual: bank 179, clip 184, bottom 188, top 192, container 196, cumulative 200, multiuse 204 (not 207), forceuse 208 (not 211), usable 212 (not 215), write 216 (not 219), write_once 221 (not 224), liquidpool 226, unpass 230, unmove 234, unsight 238 (not 239), avoid 242 (not 244), take 248 (not 250), liquidcontainer 252 (not 254), hang 256 (not 258), rotate 285 (not 288), height 302, lying_object 307 (not 305), automap 315, lenshelp 320, fullbank 325 (not 323), ignore_look 329 (not 327), clothes 333, wrap 362 (not 361), unwrap 366 (not 365). The function itself starts at :186, not :176. All field NUMBERS and all has_x()/has_x()&&x() semantics are correct.
  - Evidence: grep -n 'has_bank\|has_clip\|...' src/client/thingtype.cpp.
- **Claim**: Call-site counts used to justify priority: getTile 97x, getTiles 49x, isWalkable 44x, getTopUseThing 60x, getAttackingCreature 21x, isAttacking 10x, getUnjustifiedPoints 15x, getClientVersion 70x, safeLogout 3x
  - **Correction**: Inflated roughly 1.2-1.7x. Measured over profiles/bot/vBot_4.8 + mods/game_bot: g_map.getTile 87, g_map.getTiles 37, :isWalkable 40, getTopUseThing 56, getAttackingCreature 19, isAttacking 6, getUnjustifiedPoints 9, getClientVersion 58, safeLogout 4. Exact matches: hasFloorChange 4, getInventoryCount 18, getFollowingCreature 2, getTopMoveThing 2, :hasCreatures 22, :getGround 6, :getTopThing 8. These do not change any behaviour, but they are presented as evidence for prioritisation.
  - Evidence: grep -rEo over profiles/bot/vBot_4.8 and mods/game_bot for each identifier.
- **Claim**: Assorted luaclient line references: "game/state.lua:127-129" (walk fields), "game/state.lua:409-436" (setCentralPosition), "game/state.lua:392-397" (aware floors), "game/state.lua:538-560" (walkableAt), "parser.lua:1836-1838" (capacity), "proto/sender.lua (631 lines) has 30 builders", "targetbot/looting.lua:75-81"
  - **Correction**: Drift throughout. Walk fields are state.lua:126-128; setCentralPosition 406-432; firstAwareFloor/lastAwareFloor exported at 372-373; walkableAt 537-560. pl.capacity/pl.maxCapacity are at parser.lua:1818-1819 inside S[0xA1] (which begins at 1787) — the opcode attribution (0xA1 / F_CHARACTER_SKILL_STATS) is correct, the line range is not. sender.lua has 37 `function sender:` builders, not 30. The looting save block is at targetbot/looting.lua:77-84. The def.json quoted as "verbatim" has a different key order from the file on disk (content is identical).
  - Evidence: Direct reads of D:/Claude/otclient_web/luaclient/game/state.lua, proto/parser.lua, proto/sender.lua; profiles/bot/vBot_4.8/targetbot/looting.lua and targetbot_configs/def.json.

### Additions
- Add the ping-model semantics the spec's main.lua recipe silently changes. Game::getPing() returns -1 until the first pong (m_ping{-1}); Game::ping() refuses to send while one is outstanding (`if (m_pingReceived != m_pingSent) return;`), then does ++m_pingSent and m_pingTimer.restart(); the reply path does ++m_pingReceived and, only when the counters match, sets m_ping = m_pingTimer.elapsed_millis() and fires onPingBack. luaclient's keepalive fires at `cfg.pingMs or 10000`, so state.ping would refresh once per 10 s while CaveBot's sendWindow() reads pingMs() on every step. Either shorten the keepalive or say the 10 s staleness is accepted. (src/client/game.cpp:62, 74-75, 256-264, 1678-1683; game.h:358, 537-538, 551; main.lua:302)
- State the ping opcode wiring explicitly so a reimplementer wires the timestamp to the right event: the server's ping REQUEST arrives as 0x1D and luaclient answers with 0x1C (PingBackGunz, because os==gunz && cv>=1200); our own keepalive sends 0x1D and the server's pong arrives as 0x1E, emitted as the `pingBack` event. The enum names in proto/opcodes.lua are inverted relative to the direction, which is exactly the kind of thing a from-scratch implementation gets backwards.
- Give the onUse / onUseWith signatures, since P1-4 asks for them to be emitted from sender.lua but never states the shape. C++ fires `onUse(pos, itemId, stackPos, 0)` from Game::use and Game::useInventoryItem (the 4th arg is a literal 0, not the container id that was sent on the wire), and `onUseWith(pos, itemId, toThing, stackPos)` from Game::useWith / useInventoryItemWith. vlib.lua's isUsing handler destructures exactly `function(pos, itemId, stackPos, subType)`. (game.cpp:852, 864, 880, 906)
- Specify Tile::setThingFlag's item-only gate for the tile flag cache: NOT_WALKABLE, NOT_PATHABLE, BLOCK_PROJECTTILE and FULL_GROUND are set only after `if (!thing->isItem()) return;`, so creatures never contribute them. The spec's _recomputeTileFlags happens to be equivalent, but the rule should be stated, along with the fact that C++ has no HAS_GROUND bit at all — isWalkable calls getGround() (= things[0] && isGround) live. (tile.cpp:929-1010)
- Document that there is no per-tile ground cache in C++ and that FULL_GROUND is set by ANY thing on the tile, not only the ground item — the spec's pseudocode already does this but the accompanying prose ("HAS_GROUND ... FULL_GROUND") reads as if both come from things[0].
- Note that Map::isSightClear treats a MISSING tile as transparent (`if (tile && !tile->isLookPossible()) return false;`) in the horizontal walk, and likewise in the vertical tail (`if (tile && tile->getThingCount() > 0) return false;`). The pseudocode gets this right; the prose does not say it, and 'unknown tile blocks' is the intuitive but wrong choice.
- Add the CaveBot fallbacks that surround the two primitives P0-5 introduces: stepMs(dir) is `player:getStepDuration(false, dir or player:getDirection())` with a 200 ms fallback when the result is not a positive number, and pingMs() rejects non-numbers and values <=0 or >5000 before falling back to the cfg "ping" value (default 100). sendWindow(dir) = min(3, 1 + ceil(pingMs() / stepMs(dir))). (cavebot/walking.lua:209-215, 217-223, 245-247)
- Give the max observed bank.waypoints value alongside the other submessage maxima: 1200 (u16 is fine, but the spec lists maxima for elevation 24, minimapColor 215 and lensHelp 1112 and omits this one). Max clothes.slot is 12.
- Record that NOTE 1's presence-vs-truth distinction, while correct as C++ documentation, has no observable effect on this asset set: zero varint boolean fields are encoded with value 0 across all 43,536 objects, so presence and truth counts are identical for every field including bottom(3) and top(4). Worth saying so, otherwise an implementer may spend effort on a distinction that cannot be tested here.
- Add the FLAGS4 fields the spec extracts but never justifies against a real consumer: corpse(42) 3,744 objects, player_corpse(43) 17, lying_object(28) 1,890, wrap(37) 2,148, unwrap(38) 2, rotate(22) 1,156, fullbank(32) 2,958, ignore_look(33) 1,687. Only fullbank has a consumer inside the tile-flag cache; the rest have zero Lua call sites. Either cite a consumer or mark them speculative parity.
- Specify how the walker must honour 0xB6 WalkWait beyond 'the walker must honour it'. The parser emits walkWait{millis}; the C++ LocalPlayer path locks walking for that many ms and, in the mehah build, also interacts with the pre-walk queue. Without a stated rule (does it clear pending pre-walks, or only delay the next send?) two implementations will diverge on exactly the packet the server sends when the bot walks too fast.
- Note that Container fields hasPages / firstIndex / capacity / size all arrive from the 0x6E OpenContainer packet and are what the rewritten 0x70/0x71/0x72 depend on. The spec asks for c.size to be maintained but never says where the initial size and firstIndex come from, and hasPages gates two of the four branches.
- Add a note that Tile::getTopUseThing's first loop tests `thing->isForceUse() || (isCommon(thing) && !isSplash(thing))` where Thing::isCommon() already excludes creatures — so the spec's extra `th.kind ~= 'creature'` guard is harmless, but the forceuse test in C++ is NOT creature-guarded. If a creature appearance ever carried forceuse it would be returned. Worth one line so an implementer does not 'fix' the difference in the wrong direction.
- State that vBot's icon-learning uses schedule(1) and schedule(2) MILLISECONDS, not ticks, that the group binding REPLACES rather than merges (`customCooldowns[lastPhrase] = {id = <existing id>, group = {[iconId] = duration}}`) and only fires when an id entry already exists, and that lastPhrase is updated on ANY talk whose name matches the player, including ordinary chat. (vlib.lua onSpellCooldown/onGroupSpellCooldown handlers)
- Confirmed-correct sections worth leaving untouched, so effort is not wasted re-deriving them: every protobuf field number in the P0-1 table matches appearances.proto:142-211; all eight decoded sample records (3031, 2854, 3160, 103, 4526, 386, 1948, 9596) are byte-exact against the real asset, including every FLAGS2/3/4 value and every submessage column; every frequency statistic in the measurement list is exact (unmove 31818, unpass 16697, automap 15777, bottom 11212, usable 10883, take 7221, clip 6312, unsight 5925, bank 3354, container 3381, multiuse 2675, cumulative 2593, height 2194, avoid 2055, clothes 1984, top 1267, forceuse 1057, lenshelp 981, hang 540, liquidcontainer 48, liquidpool 12, write 12, write_once 84; 43,536 objects, max id 62,144, 8,951 names); the v1 layout and its 62,177-byte size; the claim that ThingFlagAttrFloorChange is dead at 1530 (set only from thingtype.cpp:1096, the legacy .dat path); playerDiagonalWalkSpeed = 3 at data/setup.otml:29; Position::toString = "x,y,z" and the {totalCost, distance, dirFromPrev, prevKey} tuple with translateAllPathsToPath's `node[3] < 0 -> break` chain; the entire Dijkstra core (init cost 1 / totalCost 0, min-heap via the inverted LessNode, ret overwritten on every pop, `distance >= maxDistance -> continue`, hasStairs = isNotPathable && 210<=color<=213, the four-clause reject, ignoreLastCreature recording cost+100, unseen = node.unseen+1, ignoreCost -> 1); the isSightClear Bresenham loop transcribed exactly including the z-walk tail; Container::onAddItem/onRemoveItem's algorithm; getSlotPosition = {0xffff, id|0x40, slot} with no firstIndex; Game::findEmptyContainerId as the lowest free id; Thing::getStackPos returning pos.z when x==0xFFFF && isItem(); the spellId == SpellInfo.id (not clientId) proof via Spells.getSpellByIcon; USE_COOLDOWN_MS = 1000; the diagnosis of luaclient's S[0x70] insert-at-1 bug and S[0x72]'s wrong lastItem placement; the list of consume-and-discard handlers (0x5D, 0x7A, 0x7B, 0x7D/0x7E, 0x96, 0xC0, 0x2A, 0xEB, 0xF4) and that S[0xFA] does emit modalDialog while S[0x96] does not; the on-disk config formats (test.cfg verbatim, def.json content, profile_1.json 44,975 bytes, storage.extras.looting default 40 and lootDelay default 200, and the ui.* <-> JSON mapping).
