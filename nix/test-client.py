# A Wayland client for the tests of kwm. It shows one xdg-shell window and
# writes the last state that the compositor gives it to a file:
#
#     maximized=1 activated=1 keyboard=1 can_maximize=1 tiled=1 width=1280 height=696
#
# activated is the xdg_toplevel state: river gives it to the window that river
# knows as focused. keyboard is 1 between wl_keyboard.enter and
# wl_keyboard.leave. The seat has a keyboard only with test-input.py. During a
# drag, wlroots drops the keyboard enter, thus the two values can differ.
# can_maximize is the maximize capability of xdg_toplevel.wm_capabilities
# (without the event, a window has all capabilities). tiled is 1 when the
# window has a tiled state: kwm gives it to a window that is not floating.
#
# Usage: test-client.py <name> <state file> [--maximize] [--fixed] [--drag]
#
#   --maximize  ask to be maximized before the first commit. Chromium does this
#               when the last active window was maximized.
#   --fixed     set the same minimum and maximum size, 300x200. kwm makes such
#               a window floating.
#   --drag      start a drag at a press of the pointer button on the window,
#               and stop when the drag ends. Brave does this when a tab goes
#               into another window: the window of the tab closes.
#
# SIGUSR1 asks to be maximized, SIGUSR2 asks to be unmaximized. The client
# stops at SIGTERM.
import mmap
import os
import select
import signal
import sys

from pywayland.client import Display
from pywayland.protocol.wayland import WlCompositor, WlDataDeviceManager, WlSeat, WlShm
from pywayland.protocol.xdg_shell import XdgToplevel, XdgWmBase

name, state_file = sys.argv[1], sys.argv[2]
flags = set(sys.argv[3:])

display = Display()
display.connect()

globals_ = {}


def on_global(registry, id_, interface, version):
    if interface == "wl_compositor":
        globals_["compositor"] = registry.bind(id_, WlCompositor, 4)
    elif interface == "wl_shm":
        globals_["shm"] = registry.bind(id_, WlShm, 1)
    elif interface == "xdg_wm_base":
        # wm_capabilities comes with version 5.
        globals_["wm_base"] = registry.bind(id_, XdgWmBase, min(version, 5))
    elif interface == "wl_data_device_manager":
        globals_["data_device_manager"] = registry.bind(id_, WlDataDeviceManager, 3)
    elif interface == "wl_seat" and "seat" not in globals_:
        # Set the listener before the capabilities event comes.
        globals_["seat"] = registry.bind(id_, WlSeat, 5)
        globals_["seat"].dispatcher["capabilities"] = on_capabilities


# The objects of the seat. A Python reference keeps each one.
seat_objects = {}


def on_capabilities(seat, capabilities):
    if capabilities & WlSeat.capability.keyboard.value and "keyboard" not in seat_objects:
        keyboard = seat_objects["keyboard"] = seat.get_keyboard()
        keyboard.dispatcher["keymap"] = lambda keyboard, format_, fd, size: os.close(fd)
        keyboard.dispatcher["enter"] = lambda keyboard, serial, focus, keys: set_keyboard(True)
        keyboard.dispatcher["leave"] = lambda keyboard, serial, focus: set_keyboard(False)
    if "--drag" in flags and capabilities & WlSeat.capability.pointer.value and "pointer" not in seat_objects:
        pointer = seat_objects["pointer"] = seat.get_pointer()
        pointer.dispatcher["button"] = on_button


def set_keyboard(value):
    # The client has one surface, thus the event is for the window.
    current["keyboard"] = value
    write_state()


def on_button(pointer, serial, time, button, state):
    if state != 1 or "source" in seat_objects:
        return
    manager = globals_["data_device_manager"]
    source = seat_objects["source"] = manager.create_data_source()
    source.offer("text/plain")
    source.set_actions(WlDataDeviceManager.dnd_action.copy.value)
    # The drag ends without a target (cancelled) or after a drop: the window
    # closes.
    source.dispatcher["cancelled"] = lambda source: closed.append(True)
    source.dispatcher["dnd_finished"] = lambda source: closed.append(True)
    device = seat_objects["data_device"] = manager.get_data_device(globals_["seat"])
    device.start_drag(source, surface, None, serial)


registry = display.get_registry()
registry.dispatcher["global"] = on_global

display.roundtrip()

wm_base = globals_["wm_base"]
wm_base.dispatcher["ping"] = lambda base, serial: base.pong(serial)

surface = globals_["compositor"].create_surface()
xdg_surface = wm_base.get_xdg_surface(surface)
toplevel = xdg_surface.get_toplevel()
toplevel.set_app_id(name)
toplevel.set_title(name)
if "--fixed" in flags:
    toplevel.set_min_size(300, 200)
    toplevel.set_max_size(300, 200)
if "--maximize" in flags:
    toplevel.set_maximized()

# The state of the last toplevel configure. xdg_surface.configure applies it.
pending = {"width": 0, "height": 0, "maximized": False, "activated": False, "tiled": False, "can_maximize": True}
# The state that the window has now.
current = {
    "width": 0,
    "height": 0,
    "maximized": False,
    "activated": False,
    "keyboard": False,
    "tiled": False,
    "can_maximize": True,
}
buffers = []


def write_state():
    # Before the first configure, the window has no state.
    if current["width"] == 0:
        return
    # Write a new file and rename it, thus a reader never sees half a line.
    tmp = state_file + ".tmp"
    with open(tmp, "w") as f:
        f.write(
            f"maximized={int(current['maximized'])} activated={int(current['activated'])} "
            f"keyboard={int(current['keyboard'])} can_maximize={int(current['can_maximize'])} "
            f"tiled={int(current['tiled'])} width={current['width']} height={current['height']}\n"
        )
    os.rename(tmp, state_file)


def on_toplevel_configure(toplevel, width, height, states):
    pending["width"] = width
    pending["height"] = height
    # The states are an array of uint32 values in the byte order of the host.
    values = [int.from_bytes(states[i : i + 4], sys.byteorder) for i in range(0, len(states), 4)]
    pending["maximized"] = XdgToplevel.state.maximized.value in values
    pending["activated"] = XdgToplevel.state.activated.value in values
    tiled_states = (
        XdgToplevel.state.tiled_left,
        XdgToplevel.state.tiled_right,
        XdgToplevel.state.tiled_top,
        XdgToplevel.state.tiled_bottom,
    )
    pending["tiled"] = any(state.value in values for state in tiled_states)


def on_wm_capabilities(toplevel, capabilities):
    # The capabilities stay until the next wm_capabilities event.
    values = [int.from_bytes(capabilities[i : i + 4], sys.byteorder) for i in range(0, len(capabilities), 4)]
    pending["can_maximize"] = XdgToplevel.wm_capabilities.maximize.value in values


def make_buffer(width, height):
    stride = width * 4
    size = stride * height
    fd = os.memfd_create("kwm-test-client")
    os.ftruncate(fd, size)
    data = mmap.mmap(fd, size)
    data.write(b"\x80\x80\x80\xff" * (width * height))
    pool = globals_["shm"].create_pool(fd, size)
    buffer = pool.create_buffer(0, width, height, stride, WlShm.format.argb8888.value)
    pool.destroy()
    os.close(fd)
    # Keep the memory until the client stops.
    buffers.append((buffer, data))
    return buffer


def on_surface_configure(xdg_surface, serial):
    xdg_surface.ack_configure(serial)
    width = pending["width"] or 300
    height = pending["height"] or 200
    surface.attach(make_buffer(width, height), 0, 0)
    surface.damage(0, 0, width, height)
    surface.commit()
    current.update(pending, width=width, height=height)
    write_state()


toplevel.dispatcher["configure"] = on_toplevel_configure
toplevel.dispatcher["wm_capabilities"] = on_wm_capabilities
# sys.exit in a callback of pywayland does not stop the client. The main loop
# stops after the dispatch.
closed = []
toplevel.dispatcher["close"] = lambda toplevel: closed.append(True)
xdg_surface.dispatcher["configure"] = on_surface_configure
surface.commit()

requests = []
signal.signal(signal.SIGUSR1, lambda *_: requests.append("maximize"))
signal.signal(signal.SIGUSR2, lambda *_: requests.append("unmaximize"))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

fd = display.get_fd()
while True:
    while requests:
        if requests.pop(0) == "maximize":
            toplevel.set_maximized()
        else:
            toplevel.unset_maximized()
    display.flush()
    try:
        readable, _, _ = select.select([fd], [], [], 0.1)
    except InterruptedError:
        continue
    if readable and display.dispatch(block=True) == -1:
        sys.exit(1)
    if closed:
        # The finalizers of pywayland can crash after a drag. Stop without
        # them.
        display.flush()
        os._exit(0)
