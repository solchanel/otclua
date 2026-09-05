# assets/

Generated, checked-in game metadata for the LuaJIT client. Nothing here is hand-edited.

## items1530.bin

Per-item-id metadata table for protocol 1530 / OS 61 (Gunzodus). Two consumers:

* `proto/parser.lua` cannot decode a single map description without **FLAGS1**: every item on the
  wire is followed by a variable number of attribute bytes, and which blocks are present is decided
  purely by these flags (`docs/appearances-assets.md` §3.1).
* the bot layer needs the walkability / interaction flags, the per-item scalars and the item names
  (`docs/vbot/gaps.md` P0-1, `docs/vbot/pathfinding.md` §4).

Loaded by `proto/items.lua` (`items.load(path)` → `items.flags(id)`, `items.flags2..5(id)`,
`items.groundSpeed/minimapColor/elevation/lensHelp/clothSlot/name/marketName(id)` and the derived
predicates `isGround`, `isNotWalkable`, `isNotPathable`, `isBlockProjectile`, `isPickupable`,
`isUsable`, `isMultiUse`, `isContainer`, `isStackable`, `isCommon`, `stackPriority`, …).

| | |
|---|---|
| format version | **2** (v1 files still load; every v2-only column then reads 0) |
| size | 949,392 bytes (40-byte header + 12-entry directory + 12 sections) |
| sha256 | `b44e05e3e96cba19559c146f3b51e66dc763092e039531a2ca024e45aadda9a1` |
| item ids | 1 .. 62,144 (`items.MAX_ID`); 43,536 ids carry an appearance, the rest are holes |
| names | 8,951 ids (sparse index + 149,730-byte blob); 5,099 of them also carry a market block |
| content revision | 42,196 (diagnostic copy only — see below) |
| load cost | ~1 ms and ~929 KB of Lua heap on both Windows and Debian LuaJIT (measured by `test/f1_metadata.lua`) |

Names are looked up lazily (binary search over `NAMEIDX`, memoised), so `items.load` does not
materialise 8,951 Lua strings; the 929 KB is essentially the file held as one string.

### Regenerating

```
cd D:/Claude/otclient_web/luaclient
python tools/extract_appearances.py
```

Options: `--things-dir DIR` (default `D:/Claude/otclient_mehah1530/otclient/data/things/1530`),
`--out FILE` (default `assets/items1530.bin`), `--dump ID [ID ...]` (print the decoded
`AppearanceFlags`, the derived `FLAGS1..5`, every scalar column and the name of specific object ids
for spot-checking; writes nothing).

The extractor is deterministic: two runs over the same input produce a byte-identical file
(verified). Re-run it whenever the server ships a new asset set, i.e. whenever
`data/things/1530/appearances-*.dat` or `assets.json.sha256` changes.

### Source

```
D:/Claude/otclient_mehah1530/otclient/data/things/1530/
  appearances-17a72b30b5c3c9ca8c1283cfb2febd2a93a145ff8ab66916f7a412d0f1dee5a1.dat
      size    5,017,714 bytes
      sha256  e39b2d40a9e59b380cfcd6e4c3b337a512c6fd88f8445eb78d532fb332670da7
  assets.json.sha256
      5 bytes, ASCII "42196" (a decimal content revision, NOT a hash)
```

Note the filename hash and the file's own sha256 differ — the filename hash is the upstream
catalog's identifier, not a checksum of the bytes on disk. The value above is the real sha256
of the file, measured with `hashlib`.

The reference tree is READ-ONLY; the extractor only reads from it.

### Extracted counts (measured, matches `docs/vbot/gaps.md` VERIFIER exactly)

| category | protobuf field | count | max id | array len |
|---|---|---|---|---|
| object (item) | 1 | 43,536 | 62,144 | 62,145 |
| outfit (creature) | 2 | 1,475 | 10,003 | 10,004 |
| effect | 3 | 243 | 343 | 344 |
| missile | 4 | 76 | 82 | 83 |

Flag-bit population:

| byte | bits |
|---|---|
| FLAGS1 | `CUMULATIVE` 2,653 · `WEAROUT` 92 · `EXPIRE` 338 · `CONTAINER` 3,381 · `CLASSIFY` 1,016 · `PODIUM` 5 · `DECOKIT` 1 · spare 0 |
| FLAGS2 | `GROUND` 3,354 · `GROUND_BORDER` 6,312 · `ON_BOTTOM` 11,212 · `ON_TOP` 1,267 · `NOT_WALKABLE` 16,697 · `NOT_PATHABLE` 2,055 · `NOT_MOVEABLE` 31,818 · `BLOCK_PROJECTILE` 5,925 |
| FLAGS3 | `PICKUPABLE` 7,221 · `USABLE` 10,883 · `MULTIUSE` 2,675 · `FORCE_USE` 1,057 · `FLUID_CONTAINER` 48 · `SPLASH` 12 · `HANGABLE` 540 · `WRITABLE` 96 |
| FLAGS4 | `ROTATEABLE` 1,156 · `FULL_GROUND` 2,958 · `IGNORE_LOOK` 1,687 · `CORPSE` 3,744 · `PLAYER_CORPSE` 17 · `LYING_OBJECT` 1,890 · `WRAPABLE` 2,148 · `UNWRAPABLE` 2 |
| FLAGS5 | `STACKABLE` 2,593 · `MARKET` 5,099 · `ELEVATION` 2,194 |

Scalar columns: `groundSpeed` 3,081 non-zero ids (max 1,200; 273 `bank` items have no `waypoints`
and are stored as 0 — see NOTE 3 in the format block) · `minimapColor` 15,658 (max 215) ·
`elevation` 2,190 (max 24) · `lensHelp` 981 (max 1,112) · `clothSlot` 1,549 (max 12).

### File format

Documented identically at the top of `tools/extract_appearances.py` and `proto/items.lua` — read
either of those for the authoritative bit-by-bit description. Summary (little-endian):

```
 0  "LCIT" | 4 version 2 | 5 headerSize 40 | 6 categoryCount 4
 8  itemArrayLen | 12 creatureArrayLen | 16 effectArrayLen | 20 missileArrayLen
24  objectCount | 28 contentRevision | 30 reserved
32  sectionCount 12 | 33 reserved[3] | 36 sectionTableOff 40
40  sectionCount * { u8 sectionId, u8 elemSize, u16 reserved, u32 offset, u32 byteLength }
    payloads, in directory order, each 4-byte aligned
```

The first 32 bytes have the **same layout as v1**, so a v1 header parser still reads
`itemArrayLen` / `objectCount` / `contentRevision` out of a v2 file. Everything new hangs off the
section directory, which is what makes the format extensible: a future v3 may append sections, an
unknown `sectionId` is skipped by the loader, and a section that is simply absent reads as
all-zero. `proto/items.lua` still accepts a v1 file unchanged.

Sections: `1 FLAGS1`, `2 FLAGS2`, `3 FLAGS3`, `4 FLAGS4`, `5 GROUNDSPEED` (u16),
`6 MINIMAPCOLOR`, `7 ELEVATION`, `8 LENSHELP` (u16), `9 CLOTHSLOT`, `10 NAMEIDX`
(u16 id + u32 blob offset, ascending), `11 NAMEBLOB` (NUL-terminated UTF-8), `12 FLAGS5`.

**FLAGS1 is byte-identical to v1 and must never be renumbered** — `proto/parser.lua` decides the
per-item attribute-block reads from it: `0x01` CUMULATIVE (u8 count/subtype), `0x02` WEAROUT
(u32+u8), `0x04` EXPIRE (u32+u8), `0x08` CONTAINER (u8 type + switch), `0x10` CLASSIFY (u8 tier),
`0x20` PODIUM, `0x40` DECOKIT (u16), `0x80` spare.

Two traps worth repeating here:

* **`isStackable` is not FLAGS1 `CUMULATIVE`.** FLAGS1 bit 0 is a *protocol-read* bit and is also
  set for `liquidcontainer` and `liquidpool` (60 ids), because those take the same u8 on the wire.
  `Item::isStackable` is `cumulative` alone, which is why v2 adds FLAGS5 `STACKABLE`.
* **There is no floor-change bit at 1530.** `ThingFlagAttrFloorChange` is only ever set by the
  legacy `.dat` path, so `Tile::hasFloorChange()` is permanently false. Floor changes are inferred
  from `LENSHELP` (1104/1105 only — ladders 1100 and rope spots 1102 are deliberately excluded),
  `GROUND`, `NOT_PATHABLE` and `MINIMAPCOLOR` 210..213.

### Not extracted, on purpose

* `frame_group` / sprites / animation phases — `GameItemAnimationPhase` is disabled at
  client version >= 1281, so no phase byte is ever read at 1530.
* item **descriptions** (Appearance field 5) — no consumer. Item *names* (field 4) ARE extracted
  now: loot lists, the depositer and every log line need them.
* `staticdata`, `proficiencies`, `map`, `backdrop_map`, `catalog-content.json` — no wire effect.

### The content revision is diagnostic only

`items1530.bin` carries a copy of the parsed `assets.json.sha256` value purely so a stale asset
file is easy to spot. The login packet must **re-parse** `things/1530/assets.json.sha256` at
runtime and send `tostring(value)` (trim, whole-string digits, require `1 <= v <= 0xFFFF`, else
`"0"`), per `docs/appearances-assets.md` §6 and its VERIFIER note about the two copies drifting
apart. Do not source the wire string from this header.
