#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extract_appearances.py -- one-time, offline extractor for luaclient item metadata.

Reads the raw (uncompressed, header-less) protobuf asset file
    <things-dir>/appearances-<hash>.dat
with a minimal hand-rolled protobuf reader (no protobuf library) and writes the
compact flag table consumed at runtime by proto/items.lua.

Only four things are extracted:
  * per-item-id flag byte (which attribute blocks ProtocolGame::getItem reads)
  * the max object id      (so the loader can tell "hole in the id range" from "out of range")
  * the max outfit/effect/missile ids (bounds checks that ARE byte-affecting inside
    the batched magic-effects loop -- see docs/appearances-assets.md VERIFIER)
  * a diagnostic copy of the content revision from assets.json.sha256

frame_group (Appearance field 2), name (4) and description (5) are deliberately NOT
parsed: sprites/animation are dead at 1530 (GameItemAnimationPhase is disabled at
>=1281) and names are not needed by the protocol.

============================================================================
 FILE FORMAT -- assets/items1530.bin   (all integers little-endian, unsigned)
 This block is duplicated verbatim at the top of proto/items.lua.
============================================================================
 off  size  field             value / meaning
   0     4  magic             ASCII "LCIT"
   4     1  version           1
   5     1  headerSize        32  (offset of the first flag byte)
   6     2  categoryCount     4   (item, creature/outfit, effect, missile)
   8     4  itemArrayLen      maxItemId + 1        (62145) -- valid item ids: 1 .. itemArrayLen-1
  12     4  creatureArrayLen  maxOutfitId + 1      (10004)
  16     4  effectArrayLen    maxEffectId + 1        (344)
  20     4  missileArrayLen   maxMissileId + 1        (83)
  24     4  objectCount       number of item appearances actually present (43536)
  28     2  contentRevision   diagnostic copy of assets.json.sha256 (42196).
                              NOT authoritative: the login packet must re-parse
                              assets.json.sha256 at runtime (docs sec.6 / VERIFIER).
  30     2  reserved          0
  32     N  flags[]           itemArrayLen bytes, flags[i] = flag byte of item id i.
                              index 0 (id 0) is always 0x00.
 total size = 32 + itemArrayLen bytes (= 62177 for this asset set)

 FLAG BYTE BITS (must match proto/items.lua and API.md exactly)
  bit 0  0x01  CUMULATIVE  read u8 count/subtype  <- cumulative(6) | liquidcontainer(19) | liquidpool(12)
  bit 1  0x02  WEAROUT     read u32 charges + u8  <- wearout(53)
  bit 2  0x04  EXPIRE      read u32 duration + u8 <- clockexpire(54) | expire(55) | expirestop(56)
  bit 3  0x08  CONTAINER   read u8 type + switch  <- container(5)
  bit 4  0x10  CLASSIFY    read u8 tier           <- upgradeclassification(48).upgrade_classification > 0
  bit 5  0x20  PODIUM      read podium block      <- show_off_socket(46)
  bit 6  0x40  DECOKIT     read u16               <- deco_kit(57)
  bit 7  0x80  (spare, always 0)

 Boolean fields use proto2 "presence AND truth" semantics (has_x() && x()), matching
 ThingType::applyAppearanceFlags. upgradeclassification is presence-only in C++ but the
 read decision is getClassification() != 0, so we require the inner value > 0.
============================================================================

Usage:
    python tools/extract_appearances.py [--things-dir DIR] [--out FILE] [--dump ID ...]

Defaults:
    --things-dir  D:/Claude/otclient_mehah1530/otclient/data/things/1530
    --out         <repo>/assets/items1530.bin

--dump ID  prints the decoded AppearanceFlags (plus the name string, for identification
           only -- names are never written to the output file) of the given object ids
           and exits without writing anything.  Used for spot-verification.
"""

import argparse
import glob
import hashlib
import os
import struct
import sys

MAGIC = b"LCIT"
VERSION = 1
HEADER_SIZE = 32
CATEGORY_COUNT = 4

# flag bits
F_CUMULATIVE = 0x01
F_WEAROUT    = 0x02
F_EXPIRE     = 0x04
F_CONTAINER  = 0x08
F_CLASSIFY   = 0x10
F_PODIUM     = 0x20
F_DECOKIT    = 0x40

BIT_NAMES = [
    (F_CUMULATIVE, "CUMULATIVE(0x01)"),
    (F_WEAROUT,    "WEAROUT   (0x02)"),
    (F_EXPIRE,     "EXPIRE    (0x04)"),
    (F_CONTAINER,  "CONTAINER (0x08)"),
    (F_CLASSIFY,   "CLASSIFY  (0x10)"),
    (F_PODIUM,     "PODIUM    (0x20)"),
    (F_DECOKIT,    "DECOKIT   (0x40)"),
]

# AppearanceFlags field numbers -> bit.  Booleans only (presence AND truth).
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

# Appearance field numbers
A_ID          = 1
A_FRAME_GROUP = 2   # skipped entirely
A_FLAGS       = 3
A_NAME        = 4   # only read by --dump, never written to the output


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


def flags_of_region(buf, start, stop, field_stats=None):
    """Decode one AppearanceFlags message into a flag byte."""
    bits = 0
    for fn, wt, v, ss, se in iter_fields(buf, start, stop, field_stats):
        if wt == 0:
            bit = BOOL_FIELD_TO_BIT.get(fn)
            # proto2 has_x() && x(): presence AND truth.
            if bit is not None and v != 0:
                bits |= bit
        elif wt == 2 and fn == FIELD_UPGRADECLASSIFICATION:
            cls = 0
            for g, gwt, gv, _, _ in iter_fields(buf, ss, se):
                if g == 1 and gwt == 0:
                    cls = gv
            # read decision is getClassification() != 0, not mere presence
            if cls > 0:
                bits |= F_CLASSIFY
    return bits


# ---------------------------------------------------------------------------
# main pass
# ---------------------------------------------------------------------------

def parse_appearances(buf, want_names=False):
    """Single pass over the whole Appearances message.
    Returns (item_flags dict, max_id list[5], counts list[5], names dict, flag_field_stats)."""
    max_id = [0, 0, 0, 0, 0]     # index by top-level field number 1..4
    counts = [0, 0, 0, 0, 0]
    item_flags = {}
    names = {}
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
                name = bytes(buf[ss:se]).decode("utf-8", "replace")
            # A_FRAME_GROUP (2) deliberately skipped
        if obj_id is None:
            raise ValueError("appearance without id in category %d" % top_fn)
        counts[top_fn] += 1
        if obj_id > max_id[top_fn]:
            max_id[top_fn] = obj_id
        if top_fn == 1:                      # objects (items) only
            bits = 0
            if flags_start is not None:
                bits = flags_of_region(buf, flags_start, flags_stop, flag_field_stats)
            if obj_id in item_flags:
                raise ValueError("duplicate object id %d" % obj_id)
            item_flags[obj_id] = bits
            if want_names and name is not None:
                names[obj_id] = name
    return item_flags, max_id, counts, names, flag_field_stats


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


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    repo = os.path.dirname(here)
    ap = argparse.ArgumentParser(
        description="extract item flag table from appearances-*.dat",
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
                    help="dump decoded flags (and name) for these object ids and exit")
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
        item_flags, max_id, counts, names, _ = parse_appearances(buf, want_names=True)
        wanted = set(args.dump)
        # second targeted pass for the raw flag field list of each wanted id
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
        for oid in args.dump:
            if oid not in item_flags:
                print("id %-6d  ABSENT (hole in the id range; flags 0x00)" % oid)
                continue
            fb = item_flags[oid]
            names_on = " ".join(nm for m, nm in BIT_NAMES if fb & m) or "(none)"
            print("id %-6d  flags=0x%02X  %-20s name=%r" % (oid, fb, names_on.replace("  ", " "),
                                                            names.get(oid)))
            print("            raw AppearanceFlags fields: %s" % (", ".join(raw.get(oid, [])) or "(no flags message)"))
        return 0

    item_flags, max_id, counts, _names, flag_field_stats = parse_appearances(buf)

    item_len = max_id[1] + 1
    table = bytearray(item_len)
    for oid, bits in item_flags.items():
        table[oid] = bits

    rev = read_content_revision(args.things_dir)
    header = MAGIC + struct.pack(
        "<BBHIIIIIHH",
        VERSION, HEADER_SIZE, CATEGORY_COUNT,
        item_len, max_id[2] + 1, max_id[3] + 1, max_id[4] + 1,
        counts[1], rev, 0)
    assert len(header) == HEADER_SIZE, len(header)

    outdir = os.path.dirname(os.path.abspath(args.out))
    if outdir and not os.path.isdir(outdir):
        os.makedirs(outdir)
    with open(args.out, "wb") as f:
        f.write(header)
        f.write(bytes(table))

    nonzero = sum(1 for b in table if b)
    print("source            : %s" % dat)
    print("source size       : %d bytes" % len(buf))
    print("source sha256     : %s" % sha256_of(dat))
    print("content revision  : %d (from assets.json.sha256, diagnostic copy only)" % rev)
    print("object count      : %d   max id %d  (array len %d)" % (counts[1], max_id[1], item_len))
    print("outfit count      : %d   max id %d  (array len %d)" % (counts[2], max_id[2], max_id[2] + 1))
    print("effect count      : %d   max id %d  (array len %d)" % (counts[3], max_id[3], max_id[3] + 1))
    print("missile count     : %d   max id %d  (array len %d)" % (counts[4], max_id[4], max_id[4] + 1))
    print("non-zero flags    : %d of %d slots" % (nonzero, item_len))
    print("output            : %s" % os.path.abspath(args.out))
    print("output size       : %d bytes (header %d + table %d)" % (HEADER_SIZE + item_len,
                                                                   HEADER_SIZE, item_len))
    print("output sha256     : %s" % sha256_of(args.out))
    print("flag-bit histogram:")
    for mask, nm in BIT_NAMES:
        print("  %s  %6d" % (nm, sum(1 for b in table if b & mask)))
    print("  %-16s  %6d" % ("SPARE     (0x80)", sum(1 for b in table if b & 0x80)))
    print("AppearanceFlags field/wire-type histogram (top 12 by count):")
    for (fn, wt), c in sorted(flag_field_stats.items(), key=lambda kv: -kv[1])[:12]:
        print("  field %-3d wt %d : %7d" % (fn, wt, c))
    exotic = [k for k in flag_field_stats if k[1] in (1, 5)]
    print("exotic wire types (1/5) seen: %s" % (exotic if exotic else "none"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
