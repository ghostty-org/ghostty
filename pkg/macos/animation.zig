pub const c = @import("animation/c.zig").c;

/// https://developer.apple.com/documentation/quartzcore/calayer/contents_gravity_values?language=objc
pub extern "c" const kCAGravityTopLeft: *anyopaque;
pub extern "c" const kCAGravityBottomLeft: *anyopaque;
pub extern "c" const kCAGravityCenter: *anyopaque;

test {
    @import("std").testing.refAllDecls(@This());
}
