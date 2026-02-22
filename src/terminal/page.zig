const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("terminal_options");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const assert = @import("../quirks.zig").inlineAssert;
const testing = std.testing;
const posix = std.posix;
const fastmem = @import("../fastmem.zig");
const color = @import("color.zig");
const hyperlink = @import("hyperlink.zig");
const kitty = @import("kitty.zig");
const stylepkg = @import("style.zig");
const Style = stylepkg.Style;
const StyleId = stylepkg.Id;
const StyleSet = stylepkg.Set;
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
pub const grapheme_bytes_default = grapheme_count_default * grapheme_chunk;
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
pub const string_bytes_default = string_count_default * string_chunk;

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
            StyleSet.base_align.toByteUnits(),
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

    /// Set to true when an operation is performed that dirties all rows in
    /// the page. See `Row.dirty` for more information on dirty tracking.
    ///
    /// NOTE: A value of false does NOT indicate that
    ///       the page has no dirty rows in it, only
    ///       that no full-page-dirtying operations
    ///       have occurred since it was last cleared.
    dirty: bool,

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
    styles: StyleSet,

    /// The structures used for tracking hyperlinks within the page.
    /// The map maps cell offsets to hyperlink IDs and the IDs are in
    /// the ref counted set. The strings within the hyperlink structures
    /// are allocated in the string allocator.
    hyperlink_map: hyperlink.Map,
    hyperlink_set: hyperlink.Set,

    /// The current dimensions of the page. The capacity may be larger
    /// than this. This allows us to allocate a larger page than necessary
    /// and also to resize a page smaller without reallocating.
    size: Size,

    /// The capacity of this page. This is the full size of the backing
    /// memory and is fixed at page creation time.
    capacity: Capacity,

    /// If this is true then verifyIntegrity will do nothing. This is
    /// only present with runtime safety enabled.
    pause_integrity_checks: if (build_options.slow_runtime_safety) usize else void =
        if (build_options.slow_runtime_safety) 0 else {},

    /// Initialize a new page, allocating the required backing memory.
    /// The size of the initialized page defaults to the full capacity.
    ///
    /// The backing memory is always allocated using mmap directly.
    /// You cannot use custom allocators with this structure because
    /// it is critical to performance that we use mmap.
    pub inline fn init(cap: Capacity) !Page {
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
    pub inline fn initBuf(buf: OffsetBuf, l: Layout) Page {
        const cap = l.capacity;
        const rows = buf.member(Row, l.rows_start);
        const cells = buf.member(Cell, l.cells_start);

        // We need to go through and initialize all the rows so that
        // they point to a valid offset into the cells, since the rows
        // zero-initialized aren't valid.
        const cells_len = @as(usize, cap.cols) * @as(usize, cap.rows);
        const cells_ptr = cells.ptr(buf)[0..cells_len];
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
            .styles = StyleSet.init(
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
            .dirty = false,
        };
    }

    /// Deinitialize the page, freeing any backing memory. Do NOT call
    /// this if you allocated the backing memory yourself (i.e. you used
    /// initBuf).
    pub inline fn deinit(self: *Page) void {
        posix.munmap(self.memory);
        self.* = undefined;
    }

    /// Reinitialize the page with the same capacity.
    pub inline fn reinit(self: *Page) void {
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
    pub inline fn pauseIntegrityChecks(self: *Page, v: bool) void {
        if (build_options.slow_runtime_safety) {
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
    pub inline fn assertIntegrity(self: *const Page) void {
        if (comptime build_options.slow_runtime_safety) {
            var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
            defer _ = debug_allocator.deinit();
            const alloc = debug_allocator.allocator();
            self.verifyIntegrity(alloc) catch |err| {
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

        // We don't run integrity checks on Valgrind because its soooooo slow,
        // Valgrind is our integrity checker, and we run these during unit
        // tests (non-Valgrind) anyways so we're verifying anyways.
        if (std.valgrind.runningOnValgrind() > 0) return;

        if (build_options.slow_runtime_safety) {
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
        var styles_seen = std.AutoHashMap(StyleId, usize).init(alloc);
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

                if (cell.style_id != stylepkg.default_id) {
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
    pub inline fn clone(self: *const Page) !Page {
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
    pub inline fn cloneBuf(self: *const Page, buf: []align(std.heap.page_size_min) u8) Page {
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

    /// Compute the exact capacity required to store a range of rows from
    /// this page.
    ///
    /// The returned capacity will have the same number of columns as this
    /// page and the number of rows equal to the range given. The returned
    /// capacity is by definition strictly less than or equal to this
    /// page's capacity, so the layout is guaranteed to succeed.
    ///
    /// Preconditions:
    /// - Range must be at least 1 row
    /// - Start and end must be valid for this page
    pub fn exactRowCapacity(
        self: *const Page,
        y_start: usize,
        y_end: usize,
    ) Capacity {
        assert(y_start < y_end);
        assert(y_end <= self.size.rows);

        // Track unique IDs using a bitset. Both style IDs and hyperlink IDs
        // are CellCountInt (u16), so we reuse this set for both to save
        // stack memory (~8KB instead of ~16KB).
        const CellCountSet = std.StaticBitSet(std.math.maxInt(size.CellCountInt) + 1);
        comptime assert(size.StyleCountInt == size.CellCountInt);
        comptime assert(size.HyperlinkCountInt == size.CellCountInt);

        // Accumulators
        var id_set: CellCountSet = .initEmpty();
        var grapheme_bytes: usize = 0;
        var string_bytes: usize = 0;

        // First pass: count styles and grapheme bytes
        const rows = self.rows.ptr(self.memory)[y_start..y_end];
        for (rows) |*row| {
            const cells = row.cells.ptr(self.memory)[0..self.size.cols];
            for (cells) |*cell| {
                if (cell.style_id != stylepkg.default_id) {
                    id_set.set(cell.style_id);
                }

                if (cell.hasGrapheme()) {
                    if (self.lookupGrapheme(cell)) |cps| {
                        grapheme_bytes += GraphemeAlloc.bytesRequired(u21, cps.len);
                    }
                }
            }
        }
        const styles_cap = StyleSet.capacityForCount(id_set.count());

        // Second pass: count hyperlinks and string bytes
        // We count both unique hyperlinks (for hyperlink_set) and total
        // hyperlink cells (for hyperlink_map capacity).
        id_set = .initEmpty();
        var hyperlink_cells: usize = 0;
        for (rows) |*row| {
            const cells = row.cells.ptr(self.memory)[0..self.size.cols];
            for (cells) |*cell| {
                if (cell.hyperlink) {
                    hyperlink_cells += 1;
                    if (self.lookupHyperlink(cell)) |id| {
                        // Only count each unique hyperlink once for set sizing
                        if (!id_set.isSet(id)) {
                            id_set.set(id);

                            // Get the hyperlink entry to compute string bytes
                            const entry = self.hyperlink_set.get(self.memory, id);
                            string_bytes += StringAlloc.bytesRequired(u8, entry.uri.len);

                            switch (entry.id) {
                                .implicit => {},
                                .explicit => |slice| {
                                    string_bytes += StringAlloc.bytesRequired(u8, slice.len);
                                },
                            }
                        }
                    }
                }
            }
        }

        // The hyperlink_map capacity in layout() is computed as:
        //   hyperlink_count * hyperlink_cell_multiplier (rounded to power of 2)
        // We need enough hyperlink_bytes so that when layout() computes
        // the map capacity, it can accommodate all hyperlink cells. This
        // is unit tested.
        const hyperlink_cap = cap: {
            const hyperlink_count = id_set.count();
            const hyperlink_set_cap = hyperlink.Set.capacityForCount(hyperlink_count);
            const hyperlink_map_min = std.math.divCeil(
                usize,
                hyperlink_cells,
                hyperlink_cell_multiplier,
            ) catch 0;
            break :cap @max(hyperlink_set_cap, hyperlink_map_min);
        };

        // All the intCasts below are safe because we should have a
        // capacity strictly less than or equal to this page's capacity.
        return .{
            .cols = self.size.cols,
            .rows = @intCast(y_end - y_start),
            .styles = @intCast(styles_cap),
            .grapheme_bytes = @intCast(grapheme_bytes),
            .hyperlink_bytes = @intCast(hyperlink_cap * @sizeOf(hyperlink.Set.Item)),
            .string_bytes = @intCast(string_bytes),
        };
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
    pub inline fn cloneFrom(
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
        for (rows, other_rows) |*dst_row, *src_row| {
            try self.cloneRowFrom(other, dst_row, src_row);
        }

        // We should remain consistent
        self.assertIntegrity();
    }

    /// Clone a single row from another page into this page.
    pub inline fn cloneRowFrom(
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
                copy.dirty |= dst_row.dirty;
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
            if (build_options.slow_runtime_safety) {
                for (other_cells) |cell| {
                    assert(!cell.hasGrapheme());
                    assert(!cell.hyperlink);
                    assert(cell.style_id == stylepkg.default_id);
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
                dst_cell.style_id = stylepkg.default_id;
                if (dst_cell.content_tag == .codepoint_grapheme) {
                    dst_cell.content_tag = .codepoint;
                }

                if (src_cell.hasGrapheme()) {
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
                if (src_cell.style_id != stylepkg.default_id) style: {
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
                if (comptime build_options.kitty_graphics) {
                    if (src_cell.codepoint() == kitty.graphics.unicode.placeholder) {
                        dst_row.kitty_virtual_placeholder = true;
                    }
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
    pub inline fn getRow(self: *const Page, y: usize) *Row {
        assert(y < self.size.rows);
        return &self.rows.ptr(self.memory)[y];
    }

    /// Get the cells for a row.
    pub inline fn getCells(self: *const Page, row: *Row) []Cell {
        if (build_options.slow_runtime_safety) {
            const rows = self.rows.ptr(self.memory);
            const cells = self.cells.ptr(self.memory);
            assert(@intFromPtr(row) >= @intFromPtr(rows));
            assert(@intFromPtr(row) < @intFromPtr(cells));
        }

        const cells = row.cells.ptr(self.memory);
        return cells[0..self.size.cols];
    }

    /// Get the row and cell for the given X/Y within this page.
    pub inline fn getRowAndCell(self: *const Page, x: usize, y: usize) struct {
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
                if (comptime build_options.kitty_graphics) {
                    if (src.codepoint() == kitty.graphics.unicode.placeholder) {
                        dst_row.kitty_virtual_placeholder = true;
                    }
                }
            }
        }

        // The destination row has styles if any of the cells are styled
        if (!dst_row.styled) dst_row.styled = styled: for (dst_cells) |c| {
            if (c.style_id != stylepkg.default_id) break :styled true;
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
            if (comptime build_options.kitty_graphics) {
                src_row.kitty_virtual_placeholder = false;
            }
        }
    }

    /// Swap two cells within the same row as quickly as possible.
    pub inline fn swapCells(
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
    pub inline fn clearCells(
        self: *Page,
        row: *Row,
        left: usize,
        end: usize,
    ) void {
        defer self.assertIntegrity();

        const cells = row.cells.ptr(self.memory)[left..end];

        // If we have managed memory (styles, graphemes, or hyperlinks)
        // in this row then we go cell by cell and clear them if present.
        if (row.grapheme) {
            for (cells) |*cell| {
                if (cell.hasGrapheme())
                    @call(.always_inline, clearGrapheme, .{ self, cell });
            }

            // If we have no left/right scroll region we can be sure
            // that we've cleared all the graphemes, so we clear the
            // flag, otherwise we use the update function to update.
            if (cells.len == self.size.cols) {
                row.grapheme = false;
            } else {
                self.updateRowGraphemeFlag(row);
            }
        }

        if (row.hyperlink) {
            for (cells) |*cell| {
                if (cell.hyperlink)
                    @call(.always_inline, clearHyperlink, .{ self, cell });
            }

            // If we have no left/right scroll region we can be sure
            // that we've cleared all the hyperlinks, so we clear the
            // flag, otherwise we use the update function to update.
            if (cells.len == self.size.cols) {
                row.hyperlink = false;
            } else {
                self.updateRowHyperlinkFlag(row);
            }
        }

        if (row.styled) {
            for (cells) |*cell| {
                if (cell.hasStyling())
                    self.styles.release(self.memory, cell.style_id);
            }

            // If we have no left/right scroll region we can be sure
            // that we've cleared all the styles, so we clear the
            // flag, otherwise we use the update function to update.
            if (cells.len == self.size.cols) {
                row.styled = false;
            } else {
                self.updateRowStyledFlag(row);
            }
        }

        if (comptime build_options.kitty_graphics) {
            if (row.kitty_virtual_placeholder and
                cells.len == self.size.cols)
            {
                for (cells) |c| {
                    if (c.codepoint() == kitty.graphics.unicode.placeholder) {
                        break;
                    }
                } else row.kitty_virtual_placeholder = false;
            }
        }

        // Zero the cells as u64s since empirically this seems
        // to be a bit faster than using @memset(cells, .{})
        @memset(@as([]u64, @ptrCast(cells)), 0);
    }

    /// Returns the hyperlink ID for the given cell.
    pub inline fn lookupHyperlink(self: *const Page, cell: *const Cell) ?hyperlink.Id {
        const cell_offset = getOffset(Cell, self.memory, cell);
        const map = self.hyperlink_map.map(self.memory);
        return map.get(cell_offset);
    }

    /// Clear the hyperlink from the given cell.
    ///
    /// In order to update the hyperlink flag on the row, call
    /// `updateRowHyperlinkFlag` after you finish clearing any
    /// hyperlinks in the row.
    pub fn clearHyperlink(self: *Page, cell: *Cell) void {
        defer self.assertIntegrity();

        // Get our ID
        const cell_offset = getOffset(Cell, self.memory, cell);
        var map = self.hyperlink_map.map(self.memory);
        const entry = map.getEntry(cell_offset) orelse return;

        // Release our usage of this, free memory, unset flag
        self.hyperlink_set.release(self.memory, entry.value_ptr.*);
        map.removeByPtr(entry.key_ptr);
        cell.hyperlink = false;
    }

    /// Checks if the row contains any hyperlinks and sets
    /// the hyperlink flag to false if none are found.
    ///
    /// Call after removing hyperlinks in a row.
    pub inline fn updateRowHyperlinkFlag(self: *Page, row: *Row) void {
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
            page_uri.slice(self.memory),
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
                slice.slice(self.memory),
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
    pub inline fn setHyperlink(self: *Page, row: *Row, cell: *Cell, id: hyperlink.Id) error{HyperlinkMapOutOfMemory}!void {
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
    inline fn moveHyperlink(self: *Page, src: *Cell, dst: *Cell) void {
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
    pub inline fn hyperlinkCount(self: *const Page) usize {
        return self.hyperlink_map.map(self.memory).count();
    }

    /// Returns the hyperlink capacity for the page. This isn't the byte
    /// size but the number of unique cells that can have hyperlink data.
    pub inline fn hyperlinkCapacity(self: *const Page) usize {
        return self.hyperlink_map.map(self.memory).capacity();
    }

    /// Set the graphemes for the given cell. This asserts that the cell
    /// has no graphemes set, and only contains a single codepoint.
    pub inline fn setGraphemes(
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

        if (build_options.slow_runtime_safety) assert(cell.codepoint() != 0);

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
        const old_cps = slice.slice(self.memory);
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
    pub inline fn lookupGrapheme(self: *const Page, cell: *const Cell) ?[]u21 {
        const cell_offset = getOffset(Cell, self.memory, cell);
        const map = self.grapheme_map.map(self.memory);
        const slice = map.get(cell_offset) orelse return null;
        return slice.slice(self.memory);
    }

    /// Move the graphemes from one cell to another. This can't fail
    /// because we avoid any allocations since we're just moving data.
    ///
    /// WARNING: This will NOT change the content_tag on the cells because
    /// there are scenarios where we want to move graphemes without changing
    /// the content tag. Callers beware but assertIntegrity should catch this.
    pub inline fn moveGrapheme(self: *Page, src: *Cell, dst: *Cell) void {
        if (build_options.slow_runtime_safety) {
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
    ///
    /// In order to update the grapheme flag on the row, call
    /// `updateRowGraphemeFlag` after you finish clearing any
    /// graphemes in the row.
    pub fn clearGrapheme(self: *Page, cell: *Cell) void {
        defer self.assertIntegrity();
        if (build_options.slow_runtime_safety) assert(cell.hasGrapheme());

        // Get our entry in the map, which must exist
        const cell_offset = getOffset(Cell, self.memory, cell);
        var map = self.grapheme_map.map(self.memory);
        const entry = map.getEntry(cell_offset).?;

        // Free our grapheme data
        const cps = entry.value_ptr.slice(self.memory);
        self.grapheme_alloc.free(self.memory, cps);

        // Remove the entry
        map.removeByPtr(entry.key_ptr);

        // Mark that we no longer have graphemes by changing the content tag.
        cell.content_tag = .codepoint;
    }

    /// Checks if the row contains any graphemes and sets
    /// the grapheme flag to false if none are found.
    ///
    /// Call after removing graphemes in a row.
    pub inline fn updateRowGraphemeFlag(self: *Page, row: *Row) void {
        const cells = row.cells.ptr(self.memory)[0..self.size.cols];
        for (cells) |c| if (c.hasGrapheme()) return;
        row.grapheme = false;
    }

    /// Returns the number of graphemes in the page. This isn't the byte
    /// size but the total number of unique cells that have grapheme data.
    pub inline fn graphemeCount(self: *const Page) usize {
        return self.grapheme_map.map(self.memory).count();
    }

    /// Returns the grapheme capacity for the page. This isn't the byte
    /// size but the number of unique cells that can have grapheme data.
    pub inline fn graphemeCapacity(self: *const Page) usize {
        return self.grapheme_map.map(self.memory).capacity();
    }

    /// Checks if the row contains any styles and sets
    /// the styled flag to false if none are found.
    ///
    /// Call after removing styles in a row.
    pub inline fn updateRowStyledFlag(self: *Page, row: *Row) void {
        const cells = row.cells.ptr(self.memory)[0..self.size.cols];
        for (cells) |c| if (c.hasStyling()) return;
        row.styled = false;
    }

    /// Returns true if this page is dirty at all.
    pub inline fn isDirty(self: *const Page) bool {
        if (self.dirty) return true;
        for (self.rows.ptr(self.memory)[0..self.size.rows]) |row| {
            if (row.dirty) return true;
        }
        return false;
    }

    pub const Layout = struct {
        total_size: usize,
        rows_start: usize,
        rows_size: usize,
        cells_start: usize,
        cells_size: usize,
        styles_start: usize,
        styles_layout: StyleSet.Layout,
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
    pub inline fn layout(cap: Capacity) Layout {
        const rows_count: usize = @intCast(cap.rows);
        const rows_start = 0;
        const rows_end: usize = rows_start + (rows_count * @sizeOf(Row));

        const cells_count: usize = @as(usize, cap.cols) * @as(usize, cap.rows);
        const cells_start = alignForward(usize, rows_end, @alignOf(Cell));
        const cells_end = cells_start + (cells_count * @sizeOf(Cell));

        const styles_layout: StyleSet.Layout = .init(cap.styles);
        const styles_start = alignForward(usize, cells_end, StyleSet.base_align.toByteUnits());
        const styles_end = styles_start + styles_layout.total_size;

        const grapheme_alloc_layout = GraphemeAlloc.layout(cap.grapheme_bytes);
        const grapheme_alloc_start = alignForward(usize, styles_end, GraphemeAlloc.base_align.toByteUnits());
        const grapheme_alloc_end = grapheme_alloc_start + grapheme_alloc_layout.total_size;

        const grapheme_count: usize = count: {
            if (cap.grapheme_bytes == 0) break :count 0;
            // Use divCeil to match GraphemeAlloc.layout() which uses alignForward,
            // ensuring grapheme_map has capacity when grapheme_alloc has chunks.
            const base = std.math.divCeil(usize, cap.grapheme_bytes, grapheme_chunk) catch unreachable;
            break :count std.math.ceilPowerOfTwo(usize, base) catch unreachable;
        };
        const grapheme_map_layout = GraphemeMap.layout(@intCast(grapheme_count));
        const grapheme_map_start = alignForward(usize, grapheme_alloc_end, GraphemeMap.base_align.toByteUnits());
        const grapheme_map_end = grapheme_map_start + grapheme_map_layout.total_size;

        const string_layout = StringAlloc.layout(cap.string_bytes);
        const string_start = alignForward(usize, grapheme_map_end, StringAlloc.base_align.toByteUnits());
        const string_end = string_start + string_layout.total_size;

        const hyperlink_count = @divFloor(cap.hyperlink_bytes, @sizeOf(hyperlink.Set.Item));
        const hyperlink_set_layout: hyperlink.Set.Layout = .init(@intCast(hyperlink_count));
        const hyperlink_set_start = alignForward(usize, string_end, hyperlink.Set.base_align.toByteUnits());
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
        const hyperlink_map_start = alignForward(usize, hyperlink_set_end, hyperlink.Map.base_align.toByteUnits());
        const hyperlink_map_end = hyperlink_map_start + hyperlink_map_layout.total_size;

        const total_size = alignForward(usize, hyperlink_map_end, std.heap.page_size_min);

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
///
/// This capacity can be maxed out (every field max) and still fit
/// within a 64-bit memory space. If you need more than this, you will
/// need to split data across separate pages.
///
/// For 32-bit systems, it is possible to overflow the addressable
/// space and this is something we still need to address in the future
/// likely by limiting the maximum capacity on 32-bit systems further.
pub const Capacity = struct {
    /// Number of columns and rows we can know about.
    cols: size.CellCountInt,
    rows: size.CellCountInt,

    /// Number of unique styles that can be used on this page.
    styles: size.StyleCountInt = 16,

    /// Number of bytes to allocate for hyperlink data. Note that the
    /// amount of data used for hyperlinks in total is more than this because
    /// hyperlinks use string data as well as a small amount of lookup metadata.
    /// This number is a rough approximation.
    hyperlink_bytes: size.HyperlinkCountInt = hyperlink_bytes_default,

    /// Number of bytes to allocate for grapheme data.
    grapheme_bytes: size.GraphemeBytesInt = grapheme_bytes_default,

    /// Number of bytes to allocate for strings.
    string_bytes: size.StringBytesInt = string_bytes_default,

    pub const Adjustment = struct {
        cols: ?size.CellCountInt = null,
    };

    /// Returns the maximum number of columns that can be used with this
    /// capacity while still fitting at least one row. Returns null if even
    /// a single column cannot fit (which would indicate an unusable capacity).
    ///
    /// Note that this is the maximum number of columns that never increases
    /// the amount of memory the original capacity will take. If you modify
    /// the original capacity to add rows, then you can fit more columns.
    pub fn maxCols(self: Capacity) ?size.CellCountInt {
        const available_bits = self.availableBitsForGrid();

        // If we can't even fit the row metadata, return null
        if (available_bits <= @bitSizeOf(Row)) return null;

        // We do the math of how many columns we can fit in the remaining
        // bits ignoring the metadata of a row.
        const remaining_bits = available_bits - @bitSizeOf(Row);
        const max_cols = remaining_bits / @bitSizeOf(Cell);

        // Clamp to CellCountInt max
        return @min(std.math.maxInt(size.CellCountInt), max_cols);
    }

    /// Adjust the capacity parameters while retaining the same total size.
    ///
    /// Adjustments always happen by limiting the rows in the page. Everything
    /// else can grow. If it is impossible to achieve the desired adjustment,
    /// OutOfMemory is returned.
    pub fn adjust(self: Capacity, req: Adjustment) Allocator.Error!Capacity {
        var adjusted = self;
        if (req.cols) |cols| {
            const available_bits = self.availableBitsForGrid();

            // The size per row is:
            //   - The row metadata itself
            //   - The cells per row (n=cols)
            const bits_per_row: usize = @bitSizeOf(Row) + @bitSizeOf(Cell) * @as(usize, @intCast(cols));
            const new_rows: usize = @divFloor(available_bits, bits_per_row);

            // If our rows go to zero then we can't fit any row metadata
            // for the desired number of columns.
            if (new_rows == 0) return error.OutOfMemory;

            adjusted.cols = cols;
            adjusted.rows = @intCast(new_rows);
        }

        return adjusted;
    }

    /// Computes the number of bits available for rows and cells in the page.
    ///
    /// This is done by laying out the "meta" members (styles, graphemes,
    /// hyperlinks, strings) from the end of the page and finding where they
    /// start, which gives us the space available for rows and cells.
    fn availableBitsForGrid(self: Capacity) usize {
        // The math below only works if there is no alignment gap between
        // the end of the rows array and the start of the cells array.
        //
        // To guarantee this, we assert that Row's size is a multiple of
        // Cell's alignment, so that any length array of Rows will end on
        // a valid alignment for the start of the Cell array.
        assert(@sizeOf(Row) % @alignOf(Cell) == 0);

        const l = Page.layout(self);

        // Layout meta members from the end to find styles_start
        const hyperlink_map_start = alignBackward(usize, l.total_size - l.hyperlink_map_layout.total_size, hyperlink.Map.base_align.toByteUnits());
        const hyperlink_set_start = alignBackward(usize, hyperlink_map_start - l.hyperlink_set_layout.total_size, hyperlink.Set.base_align.toByteUnits());
        const string_alloc_start = alignBackward(usize, hyperlink_set_start - l.string_alloc_layout.total_size, StringAlloc.base_align.toByteUnits());
        const grapheme_map_start = alignBackward(usize, string_alloc_start - l.grapheme_map_layout.total_size, GraphemeMap.base_align.toByteUnits());
        const grapheme_alloc_start = alignBackward(usize, grapheme_map_start - l.grapheme_alloc_layout.total_size, GraphemeAlloc.base_align.toByteUnits());
        const styles_start = alignBackward(usize, grapheme_alloc_start - l.styles_layout.total_size, StyleSet.base_align.toByteUnits());

        // Multiply by 8 to convert bytes to bits
        return styles_start * 8;
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

    /// The semantic prompt state for this row.
    ///
    /// This is ONLY meant to note if there are ANY cells in this
    /// row that are part of a prompt. This is an optimization for more
    /// efficiently implementing jump-to-prompt operations.
    ///
    /// This may contain false positives but never false negatives. If
    /// this is set, you should still check individual cells to see if they
    /// have prompt semantics.
    semantic_prompt: SemanticPrompt = .none,

    /// True if this row contains a virtual placeholder for the Kitty
    /// graphics protocol. (U+10EEEE)
    // Note: We keep this as memory-using even if the kitty graphics
    // feature is disabled because we want to keep our padding and
    // everything throughout the same.
    kitty_virtual_placeholder: bool = false,

    /// True if this row is dirty and requires a redraw. This is set to true
    /// by any operation that modifies the row's contents or position, and
    /// consumers of the page are expected to clear it when they redraw.
    ///
    /// Dirty status is only ever meant to convey that one or more cells in
    /// the row have changed visually. A cell which changes in a way that
    /// doesn't affect the visual representation may not be marked as dirty.
    ///
    /// Dirty tracking may have false positives but should never have false
    /// negatives. A false negative would result in a visual artifact on the
    /// screen.
    dirty: bool = false,

    _padding: u23 = 0,

    /// The semantic prompt state of the row. See `semantic_prompt`.
    pub const SemanticPrompt = enum(u2) {
        /// No prompt cells in this row.
        none = 0,
        /// Prompt cells exist in this row and this is a primary prompt
        /// line. A primary prompt line is one that is not a continuation
        /// and is the beginning of a prompt.
        prompt = 1,
        /// Prompt cells exist in this row that had k=c set (continuation)
        /// line. This is used as a way to detect when a line should
        /// be considered part of some prior prompt. If no prior prompt
        /// is found, the last (most historical) prompt continuation line is
        /// considered the prompt.
        prompt_continuation = 2,
    };

    /// Returns true if this row has any managed memory outside of the
    /// row structure (graphemes, styles, etc.)
    pub inline fn managedMemory(self: Row) bool {
        // Ordered on purpose for likelihood.
        return self.styled or self.hyperlink or self.grapheme;
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
    style_id: StyleId = 0,

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

    /// The semantic type of the content of this cell. This is used
    /// by the semantic prompt (OSC 133) set of sequences to understand
    /// boundary points for content.
    semantic_content: SemanticContent = .output,

    _padding: u16 = 0,

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

    pub const SemanticContent = enum(u2) {
        /// Regular output content, such as command output.
        output = 0,

        /// Content that is part of user input, such as the command
        /// to execute at a prompt.
        input = 1,

        /// Content that is part of prompt emitted by the interactive
        /// application, such as "user@host >"
        prompt = 2,
    };

    /// Helper to make a cell that just has a codepoint.
    pub fn init(cp: u21) Cell {
        // We have to use this bitCast here to ensure that our memory is
        // zeroed. Otherwise, the content below will leave some uninitialized
        // memory in the packed union. Valgrind verifies this.
        var cell: Cell = @bitCast(@as(u64, 0));
        cell.content_tag = .codepoint;
        cell.content = .{ .codepoint = cp };
        return cell;
    }

    pub inline fn isZero(self: Cell) bool {
        return @as(u64, @bitCast(self)) == 0;
    }

    /// Returns true if this cell represents a cell with text to render.
    ///
    /// Cases this returns false:
    ///   - Cell text is blank
    ///   - Cell is styled but only with a background color and no text
    ///   - Cell has a unicode placeholder for Kitty graphics protocol
    pub inline fn hasText(self: Cell) bool {
        return switch (self.content_tag) {
            .codepoint,
            .codepoint_grapheme,
            => self.content.codepoint != 0,

            .bg_color_palette,
            .bg_color_rgb,
            => false,
        };
    }

    pub inline fn codepoint(self: Cell) u21 {
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
    pub inline fn gridWidth(self: Cell) u2 {
        return switch (self.wide) {
            .narrow, .spacer_head, .spacer_tail => 1,
            .wide => 2,
        };
    }

    pub inline fn hasStyling(self: Cell) bool {
        return self.style_id != stylepkg.default_id;
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

    pub inline fn hasGrapheme(self: Cell) bool {
        return self.content_tag == .codepoint_grapheme;
    }

    /// Returns true if the set of cells has text in it.
    pub inline fn hasTextAny(cells: []const Cell) bool {
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

test "Page.layout can take a maxed capacity" {
    // Our intention is for a maxed-out capacity to always fit
    // within a page layout without triggering runtime safety on any
    // overflow. This simplifies some of our handling downstream of the
    // call (relevant to: https://github.com/ghostty-org/ghostty/issues/10258)
    var cap: Capacity = undefined;
    inline for (@typeInfo(Capacity).@"struct".fields) |field| {
        @field(cap, field.name) = std.math.maxInt(field.type);
    }

    // Note that a max capacity will exceed our max_page_size so we
    // can't init a page with it, but it should layout.
    _ = Page.layout(cap);
}

test "Cell is zero by default" {
    const cell = Cell.init(0);
    const cell_int: u64 = @bitCast(cell);
    try std.testing.expectEqual(@as(u64, 0), cell_int);

    // The zero value should be output type for semantic content.
    // This is very important for our assumptions elsewhere.
    try std.testing.expectEqual(Cell.SemanticContent.output, cell.semantic_content);
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

test "Capacity maxCols basic" {
    const cap = std_capacity;
    const max = cap.maxCols().?;

    // maxCols should be >= current cols (since current capacity is valid)
    try testing.expect(max >= cap.cols);

    // Adjusting to maxCols should succeed with at least 1 row
    const adjusted = try cap.adjust(.{ .cols = max });
    try testing.expect(adjusted.rows >= 1);

    // Adjusting to maxCols + 1 should fail
    try testing.expectError(
        error.OutOfMemory,
        cap.adjust(.{ .cols = max + 1 }),
    );
}

test "Capacity maxCols preserves total size" {
    const cap = std_capacity;
    const original_size = Page.layout(cap).total_size;
    const max = cap.maxCols().?;
    const adjusted = try cap.adjust(.{ .cols = max });
    const adjusted_size = Page.layout(adjusted).total_size;
    try testing.expectEqual(original_size, adjusted_size);
}

test "Capacity maxCols with 1 row exactly" {
    const cap = std_capacity;
    const max = cap.maxCols().?;
    const adjusted = try cap.adjust(.{ .cols = max });
    try testing.expectEqual(@as(size.CellCountInt, 1), adjusted.rows);
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
    page.clearGrapheme(rac.cell);
    page.updateRowGraphemeFlag(rac.row);
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
    page.clearGrapheme(rac.cell);
    page.updateRowGraphemeFlag(rac.row);
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

test "Page clone graphemes" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Append some graphemes
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .init(0x09);
        try page.appendGrapheme(rac.row, rac.cell, 0x0A);
        try page.appendGrapheme(rac.row, rac.cell, 0x0B);
    }

    // Clone it
    var page2 = try page.clone();
    defer page2.deinit();
    {
        const rac = page2.getRowAndCell(0, 0);
        try testing.expect(rac.row.grapheme);
        try testing.expect(rac.cell.hasGrapheme());
        try testing.expectEqualSlices(u21, &.{ 0x0A, 0x0B }, page2.lookupGrapheme(rac.cell).?);
    }
}

test "Page clone styles" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Write with some styles
    {
        const id = try page.styles.add(page.memory, .{ .flags = .{
            .bold = true,
        } });

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
    }

    // Clone it
    var page2 = try page.clone();
    defer page2.deinit();
    {
        const id: u16 = style: {
            const rac = page2.getRowAndCell(0, 0);
            break :style rac.cell.style_id;
        };

        for (0..page.size.cols) |x| {
            const rac = page.getRowAndCell(x, 0);
            try testing.expect(rac.row.styled);
            try testing.expectEqual(id, rac.cell.style_id);
        }

        const style = page.styles.get(
            page.memory,
            id,
        );
        try testing.expect((Style{ .flags = .{
            .bold = true,
        } }).eql(style.*));
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
        page.clearGrapheme(rac.cell);
        page.updateRowGraphemeFlag(rac.row);
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
    // Too slow, and not really necessary because the integrity tests are
    // only run in debug builds and unit tests verify they work well enough.
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

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
    // Too slow, and not really necessary because the integrity tests are
    // only run in debug builds and unit tests verify they work well enough.
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

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
    // Too slow, and not really necessary because the integrity tests are
    // only run in debug builds and unit tests verify they work well enough.
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

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
    // Too slow, and not really necessary because the integrity tests are
    // only run in debug builds and unit tests verify they work well enough.
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

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
    // Too slow, and not really necessary because the integrity tests are
    // only run in debug builds and unit tests verify they work well enough.
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

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
    // Too slow, and not really necessary because the integrity tests are
    // only run in debug builds and unit tests verify they work well enough.
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

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

test "Page exactRowCapacity empty rows" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
        .hyperlink_bytes = 32 * @sizeOf(hyperlink.Set.Item),
        .string_bytes = 512,
    });
    defer page.deinit();

    // Empty page: all capacity fields should be 0 (except cols/rows)
    const cap = page.exactRowCapacity(0, 5);
    try testing.expectEqual(10, cap.cols);
    try testing.expectEqual(5, cap.rows);
    try testing.expectEqual(0, cap.styles);
    try testing.expectEqual(0, cap.grapheme_bytes);
    try testing.expectEqual(0, cap.hyperlink_bytes);
    try testing.expectEqual(0, cap.string_bytes);
}

test "Page exactRowCapacity styles" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // No styles: capacity should be 0
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(0, cap.styles);
    }

    // Add one style to a cell
    const style1_id = try page.styles.add(page.memory, .{ .flags = .{ .bold = true } });
    {
        const rac = page.getRowAndCell(0, 0);
        rac.row.styled = true;
        rac.cell.style_id = style1_id;
    }

    // One unique style - capacity accounts for load factor
    const cap_one_style = page.exactRowCapacity(0, 5);
    {
        try testing.expectEqual(StyleSet.capacityForCount(1), cap_one_style.styles);
    }

    // Add same style to another cell (duplicate) - capacity unchanged
    {
        const rac = page.getRowAndCell(1, 0);
        rac.cell.style_id = style1_id;
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(cap_one_style.styles, cap.styles);
    }

    // Add a different style
    const style2_id = try page.styles.add(page.memory, .{ .flags = .{ .italic = true } });
    {
        const rac = page.getRowAndCell(2, 0);
        rac.cell.style_id = style2_id;
    }

    // Two unique styles - capacity accounts for load factor
    const cap_two_styles = page.exactRowCapacity(0, 5);
    {
        try testing.expectEqual(StyleSet.capacityForCount(2), cap_two_styles.styles);
        try testing.expect(cap_two_styles.styles > cap_one_style.styles);
    }

    // Style outside the row range should not be counted
    {
        const rac = page.getRowAndCell(0, 7);
        rac.row.styled = true;
        rac.cell.style_id = try page.styles.add(page.memory, .{ .flags = .{ .underline = .single } });
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(cap_two_styles.styles, cap.styles);
    }

    // Full range includes the new style
    {
        const cap = page.exactRowCapacity(0, 10);
        try testing.expectEqual(StyleSet.capacityForCount(3), cap.styles);
    }

    // Verify clone works with exact capacity and produces same result
    {
        const cap = page.exactRowCapacity(0, 5);
        var cloned = try Page.init(cap);
        defer cloned.deinit();
        for (0..5) |y| {
            const src_row = &page.rows.ptr(page.memory)[y];
            const dst_row = &cloned.rows.ptr(cloned.memory)[y];
            try cloned.cloneRowFrom(&page, dst_row, src_row);
        }
        const cloned_cap = cloned.exactRowCapacity(0, 5);
        try testing.expectEqual(cap, cloned_cap);
    }
}

test "Page exactRowCapacity single style clone" {
    // Regression test: verify a single style can be cloned with exact capacity.
    // This tests that capacityForCount properly accounts for ID 0 being reserved.
    var page = try Page.init(.{
        .cols = 10,
        .rows = 2,
        .styles = 8,
    });
    defer page.deinit();

    // Add exactly one style to row 0
    const style_id = try page.styles.add(page.memory, .{ .flags = .{ .bold = true } });
    {
        const rac = page.getRowAndCell(0, 0);
        rac.row.styled = true;
        rac.cell.style_id = style_id;
    }

    // exactRowCapacity for just row 0 should give capacity for 1 style
    const cap = page.exactRowCapacity(0, 1);
    try testing.expectEqual(StyleSet.capacityForCount(1), cap.styles);

    // Create a new page with exact capacity and clone
    var cloned = try Page.init(cap);
    defer cloned.deinit();

    const src_row = &page.rows.ptr(page.memory)[0];
    const dst_row = &cloned.rows.ptr(cloned.memory)[0];

    // This must not fail with StyleSetOutOfMemory
    try cloned.cloneRowFrom(&page, dst_row, src_row);

    // Verify the style was cloned correctly
    const cloned_cell = &cloned.rows.ptr(cloned.memory)[0].cells.ptr(cloned.memory)[0];
    try testing.expect(cloned_cell.style_id != stylepkg.default_id);
}

test "Page exactRowCapacity styles max single row" {
    var page = try Page.init(.{
        .cols = std.math.maxInt(size.CellCountInt),
        .rows = 1,
        .styles = std.math.maxInt(size.StyleCountInt),
    });
    defer page.deinit();

    // Style our first row
    const row = &page.rows.ptr(page.memory)[0];
    row.styled = true;

    // Fill cells with styles until we get OOM, but limit to a reasonable count
    // to avoid overflow when computing capacityForCount near maxInt
    const cells = row.cells.ptr(page.memory)[0..page.size.cols];
    var count: usize = 0;
    const max_count: usize = 1000; // Limit to avoid overflow in capacity calculation
    for (cells, 0..) |*cell, i| {
        if (count >= max_count) break;
        const style_id = page.styles.add(page.memory, .{
            .fg_color = .{ .rgb = .{
                .r = @intCast(i & 0xFF),
                .g = @intCast((i >> 8) & 0xFF),
                .b = 0,
            } },
        }) catch break;
        cell.style_id = style_id;
        count += 1;
    }

    // Verify we added a meaningful number of styles
    try testing.expect(count > 0);

    // Capacity should be at least count (adjusted for load factor)
    const cap = page.exactRowCapacity(0, 1);
    try testing.expectEqual(StyleSet.capacityForCount(count), cap.styles);
}

test "Page exactRowCapacity grapheme_bytes" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // No graphemes: capacity should be 0
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(0, cap.grapheme_bytes);
    }

    // Add one grapheme (1 codepoint) to a cell - rounds up to grapheme_chunk
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .init('a');
        try page.appendGrapheme(rac.row, rac.cell, 0x0301); // combining acute accent
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        // 1 codepoint = 4 bytes, rounds up to grapheme_chunk (16)
        try testing.expectEqual(grapheme_chunk, cap.grapheme_bytes);
    }

    // Add another grapheme to a different cell - should sum
    {
        const rac = page.getRowAndCell(1, 0);
        rac.cell.* = .init('e');
        try page.appendGrapheme(rac.row, rac.cell, 0x0300); // combining grave accent
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        // 2 graphemes, each 1 codepoint = 2 * grapheme_chunk
        try testing.expectEqual(grapheme_chunk * 2, cap.grapheme_bytes);
    }

    // Add a larger grapheme (multiple codepoints) that fits in one chunk
    {
        const rac = page.getRowAndCell(2, 0);
        rac.cell.* = .init('o');
        try page.appendGrapheme(rac.row, rac.cell, 0x0301);
        try page.appendGrapheme(rac.row, rac.cell, 0x0302);
        try page.appendGrapheme(rac.row, rac.cell, 0x0303);
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        // First two cells: 2 * grapheme_chunk
        // Third cell: 3 codepoints = 12 bytes, rounds up to grapheme_chunk
        try testing.expectEqual(grapheme_chunk * 3, cap.grapheme_bytes);
    }

    // Grapheme outside the row range should not be counted
    {
        const rac = page.getRowAndCell(0, 7);
        rac.cell.* = .init('x');
        try page.appendGrapheme(rac.row, rac.cell, 0x0304);
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(grapheme_chunk * 3, cap.grapheme_bytes);
    }

    // Full range includes the new grapheme
    {
        const cap = page.exactRowCapacity(0, 10);
        try testing.expectEqual(grapheme_chunk * 4, cap.grapheme_bytes);
    }

    // Verify clone works with exact capacity and produces same result
    {
        const cap = page.exactRowCapacity(0, 5);
        var cloned = try Page.init(cap);
        defer cloned.deinit();
        for (0..5) |y| {
            const src_row = &page.rows.ptr(page.memory)[y];
            const dst_row = &cloned.rows.ptr(cloned.memory)[y];
            try cloned.cloneRowFrom(&page, dst_row, src_row);
        }
        const cloned_cap = cloned.exactRowCapacity(0, 5);
        try testing.expectEqual(cap, cloned_cap);
    }
}

test "Page exactRowCapacity grapheme_bytes larger than chunk" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
    });
    defer page.deinit();

    // Add a grapheme larger than one chunk (grapheme_chunk_len = 4 codepoints)
    const rac = page.getRowAndCell(0, 0);
    rac.cell.* = .init('a');

    // Add 6 codepoints - requires 2 chunks (6 * 4 = 24 bytes, rounds up to 32)
    for (0..6) |i| {
        try page.appendGrapheme(rac.row, rac.cell, @intCast(0x0300 + i));
    }

    const cap = page.exactRowCapacity(0, 1);
    // 6 codepoints = 24 bytes, alignForward(24, 16) = 32
    try testing.expectEqual(32, cap.grapheme_bytes);

    // Verify clone works with exact capacity and produces same result
    var cloned = try Page.init(cap);
    defer cloned.deinit();
    const src_row = &page.rows.ptr(page.memory)[0];
    const dst_row = &cloned.rows.ptr(cloned.memory)[0];
    try cloned.cloneRowFrom(&page, dst_row, src_row);
    const cloned_cap = cloned.exactRowCapacity(0, 1);
    try testing.expectEqual(cap, cloned_cap);
}

test "Page exactRowCapacity hyperlinks" {
    var page = try Page.init(.{
        .cols = 10,
        .rows = 10,
        .styles = 8,
        .hyperlink_bytes = 32 * @sizeOf(hyperlink.Set.Item),
        .string_bytes = 512,
    });
    defer page.deinit();

    // No hyperlinks: capacity should be 0
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(0, cap.hyperlink_bytes);
        try testing.expectEqual(0, cap.string_bytes);
    }

    // Add one hyperlink with implicit ID
    const uri1 = "https://example.com";
    const id1 = blk: {
        const rac = page.getRowAndCell(0, 0);

        // Create and add hyperlink entry
        const id = try page.insertHyperlink(.{
            .id = .{ .implicit = 1 },
            .uri = uri1,
        });
        try page.setHyperlink(rac.row, rac.cell, id);
        break :blk id;
    };
    // 1 hyperlink - capacity accounts for load factor
    const cap_one_link = page.exactRowCapacity(0, 5);
    {
        try testing.expectEqual(hyperlink.Set.capacityForCount(1) * @sizeOf(hyperlink.Set.Item), cap_one_link.hyperlink_bytes);
        // URI "https://example.com" = 19 bytes, rounds up to string_chunk (32)
        try testing.expectEqual(string_chunk, cap_one_link.string_bytes);
    }

    // Add same hyperlink to another cell (duplicate ID) - capacity unchanged
    {
        const rac = page.getRowAndCell(1, 0);

        // Use the same hyperlink ID for another cell
        page.hyperlink_set.use(page.memory, id1);
        try page.setHyperlink(rac.row, rac.cell, id1);
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(cap_one_link.hyperlink_bytes, cap.hyperlink_bytes);
        try testing.expectEqual(cap_one_link.string_bytes, cap.string_bytes);
    }

    // Add a different hyperlink with explicit ID
    const uri2 = "https://other.example.org/path";
    const explicit_id = "my-link-id";
    {
        const rac = page.getRowAndCell(2, 0);

        const id = try page.insertHyperlink(.{
            .id = .{ .explicit = explicit_id },
            .uri = uri2,
        });
        try page.setHyperlink(rac.row, rac.cell, id);
    }
    // 2 hyperlinks - capacity accounts for load factor
    const cap_two_links = page.exactRowCapacity(0, 5);
    {
        try testing.expectEqual(hyperlink.Set.capacityForCount(2) * @sizeOf(hyperlink.Set.Item), cap_two_links.hyperlink_bytes);
        // First URI: 19 bytes -> 32, Second URI: 30 bytes -> 32, Explicit ID: 10 bytes -> 32
        try testing.expectEqual(string_chunk * 3, cap_two_links.string_bytes);
    }

    // Hyperlink outside the row range should not be counted
    {
        const rac = page.getRowAndCell(0, 7); // row 7 is outside range [0, 5)

        const id = try page.insertHyperlink(.{
            .id = .{ .implicit = 99 },
            .uri = "https://outside.example.com",
        });
        try page.setHyperlink(rac.row, rac.cell, id);
    }
    {
        const cap = page.exactRowCapacity(0, 5);
        try testing.expectEqual(cap_two_links.hyperlink_bytes, cap.hyperlink_bytes);
        try testing.expectEqual(cap_two_links.string_bytes, cap.string_bytes);
    }

    // Full range includes the new hyperlink
    {
        const cap = page.exactRowCapacity(0, 10);
        try testing.expectEqual(hyperlink.Set.capacityForCount(3) * @sizeOf(hyperlink.Set.Item), cap.hyperlink_bytes);
        // Third URI: 27 bytes -> 32
        try testing.expectEqual(string_chunk * 4, cap.string_bytes);
    }

    // Verify clone works with exact capacity and produces same result
    {
        const cap = page.exactRowCapacity(0, 5);
        var cloned = try Page.init(cap);
        defer cloned.deinit();
        for (0..5) |y| {
            const src_row = &page.rows.ptr(page.memory)[y];
            const dst_row = &cloned.rows.ptr(cloned.memory)[y];
            try cloned.cloneRowFrom(&page, dst_row, src_row);
        }
        const cloned_cap = cloned.exactRowCapacity(0, 5);
        try testing.expectEqual(cap, cloned_cap);
    }
}

test "Page exactRowCapacity single hyperlink clone" {
    // Regression test: verify a single hyperlink can be cloned with exact capacity.
    // This tests that capacityForCount properly accounts for ID 0 being reserved.
    var page = try Page.init(.{
        .cols = 10,
        .rows = 2,
        .styles = 8,
        .hyperlink_bytes = 32 * @sizeOf(hyperlink.Set.Item),
        .string_bytes = 512,
    });
    defer page.deinit();

    // Add exactly one hyperlink to row 0
    const uri = "https://example.com";
    const id = blk: {
        const rac = page.getRowAndCell(0, 0);
        const link_id = try page.insertHyperlink(.{
            .id = .{ .implicit = 1 },
            .uri = uri,
        });
        try page.setHyperlink(rac.row, rac.cell, link_id);
        break :blk link_id;
    };
    _ = id;

    // exactRowCapacity for just row 0 should give capacity for 1 hyperlink
    const cap = page.exactRowCapacity(0, 1);
    try testing.expectEqual(hyperlink.Set.capacityForCount(1) * @sizeOf(hyperlink.Set.Item), cap.hyperlink_bytes);

    // Create a new page with exact capacity and clone
    var cloned = try Page.init(cap);
    defer cloned.deinit();

    const src_row = &page.rows.ptr(page.memory)[0];
    const dst_row = &cloned.rows.ptr(cloned.memory)[0];

    // This must not fail with HyperlinkSetOutOfMemory
    try cloned.cloneRowFrom(&page, dst_row, src_row);

    // Verify the hyperlink was cloned correctly
    const cloned_cell = &cloned.rows.ptr(cloned.memory)[0].cells.ptr(cloned.memory)[0];
    try testing.expect(cloned_cell.hyperlink);
}

test "Page exactRowCapacity hyperlink map capacity for many cells" {
    // A single hyperlink spanning many cells requires hyperlink_map capacity
    // based on cell count, not unique hyperlink count.
    const cols = 50;
    var page = try Page.init(.{
        .cols = cols,
        .rows = 2,
        .styles = 8,
        .hyperlink_bytes = 32 * @sizeOf(hyperlink.Set.Item),
        .string_bytes = 512,
    });
    defer page.deinit();

    // Add one hyperlink spanning all 50 columns in row 0
    const uri = "https://example.com";
    const id = blk: {
        const rac = page.getRowAndCell(0, 0);
        const link_id = try page.insertHyperlink(.{
            .id = .{ .implicit = 1 },
            .uri = uri,
        });
        try page.setHyperlink(rac.row, rac.cell, link_id);
        break :blk link_id;
    };

    // Apply same hyperlink to remaining cells in row 0
    for (1..cols) |x| {
        const rac = page.getRowAndCell(@intCast(x), 0);
        page.hyperlink_set.use(page.memory, id);
        try page.setHyperlink(rac.row, rac.cell, id);
    }

    // exactRowCapacity must account for 50 hyperlink cells, not just 1 unique hyperlink
    const cap = page.exactRowCapacity(0, 1);

    // The hyperlink_bytes must be large enough that layout() computes sufficient
    // hyperlink_map capacity. With hyperlink_cell_multiplier=16, we need at least
    // ceil(50/16) = 4 hyperlink entries worth of bytes for the map.
    const min_for_map = std.math.divCeil(usize, cols, hyperlink_cell_multiplier) catch 0;
    const min_hyperlink_bytes = min_for_map * @sizeOf(hyperlink.Set.Item);
    try testing.expect(cap.hyperlink_bytes >= min_hyperlink_bytes);

    // Create a new page with exact capacity and clone - must not fail
    var cloned = try Page.init(cap);
    defer cloned.deinit();

    const src_row = &page.rows.ptr(page.memory)[0];
    const dst_row = &cloned.rows.ptr(cloned.memory)[0];

    // This must not fail with HyperlinkMapOutOfMemory
    try cloned.cloneRowFrom(&page, dst_row, src_row);

    // Verify all hyperlinks were cloned correctly
    for (0..cols) |x| {
        const cloned_cell = &cloned.rows.ptr(cloned.memory)[0].cells.ptr(cloned.memory)[x];
        try testing.expect(cloned_cell.hyperlink);
    }
}
