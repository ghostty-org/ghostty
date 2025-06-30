//! Application runtime that uses GTK4.

pub const App = @import("gtk/App.zig");
pub const Surface = @import("gtk/Surface.zig");
pub const resourcesDir = @import("gtk/flatpak.zig").resourcesDir;

test {
    @import("std").testing.refAllDecls(@This());

    _ = @import("gtk/inspector.zig");
    _ = @import("gtk/key.zig");
}
