const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
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
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(RowData, @intFromEnum(data)) orelse {
            return .invalid_value;
        };
    }

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| getTyped(
            row_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

pub fn get_multi(
    row_: CRow,
    count: usize,
    keys: ?[*]const RowData,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;

    for (0..count) |i| {
        const result = get(row_, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
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

test "get_multi success" {
    var zig_row: Row = @bitCast(@as(u64, 0));
    zig_row.wrap = true;
    zig_row.dirty = true;
    const row_val: CRow = @bitCast(zig_row);

    var wrap: bool = false;
    var dirty: bool = false;
    var written: usize = 0;

    const keys = [_]RowData{ .wrap, .dirty };
    var values = [_]?*anyopaque{ @ptrCast(&wrap), @ptrCast(&dirty) };
    try testing.expectEqual(Result.success, get_multi(row_val, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
    try testing.expect(wrap);
    try testing.expect(dirty);
}

test "get_multi error sets out_written" {
    var zig_row: Row = @bitCast(@as(u64, 0));
    zig_row.wrap = true;
    const row_val: CRow = @bitCast(zig_row);

    var wrap: bool = false;
    var written: usize = 99;

    const keys = [_]RowData{ .wrap, .invalid };
    var values = [_]?*anyopaque{ @ptrCast(&wrap), @ptrCast(&wrap) };
    try testing.expectEqual(Result.invalid_value, get_multi(row_val, keys.len, &keys, &values, &written));
    try testing.expectEqual(1, written);
    try testing.expect(wrap);
}

test "get_multi null keys returns invalid_value" {
    const row_val: CRow = @bitCast(@as(u64, 0));
    var wrap: bool = false;
    var values = [_]?*anyopaque{@ptrCast(&wrap)};
    try testing.expectEqual(Result.invalid_value, get_multi(row_val, 1, null, &values, null));
}
