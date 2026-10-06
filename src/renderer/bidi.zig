//! Bidirectional text reordering for a single row of render state cells.
//!
//! Terminal rows are stored in logical order. To display right-to-left
//! text we reorder the cells of a row into visual order before rendering.
//! The renderer then draws the reordered cells left-to-right as usual, and
//! the font shaper shapes right-to-left runs in the right-to-left direction
//! (see `font.shape.RunOptions.bidi_levels`).
//!
//! This only affects display. The terminal grid, cursor, and selections all
//! continue to operate in logical order, so callers map between the two
//! using `order`.

const Reorder = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../config.zig");
const terminal = @import("../terminal/main.zig");
const bidi = @import("../unicode/main.zig").bidi;

const Cells = std.MultiArrayList(terminal.RenderState.Cell);

/// The cells of the most recently reordered row, in visual order.
cells: Cells = .empty,

/// The resolved embedding level of each cell in `cells` (visual order).
levels: std.ArrayList(u8) = .empty,

/// `order[visual_x]` is the logical x of the cell displayed at visual_x.
order: std.ArrayList(u16) = .empty,

/// Scratch buffers.
classes: std.ArrayList(bidi.Class) = .empty,
codepoints: std.ArrayList(u21) = .empty,
work: std.ArrayList(bidi.Class) = .empty,
logical_levels: std.ArrayList(u8) = .empty,

pub fn deinit(self: *Reorder, alloc: Allocator) void {
    self.cells.deinit(alloc);
    self.levels.deinit(alloc);
    self.order.deinit(alloc);
    self.classes.deinit(alloc);
    self.codepoints.deinit(alloc);
    self.work.deinit(alloc);
    self.logical_levels.deinit(alloc);
}

/// Reorder the given row of cells into visual order. Returns false if the
/// row doesn't need reordering, in which case the visual order is the same
/// as the logical order and none of the fields are valid. Otherwise,
/// `cells`, `levels`, and `order` are valid until the next call.
pub fn reorder(
    self: *Reorder,
    alloc: Allocator,
    mode: configpkg.Config.Bidi,
    cells: Cells.Slice,
) Allocator.Error!bool {
    _ = try self.computeOrder(alloc, mode, cells.items(.raw)) orelse
        return false;

    // Build our visual cells and levels.
    const order = self.order.items;
    const levels = self.logical_levels.items;
    try self.levels.resize(alloc, order.len);
    self.cells.clearRetainingCapacity();
    try self.cells.resize(alloc, order.len);
    for (order, 0..) |logical, v| {
        self.cells.set(v, cells.get(logical));
        self.levels.items[v] = levels[logical];
    }

    return true;
}

/// The result of mapping a visual position to a logical position.
pub const Logical = struct {
    /// The logical x.
    x: usize,

    /// True if the cell is right-to-left, meaning that its logical
    /// start is on its visual right side.
    rtl: bool,
};

/// Map a visual x within the given row of raw cells to its logical x.
/// Returns null if the row isn't reordered (the mapping is the identity).
pub fn visualToLogical(
    self: *Reorder,
    alloc: Allocator,
    mode: configpkg.Config.Bidi,
    raws: []const terminal.page.Cell,
    visual: usize,
) Allocator.Error!?Logical {
    _ = try self.computeOrder(alloc, mode, raws) orelse return null;
    const order = self.order.items;
    if (visual >= order.len) return null;
    const logical = order[visual];
    const levels = self.logical_levels.items;
    return .{
        .x = logical,
        .rtl = levels[logical] & 1 == 1,
    };
}

/// Compute the visual order of a row of cells, setting `order` and
/// `logical_levels`. Returns the paragraph direction, or null if the row
/// doesn't need reordering.
fn computeOrder(
    self: *Reorder,
    alloc: Allocator,
    mode: configpkg.Config.Bidi,
    raws: []const terminal.page.Cell,
) Allocator.Error!?bidi.Direction {
    if (mode == .false) return null;

    // The length of the text in the row, excluding trailing empty cells.
    const text_len: usize = len: {
        var i = raws.len;
        while (i > 0) : (i -= 1) {
            if (!raws[i - 1].isEmpty()) break;
        }
        break :len i;
    };
    if (text_len == 0) return null;

    // Fast path: in LTR (or auto) mode, rows without any strong RTL
    // characters never need reordering. Explicit formatting characters
    // aren't supported so we don't need to look at graphemes.
    if (mode != .rtl) {
        for (raws[0..text_len]) |*raw| {
            if (bidi.isRtlCodepoint(raw.codepoint())) break;
        } else return null;
    }

    // We reorder the full row, treating empty cells as whitespace. Rule L1
    // puts trailing whitespace at the paragraph level, so trailing empty
    // cells stay on the right of left-to-right rows and move to the left
    // of right-to-left rows. That is, right-to-left rows are aligned to
    // the right edge of the terminal.
    const len = raws.len;

    // Classify each cell by its primary codepoint.
    try self.classes.resize(alloc, len);
    try self.codepoints.resize(alloc, len);
    for (raws[0..len], self.codepoints.items) |*raw, *cp| cp.* = raw.codepoint();
    for (raws[0..len], self.classes.items, 0..) |*raw, *c, i| {
        c.* = switch (raw.wide) {
            // The tail of a wide character has the same class as its head.
            .spacer_tail => if (i > 0) self.classes.items[i - 1] else .whitespace,
            .spacer_head => .whitespace,
            .narrow, .wide => if (raw.hasText()) bidi.class(raw.codepoint()) else .whitespace,
        };
    }

    const para: bidi.Direction = switch (mode) {
        .false => unreachable,
        .ltr => .ltr,
        .rtl => .rtl,
        .auto => bidi.Direction.detect(self.classes.items, .ltr),
    };

    // Resolve levels
    try self.work.resize(alloc, len);
    try self.logical_levels.resize(alloc, len);
    const levels = self.logical_levels.items;
    bidi.resolveLevels(
        self.classes.items,
        self.codepoints.items,
        self.work.items,
        levels,
        para,
    );

    // The tail of a wide character must always be at the same level as
    // its head so that they're reordered together.
    for (raws[0..len], 0..) |*raw, i| {
        if (raw.wide == .spacer_tail and i > 0) levels[i] = levels[i - 1];
    }

    // If nothing is at an odd level then the order is unchanged.
    for (levels) |l| {
        if (l & 1 == 1) break;
    } else return null;

    // Compute the visual order.
    try self.order.resize(alloc, len);
    const order = self.order.items;
    bidi.reorder(levels, order);

    // Reversed wide characters will have their tail before their head
    // so we swap them back to keep the head on the left.
    {
        var v: usize = 0;
        while (v + 1 < len) : (v += 1) {
            if (raws[order[v]].wide == .spacer_tail and
                order[v + 1] + 1 == order[v])
            {
                std.mem.swap(u16, &order[v], &order[v + 1]);
                v += 1;
            }
        }
    }

    return para;
}

/// Returns the visual x of the given logical x. Only valid after a call
/// to reorder (or logicalToVisual) that returned a reordered result.
pub fn visualX(self: *const Reorder, logical: usize) usize {
    for (self.order.items, 0..) |o, v| {
        if (o == logical) return v;
    }

    // Not found, must be past the end of the row.
    return logical;
}

/// The result of mapping a logical position to a visual position.
pub const Visual = struct {
    /// The visual x.
    x: usize,

    /// True if the cell is right-to-left, meaning that its logical
    /// start is on its visual right side.
    rtl: bool,
};

/// Map a logical x within the given row of raw cells to its visual x.
/// This is cheaper than `reorder` because it doesn't build the visual
/// cells.
pub fn logicalToVisual(
    self: *Reorder,
    alloc: Allocator,
    mode: configpkg.Config.Bidi,
    raws: []const terminal.page.Cell,
    logical: usize,
) Allocator.Error!Visual {
    const identity: Visual = .{ .x = logical, .rtl = false };
    _ = try self.computeOrder(alloc, mode, raws) orelse return identity;
    const levels = self.logical_levels.items;
    if (logical >= levels.len) return identity;
    return .{
        .x = self.visualX(logical),
        .rtl = levels[logical] & 1 == 1,
    };
}

fn testRow(
    alloc: Allocator,
    mode: configpkg.Config.Bidi,
    input: []const u8,
    expected: []const u8,
) !void {
    const testing = std.testing;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 20, .rows = 1 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(input);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var r: Reorder = .{};
    defer r.deinit(alloc);
    const cells = state.row_data.get(0).cells.slice();
    const reordered = try r.reorder(alloc, mode, cells);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    const visual = if (reordered) r.cells.slice() else cells;
    for (visual.items(.raw)) |raw| {
        if (raw.wide == .spacer_tail) continue;
        if (!raw.hasText()) continue;
        var cp_buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(raw.codepoint(), &cp_buf);
        try buf.appendSlice(alloc, cp_buf[0..n]);
    }
    try testing.expectEqualStrings(expected, buf.items);
}

test "bidi reorder: LTR only is not reordered" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var r: Reorder = .{};
    defer r.deinit(alloc);
    try testing.expect(!try r.reorder(alloc, .ltr, state.row_data.get(0).cells.slice()));
    try testing.expect(!try r.reorder(alloc, .auto, state.row_data.get(0).cells.slice()));
}

test "bidi reorder: disabled" {
    try testRow(std.testing.allocator, .false, "אבג", "אבג");
}

test "bidi reorder: hebrew" {
    try testRow(std.testing.allocator, .ltr, "אבג", "גבא");
}

test "bidi reorder: mixed" {
    try testRow(std.testing.allocator, .ltr, "$ שלום world", "$ םולש world");
}

test "bidi reorder: arabic with numbers" {
    try testRow(std.testing.allocator, .ltr, "سلام 123", "123 مالس");
}

test "bidi reorder: rtl paragraph" {
    try testRow(std.testing.allocator, .rtl, "abc אבג", "גבא abc");
}

test "bidi reorder: auto paragraph" {
    try testRow(std.testing.allocator, .auto, "אבג abc", "abc גבא");
    try testRow(std.testing.allocator, .auto, "abc אבג", "abc גבא");
}

test "bidi reorder: wide characters keep head before tail" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 20, .rows = 1 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    // An emoji (neutral, wide) between two RTL letters resolves to RTL.
    s.nextSlice("א😀ב");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var r: Reorder = .{};
    defer r.deinit(alloc);
    try testing.expect(try r.reorder(alloc, .ltr, state.row_data.get(0).cells.slice()));

    const raws = r.cells.items(.raw);
    try testing.expectEqual(@as(u21, 0x05D1), raws[0].codepoint());
    try testing.expectEqual(terminal.page.Cell.Wide.wide, raws[1].wide);
    try testing.expectEqual(@as(u21, 0x1F600), raws[1].codepoint());
    try testing.expectEqual(terminal.page.Cell.Wide.spacer_tail, raws[2].wide);
    try testing.expectEqual(@as(u21, 0x05D0), raws[3].codepoint());

    // Logical/visual mapping
    try testing.expectEqual(@as(usize, 3), r.visualX(0));
    try testing.expectEqual(@as(usize, 0), r.visualX(3));
    try testing.expectEqual(@as(usize, 10), r.visualX(10));
}

test "bidi reorder: brackets" {
    try testRow(std.testing.allocator, .ltr, "x: سلام (دنیا)", "x: )ایند( مالس");
}

test "bidi reorder: visual to logical" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("ab אבג");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);
    const raws = state.row_data.get(0).cells.slice().items(.raw);

    var r: Reorder = .{};
    defer r.deinit(alloc);

    // LTR cells map to themselves.
    try testing.expectEqual(Logical{ .x = 0, .rtl = false }, (try r.visualToLogical(alloc, .ltr, raws, 0)).?);
    // Visual x=3 displays the last Hebrew letter (logical x=5).
    try testing.expectEqual(Logical{ .x = 5, .rtl = true }, (try r.visualToLogical(alloc, .ltr, raws, 3)).?);
    try testing.expectEqual(Logical{ .x = 3, .rtl = true }, (try r.visualToLogical(alloc, .ltr, raws, 5)).?);
    // Trailing empty cells are unchanged.
    try testing.expectEqual(Logical{ .x = 8, .rtl = false }, (try r.visualToLogical(alloc, .ltr, raws, 8)).?);
    // Disabled
    try testing.expect(try r.visualToLogical(alloc, .false, raws, 3) == null);

    // And back again
    try testing.expectEqual(Visual{ .x = 3, .rtl = true }, try r.logicalToVisual(alloc, .ltr, raws, 5));
    try testing.expectEqual(Visual{ .x = 1, .rtl = false }, try r.logicalToVisual(alloc, .ltr, raws, 1));
    try testing.expectEqual(Visual{ .x = 5, .rtl = false }, try r.logicalToVisual(alloc, .false, raws, 5));
}
