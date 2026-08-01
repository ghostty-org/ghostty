//! Grid (rows and cells) encoding.
//!
//! A grid contains the rows and cells of a terminal page. Its dimensions are
//! supplied by the containing record rather than repeated here. The encoder
//! writes exactly `rows` row records, and every row contains exactly `columns`
//! cell records.
//!
//! All records are tightly packed with no padding between them. All integers
//! are unsigned and little-endian.
//!
//! ## Row
//!
//! Each row has the following format:
//!
//! | Offset | Size     | Field                       |
//! | -----: | -------: | :-------------------------- |
//! |      0 |        1 | Row flags                   |
//! |      1 | variable | Exactly `columns` cells     |
//!
//! Cells are encoded consecutively. Since cells may contain a variable number
//! of grapheme codepoints, the next row begins immediately after the final
//! cell and its grapheme codepoints.
//!
//! The row flag byte has the following format:
//!
//! | Bits | Field                     |
//! | ---: | :------------------------ |
//! |    0 | Wrap                      |
//! |    1 | Wrap continuation         |
//! |  2-3 | Semantic prompt           |
//! |  4-7 | Reserved, zero            |
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
//! Native row cache flags are not encoded. In particular, the Kitty virtual
//! placeholder hint is derived while decoding cells containing U+10EEEE.
//!
//! ## Cell
//!
//! Each cell has the following format:
//!
//! | Offset | Size      | Field                         |
//! | -----: | --------: | :---------------------------- |
//! |      0 |         1 | Content kind                  |
//! |      1 |         1 | Width kind                    |
//! |      2 |         1 | Protected and semantic flags  |
//! |      3 |         1 | Reserved, zero                |
//! |      4 |         2 | Style ID                      |
//! |      6 |         2 | Hyperlink ID                  |
//! |      8 |         4 | Codepoint or packed color     |
//! |     12 |         4 | Grapheme suffix count         |
//! |     16 | 4 * count | Grapheme suffix codepoints    |
//!
//! Content kinds are:
//!
//! | Value | Meaning            |
//! | ----: | :----------------- |
//! |     0 | Codepoint          |
//! |     1 | Palette background |
//! |     2 | RGB background     |
//!
//! For codepoint content, the value is a Unicode scalar encoded as a `u32`.
//! For a palette background, the low byte is the palette index and the other
//! three bytes are zero. For an RGB background, the low three bytes are red,
//! green, and blue, and the high byte is zero.
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
//! The cell flag byte has the following format:
//!
//! | Bits | Field             |
//! | ---: | :---------------- |
//! |    0 | Protected         |
//! |  1-2 | Semantic content  |
//! |  3-7 | Reserved, zero    |
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
//! tables.
//!
//! Grapheme suffixes are valid only for codepoint content. Each suffix is a
//! Unicode scalar encoded as a `u32`. A nonzero suffix count requires a
//! nonzero base codepoint.

const std = @import("std");
const test_fixture = @import("fixture.zig");
const io = @import("io.zig");
const kitty = @import("../kitty.zig");
const terminal_hyperlink = @import("../hyperlink.zig");
const terminal_page = @import("../page.zig");
const terminal_style = @import("../style.zig");

const TerminalCell = terminal_page.Cell;
const TerminalHyperlinkId = terminal_hyperlink.Id;
const TerminalPage = terminal_page.Page;
const TerminalRow = terminal_page.Row;
const TerminalStyleId = terminal_style.Id;

/// Maps encoded style table IDs to IDs assigned by the destination page.
///
/// Build this by inserting each decoded style into the page, then recording
/// the encoded ID and the ID returned by the page's style set. Style ID zero is
/// implicit and does not need an entry.
pub const StyleRemap = std.AutoHashMap(TerminalStyleId, TerminalStyleId);

/// Maps encoded hyperlink table IDs to IDs assigned by the destination page.
///
/// Build this by inserting each decoded hyperlink into the page, then
/// recording the encoded ID and the ID returned by the page's hyperlink set.
/// Hyperlink ID zero is implicit and does not need an entry.
pub const HyperlinkRemap = std.AutoHashMap(TerminalHyperlinkId, TerminalHyperlinkId);

pub const EncodeError = std.Io.Writer.Error || error{
    /// Wide and spacer cells do not form a valid row.
    InvalidWideCell,
};

/// Encode every row and cell directly from a page.
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
        // Row header
        const row = page.getRow(y);
        const row_header: RowHeader = .{
            .wrap = row.wrap,
            .wrap_continuation = row.wrap_continuation,
            .semantic_prompt = row.semantic_prompt,
        };
        try writer.writeByte(@bitCast(row_header));

        // Cells
        const cells = page.getCells(row);
        for (cells, 0..) |*cell, x| {
            // Validate the wide state of this cell, we don't want
            // to encode corrupt data.
            switch (cell.wide) {
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
            }

            const graphemes: []const u21 = if (cell.hasGrapheme())
                page.lookupGrapheme(cell) orelse unreachable
            else
                &.{};

            // The page has two codepoint tags depending on whether suffixes
            // exist, but the wire represents both with one content kind.
            const kind: CellHeader.Kind = switch (cell.content_tag) {
                .codepoint, .codepoint_grapheme => .codepoint,
                .bg_color_palette => .bg_color_palette,
                .bg_color_rgb => .bg_color_rgb,
            };
            const value: CellHeader.Value = switch (kind) {
                .codepoint => .{
                    .codepoint = cell.content.codepoint.data,
                },
                .bg_color_palette => .{ .bg_color_palette = .{
                    .index = cell.content.color_palette.data,
                } },
                .bg_color_rgb => .{ .bg_color_rgb = .{
                    .r = cell.content.color_rgb.r,
                    .g = cell.content.color_rgb.g,
                    .b = cell.content.color_rgb.b,
                } },
            };

            const style_id = cell.style_id;
            const hyperlink_id: TerminalHyperlinkId = if (cell.hyperlink)
                page.lookupHyperlink(cell) orelse unreachable
            else
                0;

            const header: CellHeader = .{
                .content_kind = kind,
                .width = cell.wide,
                .protected = cell.protected,
                .semantic_content = cell.semantic_content,
                .style_id = style_id,
                .hyperlink_id = hyperlink_id,
                .value = value,
                .grapheme_count = @intCast(graphemes.len),
            };
            try header.encode(writer);
            for (graphemes) |suffix| try io.writeInt(
                writer,
                u32,
                suffix,
            );
        }
    }
}

/// Decode every row and cell directly into an initialized, empty page.
///
/// The grid does not encode dimensions, so `page` must already have the exact
/// row and column count expected by the containing record. This function reads
/// exactly `page.size.rows` rows with `page.size.cols` cells each. Capacity
/// hints are advisory. Graphemes and cell hyperlink references that do not fit
/// are discarded without affecting the rest of the grid.
///
/// Style and hyperlink table entries must be inserted into `page` before
/// calling this function. As each table entry is inserted, the caller records
/// its encoded ID and page-assigned ID in `style_remap` or `hyperlink_remap`.
/// ID zero always means the default style or no hyperlink. A nonzero ID missing
/// from its remap is also treated as zero so unknown table references do not
/// prevent the rest of the grid from decoding.
///
/// Invalid semantic data is normalized into a degraded form while preserving
/// the declared byte boundaries. Unknown semantic values use their neutral
/// variants, invalid Unicode becomes U+FFFD, invalid optional data is ignored,
/// and malformed wide-cell relationships become narrow cells.
pub fn decode(
    page: *TerminalPage,
    reader: *std.Io.Reader,
    style_remap: *const StyleRemap,
    hyperlink_remap: *const HyperlinkRemap,
) std.Io.Reader.Error!void {
    for (0..page.size.rows) |y| {
        const row_raw = try reader.takeByte();
        const row_header: RowHeader = @bitCast(row_raw);
        const semantic_prompt_raw: u2 = @truncate(row_raw >> @bitOffsetOf(RowHeader, "semantic_prompt"));

        // Reserved bits do not change the known fields. The semantic enum is
        // the only non-exhaustive field, so give its unknown value a default.
        const row = page.getRow(y);
        row.wrap = row_header.wrap;
        row.wrap_continuation = row_header.wrap_continuation;
        row.semantic_prompt = std.enums.fromInt(
            TerminalRow.SemanticPrompt,
            semantic_prompt_raw,
        ) orelse .none;

        const cells = page.getCells(row);
        for (cells, 0..) |*cell, x| {
            const decoded_header = try CellHeader.decode(reader);

            cell.* = .init(0);
            var accept_graphemes = false;
            const grapheme_count: u32 = switch (decoded_header) {
                // The fixed header was fully consumed, but its content kind
                // cannot be interpreted. Keep the cell empty and consume only
                // the suffix bytes needed to reach the next cell.
                .invalid => |count| count,

                .valid => |header| valid: {
                    // IDs belong to the encoded page. Translate them to IDs
                    // assigned by the destination page before storing them on
                    // cells.
                    const encoded_style_id = header.style_id;
                    const style_id = if (encoded_style_id == 0)
                        0
                    else
                        style_remap.get(encoded_style_id) orelse 0;

                    const encoded_hyperlink_id = header.hyperlink_id;
                    const hyperlink_id = if (encoded_hyperlink_id == 0)
                        0
                    else
                        hyperlink_remap.get(encoded_hyperlink_id) orelse 0;

                    switch (header.content_kind) {
                        .codepoint => {
                            var cp = std.math.cast(
                                u21,
                                header.value.codepoint,
                            ) orelse 0xFFFD;
                            if (cp > 0x10FFFF or
                                (cp >= 0xD800 and cp <= 0xDFFF))
                            {
                                cp = 0xFFFD;
                            }
                            cell.content = .{ .codepoint = .{ .data = cp } };
                            accept_graphemes = cp != 0;

                            // Kitty image and placement state is not part of this
                            // snapshot version, but the placeholder is still a
                            // valid Unicode scalar. Preserve it and derive the
                            // native row hint so later row operations remain
                            // correct.
                            if (cp == kitty.graphics.unicode.placeholder) {
                                row.kitty_virtual_placeholder = true;
                            }
                        },
                        .bg_color_palette => {
                            const palette = header.value.bg_color_palette;
                            cell.content_tag = .bg_color_palette;
                            cell.content = .{
                                .color_palette = .{ .data = palette.index },
                            };
                        },
                        .bg_color_rgb => {
                            const rgb = header.value.bg_color_rgb;
                            cell.content_tag = .bg_color_rgb;
                            cell.content = .{ .color_rgb = .{
                                .r = rgb.r,
                                .g = rgb.g,
                                .b = rgb.b,
                            } };
                        },
                    }

                    cell.wide = header.width;
                    cell.protected = header.protected;
                    cell.semantic_content = header.semantic_content;

                    if (style_id != 0) {
                        // The table owns one reference and each decoded cell owns
                        // one additional reference.
                        page.styles.use(page.memory, style_id);
                        cell.style_id = style_id;
                        row.styled = true;
                    }

                    if (hyperlink_id != 0) {
                        // setHyperlink records the cell mapping but intentionally
                        // does not increment the set's reference count. If its map
                        // is full, undo our reference and leave this cell unlinked.
                        page.hyperlink_set.use(page.memory, hyperlink_id);
                        page.setHyperlink(row, cell, hyperlink_id) catch {
                            page.hyperlink_set.release(page.memory, hyperlink_id);
                        };
                    }

                    break :valid header.grapheme_count;
                },
            };

            // Always consume every declared suffix. Invalid scalars, suffixes
            // on non-text cells, and suffixes that exceed the native capacity
            // are optional detail and can be dropped independently.
            for (0..grapheme_count) |_| {
                const suffix_raw = try io.readInt(reader, u32);
                if (!accept_graphemes) continue;

                const suffix = std.math.cast(u21, suffix_raw) orelse continue;
                if (suffix > 0x10FFFF or
                    (suffix >= 0xD800 and suffix <= 0xDFFF))
                {
                    continue;
                }
                page.appendGrapheme(row, cell, suffix) catch {
                    accept_graphemes = false;
                };
            }

            // A following cell resolves whether the previous wide marker owns
            // a tail. Normalize the current marker immediately when possible,
            // including a wide marker at the row end.
            if (x > 0 and
                cells[x - 1].wide == .wide and
                cell.wide != .spacer_tail)
            {
                cells[x - 1].wide = .narrow;
            }
            switch (cell.wide) {
                .narrow => {},

                // A non-final wide marker remains pending until the next cell.
                .wide => if (x + 1 == cells.len) {
                    cell.wide = .narrow;
                },

                .spacer_tail => if (x == 0 or
                    cells[x - 1].wide != .wide)
                {
                    cell.wide = .narrow;
                },

                .spacer_head => if (x + 1 != cells.len or !row.wrap) {
                    cell.wide = .narrow;
                },
            }
        }
    }
}

/// The header before every row.
const RowHeader = packed struct(u8) {
    wrap: bool = false,
    wrap_continuation: bool = false,
    semantic_prompt: TerminalRow.SemanticPrompt = .none,
    _padding: u4 = 0,
};

/// The fixed fields that precede a cell's grapheme suffix codepoints.
const CellHeader = struct {
    /// Number of bytes written by `encode`, calculated using the encoder itself
    /// so this remains synchronized with the field-by-field wire format.
    pub const len = computeLen();

    comptime {
        // This size is part of the wire format. If it changes, the snapshot
        // version and golden fixtures must also change.
        std.debug.assert(len == 16);
    }

    /// Interpretation of `value`.
    content_kind: Kind = .codepoint,

    /// Display width and spacer role of the cell.
    width: TerminalCell.Wide = .narrow,

    /// Whether selective erase operations protect the cell.
    protected: bool = false,

    /// Semantic role assigned by shell integration.
    semantic_content: TerminalCell.SemanticContent = .output,

    /// ID in the encoded page's style table, or zero for the default style.
    style_id: TerminalStyleId = 0,

    /// ID in the encoded page's hyperlink table, or zero for no hyperlink.
    hyperlink_id: TerminalHyperlinkId = 0,

    /// Codepoint or packed background color selected by `content_kind`.
    value: Value = .{ .codepoint = 0 },

    /// Number of grapheme suffix codepoints immediately following the header.
    grapheme_count: u32 = 0,

    /// Encode the fixed cell header.
    pub fn encode(
        self: CellHeader,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const flags: Flags = .{
            .protected = self.protected,
            .semantic_content = self.semantic_content,
        };

        //  0       1       2       3       4        6        8        12       16
        //  +-------+-------+-------+-------+--------+--------+--------+--------+
        //  | kind  | width | flags | zero  | style  | link   | value  | count  |
        //  | u8    | u8    | u8    | u8    | u16 LE | u16 LE | u32 LE | u32 LE |
        //  +-------+-------+-------+-------+--------+--------+--------+--------+
        try writer.writeByte(@intFromEnum(self.content_kind));
        try writer.writeByte(@intFromEnum(self.width));
        try writer.writeByte(@bitCast(flags));
        try writer.writeByte(0);
        try io.writeInt(writer, TerminalStyleId, self.style_id);
        try io.writeInt(writer, TerminalHyperlinkId, self.hyperlink_id);
        try io.writeInt(writer, u32, @bitCast(self.value));
        try io.writeInt(writer, u32, self.grapheme_count);
    }

    /// A valid header, or the suffix count from an uninterpretable header.
    const DecodeResult = union(enum) {
        valid: CellHeader,
        invalid: u32,
    };

    /// Decode a fixed cell header, normalizing unknown semantic values.
    pub fn decode(reader: *std.Io.Reader) std.Io.Reader.Error!DecodeResult {
        // Decode various fields. We need to be very defensive here
        // because it can come from an untrusted source and may be invalid.
        const content_kind_optional = kind: {
            const raw = try reader.takeByte();
            break :kind std.enums.fromInt(Kind, raw);
        };
        const width = width: {
            const raw = try reader.takeByte();
            break :width std.enums.fromInt(TerminalCell.Wide, raw) orelse .narrow;
        };

        const flags: Flags = @bitCast(try reader.takeByte());

        // We can't trust `flags` to have a valid semantic content so
        // we need extract the bits and do a safe conversion.
        const semantic_content = semantic: {
            const flags_raw: u8 = @bitCast(flags);
            const raw: u2 = @truncate(flags_raw >> @bitOffsetOf(Flags, "semantic_content"));
            break :semantic std.enums.fromInt(
                TerminalCell.SemanticContent,
                raw,
            ) orelse .output;
        };

        // This byte is reserved so the IDs and content value remain naturally
        // aligned within the fixed cell header. Ignore it so future versions
        // can give it meaning without making old decoders reject the cell.
        _ = try reader.takeByte();

        const style_id = try io.readInt(reader, TerminalStyleId);
        const hyperlink_id = try io.readInt(reader, TerminalHyperlinkId);
        const value: Value = @bitCast(try io.readInt(reader, u32));
        const grapheme_count = try io.readInt(reader, u32);

        // If we don't have a valid content kind, we return invalid and
        // note the suffix bytes so that the reader can discard
        const content_kind = content_kind_optional orelse
            return .{ .invalid = grapheme_count };

        return .{ .valid = .{
            .content_kind = content_kind,
            .width = width,
            .protected = flags.protected,
            .semantic_content = semantic_content,
            .style_id = style_id,
            .hyperlink_id = hyperlink_id,
            .value = value,
            .grapheme_count = grapheme_count,
        } };
    }

    /// Computes the fixed header size using the encoder itself.
    fn computeLen() usize {
        comptime {
            var buf: [128]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buf);
            CellHeader.encode(.{}, &writer) catch unreachable;
            return writer.end;
        }
    }

    /// Determines how `value` is interpreted.
    pub const Kind = enum(u8) {
        codepoint = 0,
        bg_color_palette = 1,
        bg_color_rgb = 2,
    };

    /// The alternate interpretations of the four-byte content field.
    pub const Value = packed union(u32) {
        codepoint: u32,
        bg_color_palette: packed struct(u32) {
            index: u8,
            _padding: u24 = 0,
        },
        bg_color_rgb: packed struct(u32) {
            r: u8,
            g: u8,
            b: u8,
            _padding: u8 = 0,
        },
    };

    const Flags = packed struct(u8) {
        protected: bool = false,
        semantic_content: TerminalCell.SemanticContent = .output,
        _padding: u5 = 0,
    };
};

const test_golden_fixture = test_fixture.parse(
    @embedFile("testdata/grid-v1.hex"),
);

test "grid golden encoding and decoding" {
    const capacity: terminal_page.Capacity = .{
        .cols = 3,
        .rows = 2,
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

    var encoded: [128]u8 = undefined;
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
    var style_remap = StyleRemap.init(std.testing.allocator);
    defer style_remap.deinit();
    var hyperlink_remap = HyperlinkRemap.init(std.testing.allocator);
    defer hyperlink_remap.deinit();

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

    // A re-encode proves the decoded native page retains every wire field.
    var reencoded: [128]u8 = undefined;
    var rewriter: std.Io.Writer = .fixed(&reencoded);
    try encode(&destination, &rewriter);
    try std.testing.expectEqualStrings(
        &test_golden_fixture,
        rewriter.buffered(),
    );
}

test "grid normalizes incomplete wide cells" {
    const testing = std.testing;
    // One column puts the wide cell at the row end. Two columns put an
    // ordinary narrow cell after it. Neither case supplies a spacer tail.
    for ([_]u16{ 1, 2 }) |columns| {
        const capacity: terminal_page.Capacity = .{
            .cols = columns,
            .rows = 1,
        };

        // Craft the malformed row directly on the wire. Decoding keeps its
        // content but makes the incomplete wide cell narrow.
        var payload: [64]u8 = undefined;
        var payload_writer: std.Io.Writer = .fixed(&payload);
        try payload_writer.writeByte(@bitCast(RowHeader{}));
        try (CellHeader{
            .width = .wide,
            .value = .{ .codepoint = 'A' },
        }).encode(&payload_writer);
        if (capacity.cols > 1) try (CellHeader{
            .value = .{ .codepoint = 'B' },
        }).encode(&payload_writer);

        var destination = try TerminalPage.init(capacity);
        defer destination.deinit();
        var style_remap = StyleRemap.init(testing.allocator);
        defer style_remap.deinit();
        var hyperlink_remap = HyperlinkRemap.init(testing.allocator);
        defer hyperlink_remap.deinit();

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
}
