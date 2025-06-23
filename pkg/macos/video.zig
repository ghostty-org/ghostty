const display_link = @import("video/display_link.zig");
const pixel_format = @import("video/pixel_format.zig");

pub const c = @import("video/c.zig").c;
pub const DisplayLink = display_link.DisplayLink;
pub const PixelFormat = pixel_format.PixelFormat;

test {
    @import("std").testing.refAllDecls(@This());
}
