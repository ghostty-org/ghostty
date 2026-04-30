const std = @import("std");
const helpgen_actions = @import("../../input/helpgen_actions.zig");

pub fn main() !void {
    var buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &stdout_writer.interface;
    try helpgen_actions.generate(stdout, .markdown, true, std.heap.page_allocator);
}
