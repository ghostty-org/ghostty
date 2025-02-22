const std = @import("std");
const help_strings = @import("help_strings");
const helpgen_actions = @import("../../input/helpgen_actions.zig");

pub fn main() !void {
    const output = std.io.getStdOut().writer();
    try helpgen_actions.generate(output, .markdown, true, std.heap.page_allocator);
}
