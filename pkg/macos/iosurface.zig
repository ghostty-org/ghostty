const iosurface = @import("iosurface/iosurface.zig");

pub const c = @import("iosurface/c.zig").c;
pub const IOSurface = iosurface.IOSurface;

test {
    @import("std").testing.refAllDecls(@This());
}
