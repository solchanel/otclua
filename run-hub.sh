#!/bin/sh
# luaclient web panel hub — POSIX launcher.
# Usage: ./run-hub.sh [flags]          (./run-hub.sh --help for the flag list)
#
# Set LUACLIENT_LUAJIT to override the interpreter (a path or a name on PATH).
# The same interpreter is passed to the hub as --luajit, so every worker it
# spawns runs on exactly the build that is running the hub.
#
# The hub binds 127.0.0.1 by default and REFUSES any other address unless you
# pass --allow-insecure: it speaks plain HTTP and has no TLS.  Expose it with
# nginx/Caddy or an SSH tunnel, not by opening the port.
#
# The Windows twin is run-hub.bat.

set -u

# Resolve this script's own directory, following a symlink if we were invoked
# through one.  CDPATH= keeps a user's CDPATH from redirecting the cd.
script=$0
while [ -L "$script" ]; do
  target=$(readlink "$script")
  case $target in
    /*) script=$target ;;
    *)  script=$(dirname -- "$script")/$target ;;
  esac
done
dir=$(CDPATH= cd -- "$(dirname -- "$script")" && pwd -P) || exit 1

LUAJIT=${LUACLIENT_LUAJIT:-luajit}

if ! command -v "$LUAJIT" >/dev/null 2>&1 && [ ! -x "$LUAJIT" ]; then
  echo "run-hub.sh: LuaJIT not found (tried \"$LUAJIT\")." >&2
  echo "            Install it (apt install luajit) or set LUACLIENT_LUAJIT to" >&2
  echo "            the interpreter you want to use." >&2
  exit 1
fi

cd -- "$dir" || exit 1

# exec replaces this shell, so the hub's exit status IS run-hub.sh's exit status
# (0 clean stop / 1 startup failure / 2 bad command line).
exec "$LUAJIT" hub/main.lua --luajit="$LUAJIT" "$@"
