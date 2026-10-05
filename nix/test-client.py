# A Wayland client for the tests of kwm. It shows one xdg-shell window and
# writes the last state that the compositor gives it to a file:
#
#     maximized=1 width=1280 height=696
#
# Usage: test-client.py <name> <state file> [--maximize] [--fixed]
#
#   --maximize  ask to be maximized before the first commit. Chromium does this
#               when the last active window was maximized.
#   --fixed     set the same minimum and maximum size, 300x200. kwm makes such
#               a window floating.
#
# SIGUSR1 asks to be maximized, SIGUSR2 asks to be unmaximized. The client
# stops at SIGTERM.
import mmap
import os
import select
import signal
import sys

from pywayland.client import Display
from pywayland.protocol.wayland import WlCompositor, WlShm
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
        globals_["wm_base"] = registry.bind(id_, XdgWmBase, 1)


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
pending = {"width": 0, "height": 0, "maximized": False}
buffers = []


def on_toplevel_configure(toplevel, width, height, states):
    pending["width"] = width
    pending["height"] = height
    # The states are an array of uint32 values in the byte order of the host.
    values = [int.from_bytes(states[i : i + 4], sys.byteorder) for i in range(0, len(states), 4)]
    pending["maximized"] = XdgToplevel.state.maximized.value in values


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
    # Write a new file and rename it, thus a reader never sees half a line.
    tmp = state_file + ".tmp"
    with open(tmp, "w") as f:
        f.write(f"maximized={int(pending['maximized'])} width={width} height={height}\n")
    os.rename(tmp, state_file)


toplevel.dispatcher["configure"] = on_toplevel_configure
toplevel.dispatcher["close"] = lambda toplevel: sys.exit(0)
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
