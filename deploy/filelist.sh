#!/bin/sh
# deploy/filelist.sh -- the single definition of "what belongs in a runtime install".
#
# Both deploy/install.sh and deploy/package.sh use it, so a file can never be in
# the tarball but missing from an install, or the other way round.
#
#   sh deploy/filelist.sh [SOURCE_ROOT]     print the list, one repo-relative path
#                                           per line, LC_ALL=C sorted
#   . deploy/filelist.sh                    define lc_runtime_files() for a caller
#
# What is IN:  every Lua module the hub or a worker loads at run time, the panel
#              the hub serves, the generated game metadata under assets/ and
#              data/, the operator documentation, and deploy/ itself (so the
#              tarball can install and later uninstall itself).
# What is OUT: test/ (twelve suites, ~4,700 assertions -- development only),
#              docs/ including docs/vbot and docs/shim, panel/test, panel/mock and
#              panel/devhub.lua (the panel's own harness, which the hub answers
#              404 for anyway -- see hub/server.lua's PANEL_DENY), the scratch and
#              captured-profile directories, every *.log, __pycache__, dotfiles
#              and .git.
#
# tools/ contributes exactly one file: extract_appearances.py, because INSTALL.md
# tells the operator to regenerate assets/items1530.bin with it when the server
# ships a new asset set.
#
# POSIX sh.  No bashisms, no GNU-only find predicates.

lc_runtime_files() {
  lc_root=${1:-.}
  (
    CDPATH= cd -- "$lc_root" 2>/dev/null || exit 1

    # Whole trees.  Every one of these is loaded at run time.
    for d in assets bot control data deploy game hub lib panel proto shim; do
      [ -d "$d" ] && find "$d" -type f -print
    done

    # Individual files at the root.
    for f in main.lua run-hub.sh run.sh \
             INSTALL.md README.md README-HUB.md PANEL.md API.md BOT.md ARCHITECTURE.md \
             tools/extract_appearances.py; do
      [ -f "$f" ] && echo "$f"
    done
  ) | sed 's|^\./||' | grep -v \
        -e '^panel/test/' \
        -e '^panel/mock/' \
        -e '^panel/devhub\.lua$' \
        -e '__pycache__' \
        -e '\.log$' \
        -e '\.tmp$' \
        -e '\.pyc$' \
        -e '/\.' \
      | LC_ALL=C sort
  unset lc_root
}

# Executed rather than sourced?  Then print the list.
case ${0##*/} in
  filelist.sh) lc_runtime_files "${1:-.}" ;;
esac
