//! Builds the flat UTF-8 text snapshot of a terminal viewport that
//! accessibility clients (AT-SPI on Linux) read.
//!
//! This lives outside of any apprt implementation so the viewport walk
//! can be unit tested and benchmarked without standing up a live GTK
//! surface and an AT-SPI bus. `src/benchmark/A11yText.zig` drives it
//! directly; `apprt/gtk/class/surface_a11y.zig` drives it under the
//! renderer mutex on every rendered frame while an AT client is attached.
//!
//! The snapshot is a plain grid render: one line per viewport row, rows
//! joined by `\n`, trailing blanks on a row dropped and interior blanks
//! kept as spaces so columns still line up. `offsets.zig` is the
//! companion module that navigates the result.
//!
//! IMPORTANT: every offset produced here that is destined for an AT
//! client is in UTF-8 *codepoints*, not bytes. `Result.cursor_byte` is
//! the one exception and is explicitly named as such; convert it with
//! `offsets.utf8CpCount` before handing it out.

const std = @import("std");
const terminal = @import("../terminal/main.zig");
const offsets = @import("offsets.zig");

pub const Options = struct {
    /// Where to record how many columns each emitted codepoint occupies
    /// (`offsets.CellWidths`). One byte is written per codepoint
    /// appended to the text, so the two stay index-aligned: 2 for a
    /// double-width cell, 0 for a combining mark that shares its base
    /// character's cell, 1 otherwise.
    ///
    /// This is the only place the mapping is knowable: the cell walk is
    /// what sees `cell.wide`, and the text alone cannot be re-measured
    /// afterwards without guessing at the terminal's grapheme-width
    /// method. Callers that only need the text (the per-frame change
    /// probe, the benchmark) leave it null and pay nothing.
    ///
    /// Like the text, this stream is appended to, not cleared, so a
    /// caller reusing a buffer must clear it or the widths drift out of
    /// alignment with the text built by this call.
    widths: ?*std.Io.Writer = null,
};

pub const Result = struct {
    /// Byte offset of the cursor, counted from the first byte this walk
    /// writes, or null if the cursor row wasn't part of the viewport.
    /// Callers anchor a null at end-of-text. A caller that starts from
    /// an empty buffer (all of them do) can read this as a buffer
    /// offset directly.
    cursor_byte: ?usize,

    /// Total codepoints appended to the buffer by this walk.
    cp_count: usize,
};

/// The snapshot under construction: the text, the per-codepoint column
/// widths that must stay index-aligned with it, and the running codepoint
/// count.
///
/// Every append goes through here so the three cannot drift apart. They
/// used to be advanced by hand at each append site, which is four places
/// that all had to agree, and a drift silently shifts every column lookup
/// after the offending codepoint. That is the failure mode that put a routed
/// caret inside the character to the left of the one it named.
const Snapshot = struct {
    text: *std.Io.Writer,
    widths: ?*std.Io.Writer,
    cp_count: usize = 0,
    /// Bytes written to `text` so far. Tracked here rather than asked of
    /// the writer, because a writer has no stream position: `Writer.end`
    /// is an index into its internal buffer and resets when a draining
    /// implementation flushes.
    bytes: usize = 0,

    /// Byte offset of the next codepoint to be appended.
    fn end(self: Snapshot) usize {
        return self.bytes;
    }

    /// Append `n` copies of an ASCII byte, each occupying `columns`
    /// screen columns.
    fn addAscii(
        self: *Snapshot,
        byte: u8,
        columns: u8,
        n: usize,
    ) std.Io.Writer.Error!void {
        try self.text.splatByteAll(byte, n);
        self.bytes += n;
        try self.advance(columns, n);
    }

    /// Append one character: a base codepoint occupying `columns` screen
    /// columns, plus any combining marks that share its cell.
    fn addCharacter(
        self: *Snapshot,
        base: u21,
        graphemes: ?[]const u21,
        columns: u8,
    ) std.Io.Writer.Error!void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(base, &buf) catch {
            // Shouldn't happen, since the terminal stores validated
            // scalars, but if one does reach us it still has to occupy
            // its cell,
            // or every offset after it shifts. Its combining marks go
            // with it; they have nothing left to combine with.
            return self.addAscii('?', columns, 1);
        };
        try self.text.writeAll(buf[0..n]);
        self.bytes += n;
        try self.advance(columns, 1);

        for (graphemes orelse return) |cp| {
            const gn = std.unicode.utf8Encode(cp, &buf) catch continue;
            try self.text.writeAll(buf[0..gn]);
            self.bytes += gn;
            // Part of the base character's cell: extra codepoints, no
            // extra columns.
            try self.advance(0, 1);
        }
    }

    fn advance(self: *Snapshot, columns: u8, n: usize) std.Io.Writer.Error!void {
        if (self.widths) |w| try w.splatByteAll(columns, n);
        self.cp_count += n;
    }
};

/// Walk the viewport of `screen` and write its text to `writer`.
///
/// The stream is appended to, not cleared, so callers reusing a buffer
/// must clear it themselves.
pub fn build(
    writer: *std.Io.Writer,
    screen: *terminal.Screen,
    opts: Options,
) std.Io.Writer.Error!Result {
    const pages = &screen.pages;
    const viewport_rows: usize = pages.rows;

    var snap: Snapshot = .{
        .text = writer,
        .widths = opts.widths,
    };

    // Where the AT-SPI caret belongs. Null until the walk reaches the
    // cursor's row, and still null afterwards if that row never came out
    // of the iterator.
    var cursor_byte: ?usize = null;
    const cursor_x = screen.cursor.x;
    const cursor_y = screen.cursor.y;

    const tl_pin = pages.getTopLeft(.viewport);
    var row_it = tl_pin.rowIterator(.right_down, null);
    var row_idx: usize = 0;
    while (row_idx < viewport_rows) : (row_idx += 1) {
        if (row_idx > 0) {
            // A row separator, not a cell: it occupies no column, and
            // column math never crosses it.
            try snap.addAscii('\n', 0, 1);
        }

        const pin = row_it.next() orelse continue;
        const is_cursor_row = row_idx == cursor_y;

        const cells = pin.cells(.all);

        // A cursor on the tail half of a wide character belongs to the
        // character itself, which occupies the preceding column. A spacer
        // has no text and is skipped without accumulating a blank, so
        // leaving it to the deferred blank-run path below would never
        // resolve it and the caret would fall through to end-of-row.
        // `spacer_head` is deliberately not folded in: its wide character
        // lives on the *next* row, so end-of-row is the right answer there.
        const row_cursor_x = if (is_cursor_row and
            cursor_x > 0 and
            cursor_x < cells.len and
            cells[cursor_x].wide == .spacer_tail)
            cursor_x - 1
        else
            cursor_x;

        // Accumulate empty cells so runs of trailing empties drop off the
        // end of the row, but intermediate gaps still get emitted as
        // spaces to preserve column positions. This matches what
        // `ScreenFormatter` does for non-trailing blanks.
        var blank_cells: usize = 0;
        // Pending cursor position when the cursor lands on a blank cell:
        // index into the current blank run where the cursor sits.
        // Resolved to an absolute byte offset either when the blanks
        // flush (inside the about-to-be-emitted space run) or at
        // end-of-row when the blanks get eaten as trailing (= end of the
        // emitted text).
        var cursor_blank_idx: ?usize = null;
        for (0..cells.len) |col| {
            const cell = &cells[col];

            // Record the cursor position before writing the cell at
            // `cursor_x`, so the offset points AT that cell. For blank
            // cells we defer: capture the blank-run index and resolve on
            // flush or end-of-row.
            if (is_cursor_row and col == row_cursor_x) {
                if (cell.hasText()) {
                    cursor_byte = snap.end();
                } else {
                    cursor_blank_idx = blank_cells;
                }
            }

            switch (cell.wide) {
                .spacer_tail, .spacer_head => continue,
                .narrow, .wide => {},
            }

            if (!cell.hasText()) {
                blank_cells += 1;
                continue;
            }

            // Flush accumulated blanks as spaces, one column each.
            if (blank_cells > 0) {
                // Resolve a cursor that landed inside this blank run to
                // its column within the about-to-be-emitted spaces.
                if (cursor_blank_idx) |idx| {
                    cursor_byte = snap.end() + idx;
                    cursor_blank_idx = null;
                }
                try snap.addAscii(' ', 1, blank_cells);
                blank_cells = 0;
            }

            // Columns this cell covers on screen. `.wide` cells are
            // followed by a `.spacer_tail` that the switch above skipped,
            // so the character is one codepoint standing in for two
            // columns, which is the whole reason widths cannot be recovered from
            // the text later.
            const cell_columns: u8 = if (cell.wide == .wide) 2 else 1;

            try snap.addCharacter(
                cell.codepoint(),
                if (cell.hasGrapheme()) pin.grapheme(cell) else null,
                cell_columns,
            );
        }

        // If the cursor is past the last column we emitted (trailing
        // blanks, or a cursor beyond the row end), anchor to end-of-row.
        if (is_cursor_row and row_cursor_x >= cells.len) {
            cursor_byte = snap.end();
        }

        // The cursor landed inside a blank run that never flushed, so those
        // cells are trailing and got eaten. Anchor to the end of the text
        // emitted on this row.
        if (cursor_blank_idx != null) {
            cursor_byte = snap.end();
            cursor_blank_idx = null;
        }
    }

    return .{
        .cursor_byte = cursor_byte,
        .cp_count = snap.cp_count,
    };
}

const testing = std.testing;

test "a11y text: rows joined by newline, trailing blanks trimmed" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    try t.printString("hello");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("world");

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    const result = try build(&buffer.writer, t.screens.active, .{});

    // Row 2 is empty, so it contributes its leading '\n' and nothing else.
    try testing.expectEqualStrings("hello\nworld\n", buffer.written());
    try testing.expectEqual(@as(usize, 12), result.cp_count);
}

test "a11y text: widths report the columns each codepoint covers" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 2 });
    defer t.deinit(alloc);

    // Three double-width characters between narrow ones. The wide cells
    // each get a spacer the walk skips, so the text is one codepoint per
    // character while the row is 5 + 6 + 5 columns wide.
    try t.printString("wide 日本語 tail");

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();
    var widths: std.Io.Writer.Allocating = .init(alloc);
    defer widths.deinit();

    const result = try build(
        &buffer.writer,
        t.screens.active,
        .{ .widths = &widths.writer },
    );

    // One width per codepoint, or every lookup past the drift is wrong.
    try testing.expectEqual(result.cp_count, widths.written().len);

    // "wide " then 日本語 then " tail", plus the row separator.
    try testing.expectEqualSlices(
        u8,
        &.{ 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 0 },
        widths.written(),
    );

    // The payoff: 't' of "tail" is codepoint 9 but column 12. Reading the
    // codepoint index as a column is what put a routed caret three cells
    // to the left, inside 語.
    const t_byte = std.mem.indexOf(u8, buffer.written(), "tail").?;
    const cp_idx = offsets.utf8CpCount(buffer.written()[0..t_byte]);
    try testing.expectEqual(@as(usize, 9), cp_idx);
    try testing.expectEqual(
        @as(u32, 12),
        offsets.cpToGrid(buffer.written(), .{ .per_cp = widths.written() }, cp_idx).col,
    );
}

test "a11y text: recording widths does not change the text" {
    // The per-frame change probe builds without widths and compares the
    // result against the last notified snapshot, which was built *with*
    // them. That gate is only valid if the two paths agree byte for byte.
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 3 });
    defer t.deinit(alloc);

    try t.printString("héllo 日本語");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("  spaced  out");

    var with: std.Io.Writer.Allocating = .init(alloc);
    defer with.deinit();
    var widths: std.Io.Writer.Allocating = .init(alloc);
    defer widths.deinit();
    const with_result = try build(
        &with.writer,
        t.screens.active,
        .{ .widths = &widths.writer },
    );

    var without: std.Io.Writer.Allocating = .init(alloc);
    defer without.deinit();
    const without_result = try build(&without.writer, t.screens.active, .{});

    try testing.expectEqualStrings(with.written(), without.written());
    try testing.expectEqual(with_result.cp_count, without_result.cp_count);
    try testing.expectEqual(with_result.cursor_byte, without_result.cursor_byte);
}

test "a11y text: intermediate blanks preserved as spaces" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    try t.printString("ab");
    t.setCursorPos(1, 6);
    try t.printString("cd");

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    _ = try build(&buffer.writer, t.screens.active, .{});
    try testing.expectEqualStrings("ab   cd", buffer.written());
}

test "a11y text: cursor anchors past trailing blanks" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    try t.printString("hi");
    t.carriageReturn();
    try t.linefeed();
    try t.printString("abc");

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    const result = try build(&buffer.writer, t.screens.active, .{});

    // "hi\nabc", with the cursor on the blank after "abc". That is
    // trailing, so it anchors at end-of-text.
    try testing.expectEqualStrings("hi\nabc", buffer.written());
    try testing.expectEqual(@as(usize, 6), result.cursor_byte.?);
}

test "a11y text: cursor inside an interior blank run lands on its column" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    try t.printString("ab");
    t.setCursorPos(1, 7);
    try t.printString("cd");
    // Park the cursor on column 4 (0-based 3), inside the blank gap that
    // gets flushed as spaces rather than eaten as trailing.
    t.setCursorPos(1, 4);

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    const result = try build(&buffer.writer, t.screens.active, .{});

    try testing.expectEqualStrings("ab    cd", buffer.written());
    // Byte 3 is the second of the four spaces, the cell the cursor is
    // on, not the start or the end of the run.
    try testing.expectEqual(@as(usize, 3), result.cursor_byte.?);
}

test "a11y text: cursor on a wide character's spacer lands on the character" {
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    // 日 occupies columns 2 and 3; column 3 is its spacer tail.
    try t.printString("ab日cd");
    t.setCursorPos(1, 4);

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    const result = try build(&buffer.writer, t.screens.active, .{});

    try testing.expectEqualStrings("ab日cd", buffer.written());
    // The cursor is visually sitting on 日, so it must resolve to that
    // character's own offset. A spacer has no text and is skipped without
    // accumulating a blank, so the deferred blank-run path can never
    // resolve it and it would otherwise fall through to end-of-row.
    try testing.expectEqual(@as(usize, 2), result.cursor_byte.?);
}
