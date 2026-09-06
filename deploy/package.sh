#!/bin/sh
# =============================================================================
# deploy/package.sh -- build a versioned release tarball.
#
#   sh deploy/package.sh                       # version from git, or the date
#   sh deploy/package.sh --version=2026.09.06
#   sh deploy/package.sh --out=/tmp/dist
#
# Produces, in ./dist (or --out):
#
#   luaclient-<version>.tar.gz          the release
#   luaclient-<version>.tar.gz.sha256   `sha256sum -c` reads this directly
#   luaclient-<version>.manifest        every file with its size and sha256
#
# The tarball contains ONE top-level directory, `luaclient-<version>/`, holding
# exactly the files deploy/filelist.sh names -- the runtime tree, the panel, the
# generated assets, the operator documentation and deploy/ itself.  No test/, no
# docs/ (so no docs/vbot), no panel/test, panel/mock or panel/devhub.lua, no
# scratch or captured profiles, no *.log, no .git.
#
# Reproducibility: files are added in LC_ALL=C sorted order, every mtime is
# clamped to SOURCE_DATE_EPOCH (default: the git commit date, else now), owner
# and group are forced to 0/root and modes are normalised to 644/755.  Two runs
# from the same tree therefore produce the same bytes.
#
# POSIX sh.  Needs tar, gzip and sha256sum (coreutils) -- all present on Debian.
# =============================================================================
set -eu

VERSION=
OUT=
STAGE=

say() { printf '%s\n' "$*"; }
die() { printf 'package.sh: %s\n' "$*" >&2; exit 1; }
cleanup() { [ -n "$STAGE" ] && [ -d "$STAGE" ] && rm -rf -- "$STAGE"; return 0; }
trap cleanup EXIT HUP INT TERM

for a in "$@"; do
  case $a in
    --version=*) VERSION=${a#*=} ;;
    --out=*)     OUT=${a#*=} ;;
    --help|-h)   sed -n '3,20p' "$0"; exit 0 ;;
    *) die "unknown option: $a" ;;
  esac
done

self=$0
while [ -L "$self" ]; do
  t=$(readlink "$self")
  case $t in /*) self=$t ;; *) self=$(dirname -- "$self")/$t ;; esac
done
here=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd -P)
ROOT=$(CDPATH= cd -- "$here/.." && pwd -P)
[ -f "$ROOT/hub/main.lua" ] || die "$ROOT does not look like the luaclient tree."

# shellcheck disable=SC1090
. "$here/filelist.sh"

# ---------------------------------------------------------------- version --
epoch=
if [ -z "$VERSION" ]; then
  if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    short=$(git -C "$ROOT" rev-parse --short=8 HEAD 2>/dev/null || echo nogit)
    date=$(git -C "$ROOT" show -s --format=%cd --date=format:%Y.%m.%d HEAD 2>/dev/null \
           || date -u +%Y.%m.%d)
    dirty=
    git -C "$ROOT" diff --quiet 2>/dev/null || dirty=-dirty
    VERSION="$date+g$short$dirty"
    epoch=$(git -C "$ROOT" show -s --format=%ct HEAD 2>/dev/null || true)
  else
    VERSION=$(date -u +%Y.%m.%d)
  fi
fi
case $VERSION in
  *[!A-Za-z0-9._+-]*) die "version \"$VERSION\" has characters that do not belong in a filename." ;;
esac
[ -n "${SOURCE_DATE_EPOCH:-}" ] && epoch=$SOURCE_DATE_EPOCH
if [ -z "$epoch" ]; then
  # No git and no SOURCE_DATE_EPOCH: use the newest mtime in the tree.  That is
  # still a function of the SOURCE, so two builds of an unchanged tree agree --
  # `date +%s` here would silently make every build differ.
  epoch=$( (cd "$ROOT" && lc_runtime_files . | tr '\n' '\0' \
            | xargs -0 -r stat -c '%Y' 2>/dev/null) | LC_ALL=C sort -n | tail -1 || true)
fi
case ${epoch:-} in
  ''|*[!0-9]*) epoch=$(date -u +%s)
               say "  note: no git, no SOURCE_DATE_EPOCH and no GNU find -- this build is"
               say "        timestamped NOW and will not be byte-identical to another." ;;
esac
mtime=$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

NAME=luaclient-$VERSION
[ -n "$OUT" ] || OUT=$ROOT/dist
mkdir -p -- "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd -P)

say "package.sh"
say "  source   $ROOT"
say "  version  $VERSION"
say "  mtime    $mtime  (SOURCE_DATE_EPOCH=$epoch)"
say "  out      $OUT"

# ------------------------------------------------------------------ stage --
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/luaclient-pkg.XXXXXX")
top=$STAGE/$NAME
mkdir -p -- "$top"

lc_runtime_files "$ROOT" > "$STAGE/list"
n=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case $rel in */*) d=$top/${rel%/*} ;; *) d=$top ;; esac
  mkdir -p -- "$d"
  cp -- "$ROOT/$rel" "$top/$rel"
  n=$((n + 1))
done < "$STAGE/list"
[ "$n" -gt 0 ] || die "the file list is empty."

# The version the installed tree reports back (upgrade.sh reads it).
printf '%s\n' "$VERSION" > "$top/deploy/VERSION"

# assets/items1530.bin is the one file whose absence is silent until a worker
# tries to decode a map packet and cannot.
[ -f "$top/assets/items1530.bin" ] || die "assets/items1530.bin is not in the tree."

# ---------------------------------------------------------------- manifest --
command -v sha256sum >/dev/null 2>&1 || die "sha256sum not found."
manifest=$OUT/$NAME.manifest
{
  printf '# luaclient release manifest\n'
  printf '# version   %s\n' "$VERSION"
  printf '# built     %s   (source timestamp, not wall clock -- see the header)\n' "$mtime"
  printf '# files     %s\n' "$n"
  printf '#\n# %-64s %10s  %s\n' 'sha256' 'bytes' 'path'
  ( cd "$top" && lc_runtime_files . ; echo deploy/VERSION ) | LC_ALL=C sort -u | while IFS= read -r rel; do
    [ -f "$top/$rel" ] || continue
    printf '%s %10s  %s\n' "$(sha256sum "$top/$rel" | cut -d' ' -f1)" \
                           "$(wc -c < "$top/$rel")" "$rel"
  done
} > "$manifest"
cp -- "$manifest" "$top/deploy/MANIFEST.sha256"

# ------------------------------------------------------------------- modes --
chmod -R a+rX,u+w,go-w "$top"
find "$top" -type d -exec chmod 755 {} +
find "$top" -type f -exec chmod 644 {} +
find "$top" -type f -name '*.sh' -exec chmod 755 {} +

# --------------------------------------------------------------- the tarball --
tarball=$OUT/$NAME.tar.gz
( cd "$STAGE" && LC_ALL=C find "$NAME" -print | LC_ALL=C sort > "$STAGE/tarlist" )
tar --create \
    --file - \
    --directory "$STAGE" \
    --owner=0 --group=0 --numeric-owner \
    --mtime="$mtime" \
    --format=gnu \
    --no-recursion \
    --files-from "$STAGE/tarlist" \
  | gzip -9n > "$tarball"

( cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )

say ""
say "  $tarball"
say "    $(wc -c < "$tarball") bytes, $n files (+ deploy/VERSION, deploy/MANIFEST.sha256)"
say "    $(cut -d' ' -f1 < "$OUT/$NAME.tar.gz.sha256")"
say "  $manifest"
say "  $OUT/$NAME.tar.gz.sha256"
say ""
say "  Verify:   cd $OUT && sha256sum -c $NAME.tar.gz.sha256"
say "  Install:  tar -xzf $NAME.tar.gz && sudo sh $NAME/deploy/install.sh"
say "  Upgrade:  sudo sh /opt/luaclient/deploy/upgrade.sh --tarball=$tarball"
