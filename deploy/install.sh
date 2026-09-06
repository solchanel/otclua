#!/bin/sh
# =============================================================================
# deploy/install.sh -- install the luaclient hub on a fresh Debian 12/13 server.
#
#   sudo sh deploy/install.sh                 # loopback on 127.0.0.1:8777
#   sudo sh deploy/install.sh --port=9000
#   sudo sh deploy/install.sh --help
#
# Idempotent: running it again reinstalls the application tree and leaves the
# data directory, the master key, /etc/luaclient/hub.conf and the service user
# exactly as they were.  It never writes a credential anywhere.
#
# What it creates
#   /opt/luaclient            the application, root-owned, read-only to the service
#   /var/lib/luaclient        state: users, accounts, audit log, secret.key  (0700)
#   /var/lib/luaclient/workers  the cwd every worker gets; bot profiles land here
#   /var/log/luaclient        the hub's own log file                          (0750)
#   /etc/luaclient/hub.conf   configuration, written once                     (0640)
#   /etc/logrotate.d/luaclient
#   a system user and group `luaclient`, no login shell, no home of its own
#   /etc/systemd/system/luaclient-hub.service
#
# POSIX sh.  set -eu: every command that may legitimately fail is guarded.
# =============================================================================
set -eu

APP_DIR=/opt/luaclient
DATA_DIR=/var/lib/luaclient
WORK_DIR=$DATA_DIR/workers
LOG_DIR=/var/log/luaclient
CONF_DIR=/etc/luaclient
CONF=$CONF_DIR/hub.conf
SVC_USER=luaclient
SVC_GROUP=luaclient
SVC=luaclient-hub
UNIT=/etc/systemd/system/$SVC.service
LOGROTATE=/etc/logrotate.d/luaclient

BIND=127.0.0.1
PORT=8777
SRC=
DO_APT=1
DO_START=1
DO_ENABLE=1
FORCE=0
STAGE=

# ------------------------------------------------------------------ plumbing --
say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf 'install.sh: WARNING: %s\n' "$*" >&2; }
die()  { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

cleanup() {
  [ -n "$STAGE" ] && [ -d "$STAGE" ] && rm -rf -- "$STAGE"
  return 0
}
trap cleanup EXIT HUP INT TERM

usage() {
  cat <<'EOF'
Usage: sudo sh deploy/install.sh [options]

  --port=N          port the hub listens on              (default 8777)
  --bind=ADDR       address it binds                (default 127.0.0.1)
                    Anything but loopback needs --allow-insecure in
                    HUB_EXTRA_ARGS and is the wrong answer: put nginx in
                    front instead (deploy/nginx-luaclient.conf).
  --source=DIR      the tree to install from   (default: this script's ..)
  --skip-apt        do not touch apt; only verify the dependencies are there
  --no-start        install everything, do not start the service
  --no-enable       do not enable the service at boot
  --force           continue past the Debian-version and architecture checks
  --help
EOF
}

for a in "$@"; do
  case $a in
    --port=*)   PORT=${a#*=} ;;
    --bind=*)   BIND=${a#*=} ;;
    --source=*) SRC=${a#*=} ;;
    --skip-apt) DO_APT=0 ;;
    --no-start) DO_START=0 ;;
    --no-enable) DO_ENABLE=0 ;;
    --force)    FORCE=1 ;;
    --help|-h)  usage; exit 0 ;;
    *) die "unknown option: $a  (--help for the list)" ;;
  esac
done

case $PORT in
  ''|*[!0-9]*) die "--port must be a number, got \"$PORT\"" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "--port out of range: $PORT"

# Resolve this script's directory, then the source root above it.
self=$0
while [ -L "$self" ]; do
  t=$(readlink "$self")
  case $t in /*) self=$t ;; *) self=$(dirname -- "$self")/$t ;; esac
done
here=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd -P)
[ -n "$SRC" ] || SRC=$(CDPATH= cd -- "$here/.." && pwd -P)

# =============================================================== 1. preflight ==
step "Preflight"

[ "$(id -u)" = 0 ] || die "must run as root.  Try:  sudo sh $0 $*"

[ -r /etc/os-release ] || die "/etc/os-release is missing -- this is not a Debian system."
# shellcheck disable=SC1091
. /etc/os-release
os_id=${ID:-unknown}
os_like=${ID_LIKE:-}
os_ver=${VERSION_ID:-${VERSION_CODENAME:-unknown}}
say "  distribution   $os_id $os_ver  (${PRETTY_NAME:-?})"

is_debian=0
[ "$os_id" = debian ] && is_debian=1
case " $os_like " in *" debian "*) is_debian=1 ;; esac
if [ "$is_debian" != 1 ]; then
  [ "$FORCE" = 1 ] || die "this installer targets Debian 12 or 13; found ID=$os_id.
            Re-run with --force if you know the packages and paths match."
  warn "not Debian ($os_id) -- continuing because --force was given."
fi
case $os_ver in
  12|12.*|13|13.*) : ;;
  *)
    if [ "$FORCE" = 1 ]; then
      warn "Debian $os_ver is not 12 or 13 -- continuing because --force was given."
    else
      die "this installer targets Debian 12 or 13; found version $os_ver.
            Re-run with --force to install anyway."
    fi ;;
esac

arch=$(uname -m)
if command -v dpkg >/dev/null 2>&1; then
  darch=$(dpkg --print-architecture 2>/dev/null || echo "$arch")
else
  darch=$arch
fi
say "  architecture   $arch ($darch)"
case $darch in
  amd64|arm64|armhf|i386) : ;;
  *)
    if [ "$FORCE" = 1 ]; then
      warn "architecture $darch is untested -- continuing because --force was given."
    else
      die "no LuaJIT package is expected for architecture \"$darch\".
            Debian ships luajit on amd64, arm64, armhf and i386.
            Re-run with --force if you have a working LuaJIT 2.1 already."
    fi ;;
esac

[ -d "$SRC/hub" ] && [ -f "$SRC/hub/main.lua" ] && [ -f "$SRC/main.lua" ] \
  || die "--source=$SRC does not look like the luaclient tree (no hub/main.lua)."
say "  source tree    $SRC"

have_systemd=0
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  have_systemd=1
  say "  systemd        present ($(systemctl is-system-running 2>/dev/null || echo 'degraded/offline'))"
else
  say "  systemd        NOT running (container or WSL without systemd)"
  say "                 The unit will be installed and validated, but not started."
  DO_START=0; DO_ENABLE=0
fi

# ============================================================ 2. dependencies ==
step "Dependencies"

if [ "$DO_APT" = 1 ]; then
  command -v apt-get >/dev/null 2>&1 || die "apt-get not found; re-run with --skip-apt."
  export DEBIAN_FRONTEND=noninteractive
  missing=
  for p in luajit curl ca-certificates; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed$'; then
      say "  already installed: $p"
    else
      missing="$missing $p"
    fi
  done
  if [ -n "$missing" ]; then
    say "  apt-get install:$missing"
    apt-get update -qq || warn "apt-get update failed -- trying the install anyway."
    # shellcheck disable=SC2086
    apt-get install -y -qq --no-install-recommends $missing \
      || die "apt-get install failed for:$missing"
  fi
else
  say "  --skip-apt: verifying only"
fi

LUAJIT=$(command -v luajit || true)
[ -n "$LUAJIT" ] || die "luajit is not on PATH after installation."
say "  luajit         $LUAJIT"

lj_banner=$("$LUAJIT" -v 2>&1 | head -1)
say "  version        $lj_banner"
case $lj_banner in
  "LuaJIT 2.1"*) : ;;
  *) die "the hub needs LuaJIT 2.1 (it uses the FFI and 2.1-only semantics).
            Found: $lj_banner
            Install LuaJIT 2.1 by hand and re-run with --skip-apt." ;;
esac

# Debian's luajit has always been built with the FFI, but a distro CAN ship one
# without it (LUAJIT_DISABLE_FFI), and every socket, every file descriptor and
# every spawn in this program is FFI.  Prove it rather than assume it.
ffi_probe='
local ok, ffi = pcall(require, "ffi")
if not ok then io.stderr:write("no ffi module\n") os.exit(3) end
if not pcall(function()
      ffi.cdef[[ typedef struct { int a; } lc_probe_t; ]]
      local p = ffi.new("lc_probe_t[1]"); p[0].a = 4242
      assert(p[0].a == 4242)
      assert(ffi.string(ffi.cast("const char*", "ok"), 2) == "ok")
      assert(ffi.C ~= nil)
    end) then io.stderr:write("ffi present but not usable\n") os.exit(4) end
if type(jit) ~= "table" or type(jit.version) ~= "string" then
  io.stderr:write("no jit table\n") os.exit(5) end
io.write("ffi ok, ", jit.version, "\n")
'
if probe=$("$LUAJIT" -e "$ffi_probe" 2>&1); then
  say "  ffi            $probe"
else
  die "this LuaJIT cannot use the FFI:
            $probe
          The hub, its sockets, its process spawning and its filesystem layer are
          all FFI.  A LuaJIT built with LUAJIT_DISABLE_FFI cannot run it.
          Install a stock LuaJIT 2.1 and re-run with --skip-apt."
fi

command -v curl >/dev/null 2>&1 || die "curl is not on PATH after installation."

# ========================================================== 3. user and group ==
step "Service user"

if getent group "$SVC_GROUP" >/dev/null 2>&1; then
  say "  group $SVC_GROUP exists"
else
  groupadd --system "$SVC_GROUP"
  say "  group $SVC_GROUP created"
fi

nologin=/usr/sbin/nologin
[ -x "$nologin" ] || nologin=/bin/false

if getent passwd "$SVC_USER" >/dev/null 2>&1; then
  say "  user  $SVC_USER exists ($(getent passwd "$SVC_USER" | cut -d: -f6,7))"
else
  useradd --system --gid "$SVC_GROUP" --home-dir "$DATA_DIR" --no-create-home \
          --shell "$nologin" --comment "luaclient hub" "$SVC_USER"
  say "  user  $SVC_USER created (shell $nologin, home $DATA_DIR, not created here)"
fi

# ====================================================== 4. the application tree ==
step "Application  ->  $APP_DIR"

# shellcheck disable=SC1090
. "$here/filelist.sh"

STAGE=$(mktemp -d /opt/.luaclient-install.XXXXXX) || die "cannot create a staging directory in /opt"
count=0
lc_runtime_files "$SRC" > "$STAGE/.filelist"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case $rel in */*) d=$STAGE/${rel%/*} ;; *) d=$STAGE ;; esac
  mkdir -p -- "$d"
  cp -p -- "$SRC/$rel" "$STAGE/$rel"
  count=$((count + 1))
done < "$STAGE/.filelist"
rm -f -- "$STAGE/.filelist"
say "  $count files staged"

# The assets file the client cannot decode a single map packet without.
assets=$STAGE/assets/items1530.bin
if [ ! -f "$assets" ]; then
  die "assets/items1530.bin is missing from $SRC.
          proto/parser.lua cannot decode a tile without it and no worker will run.
          Regenerate it from a client's data directory:
            python3 tools/extract_appearances.py \\
                    --things-dir /path/to/otclient/data/things/1530 \\
                    --out assets/items1530.bin
          then re-run this installer."
fi
asz=$(wc -c < "$assets")
[ "$asz" -gt 100000 ] || die "assets/items1530.bin is only $asz bytes -- truncated.  Regenerate it
          (see INSTALL.md, \"Game assets\") and re-run."
say "  assets/items1530.bin  $asz bytes"
if command -v sha256sum >/dev/null 2>&1; then
  say "  sha256                $(sha256sum "$assets" | cut -d' ' -f1)"
fi

# A tree built by deploy/package.sh carries deploy/VERSION; a tree installed
# straight from a checkout does not, and upgrade.sh then has nothing to report
# but "unknown".  Stamp one so the next upgrade can say what it replaced.
if [ ! -f "$STAGE/deploy/VERSION" ]; then
  printf 'source-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" > "$STAGE/deploy/VERSION"
  say "  deploy/VERSION  $(cat "$STAGE/deploy/VERSION")  (installed from a checkout, not a tarball)"
else
  say "  deploy/VERSION  $(cat "$STAGE/deploy/VERSION")"
fi

chown -R root:root "$STAGE"
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +
find "$STAGE" -type f -name '*.sh' -exec chmod 755 {} +
[ -f "$STAGE/main.lua" ] && chmod 644 "$STAGE/main.lua"

if [ -d "$APP_DIR" ]; then
  old=$APP_DIR.replacing.$$
  mv -- "$APP_DIR" "$old"
  mv -- "$STAGE" "$APP_DIR"
  rm -rf -- "$old"
  say "  replaced the previous $APP_DIR"
else
  mv -- "$STAGE" "$APP_DIR"
  say "  installed"
fi
STAGE=

# It must at least load.  --help parses the command line, prints and exits 0
# without touching the data directory or binding a port.
if "$LUAJIT" "$APP_DIR/hub/main.lua" --help >/dev/null 2>"$APP_DIR/.helperr"; then
  say "  hub/main.lua loads and answers --help"
  rm -f -- "$APP_DIR/.helperr"
else
  msg=$(cat "$APP_DIR/.helperr" 2>/dev/null || true)
  rm -f -- "$APP_DIR/.helperr"
  die "the installed hub does not start: $msg"
fi

# ============================================================= 5. directories ==
step "Directories"

mkdir -p -- "$DATA_DIR" "$WORK_DIR" "$LOG_DIR" "$CONF_DIR"

chown "$SVC_USER:$SVC_GROUP" "$DATA_DIR" "$WORK_DIR"
chmod 700 "$DATA_DIR" "$WORK_DIR"

log_group=$SVC_GROUP
getent group adm >/dev/null 2>&1 && log_group=adm
chown "$SVC_USER:$log_group" "$LOG_DIR"
chmod 750 "$LOG_DIR"

chown root:root "$CONF_DIR"
chmod 755 "$CONF_DIR"

for d in "$DATA_DIR" "$WORK_DIR" "$LOG_DIR" "$CONF_DIR"; do
  say "  $(ls -ld "$d" | awk '{printf "%-11s %-9s %-9s %s\n", $1, $3, $4, $9}')"
done

# ================================================================= 6. config ==
step "Configuration  ->  $CONF"

if [ -f "$CONF" ]; then
  say "  $CONF exists -- left untouched (your edits survive a re-install)"
else
  tmp=$CONF.new.$$
  sed -e "s|^HUB_BIND=.*|HUB_BIND=$BIND|" \
      -e "s|^HUB_PORT=.*|HUB_PORT=$PORT|" \
      "$APP_DIR/deploy/luaclient-hub.conf.example" > "$tmp"
  chown root:"$SVC_GROUP" "$tmp"
  chmod 640 "$tmp"
  mv -- "$tmp" "$CONF"
  say "  written: HUB_BIND=$BIND HUB_PORT=$PORT"
fi

if [ ! -f "$LOGROTATE" ]; then
  cat > "$LOGROTATE" <<EOF
$LOG_DIR/*.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su $SVC_USER $log_group
    create 0640 $SVC_USER $log_group
}
EOF
  chmod 644 "$LOGROTATE"
  say "  logrotate: $LOGROTATE"
else
  say "  logrotate: $LOGROTATE exists -- left untouched"
fi

# ================================================================= 7. service ==
step "systemd unit  ->  $UNIT"

install -o root -g root -m 644 "$APP_DIR/deploy/luaclient-hub.service" "$UNIT"
say "  installed"

if command -v systemd-analyze >/dev/null 2>&1; then
  # `systemd-analyze verify` writes advisory notes to stderr and still exits 0,
  # so the exit status is the pass/fail and the output is worth showing either
  # way.  Never swallow it silently.
  vok=1
  verr=$(systemd-analyze verify "$UNIT" 2>&1) || vok=0
  if [ -n "$verr" ]; then
    say "  systemd-analyze verify said:"
    printf '%s\n' "$verr" | sed 's/^/    /'
  fi
  if [ "$vok" = 1 ]; then
    say "  systemd-analyze verify: clean"
  else
    die "the unit file does not validate."
  fi
fi

if [ "$have_systemd" = 1 ]; then
  systemctl daemon-reload
  if [ "$DO_ENABLE" = 1 ]; then
    systemctl enable "$SVC" >/dev/null 2>&1 && say "  enabled at boot"
  fi
  if [ "$DO_START" = 1 ]; then
    systemctl restart "$SVC"
    say "  started"
  fi
else
  say "  systemd is not running here, so the service was not started."
  say "  The exact command the unit runs, for a manual start as the service user:"
  say ""
  say "    setpriv --reuid=$SVC_USER --regid=$SVC_GROUP --init-groups --inh-caps=-all \\"
  say "      $LUAJIT $APP_DIR/hub/main.lua --luajit=$LUAJIT \\"
  say "      --bind=$BIND --port=$PORT --data-dir=$DATA_DIR \\"
  say "      --panel-dir=$APP_DIR/panel --workers-dir=$WORK_DIR \\"
  say "      --worker-script=$APP_DIR/main.lua \\"
  say "      --log-file=$LOG_DIR/hub.log"
fi

# ================================================================ 8. first run ==
if [ "$DO_START" = 1 ]; then
  step "First run"
  probe_url="http://$BIND:$PORT/api/health"
  case $BIND in
    0.0.0.0) probe_url="http://127.0.0.1:$PORT/api/health" ;;
    ::|'[::]') probe_url="http://[::1]:$PORT/api/health" ;;
  esac

  health=
  i=0
  while [ "$i" -lt 60 ]; do
    if health=$(curl -fsS --max-time 2 "$probe_url" 2>/dev/null); then break; fi
    health=
    i=$((i + 1))
    sleep 0.5
  done

  if [ -z "$health" ]; then
    say "  the hub did NOT answer on $probe_url"
    say "  last 30 journal lines:"
    journalctl -u "$SVC" -n 30 --no-pager 2>/dev/null | sed 's/^/    /' || true
    die "startup failed."
  fi
  say "  $probe_url  ->  $health"

  case $health in
    *'"bootstrap":true'*)
      say ""
      say "  This hub has NO web accounts yet.  It refuses to serve anything but the"
      say "  bootstrap endpoint until the first administrator exists.  The one-time"
      say "  token is printed to stdout only -- never to the log file -- so read it"
      say "  from the journal:"
      say ""
      say "      journalctl -u $SVC --no-pager | grep -A4 'bootstrap token'"
      say ""
      if command -v journalctl >/dev/null 2>&1; then
        journalctl -u "$SVC" --no-pager -n 60 2>/dev/null \
          | grep -A4 -e 'FIRST RUN' -e 'bootstrap token' | sed 's/^/    /' || true
      fi ;;
    *)
      say "  already bootstrapped -- an administrator account exists." ;;
  esac
fi

# =================================================================== 9. done ==
step "Done"
cat <<EOF

  service      systemctl status $SVC
  logs         journalctl -u $SVC -f           (and $LOG_DIR/hub.log)
  panel        http://$BIND:$PORT/
  data         $DATA_DIR   (0700 $SVC_USER -- back this up, secret.key included)
  config       $CONF
  uninstall    sudo sh $APP_DIR/deploy/uninstall.sh [--purge]
  upgrade      sudo sh $APP_DIR/deploy/upgrade.sh --source=NEW_TREE

  The hub is on LOOPBACK and speaks plain HTTP.  It has no TLS of its own.  To
  reach it from anywhere else, pick one:

    1. SSH tunnel -- nothing else to install, nothing else exposed:
         ssh -N -L $PORT:127.0.0.1:$PORT you@$(hostname -f 2>/dev/null || hostname)
       then open  http://127.0.0.1:$PORT/  on your own machine.

    2. nginx in front, terminating TLS:
         cp $APP_DIR/deploy/nginx-luaclient.conf /etc/nginx/sites-available/luaclient
         # edit server_name, then:
         ln -s ../sites-available/luaclient /etc/nginx/sites-enabled/luaclient
         nginx -t && systemctl reload nginx
         certbot --nginx -d panel.example.com --agree-tos -m you@example.com --redirect
       then set, in $CONF:
         HUB_EXTRA_ARGS="--csrf-strict --trusted-proxy=127.0.0.1/32"
         systemctl restart $SVC

  Do NOT simply change HUB_BIND to 0.0.0.0.  The session cookie, every Lua
  chunk you run in a worker and every reply would cross the network in clear
  text; the hub refuses that bind unless you also pass --allow-insecure, and
  that flag exists to be hard to type by accident.

EOF
