//! Terminal state synchronization API.
//!
//! Provides compact binary encoding of terminal state for network transmission.
//! Designed for use by both the VT attach client (converts to VT sequences)
//! and a future native Ghostty remote client (applies directly to pages).
//!
//! Encoding principles:
//! - Varint for most integers (small values = 1 byte)
//! - Style-tagged UTF-8 runs for row content (ASCII = 1 byte/char)
//! - Session-level style dictionary (styles deduped, referenced by varint ID)
//! - Blank rows encoded as a single flag byte

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const style_mod = @import("style.zig");
const Style = style_mod.Style;
const color = @import("color.zig");
const pagepkg = @import("page.zig");
const Cell = pagepkg.Cell;
const Row = pagepkg.Row;
const size = @import("size.zig");
const Screen = @import("Screen.zig");
const PageList = @import("PageList.zig");

// ─── Varint encoding ──────────────────────────────────────────────────────────

/// Write a varint (LEB128 unsigned).
pub fn writeVarint(writer: anytype, value: u64) !void {
    var v = value;
    while (v >= 0x80) {
        try writer.writeByte(@truncate((v & 0x7F) | 0x80));
        v >>= 7;
    }
    try writer.writeByte(@truncate(v & 0x7F));
}

/// Read a varint.
pub fn readVarint(reader: anytype) !u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        const byte = try reader.readByte();
        result |= @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) return result;
        shift += 7;
        if (shift >= 64) return error.Overflow;
    }
}

// ─── Color encoding ───────────────────────────────────────────────────────────

/// Encode a Style.Color compactly: tag(1 byte) + value(0-3 bytes).
pub fn writeColor(writer: anytype, c: Style.Color) !void {
    switch (c) {
        .none => try writer.writeByte(0),
        .palette => |p| {
            try writer.writeByte(1);
            try writer.writeByte(p);
        },
        .rgb => |rgb| {
            try writer.writeByte(2);
            try writer.writeByte(rgb.r);
            try writer.writeByte(rgb.g);
            try writer.writeByte(rgb.b);
        },
    }
}

pub fn readColor(reader: anytype) !Style.Color {
    const tag = try reader.readByte();
    return switch (tag) {
        0 => .none,
        1 => .{ .palette = try reader.readByte() },
        2 => .{ .rgb = .{
            .r = try reader.readByte(),
            .g = try reader.readByte(),
            .b = try reader.readByte(),
        } },
        else => error.InvalidData,
    };
}

// ─── Style Dictionary ─────────────────────────────────────────────────────────

/// Session-level style dictionary. Maps terminal styles to compact varint IDs.
/// Style 0 is always the default style (no attributes, no colors).
pub const StyleDict = struct {
    /// Style → ID mapping. Uses a simple array since we expect <100 styles.
    entries: std.ArrayList(Style),

    pub fn init(alloc: Allocator) StyleDict {
        var entries: std.ArrayList(Style) = .init(alloc);
        // ID 0 = default style
        entries.append(.{}) catch {};
        return .{ .entries = entries };
    }

    pub fn deinit(self: *StyleDict) void {
        self.entries.deinit();
    }

    /// Get or create an ID for a style. Returns the ID and whether it's new.
    pub fn intern(self: *StyleDict, s: Style) !struct { id: u16, is_new: bool } {
        // Check existing entries
        for (self.entries.items, 0..) |existing, i| {
            if (existing.eql(s)) return .{ .id = @intCast(i), .is_new = false };
        }
        // New style
        const id: u16 = @intCast(self.entries.items.len);
        try self.entries.append(s);
        return .{ .id = id, .is_new = true };
    }

    /// Encode a style definition for transmission.
    pub fn writeStyleDef(writer: anytype, id: u16, s: Style) !void {
        try writeVarint(writer, id);
        try writeColor(writer, s.fg_color);
        try writeColor(writer, s.bg_color);
        try writeColor(writer, s.underline_color);
        const flags_int: u16 = @bitCast(s.flags);
        try writer.writeInt(u16, flags_int, .big);
    }

    /// Decode a style definition.
    pub fn readStyleDef(reader: anytype) !struct { id: u16, style: Style } {
        const id: u16 = @intCast(try readVarint(reader));
        return .{
            .id = id,
            .style = .{
                .fg_color = try readColor(reader),
                .bg_color = try readColor(reader),
                .underline_color = try readColor(reader),
                .flags = @bitCast(try reader.readInt(u16, .big)),
            },
        };
    }
};

// ─── Row encoding ─────────────────────────────────────────────────────────────

/// Row flags packed into a single byte.
pub const RowFlags = packed struct(u8) {
    wrap: bool = false,
    wrap_continuation: bool = false,
    is_blank: bool = false, // If true, no runs follow — row is all default-styled spaces
    _padding: u5 = 0,
};

/// Encode a viewport row as style-tagged UTF-8 runs.
///
/// Format:
///   row_index: u16 (big-endian)
///   flags: RowFlags (1 byte)
///   if !is_blank:
///     run_count: varint
///     runs: [run_count]Run
///
/// Run:
///   style_id: varint
///   byte_count: varint
///   text: [byte_count]u8 (UTF-8)
///   (wide chars have their codepoint followed by 0xFF marker for the spacer)
pub fn encodeRow(
    writer: anytype,
    screen: *Screen,
    row_idx: size.CellCountInt,
    style_dict: *StyleDict,
    new_styles: ?*std.ArrayList(u8),
) !void {
    // Write row index
    try writer.writeInt(u16, row_idx, .big);

    // Get row data
    const pin = screen.pages.pin(.{ .active = .{ .x = 0, .y = row_idx } }) orelse {
        // No such row — write blank
        try writer.writeByte(@bitCast(RowFlags{ .is_blank = true }));
        return;
    };
    const page_row = pin.rowAndCell().row;
    const cells = pin.cells(.all);
    const cols = screen.pages.cols;

    // Check if row is blank (all default-styled spaces/empty)
    const is_blank = blk: {
        if (page_row.styled) break :blk false;
        for (cells[0..cols]) |cell| {
            if (cell.content_tag != .codepoint) break :blk false;
            if (cell.content.codepoint != 0 and cell.content.codepoint != ' ') break :blk false;
        }
        break :blk true;
    };

    const flags = RowFlags{
        .wrap = page_row.wrap,
        .wrap_continuation = page_row.wrap_continuation,
        .is_blank = is_blank,
    };
    try writer.writeByte(@bitCast(flags));

    if (is_blank) return;

    // Build runs: consecutive cells with the same style
    var runs = std.ArrayList(u8).init(std.heap.c_allocator);
    defer runs.deinit();
    var run_count: u32 = 0;

    var current_style_id: u16 = 0;
    var run_start: usize = 0;
    var col: usize = 0;

    while (col < cols) {
        const cell = cells[col];

        // Skip spacer tails (part of wide chars, handled by the wide char itself)
        if (cell.wide == .spacer_tail) {
            col += 1;
            continue;
        }

        // Get this cell's style ID
        const cell_style = if (cell.style_id != 0)
            pin.node.data.styles.get(pin.node.data.memory, cell.style_id)
        else
            Style{};

        const intern_result = try style_dict.intern(cell_style);
        const style_id = intern_result.id;

        // If this is a new style, record its definition
        if (intern_result.is_new and new_styles != null) {
            var style_writer: std.ArrayList(u8).Writer = new_styles.?.writer();
            try StyleDict.writeStyleDef(&style_writer, style_id, cell_style);
        }

        // Start new run if style changed or this is the first cell
        if (col == 0 or style_id != current_style_id) {
            if (col > 0) {
                // Finish previous run: write to runs buffer
                run_count += 1;
            }
            current_style_id = style_id;
            run_start = col;
        }

        col += 1;
    }
    // The last run
    if (cols > 0) run_count += 1;

    // Now actually encode the runs
    // Re-walk the cells and write runs directly
    try writeVarint(writer, run_count);

    var prev_style: u16 = 0xFFFF; // impossible value to force first run
    var run_buf = std.ArrayList(u8).init(std.heap.c_allocator);
    defer run_buf.deinit();

    col = 0;
    while (col < cols) {
        const cell = cells[col];

        if (cell.wide == .spacer_tail) {
            col += 1;
            continue;
        }

        const cell_style = if (cell.style_id != 0)
            pin.node.data.styles.get(pin.node.data.memory, cell.style_id)
        else
            Style{};

        const style_id = (try style_dict.intern(cell_style)).id;

        if (style_id != prev_style) {
            // Flush previous run
            if (prev_style != 0xFFFF) {
                try writeVarint(writer, prev_style);
                try writeVarint(writer, run_buf.items.len);
                try writer.writeAll(run_buf.items);
                run_buf.clearRetainingCapacity();
            }
            prev_style = style_id;
        }

        // Encode cell content as UTF-8
        const cp: u21 = switch (cell.content_tag) {
            .codepoint, .codepoint_grapheme => cell.content.codepoint,
            else => ' ',
        };

        if (cp == 0) {
            // Empty cell → space
            try run_buf.append(' ');
        } else if (cp < 0x80) {
            try run_buf.append(@truncate(cp));
        } else {
            // UTF-8 encode
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &utf8_buf) catch 1;
            try run_buf.appendSlice(utf8_buf[0..len]);
        }

        // Wide char marker
        if (cell.wide == .wide) {
            try run_buf.append(0xFF);
        }

        col += 1;
    }

    // Flush last run
    if (prev_style != 0xFFFF) {
        try writeVarint(writer, prev_style);
        try writeVarint(writer, run_buf.items.len);
        try writer.writeAll(run_buf.items);
    }
}

// ─── Row hashing ──────────────────────────────────────────────────────────────

/// Hash a viewport row's content for quick dirty detection.
pub fn hashRow(screen: *Screen, row_idx: size.CellCountInt) u64 {
    const pin = screen.pages.pin(.{ .active = .{ .x = 0, .y = row_idx } }) orelse return 0;
    const page_row = pin.rowAndCell().row;
    const cells = pin.cells(.all);
    const cols = screen.pages.cols;

    // Hash the raw cell bytes (each cell is 8 bytes packed)
    const cell_bytes = std.mem.sliceAsBytes(cells[0..cols]);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(cell_bytes);
    // Include row flags in hash
    const row_bytes: [8]u8 = @bitCast(page_row.*);
    hasher.update(&row_bytes);
    return hasher.final();
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "varint round-trip" {
    const values = [_]u64{ 0, 1, 127, 128, 255, 300, 16383, 16384, 1000000 };
    for (values) |v| {
        var buf: [16]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try writeVarint(fbs.writer(), v);
        fbs.pos = 0;
        const decoded = try readVarint(fbs.reader());
        try testing.expectEqual(v, decoded);
    }
}

test "varint size" {
    // Values 0-127 should encode as 1 byte
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeVarint(fbs.writer(), 42);
    try testing.expectEqual(@as(usize, 1), fbs.pos);
}

test "color round-trip" {
    const colors = [_]Style.Color{
        .none,
        .{ .palette = 196 },
        .{ .rgb = .{ .r = 0x12, .g = 0x34, .b = 0x56 } },
    };
    for (colors) |c| {
        var buf: [16]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try writeColor(fbs.writer(), c);
        fbs.pos = 0;
        const decoded = try readColor(fbs.reader());
        try testing.expect(c.eql(decoded));
    }
}

test "StyleDict intern" {
    var dict = StyleDict.init(testing.allocator);
    defer dict.deinit();

    // Default style is always ID 0
    const r0 = try dict.intern(.{});
    try testing.expectEqual(@as(u16, 0), r0.id);
    try testing.expect(!r0.is_new);

    // New style gets ID 1
    const bold: Style = .{ .flags = .{ .bold = true } };
    const r1 = try dict.intern(bold);
    try testing.expectEqual(@as(u16, 1), r1.id);
    try testing.expect(r1.is_new);

    // Same style again — same ID, not new
    const r1b = try dict.intern(bold);
    try testing.expectEqual(@as(u16, 1), r1b.id);
    try testing.expect(!r1b.is_new);

    // Different style — new ID
    const red_fg: Style = .{ .fg_color = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } };
    const r2 = try dict.intern(red_fg);
    try testing.expectEqual(@as(u16, 2), r2.id);
    try testing.expect(r2.is_new);
}

test "StyleDef round-trip" {
    const s: Style = .{
        .fg_color = .{ .palette = 196 },
        .bg_color = .{ .rgb = .{ .r = 0x10, .g = 0x20, .b = 0x30 } },
        .flags = .{ .bold = true, .italic = true },
    };

    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try StyleDict.writeStyleDef(fbs.writer(), 42, s);
    fbs.pos = 0;
    const result = try StyleDict.readStyleDef(fbs.reader());
    try testing.expectEqual(@as(u16, 42), result.id);
    try testing.expect(s.eql(result.style));
}

test "row hashing consistency" {
    const alloc = testing.allocator;
    const Terminal = @import("Terminal.zig");

    var t = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("hello world");

    const h1 = hashRow(t.screens.active, 0);
    const h2 = hashRow(t.screens.active, 0);
    try testing.expectEqual(h1, h2);

    // Different row should have different hash
    const h_empty = hashRow(t.screens.active, 1);
    try testing.expect(h1 != h_empty);
}
