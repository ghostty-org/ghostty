const std = @import("std");
const lib = @import("../lib.zig");
const terminal_size_report = @import("../size_report.zig");
const Result = @import("result.zig").Result;

/// C: GhosttySizeReportStyle
pub const Style = terminal_size_report.Style;

/// C: GhosttySizeReportSize
pub const Size = terminal_size_report.Size;

pub fn encode(
    style_: lib.CEnum(Style),
    size_: ?*const Size,
    out_: ?[*]u8,
    out_len: usize,
    out_written_: ?*usize,
) callconv(lib.calling_conv) Result {
    const out_written = out_written_ orelse return .invalid_value;
    const style = lib.enumFromC(Style, style_) orelse return .invalid_value;
    const size = (size_ orelse return .invalid_value).*;
    var writer: std.Io.Writer = .fixed(if (out_) |out| out[0..out_len] else &.{});
    terminal_size_report.encode(&writer, style, size) catch |err| switch (err) {
        error.WriteFailed => {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            terminal_size_report.encode(&discarding.writer, style, size) catch unreachable;
            out_written.* = @intCast(discarding.count);
            return .out_of_space;
        },
    };

    out_written.* = writer.end;
    return .success;
}

test "encode mode 2048" {
    var buf: [64]u8 = undefined;
    var written: usize = 0;
    const result = encode(.mode_2048, &.{
        .rows = 24,
        .columns = 80,
        .cell_width = 9,
        .cell_height = 18,
    }, &buf, buf.len, &written);
    try std.testing.expectEqual(.success, result);
    try std.testing.expectEqualStrings("\x1B[48;24;80;432;720t", buf[0..written]);
}

test "encode csi 14 t" {
    var buf: [64]u8 = undefined;
    var written: usize = 0;
    const result = encode(.csi_14_t, &.{
        .rows = 24,
        .columns = 80,
        .cell_width = 9,
        .cell_height = 18,
    }, &buf, buf.len, &written);
    try std.testing.expectEqual(.success, result);
    try std.testing.expectEqualStrings("\x1b[4;432;720t", buf[0..written]);
}

test "encode with insufficient buffer" {
    var buf: [1]u8 = undefined;
    var written: usize = 0;
    const result = encode(.csi_18_t, &.{
        .rows = 24,
        .columns = 80,
        .cell_width = 9,
        .cell_height = 18,
    }, &buf, buf.len, &written);
    try std.testing.expectEqual(.out_of_space, result);
    try std.testing.expect(written > 1);
}

test "encode with null buffer" {
    var written: usize = 0;
    const result = encode(.csi_18_t, &.{
        .rows = 24,
        .columns = 80,
        .cell_width = 9,
        .cell_height = 18,
    }, null, 0, &written);
    try std.testing.expectEqual(.out_of_space, result);
    try std.testing.expect(written > 0);
}

test "encode rejects a null size" {
    var buf: [64]u8 = undefined;
    var written: usize = 0;
    try std.testing.expectEqual(.invalid_value, encode(.csi_18_t, null, &buf, buf.len, &written));
}
