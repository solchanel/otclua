#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extract_appearances.py -- one-time, offline extractor for luaclient item metadata.

Reads the raw (uncompressed, header-less) protobuf asset file
    <things-dir>/appearances-<hash>.dat
with a minimal hand-rolled protobuf reader (no protobuf library) and writes the
compact metadata table consumed at runtime by proto/items.lua.

v1 extracted only the seven "which attribute blocks does ProtocolGame::getItem read"
bits.  v2 additionally extracts everything the BOT layer needs (docs/vbot/gaps.md P0-1):
the walkability / rendering / interaction flags, the per-item scalars (ground speed,
minimap colour, elevation, lenshelp id, cloth slot) and the item NAMES.

  * per-item-id flag bytes FLAGS1..FLAGS5
  * per-item-id scalar columns GROUNDSPEED u16, MINIMAPCOLOR u8, ELEVATION u8,
    LENSHELP u16, CLOTHSLOT u8
  * a sparse name index + blob (only 8 951 of 43 536 objects carry Appearance.name)
  * the max object id      (so the loader can tell "hole in the id range" from "out of range")
  * the max outfit/effect/missile ids (bounds checks that ARE byte-affecting inside
    the batched magic-effects loop -- see docs/appearances-assets.md VERIFIER)
  * a diagnostic copy of the content revision from assets.json.sha256

frame_group (Appearance field 2) and description (5) are still deliberately NOT parsed:
sprites/animation are dead at 1530 (GameItemAnimationPhase is disabled at >=1281).

============================================================================
 FILE FORMAT -- assets/items1530.bin   (all integers little-endian, unsigned)
 This block is duplicated verbatim at the top of proto/items.lua.
============================================================================
 off  size  field              value for this asset set
   0     4  magic              "LCIT"
   4     1  version            2                      (v1 = 1; the loader accepts both)
   5     1  headerSize         40                     (v1 = 32)
   6     2  categoryCount      4      (item, creature/outfit, effect, missile)
   8     4  itemArrayLen       62145  (maxItemId+1; valid ids 1..62144)
  12     4  creatureArrayLen   10004
  16     4  effectArrayLen       344
  20     4  missileArrayLen       83
  24     4  objectCount        43536
  28     2  contentRevision    42196   (diagnostic only: the login packet must re-parse
                                        assets.json.sha256 at runtime)
  30     2  reserved           0
  32     1  sectionCount       12
  33     3  reserved           0,0,0
  36     4  sectionTableOff    40
  40  12*N  section directory
 ...        section payloads (in directory order, each 4-byte aligned)

 The first 32 bytes are byte-identical in layout to v1, so a v1 header parser reads
 itemArrayLen/objectCount/contentRevision out of a v2 file unchanged.  Everything new
 hangs off the section directory, so v3 may add sections without breaking this loader:
 an unknown sectionId is skipped, and a MISSING section reads as all-zero.

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
    5  GROUNDSPEED      2      2*itemArrayLen 124290  bank.waypoints (0 = not a ground; max 1200)
    6  MINIMAPCOLOR     1      itemArrayLen  62145    automap.color (0 = none; max 215)
    7  ELEVATION        1      itemArrayLen  62145    height.elevation (0..24 observed)
    8  LENSHELP         2      2*itemArrayLen 124290  lenshelp.id (0 = none; 1104/1105 matter)
    9  CLOTHSLOT        1      itemArrayLen  62145    clothes.slot (0 = none; max 12)
   10  NAMEIDX          6      6*8951 = 53706         sparse, ASCENDING by id:
                                                        u16 itemId, u32 offsetIntoNameBlob
   11  NAMEBLOB         1      149730                 concatenated NUL-terminated UTF-8
   12  FLAGS5           1      itemArrayLen  62145    bits that v1's FLAGS1 conflates

 FLAGS1 (unchanged from v1 -- do not renumber; proto/parser.lua reads these)
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
   0x20 NOT_PATHABLE      avoid                    #16  has && value    :242
   0x40 NOT_MOVEABLE      unmove                   #14  has && value    :234
   0x80 BLOCK_PROJECTILE  unsight                  #15  has && value    :238

 FLAGS3 -- interaction
   0x01 PICKUPABLE        take                     #18  :248
   0x02 USABLE            usable                   #7   :212
   0x04 MULTIUSE          multiuse                 #9   :204
   0x08 FORCE_USE         forceuse                 #8   :208
   0x10 FLUID_CONTAINER   liquidcontainer          #19  :252
   0x20 SPLASH            liquidpool               #12  :226
   0x40 HANGABLE          hang                     #20  :256
   0x80 WRITABLE          has_write() | has_write_once()  #10/#11 PRESENCE  :216/:221

 FLAGS4 -- misc
   0x01 ROTATEABLE        rotate                   #22  :285
   0x02 FULL_GROUND       fullbank                 #32  :325
   0x04 IGNORE_LOOK       ignore_look              #33  :329
   0x08 CORPSE            corpse                   #42  (no C++ flag; loot heuristic)
   0x10 PLAYER_CORPSE     player_corpse            #43
   0x20 LYING_OBJECT      lying_object             #28  :307
   0x40 WRAPABLE          wrap                     #37  :362
   0x80 UNWRAPABLE        unwrap                   #38  :366

 FLAGS5 -- bits FLAGS1 cannot express without changing v1 semantics
   0x01 STACKABLE         cumulative(6) ALONE      -- C++ ThingFlagAttrStackable, :200.
                          FLAGS1's CUMULATIVE also covers liquidcontainer/liquidpool
                          (they take the same u8 on the wire), which is a PROTOCOL-READ
                          bit, not Item::isStackable.  targetbot/looting.lua:285 merges
                          stacks on isStackable(), so the two must not be conflated.
   0x02 MARKET            has_market()             #36  PRESENCE  :340
                          ThingType only copies m_name into m_market.name inside this
                          branch, so `Item.create(id):getMarketData().name` -- what every
                          vBot name lookup actually calls -- is EMPTY for a named item
                          with no market block (3 852 of the 8 951 named ids, gold coin
                          among them).  items.name() returns the raw name, and
                          items.marketName() reproduces the vBot-visible value.
   0x04 ELEVATION         has_height()             #27  PRESENCE  :302
                          ThingType::hasElevation() is the FLAG, not `m_elevation > 0`:
                          4 ids carry height{elevation=0} and still increment
                          Tile::m_elevation (tile.cpp:1011-1012), which hasElevation(3)
                          reads.  The ELEVATION column alone cannot express them.
   0x08..0x80 (spare)

 NOTE 1: `bank`, `bottom`, `top`, `write`, `write_once`, `height`, `automap`, `lenshelp`,
         `clothes` and `market` are PRESENCE tests in C++ (has_x() with no value test) --
         do not require value != 0.  Every other boolean is has_x() && x().
         Measured on this asset set: NO varint boolean among the extracted fields is ever
         encoded with value 0, so presence and truth agree everywhere here.  The
         distinction is implemented anyway, because a future asset set may differ.
 NOTE 2: there is NO floor-change bit at 1530.  ThingFlagAttrFloorChange (const.h:1298) is
         only ever set from the legacy .dat path (thingtype.cpp:1096), so
         Tile::hasFloorChange() is permanently false.  Floor changes are inferred from
         LENSHELP (only 1104 and 1105 -- ladders 1100 and rope spots 1102 are deliberately
         NOT floor changes) + GROUND + NOT_PATHABLE + MINIMAPCOLOR 210..213, exactly as
         cavebot/walking.lua:102,117-160 does.
 NOTE 3: bank present but waypoints absent -> groundSpeed 0.  Tile::getGroundSpeed() returns
         that 0 VERBATIM; the 100 fallback applies only when the tile has no ground item at
         all (tile.cpp:562-569).  Creature::getStepDuration() separately substitutes 150 for
         a zero result (creature.cpp:1120-1121).  Keep BOTH fallbacks at their own call
         sites and do not "fix" a zero ground speed here.
============================================================================

Usage:
    python tools/extract_appearances.py [THINGS_DIR] [--out FILE] [--dump ID ...]

Defaults:
    --things-dir  D:/Claude/otclient_mehah1530/otclient/data/things/1530
    --out         <repo>/assets/items1530.bin

--dump ID  prints the decoded AppearanceFlags, the derived FLAGS1..5 bytes, every scalar
           column and the name of the given object ids, then exits without writing.
           Used for spot-verification against the C++ ThingType.
"""

import argparse
import glob
import hashlib
import os
import struct
import sys

MAGIC = b"LCIT"
VERSION = 2
HEADER_SIZE = 40           # v2; v1 was 32 and shares the first 32 bytes' layout
HEADER_SIZE_V1 = 32
CATEGORY_COUNT = 4
DIR_ENTRY_SIZE = 12

# ---------------------------------------------------------------- FLAGS1 (v1)
F_CUMULATIVE = 0x01
F_WEAROUT    = 0x02
F_EXPIRE     = 0x04
F_CONTAINER  = 0x08
F_CLASSIFY   = 0x10
F_PODIUM     = 0x20
F_DECOKIT    = 0x40

# ---------------------------------------------------------------- FLAGS2
F2_GROUND           = 0x01
F2_GROUND_BORDER    = 0x02
F2_ON_BOTTOM        = 0x04
F2_ON_TOP           = 0x08
F2_NOT_WALKABLE     = 0x10
F2_NOT_PATHABLE     = 0x20
F2_NOT_MOVEABLE     = 0x40
F2_BLOCK_PROJECTILE = 0x80

# ---------------------------------------------------------------- FLAGS3
F3_PICKUPABLE      = 0x01
F3_USABLE          = 0x02
F3_MULTIUSE        = 0x04
F3_FORCE_USE       = 0x08
F3_FLUID_CONTAINER = 0x10
F3_SPLASH          = 0x20
F3_HANGABLE        = 0x40
F3_WRITABLE        = 0x80

# ---------------------------------------------------------------- FLAGS4
F4_ROTATEABLE   = 0x01
F4_FULL_GROUND  = 0x02
F4_IGNORE_LOOK  = 0x04
F4_CORPSE       = 0x08
F4_PLAYER_CORPSE = 0x10
F4_LYING_OBJECT = 0x20
F4_WRAPABLE     = 0x40
F4_UNWRAPABLE   = 0x80

# ---------------------------------------------------------------- FLAGS5
F5_STACKABLE = 0x01
F5_MARKET    = 0x02
F5_ELEVATION = 0x04

BIT_NAMES = [
    (F_CUMULATIVE, "CUMULATIVE(0x01)"),
    (F_WEAROUT,    "WEAROUT   (0x02)"),
    (F_EXPIRE,     "EXPIRE    (0x04)"),
    (F_CONTAINER,  "CONTAINER (0x08)"),
    (F_CLASSIFY,   "CLASSIFY  (0x10)"),
    (F_PODIUM,     "PODIUM    (0x20)"),
    (F_DECOKIT,    "DECOKIT   (0x40)"),
]
BIT_NAMES2 = [
    (F2_GROUND, "GROUND"), (F2_GROUND_BORDER, "GROUND_BORDER"),
    (F2_ON_BOTTOM, "ON_BOTTOM"), (F2_ON_TOP, "ON_TOP"),
    (F2_NOT_WALKABLE, "NOT_WALKABLE"), (F2_NOT_PATHABLE, "NOT_PATHABLE"),
    (F2_NOT_MOVEABLE, "NOT_MOVEABLE"), (F2_BLOCK_PROJECTILE, "BLOCK_PROJECTILE"),
]
BIT_NAMES3 = [
    (F3_PICKUPABLE, "PICKUPABLE"), (F3_USABLE, "USABLE"), (F3_MULTIUSE, "MULTIUSE"),
    (F3_FORCE_USE, "FORCE_USE"), (F3_FLUID_CONTAINER, "FLUID_CONTAINER"),
    (F3_SPLASH, "SPLASH"), (F3_HANGABLE, "HANGABLE"), (F3_WRITABLE, "WRITABLE"),
]
BIT_NAMES4 = [
    (F4_ROTATEABLE, "ROTATEABLE"), (F4_FULL_GROUND, "FULL_GROUND"),
    (F4_IGNORE_LOOK, "IGNORE_LOOK"), (F4_CORPSE, "CORPSE"),
    (F4_PLAYER_CORPSE, "PLAYER_CORPSE"), (F4_LYING_OBJECT, "LYING_OBJECT"),
    (F4_WRAPABLE, "WRAPABLE"), (F4_UNWRAPABLE, "UNWRAPABLE"),
]
BIT_NAMES5 = [(F5_STACKABLE, "STACKABLE"), (F5_MARKET, "MARKET"),
              (F5_ELEVATION, "ELEVATION")]

# --------------------------------------------------------------- section ids
S_FLAGS1       = 1
S_FLAGS2       = 2
S_FLAGS3       = 3
S_FLAGS4       = 4
S_GROUNDSPEED  = 5
S_MINIMAPCOLOR = 6
S_ELEVATION    = 7
S_LENSHELP     = 8
S_CLOTHSLOT    = 9
S_NAMEIDX      = 10
S_NAMEBLOB     = 11
S_FLAGS5       = 12

# AppearanceFlags field numbers -> bit.  Booleans with proto2 has_x() && x().
BOOL_FIELD_TO_BIT = {
    6:  F_CUMULATIVE,   # cumulative
    19: F_CUMULATIVE,   # liquidcontainer
    12: F_CUMULATIVE,   # liquidpool
    53: F_WEAROUT,      # wearout
    54: F_EXPIRE,       # clockexpire
    55: F_EXPIRE,       # expire
    56: F_EXPIRE,       # expirestop
    5:  F_CONTAINER,    # container
    46: F_PODIUM,       # show_off_socket
    57: F_DECOKIT,      # deco_kit
}
FIELD_UPGRADECLASSIFICATION = 48  # LEN submessage, inner field 1 = upgrade_classification

BOOL_FIELD_TO_BIT2 = {
    2:  F2_GROUND_BORDER,     # clip
    13: F2_NOT_WALKABLE,      # unpass
    16: F2_NOT_PATHABLE,      # avoid
    14: F2_NOT_MOVEABLE,      # unmove
    15: F2_BLOCK_PROJECTILE,  # unsight
}
# has_x() only -- thingtype.cpp:179/188/192.  May arrive as varint or LEN.
PRESENCE_FIELD_TO_BIT2 = {
    1: F2_GROUND,       # bank
    3: F2_ON_BOTTOM,    # bottom
    4: F2_ON_TOP,       # top
}
BOOL_FIELD_TO_BIT3 = {
    18: F3_PICKUPABLE,       # take
    7:  F3_USABLE,           # usable
    9:  F3_MULTIUSE,         # multiuse
    8:  F3_FORCE_USE,        # forceuse
    19: F3_FLUID_CONTAINER,  # liquidcontainer
    12: F3_SPLASH,           # liquidpool
    20: F3_HANGABLE,         # hang
}
PRESENCE_FIELD_TO_BIT3 = {
    10: F3_WRITABLE,   # write
    11: F3_WRITABLE,   # write_once
}
BOOL_FIELD_TO_BIT4 = {
    22: F4_ROTATEABLE,     # rotate
    32: F4_FULL_GROUND,    # fullbank
    33: F4_IGNORE_LOOK,    # ignore_look
    42: F4_CORPSE,         # corpse
    43: F4_PLAYER_CORPSE,  # player_corpse
    28: F4_LYING_OBJECT,   # lying_object
    37: F4_WRAPABLE,       # wrap
    38: F4_UNWRAPABLE,     # unwrap
}
BOOL_FIELD_TO_BIT5 = {
    6: F5_STACKABLE,       # cumulative ALONE (not liquidcontainer/liquidpool)
}
PRESENCE_FIELD_TO_BIT5 = {
    36: F5_MARKET,         # market
    27: F5_ELEVATION,      # height -- ThingType::hasElevation() is the FLAG, not the value:
                           # 4 ids carry height{elevation=0} and still count towards
                           # Tile::m_elevation (tile.cpp:1011-1012).
}

# LEN submessages carrying one scalar: field -> (column, inner field number, width)
SUBMSG = {
    1:  ("groundSpeed",  1, 2),   # bank.waypoints
    27: ("elevation",    1, 1),   # height.elevation
    30: ("minimapColor", 1, 1),   # automap.color
    31: ("lensHelp",     1, 2),   # lenshelp.id
    34: ("clothSlot",    1, 1),   # clothes.slot
}
SCALAR_COLUMNS = ("groundSpeed", "elevation", "minimapColor", "lensHelp", "clothSlot")

# Appearance field numbers
A_ID          = 1
A_FRAME_GROUP = 2   # skipped entirely
A_FLAGS       = 3
A_NAME        = 4


# ---------------------------------------------------------------------------
# minimal protobuf reader
# ---------------------------------------------------------------------------

def read_varint(buf, i):
    """Return (value, next_index). Raises IndexError past the end."""
    result = 0
    shift = 0
    while True:
        c = buf[i]
        i += 1
        result |= (c & 0x7F) << shift
        if c < 0x80:
            return result, i
        shift += 7
        if shift > 63:
            raise ValueError("varint too long at offset %d" % i)


def iter_fields(buf, i, stop, stats=None):
    """Yield (field_number, wire_type, varint_value_or_None, sub_start, sub_stop)
    over the protobuf region [i, stop). Nesting-aware: never scans for raw tag bytes."""
    while i < stop:
        key, i = read_varint(buf, i)
        fn = key >> 3
        wt = key & 7
        if stats is not None:
            stats[(fn, wt)] = stats.get((fn, wt), 0) + 1
        if wt == 0:
            v, i = read_varint(buf, i)
            yield fn, wt, v, None, None
        elif wt == 2:
            ln, i = read_varint(buf, i)
            s = i
            i += ln
            if i > stop:
                raise ValueError("length-delimited field %d overruns region" % fn)
            yield fn, wt, None, s, i
        elif wt == 5:                      # fixed32 -- does not occur in this file
            yield fn, wt, None, None, None
            i += 4
        elif wt == 1:                      # fixed64 -- does not occur in this file
            yield fn, wt, None, None, None
            i += 8
        else:
            raise ValueError("unsupported wire type %d (field %d) at %d" % (wt, fn, i))
    if i != stop:
        raise ValueError("region overrun: ended at %d, expected %d" % (i, stop))


def first_inner_varint(buf, start, stop, want_fn):
    """Value of the first varint subfield `want_fn` of a LEN submessage, or 0."""
    for g, gwt, gv, _a, _b in iter_fields(buf, start, stop):
        if g == want_fn and gwt == 0:
            return gv
    return 0


def flags_of_region(buf, start, stop, field_stats=None):
    """Decode one AppearanceFlags message into (f1, f2, f3, f4, f5, scalar columns)."""
    f1 = f2 = f3 = f4 = f5 = 0
    cols = {}
    for fn, wt, v, ss, se in iter_fields(buf, start, stop, field_stats):
        if wt == 0:
            # proto2 has_x() && x(): presence AND truth.
            if v != 0:
                b = BOOL_FIELD_TO_BIT.get(fn)
                if b:
                    f1 |= b
                b = BOOL_FIELD_TO_BIT2.get(fn)
                if b:
                    f2 |= b
                b = BOOL_FIELD_TO_BIT3.get(fn)
                if b:
                    f3 |= b
                b = BOOL_FIELD_TO_BIT4.get(fn)
                if b:
                    f4 |= b
                b = BOOL_FIELD_TO_BIT5.get(fn)
                if b:
                    f5 |= b
            # presence-only fields, varint encoding
            f2 |= PRESENCE_FIELD_TO_BIT2.get(fn, 0)
            f3 |= PRESENCE_FIELD_TO_BIT3.get(fn, 0)
            f5 |= PRESENCE_FIELD_TO_BIT5.get(fn, 0)
        elif wt == 2:
            # presence-only fields, LEN encoding (submessages)
            f2 |= PRESENCE_FIELD_TO_BIT2.get(fn, 0)
            f3 |= PRESENCE_FIELD_TO_BIT3.get(fn, 0)
            f5 |= PRESENCE_FIELD_TO_BIT5.get(fn, 0)
            if fn == FIELD_UPGRADECLASSIFICATION:
                # read decision is getClassification() != 0, not mere presence
                if first_inner_varint(buf, ss, se, 1) > 0:
                    f1 |= F_CLASSIFY
            sub = SUBMSG.get(fn)
            if sub is not None:
                col, inner_fn, _w = sub
                cols[col] = first_inner_varint(buf, ss, se, inner_fn)
    return f1, f2, f3, f4, f5, cols


# ---------------------------------------------------------------------------
# main pass
# ---------------------------------------------------------------------------

class Objects(object):
    """Everything the writer needs, keyed by object id."""

    def __init__(self):
        self.f1 = {}
        self.f2 = {}
        self.f3 = {}
        self.f4 = {}
        self.f5 = {}
        self.cols = {c: {} for c in SCALAR_COLUMNS}
        self.names = {}


def parse_appearances(buf, want_names=True):
    """Single pass over the whole Appearances message.
    Returns (Objects, max_id list[5], counts list[5], flag_field_stats)."""
    max_id = [0, 0, 0, 0, 0]     # index by top-level field number 1..4
    counts = [0, 0, 0, 0, 0]
    objs = Objects()
    flag_field_stats = {}

    n = len(buf)
    for top_fn, top_wt, _v, s, e in iter_fields(buf, 0, n):
        if top_wt != 2 or not (1 <= top_fn <= 4):
            continue                        # e.g. field 5 special_meaning_appearance_ids
        obj_id = None
        flags_start = flags_stop = None
        name = None
        for fn, wt, v, ss, se in iter_fields(buf, s, e):
            if fn == A_ID and wt == 0:
                obj_id = v
            elif fn == A_FLAGS and wt == 2:
                flags_start, flags_stop = ss, se
            elif want_names and fn == A_NAME and wt == 2:
                name = bytes(buf[ss:se])
            # A_FRAME_GROUP (2) deliberately skipped
        if obj_id is None:
            raise ValueError("appearance without id in category %d" % top_fn)
        counts[top_fn] += 1
        if obj_id > max_id[top_fn]:
            max_id[top_fn] = obj_id
        if top_fn == 1:                      # objects (items) only
            if obj_id in objs.f1:
                raise ValueError("duplicate object id %d" % obj_id)
            f1 = f2 = f3 = f4 = f5 = 0
            cols = {}
            if flags_start is not None:
                f1, f2, f3, f4, f5, cols = flags_of_region(
                    buf, flags_start, flags_stop, flag_field_stats)
            objs.f1[obj_id] = f1
            objs.f2[obj_id] = f2
            objs.f3[obj_id] = f3
            objs.f4[obj_id] = f4
            objs.f5[obj_id] = f5
            for col, value in cols.items():
                if value:
                    objs.cols[col][obj_id] = value
            if name is not None:
                objs.names[obj_id] = name
    return objs, max_id, counts, flag_field_stats


def find_appearances_file(things_dir):
    matches = sorted(glob.glob(os.path.join(things_dir, "appearances-*.dat")))
    if not matches:
        raise SystemExit("no appearances-*.dat under %s" % things_dir)
    if len(matches) > 1:
        raise SystemExit("ambiguous: %d appearances-*.dat files under %s" % (len(matches), things_dir))
    return matches[0]


def read_content_revision(things_dir):
    """docs sec.6: assets.json.sha256 holds a DECIMAL revision, not a hash.
    Parse it (trim, whole-string digits, 1 <= v <= 0xFFFF), else 0."""
    p = os.path.join(things_dir, "assets.json.sha256")
    try:
        with open(p, "rb") as f:
            txt = f.read().decode("ascii", "replace").strip()
    except OSError:
        return 0
    if not txt.isdigit():
        return 0
    v = int(txt)
    return v if 1 <= v <= 0xFFFF else 0


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# writer
# ---------------------------------------------------------------------------

def build_columns(objs, item_len):
    """Materialise every dense column plus the sparse name index/blob."""
    def dense_u8(src, what):
        t = bytearray(item_len)
        for oid, v in src.items():
            if not (0 <= v <= 0xFF):
                raise ValueError("%s of id %d is %d, does not fit in u8" % (what, oid, v))
            t[oid] = v
        return bytes(t)

    def dense_u16(src, what):
        t = bytearray(item_len * 2)
        for oid, v in src.items():
            if not (0 <= v <= 0xFFFF):
                raise ValueError("%s of id %d is %d, does not fit in u16" % (what, oid, v))
            t[oid * 2] = v & 0xFF
            t[oid * 2 + 1] = (v >> 8) & 0xFF
        return bytes(t)

    name_ids = sorted(objs.names)
    idx = bytearray()
    blob = bytearray()
    for oid in name_ids:
        if oid > 0xFFFF:
            raise ValueError("name index needs a u32 id column: id %d" % oid)
        idx += struct.pack("<HI", oid, len(blob))
        raw = objs.names[oid]
        if b"\0" in raw:
            raise ValueError("name of id %d contains a NUL" % oid)
        blob += raw
        blob += b"\0"

    return [
        (S_FLAGS1,       1, dense_u8(objs.f1, "FLAGS1")),
        (S_FLAGS2,       1, dense_u8(objs.f2, "FLAGS2")),
        (S_FLAGS3,       1, dense_u8(objs.f3, "FLAGS3")),
        (S_FLAGS4,       1, dense_u8(objs.f4, "FLAGS4")),
        (S_FLAGS5,       1, dense_u8(objs.f5, "FLAGS5")),
        (S_GROUNDSPEED,  2, dense_u16(objs.cols["groundSpeed"], "bank.waypoints")),
        (S_MINIMAPCOLOR, 1, dense_u8(objs.cols["minimapColor"], "automap.color")),
        (S_ELEVATION,    1, dense_u8(objs.cols["elevation"], "height.elevation")),
        (S_LENSHELP,     2, dense_u16(objs.cols["lensHelp"], "lenshelp.id")),
        (S_CLOTHSLOT,    1, dense_u8(objs.cols["clothSlot"], "clothes.slot")),
        (S_NAMEIDX,      6, bytes(idx)),
        (S_NAMEBLOB,     1, bytes(blob)),
    ]


def write_file(path, sections, item_len, max_id, counts, rev):
    n = len(sections)
    dir_off = HEADER_SIZE
    payload_off = dir_off + n * DIR_ENTRY_SIZE
    payload_off = (payload_off + 3) & ~3

    entries = []
    blobs = []
    off = payload_off
    for sid, elem, data in sections:
        entries.append(struct.pack("<BBHII", sid, elem, 0, off, len(data)))
        blobs.append((off, data))
        off += len(data)
        pad = (-off) & 3
        if pad:
            blobs.append((off, b"\0" * pad))
            off += pad

    header = MAGIC + struct.pack(
        "<BBHIIIIIHHBBBBI",
        VERSION, HEADER_SIZE, CATEGORY_COUNT,
        item_len, max_id[2] + 1, max_id[3] + 1, max_id[4] + 1,
        counts[1], rev, 0,
        n, 0, 0, 0, dir_off)
    assert len(header) == HEADER_SIZE, len(header)

    out = bytearray(off)
    out[0:HEADER_SIZE] = header
    p = dir_off
    for e in entries:
        out[p:p + DIR_ENTRY_SIZE] = e
        p += DIR_ENTRY_SIZE
    for o, data in blobs:
        out[o:o + len(data)] = data

    outdir = os.path.dirname(os.path.abspath(path))
    if outdir and not os.path.isdir(outdir):
        os.makedirs(outdir)
    with open(path, "wb") as f:
        f.write(bytes(out))
    return len(out)


# ---------------------------------------------------------------------------

def bits_str(value, table):
    return " ".join(nm for m, nm in table if value & m) or "-"


def do_dump(buf, dat, wanted_ids):
    objs, _max_id, _counts, _stats = parse_appearances(buf, want_names=True)
    wanted = set(wanted_ids)
    raw = {}
    for top_fn, top_wt, _v, s, e in iter_fields(buf, 0, len(buf)):
        if top_wt != 2 or top_fn != 1:
            continue
        oid = None
        fs = fe = None
        for fn, wt, v, ss, se in iter_fields(buf, s, e):
            if fn == A_ID and wt == 0:
                oid = v
            elif fn == A_FLAGS and wt == 2:
                fs, fe = ss, se
        if oid in wanted:
            lst = []
            if fs is not None:
                for fn, wt, v, ss, se in iter_fields(buf, fs, fe):
                    if wt == 0:
                        lst.append("%d=%d" % (fn, v))
                    elif wt == 2:
                        inner = []
                        try:
                            for g, gwt, gv, _a, _b in iter_fields(buf, ss, se):
                                inner.append("%d=%s" % (g, gv if gwt == 0 else "<len>"))
                        except Exception:
                            inner.append("<unparsed>")
                        lst.append("%d{%s}" % (fn, ",".join(inner)))
            raw[oid] = lst
    print("source: %s" % dat)
    for oid in wanted_ids:
        if oid not in objs.f1:
            print("id %-6d  ABSENT (hole in the id range; every column reads 0)" % oid)
            continue
        nm = objs.names.get(oid)
        nm = nm.decode("utf-8", "replace") if nm is not None else None
        print("id %-6d  name=%r" % (oid, nm))
        print("    FLAGS1=0x%02X  %s" % (objs.f1[oid], bits_str(objs.f1[oid], BIT_NAMES)))
        print("    FLAGS2=0x%02X  %s" % (objs.f2[oid], bits_str(objs.f2[oid], BIT_NAMES2)))
        print("    FLAGS3=0x%02X  %s" % (objs.f3[oid], bits_str(objs.f3[oid], BIT_NAMES3)))
        print("    FLAGS4=0x%02X  %s" % (objs.f4[oid], bits_str(objs.f4[oid], BIT_NAMES4)))
        print("    FLAGS5=0x%02X  %s" % (objs.f5[oid], bits_str(objs.f5[oid], BIT_NAMES5)))
        print("    groundSpeed=%d minimapColor=%d elevation=%d lensHelp=%d clothSlot=%d"
              % (objs.cols["groundSpeed"].get(oid, 0), objs.cols["minimapColor"].get(oid, 0),
                 objs.cols["elevation"].get(oid, 0), objs.cols["lensHelp"].get(oid, 0),
                 objs.cols["clothSlot"].get(oid, 0)))
        print("    raw AppearanceFlags fields: %s"
              % (", ".join(raw.get(oid, [])) or "(no flags message)"))
    return 0


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(here)
    ap = argparse.ArgumentParser(
        description="extract the item metadata table from appearances-*.dat",
        epilog="THINGS_DIR may also be given as --things-dir or in $LUACLIENT_THINGS_DIR; "
               "with none of the three, the reference install is used if it exists.")
    # The input directory is a CLI argument, not a baked-in Windows path: this
    # script has to run on Linux too (docs/portability.md).  Resolution order:
    #   positional  >  --things-dir  >  $LUACLIENT_THINGS_DIR  >  reference install
    ap.add_argument("things_dir", nargs="?", default=None, metavar="THINGS_DIR",
                    help="directory holding appearances-*.dat and assets.json.sha256")
    ap.add_argument("--things-dir", dest="things_dir_opt", default=None,
                    help="same as the positional THINGS_DIR")
    ap.add_argument("--out", default=os.path.join(repo, "assets", "items1530.bin"))
    ap.add_argument("--dump", type=int, nargs="+", metavar="ID",
                    help="dump the decoded flags/columns/name for these object ids and exit")
    args = ap.parse_args(argv)

    REFERENCE_THINGS_DIR = "D:/Claude/otclient_mehah1530/otclient/data/things/1530"
    things_dir = (args.things_dir or args.things_dir_opt
                  or os.environ.get("LUACLIENT_THINGS_DIR"))
    if not things_dir:
        if os.path.isdir(REFERENCE_THINGS_DIR):
            things_dir = REFERENCE_THINGS_DIR
        else:
            raise SystemExit(
                "no things directory given.  Pass it as an argument:\n"
                "    python tools/extract_appearances.py /path/to/data/things/1530\n"
                "or set LUACLIENT_THINGS_DIR.")
    things_dir = os.path.expanduser(things_dir)
    args.things_dir = things_dir

    dat = find_appearances_file(things_dir)
    with open(dat, "rb") as f:
        buf = f.read()

    if args.dump:
        return do_dump(buf, dat, args.dump)

    objs, max_id, counts, flag_field_stats = parse_appearances(buf, want_names=True)

    # ---- invariants the Lua predicates rely on -----------------------------
    # items.isStackable() must be FLAGS5 STACKABLE, never FLAGS1 CUMULATIVE.  Assert the
    # two really are different sets, so a future asset set cannot silently make the
    # cheap-looking "CUMULATIVE minus fluid/splash" shortcut wrong somewhere else.
    conflated = sum(1 for oid, v in objs.f1.items()
                    if (v & F_CUMULATIVE) and not (objs.f5[oid] & F5_STACKABLE))
    both = sum(1 for oid, v in objs.f5.items()
               if (v & F5_STACKABLE) and (objs.f3[oid] & (F3_FLUID_CONTAINER | F3_SPLASH)))
    if both:
        raise SystemExit("invariant broken: %d ids are cumulative AND a fluid/splash" % both)

    item_len = max_id[1] + 1
    sections = build_columns(objs, item_len)
    rev = read_content_revision(args.things_dir)
    total = write_file(args.out, sections, item_len, max_id, counts, rev)

    f1t = sections[0][2]
    f2t = sections[1][2]
    f3t = sections[2][2]
    f4t = sections[3][2]
    f5t = sections[4][2]

    print("source            : %s" % dat)
    print("source size       : %d bytes" % len(buf))
    print("source sha256     : %s" % sha256_of(dat))
    print("content revision  : %d (from assets.json.sha256, diagnostic copy only)" % rev)
    print("format version    : %d  (header %d bytes, %d sections)"
          % (VERSION, HEADER_SIZE, len(sections)))
    print("object count      : %d   max id %d  (array len %d)" % (counts[1], max_id[1], item_len))
    print("outfit count      : %d   max id %d  (array len %d)" % (counts[2], max_id[2], max_id[2] + 1))
    print("effect count      : %d   max id %d  (array len %d)" % (counts[3], max_id[3], max_id[3] + 1))
    print("missile count     : %d   max id %d  (array len %d)" % (counts[4], max_id[4], max_id[4] + 1))
    print("names             : %d ids, blob %d bytes (index %d bytes)"
          % (len(objs.names), len(sections[11][2]), len(sections[10][2])))
    print("  of which market : %d  (getMarketData().name is empty for the other %d)"
          % (sum(1 for v in objs.f5.values() if v & F5_MARKET),
             len(objs.names) - sum(1 for v in objs.f5.values() if v & F5_MARKET)))
    print("cumulative-but-not-stackable (fluid/splash): %d" % conflated)
    print("output            : %s" % os.path.abspath(args.out))
    print("output size       : %d bytes" % total)
    print("output sha256     : %s" % sha256_of(args.out))
    print("section directory :")
    for sid, elem, data in sections:
        print("  id %-2d elem %d  %8d bytes" % (sid, elem, len(data)))
    print("flag-bit histograms (ids with the bit set):")
    for tbl, table, nm in ((f1t, BIT_NAMES, "FLAGS1"), (f2t, BIT_NAMES2, "FLAGS2"),
                           (f3t, BIT_NAMES3, "FLAGS3"), (f4t, BIT_NAMES4, "FLAGS4"),
                           (f5t, BIT_NAMES5, "FLAGS5")):
        for mask, label in table:
            print("  %s %-18s %6d" % (nm, label.split("(")[0].strip(),
                                      sum(1 for b in tbl if b & mask)))
    print("scalar columns    :")
    for col in SCALAR_COLUMNS:
        d = objs.cols[col]
        print("  %-13s %6d ids, max %d" % (col, len(d), max(d.values()) if d else 0))
    print("AppearanceFlags field/wire-type histogram (top 12 by count):")
    for (fn, wt), c in sorted(flag_field_stats.items(), key=lambda kv: -kv[1])[:12]:
        print("  field %-3d wt %d : %7d" % (fn, wt, c))
    exotic = [k for k in flag_field_stats if k[1] in (1, 5)]
    print("exotic wire types (1/5) seen: %s" % (exotic if exotic else "none"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
