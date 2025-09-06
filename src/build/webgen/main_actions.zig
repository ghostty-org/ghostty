const std = @import("std");
const help_strings = @import("help_strings");
const helpgen_actions = @import("../../input/helpgen_actions.zig");

pub fn main() !void {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    try helpgen_actions.generate(
        &stdout_writer.interface,
        .markdown,
        true,
        std.heap.page_allocator,
    );

    // Don't forget to flush!
    try stdout_writer.interface.flush();
}
