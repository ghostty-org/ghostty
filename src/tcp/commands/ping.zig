const std = @import("std");
const build_config = @import("../../build_config.zig");

pub fn ping() []const u8 {
    return std.fmt.comptimePrint("PONG v={}\n", .{build_config.version});
}
