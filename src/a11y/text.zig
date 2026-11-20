//! Builds the flat UTF-8 text snapshot of a terminal viewport that
//! accessibility clients (AT-SPI on Linux) read.
//!
//! This lives outside of any apprt implementation so the snapshot can be
//! unit tested and benchmarked without standing up a live GTK surface
//! and an AT-SPI bus. `src/benchmark/A11yText.zig` drives it directly;
//! `apprt/gtk/class/surface_a11y.zig` drives it under the renderer mutex
//! once per rendered frame while an AT client is attached.
//!
//! The text itself comes from the terminal's own plain-text formatter
//! (`terminal.formatter`): one line per viewport row, rows joined by
//! `\n`, trailing blanks on a row dropped and interior blanks kept as
//! spaces so columns still line up. What this module adds on top is
//! what an AT client needs and the formatter does not provide: every
//! viewport row present even when it is blank, the columns each
//! codepoint covers, and the caret. `offsets.zig` is the companion
//! module that navigates the result.
//!
//! IMPORTANT: every offset produced here that is destined for an AT
//! client is in UTF-8 *codepoints*, not bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const formatter = terminal.formatter;
const unicode = @import("../unicode/main.zig");
const offsets = @import("offsets.zig");

/// One viewport snapshot. Built in place by `build`, which reuses the
/// buffers, so a long-lived snapshot stops allocating once it has grown
/// to the viewport's size.
pub const Snapshot = struct {
    /// The viewport text, one line per viewport row.
    text: std.ArrayList(u8) = .empty,

    /// How many columns each codepoint of `text` covers
    /// (`offsets.CellWidths`), index-aligned with the codepoints: 2 for
    /// a double-width cell, 0 for a combining mark that shares its base
    /// character's cell and for the row separator, 1 otherwise.
    ///
    /// The text alone cannot be re-measured afterwards without guessing
    /// at the terminal's grapheme-width method, so these come from the
    /// cells the formatter read.
    widths: std.ArrayList(u8) = .empty,

    /// The caret, as a codepoint offset into `text`. A cursor outside the
    /// viewport (scrolled back far enough) anchors at the end of the text.
    caret: usize = 0,

    /// Scratch for the formatter's byte-to-cell map. Retained only so it
    /// does not reallocate on every build.
    pin_map: formatter.PinMap.Map = .empty,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        self.text.deinit(alloc);
        self.widths.deinit(alloc);
        self.pin_map.deinit(alloc);
        self.* = undefined;
    }

    /// The widths in the form `offsets` takes them.
    pub fn cellWidths(self: *const Snapshot) offsets.CellWidths {
        return .{ .per_cp = self.widths.items };
    }

    /// Whether an AT client would see any difference between the two.
    /// Widths follow from the text and the cells under it, so a change
    /// that matters to a client always shows in the text or the caret.
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
        // Not trimmed: a space the program printed at the end of a row
        // is text. A prompt ends in one, and a space typed at the end
        // of the line has to show up in the text, or there is neither a
        // text change nor a caret move to echo it with. Cells that were
        // never written (or were erased) are still dropped.
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

    // The formatter drops blank rows at the bottom. Put them back: the
    // line index is the row index for extents and caret math, and a
    // cursor sitting on one of those rows needs its line to exist.
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

    // The cell the previous codepoint came from, so that the extra
    // codepoints of a grapheme, which all map to their base character's
    // cell, cover no columns of their own.
    var prev: ?terminal.Pin = null;

    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        defer i += len;

        if (text[i] == '\n') {
            // A row separator, not a cell: it occupies no column, and
            // column math never crosses it.
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

        // A wide character is followed by a spacer the formatter skips,
        // so it is one codepoint standing in for two columns, which is
        // the whole reason widths cannot be recovered from the text.
        const wide = pin.rowAndCell().cell.wide == .wide;
        snap.widths.appendAssumeCapacity(if (wide) 2 else 1);
    }
}

/// The codepoint offset of the character under the cursor.
///
/// The cursor's column is matched against the columns each codepoint
/// covers, which resolves every case the text alone cannot: a cursor
/// on the tail half of a wide character lands on that character, one
/// inside a run of interior blanks lands on its own space, and one
/// past the last character of its row (on trailing blanks the text
/// does not keep) lands at the end of that row.
fn caretOffset(snap: *const Snapshot, screen: *const terminal.Screen) usize {
    const text = snap.text.items;
    const widths = snap.widths.items;
    const cp_count = widths.len;

    // The cursor's row counts from the top of the active area, which is
    // not the top of the viewport once the user scrolls back. A cursor
    // that is not on screen at all anchors at the end of the text.
    const pt = screen.pages.pointFromPin(
        .viewport,
        screen.cursor.page_pin.*,
    ) orelse return cp_count;
    const cursor = pt.coord();
    if (cursor.y >= screen.pages.rows) return cp_count;

    // Find the first codepoint of the cursor's line.
    var cp: usize = 0;
    var byte: usize = 0;
    var row: usize = 0;
    while (row < cursor.y) : (cp += 1) {
        if (byte >= text.len) return cp_count;
        if (text[byte] == '\n') row += 1;
        byte += std.unicode.utf8ByteSequenceLength(text[byte]) catch 1;
    }

    // Walk the line until a codepoint covers the cursor's column.
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
    // One width per codepoint, or every lookup past the drift is wrong.
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

    // Row 3 is empty but still gets its line, so it contributes the
    // separator in front of it and nothing else. The cells after each
    // word were never written and are dropped.
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
    // The cursor is on the cell after the typed space, which was never
    // written: the end of the row.
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
    // The cursor sits on the last, blank row, which still exists.
    try testing.expectEqual(snap.widths.items.len, snap.caret);
}

test "a11y text: widths report the columns each codepoint covers" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    // Three double-width characters between narrow ones. The wide cells
    // each get a spacer the formatter skips, so the text is one
    // codepoint per character while the row is 5 + 6 + 5 columns wide.
    try t.printString("wide 日本語 tail");

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    // "wide " then 日本語 then " tail", plus the separator of row 2.
    try testing.expectEqualSlices(
        u8,
        &.{ 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 0 },
        snap.widths.items,
    );

    // The payoff: 't' of "tail" is codepoint 9 but column 12. Reading the
    // codepoint index as a column is what put a routed caret three cells
    // to the left, inside 語.
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

    // 'e' followed by U+0301 COMBINING ACUTE ACCENT: one cell, two
    // codepoints.
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

    // "hi\nabc\n", with the cursor on the blank after "abc". That is
    // trailing, so it anchors at the end of its row, not of the text.
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
    // Park the cursor on column 4 (0-based 3), inside the blank gap that
    // gets written as spaces rather than dropped as trailing.
    t.setCursorPos(1, 4);

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    try testing.expectEqualStrings("ab    cd", snap.text.items);
    // The second of the four spaces, the cell the cursor is on, not the
    // start or the end of the run.
    try testing.expectEqual(3, snap.caret);
}

test "a11y text: cursor on a wide character's spacer lands on the character" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    // 日 occupies columns 2 and 3; column 3 is its spacer tail.
    try t.printString("ab日cd");
    t.setCursorPos(1, 4);

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);
    try testBuild(&t, &snap);

    try testing.expectEqualStrings("ab日cd", snap.text.items);
    // The cursor is visually sitting on 日, so it resolves to that
    // character's own offset.
    try testing.expectEqual(2, snap.caret);
}

test "a11y text: the caret follows the cursor's row when scrolled back" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    // Five lines into three rows: "1" and "2" scroll into history.
    for (0..5) |i| {
        if (i > 0) {
            t.carriageReturn();
            try t.linefeed();
        }
        try t.print('1' + @as(u21, @intCast(i)));
    }

    var snap: Snapshot = .{};
    defer snap.deinit(alloc);

    // At the bottom the cursor is on the last row, after "5".
    try testBuild(&t, &snap);
    try testing.expectEqualStrings("3\n4\n5", snap.text.items);
    try testing.expectEqual(5, snap.caret);

    // Scrolled back by one, the cursor's row is the last viewport row
    // still: the viewport moved, the cursor did not. Counting its row
    // from the top of the active area would put the caret after "4".
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
