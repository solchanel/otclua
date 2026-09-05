# assets/

Generated, checked-in game metadata for the LuaJIT client. Nothing here is hand-edited.

## items1530.bin

Per-item-id attribute-flag table for protocol 1530 / OS 61 (Gunzodus). `proto/parser.lua` cannot
decode a single map description without it: every item on the wire is followed by a variable
number of attribute bytes, and which blocks are present is decided purely by these flags
(`docs/appearances-assets.md` §3.1).

Loaded by `proto/items.lua` (`items.load(path)` → `items.flags(id)`).

| | |
|---|---|
| size | 62,177 bytes (32-byte header + 62,145 flag bytes) |
| sha256 | `2d62e99cc56a833b511a22624e127e0a2f32508793a10556e30b7a20446a2378` |
| item ids | 1 .. 62,144 (`items.MAX_ID`); 43,536 ids carry an appearance, the rest are holes |
| non-zero flag bytes | 7,486 |
| content revision | 42,196 (diagnostic copy only — see below) |

### Regenerating

```
cd D:/Claude/otclient_web/luaclient
python tools/extract_appearances.py
```

Options: `--things-dir DIR` (default `D:/Claude/otclient_mehah1530/otclient/data/things/1530`),
`--out FILE` (default `assets/items1530.bin`), `--dump ID [ID ...]` (print the decoded
`AppearanceFlags` and the name of specific object ids for spot-checking; writes nothing).

The extractor is deterministic: two runs over the same input produce a byte-identical file.
Re-run it whenever the server ships a new asset set, i.e. whenever
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

### Extracted counts (measured, matches `docs/appearances-assets.md` VERIFIER exactly)

| category | protobuf field | count | max id | array len |
|---|---|---|---|---|
| object (item) | 1 | 43,536 | 62,144 | 62,145 |
| outfit (creature) | 2 | 1,475 | 10,003 | 10,004 |
| effect | 3 | 243 | 343 | 344 |
| missile | 4 | 76 | 82 | 83 |

Flag-bit population: `CUMULATIVE` 2,653 · `WEAROUT` 92 · `EXPIRE` 338 · `CONTAINER` 3,381 ·
`CLASSIFY` 1,016 · `PODIUM` 5 · `DECOKIT` 1 · spare 0.

### File format

Documented identically at the top of `tools/extract_appearances.py` and `proto/items.lua`.
Summary (little-endian): magic `"LCIT"`, u8 version 1, u8 headerSize 32, u16 categoryCount 4,
u32 itemArrayLen, u32 creatureArrayLen, u32 effectArrayLen, u32 missileArrayLen, u32 objectCount,
u16 contentRevision, u16 reserved, then `itemArrayLen` flag bytes indexed by item id.

Flag bits (identical to API.md): `0x01` CUMULATIVE (u8 count/subtype), `0x02` WEAROUT (u32+u8),
`0x04` EXPIRE (u32+u8), `0x08` CONTAINER (u8 type + switch), `0x10` CLASSIFY (u8 tier),
`0x20` PODIUM (podium block), `0x40` DECOKIT (u16), `0x80` spare.

### Not extracted, on purpose

* `frame_group` / sprites / animation phases — `GameItemAnimationPhase` is disabled at
  client version >= 1281, so no phase byte is ever read at 1530.
* item names and descriptions — no protocol use (`--dump` decodes them transiently for
  identification only; they never reach the output file).
* `staticdata`, `proficiencies`, `map`, `backdrop_map`, `catalog-content.json` — no wire effect.

### The content revision is diagnostic only

`items1530.bin` carries a copy of the parsed `assets.json.sha256` value purely so a stale asset
file is easy to spot. The login packet must **re-parse** `things/1530/assets.json.sha256` at
runtime and send `tostring(value)` (trim, whole-string digits, require `1 <= v <= 0xFFFF`, else
`"0"`), per `docs/appearances-assets.md` §6 and its VERIFIER note about the two copies drifting
apart. Do not source the wire string from this header.
