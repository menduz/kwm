# Tests that kwm follows the GTK theme of the settings portal, as
# toggle-theme of nix-config changes it: kwm reads the theme at its start
# (ReadOne), and reads the new colors at SettingChanged. test-portal.py is
# the portal. Run it with the environment of `kwm-test-theme` in tests.nix.
# Refer to src/kwm/settings_portal.zig.
#
# Usage: kwm-test-theme
set -euo pipefail

TEST_NAME=theme

# Two GTK themes with only an xfwm4/themerc: the caption of the focused
# window is #112233 in the first one and #445566 in the second one.
themes=$(mktemp -d)
for theme in kwm-test-a:112233 kwm-test-b:445566; do
  mkdir -p "$themes/themes/${theme%%:*}/xfwm4"
  printf 'active_color_1 = #%s\nbutton_layout=O|C\n' "${theme#*:}" \
    >"$themes/themes/${theme%%:*}/xfwm4/themerc"
done
export XDG_DATA_DIRS=$themes

# The portal is on the bus before kwm starts.
before_river() {
  # Other clients ask the portal for interfaces that it does not have. Its
  # errors go to a file.
  python3 "$TEST_PORTAL" "$work/portal.ready" kwm-test-a kwm-test-b 2>"$work/portal.log" &
  portal=$!
  pids+=("$portal")
  for _ in $(seq 50); do
    [ -s "$work/portal.ready" ] && return
    sleep 0.1
  done
  echo "kwm-test-theme: test-portal.py did not start" >&2
  exit 1
}

# shellcheck source=test-lib.sh
source "$TEST_LIB"

# caption_rows <png> <rrggbb>: the rows with at least 50 pixels of the color.
caption_rows() {
  python3 - "$1" "$2" <<'PY'
import sys
from PIL import Image
image = Image.open(sys.argv[1]).convert("RGB")
want = tuple(int(sys.argv[2][i:i + 2], 16) for i in (0, 2, 4))
pixels = image.load()
width, height = image.size
print(sum(1 for y in range(height) if sum(1 for x in range(width) if pixels[x, y] == want) >= 50))
PY
}

# expect_caption <rrggbb> <description>: the screen shows the caption of the
# focused window in the color.
expect_caption() {
  local rows=0
  for _ in $(seq 25); do
    sleep 0.2
    grim "$work/shot.png"
    rows=$(caption_rows "$work/shot.png" "$1")
    if [ "$rows" = 18 ]; then
      echo "ok: $2"
      return
    fi
  done
  echo "FAIL: $2 (rows of #$1: $rows)"
  failed=1
}

# Two windows with server side decorations: both have a title bar.
open a --decoration
open b --decoration
expect_state b " decoration=server " "the window has server side decorations"

expect_caption 112233 "at the start, kwm reads the GTK theme of the portal"
kill -USR1 "$portal"
expect_caption 445566 "at SettingChanged, kwm reads the colors of the new GTK theme"

rm -rf "$themes"
if [ "$failed" -ne 0 ]; then
  echo "kwm-test-theme: the log of kwm:" >&2
  grep -E "theme|portal" "$work/river.log" | tail -20 >&2 || true
  exit 1
fi
echo "kwm-test-theme: all tests passed"
