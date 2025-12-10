const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Create a terminal
    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 150, .rows = 80 });
    defer t.deinit(alloc);

    // Create a read-only VT stream for parsing terminal sequences
    var stream = t.vtStream();
    defer stream.deinit();

    // Read from stdin
    const stdin = std.fs.File.stdin();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try stdin.readAll(&buf);
        if (n == 0) break;

        // Replace \n with \r\n
        for (buf[0..n]) |byte| {
            if (byte == '\n') try stream.next('\r');
            try stream.next(byte);
        }
    }

    // Use TerminalFormatter to emit HTML
    const formatter: ghostty_vt.formatter.TerminalFormatter = .init(&t, .{
        .emit = .html,
        .palette = &t.colors.palette.current,
    });

    // Write to stdout
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_writer.interface;
    try stdout.print("{f}", .{formatter});
    try stdout.flush();
}
