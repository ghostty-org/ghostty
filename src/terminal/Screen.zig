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
//!   * Row - A single visible row in the screen.
//!   * Line - A single line of text. This may map to multiple rows if
//!       the row is soft-wrapped.
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

const ziglyph = @import("ziglyph");
const ansi = @import("ansi.zig");
const modes = @import("modes.zig");
const sgr = @import("sgr.zig");
const color = @import("color.zig");
const kitty = @import("kitty.zig");
const point = @import("point.zig");
const CircBuf = @import("../circ_buf.zig").CircBuf;
const Selection = @import("Selection.zig");
const StringMap = @import("StringMap.zig");
const fastmem = @import("../fastmem.zig");
const charsets = @import("charsets.zig");

const log = std.log.scoped(.screen);

/// State required for all charset operations.
const CharsetState = struct {
    /// The list of graphical charsets by slot
    charsets: CharsetArray = CharsetArray.initFill(charsets.Charset.utf8),

    /// GL is the slot to use when using a 7-bit printable char (up to 127)
    /// GR used for 8-bit printable chars.
    gl: charsets.Slots = .G0,
    gr: charsets.Slots = .G2,

    /// Single shift where a slot is used for exactly one char.
    single_shift: ?charsets.Slots = null,

    /// An array to map a charset slot to a lookup table.
    const CharsetArray = std.EnumArray(charsets.Slots, charsets.Charset);
};

/// Cursor represents the cursor state.
pub const Cursor = struct {
    /// x, y where the cursor currently exists (0-indexed). This x/y is
    /// always the offset in the active area.
    x: usize = 0,
    y: usize = 0,

    /// The visual style of the cursor. This defaults to block because
    /// it has to default to something, but users of this struct are
    /// encouraged to set their own default.
    style: Style = .block,

    /// pen is the current cell styling to apply to new cells.
    pen: Cell = .{ .char = 0 },

    /// The last column flag (LCF) used to do soft wrapping.
    pending_wrap: bool = false,

    /// The visual style of the cursor. Whether or not it blinks
    /// is determined by mode 12 (modes.zig). This mode is synchronized
    /// with CSI q, the same as xterm.
    pub const Style = enum { bar, block, underline };

    /// Saved cursor state. This contains more than just Cursor members
    /// because additional state is stored.
    pub const Saved = struct {
        x: usize,
        y: usize,
        pen: Cell,
        pending_wrap: bool,
        origin: bool,
        charset: CharsetState,
    };
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
        prompt_continuation = 2,

        /// This line contains the input area. We don't currently track
        /// where this actually is in the line, so we just assume it is somewhere.
        input = 3,

        /// This line is the start of command output.
        command = 4,

        /// True if this is a prompt or input line.
        pub fn promptOrInput(self: SemanticPrompt) bool {
            return self == .prompt or self == .prompt_continuation or self == .input;
        }
    };
};

/// The color associated with a single cell's foreground or background.
const CellColor = union(enum) {
    none,
    indexed: u8,
    rgb: color.RGB,

    pub fn eql(self: CellColor, other: CellColor) bool {
        return switch (self) {
            .none => other == .none,
            .indexed => |i| switch (other) {
                .indexed => other.indexed == i,
                else => false,
            },
            .rgb => |rgb| switch (other) {
                .rgb => other.rgb.eql(rgb),
                else => false,
            },
        };
    }
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

    /// Foreground and background color.
    fg: CellColor = .none,
    bg: CellColor = .none,

    /// Underline color.
    /// NOTE(mitchellh): This is very rarely set so ideally we wouldn't waste
    /// cell space for this. For now its on this struct because it is convenient
    /// but we should consider a lookaside table for this.
    underline_fg: color.RGB = .{},

    /// On/off attributes that can be set
    attrs: packed struct {
        bold: bool = false,
        italic: bool = false,
        faint: bool = false,
        blink: bool = false,
        inverse: bool = false,
        invisible: bool = false,
        strikethrough: bool = false,
        underline: sgr.Attribute.Underline = .none,
        underline_color: bool = false,
        protected: bool = false,

        /// True if this is a wide character. This char takes up
        /// two cells. The following cell ALWAYS is a space.
        wide: bool = false,

        /// Notes that this only exists to be blank for a preceding
        /// wide character (tail) or following (head).
        wide_spacer_tail: bool = false,
        wide_spacer_head: bool = false,

        /// True if this cell has additional codepoints to form a complete
        /// grapheme cluster. If this is true, then the row grapheme flag must
        /// also be true. The grapheme code points can be looked up in the
        /// screen grapheme map.
        grapheme: bool = false,

        /// Returns only the attributes related to style.
        pub fn styleAttrs(self: @This()) @This() {
            var copy = self;
            copy.wide = false;
            copy.wide_spacer_tail = false;
            copy.wide_spacer_head = false;
            copy.grapheme = false;
            return copy;
        }
    } = .{},

    /// True if the cell should be skipped for drawing
    pub fn empty(self: Cell) bool {
        // Get our backing integer for our packed struct of attributes
        const AttrInt = @Type(.{ .Int = .{
            .signedness = .unsigned,
            .bits = @bitSizeOf(@TypeOf(self.attrs)),
        } });

        // We're empty if we have no char AND we have no styling
        return self.char == 0 and
            self.fg == .none and
            self.bg == .none and
            @as(AttrInt, @bitCast(self.attrs)) == 0;
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

    pub inline fn isWrapped(self: Row) bool {
        return self.storage[0].header.flags.wrap;
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
        assert(x < self.storage.len - 1);

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
        assert(x < self.storage.len - 1);

        // Our row is now dirty
        self.storage[0].header.flags.dirty = true;

        const cell = &self.storage[x + 1].cell;
        const key = self.getId() + x + 1;
        cell.attrs.grapheme = false;
        if (self.screen.graphemes.fetchRemove(key)) |kv| {
            kv.value.deinit(self.screen.alloc);
        }
    }

    /// Copy a single cell from column x in src to column x in this row.
    pub fn copyCell(self: Row, src: Row, x: usize) !void {
        const dst_cell = self.getCellPtr(x);
        const src_cell = src.getCellPtr(x);

        // If our destination has graphemes, we have to clear them.
        if (dst_cell.attrs.grapheme) self.clearGraphemes(x);
        dst_cell.* = src_cell.*;

        // If the source doesn't have any graphemes, then we can just copy.
        if (!src_cell.attrs.grapheme) return;

        // Source cell has graphemes. Copy them.
        const src_key = src.getId() + x + 1;
        const src_data = src.screen.graphemes.get(src_key) orelse return;
        const dst_key = self.getId() + x + 1;
        const dst_gop = try self.screen.graphemes.getOrPut(self.screen.alloc, dst_key);
        dst_gop.value_ptr.* = try src_data.copy(self.screen.alloc);
        self.storage[0].header.flags.grapheme = true;
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

    /// Returns the number of codepoints in the cell at column x,
    /// including the primary codepoint.
    pub fn codepointLen(self: Row, x: usize) usize {
        var it = self.codepointIterator(x);
        return it.len() + 1;
    }

    /// Read-only iterator for the grapheme codepoints in a cell. This only
    /// iterates over the EXTRA GRAPHEME codepoints and not the primary
    /// codepoint in cell.char.
    pub fn codepointIterator(self: Row, x: usize) CodepointIterator {
        const cell = &self.storage[x + 1].cell;
        if (!cell.attrs.grapheme) return .{ .data = .{ .zero = {} } };

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

    /// Returns true if this cell is the end of a grapheme cluster.
    ///
    /// NOTE: If/when "real" grapheme cluster support is in then
    /// this will be removed because every cell will represent exactly
    /// one grapheme cluster.
    pub fn graphemeBreak(self: Row, x: usize) bool {
        const cell = &self.storage[x + 1].cell;

        // Right now, if we are a grapheme, we only store ZWJs on
        // the grapheme data so that means we can't be a break.
        if (cell.attrs.grapheme) return false;

        // If we are a tail then we check our prior cell.
        if (cell.attrs.wide_spacer_tail and x > 0) {
            return self.graphemeBreak(x - 1);
        }

        // If we are a wide char, then we have to check our prior cell.
        if (cell.attrs.wide and x > 0) {
            return self.graphemeBreak(x - 1);
        }

        return true;
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

    /// Returns the number of codepoints in the iterator.
    pub fn len(self: CodepointIterator) usize {
        switch (self.data) {
            .zero => return 0,
            .one => return 1,
            .two => return 2,
            .three => return 3,
            .four => return 4,
            .many => |v| return v.len,
        }
    }

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

    pub fn reset(self: *CodepointIterator) void {
        self.i = 0;
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

/// A line represents a line of text, potentially across soft-wrapped
/// boundaries. This differs from row, which is a single physical row within
/// the terminal screen.
pub const Line = struct {
    screen: *Screen,
    tag: RowIndexTag,
    start: usize,
    len: usize,

    /// Return the string for this line.
    pub fn string(self: *const Line, alloc: Allocator) ![:0]const u8 {
        return try self.screen.selectionString(alloc, self.selection(), true);
    }

    /// Receive the string for this line along with the byte-to-point mapping.
    pub fn stringMap(self: *const Line, alloc: Allocator) !StringMap {
        return try self.screen.selectionStringMap(alloc, self.selection());
    }

    /// Return a selection that covers the entire line.
    pub fn selection(self: *const Line) Selection {
        // Get the start and end screen point.
        const start_idx = self.tag.index(self.start).toScreen(self.screen).screen;
        const end_idx = self.tag.index(self.start + (self.len - 1)).toScreen(self.screen).screen;

        // Convert the start and end screen points into a selection across
        // the entire rows. We then use selectionString because it handles
        // unwrapping, graphemes, etc.
        return .{
            .start = .{ .y = start_idx, .x = 0 },
            .end = .{ .y = end_idx, .x = self.screen.cols - 1 },
        };
    }
};

/// Iterator over textual lines within the terminal. This will unwrap
/// wrapped lines and consider them a single line.
pub const LineIterator = struct {
    row_it: RowIterator,

    pub fn next(self: *LineIterator) ?Line {
        const start = self.row_it.value;

        // Get our current row
        var row = self.row_it.next() orelse return null;
        var len: usize = 1;

        // While the row is wrapped we keep iterating over the rows
        // and incrementing the length.
        while (row.isWrapped()) {
            // Note: this orelse shouldn't happen. A wrapped row should
            // always have a next row. However, this isn't the place where
            // we want to assert that.
            row = self.row_it.next() orelse break;
            len += 1;
        }

        return .{
            .screen = self.row_it.screen,
            .tag = self.row_it.tag,
            .start = start,
            .len = len,
        };
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
saved_cursor: ?Cursor.Saved = null,

/// The selection for this screen (if any).
selection: ?Selection = null,

/// The kitty keyboard settings.
kitty_keyboard: kitty.KeyFlagStack = .{},

/// Kitty graphics protocol state.
kitty_images: kitty.graphics.ImageStorage = .{},

/// The charset state
charset: CharsetState = .{},

/// The current or most recent protected mode. Once a protection mode is
/// set, this will never become "off" again until the screen is reset.
/// The current state of whether protection attributes should be set is
/// set on the Cell pen; this is only used to determine the most recent
/// protection mode since some sequences such as ECH depend on this.
protected_mode: ansi.ProtectedMode = .off,

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
    self.kitty_images.deinit(self.alloc);
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
    // circular buffer where we might have no initialized data yet.
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
    // std.log.warn("copy bytes={}", .{src[0].len + src[1].len});
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
    return .{
        .screen = self,
        .tag = tag,
        .max = tag.maxLen(self),
    };
}

/// Returns an iterator that iterates over the lines of the screen. A line
/// is a single line of text which may wrap across multiple rows. A row
/// is a single physical row of the terminal.
pub fn lineIterator(self: *Screen, tag: RowIndexTag) LineIterator {
    return .{ .row_it = self.rowIterator(tag) };
}

/// Returns the line that contains the given point. This may be null if the
/// point is outside the screen.
pub fn getLine(self: *Screen, pt: point.ScreenPoint) ?Line {
    // If our y is outside of our written area, we have no line.
    if (pt.y >= RowIndexTag.screen.maxLen(self)) return null;
    if (pt.x >= self.cols) return null;

    // Find the starting y. We go back and as soon as we find a row that
    // isn't wrapped, we know the NEXT line is the one we want.
    const start_y: usize = if (pt.y == 0) 0 else start_y: {
        for (1..pt.y) |y| {
            const bot_y = pt.y - y;
            const row = self.getRow(.{ .screen = bot_y });
            if (!row.isWrapped()) break :start_y bot_y + 1;
        }

        break :start_y 0;
    };

    // Find the end y, which is the first row that isn't wrapped.
    const end_y = end_y: {
        for (pt.y..self.rowsWritten()) |y| {
            const row = self.getRow(.{ .screen = y });
            if (!row.isWrapped()) break :end_y y;
        }

        break :end_y self.rowsWritten() - 1;
    };

    return .{
        .screen = self,
        .tag = .screen,
        .start = start_y,
        .len = (end_y - start_y) + 1,
    };
}

/// Returns the row at the given index. This row is writable, although
/// only the active area should probably be written to.
pub fn getRow(self: *Screen, index: RowIndex) Row {
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
pub fn scrollRegionUp(self: *Screen, top: RowIndex, bottom: RowIndex, count_req: usize) void {
    // Avoid a lot of work if we're doing nothing.
    if (count_req == 0) return;

    // Convert our top/bottom to screen y values. This is the y offset
    // in the entire screen buffer.
    const top_y = top.toScreen(self).screen;
    const bot_y = bottom.toScreen(self).screen;

    // If top is outside of the range of bot, we do nothing.
    if (top_y >= bot_y) return;

    // We can only scroll up to the number of rows in the region. The "+ 1"
    // is because our y values are 0-based and count is 1-based.
    const count = @min(count_req, bot_y - top_y + 1);

    // Get the storage pointer for the full scroll region. We're going to
    // be modifying the whole thing so we get it right away.
    const height = (bot_y - top_y) + 1;
    const len = height * (self.cols + 1);
    const slices = self.storage.getPtrSlice(top_y * (self.cols + 1), len);

    // The total amount we're going to copy
    const total_copy = (height - count) * (self.cols + 1);

    // The pen we'll use for new cells (only the BG attribute is applied to new
    // cells)
    const pen: Cell = switch (self.cursor.pen.bg) {
        .none => .{},
        else => |bg| .{ .bg = bg },
    };

    // Fast-path is that we have a contiguous buffer in our circular buffer.
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
            @memset(dst, .{ .cell = pen });

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
        const src2_len = remaining;
        fastmem.move(StorageCell, dst2, src2[0..src2_len]);
        break :zero_offset .{ src_len, src2_len };
    };

    // Zero
    for (zero_offset, 0..) |offset, i| {
        if (offset >= slices[i].len) continue;

        const dst = slices[i][offset..];
        @memset(dst, .{ .cell = pen });

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

pub const ClearMode = enum {
    /// Delete all history. This will also move the viewport area to the top
    /// so that the viewport area never contains history. This does NOT
    /// change the active area.
    history,

    /// Clear all the lines above the cursor in the active area. This does
    /// not touch history.
    above_cursor,
};

/// Clear the screen contents according to the given mode.
pub fn clear(self: *Screen, mode: ClearMode) !void {
    switch (mode) {
        .history => {
            // If there is no history, do nothing.
            if (self.history == 0) return;

            // Delete all our history
            self.storage.deleteOldest(self.history * (self.cols + 1));
            self.history = 0;

            // Back to the top
            self.viewport = 0;
        },

        .above_cursor => {
            // First we copy all the rows from our cursor down to the top
            // of the active area.
            var y: usize = self.cursor.y;
            const y_max = @min(self.rows, self.rowsWritten()) - 1;
            const copy_n = (y_max - y) + 1;
            while (y <= y_max) : (y += 1) {
                const dst_y = y - self.cursor.y;
                const dst = self.getRow(.{ .active = dst_y });
                const src = self.getRow(.{ .active = y });
                try dst.copyRow(src);
            }

            // Next we want to clear all the rows below the copied amount.
            y = copy_n;
            while (y <= y_max) : (y += 1) {
                const dst = self.getRow(.{ .active = y });
                dst.clear(.{});
            }

            // Move our cursor to the top
            self.cursor.y = 0;

            // Scroll to the top of the viewport
            self.viewport = self.history;
        },
    }
}

/// Return the selection for all contents on the screen. Surrounding
/// whitespace is omitted. If there is no selection, this returns null.
pub fn selectAll(self: *Screen) ?Selection {
    const whitespace = &[_]u32{ 0, ' ', '\t' };
    const y_max = self.rowsWritten() - 1;

    const start: point.ScreenPoint = start: {
        var y: usize = 0;
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

    const end: point.ScreenPoint = end: {
        var y: usize = y_max;
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
    };

    return Selection{
        .start = start,
        .end = end,
    };
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

    // Get the current point semantic prompt state since that determines
    // boundary conditions too. This makes it so that line selection can
    // only happen within the same prompt state. For example, if you triple
    // click output, but the shell uses spaces to soft-wrap to the prompt
    // then the selection will stop prior to the prompt. See issue #1329.
    const semantic_prompt_state = self.getRow(.{ .screen = pt.y })
        .getSemanticPrompt()
        .promptOrInput();

    // The real start of the row is the first row in the soft-wrap.
    const start_row: usize = start_row: {
        if (pt.y == 0) break :start_row 0;

        var y: usize = pt.y - 1;
        while (true) {
            const current = self.getRow(.{ .screen = y });
            if (!current.header().flags.wrap) break :start_row y + 1;

            // See semantic_prompt_state comment for why
            const current_prompt = current.getSemanticPrompt().promptOrInput();
            if (current_prompt != semantic_prompt_state) break :start_row y + 1;

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

            // See semantic_prompt_state comment for why
            const current_prompt = current.getSemanticPrompt().promptOrInput();
            if (current_prompt != semantic_prompt_state) break :end_row y - 1;

            // End of the screen or not wrapped, we're done.
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

/// Select the nearest word to start point that is between start_pt and
/// end_pt (inclusive). Because it selects "nearest" to start point, start
/// point can be before or after end point.
pub fn selectWordBetween(
    self: *Screen,
    start_pt: point.ScreenPoint,
    end_pt: point.ScreenPoint,
) ?Selection {
    const dir: point.Direction = if (start_pt.before(end_pt)) .right_down else .left_up;
    var it = start_pt.iterator(self, dir);
    while (it.next()) |pt| {
        // Boundary conditions
        switch (dir) {
            .right_down => if (end_pt.before(pt)) return null,
            .left_up => if (pt.before(end_pt)) return null,
        }

        // If we found a word, then return it
        if (self.selectWord(pt)) |sel| return sel;
    }

    return null;
}

/// Select the word under the given point. A word is any consecutive series
/// of characters that are exclusively whitespace or exclusively non-whitespace.
/// A selection can span multiple physical lines if they are soft-wrapped.
///
/// This will return null if a selection is impossible. The only scenario
/// this happens is if the point pt is outside of the written screen space.
pub fn selectWord(self: *Screen, pt: point.ScreenPoint) ?Selection {
    // Boundary characters for selection purposes
    const boundary = &[_]u32{
        0,
        ' ',
        '\t',
        '\'',
        '"',
        '│',
        '`',
        '|',
        ':',
        ',',
        '(',
        ')',
        '[',
        ']',
        '{',
        '}',
        '<',
        '>',
    };

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

/// Select the command output under the given point. The limits of the output
/// are determined by semantic prompt information provided by shell integration.
/// A selection can span multiple physical lines if they are soft-wrapped.
///
/// This will return null if a selection is impossible. The only scenarios
/// this happens is if:
///  - the point pt is outside of the written screen space.
///  - the point pt is on a prompt / input line.
pub fn selectOutput(self: *Screen, pt: point.ScreenPoint) ?Selection {
    // Impossible to select anything outside of the area we've written.
    const y_max = self.rowsWritten() - 1;
    if (pt.y > y_max) return null;
    const point_row = self.getRow(.{ .screen = pt.y });
    switch (point_row.getSemanticPrompt()) {
        .input, .prompt_continuation, .prompt => {
            // Cursor on a prompt line, selection impossible
            return null;
        },
        else => {},
    }

    // Go forwards to find our end boundary
    // We are looking for input start / prompt markers
    const end: point.ScreenPoint = boundary: {
        for (pt.y..y_max + 1) |y| {
            const row = self.getRow(.{ .screen = y });
            switch (row.getSemanticPrompt()) {
                .input, .prompt_continuation, .prompt => {
                    const prev_row = self.getRow(.{ .screen = y - 1 });
                    break :boundary .{ .x = prev_row.lenCells(), .y = y - 1 };
                },
                else => {},
            }
        }

        break :boundary .{ .x = self.cols - 1, .y = y_max };
    };

    // Go backwards to find our start boundary
    // We are looking for output start markers
    const start: point.ScreenPoint = boundary: {
        var y: usize = pt.y;
        while (y > 0) : (y -= 1) {
            const row = self.getRow(.{ .screen = y });
            switch (row.getSemanticPrompt()) {
                .command => break :boundary .{ .x = 0, .y = y },
                else => {},
            }
        }
        break :boundary .{ .x = 0, .y = 0 };
    };

    return Selection{
        .start = start,
        .end = end,
    };
}

/// Returns the selection bounds for the prompt at the given point. If the
/// point is not on a prompt line, this returns null. Note that due to
/// the underlying protocol, this will only return the y-coordinates of
/// the prompt. The x-coordinates of the start will always be zero and
/// the x-coordinates of the end will always be the last column.
///
/// Note that this feature requires shell integration. If shell integration
/// is not enabled, this will always return null.
pub fn selectPrompt(self: *Screen, pt: point.ScreenPoint) ?Selection {
    // Ensure that the line the point is on is a prompt.
    const pt_row = self.getRow(.{ .screen = pt.y });
    const is_known = switch (pt_row.getSemanticPrompt()) {
        .prompt, .prompt_continuation, .input => true,
        .command => return null,

        // We allow unknown to continue because not all shells output any
        // semantic prompt information for continuation lines. This has the
        // possibility of making this function VERY slow (we look at all
        // scrollback) so we should try to avoid this in the future by
        // setting a flag or something if we have EVER seen a semantic
        // prompt sequence.
        .unknown => false,
    };

    // Find the start of the prompt.
    var saw_semantic_prompt = is_known;
    const start: usize = start: for (0..pt.y) |offset| {
        const y = pt.y - offset;
        const row = self.getRow(.{ .screen = y - 1 });
        switch (row.getSemanticPrompt()) {
            // A prompt, we continue searching.
            .prompt, .prompt_continuation, .input => saw_semantic_prompt = true,

            // See comment about "unknown" a few lines above. If we have
            // previously seen a semantic prompt then if we see an unknown
            // we treat it as a boundary.
            .unknown => if (saw_semantic_prompt) break :start y,

            // Command output or unknown, definitely not a prompt.
            .command => break :start y,
        }
    } else 0;

    // If we never saw a semantic prompt flag, then we can't trust our
    // start value and we return null. This scenario usually means that
    // semantic prompts aren't enabled via the shell.
    if (!saw_semantic_prompt) return null;

    // Find the end of the prompt.
    const end: usize = end: for (pt.y..self.rowsWritten()) |y| {
        const row = self.getRow(.{ .screen = y });
        switch (row.getSemanticPrompt()) {
            // A prompt, we continue searching.
            .prompt, .prompt_continuation, .input => {},

            // Command output or unknown, definitely not a prompt.
            .command, .unknown => break :end y - 1,
        }
    } else self.rowsWritten() - 1;

    return .{
        .start = .{ .x = 0, .y = start },
        .end = .{ .x = self.cols - 1, .y = end },
    };
}

/// Returns the change in x/y that is needed to reach "to" from "from"
/// within a prompt. If "to" is before or after the prompt bounds then
/// the result will be bounded to the prompt.
///
/// This feature requires shell integration. If shell integration is not
/// enabled, this will always return zero for both x and y (no path).
pub fn promptPath(
    self: *Screen,
    from: point.ScreenPoint,
    to: point.ScreenPoint,
) struct {
    x: isize,
    y: isize,
} {
    // Get our prompt bounds assuming "from" is at a prompt.
    const bounds = self.selectPrompt(from) orelse return .{ .x = 0, .y = 0 };

    // Get our actual "to" point clamped to the bounds of the prompt.
    const to_clamped = if (bounds.contains(to))
        to
    else if (to.before(bounds.start))
        bounds.start
    else
        bounds.end;

    // Basic math to calculate our path.
    const from_x: isize = @intCast(from.x);
    const from_y: isize = @intCast(from.y);
    const to_x: isize = @intCast(to_clamped.x);
    const to_y: isize = @intCast(to_clamped.y);
    return .{ .x = to_x - from_x, .y = to_y - from_y };
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
    /// scrolling is described: "scroll the page down". This scrolls the
    /// screen (potentially in addition to the viewport) and may therefore
    /// create more rows if necessary.
    screen: isize,

    /// This is the same as "screen" but only scrolls the viewport. The
    /// delta will be clamped at the current size of the screen and will
    /// never create new scrollback.
    viewport: isize,

    /// Scroll so the given row is in view. If the row is in the viewport,
    /// this will change nothing. If the row is outside the viewport, the
    /// viewport will change so that this row is at the top of the viewport.
    row: RowIndex,

    /// Scroll down and move all viewport contents into the scrollback
    /// so that the screen is clear. This isn't eqiuivalent to "screen" with
    /// the value set to the viewport size because this will handle the case
    /// that the viewport is not full.
    ///
    /// This will ignore empty trailing rows. An empty row is a row that
    /// has never been written to at all. A row with spaces is not empty.
    clear: void,
};

/// Scroll the screen by the given behavior. Note that this will always
/// "move" the screen. It is up to the caller to determine if they actually
/// want to do that yet (i.e. are they writing to the end of the screen
/// or not).
pub fn scroll(self: *Screen, behavior: Scroll) Allocator.Error!void {
    // No matter what, scrolling marks our image state as dirty since
    // it could move placements. If there are no placements or no images
    // this is still a very cheap operation.
    self.kitty_images.dirty = true;

    switch (behavior) {
        // Setting viewport offset to zero makes row 0 be at self.top
        // which is the top!
        .top => self.viewport = 0,

        // Bottom is the end of the history area (end of history is the
        // top of the active area).
        .bottom => self.viewport = self.history,

        // TODO: deltas greater than the entire scrollback
        .screen => |delta| try self.scrollDelta(delta, false),
        .viewport => |delta| try self.scrollDelta(delta, true),

        // Scroll to a specific row
        .row => |idx| self.scrollRow(idx),

        // Scroll until the viewport is clear by moving the viewport contents
        // into the scrollback.
        .clear => try self.scrollClear(),
    }
}

fn scrollClear(self: *Screen) Allocator.Error!void {
    // The full amount of rows in the viewport
    const full_amount = self.rowsWritten() - self.viewport;

    // Find the number of non-empty rows
    const non_empty = for (0..full_amount) |i| {
        const rev_i = full_amount - i - 1;
        const row = self.getRow(.{ .viewport = rev_i });
        if (!row.isEmpty()) break rev_i + 1;
    } else full_amount;

    try self.scroll(.{ .screen = @intCast(non_empty) });
}

fn scrollRow(self: *Screen, idx: RowIndex) void {
    // Convert the given row to a screen point.
    const screen_idx = idx.toScreen(self);
    const screen_pt: point.ScreenPoint = .{ .y = screen_idx.screen };

    // Move the viewport so that the screen point is in view. We do the
    // @min here so that we don't scroll down below where our "bottom"
    // viewport is.
    self.viewport = @min(self.history, screen_pt.y);
    assert(screen_pt.inViewport(self));
}

fn scrollDelta(self: *Screen, delta: isize, viewport_only: bool) Allocator.Error!void {
    // Just in case, to avoid a bunch of stuff below.
    if (delta == 0) return;

    // If we're scrolling up, then we just subtract and we're done.
    // We just clamp at 0 which blocks us from scrolling off the top.
    if (delta < 0) {
        self.viewport -|= @as(usize, @intCast(-delta));
        return;
    }

    // If we're scrolling only the viewport, then we just add to the viewport.
    if (viewport_only) {
        self.viewport = @min(
            self.history,
            self.viewport + @as(usize, @intCast(delta)),
        );
        return;
    }

    // Add our delta to our viewport. If we're less than the max currently
    // allowed to scroll to the bottom (the end of the history), then we
    // have space and we just return.
    const start_viewport_bottom = self.viewportIsBottom();
    const viewport = self.history + @as(usize, @intCast(delta));
    if (viewport <= self.history) return;

    // If our viewport is past the top of our history then we potentially need
    // to write more blank rows. If our viewport is more than our rows written
    // then we expand out to there.
    const rows_written = self.rowsWritten();
    const viewport_bottom = viewport + self.rows;
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
                const row = self.getRow(.{ .screen = y });
                if (row.storage[0].header.flags.grapheme) row.clear(.{});
            }
        }

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
    const slices = self.storage.getPtrSlice(
        (rows_written_final - 1) * (self.cols + 1),
        self.cols + 1,
    );
    // We should never be wrapped here
    assert(slices[1].len == 0);

    // We only grabbed our new row(s), copy cells into the whole slice
    const dst = slices[0];
    // The pen we'll use for new cells (only the BG attribute is applied to new
    // cells)
    const pen: Cell = switch (self.cursor.pen.bg) {
        .none => .{},
        else => |bg| .{ .bg = bg },
    };
    @memset(dst, .{ .cell = pen });

    // Then we make sure our row headers are zeroed out. We set
    // the value to a dirty row header so that the renderer re-draws.
    var i: usize = 0;
    while (i < dst.len) : (i += self.cols + 1) {
        dst[i] = .{ .header = .{
            .flags = .{ .dirty = true },
        } };
    }

    if (start_viewport_bottom) {
        // If our viewport is on the bottom, we always update the viewport
        // to the latest so that it remains in view.
        self.viewport = self.history;
    } else if (rows_deleted > 0) {
        // If our viewport is NOT on the bottom, we want to keep our viewport
        // where it was so that we don't jump around. However, we need to
        // subtract the final rows written if we had to delete rows since
        // that changes the viewport offset.
        self.viewport -|= rows_deleted;
    }
}

/// The options for where you can jump to on the screen.
pub const JumpTarget = union(enum) {
    /// Jump forwards (positive) or backwards (negative) a set number of
    /// prompts. If the absolute value is greater than the number of prompts
    /// in either direction, jump to the furthest prompt.
    prompt_delta: isize,
};

/// Jump the viewport to specific location.
pub fn jump(self: *Screen, target: JumpTarget) bool {
    return switch (target) {
        .prompt_delta => |delta| self.jumpPrompt(delta),
    };
}

/// Jump the viewport forwards (positive) or backwards (negative) a set number of
/// prompts (delta). Returns true if the viewport changed and false if no jump
/// occurred.
fn jumpPrompt(self: *Screen, delta: isize) bool {
    // If we aren't jumping any prompts then we don't need to do anything.
    if (delta == 0) return false;

    // The screen y value we start at
    const start_y: isize = start_y: {
        const idx: RowIndex = .{ .viewport = 0 };
        const screen = idx.toScreen(self);
        break :start_y @intCast(screen.screen);
    };

    // The maximum y in the positive direction. Negative is always 0.
    const max_y: isize = @intCast(self.rowsWritten() - 1);

    // Go line-by-line counting the number of prompts we see.
    const step: isize = if (delta > 0) 1 else -1;
    var y: isize = start_y + step;
    const delta_start: usize = @intCast(if (delta > 0) delta else -delta);
    var delta_rem: usize = delta_start;
    while (y >= 0 and y <= max_y and delta_rem > 0) : (y += step) {
        const row = self.getRow(.{ .screen = @intCast(y) });
        switch (row.getSemanticPrompt()) {
            .prompt, .prompt_continuation, .input => delta_rem -= 1,
            .command, .unknown => {},
        }
    }

    //log.warn("delta={} delta_rem={} start_y={} y={}", .{ delta, delta_rem, start_y, y });

    // If we didn't find any, do nothing.
    if (delta_rem == delta_start) return false;

    // Done! We count the number of lines we changed and scroll.
    const y_delta = (y - step) - start_y;
    const new_y: usize = @intCast(start_y + y_delta);
    const old_viewport = self.viewport;
    self.scroll(.{ .row = .{ .screen = new_y } }) catch unreachable;
    //log.warn("delta={} y_delta={} start_y={} new_y={}", .{ delta, y_delta, start_y, new_y });
    return self.viewport != old_viewport;
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

    // Use an ArrayList so that we can grow the array as we go. We
    // build an initial capacity of just our rows in our selection times
    // columns. It can be more or less based on graphemes, newlines, etc.
    var strbuilder = try std.ArrayList(u8).initCapacity(alloc, slices.rows * self.cols);
    defer strbuilder.deinit();

    // Get our string result.
    try self.selectionSliceString(slices, &strbuilder, null);

    // Remove any trailing spaces on lines. We could do optimize this by
    // doing this in the loop above but this isn't very hot path code and
    // this is simple.
    if (trim) {
        var it = std.mem.tokenizeScalar(u8, strbuilder.items, '\n');

        // Reset our items. We retain our capacity. Because we're only
        // removing bytes, we know that the trimmed string must be no longer
        // than the original string so we copy directly back into our
        // allocated memory.
        strbuilder.clearRetainingCapacity();
        while (it.next()) |line| {
            const trimmed = std.mem.trimRight(u8, line, " \t");
            const i = strbuilder.items.len;
            strbuilder.items.len += trimmed.len;
            std.mem.copyForwards(u8, strbuilder.items[i..], trimmed);
            strbuilder.appendAssumeCapacity('\n');
        }

        // Remove our trailing newline again
        if (strbuilder.items.len > 0) strbuilder.items.len -= 1;
    }

    // Get our final string
    const string = try strbuilder.toOwnedSliceSentinel(0);
    errdefer alloc.free(string);

    return string;
}

/// Returns the row text associated with a selection along with the
/// mapping of each individual byte in the string to the point in the screen.
fn selectionStringMap(
    self: *Screen,
    alloc: Allocator,
    sel: Selection,
) !StringMap {
    // Get the slices for the string
    const slices = self.selectionSlices(sel);

    // Use an ArrayList so that we can grow the array as we go. We
    // build an initial capacity of just our rows in our selection times
    // columns. It can be more or less based on graphemes, newlines, etc.
    var strbuilder = try std.ArrayList(u8).initCapacity(alloc, slices.rows * self.cols);
    defer strbuilder.deinit();
    var mapbuilder = try std.ArrayList(point.ScreenPoint).initCapacity(alloc, strbuilder.capacity);
    defer mapbuilder.deinit();

    // Get our results
    try self.selectionSliceString(slices, &strbuilder, &mapbuilder);

    // Get our final string
    const string = try strbuilder.toOwnedSliceSentinel(0);
    errdefer alloc.free(string);
    const map = try mapbuilder.toOwnedSlice();
    errdefer alloc.free(map);
    return .{ .string = string, .map = map };
}

/// Takes a SelectionSlices value and builds the string and mapping for it.
fn selectionSliceString(
    self: *Screen,
    slices: SelectionSlices,
    strbuilder: *std.ArrayList(u8),
    mapbuilder: ?*std.ArrayList(point.ScreenPoint),
) !void {
    // Connect the text from the two slices
    const arr = [_][]StorageCell{ slices.top, slices.bot };
    var row_count: usize = 0;
    for (arr) |slice| {
        const row_start: usize = row_count;
        while (row_count < slices.rows) : (row_count += 1) {
            const row_i = row_count - row_start;

            // Calculate our start index. If we are beyond the length
            // of this slice, then its time to move on (we exhausted top).
            const start_idx = row_i * (self.cols + 1);
            if (start_idx >= slice.len) break;

            const end_idx = if (slices.sel.rectangle)
                // Rectangle select: calculate end with bottom offset.
                start_idx + slices.bot_offset + 2 // think "column count" + 1
            else
                // Normal select: our end index is usually a full row, but if
                // we're the final row then we just use the length.
                @min(slice.len, start_idx + self.cols + 1);

            // We may have to skip some cells from the beginning if we're the
            // first row, of if we're using rectangle select.
            var skip: usize = if (row_count == 0 or slices.sel.rectangle) slices.top_offset else 0;

            // If we have runtime safety we need to initialize the row
            // so that the proper union tag is set. In release modes we
            // don't need to do this because we zero the memory.
            if (std.debug.runtime_safety) {
                _ = self.getRow(.{ .screen = slices.sel.start.y + row_i });
            }

            const row: Row = .{ .screen = self, .storage = slice[start_idx..end_idx] };
            var it = row.cellIterator();
            var x: usize = 0;
            while (it.next()) |cell| {
                defer x += 1;

                if (skip > 0) {
                    skip -= 1;
                    continue;
                }

                // Skip spacers
                if (cell.attrs.wide_spacer_head or
                    cell.attrs.wide_spacer_tail) continue;

                var buf: [4]u8 = undefined;
                const char = if (cell.char > 0) cell.char else ' ';
                {
                    const encode_len = try std.unicode.utf8Encode(@intCast(char), &buf);
                    try strbuilder.appendSlice(buf[0..encode_len]);
                    if (mapbuilder) |b| {
                        for (0..encode_len) |_| try b.append(.{
                            .x = x,
                            .y = slices.sel.start.y + row_i,
                        });
                    }
                }

                var cp_it = row.codepointIterator(x);
                while (cp_it.next()) |cp| {
                    const encode_len = try std.unicode.utf8Encode(cp, &buf);
                    try strbuilder.appendSlice(buf[0..encode_len]);
                    if (mapbuilder) |b| {
                        for (0..encode_len) |_| try b.append(.{
                            .x = x,
                            .y = slices.sel.start.y + row_i,
                        });
                    }
                }
            }

            // If this row is not soft-wrapped or if we're using rectangle
            // select, add a newline
            if (!row.header().flags.wrap or slices.sel.rectangle) {
                try strbuilder.append('\n');
                if (mapbuilder) |b| {
                    try b.append(.{
                        .x = self.cols - 1,
                        .y = slices.sel.start.y + row_i,
                    });
                }
            }
        }
    }

    // Remove our trailing newline, its never correct.
    if (strbuilder.items.len > 0 and
        strbuilder.items[strbuilder.items.len - 1] == '\n')
    {
        strbuilder.items.len -= 1;
        if (mapbuilder) |b| b.items.len -= 1;
    }

    if (std.debug.runtime_safety) {
        if (mapbuilder) |b| {
            assert(strbuilder.items.len == b.items.len);
        }
    }
}

const SelectionSlices = struct {
    rows: usize,

    // The selection that the slices below represent. This may not
    // be the same as the input selection since some normalization
    // occurs.
    sel: Selection,

    // Top offset can be used to determine if a newline is required by
    // seeing if the cell index plus the offset cleanly divides by screen cols.
    top_offset: usize,

    // Our bottom offset is used in rectangle select to always determine the
    // maximum cell in a given row.
    bot_offset: usize,

    // Our selection storage cell chunks.
    top: []StorageCell,
    bot: []StorageCell,
};

/// Returns the slices that make up the selection, in order. There are at most
/// two parts to handle the ring buffer. If the selection fits in one contiguous
/// slice, then the second slice will have a length of zero.
fn selectionSlices(self: *Screen, sel_raw: Selection) SelectionSlices {
    // Note: this function is tested via selectionString

    // If the selection starts beyond the end of the screen, then we return empty
    if (sel_raw.start.y >= self.rowsWritten()) return .{
        .rows = 0,
        .sel = sel_raw,
        .top_offset = 0,
        .bot_offset = 0,
        .top = self.storage.storage[0..0],
        .bot = self.storage.storage[0..0],
    };

    const sel = sel: {
        var sel = sel_raw;

        // Clamp the selection to the screen
        if (sel.end.y >= self.rowsWritten()) {
            sel.end.y = self.rowsWritten() - 1;
            sel.end.x = self.cols - 1;
        }

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
                sel.start.x -= 1;
            }
        }

        break :sel sel;
    };

    // Get the true "top" and "bottom"
    const sel_top = sel.topLeft();
    const sel_bot = sel.bottomRight();
    const sel_isRect = sel.rectangle;

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
        .sel = .{ .start = sel_top, .end = sel_bot, .rectangle = sel_isRect },
        .top_offset = sel_top.x,
        .bot_offset = sel_bot.x,
        .top = slices[0],
        .bot = slices[1],
    };
}

/// Resize the screen without any reflow. In this mode, columns/rows will
/// be truncated as they are shrunk. If they are grown, the new space is filled
/// with zeros.
pub fn resizeWithoutReflow(self: *Screen, rows: usize, cols: usize) !void {
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

        const blank = self.trailingBlankLines();

        // If we are shrinking the number of rows, we don't want to trim
        // off more blank rows than the number we're shrinking because it
        // creates a jarring screen move experience.
        if (self.rows > rows) break :blank @min(blank, self.rows - rows);

        break :blank blank;
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
            try self.scroll(.{ .screen = 1 });
        }

        // Get this row
        const new_row = self.getRow(.{ .active = y });
        try new_row.copyRow(old_row);

        // Next row
        y += 1;
    }

    // Convert our cursor to screen coordinates so we can preserve it.
    // The cursor is normally in active coordinates, but by converting to
    // screen we can accommodate keeping it on the same place if we retain
    // the same scrollback.
    const old_cursor_y_screen = RowIndexTag.active.index(old.cursor.y).toScreen(&old).screen;
    self.cursor.x = @min(old.cursor.x, self.cols - 1);
    self.cursor.y = if (old_cursor_y_screen <= RowIndexTag.screen.maxLen(self))
        old_cursor_y_screen -| self.history
    else
        self.rows - 1;

    // If our rows increased and our cursor is NOT at the bottom, we want
    // to try to preserve the y value of the old cursor. In other words, we
    // don't want to "pull down" scrollback. This is purely a UX feature.
    if (self.rows > old.rows and
        old.cursor.y < old.rows - 1 and
        self.cursor.y > old.cursor.y)
    {
        const delta = self.cursor.y - old.cursor.y;
        if (self.scroll(.{ .screen = @intCast(delta) })) {
            self.cursor.y -= delta;
        } else |err| {
            // If this scroll fails its not that big of a deal so we just
            // log and ignore.
            log.warn("failed to scroll for resize, cursor may be off err={}", .{err});
        }
    }
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

        // No matter what we mark our image state as dirty
        self.kitty_images.dirty = true;

        // If we have the same number of columns, text can't possibly
        // reflow in any way, so we do the quicker thing and do a resize
        // without reflow checks.
        try self.resizeWithoutReflow(rows, cols);
        return;
    }

    // No matter what we mark our image state as dirty
    self.kitty_images.dirty = true;

    // Keep track if our cursor is at the bottom
    const cursor_bottom = self.cursor.y == self.rows - 1;

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
        const cursor_pos = (point.Active{
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
                try self.scroll(.{ .screen = 1 });
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
                // We used to do have this behavior, but it broke some programs.
                // I know I copied this behavior while observing some other
                // terminal, but I can't remember which one. I'm leaving this
                // here in case we want to bring this back (with probably
                // slightly different behavior).
                //
                // If we have no reflow, we attempt to extend any stylized
                // cells at the end of the line if there is one.
                // const len = old_row.lenCells();
                // const end = new_row.getCell(len - 1);
                // if ((end.char == 0 or end.char == ' ') and !end.empty()) {
                //     for (len..self.cols) |x| {
                //         const cell = new_row.getCellPtr(x);
                //         cell.* = end;
                //     }
                // }

                y += 1;
                continue;
            }

            // We need to reflow. At this point things get a bit messy.
            // The goal is to keep the messiness of reflow down here and
            // only reloop when we're back to clean non-wrapped lines.

            // Mark the last element as not wrapped
            new_row.setWrapped(false);

            // x is the offset where we start copying into new_row. Its also
            // used for cursor tracking.
            var x: usize = old.cols;

            // Edge case: if the end of our old row is a wide spacer head,
            // we want to overwrite it.
            if (old_row.getCellPtr(x - 1).attrs.wide_spacer_head) x -= 1;

            wrapping: while (iter.next()) |wrapped_row| {
                const wrapped_cells = trim: {
                    var i: usize = old.cols;

                    // Trim the row from the right so that we ignore all trailing
                    // empty chars and don't wrap them. We only do this if the
                    // row is NOT wrapped again because the whitespace would be
                    // meaningful.
                    if (!wrapped_row.header().flags.wrap) {
                        while (i > 0) : (i -= 1) {
                            if (!wrapped_row.getCell(i - 1).empty()) break;
                        }
                    } else {
                        // If we are wrapped, then similar to above "edge case"
                        // we want to overwrite the wide spacer head if we end
                        // in one.
                        if (wrapped_row.getCellPtr(i - 1).attrs.wide_spacer_head) {
                            i -= 1;
                        }
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
                    const copy_len = if (new_row_rem <= wrapped_cells_rem) copy_len: {
                        // We are going to end up filling our new row. We need
                        // to check if the end of the row is a wide char and
                        // if so, we need to insert a wide char header and wrap
                        // there.
                        var proposed: usize = new_row_rem;

                        // If the end of our copy is wide, we copy one less and
                        // set the wide spacer header now since we're not going
                        // to write over it anyways.
                        if (proposed > 0 and wrapped_cells[wrapped_i + proposed - 1].cell.attrs.wide) {
                            proposed -= 1;
                            new_row.getCellPtr(x + proposed).* = .{
                                .char = ' ',
                                .attrs = .{ .wide_spacer_head = true },
                            };
                        }

                        break :copy_len proposed;
                    } else wrapped_cells_rem;

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
                        try self.scroll(.{ .screen = 1 });
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

        // Create empty grapheme map. Cell IDs change so we can't just copy it,
        // we'll rebuild it.
        self.graphemes = .{};
        errdefer self.deinitGraphemes();
        defer old.deinitGraphemes();

        // Convert our cursor coordinates to screen coordinates because
        // we may have to reflow the cursor if the line it is on is moved.
        const cursor_pos = (point.Active{
            .x = old.cursor.x,
            .y = old.cursor.y,
        }).toScreen(&old);

        // Whether we need to move the cursor or not
        var new_cursor: ?point.ScreenPoint = null;
        var new_cursor_wrap: usize = 0;

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
                try self.scroll(.{ .screen = 1 });
                y -= 1;
            }

            // Fast path: our old row is not wrapped AND our old row fits
            // into our new smaller size AND this row has no grapheme clusters.
            // In this case, we just do a fast copy and move on.
            if (!old_row_wrapped and
                trimmed_row.len <= self.cols and
                !old_row.header().flags.grapheme)
            {
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
                for (cur_trimmed_row, 0..) |old_cell, old_x| {
                    var cell: StorageCell = old_cell;

                    // This is a really wild edge case if we're resizing down
                    // to 1 column. In reality this is pretty broken for end
                    // users so downstream should prevent this.
                    if (self.cols == 1 and
                        (cell.cell.attrs.wide or
                        cell.cell.attrs.wide_spacer_head or
                        cell.cell.attrs.wide_spacer_tail))
                    {
                        cell = .{ .cell = .{ .char = ' ' } };
                    }

                    // We need to wrap wide chars with a spacer head.
                    if (cell.cell.attrs.wide and x == self.cols - 1) {
                        row.getCellPtr(x).* = .{
                            .char = ' ',
                            .attrs = .{ .wide_spacer_head = true },
                        };
                        x += 1;
                    }

                    // Soft wrap if we have to.
                    if (x == self.cols) {
                        row.setWrapped(true);
                        x = 0;
                        y += 1;

                        // Wrapping can cause us to overflow our visible area.
                        // If so, scroll.
                        if (y >= self.rows) {
                            try self.scroll(.{ .screen = 1 });
                            y -= 1;

                            // Clear if our current cell is a wide spacer tail
                            if (cell.cell.attrs.wide_spacer_tail) {
                                cell = .{ .cell = .{} };
                            }
                        }

                        if (cursor_pos.y == old_y) {
                            // If this original y is where our cursor is, we
                            // track the number of wraps we do so we can try to
                            // keep this whole line on the screen.
                            new_cursor_wrap += 1;
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
                    const new_cell = row.getCellPtr(x);
                    new_cell.* = cell.cell;

                    // If the old cell is a multi-codepoint grapheme then we
                    // need to also attach the graphemes.
                    if (cell.cell.attrs.grapheme) {
                        var it = cur_old_row.codepointIterator(old_x);
                        while (it.next()) |cp| try row.attachGrapheme(x, cp);
                    }

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

            // We want to keep our cursor y at the same place. To do so, we
            // scroll the screen. This scrolls all of the content so the cell
            // the cursor is over doesn't change.
            if (!cursor_bottom and old.cursor.y < self.cursor.y) scroll: {
                const delta: isize = delta: {
                    var delta: isize = @intCast(self.cursor.y - old.cursor.y);

                    // new_cursor_wrap is the number of times the line that the
                    // cursor was on previously was wrapped to fit this new col
                    // width. We want to scroll that many times less so that
                    // the whole line the cursor was on attempts to remain
                    // in view.
                    delta -= @intCast(new_cursor_wrap);

                    if (delta <= 0) break :scroll;
                    break :delta delta;
                };

                self.scroll(.{ .screen = delta }) catch |err| {
                    log.warn("failed to scroll for resize, cursor may be off err={}", .{err});
                    break :scroll;
                };

                self.cursor.y -= @intCast(delta);
            }
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
            // We also have to ignore wide spacers because they form
            // a critical part of a wide character.
            if (i > self.cols) {
                if ((cell.char == 0 or cell.char == ' ') and
                    !cell.attrs.wide_spacer_tail and
                    !cell.attrs.wide_spacer_head) continue;
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
            try self.scroll(.{ .screen = 1 });
        }

        // Get our row
        var row = self.getRow(.{ .active = y });

        // NOTE: graphemes are currently disabled
        if (false) {
            // If we have a previous cell, we check if we're part of a grapheme.
            if (grapheme.cell) |prev_cell| {
                const grapheme_break = brk: {
                    var state: u3 = 0;
                    var cp1 = @as(u21, @intCast(prev_cell.char));
                    if (prev_cell.attrs.grapheme) {
                        var it = row.codepointIterator(grapheme.x);
                        while (it.next()) |cp2| {
                            assert(!ziglyph.graphemeBreak(
                                cp1,
                                cp2,
                                &state,
                            ));

                            cp1 = cp2;
                        }
                    }

                    break :brk ziglyph.graphemeBreak(cp1, c, &state);
                };

                if (!grapheme_break) {
                    try row.attachGrapheme(grapheme.x, c);
                    continue;
                }
            }
        }

        const width: usize = @intCast(@max(0, ziglyph.display_width.codePointWidth(c, .half)));
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
                try self.scroll(.{ .screen = 1 });
            }
            row = self.getRow(.{ .active = y });
        }

        // If our character is double-width, handle it.
        assert(width == 1 or width == 2);
        switch (width) {
            1 => {
                const cell = row.getCellPtr(x);
                cell.* = self.cursor.pen;
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
                        try self.scroll(.{ .screen = 1 });
                    }
                    row = self.getRow(.{ .active = y });
                }

                {
                    const cell = row.getCellPtr(x);
                    cell.* = self.cursor.pen;
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

/// Options for dumping the screen to a string.
pub const Dump = struct {
    /// The start and end rows. These don't have to be in order, the dump
    /// function will automatically sort them.
    start: RowIndex,
    end: RowIndex,

    /// If true, this will unwrap soft-wrapped lines into a single line.
    unwrap: bool = true,
};

/// Dump the screen to a string. The writer given should be buffered;
/// this function does not attempt to efficiently write and generally writes
/// one byte at a time.
///
/// TODO: look at selectionString implementation for more efficiency
/// TODO: change selectionString to use this too after above todo
pub fn dumpString(self: *Screen, writer: anytype, opts: Dump) !void {
    const start_screen = opts.start.toScreen(self);
    const end_screen = opts.end.toScreen(self);

    // If we have no rows in our screen, do nothing.
    const rows_written = self.rowsWritten();
    if (rows_written == 0) return;

    // Get the actual top and bottom y values. This handles situations
    // where start/end are backwards.
    const y_top = @min(start_screen.screen, end_screen.screen);
    const y_bottom = @min(
        @max(start_screen.screen, end_screen.screen),
        rows_written - 1,
    );

    // This keeps track of the number of blank rows we see. We don't want
    // to output blank rows unless they're followed by a non-blank row.
    var blank_rows: usize = 0;

    // Iterate through the rows
    var y: usize = y_top;
    while (y <= y_bottom) : (y += 1) {
        const row = self.getRow(.{ .screen = y });

        // Handle blank rows
        if (row.isEmpty()) {
            blank_rows += 1;
            continue;
        }
        if (blank_rows > 0) {
            for (0..blank_rows) |_| try writer.writeByte('\n');
            blank_rows = 0;
        }

        if (!row.header().flags.wrap) {
            // If we're not wrapped, we always add a newline.
            blank_rows += 1;
        } else if (!opts.unwrap) {
            // If we are wrapped, we only add a new line if we're unwrapping
            // soft-wrapped lines.
            blank_rows += 1;
        }

        // Output each of the cells
        var cells = row.cellIterator();
        var spacers: usize = 0;
        while (cells.next()) |cell| {
            // Skip spacers
            if (cell.attrs.wide_spacer_head or cell.attrs.wide_spacer_tail) continue;

            // If we have a zero value, then we accumulate a counter. We
            // only want to turn zero values into spaces if we have a non-zero
            // char sometime later.
            if (cell.char == 0) {
                spacers += 1;
                continue;
            }
            if (spacers > 0) {
                for (0..spacers) |_| try writer.writeByte(' ');
                spacers = 0;
            }

            const codepoint: u21 = @intCast(cell.char);
            try writer.print("{u}", .{codepoint});

            var it = row.codepointIterator(cells.i - 1);
            while (it.next()) |cp| {
                try writer.print("{u}", .{cp});
            }
        }
    }
}

/// Turns the screen into a string. Different regions of the screen can
/// be selected using the "tag", i.e. if you want to output the viewport,
/// the scrollback, the full screen, etc.
///
/// This is only useful for testing.
pub fn testString(self: *Screen, alloc: Allocator, tag: RowIndexTag) ![]const u8 {
    var builder = std.ArrayList(u8).init(alloc);
    defer builder.deinit();
    try self.dumpString(builder.writer(), .{
        .start = tag.index(0),
        .end = tag.index(tag.maxLen(self) - 1),

        // historically our testString wants to view the screen as-is without
        // unwrapping soft-wrapped lines so turn this off.
        .unwrap = false,
    });
    return try builder.toOwnedSlice();
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
        cell.*.bg = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } };
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
        const contents = try s.testString(alloc, .screen);
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
        const contents = try s.testString(alloc, .screen);
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

test "Screen: lineIterator" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();

    // Sanity check that our test helpers work
    const str = "1ABCD\n2EFGH";
    try s.testWriteString(str);

    // Test the line iterator
    var iter = s.lineIterator(.viewport);
    {
        const line = iter.next().?;
        const actual = try line.string(alloc);
        defer alloc.free(actual);
        try testing.expectEqualStrings("1ABCD", actual);
    }
    {
        const line = iter.next().?;
        const actual = try line.string(alloc);
        defer alloc.free(actual);
        try testing.expectEqualStrings("2EFGH", actual);
    }
    try testing.expect(iter.next() == null);
}

test "Screen: lineIterator soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();

    // Sanity check that our test helpers work
    const str = "1ABCD2EFGH\n3ABCD";
    try s.testWriteString(str);

    // Test the line iterator
    var iter = s.lineIterator(.viewport);
    {
        const line = iter.next().?;
        const actual = try line.string(alloc);
        defer alloc.free(actual);
        try testing.expectEqualStrings("1ABCD2EFGH", actual);
    }
    {
        const line = iter.next().?;
        const actual = try line.string(alloc);
        defer alloc.free(actual);
        try testing.expectEqualStrings("3ABCD", actual);
    }
    try testing.expect(iter.next() == null);
}

test "Screen: getLine soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();

    // Sanity check that our test helpers work
    const str = "1ABCD2EFGH\n3ABCD";
    try s.testWriteString(str);

    // Test the line iterator
    {
        const line = s.getLine(.{ .x = 2, .y = 1 }).?;
        const actual = try line.string(alloc);
        defer alloc.free(actual);
        try testing.expectEqualStrings("1ABCD2EFGH", actual);
    }
    {
        const line = s.getLine(.{ .x = 2, .y = 2 }).?;
        const actual = try line.string(alloc);
        defer alloc.free(actual);
        try testing.expectEqualStrings("3ABCD", actual);
    }

    try testing.expect(s.getLine(.{ .x = 2, .y = 3 }) == null);
    try testing.expect(s.getLine(.{ .x = 7, .y = 1 }) == null);
}

// X
test "Screen: scrolling" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    s.cursor.pen.bg = .{ .rgb = .{ .r = 155 } };
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try testing.expect(s.viewportIsBottom());

    // Scroll down, should still be bottom
    try s.scroll(.{ .screen = 1 });
    try testing.expect(s.viewportIsBottom());

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
    {
        // Test that our new row has the correct background
        const cell = s.getCell(.active, 2, 0);
        try testing.expectEqual(@as(u8, 155), cell.bg.rgb.r);
    }

    // Scrolling to the bottom does nothing
    try s.scroll(.{ .bottom = {} });

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

// X
test "Screen: scroll down from 0" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Scrolling up does nothing, but allows it
    try s.scroll(.{ .screen = -1 });
    try testing.expect(s.viewportIsBottom());

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}

// X
test "Screen: scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 1);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try s.scroll(.{ .screen = 1 });

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom
    try s.scroll(.{ .bottom = {} });
    try testing.expect(s.viewportIsBottom());

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling back should make it visible again
    try s.scroll(.{ .screen = -1 });
    try testing.expect(!s.viewportIsBottom());

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scrolling back again should do nothing
    try s.scroll(.{ .screen = -1 });

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom
    try s.scroll(.{ .bottom = {} });

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling forward with no grow should do nothing
    try s.scroll(.{ .viewport = 1 });

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the top should work
    try s.scroll(.{ .top = {} });

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Should be able to easily clear active area only
    var it = s.rowIterator(.active);
    while (it.next()) |row| row.clear(.{});
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }

    // Scrolling to the bottom
    try s.scroll(.{ .bottom = {} });

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

// X
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scroll down a ton
    try s.scroll(.{ .viewport = 5 });
    try testing.expect(s.viewportIsBottom());
    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
}

// X
test "Screen: scrollback empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 50);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try s.scroll(.{ .viewport = 1 });

    {
        // Test our contents
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}

// X
test "Screen: scrollback doesn't move viewport if not at bottom" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 3);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH");

    // First test: we scroll up by 1, so we're not at the bottom anymore.
    try s.scroll(.{ .screen = -1 });
    try testing.expect(!s.viewportIsBottom());
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n4ABCD", contents);
    }

    // Next, we scroll back down by 1, this grows the scrollback but we
    // shouldn't move.
    try s.scroll(.{ .screen = 1 });
    try testing.expect(!s.viewportIsBottom());
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n4ABCD", contents);
    }

    // Scroll again, this clears scrollback so we should move viewports
    // but still see the same thing since our original view fits.
    try s.scroll(.{ .screen = 1 });
    try testing.expect(!s.viewportIsBottom());
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL\n4ABCD", contents);
    }

    // Scroll again, this again goes into scrollback but is now deleting
    // what we were looking at. We should see changes.
    try s.scroll(.{ .screen = 1 });
    try testing.expect(!s.viewportIsBottom());
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("3IJKL\n4ABCD\n5EFGH", contents);
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
    try s.scroll(.{ .screen = 1 });
    try testing.expect(s.viewportIsBottom());

    // Our selection should've moved up
    try testing.expectEqual(Selection{
        .start = .{ .x = 0, .y = 0 },
        .end = .{ .x = s.cols - 1, .y = 0 },
    }, s.selection.?);

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scroll up again
    try s.scroll(.{ .screen = 1 });

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
    try s.scroll(.{ .screen = 1 });
    try testing.expect(s.viewportIsBottom());

    // Our selection should NOT move since we have scrollback
    try testing.expectEqual(Selection{
        .start = .{ .x = 0, .y = 1 },
        .end = .{ .x = s.cols - 1, .y = 1 },
    }, s.selection.?);

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling back should make it visible again
    try s.scroll(.{ .screen = -1 });
    try testing.expect(!s.viewportIsBottom());

    // Our selection should NOT move since we have scrollback
    try testing.expectEqual(Selection{
        .start = .{ .x = 0, .y = 1 },
        .end = .{ .x = s.cols - 1, .y = 1 },
    }, s.selection.?);

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scroll down, this sends us off the scrollback
    try s.scroll(.{ .screen = 2 });

    // Selection should be gone since we selected a line that went off.
    try testing.expect(s.selection == null);

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("3IJKL", contents);
    }
}

// X
test "Screen: scroll and clear full screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    try s.scroll(.{ .clear = {} });
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}

// X
test "Screen: scroll and clear partial screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH");

    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }

    try s.scroll(.{ .clear = {} });
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH", contents);
    }
}

// X
test "Screen: scroll and clear empty screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit();
    try s.scroll(.{ .clear = {} });
    try testing.expectEqual(@as(usize, 0), s.viewport);
}

// X
test "Screen: scroll and clear ignore blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 10);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH");
    try s.scroll(.{ .clear = {} });
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }

    // Move back to top-left
    s.cursor.x = 0;
    s.cursor.y = 0;

    // Write and clear
    try s.testWriteString("3ABCD\n");
    try s.scroll(.{ .clear = {} });
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }

    // Move back to top-left
    s.cursor.x = 0;
    s.cursor.y = 0;
    try s.testWriteString("X");

    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3ABCD\nX", contents);
    }
}

// X - i don't think we need rowIterator
test "Screen: history region with no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 1, 5, 0);
    defer s.deinit();

    // Write a bunch that WOULD invoke scrollback if exists
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    {
        const contents = try s.testString(alloc, .screen);
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

// X - duplicated test above
test "Screen: history region with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 1, 5, 2);
    defer s.deinit();

    // Write a bunch that WOULD invoke scrollback if exists
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        // Test our contents
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    {
        const contents = try s.testString(alloc, .history);
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

// X - don't need this, internal API
test "Screen: row copy" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Copy
    try s.scroll(.{ .screen = 1 });
    try s.copyRow(.{ .active = 2 }, .{ .active = 0 });

    // Test our contents
    const contents = try s.testString(alloc, .viewport);
    defer alloc.free(contents);
    try testing.expectEqualStrings("2EFGH\n3IJKL\n2EFGH", contents);
}

// X
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
        const contents = try s2.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH", contents);
    }

    {
        var s2 = try s.clone(alloc, .{ .active = 1 }, .{ .active = 2 });
        defer s2.deinit();

        // Test our contents rotated
        const contents = try s2.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

// X
test "Screen: clone empty viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();

    {
        var s2 = try s.clone(alloc, .{ .viewport = 0 }, .{ .viewport = 0 });
        defer s2.deinit();

        // Test our contents rotated
        const contents = try s2.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

// X
test "Screen: clone one line viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABC");

    {
        var s2 = try s.clone(alloc, .{ .viewport = 0 }, .{ .viewport = 0 });
        defer s2.deinit();

        // Test our contents
        const contents = try s2.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABC", contents);
    }
}

// X
test "Screen: clone empty active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();

    {
        var s2 = try s.clone(alloc, .{ .active = 0 }, .{ .active = 0 });
        defer s2.deinit();

        // Test our contents rotated
        const contents = try s2.testString(alloc, .active);
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

// X
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
        const contents = try s2.testString(alloc, .active);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABC", contents);
    }

    // Should still have no history. A bug was that we were generating history
    // in this case which is not good! This was causing resizes to have all
    // sorts of problems.
    try testing.expectEqual(@as(usize, 1), s.rowsWritten());
}

// X
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

// X
test "Screen: selectAll" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    {
        try s.testWriteString("ABC  DEF\n 123\n456");
        const sel = s.selectAll().?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 2), sel.end.x);
        try testing.expectEqual(@as(usize, 2), sel.end.y);
    }

    {
        try s.testWriteString("\nFOO\n BAR\n BAZ\n QWERTY\n 12345678");
        const sel = s.selectAll().?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 8), sel.end.x);
        try testing.expectEqual(@as(usize, 7), sel.end.y);
    }
}

// X
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

// X
// https://github.com/mitchellh/ghostty/issues/1329
test "Screen: selectLine semantic prompt boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 5, 0);
    defer s.deinit();
    try s.testWriteString("ABCDE\nA    > ");

    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("ABCDE\nA    \n> ", contents);
    }

    var row = s.getRow(.{ .screen = 2 });
    row.setSemanticPrompt(.prompt);

    // Selecting output stops at the prompt even if soft-wrapped
    {
        const sel = s.selectLine(.{ .x = 1, .y = 1 }).?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 1), sel.start.y);
        try testing.expectEqual(@as(usize, 0), sel.end.x);
        try testing.expectEqual(@as(usize, 1), sel.end.y);
    }
    {
        const sel = s.selectLine(.{ .x = 1, .y = 2 }).?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 2), sel.start.y);
        try testing.expectEqual(@as(usize, 0), sel.end.x);
        try testing.expectEqual(@as(usize, 2), sel.end.y);
    }
}

// X
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

// X
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

// X
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

// X
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

// X
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

// X
test "Screen: selectWord with character boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cases = [_][]const u8{
        " 'abc' \n123",
        " \"abc\" \n123",
        " │abc│ \n123",
        " `abc` \n123",
        " |abc| \n123",
        " :abc: \n123",
        " ,abc, \n123",
        " (abc( \n123",
        " )abc) \n123",
        " [abc[ \n123",
        " ]abc] \n123",
        " {abc{ \n123",
        " }abc} \n123",
        " <abc< \n123",
        " >abc> \n123",
    };

    for (cases) |case| {
        var s = try init(alloc, 10, 20, 0);
        defer s.deinit();
        try s.testWriteString(case);

        // Inside character forward
        {
            const sel = s.selectWord(.{ .x = 2, .y = 0 }).?;
            try testing.expectEqual(@as(usize, 2), sel.start.x);
            try testing.expectEqual(@as(usize, 0), sel.start.y);
            try testing.expectEqual(@as(usize, 4), sel.end.x);
            try testing.expectEqual(@as(usize, 0), sel.end.y);
        }

        // Inside character backward
        {
            const sel = s.selectWord(.{ .x = 4, .y = 0 }).?;
            try testing.expectEqual(@as(usize, 2), sel.start.x);
            try testing.expectEqual(@as(usize, 0), sel.start.y);
            try testing.expectEqual(@as(usize, 4), sel.end.x);
            try testing.expectEqual(@as(usize, 0), sel.end.y);
        }

        // Inside character bidirectional
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
}

// X
test "Screen: selectOutput" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 15, 10, 0);
    defer s.deinit();

    // zig fmt: off
    {
                                                    // line number:
        try s.testWriteString("output1\n");         // 0
        try s.testWriteString("output1\n");         // 1
        try s.testWriteString("prompt2\n");         // 2
        try s.testWriteString("input2\n");          // 3
        try s.testWriteString("output2\n");         // 4
        try s.testWriteString("output2\n");         // 5
        try s.testWriteString("prompt3$ input3\n"); // 6
        try s.testWriteString("output3\n");         // 7
        try s.testWriteString("output3\n");         // 8
        try s.testWriteString("output3");           // 9
    }
    // zig fmt: on

    var row = s.getRow(.{ .screen = 2 });
    row.setSemanticPrompt(.prompt);
    row = s.getRow(.{ .screen = 3 });
    row.setSemanticPrompt(.input);
    row = s.getRow(.{ .screen = 4 });
    row.setSemanticPrompt(.command);
    row = s.getRow(.{ .screen = 6 });
    row.setSemanticPrompt(.input);
    row = s.getRow(.{ .screen = 7 });
    row.setSemanticPrompt(.command);

    // No start marker, should select from the beginning
    {
        const sel = s.selectOutput(.{ .x = 1, .y = 1 }).?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 0), sel.start.y);
        try testing.expectEqual(@as(usize, 10), sel.end.x);
        try testing.expectEqual(@as(usize, 1), sel.end.y);
    }
    // Both start and end markers, should select between them
    {
        const sel = s.selectOutput(.{ .x = 3, .y = 5 }).?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 4), sel.start.y);
        try testing.expectEqual(@as(usize, 10), sel.end.x);
        try testing.expectEqual(@as(usize, 5), sel.end.y);
    }
    // No end marker, should select till the end
    {
        const sel = s.selectOutput(.{ .x = 2, .y = 7 }).?;
        try testing.expectEqual(@as(usize, 0), sel.start.x);
        try testing.expectEqual(@as(usize, 7), sel.start.y);
        try testing.expectEqual(@as(usize, 9), sel.end.x);
        try testing.expectEqual(@as(usize, 10), sel.end.y);
    }
    // input / prompt at y = 0, pt.y = 0
    {
        s.deinit();
        s = try init(alloc, 5, 10, 0);
        try s.testWriteString("prompt1$ input1\n");
        try s.testWriteString("output1\n");
        try s.testWriteString("prompt2\n");
        row = s.getRow(.{ .screen = 0 });
        row.setSemanticPrompt(.input);
        row = s.getRow(.{ .screen = 1 });
        row.setSemanticPrompt(.command);
        try testing.expect(s.selectOutput(.{ .x = 2, .y = 0 }) == null);
    }
}

// X
test "Screen: selectPrompt basics" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 15, 10, 0);
    defer s.deinit();

    // zig fmt: off
    {
                                                    // line number:
        try s.testWriteString("output1\n");         // 0
        try s.testWriteString("output1\n");         // 1
        try s.testWriteString("prompt2\n");         // 2
        try s.testWriteString("input2\n");          // 3
        try s.testWriteString("output2\n");         // 4
        try s.testWriteString("output2\n");         // 5
        try s.testWriteString("prompt3$ input3\n"); // 6
        try s.testWriteString("output3\n");         // 7
        try s.testWriteString("output3\n");         // 8
        try s.testWriteString("output3");           // 9
    }
    // zig fmt: on

    var row = s.getRow(.{ .screen = 2 });
    row.setSemanticPrompt(.prompt);
    row = s.getRow(.{ .screen = 3 });
    row.setSemanticPrompt(.input);
    row = s.getRow(.{ .screen = 4 });
    row.setSemanticPrompt(.command);
    row = s.getRow(.{ .screen = 6 });
    row.setSemanticPrompt(.input);
    row = s.getRow(.{ .screen = 7 });
    row.setSemanticPrompt(.command);

    // Not at a prompt
    {
        const sel = s.selectPrompt(.{ .x = 0, .y = 1 });
        try testing.expect(sel == null);
    }
    {
        const sel = s.selectPrompt(.{ .x = 0, .y = 8 });
        try testing.expect(sel == null);
    }

    // Single line prompt
    {
        const sel = s.selectPrompt(.{ .x = 1, .y = 6 }).?;
        try testing.expectEqual(Selection{
            .start = .{ .x = 0, .y = 6 },
            .end = .{ .x = 9, .y = 6 },
        }, sel);
    }

    // Multi line prompt
    {
        const sel = s.selectPrompt(.{ .x = 1, .y = 3 }).?;
        try testing.expectEqual(Selection{
            .start = .{ .x = 0, .y = 2 },
            .end = .{ .x = 9, .y = 3 },
        }, sel);
    }
}

// X
test "Screen: selectPrompt prompt at start" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 15, 10, 0);
    defer s.deinit();

    // zig fmt: off
    {
                                                    // line number:
        try s.testWriteString("prompt1\n");         // 0
        try s.testWriteString("input1\n");          // 1
        try s.testWriteString("output2\n");         // 2
        try s.testWriteString("output2\n");         // 3
    }
    // zig fmt: on

    var row = s.getRow(.{ .screen = 0 });
    row.setSemanticPrompt(.prompt);
    row = s.getRow(.{ .screen = 1 });
    row.setSemanticPrompt(.input);
    row = s.getRow(.{ .screen = 2 });
    row.setSemanticPrompt(.command);

    // Not at a prompt
    {
        const sel = s.selectPrompt(.{ .x = 0, .y = 3 });
        try testing.expect(sel == null);
    }

    // Multi line prompt
    {
        const sel = s.selectPrompt(.{ .x = 1, .y = 1 }).?;
        try testing.expectEqual(Selection{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 9, .y = 1 },
        }, sel);
    }
}

// X
test "Screen: selectPrompt prompt at end" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 15, 10, 0);
    defer s.deinit();

    // zig fmt: off
    {
                                                    // line number:
        try s.testWriteString("output2\n");         // 0
        try s.testWriteString("output2\n");         // 1
        try s.testWriteString("prompt1\n");         // 2
        try s.testWriteString("input1\n");          // 3
    }
    // zig fmt: on

    var row = s.getRow(.{ .screen = 2 });
    row.setSemanticPrompt(.prompt);
    row = s.getRow(.{ .screen = 3 });
    row.setSemanticPrompt(.input);

    // Not at a prompt
    {
        const sel = s.selectPrompt(.{ .x = 0, .y = 1 });
        try testing.expect(sel == null);
    }

    // Multi line prompt
    {
        const sel = s.selectPrompt(.{ .x = 1, .y = 2 }).?;
        try testing.expectEqual(Selection{
            .start = .{ .x = 0, .y = 2 },
            .end = .{ .x = 9, .y = 3 },
        }, sel);
    }
}

// X
test "Screen: promptPath" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 15, 10, 0);
    defer s.deinit();

    // zig fmt: off
    {
                                                    // line number:
        try s.testWriteString("output1\n");         // 0
        try s.testWriteString("output1\n");         // 1
        try s.testWriteString("prompt2\n");         // 2
        try s.testWriteString("input2\n");          // 3
        try s.testWriteString("output2\n");         // 4
        try s.testWriteString("output2\n");         // 5
        try s.testWriteString("prompt3$ input3\n"); // 6
        try s.testWriteString("output3\n");         // 7
        try s.testWriteString("output3\n");         // 8
        try s.testWriteString("output3");           // 9
    }
    // zig fmt: on

    var row = s.getRow(.{ .screen = 2 });
    row.setSemanticPrompt(.prompt);
    row = s.getRow(.{ .screen = 3 });
    row.setSemanticPrompt(.input);
    row = s.getRow(.{ .screen = 4 });
    row.setSemanticPrompt(.command);
    row = s.getRow(.{ .screen = 6 });
    row.setSemanticPrompt(.input);
    row = s.getRow(.{ .screen = 7 });
    row.setSemanticPrompt(.command);

    // From is not in the prompt
    {
        const path = s.promptPath(
            .{ .x = 0, .y = 1 },
            .{ .x = 0, .y = 2 },
        );
        try testing.expectEqual(@as(isize, 0), path.x);
        try testing.expectEqual(@as(isize, 0), path.y);
    }

    // Same line
    {
        const path = s.promptPath(
            .{ .x = 6, .y = 2 },
            .{ .x = 3, .y = 2 },
        );
        try testing.expectEqual(@as(isize, -3), path.x);
        try testing.expectEqual(@as(isize, 0), path.y);
    }

    // Different lines
    {
        const path = s.promptPath(
            .{ .x = 6, .y = 2 },
            .{ .x = 3, .y = 3 },
        );
        try testing.expectEqual(@as(isize, -3), path.x);
        try testing.expectEqual(@as(isize, 1), path.y);
    }

    // To is out of bounds before
    {
        const path = s.promptPath(
            .{ .x = 6, .y = 2 },
            .{ .x = 3, .y = 1 },
        );
        try testing.expectEqual(@as(isize, -6), path.x);
        try testing.expectEqual(@as(isize, 0), path.y);
    }

    // To is out of bounds after
    {
        const path = s.promptPath(
            .{ .x = 6, .y = 2 },
            .{ .x = 3, .y = 9 },
        );
        try testing.expectEqual(@as(isize, 3), path.x);
        try testing.expectEqual(@as(isize, 1), path.y);
    }
}

// X - we don't use this in new terminal
test "Screen: scrollRegionUp single" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    s.scrollRegionUp(.{ .active = 1 }, .{ .active = 2 }, 1);
    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n3IJKL\n\n4ABCD", contents);
    }
}

// X - we don't use this in new terminal
test "Screen: scrollRegionUp same line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    s.scrollRegionUp(.{ .active = 1 }, .{ .active = 1 }, 1);
    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL\n4ABCD", contents);
    }
}

// X - we don't use this in new terminal
test "Screen: scrollRegionUp single with pen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    s.cursor.pen = .{ .char = 'X' };
    s.cursor.pen.bg = .{ .rgb = .{ .r = 155 } };
    s.cursor.pen.attrs.bold = true;
    s.scrollRegionUp(.{ .active = 1 }, .{ .active = 2 }, 1);
    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n3IJKL\n\n4ABCD", contents);
        const cell = s.getCell(.active, 2, 0);
        try testing.expectEqual(@as(u8, 155), cell.bg.rgb.r);
        try testing.expect(!cell.attrs.bold);
        try testing.expect(s.cursor.pen.attrs.bold);
    }
}

// X - we don't use this in new terminal
test "Screen: scrollRegionUp multiple" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    s.scrollRegionUp(.{ .active = 1 }, .{ .active = 3 }, 1);
    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n3IJKL\n4ABCD", contents);
    }
}

// X - we don't use this in new terminal
test "Screen: scrollRegionUp multiple count" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    s.scrollRegionUp(.{ .active = 1 }, .{ .active = 3 }, 2);
    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n4ABCD", contents);
    }
}

// X - we don't use this in new terminal
test "Screen: scrollRegionUp count greater than available lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    s.scrollRegionUp(.{ .active = 1 }, .{ .active = 2 }, 10);
    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n\n\n4ABCD", contents);
    }
}
// X - we don't use this in new terminal
test "Screen: scrollRegionUp fills with pen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 5, 0);
    defer s.deinit();
    try s.testWriteString("A\nB\nC\nD");

    s.cursor.pen = .{ .char = 'X' };
    s.cursor.pen.bg = .{ .rgb = .{ .r = 155 } };
    s.cursor.pen.attrs.bold = true;
    s.scrollRegionUp(.{ .active = 0 }, .{ .active = 2 }, 1);
    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("B\nC\n\nD", contents);
        const cell = s.getCell(.active, 2, 0);
        try testing.expectEqual(@as(u8, 155), cell.bg.rgb.r);
        try testing.expect(!cell.attrs.bold);
        try testing.expect(s.cursor.pen.attrs.bold);
    }
}

// X - we don't use this in new terminal
test "Screen: scrollRegionUp buffer wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Scroll down, should still be bottom, but should wrap because
    // we're out of space.
    try s.scroll(.{ .screen = 1 });
    s.cursor.x = 0;
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    // Scroll
    s.cursor.pen = .{ .char = 'X' };
    s.cursor.pen.bg = .{ .rgb = .{ .r = 155 } };
    s.cursor.pen.attrs.bold = true;
    s.scrollRegionUp(.{ .screen = 0 }, .{ .screen = 2 }, 1);

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("3IJKL\n4ABCD", contents);
        const cell = s.getCell(.active, 2, 0);
        try testing.expectEqual(@as(u8, 155), cell.bg.rgb.r);
        try testing.expect(!cell.attrs.bold);
        try testing.expect(s.cursor.pen.attrs.bold);
    }
}

// X - we don't use this in new terminal
test "Screen: scrollRegionUp buffer wrap alternate" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Scroll down, should still be bottom, but should wrap because
    // we're out of space.
    try s.scroll(.{ .screen = 1 });
    s.cursor.x = 0;
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD");

    // Scroll
    s.cursor.pen = .{ .char = 'X' };
    s.cursor.pen.bg = .{ .rgb = .{ .r = 155 } };
    s.cursor.pen.attrs.bold = true;
    s.scrollRegionUp(.{ .screen = 0 }, .{ .screen = 2 }, 2);

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD", contents);
        const cell = s.getCell(.active, 2, 0);
        try testing.expectEqual(@as(u8, 155), cell.bg.rgb.r);
        try testing.expect(!cell.attrs.bold);
        try testing.expect(s.cursor.pen.attrs.bold);
    }
}

// X - we don't use this in new terminal
test "Screen: scrollRegionUp buffer wrap alternative with extra lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();

    // We artificially mess with the circular buffer here. This was discovered
    // when debugging https://github.com/mitchellh/ghostty/issues/315. I
    // don't know how to "naturally" get the circular buffer into this state
    // although it is obviously possible, verified through various
    // asciinema casts.
    //
    // I think the proper way to recreate this state would be to fill
    // the screen, scroll the correct number of times, clear the screen
    // with a fill. I can try that later to ensure we're hitting the same
    // code path.
    s.storage.head = 24;
    s.storage.tail = 24;
    s.storage.full = true;

    // Scroll down, should still be bottom, but should wrap because
    // we're out of space.
    // try s.scroll(.{ .screen = 2 });
    // s.cursor.x = 0;
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH");

    // Scroll
    s.scrollRegionUp(.{ .screen = 0 }, .{ .screen = 3 }, 2);

    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("3IJKL\n4ABCD\n\n\n5EFGH", contents);
    }
}

// X
test "Screen: clear history with no history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 3);
    defer s.deinit();
    try s.testWriteString("4ABCD\n5EFGH\n6IJKL");
    try testing.expect(s.viewportIsBottom());
    try s.clear(.history);
    try testing.expect(s.viewportIsBottom());
    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
}

// X
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    try s.clear(.history);
    try testing.expect(s.viewportIsBottom());
    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
    {
        // Test our contents rotated
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("4ABCD\n5EFGH\n6IJKL", contents);
    }
}

// X
test "Screen: clear above cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 3);
    defer s.deinit();
    try s.testWriteString("4ABCD\n5EFGH\n6IJKL");
    try testing.expect(s.viewportIsBottom());
    try s.clear(.above_cursor);
    try testing.expect(s.viewportIsBottom());
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("6IJKL", contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("6IJKL", contents);
    }

    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);
}

// X
test "Screen: clear above cursor with history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 10, 3);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n");
    try s.testWriteString("4ABCD\n5EFGH\n6IJKL");
    try testing.expect(s.viewportIsBottom());
    try s.clear(.above_cursor);
    try testing.expect(s.viewportIsBottom());
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("6IJKL", contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL\n6IJKL", contents);
    }

    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);
}

// X
test "Screen: selectionString basic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    {
        const contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 1 },
            .end = .{ .x = 2, .y = 2 },
        }, true);
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
test "Screen: selectionString start outside of written area" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    {
        const contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 5 },
            .end = .{ .x = 2, .y = 6 },
        }, true);
        defer alloc.free(contents);
        const expected = "";
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
test "Screen: selectionString end outside of written area" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    {
        const contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 2 },
            .end = .{ .x = 2, .y = 6 },
        }, true);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
test "Screen: selectionString trim space" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1AB  \n2EFGH\n3IJKL";
    try s.testWriteString(str);

    {
        const contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 2, .y = 1 },
        }, true);
        defer alloc.free(contents);
        const expected = "1AB\n2EF";
        try testing.expectEqualStrings(expected, contents);
    }

    // No trim
    {
        const contents = try s.selectionString(alloc, .{
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
        const contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 2, .y = 2 },
        }, true);
        defer alloc.free(contents);
        const expected = "1AB\n\n2EF";
        try testing.expectEqualStrings(expected, contents);
    }

    // No trim
    {
        const contents = try s.selectionString(alloc, .{
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
        const contents = try s.selectionString(alloc, .{
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
    try s.scroll(.{ .screen = 1 });
    try testing.expect(s.viewportIsBottom());
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    {
        const contents = try s.selectionString(alloc, .{
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
        const contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 3, .y = 0 },
        }, true);
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }

    {
        const contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 2, .y = 0 },
        }, true);
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }

    {
        const contents = try s.selectionString(alloc, .{
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
        const contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 4, .y = 0 },
        }, true);
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }
}

// https://github.com/mitchellh/ghostty/issues/289
test "Screen: selectionString empty with soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 5, 0);
    defer s.deinit();

    // Let me describe the situation that caused this because this
    // test is not obvious. By writing an emoji below, we introduce
    // one cell with the emoji and one cell as a "wide char spacer".
    // We then soft wrap the line by writing spaces.
    //
    // By selecting only the tail, we'd select nothing and we had
    // a logic error that would cause a crash.
    try s.testWriteString("👨");
    try s.testWriteString("      ");

    {
        const contents = try s.selectionString(alloc, .{
            .start = .{ .x = 1, .y = 0 },
            .end = .{ .x = 2, .y = 0 },
        }, true);
        defer alloc.free(contents);
        const expected = "👨";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString with zero width joiner" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 1, 10, 0);
    defer s.deinit();
    const str = "👨‍"; // this has a ZWJ
    try s.testWriteString(str);

    // Integrity check
    const row = s.getRow(.{ .screen = 0 });
    {
        const cell = row.getCell(0);
        try testing.expectEqual(@as(u32, 0x1F468), cell.char);
        try testing.expect(cell.attrs.wide);
        try testing.expectEqual(@as(usize, 2), row.codepointLen(0));
    }
    {
        const cell = row.getCell(1);
        try testing.expectEqual(@as(u32, ' '), cell.char);
        try testing.expect(cell.attrs.wide_spacer_tail);
        try testing.expectEqual(@as(usize, 1), row.codepointLen(1));
    }

    // The real test
    {
        const contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 1, .y = 0 },
        }, true);
        defer alloc.free(contents);
        const expected = "👨‍";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString, rectangle, basic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 30, 0);
    defer s.deinit();
    const str =
        \\Lorem ipsum dolor
        \\sit amet, consectetur
        \\adipiscing elit, sed do
        \\eiusmod tempor incididunt
        \\ut labore et dolore
    ;
    const sel = Selection{
        .start = .{ .x = 2, .y = 1 },
        .end = .{ .x = 6, .y = 3 },
        .rectangle = true,
    };
    const expected =
        \\t ame
        \\ipisc
        \\usmod
    ;
    try s.testWriteString(str);

    const contents = try s.selectionString(alloc, sel, true);
    defer alloc.free(contents);
    try testing.expectEqualStrings(expected, contents);
}

test "Screen: selectionString, rectangle, w/EOL" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 30, 0);
    defer s.deinit();
    const str =
        \\Lorem ipsum dolor
        \\sit amet, consectetur
        \\adipiscing elit, sed do
        \\eiusmod tempor incididunt
        \\ut labore et dolore
    ;
    const sel = Selection{
        .start = .{ .x = 12, .y = 0 },
        .end = .{ .x = 26, .y = 4 },
        .rectangle = true,
    };
    const expected =
        \\dolor
        \\nsectetur
        \\lit, sed do
        \\or incididunt
        \\ dolore
    ;
    try s.testWriteString(str);

    const contents = try s.selectionString(alloc, sel, true);
    defer alloc.free(contents);
    try testing.expectEqualStrings(expected, contents);
}

test "Screen: selectionString, rectangle, more complex w/breaks" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 8, 30, 0);
    defer s.deinit();
    const str =
        \\Lorem ipsum dolor
        \\sit amet, consectetur
        \\adipiscing elit, sed do
        \\eiusmod tempor incididunt
        \\ut labore et dolore
        \\
        \\magna aliqua. Ut enim
        \\ad minim veniam, quis
    ;
    const sel = Selection{
        .start = .{ .x = 11, .y = 2 },
        .end = .{ .x = 26, .y = 7 },
        .rectangle = true,
    };
    const expected =
        \\elit, sed do
        \\por incididunt
        \\t dolore
        \\
        \\a. Ut enim
        \\niam, quis
    ;
    try s.testWriteString(str);

    const contents = try s.selectionString(alloc, sel, true);
    defer alloc.free(contents);
    try testing.expectEqualStrings(expected, contents);
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

// X
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Everything should be dirty
    iter = s.rowIterator(.viewport);
    while (iter.next()) |row| try testing.expect(row.isDirty());
}

// X
test "Screen: resize (no reflow) less rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(2, 5);

    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

// X
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
            cell.*.bg = .{ .rgb = .{ .r = 0xFF, .g = 0, .b = 0 } };
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }
}

// X
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
            cell.*.bg = .{ .rgb = .{ .r = 0xFF, .g = 0, .b = 0 } };
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }
}

// X
test "Screen: resize (no reflow) more cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(3, 10);

    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

// X
test "Screen: resize (no reflow) less cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(3, 4);

    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABC\n2EFG\n3IJK";
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
test "Screen: resize (no reflow) more rows with scrollback cursor end" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 2);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(10, 5);

    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

// X
test "Screen: resize (no reflow) less rows with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 2);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(2, 5);

    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
// https://github.com/mitchellh/ghostty/issues/1030
test "Screen: resize (no reflow) less rows with empty trailing" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit();
    const str = "1\n2\n3\n4\n5\n6\n7\n8";
    try s.testWriteString(str);
    try s.scroll(.{ .clear = {} });
    s.cursor.x = 0;
    s.cursor.y = 0;
    try s.testWriteString("A\nB");

    const cursor = s.cursor;
    try s.resizeWithoutReflow(2, 5);
    try testing.expectEqual(cursor, s.cursor);

    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("A\nB", contents);
    }
}

// X
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

// X
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
        const expected = "1️A️B️C️D️\n2️E️F️G️H️\n3️I️J️K️L️";
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(expected, contents);
    }

    // Everything should be dirty
    {
        var iter = s.rowIterator(.viewport);
        while (iter.next()) |row| try testing.expect(row.isDirty());
    }
}

// X
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
        const contents = try s.testString(alloc, .viewport);
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

// X
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

// X
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

// X
test "Screen: resize more rows with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.testString(alloc, .viewport);
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
test "Screen: resize more rows and cols with wrapping" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 2, 0);
    defer s.deinit();
    const str = "1A2B\n3C4D";
    try s.testWriteString(str);
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1A\n2B\n3C\n4D";
        try testing.expectEqualStrings(expected, contents);
    }

    try s.resize(10, 5);

    // Cursor should move due to wrapping
    try testing.expectEqual(@as(usize, 3), s.cursor.x);
    try testing.expectEqual(@as(usize, 1), s.cursor.y);

    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

// X
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

// X
// https://github.com/mitchellh/ghostty/issues/272#issuecomment-1676038963
test "Screen: resize more cols perfect split" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL";
    try s.testWriteString(str);
    try s.resize(3, 10);

    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD2EFGH\n3IJKL", contents);
    }
}

// X
// https://github.com/mitchellh/ghostty/issues/1159
test "Screen: resize (no reflow) more cols with scrollback scrolled up" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit();
    const str = "1\n2\n3\n4\n5\n6\n7\n8";
    try s.testWriteString(str);

    // Cursor at bottom
    try testing.expectEqual(@as(usize, 1), s.cursor.x);
    try testing.expectEqual(@as(usize, 2), s.cursor.y);

    try s.scroll(.{ .viewport = -4 });
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2\n3\n4", contents);
    }

    try s.resize(3, 8);
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Cursor remains at bottom
    try testing.expectEqual(@as(usize, 1), s.cursor.x);
    try testing.expectEqual(@as(usize, 2), s.cursor.y);
}

// X
// https://github.com/mitchellh/ghostty/issues/1159
test "Screen: resize (no reflow) less cols with scrollback scrolled up" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit();
    const str = "1\n2\n3\n4\n5\n6\n7\n8";
    try s.testWriteString(str);

    // Cursor at bottom
    try testing.expectEqual(@as(usize, 1), s.cursor.x);
    try testing.expectEqual(@as(usize, 2), s.cursor.y);

    try s.scroll(.{ .viewport = -4 });
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2\n3\n4", contents);
    }

    try s.resize(3, 4);
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.testString(alloc, .active);
        defer alloc.free(contents);
        try testing.expectEqualStrings("6\n7\n8", contents);
    }

    // Cursor remains at bottom
    try testing.expectEqual(@as(usize, 1), s.cursor.x);
    try testing.expectEqual(@as(usize, 2), s.cursor.y);
}

// X
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
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

// X
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
        const expected = "1️A️B️C️D️\n2️E️F️G️H️\n3️I️J️K️L️";
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const expected = "1️A️B️C️D️\n2️E️F️G️H️\n3️I️J️K️L️";
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
test "Screen: resize more cols with reflow that fits full width" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Verify we soft wrapped
    {
        const contents = try s.testString(alloc, .viewport);
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);
}

// X
test "Screen: resize more cols with reflow that ends in newline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 6, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);

    // Verify we soft wrapped
    {
        const contents = try s.testString(alloc, .viewport);
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Our cursor should still be on the 3
    try testing.expectEqual(@as(u32, '3'), s.getCell(.active, s.cursor.y, s.cursor.x).char);
}

// X
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(3, 7);
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABCD2E\nFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(usize, 5), s.cursor.x);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);
}

// X
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(3, 15);
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABCD2EFGH3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(usize, 10), s.cursor.x);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);
}

// X
test "Screen: resize more cols with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.testString(alloc, .viewport);
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
    try testing.expectEqual(@as(u32, '5'), s.getCell(.active, s.cursor.y, s.cursor.x).char);

    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJKL\n4ABCD5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "BC\n4D\nEF";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize and verify we undid the soft wrap because we have space now
    try s.resize(3, 7);

    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "1ABC\n2DEF\n3ABC\n4DEF";
        try testing.expectEqualStrings(expected, contents);
    }

    // Our cursor should've moved
    try testing.expectEqual(@as(usize, 2), s.cursor.x);
    try testing.expectEqual(@as(usize, 2), s.cursor.y);
}

// X
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
test "Screen: resize less rows with empty scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 10);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resize(1, 5);

    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
test "Screen: resize less rows with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Resize
    try s.resize(1, 5);

    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
test "Screen: resize less rows with full scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 3);
    defer s.deinit();
    const str = "00000\n1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    {
        const contents = try s.testString(alloc, .viewport);
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
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
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
    const pen: Cell = .{ .bg = .{ .rgb = .{ .r = 0xFF } } };
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
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

// X
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
        const expected = "1️A️B️\n2️E️F️\n3️I️J️";
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const expected = "1️A️B️\n2️E️F️\n3️I️J️";
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
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

// X
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1AB\nCD";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "1AB\nCD";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(usize, 1), s.cursor.x);
    try testing.expectEqual(@as(usize, 1), s.cursor.y);
}

// X
test "Screen: resize less cols with reflow with trimmed rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(3, 3);

    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
test "Screen: resize less cols with reflow with trimmed rows and scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 1);
    defer s.deinit();
    const str = "3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resize(3, 3);

    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "CD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "4AB\nCD\n5EF\nGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
test "Screen: resize less cols with reflow previously wrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "3IJKL4ABCD5EFGH";
    try s.testWriteString(str);

    // Check
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    try s.resize(3, 3);

    // {
    //     const contents = try s.testString(alloc, .viewport);
    //     defer alloc.free(contents);
    //     const expected = "CD\n5EF\nGH";
    //     try testing.expectEqualStrings(expected, contents);
    // }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "ABC\nD5E\nFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3C\n4D\n5E";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(usize, 1), s.cursor.x);
    try testing.expectEqual(@as(usize, 2), s.cursor.y);
}

// X
test "Screen: resize less cols with reflow previously wrapped and scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 2);
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL4ABCD5EFGH";
    try s.testWriteString(str);

    // Check
    {
        const contents = try s.testString(alloc, .viewport);
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "CD5\nEFG\nH";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "JKL\n4AB\nCD5\nEFG\nH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(u32, 'H'), s.getCell(.active, s.cursor.y, s.cursor.x).char);
    try testing.expectEqual(@as(usize, 0), s.cursor.x);
    try testing.expectEqual(@as(usize, 2), s.cursor.y);
}

test "Screen: resize less cols with scrollback keeps cursor row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit();
    const str = "1A\n2B\n3C\n4D\n5E";
    try s.testWriteString(str);

    // Lets do a scroll and clear operation
    try s.scroll(.{ .clear = {} });

    // Move our cursor to the beginning
    s.cursor.x = 0;
    s.cursor.y = 0;

    try s.resize(3, 3);

    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "";
        try testing.expectEqualStrings(expected, contents);
    }

    // Cursor should be on the last line
    try testing.expectEqual(@as(usize, 0), s.cursor.x);
    try testing.expectEqual(@as(usize, 0), s.cursor.y);
}

// X
test "Screen: resize more rows, less cols with reflow with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 3);
    defer s.deinit();
    const str = "1ABCD\n2EFGH3IJKL\n4MNOP";
    try s.testWriteString(str);

    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH\n3IJKL\n4MNOP";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJKL\n4MNOP";
        try testing.expectEqualStrings(expected, contents);
    }

    try s.resize(10, 2);

    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "BC\nD\n2E\nFG\nH3\nIJ\nKL\n4M\nNO\nP";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "1A\nBC\nD\n2E\nFG\nH3\nIJ\nKL\n4M\nNO\nP";
        try testing.expectEqualStrings(expected, contents);
    }
}

// X
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
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Shrink
    try s.resize(3, 5);
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Grow again
    try s.resize(10, 5);
    {
        const contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

// X
test "Screen: resize less cols to eliminate wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 1, 2, 0);
    defer s.deinit();
    const str = "😀";
    try s.testWriteString(str);
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const cell = s.getCell(.screen, 0, 0);
        try testing.expectEqual(@as(u32, '😀'), cell.char);
        try testing.expect(cell.attrs.wide);
    }

    // Resize to 1 column can't fit a wide char. So it should be deleted.
    try s.resize(1, 1);
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(" ", contents);
    }

    const cell = s.getCell(.screen, 0, 0);
    try testing.expectEqual(@as(u32, ' '), cell.char);
    try testing.expect(!cell.attrs.wide);
    try testing.expect(!cell.attrs.wide_spacer_tail);
    try testing.expect(!cell.attrs.wide_spacer_head);
}

// X
test "Screen: resize less cols to wrap wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 3, 0);
    defer s.deinit();
    const str = "x😀";
    try s.testWriteString(str);
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const cell = s.getCell(.screen, 0, 1);
        try testing.expectEqual(@as(u32, '😀'), cell.char);
        try testing.expect(cell.attrs.wide);
        try testing.expect(s.getCell(.screen, 0, 2).attrs.wide_spacer_tail);
    }

    try s.resize(3, 2);
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("x\n😀", contents);
    }
    {
        const cell = s.getCell(.screen, 0, 1);
        try testing.expectEqual(@as(u32, ' '), cell.char);
        try testing.expect(!cell.attrs.wide);
        try testing.expect(!cell.attrs.wide_spacer_tail);
        try testing.expect(cell.attrs.wide_spacer_head);
    }
}

// X
test "Screen: resize less cols to eliminate wide char with row space" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
    defer s.deinit();
    const str = "😀";
    try s.testWriteString(str);
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const cell = s.getCell(.screen, 0, 0);
        try testing.expectEqual(@as(u32, '😀'), cell.char);
        try testing.expect(cell.attrs.wide);
        try testing.expect(s.getCell(.screen, 0, 1).attrs.wide_spacer_tail);
    }

    try s.resize(2, 1);
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(" \n ", contents);
    }
    {
        const cell = s.getCell(.screen, 0, 0);
        try testing.expectEqual(@as(u32, ' '), cell.char);
        try testing.expect(!cell.attrs.wide);
        try testing.expect(!cell.attrs.wide_spacer_tail);
        try testing.expect(!cell.attrs.wide_spacer_head);
    }
}

// X
test "Screen: resize more cols with wide spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 3, 0);
    defer s.deinit();
    const str = "  😀";
    try s.testWriteString(str);
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("  \n😀", contents);
    }

    // So this is the key point: we end up with a wide spacer head at
    // the end of row 1, then the emoji, then a wide spacer tail on row 2.
    // We should expect that if we resize to more cols, the wide spacer
    // head is replaced with the emoji.
    {
        const cell = s.getCell(.screen, 0, 2);
        try testing.expectEqual(@as(u32, ' '), cell.char);
        try testing.expect(cell.attrs.wide_spacer_head);
        try testing.expect(s.getCell(.screen, 1, 0).attrs.wide);
        try testing.expect(s.getCell(.screen, 1, 1).attrs.wide_spacer_tail);
    }

    try s.resize(2, 4);
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const cell = s.getCell(.screen, 0, 2);
        try testing.expectEqual(@as(u32, '😀'), cell.char);
        try testing.expect(!cell.attrs.wide_spacer_head);
        try testing.expect(cell.attrs.wide);
        try testing.expect(s.getCell(.screen, 0, 3).attrs.wide_spacer_tail);
    }
}

// X
test "Screen: resize less cols preserves grapheme cluster" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 1, 5, 0);
    defer s.deinit();
    const str: []const u8 = &.{ 0x43, 0xE2, 0x83, 0x90 }; // C⃐ (C with combining left arrow)
    try s.testWriteString(str);

    // We should have a single cell with all the codepoints
    {
        const row = s.getRow(.{ .screen = 0 });
        try testing.expectEqual(@as(usize, 2), row.codepointLen(0));
    }
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Resize to less columns. No wrapping, but we should still have
    // the same grapheme cluster.
    try s.resize(1, 4);
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

// X
test "Screen: resize more cols with wide spacer head multiple lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 3, 0);
    defer s.deinit();
    const str = "xxxyy😀";
    try s.testWriteString(str);
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("xxx\nyy\n😀", contents);
    }

    // Similar to the "wide spacer head" test, but this time we'er going
    // to increase our columns such that multiple rows are unwrapped.
    {
        const cell = s.getCell(.screen, 1, 2);
        try testing.expectEqual(@as(u32, ' '), cell.char);
        try testing.expect(cell.attrs.wide_spacer_head);
        try testing.expect(s.getCell(.screen, 2, 0).attrs.wide);
        try testing.expect(s.getCell(.screen, 2, 1).attrs.wide_spacer_tail);
    }

    try s.resize(2, 8);
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        const cell = s.getCell(.screen, 0, 5);
        try testing.expect(!cell.attrs.wide_spacer_head);
        try testing.expectEqual(@as(u32, '😀'), cell.char);
        try testing.expect(cell.attrs.wide);
        try testing.expect(s.getCell(.screen, 0, 6).attrs.wide_spacer_tail);
    }
}

// X
test "Screen: resize more cols requiring a wide spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
    defer s.deinit();
    const str = "xx😀";
    try s.testWriteString(str);
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("xx\n😀", contents);
    }
    {
        try testing.expect(s.getCell(.screen, 1, 0).attrs.wide);
        try testing.expect(s.getCell(.screen, 1, 1).attrs.wide_spacer_tail);
    }

    // This resizes to 3 columns, which isn't enough space for our wide
    // char to enter row 1. But we need to mark the wide spacer head on the
    // end of the first row since we're wrapping to the next row.
    try s.resize(2, 3);
    {
        const contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("xx\n😀", contents);
    }
    {
        const cell = s.getCell(.screen, 0, 2);
        try testing.expectEqual(@as(u32, ' '), cell.char);
        try testing.expect(cell.attrs.wide_spacer_head);
        try testing.expect(s.getCell(.screen, 1, 0).attrs.wide);
        try testing.expect(s.getCell(.screen, 1, 1).attrs.wide_spacer_tail);
    }
    {
        const cell = s.getCell(.screen, 1, 0);
        try testing.expectEqual(@as(u32, '😀'), cell.char);
        try testing.expect(cell.attrs.wide);
        try testing.expect(s.getCell(.screen, 1, 1).attrs.wide_spacer_tail);
    }
}

test "Screen: jump zero" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 10);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n");
    try s.testWriteString("4ABCD\n5EFGH\n6IJKL");
    try testing.expect(s.viewportIsBottom());

    // Set semantic prompts
    {
        const row = s.getRow(.{ .screen = 1 });
        row.setSemanticPrompt(.prompt);
    }
    {
        const row = s.getRow(.{ .screen = 5 });
        row.setSemanticPrompt(.prompt);
    }

    try testing.expect(!s.jump(.{ .prompt_delta = 0 }));
    try testing.expectEqual(@as(usize, 3), s.viewport);
}

test "Screen: jump to prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 10);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n");
    try s.testWriteString("4ABCD\n5EFGH\n6IJKL");
    try testing.expect(s.viewportIsBottom());

    // Set semantic prompts
    {
        const row = s.getRow(.{ .screen = 1 });
        row.setSemanticPrompt(.prompt);
    }
    {
        const row = s.getRow(.{ .screen = 5 });
        row.setSemanticPrompt(.prompt);
    }

    // Jump back
    try testing.expect(s.jump(.{ .prompt_delta = -1 }));
    try testing.expectEqual(@as(usize, 1), s.viewport);

    // Jump back
    try testing.expect(!s.jump(.{ .prompt_delta = -1 }));
    try testing.expectEqual(@as(usize, 1), s.viewport);

    // Jump forward
    try testing.expect(s.jump(.{ .prompt_delta = 1 }));
    try testing.expectEqual(@as(usize, 3), s.viewport);

    // Jump forward
    try testing.expect(!s.jump(.{ .prompt_delta = 1 }));
    try testing.expectEqual(@as(usize, 3), s.viewport);
}

test "Screen: row graphemeBreak" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 1, 10, 0);
    defer s.deinit();
    try s.testWriteString("x");
    try s.testWriteString("👨‍A");

    const row = s.getRow(.{ .screen = 0 });

    // Normal char is a break
    try testing.expect(row.graphemeBreak(0));

    // Emoji with ZWJ is not
    try testing.expect(!row.graphemeBreak(1));
}
