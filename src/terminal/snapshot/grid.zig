//! Grid (rows, cells, and grapheme suffixes) encoding.
//!
//! A grid contains the rows and cells of a terminal page. Its dimensions are
//! supplied by the containing record rather than repeated here. The encoder
//! writes exactly `rows` row records followed by one grapheme suffix section.
//!
//! All records are tightly packed with no padding between them. All integers
//! are unsigned and little-endian.
//!
//! The layout is designed so the common case decodes with bulk copies: cells
//! are fixed-size words, trailing default cells are elided per row, and the
//! variable-length grapheme suffixes live outside the row data.
//!
//! ```text
//! +---------------------------+
//! | Row 0                     |
//! +---------------------------+
//! | ...                       |
//! +---------------------------+
//! | Row (rows - 1)            |
//! +---------------------------+
//! | Grapheme suffix section   |
//! +---------------------------+
//! ```
//!
//! ## Row
//!
//! Each row has the following format:
//!
//! | Offset | Size              | Field                      |
//! | -----: | ----------------: | :------------------------- |
//! |      0 |                 1 | Row flags                  |
//! |      1 |                 2 | Encoded cell count (`u16`) |
//! |      3 | `width` * `count` | Encoded cells              |
//!
//! The row flag byte has the following format:
//!
//! | Bits | Field                     |
//! | ---: | :------------------------ |
//! |    0 | Wrap                      |
//! |    1 | Wrap continuation         |
//! |  2-3 | Semantic prompt           |
//! |  4-5 | Encoded cell width        |
//! |  6-7 | Reserved, zero            |
//!
//! Semantic prompt values are:
//!
//! | Value | Meaning             |
//! | ----: | :------------------ |
//! |     0 | None                |
//! |     1 | Prompt              |
//! |     2 | Prompt continuation |
//!
//! Value 3 is not emitted in snapshot version 1. Decoders treat it as none.
//!
//! The encoded cell count must not exceed the grid's column count; it is a
//! structural field and decoders reject larger values. Cells at and beyond
//! the count are the default cell: all sixty-four bits zero, meaning an
//! empty narrow codepoint cell with the default style and no hyperlink.
//! Canonical encoders emit exactly through the row's last non-default cell,
//! so a fully default row has a zero count and no cell words.
//!
//! ## Encoded cell width
//!
//! The two width bits select how many bytes encode each of the row's
//! cells: `1 << width` is the size, so zero through three select one, two,
//! four, or eight bytes. Narrower widths are truncated transports of the
//! same cell word: a cell qualifies for a width when all of its higher
//! word bits are zero.
//!
//! | Width | Bytes | Encoded value and admitted cells                     |
//! | ----: | ----: | :--------------------------------------------------- |
//! |     0 |     1 | Codepoint at or below U+00FF; all other bits zero    |
//! |     1 |     2 | Codepoint at or below U+FFFF; all other bits zero    |
//! |     2 |     4 | Word bits 0-31: any content kind and codepoint, style |
//! |       |       | IDs 1-63, narrow, no flags, no hyperlink             |
//! |     3 |     8 | The complete word                                    |
//!
//! Widths zero and one store the codepoint value itself, which is word
//! bits 2-25 shifted down; the reconstructed word is the codepoint shifted
//! left by two. Width two stores the word's low half unshifted. This makes
//! every width a zero-extension on decode and a truncation on encode.
//!
//! Canonical encoders choose each row's smallest admissible width, which
//! follows directly from the bitwise OR of the row's cell words. Decoders
//! use the declared width for framing and accept rows encoded wider than
//! necessary. The width of a row with a zero cell count is canonically
//! zero and carries no meaning.
//!
//! Native row cache flags are not encoded. In particular, the Kitty virtual
//! placeholder hint is derived while decoding cells containing U+10EEEE.
//!
//! ## Cell
//!
//! Each cell is one 64-bit little-endian word, transported at the row's
//! encoded cell width as described above:
//!
//! ```text
//!  bit 0 +-------------------------------+
//!        | Content kind                  |
//!        | 2 bits                        |
//!  bit 2 +-------------------------------+
//!        | Content                       |
//!        | 24 bits                       |
//! bit 26 +-------------------------------+
//!        | Style ID                      |
//!        | 16 bits                       |
//! bit 42 +-------------------------------+
//!        | Width kind                    |
//!        | 2 bits                        |
//! bit 44 +-------------------------------+
//!        | Protected                     |
//! bit 45 +-------------------------------+
//!        | Hyperlink flag                |
//! bit 46 +-------------------------------+
//!        | Semantic content              |
//!        | 2 bits                        |
//! bit 48 +-------------------------------+
//!        | Hyperlink ID                  |
//!        | 16 bits                       |
//! bit 64 +-------------------------------+
//! ```
//!
//! Content kinds are:
//!
//! | Value | Meaning                          |
//! | ----: | :------------------------------- |
//! |     0 | Codepoint                        |
//! |     1 | Codepoint with grapheme suffix   |
//! |     2 | Palette background               |
//! |     3 | RGB background                   |
//!
//! The content kind selects the layout of the 24-bit content field. All
//! content bit positions below are relative to the start of the content
//! field, so content bit 0 is cell word bit 2.
//!
//! For codepoint content (kinds 0 and 1), the content field is a Unicode
//! scalar value. Values above U+10FFFF and surrogates decode as U+FFFD.
//! Kind 1 additionally declares that the grapheme suffix section contains
//! one entry for this cell; the cell is otherwise identical to kind 0.
//!
//! ```text
//!  bit 0 +-------------------------------+
//!        | Unicode scalar value          |
//!        | 24 bits                       |
//! bit 24 +-------------------------------+
//! ```
//!
//! For a palette background (kind 2), the low byte is the palette index.
//! The remaining content bits are reserved, canonically zero, and ignored
//! by decoders.
//!
//! ```text
//!  bit 0 +-------------------------------+
//!        | Palette index                 |
//!        | 8 bits                        |
//!  bit 8 +-------------------------------+
//!        | Reserved, zero                |
//!        | 16 bits                       |
//! bit 24 +-------------------------------+
//! ```
//!
//! For an RGB background (kind 3), the content field is one byte per
//! channel:
//!
//! ```text
//!  bit 0 +-------------------------------+
//!        | Red                           |
//!        | 8 bits                        |
//!  bit 8 +-------------------------------+
//!        | Green                         |
//!        | 8 bits                        |
//! bit 16 +-------------------------------+
//!        | Blue                          |
//!        | 8 bits                        |
//! bit 24 +-------------------------------+
//! ```
//!
//! Width kinds are:
//!
//! | Value | Meaning     |
//! | ----: | :---------- |
//! |     0 | Narrow      |
//! |     1 | Wide        |
//! |     2 | Spacer tail |
//! |     3 | Spacer head |
//!
//! Semantic content values are:
//!
//! | Value | Meaning |
//! | ----: | :------ |
//! |     0 | Output  |
//! |     1 | Input   |
//! |     2 | Prompt  |
//!
//! Value 3 is not emitted in snapshot version 1. Decoders treat it as output.
//!
//! Style and hyperlink ID zero mean no style and no hyperlink. Other IDs
//! refer to entries in the containing record's separate style and hyperlink
//! tables. The hyperlink flag is set exactly when the hyperlink ID is
//! nonzero; decoders derive cell linkage from the remapped ID and ignore the
//! flag itself.
//!
//! ## Grapheme suffix section
//!
//! The section begins with an entry count followed by that many entries:
//!
//! | Offset | Size    | Field                |
//! | -----: | ------: | :------------------- |
//! |      0 |       4 | Entry count (`u32`)  |
//! |      4 | varies  | Entries              |
//!
//! Each entry:
//!
//! | Offset | Size        | Field                       |
//! | -----: | ----------: | :-------------------------- |
//! |      0 |           2 | Row (`u16`)                 |
//! |      2 |           2 | Column (`u16`)              |
//! |      4 |           2 | Codepoint count (`u16`)     |
//! |      6 | 4 * `count` | Codepoints (`u32` each)     |
//!
//! Each codepoint is a Unicode scalar; invalid scalars are individually
//! ignored by decoders. Canonical encoders emit exactly one entry, with at
//! least one codepoint, for every kind 1 cell, in ascending row-then-column
//! order. Decoders consume every declared entry and ignore entries whose
//! target is out of range, is not a codepoint cell, has a zero codepoint, or
//! already received an entry. A kind 1 cell that receives no suffix
//! codepoints decodes as a plain codepoint cell.

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const test_fixture = @import("fixture.zig");
const io = @import("io.zig");
const terminal_hyperlink = @import("../hyperlink.zig");
const terminal_page = @import("../page.zig");
const terminal_style = @import("../style.zig");

/// The Kitty virtual-placement placeholder remains wire-relevant even when
/// runtime Kitty graphics support is compiled out.
const kitty_virtual_placeholder: u21 = 0x10EEEE;

const TerminalCell = terminal_page.Cell;
const TerminalHyperlinkId = terminal_hyperlink.Id;
const TerminalPage = terminal_page.Page;
const TerminalRow = terminal_page.Row;
const TerminalStyleId = terminal_style.Id;

/// The header before every row's encoded cells.
///
/// The semantic prompt is a raw integer for the same reason as the wire
/// cell fields: decoders must accept its reserved value without
/// instantiating an invalid native enum. The width enum is exhaustive over
/// its two bits, so every header byte bit-casts to a valid value.
pub const Row = packed struct(u8) {
    wrap: bool = false,
    wrap_continuation: bool = false,
    semantic_prompt: u2 = 0,
    cell_width: Cell.EncodedWidth = .one,
    _padding: u2 = 0,
};

/// The wire layout of one encoded cell. This is its own registry: the bit
/// positions and field meanings are part of the snapshot format and are
/// documented above independently of the native cell.
///
/// Enum-like fields are raw integers because decoders must accept reserved
/// values (for example semantic content 3) without instantiating an invalid
/// native enum.
pub const Cell = packed struct(u64) {
    kind: u2 = @intFromEnum(Kind.codepoint),
    content: u24 = 0,
    style_id: u16 = 0,
    width: u2 = 0,
    protected: bool = false,
    hyperlink: bool = false,
    semantic_content: u2 = 0,
    hyperlink_id: u16 = 0,

    /// Determines how `content` is interpreted.
    pub const Kind = enum(u2) {
        codepoint = 0,
        codepoint_grapheme = 1,
        bg_color_palette = 2,
        bg_color_rgb = 3,
    };

    /// The encoded cell width declared by a row header: how many bytes
    /// transport each of the row's cell words. See the format
    /// documentation above for the value each width transports and the
    /// cells it admits.
    ///
    /// `truncate` and `extend` are the transport transform itself, so the
    /// admission masks derive from them rather than being maintained by
    /// hand: a cell word is admitted exactly when it round-trips.
    pub const EncodedWidth = enum(u2) {
        one = 0,
        two = 1,
        four = 2,
        eight = 3,

        /// The number of bytes transporting one cell word.
        pub fn size(self: EncodedWidth) usize {
            return @as(usize, 1) << @intFromEnum(self);
        }

        /// The integer type transporting one cell word.
        pub fn Int(comptime self: EncodedWidth) type {
            return switch (self) {
                .one => u8,
                .two => u16,
                .four => u32,
                .eight => u64,
            };
        }

        /// Truncate one cell word to its transported value. Only words
        /// admitted by this width round-trip; `select` proves that for
        /// every cell in a row before an encoder may use it.
        pub fn truncate(comptime self: EncodedWidth, word: u64) self.Int() {
            return @truncate(switch (self) {
                // The bare codepoint, shifted down from the content field.
                .one, .two => @as(Cell, @bitCast(word)).content,

                // The word itself.
                .four, .eight => word,
            });
        }

        /// Widen one transported value back to its cell word.
        pub fn extend(comptime self: EncodedWidth, value: self.Int()) u64 {
            return switch (self) {
                .one, .two => @bitCast(Cell{ .content = value }),
                .four, .eight => value,
            };
        }

        /// The word bits a cell may use and still round-trip through this
        /// width.
        pub fn mask(comptime self: EncodedWidth) u64 {
            return comptime self.extend(std.math.maxInt(self.Int()));
        }

        /// The smallest width admitting the word, typically the bitwise
        /// OR of every cell word in a row.
        pub fn select(word: u64) EncodedWidth {
            inline for ([_]EncodedWidth{ .one, .two, .four }) |width| {
                if (word & ~width.mask() == 0) return width;
            }
            return .eight;
        }
    };
};

/// Whether the native cell's in-memory layout matches the wire cell layout
/// bit for bit, with the wire hyperlink ID occupying the native padding.
///
/// The wire format does not require this: it is an optimization. When it
/// holds, whole rows encode and decode as bulk copies. If the native layout
/// ever diverges, the portable field-by-field codec below remains correct
/// and this constant simply becomes false.
const native_matches_wire = native: {
    if (@bitSizeOf(TerminalCell) != 64) break :native false;

    // The bulk copies above are only sound if we can prove the two layouts
    // agree, and we want native cell changes to demote us to the portable
    // codec automatically rather than corrupt snapshots.
    //
    // Instead of pinning every native field offset and enum value w/ assertions
    // that must be maintained by hand, each probe below pairs a native
    // cell with the wire cell that must share its exact bit pattern; both
    // sides bit cast to a word and any difference means some field moved
    // or some enum member was renumbered.
    //
    // Three probes, one per content payload, cover the whole cell.
    const probes = [_]struct {
        native: TerminalCell,
        wire: Cell,
    }{
        .{
            .native = .{
                .content_tag = .codepoint_grapheme,
                .content = .{ .codepoint = .{ .data = 0x10FFFF } },
                .style_id = 0xBEEF,
                .wide = .spacer_tail,
                .protected = true,
                ._padding = 0x1D2C,
            },
            .wire = .{
                .kind = 1,
                .content = 0x10FFFF,
                .style_id = 0xBEEF,
                .width = 2,
                .protected = true,
                // The native padding position, canonical wire or not.
                .hyperlink_id = 0x1D2C,
            },
        },
        .{
            .native = .{
                .content_tag = .bg_color_palette,
                .content = .{ .color_palette = .{ .data = 0xAB } },
                .wide = .spacer_head,
                .hyperlink = true,
                .semantic_content = .input,
            },
            .wire = .{
                .kind = 2,
                .content = 0xAB,
                .width = 3,
                .hyperlink = true,
                .semantic_content = 1,
            },
        },
        .{
            .native = .{
                .content_tag = .bg_color_rgb,
                .content = .{ .color_rgb = .{
                    .r = 0x12,
                    .g = 0x34,
                    .b = 0x56,
                } },
                .wide = .wide,
                .semantic_content = .prompt,
            },
            .wire = .{
                .kind = 3,
                .content = 0x563412,
                .width = 1,
                .semantic_content = 2,
            },
        },
    };
    for (probes) |probe| {
        const native_bits: u64 = @bitCast(probe.native);
        const wire_bits: u64 = @bitCast(probe.wire);
        if (native_bits != wire_bits) break :native false;
    }

    break :native true;
};

/// Whether rows of cells can be copied between native and wire storage
/// without per-cell transformation.
const bulk_codec = native_matches_wire and
    builtin.cpu.arch.endian() == .little;

pub const EncodeError = std.Io.Writer.Error || error{
    /// Wide and spacer cells do not form a valid row.
    InvalidWideCell,

    /// One cell's grapheme suffix exceeds the entry's u16 codepoint count.
    TooManyGraphemes,
};

/// Encode every row, cell, and grapheme suffix directly from a page.
///
/// If an error is returned, partial data may have been written. If you
/// want transactional writing, the caller is responsible for using something
/// like a seekable stream and rolling back.
pub fn encode(
    page: *const TerminalPage,
    writer: *std.Io.Writer,
) EncodeError!void {
    defer page.assertIntegrity();
    for (0..page.size.rows) |y| {
        const row = page.getRow(y);
        const cells = page.getCells(row);

        // Trailing default cells decode implicitly: wide/spacer pairs and
        // hyperlinked or styled cells are always nonzero, so eliding the
        // zero suffix never drops encoded state. The scan also accumulates
        // the OR of the row's cell words to select its encoded cell width.
        const count: usize, const word_or: u64 = scanRow(cells);

        // Validate the wide state of every encoded cell so we don't encode
        // corrupt data. The width bits of the OR word witness whether any
        // encoded cell is non-narrow at all; rows without them, the common
        // case, satisfy every pair rule vacuously. Trailing default cells
        // are narrow, so checking the encoded prefix against the full row
        // width covers every pair.
        const wide_mask: u64 = comptime @bitCast(Cell{ .width = 3 });
        if (word_or & wide_mask != 0) {
            for (cells[0..count], 0..) |*cell, x| switch (cell.wide) {
                .narrow => {},
                .wide => if (x + 1 == cells.len or
                    cells[x + 1].wide != .spacer_tail)
                {
                    return error.InvalidWideCell;
                },
                .spacer_tail => if (x == 0 or
                    cells[x - 1].wide != .wide)
                {
                    return error.InvalidWideCell;
                },
                .spacer_head => if (x + 1 != cells.len or !row.wrap) {
                    return error.InvalidWideCell;
                },
            };
        }

        // Canonical rows use the smallest admissible width.
        const cell_width: Cell.EncodedWidth = .select(word_or);

        const row_header: Row = .{
            .wrap = row.wrap,
            .wrap_continuation = row.wrap_continuation,
            .semantic_prompt = @intFromEnum(row.semantic_prompt),
            .cell_width = cell_width,
        };

        // The bulk codec emits the row header and its encoded cells directly
        // into the destination's spare buffer capacity, so a row costs no
        // writer call at all instead of one for the header and one per cell
        // chunk.
        if (comptime bulk_codec) emit: {
            const words: [*]const u64 = @ptrCast(cells.ptr);
            switch (cell_width) {
                inline .one, .two, .four => |width| {
                    const size = comptime width.size();
                    const needed = 3 + count * size;
                    if (writer.unusedCapacityLen() < needed) break :emit;
                    const out = writer.unusedCapacitySlice()[0..needed];
                    out[0] = @bitCast(row_header);
                    std.mem.writeInt(u16, out[1..3], @intCast(count), .little);
                    encodeNarrowInto(width, words, count, out[3..]);
                    writer.advance(needed);
                    continue;
                },
                .eight => {
                    // Hyperlink IDs live in a native side table, but we
                    // embed them in ours, so if we have any hyperlinks we
                    // need to fall back to the loop below.
                    const witness: Cell = @bitCast(word_or);
                    if (!witness.hyperlink and witness.hyperlink_id == 0) {
                        const needed = 3 + count * 8;
                        if (writer.unusedCapacityLen() < needed) break :emit;
                        const out = writer.unusedCapacitySlice()[0..needed];
                        out[0] = @bitCast(row_header);
                        std.mem.writeInt(
                            u16,
                            out[1..3],
                            @intCast(count),
                            .little,
                        );
                        @memcpy(
                            out[3..],
                            std.mem.sliceAsBytes(cells[0..count]),
                        );
                        writer.advance(needed);
                        continue;
                    }
                },
            }
        }

        // Row header: flags then the encoded cell count.
        {
            var header_bytes: [3]u8 = undefined;
            header_bytes[0] = @bitCast(row_header);
            std.mem.writeInt(u16, header_bytes[1..3], @intCast(count), .little);
            try writer.writeAll(&header_bytes);
        }

        switch (cell_width) {
            inline .one, .two, .four => |width| try encodeNarrowCells(
                width,
                cells[0..count],
                writer,
            ),

            .eight => {
                // Hyperlink IDs live in a native side table, but we embed
                // them in ours, so if we have any hyperlinks we need
                // to fallback to the loop below.
                if (comptime bulk_codec) {
                    const witness: Cell = @bitCast(word_or);
                    if (!witness.hyperlink and witness.hyperlink_id == 0) {
                        try writer.writeAll(std.mem.sliceAsBytes(cells[0..count]));
                        continue;
                    }
                }

                for (cells[0..count]) |*cell| {
                    const link_id: TerminalHyperlinkId = if (cell.hyperlink)
                        page.lookupHyperlink(cell) orelse unreachable
                    else
                        0;
                    try io.writeInt(
                        writer,
                        u64,
                        cellBits(cell.*, link_id),
                    );
                }
            },
        }
    }

    try encodeGraphemes(page, writer);
}

/// The encoded cell count (through the last nonzero cell) and the bitwise
/// OR of every encoded cell word for one row.
fn scanRow(cells: []const TerminalCell) struct { usize, u64 } {
    if (comptime bulk_codec) {
        const words: [*]const u64 = @ptrCast(cells.ptr);
        const V = @Vector(4, u64);
        const VPtr = *align(@alignOf(u64)) const V;

        // Count the zero cells using vectorized instructions
        var count = cells.len;
        while (count >= 4) {
            const tail = @as(VPtr, @ptrCast(words + count - 4)).*;
            if (@reduce(.Or, tail) != 0) break;
            count -= 4;
        }
        while (count > 0 and words[count - 1] == 0) count -= 1;

        // Accumulate the OR of the classifaction vectorized, with the
        // scalar tail continuing from where the vector loop stopped.
        const word_or: u64 = word_or: {
            var acc: V = @splat(0);
            var i: usize = 0;
            while (i + 4 <= count) : (i += 4) {
                acc |= @as(VPtr, @ptrCast(words + i)).*;
            }
            var word_or: u64 = @reduce(.Or, acc);
            while (i < count) : (i += 1) word_or |= words[i];
            break :word_or word_or;
        };

        return .{ count, word_or };
    }

    // Scalar path, count backwards
    var count: usize = cells.len;
    while (count > 0 and cells[count - 1].isZero()) count -= 1;
    var word_or: u64 = 0;
    for (cells[0..count]) |*cell| word_or |= classifyWord(cell);
    return .{ count, word_or };
}

/// The word used to select a row's encoded cell width. This is the cell's
/// wire word with the hyperlink flag reflecting the native cell, so linked
/// cells and nonzero native padding disqualify every narrow width.
inline fn classifyWord(cell: *const TerminalCell) u64 {
    if (comptime native_matches_wire) return @bitCast(cell.*);

    var wire: Cell = @bitCast(cellBits(cell.*, 0));
    wire.hyperlink = cell.hyperlink;
    return @bitCast(wire);
}

/// Write one row's cells truncated to the given encoded width.
///
/// Every admitted cell round-trips exactly because the row's width
/// selection proved every cell word survives `truncate` then `extend`.
fn encodeNarrowCells(
    comptime width: Cell.EncodedWidth,
    cells: []const TerminalCell,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const size = comptime width.size();
    var chunk: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < cells.len) {
        const n = @min(cells.len - i, chunk.len / size);
        for (cells[i..][0..n], 0..) |*cell, j| {
            std.mem.writeInt(
                width.Int(),
                chunk[j * size ..][0..size],
                width.truncate(classifyWord(cell)),
                .little,
            );
        }
        try writer.writeAll(chunk[0 .. n * size]);
        i += n;
    }
}

/// Truncate one row's cell words into `out` at the given encoded width.
fn encodeNarrowInto(
    comptime width: Cell.EncodedWidth,
    words: [*]const u64,
    count: usize,
    out: []u8,
) void {
    comptime assert(bulk_codec);
    const size = comptime width.size();
    const V = @Vector(2, u64);
    const shift: V = @splat(comptime switch (width) {
        .one, .two => @bitOffsetOf(Cell, "content"),
        .four => 0,
        .eight => unreachable,
    });
    const mask: @Vector(size * 4, i32) = comptime mask: {
        var mask: [size * 4]i32 = undefined;
        for (0..2) |lane| {
            for (0..size) |byte| {
                mask[lane * size + byte] = @intCast(lane * 8 + byte);
                mask[(lane + 2) * size + byte] =
                    ~@as(i32, @intCast(lane * 8 + byte));
            }
        }
        break :mask mask;
    };

    var j: usize = 0;
    while (j + 4 <= count) : (j += 4) encodeNarrowStep(
        width,
        words,
        j,
        out,
        shift,
        mask,
    );
    if (j < count) {
        if (count >= 4) {
            encodeNarrowStep(width, words, count - 4, out, shift, mask);
        } else {
            while (j < count) : (j += 1) {
                std.mem.writeInt(
                    width.Int(),
                    out[j * size ..][0..size],
                    width.truncate(words[j]),
                    .little,
                );
            }
        }
    }
}

/// Emit four truncated cell words starting at cell index `j`.
inline fn encodeNarrowStep(
    comptime width: Cell.EncodedWidth,
    words: [*]const u64,
    j: usize,
    out: []u8,
    shift: @Vector(2, u64),
    mask: @Vector(width.size() * 4, i32),
) void {
    const size = comptime width.size();
    const VPtr = *align(@alignOf(u64)) const @Vector(2, u64);
    const lo: @Vector(16, u8) = @bitCast(@as(VPtr, @ptrCast(words + j)).* >> shift);
    const hi: @Vector(16, u8) = @bitCast(@as(VPtr, @ptrCast(words + j + 2)).* >> shift);
    @as(
        *align(1) @Vector(size * 4, u8),
        @ptrCast(out[j * size ..].ptr),
    ).* = @shuffle(u8, lo, hi, mask);
}

/// Encode the grapheme suffix section for every kind 1 cell in the grid.
fn encodeGraphemes(
    page: *const TerminalPage,
    writer: *std.Io.Writer,
) EncodeError!void {
    // Every grapheme cell owns exactly one entry in the page's grapheme
    // map, so the section header comes straight from the page without a
    // counting pass over the grid. Rows without the native grapheme hint
    // contain no grapheme cells in any intact page.
    const entries = page.graphemeCount();
    try io.writeInt(writer, u32, @intCast(entries));
    if (entries == 0) return;

    // Entries are batched into a local buffer so hot pages perform one
    // writer call per flush instead of several per entry.
    var buffer: [4096]u8 = undefined;
    var used: usize = 0;
    var emitted: usize = 0;
    for (0..page.size.rows) |y| {
        const row = page.getRow(y);
        if (!row.grapheme) continue;
        for (page.getCells(row), 0..) |*cell, x| {
            if (!cell.hasGrapheme()) continue;
            const cps = page.lookupGrapheme(cell) orelse unreachable;
            if (cps.len > std.math.maxInt(u16)) return error.TooManyGraphemes;
            emitted += 1;

            const needed = 6 + cps.len * 4;
            if (buffer.len - used < needed) {
                try writer.writeAll(buffer[0..used]);
                used = 0;
            }
            if (needed > buffer.len) {
                // An entry larger than the whole buffer streams directly.
                try io.writeInt(writer, u16, @intCast(y));
                try io.writeInt(writer, u16, @intCast(x));
                try io.writeInt(writer, u16, @intCast(cps.len));
                for (cps) |cp| try io.writeInt(writer, u32, cp);
                continue;
            }

            std.mem.writeInt(u16, buffer[used..][0..2], @intCast(y), .little);
            std.mem.writeInt(u16, buffer[used + 2 ..][0..2], @intCast(x), .little);
            std.mem.writeInt(u16, buffer[used + 4 ..][0..2], @intCast(cps.len), .little);
            used += 6;
            for (cps) |cp| {
                std.mem.writeInt(u32, buffer[used..][0..4], cp, .little);
                used += 4;
            }
        }
    }
    try writer.writeAll(buffer[0..used]);

    // The declared count is trusted by decoders for framing, so the grid
    // must have produced exactly that many entries.
    assert(emitted == entries);
}

pub const DecodeError = std.Io.Reader.Error || error{
    /// A row declares more encoded cells than the grid has columns.
    InvalidRowCellCount,
};

/// Maps encoded style table IDs to page-assigned style IDs.
pub const StyleRemap = Remap(TerminalStyleId);

/// Maps encoded hyperlink table IDs to page-assigned hyperlink IDs.
pub const HyperlinkRemap = Remap(TerminalHyperlinkId);

/// Decode every row, cell, and grapheme suffix directly into an
/// initialized, empty page.
///
/// The grid does not encode dimensions, so `page` must already have the
/// exact row and column count expected by the containing record. Capacity
/// hints are advisory. Graphemes and cell hyperlink references that do not
/// fit are discarded without affecting the rest of the grid.
///
/// Style and hyperlink table entries must be inserted into `page` before
/// calling this function, with their encoded and page-assigned IDs recorded
/// in `style_remap` and `hyperlink_remap`. ID zero always means the default
/// style or no hyperlink. A nonzero ID missing from its remap is also
/// treated as zero so unknown table references do not prevent the rest of
/// the grid from decoding.
///
/// Invalid semantic data is normalized into a degraded form while
/// preserving the declared byte boundaries. Unknown semantic values use
/// their neutral variants, invalid Unicode becomes U+FFFD, invalid optional
/// data is ignored, and malformed wide-cell relationships become narrow
/// cells. The encoded cell count is the only structural field.
pub fn decode(
    page: *TerminalPage,
    reader: *std.Io.Reader,
    style_remap: *const StyleRemap,
    hyperlink_remap: *const HyperlinkRemap,
) DecodeError!void {
    for (0..page.size.rows) |y| {
        // Read the row header and cell count.
        const row_header: Row, const count: u16 = header: {
            // The staged payload path has every header buffered.
            var row_header_bytes: [3]u8 = undefined;
            if (reader.bufferedLen() >= 3) {
                row_header_bytes = reader.buffered()[0..3].*;
                reader.toss(3);
            } else {
                try reader.readSliceAll(&row_header_bytes);
            }

            // Every bit pattern is a valid header: booleans and the exhaustive
            // width enum decode directly, and the raw semantic value gets a
            // default below. Reserved bits do not change the known fields.
            const row_header: Row = @bitCast(row_header_bytes[0]);
            const count = std.mem.readInt(u16, row_header_bytes[1..3], .little);
            break :header .{ row_header, count };
        };

        // A fully default row needs no work at all: decoded pages start
        // zeroed, which is exactly the default row and cell state.
        if (@as(u8, @bitCast(row_header)) == 0 and count == 0) continue;

        // Update the row fields through one load and store instead of a
        // read-modify-write per packed field.
        const row = page.getRow(y);
        var row_value = row.*;
        row_value.wrap = row_header.wrap;
        row_value.wrap_continuation = row_header.wrap_continuation;
        row_value.semantic_prompt = std.enums.fromInt(
            TerminalRow.SemanticPrompt,
            row_header.semantic_prompt,
        ) orelse .none;
        row.* = row_value;

        const cells = page.getCells(row);
        if (count > cells.len) return error.InvalidRowCellCount;
        if (count == 0) continue;

        // The encoded cell width is framing: it determines exactly how many
        // bytes this row occupies.
        switch (row_header.cell_width) {
            inline .one, .two => |width| try decodeNarrowCells(
                width,
                reader,
                cells[0..count],
            ),
            .four => _ = try decodeWordCells(
                .four,
                page,
                row,
                cells,
                count,
                reader,
                style_remap,
                hyperlink_remap,
            ),
            .eight => {
                if (comptime bulk_codec) {
                    // Read the encoded words directly into page storage,
                    // then normalize them in place. The raw words are only
                    // ever touched as integers until normalization makes
                    // them valid cells.
                    const words: [*]u64 = @ptrCast(cells.ptr);
                    try reader.readSliceAll(
                        std.mem.sliceAsBytes(cells[0..count]),
                    );
                    var row_or: u64 = 0;
                    for (0..count) |x| {
                        row_or |= words[x];
                        applyCell(
                            page,
                            row,
                            cells,
                            x,
                            words[x],
                            style_remap,
                            hyperlink_remap,
                        );
                    }
                    normalizeWideRow(.eight, row, cells, count, row_or);
                } else {
                    _ = try decodeWordCells(
                        .eight,
                        page,
                        row,
                        cells,
                        count,
                        reader,
                        style_remap,
                        hyperlink_remap,
                    );
                }

                // The implicit cell after a short row is narrow, which
                // resolves a trailing wide marker exactly like an explicit
                // narrow neighbor. Only full-width rows can encode wide
                // markers.
                if (count < cells.len and cells[count - 1].wide == .wide) {
                    cells[count - 1].wide = .narrow;
                }
            },
        }
    }

    try decodeGraphemes(page, reader);
}

/// Decode one row of width-one or width-two cells.
///
/// These widths admit only bare codepoints, so cells store directly with at
/// most Unicode scalar validation: no styles, hyperlinks, wide pairs, or
/// row hints are reachable and no normalization state is needed.
fn decodeNarrowCells(
    comptime width: Cell.EncodedWidth,
    reader: *std.Io.Reader,
    cells: []TerminalCell,
) DecodeError!void {
    const size = comptime width.size();

    // The staged payload path has the complete row buffered, making this
    // one bounds check followed by a vectorizable widening loop.
    const total = cells.len * size;
    if (reader.bufferedLen() >= total) {
        widenCells(width, reader.buffered()[0..total], cells);
        reader.toss(total);
        return;
    }

    // Streaming sources fall back to bounded chunks.
    var chunk: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < cells.len) {
        const n = @min(cells.len - i, chunk.len / size);
        try reader.readSliceAll(chunk[0 .. n * size]);
        widenCells(width, chunk[0 .. n * size], cells[i..][0..n]);
        i += n;
    }
}

/// Store codepoint-valued encoded cells of the given width.
fn widenCells(
    comptime width: Cell.EncodedWidth,
    bytes: []const u8,
    cells: []TerminalCell,
) void {
    const size = comptime width.size();

    // With the bulk codec layout this is a pure widening store: sixteen
    // transported bytes per step, shuffling each pair of encoded values
    // into u64 lane position against a zero vector and shifting them into
    // the content field. Zig 0.16 disables loop auto-vectorization, so the
    // scalar loop would issue one widening store per cell.
    if (comptime bulk_codec) {
        const words: [*]u64 = @ptrCast(cells.ptr);
        const step = 16 / size;
        var i: usize = 0;
        while (i + step <= cells.len) : (i += step) {
            widenStep(width, bytes, words, i);
        }
        if (i < cells.len) {
            if (cells.len >= step) {
                // Reprocess the final full window with overlapping stores,
                // which rewrite the same widened values.
                widenStep(width, bytes, words, cells.len - step);
            } else {
                while (i < cells.len) : (i += 1) {
                    words[i] = width.extend(widenValue(width, bytes[i * size ..]));
                }
            }
        }
        return;
    }

    // When the native cell matches the wire word, this is a pure widening
    // loop over integers.
    if (comptime native_matches_wire) {
        const words: [*]u64 = @ptrCast(cells.ptr);
        for (0..cells.len) |i| {
            words[i] = width.extend(widenValue(width, bytes[i * size ..]));
        }
        return;
    }

    for (cells, 0..) |*cell, i| {
        storeCell(cell, width.extend(widenValue(width, bytes[i * size ..])));
    }
}

/// Widen sixteen transported bytes into their cell words at cell index `i`:
/// shuffle each pair of encoded values into u64 lane position against a
/// zero vector, then shift the value into the content field. Width two
/// first degrades surrogate lanes to U+FFFD, matching `widenValue`.
inline fn widenStep(
    comptime width: Cell.EncodedWidth,
    bytes: []const u8,
    words: [*]u64,
    i: usize,
) void {
    const size = comptime width.size();
    const step = 16 / size;

    var in: @Vector(16, u8) = @as(
        *align(1) const @Vector(16, u8),
        @ptrCast(bytes[i * size ..].ptr),
    ).*;

    // Width two admits surrogates, which degrade to U+FFFD exactly
    // like `widenValue`. Width one cannot encode an invalid scalar.
    if (comptime width == .two) {
        const values: @Vector(8, u16) = @bitCast(in);
        const invalid = (values & @as(@Vector(8, u16), @splat(0xF800))) ==
            @as(@Vector(8, u16), @splat(0xD800));
        in = @bitCast(@select(
            u16,
            invalid,
            @as(@Vector(8, u16), @splat(0xFFFD)),
            values,
        ));
    }

    const zero: @Vector(16, u8) = @splat(0);
    inline for (0..step / 2) |pair| {
        const mask: @Vector(16, i32) = comptime mask: {
            var mask: [16]i32 = @splat(~@as(i32, 0));
            for (0..size) |byte| {
                mask[byte] = @intCast((2 * pair) * size + byte);
                mask[8 + byte] = @intCast((2 * pair + 1) * size + byte);
            }
            break :mask mask;
        };
        const lanes: @Vector(2, u64) = @bitCast(
            @shuffle(u8, in, zero, mask),
        );
        @as(
            *align(@alignOf(u64)) @Vector(2, u64),
            @ptrCast(words + i + 2 * pair),
        ).* = lanes << @splat(@bitOffsetOf(Cell, "content"));
    }
}

/// Read and validate one narrow transported value.
inline fn widenValue(
    comptime width: Cell.EncodedWidth,
    bytes: []const u8,
) width.Int() {
    const size = comptime width.size();
    const value = std.mem.readInt(width.Int(), bytes[0..size], .little);

    // Width one cannot encode an invalid scalar. Width two admits
    // surrogates, which degrade exactly like their full-width form.
    if (comptime width != .one) {
        if (!validScalar(value)) return 0xFFFD;
    }
    return value;
}

/// Decode one row of width-four or fallback full-width cells through the
/// complete per-cell normalization path.
///
/// Returns the bitwise OR of every decoded wire word so callers can gate
/// the trailing wide-pair resolution pass without a second scan.
fn decodeWordCells(
    comptime width: Cell.EncodedWidth,
    page: *TerminalPage,
    row: *TerminalRow,
    cells: []TerminalCell,
    count: usize,
    reader: *std.Io.Reader,
    style_remap: *const StyleRemap,
    hyperlink_remap: *const HyperlinkRemap,
) DecodeError!u64 {
    const size = comptime width.size();
    var row_or: u64 = 0;

    // The staged payload path has the complete row buffered.
    const total = count * size;
    if (reader.bufferedLen() >= total) {
        const bytes = reader.buffered()[0..total];
        for (0..count) |x| {
            const bits = width.extend(std.mem.readInt(
                width.Int(),
                bytes[x * size ..][0..size],
                .little,
            ));
            row_or |= bits;
            applyCell(
                page,
                row,
                cells,
                x,
                bits,
                style_remap,
                hyperlink_remap,
            );
        }
        reader.toss(total);
        normalizeWideRow(width, row, cells, count, row_or);
        return row_or;
    }

    // Streaming sources fall back to per-cell reads.
    for (0..count) |x| {
        const bits = width.extend(try io.readInt(reader, width.Int()));
        row_or |= bits;
        applyCell(
            page,
            row,
            cells,
            x,
            bits,
            style_remap,
            hyperlink_remap,
        );
    }
    normalizeWideRow(width, row, cells, count, row_or);
    return row_or;
}

/// Resolve wide-pair relationships for one decoded row.
///
/// Cell decoding stores every cell unresolved, so this pass applies
/// `normalizeWide` in order, which is equivalent to interleaving it with
/// the stores. Rows whose word OR carries no wide bits are already
/// normalized: every cell is narrow. Width four and narrower transports
/// cannot encode wide bits at all, so those rows skip the check entirely.
inline fn normalizeWideRow(
    comptime width: Cell.EncodedWidth,
    row: *const TerminalRow,
    cells: []TerminalCell,
    count: usize,
    row_or: u64,
) void {
    if (comptime width != .eight) return;
    const wide_mask: u64 = comptime @bitCast(Cell{ .width = 3 });
    if (row_or & wide_mask == 0) return;
    for (0..count) |x| normalizeWide(row, cells, x);
}

/// Whether the value is a valid Unicode scalar value.
inline fn validScalar(cp: u32) bool {
    return cp <= 0x10FFFF and (cp < 0xD800 or cp > 0xDFFF);
}

/// Normalize one encoded cell word and store it at `cells[x]`.
///
/// This owns every per-cell decode rule except grapheme suffixes and
/// wide-pair resolution: content validation, reserved-value degradation,
/// and style and hyperlink remapping with reference counting. Callers run
/// `normalizeWideRow` over the stored row afterward.
fn applyCell(
    page: *TerminalPage,
    row: *TerminalRow,
    cells: []TerminalCell,
    x: usize,
    bits_wire: u64,
    style_remap: *const StyleRemap,
    hyperlink_remap: *const HyperlinkRemap,
) void {
    const cell = &cells[x];

    // The default cell is the common case and needs no normalization,
    // reference counting, or table lookups.
    if (bits_wire == 0) {
        storeCell(cell, 0);
        return;
    }

    // Any word is a valid wire cell because its fields are raw integers,
    // so all normalization below is plain field access.
    var wire: Cell = @bitCast(bits_wire);

    // Hyperlink linkage is derived from the remapped ID below. The stored
    // native cell starts unlinked either way.
    const link_encoded = wire.hyperlink_id;
    wire.hyperlink_id = 0;
    wire.hyperlink = false;

    switch (@as(Cell.Kind, @enumFromInt(wire.kind))) {
        // Kind 1 differs from 0 only by declaring a grapheme suffix section
        // entry, which reattaches through the native grapheme APIs later.
        .codepoint, .codepoint_grapheme => {
            wire.kind = @intFromEnum(Cell.Kind.codepoint);
            if (!validScalar(wire.content)) wire.content = 0xFFFD;

            // Kitty image and placement state is not part of this snapshot
            // version, but the placeholder is still a valid Unicode scalar.
            // Preserve it and derive the native row hint so later row
            // operations remain correct.
            if (wire.content == kitty_virtual_placeholder) {
                row.kitty_virtual_placeholder = true;
            }
        },

        // Only the palette index is meaningful; the remaining content bits
        // are reserved and must not obscure it.
        .bg_color_palette => wire.content = @as(u8, @truncate(wire.content)),

        .bg_color_rgb => {},
    }

    // Reserved semantic content degrades to plain output.
    wire.semantic_content = @intFromEnum(std.enums.fromInt(
        TerminalCell.SemanticContent,
        wire.semantic_content,
    ) orelse .output);

    // IDs belong to the encoded page. Translate them to IDs assigned by the
    // destination page before storing them on cells. The table owns one
    // reference and each decoded cell owns one additional reference.
    if (wire.style_id != 0) {
        wire.style_id = style_remap.get(wire.style_id);
        if (wire.style_id != 0) {
            page.styles.use(page.memory, wire.style_id);
            row.styled = true;
        }
    }

    storeCell(cell, @bitCast(wire));

    if (link_encoded != 0) link: {
        const link_native = hyperlink_remap.get(link_encoded);
        if (link_native == 0) break :link;

        // setHyperlink records the cell mapping but intentionally does not
        // increment the set's reference count. If its map is full, undo our
        // reference and leave this cell unlinked.
        page.hyperlink_set.use(page.memory, link_native);
        page.setHyperlink(row, cell, link_native) catch {
            page.hyperlink_set.release(page.memory, link_native);
        };
    }
}

/// Resolve wide-pair relationships for the cell at `x` against its already
/// normalized predecessors.
fn normalizeWide(row: *const TerminalRow, cells: []TerminalCell, x: usize) void {
    // A following cell resolves whether the previous wide marker owns a
    // tail. Normalize the current marker immediately when possible,
    // including a wide marker at the row end.
    if (x > 0 and
        cells[x - 1].wide == .wide and
        cells[x].wide != .spacer_tail)
    {
        cells[x - 1].wide = .narrow;
    }
    switch (cells[x].wide) {
        .narrow => {},

        // A non-final wide marker remains pending until the next cell.
        .wide => if (x + 1 == cells.len) {
            cells[x].wide = .narrow;
        },

        .spacer_tail => if (x == 0 or
            cells[x - 1].wide != .wide)
        {
            cells[x].wide = .narrow;
        },

        .spacer_head => if (x + 1 != cells.len or !row.wrap) {
            cells[x].wide = .narrow;
        },
    }
}

/// Decode the grapheme suffix section into already decoded cells.
fn decodeGraphemes(
    page: *TerminalPage,
    reader: *std.Io.Reader,
) DecodeError!void {
    const entries = try io.readInt(reader, u32);
    for (0..entries) |_| {
        // The staged and borrowed payload paths have every header buffered.
        const y: u16, const x: u16, const cp_count: u16 = header: {
            if (reader.bufferedLen() >= 6) {
                const bytes = reader.buffered()[0..6];
                defer reader.toss(6);
                break :header .{
                    std.mem.readInt(u16, bytes[0..2], .little),
                    std.mem.readInt(u16, bytes[2..4], .little),
                    std.mem.readInt(u16, bytes[4..6], .little),
                };
            }
            break :header .{
                try io.readInt(reader, u16),
                try io.readInt(reader, u16),
                try io.readInt(reader, u16),
            };
        };

        // Resolve the target cell. Entries whose target cannot carry a
        // suffix are optional detail: their codepoints are consumed to
        // preserve framing and then dropped.
        const target: ?struct {
            row: *TerminalRow,
            cell: *TerminalCell,
        } = target: {
            if (y >= page.size.rows or x >= page.size.cols) {
                break :target null;
            }
            const row = page.getRow(y);
            const cell = &page.getCells(row)[x];

            // Cell decoding stores every kind 1 cell as a plain codepoint,
            // so this also gives duplicate entries first-wins semantics.
            if (cell.content_tag != .codepoint) break :target null;
            if (cell.content.codepoint.data == 0) break :target null;
            break :target .{ .row = row, .cell = cell };
        };

        // Always consume every declared codepoint. Invalid scalars and NUL
        // are not meaningful grapheme suffix components and are ignored. A
        // dropped entry's codepoints are discarded in bulk.
        const resolved = target orelse {
            try reader.discardAll(@as(usize, cp_count) * 4);
            continue;
        };

        var accept = true;
        var index: usize = 0;
        while (index < cp_count) {
            const buffered = reader.buffered();
            if (buffered.len >= 4) {
                const n = @min(cp_count - index, buffered.len / 4);
                for (0..n) |i| applyGraphemeSuffix(
                    page,
                    resolved.row,
                    resolved.cell,
                    &accept,
                    std.mem.readInt(u32, buffered[i * 4 ..][0..4], .little),
                );
                reader.toss(n * 4);
                index += n;
            } else {
                applyGraphemeSuffix(
                    page,
                    resolved.row,
                    resolved.cell,
                    &accept,
                    try io.readInt(reader, u32),
                );
                index += 1;
            }
        }
    }
}

/// Attach one decoded suffix codepoint to its resolved target cell.
///
/// If native capacity is exhausted, any prefix already attached is removed
/// so the cell never exposes a truncated cluster, and `accept` latches
/// false so the entry's remaining codepoints are consumed but dropped.
fn applyGraphemeSuffix(
    page: *TerminalPage,
    row: *TerminalRow,
    cell: *TerminalCell,
    accept: *bool,
    cp: u32,
) void {
    if (!accept.*) return;
    if (cp == 0 or !validScalar(cp)) return;

    page.appendGrapheme(row, cell, @intCast(cp)) catch {
        if (cell.hasGrapheme()) {
            page.clearGrapheme(cell);
            page.updateRowGraphemeFlag(row);
        }
        accept.* = false;
    };
}

/// The encoded word for one native cell and its hyperlink ID.
fn cellBits(cell: TerminalCell, link_id: TerminalHyperlinkId) u64 {
    if (comptime native_matches_wire) {
        var wire: Cell = @bitCast(cell);
        wire.hyperlink = link_id != 0;
        wire.hyperlink_id = link_id;
        return @bitCast(wire);
    }

    const wire: Cell = .{
        .kind = @intFromEnum(cell.content_tag),
        .content = switch (cell.content_tag) {
            .codepoint,
            .codepoint_grapheme,
            => cell.content.codepoint.data,
            .bg_color_palette => cell.content.color_palette.data,
            .bg_color_rgb => @as(u24, cell.content.color_rgb.r) |
                (@as(u24, cell.content.color_rgb.g) << 8) |
                (@as(u24, cell.content.color_rgb.b) << 16),
        },
        .style_id = cell.style_id,
        .width = switch (cell.wide) {
            .narrow => 0,
            .wide => 1,
            .spacer_tail => 2,
            .spacer_head => 3,
        },
        .protected = cell.protected,
        .hyperlink = link_id != 0,
        .semantic_content = switch (cell.semantic_content) {
            .output => 0,
            .input => 1,
            .prompt => 2,
        },
        .hyperlink_id = link_id,
    };
    return @bitCast(wire);
}

/// Store one normalized, hyperlink-free wire word as a native cell.
fn storeCell(cell: *TerminalCell, bits: u64) void {
    if (comptime native_matches_wire) {
        const words: [*]u64 = @ptrCast(cell);
        words[0] = bits;
        return;
    }

    const wire: Cell = @bitCast(bits);
    var native: TerminalCell = .init(0);
    switch (@as(Cell.Kind, @enumFromInt(wire.kind))) {
        .codepoint, .codepoint_grapheme => native.content = .{
            .codepoint = .{ .data = @intCast(wire.content) },
        },
        .bg_color_palette => {
            native.content_tag = .bg_color_palette;
            native.content = .{
                .color_palette = .{ .data = @truncate(wire.content) },
            };
        },
        .bg_color_rgb => {
            native.content_tag = .bg_color_rgb;
            native.content = .{ .color_rgb = .{
                .r = @truncate(wire.content),
                .g = @truncate(wire.content >> 8),
                .b = @truncate(wire.content >> 16),
            } };
        },
    }
    native.style_id = wire.style_id;
    native.wide = @enumFromInt(wire.width);
    native.protected = wire.protected;
    native.semantic_content = @enumFromInt(wire.semantic_content);
    cell.* = native;
}

/// Maps encoded table IDs to IDs assigned by the destination page.
///
/// Build this by inserting each decoded table entry into the page, then
/// recording the encoded ID and the ID returned by the page's set. ID zero
/// is implicit and does not need an entry. Lookup must be cheap because the
/// grid decoder consults it for every styled or linked cell, so this is a
/// direct-indexed table rather than a hash map.
fn Remap(comptime Id: type) type {
    return struct {
        const Self = @This();

        /// One slot for every possible encoded ID.
        pub const capacity = std.math.maxInt(Id) + 1;

        /// Indexed by encoded ID; zero means unmapped or default.
        entries: []Id,

        /// Tracks IDs that received an entry, including ones mapped to the
        /// default, so callers can give duplicate table entries first-wins
        /// semantics.
        seen: std.DynamicBitSetUnmanaged,

        /// A remap with no entries at all: every lookup is unmapped. Use
        /// this instead of `init` when the encoded table is empty so pages
        /// without styles or hyperlinks allocate nothing.
        pub const empty: Self = .{ .entries = &.{}, .seen = .{} };

        pub fn init(alloc: Allocator) Allocator.Error!Self {
            const entries = try alloc.alloc(Id, capacity);
            errdefer alloc.free(entries);
            @memset(entries, 0);
            const seen = try std.DynamicBitSetUnmanaged.initEmpty(
                alloc,
                capacity,
            );
            return .{ .entries = entries, .seen = seen };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            if (self.entries.len != 0) {
                alloc.free(self.entries);
                self.seen.deinit(alloc);
            }
            self.* = undefined;
        }

        /// Record one encoded-to-native mapping. Illegal on `empty`.
        pub fn put(self: *Self, encoded: Id, native: Id) void {
            assert(!self.seen.isSet(encoded));
            self.entries[encoded] = native;
            self.seen.set(encoded);
        }

        /// Whether the encoded ID already has an entry, even a default
        /// one. Illegal on `empty`.
        pub fn contains(self: *const Self, encoded: Id) bool {
            return self.seen.isSet(encoded);
        }

        /// The native ID for an encoded ID, or zero when unmapped.
        pub inline fn get(self: *const Self, encoded: Id) Id {
            if (self.entries.len == 0) return 0;
            return self.entries[encoded];
        }
    };
}
const test_golden_fixture = test_fixture.parse(
    @embedFile("testdata/grid-v1.hex"),
);

test "cell wire layout registry" {
    const testing = std.testing;

    // The wire bit positions are format constants. The shifts and masks
    // derive from the packed struct, so pin the struct itself to the
    // documented registry so an edit cannot silently move wire bits.
    try testing.expectEqual(0, @bitOffsetOf(Cell, "kind"));
    try testing.expectEqual(2, @bitOffsetOf(Cell, "content"));
    try testing.expectEqual(26, @bitOffsetOf(Cell, "style_id"));
    try testing.expectEqual(42, @bitOffsetOf(Cell, "width"));
    try testing.expectEqual(44, @bitOffsetOf(Cell, "protected"));
    try testing.expectEqual(45, @bitOffsetOf(Cell, "hyperlink"));
    try testing.expectEqual(46, @bitOffsetOf(Cell, "semantic_content"));
    try testing.expectEqual(48, @bitOffsetOf(Cell, "hyperlink_id"));

    // The native cell currently matches the wire registry, which enables
    // the bulk row codec. If this fails, the native layout diverged: either
    // restore it or accept the portable codec and update this expectation.
    try testing.expect(native_matches_wire);
}

test "encoded cell width transport registry" {
    const testing = std.testing;

    // Pin the transported value and admission mask of every width against
    // the documented format: widths one and two carry the bare codepoint,
    // width four the low word half, width eight the complete word.
    const word: u64 = @bitCast(Cell{
        .kind = 1,
        .content = 0xABCDEF,
        .style_id = 0x1234,
        .hyperlink_id = 0x5678,
    });
    try testing.expectEqual(@as(u8, 0xEF), Cell.EncodedWidth.one.truncate(word));
    try testing.expectEqual(@as(u16, 0xCDEF), Cell.EncodedWidth.two.truncate(word));
    try testing.expectEqual(
        @as(u32, @truncate(word)),
        Cell.EncodedWidth.four.truncate(word),
    );
    try testing.expectEqual(word, Cell.EncodedWidth.eight.truncate(word));

    try testing.expectEqual(
        @as(u64, 0x0000_0000_0000_03FC),
        Cell.EncodedWidth.one.mask(),
    );
    try testing.expectEqual(
        @as(u64, 0x0000_0000_0003_FFFC),
        Cell.EncodedWidth.two.mask(),
    );
    try testing.expectEqual(
        @as(u64, 0x0000_0000_FFFF_FFFF),
        Cell.EncodedWidth.four.mask(),
    );
    try testing.expectEqual(
        @as(u64, 0xFFFF_FFFF_FFFF_FFFF),
        Cell.EncodedWidth.eight.mask(),
    );

    // Selection returns the smallest admissible width, and every admitted
    // word round-trips through its transport.
    const cases = [_]struct { cell: Cell, width: Cell.EncodedWidth }{
        .{ .cell = .{}, .width = .one },
        .{ .cell = .{ .content = 0xFF }, .width = .one },
        .{ .cell = .{ .content = 0x100 }, .width = .two },
        .{ .cell = .{ .content = 0xFFFF }, .width = .two },
        .{ .cell = .{ .content = 0x10000 }, .width = .four },
        .{ .cell = .{ .kind = 2, .content = 7 }, .width = .four },
        .{ .cell = .{ .content = 'a', .style_id = 63 }, .width = .four },
        .{ .cell = .{ .content = 'a', .style_id = 64 }, .width = .eight },
        .{ .cell = .{ .width = 1, .content = 'a' }, .width = .eight },
        .{ .cell = .{ .protected = true }, .width = .eight },
        .{ .cell = .{ .semantic_content = 1 }, .width = .eight },
        .{ .cell = .{ .hyperlink = true, .hyperlink_id = 1 }, .width = .eight },
    };
    inline for (cases) |case| {
        const case_word: u64 = @bitCast(case.cell);
        try testing.expectEqual(
            case.width,
            Cell.EncodedWidth.select(case_word),
        );
        try testing.expectEqual(
            case_word,
            case.width.extend(case.width.truncate(case_word)),
        );
    }
}

test "grid golden encoding and decoding" {
    const capacity: terminal_page.Capacity = .{
        .cols = 3,
        .rows = 4,
        .styles = 0,
        .hyperlink_bytes = 0,
        .grapheme_bytes = 64,
        .string_bytes = 0,
    };
    var source = try TerminalPage.init(capacity);
    defer source.deinit();

    // The first row covers semantic metadata, a wide-cell pair, and a
    // multi-codepoint grapheme.
    const wide = source.getRowAndCell(0, 0);
    wide.row.semantic_prompt = .prompt;
    wide.cell.* = .init('A');
    wide.cell.wide = .wide;
    wide.cell.protected = true;
    wide.cell.semantic_content = .prompt;

    const tail = source.getRowAndCell(1, 0);
    tail.cell.wide = .spacer_tail;
    tail.cell.semantic_content = .input;

    const grapheme = source.getRowAndCell(2, 0);
    grapheme.cell.* = .init('x');
    try source.setGraphemes(
        grapheme.row,
        grapheme.cell,
        &.{ 0x0301, 0x0302 },
    );

    // The second row covers both background-color kinds and a wrapped spacer
    // head with the remaining row semantic value.
    const palette = source.getRowAndCell(0, 1);
    palette.cell.content_tag = .bg_color_palette;
    palette.cell.content = .{ .color_palette = .{ .data = 7 } };

    const rgb = source.getRowAndCell(1, 1);
    rgb.cell.content_tag = .bg_color_rgb;
    rgb.cell.content = .{ .color_rgb = .{
        .r = 0xaa,
        .g = 0xbb,
        .b = 0xcc,
    } };
    rgb.cell.protected = true;

    const head = source.getRowAndCell(2, 1);
    head.cell.wide = .spacer_head;
    head.row.wrap = true;
    head.row.wrap_continuation = true;
    head.row.semantic_prompt = .prompt_continuation;

    // The third row is bare ASCII text with an interior blank, which uses
    // the one-byte encoded cell width.
    source.getRowAndCell(0, 2).cell.* = .init('h');
    source.getRowAndCell(2, 2).cell.* = .init('i');

    // The fourth row needs the two-byte width for a codepoint above U+00FF.
    source.getRowAndCell(0, 3).cell.* = .init(0x0416); // Ж
    source.getRowAndCell(1, 3).cell.* = .init('!');

    var encoded: [160]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try encode(&source, &writer);
    try test_fixture.expectEqual(
        .bytes,
        "src/terminal/snapshot/testdata/grid-v1.hex",
        "snapshot_fixture-grid-v1.hex",
        &test_golden_fixture,
        writer.buffered(),
    );

    var destination = try TerminalPage.init(capacity);
    defer destination.deinit();
    var style_remap = try StyleRemap.init(std.testing.allocator);
    defer style_remap.deinit(std.testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(std.testing.allocator);
    defer hyperlink_remap.deinit(std.testing.allocator);

    // Decode the checked-in reference through a one-byte reader buffer.
    var fixture_reader: std.Io.Reader = .fixed(&test_golden_fixture);
    var read_buffer: [1]u8 = undefined;
    var limited = fixture_reader.limited(.unlimited, &read_buffer);
    try decode(
        &destination,
        &limited.interface,
        &style_remap,
        &hyperlink_remap,
    );
    try destination.verifyIntegrity(std.testing.allocator);

    const decoded_wide = destination.getRowAndCell(0, 0);
    try std.testing.expectEqual(@as(u21, 'A'), decoded_wide.cell.codepoint());
    try std.testing.expectEqual(TerminalCell.Wide.wide, decoded_wide.cell.wide);
    try std.testing.expect(decoded_wide.cell.protected);
    try std.testing.expectEqual(
        TerminalCell.SemanticContent.prompt,
        decoded_wide.cell.semantic_content,
    );
    try std.testing.expectEqual(
        TerminalRow.SemanticPrompt.prompt,
        decoded_wide.row.semantic_prompt,
    );

    const decoded_tail = destination.getRowAndCell(1, 0);
    try std.testing.expectEqual(
        TerminalCell.Wide.spacer_tail,
        decoded_tail.cell.wide,
    );
    try std.testing.expectEqual(
        TerminalCell.SemanticContent.input,
        decoded_tail.cell.semantic_content,
    );

    const decoded_grapheme = destination.getRowAndCell(2, 0);
    try std.testing.expectEqualSlices(
        u21,
        &.{ 0x0301, 0x0302 },
        destination.lookupGrapheme(decoded_grapheme.cell).?,
    );

    const decoded_palette = destination.getRowAndCell(0, 1);
    try std.testing.expectEqual(
        TerminalCell.ContentTag.bg_color_palette,
        decoded_palette.cell.content_tag,
    );
    try std.testing.expectEqual(
        @as(u8, 7),
        decoded_palette.cell.content.color_palette.data,
    );

    const decoded_rgb = destination.getRowAndCell(1, 1);
    try std.testing.expectEqual(
        TerminalCell.ContentTag.bg_color_rgb,
        decoded_rgb.cell.content_tag,
    );
    try std.testing.expectEqual(
        TerminalCell.RGB{ .r = 0xaa, .g = 0xbb, .b = 0xcc },
        decoded_rgb.cell.content.color_rgb,
    );
    try std.testing.expect(decoded_rgb.cell.protected);

    const decoded_head = destination.getRowAndCell(2, 1);
    try std.testing.expectEqual(
        TerminalCell.Wide.spacer_head,
        decoded_head.cell.wide,
    );
    try std.testing.expect(decoded_head.row.wrap);
    try std.testing.expect(decoded_head.row.wrap_continuation);
    try std.testing.expectEqual(
        TerminalRow.SemanticPrompt.prompt_continuation,
        decoded_head.row.semantic_prompt,
    );

    try std.testing.expectEqual(
        @as(u21, 'h'),
        destination.getRowAndCell(0, 2).cell.codepoint(),
    );
    try std.testing.expect(destination.getRowAndCell(1, 2).cell.isZero());
    try std.testing.expectEqual(
        @as(u21, 'i'),
        destination.getRowAndCell(2, 2).cell.codepoint(),
    );
    try std.testing.expectEqual(
        @as(u21, 0x0416),
        destination.getRowAndCell(0, 3).cell.codepoint(),
    );
    try std.testing.expectEqual(
        @as(u21, '!'),
        destination.getRowAndCell(1, 3).cell.codepoint(),
    );

    // A re-encode proves the decoded native page retains every wire field.
    var reencoded: [160]u8 = undefined;
    var rewriter: std.Io.Writer = .fixed(&reencoded);
    try encode(&destination, &rewriter);
    try std.testing.expectEqualStrings(
        &test_golden_fixture,
        rewriter.buffered(),
    );
}

test "grid elides trailing default cells" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{ .cols = 80, .rows = 3 });
    defer page.deinit();

    // Row 0 is fully default. Row 1 has content in columns zero and two.
    // Row 2 has one protected-only cell at column four.
    const middle = page.getRowAndCell(2, 1);
    middle.cell.* = .init('b');
    page.getRowAndCell(0, 1).cell.* = .init('a');
    page.getRowAndCell(4, 2).cell.protected = true;

    var encoded: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try encode(&page, &writer);

    // 3 bytes per row header and cells only through the last non-default
    // cell, followed by an empty grapheme section. The text row uses the
    // one-byte width while the protected flag forces the full width.
    try testing.expectEqual(
        @as(usize, 3 + (3 + 3 * 1) + (3 + 5 * 8) + 4),
        writer.buffered().len,
    );

    var destination = try TerminalPage.init(.{ .cols = 80, .rows = 3 });
    defer destination.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);

    var reader: std.Io.Reader = .fixed(writer.buffered());
    try decode(&destination, &reader, &style_remap, &hyperlink_remap);
    try destination.verifyIntegrity(testing.allocator);

    try testing.expectEqual(
        @as(u21, 'a'),
        destination.getRowAndCell(0, 1).cell.codepoint(),
    );
    try testing.expectEqual(
        @as(u21, 'b'),
        destination.getRowAndCell(2, 1).cell.codepoint(),
    );
    try testing.expect(destination.getRowAndCell(4, 2).cell.protected);
    try testing.expect(destination.getRowAndCell(79, 1).cell.isZero());
}

test "grid rejects a row cell count above the column count" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{ .cols = 2, .rows = 1 });
    defer page.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);

    var payload: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&payload);
    try writer.writeByte(@bitCast(Row{}));
    try io.writeInt(&writer, u16, 3);
    for (0..3) |_| try io.writeInt(&writer, u64, 0);
    try io.writeInt(&writer, u32, 0);

    var reader: std.Io.Reader = .fixed(writer.buffered());
    try testing.expectError(
        error.InvalidRowCellCount,
        decode(&page, &reader, &style_remap, &hyperlink_remap),
    );
}

test "grid normalizes incomplete wide cells" {
    const testing = std.testing;
    // One column puts the wide cell at the row end. Two columns put an
    // ordinary narrow cell after it. Neither case supplies a spacer tail.
    // Both rely on the implicit narrow cell rule when the tail is elided.
    for ([_]u16{ 1, 2 }) |columns| {
        const capacity: terminal_page.Capacity = .{
            .cols = columns,
            .rows = 1,
        };

        // Craft the malformed row directly on the wire. Decoding keeps its
        // content but makes the incomplete wide cell narrow.
        var payload: [64]u8 = undefined;
        var payload_writer: std.Io.Writer = .fixed(&payload);
        try payload_writer.writeByte(@bitCast(Row{ .cell_width = .eight }));
        try io.writeInt(&payload_writer, u16, columns);
        try io.writeInt(&payload_writer, u64, @bitCast(Cell{
            .width = 1, // wide
            .content = 'A',
        }));
        if (columns > 1) try io.writeInt(&payload_writer, u64, @bitCast(Cell{
            .content = 'B',
        }));
        try io.writeInt(&payload_writer, u32, 0);

        var destination = try TerminalPage.init(capacity);
        defer destination.deinit();
        var style_remap = try StyleRemap.init(testing.allocator);
        defer style_remap.deinit(testing.allocator);
        var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
        defer hyperlink_remap.deinit(testing.allocator);

        var payload_reader: std.Io.Reader = .fixed(
            payload_writer.buffered(),
        );
        try decode(
            &destination,
            &payload_reader,
            &style_remap,
            &hyperlink_remap,
        );
        try destination.verifyIntegrity(testing.allocator);

        try testing.expectEqual(
            @as(u21, 'A'),
            destination.getRowAndCell(0, 0).cell.codepoint(),
        );
        try testing.expectEqual(
            TerminalCell.Wide.narrow,
            destination.getRowAndCell(0, 0).cell.wide,
        );
        if (columns > 1) {
            const second = destination.getRowAndCell(1, 0).cell;
            try testing.expectEqual(@as(u21, 'B'), second.codepoint());
            try testing.expectEqual(TerminalCell.Wide.narrow, second.wide);
        }
    }

    // A wide marker whose spacer tail was elided by a short cell count is
    // also normalized, and the trailing cells stay default.
    var page = try TerminalPage.init(.{ .cols = 4, .rows = 1 });
    defer page.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);

    var payload: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&payload);
    try writer.writeByte(@bitCast(Row{ .cell_width = .eight }));
    try io.writeInt(&writer, u16, 1);
    try io.writeInt(&writer, u64, @bitCast(Cell{
        .width = 1, // wide
        .content = 'W',
    }));
    try io.writeInt(&writer, u32, 0);

    var reader: std.Io.Reader = .fixed(writer.buffered());
    try decode(&page, &reader, &style_remap, &hyperlink_remap);
    try page.verifyIntegrity(testing.allocator);
    try testing.expectEqual(
        TerminalCell.Wide.narrow,
        page.getRowAndCell(0, 0).cell.wide,
    );
    try testing.expect(page.getRowAndCell(1, 0).cell.isZero());
}

test "grid normalizes reserved cell values" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{ .cols = 3, .rows = 1 });
    defer page.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);

    var payload: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&payload);

    // Reserved row flag bits six and seven are ignored while the unknown
    // semantic-prompt value degrades to none and wrap survives. Bits four
    // and five select the full encoded cell width.
    try writer.writeByte(0xFD);
    try io.writeInt(&writer, u16, 3);

    // A surrogate codepoint with reserved semantic content 3.
    try io.writeInt(&writer, u64, @bitCast(Cell{
        .content = 0xD800,
        .semantic_content = 3,
    }));

    // Reserved palette content bits do not obscure the palette index.
    try io.writeInt(&writer, u64, @bitCast(Cell{
        .kind = 2,
        .content = 0xFFFF07,
    }));

    // An unknown style reference degrades to the default style, and an
    // unknown hyperlink reference leaves the cell unlinked.
    try io.writeInt(&writer, u64, @bitCast(Cell{
        .content = 'x',
        .style_id = 5,
        .hyperlink = true,
        .hyperlink_id = 9,
    }));
    try io.writeInt(&writer, u32, 0);

    var reader: std.Io.Reader = .fixed(writer.buffered());
    try decode(&page, &reader, &style_remap, &hyperlink_remap);
    try page.verifyIntegrity(testing.allocator);

    const first = page.getRowAndCell(0, 0);
    try testing.expect(first.row.wrap);
    try testing.expectEqual(
        TerminalRow.SemanticPrompt.none,
        first.row.semantic_prompt,
    );
    try testing.expectEqual(@as(u21, 0xFFFD), first.cell.codepoint());
    try testing.expectEqual(
        TerminalCell.SemanticContent.output,
        first.cell.semantic_content,
    );

    const second = page.getRowAndCell(1, 0).cell;
    try testing.expectEqual(
        TerminalCell.ContentTag.bg_color_palette,
        second.content_tag,
    );
    try testing.expectEqual(@as(u8, 7), second.content.color_palette.data);

    const third = page.getRowAndCell(2, 0).cell;
    try testing.expectEqual(@as(u21, 'x'), third.codepoint());
    try testing.expectEqual(@as(TerminalStyleId, 0), third.style_id);
    try testing.expect(!third.hyperlink);
    try testing.expectEqual(null, page.lookupHyperlink(third));
}

test "grid drops undeliverable grapheme entries" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{
        .cols = 4,
        .rows = 1,
        .grapheme_bytes = 64,
    });
    defer page.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);

    var payload: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&payload);
    try writer.writeByte(@bitCast(Row{ .cell_width = .eight }));
    try io.writeInt(&writer, u16, 4);
    // A kind 1 cell that receives a valid entry.
    try io.writeInt(&writer, u64, @bitCast(Cell{ .kind = 1, .content = 'x' }));
    // A kind 1 cell without an entry decodes as a plain codepoint.
    try io.writeInt(&writer, u64, @bitCast(Cell{ .kind = 1, .content = 'y' }));
    // A background cell cannot carry a suffix.
    try io.writeInt(&writer, u64, @bitCast(Cell{ .kind = 2, .content = 7 }));
    // An empty codepoint cannot carry a suffix.
    try io.writeInt(&writer, u64, @bitCast(Cell{}));

    try io.writeInt(&writer, u32, 5);
    // Valid entry with one invalid scalar dropped from within it.
    try io.writeInt(&writer, u16, 0);
    try io.writeInt(&writer, u16, 0);
    try io.writeInt(&writer, u16, 4);
    try io.writeInt(&writer, u32, 0x0301);
    try io.writeInt(&writer, u32, 0);
    try io.writeInt(&writer, u32, 0xD800);
    try io.writeInt(&writer, u32, 0x0302);
    // Duplicate entry for the same cell is consumed and dropped.
    try io.writeInt(&writer, u16, 0);
    try io.writeInt(&writer, u16, 0);
    try io.writeInt(&writer, u16, 1);
    try io.writeInt(&writer, u32, 0x0303);
    // Entry for the background cell is consumed and dropped.
    try io.writeInt(&writer, u16, 0);
    try io.writeInt(&writer, u16, 2);
    try io.writeInt(&writer, u16, 1);
    try io.writeInt(&writer, u32, 0x0301);
    // Entry for the empty cell is consumed and dropped.
    try io.writeInt(&writer, u16, 0);
    try io.writeInt(&writer, u16, 3);
    try io.writeInt(&writer, u16, 1);
    try io.writeInt(&writer, u32, 0x0301);
    // Entry outside the grid is consumed and dropped.
    try io.writeInt(&writer, u16, 7);
    try io.writeInt(&writer, u16, 0);
    try io.writeInt(&writer, u16, 1);
    try io.writeInt(&writer, u32, 0x0301);

    var reader: std.Io.Reader = .fixed(writer.buffered());
    try decode(&page, &reader, &style_remap, &hyperlink_remap);
    try page.verifyIntegrity(testing.allocator);

    const first = page.getRowAndCell(0, 0);
    try testing.expectEqualSlices(
        u21,
        &.{ 0x0301, 0x0302 },
        page.lookupGrapheme(first.cell).?,
    );
    const second = page.getRowAndCell(1, 0).cell;
    try testing.expectEqual(@as(u21, 'y'), second.codepoint());
    try testing.expect(!second.hasGrapheme());
    try testing.expect(!page.getRowAndCell(2, 0).cell.hasGrapheme());
    try testing.expect(!page.getRowAndCell(3, 0).cell.hasGrapheme());
}

test "grid drops a complete grapheme when capacity fails mid-cluster" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{
        .cols = 4,
        .rows = 1,
        .grapheme_bytes = 512,
    });
    defer page.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);

    var payload: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&payload);
    try writer.writeByte(@bitCast(Row{ .cell_width = .eight }));
    try io.writeInt(&writer, u16, 4);
    for (0..4) |i| try io.writeInt(
        &writer,
        u64,
        @bitCast(Cell{ .kind = 1, .content = @intCast('x' + i) }),
    );

    // BitmapAllocator rounds this capacity to 64 four-codepoint chunks. The
    // first three cells consume 34 chunks. On the fourth cell, appending the
    // 61st suffix needs 16 new chunks while the old 15-chunk slice is still
    // live, exceeding capacity and forcing the complete suffix to be dropped.
    try io.writeInt(&writer, u32, 4);
    for ([_]u16{ 64, 64, 8, 61 }, 0..) |count, x| {
        try io.writeInt(&writer, u16, 0);
        try io.writeInt(&writer, u16, @intCast(x));
        try io.writeInt(&writer, u16, count);
        for (0..count) |i| try io.writeInt(
            &writer,
            u32,
            @intCast(0x0300 + i),
        );
    }

    var reader: std.Io.Reader = .fixed(writer.buffered());
    try decode(&page, &reader, &style_remap, &hyperlink_remap);
    try page.verifyIntegrity(testing.allocator);

    const cell = page.getRowAndCell(3, 0);
    try testing.expectEqual(@as(u21, @intCast('x' + 3)), cell.cell.codepoint());
    try testing.expect(!cell.cell.hasGrapheme());
    try testing.expect(cell.row.grapheme);
    try testing.expectEqual(@as(usize, 3), page.graphemeCount());
}

test "grid encodes rows at their narrowest width" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{
        .cols = 2,
        .rows = 4,
        .styles = 8,
    });
    defer page.deinit();

    // Width zero: bare Latin-1 text.
    page.getRowAndCell(0, 0).cell.* = .init('A');
    page.getRowAndCell(1, 0).cell.* = .init(0xFF);

    // Width one: any BMP codepoint.
    page.getRowAndCell(0, 1).cell.* = .init(0x0100);

    // Width two: a small style ID and a background color.
    const style_id = try page.styles.add(page.memory, .{
        .flags = .{ .bold = true },
    });
    try testing.expect(style_id <= 63);
    const styled = page.getRowAndCell(0, 2);
    styled.cell.* = .init('s');
    styled.cell.style_id = style_id;
    styled.row.styled = true;
    const bg = page.getRowAndCell(1, 2);
    bg.cell.content_tag = .bg_color_palette;
    bg.cell.content = .{ .color_palette = .{ .data = 7 } };

    // Width three: a protected cell.
    page.getRowAndCell(0, 3).cell.protected = true;

    var encoded: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try encode(&page, &writer);

    const bytes = writer.buffered();
    try testing.expectEqual(
        @as(usize, (3 + 2 * 1) + (3 + 1 * 2) + (3 + 2 * 4) + (3 + 1 * 8) + 4),
        bytes.len,
    );

    // Each row header carries the expected width bits.
    try testing.expectEqual(@as(u8, 0 << 4), bytes[0] & 0x30);
    try testing.expectEqual(@as(u8, 1 << 4), bytes[5] & 0x30);
    try testing.expectEqual(@as(u8, 2 << 4), bytes[10] & 0x30);
    try testing.expectEqual(@as(u8, 3 << 4), bytes[21] & 0x30);

    var destination = try TerminalPage.init(.{
        .cols = 2,
        .rows = 4,
        .styles = 8,
    });
    defer destination.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);
    const native_style = try destination.styles.add(destination.memory, .{
        .flags = .{ .bold = true },
    });
    style_remap.put(style_id, native_style);

    var reader: std.Io.Reader = .fixed(bytes);
    try decode(&destination, &reader, &style_remap, &hyperlink_remap);
    try destination.verifyIntegrity(testing.allocator);

    try testing.expectEqual(
        @as(u21, 'A'),
        destination.getRowAndCell(0, 0).cell.codepoint(),
    );
    try testing.expectEqual(
        @as(u21, 0xFF),
        destination.getRowAndCell(1, 0).cell.codepoint(),
    );
    try testing.expectEqual(
        @as(u21, 0x0100),
        destination.getRowAndCell(0, 1).cell.codepoint(),
    );
    const decoded_styled = destination.getRowAndCell(0, 2);
    try testing.expectEqual(@as(u21, 's'), decoded_styled.cell.codepoint());
    try testing.expectEqual(native_style, decoded_styled.cell.style_id);
    try testing.expect(decoded_styled.row.styled);
    try testing.expectEqual(
        @as(u8, 7),
        destination.getRowAndCell(1, 2).cell.content.color_palette.data,
    );
    try testing.expect(destination.getRowAndCell(0, 3).cell.protected);
}

test "grid decodes non-canonical cell widths" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{ .cols = 2, .rows = 1 });
    defer page.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);

    // A bare ASCII row encoded at the full width is wasteful but valid.
    var payload: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&payload);
    try writer.writeByte(@bitCast(Row{ .cell_width = .eight }));
    try io.writeInt(&writer, u16, 2);
    try io.writeInt(&writer, u64, @bitCast(Cell{ .content = 'o' }));
    try io.writeInt(&writer, u64, @bitCast(Cell{ .content = 'k' }));
    try io.writeInt(&writer, u32, 0);

    var reader: std.Io.Reader = .fixed(writer.buffered());
    try decode(&page, &reader, &style_remap, &hyperlink_remap);
    try page.verifyIntegrity(testing.allocator);
    try testing.expectEqual(
        @as(u21, 'o'),
        page.getRowAndCell(0, 0).cell.codepoint(),
    );
    try testing.expectEqual(
        @as(u21, 'k'),
        page.getRowAndCell(1, 0).cell.codepoint(),
    );

    // Re-encoding canonicalizes the row back to the one-byte width.
    var reencoded: [16]u8 = undefined;
    var rewriter: std.Io.Writer = .fixed(&reencoded);
    try encode(&page, &rewriter);
    try testing.expectEqual(@as(usize, 3 + 2 + 4), rewriter.buffered().len);
}

test "grid normalizes surrogates in two-byte cells" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{ .cols = 2, .rows = 1 });
    defer page.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);

    var payload: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&payload);
    try writer.writeByte(@bitCast(Row{ .cell_width = .two }));
    try io.writeInt(&writer, u16, 2);
    try io.writeInt(&writer, u16, 0xD800);
    try io.writeInt(&writer, u16, 0x0416);
    try io.writeInt(&writer, u32, 0);

    var reader: std.Io.Reader = .fixed(writer.buffered());
    try decode(&page, &reader, &style_remap, &hyperlink_remap);
    try page.verifyIntegrity(testing.allocator);
    try testing.expectEqual(
        @as(u21, 0xFFFD),
        page.getRowAndCell(0, 0).cell.codepoint(),
    );
    try testing.expectEqual(
        @as(u21, 0x0416),
        page.getRowAndCell(1, 0).cell.codepoint(),
    );
}

test "grid four-byte cells run full normalization" {
    const testing = std.testing;
    var page = try TerminalPage.init(.{
        .cols = 3,
        .rows = 1,
        .styles = 8,
    });
    defer page.deinit();
    var style_remap = try StyleRemap.init(testing.allocator);
    defer style_remap.deinit(testing.allocator);
    var hyperlink_remap = try HyperlinkRemap.init(testing.allocator);
    defer hyperlink_remap.deinit(testing.allocator);

    var payload: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&payload);
    try writer.writeByte(@bitCast(Row{ .cell_width = .four }));
    try io.writeInt(&writer, u16, 3);

    // The Kitty placeholder does not fit two-byte cells but fits here
    // and must still derive the native row hint.
    try io.writeInt(&writer, u32, @truncate(@as(u64, @bitCast(Cell{
        .content = kitty_virtual_placeholder,
    }))));

    // An unknown small style reference degrades to the default style.
    try io.writeInt(&writer, u32, @truncate(@as(u64, @bitCast(Cell{
        .content = 'x',
        .style_id = 63,
    }))));

    // Reserved palette content bits are cleared at this width too.
    try io.writeInt(&writer, u32, @truncate(@as(u64, @bitCast(Cell{
        .kind = 2,
        .content = 0xFFFF07,
    }))));
    try io.writeInt(&writer, u32, 0);

    var reader: std.Io.Reader = .fixed(writer.buffered());
    try decode(&page, &reader, &style_remap, &hyperlink_remap);
    try page.verifyIntegrity(testing.allocator);

    const first = page.getRowAndCell(0, 0);
    try testing.expectEqual(
        kitty_virtual_placeholder,
        first.cell.codepoint(),
    );
    try testing.expect(first.row.kitty_virtual_placeholder);

    const second = page.getRowAndCell(1, 0).cell;
    try testing.expectEqual(@as(u21, 'x'), second.codepoint());
    try testing.expectEqual(@as(TerminalStyleId, 0), second.style_id);

    const third = page.getRowAndCell(2, 0).cell;
    try testing.expectEqual(
        TerminalCell.ContentTag.bg_color_palette,
        third.content_tag,
    );
    try testing.expectEqual(@as(u8, 7), third.content.color_palette.data);
}
