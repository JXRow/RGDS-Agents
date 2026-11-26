#!/bin/sh
# Start a LÖVE game the way the stock menu starts an app: a shell script sets
# the launcher exports, then runs the engine. The finder and the agent's shell
# tool both run this file. It does not write /tmp/.next.
#
#   engines/love/start.sh <game path>
# stdout is the pid. A bad path or an engine that exits immediately is one
# line on stderr and exit 1.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
# shellcheck source=engines/common.sh
. "$HERE/../common.sh"

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  rgds_fail "usage: start.sh <game path>"
fi

if [ -n "${RGDS_LOVE_BIN:-}" ]; then
  _bin=$RGDS_LOVE_BIN
elif [ -x "$APP_ROOT/bin/love" ]; then
  _bin=$APP_ROOT/bin/love
else
  _bin=$(command -v love 2>/dev/null || true)
fi
if [ -n "${LD_LIBRARY_PATH:-}" ]; then
  RGDS_GAME_LIB="$APP_ROOT/lib:$LD_LIBRARY_PATH"
else
  RGDS_GAME_LIB="$APP_ROOT/lib"
fi
export ALSOFT_CONF="$APP_ROOT/alsoft.conf"
export SDL_VIDEO_DOUBLE_BUFFER=1

rgds_resolve_game "$1"
rgds_require_exec "$_bin" love
rgds_acquire_lock || exit 1
rgds_stop_game
rgds_launch_game love "$_bin" "$RGDS_GAME_PATH"
