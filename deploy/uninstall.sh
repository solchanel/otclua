#!/bin/sh
# =============================================================================
# deploy/uninstall.sh -- remove the luaclient hub.
#
#   sudo sh deploy/uninstall.sh              keep the data, the config and the user
#   sudo sh deploy/uninstall.sh --purge      remove them too  (irreversible)
#   sudo sh deploy/uninstall.sh --purge --yes    ... without the confirmation
#
# The default is deliberately conservative.  /var/lib/luaclient holds secret.key,
# and every stored game-account password is sealed with a key derived from it: a
# data directory without that file is not a backup, it is a pile of ciphertext
# nothing can ever open again.  So a plain uninstall stops the service, takes the
# unit and the application tree away, and leaves the state exactly where it is.
#
# POSIX sh.
# =============================================================================
set -eu

APP_DIR=/opt/luaclient
DATA_DIR=/var/lib/luaclient
LOG_DIR=/var/log/luaclient
CONF_DIR=/etc/luaclient
BACKUP_ROOT=/var/backups/luaclient
SVC_USER=luaclient
SVC_GROUP=luaclient
SVC=luaclient-hub
UNIT=/etc/systemd/system/$SVC.service
LOGROTATE=/etc/logrotate.d/luaclient

PURGE=0
ASSUME_YES=0

say() { printf '%s\n' "$*"; }
die() { printf 'uninstall.sh: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: sudo sh deploy/uninstall.sh [--purge] [--yes]

  (default)   stop and disable the service, remove the unit, /opt/luaclient and
              /etc/logrotate.d/luaclient.  KEEPS /var/lib/luaclient,
              /var/log/luaclient, /etc/luaclient and the `luaclient` user, so a
              re-install picks the fleet back up exactly where it was.

  --purge     also remove /var/lib/luaclient (secret.key, every web account,
              every sealed game credential and the audit log), /var/log/luaclient,
              /etc/luaclient, and the luaclient user and group.  Irreversible.
              It does NOT remove /var/backups/luaclient -- upgrade.sh's backups
              are the last copy of secret.key and are yours to delete.

  --yes       do not ask for confirmation on --purge.
EOF
}

for a in "$@"; do
  case $a in
    --purge)   PURGE=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $a  (--help for the list)" ;;
  esac
done

[ "$(id -u)" = 0 ] || die "must run as root.  Try:  sudo sh $0 $*"

if [ "$PURGE" = 1 ] && [ "$ASSUME_YES" != 1 ]; then
  say "--purge will PERMANENTLY delete:"
  say "    $DATA_DIR   (secret.key, web accounts, sealed game credentials, audit log)"
  say "    $LOG_DIR"
  say "    $CONF_DIR"
  say "    the system user and group $SVC_USER"
  say ""
  say "Nothing here can be recovered without a backup taken beforehand."
  printf 'Type exactly  purge  to continue: '
  read -r answer || answer=
  [ "$answer" = purge ] || die "aborted (you typed \"$answer\")."
fi

# ------------------------------------------------------------------- service --
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  if systemctl list-unit-files "$SVC.service" >/dev/null 2>&1; then
    systemctl stop "$SVC" 2>/dev/null || true
    systemctl disable "$SVC" 2>/dev/null || true
    say "stopped and disabled $SVC"
  fi
else
  # No systemd (container, WSL without systemd, or the unit was started by hand).
  # Take down whatever is still running from this install, gently first.
  pids=$(pgrep -f "$APP_DIR/hub/main.lua" 2>/dev/null || true)
  if [ -n "$pids" ]; then
    say "no systemd; sending SIGTERM to hub pid(s): $pids"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    i=0
    while [ "$i" -lt 40 ] && kill -0 $pids 2>/dev/null; do i=$((i + 1)); sleep 0.25; done
    # shellcheck disable=SC2086
    kill -0 $pids 2>/dev/null && { say "still up after 10 s -- SIGKILL"; kill -9 $pids 2>/dev/null || true; }
  fi
fi

if [ -f "$UNIT" ]; then
  rm -f -- "$UNIT"
  say "removed $UNIT"
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] \
    && { systemctl daemon-reload; systemctl reset-failed "$SVC" 2>/dev/null || true; }
fi

# --------------------------------------------------------------------- files --
if [ -d "$APP_DIR" ]; then
  rm -rf -- "$APP_DIR"
  say "removed $APP_DIR"
fi

if [ -f "$LOGROTATE" ]; then
  rm -f -- "$LOGROTATE"
  say "removed $LOGROTATE"
fi

if [ "$PURGE" = 1 ]; then
  for d in "$DATA_DIR" "$LOG_DIR" "$CONF_DIR"; do
    if [ -e "$d" ]; then rm -rf -- "$d"; say "purged $d"; fi
  done
  # `userdel` refuses while anything is still running as that user, and systemd
  # tears a cgroup down asynchronously -- `systemctl stop` returning is not the
  # same as the last process being reaped.  Wait for that, then check the RESULT
  # rather than trusting the exit status: an earlier version of this script
  # printed "removed user luaclient" immediately after userdel had failed, and
  # left the account behind.
  if getent passwd "$SVC_USER" >/dev/null 2>&1; then
    if command -v pgrep >/dev/null 2>&1; then
      i=0
      while [ "$i" -lt 30 ] && pgrep -u "$SVC_USER" >/dev/null 2>&1; do
        i=$((i + 1)); sleep 0.5
      done
    else
      sleep 2
    fi
    uerr=$(userdel "$SVC_USER" 2>&1) || true
    if getent passwd "$SVC_USER" >/dev/null 2>&1; then
      say "could NOT remove user $SVC_USER: ${uerr:-userdel failed}"
      say "    retry by hand once nothing runs as it:   userdel $SVC_USER"
    else
      say "removed user $SVC_USER"
    fi
  fi
  if getent group "$SVC_GROUP" >/dev/null 2>&1; then
    gerr=$(groupdel "$SVC_GROUP" 2>&1) || true
    if getent group "$SVC_GROUP" >/dev/null 2>&1; then
      say "could NOT remove group $SVC_GROUP: ${gerr:-groupdel failed}"
    else
      say "removed group $SVC_GROUP"
    fi
  else
    say "group $SVC_GROUP is gone (userdel took the primary group with it)"
  fi
  # NOT removed, and it must be said out loud: these are backups, and one of
  # them is the only remaining copy of secret.key -- without which every sealed
  # game credential in that archive is permanently undecryptable.  Deleting
  # somebody's last backup as part of an uninstall would be indefensible.
  if [ -d "$BACKUP_ROOT" ] && [ -n "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]; then
    say ""
    say "KEPT DELIBERATELY: $BACKUP_ROOT"
    ls -1 "$BACKUP_ROOT" | sed 's/^/    /'
    say "    These are deploy/upgrade.sh's backups.  They contain secret.key in the"
    say "    clear -- treat them as credentials.  Remove them yourself when you are"
    say "    certain you will never restore this fleet:  rm -rf $BACKUP_ROOT"
  fi
else
  say ""
  say "KEPT (use --purge to remove):"
  for d in "$DATA_DIR" "$LOG_DIR" "$CONF_DIR"; do
    [ -e "$d" ] && say "    $d"
  done
  getent passwd "$SVC_USER" >/dev/null 2>&1 && say "    user/group $SVC_USER"
  say ""
  say "Re-installing over this state is safe: install.sh does not touch the data"
  say "directory, and it will not overwrite $CONF_DIR/hub.conf."
fi

say ""
say "Not removed: the luajit, curl and ca-certificates packages.  install.sh asked"
say "apt for them, but they are ordinary shared dependencies and something else on"
say "this machine may be using them.  Remove them yourself if you are sure:"
say "    apt-get remove luajit"
say ""
say "done."
