const std = @import("std");
const gen = @import("mdgen.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const alloc = gpa.allocator();

    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const writer = &stdout_writer.interface;
    try gen.substitute(alloc, @embedFile("ghostty_5_header.md"), writer);
    try gen.genConfig(writer, false);
    try gen.genKeybindActions(writer);
    try gen.substitute(alloc, @embedFile("ghostty_5_footer.md"), writer);
    try writer.flush();
}
