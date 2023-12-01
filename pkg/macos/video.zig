pub const c = @import("video/c.zig");
pub usingnamespace @import("video/display_link.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
