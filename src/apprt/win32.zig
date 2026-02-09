// The required comptime API for any apprt.
const internal_os = @import("../os/main.zig");

pub const App = @import("win32/App.zig");
pub const Surface = @import("win32/Surface.zig");
pub const resourcesDir = internal_os.resourcesDir;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
