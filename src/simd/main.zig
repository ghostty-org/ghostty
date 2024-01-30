const std = @import("std");

pub const isa = @import("isa.zig");
pub const utf8 = @import("utf8.zig");
const index_of = @import("index_of.zig");
pub usingnamespace index_of;

pub fn main() !void {
    //std.log.warn("ISA={}", .{isa.ISA.detect()});
    const input = "1234567\x1b1234567\x1b";
    //const input = "1234567812345678";
    std.log.warn("result={any}", .{index_of.indexOf(input, 0x1B)});
    std.log.warn("result={any}", .{utf8.utf8Validate(input)});
}

test {
    @import("std").testing.refAllDecls(@This());
}
