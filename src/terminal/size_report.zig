const std = @import("std");
const lib = @import("lib.zig");
const CellCountInt = @import("size.zig").CellCountInt;

/// Output formats for terminal size reports written to the PTY.
pub const Style = lib.Enum(lib.target, &.{
    // In-band size reports (mode 2048)
    "mode_2048",
    // XTWINOPS: report text area size in pixels
    "csi_14_t",
    // XTWINOPS: report cell size in pixels
    "csi_16_t",
    // XTWINOPS: report text area size in characters
    "csi_18_t",
});

/// Runtime size values used to encode terminal size reports.
pub const Size = lib.Struct(lib.target, struct {
    /// Terminal row count in cells.
    rows: CellCountInt,

    /// Terminal column count in cells.
    columns: CellCountInt,

    /// Width of a single terminal cell in pixels.
    cell_width: u32,

    /// Height of a single terminal cell in pixels.
    cell_height: u32,
});

fn widthPixels(s: Size) u64 {
    return @as(u64, s.columns) * @as(u64, s.cell_width);
}

fn heightPixels(s: Size) u64 {
    return @as(u64, s.rows) * @as(u64, s.cell_height);
}

/// Encode a terminal size report sequence.
pub fn encode(
    writer: *std.Io.Writer,
    style: Style,
    size: Size,
) std.Io.Writer.Error!void {
    switch (style) {
        .mode_2048 => try writer.print(
            "\x1B[48;{};{};{};{}t",
            .{
                size.rows,
                size.columns,
                heightPixels(size),
                widthPixels(size),
            },
        ),

        .csi_14_t => try writer.print(
            "\x1b[4;{};{}t",
            .{
                heightPixels(size),
                widthPixels(size),
            },
        ),

        .csi_16_t => try writer.print(
            "\x1b[6;{};{}t",
            .{
                size.cell_height,
                size.cell_width,
            },
        ),

        .csi_18_t => try writer.print(
            "\x1b[8;{};{}t",
            .{
                size.rows,
                size.columns,
            },
        ),
    }
}

fn testSize() Size {
    return .{
        .rows = 24,
        .columns = 80,
        .cell_width = 9,
        .cell_height = 18,
    };
}

test "encode mode 2048" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, .mode_2048, testSize());

    try std.testing.expectEqualStrings("\x1B[48;24;80;432;720t", writer.buffered());
}

test "encode csi 14 t" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, .csi_14_t, testSize());

    try std.testing.expectEqualStrings("\x1b[4;432;720t", writer.buffered());
}

test "encode csi 16 t" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, .csi_16_t, testSize());

    try std.testing.expectEqualStrings("\x1b[6;18;9t", writer.buffered());
}

test "encode csi 18 t" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, .csi_18_t, testSize());

    try std.testing.expectEqualStrings("\x1b[8;24;80t", writer.buffered());
}

test "encode max values for all fields" {
    const max_size: Size = .{
        .rows = std.math.maxInt(@FieldType(Size, "rows")),
        .columns = std.math.maxInt(@FieldType(Size, "columns")),
        .cell_width = std.math.maxInt(@FieldType(Size, "cell_width")),
        .cell_height = std.math.maxInt(@FieldType(Size, "cell_height")),
    };

    const Case = struct {
        style: Style,
        expected: []const u8,
    };

    inline for ([_]Case{
        .{
            .style = .mode_2048,
            .expected = "\x1B[48;65535;65535;281470681677825;281470681677825t",
        },
        .{
            .style = .csi_14_t,
            .expected = "\x1b[4;281470681677825;281470681677825t",
        },
        .{
            .style = .csi_16_t,
            .expected = "\x1b[6;4294967295;4294967295t",
        },
        .{
            .style = .csi_18_t,
            .expected = "\x1b[8;65535;65535t",
        },
    }) |case| {
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try encode(&writer, case.style, max_size);
        try std.testing.expectEqualStrings(case.expected, writer.buffered());
    }
}
