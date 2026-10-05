# Tests the maximized state that kwm gives to windows: river with the headless
# backend of wlroots, kwm with config.def.zon (smart_gaps = true) and the
# windows of test-client.py. Run it with the environment of `kwm-test-maximize`
# in tests.nix.
#
# Usage: kwm-test-maximize
set -euo pipefail

work=$(mktemp -d)
pids=()
cleanup() {
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

unset GTK_THEME DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE \
  XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME LD_PRELOAD

# A home that holds no setting of the user. kwm reads config.def.zon.
export HOME=$work/home
export XDG_CONFIG_HOME=$work/config
export XDG_RUNTIME_DIR=$work/run
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

export WLR_BACKENDS=headless
export WLR_RENDERER=pixman
export WLR_HEADLESS_OUTPUTS=1
export WLR_LIBINPUT_NO_DEVICES=1

dbus-daemon --config-file="$DBUS_SESSION_CONF" --fork \
  --print-address=3 --print-pid=4 3>"$work/bus-address" 4>"$work/bus-pid"
pids+=("$(cat "$work/bus-pid")")
DBUS_SESSION_BUS_ADDRESS=$(cat "$work/bus-address")
export DBUS_SESSION_BUS_ADDRESS

river -no-xwayland -c "kwm -log-level debug" >"$work/river.log" 2>&1 &
pids+=("$!")

for _ in $(seq 100); do
  socket=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' -print -quit)
  [ -n "$socket" ] && break
  sleep 0.1
done
if [ -z "${socket:-}" ]; then
  echo "kwm-test-maximize: river did not start" >&2
  cat "$work/river.log" >&2
  exit 1
fi
WAYLAND_DISPLAY=$(basename "$socket")
export WAYLAND_DISPLAY
sleep 1

declare -A client
failed=0

# open <name> [flags of test-client.py]
open() {
  python3 "$TEST_CLIENT" "$1" "$work/$1.state" "${@:2}" &
  client[$1]=$!
  pids+=("$!")
}

# close <name>
close() {
  kill "${client[$1]}"
  wait "${client[$1]}" 2>/dev/null || true
}

# expect <name> <0|1> <description>: the window gets maximized=<0|1>, and
# keeps it for one second.
expect() {
  local file=$work/$1.state
  for _ in $(seq 50); do
    if grep -qs "^maximized=$2 " "$file"; then
      sleep 1
      if grep -qs "^maximized=$2 " "$file"; then
        echo "ok: $3"
        return
      fi
    fi
    sleep 0.1
  done
  echo "FAIL: $3 (window $1: $(cat "$file" 2>/dev/null || echo 'no configure'))"
  failed=1
}

open a
expect a 1 "one tiled window fills the output, thus it is maximized"

open b --maximize
expect b 0 "a tiled window that asks to be maximized at start is not maximized"
expect a 0 "the first window no longer fills the output"

close b
expect a 1 "the first window fills the output again"

open c
expect c 0 "a second tiled window is not maximized"
kill -USR1 "${client[c]}"
expect c 1 "a mapped window that asks to be maximized is maximized"
expect a 0 "the other window stays unmaximized"
kill -USR2 "${client[c]}"
expect c 0 "a window that asks to be unmaximized is unmaximized"

open d --fixed --maximize
expect d 1 "a floating window that asks to be maximized at start is maximized"

if [ "$failed" -ne 0 ]; then
  echo "kwm-test-maximize: the log of kwm:" >&2
  grep -E "maximiz|managing new window|floating" "$work/river.log" >&2 || true
  exit 1
fi
echo "kwm-test-maximize: all tests passed"
