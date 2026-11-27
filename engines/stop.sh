#!/bin/sh
# Stop the game named by /tmp/rgds-game.pid.
# SIGTERM, then SIGKILL after 2 seconds, then the pid file is removed.
# No game, a stale pid, or a live pid that is not the recorded game: exit 0
# and leave that other process alone.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=engines/common.sh
. "$HERE/common.sh"

if [ "$#" -ne 0 ]; then
  rgds_fail "usage: stop.sh"
fi

rgds_acquire_lock || exit 1
rgds_stop_game
rgds_release_lock
printf '%s\n' stopped
