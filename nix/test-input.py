# A virtual keyboard and a virtual pointer for the tests of kwm. A client sees
# wl_keyboard.enter only when the seat has a keyboard, and a drag needs a
# pointer button that stays pressed. wlrctl can only click.
#
# Usage: test-input.py <command fifo> <done file> <output width> <output height>
#
# The helper reads one command per line from the fifo:
#
#     move X Y   move the pointer to X,Y of the output
#     press      press the left button
#     release    release the left button
#
# After each command and a roundtrip, it writes the number of done commands to
# the done file. The protocol modules come from tests.nix (kwm_test_protocols).
import os
import sys
import time

from pywayland.client import Display

from kwm_test_protocols.virtual_keyboard_unstable_v1 import ZwpVirtualKeyboardManagerV1
from kwm_test_protocols.wayland import WlSeat
from kwm_test_protocols.wlr_virtual_pointer_unstable_v1 import ZwlrVirtualPointerManagerV1

fifo, done_file = sys.argv[1], sys.argv[2]
width, height = int(sys.argv[3]), int(sys.argv[4])

BTN_LEFT = 0x110
KEYMAP = b"""xkb_keymap {
  xkb_keycodes { include "evdev+aliases(qwerty)" };
  xkb_types { include "complete" };
  xkb_compat { include "complete" };
  xkb_symbols { include "pc+us+inet(evdev)" };
};
\0"""

display = Display()
display.connect()

globals_ = {}


def on_global(registry, id_, interface, version):
    if interface == "wl_seat" and "seat" not in globals_:
        globals_["seat"] = registry.bind(id_, WlSeat, 1)
    elif interface == "zwlr_virtual_pointer_manager_v1":
        globals_["pointer"] = registry.bind(id_, ZwlrVirtualPointerManagerV1, 1)
    elif interface == "zwp_virtual_keyboard_manager_v1":
        globals_["keyboard"] = registry.bind(id_, ZwpVirtualKeyboardManagerV1, 1)


registry = display.get_registry()
registry.dispatcher["global"] = on_global
display.roundtrip()

keyboard = globals_["keyboard"].create_virtual_keyboard(globals_["seat"])
fd = os.memfd_create("kwm-test-keymap")
os.write(fd, KEYMAP)
# WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1
keyboard.keymap(1, fd, len(KEYMAP))
os.close(fd)

pointer = globals_["pointer"].create_virtual_pointer(globals_["seat"])


def now():
    return int(time.monotonic() * 1000) & 0xFFFFFFFF


done = 0


def write_done():
    tmp = done_file + ".tmp"
    with open(tmp, "w") as f:
        f.write(f"{done}\n")
    os.rename(tmp, done_file)


display.roundtrip()
write_done()

with open(fifo) as commands:
    for line in commands:
        words = line.split()
        if not words:
            continue
        if words[0] == "move":
            pointer.motion_absolute(now(), int(words[1]), int(words[2]), width, height)
        elif words[0] in ("press", "release"):
            pointer.button(now(), BTN_LEFT, 1 if words[0] == "press" else 0)
        else:
            sys.exit(f"test-input.py: unknown command: {line.strip()}")
        pointer.frame()
        display.roundtrip()
        done += 1
        write_done()
