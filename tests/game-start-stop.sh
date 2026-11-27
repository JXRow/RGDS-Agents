#!/bin/sh
# Start and stop scripts, with a stand-in engine. No handheld, no SDL.
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LOVE="$REPO/engines/love/start.sh"
OPENBOR="$REPO/engines/openbor/start.sh"
STOP="$REPO/engines/stop.sh"
SECRET=RGDS-SECRET-7f3a

TMP=$(mktemp -d)
WORK=$TMP/work
PIDS=$TMP/pids
CLEAN_DEFAULT=0
: > "$PIDS"

fail() {
  printf 'FAIL %s\n' "$1" >&2
  if [ -f "$TMP/last.out" ]; then
    printf 'stdout: ' >&2
    sed "s/$SECRET/[redacted]/g" "$TMP/last.out" >&2 || true
  fi
  if [ -f "$TMP/last.err" ]; then
    printf 'stderr: ' >&2
    sed "s/$SECRET/[redacted]/g" "$TMP/last.err" >&2 || true
  fi
  exit 1
}

ok() {
  printf 'ok %s\n' "$1"
}

note() {
  case ${1:-} in
    ""|*[!0-9]*) return 0 ;;
  esac
  printf '%s\n' "$1" >> "$PIDS"
}

cleanup_pid() {
  _cp=$1
  case ${_cp:-} in
    ""|*[!0-9]*|0) return 0 ;;
  esac
  kill -0 "$_cp" 2>/dev/null || return 0
  if { tr '\0' '\n' < "/proc/$_cp/environ"; } 2>/dev/null | grep -q '^RGDS_GAME_ID='; then
    kill -KILL "$_cp" 2>/dev/null || true
  fi
}

cleanup() {
  if [ -f "$PIDS" ]; then
    while IFS= read -r _p; do
      cleanup_pid "$_p"
    done < "$PIDS"
  fi
  if [ "$CLEAN_DEFAULT" = 1 ]; then
    if [ -f /tmp/rgds-game.pid ]; then
      _p=$(sed -n '1p' /tmp/rgds-game.pid 2>/dev/null || true)
      if grep -F -x -q "$_p" "$PIDS" 2>/dev/null; then
        cleanup_pid "$_p"
      fi
    fi
    rm -f /tmp/rgds-game.pid /tmp/rgds-game.log
    rm -rf /tmp/rgds-game.lock
  fi
  rm -rf "${RGDS_GAME_LOCK_DIR:-}"
  rm -rf "$TMP"
}
trap cleanup EXIT

if [ -f /tmp/.next ]; then
  NEXT_BEFORE=$(cksum /tmp/.next)
else
  NEXT_BEFORE=absent
fi

mkdir -p "$WORK/my game" "$WORK/bor game" "$WORK/loose/data" "$TMP/outside" "$TMP/bin"
printf '%s\n' 'return' > "$WORK/my game/main.lua"
printf '%s\n' pak > "$WORK/bor game/demo.pak"
printf '%s\n' x > "$WORK/loose/data/keep"
printf '%s\n' "$WORK" > "$TMP/workdir"

cat > "$TMP/fake-engine" <<'EOF'
#!/bin/sh
out=${RGDS_FAKE_OUT:?}
mkdir -p "$(dirname "$out")"
{
  printf 'pid=%s\n' "$$"
  printf 'started=%s\n' "$(date +%s.%N)"
  printf 'cwd=%s\n' "$(pwd -P)"
  printf 'argcount=%s\n' "$#"
  n=1
  for a in "$@"; do
    printf 'arg%s=%s\n' "$n" "$a"
    n=$((n + 1))
  done
  printf '%s\n' '----env----'
  env | sort
} > "$out"
mode=${RGDS_FAKE_MODE:-run}
case $mode in
  die)
    printf '%s\n' 'boom-line' >&2
    exit 7
    ;;
  ignore-term)
    exec python3 -c 'import signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
while True:
    time.sleep(30)
'
    ;;
esac
exec sleep 60
EOF
chmod +x "$TMP/fake-engine"
cp "$TMP/fake-engine" "$TMP/bin/love"
cp "$TMP/fake-engine" "$TMP/bin/OpenBOR-arm64"
chmod +x "$TMP/bin/love" "$TMP/bin/OpenBOR-arm64"

cat > "$TMP/bin/path-only" <<'EOF'
#!/bin/sh
printf '%s\n' path > "${RGDS_FAKE_MARKER:?}"
exec sleep 60
EOF
chmod +x "$TMP/bin/path-only"

export OPENCODE_WORKDIR_FILE=$TMP/workdir
export RGDS_GAME_PID_FILE=$TMP/game.pid
export RGDS_GAME_LOG=$TMP/game.log
export RGDS_GAME_LOCK_DIR=$TMP/game.lock
export RGDS_GAME_START_DELAY=0
export RGDS_GAME_START_WATCH=0.4
export RGDS_GAME_STOP_GRACE=0.3
export OPENCODE_PASSWORD=$SECRET
export XDG_CONFIG_HOME=/userdata/opencode/config
export XDG_DATA_HOME=/userdata/opencode/share
export XDG_STATE_HOME=/userdata/opencode/state
export XDG_CACHE_HOME=/userdata/opencode/cache
export LD_LIBRARY_PATH=/from/parent/lib
export ALSOFT_CONF=/from/parent/alsoft.conf
export SDL_VIDEO_DOUBLE_BUFFER=0
unset XDG_RUNTIME_DIR WAYLAND_DISPLAY RGDS_LOVE_BIN RGDS_OPENBOR_BIN || true

run() {
  set +e
  "$@" > "$TMP/last.out" 2> "$TMP/last.err"
  LAST_CODE=$?
  set -e
  LAST_OUT=$(cat "$TMP/last.out" 2>/dev/null || true)
  LAST_ERR=$(cat "$TMP/last.err" 2>/dev/null || true)
}

forbid_secret() {
  _f=$1
  if [ -f "$_f" ] && grep -F -q "$SECRET" "$_f"; then
    fail "$_f contains the server password"
  fi
}

assert_code() {
  if [ "$LAST_CODE" -ne "$1" ]; then
    fail "$2 (exit $LAST_CODE, expected $1)"
  fi
}

assert_err() {
  if [ "$LAST_ERR" != "$1" ]; then
    fail "$2"
  fi
}

env_has() {
  if ! grep -x -F -q "$1" "$2"; then
    fail "missing env line: $1"
  fi
}

env_lacks() {
  if grep -F -q "$1" "$2"; then
    fail "env should not contain $1"
  fi
}

alive() {
  kill -0 "$1" 2>/dev/null
}

# --- refuse bad invocations before touching a running game ---

run "$LOVE"
assert_code 1 "love usage with no args"
assert_err "usage: start.sh <game path>" "love usage text"
ok "love usage"

run "$OPENBOR" too many
assert_code 1 "openbor extra args"
assert_err "usage: start.sh <game path>" "openbor usage text"
ok "openbor usage"

run "$LOVE" "$WORK/missing"
assert_code 1 "missing path"
assert_err "game path does not exist: $WORK/missing" "missing path text"
if [ -e "$RGDS_GAME_PID_FILE" ]; then
  fail "missing path wrote a pid file"
fi
ok "missing path"

run "$LOVE" "$TMP/outside"
assert_code 1 "outside path"
assert_err "game path is outside the work directory: $TMP/outside" "outside text"
ok "outside path"

ln -s "$TMP/outside" "$WORK/escape"
run "$LOVE" "$WORK/escape"
assert_code 1 "symlink escape"
assert_err "game path is outside the work directory: $WORK/escape" "symlink text"
ok "symlink escape"

run "$LOVE" "$WORK/my game/../../outside"
assert_code 1 "dotdot escape"
assert_err "game path is outside the work directory: $WORK/my game/../../outside" "dotdot text"
ok "dotdot escape"

NL="$WORK/bad
name"
mkdir -p "$NL"
run "$LOVE" "$NL"
assert_code 1 "newline path"
assert_err "game path is not valid" "newline text"
ok "newline path"

printf '\n' > "$TMP/workdir"
run "$LOVE" "$WORK/my game"
assert_code 1 "blank workdir"
assert_err "game path is outside the work directory: $WORK/my game" "blank workdir text"
rm -f "$TMP/workdir"
run "$OPENBOR" "$WORK/bor game/demo.pak"
assert_code 1 "missing workdir file"
assert_err "game path is outside the work directory: $WORK/bor game/demo.pak" "missing workdir text"
printf '   \n' > "$TMP/workdir"
run "$LOVE" "$WORK/my game"
assert_code 1 "whitespace workdir"
ok "default workdir is not the test tree"

printf '%s \r\n' "$WORK" > "$TMP/workdir"

# --- love start: pid file, cleared environment, engine args ---

FAKE_OUT=$TMP/love.out
t0=$(date +%s.%N)
run env RGDS_LOVE_BIN="$TMP/fake-engine" RGDS_FAKE_OUT="$FAKE_OUT" RGDS_FAKE_MODE=run \
  RGDS_GAME_START_DELAY=0.3 RGDS_GAME_START_WATCH=0.6 \
  "$LOVE" "$WORK/my game"
assert_code 0 "love start"
forbid_secret "$TMP/last.out"
forbid_secret "$TMP/last.err"
forbid_secret "$RGDS_GAME_PID_FILE"
forbid_secret "$RGDS_GAME_LOG"
forbid_secret "$FAKE_OUT"
if [ -n "$LAST_ERR" ]; then
  fail "love start wrote stderr"
fi
love_pid=$LAST_OUT
note "$love_pid"
if ! alive "$love_pid"; then
  fail "love pid is not alive"
fi
printf '%s\n' "$love_pid" love "$(readlink -f -- "$WORK/my game")" > "$TMP/expect.pid"
if ! cmp -s "$TMP/expect.pid" "$RGDS_GAME_PID_FILE"; then
  fail "love pid file"
fi
if [ "$(sed -n 's/^pid=//p' "$FAKE_OUT")" != "$love_pid" ]; then
  fail "engine pid is not the recorded pid"
fi
if [ "$(sed -n 's/^cwd=//p' "$FAKE_OUT")" != "$(readlink -f -- "$WORK/my game")" ]; then
  fail "love cwd"
fi
if [ "$(sed -n 's/^argcount=//p' "$FAKE_OUT")" != 1 ]; then
  fail "love arg count"
fi
if [ "$(sed -n 's/^arg1=//p' "$FAKE_OUT")" != "$(readlink -f -- "$WORK/my game")" ]; then
  fail "love arg"
fi
env_has "HOME=/root" "$FAKE_OUT"
env_has "WAYLAND_DISPLAY=wayland-0" "$FAKE_OUT"
env_has "XDG_RUNTIME_DIR=/var/run" "$FAKE_OUT"
env_has "SDL_VIDEO_DOUBLE_BUFFER=1" "$FAKE_OUT"
env_has "ALSOFT_CONF=$REPO/alsoft.conf" "$FAKE_OUT"
env_has "LD_LIBRARY_PATH=$REPO/lib:/from/parent/lib" "$FAKE_OUT"
env_has "RGDS_GAME_ID=love" "$FAKE_OUT"
env_lacks "XDG_CONFIG_HOME" "$FAKE_OUT"
env_lacks "XDG_DATA_HOME" "$FAKE_OUT"
env_lacks "XDG_STATE_HOME" "$FAKE_OUT"
env_lacks "XDG_CACHE_HOME" "$FAKE_OUT"
env_lacks "OPENCODE_PASSWORD" "$FAKE_OUT"
started=$(sed -n 's/^started=//p' "$FAKE_OUT")
python3 -c 'import sys; raise SystemExit(0 if float(sys.argv[1]) - float(sys.argv[2]) >= 0.2 else 1)' \
  "$started" "$t0" || fail "engine started before the delay"
if [ -d "$RGDS_GAME_LOCK_DIR" ]; then
  fail "lock left held after start"
fi
ok "love start"

# --- second start stops the first ---

FAKE_OUT=$TMP/bor.out
run env RGDS_OPENBOR_BIN="$TMP/fake-engine" RGDS_FAKE_OUT="$FAKE_OUT" RGDS_FAKE_MODE=run \
  "$OPENBOR" "$WORK/bor game/demo.pak"
assert_code 0 "openbor start"
bor_pid=$LAST_OUT
note "$bor_pid"
if alive "$love_pid"; then
  fail "second start left the first game running"
fi
if ! alive "$bor_pid"; then
  fail "openbor pid is not alive"
fi
pak=$(readlink -f -- "$WORK/bor game/demo.pak")
printf '%s\n' "$bor_pid" openbor "$pak" > "$TMP/expect.pid"
if ! cmp -s "$TMP/expect.pid" "$RGDS_GAME_PID_FILE"; then
  fail "openbor pid file"
fi
if [ "$(sed -n 's/^cwd=//p' "$FAKE_OUT")" != "$(readlink -f -- "$WORK/bor game")" ]; then
  fail "openbor cwd"
fi
if [ "$(sed -n 's/^arg1=//p' "$FAKE_OUT")" != "$pak" ]; then
  fail "openbor arg"
fi
env_has "LD_LIBRARY_PATH=$REPO/engines/openbor" "$FAKE_OUT"
env_has "RGDS_GAME_ID=openbor" "$FAKE_OUT"
env_has "HOME=/root" "$FAKE_OUT"
env_lacks "ALSOFT_CONF" "$FAKE_OUT"
env_lacks "SDL_VIDEO_DOUBLE_BUFFER" "$FAKE_OUT"
env_lacks "/from/parent/lib" "$FAKE_OUT"
env_lacks "$REPO/lib" "$FAKE_OUT"
env_lacks "XDG_CONFIG_HOME" "$FAKE_OUT"
env_lacks "OPENCODE_PASSWORD" "$FAKE_OUT"
forbid_secret "$FAKE_OUT"
ok "second start stops the first"

# A bad start must not stop the game that is already running.
saved=$(cat "$RGDS_GAME_PID_FILE")
run env PATH=/usr/bin:/bin "$LOVE" "$WORK/my game"
assert_code 1 "missing binary"
assert_err "engine binary not found: love" "missing binary text"
if ! alive "$bor_pid"; then
  fail "missing binary stopped the running game"
fi
if [ "$(cat "$RGDS_GAME_PID_FILE")" != "$saved" ]; then
  fail "missing binary changed the pid file"
fi
ok "missing binary"

printf '%s\n' '#!/bin/sh' > "$TMP/not-executable"
chmod 644 "$TMP/not-executable"
run env RGDS_LOVE_BIN="$TMP/not-executable" "$LOVE" "$WORK/my game"
assert_code 1 "non-executable binary"
assert_err "engine binary is not executable: $TMP/not-executable" "non-executable text"
if ! alive "$bor_pid"; then
  fail "bad binary stopped the running game"
fi
ok "non-executable binary"

run env RGDS_OPENBOR_BIN="$TMP/fake-engine" "$OPENBOR" "$TMP/outside"
assert_code 1 "outside while running"
assert_err "game path is outside the work directory: $TMP/outside" "outside while running text"
if ! alive "$bor_pid"; then
  fail "outside path stopped the running game"
fi
if [ "$(cat "$RGDS_GAME_PID_FILE")" != "$saved" ]; then
  fail "outside path changed the pid file"
fi
ok "bad start leaves the running game"

# TERM ends a normal engine without waiting out the grace period.
t0=$(date +%s.%N)
run env RGDS_GAME_STOP_GRACE=2 "$STOP"
assert_code 0 "stop"
if [ "$LAST_OUT" != "stopped" ]; then
  fail "stop stdout"
fi
if alive "$bor_pid"; then
  fail "stop left the game running"
fi
if [ -e "$RGDS_GAME_PID_FILE" ]; then
  fail "stop left the pid file"
fi
python3 -c 'import sys; raise SystemExit(0 if float(sys.argv[1]) - float(sys.argv[2]) < 1.5 else 1)' \
  "$(date +%s.%N)" "$t0" || fail "stop waited for the kill grace"
ok "stop"

run "$STOP"
assert_code 0 "stop with nothing"
if [ "$LAST_OUT" != "stopped" ]; then
  fail "second stop stdout"
fi
ok "stop with nothing"

printf '%s\n' 999999 love "$WORK/my game" > "$RGDS_GAME_PID_FILE"
run "$STOP"
assert_code 0 "stale pid"
if [ -e "$RGDS_GAME_PID_FILE" ]; then
  fail "stale pid file remained"
fi
ok "stale pid"

printf '%s\n' 'not-a-pid' > "$RGDS_GAME_PID_FILE"
run "$STOP"
assert_code 0 "garbage pid"
if [ -e "$RGDS_GAME_PID_FILE" ]; then
  fail "garbage pid file remained"
fi
ok "garbage pid"

sleep 60 &
other=$!
note "$other"
printf '%s\n' "$other" love "$WORK/my game" > "$RGDS_GAME_PID_FILE"
run "$STOP"
assert_code 0 "unrelated pid"
if ! alive "$other"; then
  fail "stop killed a process that was not the game"
fi
if [ -e "$RGDS_GAME_PID_FILE" ]; then
  fail "unrelated pid file remained"
fi
kill -KILL "$other" 2>/dev/null || true
ok "unrelated pid"

# Engine dies during the watch.
FAKE_OUT=$TMP/die.out
run env RGDS_LOVE_BIN="$TMP/fake-engine" RGDS_FAKE_OUT="$FAKE_OUT" RGDS_FAKE_MODE=die \
  "$LOVE" "$WORK/my game"
assert_code 1 "dying engine"
assert_err "boom-line" "dying engine text"
if [ -n "$LAST_OUT" ]; then
  fail "dying engine wrote stdout"
fi
if [ -e "$RGDS_GAME_PID_FILE" ]; then
  fail "dying engine left a pid file"
fi
forbid_secret "$FAKE_OUT"
forbid_secret "$RGDS_GAME_LOG"
env_lacks "OPENCODE_PASSWORD" "$FAKE_OUT"
env_lacks "XDG_CONFIG_HOME" "$FAKE_OUT"
ok "dying engine"

# SIGKILL after the grace when TERM is ignored.
FAKE_OUT=$TMP/stubborn.out
run env RGDS_LOVE_BIN="$TMP/fake-engine" RGDS_FAKE_OUT="$FAKE_OUT" RGDS_FAKE_MODE=ignore-term \
  "$LOVE" "$WORK/my game"
assert_code 0 "stubborn start"
stubborn=$LAST_OUT
note "$stubborn"
if ! alive "$stubborn"; then
  fail "stubborn engine did not stay up"
fi
run "$STOP"
assert_code 0 "stop stubborn"
if alive "$stubborn"; then
  fail "stop did not kill an engine that ignores TERM"
fi
if [ -e "$RGDS_GAME_PID_FILE" ]; then
  fail "stubborn pid file remained"
fi
ok "stop kills when TERM is ignored"

# PATH lookup, and an injected binary wins over PATH.
FAKE_OUT=$TMP/path-love.out
run env PATH="$TMP/bin:/usr/bin:/bin" RGDS_FAKE_OUT="$FAKE_OUT" RGDS_FAKE_MODE=run \
  "$LOVE" "$WORK/my game"
assert_code 0 "love on PATH"
note "$LAST_OUT"
if [ "$(sed -n 's/^arg1=//p' "$FAKE_OUT")" != "$(readlink -f -- "$WORK/my game")" ]; then
  fail "PATH love was not the engine"
fi
run "$STOP"
ok "love on PATH"

mkdir -p "$TMP/override-bin"
cp "$TMP/bin/path-only" "$TMP/override-bin/love"
marker=$TMP/path-marker
rm -f "$marker"
FAKE_OUT=$TMP/injected.out
run env PATH="$TMP/override-bin:/usr/bin:/bin" RGDS_LOVE_BIN="$TMP/fake-engine" \
  RGDS_FAKE_OUT="$FAKE_OUT" RGDS_FAKE_MARKER="$marker" RGDS_FAKE_MODE=run \
  "$LOVE" "$WORK/my game"
assert_code 0 "injected over decoy"
note "$LAST_OUT"
if [ -e "$marker" ]; then
  fail "decoy on PATH ran instead of RGDS_LOVE_BIN"
fi
env_has "RGDS_GAME_ID=love" "$FAKE_OUT"
run "$STOP"
ok "injected binary beats a PATH decoy"

FAKE_OUT=$TMP/path-bor.out
run env PATH="$TMP/bin:/usr/bin:/bin" RGDS_FAKE_OUT="$FAKE_OUT" RGDS_FAKE_MODE=run \
  "$OPENBOR" "$WORK/loose"
assert_code 0 "openbor on PATH"
note "$LAST_OUT"
loose=$(readlink -f -- "$WORK/loose")
if [ "$(sed -n 's/^cwd=//p' "$FAKE_OUT")" != "$loose" ]; then
  fail "loose data cwd"
fi
if [ "$(sed -n 's/^arg1=//p' "$FAKE_OUT")" != "$loose" ]; then
  fail "loose data arg"
fi
if [ "$(sed -n '2p' "$RGDS_GAME_PID_FILE")" != openbor ]; then
  fail "loose data engine id"
fi
run "$STOP"
ok "openbor on PATH"

# Relative path, from the work directory.
FAKE_OUT=$TMP/rel.out
(
  set +e
  cd "$WORK"
  env RGDS_LOVE_BIN="$TMP/fake-engine" RGDS_FAKE_OUT="$FAKE_OUT" RGDS_FAKE_MODE=run \
    "$LOVE" "./my game" > "$TMP/last.out" 2> "$TMP/last.err"
  echo $? > "$TMP/rel.code"
)
LAST_CODE=$(cat "$TMP/rel.code")
LAST_OUT=$(cat "$TMP/last.out")
LAST_ERR=$(cat "$TMP/last.err")
assert_code 0 "relative path"
note "$LAST_OUT"
if [ "$(sed -n '3p' "$RGDS_GAME_PID_FILE")" != "$(readlink -f -- "$WORK/my game")" ]; then
  fail "relative path was not stored absolute"
fi
run "$STOP"
ok "relative path"

run "$STOP" extra
assert_code 1 "stop usage"
assert_err "usage: stop.sh" "stop usage text"
ok "stop usage"

run sh "$REPO/engines/common.sh"
assert_code 2 "common.sh executed"
ok "common.sh is not a launcher"

# Defaults: an unset pid-file variable really is /tmp/rgds-game.pid.
if [ -e /tmp/rgds-game.pid ] || [ -e /tmp/rgds-game.log ] || [ -e /tmp/rgds-game.lock ]; then
  ok "skip default pid path (files already present)"
else
  CLEAN_DEFAULT=1
  FAKE_OUT=$TMP/default.out
  (
    set +e
    unset RGDS_GAME_PID_FILE RGDS_GAME_LOG RGDS_GAME_LOCK_DIR
    env RGDS_LOVE_BIN="$TMP/fake-engine" RGDS_FAKE_OUT="$FAKE_OUT" RGDS_FAKE_MODE=run \
      "$LOVE" "$WORK/my game" > "$TMP/last.out" 2> "$TMP/last.err"
    echo $? > "$TMP/def.code"
  )
  LAST_CODE=$(cat "$TMP/def.code")
  LAST_OUT=$(cat "$TMP/last.out")
  assert_code 0 "default pid path start"
  note "$LAST_OUT"
  if [ "$(sed -n '1p' /tmp/rgds-game.pid)" != "$LAST_OUT" ]; then
    fail "default pid file"
  fi
  if [ "$(sed -n '2p' /tmp/rgds-game.pid)" != love ]; then
    fail "default pid engine"
  fi
  (
    set +e
    unset RGDS_GAME_PID_FILE RGDS_GAME_LOG RGDS_GAME_LOCK_DIR
    "$STOP" > "$TMP/last.out" 2> "$TMP/last.err"
    echo $? > "$TMP/def.code"
  )
  LAST_CODE=$(cat "$TMP/def.code")
  assert_code 0 "default pid path stop"
  if [ -e /tmp/rgds-game.pid ]; then
    fail "default stop left /tmp/rgds-game.pid"
  fi
  ok "default pid path"
fi

# A log line that contains the server password is not printed.
(
  set +e
  export OPENCODE_PASSWORD="$SECRET"
  export RGDS_GAME_LOG="$TMP/redact.log"
  printf '%s\n' "failed $SECRET" > "$RGDS_GAME_LOG"
  . "$REPO/engines/common.sh"
  rgds_last_log_line > "$TMP/redact.out" 2> "$TMP/redact.err"
  echo $? > "$TMP/redact.code"
)
if [ "$(cat "$TMP/redact.code")" -ne 0 ]; then
  fail "redaction helper failed"
fi
if [ "$(cat "$TMP/redact.out")" != "engine exited" ]; then
  fail "log line with the server password was not replaced"
fi
if grep -F -q "$SECRET" "$TMP/redact.out" || grep -F -q "$SECRET" "$TMP/redact.err"; then
  fail "redaction helper printed the server password"
fi
ok "log line redaction"

# Reject the controller's own directory even when workdir is that directory.
printf '%s\n' "$REPO" > "$TMP/workdir-self"
run env OPENCODE_WORKDIR_FILE="$TMP/workdir-self" RGDS_LOVE_BIN="$TMP/fake-engine" "$LOVE" "$REPO"
assert_code 1 "controller directory rejected"
assert_err "game path cannot be the controller directory: $REPO" "controller directory text"
ok "controller directory rejected"

# Reject a regular file as workdir.
printf '%s\n' "$TMP/not-a-dir" > "$TMP/not-a-dir"
printf '%s\n' "$TMP/not-a-dir" > "$TMP/workdir-file"
run env OPENCODE_WORKDIR_FILE="$TMP/workdir-file" RGDS_LOVE_BIN="$TMP/fake-engine" "$LOVE" "$TMP/not-a-dir"
assert_code 1 "regular file workdir rejected"
ok "regular file workdir rejected"

# Workdir '/' accepts ordinary descendants.
printf '%s\n' "/" > "$TMP/workdir-root"
run env OPENCODE_WORKDIR_FILE="$TMP/workdir-root" RGDS_LOVE_BIN="$TMP/fake-engine" RGDS_FAKE_OUT="$TMP/root.out" RGDS_FAKE_MODE=run "$LOVE" "$WORK/my game"
assert_code 0 "root workdir start"
note "$LAST_OUT"
run "$STOP"
ok "root workdir"

# Failed pidfile publication terminates the launched engine and releases the lock.
mkdir -p "$TMP/pid-as-dir"
run env RGDS_GAME_PID_FILE="$TMP/pid-as-dir" RGDS_LOVE_BIN="$TMP/fake-engine" RGDS_FAKE_OUT="$TMP/badpid.out" RGDS_FAKE_MODE=run "$LOVE" "$WORK/my game"
assert_code 1 "unwritable pidfile fails"
if [ -e "$RGDS_GAME_LOCK_DIR" ]; then
  fail "unwritable pidfile left lock directory"
fi
if [ -f "$TMP/badpid.out" ]; then
  _leaked=$(sed -n 's/^pid=//p' "$TMP/badpid.out" 2>/dev/null || true)
  if [ -n "$_leaked" ] && alive "$_leaked"; then
    kill -KILL "$_leaked" 2>/dev/null || true
    fail "unwritable pidfile left engine alive"
  fi
fi
ok "unwritable pidfile cleanup"

# Trailing blank lines in the engine log do not hide the last message.
(
  set +e
  export RGDS_GAME_LOG="$TMP/blank-tail.log"
  printf 'real error line\n\n   \n' > "$RGDS_GAME_LOG"
  . "$REPO/engines/common.sh"
  rgds_last_log_line > "$TMP/blank-tail.out"
)
if [ "$(cat "$TMP/blank-tail.out")" != "real error line" ]; then
  fail "trailing blank lines hid last log line"
fi
ok "trailing blank line log"

if [ -f /tmp/.next ]; then
  NEXT_AFTER=$(cksum /tmp/.next)
else
  NEXT_AFTER=absent
fi
if [ "$NEXT_BEFORE" != "$NEXT_AFTER" ]; then
  fail "script wrote /tmp/.next"
fi
ok "no /tmp/.next"

printf 'PASS\n'
