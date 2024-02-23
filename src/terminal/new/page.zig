const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
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

    /// The mapping of cell to grapheme data. The exact mapping is the
    /// cell offset to the grapheme data offset. Therefore, whenever a
    /// cell is moved (i.e. `erase`) then the grapheme data must be updated.
    /// Grapheme data is relatively rare so this is considered a slow
    /// path.
    grapheme_map: GraphemeMap,

    /// The available set of styles in use on this page.
    styles: style.Set,

    /// The current dimensions of the page. The capacity may be larger
    /// than this. This allows us to allocate a larger page than necessary
    /// and also to resize a page smaller witout reallocating.
    size: Size,

    /// The capacity of this page. This is the full size of the backing
    /// memory and is fixed at page creation time.
    capacity: Capacity,

    /// Initialize a new page, allocating the required backing memory.
    /// The size of the initialized page defaults to the full capacity.
    ///
    /// The backing memory is always allocated using mmap directly.
    /// You cannot use custom allocators with this structure because
    /// it is critical to performance that we use mmap.
    pub fn init(cap: Capacity) !Page {
        const l = layout(cap);

        // We use mmap directly to avoid Zig allocator overhead
        // (small but meaningful for this path) and because a private
        // anonymous mmap is guaranteed on Linux and macOS to be zeroed,
        // which is a critical property for us.
        assert(l.total_size % std.mem.page_size == 0);
        const backing = try std.os.mmap(
            null,
            l.total_size,
            std.os.PROT.READ | std.os.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        errdefer std.os.munmap(backing);

        const buf = OffsetBuf.init(backing);
        return initBuf(buf, l);
    }

    /// Initialize a new page using the given backing memory.
    /// It is up to the caller to not call deinit on these pages.
    pub fn initBuf(buf: OffsetBuf, l: Layout) Page {
        const cap = l.capacity;
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
            .memory = @alignCast(buf.start()[0..l.total_size]),
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
            .size = .{ .cols = cap.cols, .rows = cap.rows },
            .capacity = cap,
        };
    }

    /// Deinitialize the page, freeing any backing memory. Do NOT call
    /// this if you allocated the backing memory yourself (i.e. you used
    /// initBuf).
    pub fn deinit(self: *Page) void {
        std.os.munmap(self.memory);
        self.* = undefined;
    }

    /// Get a single row. y must be valid.
    pub fn getRow(self: *const Page, y: usize) *Row {
        assert(y < self.size.rows);
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
        return cells[0..self.size.cols];
    }

    /// Get the row and cell for the given X/Y within this page.
    pub fn getRowAndCell(self: *const Page, x: usize, y: usize) struct {
        row: *Row,
        cell: *Cell,
    } {
        assert(y < self.size.rows);
        assert(x < self.size.cols);

        const rows = self.rows.ptr(self.memory);
        const row = &rows[y];
        const cell = &row.cells.ptr(self.memory)[x];

        return .{ .row = row, .cell = cell };
    }

    pub const Layout = struct {
        total_size: usize,
        rows_start: usize,
        rows_size: usize,
        cells_start: usize,
        cells_size: usize,
        styles_start: usize,
        styles_layout: style.Set.Layout,
        grapheme_alloc_start: usize,
        grapheme_alloc_layout: GraphemeAlloc.Layout,
        grapheme_map_start: usize,
        grapheme_map_layout: GraphemeMap.Layout,
        capacity: Capacity,
    };

    /// The memory layout for a page given a desired minimum cols
    /// and rows size.
    pub fn layout(cap: Capacity) Layout {
        const rows_count: usize = @intCast(cap.rows);
        const rows_start = 0;
        const rows_end: usize = rows_start + (rows_count * @sizeOf(Row));

        const cells_count: usize = @intCast(cap.cols * cap.rows);
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

        const total_size = alignForward(usize, grapheme_map_end, std.mem.page_size);

        return .{
            .total_size = total_size,
            .rows_start = rows_start,
            .rows_size = rows_end - rows_start,
            .cells_start = cells_start,
            .cells_size = cells_end - cells_start,
            .styles_start = styles_start,
            .styles_layout = styles_layout,
            .grapheme_alloc_start = grapheme_alloc_start,
            .grapheme_alloc_layout = grapheme_alloc_layout,
            .grapheme_map_start = grapheme_map_start,
            .grapheme_map_layout = grapheme_map_layout,
            .capacity = cap,
        };
    }
};

/// The standard capacity for a page that doesn't have special
/// requirements. This is enough to support a very large number of cells.
/// The standard capacity is chosen as the fast-path for allocation.
pub const std_capacity: Capacity = .{
    .cols = 250,
    .rows = 250,
    .styles = 128,
    .grapheme_bytes = 1024,
};

/// The size of this page.
pub const Size = struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,
};

/// Capacity of this page.
pub const Capacity = struct {
    /// Number of columns and rows we can know about.
    cols: size.CellCountInt,
    rows: size.CellCountInt,

    /// Number of unique styles that can be used on this page.
    styles: u16 = 16,

    /// Number of bytes to allocate for grapheme data.
    grapheme_bytes: usize = grapheme_bytes_default,

    pub const Adjustment = struct {
        cols: ?size.CellCountInt = null,
    };

    /// Adjust the capacity parameters while retaining the same total size.
    /// Adjustments always happen by limiting the rows in the page. Everything
    /// else can grow. If it is impossible to achieve the desired adjustment,
    /// OutOfMemory is returned.
    pub fn adjust(self: Capacity, req: Adjustment) Allocator.Error!Capacity {
        var adjusted = self;
        if (req.cols) |cols| {
            // The calculations below only work if cells/rows match size.
            assert(@sizeOf(Cell) == @sizeOf(Row));

            // total_size = (Nrows * sizeOf(Row)) + (Nrows * Ncells * sizeOf(Cell))
            // with some algebra:
            // Nrows = total_size / (sizeOf(Row) + (Ncells * sizeOf(Cell)))
            const layout = Page.layout(self);
            const total_size = layout.rows_size + layout.cells_size;
            const denom = @sizeOf(Row) + (@sizeOf(Cell) * @as(usize, @intCast(cols)));
            const new_rows = @divFloor(total_size, denom);

            // If our rows go to zero then we can't fit any row metadata
            // for the desired number of columns.
            if (new_rows == 0) return error.OutOfMemory;

            adjusted.cols = cols;
            adjusted.rows = @intCast(new_rows);
        }

        if (comptime std.debug.runtime_safety) {
            const old_size = Page.layout(self).total_size;
            const new_size = Page.layout(adjusted).total_size;
            assert(new_size == old_size);
        }

        return adjusted;
    }
};

pub const Row = packed struct(u64) {
    _padding: u29 = 0,

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

        /// True if any of the cells in this row have multi-codepoint
        /// grapheme clusters. If this is true, some fast paths are not
        /// possible because erasing for example may need to clear existing
        /// grapheme data.
        grapheme: bool = false,
    } = .{},
};

/// A cell represents a single terminal grid cell.
///
/// The zero value of this struct must be a valid cell representing empty,
/// since we zero initialize the backing memory for a page.
pub const Cell = packed struct(u64) {
    /// The codepoint that this cell contains. If `grapheme` is false,
    /// then this is the only codepoint in the cell. If `grapheme` is
    /// true, then this is the first codepoint in the grapheme cluster.
    codepoint: u21 = 0,

    /// The style ID to use for this cell within the style map. Zero
    /// is always the default style so no lookup is required.
    style_id: style.Id = 0,

    /// This is true if there are additional codepoints in the grapheme
    /// map for this cell to build a multi-codepoint grapheme.
    grapheme: bool = false,

    _padding: u26 = 0,

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
//             .cols = 250,
//             .rows = 250,
//             .styles = 128,
//             .grapheme_bytes = 1024,
//         }).total_size,
//         std.mem.page_size,
//     );
//
//     std.log.warn("total_size={} pages={}", .{
//         total_size,
//         total_size / std.mem.page_size,
//     });
// }

test "Page std size" {
    // We want to ensure that the standard capacity is what we
    // expect it to be. Changing this is fine but should be done with care
    // so we fail a test if it changes.
    const total_size = Page.layout(std_capacity).total_size;
    try testing.expectEqual(@as(usize, 524_288), total_size); // 512 KiB
    //const pages = total_size / std.mem.page_size;
}

test "Page capacity adjust cols down" {
    const original = std_capacity;
    const original_size = Page.layout(original).total_size;
    const adjusted = try original.adjust(.{ .cols = original.cols / 2 });
    const adjusted_size = Page.layout(adjusted).total_size;
    try testing.expectEqual(original_size, adjusted_size);
}

test "Page capacity adjust cols down to 1" {
    const original = std_capacity;
    const original_size = Page.layout(original).total_size;
    const adjusted = try original.adjust(.{ .cols = 1 });
    const adjusted_size = Page.layout(adjusted).total_size;
    try testing.expectEqual(original_size, adjusted_size);
}

test "Page capacity adjust cols up" {
    const original = std_capacity;
    const original_size = Page.layout(original).total_size;
    const adjusted = try original.adjust(.{ .cols = original.cols * 2 });
    const adjusted_size = Page.layout(adjusted).total_size;
    try testing.expectEqual(original_size, adjusted_size);
}

test "Page capacity adjust cols too high" {
    const original = std_capacity;
    try testing.expectError(
        error.OutOfMemory,
        original.adjust(.{ .cols = std.math.maxInt(size.CellCountInt) }),
    );
}

test "Page init" {
    var page = try Page.init(.{
        .cols = 120,
        .rows = 80,
        .styles = 32,
    });
    defer page.deinit();
}

test "Page read and write cells" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

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
