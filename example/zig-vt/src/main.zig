const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

pub fn main(init: std.process.Init) !void {
    // Initialize a terminal.
    var t: ghostty_vt.Terminal = try .init(init.gpa, .{
        .cols = 6,
        .rows = 40,
    });
    defer t.deinit(init.gpa);

    // Write some text. It'll wrap because this is too long for our
    // columns size above (6).
    try t.printString("Hello, World!");

    // Get the plain string view of the terminal screen.
    const str = try t.plainString(alloc);
    defer alloc.free(str);
    std.debug.print("{s}\n", .{str});
}
