const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});

pub const ParsedTimestamp = struct {
    unix_milliseconds: i64,
};

pub fn parseSelectionTimestamp(selection: []const u8) ?ParsedTimestamp {
    const trimmed = std.mem.trim(u8, selection, &std.ascii.whitespace);
    if (trimmed.len != 10 and trimmed.len != 13) return null;

    for (trimmed) |ch| {
        if (!std.ascii.isDigit(ch)) return null;
    }

    const value = std.fmt.parseInt(i64, trimmed, 10) catch return null;
    const unix_milliseconds = switch (trimmed.len) {
        10 => std.math.mul(i64, value, std.time.ms_per_s) catch return null,
        13 => value,
        else => unreachable,
    };

    return .{ .unix_milliseconds = unix_milliseconds };
}

pub fn formatSelectionMenuLabel(buf: []u8, selection: []const u8) ?[:0]const u8 {
    const parsed = parseSelectionTimestamp(selection) orelse return null;
    return formatMenuLabel(buf, parsed.unix_milliseconds);
}

fn formatMenuLabel(buf: []u8, unix_milliseconds: i64) ?[:0]const u8 {
    var preview_buf: [64]u8 = undefined;
    const preview = formatTimestampPreview(&preview_buf, unix_milliseconds) orelse return null;
    return std.fmt.bufPrintZ(buf, "Time: {s}", .{preview}) catch null;
}

fn formatTimestampPreview(buf: []u8, unix_milliseconds: i64) ?[]const u8 {
    const unix_seconds = @divTrunc(unix_milliseconds, std.time.ms_per_s);
    var time_value: c.time_t = std.math.cast(c.time_t, unix_seconds) orelse return null;
    var tm_value: c.struct_tm = std.mem.zeroes(c.struct_tm);
    if (c.localtime_r(&time_value, &tm_value) == null) return null;

    var datetime_buf: [32]u8 = undefined;
    const datetime_len = c.strftime(
        &datetime_buf,
        datetime_buf.len,
        "%Y-%m-%d %H:%M:%S",
        &tm_value,
    );
    if (datetime_len == 0) return null;

    const offset_seconds: i64 = @intCast(tm_value.tm_gmtoff);
    const sign: u8 = if (offset_seconds < 0) '-' else '+';
    const abs_offset_seconds = @abs(offset_seconds);
    const offset_hours = @divTrunc(abs_offset_seconds, std.time.s_per_hour);
    const offset_minutes = @divTrunc(
        @mod(abs_offset_seconds, std.time.s_per_hour),
        std.time.s_per_min,
    );

    return std.fmt.bufPrint(
        buf,
        "{s} GMT{c}{d:0>2}:{d:0>2}",
        .{
            datetime_buf[0..datetime_len],
            sign,
            offset_hours,
            offset_minutes,
        },
    ) catch null;
}

test "parseSelectionTimestamp accepts second precision timestamps" {
    const parsed = parseSelectionTimestamp("1773193977").?;
    try std.testing.expectEqual(@as(i64, 1773193977000), parsed.unix_milliseconds);
}

test "parseSelectionTimestamp accepts millisecond precision timestamps" {
    const parsed = parseSelectionTimestamp("1773193977000").?;
    try std.testing.expectEqual(@as(i64, 1773193977000), parsed.unix_milliseconds);
}

test "parseSelectionTimestamp trims surrounding whitespace" {
    const parsed = parseSelectionTimestamp(" \n1773193977\t").?;
    try std.testing.expectEqual(@as(i64, 1773193977000), parsed.unix_milliseconds);
}

test "parseSelectionTimestamp rejects mixed content" {
    try std.testing.expectEqual(@as(?ParsedTimestamp, null), parseSelectionTimestamp("abc1773193977"));
    try std.testing.expectEqual(@as(?ParsedTimestamp, null), parseSelectionTimestamp("1773193977 abc"));
}

test "parseSelectionTimestamp rejects unsupported lengths" {
    try std.testing.expectEqual(@as(?ParsedTimestamp, null), parseSelectionTimestamp("177319397"));
    try std.testing.expectEqual(@as(?ParsedTimestamp, null), parseSelectionTimestamp("17731939770"));
    try std.testing.expectEqual(@as(?ParsedTimestamp, null), parseSelectionTimestamp("177319397700"));
    try std.testing.expectEqual(@as(?ParsedTimestamp, null), parseSelectionTimestamp("17731939770000"));
}
