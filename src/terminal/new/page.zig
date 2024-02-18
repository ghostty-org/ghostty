const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const color = @import("../color.zig");
const sgr = @import("../sgr.zig");
const style = @import("style.zig");
const size = @import("size.zig");
const Offset = size.Offset;
const OffsetBuf = size.OffsetBuf;
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
    ///
    /// The backing memory is always zero initialized, so the zero value
    /// of all data within the page must always be valid.
    memory: []align(std.mem.page_size) u8,

    /// The array of rows in the page. The rows are always in row order
    /// (i.e. index 0 is the top row, index 1 is the row below that, etc.)
    rows: Offset(Row),

    /// The array of cells in the page. The cells are NOT in row order,
    /// but they are in column order. To determine the mapping of cells
    /// to row, you must use the `rows` field. From the pointer to the
    /// first column, all cells in that row are laid out in column order.
    cells: Offset(Cell),

    /// The available set of styles in use on this page.
    styles: style.Set,

    /// The capacity of this page.
    capacity: Capacity,

    /// Capacity of this page.
    pub const Capacity = struct {
        /// Number of columns and rows we can know about.
        cols: usize,
        rows: usize,

        /// Number of unique styles that can be used on this page.
        styles: u16,
    };

    /// Initialize a new page, allocating the required backing memory.
    /// It is HIGHLY RECOMMENDED you use a page_allocator as the allocator
    /// but any allocator is allowed.
    pub fn init(alloc: Allocator, cap: Capacity) !Page {
        const l = layout(cap);
        const backing = try alloc.alignedAlloc(u8, std.mem.page_size, l.total_size);
        errdefer alloc.free(backing);

        const buf = OffsetBuf.init(backing);
        return .{
            .memory = backing,
            .rows = buf.member(Row, l.rows_start),
            .cells = buf.member(Cell, l.cells_start),
            .styles = style.Set.init(buf.add(l.styles_start), l.styles_layout),
            .capacity = cap,
        };
    }

    pub fn deinit(self: *Page, alloc: Allocator) void {
        alloc.free(self.memory);
        self.* = undefined;
    }

    const Layout = struct {
        total_size: usize,
        rows_start: usize,
        cells_start: usize,
        styles_start: usize,
        styles_layout: style.Set.Layout,
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

        const total_size = styles_end;

        return .{
            .total_size = total_size,
            .rows_start = rows_start,
            .cells_start = cells_start,
            .styles_start = styles_start,
            .styles_layout = styles_layout,
        };
    }
};

pub const Row = packed struct(u18) {
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
    },
};

/// A cell represents a single terminal grid cell.
///
/// The zero value of this struct must be a valid cell representing empty,
/// since we zero initialize the backing memory for a page.
pub const Cell = packed struct(u32) {
    codepoint: u21 = 0,
    _padding: u11 = 0,
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

test "Page" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var page = try Page.init(alloc, .{
        .cols = 120,
        .rows = 80,
        .styles = 32,
    });
    defer page.deinit(alloc);
}
