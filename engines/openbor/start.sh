#!/bin/sh
# Start an OpenBOR game. Same contract as engines/love/start.sh.
# The engine's library path is engines/openbor/, not this app's lib/.
# ALSOFT_CONF and SDL_VIDEO_DOUBLE_BUFFER belong to the LÖVE launcher only.
#
# The working directory is the pak's directory, or the directory itself when
# the game path is a directory. The argument is that path made absolute.
# Whether OpenBOR skips its menu for a loose data directory is unconfirmed
# on a device; this script still passes that directory as the one argument.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP_ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
# shellcheck source=engines/common.sh
. "$HERE/../common.sh"

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  rgds_fail "usage: start.sh <game path>"
fi

if [ -n "${RGDS_OPENBOR_BIN:-}" ]; then
  _bin=$RGDS_OPENBOR_BIN
elif [ -x "$APP_ROOT/engines/openbor/OpenBOR-arm64" ]; then
  _bin=$APP_ROOT/engines/openbor/OpenBOR-arm64
else
  _bin=$(command -v OpenBOR-arm64 2>/dev/null || true)
fi
RGDS_GAME_LIB="$APP_ROOT/engines/openbor"
unset ALSOFT_CONF SDL_VIDEO_DOUBLE_BUFFER || true

rgds_resolve_game "$1"
rgds_require_exec "$_bin" OpenBOR-arm64
rgds_acquire_lock || exit 1
rgds_stop_game
rgds_launch_game openbor "$_bin" "$RGDS_GAME_PATH"
