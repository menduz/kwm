"""Tray items for the screenshots of kwm.

Waits for the StatusNotifierWatcher of kwm, then registers one item for each
icon name in the arguments, in that order. The icons come from the icon theme
of the tray. The items stay until the script stops.
"""

import asyncio
import sys

from dbus_next import Message, PropertyAccess
from dbus_next.aio import MessageBus
from dbus_next.service import ServiceInterface, dbus_property

WATCHER = "org.kde.StatusNotifierWatcher"


class Item(ServiceInterface):
    def __init__(self, icon):
        super().__init__("org.kde.StatusNotifierItem")
        self.icon = icon

    @dbus_property(access=PropertyAccess.READ)
    def Id(self) -> "s":
        return self.icon

    @dbus_property(access=PropertyAccess.READ)
    def Status(self) -> "s":
        return "Active"

    @dbus_property(access=PropertyAccess.READ)
    def IconName(self) -> "s":
        return self.icon


async def name_has_owner(bus, name):
    reply = await bus.call(
        Message(
            destination="org.freedesktop.DBus",
            path="/org/freedesktop/DBus",
            interface="org.freedesktop.DBus",
            member="NameHasOwner",
            signature="s",
            body=[name],
        )
    )
    return reply.body[0]


async def main():
    bus = await MessageBus().connect()
    while not await name_has_owner(bus, WATCHER):
        await asyncio.sleep(0.1)
    # One connection for each item. The watcher keeps the order of the
    # registrations.
    for icon in sys.argv[1:]:
        bus = await MessageBus().connect()
        bus.export("/StatusNotifierItem", Item(icon))
        await bus.call(
            Message(
                destination=WATCHER,
                path="/StatusNotifierWatcher",
                interface=WATCHER,
                member="RegisterStatusNotifierItem",
                signature="s",
                body=[bus.unique_name],
            )
        )
    await asyncio.Event().wait()


asyncio.run(main())
