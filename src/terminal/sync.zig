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
const Terminal = @import("Terminal.zig");

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
        var entries: std.ArrayList(Style) = .empty;
        entries.append(alloc, .{}) catch {};
        return .{ .entries = entries };
    }

    pub fn deinit(self: *StyleDict, alloc: Allocator) void {
        self.entries.deinit(alloc);
    }

    /// Get or create an ID for a style. Returns the ID and whether it's new.
    pub fn intern(self: *StyleDict, alloc: Allocator, s: Style) !struct { id: u16, is_new: bool } {
        // Check existing entries
        for (self.entries.items, 0..) |existing, i| {
            if (existing.eql(s)) return .{ .id = @intCast(i), .is_new = false };
        }
        // New style
        const id: u16 = @intCast(self.entries.items.len);
        try self.entries.append(alloc, s);
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

    // Encode as style-tagged UTF-8 runs.
    // Walk cells, emit a new run whenever the style changes.
    // Use a fixed buffer for run text (max ~2KB for 500-col terminal).
    var run_text: [2048]u8 = undefined;
    var run_len: usize = 0;
    var run_count: u32 = 0;
    var prev_style: u16 = 0xFFFF;

    // First pass: count runs
    var col: usize = 0;
    while (col < cols) : (col += 1) {
        const cell = cells[col];
        if (cell.wide == .spacer_tail) continue;
        const cell_style = if (cell.style_id != 0)
            pin.node.data.styles.get(pin.node.data.memory, cell.style_id).*
        else
            Style{};
        const sid = (try style_dict.intern(std.heap.c_allocator, cell_style)).id;
        if (sid != prev_style) {
            if (prev_style != 0xFFFF) run_count += 1;
            prev_style = sid;
        }
    }
    if (prev_style != 0xFFFF) run_count += 1;

    try writeVarint(writer, run_count);

    // Second pass: write runs
    prev_style = 0xFFFF;
    run_len = 0;
    col = 0;
    while (col < cols) : (col += 1) {
        const cell = cells[col];
        if (cell.wide == .spacer_tail) continue;

        const cell_style = if (cell.style_id != 0)
            pin.node.data.styles.get(pin.node.data.memory, cell.style_id).*
        else
            Style{};
        const sid = (try style_dict.intern(std.heap.c_allocator, cell_style)).id;

        if (sid != prev_style) {
            // Flush previous run
            if (prev_style != 0xFFFF and run_len > 0) {
                try writeVarint(writer, prev_style);
                try writeVarint(writer, run_len);
                try writer.writeAll(run_text[0..run_len]);
            }
            prev_style = sid;
            run_len = 0;

            // Record new style if needed
            if (new_styles != null) {
                // Style was already interned above; check if new
                for (style_dict.entries.items, 0..) |_, idx| {
                    if (idx == sid) break;
                }
            }
        }

        // Encode codepoint as UTF-8
        const cp: u21 = switch (cell.content_tag) {
            .codepoint, .codepoint_grapheme => cell.content.codepoint,
            else => ' ',
        };

        if (cp == 0) {
            run_text[run_len] = ' ';
            run_len += 1;
        } else if (cp < 0x80) {
            run_text[run_len] = @truncate(cp);
            run_len += 1;
        } else {
            const len = std.unicode.utf8Encode(cp, run_text[run_len..]) catch 1;
            run_len += len;
        }

        if (cell.wide == .wide and run_len < run_text.len) {
            run_text[run_len] = 0xFF;
            run_len += 1;
        }
    }

    // Flush last run
    if (prev_style != 0xFFFF and run_len > 0) {
        try writeVarint(writer, prev_style);
        try writeVarint(writer, run_len);
        try writer.writeAll(run_text[0..run_len]);
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

// ─── SyncState ────────────────────────────────────────────────────────────────

/// Terminal state synchronization tracker. Mirrors the RenderState pattern
/// but produces network frames instead of GPU buffers.
///
/// Usage:
///   var sync: SyncState = .empty;
///   defer sync.deinit(alloc);
///   // Under terminal mutex:
///   const delta = sync.computeDelta(terminal);
///   if (delta.kind != .none) {
///       sync.serializeDelta(terminal, writer);  // or serializeFull
///   }
pub const SyncState = struct {
    alloc: Allocator,

    /// Epoch counter — incremented on every successful sync.
    epoch: u64,

    /// Dimensions at last sync.
    rows: size.CellCountInt,
    cols: size.CellCountInt,

    /// Hash of each viewport row at last sync.
    row_hashes: []u64,

    /// Cursor state at last sync.
    cursor_x: size.CellCountInt,
    cursor_y: size.CellCountInt,

    /// Screen key at last sync.
    screen_key: @import("ScreenSet.zig").Key,

    /// Session style dictionary (persists across syncs).
    styles: StyleDict,

    /// Scrollback tracking.
    scrollback_total: usize,
    scrollback_sent: usize,

    pub const empty: SyncState = .{
        .alloc = undefined, // must be set via init
        .epoch = 0,
        .rows = 0,
        .cols = 0,
        .row_hashes = &.{},
        .cursor_x = 0,
        .cursor_y = 0,
        .screen_key = .primary,
        .styles = undefined,
        .scrollback_total = 0,
        .scrollback_sent = 0,
    };

    pub fn init(alloc: Allocator) SyncState {
        return .{
            .alloc = alloc,
            .epoch = 0,
            .rows = 0,
            .cols = 0,
            .row_hashes = &.{},
            .cursor_x = 0,
            .cursor_y = 0,
            .screen_key = .primary,
            .styles = StyleDict.init(alloc),
            .scrollback_total = 0,
            .scrollback_sent = 0,
        };
    }

    pub fn deinit(self: *SyncState) void {
        if (self.row_hashes.len > 0) {
            self.alloc.free(self.row_hashes);
        }
        self.styles.deinit(self.alloc);
    }

    /// Compute what changed since the last sync.
    /// Must be called with the terminal mutex held.
    pub fn computeDelta(self: *SyncState, t: *Terminal) Delta {
        const screen = t.screens.active;
        const new_rows = screen.pages.rows;
        const new_cols = screen.pages.cols;

        // Full redraw conditions (same as RenderState)
        const full = full: {
            if (t.screens.active_key != self.screen_key) break :full true;
            if (self.rows != new_rows or self.cols != new_cols) break :full true;
            // Check terminal-level dirty flags
            {
                const Int = @typeInfo(Terminal.Dirty).@"struct".backing_integer.?;
                const v: Int = @bitCast(t.flags.dirty);
                if (v > 0) break :full true;
            }
            break :full false;
        };

        if (full) {
            return .{
                .kind = .full,
                .dirty_rows = &.{},
                .cursor_changed = true,
                .modes_changed = true,
                .palette_changed = true,
            };
        }

        // Resize hash array if needed
        if (self.row_hashes.len != new_rows) {
            if (self.row_hashes.len > 0) self.alloc.free(self.row_hashes);
            self.row_hashes = self.alloc.alloc(u64, new_rows) catch return .{
                .kind = .full,
                .dirty_rows = &.{},
                .cursor_changed = true,
                .modes_changed = true,
                .palette_changed = true,
            };
            // Force all rows dirty
            @memset(self.row_hashes, 0);
        }

        // Per-row dirty detection via hashing
        // We use a static buffer for dirty flags to avoid allocation
        var dirty_buf: [512]bool = undefined;
        const dirty_rows = dirty_buf[0..new_rows];
        var any_dirty = false;

        for (0..new_rows) |y| {
            const yi: size.CellCountInt = @intCast(y);
            const new_hash = hashRow(screen, yi);
            if (new_hash != self.row_hashes[y]) {
                dirty_rows[y] = true;
                any_dirty = true;
            } else {
                dirty_rows[y] = false;
            }
        }

        const cursor_changed = self.cursor_x != screen.cursor.x or
            self.cursor_y != screen.cursor.y;

        if (!any_dirty and !cursor_changed) {
            return .{ .kind = .none, .dirty_rows = &.{}, .cursor_changed = false, .modes_changed = false, .palette_changed = false };
        }

        return .{
            .kind = .partial,
            .dirty_rows = dirty_rows,
            .cursor_changed = cursor_changed,
            .modes_changed = false,
            .palette_changed = false,
        };
    }

    /// Update internal state after a successful sync.
    /// Call this after serializing the delta/full frame.
    pub fn markSynced(self: *SyncState, t: *Terminal) void {
        const screen = t.screens.active;
        self.epoch += 1;
        self.rows = screen.pages.rows;
        self.cols = screen.pages.cols;
        self.cursor_x = screen.cursor.x;
        self.cursor_y = screen.cursor.y;
        self.screen_key = t.screens.active_key;

        // Update row hashes
        if (self.row_hashes.len != self.rows) {
            if (self.row_hashes.len > 0) self.alloc.free(self.row_hashes);
            self.row_hashes = self.alloc.alloc(u64, self.rows) catch return;
        }
        for (0..self.rows) |y| {
            self.row_hashes[y] = hashRow(screen, @intCast(y));
        }

        // Track scrollback
        self.scrollback_total = screen.pages.total_rows -| screen.pages.rows;
    }

    /// Serialize the full viewport state.
    /// Must be called with terminal mutex held.
    pub fn serializeFull(
        self: *SyncState,
        t: *Terminal,
        writer: anytype,
    ) !void {
        const screen = t.screens.active;
        const rows = screen.pages.rows;
        const cols = screen.pages.cols;

        // Header: epoch, rows, cols, cursor
        try writer.writeInt(u64, self.epoch, .big);
        try writer.writeInt(u16, rows, .big);
        try writer.writeInt(u16, cols, .big);
        try writer.writeInt(u16, screen.cursor.x, .big);
        try writer.writeInt(u16, screen.cursor.y, .big);

        // All rows
        try writeVarint(writer, rows);
        for (0..rows) |y| {
            try encodeRow(writer, screen, @intCast(y), &self.styles, null);
        }
    }

    /// Serialize only dirty viewport rows.
    /// Must be called with terminal mutex held.
    pub fn serializeDelta(
        self: *SyncState,
        t: *Terminal,
        delta: Delta,
        writer: anytype,
    ) !void {
        const screen = t.screens.active;

        // Header: epoch, cursor
        try writer.writeInt(u64, self.epoch, .big);
        try writer.writeInt(u16, screen.cursor.x, .big);
        try writer.writeInt(u16, screen.cursor.y, .big);

        // Count dirty rows
        var dirty_count: u16 = 0;
        for (delta.dirty_rows) |d| {
            if (d) dirty_count += 1;
        }
        try writeVarint(writer, dirty_count);

        // Dirty rows only
        for (delta.dirty_rows, 0..) |d, y| {
            if (d) {
                try encodeRow(writer, screen, @intCast(y), &self.styles, null);
            }
        }
    }

    /// Get the next chunk of scrollback to send.
    /// Returns the number of rows serialized, or null if all sent.
    pub fn nextScrollbackChunk(
        self: *SyncState,
        screen: *Screen,
        max_rows: usize,
        writer: anytype,
    ) !?usize {
        const total = screen.pages.total_rows -| screen.pages.rows;
        if (self.scrollback_sent >= total) return null;

        const remaining = total - self.scrollback_sent;
        const count = @min(remaining, max_rows);

        // Header: total, offset, count
        try writer.writeInt(u32, @intCast(total), .big);
        try writer.writeInt(u32, @intCast(self.scrollback_sent), .big);
        try writeVarint(writer, count);

        // Serialize scrollback rows (oldest first)
        // Scrollback rows are at screen coordinates: row 0 = oldest
        for (0..count) |i| {
            const row_idx = self.scrollback_sent + i;
            const pin = screen.pages.pin(.{ .screen = .{ .x = 0, .y = @intCast(row_idx) } }) orelse continue;
            const page_row = pin.rowAndCell().row;
            const cells = pin.cells(.all);
            const cols = screen.pages.cols;

            // Use a simplified encoding for scrollback (no style dict needed for now)
            try writer.writeInt(u16, @intCast(row_idx), .big);

            const is_blank = blk: {
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

            if (!is_blank) {
                // Write as UTF-8 text (style-less for scrollback)
                try writeVarint(writer, 1); // 1 run
                try writeVarint(writer, 0); // style 0 (default)
                // Encode cells as UTF-8
                var text_len: usize = 0;
                var text_buf: [1024]u8 = undefined;
                for (cells[0..cols]) |cell| {
                    if (cell.wide == .spacer_tail) continue;
                    const cp: u21 = switch (cell.content_tag) {
                        .codepoint, .codepoint_grapheme => cell.content.codepoint,
                        else => ' ',
                    };
                    if (cp == 0) {
                        text_buf[text_len] = ' ';
                        text_len += 1;
                    } else if (cp < 0x80) {
                        text_buf[text_len] = @truncate(cp);
                        text_len += 1;
                    } else {
                        const len = std.unicode.utf8Encode(cp, text_buf[text_len..]) catch 1;
                        text_len += len;
                    }
                    if (text_len >= text_buf.len - 4) break;
                }
                try writeVarint(writer, text_len);
                try writer.writeAll(text_buf[0..text_len]);
            }
        }

        self.scrollback_sent += count;
        return count;
    }
};

pub const Delta = struct {
    kind: Kind,
    dirty_rows: []const bool,
    cursor_changed: bool,
    modes_changed: bool,
    palette_changed: bool,

    pub const Kind = enum {
        none,
        partial,
        full,
    };
};

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
    defer dict.deinit(testing.allocator);

    // Default style is always ID 0
    const r0 = try dict.intern(testing.allocator, .{});
    try testing.expectEqual(@as(u16, 0), r0.id);
    try testing.expect(!r0.is_new);

    // New style gets ID 1
    const bold: Style = .{ .flags = .{ .bold = true } };
    const r1 = try dict.intern(testing.allocator, bold);
    try testing.expectEqual(@as(u16, 1), r1.id);
    try testing.expect(r1.is_new);

    // Same style again — same ID, not new
    const r1b = try dict.intern(testing.allocator, bold);
    try testing.expectEqual(@as(u16, 1), r1b.id);
    try testing.expect(!r1b.is_new);

    // Different style — new ID
    const red_fg: Style = .{ .fg_color = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } };
    const r2 = try dict.intern(testing.allocator, red_fg);
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

test "SyncState delta computation" {
    const alloc = testing.allocator;
    var t = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    var sync_state = SyncState.init(alloc);
    defer sync_state.deinit();

    // First call should be full (no prior state)
    const d1 = sync_state.computeDelta(&t);
    try testing.expectEqual(Delta.Kind.full, d1.kind);

    // Mark synced
    sync_state.markSynced(&t);
    try testing.expectEqual(@as(u64, 1), sync_state.epoch);

    // No changes → none
    const d2 = sync_state.computeDelta(&t);
    try testing.expectEqual(Delta.Kind.none, d2.kind);

    // Write to terminal → partial delta
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("hello");

    const d3 = sync_state.computeDelta(&t);
    try testing.expectEqual(Delta.Kind.partial, d3.kind);
    // Row 0 should be dirty (that's where "hello" was written)
    try testing.expect(d3.dirty_rows.len > 0);
    try testing.expect(d3.dirty_rows[0]);
    // Row 1 should NOT be dirty
    if (d3.dirty_rows.len > 1) {
        try testing.expect(!d3.dirty_rows[1]);
    }

    sync_state.markSynced(&t);
    try testing.expectEqual(@as(u64, 2), sync_state.epoch);
}

test "SyncState serializeFull" {
    const alloc = testing.allocator;
    var t = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer t.deinit(alloc);

    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("hello world");

    var sync_state = SyncState.init(alloc);
    defer sync_state.deinit();

    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    try sync_state.serializeFull(&t, &builder.writer);

    const output = builder.writer.buffered();

    // Should have produced some output
    try testing.expect(output.len > 0);

    // Parse header: epoch(8) + rows(2) + cols(2) + cursor_x(2) + cursor_y(2)
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, output[0..8], .big));
    try testing.expectEqual(@as(u16, 24), std.mem.readInt(u16, output[8..10], .big));
    try testing.expectEqual(@as(u16, 80), std.mem.readInt(u16, output[10..12], .big));
}
