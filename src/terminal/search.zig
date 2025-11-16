//! Search functionality for the terminal.

pub const Active = @import("search/active.zig").ActiveSearch;
pub const PageList = @import("search/pagelist.zig").PageListSearch;
pub const Screen = @import("search/screen.zig").ScreenSearch;
pub const Viewport = @import("search/viewport.zig").ViewportSearch;
pub const Thread = @import("search/Thread.zig");

test {
    @import("std").testing.refAllDecls(@This());

    // Non-public APIs
    _ = @import("search/sliding_window.zig");
}
