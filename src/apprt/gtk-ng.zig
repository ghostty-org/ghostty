const internal_os = @import("../os/main.zig");

// The required comptime API for any apprt.
pub const App = @import("gtk-ng/App.zig");
pub const Surface = @import("gtk-ng/Surface.zig");
pub const resourcesDir = internal_os.resourcesDir;

// The exported API, custom for the apprt.
pub const class = @import("gtk-ng/class.zig");
pub const WeakRef = @import("gtk-ng/weak_ref.zig").WeakRef;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("gtk-ng/ext.zig");
}
