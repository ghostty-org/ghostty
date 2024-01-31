const std = @import("std");

pub const isa = @import("isa.zig");
pub const utf8_count = @import("utf8_count.zig");
pub const utf8_decode = @import("utf8_decode.zig");
pub const utf8_validate = @import("utf8_validate.zig");
pub const index_of = @import("index_of.zig");

// TODO: temporary, only for zig build simd to inspect disasm easily
// pub fn main() !void {
//     //std.log.warn("ISA={}", .{isa.ISA.detect()});
//     const input = "1234567\x1b1234567\x1b";
//     //const input = "1234567812345678";
//     std.log.warn("result={any}", .{index_of.indexOf(input, 0x1B)});
//     std.log.warn("result={any}", .{utf8.utf8Validate(input)});
// }

test {
    @import("std").testing.refAllDecls(@This());
}
