const std = @import("std");
const testing = std.testing;
const page = @import("../page.zig");
const Row = page.Row;
const Result = @import("result.zig").Result;

/// C: GhosttyRow
pub const CRow = Row.C;

/// C: GhosttyRowSemanticPrompt
pub const SemanticPrompt = enum(c_int) {
    none = 0,
    prompt = 1,
    prompt_continuation = 2,
};

/// C: GhosttyRowData
pub const RowData = enum(c_int) {
    invalid = 0,

    /// Whether this row is soft-wrapped.
    /// Output type: bool *
    wrap = 1,

    /// Whether this row is a continuation of a soft-wrapped row.
    /// Output type: bool *
    wrap_continuation = 2,

    /// Whether any cells in this row have grapheme clusters.
    /// Output type: bool *
    grapheme = 3,

    /// Whether any cells in this row have styling (may have false positives).
    /// Output type: bool *
    styled = 4,

    /// Whether any cells in this row have hyperlinks (may have false positives).
    /// Output type: bool *
    hyperlink = 5,

    /// The semantic prompt state of this row.
    /// Output type: GhosttyRowSemanticPrompt *
    semantic_prompt = 6,

    /// Whether this row contains a Kitty virtual placeholder.
    /// Output type: bool *
    kitty_virtual_placeholder = 7,

    /// Whether this row is dirty and requires a redraw.
    /// Output type: bool *
    dirty = 8,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: RowData) type {
        return switch (self) {
            .invalid => void,
            .wrap, .wrap_continuation, .grapheme, .styled, .hyperlink => bool,
            .kitty_virtual_placeholder, .dirty => bool,
            .semantic_prompt => SemanticPrompt,
        };
    }
};

pub fn get(
    row_: CRow,
    data: RowData,
    out: ?*anyopaque,
) callconv(.c) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(RowData, @intFromEnum(data)) catch {
            return .invalid_value;
        };
    }

    return switch (data) {
        inline else => |comptime_data| getTyped(
            row_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

fn getTyped(
    row_: CRow,
    comptime data: RowData,
    out: *data.OutType(),
) Result {
    const row: Row = @bitCast(row_);
    switch (data) {
        .invalid => return .invalid_value,
        .wrap => out.* = row.wrap,
        .wrap_continuation => out.* = row.wrap_continuation,
        .grapheme => out.* = row.grapheme,
        .styled => out.* = row.styled,
        .hyperlink => out.* = row.hyperlink,
        .semantic_prompt => out.* = @enumFromInt(@intFromEnum(row.semantic_prompt)),
        .kitty_virtual_placeholder => out.* = row.kitty_virtual_placeholder,
        .dirty => out.* = row.dirty,
    }

    return .success;
}

test "get wrap" {
    var zig_row: Row = @bitCast(@as(u64, 0));
    zig_row.wrap = true;
    const row: CRow = @bitCast(zig_row);
    var wrap: bool = false;
    try testing.expectEqual(Result.success, get(row, .wrap, @ptrCast(&wrap)));
    try testing.expect(wrap);
}

test "get semantic_prompt" {
    var zig_row: Row = @bitCast(@as(u64, 0));
    zig_row.semantic_prompt = .prompt;
    const row: CRow = @bitCast(zig_row);
    var sp: SemanticPrompt = .none;
    try testing.expectEqual(Result.success, get(row, .semantic_prompt, @ptrCast(&sp)));
    try testing.expectEqual(SemanticPrompt.prompt, sp);
}

test "get dirty" {
    var zig_row: Row = @bitCast(@as(u64, 0));
    zig_row.dirty = true;
    const row: CRow = @bitCast(zig_row);
    var dirty: bool = false;
    try testing.expectEqual(Result.success, get(row, .dirty, @ptrCast(&dirty)));
    try testing.expect(dirty);
}
