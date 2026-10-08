# Takes a screenshot of kwm: river with the headless backend of wlroots, kwm
# with config.def.zon, three terminals and three tray items. Run it with the
# environment of `kwm-screenshot` in screenshots.nix.
#
# Usage: kwm-screenshot <output directory> [<preset>]
#
# The presets, each one in <preset>.png:
#
#   kwm                     config.def.zon (the default)
#   title-bar-flat-<theme>  the flat border of 1 pixel: an outline, without
#                           the 3D edges
#   title-bar-raised-<theme>
#                           the raised border of 3 pixels, without the outline
#
# <theme> is dark (win-classic-dark) or light (win-classic-standard, the
# Windows Standard scheme). A title bar preset also has a floating terminal.
set -euo pipefail

out=${1:?usage: kwm-screenshot <output directory> [<preset>]}
preset=${2:-kwm}
mkdir -p "$out"

case $preset in
  kwm) border=default theme= ;;
  title-bar-flat-dark) border=flat theme=win-classic-dark ;;
  title-bar-flat-light) border=flat theme=win-classic-standard ;;
  title-bar-raised-dark) border=raised theme=win-classic-dark ;;
  title-bar-raised-light) border=raised theme=win-classic-standard ;;
  *)
    echo "kwm-screenshot: unknown preset: $preset" >&2
    exit 1
    ;;
esac

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

# No setting of a desktop session comes in, so a run outside the sandbox gives
# the same pixels. For example kwm reads GTK_THEME for the raised borders.
unset GTK_THEME GTK2_RC_FILES XCURSOR_THEME XCURSOR_SIZE XCURSOR_PATH \
  DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_DATA_HOME \
  XDG_STATE_HOME XDG_CACHE_HOME LD_PRELOAD LD_LIBRARY_PATH FAKETIME

# A home that holds no setting of the user. kwm reads config.def.zon.
export HOME=$work/home
export XDG_CONFIG_HOME=$work/config
export XDG_RUNTIME_DIR=$work/run
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# The border of the preset: lines of config.def.zon with other values.
if [ "$border" != default ]; then
  mkdir -p "$XDG_CONFIG_HOME/kwm"
  python3 - "$DEFAULT_CONFIG" "$border" >"$XDG_CONFIG_HOME/kwm/config.zon" <<'PY'
import sys

config = open(sys.argv[1]).read()
changes = {
    "flat": [("        .width = 2,\n", "        .width = 1,\n")],
    "raised": [
        ("        .width = 2,\n", "        .width = 3,\n"),
        ("        .style = .flat,\n", "        .style = .raised,\n"),
        ("            .outline = .all,\n", "            .outline = .none,\n"),
    ],
}[sys.argv[2]]
for old, new in changes:
    if config.count(old) != 1:
        sys.exit(f"kwm-screenshot: config.def.zon has not one line {old.strip()!r}")
    config = config.replace(old, new)
print(config, end="")
PY
fi

# The GTK theme of the title bars and of the raised border.
if [ -n "$theme" ]; then
  export GTK_THEME=$theme
  export XDG_DATA_DIRS=$XDG_DATA_DIRS:$THEME_DATA_DIRS
fi

export TZ=UTC
export LANG=C.UTF-8

# One output of 1280x720 pixels, without a GPU and without input devices.
export WLR_BACKENDS=headless
export WLR_RENDERER=pixman
export WLR_HEADLESS_OUTPUTS=1
export WLR_LIBINPUT_NO_DEVICES=1

# The session bus of the tray.
dbus-daemon --config-file="$DBUS_SESSION_CONF" --fork \
  --print-address=3 --print-pid=4 3>"$work/bus-address" 4>"$work/bus-pid"
pids+=("$(cat "$work/bus-pid")")
DBUS_SESSION_BUS_ADDRESS=$(cat "$work/bus-address")
export DBUS_SESSION_BUS_ADDRESS

# kwm gets a fixed clock, and fixed values for the CPU, the memory and the disk.
# The clock starts at 12:00:00 and runs, but the bar shows only the minutes.
# The other programs have the real clock.
cat >"$work/kwm" <<KWM
#!/bin/sh
export LD_PRELOAD="$FAKETIME_LIB:$PRELOAD_LIB"
export FAKETIME="@2026-10-04 12:00:00"
export FAKETIME_DONT_FAKE_MONOTONIC=1
exec kwm
KWM
chmod +x "$work/kwm"

river -no-xwayland -c "$work/kwm" >"$work/river.log" 2>&1 &
pids+=("$!")

# river makes the socket of the Wayland display.
for _ in $(seq 100); do
  socket=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'wayland-*' ! -name '*.lock' -print -quit)
  [ -n "$socket" ] && break
  sleep 0.1
done
if [ -z "${socket:-}" ]; then
  echo "kwm-screenshot: river did not start" >&2
  cat "$work/river.log" >&2
  exit 1
fi
WAYLAND_DISPLAY=$(basename "$socket")
export WAYLAND_DISPLAY
sleep 1

# Three tray items with the icons of Adwaita.
python3 "$TRAY_SCRIPT" audio-volume-high network-wireless-signal-excellent bluetooth-active &
pids+=("$!")

# Three terminals. Each one opens after the one before, so the tile layout
# always gives the same places.
cat >"$work/foot.ini" <<FOOT
font=DejaVu Sans Mono:size=9
pad=6x6
[cursor]
blink=no
FOOT
terminal() {
  foot --config="$work/foot.ini" "${@:2}" sh -c "$1; exec sleep infinity" &
  pids+=("$!")
  sleep 1
}
terminal 'kwm -h'
terminal 'printf "%s\n" "tags 1-9" "layouts: tile, grid, monocle, deck," "  scroller, centered master, float" "widgets: memory, clock, cpu, battery," "  disk, scripts, tray"'
terminal 'printf "%s\n" "Super+Return  terminal" "Super+Space   launcher" "Super+1..9    tags" "Super+J/K     focus" "Super+Q       close"'

# A floating terminal: config.def.zon makes a window with this title floating.
if [ "$preset" != kwm ]; then
  terminal 'printf "%s\n" "a floating window" "with a title bar"' --title=FloatingTerminal --window-size-chars=40x6
fi

# The widgets update each second, and the tray reads the icons.
sleep 3

grim "$out/$preset.png"
echo "kwm-screenshot: wrote $out/$preset.png"
