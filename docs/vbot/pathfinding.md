# Pathfinding and tile walkability (reimplemented from the C++ client, not from vBot)

# Pathfinding & tile walkability — full specification for `luaclient`

Everything below is **behaviour**, not widget detail, unless a line is explicitly tagged
`[WIDGET]`. Config persistence is named per setting.

All C++ citations are `file:line` under `D:/Claude/otclient_mehah1530/otclient/src/`.

---

## 0. Which of the three pathfinders matters

The C++ client ships **three** independent path searches. They do not share code and do not
agree with each other.

| # | Function | Used by | Knowledge source | Result |
|---|----------|---------|------------------|--------|
| A | `Map::findEveryPath` (`client/map.cpp:1316-1473`) | **every vBot `findPath`/`getPath`/`autoWalk`** via `mods/game_bot/functions/map.lua:76-210` | live tiles **+** minimap | full Dijkstra field `{posStr → (cost, distance, dir, prevPosStr)}` |
| B | `Map::findPath` (`client/map.cpp:831-1003`) | client modules only (`g_map.findPath`, `luafunctions.cpp:164`); **vBot never calls it** | live tiles **+** minimap | `(dirs[], PathFindResult)` |
| C | `Map::newFindPath` / `findPathAsync` (`client/map.cpp:1011-1166`) | map-click autowalk (`LocalPlayer::autoWalk`, `client/localplayer.cpp:213-264`), reached from vBot only through `player:autoWalk(pos)` (`cavebot/minimap.lua:13`) | **minimap only**, seeded with a snapshot of visible tiles | `PathFindResult{status, path, complexity}` |

**Port A first and exactly.** It is the only one the cavebot/targetbot/navibot logic depends
on. Port B second (cheap, ~60 lines, and its flag vocabulary is what `Otc::PathFindFlags`
documents). C is optional; port it only if you implement map-click autowalk.

---

## 1. A — `Map::findEveryPath`: the exact algorithm

### 1.1 Signature and Lua surface

```
std::map<std::string, std::tuple<int,int,int,std::string>>
Map::findEveryPath(const Position& start, int maxDistance,
                   const std::map<std::string,std::string>& params)   // map.cpp:1316
```

Lua binding: `g_map.findEveryPath` (`client/luafunctions.cpp:204`). Params arrive as a
**string→string map**; the Lua wrapper (`functions/map.lua:76-110`) converts `false/nil → 0`
and `true → 1` before the call, and C++ tests `value != "0" && value != ""`
(`map.cpp:1328-1343`). So **any value other than `0` or the empty string is TRUE** —
`ignoreCreatures = "false"` would be *true*.

Return tuple, 1-based in Lua (`functions/map.lua:118-133` reads `node[1]`, `node[3]`, `node[4]`):

```
node[1] = totalCost   (int; the float totalCost truncated by std::tuple<int,...>)
node[2] = distance    (int; number of steps from start)
node[3] = direction   (Otc::Direction 0..7 taken from prev INTO this tile; -1 for the start node)
node[4] = prevPosStr  ("x,y,z" of the predecessor; "" for the start node)
```

Keys are `Position::toString()` = `"x,y,z"` with **no padding** (`client/position.h:249-252`).

### 1.2 Node model

```
struct Node { float cost; float totalCost; Position pos; Node* prev; int distance; int unseen; }
                                                                            // client/map.h:57-65
```

* `cost` = the **ground speed of the tile itself**, fixed at node creation, never updated
  (`map.cpp:1443`). It is the cost *of entering* that tile.
* `totalCost` = accumulated path cost (Dijkstra `g`). **There is no heuristic** — this is
  pure Dijkstra, not A\*.
* `distance` = step count, used for the `maxDistance` cutoff.
* `unseen` = 1 if the tile was not `wasSeen` at creation, then it is *reassigned*
  `node->unseen + 1` on every successful relaxation (`map.cpp:1458-1459`) — i.e. it becomes a
  run-length of unseen tiles. **In `findEveryPath` it is written but never read.** (It is only
  read in C, `map.cpp:1098` `unseen > 50` and `map.cpp:1121-1123`.)

Priority queue: `LessNode{ return b->totalCost < a->totalCost; }` over `Node*`
(`map.cpp:1319-1325`) → a **min-heap on the live, mutable `totalCost`**. Because the compared
value is read from the node at *pop* time and nodes are mutated in place, the heap invariant is
formally violated; in practice it behaves as a lazy-decrease-key Dijkstra. A conforming Lua port
should push `(node, totalCostAtPushTime)` pairs (as `findPath` does, `map.cpp:846-852`) — the
resulting order is identical for all non-degenerate inputs.

### 1.3 Initialisation

```
Node* initNode = new Node{ 1, 0, start, nullptr, 0, 0 };   // map.cpp:1373
nodes[start] = initNode; searchList.push(initNode);
```

The start tile is **never walkability-checked**.

### 1.4 Main loop (`map.cpp:1377-1465`)

```
while searchList not empty:
    node = pop-min
    ret[node.pos.str] = (node.totalCost, node.distance,
                         node.prev ? dirFrom(node.prev.pos, node.pos) : -1,
                         node.prev ? node.prev.pos.str : "")          # 1380-1382
    if node.pos == destPos:
        if hasMargin: maxDistance = min(node.distance + 4, maxDistance)   # 1385
        else:         break                                                # 1387
    if node.distance >= maxDistance: continue                              # 1390
    for i in -1..1: for j in -1..1:                                        # 1392-1395
        if i==0 and j==0: continue
        neighbor = node.pos.translated(i, j)                               # 1396
        if neighbor.x < 0 or neighbor.y < 0: continue                      # 1397
        if neighbor not in nodes:  <classify, see 1.5>                     # 1399-1445
        if nodes[neighbor] == nil: continue      # permanently blocked     # 1447
        diagonal = (i==0 or j==0) ? 1.0 : PLAYER_DIAGONAL_WALK_SPEED       # 1451
        cost = nodes[neighbor].cost * diagonal                             # 1452
        if ignoreCost: cost = 1                                            # 1453-1454
        if node.totalCost + cost < nodes[neighbor].totalCost:              # 1455
            nodes[neighbor].totalCost = node.totalCost + cost
            nodes[neighbor].prev     = node
            if nodes[neighbor].unseen: nodes[neighbor].unseen = node.unseen + 1
            nodes[neighbor].distance = node.distance + 1
            push nodes[neighbor]
```

**Neighbour ordering** is exactly `(dx,dy)` in
`(-1,-1) (-1,0) (-1,1) (0,-1) (0,1) (1,-1) (1,0) (1,1)`
i.e. `NW, W, SW, N, S, NE, E, SE`. It is a genuine tie-breaker: `ret` writes the *last*
relaxation's `prev`, so reproducing this order reproduces vBot's exact chosen route among
equal-cost paths.

### 1.5 Neighbour classification, first visit only (`map.cpp:1399-1445`)

Defaults before any lookup (`map.cpp:1400-1405`):

```
wasSeen=false  hasCreature=false  isNotWalkable=true  isNotPathable=true  mapColor=0  speed=1000
```

Then:

```
if isAwareOfPosition(neighbor):                       # 1406  (live tile window)
    tile = getTile(neighbor)
    if tile:                                          # a MISSING tile keeps the defaults
        wasSeen       = true
        hasCreature   = tile.hasBlockingCreature()    # 1409  (excludes the local player)
        isNotWalkable = not tile.isWalkable(true)     # 1410  (ignoreCreatures = TRUE)
        isNotPathable = not tile.isPathable()         # 1411
        mapColor      = tile.getMinimapColorByte()    # 1412
        speed         = tile.getGroundSpeed()         # 1413
elif not allowOnlyVisibleTiles:                       # 1415  (minimap fallback)
    m = g_minimap.getTile(neighbor)
    wasSeen       = m.hasFlag(MinimapTileWasSeen)
    isNotWalkable = m.hasFlag(MinimapTileNotWalkable)
    isNotPathable = m.hasFlag(MinimapTileNotPathable)
    mapColor      = m.color
    if isNotWalkable or isNotPathable: wasSeen = true # 1421-1422  (blocked ⇒ counts as seen)
    speed         = m.getSpeed()                      # 1423  = speed_byte * 10
# else (allowOnlyVisibleTiles and not aware): defaults stand → blocked
```

Blocking decision:

```
hasStairs = isNotPathable and 210 <= mapColor <= 213                       # 1429
hasReachedMaxDistance = maxDistanceFrom != 0
                        and maxDistanceFromPos.isValid()
                        and euclid(maxDistanceFromPos, neighbor) > maxDistanceFrom   # 1430

if (not wasSeen and not allowUnseen)
   or (hasStairs      and not ignoreStairs      and neighbor != destPos)
   or (isNotPathable  and not ignoreNonPathable and neighbor != destPos)
   or (isNotWalkable  and not ignoreNonWalkable)          # NOTE: no destPos exemption
   or hasReachedMaxDistance:
        nodes[neighbor] = nil                       # permanently blocked  # 1434
elif hasCreature and not ignoreCreatures:                                  # 1435
        nodes[neighbor] = nil                                              # 1436
        if ignoreLastCreature:                                             # 1437-1440
            ret[neighbor.str] = (node.totalCost + 100, node.distance + 1,
                                 dirFrom(node.pos, neighbor), node.pos.str)
            # the tile is reachable-as-a-final-step but never expanded through
else:
        nodes[neighbor] = Node{ cost = speed, totalCost = 1e7,
                                pos = neighbor, prev = node,
                                distance = node.distance + 1,
                                unseen = wasSeen ? 0 : 1 }                 # 1443
```

Three consequences a reimplementer must not miss:

1. **`isNotWalkable` has no `destPos` exemption** — you can never path *onto* an unwalkable
   goal, but you *can* path onto a non-pathable or stairs goal.
2. Classification is **cached forever per position**. A tile first reached in a way that made
   it `nil` is never reconsidered, even from a cheaper direction.
3. `hasStairs` requires **yellow AND not-pathable**. This is a local patch in this repo
   (`map.cpp:1425-1429` carries the rationale comment); stock OTCv8/mehah block on
   `mapColor >= 210 && mapColor <= 213` alone. Port the patched form: colour alone made
   staircases unreachable.

### 1.6 Constants

| Constant | Value | Source |
|---|---|---|
| diagonal multiplier | **3.0** | `g_gameConfig.getPlayerDiagonalWalkSpeed()`, default `3` (`client/gameconfig.h:125`), and `data/setup.otml:26,29` sets `diagonal-walk-speed: 3` for both entries → 3 for this deployment |
| straight multiplier | 1.0 | `map.cpp:1451` |
| unknown-tile speed (A) | 1000 | `map.cpp:1405` |
| minimap speed | `speed_byte * 10`, default byte `10` → 100 | `client/minimap.h:47` |
| tile speed fallback | 100 when the tile has no ground | `client/tile.cpp:563-568` |
| `ignoreCost` step cost | 1 (straight **and** diagonal) | `map.cpp:1453-1454` |
| creature "last step" surcharge | +100 | `map.cpp:1438` |
| margin distance slack | `+4` steps | `map.cpp:1385` |
| default `maxDistance` from Lua | 100 | `functions/map.lua:156-158` |

**There is no `maxComplexity` and no node-count cap in A.** The only bounds are `maxDistance`
(step count) and the walkability classification. A Lua port must add its own guard (see §5.6).

### 1.7 Path extraction (`functions/map.lua:110-134`, `translateAllPathsToPath`)

```
dirs = {}
cur = destPosStr
while #cur > 0:
    node = paths[cur]
    if not node: break
    if node[3] < 0: break          # reached the start node
    prepend node[3]
    cur = node[4]
reverse → list of Otc::Direction
```

Returned path is a **plain array of `Otc::Direction` integers**
(`North=0, East=1, South=2, West=3, NorthEast=4, SouthEast=5, SouthWest=6, NorthWest=7`,
`client/const.h:158-169`) — exactly the numbering `luaclient`'s `proto/sender.lua:80-82`
already uses, so `sender:walk(path[1])` and `sender:autoWalk(path)` take it unchanged.

The direction between two adjacent tiles is computed by
`Position::getDirectionFromPositions` (`client/position.h:149-180`) via `atan2(-dy, dx)` and
22.5°-wide sectors. For strictly adjacent tiles this reduces to a trivial 3×3 lookup — implement
it as a table, not with `atan2`.

### 1.8 The Lua wrapper (`functions/map.lua:137-210`) — `findPath` / `getPath`

This is what the bot actually calls. Its behaviour is part of the contract:

1. `if not destPos or startPos.z ~= destPos.z then return nil end` (line 150-152).
2. `maxDist` defaults to **100** if not a number (156-158).
3. Injects `params.destination = "x,y,z"` (162-163) → enables the early `break` in A.
4. **Margin mode** — when both `marginMin` and `marginMax` (aliases `minMargin`/`maxMargin`)
   are numbers (165-186): scans the full square `x,y ∈ [-marginMax, marginMax]`, keeps only
   cells with `|x| >= marginMin or |y| >= marginMin` (a **Chebyshev ring**, not a circle),
   picks the candidate with the smallest `node[1]` (totalCost), returns the path to it. If no
   candidate exists → `nil`. Note the C++ side ALSO sees `marginMin`/`marginMax` and switches
   to `maxDistance = min(dist+4, maxDistance)` on reaching `destPos` (`map.cpp:1384-1385`) —
   the extra 4 steps of exploration is what makes the ring reachable.
5. **Precision mode** — when `paths[destPosStr]` is missing and `params.precision` is a number
   (189-208): for `p = 1..precision`, scan the **full square** `[-p,p]²` (not a ring), pick the
   lowest-cost node, return that path. `precision = 0` means "no fallback": the exact tile or
   nothing. **`precision` is never sent to C++** — it is purely a Lua post-filter.
6. Otherwise return `translateAllPathsToPath(paths, destPos)`.

`autoWalk(dest, maxDist, params)` (212-226) = `findPath` + `g_game.autoWalk(path, {0,0,0})`;
`autoWalk(dirsList)` with a list argument sends the list verbatim.

---

## 2. B — `Map::findPath` (the `Otc::PathFindFlags` variant)

`map.cpp:831-1003`. Same 8-neighbour loop, but a real **A\*** with an admissible-ish heuristic.

```
result = NoWay
if start == goal              -> SamePosition        # 859-862
if start.z != goal.z          -> Impossible          # 864-867
# goal pre-check                                     # 869-880
if isAwareOfPosition(goal):
    t = getTile(goal); if not t or not t.isWalkable(flags & PathFindIgnoreCreatures): return NoWay
else:
    if minimap.getTile(goal).hasFlag(MinimapTileNotWalkable): return NoWay

nodes[start] = SNode{cost=0, totalCost=0}
loop with currentNode:
    if #nodes > maxComplexity: result = TooFar; break            # 890-893
    if currentNode.pos == goal and (!found or cost < found.cost): found = currentNode
    if found and currentNode.totalCost >= found.cost: break      # 899-900
    for the same 8 neighbours (same NW,W,SW,N,S,NE,E,SE order):
        defaults: wasSeen=false hasCreature=false isNotWalkable=true isNotPathable=true speed=100
        if isAwareOfPosition(n):
            wasSeen = true                                        # 916 (even if tile==nullptr!)
            if tile: hasCreature   = tile.hasCreatures() and not (flags & IgnoreCreatures)
                     isNotWalkable = not tile.isWalkable(flags & IgnoreCreatures)
                     isNotPathable = not tile.isPathable()
                     speed         = tile.getGroundSpeed()
        else:
            m = minimap.getTile(n)
            wasSeen       = m.hasFlag(WasSeen)
            isNotWalkable = m.hasFlag(NotWalkable)
            isNotPathable = m.hasFlag(NotPathable)
            if isNotWalkable or isNotPathable: wasSeen = true
            speed         = m.getSpeed()
        if n != goal:                                             # 934-946
            if not (flags & AllowNotSeenTiles) and not wasSeen: continue
            if wasSeen:
                if not (flags & AllowCreatures)   and hasCreature:   continue
                if not (flags & AllowNonPathable) and isNotPathable: continue
                if not (flags & AllowNonWalkable) and isNotWalkable: continue
        else:                                                     # 947-953
            if not (flags & AllowNotSeenTiles) and not wasSeen: continue
            if wasSeen and not (flags & AllowNonWalkable) and isNotWalkable: continue
        walkDir    = dirFrom(current.pos, n)
        walkFactor = (walkDir >= Otc::NorthEast) ? 3.0 : 1.0      # 954-958  (diagonal = 4..7)
        cost       = current.cost + (speed * walkFactor) / 100.0  # 959
        ...
        neighbor.totalCost = neighbor.cost + n.distance(goal)     # 971  euclidean heuristic
```

Path extraction (`map.cpp:986-996`): walk `prev` chain from the found node pushing `dir`,
then `dirs.pop_back()` (drops the start node's `InvalidDirection`), then reverse.

Flags (`client/const.h:701-708`):

```
PathFindAllowNotSeenTiles = 1
PathFindAllowCreatures    = 2
PathFindAllowNonPathable  = 4
PathFindAllowNonWalkable  = 8
PathFindIgnoreCreatures   = 16
```

Results (`const.h:692-699`): `Ok=0, SamePosition=1, Impossible=2, TooFar=3, NoWay=4`.

Key differences from A: `cost` is divided by 100; the heuristic is euclidean distance added to
`cost`; `maxComplexity` caps the **node count** (not step count); an aware-but-absent tile is
treated as `wasSeen=true, isNotWalkable=true` (A treats it as `wasSeen=false`).

---

## 3. C — `Map::newFindPath` (minimap-only A\*, async)

`map.cpp:1011-1139`. Included for completeness; only reachable through `player:autoWalk()`.

* Seeded with `visibleNodes`: one `Node` per **currently loaded tile on the start floor**
  (`map.cpp:1141-1160`); blocked ones get `totalCost = 0` (so they are effectively pre-closed),
  passable ones `totalCost = 1e7`.
* Neighbours are read from `g_minimap.threadGetTile` **only** (`map.cpp:1082`) — this runs on a
  detached worker thread.
* A tile that is `NotWalkable || NotPathable || Empty` and is not the goal → `nil`
  (`map.cpp:1088-1089`).
* Unseen tiles get `speed = 2000` (`map.cpp:1091-1092`) instead of being refused, and any node
  whose `unseen` run exceeds **50** is skipped (`map.cpp:1098-1099`).
* Cost: `cost = tileSpeed * diagonal; cost += diagonal * 50 * max(5, dist(pos, goal))`
  (`map.cpp:1101-1103`) — the heuristic is folded into the edge weight (inconsistent, so this
  is a greedy-ish search); relaxation needs a `+50` improvement margin (`map.cpp:1104`).
* Node budget `limit = 50000` (`map.cpp:1062`), `complexity = 50000 - limit`.
* Nodes farther than `startDistance + 10000` from the goal are skipped (`map.cpp:1076`).
* Reconstruction **clears the whole path** whenever an `unseen` node is met
  (`map.cpp:1119-1123`) → only the fully-seen suffix survives.
* `LocalPlayer::autoWalk` truncates to 127 dirs and retries at 300/700/1200 ms on failure
  (`client/localplayer.cpp:230-258`, `:174-185`).

---

## 4. The walkability / pathability predicates (THE critical output)

### 4.1 Tile-level flag word

`Tile` keeps a 32-bit `m_thingTypeFlag` OR-ed from every thing on it
(`Tile::setThingFlag`, `client/tile.cpp:930-1013`). Bits (`client/const.h:1545-1573`):

```
FULL_GROUND               = 1<<0     NOT_WALKABLE   = 1<<1     NOT_PATHABLE = 1<<2
NOT_SINGLE_DIMENSION      = 1<<3     BLOCK_PROJECTTILE = 1<<4  HAS_DISPLACEMENT = 1<<5
ELEVATION = 1<<7  HAS_LIGHT = 1<<9   HAS_TALL_THINGS = 1<<10   HAS_WIDE_THINGS = 1<<11
HAS_TALL_THINGS_2 = 1<<12  HAS_WIDE_THINGS_2 = 1<<13  HAS_WALL = 1<<14
HAS_HOOK_EAST = 1<<15  HAS_HOOK_SOUTH = 1<<16  HAS_CREATURE = 1<<17
HAS_COMMON_ITEM = 1<<18  HAS_TOP_ITEM = 1<<19  HAS_BOTTOM_ITEM = 1<<20
HAS_GROUND_BORDER = 1<<21  HAS_TOP_GROUND_BORDER = 1<<22
HAS_THING_WITH_ELEVATION = 1<<23  IGNORE_LOOK = 1<<24  CORRECT_CORPSE = 1<<25
```

**Only ITEMS contribute the movement bits.** `Tile::setThingFlag` returns early with
`if (!thing->isItem()) return;` (`tile.cpp:996`) before the block that sets `NOT_WALKABLE`,
`NOT_PATHABLE`, `BLOCK_PROJECTTILE`, `FULL_GROUND` and increments `m_elevation`
(`tile.cpp:998-1012`). Creatures affect walkability only through the explicit creature loop.

### 4.2 The predicates verbatim

```cpp
// tile.cpp:708-724
bool Tile::isWalkable(bool ignoreCreatures) {
    if (m_thingTypeFlag & NOT_WALKABLE || !getGround()) return false;
    if (!ignoreCreatures && hasCreatures())
        for (thing : m_things)
            if (thing->isCreature()) {
                auto c = thing->as<Creature>();
                if (!c->isPassable() && c->canBeSeen()) return false;
            }
    return true;
}
// tile.h:77
bool Tile::isPathable()   { return (m_thingTypeFlag & NOT_PATHABLE) == 0; }
// tile.h:81
bool Tile::isLookPossible(){ return (m_thingTypeFlag & BLOCK_PROJECTTILE) == 0; }
// tile.h:129
bool Tile::hasElevation(int e = 1) { return m_elevation >= e; }
// tile.cpp:838-844
bool Tile::hasBlockingCreature() const {
    for (thing : m_things)
        if (thing->isCreature() && !thing->as<Creature>()->isPassable() && !thing->isLocalPlayer())
            return true;
    return false;
}
// tile.cpp:563-568
int  Tile::getGroundSpeed() { auto g = getGround(); return g ? g->getGroundSpeed() : 100; }
// tile.cpp:537
ItemPtr Tile::getGround()   { auto t = getThing(0); return (t && t->isGround()) ? t : nullptr; }
// tile.cpp:571-584
uint8_t Tile::getMinimapColorByte() {
    if (m_minimapColor != 0) return m_minimapColor;      // editor builds only
    for (thing : reverse(m_things)) {
        if (thing->isCreature() || thing->isCommon()) continue;
        uint8_t c = thing->getMinimapColor(); if (c != 0) return c;
    }
    return 255;
}
// tile.cpp:783-802
bool Tile::isClickable() {          // NOT used by pathfinding; mouse targeting only
    bool hasGround=false, hasOnBottom=false, hasIgnoreLook=false;
    for (thing : m_things) {
        if (thing->isGround()) hasGround = true; else if (thing->isOnBottom()) hasOnBottom = true;
        if (thing->isIgnoreLook()) hasIgnoreLook = true;
        if ((hasGround || hasOnBottom) && !hasIgnoreLook) return true;
    }
    return false;
}
```

Creature side (`client/creature.h:146,152,156`):
```
isPassable()  = m_passable                         // set by 0x92 CreatureUnpass; DEFAULT false
isInvisible() = outfit.isEffect() && outfit.auxId == 13
canBeSeen()   = !isInvisible() || isPlayer()
```

### 4.3 Every appearance flag involved, with protobuf field number

Source of truth for the mapping: `ThingType::applyAppearanceFlags`
(`client/thingtype.cpp:177-380`); field numbers from
`src/protobuf/appearances.proto:142-210` (message `AppearanceFlags`).

| proto field | # | wire | → `ThingFlagAttr` (`const.h:1247-1303`) | consumed by |
|---|---|---|---|---|
| `bank` (`AppearanceFlagBank{waypoints=1}`) | **1** | LEN | `ThingFlagAttrGround` (1<<0) **and** `m_groundSpeed = bank.waypoints` (`thingtype.cpp:179-182`) | `Tile::getGround()`, `getGroundSpeed()` — **the single most important flag** |
| `clip` | **2** | bool | `ThingFlagAttrGroundBorder` (1<<1) | `HAS_GROUND_BORDER`, `getMinimapColorByte` skip rules |
| `bottom` | **3** | bool | `ThingFlagAttrOnBottom` (1<<2) | stack order, `isClickable`, `limitsFloorsView` |
| `top` | **4** | bool | `ThingFlagAttrOnTop` (1<<3) | stack order |
| `unpass` | **13** | bool | **`ThingFlagAttrNotWalkable` (1<<13)** → tile `NOT_WALKABLE` | `isWalkable` |
| `unmove` | **14** | bool | `ThingFlagAttrNotMoveable` (1<<14) | *not used by pathfinding* (only by "move item") |
| `unsight` | **15** | bool | **`ThingFlagAttrBlockProjectile` (1<<15)** → tile `BLOCK_PROJECTTILE` | `isLookPossible`, `Map::isSightClear`, `Tile::canShoot` |
| `avoid` | **16** | bool | **`ThingFlagAttrNotPathable` (1<<16)** → tile `NOT_PATHABLE` | `isPathable`, `hasStairs`, floor-change detection |
| `hang` / `hook` / `rotate` … | 20/21/22 | — | — | irrelevant |
| `light` | 23 | LEN | `ThingFlagAttrLight` | irrelevant |
| `shift` | **26** | LEN | `ThingFlagAttrDisplacement` (1<<25) | `NOT_SINGLE_DIMENSION` only |
| `height` (`AppearanceFlagHeight{elevation=1}`) | **27** | LEN | `ThingFlagAttrElevation` (1<<26), `m_elevation = height.elevation` | `Tile::m_elevation` **counter** (+1 per elevated item, `tile.cpp:1011-1012`) → `hasElevation(3)` in the autowalk truncation rule |
| `lying_object` | 28 | bool | `ThingFlagAttrLyingCorpse` | irrelevant |
| `automap` (`AppearanceFlagAutomap{color=1}`) | **30** | LEN | `ThingFlagAttrMinimapColor`, `m_minimapColor = automap.color` | `getMinimapColorByte` → the 210-213 stairs rule, minimap store |
| `lenshelp` (`AppearanceFlagLenshelp{id=1}`) | **31** | LEN | `ThingFlagAttrLensHelp`, `m_lensHelp = id` | vBot's floor-change classifier (1104/1105) |
| `fullbank` | **32** | bool | `ThingFlagAttrFullGround` (1<<31) → tile `FULL_GROUND` | rendering/covering only |
| `ignore_look` | **33** | bool | `ThingFlagAttrLook` (1<<32) → tile `IGNORE_LOOK` | `isClickable` only |
| `dont_hide` | 24 | bool | `ThingFlagAttrDontHide` | `limitsFloorsView` only |

Also needed for tile geometry: `Appearance.frame_group[].sprite_info.pattern_width/height`
(`appearances.proto:118-119`) → `m_size`; `isSingleDimension() = area()==1`
(`thingtype.h:109`), used for `NOT_SINGLE_DIMENSION`, `HAS_WALL`, `isSingleGround`. Pathfinding
does **not** need these.

**`ThingFlagAttrFloorChange` (1<<48) is unreachable from protobuf assets.** It is only produced
by the legacy `.dat` path (`thingtype.cpp:1096`); `applyAppearanceFlags` never sets it. So
`Tile::hasFloorChange()` is **always false on 1530** — confirmed by the vBot comment at
`cavebot/walking.lua:57-68`. Do not build hole avoidance on it.

### 4.4 Reduced predicates for `luaclient`

Given a per-item-id flag word `F(id)` and a tile's `things[]` (all `kind=='item'` except
creatures), and creature records with `passable`:

```
GROUND_ID(tile)     = things[1].kind=='item' and F(things[1].id) has GROUND  ->  things[1].id  else nil
groundSpeed(tile)   = GROUND_ID and bankWaypoints(GROUND_ID) or 100
notWalkable(tile)   = any item thing t with F(t.id) & UNPASS
notPathable(tile)   = any item thing t with F(t.id) & AVOID
blockProjectile(t)  = any item thing t with F(t.id) & UNSIGHT
minimapColor(tile)  = last item thing (reverse order) that is NOT "common"
                      (common = not ground, not groundBorder, not onTop, not onBottom)
                      with automapColor != 0 ; else 255
elevationCount(t)   = # of item things with F(t.id) & ELEVATION

isWalkable(tile, ignoreCreatures) =
      GROUND_ID ~= nil
  and not notWalkable(tile)
  and (ignoreCreatures or no creature c on the tile with (not c.passable and canBeSeen(c)))
isPathable(tile) = not notPathable(tile)
hasBlockingCreature(tile) = exists creature c ~= localPlayer with not c.passable
```

Magic fields (fire/energy/poison) are **ordinary items carrying `avoid`, not `unpass`** — so a
field tile is *walkable* but *not pathable*, which is exactly why every vBot call passes
`ignoreNonPathable = true` ("ignore fields"). There is **no** `ignoreFields` parameter in C++
(`map.cpp:1327-1347` lists every recognised key); `cavebot/stand_lure.lua:89-90,138` passes
`ignoreFields` and it is silently ignored.

### 4.5 Measured statistics from this deployment's `appearances-*.dat`

(43 536 object appearances, `data/things/1530/appearances-17a72b30….dat`; measured with a
protobuf walk reusing `luaclient/tools/extract_appearances.py`)

```
unpass    16697    unsight   5925    avoid     2055    bank(ground) 3354
automap   15777    fullbank  2958    elevation 2194    lenshelp      981
grounds that are also unpass: 496      grounds that are avoid: 249
bank.waypoints values: {0,1,50,70,90,95,100,110,115,120,121,125,130,140,150,160,170,180,
                        200,250,260,300,350,400,450,500,800,850,1000,1200}
bank.waypoints == 0: 273 items — ALL of them also unpass (so cost-0 steps are unreachable)
automap colours in 205..215: only 207 (301 items), 210 (972 items), 215 (115 items)
  → of the 972 yellow(210) items, 545 also carry `avoid`
lenshelp: 1100:22 1101:4 1102:6 1103:38 1104:422 1105:122 1106:19 1107:6 1108:11
          1109:2 1110:8 1111:194 1112:127
```

So **211/212/213 do not exist in this asset set** — the range check is future-proofing. Colour
210 is pure yellow: the byte is a 6×6×6 cube, `c = (r/51)*36 + (g/51)*6 + (b/51)`
(`framework/util/color.h:94-101`), so 210 = (255,255,0), 211 = (255,255,51), 212 =
(255,255,102), 213 = (255,255,153).

---

## 5. Unseen tiles: the minimap substitute

### 5.1 `MinimapTile` (`client/minimap.h:33-51`)

```
struct MinimapTile { uint8_t flags; uint8_t color = 255; uint8_t speed = 10; }   // 3 bytes, packed
enum MinimapTileFlags { WasSeen = 1, NotPathable = 2, NotWalkable = 4, Empty = 8 }
getSpeed() = speed * 10
```

Default ("nulltile", `minimap.cpp:51`) = `{flags=0, color=255, speed=10}` → `getSpeed()==100`,
`wasSeen == false`. `getTile` returns it for any position outside a known block
(`minimap.cpp:482-490`).

`MinimapTileEmpty (8)` is **never written** by any code path in this client (grep: set nowhere;
read only at `map.cpp:1086`). Treat it as always 0.

### 5.2 How a tile enters the minimap

`Minimap::updateTile` (`minimap.cpp:459-480`):

```
if tile:
    color  = tile.getMinimapColorByte()
    flags |= WasSeen
    if not tile.isWalkable(true): flags |= NotWalkable      # ignoreCreatures = TRUE
    if not tile.isPathable():     flags |= NotPathable
    speed  = min(ceil(tile.getGroundSpeed() / 10.0), 255)
else:
    flags |= NotWalkable | NotPathable                      # (and color stays 255, speed 10)
if tile != nulltile: write into the 64x64 block, block.justSaw()
```

Called from `Map::notificateTileUpdate` **only when the changed thing is an item**
(`map.cpp:114-127`) and from `Map::cleanTile` when the tile object is already gone
(`map.cpp:438`). So: every map-description item write updates the minimap knowledge for that
tile — the minimap is a *lossy 3-byte-per-tile persistent cache* of exactly the three facts the
pathfinder needs.

Note the walkability recorded is **creature-independent** (`isWalkable(true)`); creatures never
enter the minimap.

### 5.3 Colour → walkability

There is **no colour→walkable mapping in the live client path**. Colour is only consulted for
the stairs rule (`mapColor in [210,213] && isNotPathable`). Colour-based classification exists
only in `Minimap::loadImage` (`minimap.cpp:506-578`), which imports a PNG:

```
nonPathableColors = { #ffff00 }                                        // yellow
nonWalkableColors = { #000000 oil, #006600 trees, #ff3300 walls, #666666 mountain,
                      #ff6600 lava, #00ff00 position, #ccffff ice }
water #3300cc or alpha==0 -> NotWalkable and c = 255 (skipped)
```

and even there the loop is dead code for the walk/pathable lists: the `for` bodies are guarded
by `if (flags != 0)` **before** any flag has been set (`minimap.cpp:542,550`), so only the
water/alpha case ever sets a flag. Do not port `loadImage`.

### 5.4 Block addressing and the on-disk format (`minimap.otmm`)

Needed if the headless client wants to seed itself from the real client's knowledge, or persist
its own. `MMBLOCK_SIZE = 64` (`minimap.h:29`), one `std::unordered_map<blockIndex, block>` per z.

```
blockIndex(pos)   = (pos.y / 64) * 1024 + (pos.x / 64)        // minimap.h:167   (65536/64 = 1024)
blockOffset(pos)  = (x - x%64, y - y%64)                       // minimap.h:153-159
tileIndex(x, y)   = ((y % 64) * 64) + (x % 64)                 // minimap.h:61
indexPosition(i,z)= ((i % 1024)*64, (i / 1024)*64, z)          // minimap.h:160-166
```

File (`saveOtmm` `minimap.cpp:930-985`, `readOtmm` `minimap.cpp:656-743`), little-endian:

```
off 0  u32  signature 0x4D4D544F ("OTMM")
off 4  u16  dataStart (= 22 for version 1)
off 6  u16  version   (= 1)
off 8  u32  flags     (= 0)
off 12      string    u16 len + bytes, "OTMM 1.0"          -> 10 bytes, ends at 22
then repeated blocks:
       u16 blockX (multiple of 64)  u16 blockY  u8 z  u16 compressedLen
       compressedLen bytes of zlib (compress2 level 3) of exactly 64*64*3 = 12288 bytes
       = 4096 MinimapTile records in tileIndex order, each {flags u8, color u8, speed u8}
end marker: u16 0xFFFF, u16 0xFFFF, u8 0xFF
```

Live path: `<profile>/minimap.otmm` (written by `modules/game_minimap/minimap.lua:139`,
present at `otclient/profiles/minimap.otmm`). Only blocks with `wasSeen()` are written
(`minimap.cpp:952-953`); the loader merges tile-by-tile into memory (`mergeOtmmBlock`).

### 5.5 What this means for a client with no minimap

`luaclient` currently has **no** persistent tile knowledge — `state.map` holds only the aware
window (`game/state.lua:409-435`, `setCentralPosition` evicts everything outside it). With the
C++ semantics ported literally:

* `isAwareOf(n)` false and `allowOnlyVisibleTiles` falsy → the minimap lookup returns nulltile →
  `wasSeen=false, isNotWalkable=false?` **No** — nulltile has `flags == 0`, so
  `isNotWalkable=false, isNotPathable=false, wasSeen=false`, `speed=100`. With
  `allowUnseen` **not** set (which is the case for most vBot calls) the tile is blocked by
  `(!wasSeen && !allowUnseen)`. With `allowUnseen = true` (goto's main call passes it) the tile
  is **treated as free, speed 100** — the search would happily plan straight through unexplored
  space.
* Therefore a `luaclient` cavebot **must** implement a `MinimapTile`-equivalent store, or every
  `goto` beyond ~9 tiles either fails (no `allowUnseen`) or produces fantasy paths (with it).

**Recommendation: implement `game/known.lua` — a 3-byte-per-tile store written on every tile
description, with the exact `Minimap::updateTile` semantics and the OTMM format above** so it
interoperates with the real client's file.

### 5.6 vBot's own floor-change guard (behaviour that must be reimplemented alongside)

`cavebot/walking.lua:126-205` re-walks every returned path and refuses it if any tile other
than the exact destination is a floor change. Classifier `isFloorChangeTile(p)`
(`walking.lua:132-165`):

```
tile = getTile(p); if not tile -> false            # unseen: trust the pathfinder's stairs rule
color = getMinimapColor(p)                          # Map::getMinimapColor, map.cpp:1168-1178:
                                                    #   tile colour byte, else minimap colour
if 210 <= color <= 213 and not tile:isPathable() -> true   ("stairs (yellow, not pathable)")
ground = tile:getGround()
if itemChangesFloor(ground) -> true
top = tile:getTopUseThing(); if top ~= ground and itemChangesFloor(top) -> true
if ground.id or top.id in avoidTileIds -> true

itemChangesFloor(item):                             # walking.lua:118-127
    tt = g_things.getThingType(item:getId(), 0)
    if tt:getLensHelp() in {1104, 1105} -> true      # stairs up / stairs down
    if item:isGround() and tt:isNotPathable() -> true  # holes/trapdoors/stairs grounds
```

`TargetBot` uses the single-step form `CaveBot.wouldStepChangeFloor(pos, dir)`
(`walking.lua:170-180`, called from `targetbot/walking.lua:38-47`).

Lenshelp groups **deliberately excluded** (`walking.lua:96-100`): 1100 ladders, 1101 sewer
grates, 1102 rope spots, 1106 shovel spots — you `use()` those, standing on them is harmless.

Also mirrored from the client: before sending an autowalk the path is truncated at the first
tile with `hasFloorChange() or hasElevation(3)` (`walking.lua:430-449`, mirroring
`modules/game_walk/walk.lua:74-79`). Since `hasFloorChange()` is always false on 1530, the only
live half is `elevationCount >= 3`.

---

## 6. The parameter values vBot actually passes

Every call goes through `functions/map.lua`'s `findPath`/`getPath`/`autoWalk` → `findEveryPath`.
`maxDist` is the second argument.

| Call site | maxDist | params |
|---|---|---|
| `cavebot/actions.lua:80` (travel/npc approach) | 7 | `{ignoreNonPathable=true, precision=1}` |
| `cavebot/actions.lua:418` (goto final approach, dist<=3) | 10 | `{ignoreNonPathable=true, precision=0}` |
| `cavebot/actions.lua:436` (goto reachability probe) | `storage.extras.gotoMaxDistance` (**64**) | `{ignoreNonPathable=true, precision=1, ignoreCreatures=true, allowUnseen=true, allowOnlyVisibleTiles=false}` |
| `cavebot/actions.lua:449` (same, creatures NOT ignored) | same | `{ignoreNonPathable=true, precision=1}` |
| `cavebot/actions.lua:468` (attack blocker) | 7 | `{ignoreNonPathable=true, precision=1}` |
| `cavebot/actions.lua:501` (goto attempt #1) | 40 | **`{}` — nothing ignored** ("don't ignore fields") — only when `Config.ignoreFields` is false |
| `cavebot/actions.lua:506` (goto attempt #2) | `gotoMaxDistance` | `{ignoreNonPathable=true, allowUnseen=true, allowOnlyVisibleTiles=false}` |
| `cavebot/actions.lua:518` (goto, retries>=3) | 50 | `{ignoreNonPathable=true, precision=retries-1 (0 for stairs/explicit precision), allowUnseen=true, allowOnlyVisibleTiles=false}` |
| `cavebot/actions.lua:536` (goto last resort) | `gotoMaxDistance` | `{ignoreNonPathable=true, precision=1, ignoreCreatures=true, allowUnseen=true, allowOnlyVisibleTiles=false}` |
| `cavebot/cavebot.lua:368,389` (resume-nearest-waypoint scan) | `gotoMaxDistance` | `{ignoreNonPathable=true}` |
| `cavebot/cavebot.lua:145` (self-nav to stay position) | 40 | `{ignoreNonPathable=true, precision=2}` |
| `cavebot/antilost.lua:205` (is-back-on-track probe) | `gotoMaxDistance` or 40 | `{ignoreNonPathable=true, precision=1, ignoreCreatures=true, allowUnseen=true, allowOnlyVisibleTiles=false}` |
| `cavebot/antilost.lua:458,530` (recovery walk) | 30 | `{ignoreNonPathable=true, precision=0}` |
| `cavebot/antilost.lua:577,583` (step away / final) | 3 | `{ignoreNonPathable=true, precision=0}` |
| `cavebot/stand_lure.lua:89` (path without monsters) | 30 | `{ignoreFields=true (NO-OP), ignoreNonPathable=true, ignoreCreatures=true, precision=0}` |
| `cavebot/stand_lure.lua:90` (path with monsters) | maxDist | same but `ignoreCreatures=false` |
| `cavebot/stand_lure.lua:138` | 30 | `{ignoreCreatures=false, ignoreFields=true(NO-OP), ignoreNonPathable=true, precision=0}` |
| `targetbot/target.lua:70` (target scoring, `#path` = step distance) | 7 | `{ignoreLastCreature=true, ignoreNonPathable=true, ignoreCost=true, ignoreCreatures=true}` |
| `targetbot/creature_attack.lua:161` | 5 | `{ignoreNonPathable=true, precision=2}` |
| `targetbot/creature_attack.lua:170` (distance measure) | 10 | `{ignoreCreatures=true, ignoreNonPathable=true, ignoreCost=true}` |
| `targetbot/creature_attack.lua:163/176/184/186` (`walkTo`) | 10 | `{marginMin=5, marginMax=6, ignoreNonPathable=true}` / `{ignoreNonPathable=true, precision=1}` / `{ignoreNonPathable=true, marginMin=keepDistanceRange, marginMax=keepDistanceRange+1, maxDistanceFrom={anchorPosition, anchorRange}}` |
| `targetbot/creature_attack.lua:204,230` (reposition) | 2 | `{ignoreNonPathable=true}` |
| `targetbot/looting.lua:169,330` | 20 / 6 | `{ignoreNonPathable=true, precision=walkPrecision}` / `{ignoreNonPathable=true, ignoreCreatures=true, ignoreCost=true}` |
| `navibot/navibot.lua:514` (follow leader) | 50 | `{ignoreNonPathable=true, ignoreCreatures=true, precision=max(1, holdDist)}` |
| `vBot/vlib.lua:952,962` (reach ground item) | 20 | `{ignoreNonPathable=true, precision=1}` |
| `vBot/new_cavebot_lib.lua:264` | 10 | `{ignoreNonPathable=true, ignoreCreatures=true, precision=<caller>}` |
| `vBot/new_cavebot_lib.lua:229/247/278` | 20 | `{ignoreCreatures=true, precision=<caller>}` |
| `vBot/combo.lua:382` | 20 | `{ignoreNonPathable=true, precision=1, ignoreStairs=false}` |

**Observations that constrain the port:**

* `ignoreNonWalkable` is **never** passed by vBot. Unwalkable tiles always block.
* `ignoreStairs` is never passed truthy (`combo.lua:382` passes `false`→`0`). So the
  yellow+non-pathable stairs rule is **always active**.
* `allowUnseen=true` appears only in the goto/antilost family, always paired with
  `allowOnlyVisibleTiles=false`.
* `maxDistanceFrom` is only used by TargetBot's anchor mode, as `{positionTable, range}`
  → serialised `"x,y,z,range"` by `functions/map.lua:101-108`.
* `ignoreLastCreature` is used only by `targetbot/target.lua:70`, so a monster's own tile
  counts as reachable-in-one-more-step (cost +100).

Also relevant (behaviour, not pathfinding proper):
`cavebot/actions.lua:385` refuses a goto when `|dx| + |dy| > gotoMaxDistance` (**Manhattan**,
while `maxDistanceFrom` uses **euclidean** and `precision`/`margin` use **Chebyshev**).
`cavebot/actions.lua:394-395` marks a waypoint as "stairs" when
`210 <= g_map.getMinimapColor(pos) <= 213`, which forces exact-tile arrival.

---

## 7. Configuration data and where it lives (headless-readable)

### 7.1 CaveBot config → `cavebot_configs/<name>.cfg`

Line-oriented `key:value`; the last three lines are JSON blobs
(`cavebot/cavebot.lua:578-610` writes, `:207-282` reads). Real file, verbatim
(`profiles/bot/vBot_4.8/cavebot_configs/test.cfg`):

```
goto:33218,32434,7,0
exanihur:up,north
exanihur:down,south
config:{"ignoreFields":false,"skipBlocked":false,"antiLostLadderIds":"1948,1968,5542,7771,9116,20474,20475,21365,28656,31129,31130,31262,33770,34243,35908,43374,48493,48494,50122,50123,50564,50565,435,7750,21221,21298","ping":100,"antiLostRopeToolId":9596,"stayPathEnabled":true,"waypointHud":false,"walkDelay":10,"avoidTileIds":"","avoidFloorChange":true,"mapClickDelay":100,"useDelay":400,"wptDistance":5,"antiLostTeleportIds":"1949,1950,1951,1952","mapClick":false,"smoothWalk":false,"antiLostRopeIds":"386,7762,12935,12936,13381,33051","antiLostEnabled":true}
extensions:[]
staypositions:{"3":{"x":33218,"y":32433,"z":6},"2":{"x":33218,"y":32434,"z":7}}
```

* `goto:x,y,z[,precision]` — the optional 4th field is the **precision marker**
  (`cavebot/actions.lua:346-352`): present ⇒ arrival requires `|dx| <= p and |dy| <= p`
  (Chebyshev per axis), `0` ⇒ the exact tile.
* `staypositions` is keyed by the **1-based action index as a string**.
* Pathfinding-relevant keys in `config:`: `avoidFloorChange` (bool, default `true`),
  `avoidTileIds` (comma-separated ids, default `""`), `smoothWalk`, `mapClick`,
  `mapClickDelay`, `walkDelay`, `ping`, `ignoreFields`, `skipBlocked`
  (`cavebot/config.lua:26-61`, `cavebot/walking.lua:34-37`). `[WIDGET]` The rows themselves
  are a UI panel; only the JSON blob matters headless.

### 7.2 Global bot storage → `storage/profile_<n>.json`

`storage.extras.gotoMaxDistance` = **64** in the live profile
(`profiles/bot/vBot_4.8/storage/profile_1.json`, key `extras`). Same object holds
`extras.machete = 9596`, `extras.pathfinding = true`, `extras.killUnder = 1`, etc.
`storage.targetbotAvoidFloorChange` (default: absent ⇒ enabled,
`targetbot/walking.lua:36-38`) is a top-level key of the same file.

### 7.3 TargetBot config → `targetbot_configs/<name>.json`

Per-creature entries carry `keepDistanceRange`, `anchorRange`, `chase`, `rePosition`,
`lureCount` — all consumed as pathfinding params at `targetbot/creature_attack.lua:161-230`.

### 7.4 Persistent map knowledge → `<profile>/minimap.otmm`

Format in §5.4. There is no per-bot copy; it is the client-wide file.

---

## 8. Memory / time expectations

Reference frames:

* **Aware window** (all the `luaclient` tile store ever holds for one floor):
  `awareRange = {left=8, top=6, right=9, bottom=7}` (`game/state.lua:160`) → **18 × 14 = 252
  tiles**. A Dijkstra over that closes at most 252 nodes, ~2 000 relaxations → **< 0.3 ms** in
  LuaJIT, negligible memory.
* **40 × 40 known area** (the target in the brief, i.e. with a `known.lua` store): the search box
  is bounded by `maxDistance` in Chebyshev steps, so `maxDistance = 40` ⇒ ≤ 81 × 81 = **6 561**
  candidate cells, in practice ≤ the number of known tiles in range (~1 600).
  * Flat FFI arrays over an 81×81 origin-relative grid:
    `totalCost` (double, 52 KB) + `cost` (float, 26 KB) + `prev` (int32, 26 KB) +
    `dist` (int16, 13 KB) + `state` (uint8, 6.5 KB) ≈ **125 KB**, allocated once and reused.
  * Binary heap: worst case one push per relaxation ⇒ ≤ 8 × 6 561 ≈ 52 k entries; two
    parallel FFI arrays (int32 index + double key) sized 65 536 ⇒ **768 KB**, also reused.
    Practical peak is ~4 k entries.
  * Time: ~50 k relaxations, each ~10 LuaJIT ops plus a `log2(n)` sift ⇒ **1.5-4 ms** per call
    on this machine. Total budget matters: `cavebot/actions.lua` fires 3-4 searches per goto
    tick and the cavebot macro runs every 20 ms (`cavebot/actions.lua:539` comment), so
    **cache the result field per (start, maxDist, paramsHash) for the current tick** and
    back off on failure exactly as vBot does (`min(100 + retries*50, 500)` ms,
    `cavebot/actions.lua:540`).
* Pure-table implementation (one Lua table per node) costs ~250 B/node ⇒ ~1.6 MB and a GC
  churn spike per call at 6 561 nodes. Acceptable for the 252-tile case, not for 40×40.
  Use the FFI arrays.

---

## 9. Explicitly: behaviour vs widget detail

**Behaviour (reimplement):** everything in §1-§6, the floor-change classifier, the goto
retry/precision ladder, the Manhattan `gotoMaxDistance` gate, the stairs detection, the
minimap-equivalent knowledge store.

**`[WIDGET]` (do not reimplement):** `CaveBot.Config.window`, the label/value panels
(`cavebot/config.lua:7-62,95-140`), `CaveBotList()`/`ui.list:getFocusedChild()` as the
"current action" cursor (replace with an array index + a `focused` integer), the waypoint HUD
(`waypointHud`), `context.getTileUnderCursor` (`functions/map.lua:228-237`), map-click mode's
dependence on `modules.game_interface`. `CaveBot.Config.get(k)` is just
`CaveBot.Config.values[k]`, which is exactly the `config:` JSON object — read it from the
`.cfg` file.

## Configuration format

TWO files matter for pathfinding configuration, plus one binary knowledge file.

============================================================================
(1) cavebot_configs/<name>.cfg  -- line-oriented "key:value"; the trailing
    `config:` / `extensions:` / `staypositions:` lines are JSON.
    Writer: cavebot/cavebot.lua:578-610. Reader: cavebot/cavebot.lua:207-282.
    REAL FILE, verbatim: profiles/bot/vBot_4.8/cavebot_configs/test.cfg
============================================================================
goto:33218,32434,7,0
exanihur:up,north
exanihur:down,south
config:{"ignoreFields":false,"skipBlocked":false,"antiLostLadderIds":"1948,1968,5542,7771,9116,20474,20475,21365,28656,31129,31130,31262,33770,34243,35908,43374,48493,48494,50122,50123,50564,50565,435,7750,21221,21298","ping":100,"antiLostRopeToolId":9596,"stayPathEnabled":true,"waypointHud":false,"walkDelay":10,"avoidTileIds":"","avoidFloorChange":true,"mapClickDelay":100,"useDelay":400,"wptDistance":5,"antiLostTeleportIds":"1949,1950,1951,1952","mapClick":false,"smoothWalk":false,"antiLostRopeIds":"386,7762,12935,12936,13381,33051","antiLostEnabled":true}
extensions:[]
staypositions:{"3":{"x":33218,"y":32433,"z":6},"2":{"x":33218,"y":32434,"z":7}}

  * every non-"config"/"extensions"/"staypositions" line is one waypoint:
    "<action>:<value>"; action order == execution order.
  * goto:x,y,z[,precision] -- the 4th field is OPTIONAL. Present => exact-arrival
    semantics with that Chebyshev-per-axis tolerance (0 = the exact tile);
    absent => tolerance 1 on the y axis only (cavebot/actions.lua:346-352, 359-433).
  * staypositions is keyed by the 1-based waypoint index AS A STRING.
  * pathfinding-relevant keys inside `config`, with defaults
    (cavebot/config.lua:26-61 + cavebot/walking.lua:34-37):
        ping                100    walkDelay          10
        mapClick            false  mapClickDelay      100
        ignoreFields        false  skipBlocked        false
        smoothWalk          false  avoidFloorChange   true
        avoidTileIds        ""     (comma-separated item ids)
        antiLostEnabled     true   wptDistance        5

============================================================================
(2) storage/profile_<n>.json  -- global bot storage (one JSON object).
    REAL VALUES from profiles/bot/vBot_4.8/storage/profile_1.json:
============================================================================
{
  "extras": {
    "gotoMaxDistance": 64,        <-- maxDist for every goto pathfind + the
                                      Manhattan pre-gate (actions.lua:385-390)
    "pathfinding": true,
    "machete": 9596, "shovel": 9596, "rope": 9596, "scythe": 9596,
    "killUnder": 1, "lootDelay": 220, "looting": 40, "autoOpenDoors": true
  },
  "targetbotAvoidFloorChange": true   <-- top level; absent means ENABLED
                                          (targetbot/walking.lua:36-38)
}

============================================================================
(3) <profile>/minimap.otmm  -- persistent 3-byte-per-tile map knowledge.
    Little-endian.  Writer minimap.cpp:930-985, reader minimap.cpp:656-743.
============================================================================
off  0  u32  0x4D4D544F  ("OTMM")
off  4  u16  dataStart   (22 for version 1)
off  6  u16  version     (1)
off  8  u32  flags       (0)
off 12  str  u16 len(8) + "OTMM 1.0"
off 22  repeated blocks, each:
          u16 blockX  (multiple of 64)
          u16 blockY  (multiple of 64)
          u8  z
          u16 compressedLen
          compressedLen bytes: zlib (compress2, level 3) of exactly 12288 bytes
            = 64*64 MinimapTile in index order ((y%64)*64 + (x%64)), each 3 bytes:
              u8 flags  (1=WasSeen 2=NotPathable 4=NotWalkable 8=Empty[never set])
              u8 color  (6x6x6 cube byte; 255 = none)
              u8 speed  (groundSpeed/10, ceil, clamped 255; effective speed = byte*10)
        end marker: u16 0xFFFF, u16 0xFFFF, u8 0xFF

============================================================================
(4) PROPOSED assets/items1530.bin v2 -- luaclient MUST extend its item table;
    v1 (tools/extract_appearances.py, 32-byte header + 1 flag byte per id)
    carries NO movement flags at all.  Suggested layout, backward-compatible
    by bumping `version` to 2 and `headerSize` to 40:
============================================================================
off  0  "LCIT" | u8 version=2 | u8 headerSize=40 | u16 categoryCount=4
off  8  u32 itemArrayLen | u32 creatureArrayLen | u32 effectArrayLen | u32 missileArrayLen
off 24  u32 objectCount | u16 contentRevision | u16 reserved
off 32  u32 walkTableOffset | u32 groundTableOffset
then:
  flags[itemArrayLen]      u8   (v1 bits, unchanged)
  walk[itemArrayLen]       u8   NEW, bit per appearance flag:
                                 0x01 GROUND     <- bank            (field 1, presence)
                                 0x02 UNPASS     <- unpass          (field 13)
                                 0x04 AVOID      <- avoid           (field 16)
                                 0x08 UNSIGHT    <- unsight         (field 15)
                                 0x10 ELEVATION  <- height          (field 27, presence)
                                 0x20 CLIP       <- clip            (field 2)  (groundBorder)
                                 0x40 BOTTOM     <- bottom          (field 3)
                                 0x80 TOP        <- top             (field 4)
  ground[itemArrayLen]     u16  bank.waypoints (0 when not a ground)
  automap[itemArrayLen]    u8   automap.color  (0 = none)
  lenshelp[itemArrayLen]   u16  lenshelp.id    (0 = none; 1104/1105 = stairs)
  size 40 + itemArrayLen*7 bytes = ~435 KB for itemArrayLen 62145.
  ("common" = not GROUND, not CLIP, not TOP, not BOTTOM, not a creature --
   needed verbatim by getMinimapColorByte.)

## Pseudocode

-- =====================================================================================
-- game/tileflags.lua  -- tile predicates over state.lua tiles + the v2 item table
-- Mirrors: tile.cpp:708-724 (isWalkable), tile.h:77 (isPathable),
--          tile.cpp:563-568 (getGroundSpeed), tile.cpp:571-584 (getMinimapColorByte),
--          tile.cpp:838-844 (hasBlockingCreature), tile.cpp:930-1013 (setThingFlag)
-- =====================================================================================
local items = require('proto.items')          -- extended: items.walk(id), items.ground(id),
                                              --           items.automap(id), items.lenshelp(id)
local W = items.WALK                          -- {GROUND=1,UNPASS=2,AVOID=4,UNSIGHT=8,
                                              --  ELEVATION=0x10,CLIP=0x20,BOTTOM=0x40,TOP=0x80}
local band = bit.band

local TF = {}

-- Only ITEMS contribute movement bits (tile.cpp:996 early-returns for non-items).
local function scan(st, tile)
    local f = tile._f
    if f and f.rev == tile._rev then return f end          -- memoised per mutation
    f = { rev = tile._rev, notWalkable=false, notPathable=false, blockProj=false,
          groundId=nil, elevation=0, color=255, hasCreature=false }
    local things = tile.things
    for i = 1, #things do
        local t = things[i]
        if t.kind == 'item' then
            local w = items.walk(t.id)
            if band(w, W.UNPASS)  ~= 0 then f.notWalkable = true end
            if band(w, W.AVOID)   ~= 0 then f.notPathable = true end
            if band(w, W.UNSIGHT) ~= 0 then f.blockProj   = true end
            if band(w, W.ELEVATION) ~= 0 then f.elevation = f.elevation + 1 end
            if i == 1 and band(w, W.GROUND) ~= 0 then f.groundId = t.id end   -- getThing(0)
        elseif t.kind == 'creature' then
            f.hasCreature = true
        end
    end
    -- getMinimapColorByte: reverse scan, skip creatures and "common" items, first non-zero.
    f.color = 255
    for i = #things, 1, -1 do
        local t = things[i]
        if t.kind == 'item' then
            local w = items.walk(t.id)
            local isCommon = band(w, W.GROUND + W.CLIP + W.TOP + W.BOTTOM) == 0
            if not isCommon then
                local c = items.automap(t.id)
                if c ~= 0 then f.color = c; break end
            end
        end
    end
    tile._f = f
    return f
end

function TF.groundSpeed(st, tile)                              -- tile.cpp:563-568
    local f = scan(st, tile)
    if not f.groundId then return 100 end
    local s = items.ground(f.groundId)
    return (s ~= 0) and s or 100          -- see PITFALL: every bank==0 ground is also unpass
end

function TF.isPathable(st, tile) return not scan(st, tile).notPathable end
function TF.minimapColor(st, tile) return scan(st, tile).color end
function TF.elevationCount(st, tile) return scan(st, tile).elevation end

function TF.isWalkable(st, tile, ignoreCreatures)              -- tile.cpp:708-724
    local f = scan(st, tile)
    if f.notWalkable or not f.groundId then return false end
    if not ignoreCreatures and f.hasCreature then
        for i = 1, #tile.things do
            local t = tile.things[i]
            if t.kind == 'creature' then
                local c = t.creatureId and st.creatures[t.creatureId]
                -- Creature::isPassable defaults FALSE; canBeSeen = not invisible or is player
                local passable = c and c.passable
                local canBeSeen = not (c and c.invisible) or (c and c.isPlayer)
                if not passable and canBeSeen then return false end
            end
        end
    end
    return true
end

function TF.hasBlockingCreature(st, tile)                      -- tile.cpp:838-844
    for i = 1, #tile.things do
        local t = tile.things[i]
        if t.kind == 'creature' and t.creatureId ~= st.player.id then
            local c = st.creatures[t.creatureId]
            if not (c and c.passable) then return true end
        end
    end
    return false
end


-- =====================================================================================
-- game/known.lua  -- the Minimap substitute.  3 bytes per tile, 64x64 blocks per floor.
-- Mirrors Minimap::updateTile (minimap.cpp:459-480) and the OTMM file (minimap.cpp:930-985).
-- =====================================================================================
local ffi = require('ffi')
local known = {}
known.WAS_SEEN, known.NOT_PATHABLE, known.NOT_WALKABLE, known.EMPTY = 1, 2, 4, 8
-- blocks[z][blockIndex] = ffi uint8_t[64*64*3]  (flags,color,speed interleaved)
-- blockIndex(pos) = (y/64)*1024 + (x/64)          minimap.h:167
-- tileIndex(x,y)  = (y%64)*64 + (x%64)            minimap.h:61

function known:update(st, pos, tile)                   -- call from the tile-description path
    local flags, color, speed = 0, 255, 10
    if tile then
        color = TF.minimapColor(st, tile)
        flags = known.WAS_SEEN
        if not TF.isWalkable(st, tile, true) then flags = flags + known.NOT_WALKABLE end
        if not TF.isPathable(st, tile)       then flags = flags + known.NOT_PATHABLE end
        speed = math.min(math.ceil(TF.groundSpeed(st, tile) / 10), 255)
    else
        flags = known.NOT_WALKABLE + known.NOT_PATHABLE
    end
    if not (flags == 0 and color == 255 and speed == 10) then   -- "!= nulltile"
        self:_write(pos, flags, color, speed)
    end
end

function known:get(pos)   -- returns flags, color, speed  (nulltile = 0, 255, 10)
    local b = self:_block(pos); if not b then return 0, 255, 10 end
    local i = ((pos.y % 64) * 64 + (pos.x % 64)) * 3
    return b[i], b[i+1], b[i+2]
end
-- known:loadOtmm(path) / known:saveOtmm(path) per the byte layout in configFormat (3).


-- =====================================================================================
-- game/heap.lua  -- binary min-heap on parallel FFI arrays (no GC, reused across calls)
-- =====================================================================================
local Heap = {}
Heap.__index = Heap
function Heap.new(cap)
    return setmetatable({ n = 0, cap = cap,
        key = ffi.new('double[?]', cap + 1),
        val = ffi.new('int32_t[?]', cap + 1) }, Heap)
end
function Heap:clear() self.n = 0 end
function Heap:push(v, k)
    local n = self.n + 1; self.n = n
    if n > self.cap then error('path heap overflow') end
    local key, val = self.key, self.val
    key[n], val[n] = k, v
    while n > 1 do
        local p = math.floor(n / 2)
        if key[p] <= key[n] then break end
        key[p], key[n] = key[n], key[p]; val[p], val[n] = val[n], val[p]; n = p
    end
end
function Heap:pop()
    local n = self.n; if n == 0 then return nil end
    local key, val = self.key, self.val
    local topv = val[1]
    key[1], val[1] = key[n], val[n]; self.n = n - 1; n = n - 1
    local i = 1
    while true do
        local l, r, m = i * 2, i * 2 + 1, i
        if l <= n and key[l] < key[m] then m = l end
        if r <= n and key[r] < key[m] then m = r end
        if m == i then break end
        key[i], key[m] = key[m], key[i]; val[i], val[m] = val[m], val[i]; i = m
    end
    return topv
end


-- =====================================================================================
-- game/pathfind.lua  -- exact port of Map::findEveryPath (map.cpp:1316-1473)
-- =====================================================================================
local DIAGONAL = 3.0                 -- gameconfig.h:125 / data/setup.otml:26  (NEVER hardcode 1.5)
local DEFAULT_UNKNOWN_SPEED = 1000   -- map.cpp:1405

-- Neighbour order MUST be this (map.cpp:1392-1395: i=-1..1 outer, j=-1..1 inner).
-- It is the tie-breaker that reproduces vBot's exact route.
local NB = { {-1,-1},{-1,0},{-1,1},{0,-1},{0,1},{1,-1},{1,0},{1,1} }   -- NW W SW N S NE E SE

-- Direction lookup replacing Position::getDirectionFromPositions (position.h:149-180).
-- Otc::Direction: N=0 E=1 S=2 W=3 NE=4 SE=5 SW=6 NW=7   (const.h:158-169)
local DIR = { [-1] = {[-1]=7, [0]=3, [1]=6},      -- dx=-1: NW, W, SW
              [ 0] = {[-1]=0,        [1]=2},      -- dx= 0: N,      S
              [ 1] = {[-1]=4, [0]=1, [1]=5} }     -- dx= 1: NE, E, SE

-- Grid is origin-relative: side = 2*maxDistance+1, idx = (gy*side + gx) + 1
-- Arrays are module-level and reused; only the touched cells are reset via a `stamp` array.
local A = {}    -- A.cost A.total A.prev A.dist A.state A.stamp  (FFI arrays, allocated on demand)

--- findEveryPath(st, known, start, maxDistance, p) -> field
---   p = { ignoreLastCreature=, ignoreCreatures=, ignoreNonPathable=, ignoreNonWalkable=,
---         ignoreStairs=, ignoreCost=, allowUnseen=, allowOnlyVisibleTiles=,
---         destination={x,y,z}, maxDistanceFrom={pos, range}, hasMargin=bool }
---   field[idx] = { total, dist, dir, prevIdx }   (idx-keyed; convert to "x,y,z" only if a
---                 caller wants the C++-compatible string map)
local function findEveryPath(st, known, start, maxDistance, p)
    local side  = 2 * maxDistance + 1
    local ox, oy = start.x - maxDistance, start.y - maxDistance
    local z = start.z
    ensureArrays(side * side)
    local stamp = nextStamp()
    local heap = getHeap(); heap:clear()

    local function idxOf(x, y)
        local gx, gy = x - ox, y - oy
        if gx < 0 or gy < 0 or gx >= side or gy >= side then return nil end
        return gy * side + gx + 1
    end

    local si = idxOf(start.x, start.y)
    A.stamp[si] = stamp; A.state[si] = 1       -- 1 = open node, 0 = blocked(nil), nil = unvisited
    A.cost[si], A.total[si], A.prev[si], A.dist[si] = 1, 0, 0, 0
    heap:push(si, 0)

    local field = {}
    local destIdx = p.destination and p.destination.z == z
                    and idxOf(p.destination.x, p.destination.y) or nil
    local maxDist = maxDistance

    while true do
        local ni = heap:pop(); if not ni then break end
        local nx, ny = ox + (ni - 1) % side, oy + math.floor((ni - 1) / side)
        local pi = A.prev[ni]
        field[ni] = { A.total[ni], A.dist[ni],
                      pi ~= 0 and A.dirIn[ni] or -1,
                      pi ~= 0 and pi or nil }                       -- map.cpp:1380-1382

        if ni == destIdx then                                       -- map.cpp:1383-1389
            if p.hasMargin then maxDist = math.min(A.dist[ni] + 4, maxDist)
            else break end
        end
        if A.dist[ni] >= maxDist then goto continue end             -- map.cpp:1390 (no goto in
                                                                    -- 5.1: use an if-block)

        for k = 1, 8 do
            local i, j = NB[k][1], NB[k][2]
            local x, y = nx + i, ny + j
            if x >= 0 and y >= 0 then                               -- map.cpp:1397
                local mi = idxOf(x, y)
                if mi then
                    if A.stamp[mi] ~= stamp then                    -- first visit: classify
                        A.stamp[mi] = stamp
                        local wasSeen, hasCreature = false, false
                        local notWalk, notPath = true, true
                        local color, speed = 0, DEFAULT_UNKNOWN_SPEED
                        local pos = { x = x, y = y, z = z }
                        if st:isAwareOf(pos) then                   -- map.cpp:1406
                            local tile = st:tile(pos)
                            if tile then
                                wasSeen     = true
                                hasCreature = TF.hasBlockingCreature(st, tile)
                                notWalk     = not TF.isWalkable(st, tile, true)  -- ignoreCreatures!
                                notPath     = not TF.isPathable(st, tile)
                                color       = TF.minimapColor(st, tile)
                                speed       = TF.groundSpeed(st, tile)
                            end
                        elseif not p.allowOnlyVisibleTiles then     -- map.cpp:1415
                            local f, c, sp = known:get(pos)
                            wasSeen = band(f, known.WAS_SEEN)      ~= 0
                            notWalk = band(f, known.NOT_WALKABLE)  ~= 0
                            notPath = band(f, known.NOT_PATHABLE)  ~= 0
                            color   = c
                            if notWalk or notPath then wasSeen = true end   -- map.cpp:1421-1422
                            speed   = sp * 10                                -- minimap.h:47
                        end
                        local hasStairs = notPath and color >= 210 and color <= 213
                        local tooFar = false
                        if p.maxDistanceFrom then
                            local a, r = p.maxDistanceFrom[1], p.maxDistanceFrom[2]
                            local dx, dy = a.x - x, a.y - y
                            tooFar = math.sqrt(dx*dx + dy*dy) > r    -- EUCLIDEAN (map.cpp:1430)
                        end
                        local isDest = (mi == destIdx)
                        if (not wasSeen and not p.allowUnseen)
                           or (hasStairs and not p.ignoreStairs      and not isDest)
                           or (notPath   and not p.ignoreNonPathable and not isDest)
                           or (notWalk   and not p.ignoreNonWalkable)      -- no dest exemption!
                           or tooFar then
                            A.state[mi] = 0                          -- blocked forever
                        elseif hasCreature and not p.ignoreCreatures then
                            A.state[mi] = 0
                            if p.ignoreLastCreature then             -- map.cpp:1437-1440
                                field[mi] = { A.total[ni] + 100, A.dist[ni] + 1,
                                              DIR[i][j], ni }
                            end
                        else
                            A.state[mi] = 1
                            A.cost[mi]  = speed
                            A.total[mi] = 1e7
                            A.prev[mi]  = ni
                            A.dist[mi]  = A.dist[ni] + 1
                        end
                    end
                    if A.state[mi] == 1 then
                        local diagonal = (i == 0 or j == 0) and 1.0 or DIAGONAL
                        local cost = p.ignoreCost and 1 or (A.cost[mi] * diagonal)
                        local nt = A.total[ni] + cost
                        if nt < A.total[mi] then                     -- map.cpp:1455
                            A.total[mi] = nt
                            A.prev[mi]  = ni
                            A.dirIn[mi] = DIR[i][j]
                            A.dist[mi]  = A.dist[ni] + 1
                            heap:push(mi, nt)
                        end
                    end
                end
            end
        end
        ::continue::
    end
    return field, idxOf, side, ox, oy
end


-- =====================================================================================
-- game/pathfind.lua (cont.) -- port of functions/map.lua:137-210 (findPath / getPath)
-- =====================================================================================
local function translate(field, idx)                    -- functions/map.lua:110-134
    local rev = {}
    while idx do
        local n = field[idx]; if not n then break end
        if n[3] < 0 then break end
        rev[#rev + 1] = n[3]
        idx = n[4]
    end
    local dirs = {}
    for i = #rev, 1, -1 do dirs[#dirs + 1] = rev[i] end
    return dirs
end

function pathfind.getPath(st, known, startPos, destPos, maxDist, params)
    if not destPos or startPos.z ~= destPos.z then return nil end   -- map.lua:150-152
    maxDist = tonumber(maxDist) or 100                              -- map.lua:156-158
    local p = normalise(params)                                     -- false/nil -> falsy;
                                                                    -- anything else -> truthy
    p.destination = destPos
    p.hasMargin = (params.marginMin ~= nil or params.marginMax ~= nil
                   or params.minMargin ~= nil or params.maxMargin ~= nil)
    local field, idxOf = findEveryPath(st, known, startPos, maxDist, p)

    local mMin = params.marginMin or params.minMargin
    local mMax = params.marginMax or params.maxMargin
    if type(mMin) == 'number' and type(mMax) == 'number' then       -- map.lua:165-186
        local best, bestIdx
        for dx = -mMax, mMax do for dy = -mMax, mMax do
            if math.abs(dx) >= mMin or math.abs(dy) >= mMin then
                local i = idxOf(destPos.x + dx, destPos.y + dy)
                local n = i and field[i]
                if n and (not best or best[1] > n[1]) then best, bestIdx = n, i end
            end
        end end
        return bestIdx and translate(field, bestIdx) or nil
    end

    local di = idxOf(destPos.x, destPos.y)
    if not (di and field[di]) then                                  -- map.lua:189-208
        local prec = params.precision
        if type(prec) == 'number' then
            for r = 1, prec do
                local best, bestIdx
                for dx = -r, r do for dy = -r, r do                 -- FULL SQUARE, not a ring
                    local i = idxOf(destPos.x + dx, destPos.y + dy)
                    local n = i and field[i]
                    if n and (not best or best[1] > n[1]) then best, bestIdx = n, i end
                end end
                if bestIdx then return translate(field, bestIdx) end
            end
        end
        return nil
    end
    return translate(field, di)
end


-- =====================================================================================
-- Floor-change guard (cavebot/walking.lua:118-205) -- run on EVERY path before walking
-- =====================================================================================
local FLOOR_CHANGE_LENSHELP = { [1104] = true, [1105] = true }   -- stairs up / stairs down only

local function itemChangesFloor(st, id, isGroundSlot)
    if FLOOR_CHANGE_LENSHELP[items.lenshelp(id)] then return true end
    if isGroundSlot and band(items.walk(id), W.AVOID) ~= 0 then return true end
    return false
end

function pathfind.isFloorChangeTile(st, known, pos, avoidIds)
    local tile = st:tile(pos)
    if not tile then return false end                 -- unseen: trust the stairs rule
    local color = TF.minimapColor(st, tile)
    if color == 255 then local _, c = known:get(pos); color = c end   -- Map::getMinimapColor
    if color >= 210 and color <= 213 and not TF.isPathable(st, tile) then
        return true, 'stairs (yellow, not pathable)'
    end
    local g = tile.things[1]
    if g and g.kind == 'item' and itemChangesFloor(st, g.id, true) then
        return true, 'floor-change ground id ' .. g.id
    end
    local top = topUseThing(tile)                     -- tile.cpp:~690: first non-ground, non-onTop
    if top and top ~= g and itemChangesFloor(st, top.id, false) then
        return true, 'floor-change item id ' .. top.id
    end
    for _, id in ipairs(avoidIds) do
        if (g and g.id == id) or (top and top.id == id) then return true, 'listed id ' .. id end
    end
    return false
end

function pathfind.pathCrossesFloorChange(st, known, fromPos, dest, path, avoidIds)
    local x, y = fromPos.x, fromPos.y
    for i = 1, #path do
        local d = DELTA[path[i]]; if not d then break end
        x, y = x + d.x, y + d.y
        if not (x == dest.x and y == dest.y) then
            local bad, why = pathfind.isFloorChangeTile(st, known,
                                                        {x=x, y=y, z=fromPos.z}, avoidIds)
            if bad then return true, why end
        end
    end
    return false
end


-- =====================================================================================
-- Wiring into luaclient
-- =====================================================================================
-- 1. proto/parser.lua tile-description path: after every st:setTile / st:addThing that
--    touches an ITEM, call known:update(st, pos, st:tile(pos)); on cleanTile with no tile,
--    call known:update(st, pos, nil).   (mirrors map.cpp:114-127 and :438)
-- 2. main.lua boot: known:loadOtmm(profileDir .. '/minimap.otmm'); on shutdown, saveOtmm.
-- 3. Bump assets/items1530.bin to v2 (see configFormat) and extend proto/items.lua with
--    items.walk / items.ground / items.automap / items.lenshelp.
-- 4. Invalidate tile._f whenever state.lua mutates tile.things (bump tile._rev in addThing,
--    _removeAt and setTile).
-- 5. Cache the findEveryPath field per tick: key on (startIdx, maxDist, paramsHash) and drop
--    it at the end of the scheduler turn -- goto issues 3-4 identical searches per tick.

## Evidence
- D:/Claude/otclient_mehah1530/otclient/src/client/map.cpp:1316-1473 -- Map::findEveryPath, the ONLY pathfinder vBot uses. Node init {1,0,start,nullptr,0,0} at :1373; pop/record at :1378-1382; destPos break / margin+4 at :1383-1389; maxDistance step cutoff at :1390; neighbour double loop i=-1..1 / j=-1..1 at :1392-1395; classification defaults (wasSeen=false, notWalkable=true, notPathable=true, mapColor=0, speed=1000) at :1400-1405; aware-tile branch at :1406-1414; minimap branch at :1415-1424 incl. 'blocked implies wasSeen' at :1421-1422; hasStairs = notPathable AND colour 210-213 at :1429 with the rationale comment at :1425-1428; the full block predicate at :1431-1433; ignoreLastCreature +100 entry at :1435-1441; node creation cost=speed, totalCost=1e7 at :1443; diagonal = getPlayerDiagonalWalkSpeed() at :1451; ignoreCost=1 at :1453-1454; relaxation at :1455-1462.
- D:/Claude/otclient_mehah1530/otclient/src/client/map.cpp:831-1003 -- Map::findPath (flag variant): SNode/LessNode :835-852; SamePosition :859-862; Impossible :864-867; goal walkability pre-check incl. the minimap fallback :869-880; maxComplexity node cap :890-893; 'cost too high' early break :899-900; per-neighbour defaults speed=100 :907-911; aware branch sets wasSeen=true even when the tile pointer is null :915-923; flag filters for non-goal :934-946 and for the goal :947-953; walkFactor 3.0 for dir>=NorthEast else 1.0 :954-958; cost = prev.cost + (speed*walkFactor)/100 :959; totalCost = cost + euclidean distance to goal :971; path reconstruction with pop_back + reverse :986-996.
- D:/Claude/otclient_mehah1530/otclient/src/client/map.cpp:1011-1166 -- Map::newFindPath / findPathAsync: minimap-only reads via threadGetTile :1082; Empty/NotWalkable/NotPathable -> nil :1086-1089; unseen speed 2000 :1091-1092; unseen>50 cutoff :1098-1099; cost = speed*diagonal + diagonal*50*max(5, dist) :1101-1103; +50 relaxation margin :1104; limit 50000 :1062, complexity = 50000-limit :1129; path cleared on any unseen node :1119-1123; visibleNodes snapshot of the start floor :1141-1160.
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:692-708 -- PathFindResult {Ok=0,SamePosition,Impossible,TooFar,NoWay} and PathFindFlags {AllowNotSeenTiles=1, AllowCreatures=2, AllowNonPathable=4, AllowNonWalkable=8, IgnoreCreatures=16}. const.h:158-169 -- Otc::Direction N=0,E=1,S=2,W=3,NE=4,SE=5,SW=6,NW=7,Invalid=8. const.h:1247-1303 -- ThingFlagAttr bit numbers (Ground=1<<0, NotWalkable=1<<13, BlockProjectile=1<<15, NotPathable=1<<16, Elevation=1<<26, MinimapColor=1<<29, FullGround=1<<31, Look=1<<32, FloorChange=1<<48). const.h:1545-1573 -- TileThingType bits (FULL_GROUND=1<<0, NOT_WALKABLE=1<<1, NOT_PATHABLE=1<<2, BLOCK_PROJECTTILE=1<<4, HAS_CREATURE=1<<17, ...).
- D:/Claude/otclient_mehah1530/otclient/src/client/tile.h:71-130 and tile.cpp:527-584, 708-724, 783-802, 838-844, 930-1013 -- isPathable = !(flags & NOT_PATHABLE) (tile.h:77); isLookPossible = !(flags & BLOCK_PROJECTTILE) (tile.h:81); hasCreatures = flags & HAS_CREATURE (tile.h:94); hasElevation(e) = m_elevation >= e (tile.h:129); getGround = getThing(0) if isGround (tile.cpp:537); getGroundSpeed falls back to 100 (tile.cpp:563-568); getMinimapColorByte reverse scan skipping creatures and common items, default 255 (tile.cpp:571-584); isWalkable (tile.cpp:708-724); hasBlockingCreature excludes the local player (tile.cpp:838-844); setThingFlag returns early for non-items at tile.cpp:996 so ONLY items set NOT_WALKABLE/NOT_PATHABLE/BLOCK_PROJECTTILE/FULL_GROUND and increment m_elevation (tile.cpp:998-1012).
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtype.cpp:177-380 (applyAppearanceFlags) mapped against src/protobuf/appearances.proto:142-210 -- bank(1)->Ground + m_groundSpeed=bank.waypoints (thingtype.cpp:179-182); clip(2)->GroundBorder; bottom(3)->OnBottom; top(4)->OnTop; unpass(13)->NotWalkable (:230-232); unmove(14)->NotMoveable; unsight(15)->BlockProjectile (:238-240); avoid(16)->NotPathable (:242-244); shift(26)->Displacement; height(27)->Elevation + m_elevation (:302-304); automap(30)->m_minimapColor (:315-317); lenshelp(31)->m_lensHelp (:319-322); fullbank(32)->FullGround (:325-327); ignore_look(33)->Look (:329-331). ThingFlagAttrFloorChange is set ONLY by the legacy .dat path (thingtype.cpp:1096) and never by applyAppearanceFlags -- grep over src/client confirms three hits, none of them a protobuf assignment -- so Tile::hasFloorChange() is permanently false on 1530 assets.
- D:/Claude/otclient_mehah1530/otclient/src/client/minimap.h:29-51 -- MMBLOCK_SIZE 64, MinimapTileFlags {WasSeen=1, NotPathable=2, NotWalkable=4, Empty=8}, MinimapTile{flags, color=255, speed=10}, getSpeed() = speed*10. minimap.h:144-167 -- hasBlock/getBlock/getBlockOffset/getIndexPosition/getBlockIndex = (y/64)*1024 + (x/64). minimap.cpp:51 nulltile; :459-480 updateTile (WasSeen, isWalkable(true), isPathable, speed = min(ceil(groundSpeed/10),255), null tile -> NotWalkable|NotPathable); :482-490 getTile returns nulltile outside known blocks; :506-578 loadImage colour tables (dead for the walk/pathable lists: both loops are guarded by `if (flags != 0)` before any flag is set, minimap.cpp:542,550). MinimapTileEmpty is read only at map.cpp:1086 and written nowhere.
- D:/Claude/otclient_mehah1530/otclient/src/client/minimap.cpp:656-743 (readOtmm) and :930-985 (saveOtmm) -- OTMM header u32 signature 0x4D4D544F, u16 dataStart, u16 version=1, u32 flags, string 'OTMM 1.0' (=> dataStart 22); per block u16 x, u16 y, u8 z, u16 compressedLen, then zlib(level 3) of 64*64*3 = 12288 bytes; end marker 0xFFFF/0xFFFF/0xFF. Constants at minimap.cpp:65-70. Live file: otclient/profiles/minimap.otmm, written by modules/game_minimap/minimap.lua:139.
- D:/Claude/otclient_mehah1530/otclient/src/framework/util/color.h:94-110 -- the minimap colour byte is a 6x6x6 cube: c = (r/51)*36 + (g/51)*6 + (b/51); so 210 = (255,255,0) pure yellow, 211..213 add blue 51/102/153. This is what the 210-213 stairs range means.
- D:/Claude/otclient_mehah1530/otclient/src/client/position.h:149-188, 219-228, 249-252, 259-265 -- getDirectionFromPositions via atan2(-dy,dx) with 22.5-degree sectors; distance() is EUCLIDEAN (sqrt of dx^2+dy^2) and is what map.cpp:1430 (maxDistanceFrom) and map.cpp:971 (findPath heuristic) use; manhattanDistance is separate; toString() = 'x,y,z'; Hasher = ((x*8192)+y)*16+z.
- D:/Claude/otclient_mehah1530/otclient/src/client/map.cpp:776-798 (isAwareOfPosition: floor range test then coveredUp/coveredDown projection then isInRange with the aware rectangle) and :815-829 (getFirstAwareFloor/getLastAwareFloor). Already ported at D:/Claude/otclient_web/luaclient/game/state.lua:356-407.
- D:/Claude/otclient_mehah1530/otclient/src/client/gameconfig.h:69,125 (m_playerDiagonalWalkSpeed default 3) and D:/Claude/otclient_mehah1530/otclient/data/setup.otml:26,29 (diagonal-walk-speed: 3) -- the diagonal multiplier for this deployment is 3.0, not 1.5 or sqrt(2).
- D:/Claude/otclient_mehah1530/otclient/mods/game_bot/functions/map.lua:76-226 -- findAllPaths/findEveryPath wrapper converting false/nil->0 and true->1 (:93-99) and maxDistanceFrom table->'x,y,z,range' (:100-108); translateAllPathsToPath reading node[3]/node[4] (:110-134); findPath/getPath with the z-guard (:150-152), maxDist default 100 (:156-158), destination injection (:162-163), margin ring scan (:165-186), precision full-square fallback (:189-208); autoWalk (:212-226); isTrapped (:249-262).
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/cavebot/actions.lua:345-541 -- the goto action: precision marker parsing (:346-352), retry caps 5 (mapClick) / 100 (:361-373), gotoMaxDistance Manhattan gate (:385-390), stairs detection via minimap colour 210-213 (:393-395), the final-approach single-step path with precision 0 (:418), and the exact parameter tables of the four fallback searches (:436, :449, :501, :506, :518, :536) plus the retry back-off min(100+retries*50, 500) (:540).
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/cavebot/walking.lua:34-37 (config rows smoothWalk/avoidFloorChange/avoidTileIds), :57-76 (the C++ stairs rule explained, and why Tile::hasFloorChange is useless on 1530), :96-100 (FLOOR_CHANGE_LENSHELP = {1104,1105} only), :118-127 (itemChangesFloor: lenshelp 1104/1105, or an 'avoid' GROUND), :132-165 (isFloorChangeTile), :170-180 (wouldStepChangeFloor), :185-205 (pathCrossesFloorChange), :430-449 (the autowalk truncation mirroring modules/game_walk/walk.lua:74-79), :465-500 (CaveBot.walkTo).
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/cavebot/config.lua:26-61 -- the complete CaveBot.Config defaults (ping 100, walkDelay 10, mapClick false, mapClickDelay 100, ignoreFields false, skipBlocked false, useDelay 400, wptDistance 5, antiLost* lists, stayPathEnabled true, waypointHud false); :93-96 Config.save() returns the values table verbatim, which is what lands in the `config:` JSON line.
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/cavebot/cavebot.lua:207-282 (config parsing: config / extensions / staypositions blobs, stayPositions keyed by the 1-based action index as a string) and :578-610 (CaveBot.save building exactly those three trailing lines). Real file example: profiles/bot/vBot_4.8/cavebot_configs/test.cfg.
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/storage/profile_1.json -- extras.gotoMaxDistance = 64 (the maxDist of every goto search and the Manhattan pre-gate), extras.pathfinding = true, extras.machete/shovel/rope/scythe = 9596, extras.killUnder = 1. targetbotAvoidFloorChange is a sibling top-level key (targetbot/walking.lua:36-38 defaults it to enabled when absent).
- Measured over D:/Claude/otclient_mehah1530/otclient/data/things/1530/appearances-17a72b30b5c3c9ca8c1283cfb2febd2a93a145ff8ab66916f7a412d0f1dee5a1.dat (43536 object appearances) with a protobuf walk reusing luaclient/tools/extract_appearances.py: unpass 16697, unsight 5925, avoid 2055, bank(ground) 3354, automap 15777, fullbank 2958, height/elevation 2194, lenshelp 981. Grounds that are also unpass: 496; grounds that are avoid: 249. bank.waypoints value set {0,1,50,70,90,95,100,110,115,120,121,125,130,140,150,160,170,180,200,250,260,300,350,400,450,500,800,850,1000,1200}; all 273 items with waypoints==0 are also unpass. automap colours present in 205..215: only 207 (301), 210 (972), 215 (115) -- 545 of the 972 yellow items also carry avoid; 211/212/213 do not occur in this asset set. lenshelp histogram: 1100:22 1101:4 1102:6 1103:38 1104:422 1105:122 1106:19 1107:6 1108:11 1109:2 1110:8 1111:194 1112:127.
- D:/Claude/otclient_web/luaclient/tools/extract_appearances.py:20-60 and D:/Claude/otclient_web/luaclient/API.md:118-135 -- the CURRENT items1530.bin carries only CUMULATIVE/WEAROUT/EXPIRE/CONTAINER/CLASSIFY/PODIUM/DECOKIT. None of unpass/avoid/unsight/bank/height/automap/lenshelp is extracted, which is why game/state.lua:517-537 documents walkableAt as unable to see blocking items. The extractor must be extended before any of this spec can run.
- D:/Claude/otclient_web/luaclient/game/state.lua:160 (default awareRange left=8 top=6 right=9 bottom=7 -> 18x14 = 252 tiles), :170-216 (tile store shape: map['x,y,z'] = {pos, things={{kind,id,count,tier,creatureId}}}), :356-407 (isAwareOf port), :409-435 (setCentralPosition evicts everything outside the aware range -- there is no persistent knowledge today), :510-563 (walkableAt and its four reason strings).
- D:/Claude/otclient_web/luaclient/proto/sender.lua:79-113, 298-330 -- DIR already uses Otc::Direction numbering (N=0..NW=7), so a returned path plugs straight into sender:walk(dir); sender:autoWalk(dirs) re-encodes to the wire order E=1..SE=8 and clamps to 127 steps, matching Game::autoWalk (client/game.cpp:683-711) and LocalPlayer::autoWalk's resize to 127 (client/localplayer.cpp:244-245).
- vBot call-site parameter tables, verbatim: cavebot/actions.lua:80,418,436,449,468,501,506,518,536; cavebot/antilost.lua:205,458,469,530,577,583; cavebot/cavebot.lua:145,368,389; cavebot/stand_lure.lua:89,90,112,138; targetbot/target.lua:70; targetbot/creature_attack.lua:161,163,170,176,184,186,204,230; targetbot/looting.lua:169,330; navibot/navibot.lua:514; vBot/vlib.lua:952,962; vBot/new_cavebot_lib.lua:229,247,264,278,349; vBot/combo.lua:382. ignoreNonWalkable is never passed anywhere; ignoreStairs is never passed truthy; ignoreFields (stand_lure.lua:89,90,138) is not a recognised C++ key (the full list is map.cpp:1327-1347) and is therefore a no-op.

## Pitfalls
- The diagonal multiplier is 3.0, not 1.5 or sqrt(2). g_gameConfig.getPlayerDiagonalWalkSpeed() defaults to 3 (gameconfig.h:125) and data/setup.otml:26,29 confirms 3 for this deployment. Using 1.414 makes the bot prefer diagonals the real client avoids and produces different routes from the same waypoints.
- findEveryPath is pure Dijkstra with NO heuristic (map.cpp:1455 relaxes on node.totalCost + cost only). Adding an A* heuristic changes which tiles land in the returned FIELD, and callers depend on the field being complete: the precision and margin fallbacks in functions/map.lua:165-208 look up arbitrary tiles around the destination that a goal-directed search would never expand.
- The neighbour iteration order (i=-1..1 outer, j=-1..1 inner => NW, W, SW, N, S, NE, E, SE) is a real tie-breaker, not an implementation detail. `ret` records the LAST relaxation's prev, so a different order yields a different (equal-cost) path and therefore different floor-change-guard verdicts.
- isNotWalkable has NO destination exemption (map.cpp:1432) while isNotPathable and hasStairs both do. Do not 'tidy' the condition into a uniform `neighbor != destPos` guard: it would let the bot path onto walls.
- A neighbour is classified exactly ONCE, at first discovery, and the verdict is cached in `nodes` forever (map.cpp:1399-1445). A tile refused because it was reached first as a non-destination is never reconsidered. Re-classifying per relaxation gives different (better) paths than the real client, which is a behaviour change.
- Tile::isWalkable(true) -- ignoreCreatures TRUE -- is what findEveryPath calls (map.cpp:1410); creatures are handled separately through hasBlockingCreature (map.cpp:1409), which unlike isWalkable's loop EXCLUDES the local player (tile.cpp:838-844) and ignores canBeSeen(). Wiring creatures into one predicate breaks both the standing-on-your-own-tile case and invisible creatures.
- Creature::isPassable defaults to FALSE (client/creature.h:146; the 0x92 CreatureUnpass packet is what sets it), so an unknown creature blocks. game/state.lua:544-551 already encodes this; keep it.
- The stairs rule is `notPathable AND colour in 210..213` (map.cpp:1429). Upstream OTCv8/mehah use colour alone; this repo carries a deliberate patch (the rationale comment sits at map.cpp:1425-1428 and again at cavebot/walking.lua:57-76) because colour alone made whole staircases unreachable. Port the patched form. Only colour 210 actually exists in this asset set (972 items, 545 of them `avoid`).
- Tile::hasFloorChange() is ALWAYS false on 1530 assets: ThingFlagAttrFloorChange is only set by the legacy .dat unserialiser (thingtype.cpp:1096), never by applyAppearanceFlags. Any hole avoidance built on it silently does nothing; use the lenshelp 1104/1105 + `avoid` ground + yellow&non-pathable classifier from cavebot/walking.lua:118-165 instead.
- `ignoreFields` is not a real parameter. map.cpp:1327-1347 enumerates every key findEveryPath reads; cavebot/stand_lure.lua:89,90,138 passes ignoreFields and it is discarded. Field avoidance IS ignoreNonPathable, because magic fields are items carrying `avoid` (field 16) and not `unpass`.
- Parameter truthiness is `value != "0" && value != ""` on strings (map.cpp:1328-1343). functions/map.lua:93-99 converts false/nil to 0 first. If a Lua port passes the raw table through, the string "false" would be TRUE. Normalise explicitly.
- hasMargin is PRESENCE-based, not value-based (map.cpp:1344-1347). {marginMin = 0} switches the search into margin mode (maxDistance = min(dist+4, maxDistance) instead of an early break) even though 0 looks like 'off'.
- Three different distance metrics are in play and mixing them is silent: maxDistanceFrom uses euclidean (map.cpp:1430), the goto pre-gate uses Manhattan (cavebot/actions.lua:385-390), and precision/margin/arrival use Chebyshev per axis (functions/map.lua:170-206, cavebot/actions.lua:399-401).
- `precision` never reaches C++. It is a Lua post-filter that scans the FULL square [-p,p]^2 (functions/map.lua:194-204), not a ring. precision = 0 therefore means 'exact tile or nothing', which is what the stairs/precision-marker waypoints rely on.
- The C++ priority queue compares the live, mutable node->totalCost (map.cpp:1319-1325), violating the heap invariant on decrease-key. Reproduce the RESULT (lazy decrease-key: push a (node, keyAtPushTime) pair and skip stale pops) rather than the mechanism; a strict-invariant heap is fine, a 'fixed' version that re-heapifies on mutation is not needed.
- findEveryPath has no node-count cap. maxDistance bounds step count, so the explored set is bounded by (2*maxDistance+1)^2; with maxDistance = 100 (the Lua default when the caller omits it, functions/map.lua:156-158) that is 40401 cells. Size the Lua arrays from maxDistance and add an explicit node cap; do not let a stray getPath(pos, dest) with no maxDist allocate a 40k-cell grid every tick.
- The minimap's tile record is written with isWalkable(TRUE) (minimap.cpp:465), i.e. creature-independent, and a tile the client has forgotten writes NotWalkable|NotPathable with colour 255 (minimap.cpp:470-472). A Lua `known` store that records creature-dependent walkability would permanently poison the cache the first time a monster stood on a corridor tile.
- MinimapTile.speed is groundSpeed/10 rounded UP and clamped to 255 (minimap.cpp:469); getSpeed() multiplies by 10 again (minimap.h:47). Round-tripping loses up to 9 speed units per tile and caps at 2550 -- costs from minimap tiles will not exactly match costs from live tiles for the same ground.
- With no `known` store at all, nulltile has flags == 0, so isNotWalkable and isNotPathable come back FALSE and only wasSeen is false. With allowUnseen = true (which the goto path passes, cavebot/actions.lua:436,506,518,536) every unexplored tile becomes free at speed 100 and the bot plans straight through walls it has never seen. Either implement the store or never pass allowUnseen.
- MinimapTileEmpty (8) is checked at map.cpp:1086 but is written by nothing in the codebase. Do not invent a producer for it; treat it as always 0.
- getGroundSpeed can legitimately be 0 -- has_bank() sets Ground even when waypoints == 0 (thingtype.cpp:179-182), and 273 items in this asset set have waypoints 0. All 273 are also `unpass`, so a zero-cost step is unreachable in practice; but if you clamp speed to >= 1 you will diverge from the C++ on any custom asset that breaks that coincidence. Mirror the C++ (no clamp) and rely on the unpass check.
- Tile::getGround() requires the ground to be at STACK INDEX 0 specifically (tile.cpp:537, getThing(0)). game/state.lua's addThing already reproduces the stack-priority insertion, but any shortcut that scans all things for a GROUND flag will call tiles walkable that the C++ calls groundless.
- getMinimapColorByte skips creatures AND 'common' items (tile.cpp:571-584); isCommon = not ground, not groundBorder, not onTop, not onBottom, not creature (thing.h:67). Dropped loot lying on a stair tile must not change its minimap colour, or the stairs rule flips.
- Map::findPath (variant B) sets wasSeen = true for an aware position even when getTile returns nullptr (map.cpp:915-916), while findEveryPath leaves wasSeen false in the same situation (map.cpp:1406-1414). The two pathfinders genuinely disagree about holes in the aware window; do not share the classification helper between the ports.
- cavebot/actions.lua fires 3-4 synchronous findPath calls per goto tick on a 20 ms macro (the comment at actions.lua:539 exists because a missing back-off made this pathological). A Lua port must cache the field per tick and keep the min(100 + retries*50, 500) ms back-off, or the scheduler will starve the socket loop.

## Open questions
- Does the target client intend to persist map knowledge at all? Nothing in API.md or game/state.lua provides it, and without a MinimapTile-equivalent store no goto beyond the 18x14 aware window can work the way vBot's does. Confirm that `game/known.lua` (or an equivalent) is in scope before the pathfinder is written -- it changes the item-table extension, the parser hooks and the boot sequence.
- Should the `known` store read and write the real client's <profile>/minimap.otmm, or keep its own file? Sharing gives an instantly-seeded map (the 11.4k-block file already exists) but means two processes writing the same file; the C++ side guards that with a cross-process lock and a read-merge-publish cycle (minimap.cpp:861-928) that a Lua writer would have to reproduce. Read-only sharing plus a separate write file is the safer default -- confirm.
- The items1530.bin v2 layout in configFormat is a proposal. Confirm the field set (walk byte, ground u16, automap u8, lenshelp u16 = 7 bytes/id, ~435 KB) and whether lenshelp is wanted at all -- it is needed only by the floor-change classifier, not by the pathfinder proper, and could be shipped as a small id->group side table instead of a full array.
- Is `Creature.invisible` (outfit.isEffect() && auxId == 13, creature.h:152) available in game/state.lua's creature records? Tile::isWalkable's creature loop needs canBeSeen(), and state.lua currently exposes only `passable`. If invisibility is not parsed, the port must decide between 'invisible creatures always block' (safer, diverges) and 'always visible' (matches the common case).
- Which of the three pathfinders should the headless bot expose? The spec assumes findEveryPath only. If map-click autowalk is ever wanted, newFindPath (variant C) has materially different semantics -- minimap-only, unseen tiles cost 2000 instead of being refused, and the reconstruction discards the path prefix on any unseen node -- and reimplementing it means also porting the client's async/retry ladder (localplayer.cpp:230-258).
- The 210-213 stairs rule and the avoidFloorChange guard are local patches in this repo, not upstream vBot. Confirm the headless client should carry the patched behaviour (recommended: it is the behaviour the live cavebot configs were tuned against) rather than the stock colour-only rule.
- Should the returned path be an array of Otc::Direction (matching vBot and sender.lua) or a list of positions? Directions are what sender:walk/autoWalk take, but the floor-change guard has to re-derive positions from them (walking.lua:185-205); carrying both would remove a class of off-by-one bugs at the cost of diverging from the vBot contract.
- What is the acceptable per-tick pathfinding budget on the target hardware? The 40x40 estimate (1.5-4 ms per search, 3-4 searches per goto tick on a 20 ms macro) is projected, not measured on luaclient. If it does not fit, the cheapest fix is to raise the cavebot tick and cache the field across ticks while the player has not moved -- both are behaviour changes vBot does not make.

## VERIFIER (confidence 0.88)

### Corrections (AUTHORITATIVE)
- **Claim**: PSEUDOCODE: `p.hasMargin = (params.marginMin ~= nil or params.marginMax ~= nil or params.minMargin ~= nil or params.maxMargin ~= nil)`; §1.8.4 implies C++ sees the same margin keys the Lua side does.
  - **Correction**: C++ sets hasMargin ONLY from the literal keys "marginMin"/"marginMax", and only by KEY PRESENCE (any value, including 0/false). The aliases minMargin/maxMargin are a Lua-wrapper-only convenience: a caller using them gets the Lua ring scan but NOT the C++ `maxDistance = min(dist+4, maxDistance)` extension, so the ring is usually unreachable. Also `{marginMin=5}` alone (no marginMax) changes the C++ search while the Lua side takes the normal path.
  - Evidence: map.cpp:1344-1348: `it = params.find("marginMin"); bool hasMargin = it != params.end(); it = params.find("marginMax"); hasMargin = hasMargin || (it != params.end());` — no alias lookup, no value test. functions/map.lua:171 `local marginMin = params.marginMin or params.minMargin`.
- **Claim**: §1.4: "It is a genuine tie-breaker: `ret` writes the *last* relaxation's `prev`, so reproducing this order reproduces vBot's exact chosen route among equal-cost paths."
  - **Correction**: Relaxation uses STRICT less-than, so an equal-cost alternative never overwrites: the FIRST relaxation that achieves the minimum wins, not the last. A reimplementer following the prose might use `<=` and produce different (mirror-image) routes. The neighbour order is still the tie-breaker, but in the first-wins sense, and the order in which parents are POPPED matters as much as the NW,W,SW,N,S,NE,E,SE scan order.
  - Evidence: map.cpp:1455 `if (node->totalCost + cost < it->second->totalCost)`. (The spec's own pseudocode uses `nt < A.total[mi]`, i.e. it contradicts its prose.)
- **Claim**: PSEUDOCODE `findEveryPath`: `field[ni] = { A.total[ni], A.dist[ni], ... }` stores the float totalCost; margin/precision selection then compares `best[1] > n[1]` on those floats.
  - **Correction**: C++ returns `std::tuple<int,int,int,std::string>`, so totalCost is TRUNCATED TOWARD ZERO before Lua ever sees it, and the margin/precision "lowest cost" comparisons in functions/map.lua run on the truncated integers. Two candidates at 100.7 and 100.2 both become 100 in real vBot (first-scanned wins); the float pseudocode picks 100.2. The port must store `math.floor(total)` in field[..][1] (and in the ignoreLastCreature entry, `floor(total)+100`) to reproduce candidate selection.
  - Evidence: map.cpp:1316 return type; map.cpp:1380 `std::make_tuple(node->totalCost, ...)` (float→int); functions/map.lua:184 and 208 `if node and (not bestCandidate or bestCandidate[1] > node[1])`.
- **Claim**: PSEUDOCODE `game/known.lua`: "blocks[z][blockIndex] = ffi uint8_t[64*64*3]"; `known:get` returns `b[i], b[i+1], b[i+2]` and only falls back to (0,255,10) when the whole block is missing.
  - **Correction**: A freshly allocated FFI byte array is zero-filled, but a fresh C++ MinimapBlock is filled with default MinimapTile{flags=0, color=255, speed=10}. So every never-written tile inside an existing block would report color=0 and speed=0 (→ getSpeed()==0, i.e. free/zero-cost steps) instead of 255/10 (→100). New blocks MUST be initialised to the nulltile pattern.
  - Evidence: minimap.h:41-45 `struct MinimapTile { uint8_t flags{0}; uint8_t color{255}; uint8_t speed{10}; }`; MinimapBlock holds `std::array<MinimapTile, 64*64>` default-constructed; minimap.cpp:52 `static MinimapTile nulltile;`.
- **Claim**: PSEUDOCODE `pathfind.isFloorChangeTile`: `if color == 255 then local _, c = known:get(pos); color = c end   -- Map::getMinimapColor`.
  - **Correction**: Map::getMinimapColor falls back to the minimap when the tile colour is **0**, not 255. And `Tile::getMinimapColorByte()` returns 255 (never 0) when no thing on the tile carries a colour, so for an existing tile the minimap fallback is unreachable — and isFloorChangeTile already returns false when the tile is missing. The pseudocode therefore invents behaviour: a live tile with colour 255 whose stored minimap colour happens to be 210-213 would be wrongly refused as a floor change.
  - Evidence: map.cpp:1168-1178 `int color = 0; if (tile) color = tile->getMinimapColorByte(); if (color == 0) { color = g_minimap.getTile(pos).color; }`; tile.cpp:571-584 returns 255 as the no-colour result; cavebot/walking.lua:141 `local color = g_map.getMinimapColor(p)`.
- **Claim**: PSEUDOCODE `game/tileflags.lua` `scan()`: memoises per tile with `if f and f.rev == tile._rev then return f end` and `f.rev = tile._rev`.
  - **Correction**: luaclient tiles have no `_rev` field and nothing in game/state.lua maintains one, so `f.rev == tile._rev` is `nil == nil` → true forever: the first scan of a tile is cached permanently and every later item add/remove is invisible to isWalkable/isPathable/minimapColor. Either add a revision counter bumped by state:addThing/removeThing/cleanTile, or drop the memoisation.
  - Evidence: game/state.lua:170-213 (state:tile / setTile / cleanTile) and :224+ (addThing) — tile tables carry only `pos` and `things`; grep for `_rev` in game/state.lua returns nothing.
- **Claim**: §3: "`LocalPlayer::autoWalk` truncates to 127 dirs and retries at 300/700/1200 ms on failure (client/localplayer.cpp:230-258, :174-185)."
  - **Correction**: The retry delays are wrong. The pathfind-failure retry is `200 + m_autoWalkRetries * 100` ms → 300 / 400 / 500 ms for retries 1..3, and it only fires when `m_autoWalkRetries > 0` (i.e. never on the first failure). The separate server-cancel retry in retryAutoWalk() is a flat 200 ms. The 127-dir truncation is correct.
  - Evidence: localplayer.cpp:236-238 `if (self->m_autoWalkRetries > 0 && self->m_autoWalkRetries <= 3) { ... scheduleEvent(..., 200 + self->m_autoWalkRetries * 100); }`; localplayer.cpp:178-183 `scheduleEvent(..., 200)`.
- **Claim**: §5.6: "before sending an autowalk the path is truncated at the first tile with `hasFloorChange() or hasElevation(3)` (walking.lua:430-449, mirroring `modules/game_walk/walk.lua:74-79`)."
  - **Correction**: Two errors. (a) There is no such truncation in the C++ client to mirror: `Game::autoWalk` only refuses paths longer than 127 dirs, and modules/game_walk/walk.lua:74-79 is a "would this step change floor" predicate for up/down stepping, not a path cut. (b) The truncation exists only in vBot's SMOOTH-mode mapClick branch; the stock (`smoothWalk` off) walkTo mapClick branch calls `autoWalk(path)` untruncated. A port must apply it in exactly that one branch, or not at all.
  - Evidence: game.cpp:683-711 (Game::autoWalk: only `dirs.size() > 127` rejection); modules/game_walk/walk.lua:72-79; cavebot/walking.lua:430-451 sits inside `if CaveBot.Config.get("mapClick")` of `smoothWalkTo`, while `CaveBot.walkTo` (walking.lua:471, non-smooth) at 486-491 calls `autoWalk(path)` with no cut.
- **Claim**: CONFIG FORMAT (2): "REAL VALUES from profiles/bot/vBot_4.8/storage/profile_1.json" showing `"targetbotAvoidFloorChange": true` at top level; cited as targetbot/walking.lua:36-38.
  - **Correction**: The key is ABSENT from profile_1.json — it is presented as a real value but does not exist on disk. The semantics (absent ⇒ enabled) are right, but the accessor is at targetbot/walking.lua:16-18, not 36-38 (36-38 is the margin early-return inside TargetBot.walkTo).
  - Evidence: `json.load(storage/profile_1.json)` has no `targetbotAvoidFloorChange` key (verified); targetbot/walking.lua:16-18 `TargetBot.avoidFloorChangeEnabled = function() return storage.targetbotAvoidFloorChange ~= false end`.
- **Claim**: §1.8.5: "**`precision` is never sent to C++** — it is purely a Lua post-filter." (and §4.4: `ignoreFields` "is silently ignored" implying it is filtered out)
  - **Correction**: The wrapper passes the ENTIRE params table to `g_map.findEveryPath` — precision, marginMin/marginMax, ignoreFields and any other key all cross into C++; they are simply keys C++ never looks up. The practical consequence the spec misses: every value in the table must be castable to std::string (the boolean→0/1 pass and the maxDistanceFrom table→string pass exist precisely for that), so a port that forwards a params table must apply the same normalisation to *all* keys, not just the recognised ones.
  - Evidence: functions/map.lua:113 `return g_map.findEveryPath(start, maxDist, params)` — no key filtering; map.cpp:1327-1348 looks up 12 fixed keys.
- **Claim**: §0 table: B `Map::findPath` is "Used by client modules only (`g_map.findPath`, `luafunctions.cpp:164`)"; "Port B second".
  - **Correction**: `Map::findPath` has zero callers anywhere: no C++ call site (only the declaration in map.h:218 and the Lua binding) and no Lua caller in modules/ or in any bot profile. It is dead code kept alive by the binding. Porting it reproduces nothing observable; its only value is documenting the `Otc::PathFindFlags` vocabulary, which nothing in vBot uses either.
  - Evidence: grep `findPath(` over src/ yields only map.cpp:831 (definition) and map.h:218 (declaration); grep `g_map.findPath|:findPath` over modules/ and profiles/bot/ yields nothing.
- **Claim**: §5.3: "the `for` bodies are guarded by `if (flags != 0)` **before** any flag has been set (`minimap.cpp:542,550`), so only the water/alpha case ever sets a flag."
  - **Correction**: Stronger than stated: loadImage never sets a flag at all. The only branch that can set `flags` is the water/alpha branch, and that same branch sets `c = UINT8_MAX`, after which `if (c == UINT8_MAX) continue;` skips the tile write entirely. So every tile loadImage does write gets `flags = 0`. (Conclusion "do not port loadImage" is still right.)
  - Evidence: minimap.cpp:534-538 (`flags |= NotWalkable; c = UINT8_MAX;`), :542/:550 (`if (flags != 0)` guards), :558 `if (c == UINT8_MAX) continue;`.
- **Claim**: PSEUDOCODE comment: `local top = topUseThing(tile)  -- tile.cpp:~690: first non-ground, non-onTop`.
  - **Correction**: Wrong line and wrong algorithm. `Tile::getTopUseThing()` is at tile.cpp:599-616 and is: (1) first thing with `isForceUse() || (!isGround && !isGroundBorder && !isOnBottom && !isOnTop && !isCreature && !isSplash)`; (2) else scan m_things BACKWARDS from the top down to index 1, returning the first non-splash non-creature; (3) else m_things[0]. So it can and routinely does return an onBottom/groundBorder item — which is exactly the kind of thing (trapdoor covers, hole lids) the floor-change guard is meant to catch — and its result is index-0 (the ground) only in the degenerate fallback. Getting this wrong changes which id `itemChangesFloor` is asked about. (tile.cpp:690-706 is `getTopMultiUseThing`.)
  - Evidence: tile.cpp:599-616.
- **Claim**: PSEUDOCODE `pathfind.isFloorChangeTile`: `local g = tile.things[1]; if g and g.kind == 'item' and itemChangesFloor(st, g.id, true)`.
  - **Correction**: `tile:getGround()` is nil unless things[1] actually carries the GROUND flag; the pseudocode passes `isGroundSlot = true` for whatever sits at index 1. On a tile the server described without a ground item (or where index 1 is a groundBorder/onBottom), an `avoid` item there would be misclassified as a floor-change ground and the whole path refused. Test `band(items.walk(g.id), W.GROUND) ~= 0` first, exactly as `Tile::getGround()` does.
  - Evidence: tile.cpp:537 `ItemPtr Tile::getGround() { const auto& ground = getThing(0); return ground && ground->isGround() ? ... : nullptr; }`; cavebot/walking.lua:145 `local ground = tile:getGround()`.
- **Claim**: PSEUDOCODE `TF.groundSpeed`: `return (s ~= 0) and s or 100  -- see PITFALL`.
  - **Correction**: C++ returns the ground item's `m_groundSpeed` verbatim, including 0; the 100 fallback applies only when there is NO ground item. The substitution is harmless inside findEveryPath (all 273 bank==0 grounds are also `unpass`, so those tiles are always blocked) but it is NOT harmless in `known:update`, where the real client writes `ceil(0/10) = 0` into the speed byte and the pseudocode would write 10. That breaks the spec's own claim that the store is byte-compatible with the real client's minimap.otmm.
  - Evidence: tile.cpp:563-568; minimap.cpp:470 `minimapTile.speed = std::min<int>(ceil(tile->getGroundSpeed() / 10.f), UINT8_MAX);`; measured: 273 objects have bank.waypoints == 0 and all 273 also carry unpass.
- **Claim**: PSEUDOCODE `pathfind.getPath(st, known, startPos, destPos, maxDist, params)` dereferences `params.marginMin`, `params.precision` etc. directly.
  - **Correction**: Missing the wrapper's nil guard. Real vBot callers pass no params at all (`CaveBot.walkTo(pos, 40)` → `getPath(fromPos, dest, 40, nil)`), and functions/map.lua:164-166 does `if type(params) ~= 'table' then params = {} end`. The pseudocode as written throws on the single most important goto call site. Also missing: the wrapper MUTATES the caller's table in place (false→0, true→1), which callers that reuse a params literal are silently affected by.
  - Evidence: functions/map.lua:164-166 and :85-92; cavebot/actions.lua:501 `CaveBot.walkTo(pos, 40)`; cavebot/walking.lua:477 `getPath(fromPos, dest, maxDist, params)`.
- **Claim**: §6 table rows for `cavebot/actions.lua:501/506/518/536`, `cavebot.lua:145`, `antilost.lua:458,530,577,583`, `looting.lua:169`, `creature_attack.lua:163/176/184/186`, `new_cavebot_lib.lua:229/247/278`, `combo.lua:382` presented as findPath calls with those params.
  - **Correction**: Those are `CaveBot.walkTo` / `TargetBot.walkTo` calls, not findPath, and both wrappers add pre-gates the port must reproduce or the call counts will differ: TargetBot.walkTo returns WITHOUT pathing when `params.precision >= chebyshev(pos,dest)` or when `marginMin <= dist <= marginMax` (targetbot/walking.lua:26-32); CaveBot.walkTo in smooth mode paths from `projectedPos()` rather than the player's real position, and both modes refuse the path if `pathCrossesFloorChange` fires. Line numbers themselves check out (combo.lua:382 is a walkTo, not a getPath — the row's params are right).
  - Evidence: targetbot/walking.lua:26-33; cavebot/walking.lua:471-483 and :399-415.
- **Claim**: §6 table is presented as the complete inventory of vBot pathfinding call sites.
  - **Correction**: At least three call sites are missing: `cavebot/antilost.lua:469` — `CaveBot.walkTo(targetPos, 1, {ignoreNonPathable=true, precision=0})` (maxDist 1, a case no other row covers); `vBot/new_cavebot_lib.lua:349` — `findPath(pos(), tPos, 20, {ignoreNonPathable = false, precision = 1, ignoreCreatures = true})` (the only site that passes ignoreNonPathable explicitly FALSE, contradicting the implicit "fields are always ignored" reading); `cavebot/stand_lure.lua:112` — `findPath(playerPos, creature:getPosition(), 7, {ignoreNonPathable=true, precision=1})`.
  - Evidence: grep of `findPath(|getPath(|walkTo(` over profiles/bot/vBot_4.8.
- **Claim**: PSEUDOCODE: array list `A.cost A.total A.prev A.dist A.state A.stamp`, with `A.dirIn[mi]` written only inside the relaxation block.
  - **Correction**: `A.dirIn` is used (`field[ni] = { ..., A.dirIn[ni], ... }`) but never declared/allocated, and it is not set in the classification branch that sets `A.prev[mi] = ni`. C++ recomputes the direction at pop time from the node's CURRENT prev (`node->prev->pos.getDirectionFromPosition(node->pos)`), so prev and dir can never drift apart there; the port must set dirIn everywhere prev is set, or recompute it from prev at pop time.
  - Evidence: map.cpp:1380-1382 and map.cpp:1443 (`prev = node` at creation, before any relaxation).
- **Claim**: §1.2: "`unseen` = 1 if the tile was not `wasSeen` at creation, then it is *reassigned* `node->unseen + 1` on every successful relaxation."
  - **Correction**: Only when it is already non-zero: `if (it->second->unseen) it->second->unseen = node->unseen + 1;`. A tile created as seen (unseen == 0) stays 0 forever. The spec's own §1.4 pseudocode has the guard, so only the prose is wrong — but it matters for anyone porting C, where `unseen > 50` is a live cutoff.
  - Evidence: map.cpp:1458-1459.
- **Claim**: CONFIG FORMAT (1): "line-oriented \"key:value\" ... Reader: cavebot/cavebot.lua:207-282."
  - **Correction**: cavebot.lua:207+ is the post-parse callback; the actual .cfg decoder is `table.decodeStringPairList` (modules/corelib/table.lua:291), reached via Config.load / Config.parse (mods/game_bot/functions/config.lua:36-52, :78-95). Its regex is `(?:^|\n)([^:^\n]{1,20}):?(.*)(?:$|\n)`: the key is limited to 1-20 characters and may contain neither ':' nor '^', the ':' is optional, and there is a `[[ ... ]]` multiline continuation mode. A reimplemented reader that just splits on the first ':' will diverge on long keys and multiline values. Config.parse also tries json.decode FIRST and falls back to the pair list.
  - Evidence: modules/corelib/table.lua:291-330; mods/game_bot/functions/config.lua:36-52 and :78-95; cavebot/cavebot.lua:207 `config = Config.setup("cavebot_configs", configWidget, "cfg", function(name, enabled, data)`.
- **Claim**: §4.3 table describes `bank`, `bottom`, `top`, `shift`, `height`, `automap`, `lenshelp` alongside the bool flags as if all were value-tested.
  - **Correction**: `applyAppearanceFlags` sets the flag on PRESENCE for bank(1), bottom(3), top(4), write(10), write_once(11), hook(21), light(23), shift(26), height(27), automap(30), lenshelp(31), clothes(34), market(36) — `has_x()` with no value test — while clip(2), container(5), unpass(13), unmove(14), unsight(15), avoid(16), fullbank(32), ignore_look(33) etc. require `has_x() && x()`. The proposed items1530.bin v2 extractor must use presence semantics for GROUND/ELEVATION/BOTTOM/TOP (the spec says "presence" for GROUND and ELEVATION but labels BOTTOM/TOP as plain bools) — note this differs from the v1 extractor's blanket "presence AND truth" rule.
  - Evidence: thingtype.cpp:177-183 (`if (flags.has_bank())`, `if (flags.has_clip() && flags.clip())`), :188-194 (`has_bottom()` / `has_top()` with no value test), :301-305, :315-323.
- **Claim**: PSEUDOCODE `TF.isWalkable`: `local canBeSeen = not (c and c.invisible) or (c and c.isPlayer)`.
  - **Correction**: luaclient creature records have `passable` and `isPlayer` but no `invisible` field. Derive it from the wire: `Outfit::isEffect() && auxId == 13` is set by ProtocolGame::getOutfit ONLY in the `lookType == 0 && lookTypeEx == 0` case (auxId is then hard-coded to 13), so on luaclient the predicate is exactly `outfit.lookType == 0 and outfit.lookTypeEx == 0`. The spec should say so, otherwise `c.invisible` is permanently nil and invisible creatures block the tile.
  - Evidence: protocolgameparse.cpp:4165-4176; creature.h:152,156; proto/parser.lua:446-451 stores lookType/lookTypeEx; grep for `invisible` in luaclient game/state.lua and proto/parser.lua returns nothing.
- **Claim**: §1.2: pushing `(node, totalCostAtPushTime)` pairs gives "the resulting order [...] identical for all non-degenerate inputs".
  - **Correction**: Asserted without proof and not generally true: the C++ heap re-reads the live, mutated `totalCost` during sift operations, so the pop ORDER can differ from a snapshot-key heap even for ordinary inputs (a node whose key was decreased after being pushed can surface earlier in C++ than in a snapshot heap, and a stale duplicate pops with a lower key than it actually has). The final field contents converge (every relaxation re-pushes, and ret is rewritten at each pop), but expansion order — and therefore the first-wins tie-break of §1.4 — can diverge. This is the one place where an exact port is impossible; the spec should say that rather than claim equivalence.
  - Evidence: map.cpp:1319-1325 (`LessNode` over `Node*`, comparing `b->totalCost < a->totalCost` at sift time) vs map.cpp:846-852 (findPath's pair<SNode*,float> snapshot heap).
- **Claim**: §4.1 lists the TileThingType bits; §4.2 says the movement bits come only from items.
  - **Correction**: Both correct, but the list omits `IS_NOT_PATHAB = 1 << 6` (declared, never used) and does not say that `ELEVATION = 1 << 7` is never set by `setThingFlag` — elevation is tracked only by the `m_elevation` counter, which is what `hasElevation(3)` reads. A reimplementer who wires ELEVATION into the tile flag word gets a bit that the real client never sets.
  - Evidence: const.h:1545-1573 (`IS_NOT_PATHAB = 1 << 6`, `ELEVATION = 1 << 7`); tile.cpp:1011-1012 `if (thing->hasElevation()) ++m_elevation;` — no `m_thingTypeFlag |= ELEVATION` anywhere.
- **Claim**: Line citations for `mods/game_bot/functions/map.lua` throughout §0/§1.1/§1.7/§1.8 (76-210, 110-134, 118-133, 137-210, 150-152, 156-158, 162-163, 165-186, 189-208, 212-226, 101-108).
  - **Correction**: Systematically 5-6 lines low. Actual: findAllPaths 80-113; translateAllPathsToPath 116-140; findPath 143-218 (`getPath` alias 220); z/nil guard 156-158; maxDist default 161-163; destination injection 168-169; margin block 171-192; precision block 195-215; autoWalk 223-236; maxDistanceFrom serialisation 105-112. Similar 1-2 line drift in the vBot citations: walking.lua itemChangesFloor 116-127 (not 118-127), isFloorChangeTile 133-166 (not 132-165), wouldStepChangeFloor 172-183 (not 170-180), truncation 430-451; actions.lua Manhattan gate 387 (not 385), stairs marking 393-394 (not 394-395); targetbot/walking.lua guard call at 39-40 (not 38-47). All C++ citations in §1-§5 are exact.
  - Evidence: grep -n over mods/game_bot/functions/map.lua and profiles/bot/vBot_4.8/cavebot/*.lua.
- **Claim**: "## 7. Configuration d" and the final "-- Wiring into luaclient" block.
  - **Correction**: The document is truncated: section 7 stops mid-word and the closing "Wiring into luaclient" section contains only a bare `--`. Whatever those sections were meant to specify (config persistence naming, and how pathfind.lua/known.lua hook into the parser, the walk sender and the aware-window eviction) is absent, and §5.5's own conclusion says the store must be written "on every tile description" without saying where — the C++ trigger is item-only tile updates plus cleanTile, which is a non-obvious hook point.
  - Evidence: The SPEC text as given; map.cpp:116-128 and map.cpp:438 are the only two callers of Minimap::updateTile.

### Additions
- VERIFIED EXACT (no changes needed): the whole of §1.4/§1.5 against map.cpp:1373-1465 — line numbers, the (i,j) neighbour order NW,W,SW,N,S,NE,E,SE, the defaults {wasSeen=false, hasCreature=false, isNotWalkable=true, isNotPathable=true, mapColor=0, speed=1000}, the aware-but-tile-missing case keeping the defaults, the minimap branch including `if (isNotWalkable || isNotPathable) wasSeen = true`, `hasStairs = isNotPathable && 210<=color<=213` (the local patch, comment at 1425-1428 verified), the missing destPos exemption on isNotWalkable, the permanent nil caching, the +100 ignoreLastCreature entry, the margin `+4`, the ignoreCost=1 override, and the 12 recognised param keys (no ignoreFields among them).
- VERIFIED EXACT: the DIR lookup table. atan2(-dy,dx) with 22.5-degree sectors gives (dx,dy) -> (-1,-1)=NW=7, (-1,0)=W=3, (-1,1)=SW=6, (0,-1)=N=0, (0,1)=S=2, (1,-1)=NE=4, (1,0)=E=1, (1,1)=SE=5, matching const.h:158-169 and luaclient proto/sender.lua:80-81. Implementing it as a table rather than atan2 is correct.
- VERIFIED EXACT by re-measuring the asset file: every number in §4.5. 43536 object appearances, maxId 62144 (itemArrayLen 62145), unpass 16697, unsight 5925, avoid 2055, bank 3354, automap 15777, fullbank 2958, elevation 2194, lenshelp 981, grounds also unpass 496, grounds avoid 249, the exact bank.waypoints value set, 273 items with waypoints==0 of which 0 lack unpass, automap in 205..215 = {207:301, 210:972, 215:115} (so 211/212/213 really are absent), 545 of the 972 yellow items also carry avoid, and the full lenshelp histogram. Also verified: every proto field number in §4.3 against src/protobuf/appearances.proto, and that ThingFlagAttrFloorChange (1<<48) is reachable only from the legacy .dat path (thingtype.cpp:1096), never from applyAppearanceFlags.
- VERIFIED EXACT: §4.2 predicates verbatim (tile.cpp:708-724, 838-844, 563-568, 571-584, 537, 783-802; tile.h:77, 81, 129), the `if (!thing->isItem()) return;` early exit at tile.cpp:996 before the movement bits, Creature::isPassable/isInvisible/canBeSeen at creature.h:146/152/156 with m_passable defaulting to false (creature.h:359), and GameServerCreatureUnpass == 146 == 0x92 (protocolcodes.h:147). `isCommon()` is `!isGround && !isGroundBorder && !isOnTop && !isCreature && !isOnBottom` (thing.h:67), matching the spec's getMinimapColorByte skip rule.
- VERIFIED EXACT: §5.1/§5.2/§5.4 minimap semantics and the OTMM layout — MMBLOCK_SIZE 64, flags 1/2/4/8, getSpeed()=speed*10, nulltile {0,255,10}, blockIndex/tileIndex/indexPosition formulas (minimap.h:61,153-167), updateTile's `isWalkable(true)` creature-independent recording, the tile-absent case setting NotWalkable|NotPathable, the 22-byte header, the u16/u16/u8/u16 block framing, zlib level 3 (OTMM_COMPRESS_LEVEL = 3) over exactly 12288 bytes, the 0xFFFF/0xFFFF/0xFF terminator, wasSeen-only block writing, and MinimapTileEmpty being read at map.cpp:1086 and written nowhere.
- VERIFIED EXACT: §7 CONFIG FORMAT (1) — cavebot_configs/test.cfg matches the quoted bytes verbatim, and every default in the pathfinding-relevant key list matches cavebot/config.lua:25-32,37 plus walking.lua:34-36 (smoothWalk false, avoidFloorChange true, avoidTileIds ""). §7 (2) extras values other than targetbotAvoidFloorChange match profile_1.json exactly (gotoMaxDistance 64, pathfinding true, machete/shovel/rope/scythe 9596, killUnder 1, lootDelay 220, looting 40, autoOpenDoors true). The goto arrival rule is right: with a 4th field, both axes within that tolerance; without it, |dx|==0 and |dy|<=1.
- VERIFIED CORRECT and worth stating explicitly in the spec, because it is non-obvious: clipping the search grid to a (2*maxDistance+1) square centred on start is safe. Every created node has Chebyshev(start,node) <= node.distance, a node is expanded only while distance < maxDistance, and margin mode only shrinks maxDistance — so no node C++ would create falls outside the grid. Sizing the arrays from the ORIGINAL maxDistance (not the shrunk one) is also required and the pseudocode does it.
- The luaclient already ships `state:walkableAt(pos, ignoreCreatures)` (game/state.lua:537-558) as a partial Tile::isWalkable with a documented 'items-unknown' escape hatch, and it infers 'has ground' from "things[1] is an item" rather than from a GROUND flag. The spec introduces `TF.isWalkable` without mentioning it; the port must either replace walkableAt or the two will disagree once the v2 item table lands (walkableAt would keep reporting walls walkable). Same for the reason-string contract, which other luaclient code may depend on.
- Missing from §3, and needed if C is ever ported: `findPathAsync` seeds visibleNodes using `!tile->isWalkable(false)` — i.e. CREATURE-AWARE walkability, unlike A and unlike Minimap::updateTile — and `newFindPath`'s goal pre-check uses `isWalkable()` with the default ignoreCreatures=false (map.cpp:1029-1031, 1143-1147). The blocked-seed nodes get totalCost 0 and are unreachable by relaxation, which is what makes them behave as pre-closed.
- Missing behaviour that bounds any autowalk port: `Game::autoWalk` REFUSES (logs an error and sends nothing) when dirs.size() > 127 — it does not truncate. LocalPlayer::autoWalk truncates to 127 before calling, but the bot's `autoWalk(path)` (functions/map.lua:223-236) passes the path straight through, so a >127-step bot path is silently dropped. Relevant because §1.6 documents a default maxDistance of 100 and the goto family uses 50-64.
- Worth adding to §1.7: `translateAllPathsToPath` walks the prev chain with no cycle guard and no step budget; it terminates only because `node[3] < 0` marks the start node and the chain is acyclic in a correct field. A port that builds `field` incrementally (or that lets a stale prev survive) can hang here — bound the loop by maxDistance+1 iterations.
- Verified and worth stating: `precision = 0` and `ignoreStairs = false` both survive the wrapper as the number 0, and C++ tests `value != "0" && value != ""`, so both read as FALSE — confirming the spec's conclusion that the yellow+non-pathable stairs rule is always active (combo.lua:382 is the only ignoreStairs caller and it passes false).
