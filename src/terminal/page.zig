const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const assert = std.debug.assert;
const testing = std.testing;
const posix = std.posix;
const fastmem = @import("../fastmem.zig");
const color = @import("color.zig");
const hyperlink = @import("hyperlink.zig");
const kitty = @import("kitty.zig");
const sgr = @import("sgr.zig");
const style = @import("style.zig");
const size = @import("size.zig");
const getOffset = size.getOffset;
const Offset = size.Offset;
const OffsetBuf = size.OffsetBuf;
const BitmapAllocator = @import("bitmap_allocator.zig").BitmapAllocator;
const hash_map = @import("hash_map.zig");
const AutoOffsetHashMap = hash_map.AutoOffsetHashMap;
const alignForward = std.mem.alignForward;
const alignBackward = std.mem.alignBackward;

const log = std.log.scoped(.page);

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

/// The allocator used for shared utf8-encoded strings within a page.
/// Note the chunk size below is the minimum size of a single allocation
/// and requires a single bit of metadata in our bitmap allocator. Therefore
/// it should be tuned carefully (too small and we waste metadata, too large
/// and we have fragmentation). We can probably use a better allocation
/// strategy in the future.
///
/// At the time of writing this, the strings table is only used for OSC8
/// IDs and URIs. IDs are usually short and URIs are usually longer. I chose
/// 32 bytes as a compromise between these two since it represents single
/// domain links quite well and is not too wasteful for short IDs. We can
/// continue to tune this as we see how it's used.
const string_chunk_len = 32;
const string_chunk = string_chunk_len * @sizeOf(u8);
const StringAlloc = BitmapAllocator(string_chunk);
const string_count_default = StringAlloc.bitmap_bit_size;
const string_bytes_default = string_count_default * string_chunk;

/// Default number of hyperlinks we support.
///
/// The cell multiplier is the number of cells per hyperlink entry that
/// we support. A hyperlink can be longer than this multiplier; the multiplier
/// just sets the total capacity to simplify adjustable size metrics.
const hyperlink_count_default = 4;
const hyperlink_bytes_default = hyperlink_count_default * @sizeOf(hyperlink.Set.Item);
const hyperlink_cell_multiplier = 16;

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
        assert(std.heap.page_size_min % @max(
            @alignOf(Row),
            @alignOf(Cell),
            style.Set.base_align,
        ) == 0);
    }

    /// The backing memory for the page. A page is always made up of a
    /// a single contiguous block of memory that is aligned on a page
    /// boundary and is a multiple of the system page size.
    memory: []align(std.heap.page_size_min) u8,

    /// The array of rows in the page. The rows are always in row order
    /// (i.e. index 0 is the top row, index 1 is the row below that, etc.)
    rows: Offset(Row),

    /// The array of cells in the page. The cells are NOT in row order,
    /// but they are in column order. To determine the mapping of cells
    /// to row, you must use the `rows` field. From the pointer to the
    /// first column, all cells in that row are laid out in column order.
    cells: Offset(Cell),

    /// The string allocator for this page used for shared utf-8 encoded
    /// strings. Liveness of strings and memory management is deferred to
    /// the individual use case.
    string_alloc: StringAlloc,

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

    /// The structures used for tracking hyperlinks within the page.
    /// The map maps cell offsets to hyperlink IDs and the IDs are in
    /// the ref counted set. The strings within the hyperlink structures
    /// are allocated in the string allocator.
    hyperlink_map: hyperlink.Map,
    hyperlink_set: hyperlink.Set,

    /// The offset to the first mask of dirty bits in the page.
    ///
    /// The dirty bits is a contiguous array of usize where each bit represents
    /// a row in the page, in order. If the bit is set, then the row is dirty
    /// and requires a redraw. Dirty status is only ever meant to convey that
    /// a cell has changed visually. A cell which changes in a way that doesn't
    /// affect the visual representation may not be marked as dirty.
    ///
    /// Dirty tracking may have false positives but should never have false
    /// negatives. A false negative would result in a visual artifact on the
    /// screen.
    ///
    /// Dirty bits are only ever unset by consumers of a page. The page
    /// structure itself does not unset dirty bits since the page does not
    /// know when a cell has been redrawn.
    ///
    /// As implementation background: it may seem that dirty bits should be
    /// stored elsewhere and not on the page itself, because the only data
    /// that could possibly change is in the active area of a terminal
    /// historically and that area is small compared to the typical scrollback.
    /// My original thinking was to put the dirty bits on Screen instead and
    /// have them only track the active area. However, I decided to put them
    /// into the page directly for a few reasons:
    ///
    ///   1. It's simpler. The page is a self-contained unit and it's nice
    ///      to have all the data for a page in one place.
    ///
    ///   2. It's cheap. Even a very large page might have 1000 rows and
    ///      that's only ~128 bytes of 64-bit integers to track all the dirty
    ///      bits. Compared to the hundreds of kilobytes a typical page
    ///      consumes, this is nothing.
    ///
    ///   3. It's more flexible. If we ever want to implement new terminal
    ///      features that allow non-active area to be dirty, we can do that
    ///      with minimal dirty-tracking work.
    ///
    dirty: Offset(usize),

    /// The current dimensions of the page. The capacity may be larger
    /// than this. This allows us to allocate a larger page than necessary
    /// and also to resize a page smaller without reallocating.
    size: Size,

    /// The capacity of this page. This is the full size of the backing
    /// memory and is fixed at page creation time.
    capacity: Capacity,

    /// If this is true then verifyIntegrity will do nothing. This is
    /// only present with runtime safety enabled.
    pause_integrity_checks: if (build_config.slow_runtime_safety) usize else void =
        if (build_config.slow_runtime_safety) 0 else {},

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
        assert(l.total_size % std.heap.page_size_min == 0);
        const backing = try posix.mmap(
            null,
            l.total_size,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        errdefer posix.munmap(backing);

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
            .dirty = buf.member(usize, l.dirty_start),
            .styles = style.Set.init(
                buf.add(l.styles_start),
                l.styles_layout,
                .{},
            ),
            .string_alloc = .init(
                buf.add(l.string_alloc_start),
                l.string_alloc_layout,
            ),
            .grapheme_alloc = .init(
                buf.add(l.grapheme_alloc_start),
                l.grapheme_alloc_layout,
            ),
            .grapheme_map = .init(
                buf.add(l.grapheme_map_start),
                l.grapheme_map_layout,
            ),
            .hyperlink_map = .init(
                buf.add(l.hyperlink_map_start),
                l.hyperlink_map_layout,
            ),
            .hyperlink_set = .init(
                buf.add(l.hyperlink_set_start),
                l.hyperlink_set_layout,
                .{},
            ),
            .size = .{ .cols = cap.cols, .rows = cap.rows },
            .capacity = cap,
        };
    }

    /// Deinitialize the page, freeing any backing memory. Do NOT call
    /// this if you allocated the backing memory yourself (i.e. you used
    /// initBuf).
    pub fn deinit(self: *Page) void {
        posix.munmap(self.memory);
        self.* = undefined;
    }

    /// Reinitialize the page with the same capacity.
    pub fn reinit(self: *Page) void {
        // We zero the page memory as u64 instead of u8 because
        // we can and it's empirically quite a bit faster.
        @memset(@as([*]u64, @ptrCast(self.memory))[0 .. self.memory.len / 8], 0);
        self.* = initBuf(.init(self.memory), layout(self.capacity));
    }

    pub const IntegrityError = error{
        ZeroRowCount,
        ZeroColCount,
        UnmarkedGraphemeRow,
        MissingGraphemeData,
        InvalidGraphemeCount,
        UnmarkedGraphemeCell,
        MissingStyle,
        UnmarkedStyleRow,
        MismatchedStyleRef,
        InvalidStyleCount,
        MissingHyperlinkData,
        MismatchedHyperlinkRef,
        UnmarkedHyperlinkCell,
        UnmarkedHyperlinkRow,
        InvalidSpacerTailLocation,
        InvalidSpacerHeadLocation,
        UnwrappedSpacerHead,
    };

    /// Temporarily pause integrity checks. This is useful when you are
    /// doing a lot of operations that would trigger integrity check
    /// violations but you know the page will end up in a consistent state.
    pub fn pauseIntegrityChecks(self: *Page, v: bool) void {
        if (build_config.slow_runtime_safety) {
            if (v) {
                self.pause_integrity_checks += 1;
            } else {
                self.pause_integrity_checks -= 1;
            }
        }
    }

    /// A helper that can be used to assert the integrity of the page
    /// when runtime safety is enabled. This is a no-op when runtime
    /// safety is disabled. This uses the libc allocator.
    pub fn assertIntegrity(self: *const Page) void {
        if (comptime build_config.slow_runtime_safety) {
            self.verifyIntegrity(std.heap.c_allocator) catch |err| {
                log.err("page integrity violation, crashing. err={}", .{err});
                @panic("page integrity violation");
            };
        }
    }

    /// Verifies the integrity of the page data. This is not fast,
    /// but it is useful for assertions, deserialization, etc. The
    /// allocator is only used for temporary allocations -- all memory
    /// is freed before this function returns.
    ///
    /// Integrity errors are also logged as warnings.
    pub fn verifyIntegrity(self: *const Page, alloc_gpa: Allocator) !void {
        // Some things that seem like we should check but do not:
        //
        // - We do not check that the style ref count is exact, only that
        //   it is at least what we see. We do this because some fast paths
        //   trim rows without clearing data.
        // - We do not check that styles seen is exactly the same as the
        //   styles count in the page for the same reason as above.
        // - We only check that we saw less graphemes than the total memory
        //   used for the same reason as styles above.
        //

        if (build_config.slow_runtime_safety) {
            if (self.pause_integrity_checks > 0) return;
        }

        if (self.size.rows == 0) {
            log.warn("page integrity violation zero row count", .{});
            return IntegrityError.ZeroRowCount;
        }
        if (self.size.cols == 0) {
            log.warn("page integrity violation zero col count", .{});
            return IntegrityError.ZeroColCount;
        }

        var arena = ArenaAllocator.init(alloc_gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        var graphemes_seen: usize = 0;
        var styles_seen = std.AutoHashMap(style.Id, usize).init(alloc);
        defer styles_seen.deinit();
        var hyperlinks_seen = std.AutoHashMap(hyperlink.Id, usize).init(alloc);
        defer hyperlinks_seen.deinit();

        const grapheme_count = self.graphemeCount();

        const rows = self.rows.ptr(self.memory)[0..self.size.rows];
        for (rows, 0..) |*row, y| {
            const graphemes_start = graphemes_seen;
            const cells = row.cells.ptr(self.memory)[0..self.size.cols];
            for (cells, 0..) |*cell, x| {
                if (cell.hasGrapheme()) {
                    // If a cell has grapheme data, it must be present in
                    // the grapheme map.
                    _ = self.lookupGrapheme(cell) orelse {
                        log.warn(
                            "page integrity violation y={} x={} grapheme data missing",
                            .{ y, x },
                        );
                        return IntegrityError.MissingGraphemeData;
                    };

                    graphemes_seen += 1;
                } else if (grapheme_count > 0) {
                    // It should not have grapheme data if it isn't marked.
                    // The grapheme_count check above is just an optimization
                    // to speed up integrity checks.
                    if (self.lookupGrapheme(cell) != null) {
                        log.warn(
                            "page integrity violation y={} x={} cell not marked as grapheme",
                            .{ y, x },
                        );
                        return IntegrityError.UnmarkedGraphemeCell;
                    }
                }

                if (cell.style_id != style.default_id) {
                    // If a cell has a style, it must be present in the styles
                    // set. Accessing it with `get` asserts that.
                    _ = self.styles.get(
                        self.memory,
                        cell.style_id,
                    );

                    if (!row.styled) {
                        log.warn(
                            "page integrity violation y={} x={} row not marked as styled",
                            .{ y, x },
                        );
                        return IntegrityError.UnmarkedStyleRow;
                    }

                    const gop = try styles_seen.getOrPut(cell.style_id);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                }

                if (cell.hyperlink) {
                    const id = self.lookupHyperlink(cell) orelse {
                        log.warn(
                            "page integrity violation y={} x={} hyperlink data missing",
                            .{ y, x },
                        );
                        return IntegrityError.MissingHyperlinkData;
                    };

                    if (!row.hyperlink) {
                        log.warn(
                            "page integrity violation y={} x={} row not marked as hyperlink",
                            .{ y, x },
                        );
                        return IntegrityError.UnmarkedHyperlinkRow;
                    }

                    const gop = try hyperlinks_seen.getOrPut(id);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;

                    // Hyperlink ID should be valid. This just straight crashes
                    // if this fails due to assertions.
                    _ = self.hyperlink_set.get(self.memory, id);
                } else {
                    // It should not have hyperlink data if it isn't marked
                    if (self.lookupHyperlink(cell) != null) {
                        log.warn(
                            "page integrity violation y={} x={} cell not marked as hyperlink",
                            .{ y, x },
                        );
                        return IntegrityError.UnmarkedHyperlinkCell;
                    }
                }

                switch (cell.wide) {
                    .narrow => {},
                    .wide => {},

                    .spacer_tail => {
                        // Spacer tails can't be at the start because they follow
                        // a wide char.
                        if (x == 0) {
                            log.warn(
                                "page integrity violation y={} x={} spacer tail at start",
                                .{ y, x },
                            );
                            return IntegrityError.InvalidSpacerTailLocation;
                        }

                        // Spacer tails must follow a wide char
                        const prev = cells[x - 1];
                        if (prev.wide != .wide) {
                            log.warn(
                                "page integrity violation y={} x={} spacer tail not following wide",
                                .{ y, x },
                            );
                            return IntegrityError.InvalidSpacerTailLocation;
                        }
                    },

                    .spacer_head => {
                        // Spacer heads must be at the end
                        if (x != self.size.cols - 1) {
                            log.warn(
                                "page integrity violation y={} x={} spacer head not at end",
                                .{ y, x },
                            );
                            return IntegrityError.InvalidSpacerHeadLocation;
                        }

                        // The row must be wrapped
                        if (!row.wrap) {
                            log.warn(
                                "page integrity violation y={} spacer head not wrapped",
                                .{y},
                            );
                            return IntegrityError.UnwrappedSpacerHead;
                        }
                    },
                }
            }

            // Check row grapheme data
            if (graphemes_seen > graphemes_start) {
                // If a cell in a row has grapheme data, the row must
                // be marked as having grapheme data.
                if (!row.grapheme) {
                    log.warn(
                        "page integrity violation y={} grapheme data but row not marked",
                        .{y},
                    );
                    return IntegrityError.UnmarkedGraphemeRow;
                }
            }
        }

        // Our graphemes seen should exactly match the grapheme count
        if (graphemes_seen > self.graphemeCount()) {
            log.warn(
                "page integrity violation grapheme count mismatch expected={} actual={}",
                .{ graphemes_seen, self.graphemeCount() },
            );
            return IntegrityError.InvalidGraphemeCount;
        }

        // Verify all our styles have the correct ref count.
        {
            var it = styles_seen.iterator();
            while (it.next()) |entry| {
                const ref_count = self.styles.refCount(self.memory, entry.key_ptr.*);
                if (ref_count < entry.value_ptr.*) {
                    log.warn(
                        "page integrity violation style ref count mismatch id={} expected={} actual={}",
                        .{ entry.key_ptr.*, entry.value_ptr.*, ref_count },
                    );
                    return IntegrityError.MismatchedStyleRef;
                }
            }
        }

        // Verify all our hyperlinks have the correct ref count.
        {
            var it = hyperlinks_seen.iterator();
            while (it.next()) |entry| {
                const ref_count = self.hyperlink_set.refCount(self.memory, entry.key_ptr.*);
                if (ref_count < entry.value_ptr.*) {
                    log.warn(
                        "page integrity violation hyperlink ref count mismatch id={} expected={} actual={}",
                        .{ entry.key_ptr.*, entry.value_ptr.*, ref_count },
                    );
                    return IntegrityError.MismatchedHyperlinkRef;
                }
            }
        }

        // Verify there are no zombie styles, that is, styles in the
        // set with ref counts > 0, which are not present in the page.
        {
            const styles_table = self.styles.table.ptr(self.memory)[0..self.styles.layout.table_cap];
            const styles_items = self.styles.items.ptr(self.memory)[0..self.styles.layout.cap];

            var zombies: usize = 0;

            for (styles_table) |id| {
                if (id == 0) continue;
                const item = styles_items[id];
                if (item.meta.ref == 0) continue;

                const expected = styles_seen.get(id) orelse 0;
                if (expected > 0) continue;

                if (item.meta.ref > expected) {
                    zombies += 1;
                }
            }

            // NOTE: This is currently disabled because @qwerasd says that
            // certain fast paths can cause this but its okay.
            // Just 1 zombie style might be the cursor style, so ignore it.
            // if (zombies > 1) {
            //     log.warn(
            //         "page integrity violation zombie styles count={}",
            //         .{zombies},
            //     );
            //     return IntegrityError.ZombieStyles;
            // }
        }
    }

    /// Clone the contents of this page. This will allocate new memory
    /// using the page allocator. If you want to manage memory manually,
    /// use cloneBuf.
    pub fn clone(self: *const Page) !Page {
        const backing = try posix.mmap(
            null,
            self.memory.len,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        errdefer posix.munmap(backing);
        return self.cloneBuf(backing);
    }

    /// Clone the entire contents of this page.
    ///
    /// The buffer must be at least the size of self.memory.
    pub fn cloneBuf(self: *const Page, buf: []align(std.heap.page_size_min) u8) Page {
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

    pub const StyleSetError = error{
        StyleSetOutOfMemory,
        StyleSetNeedsRehash,
    };

    pub const HyperlinkError = error{
        StringAllocOutOfMemory,
        HyperlinkSetOutOfMemory,
        HyperlinkSetNeedsRehash,
        HyperlinkMapOutOfMemory,
    };

    pub const GraphemeError = error{
        GraphemeMapOutOfMemory,
        GraphemeAllocOutOfMemory,
    };

    pub const CloneFromError =
        StyleSetError ||
        HyperlinkError ||
        GraphemeError;

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
    pub fn cloneFrom(
        self: *Page,
        other: *const Page,
        y_start: usize,
        y_end: usize,
    ) CloneFromError!void {
        assert(y_start <= y_end);
        assert(y_end <= other.size.rows);
        assert(y_end - y_start <= self.size.rows);

        const other_rows = other.rows.ptr(other.memory)[y_start..y_end];
        const rows = self.rows.ptr(self.memory)[0 .. y_end - y_start];
        const other_dirty_set = other.dirtyBitSet();
        var dirty_set = self.dirtyBitSet();
        for (rows, 0.., other_rows, y_start..) |*dst_row, dst_y, *src_row, src_y| {
            try self.cloneRowFrom(other, dst_row, src_row);
            if (other_dirty_set.isSet(src_y)) dirty_set.set(dst_y);
        }

        // We should remain consistent
        self.assertIntegrity();
    }

    /// Clone a single row from another page into this page.
    pub fn cloneRowFrom(
        self: *Page,
        other: *const Page,
        dst_row: *Row,
        src_row: *const Row,
    ) CloneFromError!void {
        try self.clonePartialRowFrom(
            other,
            dst_row,
            src_row,
            0,
            self.size.cols,
        );
    }

    /// Clone a single row from another page into this page, supporting
    /// partial copy. cloneRowFrom calls this.
    pub fn clonePartialRowFrom(
        self: *Page,
        other: *const Page,
        dst_row: *Row,
        src_row: *const Row,
        x_start: usize,
        x_end_req: usize,
    ) CloneFromError!void {
        // This whole operation breaks integrity until the end.
        self.pauseIntegrityChecks(true);
        defer {
            self.pauseIntegrityChecks(false);
            self.assertIntegrity();
        }

        const cell_len = @min(self.size.cols, other.size.cols);
        const x_end = @min(x_end_req, cell_len);
        assert(x_start <= x_end);
        const other_cells = src_row.cells.ptr(other.memory)[x_start..x_end];
        const cells = dst_row.cells.ptr(self.memory)[x_start..x_end];

        // If our destination has styles or graphemes then we need to
        // clear some state. This will free up the managed memory as well.
        if (dst_row.managedMemory()) self.clearCells(dst_row, x_start, x_end);

        // Copy all the row metadata but keep our cells offset
        dst_row.* = copy: {
            var copy = src_row.*;

            // If we're not copying the full row then we want to preserve
            // some original state from our dst row.
            if ((x_end - x_start) < self.size.cols) {
                copy.wrap = dst_row.wrap;
                copy.wrap_continuation = dst_row.wrap_continuation;
                copy.grapheme = dst_row.grapheme;
                copy.hyperlink = dst_row.hyperlink;
                copy.styled = dst_row.styled;
            }

            // Our cell offset remains the same
            copy.cells = dst_row.cells;

            break :copy copy;
        };

        // If we have no managed memory in the source, then we can just
        // copy it directly.
        if (!src_row.managedMemory()) {
            // This is an integrity check: if the row claims it doesn't
            // have managed memory then all cells must also not have
            // managed memory.
            if (build_config.slow_runtime_safety) {
                for (other_cells) |cell| {
                    assert(!cell.hasGrapheme());
                    assert(!cell.hyperlink);
                    assert(cell.style_id == style.default_id);
                }
            }

            fastmem.copy(Cell, cells, other_cells);
        } else {
            // We have managed memory, so we have to do a slower copy to
            // get all of that right.
            for (cells, other_cells) |*dst_cell, *src_cell| {
                dst_cell.* = src_cell.*;

                // Reset any managed memory markers on the cell so that we don't
                // hit an integrity check if we have to return an error because
                // the page can't fit the new memory.
                dst_cell.hyperlink = false;
                dst_cell.style_id = style.default_id;
                if (dst_cell.content_tag == .codepoint_grapheme) {
                    dst_cell.content_tag = .codepoint;
                }

                if (src_cell.hasGrapheme()) {
                    // To prevent integrity checks flipping. This will
                    // get fixed up when we check the style id below.
                    if (build_config.slow_runtime_safety) {
                        dst_cell.style_id = style.default_id;
                    }

                    // Copy the grapheme codepoints
                    const cps = other.lookupGrapheme(src_cell).?;

                    // Safe to use setGraphemes because we cleared all
                    // managed memory for our destination cell range.
                    try self.setGraphemes(dst_row, dst_cell, cps);
                }
                if (src_cell.hyperlink) hyperlink: {
                    const id = other.lookupHyperlink(src_cell).?;

                    // Fast-path: same page we can add with the same id.
                    if (other == self) {
                        self.hyperlink_set.use(self.memory, id);
                        try self.setHyperlink(dst_row, dst_cell, id);
                        break :hyperlink;
                    }

                    // Slow-path: get the hyperlink from the other page,
                    // add it, and migrate.

                    // If our page can't support an additional cell with
                    // a hyperlink then we have to return an error.
                    if (self.hyperlinkCount() >= self.hyperlinkCapacity()) {
                        // The hyperlink map capacity needs to be increased.
                        return error.HyperlinkMapOutOfMemory;
                    }

                    const other_link = other.hyperlink_set.get(other.memory, id);
                    const dst_id = dst_id: {
                        // First check if the link already exists in our page,
                        // and increment its refcount if so, since we're about
                        // to use it.
                        if (self.hyperlink_set.lookupContext(
                            self.memory,
                            other_link.*,
                            .{ .page = self, .src_page = @constCast(other) },
                        )) |i| {
                            self.hyperlink_set.use(self.memory, i);
                            break :dst_id i;
                        }

                        // If we don't have this link in our page yet then
                        // we need to clone it over and add it to our set.

                        // Clone the link.
                        const dst_link = other_link.dupe(other, self) catch |e| {
                            comptime assert(@TypeOf(e) == error{OutOfMemory});
                            // The string alloc capacity needs to be increased.
                            return error.StringAllocOutOfMemory;
                        };

                        // Add it, preferring to use the same ID as the other
                        // page, since this *probably* speeds up full-page
                        // clones.
                        //
                        // TODO(qwerasd): verify the assumption that `addWithId`
                        // is ever actually useful, I think it may not be.
                        break :dst_id self.hyperlink_set.addWithIdContext(
                            self.memory,
                            dst_link,
                            id,
                            .{ .page = self },
                        ) catch |e| switch (e) {
                            // The hyperlink set capacity needs to be increased.
                            error.OutOfMemory => return error.HyperlinkSetOutOfMemory,

                            // The hyperlink set needs to be rehashed.
                            error.NeedsRehash => return error.HyperlinkSetNeedsRehash,
                        } orelse id;
                    };

                    try self.setHyperlink(dst_row, dst_cell, dst_id);
                }
                if (src_cell.style_id != style.default_id) style: {
                    dst_row.styled = true;

                    if (other == self) {
                        // If it's the same page we don't have to worry about
                        // copying the style, we can use the style ID directly.
                        dst_cell.style_id = src_cell.style_id;
                        self.styles.use(self.memory, dst_cell.style_id);
                        break :style;
                    }

                    // Slow path: Get the style from the other
                    // page and add it to this page's style set.
                    const other_style = other.styles.get(other.memory, src_cell.style_id);
                    dst_cell.style_id = self.styles.addWithId(
                        self.memory,
                        other_style.*,
                        src_cell.style_id,
                    ) catch |e| switch (e) {
                        // The style set capacity needs to be increased.
                        error.OutOfMemory => return error.StyleSetOutOfMemory,

                        // The style set needs to be rehashed.
                        error.NeedsRehash => return error.StyleSetNeedsRehash,
                    } orelse src_cell.style_id;
                }
                if (src_cell.codepoint() == kitty.graphics.unicode.placeholder) {
                    dst_row.kitty_virtual_placeholder = true;
                }
            }
        }

        // If we are growing columns, then we need to ensure spacer heads
        // are cleared.
        if (self.size.cols > other.size.cols) {
            const last = &cells[other.size.cols - 1];
            if (last.wide == .spacer_head) {
                last.wide = .narrow;
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
        if (build_config.slow_runtime_safety) {
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
        defer self.assertIntegrity();

        const src_cells = src_row.cells.ptr(self.memory)[src_left .. src_left + len];
        const dst_cells = dst_row.cells.ptr(self.memory)[dst_left .. dst_left + len];

        // Clear our destination now matter what
        self.clearCells(dst_row, dst_left, dst_left + len);

        // If src has no managed memory, this is very fast.
        if (!src_row.managedMemory()) {
            fastmem.copy(Cell, dst_cells, src_cells);
        } else {
            // Source has graphemes or hyperlinks...
            for (src_cells, dst_cells) |*src, *dst| {
                dst.* = src.*;
                if (src.hasGrapheme()) {
                    // Required for moveGrapheme assertions
                    dst.content_tag = .codepoint;
                    self.moveGrapheme(src, dst);
                    src.content_tag = .codepoint;
                    dst.content_tag = .codepoint_grapheme;
                    dst_row.grapheme = true;
                }
                if (src.hyperlink) {
                    dst.hyperlink = false;
                    self.moveHyperlink(src, dst);
                    dst.hyperlink = true;
                    dst_row.hyperlink = true;
                }
                if (src.codepoint() == kitty.graphics.unicode.placeholder) {
                    dst_row.kitty_virtual_placeholder = true;
                }
            }
        }

        // The destination row has styles if any of the cells are styled
        if (!dst_row.styled) dst_row.styled = styled: for (dst_cells) |c| {
            if (c.style_id != style.default_id) break :styled true;
        } else false;

        // Clear our source row now that the copy is complete. We can NOT
        // use clearCells here because clearCells will garbage collect our
        // styles and graphames but we moved them above.
        //
        // Zero the cells as u64s since empirically this seems
        // to be a bit faster than using @memset(src_cells, .{})
        @memset(@as([]u64, @ptrCast(src_cells)), 0);
        if (src_cells.len == self.size.cols) {
            src_row.grapheme = false;
            src_row.hyperlink = false;
            src_row.styled = false;
            src_row.kitty_virtual_placeholder = false;
        }
    }

    /// Swap two cells within the same row as quickly as possible.
    pub fn swapCells(
        self: *Page,
        src: *Cell,
        dst: *Cell,
    ) void {
        defer self.assertIntegrity();

        // Graphemes are keyed by cell offset so we do have to move them.
        // We do this first so that all our grapheme state is correct.
        if (src.hasGrapheme() or dst.hasGrapheme()) {
            if (src.hasGrapheme() and !dst.hasGrapheme()) {
                self.moveGrapheme(src, dst);
            } else if (!src.hasGrapheme() and dst.hasGrapheme()) {
                self.moveGrapheme(dst, src);
            } else {
                // Both had graphemes, so we have to manually swap
                const src_offset = getOffset(Cell, self.memory, src);
                const dst_offset = getOffset(Cell, self.memory, dst);
                var map = self.grapheme_map.map(self.memory);
                const src_entry = map.getEntry(src_offset).?;
                const dst_entry = map.getEntry(dst_offset).?;
                const src_value = src_entry.value_ptr.*;
                const dst_value = dst_entry.value_ptr.*;
                src_entry.value_ptr.* = dst_value;
                dst_entry.value_ptr.* = src_value;
            }
        }

        // Hyperlinks are keyed by cell offset.
        if (src.hyperlink or dst.hyperlink) {
            if (src.hyperlink and !dst.hyperlink) {
                self.moveHyperlink(src, dst);
            } else if (!src.hyperlink and dst.hyperlink) {
                self.moveHyperlink(dst, src);
            } else {
                // Both had hyperlinks, so we have to manually swap
                const src_offset = getOffset(Cell, self.memory, src);
                const dst_offset = getOffset(Cell, self.memory, dst);
                var map = self.hyperlink_map.map(self.memory);
                const src_entry = map.getEntry(src_offset).?;
                const dst_entry = map.getEntry(dst_offset).?;
                const src_value = src_entry.value_ptr.*;
                const dst_value = dst_entry.value_ptr.*;
                src_entry.value_ptr.* = dst_value;
                dst_entry.value_ptr.* = src_value;
            }
        }

        // Copy the metadata. Note that we do NOT have to worry about
        // styles because styles are keyed by ID and we're preserving the
        // exact ref count and row state here.
        const old_dst = dst.*;
        dst.* = src.*;
        src.* = old_dst;
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
        defer self.assertIntegrity();

        const cells = row.cells.ptr(self.memory)[left..end];

        if (row.grapheme) {
            for (cells) |*cell| {
                if (cell.hasGrapheme()) self.clearGrapheme(row, cell);
            }
        }

        if (row.hyperlink) {
            for (cells) |*cell| {
                if (cell.hyperlink) self.clearHyperlink(row, cell);
            }
        }

        if (row.styled) {
            for (cells) |*cell| {
                if (cell.style_id == style.default_id) continue;

                self.styles.release(self.memory, cell.style_id);
            }

            if (cells.len == self.size.cols) row.styled = false;
        }

        if (row.kitty_virtual_placeholder and
            cells.len == self.size.cols)
        {
            for (cells) |c| {
                if (c.codepoint() == kitty.graphics.unicode.placeholder) {
                    break;
                }
            } else row.kitty_virtual_placeholder = false;
        }

        // Zero the cells as u64s since empirically this seems
        // to be a bit faster than using @memset(cells, .{})
        @memset(@as([]u64, @ptrCast(cells)), 0);
    }

    /// Returns the hyperlink ID for the given cell.
    pub fn lookupHyperlink(self: *const Page, cell: *const Cell) ?hyperlink.Id {
        const cell_offset = getOffset(Cell, self.memory, cell);
        const map = self.hyperlink_map.map(self.memory);
        return map.get(cell_offset);
    }

    /// Clear the hyperlink from the given cell.
    pub fn clearHyperlink(self: *Page, row: *Row, cell: *Cell) void {
        defer self.assertIntegrity();

        // Get our ID
        const cell_offset = getOffset(Cell, self.memory, cell);
        var map = self.hyperlink_map.map(self.memory);
        const entry = map.getEntry(cell_offset) orelse return;

        // Release our usage of this, free memory, unset flag
        self.hyperlink_set.release(self.memory, entry.value_ptr.*);
        map.removeByPtr(entry.key_ptr);
        cell.hyperlink = false;

        // Mark that we no longer have hyperlinks, also search the row
        // to make sure its state is correct.
        const cells = row.cells.ptr(self.memory)[0..self.size.cols];
        for (cells) |c| if (c.hyperlink) return;
        row.hyperlink = false;
    }

    pub const InsertHyperlinkError = error{
        /// string_alloc errors
        StringsOutOfMemory,

        /// hyperlink_set errors
        SetOutOfMemory,
        SetNeedsRehash,
    };

    /// Convert a hyperlink into a page entry, returning the ID.
    ///
    /// This does not de-dupe any strings, so if the URI, explicit ID,
    /// etc. is already in the strings table this will duplicate it.
    ///
    /// To release the memory associated with the given hyperlink,
    /// release the ID from the `hyperlink_set`. If the refcount reaches
    /// zero and the slot is needed then the context will reap the
    /// memory.
    pub fn insertHyperlink(
        self: *Page,
        link: hyperlink.Hyperlink,
    ) InsertHyperlinkError!hyperlink.Id {
        // Insert our URI into the page strings table.
        const page_uri: Offset(u8).Slice = uri: {
            const buf = self.string_alloc.alloc(
                u8,
                self.memory,
                link.uri.len,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.StringsOutOfMemory,
            };
            errdefer self.string_alloc.free(self.memory, buf);
            @memcpy(buf, link.uri);

            break :uri .{
                .offset = size.getOffset(u8, self.memory, &buf[0]),
                .len = link.uri.len,
            };
        };
        errdefer self.string_alloc.free(
            self.memory,
            page_uri.offset.ptr(self.memory)[0..page_uri.len],
        );

        // Allocate an ID for our page memory if we have to.
        const page_id: hyperlink.PageEntry.Id = switch (link.id) {
            .explicit => |id| explicit: {
                const buf = self.string_alloc.alloc(
                    u8,
                    self.memory,
                    id.len,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.StringsOutOfMemory,
                };
                errdefer self.string_alloc.free(self.memory, buf);
                @memcpy(buf, id);

                break :explicit .{
                    .explicit = .{
                        .offset = size.getOffset(u8, self.memory, &buf[0]),
                        .len = id.len,
                    },
                };
            },

            .implicit => |id| .{ .implicit = id },
        };
        errdefer switch (page_id) {
            .implicit => {},
            .explicit => |slice| self.string_alloc.free(
                self.memory,
                slice.offset.ptr(self.memory)[0..slice.len],
            ),
        };

        // Build our entry
        const entry: hyperlink.PageEntry = .{
            .id = page_id,
            .uri = page_uri,
        };

        // Put our hyperlink into the hyperlink set to get an ID
        const id = self.hyperlink_set.addContext(
            self.memory,
            entry,
            .{ .page = self },
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.SetOutOfMemory,
            error.NeedsRehash => return error.SetNeedsRehash,
        };
        errdefer self.hyperlink_set.release(self.memory, id);

        return id;
    }

    /// Set the hyperlink for the given cell. If the cell already has a
    /// hyperlink, then this will handle memory management and refcount
    /// update for the prior hyperlink.
    ///
    /// DOES NOT increment the reference count for the new hyperlink!
    ///
    /// Caller is responsible for updating the refcount in the hyperlink
    /// set as necessary by calling `use` if the id was not acquired with
    /// `add`.
    pub fn setHyperlink(self: *Page, row: *Row, cell: *Cell, id: hyperlink.Id) error{HyperlinkMapOutOfMemory}!void {
        defer self.assertIntegrity();

        const cell_offset = getOffset(Cell, self.memory, cell);
        var map = self.hyperlink_map.map(self.memory);
        const gop = map.getOrPut(cell_offset) catch |e| {
            comptime assert(@TypeOf(e) == error{OutOfMemory});
            // The hyperlink map capacity needs to be increased.
            return error.HyperlinkMapOutOfMemory;
        };

        if (gop.found_existing) {
            // Always release the old hyperlink, because even if it's actually
            // the same as the one we're setting, we'd end up double-counting
            // if we left the reference count be, because the caller does not
            // know whether it's the same and will have increased the count
            // outside of this function.
            self.hyperlink_set.release(self.memory, gop.value_ptr.*);

            // If the hyperlink matches then we don't need to do anything.
            if (gop.value_ptr.* == id) {
                // It is possible for cell hyperlink to be false but row
                // must never be false. The cell hyperlink can be false because
                // in Terminal.print we clear the hyperlink for the cursor cell
                // before writing the cell again, so if someone prints over
                // a cell with a matching hyperlink this state can happen.
                // This is tested in Terminal.zig.
                assert(row.hyperlink);
                cell.hyperlink = true;
                return;
            }
        }

        // Set the hyperlink on the cell and in the map.
        gop.value_ptr.* = id;
        cell.hyperlink = true;
        row.hyperlink = true;
    }

    /// Move the hyperlink from one cell to another. This can't fail
    /// because we avoid any allocations since we're just moving data.
    /// Destination must NOT have a hyperlink.
    fn moveHyperlink(self: *Page, src: *Cell, dst: *Cell) void {
        assert(src.hyperlink);
        assert(!dst.hyperlink);

        const src_offset = getOffset(Cell, self.memory, src);
        const dst_offset = getOffset(Cell, self.memory, dst);
        var map = self.hyperlink_map.map(self.memory);
        const entry = map.getEntry(src_offset).?;
        const value = entry.value_ptr.*;
        map.removeByPtr(entry.key_ptr);
        map.putAssumeCapacity(dst_offset, value);

        // NOTE: We must not set src/dst.hyperlink here because this
        // function is used in various cases where we swap cell contents
        // and its unsafe. The flip side: the caller must be careful
        // to set the proper cell state to represent the move.
    }

    /// Returns the number of hyperlinks in the page. This isn't the byte
    /// size but the total number of unique cells that have hyperlink data.
    pub fn hyperlinkCount(self: *const Page) usize {
        return self.hyperlink_map.map(self.memory).count();
    }

    /// Returns the hyperlink capacity for the page. This isn't the byte
    /// size but the number of unique cells that can have hyperlink data.
    pub fn hyperlinkCapacity(self: *const Page) usize {
        return self.hyperlink_map.map(self.memory).capacity();
    }

    /// Set the graphemes for the given cell. This asserts that the cell
    /// has no graphemes set, and only contains a single codepoint.
    pub fn setGraphemes(
        self: *Page,
        row: *Row,
        cell: *Cell,
        cps: []const u21,
    ) GraphemeError!void {
        defer self.assertIntegrity();

        assert(cell.codepoint() > 0);
        assert(cell.content_tag == .codepoint);

        const cell_offset = getOffset(Cell, self.memory, cell);
        var map = self.grapheme_map.map(self.memory);

        const slice = self.grapheme_alloc.alloc(u21, self.memory, cps.len) catch |e| {
            comptime assert(@TypeOf(e) == error{OutOfMemory});
            // The grapheme alloc capacity needs to be increased.
            return error.GraphemeAllocOutOfMemory;
        };
        errdefer self.grapheme_alloc.free(self.memory, slice);
        @memcpy(slice, cps);

        map.putNoClobber(cell_offset, .{
            .offset = getOffset(u21, self.memory, @ptrCast(slice.ptr)),
            .len = slice.len,
        }) catch |e| {
            comptime assert(@TypeOf(e) == error{OutOfMemory});
            // The grapheme map capacity needs to be increased.
            return error.GraphemeMapOutOfMemory;
        };
        errdefer map.remove(cell_offset);

        cell.content_tag = .codepoint_grapheme;
        row.grapheme = true;

        return;
    }

    /// Append a codepoint to the given cell as a grapheme.
    pub fn appendGrapheme(self: *Page, row: *Row, cell: *Cell, cp: u21) Allocator.Error!void {
        defer self.assertIntegrity();

        if (build_config.slow_runtime_safety) assert(cell.codepoint() != 0);

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
    pub fn lookupGrapheme(self: *const Page, cell: *const Cell) ?[]u21 {
        const cell_offset = getOffset(Cell, self.memory, cell);
        const map = self.grapheme_map.map(self.memory);
        const slice = map.get(cell_offset) orelse return null;
        return slice.offset.ptr(self.memory)[0..slice.len];
    }

    /// Move the graphemes from one cell to another. This can't fail
    /// because we avoid any allocations since we're just moving data.
    ///
    /// WARNING: This will NOT change the content_tag on the cells because
    /// there are scenarios where we want to move graphemes without changing
    /// the content tag. Callers beware but assertIntegrity should catch this.
    fn moveGrapheme(self: *Page, src: *Cell, dst: *Cell) void {
        if (build_config.slow_runtime_safety) {
            assert(src.hasGrapheme());
            assert(!dst.hasGrapheme());
        }

        const src_offset = getOffset(Cell, self.memory, src);
        const dst_offset = getOffset(Cell, self.memory, dst);
        var map = self.grapheme_map.map(self.memory);
        const entry = map.getEntry(src_offset).?;
        const value = entry.value_ptr.*;
        map.removeByPtr(entry.key_ptr);
        map.putAssumeCapacity(dst_offset, value);
    }

    /// Clear the graphemes for a given cell.
    pub fn clearGrapheme(self: *Page, row: *Row, cell: *Cell) void {
        defer self.assertIntegrity();
        if (build_config.slow_runtime_safety) assert(cell.hasGrapheme());

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

    /// Returns the grapheme capacity for the page. This isn't the byte
    /// size but the number of unique cells that can have grapheme data.
    pub fn graphemeCapacity(self: *const Page) usize {
        return self.grapheme_map.map(self.memory).capacity();
    }

    /// Options for encoding the page as UTF-8.
    pub const EncodeUtf8Options = struct {
        /// The range of rows to encode. If end_y is null, then it will
        /// encode to the end of the page.
        start_y: size.CellCountInt = 0,
        end_y: ?size.CellCountInt = null,

        /// If true, this will unwrap soft-wrapped lines. If false, this will
        /// dump the screen as it is visually seen in a rendered window.
        unwrap: bool = true,

        /// Preceding state from encoding the prior page. Used to preserve
        /// blanks properly across multiple pages.
        preceding: TrailingUtf8State = .{},

        /// If non-null, this will be cleared and filled with the x/y
        /// coordinates of each byte in the UTF-8 encoded output.
        /// The index in the array is the byte offset in the output
        /// where 0 is the cursor of the writer when the function is
        /// called.
        cell_map: ?*CellMap = null,

        /// Trailing state for UTF-8 encoding.
        pub const TrailingUtf8State = struct {
            rows: usize = 0,
            cells: usize = 0,
        };
    };

    /// See cell_map
    pub const CellMap = std.ArrayList(CellMapEntry);

    /// The x/y coordinate of a single cell in the cell map.
    pub const CellMapEntry = struct {
        y: size.CellCountInt,
        x: size.CellCountInt,
    };

    /// Encode the page contents as UTF-8.
    ///
    /// If preceding is non-null, then it will be used to initialize our
    /// blank rows/cells count so that we can accumulate blanks across
    /// multiple pages.
    ///
    /// Note: Many tests for this function are done via Screen.dumpString
    /// tests since that function is a thin wrapper around this one and
    /// it makes it easier to test input contents.
    pub fn encodeUtf8(
        self: *const Page,
        writer: anytype,
        opts: EncodeUtf8Options,
    ) anyerror!EncodeUtf8Options.TrailingUtf8State {
        var blank_rows: usize = opts.preceding.rows;
        var blank_cells: usize = opts.preceding.cells;

        const start_y: size.CellCountInt = opts.start_y;
        const end_y: size.CellCountInt = opts.end_y orelse self.size.rows;

        // We can probably avoid this by doing the logic below in a different
        // way. The reason this exists is so that when we end a non-blank
        // line with a newline, we can correctly map the cell map over to
        // the correct x value.
        //
        // For example "A\nB". The cell map for "\n" should be (1, 0).
        // This is tested in Screen.zig so feel free to refactor this.
        var last_x: size.CellCountInt = 0;

        for (start_y..end_y) |y_usize| {
            const y: size.CellCountInt = @intCast(y_usize);
            const row: *Row = self.getRow(y);
            const cells: []const Cell = self.getCells(row);

            // If this row is blank, accumulate to avoid a bunch of extra
            // work later. If it isn't blank, make sure we dump all our
            // blanks.
            if (!Cell.hasTextAny(cells)) {
                blank_rows += 1;
                continue;
            }
            for (1..blank_rows + 1) |i| {
                try writer.writeByte('\n');

                // This is tested in Screen.zig, i.e. one test is
                // "cell map with newlines"
                if (opts.cell_map) |cell_map| {
                    try cell_map.append(.{
                        .x = last_x,
                        .y = @intCast(y - blank_rows + i - 1),
                    });
                    last_x = 0;
                }
            }
            blank_rows = 0;

            // If we're not wrapped, we always add a newline so after
            // the row is printed we can add a newline.
            if (!row.wrap or !opts.unwrap) blank_rows += 1;

            // If the row doesn't continue a wrap then we need to reset
            // our blank cell count.
            if (!row.wrap_continuation or !opts.unwrap) blank_cells = 0;

            // Go through each cell and print it
            for (cells, 0..) |*cell, x_usize| {
                const x: size.CellCountInt = @intCast(x_usize);

                // Skip spacers
                switch (cell.wide) {
                    .narrow, .wide => {},
                    .spacer_head, .spacer_tail => continue,
                }

                // If we have a zero value, then we accumulate a counter. We
                // only want to turn zero values into spaces if we have a non-zero
                // char sometime later.
                if (!cell.hasText()) {
                    blank_cells += 1;
                    continue;
                }
                if (blank_cells > 0) {
                    try writer.writeByteNTimes(' ', blank_cells);
                    if (opts.cell_map) |cell_map| {
                        for (0..blank_cells) |i| try cell_map.append(.{
                            .x = @intCast(x - blank_cells + i),
                            .y = y,
                        });
                    }

                    blank_cells = 0;
                }

                switch (cell.content_tag) {
                    .codepoint => {
                        try writer.print("{u}", .{cell.content.codepoint});
                        if (opts.cell_map) |cell_map| {
                            last_x = x + 1;
                            try cell_map.append(.{
                                .x = x,
                                .y = y,
                            });
                        }
                    },

                    .codepoint_grapheme => {
                        try writer.print("{u}", .{cell.content.codepoint});
                        if (opts.cell_map) |cell_map| {
                            last_x = x + 1;
                            try cell_map.append(.{
                                .x = x,
                                .y = y,
                            });
                        }

                        for (self.lookupGrapheme(cell).?) |cp| {
                            try writer.print("{u}", .{cp});
                            if (opts.cell_map) |cell_map| try cell_map.append(.{
                                .x = x,
                                .y = y,
                            });
                        }
                    },

                    // Unreachable since we do hasText() above
                    .bg_color_palette,
                    .bg_color_rgb,
                    => unreachable,
                }
            }
        }

        return .{ .rows = blank_rows, .cells = blank_cells };
    }

    /// Returns the bitset for the dirty bits on this page.
    ///
    /// The returned value is a DynamicBitSetUnmanaged but it is NOT
    /// actually dynamic; do NOT call resize on this. It is safe to
    /// read and write but do not resize it.
    pub fn dirtyBitSet(self: *const Page) std.DynamicBitSetUnmanaged {
        return .{
            .bit_length = self.capacity.rows,
            .masks = self.dirty.ptr(self.memory),
        };
    }

    /// Returns true if the given row is dirty. This is NOT very
    /// efficient if you're checking many rows and you should use
    /// dirtyBitSet directly instead.
    pub fn isRowDirty(self: *const Page, y: usize) bool {
        return self.dirtyBitSet().isSet(y);
    }

    /// Returns true if this page is dirty at all. If you plan on
    /// checking any additional rows, you should use dirtyBitSet and
    /// check this on your own so you have the set available.
    pub fn isDirty(self: *const Page) bool {
        return self.dirtyBitSet().findFirstSet() != null;
    }

    pub const Layout = struct {
        total_size: usize,
        rows_start: usize,
        rows_size: usize,
        cells_start: usize,
        cells_size: usize,
        dirty_start: usize,
        dirty_size: usize,
        styles_start: usize,
        styles_layout: style.Set.Layout,
        grapheme_alloc_start: usize,
        grapheme_alloc_layout: GraphemeAlloc.Layout,
        grapheme_map_start: usize,
        grapheme_map_layout: GraphemeMap.Layout,
        string_alloc_start: usize,
        string_alloc_layout: StringAlloc.Layout,
        hyperlink_map_start: usize,
        hyperlink_map_layout: hyperlink.Map.Layout,
        hyperlink_set_start: usize,
        hyperlink_set_layout: hyperlink.Set.Layout,
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

        // The division below cannot fail because our row count cannot
        // exceed the maximum value of usize.
        const dirty_bit_length: usize = rows_count;
        const dirty_usize_length: usize = std.math.divCeil(
            usize,
            dirty_bit_length,
            @bitSizeOf(usize),
        ) catch unreachable;
        const dirty_start = alignForward(usize, cells_end, @alignOf(usize));
        const dirty_end: usize = dirty_start + (dirty_usize_length * @sizeOf(usize));

        const styles_layout: style.Set.Layout = .init(cap.styles);
        const styles_start = alignForward(usize, dirty_end, style.Set.base_align);
        const styles_end = styles_start + styles_layout.total_size;

        const grapheme_alloc_layout = GraphemeAlloc.layout(cap.grapheme_bytes);
        const grapheme_alloc_start = alignForward(usize, styles_end, GraphemeAlloc.base_align);
        const grapheme_alloc_end = grapheme_alloc_start + grapheme_alloc_layout.total_size;

        const grapheme_count = @divFloor(cap.grapheme_bytes, grapheme_chunk);
        const grapheme_map_layout = GraphemeMap.layout(@intCast(grapheme_count));
        const grapheme_map_start = alignForward(usize, grapheme_alloc_end, GraphemeMap.base_align);
        const grapheme_map_end = grapheme_map_start + grapheme_map_layout.total_size;

        const string_layout = StringAlloc.layout(cap.string_bytes);
        const string_start = alignForward(usize, grapheme_map_end, StringAlloc.base_align);
        const string_end = string_start + string_layout.total_size;

        const hyperlink_count = @divFloor(cap.hyperlink_bytes, @sizeOf(hyperlink.Set.Item));
        const hyperlink_set_layout: hyperlink.Set.Layout = .init(@intCast(hyperlink_count));
        const hyperlink_set_start = alignForward(usize, string_end, hyperlink.Set.base_align);
        const hyperlink_set_end = hyperlink_set_start + hyperlink_set_layout.total_size;

        const hyperlink_map_count: u32 = count: {
            if (hyperlink_count == 0) break :count 0;
            const mult = std.math.cast(
                u32,
                hyperlink_count * hyperlink_cell_multiplier,
            ) orelse break :count std.math.maxInt(u32);
            break :count std.math.ceilPowerOfTwoAssert(u32, mult);
        };
        const hyperlink_map_layout = hyperlink.Map.layout(hyperlink_map_count);
        const hyperlink_map_start = alignForward(usize, hyperlink_set_end, hyperlink.Map.base_align);
        const hyperlink_map_end = hyperlink_map_start + hyperlink_map_layout.total_size;

        const total_size = alignForward(usize, hyperlink_map_end, std.heap.page_size_min);

        return .{
            .total_size = total_size,
            .rows_start = rows_start,
            .rows_size = rows_end - rows_start,
            .cells_start = cells_start,
            .cells_size = cells_end - cells_start,
            .dirty_start = dirty_start,
            .dirty_size = dirty_end - dirty_start,
            .styles_start = styles_start,
            .styles_layout = styles_layout,
            .grapheme_alloc_start = grapheme_alloc_start,
            .grapheme_alloc_layout = grapheme_alloc_layout,
            .grapheme_map_start = grapheme_map_start,
            .grapheme_map_layout = grapheme_map_layout,
            .string_alloc_start = string_start,
            .string_alloc_layout = string_layout,
            .hyperlink_map_start = hyperlink_map_start,
            .hyperlink_map_layout = hyperlink_map_layout,
            .hyperlink_set_start = hyperlink_set_start,
            .hyperlink_set_layout = hyperlink_set_layout,
            .capacity = cap,
        };
    }
};

/// The standard capacity for a page that doesn't have special
/// requirements. This is enough to support a very large number of cells.
/// The standard capacity is chosen as the fast-path for allocation since
/// pages of standard capacity use a pooled allocator instead of single-use
/// mmaps.
pub const std_capacity: Capacity = .{
    .cols = 215,
    .rows = 215,
    .styles = 128,
    .grapheme_bytes = if (builtin.is_test) 512 else 8192,
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
    styles: usize = 16,

    /// Number of bytes to allocate for hyperlink data. Note that the
    /// amount of data used for hyperlinks in total is more than this because
    /// hyperlinks use string data as well as a small amount of lookup metadata.
    /// This number is a rough approximation.
    hyperlink_bytes: usize = hyperlink_bytes_default,

    /// Number of bytes to allocate for grapheme data.
    grapheme_bytes: usize = grapheme_bytes_default,

    /// Number of bytes to allocate for strings.
    string_bytes: usize = string_bytes_default,

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
            // The math below only works if there is no alignment gap between
            // the end of the rows array and the start of the cells array.
            //
            // To guarantee this, we assert that Row's size is a multiple of
            // Cell's alignment, so that any length array of Rows will end on
            // a valid alignment for the start of the Cell array.
            assert(@sizeOf(Row) % @alignOf(Cell) == 0);

            const layout = Page.layout(self);

            // In order to determine the amount of space in the page available
            // for rows & cells (which will allow us to calculate the number of
            // rows we can fit at a certain column width) we need to layout the
            // "meta" members of the page (i.e. everything else) from the end.
            const hyperlink_map_start = alignBackward(usize, layout.total_size - layout.hyperlink_map_layout.total_size, hyperlink.Map.base_align);
            const hyperlink_set_start = alignBackward(usize, hyperlink_map_start - layout.hyperlink_set_layout.total_size, hyperlink.Set.base_align);
            const string_alloc_start = alignBackward(usize, hyperlink_set_start - layout.string_alloc_layout.total_size, StringAlloc.base_align);
            const grapheme_map_start = alignBackward(usize, string_alloc_start - layout.grapheme_map_layout.total_size, GraphemeMap.base_align);
            const grapheme_alloc_start = alignBackward(usize, grapheme_map_start - layout.grapheme_alloc_layout.total_size, GraphemeAlloc.base_align);
            const styles_start = alignBackward(usize, grapheme_alloc_start - layout.styles_layout.total_size, style.Set.base_align);

            // The size per row is:
            //   - The row metadata itself
            //   - The cells per row (n=cols)
            //   - 1 bit for dirty tracking
            const bits_per_row: usize = size: {
                var bits: usize = @bitSizeOf(Row); // Row metadata
                bits += @bitSizeOf(Cell) * @as(usize, @intCast(cols)); // Cells (n=cols)
                bits += 1; // The dirty bit
                break :size bits;
            };
            const available_bits: usize = styles_start * 8;
            const new_rows: usize = @divFloor(available_bits, bits_per_row);

            // If our rows go to zero then we can't fit any row metadata
            // for the desired number of columns.
            if (new_rows == 0) return error.OutOfMemory;

            adjusted.cols = cols;
            adjusted.rows = @intCast(new_rows);
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

    /// True if any of the cells in this row are part of a hyperlink.
    /// This is similar to styled: it can have false positives but never
    /// false negatives. This is used to optimize hyperlink operations.
    hyperlink: bool = false,

    /// The semantic prompt type for this row as specified by the
    /// running program, or "unknown" if it was never set.
    semantic_prompt: SemanticPrompt = .unknown,

    /// True if this row contains a virtual placeholder for the Kitty
    /// graphics protocol. (U+10EEEE)
    kitty_virtual_placeholder: bool = false,

    _padding: u23 = 0,

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

    /// Returns true if this row has any managed memory outside of the
    /// row structure (graphemes, styles, etc.)
    fn managedMemory(self: Row) bool {
        return self.grapheme or self.styled or self.hyperlink;
    }
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

    /// Whether this cell is a hyperlink. If this is true then you must
    /// look up the hyperlink ID in the page hyperlink_map and the ID in
    /// the hyperlink_set to get the actual hyperlink data.
    hyperlink: bool = false,

    _padding: u18 = 0,

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
    pub fn init(cp: u21) Cell {
        return .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = cp },
        };
    }

    pub fn isZero(self: Cell) bool {
        return @as(u64, @bitCast(self)) == 0;
    }

    /// Returns true if this cell represents a cell with text to render.
    ///
    /// Cases this returns false:
    ///   - Cell text is blank
    ///   - Cell is styled but only with a background color and no text
    ///   - Cell has a unicode placeholder for Kitty graphics protocol
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

    pub fn codepoint(self: Cell) u21 {
        return switch (self.content_tag) {
            .codepoint,
            .codepoint_grapheme,
            => self.content.codepoint,

            .bg_color_palette,
            .bg_color_rgb,
            => 0,
        };
    }

    /// The width in grid cells that this cell takes up.
    pub fn gridWidth(self: Cell) u2 {
        return switch (self.wide) {
            .narrow, .spacer_head, .spacer_tail => 1,
            .wide => 2,
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
//         std.heap.page_size_min,
//     );
//
//     std.log.warn("total_size={} pages={}", .{
//         total_size,
//         total_size / std.heap.page_size_min,
//     });
// }
//
// test "Page std size" {
//     // We want to ensure that the standard capacity is what we
//     // expect it to be. Changing this is fine but should be done with care
//     // so we fail a test if it changes.
//     const total_size = Page.layout(std_capacity).total_size;
//     try testing.expectEqual(@as(usize, 524_288), total_size); // 512 KiB
//     //const pages = total_size / std.heap.page_size_min;
// }

test "Cell is zero by default" {
    const cell = Cell.init(0);
    const cell_int: u64 = @bitCast(cell);
    try std.testing.expectEqual(@as(u64, 0), cell_int);
}

test "Page capacity adjust cols down" {
    const original = std_capacity;
    const original_size = Page.layout(original).total_size;
    const adjusted = try original.adjust(.{ .cols = original.cols / 2 });
    const adjusted_size = Page.layout(adjusted).total_size;
    try testing.expectEqual(original_size, adjusted_size);
    // If we layout a page with 1 more row and it's still the same size
    // then adjust is not producing enough rows.
    var bigger = adjusted;
    bigger.rows += 1;
    const bigger_size = Page.layout(bigger).total_size;
    try testing.expect(bigger_size > original_size);
}

test "Page capacity adjust cols down to 1" {
    const original = std_capacity;
    const original_size = Page.layout(original).total_size;
    const adjusted = try original.adjust(.{ .cols = 1 });
    const adjusted_size = Page.layout(adjusted).total_size;
    try testing.expectEqual(original_size, adjusted_size);
    // If we layout a page with 1 more row and it's still the same size
    // then adjust is not producing enough rows.
    var bigger = adjusted;
    bigger.rows += 1;
    const bigger_size = Page.layout(bigger).total_size;
    try testing.expect(bigger_size > original_size);
}

test "Page capacity adjust cols up" {
    const original = std_capacity;
    const original_size = Page.layout(original).total_size;
    const adjusted = try original.adjust(.{ .cols = original.cols * 2 });
    const adjusted_size = Page.layout(adjusted).total_size;
    try testing.expectEqual(original_size, adjusted_size);
    // If we layout a page with 1 more row and it's still the same size
    // then adjust is not producing enough rows.
    var bigger = adjusted;
    bigger.rows += 1;
    const bigger_size = Page.layout(bigger).total_size;
    try testing.expect(bigger_size > original_size);
}

test "Page capacity adjust cols sweep" {
    var cap = std_capacity;
    const original_cols = cap.cols;
    const original_size = Page.layout(cap).total_size;
    for (1..original_cols * 2) |c| {
        cap = try cap.adjust(.{ .cols = @as(u16, @intCast(c)) });
        const adjusted_size = Page.layout(cap).total_size;
        try testing.expectEqual(original_size, adjusted_size);
        // If we layout a page with 1 more row and it's still the same size
        // then adjust is not producing enough rows.
        var bigger = cap;
        bigger.rows += 1;
        const bigger_size = Page.layout(bigger).total_size;
        try testing.expect(bigger_size > original_size);
    }
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

    // Dirty set should be empty
    const dirty = page.dirtyBitSet();
    try std.testing.expectEqual(@as(usize, 0), dirty.count());
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
    rac.cell.* = .init(0x09);

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
    rac.cell.* = .init(0x09);

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
    rac.cell.* = .init(0x09);
    try page.appendGrapheme(rac.row, rac.cell, 0x0A);

    const rac2 = page.getRowAndCell(1, 0);
    rac2.cell.* = .init(0x09);
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

test "Page cloneFrom hyperlinks exact capacity" {
    var page = try Page.init(.{
        .cols = 50,
        .rows = 50,
    });
    defer page.deinit();

    // Ensure our page can accommodate the capacity.
    const hyperlink_cap = page.hyperlinkCapacity();
    try testing.expect(hyperlink_cap <= page.size.cols * page.size.rows);

    // Create a hyperlink.
    const hyperlink_id = try page.insertHyperlink(.{
        .id = .{ .implicit = 0 },
        .uri = "https://example.com",
    });

    // Fill the exact cap with cells.
    fill: for (0..page.size.cols) |x| {
        for (0..page.size.rows) |y| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 42 },
            };
            try page.setHyperlink(rac.row, rac.cell, hyperlink_id);
            page.hyperlink_set.use(page.memory, hyperlink_id);

            if (page.hyperlinkCount() == hyperlink_cap) {
                break :fill;
            }
        }
    }
    try testing.expectEqual(page.hyperlinkCount(), page.hyperlinkCapacity());

    // Clone the full page
    var page2 = try Page.init(page.capacity);
    defer page2.deinit();
    try page2.cloneFrom(&page, 0, page.size.rows);

    // We should have the same number of hyperlinks
    try testing.expectEqual(page2.hyperlinkCount(), page.hyperlinkCount());
}

test "Page cloneFrom graphemes" {
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
            .content = .{ .codepoint = @intCast(y + 1) },
        };
        try page.appendGrapheme(rac.row, rac.cell, 0x0A);
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
        try testing.expectEqual(@as(u21, @intCast(y + 1)), rac.cell.content.codepoint);
        try testing.expect(rac.row.grapheme);
        try testing.expect(rac.cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{0x0A}, page2.lookupGrapheme(rac.cell).?);
    }

    // Write again
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        page.clearGrapheme(rac.row, rac.cell);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 0 },
        };
    }

    // Read it again, should be unchanged
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y + 1)), rac.cell.content.codepoint);
        try testing.expect(rac.row.grapheme);
        try testing.expect(rac.cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{0x0A}, page2.lookupGrapheme(rac.cell).?);
    }

    // Read the original
    for (0..page.capacity.rows) |y| {
        const rac = page.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
    }
}

test "Page cloneFrom frees dst graphemes" {
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
            .content = .{ .codepoint = @intCast(y + 1) },
        };
    }

    // Clone
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y + 1) },
        };
        try page2.appendGrapheme(rac.row, rac.cell, 0x0A);
    }

    // Clone from page which has no graphemes.
    try page2.cloneFrom(&page, 0, page.size.rows);

    // Read it again
    for (0..page2.capacity.rows) |y| {
        const rac = page2.getRowAndCell(1, y);
        try testing.expectEqual(@as(u21, @intCast(y + 1)), rac.cell.content.codepoint);
        try testing.expect(!rac.row.grapheme);
        try testing.expect(!rac.cell.hasGrapheme());
    }
    try testing.expectEqual(@as(usize, 0), page2.graphemeCount());
}

test "Page cloneRowFrom partial" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    {
        const y = 0;
        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x + 1) },
            };
        }
    }

    // Clone
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    try page2.clonePartialRowFrom(
        &page,
        page2.getRow(0),
        page.getRow(0),
        2,
        8,
    );

    // Read it again
    {
        const y = 0;
        for (0..page2.size.cols) |x| {
            const expected: u21 = if (x >= 2 and x < 8) @intCast(x + 1) else 0;
            const rac = page2.getRowAndCell(x, y);
            try testing.expectEqual(expected, rac.cell.content.codepoint);
        }
    }
}

test "Page cloneRowFrom partial grapheme in non-copied source region" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    {
        const y = 0;
        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x + 1) },
            };
        }
        {
            const rac = page.getRowAndCell(0, y);
            try page.appendGrapheme(rac.row, rac.cell, 0x0A);
        }
        {
            const rac = page.getRowAndCell(9, y);
            try page.appendGrapheme(rac.row, rac.cell, 0x0A);
        }
    }
    try testing.expectEqual(@as(usize, 2), page.graphemeCount());

    // Clone
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    try page2.clonePartialRowFrom(
        &page,
        page2.getRow(0),
        page.getRow(0),
        2,
        8,
    );

    // Read it again
    {
        const y = 0;
        for (0..page2.size.cols) |x| {
            const expected: u21 = if (x >= 2 and x < 8) @intCast(x + 1) else 0;
            const rac = page2.getRowAndCell(x, y);
            try testing.expectEqual(expected, rac.cell.content.codepoint);
            try testing.expect(!rac.cell.hasGrapheme());
        }
        {
            const rac = page2.getRowAndCell(9, y);
            try testing.expect(!rac.row.grapheme);
        }
    }
    try testing.expectEqual(@as(usize, 0), page2.graphemeCount());
}

test "Page cloneRowFrom partial grapheme in non-copied dest region" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    {
        const y = 0;
        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x + 1) },
            };
        }
    }
    try testing.expectEqual(@as(usize, 0), page.graphemeCount());

    // Clone
    var page2 = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page2.deinit();
    {
        const y = 0;
        for (0..page2.size.cols) |x| {
            const rac = page2.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 0xBB },
            };
        }
        {
            const rac = page2.getRowAndCell(0, y);
            try page2.appendGrapheme(rac.row, rac.cell, 0x0A);
        }
        {
            const rac = page2.getRowAndCell(9, y);
            try page2.appendGrapheme(rac.row, rac.cell, 0x0A);
        }
    }
    try page2.clonePartialRowFrom(
        &page,
        page2.getRow(0),
        page.getRow(0),
        2,
        8,
    );

    // Read it again
    {
        const y = 0;
        for (0..page2.size.cols) |x| {
            const expected: u21 = if (x >= 2 and x < 8) @intCast(x + 1) else 0xBB;
            const rac = page2.getRowAndCell(x, y);
            try testing.expectEqual(expected, rac.cell.content.codepoint);
        }
        {
            const rac = page2.getRowAndCell(9, y);
            try testing.expect(rac.row.grapheme);
        }
    }
    try testing.expectEqual(@as(usize, 2), page2.graphemeCount());
}

test "Page cloneRowFrom partial hyperlink in same page copy" {
    var page = try Page.init(.{ .cols = 10, .rows = 10 });
    defer page.deinit();

    // We need to create a hyperlink.
    const hyperlink_id = try page.hyperlink_set.addContext(
        page.memory,
        .{ .id = .{ .implicit = 0 }, .uri = .{} },
        .{ .page = &page },
    );

    // Write
    {
        const y = 0;
        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x + 1) },
            };
        }

        // Hyperlink in a single cell
        {
            const rac = page.getRowAndCell(7, y);
            try page.setHyperlink(rac.row, rac.cell, hyperlink_id);
        }
    }
    try testing.expectEqual(@as(usize, 1), page.hyperlinkCount());

    // Clone into the same page
    try page.clonePartialRowFrom(
        &page,
        page.getRow(1),
        page.getRow(0),
        2,
        8,
    );

    // Read it again
    {
        const y = 1;
        for (0..page.size.cols) |x| {
            const expected: u21 = if (x >= 2 and x < 8) @intCast(x + 1) else 0;
            const rac = page.getRowAndCell(x, y);
            try testing.expectEqual(expected, rac.cell.content.codepoint);
        }
        {
            const rac = page.getRowAndCell(7, y);
            try testing.expect(rac.row.hyperlink);
            try testing.expect(rac.cell.hyperlink);
        }
    }
    try testing.expectEqual(@as(usize, 2), page.hyperlinkCount());
}

test "Page cloneRowFrom partial hyperlink in same page omit" {
    var page = try Page.init(.{ .cols = 10, .rows = 10 });
    defer page.deinit();

    // We need to create a hyperlink.
    const hyperlink_id = try page.hyperlink_set.addContext(
        page.memory,
        .{ .id = .{ .implicit = 0 }, .uri = .{} },
        .{ .page = &page },
    );

    // Write
    {
        const y = 0;
        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x + 1) },
            };
        }

        // Hyperlink in a single cell
        {
            const rac = page.getRowAndCell(7, y);
            try page.setHyperlink(rac.row, rac.cell, hyperlink_id);
        }
    }
    try testing.expectEqual(@as(usize, 1), page.hyperlinkCount());

    // Clone into the same page
    try page.clonePartialRowFrom(
        &page,
        page.getRow(1),
        page.getRow(0),
        2,
        6,
    );

    // Read it again
    {
        const y = 1;
        for (0..page.size.cols) |x| {
            const expected: u21 = if (x >= 2 and x < 6) @intCast(x + 1) else 0;
            const rac = page.getRowAndCell(x, y);
            try testing.expectEqual(expected, rac.cell.content.codepoint);
        }
        {
            const rac = page.getRowAndCell(7, y);
            try testing.expect(!rac.row.hyperlink);
            try testing.expect(!rac.cell.hyperlink);
        }
    }
    try testing.expectEqual(@as(usize, 1), page.hyperlinkCount());
}

test "Page moveCells text-only" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    for (0..page.capacity.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(x + 1) },
        };
    }

    const src = page.getRow(0);
    const dst = page.getRow(1);
    page.moveCells(src, 0, dst, 0, page.capacity.cols);

    // New rows should have text
    for (0..page.capacity.cols) |x| {
        const rac = page.getRowAndCell(x, 1);
        try testing.expectEqual(
            @as(u21, @intCast(x + 1)),
            rac.cell.content.codepoint,
        );
    }

    // Old row should be blank
    for (0..page.capacity.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        try testing.expectEqual(
            @as(u21, 0),
            rac.cell.content.codepoint,
        );
    }
}

test "Page moveCells graphemes" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(x + 1) },
        };
        try page.appendGrapheme(rac.row, rac.cell, 0x0A);
    }
    const original_count = page.graphemeCount();

    const src = page.getRow(0);
    const dst = page.getRow(1);
    page.moveCells(src, 0, dst, 0, page.size.cols);
    try testing.expectEqual(original_count, page.graphemeCount());

    // New rows should have text
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 1);
        try testing.expectEqual(
            @as(u21, @intCast(x + 1)),
            rac.cell.content.codepoint,
        );
        try testing.expectEqualSlices(
            u21,
            &.{0x0A},
            page.lookupGrapheme(rac.cell).?,
        );
    }

    // Old row should be blank
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        try testing.expectEqual(
            @as(u21, 0),
            rac.cell.content.codepoint,
        );
    }
}

test "Page verifyIntegrity graphemes good" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(x + 1) },
        };
        try page.appendGrapheme(rac.row, rac.cell, 0x0A);
    }

    try page.verifyIntegrity(testing.allocator);
}

test "Page verifyIntegrity grapheme row not marked" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(x + 1) },
        };
        try page.appendGrapheme(rac.row, rac.cell, 0x0A);
    }

    // Make invalid by unmarking the row
    page.getRow(0).grapheme = false;

    try testing.expectError(
        Page.IntegrityError.UnmarkedGraphemeRow,
        page.verifyIntegrity(testing.allocator),
    );
}

test "Page verifyIntegrity styles good" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Upsert a style we'll use
    const id = try page.styles.add(page.memory, .{ .flags = .{
        .bold = true,
    } });

    // Write
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.row.styled = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(x + 1) },
            .style_id = id,
        };
        page.styles.use(page.memory, id);
    }

    // The original style add would have incremented the
    // ref count too, so release it to balance that out.
    page.styles.release(page.memory, id);

    try page.verifyIntegrity(testing.allocator);
}

test "Page verifyIntegrity styles ref count mismatch" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Upsert a style we'll use
    const id = try page.styles.add(page.memory, .{ .flags = .{
        .bold = true,
    } });

    // Write
    for (0..page.size.cols) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.row.styled = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(x + 1) },
            .style_id = id,
        };
        page.styles.use(page.memory, id);
    }

    // The original style add would have incremented the
    // ref count too, so release it to balance that out.
    page.styles.release(page.memory, id);

    // Miss a ref
    page.styles.release(page.memory, id);

    try testing.expectError(
        Page.IntegrityError.MismatchedStyleRef,
        page.verifyIntegrity(testing.allocator),
    );
}

test "Page verifyIntegrity zero rows" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    page.size.rows = 0;
    try testing.expectError(
        Page.IntegrityError.ZeroRowCount,
        page.verifyIntegrity(testing.allocator),
    );
}

test "Page verifyIntegrity zero cols" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();
    page.size.cols = 0;
    try testing.expectError(
        Page.IntegrityError.ZeroColCount,
        page.verifyIntegrity(testing.allocator),
    );
}
