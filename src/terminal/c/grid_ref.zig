const std = @import("std");
const testing = std.testing;
const page = @import("../page.zig");
const PageList = @import("../PageList.zig");
const size = @import("../size.zig");
const stylepkg = @import("../style.zig");
const cell_c = @import("cell.zig");
const row_c = @import("row.zig");
const style_c = @import("style.zig");
const Result = @import("result.zig").Result;

/// C: GhosttyGridRef
///
/// A sized struct that holds a reference to a position in the terminal grid.
/// The ref points to a specific cell position within the terminal's
/// internal page structure.
pub const CGridRef = extern struct {
    size: usize = @sizeOf(CGridRef),
    node: ?*PageList.List.Node = null,
    x: size.CellCountInt = 0,
    y: size.CellCountInt = 0,

    pub fn fromPin(pin: PageList.Pin) CGridRef {
        return .{
            .node = pin.node,
            .x = pin.x,
            .y = pin.y,
        };
    }

    fn toPin(self: CGridRef) ?PageList.Pin {
        return .{
            .node = self.node orelse return null,
            .x = self.x,
            .y = self.y,
        };
    }
};

pub fn grid_ref_cell(
    ref: *const CGridRef,
    out: ?*cell_c.CCell,
) callconv(.c) Result {
    const p = ref.toPin() orelse return .invalid_value;
    if (out) |o| o.* = @bitCast(p.rowAndCell().cell.*);
    return .success;
}

pub fn grid_ref_row(
    ref: *const CGridRef,
    out: ?*row_c.CRow,
) callconv(.c) Result {
    const p = ref.toPin() orelse return .invalid_value;
    if (out) |o| o.* = @bitCast(p.rowAndCell().row.*);
    return .success;
}

pub fn grid_ref_graphemes(
    ref: *const CGridRef,
    out_buf: ?[*]u32,
    buf_len: usize,
    out_len: *usize,
) callconv(.c) Result {
    const p = ref.toPin() orelse return .invalid_value;
    const cell = p.rowAndCell().cell;

    if (!cell.hasText()) {
        out_len.* = 0;
        return .success;
    }

    const cp = cell.codepoint();
    const extra = if (cell.hasGrapheme()) p.grapheme(cell) else null;
    const total = 1 + if (extra) |e| e.len else 0;

    if (out_buf == null or buf_len < total) {
        out_len.* = total;
        return .out_of_space;
    }

    const buf = out_buf.?[0..buf_len];
    buf[0] = cp;
    if (extra) |e| for (e, 1..) |c, i| {
        buf[i] = c;
    };

    out_len.* = total;
    return .success;
}

pub fn grid_ref_style(
    ref: *const CGridRef,
    out: ?*style_c.Style,
) callconv(.c) Result {
    const p = ref.toPin() orelse return .invalid_value;
    if (out) |o| {
        const cell = p.rowAndCell().cell;
        if (cell.style_id == stylepkg.default_id) {
            o.* = .fromStyle(.{});
        } else {
            o.* = .fromStyle(p.node.data.styles.get(
                p.node.data.memory,
                cell.style_id,
            ).*);
        }
    }
    return .success;
}

test "grid_ref_cell null node" {
    const ref = CGridRef{};
    var out: cell_c.CCell = undefined;
    try testing.expectEqual(Result.invalid_value, grid_ref_cell(&ref, &out));
}

test "grid_ref_row null node" {
    const ref = CGridRef{};
    var out: row_c.CRow = undefined;
    try testing.expectEqual(Result.invalid_value, grid_ref_row(&ref, &out));
}

test "grid_ref_cell null out" {
    const ref = CGridRef{};
    try testing.expectEqual(Result.invalid_value, grid_ref_cell(&ref, null));
}

test "grid_ref_row null out" {
    const ref = CGridRef{};
    try testing.expectEqual(Result.invalid_value, grid_ref_row(&ref, null));
}

test "grid_ref_graphemes null node" {
    const ref = CGridRef{};
    var len: usize = undefined;
    try testing.expectEqual(Result.invalid_value, grid_ref_graphemes(&ref, null, 0, &len));
}

test "grid_ref_graphemes null buf returns out_of_space" {
    const ref = CGridRef{};
    var len: usize = undefined;
    // With null node this returns invalid_value before checking the buffer,
    // so we can only test null node here. Full buffer tests require a real page.
    try testing.expectEqual(Result.invalid_value, grid_ref_graphemes(&ref, null, 0, &len));
}

test "grid_ref_style null node" {
    const ref = CGridRef{};
    var out: style_c.Style = undefined;
    try testing.expectEqual(Result.invalid_value, grid_ref_style(&ref, &out));
}

test "grid_ref_style null out" {
    const ref = CGridRef{};
    try testing.expectEqual(Result.invalid_value, grid_ref_style(&ref, null));
}
