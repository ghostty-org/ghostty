//! PAGE record payload encoding.
//!
//! One PAGE record represents a set of rows/columns in the terminal.
//! In libghostty, this happens to map internally to a very specific
//! data structure called a "page" (hence the name), but consumers of
//! the format don't need to reproduce that.
//!
//! The important thing is that one page is fully self-contained: it has
//! a dimension (cols x rows), a set of styles, hyperlinks, cells, etc.
//! and depends on no external state to decode that with some exceptions
//! like assets such as images.
//!
//! A page could have a dimension that doesn't match the terminal
//! dimensions, e.g. for lazy resize/reflow. Callers must be prepared for
//! that.
//!
//! ## Binary Format
//!
//! Every PAGE payload begins with a fixed header, followed by a
//! payload of styles, hyperlinks, and rows and columns.
//!
//! All integers are unsigned and little-endian.
//!
//! ### Header
//!
//! | Offset | Size | Field                              |
//! | -----: | ---: | :--------------------------------- |
//! |      0 |    2 | Logical columns (`u16`)            |
//! |      2 |    2 | Logical rows (`u16`)               |
//! |      4 |    2 | Non-default style count (`u16`)    |
//! |      6 |    2 | Unique hyperlink count (`u16`)     |
//! |      8 |    2 | Style capacity hint (`u16`)        |
//! |     10 |    2 | Hyperlink capacity bytes (`u16`)   |
//! |     12 |    4 | Grapheme capacity bytes (`u32`)    |
//! |     16 |    4 | String capacity bytes (`u32`)      |
//!
//! The first two fields (columns and rows) denote the dimensionality
//! of the page. The payload is guaranteed to have this dimensionality;
//! every row has exactly the columns specified.
//!
//! Next, the style count and hyperlink count denote the number of
//! styles and hyperlinks respectively that are sent with the page.
//! The default style and absence of a hyperlink are implicit at native
//! ID zero and are not included in these counts. Each encoded table entry
//! carries its nonzero native page ID.
//!
//! The final four fields are allocation hints copied from the source page.
//! These represent upper limits on what this page might contain. A decoder
//! can optionally choose to use this for preallocation or it can ignore
//! and decode and allocate dynamically.
//!
//! ### Payload
//!
//! ```text
//! +---------------------------+
//! | Header                    |
//! | 20 bytes                  |
//! +---------------------------+
//! | Style table               |
//! | style_count entries       |
//! +---------------------------+
//! | Hyperlink table           |
//! | hyperlink_count entries   |
//! +---------------------------+
//! | Grid                      |
//! | rows and grapheme section |
//! +---------------------------+
//!
//! Style entry     = encoded ID + style record
//! Hyperlink entry = encoded ID + hyperlink record
//! Grid            = row 0 ... row (rows - 1) + grapheme suffix section
//! Row             = row header + encoded cells
//! ```
//!
//! Following the header, the payload contains exactly `style_count` style
//! records and `hyperlink_count` hyperlink records, followed by exactly
//! `rows` row records and one grapheme suffix section. There is no padding
//! between records.
//!
//! Each style begins with an ID (`u16`) followed by the typical style
//! binary representation (in style.zig). The ID is what cells will use
//! to reference the style. Decoders must maintain some kind of mapping
//! in order to associate these properly.
//!
//! Each hyperlink also begins with an ID (`u16`) with the same semantics
//! as the style ID. The hyperlink and style IDs are separate namespaces,
//! so they may collide. Following the ID, the hyperlink binary format
//! is encoded directly.
//!
//! Both style and hyperlink IDs are not guaranteed to be in any specific
//! order and may contain gaps (e.g. ID 1 and 3 but not 2).
//!
//! Rows and cells use the grid encoding documented in `grid.zig`.

const std = @import("std");
const build_options = @import("terminal_options");
const Allocator = std.mem.Allocator;
const test_fixture = @import("fixture.zig");
const grid = @import("grid.zig");
const hyperlink = @import("hyperlink.zig");
const io = @import("io.zig");
const record = @import("record.zig");
const style = @import("style.zig");
const terminal_hyperlink = @import("../hyperlink.zig");
const terminal_page = @import("../page.zig");
const terminal_style = @import("../style.zig");

// Frequent constants we use
const TerminalHyperlink = terminal_hyperlink.Hyperlink;
const TerminalHyperlinkId = terminal_hyperlink.Id;
const TerminalHyperlinkPageEntry = terminal_hyperlink.PageEntry;
const TerminalCell = terminal_page.Cell;
const TerminalPage = terminal_page.Page;
const TerminalPageCapacity = terminal_page.Capacity;
const TerminalRow = terminal_page.Row;
const TerminalStyle = terminal_style.Style;
const TerminalStyleId = terminal_style.Id;

const PayloadEncodeError = hyperlink.EncodeError || grid.EncodeError;

const PayloadDecodeError = std.Io.Reader.Error ||
    Header.CapacityError ||
    grid.DecodeError ||
    error{
        /// The hyperlink kind is not defined by snapshot version 1.
        InvalidKind,

        /// Native page backing memory could not be allocated.
        OutOfMemory,

        /// The caller-provided page does not have the advertised capacity.
        InvalidDestinationCapacity,
    };

/// Errors possible while encoding a complete PAGE record.
pub const EncodeError = PayloadEncodeError || record.Writer.FinishError;

/// Encode one complete PAGE record from a native page.
///
/// The payload is built in the stream's reusable record buffer. If payload
/// encoding fails, no bytes from this record are emitted.
pub fn encode(
    page: *const TerminalPage,
    destination: *record.Writer,
) EncodeError!void {
    const payload = destination.begin(.page);
    errdefer destination.cancel();
    try encodePayload(page, payload);
    try destination.finish();
}

/// Errors possible while decoding and validating a complete PAGE record.
pub const DecodeError = PayloadDecodeError ||
    record.Reader.InitError ||
    record.Reader.FinishError ||
    TerminalPage.IntegrityError ||
    error{
        /// The next record is valid but is not a PAGE.
        UnexpectedRecordTag,
    };

/// Decode and validate one complete PAGE record into a fresh native page.
///
/// The record tag, payload boundary, CRC32C, payload contents, and final page
/// integrity are all validated before the page is returned. `alloc` is used
/// only for temporary decode remaps and integrity-check storage.
pub fn decode(
    reader: *std.Io.Reader,
    alloc: Allocator,
) DecodeError!TerminalPage {
    var decoder: Decoder = undefined;
    try decoder.init(reader);

    var page = TerminalPage.init(decoder.capacity()) catch
        return error.OutOfMemory;
    errdefer page.deinit();
    try decoder.decode(&page, alloc);
    return page;
}

/// PAGE record decoder where the caller is responsible for owning
/// the Page memory. This is particularly useful paired with
/// PageList.Builder so you can build up a proper PageList with
/// valid memory ownership.
pub const Decoder = struct {
    record_reader: record.Reader,
    header: Header,

    /// Begin decoding one PAGE record and expose its required capacity.
    /// After this, call `capacity` to get the capacity to allocate
    /// the page properly, then `decode` into it.
    pub fn init(self: *Decoder, reader: *std.Io.Reader) DecodeError!void {
        try self.record_reader.init(reader);
        if (self.record_reader.header.tag != .page) {
            return error.UnexpectedRecordTag;
        }

        self.header = try Header.decode(self.record_reader.payloadReader());
        _ = try self.header.pageCapacity();
    }

    /// Return the exact native capacity advertised by the PAGE header.
    pub fn capacity(self: *const Decoder) TerminalPageCapacity {
        return self.header.pageCapacity() catch unreachable;
    }

    /// Largest remaining PAGE payload staged into one contiguous buffer.
    /// This comfortably covers every payload a standard-capacity page can
    /// produce while keeping the allocation an untrusted length can force
    /// far below the record framing's four-byte length limit.
    const max_staged_payload = 8 * 1024 * 1024;

    /// Decode the remaining payload into caller-owned native page storage.
    ///
    /// The destination must be freshly initialized with `capacity`. `alloc`
    /// is used only for temporary staging, ID remaps, and integrity-check
    /// storage.
    pub fn decode(
        self: *Decoder,
        destination: *TerminalPage,
        alloc: Allocator,
    ) DecodeError!void {
        if (!std.meta.eql(destination.capacity, self.capacity())) {
            return error.InvalidDestinationCapacity;
        }

        destination.size = .{
            .cols = self.header.columns,
            .rows = self.header.rows,
        };

        // `init` consumed exactly the fixed header from the declared
        // payload, so this is the byte count of the tables and grid.
        const remaining = self.record_reader.header.payload_len - Header.len;

        if (self.record_reader.payloadReader().bufferedLen() >= remaining) {
            // The complete payload is already buffered, e.g. borrowed from
            // an in-memory snapshot. Parse it in place with no staging
            // copy; `finish` still enforces the CRC and exact exhaustion.
            try decodePayloadBody(
                self.record_reader.payloadReader(),
                alloc,
                destination,
                self.header,
            );
        } else if (remaining <= max_staged_payload) {
            // Stage the payload with one bulk read. The whole payload passes
            // through the checksum hasher as one update and the payload
            // decoders then parse a flat buffer, which keeps per-row work free
            // of stream adapters. The CRC and exact-length checks in `finish`
            // are unaffected.
            const staged = try alloc.alloc(u8, remaining);
            defer alloc.free(staged);
            try self.record_reader.payloadReader().readSliceAll(staged);

            var staged_reader: std.Io.Reader = .fixed(staged);
            try decodePayloadBody(
                &staged_reader,
                alloc,
                destination,
                self.header,
            );
            if (staged_reader.bufferedLen() != 0) {
                return error.PayloadNotExhausted;
            }
        } else {
            // A payload this large is either hostile or a page far beyond
            // native capacities. Decode it through the streaming payload
            // reader so its declared length cannot force an allocation.
            try decodePayloadBody(
                self.record_reader.payloadReader(),
                alloc,
                destination,
                self.header,
            );
        }
        try self.record_reader.finish();

        // The decoder normalizes every semantic value, so a complete decode
        // upholds native page invariants by construction. Verifying them
        // again is a defense against decoder bugs and follows the native
        // page policy: full integrity verification only when slow runtime
        // safety is enabled.
        if (comptime build_options.slow_runtime_safety) {
            try destination.verifyIntegrity(alloc);
        }
    }
};

/// Errors possible while discarding one PAGE record without decoding it.
pub const DiscardError = record.Reader.InitError ||
    record.Reader.FinishError ||
    std.Io.Reader.Error ||
    error{
        /// The next record is valid but is not a PAGE.
        UnexpectedRecordTag,
    };

/// Consume exactly one complete PAGE record, validating its framing and
/// CRC32C while discarding the payload without structural validation.
///
/// This lets a decoder stay aligned with the record sequence while dropping
/// page content it can no longer apply.
pub fn discard(source: *std.Io.Reader) DiscardError!void {
    var record_reader: record.Reader = undefined;
    try record_reader.init(source);
    if (record_reader.header.tag != .page) {
        return error.UnexpectedRecordTag;
    }
    try record_reader.payloadReader().discardAll(
        record_reader.header.payload_len,
    );
    try record_reader.finish();
}

/// Encode a PAGE payload directly from a native page.
fn encodePayload(
    page: *const TerminalPage,
    writer: *std.Io.Writer,
) PayloadEncodeError!void {
    // Write header
    try Header.init(page).encode(writer);

    // Sparse styles
    var style_it = page.styles.iterator(page.memory);
    while (style_it.next()) |entry| {
        try io.writeInt(writer, TerminalStyleId, entry.id);
        try style.encode(entry.value_ptr.*, writer);
    }

    // Sparse hyperlinks
    var hyperlink_it = page.hyperlink_set.iterator(page.memory);
    while (hyperlink_it.next()) |entry| {
        try io.writeInt(writer, TerminalHyperlinkId, entry.id);
        try hyperlink.encode(pageHyperlink(page, entry.value_ptr), writer);
    }

    // Rows and cells
    try grid.encode(page, writer);
}

/// Decode a PAGE payload directly into a fresh native page.
///
/// `alloc` is used only for the temporary native-ID remap tables. Styles,
/// hyperlinks, strings, graphemes, rows, and cells are stored in the page.
fn decodePayload(
    reader: *std.Io.Reader,
    alloc: Allocator,
) PayloadDecodeError!TerminalPage {
    const header = try Header.decode(reader);
    const capacity = try header.pageCapacity();
    var page = TerminalPage.init(capacity) catch
        return error.OutOfMemory;
    errdefer page.deinit();
    try decodePayloadBody(reader, alloc, &page, header);
    return page;
}

/// Decode PAGE tables and grid after the header into initialized native page
/// storage with the exact advertised capacity and dimensions.
fn decodePayloadBody(
    reader: *std.Io.Reader,
    alloc: Allocator,
    page: *TerminalPage,
    header: Header,
) PayloadDecodeError!void {
    page.pauseIntegrityChecks(true);
    defer page.pauseIntegrityChecks(false);

    // Pages without styles or hyperlinks, the common case for plain
    // scrollback, skip the remap tables entirely: every encoded cell ID
    // resolves to the default through the empty remap.
    var style_remap: grid.StyleRemap = if (header.style_count > 0)
        grid.StyleRemap.init(alloc) catch return error.OutOfMemory
    else
        .empty;
    defer style_remap.deinit(alloc);

    var hyperlink_remap: grid.HyperlinkRemap = if (header.hyperlink_count > 0)
        grid.HyperlinkRemap.init(alloc) catch return error.OutOfMemory
    else
        .empty;
    defer hyperlink_remap.deinit(alloc);

    // Styles. The complete fixed-size entry is parsed from the buffered
    // payload when possible so each entry costs no reader calls.
    const style_entry_len = @sizeOf(TerminalStyleId) + style.len;
    for (0..header.style_count) |_| {
        const native_id: TerminalStyleId, const value = entry: {
            if (reader.bufferedLen() >= style_entry_len) {
                const bytes = reader.buffered()[0..style_entry_len];
                defer reader.toss(style_entry_len);
                break :entry .{
                    std.mem.readInt(TerminalStyleId, bytes[0..2], .little),
                    style.parseOrNull(bytes[2..][0..style.len]),
                };
            }
            break :entry .{
                try io.readInt(reader, TerminalStyleId),
                try style.decodeOrNull(reader),
            };
        };

        // Zero is reserved for the implicit default. For a duplicate encoded
        // ID, the first entry wins and this complete entry is simply ignored.
        if (native_id == 0 or style_remap.contains(native_id)) continue;

        // Invalid/default styles map to the native default. `add` returns
        // the existing entry for a repeated concrete value, taking one
        // reference either way, while capacity failure degrades only this
        // style. The references are surrendered through the remap below
        // once every cell reference is installed.
        const decoded_id: TerminalStyleId = if (value) |valid| decoded: {
            if (valid.default()) break :decoded 0;
            break :decoded page.styles.add(
                page.memory,
                valid,
            ) catch 0;
        } else 0;
        style_remap.put(native_id, decoded_id);
    }

    // Hyperlinks
    for (0..header.hyperlink_count) |_| {
        const native_id = try io.readInt(reader, TerminalHyperlinkId);
        const decoded_id = try hyperlink.decodePage(page, reader);

        // As with styles, zero is reserved and the first duplicate encoded ID
        // wins. Release any native entry reference created for an ignored ID.
        if (native_id == 0 or hyperlink_remap.contains(native_id)) {
            if (decoded_id != 0) {
                page.hyperlink_set.release(page.memory, decoded_id);
            }
            continue;
        }

        // Zero records an ignored table entry. Grid decoding treats every
        // reference to it as no hyperlink.
        hyperlink_remap.put(native_id, decoded_id);
    }

    // Rows and cells
    try grid.decode(
        page,
        reader,
        &style_remap,
        &hyperlink_remap,
    );

    // Every accepted table entry took one reference through `add` so grid
    // decoding can safely attach its style to any number of cells. Unlike
    // organically built pages, those references do not themselves represent
    // cells. Release through the encoded-ID remap, so duplicate values
    // which deduplicated to the same native ID each surrender their own
    // reference; unused entries then become dead and disappear from
    // canonical re-encoding.
    var style_it = style_remap.seen.iterator(.{});
    while (style_it.next()) |encoded_id| {
        const id = style_remap.entries[encoded_id];
        if (id != 0) page.styles.release(page.memory, id);
    }

    // Hyperlink insertion likewise creates one temporary reference for every
    // accepted wire table entry. Release through the encoded-ID remap rather
    // than the native set so duplicate values which deduplicated to the same
    // native ID each surrender their own reference.
    var hyperlink_it = hyperlink_remap.seen.iterator(.{});
    while (hyperlink_it.next()) |encoded_id| {
        const id = hyperlink_remap.entries[encoded_id];
        if (id != 0) page.hyperlink_set.release(page.memory, id);
    }
}

/// The fixed logical dimensions, table counts, and allocation hints at the
/// start of PAGE.
pub const Header = struct {
    /// Number of bytes written by `encode`, calculated using the encoder itself
    /// so this remains synchronized with the field-by-field wire format.
    pub const len = computeLen();

    comptime {
        // This size is part of the wire format. If it changes, the snapshot
        // version and golden fixtures must also change.
        std.debug.assert(len == 20);
    }

    /// Number of logical cells in every encoded row.
    columns: u16,

    /// Number of logical rows encoded after the tables.
    rows: u16,

    /// Number of non-default style entries following the header.
    style_count: u16,

    /// Number of unique hyperlink entries following the style table.
    hyperlink_count: u16,

    /// Suggested capacity for the native non-default style set.
    style_capacity: u16,

    /// Suggested native hyperlink storage capacity in bytes.
    hyperlink_capacity_bytes: u16,

    /// Suggested native grapheme storage capacity in bytes.
    grapheme_capacity_bytes: u32,

    /// Suggested native string storage capacity in bytes.
    string_capacity_bytes: u32,

    /// Encode the fixed PAGE payload header.
    pub fn encode(
        self: Header,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try io.writeInt(writer, u16, self.columns);
        try io.writeInt(writer, u16, self.rows);
        try io.writeInt(writer, u16, self.style_count);
        try io.writeInt(writer, u16, self.hyperlink_count);
        try io.writeInt(writer, u16, self.style_capacity);
        try io.writeInt(writer, u16, self.hyperlink_capacity_bytes);
        try io.writeInt(writer, u32, self.grapheme_capacity_bytes);
        try io.writeInt(writer, u32, self.string_capacity_bytes);
    }

    /// Decode the fixed PAGE payload header.
    ///
    /// This reads field values only. The complete PAGE decoder is responsible
    /// for applying configured limits before using any capacity hint.
    pub fn decode(reader: *std.Io.Reader) std.Io.Reader.Error!Header {
        return .{
            .columns = try io.readInt(reader, u16),
            .rows = try io.readInt(reader, u16),
            .style_count = try io.readInt(reader, u16),
            .hyperlink_count = try io.readInt(reader, u16),
            .style_capacity = try io.readInt(reader, u16),
            .hyperlink_capacity_bytes = try io.readInt(reader, u16),
            .grapheme_capacity_bytes = try io.readInt(reader, u32),
            .string_capacity_bytes = try io.readInt(reader, u32),
        };
    }

    /// Initialize a header from the current contents of a native page.
    ///
    /// This copies the page's existing allocation capacities. It does not
    /// scan cells, allocate, or encode any bytes.
    fn init(page: *const TerminalPage) Header {
        return .{
            .columns = page.size.cols,
            .rows = page.size.rows,
            .style_count = @intCast(page.styles.count()),
            .hyperlink_count = @intCast(page.hyperlink_set.count()),
            .style_capacity = page.capacity.styles,
            .hyperlink_capacity_bytes = page.capacity.hyperlink_bytes,
            .grapheme_capacity_bytes = page.capacity.grapheme_bytes,
            .string_capacity_bytes = page.capacity.string_bytes,
        };
    }

    pub const CapacityError = error{
        InvalidDimensions,
    };

    /// Validate native allocation requirements and produce the page capacity.
    fn pageCapacity(self: Header) CapacityError!TerminalPageCapacity {
        if (self.columns == 0 or self.rows == 0) {
            return error.InvalidDimensions;
        }

        return .{
            .cols = self.columns,
            .rows = self.rows,
            .styles = self.style_capacity,
            .hyperlink_bytes = self.hyperlink_capacity_bytes,
            .grapheme_bytes = self.grapheme_capacity_bytes,
            .string_bytes = self.string_capacity_bytes,
        };
    }

    fn computeLen() usize {
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        const header: Header = .{
            .columns = 0,
            .rows = 0,
            .style_count = 0,
            .hyperlink_count = 0,
            .style_capacity = 0,
            .hyperlink_capacity_bytes = 0,
            .grapheme_capacity_bytes = 0,
            .string_capacity_bytes = 0,
        };
        header.encode(&writer) catch unreachable;
        return writer.end;
    }
};

fn pageHyperlink(
    page: *const TerminalPage,
    entry: *const TerminalHyperlinkPageEntry,
) TerminalHyperlink {
    return .{
        .id = switch (entry.id) {
            .implicit => |value| .{ .implicit = value },
            .explicit => |value| .{ .explicit = value.slice(page.memory) },
        },
        .uri = entry.uri.slice(page.memory),
    };
}

const test_page_fixture = test_fixture.parse(@embedFile("testdata/page-v1.hex"));
const test_header_fixture = test_fixture.parse(@embedFile("testdata/page-header-v1.hex"));
const test_empty_framed_page_fixture = test_fixture.parse(@embedFile("testdata/page-empty-record-v1.hex"));

test "PAGE header golden encoding and decoding" {
    const header: Header = .{
        .columns = 0x0102,
        .rows = 0x0304,
        .style_count = 0x0506,
        .hyperlink_count = 0x0708,
        .style_capacity = 0x090a,
        .hyperlink_capacity_bytes = 0x0b0c,
        .grapheme_capacity_bytes = 0x0d0e0f10,
        .string_capacity_bytes = 0x11121314,
    };
    var buf: [Header.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try header.encode(&writer);
    try test_fixture.expectEqual(
        .bytes,
        "src/terminal/snapshot/testdata/page-header-v1.hex",
        "snapshot_fixture-page-header-v1.hex",
        &test_header_fixture,
        writer.buffered(),
    );

    var source: std.Io.Reader = .fixed(&test_header_fixture);
    var read_buf: [1]u8 = undefined;
    var limited = source.limited(.unlimited, &read_buf);
    try std.testing.expectEqual(header, try Header.decode(&limited.interface));
}

test "reject every truncation" {
    for (0..Header.len) |len| {
        var reader: std.Io.Reader = .fixed(test_header_fixture[0..len]);
        try std.testing.expectError(error.EndOfStream, Header.decode(&reader));
    }
}

test "framed PAGE encode and decode a sparse native page" {
    const capacity: TerminalPageCapacity = .{
        .cols = 3,
        .rows = 2,
        .styles = 8,
        .hyperlink_bytes = 512,
        .grapheme_bytes = 128,
        .string_bytes = 256,
    };
    var page = try TerminalPage.init(capacity);
    defer page.deinit();

    // Create holes in both source tables so the encoded IDs exercise sparse
    // table remapping rather than coincidentally matching decoded IDs.
    const style_a = try page.styles.add(page.memory, .{
        .flags = .{ .bold = true },
    });
    const dead_style = try page.styles.add(page.memory, .{
        .flags = .{ .italic = true },
    });
    const style_b = try page.styles.add(page.memory, .{
        .bg_color = .{ .palette = 42 },
    });
    page.styles.release(page.memory, dead_style);

    const first = page.getRowAndCell(0, 0);
    first.cell.style_id = style_a;
    first.row.styled = true;

    const second = page.getRowAndCell(1, 0);
    second.cell.style_id = style_b;
    second.row.styled = true;

    const third = page.getRowAndCell(2, 0);
    page.styles.use(page.memory, style_a);
    third.cell.style_id = style_a;
    third.row.styled = true;

    const hyperlink_a = try page.insertHyperlink(.{
        .id = .{ .explicit = "a" },
        .uri = "alpha",
    });
    const dead_hyperlink = try page.insertHyperlink(.{
        .id = .{ .explicit = "dead-id" },
        .uri = "dead-uri",
    });
    const hyperlink_b = try page.insertHyperlink(.{
        .id = .{ .implicit = 0x01020304 },
        .uri = "beta",
    });
    page.hyperlink_set.release(page.memory, dead_hyperlink);

    page.hyperlink_set.use(page.memory, hyperlink_a);
    try page.setHyperlink(first.row, first.cell, hyperlink_a);
    try page.setHyperlink(second.row, second.cell, hyperlink_b);
    try page.setHyperlink(third.row, third.cell, hyperlink_a);

    // Cover graphemes, wide-cell pairs, colors, protection, and semantic
    // metadata in one compact two-row page.
    const grapheme = page.getRowAndCell(0, 1);
    grapheme.cell.* = .init('x');
    try page.setGraphemes(
        grapheme.row,
        grapheme.cell,
        &.{ 0x0301, 0x0302 },
    );

    first.cell.content = .{ .codepoint = .{ .data = 'A' } };
    first.cell.wide = .wide;
    first.cell.protected = true;
    first.cell.semantic_content = .prompt;
    first.row.semantic_prompt = .prompt;

    second.cell.wide = .spacer_tail;
    second.cell.semantic_content = .input;

    third.cell.content_tag = .bg_color_palette;
    third.cell.content = .{ .color_palette = .{ .data = 7 } };

    const rgb = page.getRowAndCell(1, 1);
    rgb.cell.content_tag = .bg_color_rgb;
    rgb.cell.content = .{ .color_rgb = .{
        .r = 0xaa,
        .g = 0xbb,
        .b = 0xcc,
    } };
    rgb.cell.protected = true;

    const spacer_head = page.getRowAndCell(2, 1);
    spacer_head.cell.wide = .spacer_head;
    spacer_head.row.wrap = true;
    spacer_head.row.wrap_continuation = true;
    spacer_head.row.semantic_prompt = .prompt_continuation;

    const header: Header = .{
        .columns = 3,
        .rows = 2,
        .style_count = 2,
        .hyperlink_count = 2,
        .style_capacity = 8,
        .hyperlink_capacity_bytes = 512,
        .grapheme_capacity_bytes = 128,
        .string_capacity_bytes = 256,
    };
    try std.testing.expectEqual(header, Header.init(&page));

    // Lock the payload bytes and independently verify the counting writer sees
    // the same encoded length.
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try encodePayload(&page, &counter.writer);

    var encoded: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try encodePayload(&page, &writer);

    try test_fixture.expectEqual(
        .page,
        "src/terminal/snapshot/testdata/page-v1.hex",
        "snapshot_fixture-page-v1.hex",
        &test_page_fixture,
        writer.buffered(),
    );
    try std.testing.expectEqual(
        @as(u64, test_page_fixture.len),
        counter.count,
    );

    // Decode the checked-in reference rather than the just-generated bytes.
    // A one-byte backing buffer exercises streaming reads across every field.
    var source: std.Io.Reader = .fixed(&test_page_fixture);
    var read_buf: [1]u8 = undefined;
    var limited = source.limited(.unlimited, &read_buf);
    var decoded = try decodePayload(
        &limited.interface,
        std.testing.allocator,
    );
    defer decoded.deinit();

    try std.testing.expectEqual(header, Header.init(&decoded));
    try decoded.verifyIntegrity(std.testing.allocator);

    // Decoding compacts the sparse source IDs while preserving table values
    // and all cell references through the remap tables.
    var style_it = decoded.styles.iterator(decoded.memory);
    const decoded_style_a = style_it.next().?;
    try std.testing.expectEqual(@as(TerminalStyleId, 1), decoded_style_a.id);
    try std.testing.expect((TerminalStyle{
        .flags = .{ .bold = true },
    }).eql(decoded_style_a.value_ptr.*));
    const decoded_style_b = style_it.next().?;
    try std.testing.expectEqual(@as(TerminalStyleId, 2), decoded_style_b.id);
    try std.testing.expect((TerminalStyle{
        .bg_color = .{ .palette = 42 },
    }).eql(decoded_style_b.value_ptr.*));
    try std.testing.expectEqual(null, style_it.next());
    try std.testing.expectEqual(
        @as(u16, 2),
        decoded.styles.refCount(decoded.memory, decoded_style_a.id),
    );
    try std.testing.expectEqual(
        @as(u16, 1),
        decoded.styles.refCount(decoded.memory, decoded_style_b.id),
    );

    var hyperlink_it = decoded.hyperlink_set.iterator(decoded.memory);
    const decoded_link_a = hyperlink_it.next().?;
    try std.testing.expectEqual(@as(TerminalHyperlinkId, 1), decoded_link_a.id);
    const decoded_hyperlink_a = pageHyperlink(&decoded, decoded_link_a.value_ptr);
    try std.testing.expectEqualStrings("a", decoded_hyperlink_a.id.explicit);
    try std.testing.expectEqualStrings("alpha", decoded_hyperlink_a.uri);
    const decoded_link_b = hyperlink_it.next().?;
    try std.testing.expectEqual(@as(TerminalHyperlinkId, 2), decoded_link_b.id);
    const decoded_hyperlink_b = pageHyperlink(&decoded, decoded_link_b.value_ptr);
    try std.testing.expectEqual(@as(u32, 0x01020304), decoded_hyperlink_b.id.implicit);
    try std.testing.expectEqualStrings("beta", decoded_hyperlink_b.uri);
    try std.testing.expectEqual(null, hyperlink_it.next());

    const decoded_first = decoded.getRowAndCell(0, 0);
    try std.testing.expectEqual(@as(TerminalStyleId, 1), decoded_first.cell.style_id);
    try std.testing.expectEqual(
        @as(TerminalHyperlinkId, 1),
        decoded.lookupHyperlink(decoded_first.cell).?,
    );

    const decoded_second = decoded.getRowAndCell(1, 0);
    try std.testing.expectEqual(@as(TerminalStyleId, 2), decoded_second.cell.style_id);
    try std.testing.expectEqual(
        @as(TerminalHyperlinkId, 2),
        decoded.lookupHyperlink(decoded_second.cell).?,
    );

    // The first re-encode reflects compacted IDs; subsequent round trips must
    // stabilize byte-for-byte.
    var reencoded: [512]u8 = undefined;
    var rewriter: std.Io.Writer = .fixed(&reencoded);
    try encodePayload(&decoded, &rewriter);
    try std.testing.expect(!std.mem.eql(
        u8,
        writer.buffered(),
        rewriter.buffered(),
    ));

    var reencoded_reader: std.Io.Reader = .fixed(rewriter.buffered());
    var decoded_again = try decodePayload(
        &reencoded_reader,
        std.testing.allocator,
    );
    defer decoded_again.deinit();
    try decoded_again.verifyIntegrity(std.testing.allocator);

    var reencoded_again: [512]u8 = undefined;
    var rewriter_again: std.Io.Writer = .fixed(&reencoded_again);
    try encodePayload(&decoded_again, &rewriter_again);
    try std.testing.expectEqualStrings(
        rewriter.buffered(),
        rewriter_again.buffered(),
    );
}

test "framed PAGE golden empty record" {
    const capacity: TerminalPageCapacity = .{
        .cols = 1,
        .rows = 1,
        .styles = 0,
        .hyperlink_bytes = 0,
        .grapheme_bytes = 0,
        .string_bytes = 0,
    };
    var page = try TerminalPage.init(capacity);
    defer page.deinit();

    var destination: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer destination.deinit();
    var stream: record.Writer = .init(
        std.testing.allocator,
        &destination.writer,
    );
    defer stream.deinit();
    try encode(&page, &stream);
    try test_fixture.expectEqual(
        .bytes,
        "src/terminal/snapshot/testdata/page-empty-record-v1.hex",
        "snapshot_fixture-page-empty-record-v1.hex",
        &test_empty_framed_page_fixture,
        destination.written(),
    );

    var source: std.Io.Reader = .fixed(&test_empty_framed_page_fixture);
    var decoded = try decode(&source, std.testing.allocator);
    defer decoded.deinit();
    try std.testing.expectEqual(
        Header.init(&page),
        Header.init(&decoded),
    );
}

test "framed PAGE rejects incomplete wide cells transactionally" {
    const testing = std.testing;

    // One column puts the wide cell at the row end. Two columns put an
    // ordinary narrow cell after it. Neither case supplies a spacer tail.
    for ([_]u16{ 1, 2 }) |columns| {
        var page = try TerminalPage.init(.{
            .cols = columns,
            .rows = 1,
        });
        defer page.deinit();
        const first = page.getRowAndCell(0, 0).cell;
        first.* = .init('A');
        first.wide = .wide;
        if (columns > 1) {
            page.getRowAndCell(1, 0).cell.* = .init('B');
        }

        var destination: std.Io.Writer.Allocating = .init(testing.allocator);
        defer destination.deinit();
        try destination.writer.writeAll("prefix");
        var stream: record.Writer = .init(
            testing.allocator,
            &destination.writer,
        );
        defer stream.deinit();
        try testing.expectError(
            error.InvalidWideCell,
            encode(&page, &stream),
        );
        try testing.expectEqualStrings("prefix", destination.written());
    }
}

test "framed PAGE rejects a different record tag" {
    var wrong_tag = test_empty_framed_page_fixture;
    std.mem.writeInt(
        u16,
        wrong_tag[0..2],
        @intFromEnum(record.Tag.screen),
        .little,
    );
    var reader: std.Io.Reader = .fixed(&wrong_tag);
    try std.testing.expectError(
        error.UnexpectedRecordTag,
        decode(&reader, std.testing.allocator),
    );
}

test "framed PAGE preserves following bytes" {
    var source: std.Io.Reader = .fixed(
        test_empty_framed_page_fixture ++ "next",
    );
    var decoded = try decode(&source, std.testing.allocator);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("next", try source.take(4));
}

test "decode sparse page rejects every truncation" {
    for (0..test_page_fixture.len) |len| {
        var reader: std.Io.Reader = .fixed(test_page_fixture[0..len]);
        try std.testing.expectError(
            error.EndOfStream,
            decodePayload(&reader, std.testing.allocator),
        );
    }
}

test "decode accepts unordered sparse style IDs and ignores zero" {
    const header: Header = .{
        .columns = 2,
        .rows = 1,
        .style_count = 2,
        .hyperlink_count = 0,
        .style_capacity = 8,
        .hyperlink_capacity_bytes = 0,
        .grapheme_capacity_bytes = 0,
        .string_capacity_bytes = 0,
    };

    var descending: [
        Header.len +
            2 * (2 + style.len) +
            3 + 2 * 8 + 4
    ]u8 = undefined;
    var descending_writer: std.Io.Writer = .fixed(&descending);
    try header.encode(&descending_writer);
    try io.writeInt(&descending_writer, TerminalStyleId, 3);
    try style.encode(.{ .flags = .{ .bold = true } }, &descending_writer);
    try io.writeInt(&descending_writer, TerminalStyleId, 2);
    try style.encode(.{ .flags = .{ .italic = true } }, &descending_writer);
    try descending_writer.writeByte(@bitCast(grid.Row{ .cell_width = .eight }));
    try io.writeInt(&descending_writer, u16, 2); // cell count
    try io.writeInt(&descending_writer, u64, @bitCast(grid.Cell{
        .content = 'A',
        .style_id = 3,
    }));
    try io.writeInt(&descending_writer, u64, @bitCast(grid.Cell{
        .content = 'B',
        .style_id = 2,
    }));
    try io.writeInt(&descending_writer, u32, 0); // grapheme section

    var descending_reader: std.Io.Reader = .fixed(
        descending_writer.buffered(),
    );
    var decoded_descending = try decodePayload(
        &descending_reader,
        std.testing.allocator,
    );
    defer decoded_descending.deinit();
    try std.testing.expectEqual(@as(usize, 2), decoded_descending.styles.count());
    try std.testing.expectEqual(
        @as(TerminalStyleId, 1),
        decoded_descending.getRowAndCell(0, 0).cell.style_id,
    );
    try std.testing.expectEqual(
        @as(TerminalStyleId, 2),
        decoded_descending.getRowAndCell(1, 0).cell.style_id,
    );

    const one_header: Header = .{
        .columns = 1,
        .rows = 1,
        .style_count = 1,
        .hyperlink_count = 0,
        .style_capacity = 8,
        .hyperlink_capacity_bytes = 0,
        .grapheme_capacity_bytes = 0,
        .string_capacity_bytes = 0,
    };

    var zero: [Header.len + 2 + style.len + 7]u8 = undefined;
    var zero_writer: std.Io.Writer = .fixed(&zero);
    try one_header.encode(&zero_writer);
    try io.writeInt(&zero_writer, TerminalStyleId, 0);
    try style.encode(.{ .flags = .{ .bold = true } }, &zero_writer);

    var zero_grid = try TerminalPage.init(.{ .cols = 1, .rows = 1 });
    defer zero_grid.deinit();
    try grid.encode(&zero_grid, &zero_writer);

    var zero_reader: std.Io.Reader = .fixed(zero_writer.buffered());
    var decoded_zero = try decodePayload(
        &zero_reader,
        std.testing.allocator,
    );
    defer decoded_zero.deinit();
    try std.testing.expectEqual(@as(usize, 0), decoded_zero.styles.count());
}

test "decode accepts unordered sparse hyperlink IDs" {
    const header: Header = .{
        .columns = 2,
        .rows = 1,
        .style_count = 0,
        .hyperlink_count = 2,
        .style_capacity = 0,
        .hyperlink_capacity_bytes = 512,
        .grapheme_capacity_bytes = 0,
        .string_capacity_bytes = 6,
    };

    const first: TerminalHyperlink = .{
        .id = .{ .implicit = 1 },
        .uri = "one",
    };
    const second: TerminalHyperlink = .{
        .id = .{ .implicit = 2 },
        .uri = "two",
    };

    var encoded: [
        Header.len +
            2 * 14 +
            3 + 2 * 8 + 4
    ]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try header.encode(&writer);
    try io.writeInt(&writer, TerminalHyperlinkId, 3);
    try hyperlink.encode(first, &writer);
    try io.writeInt(&writer, TerminalHyperlinkId, 2);
    try hyperlink.encode(second, &writer);
    try writer.writeByte(@bitCast(grid.Row{ .cell_width = .eight }));
    try io.writeInt(&writer, u16, 2); // cell count
    try io.writeInt(&writer, u64, @bitCast(grid.Cell{
        .content = 'A',
        .hyperlink = true,
        .hyperlink_id = 3,
    }));
    try io.writeInt(&writer, u64, @bitCast(grid.Cell{
        .content = 'B',
        .hyperlink = true,
        .hyperlink_id = 2,
    }));
    try io.writeInt(&writer, u32, 0); // grapheme section

    var reader: std.Io.Reader = .fixed(writer.buffered());
    var decoded = try decodePayload(
        &reader,
        std.testing.allocator,
    );
    defer decoded.deinit();
    try std.testing.expectEqual(
        @as(usize, 2),
        decoded.hyperlink_set.count(),
    );
    const first_id = decoded.lookupHyperlink(
        decoded.getRowAndCell(0, 0).cell,
    ).?;
    const second_id = decoded.lookupHyperlink(
        decoded.getRowAndCell(1, 0).cell,
    ).?;
    try std.testing.expectEqual(
        @as(u16, 1),
        decoded.hyperlink_set.refCount(decoded.memory, first_id),
    );
    try std.testing.expectEqual(
        @as(u16, 1),
        decoded.hyperlink_set.refCount(decoded.memory, second_id),
    );
    try std.testing.expectEqualStrings(
        "one",
        decoded.hyperlink_set.get(
            decoded.memory,
            first_id,
        ).uri.slice(decoded.memory),
    );
    try std.testing.expectEqualStrings(
        "two",
        decoded.hyperlink_set.get(
            decoded.memory,
            second_id,
        ).uri.slice(decoded.memory),
    );
}

test "decode defaults missing sparse cell references" {
    // An unknown style ID falls back to the default style.
    const style_header: Header = .{
        .columns = 1,
        .rows = 1,
        .style_count = 0,
        .hyperlink_count = 0,
        .style_capacity = 8,
        .hyperlink_capacity_bytes = 0,
        .grapheme_capacity_bytes = 0,
        .string_capacity_bytes = 0,
    };

    var style_encoded: [Header.len + 3 + 8 + 4]u8 = undefined;
    var style_writer: std.Io.Writer = .fixed(&style_encoded);
    try style_header.encode(&style_writer);
    try style_writer.writeByte(0x30); // row flags, full cell width
    try io.writeInt(&style_writer, u16, 1); // cell count
    try io.writeInt(&style_writer, u64, @bitCast(grid.Cell{
        .style_id = 1,
    }));
    try io.writeInt(&style_writer, u32, 0); // grapheme section

    var style_reader: std.Io.Reader = .fixed(style_writer.buffered());
    var style_page = try decodePayload(
        &style_reader,
        std.testing.allocator,
    );
    defer style_page.deinit();
    try std.testing.expectEqual(
        @as(TerminalStyleId, 0),
        style_page.getRowAndCell(0, 0).cell.style_id,
    );

    // An unknown hyperlink ID likewise falls back to no hyperlink.
    const hyperlink_header: Header = .{
        .columns = 1,
        .rows = 1,
        .style_count = 0,
        .hyperlink_count = 0,
        .style_capacity = 0,
        .hyperlink_capacity_bytes = 512,
        .grapheme_capacity_bytes = 0,
        .string_capacity_bytes = 0,
    };

    var hyperlink_encoded: [Header.len + 3 + 8 + 4]u8 = undefined;
    var hyperlink_writer: std.Io.Writer = .fixed(&hyperlink_encoded);
    try hyperlink_header.encode(&hyperlink_writer);
    try hyperlink_writer.writeByte(0x30); // row flags, full cell width
    try io.writeInt(&hyperlink_writer, u16, 1); // cell count
    try io.writeInt(&hyperlink_writer, u64, @bitCast(grid.Cell{
        .hyperlink = true,
        .hyperlink_id = 1,
    }));
    try io.writeInt(&hyperlink_writer, u32, 0); // grapheme section

    var hyperlink_reader: std.Io.Reader = .fixed(
        hyperlink_writer.buffered(),
    );
    var hyperlink_page = try decodePayload(
        &hyperlink_reader,
        std.testing.allocator,
    );
    defer hyperlink_page.deinit();
    const hyperlink_cell = hyperlink_page.getRowAndCell(0, 0).cell;
    try std.testing.expect(!hyperlink_cell.hyperlink);
    try std.testing.expectEqual(
        null,
        hyperlink_page.lookupHyperlink(hyperlink_cell),
    );
}

test "decode normalizes invalid grid semantics" {
    const header: Header = .{
        .columns = 3,
        .rows = 1,
        .style_count = 0,
        .hyperlink_count = 0,
        .style_capacity = 0,
        .hyperlink_capacity_bytes = 0,
        .grapheme_capacity_bytes = 0,
        .string_capacity_bytes = 0,
    };

    var encoded: [Header.len + 3 + 3 * 8 + 4 + 10]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try header.encode(&writer);

    // Preserve wrap while degrading the unknown semantic-prompt value to none
    // and ignoring all reserved row bits.
    try writer.writeByte(0xFD);
    try io.writeInt(&writer, u16, 3);

    // A text cell replaces an invalid Unicode scalar with U+FFFD while its
    // reserved semantic content degrades to output.
    try io.writeInt(&writer, u64, @bitCast(grid.Cell{
        .content = 0xD800,
        .semantic_content = 3,
    }));

    // A declared grapheme suffix cannot fit the advertised zero capacity,
    // so decoding preserves the base character and drops the suffix.
    try io.writeInt(&writer, u64, @bitCast(grid.Cell{
        .kind = 1,
        .content = 'x',
    }));

    // Reserved palette content bits do not obscure the valid low palette
    // byte.
    try io.writeInt(&writer, u64, @bitCast(grid.Cell{
        .kind = 2,
        .content = 0xFFFF07,
    }));

    // The grapheme section carries the suffix for the second cell.
    try io.writeInt(&writer, u32, 1);
    try io.writeInt(&writer, u16, 0);
    try io.writeInt(&writer, u16, 1);
    try io.writeInt(&writer, u16, 1);
    try io.writeInt(&writer, u32, 0x0301);

    var reader: std.Io.Reader = .fixed(writer.buffered());
    var page = try decodePayload(&reader, std.testing.allocator);
    defer page.deinit();
    try page.verifyIntegrity(std.testing.allocator);

    const first = page.getRowAndCell(0, 0);
    try std.testing.expect(first.row.wrap);
    try std.testing.expectEqual(
        terminal_page.Row.SemanticPrompt.none,
        first.row.semantic_prompt,
    );
    try std.testing.expectEqual(@as(u21, 0xFFFD), first.cell.codepoint());
    try std.testing.expectEqual(
        terminal_page.Cell.Wide.narrow,
        first.cell.wide,
    );
    try std.testing.expectEqual(
        terminal_page.Cell.SemanticContent.output,
        first.cell.semantic_content,
    );
    try std.testing.expect(!first.cell.protected);
    try std.testing.expect(!first.cell.hasGrapheme());

    const second = page.getRowAndCell(1, 0).cell;
    try std.testing.expectEqual(@as(u21, 'x'), second.codepoint());
    try std.testing.expect(!second.hasGrapheme());

    const third = page.getRowAndCell(2, 0).cell;
    try std.testing.expectEqual(
        terminal_page.Cell.ContentTag.bg_color_palette,
        third.content_tag,
    );
    try std.testing.expectEqual(
        @as(u8, 7),
        third.content.color_palette.data,
    );
    try std.testing.expect(!third.hasGrapheme());
}

test "decode validates dimensions" {
    const cases = [_]Header{
        .{
            .columns = 0,
            .rows = 24,
            .style_count = 0,
            .hyperlink_count = 0,
            .style_capacity = 0,
            .hyperlink_capacity_bytes = 0,
            .grapheme_capacity_bytes = 0,
            .string_capacity_bytes = 0,
        },
        .{
            .columns = 80,
            .rows = 0,
            .style_count = 0,
            .hyperlink_count = 0,
            .style_capacity = 0,
            .hyperlink_capacity_bytes = 0,
            .grapheme_capacity_bytes = 0,
            .string_capacity_bytes = 0,
        },
    };

    for (cases) |header| {
        var encoded: [Header.len]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&encoded);
        try header.encode(&writer);

        var reader: std.Io.Reader = .fixed(writer.buffered());
        try std.testing.expectError(
            error.InvalidDimensions,
            decodePayload(&reader, std.testing.allocator),
        );
    }
}

test "decode propagates a style table read failure" {
    const FailOnceReader = struct {
        source: std.Io.Reader,
        interface: std.Io.Reader,
        bytes_before_failure: usize,
        failed: bool = false,

        fn init(bytes: []const u8, bytes_before_failure: usize) @This() {
            return .{
                .source = .fixed(bytes),
                .interface = .{
                    .vtable = &.{ .stream = stream },
                    .buffer = &.{},
                    .seek = 0,
                    .end = 0,
                },
                .bytes_before_failure = bytes_before_failure,
            };
        }

        fn stream(
            reader: *std.Io.Reader,
            writer: *std.Io.Writer,
            limit: std.Io.Limit,
        ) std.Io.Reader.StreamError!usize {
            const self: *@This() = @fieldParentPtr("interface", reader);
            if (self.bytes_before_failure == 0 and !self.failed) {
                self.failed = true;
                return error.ReadFailed;
            }

            const read_limit = if (self.failed)
                limit
            else
                limit.min(.limited(self.bytes_before_failure));
            const n = try self.source.stream(writer, read_limit);
            if (!self.failed) self.bytes_before_failure -= n;
            return n;
        }
    };

    const header: Header = .{
        .columns = 1,
        .rows = 1,
        .style_count = 1,
        .hyperlink_count = 0,
        .style_capacity = 8,
        .hyperlink_capacity_bytes = 0,
        .grapheme_capacity_bytes = 0,
        .string_capacity_bytes = 0,
    };

    // If the style read error is swallowed, its sixteen zero bytes are then
    // misread as a valid empty grid and the unframed payload appears to decode.
    var encoded: [Header.len + @sizeOf(TerminalStyleId) + style.len]u8 =
        @splat(0);
    var writer: std.Io.Writer = .fixed(&encoded);
    try header.encode(&writer);
    try io.writeInt(&writer, TerminalStyleId, 1);
    try writer.splatByteAll(0, style.len);

    var source = FailOnceReader.init(
        writer.buffered(),
        Header.len + @sizeOf(TerminalStyleId),
    );
    var decoded = decodePayload(
        &source.interface,
        std.testing.allocator,
    ) catch |err| {
        try std.testing.expectEqual(error.ReadFailed, err);
        return;
    };
    defer decoded.deinit();
    try std.testing.expect(false);
}

test "decode normalizes duplicate default and invalid style entries" {
    const header: Header = .{
        .columns = 1,
        .rows = 1,
        .style_count = 2,
        .hyperlink_count = 0,
        .style_capacity = 16,
        .hyperlink_capacity_bytes = 512,
        .grapheme_capacity_bytes = 0,
        .string_capacity_bytes = 256,
    };
    const duplicate_style: TerminalStyle = .{
        .flags = .{ .bold = true },
    };

    // Generate a valid grid whose cell references a sparse style ID. The PAGE
    // table below can then give that ID duplicate, default, or invalid contents
    // without hand-authoring the cell wire format.
    var grid_page = try TerminalPage.init(.{
        .cols = 1,
        .rows = 1,
        .styles = 8,
    });
    defer grid_page.deinit();
    const released_style_a = try grid_page.styles.add(
        grid_page.memory,
        .{ .flags = .{ .italic = true } },
    );
    const released_style_b = try grid_page.styles.add(
        grid_page.memory,
        .{ .bg_color = .{ .palette = 1 } },
    );
    const encoded_style_id = try grid_page.styles.add(
        grid_page.memory,
        duplicate_style,
    );
    grid_page.styles.release(grid_page.memory, released_style_a);
    grid_page.styles.release(grid_page.memory, released_style_b);
    const grid_cell = grid_page.getRowAndCell(0, 0);
    grid_cell.cell.* = .init('A');
    grid_cell.cell.style_id = encoded_style_id;
    grid_cell.row.styled = true;

    var grid_bytes: [64]u8 = undefined;
    var grid_writer: std.Io.Writer = .fixed(&grid_bytes);
    try grid.encode(&grid_page, &grid_writer);

    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try header.encode(&encoded.writer);
    try io.writeInt(&encoded.writer, TerminalStyleId, 1);
    try style.encode(duplicate_style, &encoded.writer);
    try io.writeInt(&encoded.writer, TerminalStyleId, encoded_style_id);
    try style.encode(duplicate_style, &encoded.writer);
    try encoded.writer.writeAll(grid_writer.buffered());

    var reader: std.Io.Reader = .fixed(encoded.written());
    var duplicate_decoded = try decodePayload(
        &reader,
        std.testing.allocator,
    );
    defer duplicate_decoded.deinit();
    try std.testing.expectEqual(@as(usize, 1), duplicate_decoded.styles.count());
    const duplicate_cell = duplicate_decoded.getRowAndCell(0, 0).cell;
    try std.testing.expect(duplicate_cell.style_id != 0);
    try std.testing.expect(
        duplicate_decoded.styles.get(
            duplicate_decoded.memory,
            duplicate_cell.style_id,
        ).flags.bold,
    );

    const default_header: Header = .{
        .columns = 1,
        .rows = 1,
        .style_count = 1,
        .hyperlink_count = 0,
        .style_capacity = 16,
        .hyperlink_capacity_bytes = 0,
        .grapheme_capacity_bytes = 0,
        .string_capacity_bytes = 0,
    };
    var default_encoded: std.Io.Writer.Allocating = .init(
        std.testing.allocator,
    );
    defer default_encoded.deinit();
    try default_header.encode(&default_encoded.writer);
    try io.writeInt(
        &default_encoded.writer,
        TerminalStyleId,
        encoded_style_id,
    );
    try style.encode(.{}, &default_encoded.writer);
    try default_encoded.writer.writeAll(grid_writer.buffered());

    var default_reader: std.Io.Reader = .fixed(default_encoded.written());
    var default_decoded = try decodePayload(
        &default_reader,
        std.testing.allocator,
    );
    defer default_decoded.deinit();
    try std.testing.expectEqual(
        @as(TerminalStyleId, 0),
        default_decoded.getRowAndCell(0, 0).cell.style_id,
    );

    // The strict style codec rejects this kind, but PAGE owns the fixed entry
    // boundary and can safely map the encoded ID to the default style. A zero
    // capacity hint also remains advisory.
    var invalid_header = default_header;
    invalid_header.style_capacity = 0;
    var invalid_encoded: std.Io.Writer.Allocating = .init(
        std.testing.allocator,
    );
    defer invalid_encoded.deinit();
    try invalid_header.encode(&invalid_encoded.writer);
    try io.writeInt(
        &invalid_encoded.writer,
        TerminalStyleId,
        encoded_style_id,
    );
    try invalid_encoded.writer.writeByte(3);
    try invalid_encoded.writer.splatByteAll(0, style.len - 1);
    try invalid_encoded.writer.writeAll(grid_writer.buffered());

    var invalid_reader: std.Io.Reader = .fixed(invalid_encoded.written());
    var invalid_decoded = try decodePayload(
        &invalid_reader,
        std.testing.allocator,
    );
    defer invalid_decoded.deinit();
    try std.testing.expectEqual(
        @as(TerminalStyleId, 0),
        invalid_decoded.getRowAndCell(0, 0).cell.style_id,
    );
}

test "decode releases unused style table references" {
    const header: Header = .{
        .columns = 1,
        .rows = 1,
        .style_count = 1,
        .hyperlink_count = 0,
        .style_capacity = 8,
        .hyperlink_capacity_bytes = 0,
        .grapheme_capacity_bytes = 0,
        .string_capacity_bytes = 0,
    };

    var empty_page = try TerminalPage.init(.{ .cols = 1, .rows = 1 });
    defer empty_page.deinit();
    var grid_bytes: [32]u8 = undefined;
    var grid_writer: std.Io.Writer = .fixed(&grid_bytes);
    try grid.encode(&empty_page, &grid_writer);

    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try header.encode(&encoded.writer);
    try io.writeInt(&encoded.writer, TerminalStyleId, 7);
    try style.encode(.{ .flags = .{ .bold = true } }, &encoded.writer);
    try encoded.writer.writeAll(grid_writer.buffered());

    var reader: std.Io.Reader = .fixed(encoded.written());
    var decoded = try decodePayload(&reader, std.testing.allocator);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 0), decoded.styles.count());

    // The dead table-only entry is absent from the very first re-encode.
    var canonical: [64]u8 = undefined;
    var canonical_writer: std.Io.Writer = .fixed(&canonical);
    try encodePayload(&decoded, &canonical_writer);
    var canonical_reader: std.Io.Reader = .fixed(canonical_writer.buffered());
    const canonical_header = try Header.decode(&canonical_reader);
    try std.testing.expectEqual(@as(u16, 0), canonical_header.style_count);
}

test "decode reuses duplicate hyperlinks" {
    const header: Header = .{
        .columns = 1,
        .rows = 1,
        .style_count = 0,
        .hyperlink_count = 2,
        .style_capacity = 0,
        .hyperlink_capacity_bytes = 512,
        .grapheme_capacity_bytes = 0,
        .string_capacity_bytes = 16,
    };
    const duplicate: TerminalHyperlink = .{
        .id = .{ .explicit = "id" },
        .uri = "uri",
    };

    // As with styles above, use a sparse native ID to make grid.encode produce
    // the cell reference whose table value this test deliberately duplicates.
    var grid_page = try TerminalPage.init(.{
        .cols = 1,
        .rows = 1,
        .hyperlink_bytes = 512,
        .string_bytes = 64,
    });
    defer grid_page.deinit();
    const released_hyperlink_a = try grid_page.insertHyperlink(.{
        .id = .{ .implicit = 1 },
        .uri = "one",
    });
    const released_hyperlink_b = try grid_page.insertHyperlink(.{
        .id = .{ .implicit = 2 },
        .uri = "two",
    });
    const encoded_hyperlink_id = try grid_page.insertHyperlink(.{
        .id = .{ .implicit = 3 },
        .uri = "three",
    });
    grid_page.hyperlink_set.release(
        grid_page.memory,
        released_hyperlink_a,
    );
    grid_page.hyperlink_set.release(
        grid_page.memory,
        released_hyperlink_b,
    );
    const grid_cell = grid_page.getRowAndCell(0, 0);
    grid_cell.cell.* = .init('A');
    try grid_page.setHyperlink(
        grid_cell.row,
        grid_cell.cell,
        encoded_hyperlink_id,
    );

    var grid_bytes: [64]u8 = undefined;
    var grid_writer: std.Io.Writer = .fixed(&grid_bytes);
    try grid.encode(&grid_page, &grid_writer);

    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try header.encode(&encoded.writer);
    try io.writeInt(&encoded.writer, TerminalHyperlinkId, 1);
    try hyperlink.encode(duplicate, &encoded.writer);
    try io.writeInt(
        &encoded.writer,
        TerminalHyperlinkId,
        encoded_hyperlink_id,
    );
    try hyperlink.encode(duplicate, &encoded.writer);
    try encoded.writer.writeAll(grid_writer.buffered());

    var reader: std.Io.Reader = .fixed(encoded.written());
    var decoded = try decodePayload(
        &reader,
        std.testing.allocator,
    );
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoded.hyperlink_set.count());
    const cell = decoded.getRowAndCell(0, 0).cell;
    try std.testing.expect(cell.hyperlink);
    const id = decoded.lookupHyperlink(cell).?;
    const entry = decoded.hyperlink_set.get(decoded.memory, id);
    try std.testing.expectEqual(
        @as(u16, 1),
        decoded.hyperlink_set.refCount(decoded.memory, id),
    );
    try std.testing.expectEqualStrings(
        "uri",
        entry.uri.slice(decoded.memory),
    );

    // Overwriting the sole linked cell must make the deduplicated entry dead.
    // Any surviving reference belongs to the decode-time wire table, not the
    // native page.
    decoded.clearCells(decoded.getRow(0), 0, 1);
    try std.testing.expectEqual(@as(usize, 0), decoded.hyperlink_set.count());
}

test "discard consumes exactly one PAGE record" {
    const testing = std.testing;

    // Discard validates framing only, so an arbitrary payload keeps this test
    // focused on record consumption rather than page structure.
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    var stream: record.Writer = .init(testing.allocator, &encoded.writer);
    defer stream.deinit();
    {
        const payload = stream.begin(.page);
        errdefer stream.cancel();
        try payload.writeAll("undecodable page payload");
        try stream.finish();
    }
    const record_len = encoded.written().len;
    try encoded.writer.writeAll("next");

    var source: std.Io.Reader = .fixed(encoded.written());
    try discard(&source);
    try testing.expectEqualStrings("next", try source.take(4));

    // Only PAGE records may be discarded; the tag remains strict.
    var wrong_tag: std.Io.Writer.Allocating = .init(testing.allocator);
    defer wrong_tag.deinit();
    var wrong_tag_stream: record.Writer = .init(
        testing.allocator,
        &wrong_tag.writer,
    );
    defer wrong_tag_stream.deinit();
    {
        const payload = wrong_tag_stream.begin(.history);
        errdefer wrong_tag_stream.cancel();
        try payload.writeAll("payload");
        try wrong_tag_stream.finish();
    }
    var wrong_tag_source: std.Io.Reader = .fixed(wrong_tag.written());
    try testing.expectError(
        error.UnexpectedRecordTag,
        discard(&wrong_tag_source),
    );

    // Discarded bytes are still covered by the record CRC.
    const corrupted = try testing.allocator.dupe(
        u8,
        encoded.written()[0..record_len],
    );
    defer testing.allocator.free(corrupted);
    corrupted[corrupted.len - 1] ^= 1;
    var corrupted_source: std.Io.Reader = .fixed(corrupted);
    try testing.expectError(error.InvalidChecksum, discard(&corrupted_source));

    // A truncated payload is detected before `finish`.
    var truncated_source: std.Io.Reader = .fixed(
        encoded.written()[0 .. record_len - 1],
    );
    try testing.expectError(error.EndOfStream, discard(&truncated_source));
}

test "decode ignores empty hyperlink strings" {
    const header: Header = .{
        .columns = 1,
        .rows = 1,
        .style_count = 0,
        .hyperlink_count = 1,
        .style_capacity = 0,
        .hyperlink_capacity_bytes = 0,
        .grapheme_capacity_bytes = 0,
        .string_capacity_bytes = 16,
    };
    const fixtures = [_][]const u8{
        // Empty implicit URI.
        "\x01\x01\x00\x00\x00\x00\x00\x00\x00",
        // Empty explicit ID.
        "\x02\x00\x00\x00\x00\x03\x00\x00\x00uri",
        // Empty explicit URI.
        "\x02\x02\x00\x00\x00id\x00\x00\x00\x00",
        // Valid contents that cannot fit the zero-capacity native set.
        "\x01\x01\x00\x00\x00\x03\x00\x00\x00uri",
    };

    // Only the invalid hyperlink entry itself is hand-authored above. Generate
    // its cell reference through the native grid encoder.
    var grid_page = try TerminalPage.init(.{
        .cols = 1,
        .rows = 1,
        .hyperlink_bytes = 256,
        .string_bytes = 16,
    });
    defer grid_page.deinit();
    const encoded_hyperlink_id = try grid_page.insertHyperlink(.{
        .id = .{ .implicit = 1 },
        .uri = "uri",
    });
    const grid_cell = grid_page.getRowAndCell(0, 0);
    grid_cell.cell.* = .init('A');
    try grid_page.setHyperlink(
        grid_cell.row,
        grid_cell.cell,
        encoded_hyperlink_id,
    );
    var grid_bytes: [64]u8 = undefined;
    var grid_writer: std.Io.Writer = .fixed(&grid_bytes);
    try grid.encode(&grid_page, &grid_writer);

    for (fixtures) |fixture| {
        var encoded: std.Io.Writer.Allocating = .init(
            std.testing.allocator,
        );
        defer encoded.deinit();
        try header.encode(&encoded.writer);
        try io.writeInt(
            &encoded.writer,
            TerminalHyperlinkId,
            encoded_hyperlink_id,
        );
        try encoded.writer.writeAll(fixture);

        // The cell refers to the ignored table entry. Its absent native
        // remapping must degrade to no hyperlink while preserving the cell.
        try encoded.writer.writeAll(grid_writer.buffered());

        var reader: std.Io.Reader = .fixed(encoded.written());
        var decoded = try decodePayload(
            &reader,
            std.testing.allocator,
        );
        defer decoded.deinit();

        try std.testing.expectEqual(
            @as(usize, 0),
            decoded.hyperlink_set.count(),
        );
        const cell = decoded.getRowAndCell(0, 0).cell;
        try std.testing.expectEqual(@as(u21, 'A'), cell.codepoint());
        try std.testing.expect(!cell.hyperlink);
        try std.testing.expectEqual(null, decoded.lookupHyperlink(cell));
    }
}
