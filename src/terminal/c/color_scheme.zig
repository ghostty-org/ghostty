const std = @import("std");
const lib = @import("../lib.zig");
const device_status = @import("../device_status.zig");
const Result = @import("result.zig").Result;

pub fn report_encode(
    scheme: device_status.ColorScheme,
    out_: ?[*]u8,
    out_len: usize,
    out_written: *usize,
) callconv(lib.calling_conv) Result {
    var writer: std.Io.Writer = .fixed(if (out_) |out| out[0..out_len] else &.{});
    device_status.encodeColorSchemeReport(&writer, scheme) catch |err| switch (err) {
        error.WriteFailed => {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            device_status.encodeColorSchemeReport(&discarding.writer, scheme) catch unreachable;
            out_written.* = @intCast(discarding.count);
            return .out_of_space;
        },
    };

    out_written.* = writer.end;
    return .success;
}

test "encode color scheme report dark" {
    var buf: [device_status.max_color_scheme_report_encode_size]u8 = undefined;
    var written: usize = 0;
    const result = report_encode(.dark, &buf, buf.len, &written);
    try std.testing.expectEqual(.success, result);
    try std.testing.expectEqualStrings("\x1B[?997;1n", buf[0..written]);
}

test "encode color scheme report light" {
    var buf: [device_status.max_color_scheme_report_encode_size]u8 = undefined;
    var written: usize = 0;
    const result = report_encode(.light, &buf, buf.len, &written);
    try std.testing.expectEqual(.success, result);
    try std.testing.expectEqualStrings("\x1B[?997;2n", buf[0..written]);
}

test "encode color scheme report with null buffer" {
    var written: usize = 0;
    const result = report_encode(.dark, null, 0, &written);
    try std.testing.expectEqual(.out_of_space, result);
    try std.testing.expectEqual(@as(usize, 9), written);
}

test "encode color scheme report with insufficient buffer" {
    var buf: [3]u8 = undefined;
    var written: usize = 0;
    const result = report_encode(.light, &buf, buf.len, &written);
    try std.testing.expectEqual(.out_of_space, result);
    try std.testing.expectEqual(@as(usize, 9), written);
}

test "encode color scheme report with exact buffer" {
    var buf: [9]u8 = undefined;
    var written: usize = 0;
    const result = report_encode(.dark, &buf, buf.len, &written);
    try std.testing.expectEqual(.success, result);
    try std.testing.expectEqual(@as(usize, 9), written);
}
