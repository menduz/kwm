# Tests the keyboard focus that kwm gives to windows: river with the headless
# backend of wlroots, kwm with config.def.zon (sloppy_focus = true) and the
# windows of test-client.py. Run it with the environment of `kwm-test-focus`
# in tests.nix.
#
# Usage: kwm-test-focus
set -euo pipefail

TEST_NAME=focus
# shellcheck source=test-lib.sh
source "$TEST_LIB"

# The headless output has 1280x720 pixels. With two windows, the tile layout
# puts the new window on the left and the first window on the right.
left_x=300
right_x=1000
y=300

start_input

open a
expect_state a " activated=1 keyboard=1 " "the first window has the focus"
open b
expect_state b " activated=1 keyboard=1 " "the new window has the focus"
expect_state a " activated=0 keyboard=0 " "the first window loses the focus"
close b
expect_state a "^maximized=1 activated=1 keyboard=1 " "after a close of the focused window, the last window gets the focus"
close a

# Brave: a tab goes from window a into window b. The tab is a drag from a, and
# a closes after the drop. During the drag, the pointer over b gives b the
# focus of river (sloppy_focus), but wlroots drops the keyboard enter. Refer to
# src/kwm/refocus.zig.
open a --drag
expect_state a " activated=1 keyboard=1 " "the window with the tab has the focus"
open b
expect_state b " activated=1 keyboard=1 " "the other window has the focus"
input move "$right_x" "$y"
expect_state a " activated=1 keyboard=1 " "the pointer gives the focus to the window with the tab"
input press
input move "$left_x" "$y"
expect_state b " activated=1 " "during the drag, the pointer gives the focus of river to the other window"
input release
expect_exit a "the window of the tab closes after the drop"
expect_state b "^maximized=1 activated=1 keyboard=1 " "after the drop, the other window gets the keyboard"

if [ "$failed" -ne 0 ]; then
  echo "kwm-test-focus: the log of kwm:" >&2
  grep -E "focus|closed|pointer enter|interaction" "$work/river.log" | tail -60 >&2 || true
  exit 1
fi
echo "kwm-test-focus: all tests passed"
