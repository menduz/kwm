# The shared part of the tests of kwm: river with the headless backend of
# wlroots, kwm with config.def.zon, and the windows of test-client.py. A test
# script sources this file. Run the test with the environment of tests.nix.
#
# The script sets TEST_NAME before it sources this file.

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
  echo "kwm-test-$TEST_NAME: river did not start" >&2
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

# expect_state <name> <regex> <description>: the state line of the window
# matches the extended regex, and keeps it for one second.
expect_state() {
  local file=$work/$1.state
  for _ in $(seq 50); do
    if grep -qsE "$2" "$file"; then
      sleep 1
      if grep -qsE "$2" "$file"; then
        echo "ok: $3"
        return
      fi
    fi
    sleep 0.1
  done
  echo "FAIL: $3 (window $1: $(cat "$file" 2>/dev/null || echo 'no configure'))"
  failed=1
}

# start_input: a virtual keyboard and a virtual pointer (test-input.py). The
# pointer starts at the top left corner of the output.
start_input() {
  mkfifo "$work/input"
  python3 "$TEST_INPUT" "$work/input" "$work/input.done" 1280 720 &
  pids+=("$!")
  exec {input_fd}>"$work/input"
  input_count=0
  for _ in $(seq 50); do
    [ -s "$work/input.done" ] && return
    sleep 0.1
  done
  echo "kwm-test-$TEST_NAME: test-input.py did not start" >&2
  exit 1
}

# input <command>: give a command to test-input.py and wait until it is done.
input() {
  echo "$*" >&"$input_fd"
  input_count=$((input_count + 1))
  for _ in $(seq 50); do
    [ "$(cat "$work/input.done" 2>/dev/null)" = "$input_count" ] && sleep 0.2 && return
    sleep 0.1
  done
  echo "kwm-test-$TEST_NAME: test-input.py did not do: $*" >&2
  exit 1
}

# expect_exit <name> <description>: the client of the window stops.
expect_exit() {
  for _ in $(seq 50); do
    if ! kill -0 "${client[$1]}" 2>/dev/null; then
      echo "ok: $2"
      return
    fi
    sleep 0.1
  done
  echo "FAIL: $2 (the client of window $1 runs)"
  failed=1
  close "$1"
}
