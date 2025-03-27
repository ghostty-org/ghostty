const std = @import("std");
const testing = std.testing;

/// Writer that escapes characters that shells treat specially to reduce the
/// risk of injection attacks or other such weirdness. Specifically excludes
/// linefeeds so that they can be used to delineate lists of file paths.
///
/// T should be a Zig type that follows the `std.io.Writer` interface.
pub fn ShellEscapeWriter(comptime T: type) type {
    return struct {
        child_writer: T,

        fn write(self: *ShellEscapeWriter(T), data: []const u8) error{Error}!usize {
            var count: usize = 0;
            for (data) |byte| {
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
                self.child_writer.writeAll(buf) catch return error.Error;
                count += 1;
            }
            return count;
        }

        const Writer = std.io.Writer(*ShellEscapeWriter(T), error{Error}, write);

        pub fn writer(self: *ShellEscapeWriter(T)) Writer {
            return .{ .context = self };
        }
    };
}

test "shell escape 1" {
    var buf: [128]u8 = undefined;
    var fmt = std.io.fixedBufferStream(&buf);
    var shell: ShellEscapeWriter(@TypeOf(fmt).Writer) = .{ .child_writer = fmt.writer() };
    const writer = shell.writer();
    try writer.writeAll("abc");
    try testing.expectEqualStrings("abc", fmt.getWritten());
}

test "shell escape 2" {
    var buf: [128]u8 = undefined;
    var fmt = std.io.fixedBufferStream(&buf);
    var shell: ShellEscapeWriter(@TypeOf(fmt).Writer) = .{ .child_writer = fmt.writer() };
    const writer = shell.writer();
    try writer.writeAll("a c");
    try testing.expectEqualStrings("a\\ c", fmt.getWritten());
}

test "shell escape 3" {
    var buf: [128]u8 = undefined;
    var fmt = std.io.fixedBufferStream(&buf);
    var shell: ShellEscapeWriter(@TypeOf(fmt).Writer) = .{ .child_writer = fmt.writer() };
    const writer = shell.writer();
    try writer.writeAll("a?c");
    try testing.expectEqualStrings("a\\?c", fmt.getWritten());
}

test "shell escape 4" {
    var buf: [128]u8 = undefined;
    var fmt = std.io.fixedBufferStream(&buf);
    var shell: ShellEscapeWriter(@TypeOf(fmt).Writer) = .{ .child_writer = fmt.writer() };
    const writer = shell.writer();
    try writer.writeAll("a\\c");
    try testing.expectEqualStrings("a\\\\c", fmt.getWritten());
}

test "shell escape 5" {
    var buf: [128]u8 = undefined;
    var fmt = std.io.fixedBufferStream(&buf);
    var shell: ShellEscapeWriter(@TypeOf(fmt).Writer) = .{ .child_writer = fmt.writer() };
    const writer = shell.writer();
    try writer.writeAll("a|c");
    try testing.expectEqualStrings("a\\|c", fmt.getWritten());
}

test "shell escape 6" {
    var buf: [128]u8 = undefined;
    var fmt = std.io.fixedBufferStream(&buf);
    var shell: ShellEscapeWriter(@TypeOf(fmt).Writer) = .{ .child_writer = fmt.writer() };
    const writer = shell.writer();
    try writer.writeAll("a\"c");
    try testing.expectEqualStrings("a\\\"c", fmt.getWritten());
}

test "shell escape 7" {
    var buf: [128]u8 = undefined;
    var fmt = std.io.fixedBufferStream(&buf);
    var shell: ShellEscapeWriter(@TypeOf(fmt).Writer) = .{ .child_writer = fmt.writer() };
    const writer = shell.writer();
    try writer.writeAll("a(1)");
    try testing.expectEqualStrings("a\\(1\\)", fmt.getWritten());
}
