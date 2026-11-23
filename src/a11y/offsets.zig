//! Offset math over the text snapshot built by `text.zig`: converting
//! between bytes, codepoints and grid cells, and diffing two snapshots.
//! Accessibility clients count offsets in codepoints.

const std = @import("std");
const utf8 = @import("../unicode/main.zig").utf8;

pub const ByteOffset = usize;
pub const CodepointOffset = usize;
pub const GridCoordinate = u32;

/// The common ends of two snapshots, in bytes. Everything between them
/// changed. Both lengths fall on codepoint boundaries.
pub const PrefixSuffixDiff = struct {
    prefix_len: ByteOffset,
    suffix_len: ByteOffset,

    /// Bytes removed from `old` plus bytes inserted from `new`.
    pub fn cost(self: PrefixSuffixDiff, old_len: usize, new_len: usize) usize {
        const unchanged = self.prefix_len + self.suffix_len;
        return (old_len - unchanged) + (new_len - unchanged);
    }
};

/// The common prefix and suffix of `old_text` and `new_text`, moved back
/// to codepoint boundaries. Two characters can share leading bytes, so a
/// byte compare can stop inside one.
pub fn prefixSuffix(old_text: []const u8, new_text: []const u8) PrefixSuffixDiff {
    var prefix: usize = 0;
    const min_len = @min(old_text.len, new_text.len);
    while (prefix < min_len and old_text[prefix] == new_text[prefix]) : (prefix += 1) {}

    // The suffix must not overlap the prefix.
    var suffix: usize = 0;
    const max_suffix = @min(old_text.len - prefix, new_text.len - prefix);
    while (suffix < max_suffix and
        old_text[old_text.len - 1 - suffix] == new_text[new_text.len - 1 - suffix]) : (suffix += 1)
    {}

    // Move both back to a codepoint boundary. `prefix` can equal
    // `old_text.len`, which is already a boundary.
    while (prefix > 0 and prefix < old_text.len and
        utf8.isContinuation(old_text[prefix])) : (prefix -= 1)
    {}
    while (suffix > 0 and utf8.isContinuation(old_text[old_text.len - suffix])) : (suffix -= 1) {}

    return .{ .prefix_len = prefix, .suffix_len = suffix };
}

/// The smallest K, just past a `\n` in `old_text`, such that
/// `new_text` starts with `old_text[K..]`: the text scrolled up by the
/// lines before K. Returns 0 if there is none. Swap the arguments to find
/// a scroll down.
pub fn scrollK(old_text: []const u8, new_text: []const u8) ByteOffset {
    var search: usize = 0;
    while (std.mem.indexOfScalarPos(u8, old_text, search, '\n')) |i| {
        search = i + 1;
        const boundary = i + 1;
        const remainder = old_text.len - boundary;
        // An empty remainder would match any text ending in `\n`.
        if (remainder == 0) continue;
        if (remainder > new_text.len) continue;
        if (std.mem.eql(u8, new_text[0..remainder], old_text[boundary..])) {
            return boundary;
        }
    }
    return 0;
}

/// How to describe a viewport change to an AT client.
pub const Diff = union(enum) {
    none,

    /// Whole lines scrolled up: the first `k` bytes left the top and new
    /// text arrived at the bottom, as with command output.
    shift_up: ByteOffset,

    /// Whole lines scrolled down: `j` new bytes arrived at the top and the
    /// end fell off the bottom, as when scrolling back.
    shift_down: ByteOffset,

    /// Replace the bytes between the common prefix and suffix.
    replace: PrefixSuffixDiff,
};

/// Choose the description of the change from `old_text` to `new_text`
/// that sends the fewest bytes to the AT client.
///
/// Comparing costs is enough to pick the right one. When lines scroll,
/// almost every row changes position, so a prefix/suffix replace costs
/// nearly the whole viewport and the shift is far cheaper. When the user
/// types `x` at a `$ ` prompt and earlier rows also end in `$ `,
/// `scrollK` finds a false shift, but the replace is cheaper.
///
/// A tie between a shift and a replace goes to the replace, and a tie
/// between the two shifts goes to `shift_up`.
pub fn chooseDiff(old_text: []const u8, new_text: []const u8) Diff {
    const ps = prefixSuffix(old_text, new_text);
    const ps_total = ps.cost(old_text.len, new_text.len);

    // Bytes removed from the top plus bytes added at the bottom. A
    // non-zero `scrollK(a, b)` means `a.len - K <= b.len`, so the
    // subtractions here and below cannot underflow.
    const k = scrollK(old_text, new_text);
    const up_total = if (k > 0)
        k + (new_text.len - (old_text.len - k))
    else
        std.math.maxInt(usize);

    // Bytes added at the top plus bytes removed from the bottom.
    const j = scrollK(new_text, old_text);
    const down_total = if (j > 0)
        j + (old_text.len - (new_text.len - j))
    else
        std.math.maxInt(usize);

    if (k > 0 and up_total < ps_total and up_total <= down_total) {
        return .{ .shift_up = k };
    }
    if (j > 0 and down_total < ps_total) return .{ .shift_down = j };
    if (ps_total > 0) return .{ .replace = ps };
    return .none;
}

/// How many columns each codepoint of a snapshot covers: 2 for a wide
/// character, 0 for a combining mark, 1 otherwise. `text.build` takes
/// these from the terminal's cells, since the width can't be worked out
/// from the text alone.
pub const CellWidths = struct {
    /// Indexed by codepoint. Indices past the end read as 1.
    per_cp: []const u8 = &.{},

    /// One column per codepoint, for text without cell data.
    pub const uniform: CellWidths = .{};

    pub fn at(self: CellWidths, cp_idx: CodepointOffset) GridCoordinate {
        if (cp_idx >= self.per_cp.len) return 1;
        return self.per_cp[cp_idx];
    }
};

/// Where a row begins, in bytes and in codepoints.
const RowStart = struct {
    byte: ByteOffset,
    cp: CodepointOffset,
};

/// The start of `row`, or null when the snapshot has fewer rows.
fn rowStart(text: []const u8, row: GridCoordinate) ?RowStart {
    if (row == 0) return .{ .byte = 0, .cp = 0 };

    var byte: usize = 0;
    var cp: usize = 0;
    var seen: u32 = 0;
    while (byte < text.len) {
        const is_newline = text[byte] == '\n';
        byte += utf8.cpLen(text[byte]);
        cp += 1;
        if (!is_newline) continue;
        seen += 1;
        if (seen == row) return .{ .byte = byte, .cp = cp };
    }
    return null;
}

/// The start of the last row. If the text ends in `\n`, that is the end
/// of the text.
fn lastRowStart(text: []const u8) RowStart {
    var out: RowStart = .{ .byte = 0, .cp = 0 };
    var byte: usize = 0;
    var cp: usize = 0;
    while (byte < text.len) {
        const is_newline = text[byte] == '\n';
        byte += utf8.cpLen(text[byte]);
        cp += 1;
        if (is_newline) out = .{ .byte = byte, .cp = cp };
    }
    return out;
}

/// The codepoint in column `col` of the row at `start`. A column past
/// the end of the row gives the end of the row.
fn cpAtColumn(
    text: []const u8,
    widths: CellWidths,
    start: RowStart,
    col: GridCoordinate,
) CodepointOffset {
    var byte = start.byte;
    var cp = start.cp;
    var column: u32 = 0;
    while (byte < text.len and text[byte] != '\n') {
        const w = widths.at(cp);
        // A column gives its base character, not a combining mark.
        if (w > 0 and col < column + w) return cp;
        column += w;
        byte += utf8.cpLen(text[byte]);
        cp += 1;
    }
    return cp;
}

/// The column of codepoint `cp_idx` in the row at `start`. A combining
/// mark gives the column of its base character. Past the end of the row
/// gives the row's width.
fn columnOfCp(
    text: []const u8,
    widths: CellWidths,
    start: RowStart,
    cp_idx: CodepointOffset,
) GridCoordinate {
    var byte = start.byte;
    var cp = start.cp;
    var column: u32 = 0;
    var cell_start: u32 = 0;
    while (byte < text.len and text[byte] != '\n' and cp < cp_idx) {
        const w = widths.at(cp);
        if (w > 0) cell_start = column;
        column += w;
        byte += utf8.cpLen(text[byte]);
        cp += 1;
    }

    const in_row = byte < text.len and text[byte] != '\n';
    if (in_row and widths.at(cp_idx) == 0) return cell_start;
    return column;
}

/// The codepoint at (row, col), or null when `row` is past the last row.
/// Used for selections, where a row that scrolled out has no offset.
pub fn rowColToCp(
    text: []const u8,
    widths: CellWidths,
    row: GridCoordinate,
    col: GridCoordinate,
) ?CodepointOffset {
    const start = rowStart(text, row) orelse return null;
    return cpAtColumn(text, widths, start, col);
}

/// Like `rowColToCp`, but a row past the end gives the last row. Used for
/// points, which should always land somewhere.
pub fn offsetAtGrid(
    text: []const u8,
    widths: CellWidths,
    want_row: GridCoordinate,
    col: GridCoordinate,
) CodepointOffset {
    const start = rowStart(text, want_row) orelse lastRowStart(text);
    return cpAtColumn(text, widths, start, col);
}

/// A codepoint's byte offset, its row, and where that row starts.
const Location = struct {
    /// Clamped to the end of the text.
    cp: CodepointOffset,
    byte: ByteOffset,
    row: GridCoordinate,
    row_start: RowStart,
};

/// Walk to codepoint `cp_idx`, or to the end of `text`.
fn locate(text: []const u8, cp_idx: CodepointOffset) Location {
    var byte: usize = 0;
    var cp: usize = 0;
    var row: u32 = 0;
    var row_start: RowStart = .{ .byte = 0, .cp = 0 };
    while (byte < text.len and cp < cp_idx) {
        const is_newline = text[byte] == '\n';
        byte += utf8.cpLen(text[byte]);
        cp += 1;
        if (is_newline) {
            row += 1;
            row_start = .{ .byte = byte, .cp = cp };
        }
    }
    return .{ .cp = cp, .byte = byte, .row = row, .row_start = row_start };
}

/// The grid position of a codepoint; the inverse of `rowColToCp`. Past
/// the end of the text gives the end of the last row.
pub fn cpToGrid(text: []const u8, widths: CellWidths, cp_idx: CodepointOffset) GridPos {
    const loc = locate(text, cp_idx);
    return .{
        .row = loc.row,
        .col = columnOfCp(text, widths, loc.row_start, loc.cp),
    };
}

pub const GridPos = struct {
    row: GridCoordinate,
    col: GridCoordinate,
};

/// The grid cell under a widget-space point. Negative, infinite and NaN
/// values give 0, and huge ones are capped, so the conversion to integer
/// is always safe. Callers clamp the result to the text.
pub fn pointToGrid(x: f32, y: f32, cell_w: f32, cell_h: f32) GridPos {
    const max_cells: f32 = 1_000_000;
    const row_f = y / cell_h;
    const col_f = x / cell_w;
    const row_clamped: f32 = if (std.math.isFinite(row_f))
        @max(0, @min(row_f, max_cells))
    else
        0;
    const col_clamped: f32 = if (std.math.isFinite(col_f))
        @max(0, @min(col_f, max_cells))
    else
        0;
    return .{
        .row = @intFromFloat(row_clamped),
        .col = @intFromFloat(col_clamped),
    };
}

/// The cells covered by a codepoint range. Always one row high: a range
/// over several rows gives its first row.
pub const GridRect = struct {
    row: GridCoordinate,
    col: GridCoordinate,
    width_cols: GridCoordinate,
};

/// The cells covered by the codepoints `[start_cp, end_cp)`. The width is
/// at least 1, so an empty range still has a rect to point at.
pub fn extentsCells(
    text: []const u8,
    widths: CellWidths,
    start_cp: CodepointOffset,
    end_cp: CodepointOffset,
) GridRect {
    const loc = locate(text, start_cp);

    var width_cols: u32 = 0;
    var byte = loc.byte;
    var cp = loc.cp;
    while (cp < end_cp and byte < text.len and text[byte] != '\n') {
        width_cols += widths.at(cp);
        byte += utf8.cpLen(text[byte]);
        cp += 1;
    }
    if (width_cols == 0) width_cols = 1;

    return .{
        .row = loc.row,
        .col = columnOfCp(text, widths, loc.row_start, loc.cp),
        .width_cols = width_cols,
    };
}

/// GTK's sentence and paragraph granularities map to `line`.
pub const Granularity = enum {
    character,
    word,
    line,
};

pub const Contents = struct {
    start_cp: CodepointOffset,
    end_cp: CodepointOffset,
    bytes: []const u8,
};

/// The character, word or line that contains codepoint `offset_cp`.
pub fn contentsAt(
    text: []const u8,
    offset_cp: CodepointOffset,
    granularity: Granularity,
) Contents {
    const text_cp_count = utf8.cpCount(text);
    const off_cp = @min(offset_cp, text_cp_count);
    const off_byte = utf8.cpToByte(text, off_cp);

    switch (granularity) {
        .character => {
            if (off_cp >= text_cp_count) return .{
                .start_cp = text_cp_count,
                .end_cp = text_cp_count,
                .bytes = text[text.len..],
            };
            const end_byte = off_byte + utf8.cpLen(text[off_byte]);
            return .{
                .start_cp = off_cp,
                .end_cp = off_cp + 1,
                .bytes = text[off_byte..end_byte],
            };
        },
        .word => {
            // As in GTK, a word runs to the start of the next word, so it
            // includes the spaces after it. A word never crosses a row:
            // the last word of a row ends after its newline, and spaces
            // at the start of a row are a range of their own.
            const isWordByte = struct {
                fn f(b: u8) bool {
                    return b != ' ' and b != '\n';
                }
            }.f;

            // In a run of spaces, go back to the word before it.
            var ws_byte: usize = off_byte;
            if (ws_byte == text.len or !isWordByte(text[ws_byte])) {
                while (ws_byte > 0 and text[ws_byte - 1] == ' ') ws_byte -= 1;
            }
            while (ws_byte > 0 and isWordByte(text[ws_byte - 1])) ws_byte -= 1;

            var we_byte: usize = off_byte;
            while (we_byte < text.len and isWordByte(text[we_byte])) we_byte += 1;
            while (we_byte < text.len and text[we_byte] == ' ') we_byte += 1;
            if (we_byte < text.len and text[we_byte] == '\n') we_byte += 1;

            return .{
                .start_cp = utf8.cpCount(text[0..ws_byte]),
                .end_cp = utf8.cpCount(text[0..we_byte]),
                .bytes = text[ws_byte..we_byte],
            };
        },
        .line => {
            var ls_byte: usize = off_byte;
            while (ls_byte > 0 and text[ls_byte - 1] != '\n') : (ls_byte -= 1) {}
            var le_byte: usize = off_byte;
            while (le_byte < text.len and text[le_byte] != '\n') : (le_byte += 1) {}
            if (le_byte < text.len) le_byte += 1; // include the newline
            return .{
                .start_cp = utf8.cpCount(text[0..ls_byte]),
                .end_cp = utf8.cpCount(text[0..le_byte]),
                .bytes = text[ls_byte..le_byte],
            };
        },
    }
}

const testing = std.testing;

// Two characters that share their first two bytes.
const box_v = "\u{2502}"; // BOX DRAWINGS LIGHT VERTICAL
const box_t = "\u{251C}"; // BOX DRAWINGS LIGHT VERTICAL AND RIGHT

test "diff: prefixSuffix on a plain single-character edit" {
    const old_text = "hello world";
    const new_text = "hello Xorld";
    const d = prefixSuffix(old_text, new_text);
    try testing.expectEqual(6, d.prefix_len);
    try testing.expectEqual(4, d.suffix_len);
}

test "diff: prefixSuffix pulls back off a shared multi-byte lead" {
    // A byte compare stops 2 bytes into the box character.
    const old_text = "a" ++ box_v ++ "z";
    const new_text = "a" ++ box_t ++ "z";

    const d = prefixSuffix(old_text, new_text);
    try testing.expectEqual(1, d.prefix_len);
    try testing.expect(std.unicode.utf8ValidateSlice(old_text[0..d.prefix_len]));
    try testing.expect(std.unicode.utf8ValidateSlice(old_text[d.prefix_len .. old_text.len - d.suffix_len]));
    try testing.expect(std.unicode.utf8ValidateSlice(new_text[0..d.prefix_len]));
}

test "diff: prefixSuffix when old is a prefix of new" {
    const old_text = "abc";
    const new_text = "abcdef";
    const d = prefixSuffix(old_text, new_text);
    try testing.expectEqual(3, d.prefix_len);
    try testing.expectEqual(0, d.suffix_len);
}

test "diff: prefixSuffix on identical and empty inputs" {
    const same = prefixSuffix("abc", "abc");
    try testing.expectEqual(3, same.prefix_len);
    try testing.expectEqual(0, same.suffix_len);

    const empty = prefixSuffix("", "");
    try testing.expectEqual(0, empty.prefix_len);
    try testing.expectEqual(0, empty.suffix_len);

    const from_empty = prefixSuffix("", "new");
    try testing.expectEqual(0, from_empty.prefix_len);
    try testing.expectEqual(0, from_empty.suffix_len);
}

test "diff: prefix and suffix never overlap" {
    const old_text = "aaaa";
    const new_text = "aa";
    const d = prefixSuffix(old_text, new_text);
    try testing.expect(d.prefix_len + d.suffix_len <= old_text.len);
    try testing.expect(d.prefix_len + d.suffix_len <= new_text.len);
}

test "diff: scrollK detects a whole-line shift" {
    const old_text = "line1\nline2\nline3\n";
    const new_text = "line2\nline3\nline4\n";
    try testing.expectEqual(6, scrollK(old_text, new_text));
}

test "diff: scrollK rejects a trailing-newline-only match" {
    const old_text = "abc\n";
    const new_text = "abz\n";
    try testing.expectEqual(0, scrollK(old_text, new_text));
}

test "diff: scrollK returns 0 with no newline or no match" {
    try testing.expectEqual(0, scrollK("", "anything"));
    try testing.expectEqual(0, scrollK("no newlines", "still none"));
    try testing.expectEqual(0, scrollK("a\nb\n", "totally different"));
}

test "diff: scrollK detects a downward shift with the arguments swapped" {
    const old_text = "line1\nline2\nline3\n";
    const new_text = "line0\nline1\nline2\n";

    try testing.expectEqual(0, scrollK(old_text, new_text));
    try testing.expectEqual(6, scrollK(new_text, old_text));
}

test "diff: choose prefers a shift over replacing the viewport" {
    const old_text = "line1\nline2\nline3\n";
    const new_text = "line2\nline3\nline4\n";
    try testing.expectEqual(Diff{ .shift_up = 6 }, chooseDiff(old_text, new_text));
}

test "diff: choose reports scrolling back as a downward shift" {
    // A replace here would remove and insert almost the whole viewport.
    const old_text = "line1\nline2\nline3\n";
    const new_text = "line0\nline1\nline2\n";

    const ps_total = prefixSuffix(old_text, new_text).cost(old_text.len, new_text.len);
    const down_total = 6 + (old_text.len - (new_text.len - 6));
    try testing.expect(down_total < ps_total);

    try testing.expectEqual(Diff{ .shift_down = 6 }, chooseDiff(old_text, new_text));
}

test "diff: choose handles a multi-line scroll back" {
    const old_text = "c\nd\ne\nf\n";
    const new_text = "a\nb\nc\nd\n";
    try testing.expectEqual(Diff{ .shift_down = 4 }, chooseDiff(old_text, new_text));
}

test "diff: choose keeps typing echo as a replacement" {
    // `scrollK` finds a false shift here, but one typed character is
    // not a scroll.
    const old_text = "$ \n$ \n$ ";
    const new_text = "$ \n$ \n$ x";

    const diff = chooseDiff(old_text, new_text);
    try testing.expect(diff == .replace);
    try testing.expectEqual(8, diff.replace.prefix_len);
    try testing.expectEqual(0, diff.replace.suffix_len);
}

test "diff: choose says nothing for identical snapshots" {
    try testing.expectEqual(Diff.none, chooseDiff("a\nb\n", "a\nb\n"));
    try testing.expectEqual(Diff.none, chooseDiff("", ""));
}

test "diff: choose survives a viewport with no overlap at all" {
    const old_text = "a\nb\nc\n";
    const new_text = "x\ny\nz\n";
    const diff = chooseDiff(old_text, new_text);
    try testing.expect(diff == .replace);
}

test "diff: shift offsets stay on codepoint boundaries" {
    const old_text = "héllo\n日本語\nend\n";
    const new_text = "日本語\nend\ntail\n";

    const diff = chooseDiff(old_text, new_text);
    try testing.expect(diff == .shift_up);
    const k = diff.shift_up;
    try testing.expect(std.unicode.utf8ValidateSlice(old_text[0..k]));
    try testing.expect(std.unicode.utf8ValidateSlice(old_text[k..]));

    const back = chooseDiff(new_text, old_text);
    try testing.expect(back == .shift_down);
    const j = back.shift_down;
    try testing.expect(std.unicode.utf8ValidateSlice(old_text[0..j]));
    try testing.expect(std.unicode.utf8ValidateSlice(old_text[j..]));
}

test "diff: a downward shift describes a reachable edit" {
    // Remove `old[kept..]`, then insert `new[0..j]` at the front.
    const old_text = "line1\nline2\nline3\n";
    const new_text = "line0\nline1\nline2\n";

    const diff = chooseDiff(old_text, new_text);
    const j = diff.shift_down;
    const kept = new_text.len - j;
    try testing.expect(kept <= old_text.len);

    var buf: [64]u8 = undefined;
    const rebuilt = try std.mem.print(&buf, "{s}{s}", .{
        new_text[0..j],
        old_text[0..kept],
    });
    try testing.expectEqualStrings(new_text, rebuilt);
}

test "diff: an upward shift describes a reachable edit" {
    const old_text = "line1\nline2\nline3\n";
    const new_text = "line2\nline3\nline4\n";

    const diff = chooseDiff(old_text, new_text);
    const k = diff.shift_up;

    var buf: [64]u8 = undefined;
    const rebuilt = try std.mem.print(&buf, "{s}{s}", .{
        old_text[k..],
        new_text[old_text.len - k ..],
    });
    try testing.expectEqualStrings(new_text, rebuilt);
}

test "grid: rowColToCp counts codepoints, not bytes" {
    const text = box_v ++ box_v ++ "\nabc";
    // Row 1 starts at byte 7 but at codepoint 3.
    try testing.expectEqual(3, rowColToCp(text, .uniform, 1, 0));
    try testing.expectEqual(5, rowColToCp(text, .uniform, 1, 2));
    try testing.expectEqual(1, rowColToCp(text, .uniform, 0, 1));
}

test "grid: rowColToCp clamps column, fails past the last row" {
    const text = "ab\ncd";
    try testing.expectEqual(5, rowColToCp(text, .uniform, 1, 99));
    try testing.expectEqual(null, rowColToCp(text, .uniform, 7, 0));
}

test "grid: offsetAtGrid clamps instead of failing" {
    const text = "ab\ncd";
    try testing.expectEqual(3, offsetAtGrid(text, .uniform, 1, 0));
    try testing.expectEqual(3, offsetAtGrid(text, .uniform, 7, 0));
    try testing.expectEqual(5, offsetAtGrid(text, .uniform, 7, 99));
}

const wide_row = "日本語ab";
const wide_widths: CellWidths = .{ .per_cp = &.{ 2, 2, 2, 1, 1 } };

test "grid: a wide character spans two columns" {
    // 'a' is codepoint 3 but column 6.
    try testing.expectEqual(3, rowColToCp(wide_row, wide_widths, 0, 6));
    try testing.expectEqual(6, cpToGrid(wide_row, wide_widths, 3).col);

    // Both cells of a wide character give that character.
    try testing.expectEqual(1, rowColToCp(wide_row, wide_widths, 0, 2));
    try testing.expectEqual(1, rowColToCp(wide_row, wide_widths, 0, 3));

    for (0..5) |cp| {
        const col = cpToGrid(wide_row, wide_widths, cp).col;
        try testing.expectEqual(cp, rowColToCp(wide_row, wide_widths, 0, col));
    }
}

test "grid: widths are per row, and rows keep their own columns" {
    const text = "日本\nab";
    const widths: CellWidths = .{ .per_cp = &.{ 2, 2, 0, 1, 1 } };

    try testing.expectEqual(1, rowColToCp(text, widths, 0, 2));
    try testing.expectEqual(3, rowColToCp(text, widths, 1, 0));
    try testing.expectEqual(4, rowColToCp(text, widths, 1, 1));
    try testing.expectEqual(GridPos{ .row = 1, .col = 1 }, cpToGrid(text, widths, 4));
}

test "grid: zero-width codepoints share their base character's cell" {
    // "e" + a combining acute: two codepoints, one column.
    const text = "e\u{0301}x";
    const widths: CellWidths = .{ .per_cp = &.{ 1, 0, 1 } };

    try testing.expectEqual(0, rowColToCp(text, widths, 0, 0));
    try testing.expectEqual(2, rowColToCp(text, widths, 0, 1));
    try testing.expectEqual(1, cpToGrid(text, widths, 2).col);
    // The mark itself reports its base character's column.
    try testing.expectEqual(0, cpToGrid(text, widths, 1).col);
}

test "grid: missing widths degrade to one column per codepoint" {
    const short: CellWidths = .{ .per_cp = &.{2} };
    try testing.expectEqual(1, rowColToCp(wide_row, short, 0, 2));
    try testing.expectEqual(2, rowColToCp(wide_row, short, 0, 3));
    try testing.expectEqual(3, rowColToCp(wide_row, .uniform, 0, 3));
}

test "grid: cpToGrid clamps an offset past the end" {
    const text = "ab\ncd";
    try testing.expectEqual(GridPos{ .row = 1, .col = 2 }, cpToGrid(text, .uniform, 99));
}

test "grid: a newline belongs to the row it terminates" {
    const text = "ab\ncd\nef";
    try testing.expectEqual(GridPos{ .row = 0, .col = 2 }, cpToGrid(text, .uniform, 2));
    try testing.expectEqual(GridPos{ .row = 1, .col = 0 }, cpToGrid(text, .uniform, 3));
    try testing.expectEqual(GridPos{ .row = 1, .col = 2 }, cpToGrid(text, .uniform, 5));
    try testing.expectEqual(GridPos{ .row = 2, .col = 0 }, cpToGrid(text, .uniform, 6));

    try testing.expectEqual(0, extentsCells(text, .uniform, 2, 3).row);
    try testing.expectEqual(1, extentsCells(text, .uniform, 3, 4).row);
}

test "grid: pointToGrid survives negative and non-finite input" {
    const cw: f32 = 10;
    const ch: f32 = 20;

    try testing.expectEqual(GridPos{ .row = 2, .col = 3 }, pointToGrid(35, 55, cw, ch));

    try testing.expectEqual(GridPos{ .row = 0, .col = 0 }, pointToGrid(-500, -500, cw, ch));

    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    try testing.expectEqual(GridPos{ .row = 0, .col = 0 }, pointToGrid(nan, nan, cw, ch));
    try testing.expectEqual(GridPos{ .row = 0, .col = 0 }, pointToGrid(-inf, -inf, cw, ch));
    try testing.expectEqual(GridPos{ .row = 0, .col = 0 }, pointToGrid(inf, inf, cw, ch));

    const huge = pointToGrid(1e30, 1e30, cw, ch);
    try testing.expectEqual(1_000_000, huge.row);
    try testing.expectEqual(1_000_000, huge.col);
}

test "extents: each row reports a distinct row index" {
    const text = "row0\nrow1\nrow2";
    try testing.expectEqual(0, extentsCells(text, .uniform, 0, 1).row);
    try testing.expectEqual(1, extentsCells(text, .uniform, 5, 6).row);
    try testing.expectEqual(2, extentsCells(text, .uniform, 10, 11).row);
}

test "extents: column and width are in cells, not bytes" {
    const text = box_v ++ box_v ++ "abc";
    const r = extentsCells(text, .uniform, 2, 5);
    try testing.expectEqual(0, r.row);
    try testing.expectEqual(2, r.col);
    try testing.expectEqual(3, r.width_cols);
}

test "extents: a wide character is two cells wide and shifts what follows" {
    const wide = extentsCells(wide_row, wide_widths, 2, 3);
    try testing.expectEqual(4, wide.col);
    try testing.expectEqual(2, wide.width_cols);

    const after = extentsCells(wide_row, wide_widths, 3, 5);
    try testing.expectEqual(6, after.col);
    try testing.expectEqual(2, after.width_cols);

    try testing.expectEqual(8, extentsCells(wide_row, wide_widths, 0, 5).width_cols);
}

test "extents: width stops at the row end and never reports zero" {
    const text = "ab\ncdef";
    const spanning = extentsCells(text, .uniform, 0, 6);
    try testing.expectEqual(2, spanning.width_cols);

    const empty = extentsCells(text, .uniform, 1, 1);
    try testing.expectEqual(1, empty.width_cols);

    // A combining mark alone.
    const marks: CellWidths = .{ .per_cp = &.{ 1, 0, 1 } };
    try testing.expectEqual(1, extentsCells("e\u{0301}x", marks, 1, 2).width_cols);
}

test "contents: character granularity returns one whole codepoint" {
    const text = "a" ++ box_v ++ "b";
    const c = contentsAt(text, 1, .character);
    try testing.expectEqual(1, c.start_cp);
    try testing.expectEqual(2, c.end_cp);
    try testing.expectEqualStrings(box_v, c.bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(c.bytes));
}

test "contents: character granularity past the end is empty" {
    const text = "abc";
    const c = contentsAt(text, 99, .character);
    try testing.expectEqual(3, c.start_cp);
    try testing.expectEqual(3, c.end_cp);
    try testing.expectEqualStrings("", c.bytes);
}

test "contents: word granularity runs to the start of the next word" {
    const text = "alpha beta\ngamma";

    // A word takes the space after it.
    const first = contentsAt(text, 2, .word);
    try testing.expectEqualStrings("alpha ", first.bytes);
    try testing.expectEqual(0, first.start_cp);
    try testing.expectEqual(6, first.end_cp);

    // The last word of a row takes the row's newline, and goes no
    // further.
    const mid = contentsAt(text, 7, .word);
    try testing.expectEqualStrings("beta\n", mid.bytes);
    try testing.expectEqual(6, mid.start_cp);
    try testing.expectEqual(11, mid.end_cp);

    // A word bounded by a newline rather than a space, at the end.
    const after_nl = contentsAt(text, 12, .word);
    try testing.expectEqualStrings("gamma", after_nl.bytes);
    try testing.expectEqual(11, after_nl.start_cp);
    try testing.expectEqual(16, after_nl.end_cp);

    // Sitting on the separator resolves to the word to its left.
    const on_space = contentsAt(text, 5, .word);
    try testing.expectEqualStrings("alpha ", on_space.bytes);
}

test "contents: word granularity inside a run of spaces" {
    const text = "foo   bar";

    // Every space of the run belongs to the word before it.
    for (3..6) |off| {
        const c = contentsAt(text, off, .word);
        try testing.expectEqualStrings("foo   ", c.bytes);
        try testing.expectEqual(0, c.start_cp);
        try testing.expectEqual(6, c.end_cp);
    }

    const last = contentsAt(text, 6, .word);
    try testing.expectEqualStrings("bar", last.bytes);
}

test "contents: word granularity on spaces with no word before them" {
    // Leading spaces on a row form a range of their own, up to the
    // first word.
    const text = "x\n  lead";
    const lead = contentsAt(text, 3, .word);
    try testing.expectEqualStrings("  ", lead.bytes);
    try testing.expectEqual(2, lead.start_cp);
    try testing.expectEqual(4, lead.end_cp);

    // A blank row is its newline.
    const blank = contentsAt("a\n\nb", 2, .word);
    try testing.expectEqualStrings("\n", blank.bytes);
    try testing.expectEqual(2, blank.start_cp);
    try testing.expectEqual(3, blank.end_cp);
}

test "contents: stepping word by word reaches the end" {
    // A client reads word by word by asking for the word at the end of
    // the last one. That must never give the same range twice.
    const text = "  one   two\n\n日本 語  \nlast";
    const cp_count = utf8.cpCount(text);

    var off: usize = 0;
    var steps: usize = 0;
    while (off < cp_count) : (steps += 1) {
        const c = contentsAt(text, off, .word);
        try testing.expect(c.start_cp <= off);
        try testing.expect(c.end_cp > off);
        off = c.end_cp;
        try testing.expect(steps < cp_count);
    }
}

test "contents: line granularity includes the trailing newline" {
    const text = "first\nsecond\nthird";

    const first = contentsAt(text, 2, .line);
    try testing.expectEqualStrings("first\n", first.bytes);
    try testing.expectEqual(0, first.start_cp);
    try testing.expectEqual(6, first.end_cp);

    // The final line has no newline to include.
    const last = contentsAt(text, 14, .line);
    try testing.expectEqualStrings("third", last.bytes);
    try testing.expectEqual(13, last.start_cp);
    try testing.expectEqual(18, last.end_cp);
}

test "contents: line granularity with multi-byte rows" {
    const text = box_v ++ box_v ++ "\nabc";
    const second = contentsAt(text, 3, .line);
    try testing.expectEqualStrings("abc", second.bytes);
    try testing.expectEqual(3, second.start_cp);
    try testing.expectEqual(6, second.end_cp);
}

test "contents: every granularity yields valid UTF-8 on multi-byte text" {
    const text = box_v ++ " " ++ box_t ++ "x\n😀 tail";
    const cp_count = utf8.cpCount(text);

    var off: usize = 0;
    while (off <= cp_count) : (off += 1) {
        for ([_]Granularity{ .character, .word, .line }) |g| {
            const c = contentsAt(text, off, g);
            try testing.expect(std.unicode.utf8ValidateSlice(c.bytes));
            try testing.expect(c.start_cp <= c.end_cp);
            try testing.expect(c.end_cp <= cp_count);
        }
    }
}

/// The AT client's copy of our text. A client applies our remove and
/// insert events to its copy instead of reading the text again, so the
/// events must turn the old text into exactly the new text.
const EventModel = struct {
    buf: []u8,

    fn init(alloc: std.mem.Allocator, text: []const u8) !EventModel {
        return .{ .buf = try alloc.dupe(u8, text) };
    }

    fn deinit(self: *EventModel, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }

    /// `updateContents(.remove, start_cp, end_cp)`.
    fn remove(
        self: *EventModel,
        alloc: std.mem.Allocator,
        start_cp: usize,
        end_cp: usize,
    ) !void {
        const s = utf8.cpToByte(self.buf, start_cp);
        const e = utf8.cpToByte(self.buf, end_cp);
        const out = try alloc.alloc(u8, self.buf.len - (e - s));
        @memcpy(out[0..s], self.buf[0..s]);
        @memcpy(out[s..], self.buf[e..]);
        alloc.free(self.buf);
        self.buf = out;
    }

    /// `updateContents(.insert, start_cp, end_cp)`. The client reads the
    /// inserted text from the new text.
    fn insert(
        self: *EventModel,
        alloc: std.mem.Allocator,
        start_cp: usize,
        end_cp: usize,
        new_text: []const u8,
    ) !void {
        const cs = utf8.cpToByte(new_text, start_cp);
        const ce = utf8.cpToByte(new_text, end_cp);
        const at = utf8.cpToByte(self.buf, start_cp);
        const out = try alloc.alloc(u8, self.buf.len + (ce - cs));
        @memcpy(out[0..at], self.buf[0..at]);
        @memcpy(out[at..][0 .. ce - cs], new_text[cs..ce]);
        @memcpy(out[at + (ce - cs) ..], self.buf[at..]);
        alloc.free(self.buf);
        self.buf = out;
    }
};

/// Apply the events for `chooseDiff(old, new)` to a copy of `old`. Must
/// match `textChange` in `apprt/gtk/class/surface_a11y.zig`.
fn replayDiff(
    alloc: std.mem.Allocator,
    old_text: []const u8,
    new_text: []const u8,
) ![]u8 {
    var model = try EventModel.init(alloc, old_text);
    errdefer model.deinit(alloc);

    switch (chooseDiff(old_text, new_text)) {
        .none => {},

        .shift_up => |k| {
            const removed_cp = utf8.cpCount(old_text[0..k]);
            const tail_cp = utf8.cpCount(old_text[k..]);
            const new_end_cp = utf8.cpCount(new_text);
            try model.remove(alloc, 0, removed_cp);
            if (new_end_cp > tail_cp) {
                try model.insert(alloc, tail_cp, new_end_cp, new_text);
            }
        },

        .shift_down => |j| {
            const kept = new_text.len - j;
            const kept_cp = utf8.cpCount(old_text[0..kept]);
            const old_end_cp = utf8.cpCount(old_text);
            const inserted_cp = utf8.cpCount(new_text[0..j]);
            if (old_end_cp > kept_cp) {
                try model.remove(alloc, kept_cp, old_end_cp);
            }
            try model.insert(alloc, 0, inserted_cp, new_text);
        },

        .replace => |ps| {
            const p = ps.prefix_len;
            const s = ps.suffix_len;
            const start_cp = utf8.cpCount(old_text[0..p]);
            if (old_text.len - p - s != 0) {
                try model.remove(
                    alloc,
                    start_cp,
                    utf8.cpCount(old_text[0 .. old_text.len - s]),
                );
            }
            if (new_text.len - p - s != 0) {
                try model.insert(
                    alloc,
                    start_cp,
                    utf8.cpCount(new_text[0 .. new_text.len - s]),
                    new_text,
                );
            }
        },
    }

    return model.buf;
}

fn expectRoundTrip(old_text: []const u8, new_text: []const u8) !void {
    const alloc = testing.allocator;
    const got = try replayDiff(alloc, old_text, new_text);
    defer alloc.free(got);
    testing.expectEqualStrings(new_text, got) catch |err| {
        std.debug.print(
            "round-trip failed\n  old: '{s}'\n  new: '{s}'\n  got: '{s}'\n  diff: {any}\n",
            .{ old_text, new_text, got, chooseDiff(old_text, new_text) },
        );
        return err;
    };
}

test "diff: events round-trip on the shapes we emit by name" {
    // Command output: rows leave the top, new rows arrive at the bottom.
    try expectRoundTrip("a\nb\nc\nd", "c\nd\ne\nf");
    // Scrolling back: rows arrive at the top, the tail falls off.
    try expectRoundTrip("c\nd\ne\nf", "a\nb\nc\nd");
    // Typing echo at the prompt.
    try expectRoundTrip("a\nb\n$ ", "a\nb\n$ x");
    // A row rewritten in place (a progress bar).
    try expectRoundTrip("a\n[--]\nc", "a\n[##]\nc");
    // Nothing moved.
    try expectRoundTrip("a\nb\nc", "a\nb\nc");
    // Empty in both directions.
    try expectRoundTrip("", "a\nb");
    try expectRoundTrip("a\nb", "");
    // Multi-byte text.
    try expectRoundTrip("日本\nx\n😀", "x\n😀\n日本");
    try expectRoundTrip(box_v ++ "a\n" ++ box_t ++ "b", box_t ++ "b\n" ++ box_v ++ "a");
}

test "diff: events round-trip over generated viewports" {
    const alloc = testing.allocator;
    // Includes characters that share leading bytes, and a 4-byte one.
    const glyphs = [_][]const u8{ "a", "b", " ", "$", "é", "日", box_v, box_t, "😀" };

    var prng = std.Random.DefaultPrng.init(0x9057e11);
    const rand = prng.random();

    var buf_old: std.ArrayList(u8) = .empty;
    defer buf_old.deinit(alloc);
    var buf_new: std.ArrayList(u8) = .empty;
    defer buf_new.deinit(alloc);

    const genRow = struct {
        fn f(
            a: std.mem.Allocator,
            out: *std.ArrayList(u8),
            r: std.Random,
            gs: []const []const u8,
        ) !void {
            const n = r.uintLessThan(usize, 7);
            for (0..n) |_| try out.appendSlice(a, gs[r.uintLessThan(usize, gs.len)]);
        }
    }.f;

    var iter: usize = 0;
    while (iter < 3000) : (iter += 1) {
        buf_old.clearRetainingCapacity();
        buf_new.clearRetainingCapacity();

        const rows = 1 + rand.uintLessThan(usize, 10);
        var row_starts: [11]usize = undefined;
        for (0..rows) |i| {
            if (i > 0) try buf_old.append(alloc, '\n');
            row_starts[i] = buf_old.items.len;
            try genRow(alloc, &buf_old, rand, &glyphs);
        }
        const old_text = buf_old.items;

        switch (rand.uintLessThan(u8, 6)) {
            // Identical.
            0 => try buf_new.appendSlice(alloc, old_text),

            // Shift up: drop the first `s` rows, append `s` fresh ones.
            1 => {
                const s = 1 + rand.uintLessThan(usize, @max(1, rows - 1));
                if (s < rows) try buf_new.appendSlice(alloc, old_text[row_starts[s]..]);
                for (0..s) |_| {
                    if (buf_new.items.len > 0) try buf_new.append(alloc, '\n');
                    try genRow(alloc, &buf_new, rand, &glyphs);
                }
            },

            // Shift down: prepend `s` fresh rows, drop the last `s`.
            2 => {
                const s = 1 + rand.uintLessThan(usize, @max(1, rows - 1));
                for (0..s) |_| {
                    try genRow(alloc, &buf_new, rand, &glyphs);
                    try buf_new.append(alloc, '\n');
                }
                if (s < rows) {
                    const end = if (rows - s < rows) row_starts[rows - s] else old_text.len;
                    const keep = if (end > 0) end - 1 else 0;
                    try buf_new.appendSlice(alloc, old_text[0..keep]);
                }
            },

            // Rewrite one row in place.
            3 => {
                const target = rand.uintLessThan(usize, rows);
                for (0..rows) |i| {
                    if (i > 0) try buf_new.append(alloc, '\n');
                    if (i == target) {
                        try genRow(alloc, &buf_new, rand, &glyphs);
                    } else {
                        const start = row_starts[i];
                        const end = if (i + 1 < rows) row_starts[i + 1] - 1 else old_text.len;
                        try buf_new.appendSlice(alloc, old_text[start..end]);
                    }
                }
            },

            // Typing echo: extend the last row.
            4 => {
                try buf_new.appendSlice(alloc, old_text);
                try genRow(alloc, &buf_new, rand, &glyphs);
            },

            // An unrelated screen.
            else => {
                const n = 1 + rand.uintLessThan(usize, 10);
                for (0..n) |i| {
                    if (i > 0) try buf_new.append(alloc, '\n');
                    try genRow(alloc, &buf_new, rand, &glyphs);
                }
            },
        }

        try expectRoundTrip(old_text, buf_new.items);
    }
}
