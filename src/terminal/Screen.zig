//! Screen represents the internal storage for a terminal screen, including
//! scrollback. This is implemented as a single continuous ring buffer.
//!
//! Definitions:
//!
//!   * Screen - The full screen (active + history).
//!   * Active - The area that is the current edit-able screen (the
//!       bottom of the scrollback). This is "edit-able" because it is
//!       the only part that escape sequences such as set cursor position
//!       actually affect.
//!   * History - The area that contains the lines prior to the active
//!       area. This is the scrollback area. Escape sequences can no longer
//!       affect this area.
//!   * Viewport - The area that is currently visible to the user. This
//!       can be thought of as the current window into the screen.
//!
//! The internal storage of the screen is stored in a circular buffer
//! with roughly the following format:
//!
//!      Storage (Circular Buffer)
//!   ┌─────────────────────────────────────┐
//!   │ ┌─────┐┌─────┐┌─────┐       ┌─────┐ │
//!   │ │ Hdr ││Cell ││Cell │  ...  │Cell │ │
//!   │ │     ││  0  ││  1  │       │ N-1 │ │
//!   │ └─────┘└─────┘└─────┘       └─────┘ │
//!   │ ┌─────┐┌─────┐┌─────┐       ┌─────┐ │
//!   │ │ Hdr ││Cell ││Cell │  ...  │Cell │ │
//!   │ │     ││  0  ││  1  │       │ N-1 │ │
//!   │ └─────┘└─────┘└─────┘       └─────┘ │
//!   │ ┌─────┐┌─────┐┌─────┐       ┌─────┐ │
//!   │ │ Hdr ││Cell ││Cell │  ...  │Cell │ │
//!   │ │     ││  0  ││  1  │       │ N-1 │ │
//!   │ └─────┘└─────┘└─────┘       └─────┘ │
//!   └─────────────────────────────────────┘
//!
//! There are R rows with N columns. Each row has an extra "cell" which is
//! the row header. The row header is used to track metadata about the row.
//! Each cell itself is a union (see StorageCell) of either the header or
//! the cell.
//!
//! The storage is in a circular buffer so that scrollback can be handled
//! without copying rows. The circular buffer is implemented in circ_buf.zig.
//! The top of the circular buffer (index 0) is the top of the screen,
//! i.e. the scrollback if there is a lot of data.
//!
//! The top of the active area (or end of the history area, same thing) is
//! cached in `self.history` and is an offset in rows. This could always be
//! calculated but profiling showed that caching it saves a lot of time in
//! hot loops for minimal memory cost.
const Screen = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const utf8proc = @import("utf8proc");
const trace = @import("tracy").trace;
const sgr = @import("sgr.zig");
const color = @import("color.zig");
const point = @import("point.zig");
const CircBuf = @import("circ_buf.zig").CircBuf;
const Selection = @import("Selection.zig");
const fastmem = @import("../fastmem.zig");

const log = std.log.scoped(.screen);

/// Cursor represents the cursor state.
pub const Cursor = struct {
    // x, y where the cursor currently exists (0-indexed). This x/y is
    // always the offset in the active area.
    x: usize = 0,
    y: usize = 0,

    // pen is the current cell styling to apply to new cells.
    pen: Cell = .{ .char = 0 },

    // The last column flag (LCF) used to do soft wrapping.
    pending_wrap: bool = false,
};

/// This is a single item within the storage buffer. We use a union to
/// have different types of data in a single contiguous buffer.
const StorageCell = union {
    header: RowHeader,
    cell: Cell,

    test {
        // log.warn("header={}@{} cell={}@{} storage={}@{}", .{
        //     @sizeOf(RowHeader),
        //     @alignOf(RowHeader),
        //     @sizeOf(Cell),
        //     @alignOf(Cell),
        //     @sizeOf(StorageCell),
        //     @alignOf(StorageCell),
        // });
    }

    comptime {
        // We only check this during ReleaseFast because safety checks
        // have to be disabled to get this size.
        if (!std.debug.runtime_safety) {
            // We want to be at most the size of a cell always. We have WAY
            // more cells than other fields, so we don't want to pay the cost
            // of padding due to other fields.
            assert(@sizeOf(Cell) == @sizeOf(StorageCell));
        } else {
            // Extra u32 for the tag for safety checks. This is subject to
            // change depending on the Zig compiler...
            assert((@sizeOf(Cell) + @sizeOf(u32)) == @sizeOf(StorageCell));
        }
    }
};

/// The row header is at the start of every row within the storage buffer.
/// It can store row-specific data.
pub const RowHeader = struct {
    pub const Id = u32;

    /// The ID of this row, used to uniquely identify this row. The cells
    /// are also ID'd by id + cell index (0-indexed). This will wrap around
    /// when it reaches the maximum value for the type. For caching purposes,
    /// when wrapping happens, all rows in the screen will be marked dirty.
    id: Id = 0,

    // Packed flags
    flags: packed struct {
        /// If true, this row is soft-wrapped. The first cell of the next
        /// row is a continuous of this row.
        wrap: bool = false,

        /// True if this row has had changes. It is up to the caller to
        /// set this to false. See the methods on Row to see what will set
        /// this to true.
        dirty: bool = false,

        /// True if any cell in this row has a grapheme associated with it.
        grapheme: bool = false,

        /// True if this row is an active prompt (awaiting input). This is
        /// set to false when the semantic prompt events (OSC 133) are received.
        /// There are scenarios where the shell may never send this event, so
        /// in order to reliably test prompt status, you need to iterate
        /// backwards from the cursor to check the current line status going
        /// back.
        semantic_prompt: SemanticPrompt = .unknown,
    } = .{},

    /// Semantic prompt type.
    pub const SemanticPrompt = enum(u3) {
        /// Unknown, the running application didn't tell us for this line.
        unknown = 0,

        /// This is a prompt line, meaning it only contains the shell prompt.
        /// For poorly behaving shells, this may also be the input.
        prompt = 1,

        /// This line contains the input area. We don't currently track
        /// where this actually is in the line, so we just assume it is somewhere.
        input = 2,

        /// This line is the start of command output.
        command = 3,
    };
};

/// Cell is a single cell within the screen.
pub const Cell = struct {
    /// The primary unicode codepoint for this cell. Most cells (almost all)
    /// contain exactly one unicode codepoint. However, it is possible for
    /// cells to contain multiple if multiple codepoints are used to create
    /// a single grapheme cluster.
    ///
    /// In the case multiple codepoints make up a single grapheme, the
    /// additional codepoints can be looked up in the hash map on the
    /// Screen. Since multi-codepoints graphemes are rare, we don't want to
    /// waste memory for every cell, so we use a side lookup for it.
    char: u32 = 0,

    /// Foreground and background color. attrs.has_{bg/fg} must be checked
    /// to see if these are useful values.
    fg: color.RGB = .{},
    bg: color.RGB = .{},

    /// Underline color.
    /// NOTE(mitchellh): This is very rarely set so ideally we wouldn't waste
    /// cell space for this. For now its on this struct because it is convenient
    /// but we should consider a lookaside table for this.
    underline_fg: color.RGB = .{},

    /// On/off attributes that can be set
    attrs: packed struct {
        has_bg: bool = false,
        has_fg: bool = false,

        bold: bool = false,
        italic: bool = false,
        faint: bool = false,
        blink: bool = false,
        inverse: bool = false,
        invisible: bool = false,
        strikethrough: bool = false,
        underline: sgr.Attribute.Underline = .none,
        underline_color: bool = false,

        /// True if this is a wide character. This char takes up
        /// two cells. The following cell ALWAYS is a space.
        wide: bool = false,

        /// Notes that this only exists to be blank for a preceeding
        /// wide character (tail) or following (head).
        wide_spacer_tail: bool = false,
        wide_spacer_head: bool = false,

        /// True if this cell has additional codepoints to form a complete
        /// grapheme cluster. If this is true, then the row grapheme flag must
        /// also be true. The grapheme code points can be looked up in the
        /// screen grapheme map.
        grapheme: bool = false,
    } = .{},

    /// True if the cell should be skipped for drawing
    pub fn empty(self: Cell) bool {
        // Get our backing integer for our packed struct of attributes
        const AttrInt = @Type(.{ .Int = .{
            .signedness = .unsigned,
            .bits = @bitSizeOf(@TypeOf(self.attrs)),
        } });

        // We're empty if we have no char AND we have no styling
        return self.char == 0 and @as(AttrInt, @bitCast(self.attrs)) == 0;
    }

    /// The width of the cell.
    ///
    /// This uses the legacy calculation of a per-codepoint width calculation
    /// to determine the width. This legacy calculation is incorrect because
    /// it doesn't take into account multi-codepoint graphemes.
    ///
    /// The goal of this function is to match the expectation of shells
    /// that aren't grapheme aware (at the time of writing this comment: none
    /// are grapheme aware). This means it should match wcswidth.
    pub fn widthLegacy(self: Cell) u8 {
        // Wide is always 2
        if (self.attrs.wide) return 2;

        // Wide spacers are always 0 because their width is accounted for
        // in the wide char.
        if (self.attrs.wide_spacer_tail or self.attrs.wide_spacer_head) return 0;

        return 1;
    }

    test "widthLegacy" {
        const testing = std.testing;

        var c: Cell = .{};
        try testing.expectEqual(@as(u16, 1), c.widthLegacy());

        c = .{ .attrs = .{ .wide = true } };
        try testing.expectEqual(@as(u16, 2), c.widthLegacy());

        c = .{ .attrs = .{ .wide_spacer_tail = true } };
        try testing.expectEqual(@as(u16, 0), c.widthLegacy());
    }

    test {
        // We use this test to ensure we always get the right size of the attrs
        // const cell: Cell = .{ .char = 0 };
        // _ = @bitCast(u8, cell.attrs);
        // try std.testing.expectEqual(1, @sizeOf(@TypeOf(cell.attrs)));
    }

    test {
        //log.warn("CELL={} bits={} {}", .{ @sizeOf(Cell), @bitSizeOf(Cell), @alignOf(Cell) });
        try std.testing.expectEqual(20, @sizeOf(Cell));
    }
};

/// A row is a single row in the screen.
pub const Row = struct {
    /// The screen this row is part of.
    screen: *Screen,

    /// Raw internal storage, do NOT write to this, use only the
    /// helpers. Writing directly to this can easily mess up state
    /// causing future crashes or misrendering.
    storage: []StorageCell,

    /// Returns the ID for this row. You can turn this into a cell ID
    /// by adding the cell offset plus 1 (so it is 1-indexed).
    pub inline fn getId(self: Row) RowHeader.Id {
        return self.storage[0].header.id;
    }

    /// Set that this row is soft-wrapped. This doesn't change the contents
    /// of this row so the row won't be marked dirty.
    pub fn setWrapped(self: Row, v: bool) void {
        self.storage[0].header.flags.wrap = v;
    }

    /// Set a row as dirty or not. Generally you only set a row as NOT dirty.
    /// Various Row functions manage flagging dirty to true.
    pub fn setDirty(self: Row, v: bool) void {
        self.storage[0].header.flags.dirty = v;
    }

    pub inline fn isDirty(self: Row) bool {
        return self.storage[0].header.flags.dirty;
    }

    /// Set the semantic prompt state for this row.
    pub fn setSemanticPrompt(self: Row, p: RowHeader.SemanticPrompt) void {
        self.storage[0].header.flags.semantic_prompt = p;
    }

    /// Retrieve the semantic prompt state for this row.
    pub fn getSemanticPrompt(self: Row) RowHeader.SemanticPrompt {
        return self.storage[0].header.flags.semantic_prompt;
    }

    /// Retrieve the header for this row.
    pub fn header(self: Row) RowHeader {
        return self.storage[0].header;
    }

    /// Returns the number of cells in this row.
    pub fn lenCells(self: Row) usize {
        return self.storage.len - 1;
    }

    /// Returns true if the row only has empty characters. This ignores
    /// styling (i.e. styling does not count as non-empty).
    pub fn isEmpty(self: Row) bool {
        const len = self.storage.len;
        for (self.storage[1..len]) |cell| {
            if (cell.cell.char != 0) return false;
        }

        return true;
    }

    /// Clear the row, making all cells empty.
    pub fn clear(self: Row, pen: Cell) void {
        var empty_pen = pen;
        empty_pen.char = 0;
        self.fill(empty_pen);
    }

    /// Fill the entire row with a copy of a single cell.
    pub fn fill(self: Row, cell: Cell) void {
        self.fillSlice(cell, 0, self.storage.len - 1);
    }

    /// Fill a slice of a row.
    pub fn fillSlice(self: Row, cell: Cell, start: usize, len: usize) void {
        assert(len <= self.storage.len - 1);
        assert(!cell.attrs.grapheme); // you can't fill with graphemes

        // Always mark the row as dirty for this.
        self.storage[0].header.flags.dirty = true;

        // If our row has no graphemes, then this is a fast copy
        if (!self.storage[0].header.flags.grapheme) {
            @memset(self.storage[start + 1 .. len + 1], .{ .cell = cell });
            return;
        }

        // We have graphemes, so we have to clear those first.
        for (self.storage[start + 1 .. len + 1], 0..) |*storage_cell, x| {
            if (storage_cell.cell.attrs.grapheme) self.clearGraphemes(x);
            storage_cell.* = .{ .cell = cell };
        }

        // We only reset the grapheme flag if we fill the whole row, for now.
        // We can improve performance by more correctly setting this but I'm
        // going to defer that until we can measure.
        if (start == 0 and len == self.storage.len - 1) {
            self.storage[0].header.flags.grapheme = false;
        }
    }

    /// Get a single immutable cell.
    pub fn getCell(self: Row, x: usize) Cell {
        assert(x < self.storage.len - 1);
        return self.storage[x + 1].cell;
    }

    /// Get a pointr to the cell at column x (0-indexed). This always
    /// assumes that the cell was modified, notifying the renderer on the
    /// next call to re-render this cell. Any change detection to avoid
    /// this should be done prior.
    pub fn getCellPtr(self: Row, x: usize) *Cell {
        assert(x < self.storage.len - 1);

        // Always mark the row as dirty for this.
        self.storage[0].header.flags.dirty = true;

        return &self.storage[x + 1].cell;
    }

    /// Attach a grapheme codepoint to the given cell.
    pub fn attachGrapheme(self: Row, x: usize, cp: u21) !void {
        const cell = &self.storage[x + 1].cell;
        const key = self.getId() + x + 1;
        const gop = try self.screen.graphemes.getOrPut(self.screen.alloc, key);
        errdefer if (!gop.found_existing) {
            _ = self.screen.graphemes.remove(key);
        };

        // Our row now has a grapheme
        self.storage[0].header.flags.grapheme = true;

        // Our row is now dirty
        self.storage[0].header.flags.dirty = true;

        // If we weren't previously a grapheme and we found an existing value
        // it means that it is old grapheme data. Just delete that.
        if (!cell.attrs.grapheme and gop.found_existing) {
            cell.attrs.grapheme = true;
            gop.value_ptr.deinit(self.screen.alloc);
            gop.value_ptr.* = .{ .one = cp };
            return;
        }

        // If we didn't have a previous value, attach the single codepoint.
        if (!gop.found_existing) {
            cell.attrs.grapheme = true;
            gop.value_ptr.* = .{ .one = cp };
            return;
        }

        // We have an existing value, promote
        assert(cell.attrs.grapheme);
        try gop.value_ptr.append(self.screen.alloc, cp);
    }

    /// Removes all graphemes associated with a cell.
    pub fn clearGraphemes(self: Row, x: usize) void {
        // Our row is now dirty
        self.storage[0].header.flags.dirty = true;

        const cell = &self.storage[x + 1].cell;
        const key = self.getId() + x + 1;
        cell.attrs.grapheme = false;
        if (self.screen.graphemes.fetchRemove(key)) |kv| {
            kv.value.deinit(self.screen.alloc);
        }
    }

    /// Copy the row src into this row. The row can be from another screen.
    pub fn copyRow(self: Row, src: Row) !void {
        // If we have graphemes, clear first to unset them.
        if (self.storage[0].header.flags.grapheme) self.clear(.{});

        // Copy the flags
        self.storage[0].header.flags = src.storage[0].header.flags;

        // Always mark the row as dirty for this.
        self.storage[0].header.flags.dirty = true;

        // If the source has no graphemes (likely) then this is fast.
        const end = @min(src.storage.len, self.storage.len);
        if (!src.storage[0].header.flags.grapheme) {
            fastmem.copy(StorageCell, self.storage[1..], src.storage[1..end]);
            return;
        }

        // Source has graphemes, this is slow.
        for (src.storage[1..end], 0..) |storage, x| {
            self.storage[x + 1] = .{ .cell = storage.cell };

            // Copy grapheme data if it exists
            if (storage.cell.attrs.grapheme) {
                const src_key = src.getId() + x + 1;
                const src_data = src.screen.graphemes.get(src_key) orelse continue;

                const dst_key = self.getId() + x + 1;
                const dst_gop = try self.screen.graphemes.getOrPut(self.screen.alloc, dst_key);
                dst_gop.value_ptr.* = try src_data.copy(self.screen.alloc);

                self.storage[0].header.flags.grapheme = true;
            }
        }
    }

    /// Read-only iterator for the cells in the row.
    pub fn cellIterator(self: Row) CellIterator {
        return .{ .row = self };
    }

    /// Read-only iterator for the grapheme codepoints in a cell. This only
    /// iterates over the EXTRA GRAPHEME codepoints and not the primary
    /// codepoint in cell.char.
    pub fn codepointIterator(self: Row, x: usize) CodepointIterator {
        const cell = &self.storage[x + 1].cell;
        assert(cell.attrs.grapheme);

        const key = self.getId() + x + 1;
        const data: GraphemeData = self.screen.graphemes.get(key) orelse data: {
            // This is probably a bug somewhere in our internal state,
            // but we don't want to just hard crash so its easier to just
            // have zero codepoints.
            log.debug("cell with grapheme flag but no grapheme data", .{});
            break :data .{ .zero = {} };
        };
        return .{ .data = data };
    }
};

/// Used to iterate through the rows of a specific region.
pub const RowIterator = struct {
    screen: *Screen,
    tag: RowIndexTag,
    max: usize,
    value: usize = 0,

    pub fn next(self: *RowIterator) ?Row {
        if (self.value >= self.max) return null;
        const idx = self.tag.index(self.value);
        const res = self.screen.getRow(idx);
        self.value += 1;
        return res;
    }
};

/// Used to iterate through the rows of a specific region.
pub const CellIterator = struct {
    row: Row,
    i: usize = 0,

    pub fn next(self: *CellIterator) ?Cell {
        if (self.i >= self.row.storage.len - 1) return null;
        const res = self.row.storage[self.i + 1].cell;
        self.i += 1;
        return res;
    }
};

/// Used to iterate through the codepoints of a cell. This only iterates
/// over the extra grapheme codepoints and not the primary codepoint.
pub const CodepointIterator = struct {
    data: GraphemeData,
    i: usize = 0,

    pub fn next(self: *CodepointIterator) ?u21 {
        switch (self.data) {
            .zero => return null,

            .one => |v| {
                if (self.i >= 1) return null;
                self.i += 1;
                return v;
            },

            .two => |v| {
                if (self.i >= v.len) return null;
                defer self.i += 1;
                return v[self.i];
            },

            .three => |v| {
                if (self.i >= v.len) return null;
                defer self.i += 1;
                return v[self.i];
            },

            .four => |v| {
                if (self.i >= v.len) return null;
                defer self.i += 1;
                return v[self.i];
            },

            .many => |v| {
                if (self.i >= v.len) return null;
                defer self.i += 1;
                return v[self.i];
            },
        }
    }
};

/// RowIndex represents a row within the screen. There are various meanings
/// of a row index and this union represents the available types. For example,
/// when talking about row "0" you may want the first row in the viewport,
/// the first row in the scrollback, or the first row in the active area.
///
/// All row indexes are 0-indexed.
pub const RowIndex = union(RowIndexTag) {
    /// The index is from the top of the screen. The screen includes all
    /// the history.
    screen: usize,

    /// The index is from the top of the viewport. Therefore, depending
    /// on where the user has scrolled the viewport, "0" is different.
    viewport: usize,

    /// The index is from the top of the active area. The active area is
    /// always "rows" tall, and 0 is the top row. The active area is the
    /// "edit-able" area where the terminal cursor is.
    active: usize,

    /// The index is from the top of the history (scrollback) to just
    /// prior to the active area.
    history: usize,

    /// Convert this row index into a screen offset. This will validate
    /// the value so even if it is already a screen value, this may error.
    pub fn toScreen(self: RowIndex, screen: *const Screen) RowIndex {
        const y = switch (self) {
            .screen => |y| y: {
                // NOTE for this and others below: Zig is supposed to optimize
                // away assert in releasefast but for some reason these were
                // not being optimized away. I don't know why. For these asserts
                // only, I comptime gate them.
                if (std.debug.runtime_safety) assert(y < RowIndexTag.screen.maxLen(screen));
                break :y y;
            },

            .viewport => |y| y: {
                if (std.debug.runtime_safety) assert(y < RowIndexTag.viewport.maxLen(screen));
                break :y y + screen.viewport;
            },

            .active => |y| y: {
                if (std.debug.runtime_safety) assert(y < RowIndexTag.active.maxLen(screen));
                break :y screen.history + y;
            },

            .history => |y| y: {
                if (std.debug.runtime_safety) assert(y < RowIndexTag.history.maxLen(screen));
                break :y y;
            },
        };

        return .{ .screen = y };
    }
};

/// The tags of RowIndex
pub const RowIndexTag = enum {
    screen,
    viewport,
    active,
    history,

    /// The max length for a given tag. This is a length, not an index,
    /// so it is 1-indexed. If the value is zero, it means that this
    /// section of the screen is empty or disabled.
    pub inline fn maxLen(self: RowIndexTag, screen: *const Screen) usize {
        const tracy = trace(@src());
        defer tracy.end();

        return switch (self) {
            // Screen can be any of the written rows
            .screen => screen.rowsWritten(),

            // Viewport can be any of the written rows or the max size
            // of a viewport.
            .viewport => @max(1, @min(screen.rows, screen.rowsWritten())),

            // History is all the way up to the top of our active area. If
            // we haven't filled our active area, there is no history.
            .history => screen.history,

            // Active area can be any number of rows. We ignore rows
            // written here because this is the only row index that can
            // actively grow our rows.
            .active => screen.rows,
            //TODO .active => @min(rows_written, screen.rows),
        };
    }

    /// Construct a RowIndex from a tag.
    pub fn index(self: RowIndexTag, value: usize) RowIndex {
        return switch (self) {
            .screen => .{ .screen = value },
            .viewport => .{ .viewport = value },
            .active => .{ .active = value },
            .history => .{ .history = value },
        };
    }
};

/// Stores the extra unicode codepoints that form a complete grapheme
/// cluster alongside a cell. We store this separately from a Cell because
/// grapheme clusters are relatively rare (depending on the language) and
/// we don't want to pay for the full cost all the time.
pub const GraphemeData = union(enum) {
    // The named counts allow us to avoid allocators. We do this because
    // []u21 is sizeof([4]u21) anyways so if we can store avoid small allocations
    // we prefer it. Grapheme clusters are almost always <= 4 codepoints.

    zero: void,
    one: u21,
    two: [2]u21,
    three: [3]u21,
    four: [4]u21,
    many: []u21,

    pub fn deinit(self: GraphemeData, alloc: Allocator) void {
        switch (self) {
            .many => |v| alloc.free(v),
            else => {},
        }
    }

    /// Append the codepoint cp to the grapheme data.
    pub fn append(self: *GraphemeData, alloc: Allocator, cp: u21) !void {
        switch (self.*) {
            .zero => self.* = .{ .one = cp },
            .one => |v| self.* = .{ .two = .{ v, cp } },
            .two => |v| self.* = .{ .three = .{ v[0], v[1], cp } },
            .three => |v| self.* = .{ .four = .{ v[0], v[1], v[2], cp } },
            .four => |v| {
                const many = try alloc.alloc(u21, 5);
                fastmem.copy(u21, many, &v);
                many[4] = cp;
                self.* = .{ .many = many };
            },

            .many => |v| {
                // Note: this is super inefficient, we should use an arraylist
                // or something so we have extra capacity.
                const many = try alloc.realloc(v, v.len + 1);
                many[v.len] = cp;
                self.* = .{ .many = many };
            },
        }
    }

    pub fn copy(self: GraphemeData, alloc: Allocator) !GraphemeData {
        // If we're not many we're not allocated so just copy on stack.
        if (self != .many) return self;

        // Heap allocated
        return GraphemeData{ .many = try alloc.dupe(u21, self.many) };
    }

    test {
        log.warn("Grapheme={}", .{@sizeOf(GraphemeData)});
    }

    test "append" {
        const testing = std.testing;
        const alloc = testing.allocator;

        var data: GraphemeData = .{ .one = 1 };
        defer data.deinit(alloc);

        try data.append(alloc, 2);
        try testing.expectEqual(GraphemeData{ .two = .{ 1, 2 } }, data);
        try data.append(alloc, 3);
        try testing.expectEqual(GraphemeData{ .three = .{ 1, 2, 3 } }, data);
        try data.append(alloc, 4);
        try testing.expectEqual(GraphemeData{ .four = .{ 1, 2, 3, 4 } }, data);
        try data.append(alloc, 5);
        try testing.expect(data == .many);
        try testing.expectEqualSlices(u21, &[_]u21{ 1, 2, 3, 4, 5 }, data.many);
        try data.append(alloc, 6);
        try testing.expect(data == .many);
        try testing.expectEqualSlices(u21, &[_]u21{ 1, 2, 3, 4, 5, 6 }, data.many);
    }

    comptime {
        // We want to keep this at most the size of the tag + []u21 so that
        // at most we're paying for the cost of a slice.
        //assert(@sizeOf(GraphemeData) == 24);
    }
};

// Initialize to header and not a cell so that we can check header.init
// to know if the remainder of the row has been initialized or not.
const StorageBuf = CircBuf(StorageCell, .{ .header = .{} });

/// Stores a mapping of cell ID (row ID + cell offset + 1) to
/// graphemes associated with a cell. To know if a cell has graphemes,
/// check the "grapheme" flag of a cell.
const GraphemeMap = std.AutoHashMapUnmanaged(usize, GraphemeData);

/// The allocator used for all the storage operations
alloc: Allocator,

/// The full set of storage.
storage: StorageBuf,

/// Graphemes associated with our current screen.
graphemes: GraphemeMap = .{},

/// The next ID to assign to a row. The value of this is NOT assigned.
next_row_id: RowHeader.Id = 1,

/// The number of rows and columns in the visible space.
rows: usize,
cols: usize,

/// The maximum number of lines that are available in scrollback. This
/// is in addition to the number of visible rows.
max_scrollback: usize,

/// The row (offset from the top) where the viewport currently is.
viewport: usize,

/// The amount of history (scrollback) that has been written so far. This
/// can be calculated dynamically using the storage buffer but its an
/// extremely hot piece of data so we cache it. Empirically this eliminates
/// millions of function calls and saves seconds under high scroll scenarios
/// (i.e. reading a large file).
history: usize,

/// Each screen maintains its own cursor state.
cursor: Cursor = .{},

/// Saved cursor saved with DECSC (ESC 7).
saved_cursor: Cursor = .{},

/// The selection for this screen (if any).
selection: ?Selection = null,

/// Initialize a new screen.
pub fn init(
    alloc: Allocator,
    rows: usize,
    cols: usize,
    max_scrollback: usize,
) !Screen {
    // * Our buffer size is preallocated to fit double our visible space
    //   or the maximum scrollback whichever is smaller.
    // * We add +1 to cols to fit the row header
    const buf_size = (rows + @min(max_scrollback, rows)) * (cols + 1);

    return Screen{
        .alloc = alloc,
        .storage = try StorageBuf.init(alloc, buf_size),
        .rows = rows,
        .cols = cols,
        .max_scrollback = max_scrollback,
        .viewport = 0,
        .history = 0,
    };
}

pub fn deinit(self: *Screen) void {
    self.storage.deinit(self.alloc);
    self.deinitGraphemes();
}

fn deinitGraphemes(self: *Screen) void {
    var grapheme_it = self.graphemes.valueIterator();
    while (grapheme_it.next()) |data| data.deinit(self.alloc);
    self.graphemes.deinit(self.alloc);
}

/// Copy the screen portion given by top and bottom into a new screen instance.
/// This clone is meant for read-only access and hasn't been tested for
/// mutability.
pub fn clone(self: *Screen, alloc: Allocator, top: RowIndex, bottom: RowIndex) !Screen {
    // Convert our top/bottom to screen coordinates
    const top_y = top.toScreen(self).screen;
    const bot_y = bottom.toScreen(self).screen;
    assert(bot_y >= top_y);
    const height = (bot_y - top_y) + 1;

    // We also figure out the "max y" we can have based on the number
    // of rows written. This is used to prevent from reading out of the
    // circular buffer where we might ahve no initialized data yet.
    const max_y = max_y: {
        const rows_written = self.rowsWritten();
        const index = RowIndex{ .active = @min(rows_written -| 1, self.rows - 1) };
        break :max_y index.toScreen(self).screen;
    };

    // The "real" Y value we use is whichever is smaller: the bottom
    // requested or the max. This prevents from reading zero data.
    // The "real" height is the amount of height of data we can actually
    // copy.
    const real_y = @min(bot_y, max_y);
    const real_height = (real_y - top_y) + 1;
    //log.warn("bot={} max={} top={} real={}", .{ bot_y, max_y, top_y, real_y });

    // Init a new screen that exactly fits the height. The height is the
    // non-real value because we still want the requested height by the
    // caller.
    var result = try init(alloc, height, self.cols, 0);
    errdefer result.deinit();

    // Copy some data
    result.cursor = self.cursor;

    // Get the pointer to our source buffer
    const len = real_height * (self.cols + 1);
    const src = self.storage.getPtrSlice(top_y * (self.cols + 1), len);

    // Get a direct pointer into our storage buffer. This should always be
    // one slice because we created a perfectly fitting buffer.
    const dst = result.storage.getPtrSlice(0, len);
    assert(dst[1].len == 0);

    // Perform the copy
    fastmem.copy(StorageCell, dst[0], src[0]);
    fastmem.copy(StorageCell, dst[0][src[0].len..], src[1]);

    // If there are graphemes, we just copy them all
    if (self.graphemes.count() > 0) {
        // Clone the map
        const graphemes = try self.graphemes.clone(alloc);

        // Go through all the values and clone the data because it MAY
        // (rarely) be allocated.
        var it = graphemes.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.* = try kv.value_ptr.copy(alloc);
        }

        result.graphemes = graphemes;
    }

    return result;
}

/// Returns true if the viewport is scrolled to the bottom of the screen.
pub fn viewportIsBottom(self: Screen) bool {
    return self.viewport == self.history;
}

/// Shortcut for getRow followed by getCell as a quick way to read a cell.
/// This is particularly useful for quickly reading the cell under a cursor
/// with `getCell(.active, cursor.y, cursor.x)`.
pub fn getCell(self: *Screen, tag: RowIndexTag, y: usize, x: usize) Cell {
    return self.getRow(tag.index(y)).getCell(x);
}

/// Shortcut for getRow followed by getCellPtr as a quick way to read a cell.
pub fn getCellPtr(self: *Screen, tag: RowIndexTag, y: usize, x: usize) *Cell {
    return self.getRow(tag.index(y)).getCellPtr(x);
}

/// Returns an iterator that can be used to iterate over all of the rows
/// from index zero of the given row index type. This can therefore iterate
/// from row 0 of the active area, history, viewport, etc.
pub fn rowIterator(self: *Screen, tag: RowIndexTag) RowIterator {
    const tracy = trace(@src());
    defer tracy.end();

    return .{
        .screen = self,
        .tag = tag,
        .max = tag.maxLen(self),
    };
}

/// Returns the row at the given index. This row is writable, although
/// only the active area should probably be written to.
pub fn getRow(self: *Screen, index: RowIndex) Row {
    const tracy = trace(@src());
    defer tracy.end();

    // Get our offset into storage
    const offset = index.toScreen(self).screen * (self.cols + 1);

    // Get the slices into the storage. This should never wrap because
    // we're perfectly aligned on row boundaries.
    const slices = self.storage.getPtrSlice(offset, self.cols + 1);
    assert(slices[0].len == self.cols + 1 and slices[1].len == 0);

    const row: Row = .{ .screen = self, .storage = slices[0] };
    if (row.storage[0].header.id == 0) {
        const Id = @TypeOf(self.next_row_id);
        const id = self.next_row_id;
        self.next_row_id +%= @as(Id, @intCast(self.cols));

        // Store the header
        row.storage[0].header.id = id;

        // We only set dirty and fill if its not dirty. If its dirty
        // we assume this row has been written but just hasn't had
        // an ID assigned yet.
        if (!row.storage[0].header.flags.dirty) {
            // Mark that we're dirty since we're a new row
            row.storage[0].header.flags.dirty = true;

            // We only need to fill with runtime safety because unions are
            // tag-checked. Otherwise, the default value of zero will be valid.
            if (std.debug.runtime_safety) row.fill(.{});
        }
    }
    return row;
}

/// Copy the row at src to dst.
pub fn copyRow(self: *Screen, dst: RowIndex, src: RowIndex) !void {
    // One day we can make this more efficient but for now
    // we do the easy thing.
    const dst_row = self.getRow(dst);
    const src_row = self.getRow(src);
    try dst_row.copyRow(src_row);
}

/// Scroll rows in a region up. Rows that go beyond the region
/// top or bottom are deleted, and new rows inserted are blank according
/// to the current pen.
///
/// This does NOT create any new scrollback. This modifies an existing
/// region within the screen (including possibly the scrollback if
/// the top/bottom are within it).
///
/// This can be used to implement terminal scroll regions efficiently.
pub fn scrollRegionUp(self: *Screen, top: RowIndex, bottom: RowIndex, count: usize) void {
    const tracy = trace(@src());
    defer tracy.end();

    // Avoid a lot of work if we're doing nothing.
    if (count == 0) return;

    // Convert our top/bottom to screen y values. This is the y offset
    // in the entire screen buffer.
    const top_y = top.toScreen(self).screen;
    const bot_y = bottom.toScreen(self).screen;

    // If top is outside of the range of bot, we do nothing.
    if (top_y >= bot_y) return;

    // We can only scroll up to the number of rows in the region. The "+ 1"
    // is because our y values are 0-based and count is 1-based.
    assert(count <= (bot_y - top_y + 1));

    // Get the storage pointer for the full scroll region. We're going to
    // be modifying the whole thing so we get it right away.
    const height = (bot_y - top_y) + 1;
    const len = height * (self.cols + 1);
    const slices = self.storage.getPtrSlice(top_y * (self.cols + 1), len);

    // The total amount we're going to copy
    const total_copy = (height - count) * (self.cols + 1);

    // Fast-path is that we have a contigous buffer in our circular buffer.
    // In this case we can do some memmoves.
    if (slices[1].len == 0) {
        const buf = slices[0];

        {
            // Our copy starts "count" rows below and is the length of
            // the remainder of the data. Our destination is the top since
            // we're scrolling up.
            //
            // Note we do NOT need to set any row headers to dirty because
            // the row contents are not changing for the row ID.
            const dst = buf;
            const src_offset = count * (self.cols + 1);
            const src = buf[src_offset..];
            assert(@intFromPtr(dst.ptr) < @intFromPtr(src.ptr));
            fastmem.move(StorageCell, dst, src);
        }

        {
            // Copy in our empties. The destination is the bottom
            // count rows. We first fill with the pen values since there
            // is a lot more of that.
            const dst_offset = total_copy;
            const dst = buf[dst_offset..];
            @memset(dst, .{ .cell = self.cursor.pen });

            // Then we make sure our row headers are zeroed out. We set
            // the value to a dirty row header so that the renderer re-draws.
            //
            // NOTE: we do NOT set a valid row ID here. The next time getRow
            // is called it will be initialized. This should work fine as
            // far as I can tell. It is important to set dirty so that the
            // renderer knows to redraw this.
            var i: usize = dst_offset;
            while (i < buf.len) : (i += self.cols + 1) {
                buf[i] = .{ .header = .{
                    .flags = .{ .dirty = true },
                } };
            }
        }

        return;
    }

    // If we're split across two buffers this is a "slow" path. This shouldn't
    // happen with the "active" area but it appears it does... in the future
    // I plan on changing scroll region stuff to make it much faster so for
    // now we just deal with this slow path.

    // This is the offset where we have to start copying.
    const src_offset = count * (self.cols + 1);

    // Perform the copy and calculate where we need to start zero-ing.
    const zero_offset: [2]usize = if (src_offset < slices[0].len) zero_offset: {
        var remaining: usize = len;

        // Source starts in the top... so we can copy some from there.
        const dst = slices[0];
        const src = slices[0][src_offset..];
        assert(@intFromPtr(dst.ptr) < @intFromPtr(src.ptr));
        fastmem.move(StorageCell, dst, src);
        remaining = total_copy - src.len;
        if (remaining == 0) break :zero_offset .{ src.len, 0 };

        // We have data remaining, which means that we have to grab some
        // from the bottom slice.
        const dst2 = slices[0][src.len..];
        const src2_len = @min(dst2.len, remaining);
        const src2 = slices[1][0..src2_len];
        fastmem.copy(StorageCell, dst2, src2);
        remaining -= src2_len;
        if (remaining == 0) break :zero_offset .{ src.len + src2.len, 0 };

        // We still have data remaining, which means we copy into the bot.
        const dst3 = slices[1];
        const src3 = slices[1][src2_len .. src2_len + remaining];
        fastmem.move(StorageCell, dst3, src3);

        break :zero_offset .{ slices[0].len, src3.len };
    } else zero_offset: {
        var remaining: usize = len;

        // Source is in the bottom, so we copy from there into top.
        const bot_src_offset = src_offset - slices[0].len;
        const dst = slices[0];
        const src = slices[1][bot_src_offset..];
        const src_len = @min(dst.len, src.len);
        fastmem.copy(StorageCell, dst, src[0..src_len]);
        remaining = total_copy - src_len;
        if (remaining == 0) break :zero_offset .{ src_len, 0 };

        // We have data remaining, this has to go into the bottom.
        const dst2 = slices[1];
        const src2_offset = bot_src_offset + src_len;
        const src2 = slices[1][src2_offset..];
        fastmem.move(StorageCell, dst2, src2);
        break :zero_offset .{ slices[0].len, src2_offset };
    };

    // Zero
    for (zero_offset, 0..) |offset, i| {
        if (offset >= slices[i].len) continue;

        const dst = slices[i][offset..];
        @memset(dst, .{ .cell = self.cursor.pen });

        var j: usize = offset;
        while (j < slices[i].len) : (j += self.cols + 1) {
            slices[i][j] = .{ .header = .{
                .flags = .{ .dirty = true },
            } };
        }
    }
}

/// Returns the offset into the storage buffer that the given row can
/// be found. This assumes valid input and will crash if the input is
/// invalid.
fn rowOffset(self: Screen, index: RowIndex) usize {
    // +1 for row header
    return index.toScreen(&self).screen * (self.cols + 1);
}

/// Returns the number of rows that have actually been written to the
/// screen. This assumes a row is "written" if getRow was ever called
/// on the row.
fn rowsWritten(self: Screen) usize {
    // The number of rows we've actually written into our buffer
    // This should always be cleanly divisible since we only request
    // data in row chunks from the buffer.
    assert(@mod(self.storage.len(), self.cols + 1) == 0);
    return self.storage.len() / (self.cols + 1);
}

/// The number of rows our backing storage supports. This should
/// always be self.rows but we use the backing storage as a source of truth.
fn rowsCapacity(self: Screen) usize {
    assert(@mod(self.storage.capacity(), self.cols + 1) == 0);
    return self.storage.capacity() / (self.cols + 1);
}

/// The maximum possible capacity of the underlying buffer if we reached
/// the max scrollback.
fn maxCapacity(self: Screen) usize {
    return (self.rows + self.max_scrollback) * (self.cols + 1);
}

/// Clear all the history. This moves the viewport back to the "top", too.
pub fn clearHistory(self: *Screen) void {
    // If there is no history, do nothing.
    if (self.history == 0) return;

    // Delete all our history
    self.storage.deleteOldest(self.history * (self.cols + 1));
    self.history = 0;

    // Back to the top
    self.viewport = 0;
}

/// Select the line under the given point. This will select across soft-wrapped
/// lines and will omit the leading and trailing whitespace. If the point is
/// over whitespace but the line has non-whitespace characters elsewhere, the
/// line will be selected.
pub fn selectLine(self: *Screen, pt: point.ScreenPoint) ?Selection {
    // Whitespace characters for selection purposes
    const whitespace = &[_]u32{ 0, ' ', '\t' };

    // Impossible to select anything outside of the area we've written.
    const y_max = self.rowsWritten() - 1;
    if (pt.y > y_max or pt.x >= self.cols) return null;

    // The real start of the row is the first row in the soft-wrap.
    const start_row: usize = start_row: {
        if (pt.y == 0) break :start_row 0;

        var y: usize = pt.y - 1;
        while (true) {
            const current = self.getRow(.{ .screen = y });
            if (!current.header().flags.wrap) break :start_row y + 1;
            if (y == 0) break :start_row y;
            y -= 1;
        }
        unreachable;
    };

    // The real end of the row is the final row in the soft-wrap.
    const end_row: usize = end_row: {
        var y: usize = pt.y;
        while (y <= y_max) : (y += 1) {
            const current = self.getRow(.{ .screen = y });
            if (y == y_max or !current.header().flags.wrap) break :end_row y;
        }
        unreachable;
    };

    // Go forward from the start to find the first non-whitespace character.
    const start: point.ScreenPoint = start: {
        var y: usize = start_row;
        while (y <= y_max) : (y += 1) {
            const current_row = self.getRow(.{ .screen = y });
            var x: usize = 0;
            while (x < self.cols) : (x += 1) {
                const cell = current_row.getCell(x);

                // Empty is whitespace
                if (cell.empty()) continue;

                // Non-empty means we found it.
                const this_whitespace = std.mem.indexOfAny(
                    u32,
                    whitespace,
                    &[_]u32{cell.char},
                ) != null;
                if (this_whitespace) continue;

                break :start .{ .x = x, .y = y };
            }
        }

        // There is no start point and therefore no line that can be selected.
        return null;
    };

    // Go backward from the end to find the first non-whitespace character.
    const end: point.ScreenPoint = end: {
        var y: usize = end_row;
        while (true) {
            const current_row = self.getRow(.{ .screen = y });

            var x: usize = 0;
            while (x < self.cols) : (x += 1) {
                const real_x = self.cols - x - 1;
                const cell = current_row.getCell(real_x);

                // Empty or whitespace, ignore.
                if (cell.empty()) continue;
                const this_whitespace = std.mem.indexOfAny(
                    u32,
                    whitespace,
                    &[_]u32{cell.char},
                ) != null;
                if (this_whitespace) continue;

                // Got it
                break :end .{ .x = real_x, .y = y };
            }

            if (y == 0) break;
            y -= 1;
        }

        // There is no start point and therefore no line that can be selected.
        return null;
    };

    return Selection{
        .start = start,
        .end = end,
    };
}

/// Select the word under the given point. A word is any consecutive series
/// of characters that are exclusively whitespace or exclusively non-whitespace.
/// A selection can span multiple physical lines if they are soft-wrapped.
///
/// This will return null if a selection is impossible. The only scenario
/// this happens is if the point pt is outside of the written screen space.
pub fn selectWord(self: *Screen, pt: point.ScreenPoint) ?Selection {
    // Boundary characters for selection purposes
    const boundary = &[_]u32{ 0, ' ', '\t', '\'', '"' };

    // Impossible to select anything outside of the area we've written.
    const y_max = self.rowsWritten() - 1;
    if (pt.y > y_max) return null;

    // Get our row
    const row = self.getRow(.{ .screen = pt.y });
    const start_cell = row.getCell(pt.x);

    // If our cell is empty we can't select a word, because we can't select
    // areas where the screen is not yet written.
    if (start_cell.empty()) return null;

    // Determine if we are a boundary or not to determine what our boundary is.
    const expect_boundary = std.mem.indexOfAny(u32, boundary, &[_]u32{start_cell.char}) != null;

    // Go forwards to find our end boundary
    const end: point.ScreenPoint = boundary: {
        var prev: point.ScreenPoint = pt;
        var y: usize = pt.y;
        var x: usize = pt.x;
        while (y <= y_max) : (y += 1) {
            const current_row = self.getRow(.{ .screen = y });

            // Go through all the remainining cells on this row until
            // we reach a boundary condition.
            while (x < self.cols) : (x += 1) {
                const cell = current_row.getCell(x);

                // If we reached an empty cell its always a boundary
                if (cell.empty()) break :boundary prev;

                // If we do not match our expected set, we hit a boundary
                const this_boundary = std.mem.indexOfAny(
                    u32,
                    boundary,
                    &[_]u32{cell.char},
                ) != null;
                if (this_boundary != expect_boundary) break :boundary prev;

                // Increase our prev
                prev.x = x;
                prev.y = y;
            }

            // If we aren't wrapping, then we're done this is a boundary.
            if (!current_row.header().flags.wrap) break :boundary prev;

            // If we are wrapping, reset some values and search the next line.
            x = 0;
        }

        break :boundary .{ .x = self.cols - 1, .y = y_max };
    };

    // Go backwards to find our start boundary
    const start: point.ScreenPoint = boundary: {
        var current_row = row;
        var prev: point.ScreenPoint = pt;

        var y: usize = pt.y;
        var x: usize = pt.x;
        while (true) {
            // Go through all the remainining cells on this row until
            // we reach a boundary condition.
            while (x > 0) : (x -= 1) {
                const cell = current_row.getCell(x - 1);
                const this_boundary = std.mem.indexOfAny(
                    u32,
                    boundary,
                    &[_]u32{cell.char},
                ) != null;
                if (this_boundary != expect_boundary) break :boundary prev;

                // Update our prev
                prev.x = x - 1;
                prev.y = y;
            }

            // If we're at the start, we need to check if the previous line wrapped.
            // If we are wrapped, we continue searching. If we are not wrapped,
            // then we've hit a boundary.
            assert(prev.x == 0);

            // If we're at the end, we're done!
            if (y == 0) break;

            // If the previous row did not wrap, then we're done. Otherwise
            // we keep searching.
            y -= 1;
            current_row = self.getRow(.{ .screen = y });
            if (!current_row.header().flags.wrap) break :boundary prev;

            // Set x to start at the first non-empty cell
            x = self.cols;
            while (x > 0) : (x -= 1) {
                if (!current_row.getCell(x - 1).empty()) break;
            }
        }

        break :boundary .{ .x = 0, .y = 0 };
    };

    return Selection{
        .start = start,
        .end = end,
    };
}

/// Scroll behaviors for the scroll function.
pub const Scroll = union(enum) {
    /// Scroll to the top of the scroll buffer. The first line of the
    /// viewport will be the top line of the scroll buffer.
    top: void,

    /// Scroll to the bottom, where the last line of the viewport
    /// will be the last line of the buffer. TODO: are we sure?
    bottom: void,

    /// Scroll up (negative) or down (positive) some fixed amount.
    /// Scrolling direction (up/down) describes the direction the viewport
    /// moves, not the direction text moves. This is the colloquial way that
    /// scrolling is described: "scroll the page down".
    delta: isize,

    /// Same as delta but scrolling down will not grow the scrollback.
    /// Scrolling down at the bottom will do nothing (similar to how
    /// delta at the top does nothing).
    delta_no_grow: isize,
};

/// Scroll the screen by the given behavior. Note that this will always
/// "move" the screen. It is up to the caller to determine if they actually
/// want to do that yet (i.e. are they writing to the end of the screen
/// or not).
pub fn scroll(self: *Screen, behavior: Scroll) !void {
    switch (behavior) {
        // Setting viewport offset to zero makes row 0 be at self.top
        // which is the top!
        .top => self.viewport = 0,

        // Bottom is the end of the history area (end of history is the
        // top of the active area).
        .bottom => self.viewport = self.history,

        // TODO: deltas greater than the entire scrollback
        .delta => |delta| try self.scrollDelta(delta, true),
        .delta_no_grow => |delta| try self.scrollDelta(delta, false),
    }
}

fn scrollDelta(self: *Screen, delta: isize, grow: bool) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // If we're scrolling up, then we just subtract and we're done.
    // We just clamp at 0 which blocks us from scrolling off the top.
    if (delta < 0) {
        self.viewport -|= @as(usize, @intCast(-delta));
        return;
    }

    // If we're scrolling down and not growing, then we just
    // add to the viewport and clamp at the bottom.
    if (!grow) {
        self.viewport = @min(
            self.history,
            self.viewport + @as(usize, @intCast(delta)),
        );
        return;
    }

    // Add our delta to our viewport. If we're less than the max currently
    // allowed to scroll to the bottom (the end of the history), then we
    // have space and we just return.
    self.viewport += @as(usize, @intCast(delta));
    if (self.viewport <= self.history) return;

    // If our viewport is past the top of our history then we potentially need
    // to write more blank rows. If our viewport is more than our rows written
    // then we expand out to there.
    const rows_written = self.rowsWritten();
    const viewport_bottom = self.viewport + self.rows;
    if (viewport_bottom <= rows_written) return;

    // The number of new rows we need is the number of rows off our
    // previous bottom we are growing.
    const new_rows_needed = viewport_bottom - rows_written;

    // If we can't fit into our capacity but we have space, resize the
    // buffer to allocate more scrollback.
    const rows_final = rows_written + new_rows_needed;
    if (rows_final > self.rowsCapacity()) {
        const max_capacity = self.maxCapacity();
        if (self.storage.capacity() < max_capacity) {
            // The capacity we want to allocate. We take whatever is greater
            // of what we actually need and two pages. We don't want to
            // allocate one row at a time (common for scrolling) so we do this
            // to chunk it.
            const needed_capacity = @max(
                rows_final * (self.cols + 1),
                @min(self.storage.capacity() * 2, max_capacity),
            );

            // Allocate what we can.
            try self.storage.resize(
                self.alloc,
                @min(max_capacity, needed_capacity),
            );
        }
    }

    // If we can't fit our rows into our capacity, we delete some scrollback.
    const rows_deleted = if (rows_final > self.rowsCapacity()) deleted: {
        const rows_to_delete = rows_final - self.rowsCapacity();

        // Fast-path: we have no graphemes.
        // Slow-path: we have graphemes, we have to check each row
        // we're going to delete to see if they contain graphemes and
        // clear the ones that do so we clear memory properly.
        if (self.graphemes.count() > 0) {
            var y: usize = 0;
            while (y < rows_to_delete) : (y += 1) {
                const row = self.getRow(.{ .active = y });
                if (row.storage[0].header.flags.grapheme) row.clear(.{});
            }
        }

        self.viewport -= rows_to_delete;
        self.storage.deleteOldest(rows_to_delete * (self.cols + 1));
        break :deleted rows_to_delete;
    } else 0;

    // If we are deleting rows and have a selection, then we need to offset
    // the selection by the rows we're deleting.
    if (self.selection) |*sel| {
        // If we're deleting more rows than our Y values, we also move
        // the X over to 0 because we're in the middle of the selection now.
        if (rows_deleted > sel.start.y) sel.start.x = 0;
        if (rows_deleted > sel.end.y) sel.end.x = 0;

        // Remove the deleted rows from both y values. We use saturating
        // subtraction so that we can detect when we're at zero.
        sel.start.y -|= rows_deleted;
        sel.end.y -|= rows_deleted;

        // If the selection is now empty, just clear it.
        if (sel.empty()) self.selection = null;
    }

    // If we have more rows than what shows on our screen, we have a
    // history boundary.
    const rows_written_final = rows_final - rows_deleted;
    if (rows_written_final > self.rows) {
        self.history = rows_written_final - self.rows;
    }

    // Ensure we have "written" our last row so that it shows up
    _ = self.storage.getPtrSlice(
        (rows_written_final - 1) * (self.cols + 1),
        self.cols + 1,
    );
}

/// Returns the raw text associated with a selection. This will unwrap
/// soft-wrapped edges. The returned slice is owned by the caller and allocated
/// using alloc, not the allocator associated with the screen (unless they match).
pub fn selectionString(
    self: *Screen,
    alloc: Allocator,
    sel: Selection,
    trim: bool,
) ![:0]const u8 {
    // Get the slices for the string
    const slices = self.selectionSlices(sel);

    // We can now know how much space we'll need to store the string. We loop
    // over and UTF8-encode and calculate the exact size required. We will be
    // off here by at most "newlines" values in the worst case that every
    // single line is soft-wrapped.
    const chars = chars: {
        var count: usize = 0;
        const arr = [_][]StorageCell{ slices.top, slices.bot };
        for (arr) |slice| {
            for (slice, 0..) |cell, i| {
                // detect row headers
                if (@mod(i, self.cols + 1) == 0) {
                    // We use each row header as an opportunity to "count"
                    // a new row, and therefore count a possible newline.
                    count += 1;

                    // If we have runtime safety, then we can have invalidly
                    // tagged cells because all cells are headers by default.
                    // This isn't an issue in prod builds because the zero values
                    // we use are correct by default.
                    if (std.debug.runtime_safety) {
                        if (cell.header.id == 0) {
                            @memset(
                                slice[i + 1 .. i + 1 + self.cols],
                                .{ .cell = .{} },
                            );
                        }
                    }

                    continue;
                }

                var buf: [4]u8 = undefined;
                const char = if (cell.cell.char > 0) cell.cell.char else ' ';
                count += try std.unicode.utf8Encode(@intCast(char), &buf);
            }
        }

        break :chars count;
    };
    const buf = try alloc.alloc(u8, chars + 1);
    errdefer alloc.free(buf);

    // Connect the text from the two slices
    const arr = [_][]StorageCell{ slices.top, slices.bot };
    var buf_i: usize = 0;
    var row_count: usize = 0;
    for (arr) |slice| {
        var row_start: usize = row_count;
        while (row_count < slices.rows) : (row_count += 1) {
            const row_i = row_count - row_start;

            // Calculate our start index. If we are beyond the length
            // of this slice, then its time to move on (we exhausted top).
            const start_idx = row_i * (self.cols + 1);
            if (start_idx >= slice.len) break;

            // Our end index is usually a full row, but if we're the final
            // row then we just use the length.
            const end_idx = @min(slice.len, start_idx + self.cols + 1);

            // We may have to skip some cells from the beginning if we're
            // the first row.
            var skip: usize = if (row_count == 0) slices.top_offset else 0;

            const row: Row = .{ .screen = self, .storage = slice[start_idx..end_idx] };
            var it = row.cellIterator();
            while (it.next()) |cell| {
                if (skip > 0) {
                    skip -= 1;
                    continue;
                }

                // Skip spacers
                if (cell.attrs.wide_spacer_head or
                    cell.attrs.wide_spacer_tail) continue;

                const char = if (cell.char > 0) cell.char else ' ';
                buf_i += try std.unicode.utf8Encode(@intCast(char), buf[buf_i..]);
            }

            // If this row is not soft-wrapped, add a newline
            if (!row.header().flags.wrap) {
                buf[buf_i] = '\n';
                buf_i += 1;
            }
        }
    }

    // Remove our trailing newline, its never correct.
    if (buf[buf_i - 1] == '\n') buf_i -= 1;

    // Remove any trailing spaces on lines. We could do optimize this by
    // doing this in the loop above but this isn't very hot path code and
    // this is simple.
    if (trim) {
        var it = std.mem.tokenize(u8, buf[0..buf_i], "\n");
        buf_i = 0;
        while (it.next()) |line| {
            const trimmed = std.mem.trimRight(u8, line, " \t");
            std.mem.copy(u8, buf[buf_i..], trimmed);
            buf_i += trimmed.len;
            buf[buf_i] = '\n';
            buf_i += 1;
        }

        // Remove our trailing newline again
        if (buf_i > 0) buf_i -= 1;
    }

    // Add null termination
    buf[buf_i] = 0;

    // Realloc so our free length is exactly correct
    const result = try alloc.realloc(buf, buf_i + 1);
    return result[0..buf_i :0];
}

/// Returns the slices that make up the selection, in order. There are at most
/// two parts to handle the ring buffer. If the selection fits in one contiguous
/// slice, then the second slice will have a length of zero.
fn selectionSlices(self: *Screen, sel_raw: Selection) struct {
    rows: usize,

    // Top offset can be used to determine if a newline is required by
    // seeing if the cell index plus the offset cleanly divides by screen cols.
    top_offset: usize,
    top: []StorageCell,
    bot: []StorageCell,
} {
    // Note: this function is tested via selectionString

    assert(sel_raw.start.y < self.rowsWritten());
    assert(sel_raw.end.y < self.rowsWritten());
    assert(sel_raw.start.x < self.cols);
    assert(sel_raw.end.x < self.cols);

    const sel = sel: {
        var sel = sel_raw;

        // If the end of our selection is a wide char leader, include the
        // first part of the next line.
        if (sel.end.x == self.cols - 1) {
            const row = self.getRow(.{ .screen = sel.end.y });
            const cell = row.getCell(sel.end.x);
            if (cell.attrs.wide_spacer_head) {
                sel.end.y += 1;
                sel.end.x = 0;
            }
        }

        // If the start of our selection is a wide char spacer, include the
        // wide char.
        if (sel.start.x > 0) {
            const row = self.getRow(.{ .screen = sel.start.y });
            const cell = row.getCell(sel.start.x);
            if (cell.attrs.wide_spacer_tail) {
                sel.end.x -= 1;
            }
        }

        break :sel sel;
    };

    // Get the true "top" and "bottom"
    const sel_top = sel.topLeft();
    const sel_bot = sel.bottomRight();

    // We get the slices for the full top and bottom (inclusive).
    const sel_top_offset = self.rowOffset(.{ .screen = sel_top.y });
    const sel_bot_offset = self.rowOffset(.{ .screen = sel_bot.y });
    const slices = self.storage.getPtrSlice(
        sel_top_offset,
        (sel_bot_offset - sel_top_offset) + (sel_bot.x + 2),
    );

    // The bottom and top are split into two slices, so we slice to the
    // bottom of the storage, then from the top.
    return .{
        .rows = sel_bot.y - sel_top.y + 1,
        .top_offset = sel_top.x,
        .top = slices[0],
        .bot = slices[1],
    };
}

/// Resize the screen without any reflow. In this mode, columns/rows will
/// be truncated as they are shrunk. If they are grown, the new space is filled
/// with zeros.
pub fn resizeWithoutReflow(self: *Screen, rows: usize, cols: usize) !void {
    const tracy = trace(@src());
    defer tracy.end();

    // If we're resizing to the same size, do nothing.
    if (self.cols == cols and self.rows == rows) return;

    // The number of no-character lines after our cursor. This is used
    // to trim those lines on a resize first without generating history.
    // This is only done if we don't have history yet.
    //
    // This matches macOS Terminal.app behavior. I chose to match that
    // behavior because it seemed fine in an ocean of differing behavior
    // between terminal apps. I'm completely open to changing it as long
    // as resize behavior isn't regressed in a user-hostile way.
    const trailing_blank_lines = blank: {
        // If we aren't changing row length, then don't bother calculating
        // because we aren't going to trim.
        if (self.rows == rows) break :blank 0;

        // If there is history, blank line counting is disabled and
        // we generate scrollback. Why? Terminal.app does it, seems... fine.
        if (self.history > 0) break :blank 0;

        break :blank self.trailingBlankLines();
    };

    // Make a copy so we can access the old indexes.
    var old = self.*;
    errdefer self.* = old;

    // Change our rows and cols so calculations make sense
    self.rows = rows;
    self.cols = cols;

    // The end of the screen is the rows we wrote minus any blank lines
    // we're trimming.
    const end_of_screen_y = old.rowsWritten() - trailing_blank_lines;

    // Calculate our buffer size. This is going to be either the old data
    // with scrollback or the max capacity of our new size. We prefer the old
    // length so we can save all the data (ignoring col truncation).
    const old_len = @max(end_of_screen_y, rows) * (cols + 1);
    const new_max_capacity = self.maxCapacity();
    const buf_size = @min(old_len, new_max_capacity);

    // Reallocate the storage
    self.storage = try StorageBuf.init(self.alloc, buf_size);
    errdefer self.storage.deinit(self.alloc);
    defer old.storage.deinit(self.alloc);

    // Our viewport and history resets to the top because we're going to
    // rewrite the screen
    self.viewport = 0;
    self.history = 0;

    // Reset our grapheme map and ensure the old one is deallocated
    // on success.
    self.graphemes = .{};
    errdefer self.deinitGraphemes();
    defer old.deinitGraphemes();

    // Rewrite all our rows
    var y: usize = 0;
    for (0..end_of_screen_y) |it_y| {
        const old_row = old.getRow(.{ .screen = it_y });

        // If we're past the end, scroll
        if (y >= self.rows) {
            // If we're shrinking rows then its possible we'll trim scrollback
            // and we have to account for how much we actually trimmed and
            // reflect that in the cursor.
            if (self.storage.len() >= self.maxCapacity()) {
                old.cursor.y -|= 1;
            }

            y -= 1;
            try self.scroll(.{ .delta = 1 });
        }

        // Get this row
        const new_row = self.getRow(.{ .active = y });
        try new_row.copyRow(old_row);

        // Next row
        y += 1;
    }

    // Convert our cursor to screen coordinates so we can preserve it.
    // The cursor is normally in active coordinates, but by converting to
    // screen we can accomodate keeping it on the same place if we retain
    // the same scrollback.
    const old_cursor_y_screen = RowIndexTag.active.index(old.cursor.y).toScreen(&old).screen;
    self.cursor.x = @min(old.cursor.x, self.cols - 1);
    self.cursor.y = if (old_cursor_y_screen <= RowIndexTag.screen.maxLen(self))
        old_cursor_y_screen -| self.history
    else
        self.rows - 1;
}

/// Resize the screen. The rows or cols can be bigger or smaller. This
/// function can only be used to resize the viewport. The scrollback size
/// (in lines) can't be changed. But due to the resize, more or less scrollback
/// "space" becomes available due to the width of lines.
///
/// Due to the internal representation of a screen, this usually involves a
/// significant amount of copying compared to any other operations.
///
/// This will trim data if the size is getting smaller. This will reflow the
/// soft wrapped text.
pub fn resize(self: *Screen, rows: usize, cols: usize) !void {
    if (self.cols == cols) {
        // No resize necessary
        if (self.rows == rows) return;

        // If we have the same number of columns, text can't possibly
        // reflow in any way, so we do the quicker thing and do a resize
        // without reflow checks.
        try self.resizeWithoutReflow(rows, cols);
        return;
    }

    // If our columns increased, we alloc space for the new column width
    // and go through each row and reflow if necessary.
    if (cols > self.cols) {
        var old = self.*;
        errdefer self.* = old;

        // Allocate enough to store our screen plus history.
        const buf_size = (self.rows + @max(self.history, self.max_scrollback)) * (cols + 1);
        self.storage = try StorageBuf.init(self.alloc, buf_size);
        errdefer self.storage.deinit(self.alloc);
        defer old.storage.deinit(self.alloc);

        // Copy grapheme map
        self.graphemes = .{};
        errdefer self.deinitGraphemes();
        defer old.deinitGraphemes();

        // Convert our cursor coordinates to screen coordinates because
        // we may have to reflow the cursor if the line it is on is unwrapped.
        const cursor_pos = (point.Viewport{
            .x = old.cursor.x,
            .y = old.cursor.y,
        }).toScreen(&old);

        // Whether we need to move the cursor or not
        var new_cursor: ?point.ScreenPoint = null;

        // Reset our variables because we're going to reprint the screen.
        self.cols = cols;
        self.viewport = 0;
        self.history = 0;

        // Iterate over the screen since we need to check for reflow.
        var iter = old.rowIterator(.screen);
        var y: usize = 0;
        while (iter.next()) |old_row| {
            // If we're past the end, scroll
            if (y >= self.rows) {
                try self.scroll(.{ .delta = 1 });
                y -= 1;
            }

            // We need to check if our cursor was on this line. If so,
            // we set the new cursor.
            if (cursor_pos.y == iter.value - 1) {
                assert(new_cursor == null); // should only happen once
                new_cursor = .{ .y = self.history + y, .x = cursor_pos.x };
            }

            // At this point, we're always at x == 0 so we can just copy
            // the row (we know old.cols < self.cols).
            var new_row = self.getRow(.{ .active = y });
            try new_row.copyRow(old_row);
            if (!old_row.header().flags.wrap) {
                // If we have no reflow, we attempt to extend any stylized
                // cells at the end of the line if there is one.
                const len = old_row.lenCells();
                const end = new_row.getCell(len - 1);
                if ((end.char == 0 or end.char == ' ') and !end.empty()) {
                    for (len..self.cols) |x| {
                        const cell = new_row.getCellPtr(x);
                        cell.* = end;
                    }
                }

                y += 1;
                continue;
            }

            // We need to reflow. At this point things get a bit messy.
            // The goal is to keep the messiness of reflow down here and
            // only reloop when we're back to clean non-wrapped lines.

            // Mark the last element as not wrapped
            new_row.setWrapped(false);

            // We maintain an x coord so that we can set cursors properly
            var x: usize = old.cols;
            wrapping: while (iter.next()) |wrapped_row| {
                // Trim the row from the right so that we ignore all trailing
                // empty chars and don't wrap them. We only do this if the
                // row is NOT wrapped again because the whitespace would be
                // meaningful.
                const wrapped_cells = trim: {
                    var i: usize = old.cols;
                    if (!wrapped_row.header().flags.wrap) {
                        while (i > 0) : (i -= 1) if (!wrapped_row.getCell(i - 1).empty()) break;
                    }
                    break :trim wrapped_row.storage[1 .. i + 1];
                };

                var wrapped_i: usize = 0;
                while (wrapped_i < wrapped_cells.len) {
                    // Remaining space in our new row
                    const new_row_rem = self.cols - x;

                    // Remaining cells in our wrapped row
                    const wrapped_cells_rem = wrapped_cells.len - wrapped_i;

                    // We copy as much as we can into our new row
                    const copy_len = @min(new_row_rem, wrapped_cells_rem);

                    // The row doesn't fit, meaning we have to soft-wrap the
                    // new row but probably at a diff boundary.
                    fastmem.copy(
                        StorageCell,
                        new_row.storage[x + 1 ..],
                        wrapped_cells[wrapped_i .. wrapped_i + copy_len],
                    );

                    // We need to check if our cursor was on this line
                    // and in the part that WAS copied. If so, we need to move it.
                    if (cursor_pos.y == iter.value - 1 and
                        cursor_pos.x < copy_len and
                        new_cursor == null)
                    {
                        new_cursor = .{ .y = self.history + y, .x = x + cursor_pos.x };
                    }

                    // We copied the full amount left in this wrapped row.
                    if (copy_len == wrapped_cells_rem) {
                        // If this row isn't also wrapped, we're done!
                        if (!wrapped_row.header().flags.wrap) {
                            y += 1;
                            break :wrapping;
                        }

                        // Wrapped again!
                        x += wrapped_cells_rem;
                        break;
                    }

                    // We still need to copy the remainder
                    wrapped_i += copy_len;

                    // Move to a new line in our new screen
                    new_row.setWrapped(true);
                    y += 1;
                    x = 0;

                    // If we're past the end, scroll
                    if (y >= self.rows) {
                        y -= 1;
                        try self.scroll(.{ .delta = 1 });
                    }
                    new_row = self.getRow(.{ .active = y });
                    new_row.setSemanticPrompt(old_row.getSemanticPrompt());
                }
            }
        }

        // If we have a new cursor, we need to convert that to a viewport
        // point and set it up.
        if (new_cursor) |pos| {
            const viewport_pos = pos.toViewport(self);
            self.cursor.x = viewport_pos.x;
            self.cursor.y = viewport_pos.y;
        }
    }

    // We grow rows after cols so that we can do our unwrapping/reflow
    // before we do a no-reflow grow.
    if (rows > self.rows) try self.resizeWithoutReflow(rows, self.cols);

    // If our rows got smaller, we trim the scrollback. We do this after
    // handling cols growing so that we can save as many lines as we can.
    // We do it before cols shrinking so we can save compute on that operation.
    if (rows < self.rows) try self.resizeWithoutReflow(rows, self.cols);

    // If our cols got smaller, we have to reflow text. This is the worst
    // possible case because we can't do any easy tricks to get reflow,
    // we just have to iterate over the screen and "print", wrapping as
    // needed.
    if (cols < self.cols) {
        var old = self.*;
        errdefer self.* = old;

        // Allocate enough to store our screen plus history.
        const buf_size = (self.rows + @max(self.history, self.max_scrollback)) * (cols + 1);
        self.storage = try StorageBuf.init(self.alloc, buf_size);
        errdefer self.storage.deinit(self.alloc);
        defer old.storage.deinit(self.alloc);

        // Copy grapheme map
        self.graphemes = .{};
        errdefer self.deinitGraphemes();
        defer old.deinitGraphemes();

        // Convert our cursor coordinates to screen coordinates because
        // we may have to reflow the cursor if the line it is on is moved.
        var cursor_pos = (point.Viewport{
            .x = old.cursor.x,
            .y = old.cursor.y,
        }).toScreen(&old);

        // Whether we need to move the cursor or not
        var new_cursor: ?point.ScreenPoint = null;

        // Reset our variables because we're going to reprint the screen.
        self.cols = cols;
        self.viewport = 0;
        self.history = 0;

        // Iterate over the screen since we need to check for reflow. We
        // clear all the trailing blank lines so that shells like zsh and
        // fish that often clear the display below don't force us to have
        // scrollback.
        var old_y: usize = 0;
        const end_y = RowIndexTag.screen.maxLen(&old) - old.trailingBlankLines();
        var y: usize = 0;
        while (old_y < end_y) : (old_y += 1) {
            const old_row = old.getRow(.{ .screen = old_y });
            const old_row_wrapped = old_row.header().flags.wrap;
            const trimmed_row = self.trimRowForResizeLessCols(&old, old_row);

            // If our y is more than our rows, we need to scroll
            if (y >= self.rows) {
                try self.scroll(.{ .delta = 1 });
                y -= 1;
            }

            // Fast path: our old row is not wrapped AND our old row fits
            // into our new smaller size. In this case, we just do a fast
            // copy and move on.
            if (!old_row_wrapped and trimmed_row.len <= self.cols) {
                // If our cursor is on this line, then set the new cursor.
                if (cursor_pos.y == old_y) {
                    assert(new_cursor == null);
                    new_cursor = .{ .x = cursor_pos.x, .y = self.history + y };
                }

                const row = self.getRow(.{ .active = y });
                row.setSemanticPrompt(old_row.getSemanticPrompt());

                fastmem.copy(
                    StorageCell,
                    row.storage[1..],
                    trimmed_row,
                );

                y += 1;
                continue;
            }

            // Slow path: the row is wrapped or doesn't fit so we have to
            // wrap ourselves. In this case, we basically just "print and wrap"
            var row = self.getRow(.{ .active = y });
            row.setSemanticPrompt(old_row.getSemanticPrompt());
            var x: usize = 0;
            var cur_old_row = old_row;
            var cur_old_row_wrapped = old_row_wrapped;
            var cur_trimmed_row = trimmed_row;
            while (true) {
                for (cur_trimmed_row, 0..) |cell, old_x| {
                    // Soft wrap if we have to.
                    if (x == self.cols) {
                        row.setWrapped(true);
                        x = 0;
                        y += 1;

                        // Wrapping can cause us to overflow our visible area.
                        // If so, scroll.
                        if (y >= self.rows) {
                            try self.scroll(.{ .delta = 1 });
                            y -= 1;
                        }

                        row = self.getRow(.{ .active = y });
                        row.setSemanticPrompt(cur_old_row.getSemanticPrompt());
                    }

                    // If our cursor is on this char, then set the new cursor.
                    if (cursor_pos.y == old_y and cursor_pos.x == old_x) {
                        assert(new_cursor == null);
                        new_cursor = .{ .x = x, .y = self.history + y };
                    }

                    // Write the cell
                    var new_cell = row.getCellPtr(x);
                    new_cell.* = cell.cell;
                    x += 1;
                }

                // If we're done wrapping, we move on.
                if (!cur_old_row_wrapped) {
                    y += 1;
                    break;
                }

                // If the old row is wrapped we continue with the loop with
                // the next row.
                old_y += 1;
                cur_old_row = old.getRow(.{ .screen = old_y });
                cur_old_row_wrapped = cur_old_row.header().flags.wrap;
                cur_trimmed_row = self.trimRowForResizeLessCols(&old, cur_old_row);
            }
        }

        // If we have a new cursor, we need to convert that to a viewport
        // point and set it up.
        if (new_cursor) |pos| {
            const viewport_pos = pos.toViewport(self);
            self.cursor.x = @min(viewport_pos.x, self.cols - 1);
            self.cursor.y = @min(viewport_pos.y, self.rows - 1);
        } else {
            // TODO: why is this necessary? Without this, neovim will
            // crash when we shrink the window to the smallest size. We
            // never got a test case to cover this.
            self.cursor.x = @min(self.cursor.x, self.cols - 1);
            self.cursor.y = @min(self.cursor.y, self.rows - 1);
        }
    }
}

/// Counts the number of trailing lines from the cursor that are blank.
/// This is specifically used for resizing and isn't meant to be a general
/// purpose tool.
fn trailingBlankLines(self: *Screen) usize {
    // Start one line below our cursor and continue to the last line
    // of the screen or however many rows we have written.
    const start = self.cursor.y + 1;
    const end = @min(self.rowsWritten(), self.rows);
    if (start >= end) return 0;

    var blank: usize = 0;
    for (0..(end - start)) |i| {
        const y = end - i - 1;
        const row = self.getRow(.{ .active = y });
        if (!row.isEmpty()) break;
        blank += 1;
    }

    return blank;
}

/// When resizing to less columns, this trims the row from the right
/// so we don't unnecessarily wrap. This will freely throw away trailing
/// colored but empty (character) cells. This matches Terminal.app behavior,
/// which isn't strictly correct but seems nice.
fn trimRowForResizeLessCols(self: *Screen, old: *Screen, row: Row) []StorageCell {
    assert(old.cols > self.cols);

    // We only trim if this isn't a wrapped line. If its a wrapped
    // line we need to keep all the empty cells because they are
    // meaningful whitespace before our wrap.
    if (row.header().flags.wrap) return row.storage[1 .. old.cols + 1];

    var i: usize = old.cols;
    while (i > 0) : (i -= 1) {
        const cell = row.getCell(i - 1);
        if (!cell.empty()) {
            // If we are beyond our new width and this is just
            // an empty-character stylized cell, then we trim it.
            if (i > self.cols) {
                if (cell.char == 0 or cell.char == ' ') continue;
            }

            break;
        }
    }

    return row.storage[1 .. i + 1];
}

/// Writes a basic string into the screen for testing. Newlines (\n) separate
/// each row. If a line is longer than the available columns, soft-wrapping
/// will occur. This will automatically handle basic wide chars.
pub fn testWriteString(self: *Screen, text: []const u8) !void {
    var y: usize = self.cursor.y;
    var x: usize = self.cursor.x;

    var grapheme: struct {
        x: usize = 0,
        cell: ?*Cell = null,
    } = .{};

    const view = std.unicode.Utf8View.init(text) catch unreachable;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |c| {
        // Explicit newline forces a new row
        if (c == '\n') {
            y += 1;
            x = 0;
            grapheme = .{};
            continue;
        }

        // If we're writing past the end of the active area, scroll.
        if (y >= self.rows) {
            y -= 1;
            try self.scroll(.{ .delta = 1 });
        }

        // Get our row
        var row = self.getRow(.{ .active = y });

        // NOTE: graphemes are currently disabled
        if (false) {
            // If we have a previous cell, we check if we're part of a grapheme.
            if (grapheme.cell) |prev_cell| {
                const grapheme_break = brk: {
                    var state: i32 = 0;
                    var cp1 = @as(u21, @intCast(prev_cell.char));
                    if (prev_cell.attrs.grapheme) {
                        var it = row.codepointIterator(grapheme.x);
                        while (it.next()) |cp2| {
                            assert(!utf8proc.graphemeBreakStateful(
                                cp1,
                                cp2,
                                &state,
                            ));

                            cp1 = cp2;
                        }
                    }

                    break :brk utf8proc.graphemeBreakStateful(cp1, c, &state);
                };

                if (!grapheme_break) {
                    try row.attachGrapheme(grapheme.x, c);
                    continue;
                }
            }
        }

        const width = utf8proc.charwidth(c);
        //log.warn("c={x} width={}", .{ c, width });

        // Zero-width are attached as grapheme data.
        // NOTE: if/when grapheme clustering is ever enabled (above) this
        // is not necessary
        if (width == 0) {
            if (grapheme.cell != null) {
                try row.attachGrapheme(grapheme.x, c);
            }

            continue;
        }

        // If we're writing past the end, we need to soft wrap.
        if (x == self.cols) {
            row.setWrapped(true);
            y += 1;
            x = 0;
            if (y >= self.rows) {
                y -= 1;
                try self.scroll(.{ .delta = 1 });
            }
            row = self.getRow(.{ .active = y });
        }

        // If our character is double-width, handle it.
        assert(width == 1 or width == 2);
        switch (width) {
            1 => {
                const cell = row.getCellPtr(x);
                cell.char = @intCast(c);

                grapheme.x = x;
                grapheme.cell = cell;
            },

            2 => {
                if (x == self.cols - 1) {
                    const cell = row.getCellPtr(x);
                    cell.char = ' ';
                    cell.attrs.wide_spacer_head = true;

                    // wrap
                    row.setWrapped(true);
                    y += 1;
                    x = 0;
                    if (y >= self.rows) {
                        y -= 1;
                        try self.scroll(.{ .delta = 1 });
                    }
                    row = self.getRow(.{ .active = y });
                }

                {
                    const cell = row.getCellPtr(x);
                    cell.char = @intCast(c);
                    cell.attrs.wide = true;

                    grapheme.x = x;
                    grapheme.cell = cell;
                }

                {
                    x += 1;
                    const cell = row.getCellPtr(x);
                    cell.char = ' ';
                    cell.attrs.wide_spacer_tail = true;
                }
            },

            else => unreachable,
        }

        x += 1;
    }

    // So the cursor doesn't go off screen
    self.cursor.x = @min(x, self.cols - 1);
    self.cursor.y = y;
}

/// Turns the screen into a string. Different regions of the screen can
/// be selected using the "tag", i.e. if you want to output the viewport,
/// the scrollback, the full screen, etc.
///
/// This is only useful for testing.
pub fn testString(self: *Screen, alloc: Allocator, tag: RowIndexTag) ![]const u8 {
    const buf = try alloc.alloc(u8, self.storage.len() * 4);

    var i: usize = 0;
    var y: usize = 0;
    var rows = self.rowIterator(tag);
    while (rows.next()) |row| {
        defer y += 1;

        if (y > 0) {
            buf[i] = '\n';
            i += 1;
        }

        var cells = row.cellIterator();
        while (cells.next()) |cell| {
            // TODO: handle character after null
            if (cell.char > 0) {
                i += try std.unicode.utf8Encode(@intCast(cell.char), buf[i..]);
            }
        }
    }

    // Never render the final newline
    const str = std.mem.trimRight(u8, buf[0..i], "\n");
    return try alloc.realloc(buf, str.len);
}

test "Row: isEmpty with no data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();

    const row = s.getRow(.{ .active = 0 });
    try testing.expect(row.isEmpty());
}

test "Row: isEmpty with a character at the end" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();

    const row = s.getRow(.{ .active = 0 });
    const cell = row.getCellPtr(4);
    cell.*.char = 'A';
    try testing.expect(!row.isEmpty());
}

test "Row: isEmpty with only styled cells" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();

    const row = s.getRow(.{ .active = 0 });
    for (0..s.cols) |x| {
        const cell = row.getCellPtr(x);
        cell.*.bg = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
        cell.*.attrs.has_bg = true;
    }
    try testing.expect(row.isEmpty());
}

test "Row: clear with graphemes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();

    const row = s.getRow(.{ .active = 0 });
    try testing.expect(row.getId() > 0);
    try testing.expectEqual(@as(usize, 5), row.lenCells());
    try testing.expect(!row.header().flags.grapheme);

    // Lets add a cell with a grapheme
    {
        const cell = row.getCellPtr(2);
        cell.*.char = 'A';
        try row.attachGrapheme(2, 'B');
        try testing.expect(cell.attrs.grapheme);
        try testing.expect(row.header().flags.grapheme);
        try testing.expect(s.graphemes.count() == 1);
    }

    // Clear the row
    row.clear(.{});
    try testing.expect(!row.header().flags.grapheme);
    try testing.expect(s.graphemes.count() == 0);
}

test "Row: copy row with graphemes in destination" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();

    // Source row does NOT have graphemes
    const row_src = s.getRow(.{ .active = 0 });
    {
        const cell = row_src.getCellPtr(2);
        cell.*.char = 'A';
    }

    // Destination has graphemes
    const row = s.getRow(.{ .active = 1 });
    {
        const cell = row.getCellPtr(1);
        cell.*.char = 'B';
        try row.attachGrapheme(1, 'C');
        try testing.expect(cell.attrs.grapheme);
        try testing.expect(row.header().flags.grapheme);
        try testing.expect(s.graphemes.count() == 1);
    }

    // Copy
    try row.copyRow(row_src);
    try testing.expect(!row.header().flags.grapheme);
    try testing.expect(s.graphemes.count() == 0);
}

test "Row: copy row with graphemes in source" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();

    // Source row does NOT have graphemes
    const row_src = s.getRow(.{ .active = 0 });
    {
        const cell = row_src.getCellPtr(2);
        cell.*.char = 'A';
        try row_src.attachGrapheme(2, 'B');
        try testing.expect(cell.attrs.grapheme);
        try testing.expect(row_src.header().flags.grapheme);
        try testing.expect(s.graphemes.count() == 1);
    }

    // Destination has no graphemes
    const row = s.getRow(.{ .active = 1 });
    try row.copyRow(row_src);
    try testing.expect(row.header().flags.grapheme);
    try testing.expect(s.graphemes.count() == 2);

    row_src.clear(.{});
    try testing.expect(s.graphemes.count() == 1);
}

test "Screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();
    try testing.expect(s.rowsWritten() == 0);

    // Sanity check that our test helpers work
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try testing.expect(s.rowsWritten() == 3);
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Test the row iterator
    var count: usize = 0;
    var iter = s.rowIterator(.viewport);
    while (iter.next()) |row| {
        // Rows should be pointer equivalent to getRow
        const row_other = s.getRow(.{ .viewport = count });
        try testing.expectEqual(row.storage.ptr, row_other.storage.ptr);
        count += 1;
    }

    // Should go through all rows
    try testing.expectEqual(@as(usize, 3), count);

    // Should be able to easily clear screen
    {
        var it = s.rowIterator(.viewport);
        while (it.next()) |row| row.fill(.{ .char = 'A' });
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("AAAAA\nAAAAA\nAAAAA", contents);
    }
}

test "Screen: write graphemes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();

    // Sanity check that our test helpers work
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x1F44D, buf[buf_idx..]); // Thumbs up plain
    buf_idx += try std.unicode.utf8Encode(0x1F44D, buf[buf_idx..]); // Thumbs up plain
    buf_idx += try std.unicode.utf8Encode(0x1F3FD, buf[buf_idx..]); // Medium skin tone

    // Note the assertions below are NOT the correct way to handle graphemes
    // in general, but they're "correct" for historical purposes for terminals.
    // For terminals, all double-wide codepoints are counted as part of the
    // width.

    try s.testWriteString(buf[0..buf_idx]);
    try testing.expect(s.rowsWritten() == 2);
    try testing.expectEqual(@as(usize, 2), s.cursor.x);
}

test "Screen: write long emoji" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 30, 0);
    defer s.deinit();

    // Sanity check that our test helpers work
    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x1F9D4, buf[buf_idx..]); // man: beard
    buf_idx += try std.unicode.utf8Encode(0x1F3FB, buf[buf_idx..]); // light skin tone (Fitz 1-2)
    buf_idx += try std.unicode.utf8Encode(0x200D, buf[buf_idx..]); // ZWJ
    buf_idx += try std.unicode.utf8Encode(0x2642, buf[buf_idx..]); // male sign
    buf_idx += try std.unicode.utf8Encode(0xFE0F, buf[buf_idx..]); // emoji representation

    // Note the assertions below are NOT the correct way to handle graphemes
    // in general, but they're "correct" for historical purposes for terminals.
    // For terminals, all double-wide codepoints are counted as part of the
    // width.

    try s.testWriteString(buf[0..buf_idx]);
    try testing.expect(s.rowsWritten() == 1);
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
}

test "Screen: scrolling" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try testing.expect(s.viewportIsBottom());

    // Scroll down, should still be bottom
    try s.scroll(.{ .delta = 1 });
    try testing.expect(s.viewportIsBottom());

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom does nothing
    try s.scroll(.{ .bottom = {} });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

test "Screen: scroll down from 0" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Scrolling up does nothing, but allows it
    try s.scroll(.{ .delta = -1 });
    try testing.expect(s.viewportIsBottom());

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}

test "Screen: scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 1);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try s.scroll(.{ .delta = 1 });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom
    try s.scroll(.{ .bottom = {} });
    try testing.expect(s.viewportIsBottom());

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling back should make it visible again
    try s.scroll(.{ .delta = -1 });
    try testing.expect(!s.viewportIsBottom());

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scrolling back again should do nothing
    try s.scroll(.{ .delta = -1 });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom
    try s.scroll(.{ .bottom = {} });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling forward with no grow should do nothing
    try s.scroll(.{ .delta_no_grow = 1 });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the top should work
    try s.scroll(.{ .top = {} });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Should be able to easily clear active area only
    var it = s.rowIterator(.active);
    while (it.next()) |row| row.clear(.{});
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }

    // Scrolling to the bottom
    try s.scroll(.{ .bottom = {} });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

test "Screen: scrollback with large delta" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 3);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH\n6IJKL");
    try testing.expect(s.viewportIsBottom());

    // Scroll to top
    try s.scroll(.{ .top = {} });
    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scroll down a ton
    try s.scroll(.{ .delta_no_grow = 5 });
    try testing.expect(s.viewportIsBottom());
    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
}

test "Screen: scrollback empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 50);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try s.scroll(.{ .delta_no_grow = 1 });

    {
        // Test our contents
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}

test "Screen: scrolling moves selection" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try testing.expect(s.viewportIsBottom());

    // Select a single line
    s.selection = .{
        .start = .{ .x = 0, .y = 1 },
        .end = .{ .x = s.cols - 1, .y = 1 },
    };

    // Scroll down, should still be bottom
    try s.scroll(.{ .delta = 1 });
    try testing.expect(s.viewportIsBottom());

    // Our selection should've moved up
    try testing.expectEqual(Selection{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = s.cols - 1, .y = 0 },
    }, s.selection.?);

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom does nothing
    try s.scroll(.{ .bottom = {} });

    // Our selection should've stayed the same
    try testing.expectEqual(Selection{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = s.cols - 1, .y = 0 },
    }, s.selection.?);

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scroll up again
    try s.scroll(.{ .delta = 1 });

    // Our selection should be null because it left the screen.
    try testing.expect(s.selection == null);
}

test "Screen: scrolling with scrollback available doesn't move selection" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 1);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try testing.expect(s.viewportIsBottom());

    // Select a single line
    s.selection = .{
        .start = .{ .x = 0, .y = 1 },
        .end = .{ .x = s.cols - 1, .y = 1 },
    };

    // Scroll down, should still be bottom
    try s.scroll(.{ .delta = 1 });
    try testing.expect(s.viewportIsBottom());

    // Our selection should NOT move since we have scrollback
    try testing.expectEqual(Selection{
        .start = .{ .x = 0, .y = 1 },
        .end = .{ .x = s.cols - 1, .y = 1 },
    }, s.selection.?);

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling back should make it visible again
    try s.scroll(.{ .delta = -1 });
    try testing.expect(!s.viewportIsBottom());

    // Our selection should NOT move since we have scrollback
    try testing.expectEqual(Selection{
        .start = .{ .x = 0, .y = 1 },
        .end = .{ .x = s.cols - 1, .y = 1 },
    }, s.selection.?);

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scroll down, this sends us off the scrollback
    try s.scroll(.{ .delta = 2 });
    try testing.expect(s.viewportIsBottom());

    // Selection should move since we went down 2
    try testing.expectEqual(Selection{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = s.cols - 1, .y = 0 },
    }, s.selection.?);

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("3IJKL", contents);
    }
}

test "Screen: history region with no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 1, 5, 0);
    defer s.deinit();

    // Write a bunch that WOULD invoke scrollback if exists
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Verify no scrollback
    var it = s.rowIterator(.history);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try testing.expect(count == 0);
}

test "Screen: history region with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 1, 5, 2);
    defer s.deinit();

    // Write a bunch that WOULD invoke scrollback if exists
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        // Test our contents
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    {
        var contents = try s.testString(alloc, .history);
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: row copy" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Copy
    try s.scroll(.{ .delta = 1 });
    try s.copyRow(.{ .active = 2 }, .{ .active = 0 });

    // Test our contents
    var contents = try s.testString(alloc, .viewport);
    defer alloc.free(contents);
    try testing.expectEqualStrings("2EFGH\n3IJKL\n2EFGH", contents);
}

test "Screen: clone" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try testing.expect(s.viewportIsBottom());

    {
        var s2 = try s.clone(alloc, .{ .active = 1 }, .{ .active = 1 });
        defer s2.deinit();

        // Test our contents rotated
        var contents = try s2.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH", contents);
    }

    {
        var s2 = try s.clone(alloc, .{ .active = 1 }, .{ .active = 2 });
        defer s2.deinit();

        // Test our contents rotated
        var contents = try s2.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

test "Screen: clone empty viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();

    {
        var s2 = try s.clone(alloc, .{ .viewport = 0 }, .{ .viewport = 0 });
        defer s2.deinit();

        // Test our contents rotated
        var contents = try s2.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

test "Screen: clone one line viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABC");

    {
        var s2 = try s.clone(alloc, .{ .viewport = 0 }, .{ .viewport = 0 });
        defer s2.deinit();

        // Test our contents rotated
        var contents = try s2.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABC", contents);
    }
}

test "Screen: clone empty active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();

    {
        var s2 = try s.clone(alloc, .{ .active = 0 }, .{ .active = 0 });
        defer s2.deinit();

        // Test our contents rotated
        var contents = try s2.testString(alloc, .active);
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

test "Screen: clone one line active with extra space" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABC");

    // Should have 1 line written
    try testing.expectEqual(@as(usize, 1), s.rowsWritten());

    {
        var s2 = try s.clone(alloc, .{ .active = 0 }, .{ .active = s.rows - 1 });
        defer s2.deinit();

        // Test our contents rotated
        var contents = try s2.testString(alloc, .active);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABC", contents);
    }

    // Should still have no history. A bug was that we were generating history
    // in this case which is not good! This was causing resizes to have all
    // sorts of problems.
    try testing.expectEqual(@as(usize, 1), s.rowsWritten());
}

test "Screen: selectLine" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();
    try s.testWriteString("ABC  DEF\n 123\n456");

    // Outside of active area
    try testing.expect(s.selectLine(.{ .x = 13, .y = 0 }) == null);
    try testing.expect(s.selectLine(.{ .x = 0, .y = 5 }) == null);

    // Going forward
    {
        const sel = s.selectLine(.{ .x = 0, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 7), sel.end.x);
        try testing.expectEqual(@as(usize, 0), sel.end.y);
    }

    // Going backward
    {
        const sel = s.selectLine(.{ .x = 7, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 7), sel.end.x);
        try testing.expectEqual(@as(usize, 0), sel.end.y);
    }

    // Going forward and backward
    {
        const sel = s.selectLine(.{ .x = 3, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 7), sel.end.x);
        try testing.expectEqual(@as(usize, 0), sel.end.y);
    }

    // Outside active area
    {
        const sel = s.selectLine(.{ .x = 9, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 7), sel.end.x);
        try testing.expectEqual(@as(usize, 0), sel.end.y);
    }
}

test "Screen: selectLine across soft-wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 5, 0);
    defer s.deinit();
    try s.testWriteString(" 12 34012   \n 123");

    // Going forward
    {
        const sel = s.selectLine(.{ .x = 1, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 1), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 3), sel.end.x);
        try testing.expectEqual(@as(usize, 1), sel.end.y);
    }
}

test "Screen: selectLine across soft-wrap ignores blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 5, 0);
    defer s.deinit();
    try s.testWriteString(" 12 34012             \n 123");

    // Going forward
    {
        const sel = s.selectLine(.{ .x = 1, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 1), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 3), sel.end.x);
        try testing.expectEqual(@as(usize, 1), sel.end.y);
    }

    // Going backward
    {
        const sel = s.selectLine(.{ .x = 1, .y = 1 }).?;
        try testing.expectEqual(@as(usize, 1), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 3), sel.end.x);
        try testing.expectEqual(@as(usize, 1), sel.end.y);
    }

    // Going forward and backward
    {
        const sel = s.selectLine(.{ .x = 3, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 1), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 3), sel.end.x);
        try testing.expectEqual(@as(usize, 1), sel.end.y);
    }
}

test "Screen: selectLine with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 2, 5);
    defer s.deinit();
    try s.testWriteString("1A\n2B\n3C\n4D\n5E");

    // Selecting first line
    {
        const sel = s.selectLine(.{ .x = 0, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 1), sel.end.x);
        try testing.expectEqual(@as(usize, 0), sel.end.y);
    }

    // Selecting last line
    {
        const sel = s.selectLine(.{ .x = 0, .y = 4 }).?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 4), sel.start.y);
        try testing.expectEqual(@as(usize, 1), sel.end.x);
        try testing.expectEqual(@as(usize, 4), sel.end.y);
    }
}

test "Screen: selectWord" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();
    try s.testWriteString("ABC  DEF\n 123\n456");

    // Outside of active area
    try testing.expect(s.selectWord(.{ .x = 9, .y = 0 }) == null);
    try testing.expect(s.selectWord(.{ .x = 0, .y = 5 }) == null);

    // Going forward
    {
        const sel = s.selectWord(.{ .x = 0, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 2), sel.end.x);
        try testing.expectEqual(@as(usize, 0), sel.end.y);
    }

    // Going backward
    {
        const sel = s.selectWord(.{ .x = 2, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 2), sel.end.x);
        try testing.expectEqual(@as(usize, 0), sel.end.y);
    }

    // Going forward and backward
    {
        const sel = s.selectWord(.{ .x = 1, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 2), sel.end.x);
        try testing.expectEqual(@as(usize, 0), sel.end.y);
    }

    // Whitespace
    {
        const sel = s.selectWord(.{ .x = 3, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 3), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 4), sel.end.x);
        try testing.expectEqual(@as(usize, 0), sel.end.y);
    }

    // Whitespace single char
    {
        const sel = s.selectWord(.{ .x = 0, .y = 1 }).?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 1), sel.start.y);
        try testing.expectEqual(@as(usize, 0), sel.end.x);
        try testing.expectEqual(@as(usize, 1), sel.end.y);
    }

    // End of screen
    {
        const sel = s.selectWord(.{ .x = 1, .y = 2 }).?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 2), sel.start.y);
        try testing.expectEqual(@as(usize, 2), sel.end.x);
        try testing.expectEqual(@as(usize, 2), sel.end.y);
    }
}

test "Screen: selectWord across soft-wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 5, 0);
    defer s.deinit();
    try s.testWriteString(" 1234012\n 123");

    // Going forward
    {
        const sel = s.selectWord(.{ .x = 1, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 1), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 2), sel.end.x);
        try testing.expectEqual(@as(usize, 1), sel.end.y);
    }

    // Going backward
    {
        const sel = s.selectWord(.{ .x = 1, .y = 1 }).?;
        try testing.expectEqual(@as(usize, 1), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 2), sel.end.x);
        try testing.expectEqual(@as(usize, 1), sel.end.y);
    }

    // Going forward and backward
    {
        const sel = s.selectWord(.{ .x = 3, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 1), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 2), sel.end.x);
        try testing.expectEqual(@as(usize, 1), sel.end.y);
    }
}

test "Screen: selectWord whitespace across soft-wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 5, 0);
    defer s.deinit();
    try s.testWriteString("1       1\n 123");

    // Going forward
    {
        const sel = s.selectWord(.{ .x = 1, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 1), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 2), sel.end.x);
        try testing.expectEqual(@as(usize, 1), sel.end.y);
    }

    // Going backward
    {
        const sel = s.selectWord(.{ .x = 1, .y = 1 }).?;
        try testing.expectEqual(@as(usize, 1), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 2), sel.end.x);
        try testing.expectEqual(@as(usize, 1), sel.end.y);
    }

    // Going forward and backward
    {
        const sel = s.selectWord(.{ .x = 3, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 1), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 2), sel.end.x);
        try testing.expectEqual(@as(usize, 1), sel.end.y);
    }
}

test "Screen: selectWord with single quote boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try s.testWriteString(" 'abc' \n123");

    // Inside quotes forward
    {
        const sel = s.selectWord(.{ .x = 2, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 2), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 4), sel.end.x);
        try testing.expectEqual(@as(usize, 0), sel.end.y);
    }

    // Inside quotes backward
    {
        const sel = s.selectWord(.{ .x = 4, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 2), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 4), sel.end.x);
        try testing.expectEqual(@as(usize, 0), sel.end.y);
    }

    // Inside quotes bidirectional
    {
        const sel = s.selectWord(.{ .x = 3, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 2), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 4), sel.end.x);
        try testing.expectEqual(@as(usize, 0), sel.end.y);
    }

    // On quote
    // NOTE: this behavior is not ideal, so we can change this one day,
    // but I think its also not that important compared to the above.
    {
        const sel = s.selectWord(.{ .x = 1, .y = 0 }).?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 1), sel.end.x);
        try testing.expectEqual(@as(usize, 0), sel.end.y);
    }
}

test "Screen: scrollRegionUp single" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    s.scrollRegionUp(.{ .active = 1 }, .{ .active = 2 }, 1);
    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n3IJKL\n\n4ABCD", contents);
    }
}

test "Screen: scrollRegionUp same line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    s.scrollRegionUp(.{ .active = 1 }, .{ .active = 1 }, 1);
    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL\n4ABCD", contents);
    }
}

test "Screen: scrollRegionUp single with pen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    s.cursor.pen = .{ .char = 'X' };
    s.scrollRegionUp(.{ .active = 1 }, .{ .active = 2 }, 1);
    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n3IJKL\nXXXXX\n4ABCD", contents);
    }
}

test "Screen: scrollRegionUp multiple" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    s.scrollRegionUp(.{ .active = 1 }, .{ .active = 3 }, 1);
    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n3IJKL\n4ABCD", contents);
    }
}

test "Screen: scrollRegionUp multiple count" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    s.scrollRegionUp(.{ .active = 1 }, .{ .active = 3 }, 2);
    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n4ABCD", contents);
    }
}

test "Screen: scrollRegionUp fills with pen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 5, 0);
    defer s.deinit();
    try s.testWriteString("A\nB\nC\nD");

    s.cursor.pen = .{ .char = 'X' };
    s.scrollRegionUp(.{ .active = 0 }, .{ .active = 2 }, 1);
    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("B\nC\nXXXXX\nD", contents);
    }
}

test "Screen: scrollRegionUp buffer wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Scroll down, should still be bottom, but should wrap because
    // we're out of space.
    try s.scroll(.{ .delta = 1 });
    s.cursor.x = 0;
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    // Scroll
    s.cursor.pen = .{ .char = 'X' };
    s.scrollRegionUp(.{ .screen = 0 }, .{ .screen = 2 }, 1);

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("3IJKL\n4ABCD\nXXXXX", contents);
    }
}

test "Screen: scrollRegionUp buffer wrap alternate" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Scroll down, should still be bottom, but should wrap because
    // we're out of space.
    try s.scroll(.{ .delta = 1 });
    s.cursor.x = 0;
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    // Scroll
    s.cursor.pen = .{ .char = 'X' };
    s.scrollRegionUp(.{ .screen = 0 }, .{ .screen = 2 }, 2);

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\nXXXXX\nXXXXX", contents);
    }
}

test "Screen: clear history with no history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 3);
    defer s.deinit();
    try s.testWriteString("4ABCD\n5EFGH\n6IJKL");
    try testing.expect(s.viewportIsBottom());
    s.clearHistory();
    try testing.expect(s.viewportIsBottom());
    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
}

test "Screen: clear history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 3);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH\n6IJKL");
    try testing.expect(s.viewportIsBottom());

    // Scroll to top
    try s.scroll(.{ .top = {} });
    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    s.clearHistory();
    try testing.expect(s.viewportIsBottom());
    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
}

test "Screen: selectionString basic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 1 },
            .end = .{ .x = 2, .y = 2 },
        }, true);
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString trim space" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1AB  \n2EFGH\n3IJKL";
    try s.testWriteString(str);

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 2, .y = 1 },
        }, true);
        defer alloc.free(contents);
        const expected = "1AB\n2EF";
        try testing.expectEqualStrings(expected, contents);
    }

    // No trim
    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 2, .y = 1 },
        }, false);
        defer alloc.free(contents);
        const expected = "1AB  \n2EF";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString trim empty line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();
    const str = "1AB  \n\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 2, .y = 2 },
        }, true);
        defer alloc.free(contents);
        const expected = "1AB\n\n2EF";
        try testing.expectEqualStrings(expected, contents);
    }

    // No trim
    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 2, .y = 2 },
        }, false);
        defer alloc.free(contents);
        const expected = "1AB  \n     \n2EF";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL";
    try s.testWriteString(str);

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 1 },
            .end = .{ .x = 2, .y = 2 },
        }, true);
        defer alloc.free(contents);
        const expected = "2EFGH3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString wrap around" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try testing.expect(s.viewportIsBottom());

    // Scroll down, should still be bottom, but should wrap because
    // we're out of space.
    try s.scroll(.{ .delta = 1 });
    try testing.expect(s.viewportIsBottom());
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 1 },
            .end = .{ .x = 2, .y = 2 },
        }, true);
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1A⚡";
    try s.testWriteString(str);

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 3, .y = 0 },
        }, true);
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 2, .y = 0 },
        }, true);
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 3, .y = 0 },
            .end = .{ .x = 3, .y = 0 },
        }, true);
        defer alloc.free(contents);
        const expected = "⚡";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString wide char with header" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABC⚡";
    try s.testWriteString(str);

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 4, .y = 0 },
        }, true);
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: dirty with getCellPtr" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try testing.expect(s.viewportIsBottom());

    // Ensure all are dirty. Clear em.
    var iter = s.rowIterator(.viewport);
    while (iter.next()) |row| {
        try testing.expect(row.isDirty());
        row.setDirty(false);
    }

    // Reset our cursor onto the second row.
    s.cursor.x = 0;
    s.cursor.y = 1;

    try s.testWriteString("foo");
    {
        const row = s.getRow(.{ .active = 0 });
        try testing.expect(!row.isDirty());
    }
    {
        const row = s.getRow(.{ .active = 1 });
        try testing.expect(row.isDirty());
    }
    {
        const row = s.getRow(.{ .active = 2 });
        try testing.expect(!row.isDirty());

        _ = row.getCell(0);
        try testing.expect(!row.isDirty());
    }
}

test "Screen: dirty with clear, fill, fillSlice, copyRow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try testing.expect(s.viewportIsBottom());

    // Ensure all are dirty. Clear em.
    var iter = s.rowIterator(.viewport);
    while (iter.next()) |row| {
        try testing.expect(row.isDirty());
        row.setDirty(false);
    }

    {
        const row = s.getRow(.{ .active = 0 });
        try testing.expect(!row.isDirty());
        row.clear(.{});
        try testing.expect(row.isDirty());
        row.setDirty(false);
    }

    {
        const row = s.getRow(.{ .active = 0 });
        try testing.expect(!row.isDirty());
        row.fill(.{ .char = 'A' });
        try testing.expect(row.isDirty());
        row.setDirty(false);
    }

    {
        const row = s.getRow(.{ .active = 0 });
        try testing.expect(!row.isDirty());
        row.fillSlice(.{ .char = 'A' }, 0, 2);
        try testing.expect(row.isDirty());
        row.setDirty(false);
    }

    {
        const src = s.getRow(.{ .active = 0 });
        const row = s.getRow(.{ .active = 1 });
        try testing.expect(!row.isDirty());
        try row.copyRow(src);
        try testing.expect(!src.isDirty());
        try testing.expect(row.isDirty());
        row.setDirty(false);
    }
}

test "Screen: dirty with graphemes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try testing.expect(s.viewportIsBottom());

    // Ensure all are dirty. Clear em.
    var iter = s.rowIterator(.viewport);
    while (iter.next()) |row| {
        try testing.expect(row.isDirty());
        row.setDirty(false);
    }

    {
        const row = s.getRow(.{ .active = 0 });
        try testing.expect(!row.isDirty());
        try row.attachGrapheme(0, 0xFE0F);
        try testing.expect(row.isDirty());
        row.setDirty(false);
        row.clearGraphemes(0);
        try testing.expect(row.isDirty());
        row.setDirty(false);
    }
}

test "Screen: resize (no reflow) more rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Clear dirty rows
    var iter = s.rowIterator(.viewport);
    while (iter.next()) |row| row.setDirty(false);

    // Resize
    try s.resizeWithoutReflow(10, 5);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Everything should be dirty
    iter = s.rowIterator(.viewport);
    while (iter.next()) |row| try testing.expect(row.isDirty());
}

test "Screen: resize (no reflow) less rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(2, 5);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

test "Screen: resize (no reflow) less rows trims blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD";
    try s.testWriteString(str);

    // Write only a background color into the remaining rows
    for (1..s.rows) |y| {
        const row = s.getRow(.{ .active = y });
        for (0..s.cols) |x| {
            const cell = row.getCellPtr(x);
            cell.*.bg = .{ .r = 0xFF, .g = 0, .b = 0 };
            cell.*.attrs.has_bg = true;
        }
    }

    // Make sure our cursor is at the end of the first line
    s.cursor.x = 4;
    s.cursor.y = 0;
    const cursor = s.cursor;

    try s.resizeWithoutReflow(2, 5);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }
}

test "Screen: resize (no reflow) more rows trims blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD";
    try s.testWriteString(str);

    // Write only a background color into the remaining rows
    for (1..s.rows) |y| {
        const row = s.getRow(.{ .active = y });
        for (0..s.cols) |x| {
            const cell = row.getCellPtr(x);
            cell.*.bg = .{ .r = 0xFF, .g = 0, .b = 0 };
            cell.*.attrs.has_bg = true;
        }
    }

    // Make sure our cursor is at the end of the first line
    s.cursor.x = 4;
    s.cursor.y = 0;
    const cursor = s.cursor;

    try s.resizeWithoutReflow(7, 5);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }
}

test "Screen: resize (no reflow) more cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(3, 10);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize (no reflow) less cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(3, 4);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABC\n2EFG\n3IJK";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize (no reflow) more rows with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 2);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(10, 5);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize (no reflow) less rows with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 2);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(2, 5);

    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize (no reflow) empty screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();
    try testing.expect(s.rowsWritten() == 0);
    try testing.expectEqual(@as(usize, 5), s.rowsCapacity());

    try s.resizeWithoutReflow(10, 10);
    try testing.expect(s.rowsWritten() == 0);

    // This is the primary test for this test, we want to ensure we
    // always have at least enough capacity for our rows.
    try testing.expectEqual(@as(usize, 10), s.rowsCapacity());
}

test "Screen: resize (no reflow) grapheme copy" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Attach graphemes to all the columns
    {
        var iter = s.rowIterator(.viewport);
        while (iter.next()) |row| {
            var col: usize = 0;
            while (col < s.cols) : (col += 1) {
                try row.attachGrapheme(col, 0xFE0F);
            }
        }
    }

    // Clear dirty rows
    {
        var iter = s.rowIterator(.viewport);
        while (iter.next()) |row| row.setDirty(false);
    }

    // Resize
    try s.resizeWithoutReflow(10, 5);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Everything should be dirty
    {
        var iter = s.rowIterator(.viewport);
        while (iter.next()) |row| try testing.expect(row.isDirty());
    }
}

test "Screen: resize (no reflow) more rows with soft wrapping" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 2, 3);
    defer s.deinit();
    const str = "1A2B\n3C4E\n5F6G";
    try s.testWriteString(str);

    // Every second row should be wrapped
    {
        var y: usize = 0;
        while (y < 6) : (y += 1) {
            const row = s.getRow(.{ .screen = y });
            const wrapped = (y % 2 == 0);
            try testing.expectEqual(wrapped, row.header().flags.wrap);
        }
    }

    // Resize
    try s.resizeWithoutReflow(10, 2);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1A\n2B\n3C\n4E\n5F\n6G";
        try testing.expectEqualStrings(expected, contents);
    }

    // Every second row should be wrapped
    {
        var y: usize = 0;
        while (y < 6) : (y += 1) {
            const row = s.getRow(.{ .screen = y });
            const wrapped = (y % 2 == 0);
            try testing.expectEqual(wrapped, row.header().flags.wrap);
        }
    }
}

test "Screen: resize more rows no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(10, 5);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more rows with empty scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 10);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(10, 5);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more rows with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Set our cursor to be on the "4"
    s.cursor.x = 0;
    s.cursor.y = 1;
    try testing.expectEqual(@as(u32, '4'), s.getCell(.active, s.cursor.y, s.cursor.x).char);

    // Resize
    try s.resize(10, 5);

    // Cursor should still be on the "4"
    try testing.expectEqual(@as(u32, '4'), s.getCell(.active, s.cursor.y, s.cursor.x).char);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more rows and cols with wrapping" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 2, 0);
    defer s.deinit();
    const str = "1A2B\n3C4D";
    try s.testWriteString(str);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1A\n2B\n3C\n4D";
        try testing.expectEqualStrings(expected, contents);
    }

    try s.resize(10, 5);

    // Cursor should move due to wrapping
    try testing.expectEqual(@as(usize, 3), s.cursor.x);
    try testing.expectEqual(@as(usize, 1), s.cursor.y);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more cols no reflow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(3, 10);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more cols trailing background colors" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1AB";
    try s.testWriteString(str);
    const cursor = s.cursor;

    // Color our cells red
    const pen: Cell = .{ .bg = .{ .r = 0xFF }, .attrs = .{ .has_bg = true } };
    for (s.cursor.x..s.cols) |x| {
        const row = s.getRow(.{ .active = s.cursor.y });
        const cell = row.getCellPtr(x);
        cell.* = pen;
    }
    for ((s.cursor.y + 1)..s.rows) |y| {
        const row = s.getRow(.{ .active = y });
        row.fill(pen);
    }

    try s.resize(3, 10);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Verify all our trailing cells have the color
    for (s.cursor.x..s.cols) |x| {
        const row = s.getRow(.{ .active = s.cursor.y });
        const cell = row.getCellPtr(x);
        try testing.expectEqual(pen, cell.*);
    }
    for ((s.cursor.y + 1)..s.rows) |y| {
        const row = s.getRow(.{ .active = y });
        for (0..s.cols) |x| {
            const cell = row.getCellPtr(x);
            try testing.expectEqual(pen, cell.*);
        }
    }
}

test "Screen: resize more cols no reflow preserves semantic prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Set one of the rows to be a prompt
    {
        const row = s.getRow(.{ .active = 1 });
        row.setSemanticPrompt(.prompt);
    }

    const cursor = s.cursor;
    try s.resize(3, 10);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Our one row should still be a semantic prompt, the others should not.
    {
        const row = s.getRow(.{ .active = 0 });
        try testing.expect(row.getSemanticPrompt() == .unknown);
    }
    {
        const row = s.getRow(.{ .active = 1 });
        try testing.expect(row.getSemanticPrompt() == .prompt);
    }
    {
        const row = s.getRow(.{ .active = 2 });
        try testing.expect(row.getSemanticPrompt() == .unknown);
    }
}

test "Screen: resize more cols grapheme map" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Attach graphemes to all the columns
    {
        var iter = s.rowIterator(.viewport);
        while (iter.next()) |row| {
            var col: usize = 0;
            while (col < s.cols) : (col += 1) {
                try row.attachGrapheme(col, 0xFE0F);
            }
        }
    }

    const cursor = s.cursor;
    try s.resize(3, 10);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more cols with reflow that fits full width" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Verify we soft wrapped
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Let's put our cursor on row 2, where the soft wrap is
    s.cursor.x = 0;
    s.cursor.y = 1;
    try testing.expectEqual(@as(u32, '2'), s.getCell(.active, s.cursor.y, s.cursor.x).char);

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(3, 10);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);
}

test "Screen: resize more cols with reflow that ends in newline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 6, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Verify we soft wrapped
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABCD2\nEFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Let's put our cursor on the last row
    s.cursor.x = 0;
    s.cursor.y = 2;
    try testing.expectEqual(@as(u32, '3'), s.getCell(.active, s.cursor.y, s.cursor.x).char);

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(3, 10);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Our cursor should still be on the 3
    try testing.expectEqual(@as(u32, '3'), s.getCell(.active, s.cursor.y, s.cursor.x).char);
}

test "Screen: resize more cols with reflow that forces more wrapping" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Let's put our cursor on row 2, where the soft wrap is
    s.cursor.x = 0;
    s.cursor.y = 1;
    try testing.expectEqual(@as(u32, '2'), s.getCell(.active, s.cursor.y, s.cursor.x).char);

    // Verify we soft wrapped
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(3, 7);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABCD2E\nFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);
}

test "Screen: resize more cols with reflow that unwraps multiple times" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL";
    try s.testWriteString(str);

    // Let's put our cursor on row 2, where the soft wrap is
    s.cursor.x = 0;
    s.cursor.y = 2;
    try testing.expectEqual(@as(u32, '3'), s.getCell(.active, s.cursor.y, s.cursor.x).char);

    // Verify we soft wrapped
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(3, 15);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABCD2EFGH3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(usize, 10), s.cursor.x);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);
}

test "Screen: resize more cols with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD5EFGH";
    try s.testWriteString(str);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // // Set our cursor to be on the "5"
    s.cursor.x = 0;
    s.cursor.y = 2;
    try testing.expectEqual(@as(u32, '5'), s.getCell(.active, s.cursor.y, s.cursor.x).char);

    // Resize
    try s.resize(3, 10);

    // Cursor should still be on the "5"
    log.warn("cursor={}", .{s.cursor});
    try testing.expectEqual(@as(u32, '5'), s.getCell(.active, s.cursor.y, s.cursor.x).char);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJKL\n4ABCD5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize more cols with reflow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 2, 5);
    defer s.deinit();
    const str = "1ABC\n2DEF\n3ABC\n4DEF";
    try s.testWriteString(str);

    // Let's put our cursor on row 2, where the soft wrap is
    s.cursor.x = 0;
    s.cursor.y = 2;
    try testing.expectEqual(@as(u32, 'E'), s.getCell(.active, s.cursor.y, s.cursor.x).char);

    // Verify we soft wrapped
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "BC\n4D\nEF";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(3, 7);

    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "1ABC\n2DEF\n3ABC\n4DEF";
        try testing.expectEqualStrings(expected, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(usize, 2), s.cursor.x);
    try testing.expectEqual(@as(usize, 2), s.cursor.y);
}

test "Screen: resize less rows no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    s.cursor.x = 0;
    s.cursor.y = 0;
    const cursor = s.cursor;
    try s.resize(1, 5);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less rows moving cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Put our cursor on the last line
    s.cursor.x = 1;
    s.cursor.y = 2;
    try testing.expectEqual(@as(u32, 'I'), s.getCell(.active, s.cursor.y, s.cursor.x).char);

    // Resize
    try s.resize(1, 5);

    // Cursor should be on the last line
    try testing.expectEqual(@as(usize, 1), s.cursor.x);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less rows with empty scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 10);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resize(1, 5);

    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less rows with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize
    try s.resize(1, 5);

    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less rows with full scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 3);
    defer s.deinit();
    const str = "00000\n1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    const cursor = s.cursor;
    try testing.expectEqual(Cursor{ .x = 4, .y = 2 }, cursor);

    // Resize
    try s.resize(2, 5);

    // Cursor should stay in the same relative place (bottom of the
    // screen, same character).
    try testing.expectEqual(Cursor{ .x = 4, .y = 1 }, s.cursor);

    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less cols no reflow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1AB\n2EF\n3IJ";
    try s.testWriteString(str);
    s.cursor.x = 0;
    s.cursor.y = 0;
    const cursor = s.cursor;
    try s.resize(3, 3);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize less cols trailing background colors" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 10, 0);
    defer s.deinit();
    const str = "1AB";
    try s.testWriteString(str);
    const cursor = s.cursor;

    // Color our cells red
    const pen: Cell = .{ .bg = .{ .r = 0xFF }, .attrs = .{ .has_bg = true } };
    for (s.cursor.x..s.cols) |x| {
        const row = s.getRow(.{ .active = s.cursor.y });
        const cell = row.getCellPtr(x);
        cell.* = pen;
    }
    for ((s.cursor.y + 1)..s.rows) |y| {
        const row = s.getRow(.{ .active = y });
        row.fill(pen);
    }

    try s.resize(3, 5);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Verify all our trailing cells have the color
    for (s.cursor.x..s.cols) |x| {
        const row = s.getRow(.{ .active = s.cursor.y });
        const cell = row.getCellPtr(x);
        try testing.expectEqual(pen, cell.*);
    }
}

test "Screen: resize less cols with graphemes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1AB\n2EF\n3IJ";
    try s.testWriteString(str);

    // Attach graphemes to all the columns
    {
        var iter = s.rowIterator(.viewport);
        while (iter.next()) |row| {
            var col: usize = 0;
            while (col < 3) : (col += 1) {
                try row.attachGrapheme(col, 0xFE0F);
            }
        }
    }

    s.cursor.x = 0;
    s.cursor.y = 0;
    const cursor = s.cursor;
    try s.resize(3, 3);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize less cols no reflow preserves semantic prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1AB\n2EF\n3IJ";
    try s.testWriteString(str);

    // Set one of the rows to be a prompt
    {
        const row = s.getRow(.{ .active = 1 });
        row.setSemanticPrompt(.prompt);
    }

    s.cursor.x = 0;
    s.cursor.y = 0;
    const cursor = s.cursor;
    try s.resize(3, 3);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Our one row should still be a semantic prompt, the others should not.
    {
        const row = s.getRow(.{ .active = 0 });
        try testing.expect(row.getSemanticPrompt() == .unknown);
    }
    {
        const row = s.getRow(.{ .active = 1 });
        try testing.expect(row.getSemanticPrompt() == .prompt);
    }
    {
        const row = s.getRow(.{ .active = 2 });
        try testing.expect(row.getSemanticPrompt() == .unknown);
    }
}

test "Screen: resize less cols with reflow but row space" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD";
    try s.testWriteString(str);

    // Put our cursor on the end
    s.cursor.x = 4;
    s.cursor.y = 0;
    try testing.expectEqual(@as(u32, 'D'), s.getCell(.active, s.cursor.y, s.cursor.x).char);

    try s.resize(3, 3);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1AB\nCD";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "1AB\nCD";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(usize, 1), s.cursor.x);
    try testing.expectEqual(@as(usize, 1), s.cursor.y);
}

test "Screen: resize less cols with reflow with trimmed rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(3, 3);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less cols with reflow with trimmed rows and scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 1);
    defer s.deinit();
    const str = "3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(3, 3);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "4AB\nCD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less cols with reflow previously wrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "3IJKL4ABCD5EFGH";
    try s.testWriteString(str);

    // Check
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    try s.resize(3, 3);

    // {
    //     var contents = try s.testString(alloc, .viewport);
    //     defer alloc.free(contents);
    //     const expected = "CD\n5EF\nGH";
    //     try testing.expectEqualStrings(expected, contents);
    // }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "ABC\nD5E\nFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize less cols with reflow and scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit();
    const str = "1A\n2B\n3C\n4D\n5E";
    try s.testWriteString(str);

    // Put our cursor on the end
    s.cursor.x = 1;
    s.cursor.y = s.rows - 1;
    try testing.expectEqual(@as(u32, 'E'), s.getCell(.active, s.cursor.y, s.cursor.x).char);

    try s.resize(3, 3);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3C\n4D\n5E";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(usize, 1), s.cursor.x);
    try testing.expectEqual(@as(usize, 2), s.cursor.y);
}

test "Screen: resize less cols with reflow previously wrapped and scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 2);
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL4ABCD5EFGH";
    try s.testWriteString(str);

    // Check
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Put our cursor on the end
    s.cursor.x = s.cols - 1;
    s.cursor.y = s.rows - 1;
    try testing.expectEqual(@as(u32, 'H'), s.getCell(.active, s.cursor.y, s.cursor.x).char);

    try s.resize(3, 3);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "CD5\nEFG\nH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "JKL\n4AB\nCD5\nEFG\nH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(u32, 'H'), s.getCell(.active, s.cursor.y, s.cursor.x).char);
    try testing.expectEqual(@as(usize, 0), s.cursor.x);
    try testing.expectEqual(@as(usize, 2), s.cursor.y);
}

test "Screen: resize more rows, less cols with reflow with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 3);
    defer s.deinit();
    const str = "1ABCD\n2EFGH3IJKL\n4MNOP";
    try s.testWriteString(str);

    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL\n4MNOP";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJKL\n4MNOP";
        try testing.expectEqualStrings(expected, contents);
    }

    try s.resize(10, 2);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "BC\nD\n2E\nFG\nH3\nIJ\nKL\n4M\nNO\nP";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "1A\nBC\nD\n2E\nFG\nH3\nIJ\nKL\n4M\nNO\nP";
        try testing.expectEqualStrings(expected, contents);
    }
}

// This seems like it should work fine but for some reason in practice
// in the initial implementation I found this bug! This is a regression
// test for that.
test "Screen: resize more rows then shrink again" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 10);
    defer s.deinit();
    const str = "1ABC";
    try s.testWriteString(str);

    // Grow
    try s.resize(10, 5);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Shrink
    try s.resize(3, 5);
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Grow again
    try s.resize(10, 5);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}
