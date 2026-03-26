const std = @import("std");
const lib = @import("../lib.zig");
const terminal_clipboard = @import("../clipboard.zig");
const Result = @import("result.zig").Result;

/// C: GhosttyClipboard
pub const Clipboard = terminal_clipboard.Clipboard;

pub fn encodeOSC52Read(
    clipboard: Clipboard,
    data: ?[*]const u8,
    data_len: usize,
    out_: ?[*]u8,
    out_len: usize,
    out_written: *usize,
) callconv(lib.calling_conv) Result {
    const input = if (data) |d| d[0..data_len] else "";
    var writer: std.Io.Writer = .fixed(if (out_) |out| out[0..out_len] else &.{});
    clipboard.encodeOSC52Read(&writer, input) catch |err| switch (err) {
        error.WriteFailed => {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            clipboard.encodeOSC52Read(&discarding.writer, input) catch unreachable;
            out_written.* = @intCast(discarding.count);
            return .out_of_space;
        },
    };

    out_written.* = writer.end;
    return .success;
}

test "encode standard" {
    var buf: [128]u8 = undefined;
    var written: usize = 0;
    const result = encodeOSC52Read(.standard, "hello", 5, &buf, buf.len, &written);
    try std.testing.expectEqual(.success, result);
    try std.testing.expectEqualStrings("\x1b]52;c;aGVsbG8=\x1b\\", buf[0..written]);
}

test "encode with insufficient buffer" {
    var buf: [1]u8 = undefined;
    var written: usize = 0;
    const result = encodeOSC52Read(.standard, "hello", 5, &buf, buf.len, &written);
    try std.testing.expectEqual(.out_of_space, result);
    try std.testing.expect(written > 1);
}

test "encode with null buffer" {
    var written: usize = 0;
    const result = encodeOSC52Read(.standard, "hello", 5, null, 0, &written);
    try std.testing.expectEqual(.out_of_space, result);
    try std.testing.expect(written > 0);
}

test "encode with null data" {
    var buf: [128]u8 = undefined;
    var written: usize = 0;
    const result = encodeOSC52Read(.standard, null, 0, &buf, buf.len, &written);
    try std.testing.expectEqual(.success, result);
    try std.testing.expectEqualStrings("\x1b]52;c;\x1b\\", buf[0..written]);
}
