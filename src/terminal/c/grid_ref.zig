const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const page = @import("../page.zig");
const PageList = @import("../PageList.zig");
const point = @import("../point.zig");
const size = @import("../size.zig");
const stylepkg = @import("../style.zig");
const cell_c = @import("cell.zig");
const row_c = @import("row.zig");
const style_c = @import("style.zig");
const terminal_c = @import("terminal.zig");
const Result = @import("result.zig").Result;

/// C: GhosttyGridRef
///
/// A reference to a single cell in the terminal grid. It points at a cell
/// within the terminal's internal page structure.
///
/// C callers allocate this struct themselves, so its size and field
/// offsets are part of the ABI. The C header documents them, and the
/// comptime block below keeps the two in sync.
pub const CGridRef = extern struct {
    node: ?*PageList.List.Node = null,
    x: size.CellCountInt = 0,
    y: size.CellCountInt = 0,

    // Expected sizes: 16 bytes on 64-bit targets, 8 bytes on 32-bit.
    comptime {
        std.debug.assert(size.CellCountInt == u16);
        std.debug.assert(@sizeOf(CGridRef) == switch (@sizeOf(usize)) {
            8 => 16,
            4 => 8,
            else => unreachable,
        });
    }

    pub fn fromPin(pin: PageList.Pin) CGridRef {
        return .{
            .node = pin.node,
            .x = pin.x,
            .y = pin.y,
        };
    }

    pub fn toPin(self: CGridRef) ?PageList.Pin {
        return .{
            .node = self.node orelse return null,
            .x = self.x,
            .y = self.y,
        };
    }
};

pub fn grid_ref_cell(
    ref_: ?*const CGridRef,
    out: ?*cell_c.CCell,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.grid_introspection)) return .unsupported;
    const ref = ref_ orelse return .invalid_value;
    const p = ref.toPin() orelse return .invalid_value;
    if (out) |o| o.* = @bitCast(p.rowAndCell().cell.*);
    return .success;
}

pub fn grid_ref_row(
    ref_: ?*const CGridRef,
    out: ?*row_c.CRow,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.grid_introspection)) return .unsupported;
    const ref = ref_ orelse return .invalid_value;
    const p = ref.toPin() orelse return .invalid_value;
    if (out) |o| o.* = @bitCast(p.rowAndCell().row.*);
    return .success;
}

pub fn grid_ref_graphemes(
    ref_: ?*const CGridRef,
    buf_: ?[*]u32,
    buf_len: usize,
    out_written_: ?*usize,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.grid_introspection)) return .unsupported;
    const ref = ref_ orelse return .invalid_value;
    const out_written = out_written_ orelse return .invalid_value;
    const p = ref.toPin() orelse return .invalid_value;
    const cell = p.rowAndCell().cell;

    if (!cell.hasText()) {
        out_written.* = 0;
        return .success;
    }

    const cp = cell.codepoint();
    const extra = if (cell.hasGrapheme()) p.grapheme(cell) else null;
    const total = 1 + if (extra) |e| e.len else 0;

    if (buf_ == null or buf_len < total) {
        out_written.* = total;
        return .out_of_space;
    }

    const buf = buf_.?[0..buf_len];
    buf[0] = cp;
    if (extra) |e| for (e, 1..) |c, i| {
        buf[i] = c;
    };

    out_written.* = total;
    return .success;
}

pub fn grid_ref_hyperlink_uri(
    ref_: ?*const CGridRef,
    buf_: ?[*]u8,
    buf_len: usize,
    out_written_: ?*usize,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.grid_introspection)) return .unsupported;
    const ref = ref_ orelse return .invalid_value;
    const out_written = out_written_ orelse return .invalid_value;
    const p = ref.toPin() orelse return .invalid_value;
    const terminal_page = p.node.page();
    const rac = terminal_page.getRowAndCell(p.x, p.y);
    const cell = rac.cell;

    if (!cell.hyperlink) {
        out_written.* = 0;
        return .success;
    }

    const link_id = terminal_page.lookupHyperlink(cell) orelse {
        out_written.* = 0;
        return .success;
    };
    const entry = terminal_page.hyperlink_set.get(
        terminal_page.memory,
        link_id,
    );
    const uri = entry.uri.slice(terminal_page.memory);

    if (buf_ == null or buf_len < uri.len) {
        out_written.* = uri.len;
        return .out_of_space;
    }

    @memcpy(buf_.?[0..uri.len], uri);
    out_written.* = uri.len;
    return .success;
}

pub fn grid_ref_style(
    ref_: ?*const CGridRef,
    out: ?*style_c.Style,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.grid_introspection)) return .unsupported;
    const ref = ref_ orelse return .invalid_value;
    const p = ref.toPin() orelse return .invalid_value;
    if (out) |o| {
        const cell = p.rowAndCell().cell;
        if (cell.style_id == stylepkg.default_id) {
            o.* = .fromStyle(.{});
        } else {
            const terminal_page = p.node.page();
            o.* = .fromStyle(terminal_page.styles.get(
                terminal_page.memory,
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

test "grid_ref_graphemes buffer" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    // "e" followed by U+0301 COMBINING ACUTE ACCENT is one cell with
    // two codepoints.
    const seq = "e\u{0301}";
    terminal_c.vt_write(terminal, seq, seq.len);

    var ref: CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(
        terminal,
        point.Point.cval(.{ .active = .{ .x = 0, .y = 0 } }),
        &ref,
    ));

    // Size query: the count is in codepoints, not bytes.
    var written: usize = undefined;
    try testing.expectEqual(Result.out_of_space, grid_ref_graphemes(&ref, null, 0, &written));
    try testing.expectEqual(@as(usize, 2), written);

    // Undersized: same result, buffer untouched.
    var small: [1]u32 = .{0xAAAA};
    try testing.expectEqual(Result.out_of_space, grid_ref_graphemes(&ref, &small, small.len, &written));
    try testing.expectEqual(@as(usize, 2), written);
    try testing.expectEqual(@as(u32, 0xAAAA), small[0]);

    // Success.
    var buf: [4]u32 = undefined;
    try testing.expectEqual(Result.success, grid_ref_graphemes(&ref, &buf, buf.len, &written));
    try testing.expectEqualSlices(u32, &.{ 'e', 0x0301 }, buf[0..written]);

    // A cell with no text needs no space, even for a size query.
    try testing.expectEqual(Result.success, terminal_c.grid_ref(
        terminal,
        point.Point.cval(.{ .active = .{ .x = 5, .y = 0 } }),
        &ref,
    ));
    try testing.expectEqual(Result.success, grid_ref_graphemes(&ref, null, 0, &written));
    try testing.expectEqual(@as(usize, 0), written);
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

test "grid_ref_hyperlink_uri null node" {
    const ref = CGridRef{};
    var len: usize = undefined;
    try testing.expectEqual(Result.invalid_value, grid_ref_hyperlink_uri(&ref, null, 0, &len));
}

test "grid_ref_hyperlink_uri no hyperlink" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    terminal_c.vt_write(terminal, "hello", 5);

    var ref: CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(
        terminal,
        point.Point.cval(.{ .active = .{ .x = 0, .y = 0 } }),
        &ref,
    ));

    var len: usize = undefined;
    try testing.expectEqual(Result.success, grid_ref_hyperlink_uri(&ref, null, 0, &len));
    try testing.expectEqual(@as(usize, 0), len);
}

test "grid_ref_hyperlink_uri with hyperlink" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    // Write OSC 8 hyperlink: \e]8;;uri\e\\text\e]8;;\e\\
    const seq = "\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\";
    terminal_c.vt_write(terminal, seq, seq.len);

    var ref: CGridRef = undefined;
    try testing.expectEqual(Result.success, terminal_c.grid_ref(
        terminal,
        point.Point.cval(.{ .active = .{ .x = 0, .y = 0 } }),
        &ref,
    ));

    // First query length with null buf
    var len: usize = undefined;
    try testing.expectEqual(Result.out_of_space, grid_ref_hyperlink_uri(&ref, null, 0, &len));
    try testing.expectEqual(@as(usize, 19), len); // "https://example.com"

    // An undersized buffer gets the same result and is left untouched.
    var small: [4]u8 = @splat('x');
    try testing.expectEqual(Result.out_of_space, grid_ref_hyperlink_uri(&ref, &small, small.len, &len));
    try testing.expectEqual(@as(usize, 19), len);
    try testing.expectEqualStrings("xxxx", &small);

    // Now read with a properly sized buffer
    var buf: [256]u8 = undefined;
    try testing.expectEqual(Result.success, grid_ref_hyperlink_uri(&ref, &buf, buf.len, &len));
    try testing.expectEqualStrings("https://example.com", buf[0..len]);
}
