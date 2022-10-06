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
const color = @import("color.zig");
const point = @import("point.zig");
const CircBuf = @import("circ_buf.zig").CircBuf;
const Selection = @import("Selection.zig");

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
    } = .{},
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

    /// On/off attributes that can be set
    attrs: packed struct {
        has_bg: bool = false,
        has_fg: bool = false,

        bold: bool = false,
        faint: bool = false,
        underline: bool = false,
        inverse: bool = false,
        strikethrough: bool = false,

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
        return self.char == 0 and @bitCast(AttrInt, self.attrs) == 0;
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
        //log.warn("CELL={} {}", .{ @sizeOf(Cell), @alignOf(Cell) });
        try std.testing.expectEqual(12, @sizeOf(Cell));
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

    /// Retrieve the header for this row.
    pub fn header(self: Row) RowHeader {
        return self.storage[0].header;
    }

    /// Returns the number of cells in this row.
    pub fn lenCells(self: Row) usize {
        return self.storage.len - 1;
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
            std.mem.set(StorageCell, self.storage[start + 1 .. len + 1], .{ .cell = cell });
            return;
        }

        // We have graphemes, so we have to clear those first.
        for (self.storage[start + 1 .. len + 1]) |*storage_cell, x| {
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
        _ = self.screen.graphemes.remove(key);
    }

    /// Copy the row src into this row. The row can be from another screen.
    pub fn copyRow(self: Row, src: Row) !void {
        // If we have graphemes, clear first to unset them.
        if (self.storage[0].header.flags.grapheme) self.clear(.{});

        // Always mark the row as dirty for this.
        self.storage[0].header.flags.dirty = true;

        // If the source has no graphemes (likely) then this is fast.
        const end = @minimum(src.storage.len, self.storage.len);
        if (!src.storage[0].header.flags.grapheme) {
            std.mem.copy(StorageCell, self.storage[1..], src.storage[1..end]);
            return;
        }

        // Source has graphemes, this is slow.
        for (src.storage[1..end]) |storage, x| {
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
        const data = self.screen.graphemes.get(key).?;
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
            .viewport => @minimum(screen.rows, screen.rowsWritten()),

            // History is all the way up to the top of our active area. If
            // we haven't filled our active area, there is no history.
            .history => screen.history,

            // Active area can be any number of rows. We ignore rows
            // written here because this is the only row index that can
            // actively grow our rows.
            .active => screen.rows,
            //TODO .active => @minimum(rows_written, screen.rows),
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
            .one => |v| self.* = .{ .two = .{ v, cp } },
            .two => |v| self.* = .{ .three = .{ v[0], v[1], cp } },
            .three => |v| self.* = .{ .four = .{ v[0], v[1], v[2], cp } },
            .four => |v| {
                const many = try alloc.alloc(u21, 5);
                std.mem.copy(u21, many, &v);
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
    const buf_size = (rows + @minimum(max_scrollback, rows)) * (cols + 1);

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

    var grapheme_it = self.graphemes.valueIterator();
    while (grapheme_it.next()) |data| if (data.* == .many) self.alloc.free(data.many);
    self.graphemes.deinit(self.alloc);
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
        self.next_row_id +%= @intCast(Id, self.cols);

        // Store the header
        row.storage[0].header.id = id;

        // Mark that we're dirty since we're a new row
        row.storage[0].header.flags.dirty = true;

        // We only need to fill with runtime safety because unions are
        // tag-checked. Otherwise, the default value of zero will be valid.
        if (std.debug.runtime_safety) row.fill(.{});
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
    // If we're scrolling up, then we just subtract and we're done.
    // We just clamp at 0 which blocks us from scrolling off the top.
    if (delta < 0) {
        self.viewport -|= @intCast(usize, -delta);
        return;
    }

    // If we're scrolling down and not growing, then we just
    // add to the viewport and clamp at the bottom.
    if (!grow) {
        self.viewport = @minimum(
            self.history,
            self.viewport + @intCast(usize, delta),
        );
        return;
    }

    // Add our delta to our viewport. If we're less than the max currently
    // allowed to scroll to the bottom (the end of the history), then we
    // have space and we just return.
    self.viewport += @intCast(usize, delta);
    if (self.viewport <= self.history) return;

    // If our viewport is past the top of our history then we potentially need
    // to write more blank rows. If our viewport is more than our rows written
    // then we expand out to there.
    const rows_written = self.rowsWritten();
    const viewport_bottom = self.viewport + self.rows;
    if (viewport_bottom > rows_written) {
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
                const needed_capacity = @maximum(
                    rows_final * (self.cols + 1),
                    @minimum(self.storage.capacity() * 2, max_capacity),
                );

                // Allocate what we can.
                try self.storage.resize(
                    self.alloc,
                    @minimum(max_capacity, needed_capacity),
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
}

/// Returns the raw text associated with a selection. This will unwrap
/// soft-wrapped edges. The returned slice is owned by the caller and allocated
/// using alloc, not the allocator associated with the screen (unless they match).
pub fn selectionString(self: *Screen, alloc: Allocator, sel: Selection) ![:0]const u8 {
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
            for (slice) |cell, i| {
                // detect row headers
                if (@mod(i, self.cols + 1) == 0) {
                    // We use each row header as an opportunity to "count"
                    // a new row, and therefore count a possible newline.
                    count += 1;
                    continue;
                }

                var buf: [4]u8 = undefined;
                const char = if (cell.cell.char > 0) cell.cell.char else ' ';
                count += try std.unicode.utf8Encode(@intCast(u21, char), &buf);
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
            const end_idx = @minimum(slice.len, start_idx + self.cols + 1);

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
                buf_i += try std.unicode.utf8Encode(@intCast(u21, char), buf[buf_i..]);
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

    // Make a copy so we can access the old indexes.
    var old = self.*;
    errdefer self.* = old;

    // Change our rows and cols so calculations make sense
    self.rows = rows;
    self.cols = cols;

    // Calculate our buffer size. This is going to be either the old data
    // with scrollback or the max capacity of our new size. We prefer the old
    // length so we can save all the data (ignoring col truncation).
    const old_len = @maximum(old.rowsWritten(), rows) * (cols + 1);
    const new_max_capacity = self.maxCapacity();
    const buf_size = @minimum(old_len, new_max_capacity);

    // Reallocate the storage
    self.storage = try StorageBuf.init(self.alloc, buf_size);
    errdefer self.storage.deinit(self.alloc);
    defer old.storage.deinit(self.alloc);

    // Our viewport and history resets to the top because we're going to
    // rewrite the screen
    self.viewport = 0;
    self.history = 0;

    // Rewrite all our rows
    var y: usize = 0;
    var row_it = old.rowIterator(.screen);
    while (row_it.next()) |old_row| {
        // If we're past the end, scroll
        if (y >= self.rows) {
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
    self.cursor.x = @minimum(old.cursor.x, self.cols - 1);
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

    // We grow rows first so we can make space for more reflow
    if (rows > self.rows) try self.resizeWithoutReflow(rows, cols);

    // If our columns increased, we alloc space for the new column width
    // and go through each row and reflow if necessary.
    if (cols > self.cols) {
        var old = self.*;
        errdefer self.* = old;

        // Allocate enough to store our screen plus history.
        const buf_size = (self.rows + @maximum(self.history, self.max_scrollback)) * (cols + 1);
        self.storage = try StorageBuf.init(self.alloc, buf_size);
        errdefer self.storage.deinit(self.alloc);
        defer old.storage.deinit(self.alloc);

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
                y -= 1;
                try self.scroll(.{ .delta = 1 });
            }

            // Get this row
            var new_row = self.getRow(.{ .active = y });
            try new_row.copyRow(old_row);

            // We need to check if our cursor was on this line. If so,
            // we set the new cursor.
            if (cursor_pos.y == iter.value - 1) {
                assert(new_cursor == null); // should only happen once
                new_cursor = .{ .y = self.rowsWritten() - 1, .x = cursor_pos.x };
            }

            // If no reflow, just keep going
            if (!old_row.header().flags.wrap) {
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
                // empty chars and don't wrap them.
                const wrapped_cells = trim: {
                    var i: usize = old.cols;
                    while (i > 0) : (i -= 1) if (!wrapped_row.getCell(i - 1).empty()) break;
                    break :trim wrapped_row.storage[1 .. i + 1];
                };

                var wrapped_i: usize = 0;
                while (wrapped_i < wrapped_cells.len) {
                    // Remaining space in our new row
                    const new_row_rem = self.cols - x;

                    // Remaining cells in our wrapped row
                    const wrapped_cells_rem = wrapped_cells.len - wrapped_i;

                    // We copy as much as we can into our new row
                    const copy_len = @minimum(new_row_rem, wrapped_cells_rem);

                    // The row doesn't fit, meaning we have to soft-wrap the
                    // new row but probably at a diff boundary.
                    std.mem.copy(
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
                        new_cursor = .{ .y = self.rowsWritten() - 1, .x = x + cursor_pos.x };
                    }

                    // We copied the full amount left in this wrapped row.
                    if (copy_len == wrapped_cells_rem) {
                        // If this row isn't also wrapped, we're done!
                        if (!wrapped_row.header().flags.wrap) {
                            // If we were able to copy the entire row then
                            // we shortened the screen by one. We need to reflect
                            // this in our viewport.
                            if (wrapped_i == 0 and old.viewport > 0) old.viewport -= 1;

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
                }
            }

            self.viewport = old.viewport;
        }

        // If we have a new cursor, we need to convert that to a viewport
        // point and set it up.
        if (new_cursor) |pos| {
            const viewport_pos = pos.toViewport(self);
            self.cursor.x = viewport_pos.x;
            self.cursor.y = viewport_pos.y;
        }
    }

    // If our rows got smaller, we trim the scrollback. We do this after
    // handling cols growing so that we can save as many lines as we can.
    // We do it before cols shrinking so we can save compute on that operation.
    if (rows < self.rows) try self.resizeWithoutReflow(rows, cols);

    // If our cols got smaller, we have to reflow text. This is the worst
    // possible case because we can't do any easy tricks to get reflow,
    // we just have to iterate over the screen and "print", wrapping as
    // needed.
    if (cols < self.cols) {
        var old = self.*;
        errdefer self.* = old;

        // Allocate enough to store our screen plus history.
        const buf_size = (self.rows + @maximum(self.history, self.max_scrollback)) * (cols + 1);
        self.storage = try StorageBuf.init(self.alloc, buf_size);
        errdefer self.storage.deinit(self.alloc);
        defer old.storage.deinit(self.alloc);

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

        // Iterate over the screen since we need to check for reflow.
        var iter = old.rowIterator(.screen);
        var x: usize = 0;
        var y: usize = 0;
        while (iter.next()) |old_row| {
            // Trim the row from the right so that we ignore all trailing
            // empty chars and don't wrap them.
            const trimmed_row = trim: {
                var i: usize = old.cols;
                while (i > 0) : (i -= 1) if (!old_row.getCell(i - 1).empty()) break;
                break :trim old_row.storage[1 .. i + 1];
            };

            // Copy all the cells into our row.
            for (trimmed_row) |cell, i| {
                // Soft wrap if we have to
                if (x == self.cols) {
                    var row = self.getRow(.{ .active = y });
                    row.setWrapped(true);
                    x = 0;
                    y += 1;
                }

                // If our y is more than our rows, we need to scroll
                if (y >= self.rows) {
                    try self.scroll(.{ .delta = 1 });
                    y = self.rows - 1;
                    x = 0;
                }

                // If our cursor is on this point, we need to move it.
                if (cursor_pos.y == iter.value - 1 and
                    cursor_pos.x == i)
                {
                    assert(new_cursor == null);
                    new_cursor = .{ .x = x, .y = self.viewport + y };
                }

                // Copy the old cell, unset the old wrap state
                // log.warn("y={} x={} rows={}", .{ y, x, self.rows });
                var new_cell = self.getCellPtr(.active, y, x);
                new_cell.* = cell.cell;

                // Next
                x += 1;
            }

            // If our cursor is on this line but not in a content area,
            // then we just set it to be at the end.
            if (cursor_pos.y == iter.value - 1 and
                cursor_pos.x >= trimmed_row.len)
            {
                assert(new_cursor == null);
                new_cursor = .{
                    .x = @minimum(cursor_pos.x, self.cols - 1),
                    .y = self.viewport + y,
                };
            }

            // If we aren't wrapping, then move to the next row
            if (trimmed_row.len == 0 or
                !old_row.header().flags.wrap)
            {
                y += 1;
                x = 0;
            }
        }

        // If we have a new cursor, we need to convert that to a viewport
        // point and set it up.
        if (new_cursor) |pos| {
            const viewport_pos = pos.toViewport(self);
            self.cursor.x = @minimum(viewport_pos.x, self.cols - 1);
            self.cursor.y = @minimum(viewport_pos.y, self.rows - 1);
        } else {
            // TODO: why is this necessary? Without this, neovim will
            // crash when we shrink the window to the smallest size. We
            // never got a test case to cover this.
            self.cursor.x = @minimum(self.cursor.x, self.cols - 1);
            self.cursor.y = @minimum(self.cursor.y, self.rows - 1);
        }
    }
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
                    var cp1 = @intCast(u21, prev_cell.char);
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
                cell.char = @intCast(u32, c);

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
                    cell.char = @intCast(u32, c);
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
    self.cursor.x = @minimum(x, self.cols - 1);
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
                i += try std.unicode.utf8Encode(@intCast(u21, cell.char), buf[i..]);
            }
        }
    }

    // Never render the final newline
    const str = std.mem.trimRight(u8, buf[0..i], "\n");
    return try alloc.realloc(buf, str.len);
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

test "Screen: selectionString" {
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
        });
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJ";
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
        });
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
        });
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
        });
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 2, .y = 0 },
        });
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 3, .y = 0 },
            .end = .{ .x = 3, .y = 0 },
        });
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
        });
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
