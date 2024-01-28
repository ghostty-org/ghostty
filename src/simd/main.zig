const std = @import("std");

const isa = @import("isa.zig");
pub usingnamespace isa;

pub fn main() !void {
    std.log.warn("ISA={}", .{isa.ISA.detect()});
}
