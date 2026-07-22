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
//! The default style and absence of a hyperlink are implicit at wire
//! index zero and are not included in these counts. Encoded table entries
//! receive one-based wire indexes in their encoded order.
//!
//! The final four fields are allocation hints copied from the source page.
//! These represent upper limits on what this page might contain. A decoder
//! can optionally choose to use this for preallocation or it can ignore
//! and decode and allocate dynamically.
//!
//! ### Payload
//!
//! This is still a work-in-progress. The current implementation encodes and
//! decodes the header, style table, and hyperlink table only. It does not yet
//! produce or consume a complete PAGE payload.
//!
//! Following the header, data is tightly packed in the following order:
//! styles, hyperlinks, cells. TODO!

const std = @import("std");
const hyperlink = @import("hyperlink.zig");
const io = @import("io.zig");
const style = @import("style.zig");
const terminal_hyperlink = @import("../hyperlink.zig");
const terminal_page = @import("../page.zig");
const terminal_style = @import("../style.zig");

/// Errors possible while encoding the native PAGE prefix.
pub const EncodeError = hyperlink.EncodeError;

/// Encode the PAGE header and lookup tables directly from a native page.
///
/// Only the currently implemented PAGE prefix is written. Rows and cells will
/// be appended by a later increment. The page is iterated in place and no
/// temporary storage is allocated or retained.
pub fn encode(
    page: *const terminal_page.Page,
    writer: *std.Io.Writer,
) EncodeError!void {
    // Write header
    try Header.init(page).encode(writer);

    // Packed styles
    var style_it = page.styles.iterator(page.memory);
    while (style_it.next()) |entry| {
        try style.encode(entry.value_ptr.*, writer);
    }

    // Packed hyperlinks
    var hyperlink_it = page.hyperlink_set.iterator(page.memory);
    while (hyperlink_it.next()) |entry| {
        try hyperlink.encode(pageHyperlink(page, entry.value_ptr), writer);
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
    fn init(page: *const terminal_page.Page) Header {
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

/// The implemented prefix of a PAGE payload: its header and lookup tables.
///
/// This borrowed representation does not own either table. Encoding writes
/// the header, exactly `header.style_count` non-default styles, and exactly
/// `header.hyperlink_count` unique hyperlinks. Rows and cells will be appended
/// by later increments.
pub const Payload = struct {
    header: Header,
    styles: []const terminal_style.Style,
    hyperlinks: []const terminal_hyperlink.Hyperlink,

    pub const EncodeError = hyperlink.EncodeError || error{
        /// `header.style_count` does not match the provided style slice.
        StyleCountMismatch,

        /// The default style cannot appear in the non-default style table.
        DefaultStyle,

        /// `header.hyperlink_count` does not match the provided hyperlink slice.
        HyperlinkCountMismatch,
    };

    pub const DecodeError = style.DecodeError || hyperlink.DecodeError || error{
        /// `header.style_count` does not match the provided style storage.
        StyleCountMismatch,

        /// The default style cannot appear in the non-default style table.
        DefaultStyle,

        /// `header.hyperlink_count` does not match the provided hyperlink storage.
        HyperlinkCountMismatch,
    };

    /// Caller-owned storage used while decoding the implemented payload prefix.
    pub const Buffers = struct {
        /// Exact storage for the non-default style table.
        styles: []terminal_style.Style,

        /// Exact storage for the unique hyperlink table.
        hyperlinks: []terminal_hyperlink.Hyperlink,

        /// Storage for explicit hyperlink IDs and URIs. This must be large
        /// enough for the decoded entries; unused trailing bytes are allowed.
        hyperlink_strings: []u8,
    };

    /// Encode the PAGE header and its complete style and hyperlink tables.
    pub fn encode(
        self: Payload,
        writer: *std.Io.Writer,
    ) Payload.EncodeError!void {
        // Some purposeful validation here, don't want to just assert
        // this because its very important to get this right for the wire
        // format.
        if (self.styles.len != self.header.style_count) {
            return error.StyleCountMismatch;
        }
        for (self.styles) |entry| {
            if (entry.default()) return error.DefaultStyle;
        }
        if (self.hyperlinks.len != self.header.hyperlink_count) {
            return error.HyperlinkCountMismatch;
        }

        // (1) Header
        // (2) Styles
        // (3) Hyperlinks
        try self.header.encode(writer);
        for (self.styles) |entry| try style.encode(entry, writer);
        for (self.hyperlinks) |entry| try hyperlink.encode(entry, writer);
    }

    /// Decode the lookup tables after `header` has already been decoded.
    ///
    /// Separating header decoding lets the caller inspect the table counts and
    /// capacity hints before choosing fixed, stack, pooled, or allocated
    /// storage. Every buffer remains owned by the caller. Decoded hyperlink
    /// strings borrow from `buffers.hyperlink_strings`.
    pub fn decode(
        header: Header,
        reader: *std.Io.Reader,
        buffers: Buffers,
    ) DecodeError!Payload {
        if (buffers.styles.len != header.style_count) {
            return error.StyleCountMismatch;
        }
        if (buffers.hyperlinks.len != header.hyperlink_count) {
            return error.HyperlinkCountMismatch;
        }
        for (buffers.styles) |*entry| {
            entry.* = try style.decode(reader);
            if (entry.default()) return error.DefaultStyle;
        }

        var string_offset: usize = 0;
        for (buffers.hyperlinks) |*entry| {
            const decoded = try hyperlink.decode(
                reader,
                buffers.hyperlink_strings[string_offset..],
            );
            entry.* = decoded.value;
            string_offset += decoded.string_bytes;
        }

        return .{
            .header = header,
            .styles = buffers.styles,
            .hyperlinks = buffers.hyperlinks,
        };
    }
};

fn pageHyperlink(
    page: *const terminal_page.Page,
    entry: *const terminal_hyperlink.PageEntry,
) terminal_hyperlink.Hyperlink {
    return .{
        .id = switch (entry.id) {
            .implicit => |value| .{ .implicit = value },
            .explicit => |value| .{ .explicit = value.slice(page.memory) },
        },
        .uri = entry.uri.slice(page.memory),
    };
}

test "golden encoding" {
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

    try std.testing.expectEqualStrings(
        "\x02\x01\x04\x03\x06\x05\x08\x07" ++
            "\x0a\x09\x0c\x0b\x10\x0f\x0e\x0d" ++
            "\x14\x13\x12\x11",
        writer.buffered(),
    );
}

test "decode with a one-byte reader buffer" {
    const fixture =
        "\x02\x01\x04\x03\x06\x05\x08\x07" ++
        "\x0a\x09\x0c\x0b\x10\x0f\x0e\x0d" ++
        "\x14\x13\x12\x11";
    var source: std.Io.Reader = .fixed(fixture);
    var buf: [1]u8 = undefined;
    var limited = source.limited(.unlimited, &buf);

    try std.testing.expectEqual(
        Header{
            .columns = 0x0102,
            .rows = 0x0304,
            .style_count = 0x0506,
            .hyperlink_count = 0x0708,
            .style_capacity = 0x090a,
            .hyperlink_capacity_bytes = 0x0b0c,
            .grapheme_capacity_bytes = 0x0d0e0f10,
            .string_capacity_bytes = 0x11121314,
        },
        try Header.decode(&limited.interface),
    );
}

test "reject every truncation" {
    const fixture =
        "\x02\x01\x04\x03\x06\x05\x08\x07" ++
        "\x0a\x09\x0c\x0b\x10\x0f\x0e\x0d" ++
        "\x14\x13\x12\x11";
    for (0..Header.len) |len| {
        var reader: std.Io.Reader = .fixed(fixture[0..len]);
        try std.testing.expectError(error.EndOfStream, Header.decode(&reader));
    }
}

test "encode native page lookup tables" {
    const capacity: terminal_page.Capacity = .{
        .cols = 3,
        .rows = 2,
        .styles = 8,
        .hyperlink_bytes = 512,
        .grapheme_bytes = 128,
        .string_bytes = 256,
    };
    var page = try terminal_page.Page.init(capacity);
    defer page.deinit();

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

    const grapheme = page.getRowAndCell(0, 1);
    grapheme.cell.* = .init('x');
    try page.setGraphemes(
        grapheme.row,
        grapheme.cell,
        &.{ 0x0301, 0x0302 },
    );

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

    var counter: std.Io.Writer.Discarding = .init(&.{});
    try encode(&page, &counter.writer);

    var encoded: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try encode(&page, &writer);

    const fixture =
        "\x03\x00\x02\x00\x02\x00\x02\x00" ++
        "\x08\x00\x00\x02\x80\x00\x00\x00" ++
        "\x00\x01\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00\x01\x00\x00\x00" ++
        "\x00\x00\x00\x00\x01\x2a\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "\x02\x01\x00\x00\x00a\x05\x00\x00\x00alpha" ++
        "\x01\x04\x03\x02\x01\x04\x00\x00\x00beta";
    try std.testing.expectEqualStrings(fixture, writer.buffered());
    try std.testing.expectEqual(@as(u64, fixture.len), counter.count);
}

test "payload prefix encodes and decodes lookup tables" {
    const styles = [_]terminal_style.Style{
        .{
            .fg_color = .{ .palette = 42 },
            .flags = .{ .bold = true },
        },
        .{
            .bg_color = .{ .rgb = .{
                .r = 0xaa,
                .g = 0xbb,
                .b = 0xcc,
            } },
            .flags = .{ .underline = .double },
        },
    };
    const hyperlinks = [_]terminal_hyperlink.Hyperlink{
        .{
            .id = .{ .implicit = 0x01020304 },
            .uri = "uri",
        },
        .{
            .id = .{ .explicit = "id" },
            .uri = "url",
        },
    };
    const header: Header = .{
        .columns = 80,
        .rows = 24,
        .style_count = styles.len,
        .hyperlink_count = hyperlinks.len,
        .style_capacity = 16,
        .hyperlink_capacity_bytes = 512,
        .grapheme_capacity_bytes = 128,
        .string_capacity_bytes = 256,
    };
    const payload: Payload = .{
        .header = header,
        .styles = &styles,
        .hyperlinks = &hyperlinks,
    };

    const encoded_len = comptime len: {
        break :len Header.len +
            styles.len * style.len +
            (hyperlink.encodedLen(hyperlinks[0]) catch unreachable) +
            (hyperlink.encodedLen(hyperlinks[1]) catch unreachable);
    };
    var encoded: [encoded_len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try payload.encode(&writer);

    const fixture =
        "\x50\x00\x18\x00\x02\x00\x02\x00" ++
        "\x10\x00\x00\x02\x80\x00\x00\x00" ++
        "\x00\x01\x00\x00" ++
        "\x01\x2a\x00\x00\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00\x01\x00\x00\x00" ++
        "\x00\x00\x00\x00\x02\xaa\xbb\xcc" ++
        "\x00\x00\x00\x00\x00\x02\x00\x00" ++
        "\x01\x04\x03\x02\x01\x03\x00\x00\x00uri" ++
        "\x02\x02\x00\x00\x00id\x03\x00\x00\x00url";
    try std.testing.expectEqualStrings(fixture, writer.buffered());

    var source: std.Io.Reader = .fixed(writer.buffered());
    var read_buf: [1]u8 = undefined;
    var limited = source.limited(.unlimited, &read_buf);
    const decoded_header = try Header.decode(&limited.interface);
    var decoded_styles: [styles.len]terminal_style.Style = undefined;
    var decoded_hyperlinks: [hyperlinks.len]terminal_hyperlink.Hyperlink =
        undefined;
    var decoded_hyperlink_strings: [8]u8 = undefined;
    const decoded = try Payload.decode(
        decoded_header,
        &limited.interface,
        .{
            .styles = &decoded_styles,
            .hyperlinks = &decoded_hyperlinks,
            .hyperlink_strings = &decoded_hyperlink_strings,
        },
    );

    try std.testing.expectEqual(header, decoded.header);
    for (styles, decoded.styles) |expected, actual| {
        try std.testing.expect(expected.eql(actual));
    }
    try std.testing.expectEqual(
        hyperlinks[0].id.implicit,
        decoded.hyperlinks[0].id.implicit,
    );
    try std.testing.expectEqualStrings(
        hyperlinks[0].uri,
        decoded.hyperlinks[0].uri,
    );
    try std.testing.expectEqualStrings(
        hyperlinks[1].id.explicit,
        decoded.hyperlinks[1].id.explicit,
    );
    try std.testing.expectEqualStrings(
        hyperlinks[1].uri,
        decoded.hyperlinks[1].uri,
    );
}

test "payload prefix validates its style table" {
    const non_default = [_]terminal_style.Style{
        .{ .flags = .{ .bold = true } },
    };
    const header: Header = .{
        .columns = 80,
        .rows = 24,
        .style_count = 2,
        .hyperlink_count = 0,
        .style_capacity = 0,
        .hyperlink_capacity_bytes = 0,
        .grapheme_capacity_bytes = 0,
        .string_capacity_bytes = 0,
    };

    var encoded: [Header.len + style.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try std.testing.expectError(
        error.StyleCountMismatch,
        (Payload{
            .header = header,
            .styles = &non_default,
            .hyperlinks = &.{},
        }).encode(&writer),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.end);

    var reader: std.Io.Reader = .fixed(&.{});
    var decoded_styles: [1]terminal_style.Style = undefined;
    var decoded_hyperlinks: [0]terminal_hyperlink.Hyperlink = .{};
    var decoded_hyperlink_strings: [0]u8 = .{};
    try std.testing.expectError(
        error.StyleCountMismatch,
        Payload.decode(header, &reader, .{
            .styles = &decoded_styles,
            .hyperlinks = &decoded_hyperlinks,
            .hyperlink_strings = &decoded_hyperlink_strings,
        }),
    );

    const default_styles = [_]terminal_style.Style{.{}};
    const default_header: Header = .{
        .columns = 80,
        .rows = 24,
        .style_count = 1,
        .hyperlink_count = 0,
        .style_capacity = 0,
        .hyperlink_capacity_bytes = 0,
        .grapheme_capacity_bytes = 0,
        .string_capacity_bytes = 0,
    };
    try std.testing.expectError(
        error.DefaultStyle,
        (Payload{
            .header = default_header,
            .styles = &default_styles,
            .hyperlinks = &.{},
        }).encode(&writer),
    );

    var default_fixture: [style.len]u8 = @splat(0);
    var default_reader: std.Io.Reader = .fixed(&default_fixture);
    var decoded_default: [1]terminal_style.Style = undefined;
    try std.testing.expectError(
        error.DefaultStyle,
        Payload.decode(default_header, &default_reader, .{
            .styles = &decoded_default,
            .hyperlinks = &decoded_hyperlinks,
            .hyperlink_strings = &decoded_hyperlink_strings,
        }),
    );
}

test "payload prefix validates its hyperlink table" {
    const hyperlinks = [_]terminal_hyperlink.Hyperlink{.{
        .id = .{ .implicit = 42 },
        .uri = "uri",
    }};
    const header: Header = .{
        .columns = 80,
        .rows = 24,
        .style_count = 0,
        .hyperlink_count = 2,
        .style_capacity = 0,
        .hyperlink_capacity_bytes = 0,
        .grapheme_capacity_bytes = 0,
        .string_capacity_bytes = 0,
    };

    var encoded: [Header.len + 12]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try std.testing.expectError(
        error.HyperlinkCountMismatch,
        (Payload{
            .header = header,
            .styles = &.{},
            .hyperlinks = &hyperlinks,
        }).encode(&writer),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.end);

    var empty_reader: std.Io.Reader = .fixed(&.{});
    var decoded_styles: [0]terminal_style.Style = .{};
    var decoded_hyperlinks: [1]terminal_hyperlink.Hyperlink = undefined;
    var decoded_strings: [3]u8 = undefined;
    try std.testing.expectError(
        error.HyperlinkCountMismatch,
        Payload.decode(header, &empty_reader, .{
            .styles = &decoded_styles,
            .hyperlinks = &decoded_hyperlinks,
            .hyperlink_strings = &decoded_strings,
        }),
    );
}
