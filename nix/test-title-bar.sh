# Tests the title bar of kwm: kwm always tries server side decorations, and a
# window with them that is not maximized gets a title bar with a close button.
# Run it with the environment of `kwm-test-title-bar` in tests.nix. Refer to
# src/kwm/decoration.zig and src/kwm/title_bar.zig.
#
# Without a GTK theme, the title bar has the colors of Windows Standard: the
# caption of the focused window starts with #000080, and the caption of
# another window is #808080.
#
# Usage: kwm-test-title-bar
set -euo pipefail

TEST_NAME=title-bar
# shellcheck source=test-lib.sh
source "$TEST_LIB"

# The height of a title bar: the caption (18) and a line below it.
title_height=19

# field <name> <field>: a value of the state line of a window.
field() {
  sed -E "s/.* $2=([^ ]+).*/\1/" "$work/$1.state"
}

# caption <name> <png> <rrggbb> [<rrggbb> <width>]: the caption of a window,
# as "x y rows": the longest run of rows with at least 50 pixels of the
# color, its left end and its top. With a second color, the caption is a
# gradient from the first color to the second one over <width> pixels, as
# decoration.zig paints it. The border has lines of some colors of the
# caption, but each line is one row.
caption() {
  python3 - "${@:2}" <<'PY'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
def rgb(hex_color):
    return tuple(int(hex_color[i:i + 2], 16) for i in (0, 2, 4))
def gradient(a, b, x, span):
    return tuple(ca + ((cb - ca) * x + span // 2) // span for ca, cb in zip(a, b))
if len(sys.argv) > 3:
    start, end, span = rgb(sys.argv[2]), rgb(sys.argv[3]), int(sys.argv[4]) - 1
    wanted = {gradient(start, end, x, span) for x in range(span + 1)}
else:
    wanted = {rgb(sys.argv[2])}
pixels = image.load()
width, height = image.size
best = None
run_start = None
for y in range(height + 1):
    xs = [x for x in range(width) if y < height and pixels[x, y] in wanted]
    if len(xs) >= 50:
        if run_start is None:
            run_start, left = y, min(xs)
        left = min(left, min(xs))
    elif run_start is not None:
        if best is None or y - run_start > best[2]:
            best = (left, run_start, y - run_start)
        run_start = None
print(" ".join(map(str, best)) if best else "none none 0")
PY
}

start_input

# The height of a tiled window next to another one, without title bar.
open x
open y
expect_state y " tiled=1 " "a reference window is tiled"
tiled_height=$(field y height)
close x
close y

open a --decoration
expect_state a "^maximized=1 .* decoration=server " \
  "a client that asks for client side decorations gets server side decorations"
expect_state a " height=$(field a height)$" "a window that fills the output has no title bar"

open b --decoration
expect_state b " decoration=server .* height=$((tiled_height - title_height))$" \
  "a tiled window keeps the top of its place for its title bar"
expect_state a " height=$((tiled_height - title_height))$" "the other tiled window has a title bar too"

grim "$work/shot.png"
width=$(field b width)
read -r focused_x focused_y focused_rows <<<"$(caption b "$work/shot.png" 000080 1084d0 "$width")"
read -r _ _ other_rows <<<"$(caption a "$work/shot.png" 808080)"
if [ "$focused_rows" = 18 ] && [ "$other_rows" = 18 ]; then
  echo "ok: the screen shows the caption of the focused window and of the other window"
else
  echo "FAIL: the screen shows the captions (rows: focused $focused_rows, other $other_rows)"
  failed=1
fi

# config.def.zon has the flat border of 2 pixels: kwm draws it around the
# window and its title bar, in the focus color above the caption.
above=$(python3 - "$work/shot.png" "$((focused_x + 10))" "$((focused_y - 1))" <<'PY'
import sys
from PIL import Image
pixel = Image.open(sys.argv[1]).convert("RGB").getpixel((int(sys.argv[2]), int(sys.argv[3])))
print("%02x%02x%02x" % pixel)
PY
)
if [ "$above" = f29718 ]; then
  echo "ok: the border goes around the title bar"
else
  echo "FAIL: the border goes around the title bar (pixel above the caption: $above)"
  failed=1
fi

# The close button is at the right end of the caption: 16x14 pixels, 2 pixels
# from the right end and from the top.
button_x=$((focused_x + width - 2 - 8))
button_y=$((focused_y + 2 + 7))
input move "$button_x" "$button_y"
input press
input release
expect_exit b "a click on the close button closes the window"
expect_state a "^maximized=1 .* height=$(field a height)$" \
  "alone again, the window fills the output, without title bar"
close a

# A client without xdg-decoration draws its own decorations.
open c
open d
expect_state d " decoration=none .* height=$tiled_height$" "a client without xdg-decoration gets no title bar"
close c
close d

# A floating window keeps its own size: the title bar goes above it.
open e
open f --decoration --fixed
expect_state f " decoration=server.* width=300 height=200$" "a floating window keeps its size with a title bar"
grim "$work/floating.png"
# The window can have the focus or not.
read -r _ _ unfocused_rows <<<"$(caption f "$work/floating.png" 808080)"
read -r _ _ focused_rows <<<"$(caption f "$work/floating.png" 000080 1084d0 300)"
floating_rows=$((unfocused_rows > focused_rows ? unfocused_rows : focused_rows))
if [ "$floating_rows" = 18 ]; then
  echo "ok: the screen shows the caption above the floating window"
else
  echo "FAIL: the screen shows the caption above the floating window (rows: $floating_rows)"
  failed=1
fi

# floating_caption <png>: the caption of the floating window, as "x y rows".
# A press focuses the window, thus its caption is the gradient after it.
floating_caption() {
  local focused unfocused
  focused=$(caption f "$1" 000080 1084d0 300)
  unfocused=$(caption f "$1" 808080)
  if [ "${focused##* }" = 18 ]; then echo "$focused"; else echo "$unfocused"; fi
}

# drag <from x> <from y> <to x> <to y>: press, move and release the button.
drag() {
  input move "$1" "$2"
  input press
  input move "$3" "$4"
  input release
}

# expect_caption_at <x> <y> <description>: the caption of the floating window
# starts at x, y.
expect_caption_at() {
  local at=""
  for _ in $(seq 25); do
    sleep 0.2
    grim "$work/drag.png"
    read -r cx cy _ <<<"$(floating_caption "$work/drag.png")"
    at="$cx $cy"
    if [ "$at" = "$1 $2" ]; then
      echo "ok: $3"
      return
    fi
  done
  echo "FAIL: $3 (the caption is at $at, not at $1 $2)"
  failed=1
}

# A drag on the title bar or on the border of a floating window moves it.
read -r fx fy _ <<<"$(floating_caption "$work/floating.png")"
drag $((fx + 40)) $((fy + 9)) $((fx + 140)) $((fy + 59))
expect_caption_at $((fx + 100)) $((fy + 50)) "a drag on the title bar moves the floating window"
# The flat border of 2 pixels is at the left of the caption.
fx=$((fx + 100)) fy=$((fy + 50))
drag $((fx - 1)) $((fy + 40)) $((fx - 61)) $((fy + 40))
expect_caption_at $((fx - 60)) "$fy" "a drag on the border moves the floating window"

if [ "$failed" -ne 0 ]; then
  echo "kwm-test-title-bar: the log of kwm:" >&2
  grep -E "title_bar|decoration|close" "$work/river.log" | tail -40 >&2 || true
  exit 1
fi
echo "kwm-test-title-bar: all tests passed"
