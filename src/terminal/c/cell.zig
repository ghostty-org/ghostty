const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const page = @import("../page.zig");
const Cell = page.Cell;
const color = @import("../color.zig");
const style_c = @import("style.zig");
const Result = @import("result.zig").Result;

/// C: GhosttyCell
pub const CCell = u64;

/// C: GhosttyCellContentTag
pub const ContentTag = enum(c_int) {
    codepoint = 0,
    codepoint_grapheme = 1,
    bg_color_palette = 2,
    bg_color_rgb = 3,
};

/// C: GhosttyCellWide
pub const Wide = enum(c_int) {
    narrow = 0,
    wide = 1,
    spacer_tail = 2,
    spacer_head = 3,
};

/// C: GhosttyCellSemanticContent
pub const SemanticContent = enum(c_int) {
    output = 0,
    input = 1,
    prompt = 2,
};

/// C: GhosttyCellData
pub const CellData = enum(c_int) {
    invalid = 0,

    /// The codepoint of the cell (0 if empty or bg-color-only).
    /// Output type: uint32_t * (stored as u21, zero-extended)
    codepoint = 1,

    /// The content tag describing what kind of content is in the cell.
    /// Output type: GhosttyCellContentTag *
    content_tag = 2,

    /// The wide property of the cell.
    /// Output type: GhosttyCellWide *
    wide = 3,

    /// Whether the cell has text to render.
    /// Output type: bool *
    has_text = 4,

    /// Whether the cell has styling (non-default style).
    /// Output type: bool *
    has_styling = 5,

    /// The style ID for the cell (for use with style lookups).
    /// Output type: uint16_t *
    style_id = 6,

    /// Whether the cell has a hyperlink.
    /// Output type: bool *
    has_hyperlink = 7,

    /// Whether the cell is protected.
    /// Output type: bool *
    protected = 8,

    /// The semantic content type of the cell (from OSC 133).
    /// Output type: GhosttyCellSemanticContent *
    semantic_content = 9,

    /// The palette index for the cell's background color.
    /// Only valid when content_tag is bg_color_palette.
    /// Output type: GhosttyColorPaletteIndex *
    color_palette = 10,

    /// The RGB value for the cell's background color.
    /// Only valid when content_tag is bg_color_rgb.
    /// Output type: GhosttyColorRgb *
    color_rgb = 11,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: CellData) type {
        return switch (self) {
            .invalid => void,
            .codepoint => u32,
            .content_tag => ContentTag,
            .wide => Wide,
            .has_text, .has_styling, .has_hyperlink, .protected => bool,
            .style_id => u16,
            .semantic_content => SemanticContent,
            .color_palette => u8,
            .color_rgb => color.RGB.C,
        };
    }
};

pub fn get(
    cell_: CCell,
    data: CellData,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(CellData, @intFromEnum(data)) catch {
            return .invalid_value;
        };
    }

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| getTyped(
            cell_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

fn getTyped(
    cell_: CCell,
    comptime data: CellData,
    out: *data.OutType(),
) Result {
    const cell: Cell = @bitCast(cell_);
    switch (data) {
        .invalid => return .invalid_value,
        .codepoint => out.* = @intCast(cell.codepoint()),
        .content_tag => out.* = @enumFromInt(@intFromEnum(cell.content_tag)),
        .wide => out.* = @enumFromInt(@intFromEnum(cell.wide)),
        .has_text => out.* = cell.hasText(),
        .has_styling => out.* = cell.hasStyling(),
        .style_id => out.* = cell.style_id,
        .has_hyperlink => out.* = cell.hyperlink,
        .protected => out.* = cell.protected,
        .semantic_content => out.* = @enumFromInt(@intFromEnum(cell.semantic_content)),
        .color_palette => out.* = cell.content.color_palette,
        .color_rgb => {
            const rgb = cell.content.color_rgb;
            out.* = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
        },
    }

    return .success;
}

test "get codepoint" {
    const cell: CCell = @bitCast(Cell.init('A'));
    var cp: u32 = 0;
    try testing.expectEqual(Result.success, get(cell, .codepoint, @ptrCast(&cp)));
    try testing.expectEqual(@as(u32, 'A'), cp);
}

test "get has_text" {
    const cell: CCell = @bitCast(Cell.init('A'));
    var has: bool = false;
    try testing.expectEqual(Result.success, get(cell, .has_text, @ptrCast(&has)));
    try testing.expect(has);
}

test "get empty cell" {
    const cell: CCell = @bitCast(Cell.init(0));
    var has: bool = true;
    try testing.expectEqual(Result.success, get(cell, .has_text, @ptrCast(&has)));
    try testing.expect(!has);
}

test "get wide" {
    var zig_cell = Cell.init('A');
    zig_cell.wide = .wide;
    const cell: CCell = @bitCast(zig_cell);
    var w: Wide = .narrow;
    try testing.expectEqual(Result.success, get(cell, .wide, @ptrCast(&w)));
    try testing.expectEqual(Wide.wide, w);
}
