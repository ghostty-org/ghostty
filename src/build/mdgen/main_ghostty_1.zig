const std = @import("std");
const gen = @import("mdgen.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &stdout_writer.interface;
    try gen.substitute(alloc, @embedFile("ghostty_1_header.md"), writer);
    try gen.genActions(writer);
    try gen.genConfig(writer, true);
    try gen.substitute(alloc, @embedFile("ghostty_1_footer.md"), writer);
    try writer.flush();
}
