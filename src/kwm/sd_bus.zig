//! The part of sd-bus (libsystemd, or basu) that the tray uses. Refer to
//! sd-bus(3). The functions return a negative errno value when they fail.

pub const Bus = opaque {};
pub const Message = opaque {};
pub const Slot = opaque {};

pub const Error = extern struct {
    name: ?[*:0]const u8 = null,
    message: ?[*:0]const u8 = null,
    _need_free: c_int = 0,
};

/// Return a positive value when the handler took the message, 0 when it did
/// not, and a negative errno value when it failed.
pub const MessageHandler = *const fn (m: *Message, userdata: ?*anyopaque, ret_error: *Error) callconv(.c) c_int;

pub const NAME_REPLACE_EXISTING: u64 = 1 << 0;
pub const NAME_ALLOW_REPLACEMENT: u64 = 1 << 1;
pub const NAME_QUEUE: u64 = 1 << 2;

pub extern "c" fn sd_bus_open_user(ret: *?*Bus) c_int;
pub extern "c" fn sd_bus_flush_close_unref(bus: ?*Bus) ?*Bus;
pub extern "c" fn sd_bus_get_fd(bus: *Bus) c_int;
pub extern "c" fn sd_bus_get_events(bus: *Bus) c_int;
pub extern "c" fn sd_bus_get_timeout(bus: *Bus, ret: *u64) c_int;
pub extern "c" fn sd_bus_process(bus: *Bus, ret: ?*?*Message) c_int;
pub extern "c" fn sd_bus_flush(bus: *Bus) c_int;
pub extern "c" fn sd_bus_set_method_call_timeout(bus: *Bus, usec: u64) c_int;
pub extern "c" fn sd_bus_get_unique_name(bus: *Bus, unique: *?[*:0]const u8) c_int;

pub extern "c" fn sd_bus_slot_unref(slot: ?*Slot) ?*Slot;

pub extern "c" fn sd_bus_add_object(bus: *Bus, ret_slot: ?*?*Slot, path: [*:0]const u8, callback: MessageHandler, userdata: ?*anyopaque) c_int;
pub extern "c" fn sd_bus_request_name_async(bus: *Bus, ret_slot: ?*?*Slot, name: [*:0]const u8, flags: u64, callback: ?MessageHandler, userdata: ?*anyopaque) c_int;
pub extern "c" fn sd_bus_match_signal_async(
    bus: *Bus,
    ret: ?*?*Slot,
    sender: ?[*:0]const u8,
    path: ?[*:0]const u8,
    interface: ?[*:0]const u8,
    member: ?[*:0]const u8,
    match_callback: MessageHandler,
    install_callback: ?MessageHandler,
    userdata: ?*anyopaque,
) c_int;
pub extern "c" fn sd_bus_call_method_async(
    bus: *Bus,
    ret_slot: ?*?*Slot,
    destination: [*:0]const u8,
    path: [*:0]const u8,
    interface: [*:0]const u8,
    member: [*:0]const u8,
    callback: ?MessageHandler,
    userdata: ?*anyopaque,
    types: ?[*:0]const u8,
    ...
) c_int;
pub extern "c" fn sd_bus_emit_signal(bus: *Bus, path: [*:0]const u8, interface: [*:0]const u8, member: [*:0]const u8, types: ?[*:0]const u8, ...) c_int;

pub extern "c" fn sd_bus_reply_method_return(call: *Message, types: ?[*:0]const u8, ...) c_int;
pub extern "c" fn sd_bus_reply_method_errorf(call: *Message, name: [*:0]const u8, format: [*:0]const u8, ...) c_int;
pub extern "c" fn sd_bus_message_new_method_return(call: *Message, ret: *?*Message) c_int;
pub extern "c" fn sd_bus_send(bus: ?*Bus, m: *Message, ret_cookie: ?*u64) c_int;
pub extern "c" fn sd_bus_message_unref(m: ?*Message) ?*Message;

pub extern "c" fn sd_bus_message_get_sender(m: *Message) ?[*:0]const u8;
pub extern "c" fn sd_bus_message_get_member(m: *Message) ?[*:0]const u8;
pub extern "c" fn sd_bus_message_get_path(m: *Message) ?[*:0]const u8;
pub extern "c" fn sd_bus_message_get_error(m: *Message) ?*const Error;
pub extern "c" fn sd_bus_message_is_method_call(m: *Message, interface: ?[*:0]const u8, member: ?[*:0]const u8) c_int;

pub extern "c" fn sd_bus_message_append(m: *Message, types: [*:0]const u8, ...) c_int;
pub extern "c" fn sd_bus_message_open_container(m: *Message, @"type": u8, contents: [*:0]const u8) c_int;
pub extern "c" fn sd_bus_message_close_container(m: *Message) c_int;

pub extern "c" fn sd_bus_message_read(m: *Message, types: [*:0]const u8, ...) c_int;
pub extern "c" fn sd_bus_message_read_basic(m: *Message, @"type": u8, ret: *anyopaque) c_int;
pub extern "c" fn sd_bus_message_read_array(m: *Message, @"type": u8, ret_ptr: *?*const anyopaque, ret_size: *usize) c_int;
pub extern "c" fn sd_bus_message_skip(m: *Message, types: ?[*:0]const u8) c_int;
pub extern "c" fn sd_bus_message_enter_container(m: *Message, @"type": u8, contents: ?[*:0]const u8) c_int;
pub extern "c" fn sd_bus_message_exit_container(m: *Message) c_int;
pub extern "c" fn sd_bus_message_peek_type(m: *Message, ret_type: ?*u8, ret_contents: ?*?[*:0]const u8) c_int;


/// Return `rc` when it is not negative. Else log the call and return an error.
pub fn check(rc: c_int, comptime what: []const u8) !c_int {
    if (rc >= 0) return rc;
    @import("std").log.scoped(.sd_bus).warn("{s} failed: errno {}", .{ what, -rc });
    return error.SdBus;
}
