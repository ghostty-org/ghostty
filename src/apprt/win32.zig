//! The native Windows application runtime.
//!
//! It owns the windows and the message loop. The OpenGL renderer draws each
//! terminal off-screen and hands over finished frames as pixels in memory,
//! which the surface copies into its window. The shell runs through ConPTY,
//! which the core already knows how to drive.
const internal_os = @import("../os/main.zig");

// The required comptime API for any apprt.
pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const resourcesDir = internal_os.resourcesDir;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("win32/key.zig");
}
