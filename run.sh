#!/bin/sh
# Standalone LuaJIT worker client for Gunzodus (protocol 1530) — POSIX launcher.
# Usage: ./run.sh [flags]            (./run.sh --help for the flag list)
# Set LUACLIENT_LUAJIT to override the interpreter (a path or a name on PATH).
#
# The Windows twin is run.bat.  Both cd to the project root first, because
# main.lua resolves package.path and ./assets relative to the working directory.

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
  echo "run.sh: LuaJIT not found (tried \"$LUAJIT\")." >&2
  echo "        Install it (apt install luajit) or set LUACLIENT_LUAJIT to the" >&2
  echo "        interpreter you want to use." >&2
  exit 1
fi

cd -- "$dir" || exit 1

# exec replaces this shell, so main.lua's exit status IS run.sh's exit status
# (0 ok / 1 usage / 2 login refused / 3 protocol failure — see README).
exec "$LUAJIT" main.lua "$@"
