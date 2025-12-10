const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    // Create a read-only VT stream for parsing terminal sequences
    var stream = t.vtStream();
    defer stream.deinit();

    // Basic text with newline
    try stream.nextSlice("Hello, World!\r\n");

    // ANSI color codes: ESC[1;32m = bold green, ESC[0m = reset
    try stream.nextSlice("\x1b[1;32mGreen Text\x1b[0m\r\n");

    // Cursor positioning: ESC[1;1H = move to row 1, column 1
    try stream.nextSlice("\x1b[1;1HTop-left corner\r\n");

    // Cursor movement: ESC[5B = move down 5 lines
    try stream.nextSlice("\x1b[5B");
    try stream.nextSlice("Moved down!\r\n");

    // Erase line: ESC[2K = clear entire line
    try stream.nextSlice("\x1b[2K");
    try stream.nextSlice("New content\r\n");

    // Multiple lines
    try stream.nextSlice("Line A\r\nLine B\r\nLine C\r\n");

    // Get the final terminal state as a plain string
    const str = try t.plainString(alloc);
    defer alloc.free(str);
    std.debug.print("{s}\n", .{str});
}
