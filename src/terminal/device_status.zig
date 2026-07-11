const std = @import("std");
const lib = @import("lib.zig");

/// The color scheme reported in response to a CSI ? 996 n query.
pub const ColorScheme = lib.Enum(lib.target, &.{
    "light",
    "dark",
});

/// Maximum number of bytes that `encodeColorSchemeReport` will write.
pub const max_color_scheme_report_encode_size = max: {
    var result: usize = 0;
    for (@typeInfo(ColorScheme).@"enum".fields) |field| {
        var discarding: std.Io.Writer.Discarding = .init(&.{});
        encodeColorSchemeReport(
            &discarding.writer,
            @enumFromInt(field.value),
        ) catch unreachable;
        result = @max(result, @as(usize, @intCast(discarding.count)));
    }

    break :max result;
};

/// Encode a color scheme report response for CSI ? 996 n queries.
pub fn encodeColorSchemeReport(
    writer: *std.Io.Writer,
    scheme: ColorScheme,
) std.Io.Writer.Error!void {
    try writer.writeAll(switch (scheme) {
        .dark => "\x1B[?997;1n",
        .light => "\x1B[?997;2n",
    });
}

/// An enum(u16) of the available device status requests.
pub const Request = dsr_enum: {
    const EnumField = std.builtin.Type.EnumField;
    var fields: [entries.len]EnumField = undefined;
    for (entries, 0..) |entry, i| {
        fields[i] = .{
            .name = entry.name,
            .value = @as(Tag.Backing, @bitCast(Tag{
                .value = entry.value,
                .question = entry.question,
            })),
        };
    }

    break :dsr_enum @Type(.{ .@"enum" = .{
        .tag_type = Tag.Backing,
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

/// The tag type for our enum is a u16 but we use a packed struct
/// in order to pack the question bit into the tag. The "u16" size is
/// chosen somewhat arbitrarily to match the largest expected size
/// we see as a multiple of 8 bits.
pub const Tag = packed struct(u16) {
    pub const Backing = @typeInfo(@This()).@"struct".backing_integer.?;
    value: u15,
    question: bool = false,

    test "order" {
        const t: Tag = .{ .value = 1 };
        const int: Backing = @bitCast(t);
        try std.testing.expectEqual(@as(Backing, 1), int);
    }
};

pub fn reqFromInt(v: u16, question: bool) ?Request {
    inline for (entries) |entry| {
        if (entry.value == v and entry.question == question) {
            const tag: Tag = .{ .question = question, .value = entry.value };
            const int: Tag.Backing = @bitCast(tag);
            return @enumFromInt(int);
        }
    }

    return null;
}

/// A single entry of a possible device status request we support. The
/// "question" field determines if it is valid with or without the "?"
/// prefix.
const Entry = struct {
    name: [:0]const u8,
    value: comptime_int,
    question: bool = false, // "?" request
};

/// The full list of device status request entries.
const entries: []const Entry = &.{
    .{ .name = "operating_status", .value = 5 },
    .{ .name = "cursor_position", .value = 6 },
    .{ .name = "color_scheme", .value = 996, .question = true },
};

test "encode color scheme report dark" {
    try std.testing.expectEqual(@as(usize, 9), max_color_scheme_report_encode_size);

    var buf: [max_color_scheme_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeColorSchemeReport(&writer, .dark);
    try std.testing.expectEqualStrings("\x1B[?997;1n", writer.buffered());
}

test "encode color scheme report light" {
    var buf: [max_color_scheme_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeColorSchemeReport(&writer, .light);
    try std.testing.expectEqualStrings("\x1B[?997;2n", writer.buffered());
}
