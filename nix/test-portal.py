# A settings portal for the tests of kwm: org.freedesktop.portal.Settings
# on the session bus, with one setting, org.gnome.desktop.interface
# gtk-theme. toggle-theme of nix-config changes that setting.
#
# Usage: test-portal.py <ready file> <theme> <next theme>
#
# ReadOne gives <theme>. At SIGUSR1, the setting becomes <next theme> and the
# portal sends SettingChanged. The portal writes the ready file when it has
# its name on the bus.
import asyncio
import signal
import sys

from dbus_next import Variant
from dbus_next.aio import MessageBus
from dbus_next.errors import DBusError
from dbus_next.service import ServiceInterface, method
from dbus_next.service import signal as dbus_signal

ready_file, theme, next_theme = sys.argv[1:4]
NAMESPACE = "org.gnome.desktop.interface"
KEY = "gtk-theme"


class Settings(ServiceInterface):
    def __init__(self):
        super().__init__("org.freedesktop.portal.Settings")
        self.theme = theme

    @method()
    def ReadOne(self, namespace: "s", key: "s") -> "v":  # noqa: F821
        if (namespace, key) != (NAMESPACE, KEY):
            raise DBusError("org.freedesktop.portal.Error.NotFound", "no such setting")
        return Variant("s", self.theme)

    @dbus_signal()
    def SettingChanged(self) -> "ssv":  # noqa: F821
        return [NAMESPACE, KEY, Variant("s", self.theme)]

    def change(self):
        self.theme = next_theme
        self.SettingChanged()


async def main():
    bus = await MessageBus().connect()
    settings = Settings()
    bus.export("/org/freedesktop/portal/desktop", settings)
    await bus.request_name("org.freedesktop.portal.Desktop")
    asyncio.get_running_loop().add_signal_handler(signal.SIGUSR1, settings.change)
    with open(ready_file, "w") as f:
        f.write("ready\n")
    await bus.wait_for_disconnect()


asyncio.run(main())
