const std = @import("std");
const lib = @import("lib.zig");
const ConformanceLevel = @import("device_attributes.zig").ConformanceLevel;

/// The color scheme reported in response to a CSI ? 996 n query.
pub const ColorScheme = lib.Enum(lib.target, &.{
    "light",
    "dark",
});

/// The visibility state reported in response to a CSI ? 998 n query or when
/// DEC mode 2033 is enabled.
pub const Visibility = lib.Enum(lib.target, &.{
    "potentially_visible",
    "not_visible",
});

/// Maximum number of bytes that `encodeColorSchemeReport` will write.
pub const max_color_scheme_report_encode_size = max: {
    var result: usize = 0;
    for (@typeInfo(ColorScheme).@"enum".field_values) |field_value| {
        var discarding: std.Io.Writer.Discarding = .init(&.{});
        encodeColorSchemeReport(
            &discarding.writer,
            @fromBackingInt(field_value),
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

/// Maximum number of bytes that `encodeVisibilityReport` will write.
pub const max_visibility_report_encode_size = "\x1B[?999;2n".len;

/// Encode a visibility report response for CSI ? 998 n queries and DEC mode
/// 2033 notifications.
pub fn encodeVisibilityReport(
    writer: *std.Io.Writer,
    visibility: Visibility,
) std.Io.Writer.Error!void {
    try writer.writeAll(switch (visibility) {
        .potentially_visible => "\x1B[?999;1n",
        .not_visible => "\x1B[?999;2n",
    });
}

/// The reply to a status request about hardware or a feature that Ghostty
/// doesn't have, which is therefore always the same. Null for requests whose
/// reply depends on the terminal's state.
pub fn fixedReport(req: Request) ?[:0]const u8 {
    return switch (req) {
        // No printer.
        .printer_status => "\x1B[?13n",

        // Locked: Ghostty doesn't support DECUDK, so user-defined keys can't
        // be set.
        .udk_status => "\x1B[?21n",

        // No locator. Ghostty doesn't support DEC locator mode (DECELR).
        .locator_status => "\x1B[?50n",

        // Locator type unknown.
        .locator_type => "\x1B[?57;0n",

        // DECMSR: no space for macros. Ghostty doesn't support DECDMAC.
        .macro_space => "\x1B[0*{",

        // No communication errors are possible on a pty.
        .data_integrity => "\x1B[?70n",

        // Not configured for multiple sessions.
        .multiple_sessions => "\x1B[?83n",

        .operating_status,
        .cursor_position,
        .cursor_position_extended,
        .keyboard_status,
        .memory_checksum,
        .color_scheme,
        .visibility,
        => null,
    };
}

/// Maximum number of bytes that `encodeKeyboardReport` will write.
pub const max_keyboard_report_encode_size = "\x1B[?27;0;0;0n".len;

/// Encode the keyboard status report for CSI ? 26 n queries. The report
/// grew a parameter at each of conformance levels 3 and 4, so its length
/// follows the level the terminal reports in its primary device attributes.
///
/// The terminal can't know the keyboard's language, so that is reported as
/// unknown. The keyboard is always ready, and its type is reported as an
/// LK201, as xterm does.
pub fn encodeKeyboardReport(
    writer: *std.Io.Writer,
    level: ConformanceLevel,
) std.Io.Writer.Error!void {
    const int = @backingInt(level);
    try writer.writeAll(
        if (int >= @backingInt(ConformanceLevel.level_4))
            "\x1B[?27;0;0;0n"
        else if (int >= @backingInt(ConformanceLevel.level_3))
            "\x1B[?27;0;0n"
        else
            "\x1B[?27;0n",
    );
}

/// Maximum number of bytes that `encodeMemoryChecksumReport` will write.
pub const max_memory_checksum_report_encode_size = "\x1BP65535!~0000\x1B\\".len;

/// Encode the DECCKSR memory checksum report for CSI ? 63 ; Pid n queries.
/// The checksum covers macro memory, and Ghostty has none, so it is zero.
pub fn encodeMemoryChecksumReport(
    writer: *std.Io.Writer,
    id: u16,
) std.Io.Writer.Error!void {
    try writer.print("\x1BP{}!~0000\x1B\\", .{id});
}

/// An enum(u16) of the available device status requests.
pub const Request = dsr_enum: {
    var names: [entries.len][]const u8 = undefined;
    var values: [entries.len]Tag.Backing = undefined;

    for (entries, &names, &values) |entry, *name, *value| {
        name.* = entry.name;
        value.* = @bitCast(Tag{
            .value = entry.value,
            .question = entry.question,
        });
    }

    break :dsr_enum @Enum(Tag.Backing, .exhaustive, &names, &values);
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
            return @fromBackingInt(int);
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
    // DECXCPR: the "?" form of value 6 reports the extended cursor position
    // (adds a page number) rather than the plain CPR.
    .{ .name = "cursor_position_extended", .value = 6, .question = true },
    .{ .name = "printer_status", .value = 15, .question = true },
    .{ .name = "udk_status", .value = 25, .question = true },
    .{ .name = "keyboard_status", .value = 26, .question = true },
    .{ .name = "locator_status", .value = 55, .question = true },
    .{ .name = "locator_type", .value = 56, .question = true },
    // DECMSR
    .{ .name = "macro_space", .value = 62, .question = true },
    // DECCKSR: the only request with a second parameter, an id that is
    // echoed in the reply.
    .{ .name = "memory_checksum", .value = 63, .question = true },
    .{ .name = "data_integrity", .value = 75, .question = true },
    .{ .name = "multiple_sessions", .value = 85, .question = true },
    .{ .name = "color_scheme", .value = 996, .question = true },
    .{ .name = "visibility", .value = 998, .question = true },
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

test "encode visibility report" {
    var buf: [max_visibility_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeVisibilityReport(&writer, .potentially_visible);
    try std.testing.expectEqualStrings("\x1B[?999;1n", writer.buffered());

    writer = .fixed(&buf);
    try encodeVisibilityReport(&writer, .not_visible);
    try std.testing.expectEqualStrings("\x1B[?999;2n", writer.buffered());
}

test "encode keyboard report follows conformance level" {
    var buf: [max_keyboard_report_encode_size]u8 = undefined;
    const cases = [_]struct { level: ConformanceLevel, expected: []const u8 }{
        .{ .level = .vt100, .expected = "\x1B[?27;0n" },
        .{ .level = .vt220, .expected = "\x1B[?27;0n" },
        .{ .level = .vt320, .expected = "\x1B[?27;0;0n" },
        .{ .level = .vt420, .expected = "\x1B[?27;0;0;0n" },
        .{ .level = .vt520, .expected = "\x1B[?27;0;0;0n" },
    };
    for (cases) |case| {
        var writer: std.Io.Writer = .fixed(&buf);
        try encodeKeyboardReport(&writer, case.level);
        try std.testing.expectEqualStrings(case.expected, writer.buffered());
    }
}

test "encode memory checksum report" {
    var buf: [max_memory_checksum_report_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeMemoryChecksumReport(&writer, 123);
    try std.testing.expectEqualStrings("\x1BP123!~0000\x1B\\", writer.buffered());

    writer = .fixed(&buf);
    try encodeMemoryChecksumReport(&writer, std.math.maxInt(u16));
    try std.testing.expectEqual(max_memory_checksum_report_encode_size, writer.buffered().len);
}
