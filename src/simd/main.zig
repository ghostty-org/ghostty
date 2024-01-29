const std = @import("std");

pub const isa = @import("isa.zig");
const index_of = @import("index_of.zig");
pub usingnamespace index_of;

// const utf8 = @import("utf8.zig");
// pub usingnamespace utf8;

pub fn main() !void {
    //std.log.warn("ISA={}", .{isa.ISA.detect()});
    const input = "1234567\x1b1234567\x1b";
    //const input = "1234567812345678";
    std.log.warn("result={any}", .{index_of.indexOf(input, 0x1B)});
}

test {
    @import("std").testing.refAllDecls(@This());
}
