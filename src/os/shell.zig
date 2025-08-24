const std = @import("std");
const testing = std.testing;
const Writer = std.Io.Writer;

/// Writer that escapes characters that shells treat specially to reduce the
/// risk of injection attacks or other such weirdness. Specifically excludes
/// linefeeds so that they can be used to delineate lists of file paths.
///
/// T should be a Zig type that follows the `std.Io.Writer` interface.
pub const ShellEscapeWriter = struct {
    writer: Writer,
    child: *Writer,

    pub fn init(child: *Writer) ShellEscapeWriter {
        return .{
            .writer = .{
                // TODO: Actually use a buffer here
                .buffer = &.{},
                .vtable = &.{ .drain = ShellEscapeWriter.drain },
            },
            .child = child,
        };
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *ShellEscapeWriter = @fieldParentPtr("writer", w);

        // TODO: This is a very naive implementation and does not really make
        // full use of the post-Writergate API. However, since we know that
        // this is going into an Allocating writer anyways, we can be a bit
        // less strict here.

        var count: usize = 0;
        for (data[0 .. data.len - 1]) |chunk| try self.writeEscaped(chunk, &count);

        for (0..splat) |_| try self.writeEscaped(data[data.len], &count);
        return count;
    }

    fn writeEscaped(
        self: *ShellEscapeWriter,
        s: []const u8,
        count: *usize,
    ) Writer.Error!void {
        for (s) |byte| {
            const buf = switch (byte) {
                '\\',
                '"',
                '\'',
                '$',
                '`',
                '*',
                '?',
                ' ',
                '|',
                '(',
                ')',
                => &[_]u8{ '\\', byte },
                else => &[_]u8{byte},
            };
            try self.child.writeAll(buf);
            count.* += 1;
        }
    }
};

test "shell escape 1" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var shell: ShellEscapeWriter = .{ .child_writer = &writer };
    try shell.writer.writeAll("abc");
    try testing.expectEqualStrings("abc", writer.buffered());
}

test "shell escape 2" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var shell: ShellEscapeWriter = .{ .child_writer = &writer };
    try shell.writer.writeAll("a c");
    try testing.expectEqualStrings("a\\ c", writer.buffered());
}

test "shell escape 3" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var shell: ShellEscapeWriter = .{ .child_writer = &writer };
    try shell.writer.writeAll("a?c");
    try testing.expectEqualStrings("a\\?c", writer.buffered());
}

test "shell escape 4" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var shell: ShellEscapeWriter = .{ .child_writer = &writer };
    try shell.writer.writeAll("a\\c");
    try testing.expectEqualStrings("a\\\\c", writer.buffered());
}

test "shell escape 5" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var shell: ShellEscapeWriter = .{ .child_writer = &writer };
    try shell.writer.writeAll("a|c");
    try testing.expectEqualStrings("a\\|c", writer.buffered());
}

test "shell escape 6" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var shell: ShellEscapeWriter = .{ .child_writer = &writer };
    try shell.writer.writeAll("a\"c");
    try testing.expectEqualStrings("a\\\"c", writer.buffered());
}

test "shell escape 7" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var shell: ShellEscapeWriter = .{ .child_writer = &writer };
    try shell.writer.writeAll("a(1)");
    try testing.expectEqualStrings("a\\(1\\)", writer.buffered());
}
