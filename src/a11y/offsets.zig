//! Offset math over the flat accessibility text snapshot produced by
//! `text.build`.
//!
//! Where `text.zig` produces the snapshot, this module navigates it:
//! converting between byte offsets, UTF-8 codepoint offsets, terminal
//! grid positions and widget-space points, and computing the minimal
//! diff between two snapshots.
//!
//! It is deliberately free of GTK and of any surface state. Every
//! function takes the snapshot text and returns numbers, so the offset
//! arithmetic can be tested directly. That matters more here than
//! anywhere else in the accessibility code: AT-SPI offsets are in
//! codepoints, not bytes, and every historical crash in this subsystem
//! has been a boundary or unit mix-up. Handing an orphan UTF-8
//! continuation byte to the AT-SPI bridge makes `g_variant_new_string`
//! return NULL and SIGSEGVs inside `g_variant_builder_add_value`; being
//! off by a codepoint in the other direction silently truncates what a
//! screen reader announces.
//!
//! Two units appear throughout and are never interchangeable:
//!
//!   - `usize` is an offset *into the snapshot*, either bytes or
//!     codepoints. Parameter and field names say which (`..._byte`,
//!     `..._cp`); an unsuffixed offset in a public signature is a
//!     codepoint offset, because that is what AT-SPI speaks.
//!   - `u32` is a *terminal grid* coordinate: a row or a column, counted
//!     in cells.
//!
//! Nothing here uses C integer types. The apprt casts at the boundary
//! where it hands numbers to GTK, which keeps that conversion in one
//! reviewable place instead of spread across the arithmetic.

const std = @import("std");
const simd = @import("../simd/main.zig");

/// Byte length of a UTF-8 codepoint given its leading byte. A total
/// wrapper over `std.unicode.utf8ByteSequenceLength`: stray continuation
/// bytes advance 1 so a scan over malformed input can't stall. These
/// helpers are total (rather than using e.g.
/// `std.unicode.utf8CountCodepoints`) because their call sites are AT
/// callbacks with no useful error path, and the snapshots they read are
/// built codepoint by codepoint and always well-formed.
pub fn utf8CpLen(b: u8) usize {
    return std.unicode.utf8ByteSequenceLength(b) catch 1;
}

/// Count UTF-8 codepoints in `s`, via simdutf when the build has SIMD
/// enabled.
pub fn utf8CpCount(s: []const u8) usize {
    return simd.countUtf8(s);
}

/// Byte offset of the `cp_idx`-th codepoint in `s`. Clamps at `s.len`.
pub fn utf8CpToByte(s: []const u8, cp_idx: usize) usize {
    var i: usize = 0;
    var c: usize = 0;
    while (i < s.len and c < cp_idx) : (c += 1) i += utf8CpLen(s[i]);
    return i;
}

/// The unchanged ends of two snapshots: the leading `prefix_len` bytes
/// and the trailing `suffix_len` bytes are common to both, and everything
/// between them was replaced. Both lengths land on UTF-8 codepoint
/// boundaries in either snapshot.
pub const PrefixSuffixDiff = struct {
    prefix_len: usize,
    suffix_len: usize,

    /// Bytes each side has to be told about: what leaves `old` plus what
    /// arrives from `new`.
    pub fn cost(self: PrefixSuffixDiff, old_len: usize, new_len: usize) usize {
        const unchanged = self.prefix_len + self.suffix_len;
        return (old_len - unchanged) + (new_len - unchanged);
    }
};

/// Compute the byte-wise common prefix and suffix of `old` and `new`,
/// then pull both offsets back to UTF-8 codepoint boundaries.
///
/// Alignment matters because two multi-byte codepoints can share a
/// leading byte (e.g. `│` and `├`, both starting with 0xE2 0x94), and a
/// byte-wise compare can land inside a character.
///
/// Aligning against `old_text` alone also aligns `new_text`: the bytes at
/// the two boundaries are equal by construction, and in well-formed UTF-8
/// a non-continuation byte can only ever begin a codepoint. So a boundary
/// that is valid in one snapshot is valid in the other.
pub fn prefixSuffix(old_text: []const u8, new_text: []const u8) PrefixSuffixDiff {
    var prefix: usize = 0;
    const min_len = @min(old_text.len, new_text.len);
    while (prefix < min_len and old_text[prefix] == new_text[prefix]) : (prefix += 1) {}

    // Cap the suffix so it can't overlap the prefix (that would make the
    // remove/insert ranges go negative).
    var suffix: usize = 0;
    const max_suffix = @min(old_text.len - prefix, new_text.len - prefix);
    while (suffix < max_suffix and
        old_text[old_text.len - 1 - suffix] == new_text[new_text.len - 1 - suffix]) : (suffix += 1)
    {}

    // Retreat each end onto a codepoint boundary. Both only ever shrink,
    // so the no-overlap cap above still holds afterwards.
    //
    // The `prefix < old_text.len` guard matters when `old_text` is a
    // prefix of `new_text`: `prefix == old_text.len` and indexing would go
    // out of bounds, but end-of-buffer is already a codepoint boundary.
    while (prefix > 0 and prefix < old_text.len and
        isContinuation(old_text[prefix])) : (prefix -= 1)
    {}
    while (suffix > 0 and isContinuation(old_text[old_text.len - suffix])) : (suffix -= 1) {}

    return .{ .prefix_len = prefix, .suffix_len = suffix };
}

/// Whether `b` is a UTF-8 continuation byte, i.e. a byte that cannot
/// begin a codepoint.
fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// Look for a whole-line shift: a K > 0 at a `\n` boundary of `old` such
/// that `new[0..|old|-K] == old[K..]`. Returns 0 if no such K exists.
/// Since `\n` is ASCII, every candidate K is already a UTF-8 codepoint
/// boundary.
///
/// As written this finds an *upward* shift: K bytes left the top and the
/// remainder moved up. The downward shift is the same relation with the
/// snapshots exchanged, so `chooseDiff` finds it by calling this with the
/// arguments swapped rather than by duplicating the scan.
pub fn scrollK(old_text: []const u8, new_text: []const u8) usize {
    var search: usize = 0;
    while (std.mem.indexOfScalarPos(u8, old_text, search, '\n')) |i| {
        search = i + 1;
        const boundary = i + 1;
        const remainder = old_text.len - boundary;
        // A zero-byte remainder matches trivially at every trailing `\n`
        // and would mask the prefix/suffix diff for every change where
        // old_text ends in `\n`. Require a non-trivial middle.
        if (remainder == 0) continue;
        // Early rows have a remainder too long to fit in `new_text`. The
        // remainder shrinks as the scan advances, so this is a skip and
        // not a stop.
        if (remainder > new_text.len) continue;
        if (std.mem.eql(u8, new_text[0..remainder], old_text[boundary..])) {
            // The first match is the smallest K, which is the one that
            // describes the change in the fewest bytes.
            return boundary;
        }
    }
    return 0;
}

/// How to describe a viewport change to an AT client.
pub const Diff = union(enum) {
    /// Nothing to announce.
    none,

    /// The text shifted up by whole lines: `k` bytes left the top of the
    /// viewport, everything below moved up to fill the gap, and new
    /// content arrived at the bottom. This is the shape of command
    /// output, and of scrolling forwards towards the prompt.
    shift_up: usize,

    /// The text shifted down by whole lines: `j` bytes of new content
    /// arrived at the top and the tail fell off the bottom. This is the
    /// shape of scrolling back into the scrollback.
    shift_down: usize,

    /// Anything else: replace the bytes between the common prefix and the
    /// common suffix.
    replace: PrefixSuffixDiff,
};

/// Pick the cheapest description of the change from `old_text` to
/// `new_text`, measured in bytes the AT client has to be told about.
///
/// Cheapest-wins is what keeps the three shapes from poaching each
/// other's cases. On a real whole-line shift, prefix/suffix covers nearly
/// the whole viewport (every row moved), so a shift wins by a wide
/// margin. But shift detection also matches spuriously on typing echo:
/// typing `x` at a `$ ` prompt when earlier rows also end in `$ ` makes
/// the last row of `old` a prefix of `new`, and there the shift is the
/// expensive one. Neither side needs to know about the other; the byte
/// count separates them.
///
/// A shift only wins by being strictly cheaper, so an exact tie with
/// prefix/suffix takes the replacement. Between the two shift directions
/// a tie goes to `shift_up`, which is by far the common case, since a terminal
/// spends most of its life scrolling forwards.
pub fn chooseDiff(old_text: []const u8, new_text: []const u8) Diff {
    const ps = prefixSuffix(old_text, new_text);
    const ps_total = ps.cost(old_text.len, new_text.len);

    // Bytes off the top, plus whatever `new` grew past what survived.
    //
    // The subtractions below cannot underflow: a non-zero K from
    // `scrollK(a, b)` carries the guarantee that `a.len - K <= b.len`,
    // which is exactly what each one needs.
    const k = scrollK(old_text, new_text);
    const up_total = if (k > 0)
        k + (new_text.len - (old_text.len - k))
    else
        std.math.maxInt(usize);

    // The mirror image: `j` bytes onto the top of `new`, plus whatever of
    // `old` fell off the bottom.
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

/// How many terminal columns each codepoint of a snapshot occupies.
///
/// The snapshot holds one codepoint per *character*, but a terminal row is
/// a grid of *cells*, and the two do not correspond: a double-width
/// character (CJK, an emoji in emoji presentation) is one codepoint across
/// two columns, while the combining marks of a grapheme cluster are
/// codepoints across no columns of their own. Equating codepoint index
/// with column, which every function here used to do, puts a caret, a
/// click, or a highlight one column left per wide character preceding it
/// on the row.
///
/// Nothing in the text records that, so `text.build` records it here
/// as it walks the cells. The widths therefore come from the same cell
/// data the renderer draws from, rather than from a width table this
/// module would have to keep in sync with the terminal's own idea of how
/// wide a character rendered, which depends on the configured
/// grapheme-width method and cannot be re-derived from the text alone.
pub const CellWidths = struct {
    /// Columns occupied by the i-th codepoint of the snapshot. Indices
    /// past the end read as 1, so a short or absent slice degrades to one
    /// column per codepoint instead of going out of bounds.
    per_cp: []const u8 = &.{},

    /// Widths for a snapshot whose cell data we don't have. Exact for
    /// all-single-width text and off by a column per wide character
    /// otherwise, so pass it only where an approximate answer beats no
    /// answer at all.
    pub const uniform: CellWidths = .{};

    pub fn at(self: CellWidths, cp_idx: usize) u32 {
        if (cp_idx >= self.per_cp.len) return 1;
        return self.per_cp[cp_idx];
    }
};

/// Where a row begins, in both units we need to walk it: bytes to index
/// `text`, codepoints to index `CellWidths`.
const RowStart = struct {
    byte: usize,
    cp: usize,
};

/// Locate the start of `row`, or null when the snapshot has fewer rows.
fn rowStart(text: []const u8, row: u32) ?RowStart {
    if (row == 0) return .{ .byte = 0, .cp = 0 };

    var byte: usize = 0;
    var cp: usize = 0;
    var seen: u32 = 0;
    while (byte < text.len) {
        const is_newline = text[byte] == '\n';
        byte += utf8CpLen(text[byte]);
        cp += 1;
        if (!is_newline) continue;
        seen += 1;
        if (seen == row) return .{ .byte = byte, .cp = cp };
    }
    return null;
}

/// Start of the last row in the snapshot. A snapshot ending in '\n' has an
/// empty last row, and this returns its (past-the-end) start.
fn lastRowStart(text: []const u8) RowStart {
    var out: RowStart = .{ .byte = 0, .cp = 0 };
    var byte: usize = 0;
    var cp: usize = 0;
    while (byte < text.len) {
        const is_newline = text[byte] == '\n';
        byte += utf8CpLen(text[byte]);
        cp += 1;
        if (is_newline) out = .{ .byte = byte, .cp = cp };
    }
    return out;
}

/// Codepoint index of the character occupying column `col` of the row
/// starting at `start`.
///
/// A column past the row's last cell resolves to one past its last
/// codepoint, which is where a caret at end of line belongs.
fn cpAtColumn(
    text: []const u8,
    widths: CellWidths,
    start: RowStart,
    col: u32,
) usize {
    var byte = start.byte;
    var cp = start.cp;
    var column: u32 = 0;
    while (byte < text.len and text[byte] != '\n') {
        const w = widths.at(cp);
        // Zero-width codepoints (the combining marks of a grapheme
        // cluster) live in the cell their base character opened, so a
        // column resolves to that base and never to one of them.
        if (w > 0 and col < column + w) return cp;
        column += w;
        byte += utf8CpLen(text[byte]);
        cp += 1;
    }
    return cp;
}

/// Column at which codepoint `cp_idx` sits, counted from the start of its
/// own row. `cp_idx` must be at or after `start`.
///
/// A zero-width codepoint reports the column of the cell it shares rather
/// than the next one along, so it stays the inverse of `cpAtColumn`: that
/// resolves a column to the base character, and this resolves the base's
/// marks back to the same column. Running off the end of the row instead
/// reports the row's full width, which is where a caret at end of line
/// belongs.
fn columnOfCp(
    text: []const u8,
    widths: CellWidths,
    start: RowStart,
    cp_idx: usize,
) u32 {
    var byte = start.byte;
    var cp = start.cp;
    var column: u32 = 0;
    // Column at which the cell currently being filled began.
    var cell_start: u32 = 0;
    while (byte < text.len and text[byte] != '\n' and cp < cp_idx) {
        const w = widths.at(cp);
        if (w > 0) cell_start = column;
        column += w;
        byte += utf8CpLen(text[byte]);
        cp += 1;
    }

    const in_row = byte < text.len and text[byte] != '\n';
    if (in_row and widths.at(cp_idx) == 0) return cell_start;
    return column;
}

/// Map (row, col) in the snapshot to a codepoint offset. Returns null
/// when `row` is past the last row in `text`.
///
/// Contrast `offsetAtGrid`, which clamps to the last row instead. The
/// difference is deliberate: a selection anchored to a row that scrolled
/// out of the viewport has no offset and must be dropped, whereas a
/// pointer event below the last row should still resolve to something.
///
/// Either cell of a double-width character resolves to that character.
pub fn rowColToCp(
    text: []const u8,
    widths: CellWidths,
    row: u32,
    col: u32,
) ?usize {
    const start = rowStart(text, row) orelse return null;
    return cpAtColumn(text, widths, start, col);
}

/// Map (row, col) to a codepoint offset, clamping a row past the end of
/// the snapshot to the last row and a column past end-of-row to the row
/// length. Always resolves; see `rowColToCp` for the variant that fails.
pub fn offsetAtGrid(
    text: []const u8,
    widths: CellWidths,
    want_row: u32,
    col: u32,
) usize {
    const start = rowStart(text, want_row) orelse lastRowStart(text);
    return cpAtColumn(text, widths, start, col);
}

/// Everything a single forward walk can learn about a codepoint offset:
/// where it sits in bytes, which row it lands on, and where that row
/// begins.
const Location = struct {
    /// `cp_idx` clamped to the end of the text.
    cp: usize,
    byte: usize,
    row: u32,
    row_start: RowStart,
};

/// Walk to codepoint `cp_idx`, or to the end of `text` if it is shorter.
///
/// This exists so the callers below make one pass instead of several.
/// They used to derive the same four numbers independently: a codepoint
/// count here, a newline count there, a backwards scan for the row start.
/// That is a handful of full scans of the snapshot per call, and
/// `extentsCells` is called once per row every time a screen reader
/// rebuilds flat review.
fn locate(text: []const u8, cp_idx: usize) Location {
    var byte: usize = 0;
    var cp: usize = 0;
    var row: u32 = 0;
    var row_start: RowStart = .{ .byte = 0, .cp = 0 };
    while (byte < text.len and cp < cp_idx) {
        const is_newline = text[byte] == '\n';
        byte += utf8CpLen(text[byte]);
        cp += 1;
        // A newline ends its row, so the row below starts just past it.
        if (is_newline) {
            row += 1;
            row_start = .{ .byte = byte, .cp = cp };
        }
    }
    return .{ .cp = cp, .byte = byte, .row = row, .row_start = row_start };
}

/// Map a codepoint offset back to the grid position it occupies. This is the
/// inverse of `rowColToCp`, and the one conversion both the caret click
/// and `extentsCells` are built on.
///
/// An offset past the end of the snapshot lands at the end of the last
/// row rather than failing.
pub fn cpToGrid(text: []const u8, widths: CellWidths, cp_idx: usize) GridPos {
    const loc = locate(text, cp_idx);
    return .{
        .row = loc.row,
        .col = columnOfCp(text, widths, loc.row_start, loc.cp),
    };
}

/// A position on the terminal grid, in cells.
pub const GridPos = struct {
    row: u32,
    col: u32,
};

/// Convert a widget-space point to a grid position.
///
/// Negative and non-finite inputs clamp to (0, 0) so the float-to-int
/// conversion stays in range; `max_cells` guards against absurd
/// magnitudes. Callers clamp the result against the actual text bounds.
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

/// The grid rectangle covered by a codepoint range. Height is always one
/// row: AT clients get one rect per line, and a range spanning rows is
/// reported as its first row only.
pub const GridRect = struct {
    row: u32,
    col: u32,
    width_cols: u32,
};

/// Grid rectangle for the codepoint range `[start, end)`.
///
/// Rows must come out distinct per line: a screen reader's flat review
/// collapses to a single line if every row reports the same Y.
pub fn extentsCells(
    text: []const u8,
    widths: CellWidths,
    start_cp: usize,
    end_cp: usize,
) GridRect {
    // `locate` clamps `start_cp`, and the walk below stops at the end of
    // the text, so neither bound needs clamping against a codepoint count.
    const loc = locate(text, start_cp);

    // Width in cells: the columns taken by the codepoints from the start
    // up to `end_cp`, stopping at the row end. A zero here means the range
    // covered nothing that occupies a cell (an empty range, or combining
    // marks alone), and AT clients need a rect they can point at.
    var width_cols: u32 = 0;
    var byte = loc.byte;
    var cp = loc.cp;
    while (cp < end_cp and byte < text.len and text[byte] != '\n') {
        width_cols += widths.at(cp);
        byte += utf8CpLen(text[byte]);
        cp += 1;
    }
    if (width_cols == 0) width_cols = 1;

    return .{
        .row = loc.row,
        .col = columnOfCp(text, widths, loc.row_start, loc.cp),
        .width_cols = width_cols,
    };
}

/// Text granularities we resolve. GTK's enum also carries `sentence` and
/// `paragraph`; both map to `line` for a terminal, where a visual row is
/// the only meaningful unit above a word.
pub const Granularity = enum {
    character,
    word,
    line,
};

/// A resolved granularity range: codepoint bounds plus the matching
/// slice of the input text.
pub const Contents = struct {
    start_cp: usize,
    end_cp: usize,
    bytes: []const u8,
};

/// Resolve the `granularity`-sized run of text containing codepoint
/// `offset_cp`.
///
/// `offset_cp` arrives from AT-SPI as a codepoint index. Boundary
/// scanning runs on bytes (fast, simple) and converts back to codepoint
/// indices before returning, so callers never see a byte offset.
pub fn contentsAt(
    text: []const u8,
    offset_cp: usize,
    granularity: Granularity,
) Contents {
    const text_cp_count = utf8CpCount(text);
    const off_cp = @min(offset_cp, text_cp_count);
    const off_byte = utf8CpToByte(text, off_cp);

    switch (granularity) {
        .character => {
            if (off_cp >= text_cp_count) return .{
                .start_cp = text_cp_count,
                .end_cp = text_cp_count,
                .bytes = text[text.len..],
            };
            const end_byte = off_byte + utf8CpLen(text[off_byte]);
            return .{
                .start_cp = off_cp,
                .end_cp = off_cp + 1,
                .bytes = text[off_byte..end_byte],
            };
        },
        .word => {
            var ws_byte: usize = off_byte;
            while (ws_byte > 0 and
                text[ws_byte - 1] != ' ' and
                text[ws_byte - 1] != '\n') : (ws_byte -= 1)
            {}
            var we_byte: usize = off_byte;
            while (we_byte < text.len and
                text[we_byte] != ' ' and
                text[we_byte] != '\n') : (we_byte += 1)
            {}
            return .{
                .start_cp = utf8CpCount(text[0..ws_byte]),
                .end_cp = utf8CpCount(text[0..we_byte]),
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
                .start_cp = utf8CpCount(text[0..ls_byte]),
                .end_cp = utf8CpCount(text[0..le_byte]),
                .bytes = text[ls_byte..le_byte],
            };
        },
    }
}

const testing = std.testing;

// A three-byte codepoint whose leading two bytes are shared with `├`
// (0xE2 0x94 0x82 vs 0xE2 0x94 0x9C). This pair is what makes a
// byte-wise diff land mid-character.
const box_v = "│";
const box_t = "├";

test "utf8: codepoint length, count and index" {
    try testing.expectEqual(@as(usize, 1), utf8CpLen('a'));
    try testing.expectEqual(@as(usize, 2), utf8CpLen("é"[0]));
    try testing.expectEqual(@as(usize, 3), utf8CpLen(box_v[0]));
    try testing.expectEqual(@as(usize, 4), utf8CpLen("😀"[0]));

    // Continuation bytes advance by one so a malformed scan terminates.
    try testing.expectEqual(@as(usize, 1), utf8CpLen(0x80));

    const s = "a" ++ box_v ++ "b😀";
    try testing.expectEqual(@as(usize, 4), utf8CpCount(s));
    try testing.expectEqual(@as(usize, 9), s.len);

    try testing.expectEqual(@as(usize, 0), utf8CpToByte(s, 0));
    try testing.expectEqual(@as(usize, 1), utf8CpToByte(s, 1));
    try testing.expectEqual(@as(usize, 4), utf8CpToByte(s, 2));
    try testing.expectEqual(@as(usize, 5), utf8CpToByte(s, 3));
    // Past the end clamps rather than overruns.
    try testing.expectEqual(s.len, utf8CpToByte(s, 99));
}

test "diff: prefixSuffix on a plain single-character edit" {
    const old_text = "hello world";
    const new_text = "hello Xorld";
    const d = prefixSuffix(old_text, new_text);
    try testing.expectEqual(@as(usize, 6), d.prefix_len);
    try testing.expectEqual(@as(usize, 4), d.suffix_len);
}

test "diff: prefixSuffix pulls back off a shared multi-byte lead" {
    // Both sides start 0xE2 0x94, so a byte-wise prefix lands 2 bytes
    // into the character. The result must retreat to the boundary or the
    // AT-SPI bridge receives an orphan continuation byte.
    const old_text = "a" ++ box_v ++ "z";
    const new_text = "a" ++ box_t ++ "z";

    const d = prefixSuffix(old_text, new_text);
    try testing.expectEqual(@as(usize, 1), d.prefix_len);
    try testing.expect(std.unicode.utf8ValidateSlice(old_text[0..d.prefix_len]));
    try testing.expect(std.unicode.utf8ValidateSlice(old_text[d.prefix_len .. old_text.len - d.suffix_len]));
    try testing.expect(std.unicode.utf8ValidateSlice(new_text[0..d.prefix_len]));
}

test "diff: prefixSuffix when old is a prefix of new" {
    // `p` reaches old_text.len; indexing at `p` would be out of bounds.
    const old_text = "abc";
    const new_text = "abcdef";
    const d = prefixSuffix(old_text, new_text);
    try testing.expectEqual(@as(usize, 3), d.prefix_len);
    try testing.expectEqual(@as(usize, 0), d.suffix_len);
}

test "diff: prefixSuffix on identical and empty inputs" {
    const same = prefixSuffix("abc", "abc");
    try testing.expectEqual(@as(usize, 3), same.prefix_len);
    try testing.expectEqual(@as(usize, 0), same.suffix_len);

    const empty = prefixSuffix("", "");
    try testing.expectEqual(@as(usize, 0), empty.prefix_len);
    try testing.expectEqual(@as(usize, 0), empty.suffix_len);

    const from_empty = prefixSuffix("", "new");
    try testing.expectEqual(@as(usize, 0), from_empty.prefix_len);
    try testing.expectEqual(@as(usize, 0), from_empty.suffix_len);
}

test "diff: prefix and suffix never overlap" {
    // Without the cap, the common prefix and suffix of "aaaa"/"aa" would
    // both claim the same bytes and the replaced range would go negative.
    const old_text = "aaaa";
    const new_text = "aa";
    const d = prefixSuffix(old_text, new_text);
    try testing.expect(d.prefix_len + d.suffix_len <= old_text.len);
    try testing.expect(d.prefix_len + d.suffix_len <= new_text.len);
}

test "diff: scrollK detects a whole-line shift" {
    const old_text = "line1\nline2\nline3\n";
    const new_text = "line2\nline3\nline4\n";
    // One line scrolled off: K is the byte just past the first newline.
    try testing.expectEqual(@as(usize, 6), scrollK(old_text, new_text));
}

test "diff: scrollK rejects a trailing-newline-only match" {
    // The zero-length remainder at the final `\n` matches trivially; if
    // that were accepted every edit to a newline-terminated buffer would
    // be reported as a scroll.
    const old_text = "abc\n";
    const new_text = "abz\n";
    try testing.expectEqual(@as(usize, 0), scrollK(old_text, new_text));
}

test "diff: scrollK returns 0 with no newline or no match" {
    try testing.expectEqual(@as(usize, 0), scrollK("", "anything"));
    try testing.expectEqual(@as(usize, 0), scrollK("no newlines", "still none"));
    try testing.expectEqual(@as(usize, 0), scrollK("a\nb\n", "totally different"));
}

test "diff: scrollK detects a downward shift with the arguments swapped" {
    // Scrolling back into the scrollback: `line0` arrives at the top and
    // `line3` falls off the bottom. Nothing about this matches the upward
    // scan, which is why `chooseDiff` runs the scan both ways.
    const old_text = "line1\nline2\nline3\n";
    const new_text = "line0\nline1\nline2\n";

    try testing.expectEqual(@as(usize, 0), scrollK(old_text, new_text));
    try testing.expectEqual(@as(usize, 6), scrollK(new_text, old_text));
}

test "diff: choose prefers a shift over replacing the viewport" {
    const old_text = "line1\nline2\nline3\n";
    const new_text = "line2\nline3\nline4\n";
    try testing.expectEqual(Diff{ .shift_up = 6 }, chooseDiff(old_text, new_text));
}

test "diff: choose reports scrolling back as a downward shift" {
    // The regression this whole path exists for. A one-line scroll back
    // changes row 0 and drops the last row, so prefix/suffix keeps almost
    // nothing and ends up rewriting the viewport twice over, which Orca
    // reads out in full instead of announcing the one new line.
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
    // Two rows in at the top, two rows off the bottom.
    try testing.expectEqual(Diff{ .shift_down = 4 }, chooseDiff(old_text, new_text));
}

test "diff: choose keeps typing echo as a replacement" {
    // Repeated `$ ` prompts make the last old row a prefix of new, so the
    // upward shift scan fires spuriously. Cheapest-wins has to reject it:
    // one appended character must not be announced as a scroll.
    const old_text = "$ \n$ \n$ ";
    const new_text = "$ \n$ \n$ x";

    const diff = chooseDiff(old_text, new_text);
    try testing.expect(diff == .replace);
    try testing.expectEqual(@as(usize, 8), diff.replace.prefix_len);
    try testing.expectEqual(@as(usize, 0), diff.replace.suffix_len);
}

test "diff: choose says nothing for identical snapshots" {
    try testing.expectEqual(Diff.none, chooseDiff("a\nb\n", "a\nb\n"));
    try testing.expectEqual(Diff.none, chooseDiff("", ""));
}

test "diff: choose survives a viewport with no overlap at all" {
    // A full-page jump shares no rows in either direction, so both shift
    // scans come up empty and the replacement path has to carry it.
    const old_text = "a\nb\nc\n";
    const new_text = "x\ny\nz\n";
    const diff = chooseDiff(old_text, new_text);
    try testing.expect(diff == .replace);
}

test "diff: shift offsets stay on codepoint boundaries" {
    // The shift amounts index into the snapshots to build codepoint
    // counts, so a multi-byte row must not leave them mid-character.
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
    // Replay what `axEmitShiftDown` emits and check it reconstructs `new`:
    // remove `old[kept..]`, then insert `new[0..j]` at the front.
    const old_text = "line1\nline2\nline3\n";
    const new_text = "line0\nline1\nline2\n";

    const diff = chooseDiff(old_text, new_text);
    const j = diff.shift_down;
    const kept = new_text.len - j;
    try testing.expect(kept <= old_text.len);

    var buf: [64]u8 = undefined;
    const rebuilt = try std.fmt.bufPrint(&buf, "{s}{s}", .{
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
    const rebuilt = try std.fmt.bufPrint(&buf, "{s}{s}", .{
        old_text[k..],
        new_text[old_text.len - k ..],
    });
    try testing.expectEqualStrings(new_text, rebuilt);
}

test "grid: rowColToCp counts codepoints, not bytes" {
    const text = box_v ++ box_v ++ "\nabc";
    // Row 1 begins 7 bytes in but only 3 codepoints in (two box drawing
    // characters plus the newline, which is itself a codepoint). Counting
    // bytes here would report 7 and push every offset off the end.
    try testing.expectEqual(@as(?usize, 3), rowColToCp(text, .uniform, 1, 0));
    try testing.expectEqual(@as(?usize, 5), rowColToCp(text, .uniform, 1, 2));
    try testing.expectEqual(@as(?usize, 1), rowColToCp(text, .uniform, 0, 1));
}

test "grid: rowColToCp clamps column, fails past the last row" {
    const text = "ab\ncd";
    try testing.expectEqual(@as(?usize, 5), rowColToCp(text, .uniform, 1, 99));
    try testing.expectEqual(@as(?usize, null), rowColToCp(text, .uniform, 7, 0));
}

test "grid: offsetAtGrid clamps instead of failing" {
    const text = "ab\ncd";
    // Same in-range answers as rowColToCp...
    try testing.expectEqual(@as(usize, 3), offsetAtGrid(text, .uniform, 1, 0));
    // ...but a row past the end resolves into the last row rather than
    // returning nothing.
    try testing.expectEqual(@as(usize, 3), offsetAtGrid(text, .uniform, 7, 0));
    try testing.expectEqual(@as(usize, 5), offsetAtGrid(text, .uniform, 7, 99));
}

// Three double-width characters followed by ASCII: one codepoint each,
// two columns each, so codepoint index and column part ways at the very
// first character.
const wide_row = "日本語ab";
const wide_widths: CellWidths = .{ .per_cp = &.{ 2, 2, 2, 1, 1 } };

test "grid: a wide character spans two columns" {
    // 'a' is codepoint 3 but column 6. Reading the codepoint index as a
    // column is the bug this exists to prevent: it lands three columns
    // to the left, on 語.
    try testing.expectEqual(@as(?usize, 3), rowColToCp(wide_row, wide_widths, 0, 6));
    try testing.expectEqual(@as(u32, 6), cpToGrid(wide_row, wide_widths, 3).col);

    // Both cells of a wide character resolve to that character, so a
    // click on either half routes to the same place.
    try testing.expectEqual(@as(?usize, 1), rowColToCp(wide_row, wide_widths, 0, 2));
    try testing.expectEqual(@as(?usize, 1), rowColToCp(wide_row, wide_widths, 0, 3));

    // Round trip: every codepoint's column maps back to itself.
    for (0..5) |cp| {
        const col = cpToGrid(wide_row, wide_widths, cp).col;
        try testing.expectEqual(@as(?usize, cp), rowColToCp(wide_row, wide_widths, 0, col));
    }
}

test "grid: widths are per row, and rows keep their own columns" {
    const text = "日本\nab";
    const widths: CellWidths = .{ .per_cp = &.{ 2, 2, 0, 1, 1 } };

    // Row 0: column 2 is the second wide character.
    try testing.expectEqual(@as(?usize, 1), rowColToCp(text, widths, 0, 2));
    // Row 1 starts its column count over, and its offsets are unaffected
    // by the wide characters above it.
    try testing.expectEqual(@as(?usize, 3), rowColToCp(text, widths, 1, 0));
    try testing.expectEqual(@as(?usize, 4), rowColToCp(text, widths, 1, 1));
    try testing.expectEqual(GridPos{ .row = 1, .col = 1 }, cpToGrid(text, widths, 4));
}

test "grid: zero-width codepoints share their base character's cell" {
    // "e" + a combining acute: two codepoints, one column.
    const text = "e\u{0301}x";
    const widths: CellWidths = .{ .per_cp = &.{ 1, 0, 1 } };

    // Column 0 resolves to the base character, never to the mark.
    try testing.expectEqual(@as(?usize, 0), rowColToCp(text, widths, 0, 0));
    // 'x' follows in the next column even though it is codepoint 2.
    try testing.expectEqual(@as(?usize, 2), rowColToCp(text, widths, 0, 1));
    try testing.expectEqual(@as(u32, 1), cpToGrid(text, widths, 2).col);
    // The mark itself reports its base character's column.
    try testing.expectEqual(@as(u32, 0), cpToGrid(text, widths, 1).col);
}

test "grid: missing widths degrade to one column per codepoint" {
    // Short slices and empty ones read as width 1 past their end, which
    // is the pre-widths behaviour rather than an out-of-bounds read.
    const short: CellWidths = .{ .per_cp = &.{2} };
    try testing.expectEqual(@as(?usize, 1), rowColToCp(wide_row, short, 0, 2));
    try testing.expectEqual(@as(?usize, 2), rowColToCp(wide_row, short, 0, 3));
    try testing.expectEqual(@as(?usize, 3), rowColToCp(wide_row, .uniform, 0, 3));
}

test "grid: cpToGrid clamps an offset past the end" {
    const text = "ab\ncd";
    // Past-the-end lands at the end of the last row, not out of bounds.
    try testing.expectEqual(GridPos{ .row = 1, .col = 2 }, cpToGrid(text, .uniform, 99));
}

test "grid: a newline belongs to the row it terminates" {
    // The separator is a codepoint of its own, and the offset *at* it must
    // still report the row above; the row below only begins one past it.
    // Getting this backwards shifts every extent by a row and puts flat
    // review one line out of step with the text it reads.
    const text = "ab\ncd\nef";
    try testing.expectEqual(GridPos{ .row = 0, .col = 2 }, cpToGrid(text, .uniform, 2));
    try testing.expectEqual(GridPos{ .row = 1, .col = 0 }, cpToGrid(text, .uniform, 3));
    try testing.expectEqual(GridPos{ .row = 1, .col = 2 }, cpToGrid(text, .uniform, 5));
    try testing.expectEqual(GridPos{ .row = 2, .col = 0 }, cpToGrid(text, .uniform, 6));

    // `extentsCells` shares the same walk, so it agrees.
    try testing.expectEqual(@as(u32, 0), extentsCells(text, .uniform, 2, 3).row);
    try testing.expectEqual(@as(u32, 1), extentsCells(text, .uniform, 3, 4).row);
}

test "grid: pointToGrid survives negative and non-finite input" {
    const cw: f32 = 10;
    const ch: f32 = 20;

    try testing.expectEqual(GridPos{ .row = 2, .col = 3 }, pointToGrid(35, 55, cw, ch));

    // Negatives clamp to the origin rather than wrapping through
    // @intFromFloat.
    try testing.expectEqual(GridPos{ .row = 0, .col = 0 }, pointToGrid(-500, -500, cw, ch));

    // NaN and both infinities are non-finite, so they take the origin
    // fallback rather than the magnitude guard.
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    try testing.expectEqual(GridPos{ .row = 0, .col = 0 }, pointToGrid(nan, nan, cw, ch));
    try testing.expectEqual(GridPos{ .row = 0, .col = 0 }, pointToGrid(-inf, -inf, cw, ch));
    try testing.expectEqual(GridPos{ .row = 0, .col = 0 }, pointToGrid(inf, inf, cw, ch));

    // A finite but absurd magnitude saturates at the guard instead of
    // overflowing the float-to-int conversion.
    const huge = pointToGrid(1e30, 1e30, cw, ch);
    try testing.expectEqual(@as(u32, 1_000_000), huge.row);
    try testing.expectEqual(@as(u32, 1_000_000), huge.col);
}

test "extents: each row reports a distinct row index" {
    const text = "row0\nrow1\nrow2";
    // Flat review collapses to one line if these ever coincide.
    try testing.expectEqual(@as(u32, 0), extentsCells(text, .uniform, 0, 1).row);
    try testing.expectEqual(@as(u32, 1), extentsCells(text, .uniform, 5, 6).row);
    try testing.expectEqual(@as(u32, 2), extentsCells(text, .uniform, 10, 11).row);
}

test "extents: column and width are in cells, not bytes" {
    const text = box_v ++ box_v ++ "abc";
    // Third codepoint sits at column 2 even though it is byte 6.
    const r = extentsCells(text, .uniform, 2, 5);
    try testing.expectEqual(@as(u32, 0), r.row);
    try testing.expectEqual(@as(u32, 2), r.col);
    try testing.expectEqual(@as(u32, 3), r.width_cols);
}

test "extents: a wide character is two cells wide and shifts what follows" {
    // Highlighting 語 must cover both its columns, and 'a' after it must
    // start at column 6, or a screen reader's highlight sits a
    // character behind the text it is reading.
    const wide = extentsCells(wide_row, wide_widths, 2, 3);
    try testing.expectEqual(@as(u32, 4), wide.col);
    try testing.expectEqual(@as(u32, 2), wide.width_cols);

    const after = extentsCells(wide_row, wide_widths, 3, 5);
    try testing.expectEqual(@as(u32, 6), after.col);
    try testing.expectEqual(@as(u32, 2), after.width_cols);

    // The whole row: three wide characters plus two narrow ones.
    try testing.expectEqual(@as(u32, 8), extentsCells(wide_row, wide_widths, 0, 5).width_cols);
}

test "extents: width stops at the row end and never reports zero" {
    const text = "ab\ncdef";
    // Range spans the newline; width covers only the first row.
    const spanning = extentsCells(text, .uniform, 0, 6);
    try testing.expectEqual(@as(u32, 2), spanning.width_cols);

    // An empty range still reports one cell so the rect is visible.
    const empty = extentsCells(text, .uniform, 1, 1);
    try testing.expectEqual(@as(u32, 1), empty.width_cols);

    // So does a range covering only zero-width codepoints: a combining
    // mark alone sums to no columns, but an AT client still needs a rect.
    const marks: CellWidths = .{ .per_cp = &.{ 1, 0, 1 } };
    try testing.expectEqual(@as(u32, 1), extentsCells("e\u{0301}x", marks, 1, 2).width_cols);
}

test "contents: character granularity returns one whole codepoint" {
    const text = "a" ++ box_v ++ "b";
    const c = contentsAt(text, 1, .character);
    try testing.expectEqual(@as(usize, 1), c.start_cp);
    try testing.expectEqual(@as(usize, 2), c.end_cp);
    try testing.expectEqualStrings(box_v, c.bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(c.bytes));
}

test "contents: character granularity past the end is empty" {
    const text = "abc";
    const c = contentsAt(text, 99, .character);
    try testing.expectEqual(@as(usize, 3), c.start_cp);
    try testing.expectEqual(@as(usize, 3), c.end_cp);
    try testing.expectEqualStrings("", c.bytes);
}

test "contents: word granularity stops at spaces and newlines" {
    const text = "alpha beta\ngamma";

    const mid = contentsAt(text, 7, .word);
    try testing.expectEqualStrings("beta", mid.bytes);
    try testing.expectEqual(@as(usize, 6), mid.start_cp);
    try testing.expectEqual(@as(usize, 10), mid.end_cp);

    // A word bounded by a newline rather than a space.
    const after_nl = contentsAt(text, 12, .word);
    try testing.expectEqualStrings("gamma", after_nl.bytes);
    try testing.expectEqual(@as(usize, 11), after_nl.start_cp);

    // Sitting on the separator itself walks back to the start of the
    // preceding word and stops immediately going forward, so the offset
    // resolves to the word to its left rather than to an empty range.
    // Pinning this down because it is the boundary case an AT client hits
    // when stepping word-by-word across a line.
    const on_space = contentsAt(text, 5, .word);
    try testing.expectEqualStrings("alpha", on_space.bytes);
    try testing.expectEqual(@as(usize, 0), on_space.start_cp);
    try testing.expectEqual(@as(usize, 5), on_space.end_cp);
}

test "contents: line granularity includes the trailing newline" {
    const text = "first\nsecond\nthird";

    const first = contentsAt(text, 2, .line);
    try testing.expectEqualStrings("first\n", first.bytes);
    try testing.expectEqual(@as(usize, 0), first.start_cp);
    try testing.expectEqual(@as(usize, 6), first.end_cp);

    // The final line has no newline to include.
    const last = contentsAt(text, 14, .line);
    try testing.expectEqualStrings("third", last.bytes);
    try testing.expectEqual(@as(usize, 13), last.start_cp);
    try testing.expectEqual(@as(usize, 18), last.end_cp);
}

test "contents: line granularity with multi-byte rows" {
    const text = box_v ++ box_v ++ "\nabc";
    const second = contentsAt(text, 3, .line);
    try testing.expectEqualStrings("abc", second.bytes);
    // Row 1 begins at codepoint 3 (two box chars plus the newline).
    try testing.expectEqual(@as(usize, 3), second.start_cp);
    try testing.expectEqual(@as(usize, 6), second.end_cp);
}

test "contents: every granularity yields valid UTF-8 on multi-byte text" {
    // The bridge substitutes the literal "[Invalid UTF-8]" for anything
    // that fails validation, and a screen reader then speaks it.
    const text = box_v ++ " " ++ box_t ++ "x\n😀 tail";
    const cp_count = utf8CpCount(text);

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

/// A test-only model of the AT client's copy of our text.
///
/// An AT client does not re-read the whole buffer when it changes; it
/// applies the `remove`/`insert` events we emit to the copy it already
/// has. So the property that actually matters is not "is each event
/// plausible" but "does replaying them reproduce the new text exactly".
/// If it does not, the client's copy silently drifts from ours and stays
/// wrong until something makes it rebuild from scratch -- which, in Orca,
/// is a focus change.
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
        const s = utf8CpToByte(self.buf, start_cp);
        const e = utf8CpToByte(self.buf, end_cp);
        const out = try alloc.alloc(u8, self.buf.len - (e - s));
        @memcpy(out[0..s], self.buf[0..s]);
        @memcpy(out[s..], self.buf[e..]);
        alloc.free(self.buf);
        self.buf = out;
    }

    /// `updateContents(.insert, start_cp, end_cp)`. The client reads the
    /// inserted bytes back out of us with `axGetContents`, which serves
    /// the post-change text -- so the content comes from `new_text` at the
    /// same codepoint range the event names.
    fn insert(
        self: *EventModel,
        alloc: std.mem.Allocator,
        start_cp: usize,
        end_cp: usize,
        new_text: []const u8,
    ) !void {
        const cs = utf8CpToByte(new_text, start_cp);
        const ce = utf8CpToByte(new_text, end_cp);
        const at = utf8CpToByte(self.buf, start_cp);
        const out = try alloc.alloc(u8, self.buf.len + (ce - cs));
        @memcpy(out[0..at], self.buf[0..at]);
        @memcpy(out[at..][0 .. ce - cs], new_text[cs..ce]);
        @memcpy(out[at + (ce - cs) ..], self.buf[at..]);
        alloc.free(self.buf);
        self.buf = out;
    }
};

/// Replay the events `surface.zig` would emit for `chooseDiff(old, new)`.
///
/// This mirrors `axEmitShiftUp` / `axEmitShiftDown` / `axEmitPrefixSuffix`
/// exactly, including which ranges are skipped when empty. Keep the two in
/// step: if an emit function changes, change this and the fuzz test below
/// will tell you whether the change still round-trips.
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
            const removed_cp = utf8CpCount(old_text[0..k]);
            const tail_cp = utf8CpCount(old_text[k..]);
            const new_end_cp = utf8CpCount(new_text);
            try model.remove(alloc, 0, removed_cp);
            if (new_end_cp > tail_cp) {
                try model.insert(alloc, tail_cp, new_end_cp, new_text);
            }
        },

        .shift_down => |j| {
            const kept = new_text.len - j;
            const kept_cp = utf8CpCount(old_text[0..kept]);
            const old_end_cp = utf8CpCount(old_text);
            const inserted_cp = utf8CpCount(new_text[0..j]);
            if (old_end_cp > kept_cp) {
                try model.remove(alloc, kept_cp, old_end_cp);
            }
            try model.insert(alloc, 0, inserted_cp, new_text);
        },

        .replace => |ps| {
            const p = ps.prefix_len;
            const s = ps.suffix_len;
            const start_cp = utf8CpCount(old_text[0..p]);
            if (old_text.len - p - s != 0) {
                try model.remove(
                    alloc,
                    start_cp,
                    utf8CpCount(old_text[0 .. old_text.len - s]),
                );
            }
            if (new_text.len - p - s != 0) {
                try model.insert(
                    alloc,
                    start_cp,
                    utf8CpCount(new_text[0 .. new_text.len - s]),
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
    // Multi-byte content shifting, including a row that is pure emoji --
    // the case where a byte-wise prefix/suffix would cut mid-codepoint.
    try expectRoundTrip("日本\nx\n😀", "x\n😀\n日本");
    try expectRoundTrip("│a\n├b", "├b\n│a");
}

test "diff: events round-trip over generated viewports" {
    const alloc = testing.allocator;
    // Deliberately includes characters that share leading bytes (│ and ├)
    // and a 4-byte codepoint, since the prefix/suffix scan walks bytes and
    // then backs up to a boundary.
    const glyphs = [_][]const u8{ "a", "b", " ", "$", "é", "日", "│", "├", "😀" };

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
