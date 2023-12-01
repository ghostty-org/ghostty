pub const foundation = @import("foundation.zig");
pub const graphics = @import("graphics.zig");
pub const os = @import("os.zig");
pub const text = @import("text.zig");
pub const video = @import("video.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
