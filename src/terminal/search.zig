//! Search functionality for the terminal.

pub const options = @import("terminal_options");

pub const Active = @import("search/active.zig").ActiveSearch;
pub const PageList = @import("search/pagelist.zig").PageListSearch;
pub const Screen = @import("search/screen.zig").ScreenSearch;
pub const Viewport = @import("search/viewport.zig").ViewportSearch;

// The search thread is not available in libghostty due to the xev dep
// for now.
pub const Thread = switch (options.artifact) {
    .ghostty => @import("search/Thread.zig"),
    .lib => void,
};

test {
    @import("std").testing.refAllDecls(@This());

    // Non-public APIs
    _ = @import("search/sliding_window.zig");
}
