const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Builder for constructing space-separated shell command strings.
/// Uses a caller-provided allocator (typically with stackFallback).
pub const ShellCommandBuilder = struct {
    buffer: std.Io.Writer.Allocating,

    pub fn init(allocator: Allocator) ShellCommandBuilder {
        return .{ .buffer = .init(allocator) };
    }

    pub fn deinit(self: *ShellCommandBuilder) void {
        self.buffer.deinit();
    }

    /// Append an argument to the command with automatic space separation.
    pub fn appendArg(self: *ShellCommandBuilder, arg: []const u8) (Allocator.Error || Writer.Error)!void {
        if (arg.len == 0) return;
        if (self.buffer.written().len > 0) {
            try self.buffer.writer.writeByte(' ');
        }
        try self.buffer.writer.writeAll(arg);
    }

    /// Get the final null-terminated command string, transferring ownership to caller.
    /// Calling deinit() after this is safe but unnecessary.
    pub fn toOwnedSlice(self: *ShellCommandBuilder) Allocator.Error![:0]const u8 {
        return try self.buffer.toOwnedSliceSentinel(0);
    }
};

test ShellCommandBuilder {
    // Empty command
    {
        var cmd = ShellCommandBuilder.init(testing.allocator);
        defer cmd.deinit();
        try testing.expectEqualStrings("", cmd.buffer.written());
    }

    // Single arg
    {
        var cmd = ShellCommandBuilder.init(testing.allocator);
        defer cmd.deinit();
        try cmd.appendArg("bash");
        try testing.expectEqualStrings("bash", cmd.buffer.written());
    }

    // Multiple args
    {
        var cmd = ShellCommandBuilder.init(testing.allocator);
        defer cmd.deinit();
        try cmd.appendArg("bash");
        try cmd.appendArg("--posix");
        try cmd.appendArg("-l");
        try testing.expectEqualStrings("bash --posix -l", cmd.buffer.written());
    }

    // Empty arg
    {
        var cmd = ShellCommandBuilder.init(testing.allocator);
        defer cmd.deinit();
        try cmd.appendArg("bash");
        try cmd.appendArg("");
        try testing.expectEqualStrings("bash", cmd.buffer.written());
    }

    // toOwnedSlice
    {
        var cmd = ShellCommandBuilder.init(testing.allocator);
        try cmd.appendArg("bash");
        try cmd.appendArg("--posix");
        const result = try cmd.toOwnedSlice();
        defer testing.allocator.free(result);
        try testing.expectEqualStrings("bash --posix", result);
        try testing.expectEqual(@as(u8, 0), result[result.len]);
    }
}

/// Writer that escapes characters that shells treat specially to reduce the
/// risk of injection attacks or other such weirdness. Specifically excludes
/// linefeeds so that they can be used to delineate lists of file paths.
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

        for (0..splat) |_| try self.writeEscaped(data[data.len - 1], &count);
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
    var shell: ShellEscapeWriter = .init(&writer);
    try shell.writer.writeAll("abc");
    try testing.expectEqualStrings("abc", writer.buffered());
}

test "shell escape 2" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var shell: ShellEscapeWriter = .init(&writer);
    try shell.writer.writeAll("a c");
    try testing.expectEqualStrings("a\\ c", writer.buffered());
}

test "shell escape 3" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var shell: ShellEscapeWriter = .init(&writer);
    try shell.writer.writeAll("a?c");
    try testing.expectEqualStrings("a\\?c", writer.buffered());
}

test "shell escape 4" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var shell: ShellEscapeWriter = .init(&writer);
    try shell.writer.writeAll("a\\c");
    try testing.expectEqualStrings("a\\\\c", writer.buffered());
}

test "shell escape 5" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var shell: ShellEscapeWriter = .init(&writer);
    try shell.writer.writeAll("a|c");
    try testing.expectEqualStrings("a\\|c", writer.buffered());
}

test "shell escape 6" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var shell: ShellEscapeWriter = .init(&writer);
    try shell.writer.writeAll("a\"c");
    try testing.expectEqualStrings("a\\\"c", writer.buffered());
}

test "shell escape 7" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var shell: ShellEscapeWriter = .init(&writer);
    try shell.writer.writeAll("a(1)");
    try testing.expectEqualStrings("a\\(1\\)", writer.buffered());
}
