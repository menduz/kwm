const Self = @This();

pub const Type = enum {
    tile,
    grid,
    monocle,
    deck,
    scroller,
    centered_master,
    float,
};

pub const Tile = @import("layout/tile.zig");
pub const Grid = @import("layout/grid.zig");
pub const Monocle = @import("layout/monocle.zig");
pub const Deck = @import("layout/deck.zig");
pub const Scroller = @import("layout/scroller.zig");
pub const CenteredMaster = @import("layout/centered_master.zig");

const Context = @import("context.zig");
const ctx = Context.get();


tile: Tile,
grid: Grid,
monocle: Monocle,
deck: Deck,
scroller: Scroller,
centered_master: CenteredMaster,


/// The outer gap for `n` tiled windows. With smart_gaps, one window fills the
/// output and has no outer gap.
pub fn outer_gap(gap: i32, n: usize) i32 {
    return if (ctx.cfg.smart_gaps and n == 1) 0 else gap;
}
