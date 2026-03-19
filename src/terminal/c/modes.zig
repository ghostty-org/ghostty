const std = @import("std");
const modes = @import("../modes.zig");
const Result = @import("result.zig").Result;

/// C: GhosttyModeReportState
pub const ReportState = enum(c_int) {
    _,

    fn toZig(self: ReportState) ?modes.Report.State {
        return std.meta.intToEnum(
            modes.Report.State,
            @intFromEnum(self),
        ) catch null;
    }
};

pub fn report_encode(
    tag: modes.ModeTag.Backing,
    state: ReportState,
    out_: ?[*]u8,
    out_len: usize,
    out_written: *usize,
) callconv(.c) Result {
    const mode_tag: modes.ModeTag = @bitCast(tag);
    const report: modes.Report = .{
        .tag = mode_tag,
        .state = state.toZig() orelse return .invalid_value,
    };

    var writer: std.Io.Writer = .fixed(if (out_) |out| out[0..out_len] else &.{});
    report.encode(&writer) catch |err| switch (err) {
        error.WriteFailed => {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            report.encode(&discarding.writer) catch unreachable;
            out_written.* = @intCast(discarding.count);
            return .out_of_space;
        },
    };

    out_written.* = writer.end;
    return .success;
}

test "encode DEC mode set" {
    var buf: [modes.Report.max_size]u8 = undefined;
    var written: usize = 0;
    const tag: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 1, .ansi = false });
    const result = report_encode(tag, @enumFromInt(1), &buf, buf.len, &written);
    try std.testing.expectEqual(.success, result);
    try std.testing.expectEqualStrings("\x1B[?1;1$y", buf[0..written]);
}

test "encode DEC mode reset" {
    var buf: [modes.Report.max_size]u8 = undefined;
    var written: usize = 0;
    const tag: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 1, .ansi = false });
    const result = report_encode(tag, @enumFromInt(2), &buf, buf.len, &written);
    try std.testing.expectEqual(.success, result);
    try std.testing.expectEqualStrings("\x1B[?1;2$y", buf[0..written]);
}

test "encode ANSI mode" {
    var buf: [modes.Report.max_size]u8 = undefined;
    var written: usize = 0;
    const tag: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 4, .ansi = true });
    const result = report_encode(tag, @enumFromInt(1), &buf, buf.len, &written);
    try std.testing.expectEqual(.success, result);
    try std.testing.expectEqualStrings("\x1B[4;1$y", buf[0..written]);
}

test "encode not recognized" {
    var buf: [modes.Report.max_size]u8 = undefined;
    var written: usize = 0;
    const tag: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 9999, .ansi = false });
    const result = report_encode(tag, @enumFromInt(0), &buf, buf.len, &written);
    try std.testing.expectEqual(.success, result);
    try std.testing.expectEqualStrings("\x1B[?9999;0$y", buf[0..written]);
}

test "encode with insufficient buffer" {
    var buf: [1]u8 = undefined;
    var written: usize = 0;
    const tag: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 1, .ansi = false });
    const result = report_encode(tag, @enumFromInt(1), &buf, buf.len, &written);
    try std.testing.expectEqual(.out_of_space, result);
    try std.testing.expect(written > 1);
}

test "encode with invalid state" {
    var buf: [modes.Report.max_size]u8 = undefined;
    var written: usize = 0;
    const tag: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 1, .ansi = false });
    const result = report_encode(tag, @enumFromInt(99), &buf, buf.len, &written);
    try std.testing.expectEqual(.invalid_value, result);
}

test "encode with null buffer" {
    var written: usize = 0;
    const tag: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 1, .ansi = false });
    const result = report_encode(tag, @enumFromInt(1), null, 0, &written);
    try std.testing.expectEqual(.out_of_space, result);
    try std.testing.expect(written > 0);
}
