const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const color = @import("../color.zig");
const sgr = @import("../sgr.zig");
const style = @import("style.zig");
const size = @import("size.zig");
const getOffset = size.getOffset;
const Offset = size.Offset;
const OffsetBuf = size.OffsetBuf;
const BitmapAllocator = @import("bitmap_allocator.zig").BitmapAllocator;
const hash_map = @import("hash_map.zig");
const AutoOffsetHashMap = hash_map.AutoOffsetHashMap;
const alignForward = std.mem.alignForward;

/// A page represents a specific section of terminal screen. The primary
/// idea of a page is that it is a fully self-contained unit that can be
/// serialized, copied, etc. as a convenient way to represent a section
/// of the screen.
///
/// This property is useful for renderers which want to copy just the pages
/// for the visible portion of the screen, or for infinite scrollback where
/// we may want to serialize and store pages that are sufficiently far
/// away from the current viewport.
///
/// Pages are always backed by a single contiguous block of memory that is
/// aligned on a page boundary. This makes it easy and fast to copy pages
/// around. Within the contiguous block of memory, the contents of a page are
/// thoughtfully laid out to optimize primarily for terminal IO (VT streams)
/// and to minimize memory usage.
pub const Page = struct {
    comptime {
        // The alignment of our members. We want to ensure that the page
        // alignment is always divisible by this.
        assert(std.mem.page_size % @max(
            @alignOf(Row),
            @alignOf(Cell),
            style.Set.base_align,
        ) == 0);
    }

    /// The backing memory for the page. A page is always made up of a
    /// a single contiguous block of memory that is aligned on a page
    /// boundary and is a multiple of the system page size.
    memory: []align(std.mem.page_size) u8,

    /// The array of rows in the page. The rows are always in row order
    /// (i.e. index 0 is the top row, index 1 is the row below that, etc.)
    rows: Offset(Row),

    /// The array of cells in the page. The cells are NOT in row order,
    /// but they are in column order. To determine the mapping of cells
    /// to row, you must use the `rows` field. From the pointer to the
    /// first column, all cells in that row are laid out in column order.
    cells: Offset(Cell),

    /// The multi-codepoint grapheme data for this page. This is where
    /// any cell that has more than one codepoint will be stored. This is
    /// relatively rare (typically only emoji) so this defaults to a very small
    /// size and we force page realloc when it grows.
    grapheme_alloc: GraphemeAlloc,
    grapheme_map: GraphemeMap,

    /// The available set of styles in use on this page.
    styles: style.Set,

    /// The capacity of this page.
    capacity: Capacity,

    /// The allocator to use for multi-codepoint grapheme data. We use
    /// a chunk size of 4 codepoints. It'd be best to set this empirically
    /// but it is currently set based on vibes. My thinking around 4 codepoints
    /// is that most skin-tone emoji are <= 4 codepoints, letter combiners
    /// are usually <= 4 codepoints, and 4 codepoints is a nice power of two
    /// for alignment.
    const grapheme_chunk = 4 * @sizeOf(u21);
    const GraphemeAlloc = BitmapAllocator(grapheme_chunk);
    const grapheme_count_default = GraphemeAlloc.bitmap_bit_size;
    const grapheme_bytes_default = grapheme_count_default * grapheme_chunk;
    const GraphemeMap = AutoOffsetHashMap(Offset(Cell), Offset(u21).Slice);

    /// Capacity of this page.
    pub const Capacity = struct {
        /// Number of columns and rows we can know about.
        cols: usize,
        rows: usize,

        /// Number of unique styles that can be used on this page.
        styles: u16 = 16,

        /// Number of bytes to allocate for grapheme data.
        grapheme_bytes: usize = grapheme_bytes_default,
    };

    /// Initialize a new page, allocating the required backing memory.
    /// It is HIGHLY RECOMMENDED you use a page_allocator as the allocator
    /// but any allocator is allowed.
    pub fn init(alloc: Allocator, cap: Capacity) !Page {
        const l = layout(cap);
        const backing = try alloc.alignedAlloc(u8, std.mem.page_size, l.total_size);
        errdefer alloc.free(backing);
        @memset(backing, 0);

        const buf = OffsetBuf.init(backing);
        const rows = buf.member(Row, l.rows_start);
        const cells = buf.member(Cell, l.cells_start);

        // We need to go through and initialize all the rows so that
        // they point to a valid offset into the cells, since the rows
        // zero-initialized aren't valid.
        const cells_ptr = cells.ptr(buf)[0 .. cap.cols * cap.rows];
        for (rows.ptr(buf)[0..cap.rows], 0..) |*row, y| {
            const start = y * cap.cols;
            row.* = .{
                .cells = getOffset(Cell, buf, &cells_ptr[start]),
            };
        }

        return .{
            .memory = backing,
            .rows = rows,
            .cells = cells,
            .styles = style.Set.init(
                buf.add(l.styles_start),
                l.styles_layout,
            ),
            .grapheme_alloc = GraphemeAlloc.init(
                buf.add(l.grapheme_alloc_start),
                l.grapheme_alloc_layout,
            ),
            .grapheme_map = GraphemeMap.init(
                buf.add(l.grapheme_map_start),
                l.grapheme_map_layout,
            ),
            .capacity = cap,
        };
    }

    pub fn deinit(self: *Page, alloc: Allocator) void {
        alloc.free(self.memory);
        self.* = undefined;
    }

    /// Get a single row. y must be valid.
    pub fn getRow(self: *const Page, y: usize) *Row {
        assert(y < self.capacity.rows);
        return &self.rows.ptr(self.memory)[y];
    }

    /// Get the cells for a row.
    pub fn getCells(self: *const Page, row: *Row) []Cell {
        if (comptime std.debug.runtime_safety) {
            const rows = self.rows.ptr(self.memory);
            const cells = self.cells.ptr(self.memory);
            assert(@intFromPtr(row) >= @intFromPtr(rows));
            assert(@intFromPtr(row) < @intFromPtr(cells));
        }

        const cells = row.cells.ptr(self.memory);
        return cells[0..self.capacity.cols];
    }

    /// Get the row and cell for the given X/Y within this page.
    pub fn getRowAndCell(self: *const Page, x: usize, y: usize) struct {
        row: *Row,
        cell: *Cell,
    } {
        assert(y < self.capacity.rows);
        assert(x < self.capacity.cols);

        const rows = self.rows.ptr(self.memory);
        const row = &rows[y];
        const cell = &row.cells.ptr(self.memory)[x];

        return .{ .row = row, .cell = cell };
    }

    const Layout = struct {
        total_size: usize,
        rows_start: usize,
        cells_start: usize,
        styles_start: usize,
        styles_layout: style.Set.Layout,
        grapheme_alloc_start: usize,
        grapheme_alloc_layout: GraphemeAlloc.Layout,
        grapheme_map_start: usize,
        grapheme_map_layout: GraphemeMap.Layout,
    };

    /// The memory layout for a page given a desired minimum cols
    /// and rows size.
    fn layout(cap: Capacity) Layout {
        const rows_start = 0;
        const rows_end = rows_start + (cap.rows * @sizeOf(Row));

        const cells_count = cap.cols * cap.rows;
        const cells_start = alignForward(usize, rows_end, @alignOf(Cell));
        const cells_end = cells_start + (cells_count * @sizeOf(Cell));

        const styles_layout = style.Set.layout(cap.styles);
        const styles_start = alignForward(usize, cells_end, style.Set.base_align);
        const styles_end = styles_start + styles_layout.total_size;

        const grapheme_alloc_layout = GraphemeAlloc.layout(cap.grapheme_bytes);
        const grapheme_alloc_start = alignForward(usize, styles_end, GraphemeAlloc.base_align);
        const grapheme_alloc_end = grapheme_alloc_start + grapheme_alloc_layout.total_size;

        const grapheme_count = @divFloor(cap.grapheme_bytes, grapheme_chunk);
        const grapheme_map_layout = GraphemeMap.layout(@intCast(grapheme_count));
        const grapheme_map_start = alignForward(usize, grapheme_alloc_end, GraphemeMap.base_align);
        const grapheme_map_end = grapheme_map_start + grapheme_map_layout.total_size;

        const total_size = grapheme_map_end;

        return .{
            .total_size = total_size,
            .rows_start = rows_start,
            .cells_start = cells_start,
            .styles_start = styles_start,
            .styles_layout = styles_layout,
            .grapheme_alloc_start = grapheme_alloc_start,
            .grapheme_alloc_layout = grapheme_alloc_layout,
            .grapheme_map_start = grapheme_map_start,
            .grapheme_map_layout = grapheme_map_layout,
        };
    }
};

pub const Row = packed struct(u64) {
    _padding: u30 = 0,

    /// The cells in the row offset from the page.
    cells: Offset(Cell),

    /// Flags where we want to pack bits
    flags: packed struct {
        /// True if this row is soft-wrapped. The first cell of the next
        /// row is a continuation of this row.
        wrap: bool = false,

        /// True if the previous row to this one is soft-wrapped and
        /// this row is a continuation of that row.
        wrap_continuation: bool = false,
    } = .{},
};

/// A cell represents a single terminal grid cell.
///
/// The zero value of this struct must be a valid cell representing empty,
/// since we zero initialize the backing memory for a page.
pub const Cell = packed struct(u64) {
    style_id: style.Id = 0,
    codepoint: u21 = 0,
    _padding: u27 = 0,

    /// Returns true if the set of cells has text in it.
    pub fn hasText(cells: []const Cell) bool {
        for (cells) |cell| {
            if (cell.codepoint != 0) return true;
        }

        return false;
    }
};

// Uncomment this when you want to do some math.
// test "Page size calculator" {
//     const total_size = alignForward(
//         usize,
//         Page.layout(.{
//             .cols = 333,
//             .rows = 81,
//             .styles = 32,
//         }).total_size,
//         std.mem.page_size,
//     );
//
//     std.log.warn("total_size={} pages={}", .{
//         total_size,
//         total_size / std.mem.page_size,
//     });
// }

test "Page init" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var page = try Page.init(alloc, .{
        .cols = 120,
        .rows = 80,
        .styles = 32,
    });
    defer page.deinit(alloc);
}

test "Page read and write cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var page = try Page.init(alloc, .{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit(alloc);

    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.codepoint = @intCast(y);
    }

    // Read it again
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.codepoint);
    }
}
