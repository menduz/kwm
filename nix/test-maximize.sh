# Tests the maximized state that kwm gives to windows: river with the headless
# backend of wlroots, kwm with config.def.zon (smart_gaps = true) and the
# windows of test-client.py. Run it with the environment of `kwm-test-maximize`
# in tests.nix.
#
# Usage: kwm-test-maximize
set -euo pipefail

TEST_NAME=maximize
# shellcheck source=test-lib.sh
source "$TEST_LIB"

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

# expect_size <name> <width> <height> <description>: the window gets this
# size, and keeps it for one second.
expect_size() {
  local file=$work/$1.state
  for _ in $(seq 50); do
    if grep -qs " width=$2 height=$3$" "$file"; then
      sleep 1
      if grep -qs " width=$2 height=$3$" "$file"; then
        echo "ok: $4"
        return
      fi
    fi
    sleep 0.1
  done
  echo "FAIL: $4 (window $1: $(cat "$file" 2>/dev/null || echo 'no configure'))"
  failed=1
}

open a
expect a 1 "one tiled window fills the output, thus it is maximized"
# The exclusive area of the output: the headless output less the bar.
full=$(cat "$work/a.state")
full_width=$(sed -E 's/.* width=([0-9]+).*/\1/' <<<"$full")
full_height=$(sed -E 's/.* height=([0-9]+).*/\1/' <<<"$full")

open b --maximize
expect b 0 "a tiled window that asks to be maximized at start is not maximized"
expect a 0 "the first window no longer fills the output"

close b
expect a 1 "the first window fills the output again"

# Some clients ask again to be maximized, for example when their window shows
# again after a change of tag. kwm must not maximize such a window itself: a
# window that kwm maximizes is smaller by the border on each side.
kill -USR1 "${client[a]}"
expect_size a "$full_width" "$full_height" "a window that fills the output and asks to be maximized keeps all of the output"

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
