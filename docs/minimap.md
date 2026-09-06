# The persisted minimap (OTMM v1) and the pathfinder

Work item M.  `lib/minimap.lua` is a **read-only** reader for the file the reference client
writes at `profiles/minimap.otmm`.  It exists for one reason: without it the pathfinder only
knows the tiles the server has described (the aware area), so a cavebot waypoint more than a
screen away has **no path at all** and CaveBot cycles waypoints without moving —
`docs/live-findings.md`, bug 3.

Everything below is taken from `D:/Claude/otclient_mehah1530/otclient/src/client/minimap.cpp`
and `minimap.h` in the user's fork, and verified byte-for-byte against the user's real
6,984,725-byte file (11,420 blocks, 20,306,438 tiles carrying `WasSeen`).

---

## 1. The file format

### 1.1 Header

| offset | size | field |
|---|---|---|
| 0 | u32 LE | signature `0x4D4D544F` = `"OTMM"` |
| 4 | u16 LE | **dataStart** — byte offset of the first block |
| 6 | u16 LE | version, must be **1** |
| 8 | u32 LE | flags (always 0; `//TODO: compression flag with zlib`) |
| 12 | u16 LE + bytes | v1 description string, always `"OTMM 1.0"` |

`dataStart` is therefore 22 in every file the client writes, but it is **read**, not assumed:
`saveOtmm` writes a placeholder, then seeks back and patches it (`minimap.cpp:940-947`).
A file whose `dataStart` is `< 12` or `> size` is rejected outright.

### 1.2 Body

```
repeat { u16 x, u16 y, u8 z, u16 len, len bytes of a zlib stream } until (0xFFFF, 0xFFFF, 0xFF)
```

* `x`, `y` are the **top-left corner of a 64×64 block** and are always multiples of
  `MMBLOCK_SIZE = 64`.  `z` is a floor, `0..15`.
* `len` is the compressed length.  The payload is a **zlib** stream (2-byte CMF/FLG header,
  raw DEFLATE, 4-byte big-endian adler32) produced by `compress2(..., level 3)`.
* the block decompresses to **exactly 12288 bytes** = 64 × 64 tiles × 3 bytes.
* the body ends on a 5-byte sentinel that is the invalid `Position` `(0xFFFF, 0xFFFF, 0xFF)`.

`compressBound(12288)` = `12288 + (12288>>12) + (12288>>14) + (12288>>25) + 13` = **12304**,
which is the hard upper bound on `len` and the reason `len` fits a u16 at all.

### 1.3 A tile

`MinimapTile` is `#pragma pack(1)` (minimap.h:40-51), so three bytes with no padding:

| byte | field | default |
|---|---|---|
| 0 | `flags` | 0 |
| 1 | `color` | **255** |
| 2 | `speed` | **10** |

```
MinimapTileWasSeen     = 1
MinimapTileNotPathable = 2
MinimapTileNotWalkable = 4
MinimapTileEmpty       = 8
```

`getSpeed()` is `speed * 10`, so the default tile has ground speed **100**.
Tile order inside a block is row-major: `index = ((y % 64) * 64) + (x % 64)` (minimap.h:60).
Block lookup is `blockIndex = (y / 64) * (65536 / 64) + (x / 64)`, per floor (minimap.h:161).

`color == 255` renders black and is skipped when drawing, **but the flags still feed
pathfinding** — a colour-only merge silently loses "known blocked" knowledge.

### 1.4 What a healthy file looks like

The first 32 bytes of the user's file:

```
4f 54 4d 4d | 16 00 | 01 00 | 00 00 00 00 | 08 00 | "OTMM 1.0"
^ OTMM        ^ 22     ^ v1    ^ flags       ^ len 8
00 82 | 40 79 | 00 | 87 00 | 78 5e ...
^ x=33280 (=520*64)   ^ z=0  ^ len=135   ^ zlib CMF/FLG
        ^ y=31040 (=485*64)
```

---

## 2. Fail-soft parsing

`Position::isValid()` is false for exactly **one** triple out of 2^40, so it cannot be used to
recognise framing on its own — arbitrary garbage parses as a "valid" block header.  The
reference client (and this reader) instead require **all** of:

* `x % 64 == 0` and `y % 64 == 0`;
* `z <= 15`;
* `8 <= len <= 12304` and the payload fits inside the file;
* the first two payload bytes look like a zlib header: `CM == 8`, `CINFO <= 7`, `FDICT` clear,
  and `(CMF << 8 | FLG) % 31 == 0`.

When those fail the reader scans forward one byte at a time to the next offset that satisfies
them (`findNextFrame`), counts a resync, and carries on: **a break in the framing costs only
the bytes up to the next recognisable header, never the rest of the file.**  A block whose
payload will not inflate to exactly 12288 bytes costs that one block.

If the sentinel is found but bytes follow it, those bytes are a **stale tail** left behind by a
pre-fix writer that rewrote the file in place without truncating it.  They are scanned for
salvageable blocks, which are only ever used to fill gaps (see the merge rule below).

`mm:stats()` reports all of it: `blocksOk`, `blocksSalvaged`, `blocksDamaged`, `duplicates`,
`resyncs`, `bytesSkipped`, `trailingBytes`, `sawEndMarker`, `damaged`.

**Deviation, deliberate:** because this reader is lazy, `blocksOk` counts headers **accepted**
on the main walk, not payloads proved to inflate — the C++ inflates every block up front and so
can count both.  A payload that turns out to be unusable when a tile inside it is first asked
for is counted in `blocksUnusable` instead.  The stale-tail scan is the exception: past the
sentinel there is no framing to trust, so it does inflate each candidate before accepting it
and advances one byte at a time when that fails, exactly like the C++.

### Merge rule for a repeated block

If two block records name the same `(z, blockIndex)`, they are folded per
`Minimap::mergeOtmmBlock` (minimap.cpp:591-649), tile by tile, first record wins:

1. what we already hold and that carries `WasSeen` **always** wins;
2. otherwise take the stored tile when it carries `WasSeen`;
3. otherwise take it when it has a real colour and we hold only the 255 default;
4. otherwise keep what we have.

---

## 3. The Lua API

```lua
local minimap = require('lib.minimap')

local mm, err = minimap.load('.../profiles/minimap.otmm')   -- reads, closes, indexes
minimap.parse(bytes [, opts [, name]])                      -- the same, from memory

mm:tile(x, y, z)     --> { color=, speed=, walkable=, pathable=, seen=,
                     --    empty=, stairs=, flags=, speedByte= }  |  nil
mm:get(pos)          --> flags, colorByte, speedByte      (the bot/world.lua `known` API)
mm:raw(x, y, z)      --> flags, colorByte, speedByte
mm:hasBlock(x, y, z) --> is any knowledge stored for that 64x64 block?
mm:blockCount()      --> distinct (z, blockIndex) pairs indexed
mm:stats()           --> the table above, plus loadMs / inflated / cache figures
mm:preload()         --> inflate everything (diagnostic; see the numbers below)
mm:seenTiles()       --> count tiles carrying WasSeen (inflates everything)
```

`minimap.load` / `minimap.tile` / `minimap.stats` / `minimap.blockCount` also work as
module-level calls against the most recently loaded instance, and every one of them accepts an
explicit instance as its first argument, so `mm:tile(x,y,z)` and `minimap.tile(mm,x,y,z)` are
the same call.

`tile()` returns **nil** when no block covers the position (the file has never held anything
there).  Inside a stored block a never-explored tile comes back as a real record with
`seen = false`, `color = 255`, `speed = 100` — the reference client's default `MinimapTile`.

`minimap.buildFile(specs)` writes an OTMM v1 image in memory (STORED deflate blocks, which
every zlib reader accepts).  `test/botsuite.lua` uses it to build fixtures so no test ever
needs the user's 6.9 MB file.

### Read-only, and why it matters

`load()` opens the file `'rb'`, slurps it and **closes it immediately**.  It never keeps a
handle open, because the reference client publishes its minimap with an atomic rename and on
Windows `MoveFileEx` fails against **any** open handle — a long-lived reader would silently
break every logout save.  Nothing in this module ever opens the file for writing.

### Laziness, speed and memory

`load()` walks the framing without inflating anything.  A block is inflated the first time a
tile inside it is asked for and then kept in a two-generation cache (default 192 blocks; the
ceiling is 2 × 192 × 12288 ≈ 4.7 MB), because a search touches a handful of 64×64 blocks and
revisits them thousands of times.  `opts.cacheBlocks` tunes it.

Measured on the user's real file (6,984,725 bytes, 11,420 blocks), LuaJIT:

| | |
|---|---|
| `load()` — read + index | **5.0 ms** (2.0 ms of it is the framing walk; 1 ms under WSL/Debian) |
| resident afterwards | **8.9 MB** Lua heap (6.98 MB file image + ~1.9 MB of index tables) |
| inflate one block | ~0.13 ms |
| a real 29-tile waypoint search | 4 blocks inflated, 1–4 ms |
| `preload()` — every block | 556 ms / 140 MB — **this is why the reader is lazy** |
| `seenTiles()` | 20,306,438 |

---

## 4. How the pathfinder uses it

`Map::findEveryPath` (map.cpp:1399-1424) classifies each neighbour like this, and
`bot/world.lua:classifyForPath` is a line-for-line port of it:

```
defaults:  wasSeen=false hasCreature=false notWalkable=true notPathable=true color=0 speed=1000

if g_map.isAwareOfPosition(pos):            -- THE LIVE MAP ALWAYS WINS
    if a tile exists there: read wasSeen / creature / walkable / pathable / colour / speed
                            off the live tile.  The minimap is NOT consulted.
    if no tile exists there: keep the defaults (blocked).
elif not allowOnlyVisibleTiles:             -- outside the aware area: the MINIMAP
    wasSeen     = flags & WasSeen
    notWalkable = flags & NotWalkable
    notPathable = flags & NotPathable
    color       = tile.color
    if notWalkable or notPathable: wasSeen = true      -- blocked IMPLIES seen
    speed       = speedByte * 10
```

Consequences, all covered by `test/botsuite.lua` section *work item M*:

* **the live map always wins** where both know a tile — in both directions.  A live wall the
  minimap remembers as walkable still blocks; a live floor the minimap remembers as a wall is
  still walked.  Outside the aware area the stale minimap record is authoritative again.
* a minimap tile with `WasSeen` and no blocking flag **is pathable, at its recorded speed** —
  `speedByte * 10` is the step cost the Dijkstra accumulates, exactly like a live ground speed.
* a tile with **no** `WasSeen` is blocked unless the caller passes `allowUnseen`.
* `allowOnlyVisibleTiles` skips the minimap branch entirely, so the search sees only the aware
  area — the pre-work-item-M behaviour, still available on demand.
* "blocked implies seen" means `allowUnseen` can never open a tile the minimap remembers as a
  wall; only `ignoreNonWalkable` does.
* with **no** minimap loaded, `world:knownAt` answers the reference client's null tile
  `(flags 0, colour 255, speed byte 10)`, so every outside tile is "not seen" and the
  behaviour is bit-for-bit what it was before this work item.

### The 210-213 stair/hole band

Unchanged, and load-bearing for the anti-lost logic:

```
hasStairs = isNotPathable AND 210 <= mapColor <= 213
```

Outside the aware area that colour comes from the **minimap**, which is where the hole/stair
avoidance gets its evidence in the first place.  Colour alone is **not** enough: staircases are
drawn over several yellow tiles of which only one changes floor, and blocking every yellow tile
made such stairs unreachable (the bot stopped at the foot of them).  `mm:tile()` exposes the
same predicate as `.stairs` so callers do not re-derive it.

`hasStairs` is tested **separately** from `isNotPathable`, so `ignoreNonPathable` alone does not
open a staircase — `ignoreStairs` is needed as well.  Both have a destination exemption;
`isNotWalkable` has none.

---

## 5. Wiring

```
main.lua  --minimap=PATH ---------> lib/minimap.lua ---> LC.minimap
                                                          |
                        bot/init.lua wireModules{ known = LC.minimap }
                                                          |
                                   bot/world.lua  world.new(client, { known = ... })
                                        (also picks up client.minimap on its own)
                                                          |
                                   world:knownAt -> world:classifyForPath -> bot/path.lua
```

* `--minimap=PATH` selects the file.  With the flag absent, the reference client's own
  `profiles/minimap.otmm` is used **when it exists** (tried relative to the checkout first, so
  the same command line works on Windows and under WSL).  `--minimap=off` disables it.
* main.lua logs one line per run:
  `minimap: <path> -- 11420 blocks loaded (46776320 tile slots) from 6984725 bytes in 2 ms |
  blocks per floor 0:144 1:216 ...`
* A missing, unreadable or non-OTMM file is a **warning, never fatal**: the bot comes up and
  simply cannot path outside the aware area, which is where it was before.
* `bot/world.lua:knownAt` fails open and fails **once** — a minimap source that raises is
  logged and switched off for the rest of the session, because an error escaping
  `classifyForPath` is retried by `bot/init.lua` every 10 ms forever.
* `path.new(client, nil, { known = mm })` installs one directly; a `path` built with an
  explicit `world` uses that world's source, since the world owns it.

## 6. Related tooling

`D:/Claude/otclient_mehah1530/otclient/tools/otmm_tool.py` (validate / repair / merge / stats)
is the Python side of the same format, written for the minimap-corruption work in the fork.
It is the reference to check this reader against on a damaged file.
