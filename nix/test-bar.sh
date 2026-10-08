# Tests that a change of the status of the bar needs no manage sequence of
# river: kwm draws the dynamic component of the bar at once. A manage
# sequence arranges all windows, thus a widget that changes each second must
# not cause one. Run it with the environment of `kwm-test-bar` in tests.nix.
# Refer to src/kwm/bar_update.zig.
#
# Usage: kwm-test-bar
set -euo pipefail

TEST_NAME=bar

# config.def.zon with one more widget: a script that writes a new line each
# 0.3 seconds, with the class "blink" (the widget flashes each 150 ms).
TEST_KWM_CONFIG=$(python3 - "$TEST_DEFAULT_CONFIG" <<'PY'
import json
import sys

script = 'while :; do printf \'{"text":"%s","class":"blink"}\\n\' "$(date +%s%N)"; sleep 0.3; done'
clock = "            .{ .clock = .{} },\n"
config = open(sys.argv[1]).read()
if clock not in config:
    sys.exit("kwm-test-bar: the clock widget is not in config.def.zon")
# A ZON string has the escapes of a JSON string.
widget = f"            .{{ .script = .{{ .exec = {json.dumps(script)}, .interval = 0, .return_type = .json }} }},\n"
print(config.replace(clock, clock + widget, 1), end="")
PY
)

# shellcheck source=test-lib.sh
source "$TEST_LIB"

open a
expect_state a " activated=1 " "the window has the focus"
sleep 2

count() { grep -c "$1" "$work/river.log" || true; }
manage_before=$(count "manage start")
draw_before=$(count "rendering dynamic component")
sleep 4
manages=$(($(count "manage start") - manage_before))
draws=$(($(count "rendering dynamic component") - draw_before))
# A screenshot (screencopy) starts a manage sequence of river, thus the
# screenshots come after the count.
grim "$work/before.png"
sleep 1
grim "$work/after.png"

if [ "$draws" -ge 10 ]; then
  echo "ok: the bar draws each change of the status ($draws draws in 4 seconds)"
else
  echo "FAIL: the bar draws each change of the status ($draws draws in 4 seconds)"
  failed=1
fi
if [ "$manages" -le 1 ]; then
  echo "ok: a change of the status needs no manage sequence ($manages in 4 seconds)"
else
  echo "FAIL: a change of the status needs no manage sequence ($manages in 4 seconds)"
  failed=1
fi

# The commits of the bar show without a render sequence.
changed=$(python3 - "$work/before.png" "$work/after.png" <<'PY'
import sys
from PIL import Image, ImageChops
a, b = (Image.open(path).convert("RGB") for path in sys.argv[1:3])
box = ImageChops.difference(a, b).getbbox()
# The bar is at the top of the output, above the window.
print(1 if box is not None and box[1] < 40 else 0)
PY
)
if [ "$changed" = 1 ]; then
  echo "ok: the screen shows the new status"
else
  echo "FAIL: the screen shows the new status"
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  echo "kwm-test-bar: the log of kwm:" >&2
  # The lines before each manage sequence show its cause.
  grep -E -B6 "manage start" "$work/river.log" | tail -60 >&2 || true
  grep -E "error" "$work/river.log" | head -10 >&2 || true
  exit 1
fi
echo "kwm-test-bar: all tests passed"
