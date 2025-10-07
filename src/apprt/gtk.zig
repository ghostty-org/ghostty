const internal_os = @import("../os/main.zig");

// The required comptime API for any apprt.
pub const App = @import("gtk/App.zig");
pub const Surface = @import("gtk/Surface.zig");
pub const resourcesDir = @import("gtk/flatpak.zig").resourcesDir;

// The exported API, custom for the apprt.
pub const class = @import("gtk/class.zig");
pub const WeakRef = @import("gtk/weak_ref.zig").WeakRef;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("gtk/ext.zig");
}
