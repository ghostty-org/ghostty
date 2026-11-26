//! The text of a terminal viewport as accessibility clients read it:
//! one line per row, with the width of each character and the caret.
//! The text comes from the plain-text formatter.

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const formatter = terminal.formatter;
const unicode = @import("../unicode/main.zig");
const offsets = @import("offsets.zig");

/// One viewport snapshot. `build` reuses its buffers.
pub const Snapshot = struct {
    /// One line per viewport row.
    text: std.ArrayList(u8) = .empty,

    /// Columns covered by each codepoint of `text`; see
    /// `offsets.CellWidths`. A newline covers 0.
    widths: std.ArrayList(u8) = .empty,

    /// The caret, as a codepoint offset. The end of the text when the
    /// cursor is outside the viewport.
    caret: offsets.CodepointOffset = 0,

    /// Kept only to reuse its memory.
    pin_map: formatter.PinMap.Map = .empty,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        self.text.deinit(alloc);
        self.widths.deinit(alloc);
        self.pin_map.deinit(alloc);
        self.* = undefined;
    }

    pub fn cellWidths(self: *const Snapshot) offsets.CellWidths {
        return .{ .per_cp = self.widths.items };
    }

    /// Compares the text and the caret.
    pub fn eql(self: *const Snapshot, other: *const Snapshot) bool {
        return self.caret == other.caret and
            std.mem.eql(u8, self.text.items, other.text.items);
    }
};

/// Build the snapshot of the viewport of `screen` into `snap`,
/// replacing what it held.
pub fn build(
    alloc: Allocator,
    snap: *Snapshot,
    screen: *const terminal.Screen,
) Allocator.Error!void {
    snap.text.clearRetainingCapacity();
    snap.widths.clearRetainingCapacity();
    snap.pin_map.clearRetainingCapacity();
    snap.caret = 0;

    const pages = &screen.pages;
    const viewport_rows: usize = pages.rows;

    {
        // Keep spaces printed at the end of a row, such as the one after
        // a prompt, so that typing a space changes the text. Empty cells
        // are still dropped.
        var f: formatter.PageListFormatter = .init(pages, .{
            .emit = .plain,
            .trim = false,
        });
        f.top_left = pages.getTopLeft(.viewport);
        f.bottom_right = pages.getBottomRight(.viewport);
        f.pin_map = .{ .alloc = alloc, .map = &snap.pin_map };

        var aw: std.Io.Writer.Allocating = .fromArrayList(alloc, &snap.text);
        defer snap.text = aw.toArrayList();
        f.format(&aw.writer) catch return error.OutOfMemory;
    }

    // The formatter drops blank rows at the bottom. Add them back so that
    // line N of the text is row N of the viewport.
    const newlines = std.mem.countScalar(u8, snap.text.items, '\n');
    if (newlines + 1 < viewport_rows) {
        try snap.text.appendNTimes(alloc, '\n', viewport_rows - 1 - newlines);
    }

    try recordWidths(alloc, snap);
    snap.caret = caretOffset(snap, screen);
}

/// Fill `snap.widths` from the cells the formatter mapped each byte to.
fn recordWidths(alloc: Allocator, snap: *Snapshot) Allocator.Error!void {
    const text = snap.text.items;
    const map = &snap.pin_map;

    try snap.widths.ensureTotalCapacity(alloc, text.len);

    // Later codepoints of a grapheme map to the same cell as the first
    // one, and cover no columns.
    var prev: ?terminal.Pin = null;

    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        defer i += len;

        if (text[i] == '\n') {
            snap.widths.appendAssumeCapacity(0);
            prev = null;
            continue;
        }

        const pin = map.get(i) orelse {
            snap.widths.appendAssumeCapacity(1);
            prev = null;
            continue;
        };

        if (prev) |p| if (p.eql(pin)) {
            snap.widths.appendAssumeCapacity(0);
            continue;
        };
        prev = pin;

        // The formatter skips the spacer cell after a wide character.
        const wide = pin.rowAndCell().cell.wide == .wide;
        snap.widths.appendAssumeCapacity(if (wide) 2 else 1);
    }
}

/// The codepoint under the cursor. Past the end of its row, the end of
/// that row.
fn caretOffset(snap: *const Snapshot, screen: *const terminal.Screen) offsets.CodepointOffset {
    const text = snap.text.items;
    const widths = snap.widths.items;
    const cp_count = widths.len;

    const pt = screen.pages.pointFromPin(
        .viewport,
        screen.cursor.page_pin.*,
    ) orelse return cp_count;
    const cursor = pt.coord();
    if (cursor.y >= screen.pages.rows) return cp_count;

    var cp: usize = 0;
    var byte: usize = 0;
    var row: usize = 0;
    while (row < cursor.y) : (cp += 1) {
        if (byte >= text.len) return cp_count;
        if (text[byte] == '\n') row += 1;
        byte += std.unicode.utf8ByteSequenceLength(text[byte]) catch 1;
    }

    var col: usize = 0;
    while (byte < text.len and text[byte] != '\n') : (cp += 1) {
        const w = widths[cp];
        if (w > 0 and cursor.x < col + w) return cp;
        col += w;
        byte += std.unicode.utf8ByteSequenceLength(text[byte]) catch 1;
    }
    return cp;
}

const testing = std.testing;

fn testBuild(t: *terminal.Terminal, snap: *Snapshot) !void {
    try build(testing.allocator, snap, t.screens.active);
    try testing.expectEqual(
        unicode.utf8.cpCount(snap.text.items),
        snap.widths.items.len,
    );
}

test "a11y text: rows joined by newline, trailing blanks trimmed" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    try t.printString("hello");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("world");

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    // Row 3 is blank but still has a line.
    try testing.expectEqualStrings("hello\nworld\n", snap.text.items);
}

test "a11y text: printed trailing spaces are text" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    // A prompt, and a space typed after a word at the end of the line.
    try t.printString("$ ls ");

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    try testing.expectEqualStrings("$ ls ", snap.text.items);
    try testing.expectEqual(5, snap.caret);
}

test "a11y text: every viewport row has a line, even blank ones" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 5 });
    defer t.deinit(alloc);

    t.setCursorPos(2, 1);
    try t.printString("mid");
    t.setCursorPos(5, 3);

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    try testing.expectEqualStrings("\nmid\n\n\n", snap.text.items);
    try testing.expectEqual(snap.widths.items.len, snap.caret);
}

test "a11y text: widths report the columns each codepoint covers" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    try t.printString("wide 日本語 tail");

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    // The last 0 is the newline before row 2.
    try testing.expectEqualSlices(
        u8,
        &.{ 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 0 },
        snap.widths.items,
    );

    // 't' of "tail" is codepoint 9 but column 12.
    const text = snap.text.items;
    const t_byte = std.mem.indexOf(u8, text, "tail").?;
    const cp_idx = unicode.utf8.cpCount(text[0..t_byte]);
    try testing.expectEqual(9, cp_idx);
    try testing.expectEqual(12, offsets.cpToGrid(text, snap.cellWidths(), cp_idx).col);
}

test "a11y text: combining marks cover no columns" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    // 'e' and a combining acute accent: two codepoints in one cell.
    try t.printString("e\u{0301}x");

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    try testing.expectEqualStrings("e\u{0301}x", snap.text.items);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 1 }, snap.widths.items);
}

test "a11y text: intermediate blanks preserved as spaces" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    try t.printString("ab");
    t.setCursorPos(1, 6);
    try t.printString("cd");

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    try testing.expectEqualStrings("ab   cd", snap.text.items);
    try testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 1, 1, 1 }, snap.widths.items);
}

test "a11y text: cursor anchors past trailing blanks" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    try t.printString("hi");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("abc");

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    // The cursor is after "abc": the end of its row, not of the text.
    try testing.expectEqualStrings("hi\nabc\n", snap.text.items);
    try testing.expectEqual(6, snap.caret);
}

test "a11y text: cursor inside an interior blank run lands on its column" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    try t.printString("ab");
    t.setCursorPos(1, 7);
    try t.printString("cd");
    // On the second of the four spaces.
    t.setCursorPos(1, 4);

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    try testing.expectEqualStrings("ab    cd", snap.text.items);
    try testing.expectEqual(3, snap.caret);
}

test "a11y text: cursor on a wide character's spacer lands on the character" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    // 日 covers columns 2 and 3. The cursor is on column 3.
    try t.printString("ab日cd");
    t.setCursorPos(1, 4);

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    try testing.expectEqualStrings("ab日cd", snap.text.items);
    try testing.expectEqual(2, snap.caret);
}

test "a11y text: the caret follows the cursor's row when scrolled back" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    // "1" and "2" scroll into history.
    for (0..5) |i| {
        if (i > 0) {
            t.carriageReturn();
            try t.linefeed();
        }
        try t.print('1' + @as(u21, @intCast(i)));
    }

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);

    try testBuild(&t, &snap);
    try testing.expectEqualStrings("3\n4\n5", snap.text.items);
    try testing.expectEqual(5, snap.caret);

    // The cursor's row is now below the viewport. Counting rows from the
    // top of the active area would put the caret after "4".
    t.scrollViewport(.{ .delta = -1 });
    try testBuild(&t, &snap);
    try testing.expectEqualStrings("2\n3\n4", snap.text.items);
    try testing.expectEqual(snap.widths.items.len, snap.caret);
}

test "a11y text: rebuilding into a used snapshot replaces it" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    try t.printString("first");

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    t.eraseDisplay(.complete, false);
    t.setCursorPos(1, 1);
    try t.printString("2nd");
    try testBuild(&t, &snap);

    try testing.expectEqualStrings("2nd\n", snap.text.items);
}
