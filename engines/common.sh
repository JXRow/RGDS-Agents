# Shared start/stop for a game engine. Sourced by engines/*/start.sh and engines/stop.sh.
# Not a menu entry and not a request file: nothing here writes /tmp/.next.
#
# /tmp/rgds-game.pid is three lines: pid, engine id, absolute game path.
# The engine log is /tmp/rgds-game.log.
#
# A child of `opencode serve` inherits XDG_CONFIG_HOME, XDG_DATA_HOME,
# XDG_STATE_HOME, XDG_CACHE_HOME, and OPENCODE_PASSWORD. Those are cleared
# before the engine is exec'd so a game does not save under /userdata/opencode
# and the password is not in the engine's environment. This file never prints
# the password.

RGDS_GAME_PID_FILE=${RGDS_GAME_PID_FILE:-/tmp/rgds-game.pid}
RGDS_GAME_LOG=${RGDS_GAME_LOG:-/tmp/rgds-game.log}
RGDS_GAME_LOCK_DIR=${RGDS_GAME_LOCK_DIR:-/tmp/rgds-game.lock}
RGDS_GAME_START_DELAY=${RGDS_GAME_START_DELAY:-1}
RGDS_GAME_START_WATCH=${RGDS_GAME_START_WATCH:-3}
RGDS_GAME_STOP_GRACE=${RGDS_GAME_STOP_GRACE:-2}

_rgds_pw="${OPENCODE_PASSWORD-}"
unset OPENCODE_PASSWORD || true

rgds_fail() {
  printf '%s\n' "$1" >&2
  rgds_release_lock
  exit 1
}

rgds_tenths() {
  local _t _w _f
  _t=$1
  case $_t in
    *.*)
      _w=${_t%%.*}
      _f=${_t#*.}
      _f=${_f%"${_f#?}"}
      case $_w in
        "") _w=0 ;;
      esac
      case $_f in
        ""|*[!0-9]*) _f=0 ;;
      esac
      echo $((_w * 10 + _f))
      ;;
    ""|*[!0-9]*)
      echo 0
      ;;
    *)
      echo $((_t * 10))
      ;;
  esac
}

rgds_pid_alive() {
  local _pid _stat
  _pid=$1
  case $_pid in
    ""|*[!0-9]*|0) return 1 ;;
  esac
  kill -0 "$_pid" 2>/dev/null || return 1
  if [ -r "/proc/$_pid/stat" ]; then
    _stat=$(cat "/proc/$_pid/stat" 2>/dev/null || true)
    case $_stat in
      *") Z "*|*") X "*) return 1 ;;
    esac
  fi
  return 0
}

rgds_is_our_game() {
  local _pid _id
  _pid=$1
  _id=$2
  rgds_pid_alive "$_pid" || return 1
  [ -r "/proc/$_pid/environ" ] || return 1
  if { tr '\0' '\n' < "/proc/$_pid/environ"; } 2>/dev/null | grep -F -x -q "RGDS_GAME_ID=$_id"; then
    return 0
  fi
  return 1
}

rgds_read_workdir() {
  _file=${OPENCODE_WORKDIR_FILE:-/userdata/opencode/workdir}
  _line=
  IFS= read -r _line 2>/dev/null < "$_file" || true
  _cr=$(printf '\r')
  case $_line in
    *"$_cr") _line=${_line%"$_cr"} ;;
  esac
  _tab=$(printf '\t')
  while :; do
    case $_line in
      " "*) _line=${_line# } ;;
      "$_tab"*) _line=${_line#"$_tab"} ;;
      *) break ;;
    esac
  done
  while :; do
    case $_line in
      *" ") _line=${_line% } ;;
      *"$_tab") _line=${_line%"$_tab"} ;;
      *) break ;;
    esac
  done
  while :; do
    case $_line in
      /) break ;;
      */) _line=${_line%/} ;;
      *) break ;;
    esac
  done
  if [ -n "$_line" ]; then
    RGDS_WORKDIR="$_line"
  else
    RGDS_WORKDIR=/mnt/mmc/Roms/APPS/RGDS-Agents
  fi
}

rgds_realpath() {
  local _p _r _d _b _rd
  _p=$1
  if command -v readlink >/dev/null 2>&1; then
    _r=$(readlink -f -- "$_p" 2>/dev/null || true)
    if [ -n "$_r" ]; then
      printf '%s\n' "$_r"
      return 0
    fi
  fi
  if [ -d "$_p" ]; then
    (CDPATH= cd -- "$_p" && pwd -P)
    return 0
  fi
  if [ -L "$_p" ]; then
    return 1
  fi
  _d=$(dirname -- "$_p")
  _b=$(basename -- "$_p")
  _rd=$(CDPATH= cd -- "$_d" && pwd -P) || return 1
  printf '%s/%s\n' "$_rd" "$_b"
}

rgds_inside() {
  local _root _path
  _root=$1
  _path=$2
  [ -n "$_root" ] || return 1
  [ -n "$_path" ] || return 1
  if [ "$_root" = "/" ]; then
    case $_path in
      /*) return 0 ;;
    esac
    return 1
  fi
  case $_path in
    "$_root"|"$_root"/*) return 0 ;;
  esac
  return 1
}

rgds_resolve_game() {
  local _arg _nl _resolved _root _app
  _arg=$1
  _nl='
'
  case "$_arg" in
    *"$_nl"*) rgds_fail "game path is not valid" ;;
  esac
  rgds_read_workdir
  if [ ! -e "$_arg" ]; then
    rgds_fail "game path does not exist: $_arg"
  fi
  _resolved=$(rgds_realpath "$_arg") || rgds_fail "game path does not exist: $_arg"
  if [ -z "$_resolved" ] || [ ! -e "$_resolved" ]; then
    rgds_fail "game path does not exist: $_arg"
  fi
  _root=$RGDS_WORKDIR
  if [ ! -d "$_root" ]; then
    rgds_fail "game path is outside the work directory: $_arg"
  fi
  _root=$(rgds_realpath "$_root") || rgds_fail "game path is outside the work directory: $_arg"
  case $_root in
    /) ;;
    */) _root=${_root%/} ;;
  esac
  if ! rgds_inside "$_root" "$_resolved"; then
    rgds_fail "game path is outside the work directory: $_arg"
  fi
  if [ -n "${RGDS_APP_ROOT:-}" ] && [ -d "$RGDS_APP_ROOT" ]; then
    _app=$(rgds_realpath "$RGDS_APP_ROOT" || true)
    if [ -n "$_app" ] && [ "$_resolved" = "$_app" ]; then
      rgds_fail "game path cannot be the controller directory: $_arg"
    fi
  fi
  RGDS_GAME_PATH=$_resolved
}

rgds_require_exec() {
  local _bin _label
  _bin=$1
  _label=$2
  if [ -z "$_bin" ]; then
    rgds_fail "engine binary not found: $_label"
  fi
  if [ ! -x "$_bin" ]; then
    rgds_fail "engine binary is not executable: $_bin"
  fi
}

rgds_read_pidfile() {
  RGDS_REC_PID=
  RGDS_REC_ENGINE=
  RGDS_REC_PATH=
  [ -f "$RGDS_GAME_PID_FILE" ] || return 1
  RGDS_REC_PID=$(sed -n '1p' "$RGDS_GAME_PID_FILE" 2>/dev/null || true)
  RGDS_REC_ENGINE=$(sed -n '2p' "$RGDS_GAME_PID_FILE" 2>/dev/null || true)
  RGDS_REC_PATH=$(sed -n '3p' "$RGDS_GAME_PID_FILE" 2>/dev/null || true)
  _cr=$(printf '\r')
  case $RGDS_REC_PID in
    *"$_cr") RGDS_REC_PID=${RGDS_REC_PID%"$_cr"} ;;
  esac
  case $RGDS_REC_ENGINE in
    *"$_cr") RGDS_REC_ENGINE=${RGDS_REC_ENGINE%"$_cr"} ;;
  esac
  case $RGDS_REC_PATH in
    *"$_cr") RGDS_REC_PATH=${RGDS_REC_PATH%"$_cr"} ;;
  esac
  return 0
}

rgds_write_pidfile() {
  local _tmp
  [ ! -d "$RGDS_GAME_PID_FILE" ] || return 1
  _tmp="$RGDS_GAME_PID_FILE.tmp.$$"
  printf '%s\n' "$1" "$2" "$3" > "$_tmp" || { rm -f "$_tmp" 2>/dev/null || true; return 1; }
  mv -f "$_tmp" "$RGDS_GAME_PID_FILE" || { rm -f "$_tmp" 2>/dev/null || true; return 1; }
}

rgds_acquire_lock() {
  local _i _owner
  _i=0
  while [ "$_i" -lt 150 ]; do
    if mkdir -m 700 "$RGDS_GAME_LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" > "$RGDS_GAME_LOCK_DIR/pid"
      RGDS_LOCK_HELD=1
      trap 'rgds_release_lock; exit 1' INT TERM
      return 0
    fi
    _owner=$(sed -n '1p' "$RGDS_GAME_LOCK_DIR/pid" 2>/dev/null || true)
    if rgds_pid_alive "$_owner"; then
      sleep 0.1
      _i=$((_i + 1))
      continue
    fi
    sleep 0.1
    _owner=$(sed -n '1p' "$RGDS_GAME_LOCK_DIR/pid" 2>/dev/null || true)
    if rgds_pid_alive "$_owner"; then
      sleep 0.1
      _i=$((_i + 1))
      continue
    fi
    rm -rf "$RGDS_GAME_LOCK_DIR"
    _i=$((_i + 1))
  done
  printf '%s\n' "game script is busy" >&2
  return 1
}

rgds_release_lock() {
  local _owner
  trap - INT TERM
  if [ "${RGDS_LOCK_HELD:-0}" = 1 ]; then
    _owner=$(sed -n '1p' "$RGDS_GAME_LOCK_DIR/pid" 2>/dev/null || true)
    if [ -z "$_owner" ] || [ "$_owner" = "$$" ]; then
      rm -rf "$RGDS_GAME_LOCK_DIR"
    fi
    RGDS_LOCK_HELD=0
  fi
}

rgds_stop_game() {
  local _pid _id _ticks _n
  if ! rgds_read_pidfile; then
    if [ -e "$RGDS_GAME_PID_FILE" ] && [ ! -d "$RGDS_GAME_PID_FILE" ]; then
      rm -f "$RGDS_GAME_PID_FILE"
    fi
    return 0
  fi
  _pid=$RGDS_REC_PID
  _id=$RGDS_REC_ENGINE
  if ! rgds_is_our_game "$_pid" "$_id"; then
    rm -f "$RGDS_GAME_PID_FILE"
    return 0
  fi
  kill -TERM "$_pid" 2>/dev/null || true
  _ticks=$(rgds_tenths "$RGDS_GAME_STOP_GRACE")
  _n=0
  while [ "$_n" -lt "$_ticks" ]; do
    if ! rgds_pid_alive "$_pid"; then
      rm -f "$RGDS_GAME_PID_FILE"
      return 0
    fi
    sleep 0.1
    _n=$((_n + 1))
  done
  if rgds_pid_alive "$_pid"; then
    kill -KILL "$_pid" 2>/dev/null || true
  fi
  _n=0
  while [ "$_n" -lt 10 ]; do
    if ! rgds_pid_alive "$_pid"; then
      break
    fi
    sleep 0.1
    _n=$((_n + 1))
  done
  rm -f "$RGDS_GAME_PID_FILE"
  return 0
}

rgds_last_log_line() {
  local _line _cr
  _line=$(awk '/[^[:space:]]/ { line = $0 } END { print line }' "$RGDS_GAME_LOG" 2>/dev/null || true)
  _cr=$(printf '\r')
  case $_line in
    *"$_cr") _line=${_line%"$_cr"} ;;
  esac
  if [ -z "$_line" ]; then
    _line="engine exited"
  fi
  if [ -n "${_rgds_pw:-}" ] && command -v python3 >/dev/null 2>&1; then
    _line=$(printf '%s' "$_line" | RGDS_REDACT="$_rgds_pw" python3 -c '
import os, sys
pw = os.environ.get("RGDS_REDACT", "")
text = sys.stdin.read()
if pw and pw in text:
    text = "engine exited"
sys.stdout.write(text)
' || true)
  elif [ -n "${_rgds_pw:-}" ]; then
    _line="engine exited"
  fi
  if [ -z "$_line" ]; then
    _line="engine exited"
  fi
  printf '%s\n' "$_line"
}

rgds_launch_game() {
  local _engine _bin _game _cwd _pid _ticks _n _msg
  _engine=$1
  _bin=$2
  _game=$3
  if [ -d "$_game" ]; then
    _cwd=$_game
  else
    _cwd=$(dirname -- "$_game")
  fi

  : > "$RGDS_GAME_LOG" || rgds_fail "could not write $RGDS_GAME_LOG"

  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME || true
  export RGDS_GAME_ID="$_engine"
  export HOME=/root
  export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/run}"
  export LD_LIBRARY_PATH="${RGDS_GAME_LIB:-}"

  (
    # Ignore HUP so the engine survives the shell tool returning.
    # setsid is not used: whether that tool kills the process group
    # when the call returns is unconfirmed on a device.
    trap '' HUP
    unset _rgds_pw OPENCODE_PASSWORD XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME || true
    cd -- "$_cwd" || exit 1
    if [ "$RGDS_GAME_START_DELAY" != 0 ]; then
      sleep "$RGDS_GAME_START_DELAY" || exit 1
    fi
    exec "$_bin" "$_game"
  ) >> "$RGDS_GAME_LOG" 2>&1 </dev/null &
  _pid=$!
  unset RGDS_GAME_ID || true

  if ! rgds_write_pidfile "$_pid" "$_engine" "$_game" 2>/dev/null; then
    rm -f "$RGDS_GAME_PID_FILE.tmp.$$"
    kill -TERM "$_pid" 2>/dev/null || true
    sleep 0.1
    if rgds_pid_alive "$_pid"; then
      kill -KILL "$_pid" 2>/dev/null || true
    fi
    wait "$_pid" 2>/dev/null || true
    rgds_fail "could not write $RGDS_GAME_PID_FILE"
  fi

  _ticks=$(rgds_tenths "$RGDS_GAME_START_WATCH")
  _n=0
  while [ "$_n" -lt "$_ticks" ]; do
    if ! rgds_pid_alive "$_pid"; then
      _msg=$(rgds_last_log_line)
      rm -f "$RGDS_GAME_PID_FILE"
      rgds_release_lock
      printf '%s\n' "$_msg" >&2
      exit 1
    fi
    sleep 0.1
    _n=$((_n + 1))
  done
  if ! rgds_pid_alive "$_pid"; then
    _msg=$(rgds_last_log_line)
    rm -f "$RGDS_GAME_PID_FILE"
    rgds_release_lock
    printf '%s\n' "$_msg" >&2
    exit 1
  fi

  rgds_release_lock
  printf '%s\n' "$_pid"
}

case $(basename -- "$0") in
  common.sh)
    printf '%s\n' "engines/common.sh is sourced by the game scripts" >&2
    exit 2
    ;;
esac
