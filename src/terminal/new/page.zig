const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;
const fastmem = @import("../../fastmem.zig");
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
const grapheme_chunk_len = 4;
const grapheme_chunk = grapheme_chunk_len * @sizeOf(u21);
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

    /// Clone the contents of this page. This will allocate new memory
    /// using the page allocator. If you want to manage memory manually,
    /// use cloneBuf.
    pub fn clone(self: *const Page) !Page {
        const backing = try std.os.mmap(
            null,
            self.memory.len,
            std.os.PROT.READ | std.os.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        errdefer std.os.munmap(backing);
        return self.cloneBuf(backing);
    }

    /// Clone the entire contents of this page.
    ///
    /// The buffer must be at least the size of self.memory.
    pub fn cloneBuf(self: *const Page, buf: []align(std.mem.page_size) u8) Page {
        assert(buf.len >= self.memory.len);

        // The entire concept behind a page is that everything is stored
        // as offsets so we can do a simple linear copy of the backing
        // memory and copy all the offsets and everything will work.
        var result = self.*;
        result.memory = buf[0..self.memory.len];

        // This is a memcpy. We may want to investigate if there are
        // faster ways to do this (i.e. copy-on-write tricks) but I suspect
        // they'll be slower. I haven't experimented though.
        // std.log.warn("copy bytes={}", .{self.memory.len});
        fastmem.copy(u8, result.memory, self.memory);

        return result;
    }

    /// Clone the contents of another page into this page. The capacities
    /// can be different, but the size of the other page must fit into
    /// this page.
    ///
    /// The y_start and y_end parameters allow you to clone only a portion
    /// of the other page. This is useful for splitting a page into two
    /// or more pages.
    ///
    /// The column count of this page will always be the same as this page.
    /// If the other page has more columns, the extra columns will be
    /// truncated. If the other page has fewer columns, the extra columns
    /// will be zeroed.
    ///
    /// The current page is assumed to be empty. We will not clear any
    /// existing data in the current page.
    pub fn cloneFrom(
        self: *Page,
        other: *const Page,
        y_start: usize,
        y_end: usize,
    ) !void {
        assert(y_start <= y_end);
        assert(y_end <= other.size.rows);
        assert(y_end - y_start <= self.size.rows);
        if (comptime std.debug.runtime_safety) {
            // The current page must be empty.
            assert(self.styles.count(self.memory) == 0);
            assert(self.graphemeCount() == 0);
        }

        const other_rows = other.rows.ptr(other.memory)[y_start..y_end];
        const rows = self.rows.ptr(self.memory)[0 .. y_end - y_start];
        for (rows, other_rows) |*dst_row, *src_row| {
            // Copy all the row metadata but keep our cells offset
            const cells_offset = dst_row.cells;
            dst_row.* = src_row.*;
            dst_row.cells = cells_offset;

            const cell_len = @min(self.size.cols, other.size.cols);
            const other_cells = src_row.cells.ptr(other.memory)[0..cell_len];
            const cells = dst_row.cells.ptr(self.memory)[0..cell_len];

            // If we have no managed memory in the row, we can just copy.
            if (!dst_row.grapheme and !dst_row.styled) {
                fastmem.copy(Cell, cells, other_cells);
                continue;
            }

            // We have managed memory, so we have to do a slower copy to
            // get all of that right.
            for (cells, other_cells) |*dst_cell, *src_cell| {
                dst_cell.* = src_cell.*;
                if (src_cell.hasGrapheme()) {
                    const cps = other.lookupGrapheme(src_cell).?;
                    for (cps) |cp| try self.appendGrapheme(dst_row, dst_cell, cp);
                }
                if (src_cell.style_id != style.default_id) {
                    const other_style = other.styles.lookupId(other.memory, src_cell.style_id).?.*;
                    const md = try self.styles.upsert(self.memory, other_style);
                    md.ref += 1;
                    dst_cell.style_id = md.id;
                }
            }
        }
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

    /// Move a cell from one location to another. This will replace the
    /// previous contents with a blank cell. Because this is a move, this
    /// doesn't allocate and can't fail.
    pub fn moveCells(
        self: *Page,
        src_row: *Row,
        src_left: usize,
        dst_row: *Row,
        dst_left: usize,
        len: usize,
    ) void {
        const src_cells = src_row.cells.ptr(self.memory)[src_left .. src_left + len];
        const dst_cells = dst_row.cells.ptr(self.memory)[dst_left .. dst_left + len];

        // If src has no graphemes, this is very fast.
        const src_grapheme = src_row.grapheme or grapheme: {
            for (src_cells) |c| if (c.hasGrapheme()) break :grapheme true;
            break :grapheme false;
        };
        if (!src_grapheme) {
            fastmem.copy(Cell, dst_cells, src_cells);
            return;
        }

        @panic("TODO: grapheme move");
    }

    /// Clear the cells in the given row. This will reclaim memory used
    /// by graphemes and styles. Note that if the style cleared is still
    /// active, Page cannot know this and it will still be ref counted down.
    /// The best solution for this is to artificially increment the ref count
    /// prior to calling this function.
    pub fn clearCells(
        self: *Page,
        row: *Row,
        left: usize,
        end: usize,
    ) void {
        const cells = row.cells.ptr(self.memory)[left..end];
        if (row.grapheme) {
            for (cells) |*cell| {
                if (cell.hasGrapheme()) self.clearGrapheme(row, cell);
            }
        }

        if (row.styled) {
            for (cells) |*cell| {
                if (cell.style_id == style.default_id) continue;

                if (self.styles.lookupId(self.memory, cell.style_id)) |prev_style| {
                    // Below upsert can't fail because it should already be present
                    const md = self.styles.upsert(self.memory, prev_style.*) catch unreachable;
                    assert(md.ref > 0);
                    md.ref -= 1;
                    if (md.ref == 0) self.styles.remove(self.memory, cell.style_id);
                }
            }

            if (cells.len == self.size.cols) row.styled = false;
        }

        @memset(cells, .{});
    }

    /// Append a codepoint to the given cell as a grapheme.
    pub fn appendGrapheme(self: *Page, row: *Row, cell: *Cell, cp: u21) !void {
        if (comptime std.debug.runtime_safety) assert(cell.hasText());

        const cell_offset = getOffset(Cell, self.memory, cell);
        var map = self.grapheme_map.map(self.memory);

        // If this cell has no graphemes, we can go faster by knowing we
        // need to allocate a new grapheme slice and update the map.
        if (cell.content_tag != .codepoint_grapheme) {
            const cps = try self.grapheme_alloc.alloc(u21, self.memory, 1);
            errdefer self.grapheme_alloc.free(self.memory, cps);
            cps[0] = cp;

            try map.putNoClobber(cell_offset, .{
                .offset = getOffset(u21, self.memory, @ptrCast(cps.ptr)),
                .len = 1,
            });
            errdefer map.remove(cell_offset);

            cell.content_tag = .codepoint_grapheme;
            row.grapheme = true;

            return;
        }

        // The cell already has graphemes. We need to append to the existing
        // grapheme slice and update the map.
        assert(row.grapheme);

        const slice = map.getPtr(cell_offset).?;

        // If our slice len doesn't divide evenly by the grapheme chunk
        // length then we can utilize the additional chunk space.
        if (slice.len % grapheme_chunk_len != 0) {
            const cps = slice.offset.ptr(self.memory);
            cps[slice.len] = cp;
            slice.len += 1;
            return;
        }

        // We are out of chunk space. There is no fast path here. We need
        // to allocate a larger chunk. This is a very slow path. We expect
        // most graphemes to fit within our chunk size.
        const cps = try self.grapheme_alloc.alloc(u21, self.memory, slice.len + 1);
        errdefer self.grapheme_alloc.free(self.memory, cps);
        const old_cps = slice.offset.ptr(self.memory)[0..slice.len];
        fastmem.copy(u21, cps[0..old_cps.len], old_cps);
        cps[slice.len] = cp;
        slice.* = .{
            .offset = getOffset(u21, self.memory, @ptrCast(cps.ptr)),
            .len = slice.len + 1,
        };

        // Free our old chunk
        self.grapheme_alloc.free(self.memory, old_cps);
    }

    /// Returns the codepoints for the given cell. These are the codepoints
    /// in addition to the first codepoint. The first codepoint is NOT
    /// included since it is on the cell itself.
    pub fn lookupGrapheme(self: *const Page, cell: *Cell) ?[]u21 {
        const cell_offset = getOffset(Cell, self.memory, cell);
        const map = self.grapheme_map.map(self.memory);
        const slice = map.get(cell_offset) orelse return null;
        return slice.offset.ptr(self.memory)[0..slice.len];
    }

    /// Clear the graphemes for a given cell.
    pub fn clearGrapheme(self: *Page, row: *Row, cell: *Cell) void {
        if (comptime std.debug.runtime_safety) assert(cell.hasGrapheme());

        // Get our entry in the map, which must exist
        const cell_offset = getOffset(Cell, self.memory, cell);
        var map = self.grapheme_map.map(self.memory);
        const entry = map.getEntry(cell_offset).?;

        // Free our grapheme data
        const cps = entry.value_ptr.offset.ptr(self.memory)[0..entry.value_ptr.len];
        self.grapheme_alloc.free(self.memory, cps);

        // Remove the entry
        map.removeByPtr(entry.key_ptr);

        // Mark that we no longer have graphemes, also search the row
        // to make sure its state is correct.
        cell.content_tag = .codepoint;
        const cells = row.cells.ptr(self.memory)[0..self.size.cols];
        for (cells) |c| if (c.hasGrapheme()) return;
        row.grapheme = false;
    }

    /// Returns the number of graphemes in the page. This isn't the byte
    /// size but the total number of unique cells that have grapheme data.
    pub fn graphemeCount(self: *const Page) usize {
        return self.grapheme_map.map(self.memory).count();
    }

    /// Move graphemes to another cell in the same row.
    pub fn moveGraphemeWithinRow(self: *Page, src: *Cell, dst: *Cell) void {
        // Note: we don't assert src has graphemes here because one of
        // the places we call this is from insertBlanks where the cells have
        // already swapped cell data but not grapheme data.

        // Get our entry in the map, which must exist
        const src_offset = getOffset(Cell, self.memory, src);
        var map = self.grapheme_map.map(self.memory);
        const entry = map.getEntry(src_offset).?;
        const value = entry.value_ptr.*;

        // Remove the entry so we know we have space
        map.removeByPtr(entry.key_ptr);

        // Add the entry for the new cell
        const dst_offset = getOffset(Cell, self.memory, dst);
        map.putAssumeCapacity(dst_offset, value);
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
    .cols = 215,
    .rows = 215,
    .styles = 128,
    .grapheme_bytes = 8192,
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
    /// The cells in the row offset from the page.
    cells: Offset(Cell),

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

    /// True if any of the cells in this row have a ref-counted style.
    /// This can have false positives but never a false negative. Meaning:
    /// this will be set to true the first time a style is used, but it
    /// will not be set to false if the style is no longer used, because
    /// checking for that condition is too expensive.
    ///
    /// Why have this weird false positive flag at all? This makes VT operations
    /// that erase cells (such as insert lines, delete lines, erase chars,
    /// etc.) MUCH MUCH faster in the case that the row was never styled.
    /// At the time of writing this, the speed difference is around 4x.
    styled: bool = false,

    /// The semantic prompt type for this row as specified by the
    /// running program, or "unknown" if it was never set.
    semantic_prompt: SemanticPrompt = .unknown,

    _padding: u25 = 0,

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

/// A cell represents a single terminal grid cell.
///
/// The zero value of this struct must be a valid cell representing empty,
/// since we zero initialize the backing memory for a page.
pub const Cell = packed struct(u64) {
    /// The content tag dictates the active tag in content and possibly
    /// some other behaviors.
    content_tag: ContentTag = .codepoint,

    /// The content of the cell. This is a union based on content_tag.
    content: packed union {
        /// The codepoint that this cell contains. If `grapheme` is false,
        /// then this is the only codepoint in the cell. If `grapheme` is
        /// true, then this is the first codepoint in the grapheme cluster.
        codepoint: u21,

        /// The content is an empty cell with a background color.
        color_palette: u8,
        color_rgb: RGB,
    } = .{ .codepoint = 0 },

    /// The style ID to use for this cell within the style map. Zero
    /// is always the default style so no lookup is required.
    style_id: style.Id = 0,

    /// The wide property of this cell, for wide characters. Characters in
    /// a terminal grid can only be 1 or 2 cells wide. A wide character
    /// is always next to a spacer. This is used to determine both the width
    /// and spacer properties of a cell.
    wide: Wide = .narrow,

    /// Whether this was written with the protection flag set.
    protected: bool = false,

    _padding: u19 = 0,

    pub const ContentTag = enum(u2) {
        /// A single codepoint, could be zero to be empty cell.
        codepoint = 0,

        /// A codepoint that is part of a multi-codepoint grapheme cluster.
        /// The codepoint tag is active in content, but also expect more
        /// codepoints in the grapheme data.
        codepoint_grapheme = 1,

        /// The cell has no text but only a background color. This is an
        /// optimization so that cells with only backgrounds don't take up
        /// style map space and also don't require a style map lookup.
        bg_color_palette = 2,
        bg_color_rgb = 3,
    };

    pub const RGB = packed struct {
        r: u8,
        g: u8,
        b: u8,
    };

    pub const Wide = enum(u2) {
        /// Not a wide character, cell width 1.
        narrow = 0,

        /// Wide character, cell width 2.
        wide = 1,

        /// Spacer after wide character. Do not render.
        spacer_tail = 2,

        /// Spacer at the end of a soft-wrapped line to indicate that a wide
        /// character is continued on the next line.
        spacer_head = 3,
    };

    /// Helper to make a cell that just has a codepoint.
    pub fn init(codepoint: u21) Cell {
        return .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = codepoint },
        };
    }

    pub fn hasText(self: Cell) bool {
        return switch (self.content_tag) {
            .codepoint,
            .codepoint_grapheme,
            => self.content.codepoint != 0,

            .bg_color_palette,
            .bg_color_rgb,
            => false,
        };
    }

    pub fn hasStyling(self: Cell) bool {
        return self.style_id != style.default_id;
    }

    /// Returns true if the cell has no text or styling.
    pub fn isEmpty(self: Cell) bool {
        return switch (self.content_tag) {
            // Textual cells are empty if they have no text and are narrow.
            // The "narrow" requirement is because wide spacers are meaningful.
            .codepoint,
            .codepoint_grapheme,
            => !self.hasText() and self.wide == .narrow,

            .bg_color_palette,
            .bg_color_rgb,
            => false,
        };
    }

    pub fn hasGrapheme(self: Cell) bool {
        return self.content_tag == .codepoint_grapheme;
    }

    /// Returns true if the set of cells has text in it.
    pub fn hasTextAny(cells: []const Cell) bool {
        for (cells) |cell| {
            if (cell.hasText()) return true;
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
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y) },
        };
    }

    // Read it again
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint);
    }
}

test "Page appendGrapheme small" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    const rac = page.getRowAndCell(0, 0);
    rac.cell.* = Cell.init(0x09);

    // One
    try page.appendGrapheme(rac.row, rac.cell, 0x0A);
    try testing.expect(rac.row.grapheme);
    try testing.expect(rac.cell.hasGrapheme());
    try testing.expectEqualSlices(u21, &.{0x0A}, page.lookupGrapheme(rac.cell).?);

    // Two
    try page.appendGrapheme(rac.row, rac.cell, 0x0B);
    try testing.expect(rac.row.grapheme);
    try testing.expect(rac.cell.hasGrapheme());
    try testing.expectEqualSlices(u21, &.{ 0x0A, 0x0B }, page.lookupGrapheme(rac.cell).?);

    // Clear it
    page.clearGrapheme(rac.row, rac.cell);
    try testing.expect(!rac.row.grapheme);
    try testing.expect(!rac.cell.hasGrapheme());
}

test "Page appendGrapheme larger than chunk" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    const rac = page.getRowAndCell(0, 0);
    rac.cell.* = Cell.init(0x09);

    const count = grapheme_chunk_len * 10;
    for (0..count) |i| {
        try page.appendGrapheme(rac.row, rac.cell, @intCast(0x0A + i));
    }

    const cps = page.lookupGrapheme(rac.cell).?;
    try testing.expectEqual(@as(usize, count), cps.len);
    for (0..count) |i| {
        try testing.expectEqual(@as(u21, @intCast(0x0A + i)), cps[i]);
    }
}

test "Page clearGrapheme not all cells" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    const rac = page.getRowAndCell(0, 0);
    rac.cell.* = Cell.init(0x09);
    try page.appendGrapheme(rac.row, rac.cell, 0x0A);

    const rac2 = page.getRowAndCell(1, 0);
    rac2.cell.* = Cell.init(0x09);
    try page.appendGrapheme(rac2.row, rac2.cell, 0x0A);

    // Clear it
    page.clearGrapheme(rac.row, rac.cell);
    try testing.expect(rac.row.grapheme);
    try testing.expect(!rac.cell.hasGrapheme());
    try testing.expect(rac2.cell.hasGrapheme());
}

test "Page clone" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y) },
        };
    }

    // Clone
    var page2 = try page.clone();
    defer page2.deinit();
    try testing.expectEqual(page2.capacity, page.capacity);

    // Read it again
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint);
    }

    // Write again
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 0 },
        };
    }

    // Read it again, should be unchanged
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint);
    }

    // Read the original
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
    }
}

test "Page cloneFrom" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y) },
        };
    }

    // Clone
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    try page2.cloneFrom(&page, 0, page.size.rows);

    // Read it again
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint);
    }

    // Write again
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 0 },
        };
    }

    // Read it again, should be unchanged
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint);
    }

    // Read the original
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
    }
}

test "Page cloneFrom shrink columns" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y) },
        };
    }

    // Clone
    var page2 = try Page.init(.{
        .cols = 5,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    try page2.cloneFrom(&page, 0, page.size.rows);
    try testing.expectEqual(@as(size.CellCountInt, 5), page2.size.cols);

    // Read it again
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint);
    }
}

test "Page cloneFrom partial" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y) },
        };
    }

    // Clone
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    try page2.cloneFrom(&page, 0, 5);

    // Read it again
    for (0..5) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint);
    }
    for (5..page2.size.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
    }
}
