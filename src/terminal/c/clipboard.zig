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

pub fn encodePaste(
    data_: ?[*]u8,
    data_len: usize,
    bracketed: bool,
    out_: ?[*]u8,
    out_len: usize,
    out_written: *usize,
) callconv(lib.calling_conv) Result {
    const data: []u8 = if (data_) |d| d[0..data_len] else &.{};
    const result = terminal_clipboard.encodePaste(data, .{ .bracketed = bracketed });
    const total_len = result[0].len + result[1].len + result[2].len;

    const out: []u8 = if (out_) |o| o[0..out_len] else &.{};
    if (out.len < total_len) {
        out_written.* = total_len;
        return .out_of_space;
    }

    var offset: usize = 0;
    for (result) |slice| {
        @memcpy(out[offset..][0..slice.len], slice);
        offset += slice.len;
    }

    out_written.* = total_len;
    return .success;
}

test "encodePaste bracketed" {
    var data = "hello".*;
    var buf: [128]u8 = undefined;
    var written: usize = 0;
    const result = encodePaste(&data, data.len, true, &buf, buf.len, &written);
    try std.testing.expectEqual(.success, result);
    try std.testing.expectEqualStrings("\x1b[200~hello\x1b[201~", buf[0..written]);
}

test "encodePaste unbracketed" {
    var data = "hello\nworld".*;
    var buf: [128]u8 = undefined;
    var written: usize = 0;
    const result = encodePaste(&data, data.len, false, &buf, buf.len, &written);
    try std.testing.expectEqual(.success, result);
    try std.testing.expectEqualStrings("hello\rworld", buf[0..written]);
}

test "encodePaste strips unsafe bytes" {
    var data = "hel\x1blo".*;
    var buf: [128]u8 = undefined;
    var written: usize = 0;
    const result = encodePaste(&data, data.len, true, &buf, buf.len, &written);
    try std.testing.expectEqual(.success, result);
    try std.testing.expectEqualStrings("\x1b[200~hel lo\x1b[201~", buf[0..written]);
}

test "encodePaste insufficient buffer" {
    var data = "hello".*;
    var buf: [1]u8 = undefined;
    var written: usize = 0;
    const result = encodePaste(&data, data.len, true, &buf, buf.len, &written);
    try std.testing.expectEqual(.out_of_space, result);
    try std.testing.expect(written > 1);
}

test "encodePaste null buffer" {
    var data = "hello".*;
    var written: usize = 0;
    const result = encodePaste(&data, data.len, true, null, 0, &written);
    try std.testing.expectEqual(.out_of_space, result);
    try std.testing.expect(written > 0);
}

test "encodePaste null data" {
    var buf: [128]u8 = undefined;
    var written: usize = 0;
    const result = encodePaste(null, 0, true, &buf, buf.len, &written);
    try std.testing.expectEqual(.success, result);
    try std.testing.expectEqualStrings("\x1b[200~\x1b[201~", buf[0..written]);
}

pub fn paste_is_safe(data: ?[*]const u8, len: usize) callconv(lib.calling_conv) bool {
    const slice: []const u8 = if (data) |v| v[0..len] else &.{};
    return terminal_clipboard.isPasteSafe(slice);
}

test "paste_is_safe with safe data" {
    const testing = std.testing;
    const safe = "hello world";
    try testing.expect(paste_is_safe(safe.ptr, safe.len));
}

test "paste_is_safe with newline" {
    const testing = std.testing;
    const unsafe = "hello\nworld";
    try testing.expect(!paste_is_safe(unsafe.ptr, unsafe.len));
}

test "paste_is_safe with bracketed paste end" {
    const testing = std.testing;
    const unsafe = "hello\x1b[201~world";
    try testing.expect(!paste_is_safe(unsafe.ptr, unsafe.len));
}

test "paste_is_safe with empty data" {
    const testing = std.testing;
    const empty = "";
    try testing.expect(paste_is_safe(empty.ptr, 0));
}

test "paste_is_safe with null empty data" {
    const testing = std.testing;
    try testing.expect(paste_is_safe(null, 0));
}
