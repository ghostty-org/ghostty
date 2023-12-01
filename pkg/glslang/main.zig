pub const c = @import("c.zig");
pub const testing = @import("test.zig");
pub usingnamespace @import("init.zig");
pub usingnamespace @import("program.zig");
pub usingnamespace @import("shader.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
