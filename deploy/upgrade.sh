#!/bin/sh
# =============================================================================
# deploy/upgrade.sh -- replace the installed tree with a newer one, safely.
#
#   sudo sh deploy/upgrade.sh --source=/root/luaclient-2026.09.06
#   sudo sh deploy/upgrade.sh --tarball=/root/luaclient-2026.09.06.tar.gz
#   sudo sh deploy/upgrade.sh --source=DIR --no-rollback     (debugging only)
#
# The order, and why:
#
#   1. sanity-check the new tree                 -- before anything is touched
#   2. stop the service                          -- the hub asks every worker to
#                                                   LOG OUT first, which is the
#                                                   whole reason not to just
#                                                   swap files under a live hub
#   3. back up /var/lib/luaclient and /etc/luaclient to /var/backups/luaclient
#   4. move the old tree aside, install the new one
#   5. MIGRATION DRY RUN: open the data directory with the NEW code and read
#      every collection.  hub/storage.lua applies schema migrations on load, so
#      this is the migration -- performed read-only, before the service is up,
#      where a failure is still recoverable.
#   6. start, and wait for /api/health
#   7. any failure from step 4 on: put the old tree back, restore the data
#      directory from the backup taken in step 3, start the old service again.
#
# POSIX sh.
# =============================================================================
set -eu

APP_DIR=/opt/luaclient
DATA_DIR=/var/lib/luaclient
CONF_DIR=/etc/luaclient
CONF=$CONF_DIR/hub.conf
BACKUP_ROOT=/var/backups/luaclient
SVC_USER=luaclient
SVC=luaclient-hub
UNIT=/etc/systemd/system/$SVC.service

SRC=
TARBALL=
ROLLBACK=1
KEEP_BACKUPS=10
TMPDIR_UP=
OLD_DIR=
BACKUP=
STARTED_STATE=

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf 'upgrade.sh: WARNING: %s\n' "$*" >&2; }
die()  { printf 'upgrade.sh: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: sudo sh deploy/upgrade.sh (--source=DIR | --tarball=FILE) [options]

  --source=DIR      an unpacked new tree (must contain hub/main.lua)
  --tarball=FILE    a tarball produced by deploy/package.sh; it is unpacked to a
                    temporary directory and its sha256 is verified when a
                    matching .sha256 file sits beside it
  --keep=N          how many timestamped backups to keep      (default 10)
  --no-rollback     leave the failed state in place for inspection
  --help
EOF
}

for a in "$@"; do
  case $a in
    --source=*)  SRC=${a#*=} ;;
    --tarball=*) TARBALL=${a#*=} ;;
    --keep=*)    KEEP_BACKUPS=${a#*=} ;;
    --no-rollback) ROLLBACK=0 ;;
    --help|-h)   usage; exit 0 ;;
    *) die "unknown option: $a  (--help for the list)" ;;
  esac
done

[ "$(id -u)" = 0 ] || die "must run as root."
[ -n "$SRC" ] || [ -n "$TARBALL" ] || { usage; die "give --source=DIR or --tarball=FILE."; }
[ -d "$APP_DIR" ] || die "$APP_DIR does not exist -- nothing to upgrade.  Run install.sh."

cleanup_tmp() { [ -n "$TMPDIR_UP" ] && [ -d "$TMPDIR_UP" ] && rm -rf -- "$TMPDIR_UP"; return 0; }
trap cleanup_tmp EXIT HUP INT TERM

have_systemd=0
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 && [ -f "$UNIT" ]; then
  have_systemd=1
fi

# ============================================================ 1. the new tree ==
step "New tree"

if [ -n "$TARBALL" ]; then
  [ -f "$TARBALL" ] || die "--tarball=$TARBALL does not exist."
  if [ -f "$TARBALL.sha256" ] && command -v sha256sum >/dev/null 2>&1; then
    ( cd "$(dirname -- "$TARBALL")" && sha256sum -c "$(basename -- "$TARBALL").sha256" ) >/dev/null \
      || die "the tarball does not match $TARBALL.sha256 -- refusing to install it."
    say "  sha256 verified against $TARBALL.sha256"
  else
    warn "no $TARBALL.sha256 beside the tarball; the contents are not verified."
  fi
  TMPDIR_UP=$(mktemp -d /var/tmp/luaclient-upgrade.XXXXXX)
  tar -xzf "$TARBALL" -C "$TMPDIR_UP"
  # The tarball has exactly one top-level directory.
  SRC=$(find "$TMPDIR_UP" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -n "$SRC" ] || die "the tarball has no top-level directory."
  say "  unpacked to $SRC"
fi

[ -f "$SRC/hub/main.lua" ] && [ -f "$SRC/main.lua" ] && [ -d "$SRC/panel" ] \
  || die "--source=$SRC is not a luaclient tree (want hub/main.lua, main.lua, panel/)."
[ -f "$SRC/deploy/install.sh" ] || die "$SRC has no deploy/ -- it is not a full release tree."
[ -f "$SRC/assets/items1530.bin" ] || die "$SRC/assets/items1530.bin is missing; no worker would run."

LUAJIT=$(command -v luajit || true)
[ -n "$LUAJIT" ] || die "luajit is not on PATH."

"$LUAJIT" "$SRC/hub/main.lua" --help >/dev/null 2>&1 \
  || die "the NEW hub/main.lua does not even parse under $LUAJIT -- refusing to install it."
say "  $SRC loads under $LUAJIT"

nv=unknown
[ -f "$SRC/deploy/VERSION" ] && nv=$(cat "$SRC/deploy/VERSION")
ov=unknown
[ -f "$APP_DIR/deploy/VERSION" ] && ov=$(cat "$APP_DIR/deploy/VERSION")
say "  installed version $ov  ->  $nv"

# ================================================================== 2. stop ==
step "Stopping $SVC"
if [ "$have_systemd" = 1 ]; then
  STARTED_STATE=$(systemctl is-active "$SVC" 2>/dev/null || true)
  say "  was: ${STARTED_STATE:-unknown}"
  systemctl stop "$SVC" || warn "systemctl stop returned non-zero; continuing."
  # `systemctl is-active` PRINTS the state and exits non-zero when it is not
  # active, so `|| echo ...` would print it twice.  `|| true` is what is wanted.
  i=0
  while [ "$i" -lt 120 ] && [ "$(systemctl is-active "$SVC" 2>/dev/null || true)" = active ]; do
    i=$((i + 1)); sleep 1
  done
  say "  now: $(systemctl is-active "$SVC" 2>/dev/null || true)"
else
  say "  no systemd unit active here; stop the hub yourself before continuing."
fi

# ================================================================ 3. backup ==
step "Backup"
mkdir -p -- "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP=$BACKUP_ROOT/luaclient-data-$stamp.tar.gz

if [ -d "$DATA_DIR" ]; then
  tar -czf "$BACKUP" -C "$(dirname -- "$DATA_DIR")" "$(basename -- "$DATA_DIR")"
  chmod 600 "$BACKUP"
  say "  $BACKUP  ($(wc -c < "$BACKUP") bytes)"
  say "  it contains secret.key -- treat it as a credential; 0600, root-only."
else
  warn "$DATA_DIR does not exist; nothing to back up."
  BACKUP=
fi
if [ -f "$CONF" ]; then
  cp -p -- "$CONF" "$BACKUP_ROOT/hub.conf-$stamp"
  chmod 600 "$BACKUP_ROOT/hub.conf-$stamp"
  say "  $BACKUP_ROOT/hub.conf-$stamp"
fi

# Prune old backups, newest first.
if [ -d "$BACKUP_ROOT" ]; then
  n=0
  for f in $(ls -1t "$BACKUP_ROOT"/luaclient-data-*.tar.gz 2>/dev/null || true); do
    n=$((n + 1))
    [ "$n" -gt "$KEEP_BACKUPS" ] && { rm -f -- "$f"; say "  pruned $f"; }
  done
fi

# ================================================================== 4. swap ==
rollback() {
  [ "$ROLLBACK" = 1 ] || { warn "--no-rollback: leaving the failed state in place."; return 0; }
  step "ROLLBACK"
  if [ -n "$OLD_DIR" ] && [ -d "$OLD_DIR" ]; then
    rm -rf -- "$APP_DIR"
    mv -- "$OLD_DIR" "$APP_DIR"
    say "  restored the previous $APP_DIR"
  fi
  if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    rm -rf -- "$DATA_DIR"
    tar -xzf "$BACKUP" -C "$(dirname -- "$DATA_DIR")" "$(basename -- "$DATA_DIR")"
    chown -R "$SVC_USER:$SVC_USER" "$DATA_DIR"
    chmod 700 "$DATA_DIR"
    say "  restored $DATA_DIR from $BACKUP"
  fi
  if [ "$have_systemd" = 1 ] && [ "$STARTED_STATE" = active ]; then
    systemctl start "$SVC" && say "  restarted the previous $SVC"
  fi
}

step "Installing the new tree"
OLD_DIR=$APP_DIR.old-$stamp
mv -- "$APP_DIR" "$OLD_DIR"
say "  previous tree parked at $OLD_DIR"

if ! sh "$SRC/deploy/install.sh" --source="$SRC" --skip-apt --no-start --no-enable \
        >"$BACKUP_ROOT/install-$stamp.log" 2>&1; then
  say "  install.sh failed; its output:"
  sed 's/^/    /' "$BACKUP_ROOT/install-$stamp.log"
  rollback
  die "upgrade aborted."
fi
say "  installed (log: $BACKUP_ROOT/install-$stamp.log)"

# ============================================================== 5. migration ==
step "Migration dry run"
# hub/storage.lua applies a collection's schema migrations when the file is
# LOADED, and marks the result dirty so it is persisted at the next save.  So
# reading every collection with the new code IS the migration, performed here
# with nothing else running and before the service comes back.  A corrupt or
# unreadable file is a hard error at open(), which is exactly what we want to
# find now rather than at 03:00 under systemd's restart loop.
#
# It runs as the service user: doing it as root would create root-owned files in
# a 0700 directory the service cannot then write.
migrate_lua='
local root = os.getenv("LC_APP") or "/opt/luaclient"
package.path = root .. "/?.lua;" .. package.path
local storage = require("hub.storage")
local dir = os.getenv("LC_DATA") or "/var/lib/luaclient"
local store, err = storage.open(dir, { collections = nil })
if not store then io.stderr:write("storage.open: ", tostring(err), "\n") os.exit(2) end
local names = { "users", "accounts", "characters", "proxies", "instances", "scripts" }
for _, n in ipairs(names) do
  local ok, info = pcall(function() return store:info(n) end)
  if ok and info then
    io.write(string.format("  %-12s rows=%-5s version=%-3s bytes=%s\n",
      n, tostring(info.count), tostring(info.version), tostring(info.bytes)))
  else
    io.write(string.format("  %-12s (absent -- first run)\n", n))
  end
end
io.write("  data directory reads clean under the new code\n")
'
# The script has to be readable BY THE SERVICE USER, so it cannot live in
# /var/backups/luaclient (0700 root).  A 0644 file in a private mktemp directory
# is fine: it contains no secret, only the collection names.
migdir=$(mktemp -d /var/tmp/luaclient-migrate.XXXXXX)
chmod 755 "$migdir"
printf '%s' "$migrate_lua" > "$migdir/migrate.lua"
chmod 644 "$migdir/migrate.lua"

mig_ok=0
if command -v setpriv >/dev/null 2>&1; then
  LC_APP=$APP_DIR LC_DATA=$DATA_DIR \
    setpriv --reuid="$SVC_USER" --regid="$SVC_USER" --init-groups --inh-caps=-all -- \
      "$LUAJIT" "$migdir/migrate.lua" && mig_ok=1
elif command -v runuser >/dev/null 2>&1; then
  LC_APP=$APP_DIR LC_DATA=$DATA_DIR \
    runuser -u "$SVC_USER" -- "$LUAJIT" "$migdir/migrate.lua" && mig_ok=1
else
  su -s /bin/sh "$SVC_USER" -c \
    "LC_APP='$APP_DIR' LC_DATA='$DATA_DIR' '$LUAJIT' '$migdir/migrate.lua'" && mig_ok=1
fi
rm -rf -- "$migdir"

if [ "$mig_ok" != 1 ]; then
  rollback
  die "the new code cannot read $DATA_DIR -- upgrade aborted, nothing lost."
fi

# ================================================================== 6. start ==
step "Starting"
if [ "$have_systemd" = 1 ]; then
  systemctl daemon-reload
  systemctl start "$SVC" || { rollback; die "the new $SVC did not start."; }

  bind=127.0.0.1; port=8777
  if [ -f "$CONF" ]; then
    b=$(sed -n 's/^HUB_BIND=//p' "$CONF" | tr -d '"'"'" | head -1); [ -n "$b" ] && bind=$b
    p=$(sed -n 's/^HUB_PORT=//p' "$CONF" | tr -d '"'"'" | head -1); [ -n "$p" ] && port=$p
  fi
  [ "$bind" = 0.0.0.0 ] && bind=127.0.0.1

  ok=0
  i=0
  while [ "$i" -lt 60 ]; do
    if h=$(curl -fsS --max-time 2 "http://$bind:$port/api/health" 2>/dev/null); then
      ok=1; say "  health: $h"; break
    fi
    i=$((i + 1)); sleep 0.5
  done
  if [ "$ok" != 1 ]; then
    say "  the new hub did not answer on http://$bind:$port/api/health"
    journalctl -u "$SVC" -n 30 --no-pager 2>/dev/null | sed 's/^/    /' || true
    systemctl stop "$SVC" 2>/dev/null || true
    rollback
    die "upgrade rolled back."
  fi
else
  say "  no systemd here -- start the hub yourself and check /api/health."
fi

# =================================================================== 7. done ==
step "Done"
say "  $ov  ->  $nv"
say "  backup      $BACKUP"
say "  old tree    $OLD_DIR   (remove it once you are satisfied: rm -rf $OLD_DIR)"
say "  logs        journalctl -u $SVC -n 50"
say ""
say "  secret.key was NOT touched, so every sealed game credential still opens."
say "  Instances flagged autoStart come back up on their own; anything else you"
say "  had running by hand needs starting again from the dashboard."
