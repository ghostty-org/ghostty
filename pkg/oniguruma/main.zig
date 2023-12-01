pub usingnamespace @import("init.zig");
pub usingnamespace @import("errors.zig");
pub usingnamespace @import("regex.zig");
pub usingnamespace @import("region.zig");
pub usingnamespace @import("types.zig");
pub const c = @import("c.zig");
pub const testing = @import("testing.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
