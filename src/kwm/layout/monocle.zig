const Self = @This();

const std = @import("std");
const log = std.log.scoped(.monocle);

const Context = @import("../context.zig");
const Output = @import("../output.zig");

const ctx = Context.get();


gap: i32,


pub fn arrange(self: *const Self, output: *Output) !void {
    log.debug("<{*}> arrange windows in output {*}", .{ self, output });

    const focus_top = ctx.focus_top_in(output, true) orelse return;
    // The window fills the output. With smart_gaps, it has no gap.
    const gap = if (ctx.cfg.smart_gaps) 0 else self.gap;
    const available_width = output.exclusive_width() - 2*gap;
    const available_height = output.exclusive_height() - 2*gap;
    {
        var it = ctx.windows.safeIterator(.forward);
        while (it.next()) |window| {
            if (!window.is_visible_in(output) or window.floating) continue;
            if (window != focus_top) window.hide();
            window.unbound_move(gap, gap);
            window.unbound_resize(available_width, available_height);
        }
    }
}
