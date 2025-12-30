const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const CircBuf = @import("../../datastruct/main.zig").CircBuf;
const terminal = @import("../main.zig");
const point = terminal.point;
const size = terminal.size;
const PageList = terminal.PageList;
const Pin = PageList.Pin;
const Selection = terminal.Selection;
const Screen = terminal.Screen;
const Terminal = terminal.Terminal;
const PageFormatter = @import("../formatter.zig").PageFormatter;
const FlattenedHighlight = terminal.highlight.Flattened;

/// Searches page nodes via a sliding window. The sliding window maintains
/// the invariant that data isn't pruned until (1) we've searched it and
/// (2) we've accounted for overlaps across pages to fit the needle.
///
/// The sliding window is first initialized empty. Pages are then appended
/// in the order to search them. The sliding window supports both a forward
/// and reverse order specified via `init`. The pages should be appended
/// in the correct order matching the search direction.
///
/// All appends grow the window. The window is only pruned when a search
/// is done (positive or negative match) via `next()`.
///
/// To avoid unnecessary memory growth, the recommended usage is to
/// call `next()` until it returns null and then `append` the next page
/// and repeat the process. This will always maintain the minimum
/// required memory to search for the needle.
///
/// The caller is responsible for providing the pages and ensuring they're
/// in the proper order. The SlidingWindow itself doesn't own the pages, but
/// it will contain pointers to them in order to return selections. If any
/// pages become invalid, the caller should clear the sliding window and
/// start over.
pub const SlidingWindow = struct {
    /// The allocator to use for all the data within this window. We
    /// store this rather than passing it around because its already
    /// part of multiple elements (eg. Meta's CellMap) and we want to
    /// ensure we always use a consistent allocator. Additionally, only
    /// a small amount of sliding windows are expected to be in use
    /// at any one time so the memory overhead isn't that large.
    alloc: Allocator,

    /// The data buffer is a circular buffer of u8 that contains the
    /// encoded page text that we can use to search for the needle.
    data: DataBuf,

    /// The meta buffer is a circular buffer that contains the metadata
    /// about the pages we're searching. This usually isn't that large
    /// so callers must iterate through it to find the offset to map
    /// data to meta.
    meta: MetaBuf,

    /// Buffer that can fit any amount of chunks necessary for next
    /// to never fail allocation.
    chunk_buf: std.MultiArrayList(FlattenedHighlight.Chunk),

    /// Offset into data for our current state. This handles the
    /// situation where our search moved through meta[0] but didn't
    /// do enough to prune it.
    data_offset: usize = 0,

    /// The needle we're searching for. Does own the memory.
    needle: []const u8,

    /// The search direction. If the direction is forward then pages should
    /// be appended in forward linked list order from the PageList. If the
    /// direction is reverse then pages should be appended in reverse order.
    ///
    /// This is important because in most cases, a reverse search is going
    /// to be more desirable to search from the end of the active area
    /// backwards so more recent data is found first. Supporting both is
    /// trivial though and will let us do more complex optimizations in the
    /// future (e.g. starting from the viewport and doing a forward/reverse
    /// concurrently from that point).
    direction: Direction,

    /// A buffer to store the overlap search data. This is used to search
    /// overlaps between pages where the match starts on one page and
    /// ends on another. The length is always `needle.len * 2`.
    overlap_buf: []u8,

    const Direction = enum { forward, reverse };
    const DataBuf = CircBuf(u8, 0);
    const MetaBuf = CircBuf(Meta, undefined);
    const Meta = struct {
        node: *PageList.List.Node,
        serial: u64,
        cell_map: std.ArrayList(point.Coordinate),

        pub fn deinit(self: *Meta, alloc: Allocator) void {
            self.cell_map.deinit(alloc);
        }
    };

    pub fn init(
        alloc: Allocator,
        direction: Direction,
        needle_unowned: []const u8,
    ) Allocator.Error!SlidingWindow {
        var data = try DataBuf.init(alloc, 0);
        errdefer data.deinit(alloc);

        var meta = try MetaBuf.init(alloc, 0);
        errdefer meta.deinit(alloc);

        const needle = try alloc.dupe(u8, needle_unowned);
        errdefer alloc.free(needle);
        switch (direction) {
            .forward => {},
            .reverse => std.mem.reverse(u8, needle),
        }

        const overlap_buf = try alloc.alloc(u8, needle.len * 2);
        errdefer alloc.free(overlap_buf);

        return .{
            .alloc = alloc,
            .data = data,
            .meta = meta,
            .chunk_buf = .empty,
            .needle = needle,
            .direction = direction,
            .overlap_buf = overlap_buf,
        };
    }

    pub fn deinit(self: *SlidingWindow) void {
        self.alloc.free(self.overlap_buf);
        self.alloc.free(self.needle);
        self.chunk_buf.deinit(self.alloc);
        self.data.deinit(self.alloc);

        var meta_it = self.meta.iterator(.forward);
        while (meta_it.next()) |meta| meta.deinit(self.alloc);
        self.meta.deinit(self.alloc);
    }

    /// Clear all data but retain allocated capacity.
    pub fn clearAndRetainCapacity(self: *SlidingWindow) void {
        var meta_it = self.meta.iterator(.forward);
        while (meta_it.next()) |meta| meta.deinit(self.alloc);
        self.meta.clear();
        self.data.clear();
        self.data_offset = 0;
    }

    /// Search the window for the next occurrence of the needle. As
    /// the window moves, the window will prune itself while maintaining
    /// the invariant that the window is always big enough to contain
    /// the needle.
    ///
    /// This returns a flattened highlight on a match. The
    /// flattened highlight requires allocation and is therefore more expensive
    /// than a normal selection, but it is more efficient to render since it
    /// has all the information without having to dereference pointers into
    /// the terminal state.
    ///
    /// The flattened highlight chunks reference internal memory for this
    /// sliding window and are only valid until the next call to `next()`
    /// or `append()`. If the caller wants to retain the flattened highlight
    /// then they should clone it.
    pub fn next(self: *SlidingWindow) ?FlattenedHighlight {
        const slices = slices: {
            // If we have less data then the needle then we can't possibly match
            const data_len = self.data.len();
            if (data_len < self.needle.len) return null;

            break :slices self.data.getPtrSlice(
                self.data_offset,
                data_len - self.data_offset,
            );
        };

        // Search the first slice for the needle.
        if (std.ascii.indexOfIgnoreCase(slices[0], self.needle)) |idx| {
            return self.highlight(
                idx,
                self.needle.len,
            );
        }

        // Search the overlap buffer for the needle.
        if (slices[0].len > 0 and slices[1].len > 0) overlap: {
            // Get up to needle.len - 1 bytes from each side (as much as
            // we can) and store it in the overlap buffer.
            const prefix: []const u8 = prefix: {
                const len = @min(slices[0].len, self.needle.len - 1);
                const idx = slices[0].len - len;
                break :prefix slices[0][idx..];
            };
            const suffix: []const u8 = suffix: {
                const len = @min(slices[1].len, self.needle.len - 1);
                break :suffix slices[1][0..len];
            };
            const overlap_len = prefix.len + suffix.len;
            assert(overlap_len <= self.overlap_buf.len);
            @memcpy(self.overlap_buf[0..prefix.len], prefix);
            @memcpy(self.overlap_buf[prefix.len..overlap_len], suffix);

            // Search the overlap
            const idx = std.ascii.indexOfIgnoreCase(
                self.overlap_buf[0..overlap_len],
                self.needle,
            ) orelse break :overlap;

            // We found a match in the overlap buffer. We need to map the
            // index back to the data buffer in order to get our selection.
            return self.highlight(
                slices[0].len - prefix.len + idx,
                self.needle.len,
            );
        }

        // Search the last slice for the needle.
        if (std.ascii.indexOfIgnoreCase(slices[1], self.needle)) |idx| {
            return self.highlight(
                slices[0].len + idx,
                self.needle.len,
            );
        }

        // Special case 1-lengthed needles to delete the entire buffer.
        if (self.needle.len == 1) {
            self.clearAndRetainCapacity();
            self.assertIntegrity();
            return null;
        }

        // No match. We keep `needle.len - 1` bytes available to
        // handle the future overlap case.
        prune: {
            var meta_it = self.meta.iterator(.reverse);
            var saved: usize = 0;
            while (meta_it.next()) |meta| {
                const needed = self.needle.len - 1 - saved;
                if (meta.cell_map.items.len >= needed) {
                    // We save up to this meta. We set our data offset
                    // to exactly where it needs to be to continue
                    // searching.
                    self.data_offset = meta.cell_map.items.len - needed;
                    break;
                }

                saved += meta.cell_map.items.len;
            } else {
                // If we exited the while loop naturally then we
                // never got the amount we needed and so there is
                // nothing to prune.
                assert(saved < self.needle.len - 1);
                break :prune;
            }

            const prune_count = self.meta.len() - meta_it.idx;
            if (prune_count == 0) {
                // This can happen if we need to save up to the first
                // meta value to retain our window.
                break :prune;
            }

            // We can now delete all the metas up to but NOT including
            // the meta we found through meta_it.
            meta_it = self.meta.iterator(.forward);
            var prune_data_len: usize = 0;
            for (0..prune_count) |_| {
                const meta = meta_it.next().?;
                prune_data_len += meta.cell_map.items.len;
                meta.deinit(self.alloc);
            }
            self.meta.deleteOldest(prune_count);
            self.data.deleteOldest(prune_data_len);
        }

        // Our data offset now moves to needle.len - 1 from the end so
        // that we can handle the overlap case.
        self.data_offset = self.data.len() - self.needle.len + 1;

        self.assertIntegrity();
        return null;
    }

    /// Return a flattened highlight for the given start and length.
    ///
    /// The flattened highlight can be used to render the highlight
    /// in the most efficient way because it doesn't require a terminal
    /// lock to access terminal data to compare whether some viewport
    /// matches the highlight (because it doesn't need to traverse
    /// the page nodes).
    ///
    /// The start index is assumed to be relative to the offset. i.e.
    /// index zero is actually at `self.data[self.data_offset]`. The
    /// selection will account for the offset.
    fn highlight(
        self: *SlidingWindow,
        start_offset: usize,
        len: usize,
    ) terminal.highlight.Flattened {
        const start = start_offset + self.data_offset;
        const end = start + len - 1;
        if (comptime std.debug.runtime_safety) {
            assert(start < self.data.len());
            assert(start + len <= self.data.len());
        }

        // Clear our previous chunk buffer to store this result
        self.chunk_buf.clearRetainingCapacity();
        var result: terminal.highlight.Flattened = .empty;

        // Go through the meta nodes to find our start.
        const tl: struct {
            /// If non-null, we need to continue searching for the bottom-right.
            br: ?struct {
                it: MetaBuf.Iterator,
                consumed: usize,
            },

            /// Data to prune, both are lengths.
            prune: struct {
                meta: usize,
                data: usize,
            },
        } = tl: {
            var meta_it = self.meta.iterator(.forward);
            var meta_consumed: usize = 0;
            while (meta_it.next()) |meta| {
                // Always increment our consumed count so that our index
                // is right for the end search if we do it.
                const prior_meta_consumed = meta_consumed;
                meta_consumed += meta.cell_map.items.len;

                // meta_i is the index we expect to find the match in the
                // cell map within this meta if it contains it.
                const meta_i = start - prior_meta_consumed;

                // This meta doesn't contain the match. This means we
                // can also prune this set of data because we only look
                // forward.
                if (meta_i >= meta.cell_map.items.len) continue;

                // Now we look for the end. In MOST cases it is the same as
                // our starting chunk because highlights are usually small and
                // not on a boundary, so let's optimize for that.
                const end_i = end - prior_meta_consumed;
                if (end_i < meta.cell_map.items.len) {
                    @branchHint(.likely);

                    // The entire highlight is within this meta.
                    const start_map = meta.cell_map.items[meta_i];
                    const end_map = meta.cell_map.items[end_i];
                    result.top_x = start_map.x;
                    result.bot_x = end_map.x;
                    self.chunk_buf.appendAssumeCapacity(.{
                        .node = meta.node,
                        .serial = meta.serial,
                        .start = @intCast(start_map.y),
                        .end = @intCast(end_map.y + 1),
                    });

                    break :tl .{
                        .br = null,
                        .prune = .{
                            .meta = meta_it.idx - 1,
                            .data = prior_meta_consumed,
                        },
                    };
                } else {
                    // We found the meta that contains the start of the match
                    // only. Consume this entire node from our start offset.
                    const map = meta.cell_map.items[meta_i];
                    result.top_x = map.x;
                    self.chunk_buf.appendAssumeCapacity(.{
                        .node = meta.node,
                        .serial = meta.serial,
                        .start = @intCast(map.y),
                        .end = meta.node.data.size.rows,
                    });

                    break :tl .{
                        .br = .{
                            .it = meta_it,
                            .consumed = meta_consumed,
                        },
                        .prune = .{
                            .meta = meta_it.idx - 1,
                            .data = prior_meta_consumed,
                        },
                    };
                }
            } else {
                // Precondition that the start index is within the data buffer.
                unreachable;
            }
        };

        // Search for our end.
        if (tl.br) |br| {
            var meta_it = br.it;
            var meta_consumed: usize = br.consumed;
            while (meta_it.next()) |meta| {
                // meta_i is the index we expect to find the match in the
                // cell map within this meta if it contains it.
                const meta_i = end - meta_consumed;
                if (meta_i >= meta.cell_map.items.len) {
                    // This meta doesn't contain the match. We still add it
                    // to our results because we want the full flattened list.
                    self.chunk_buf.appendAssumeCapacity(.{
                        .node = meta.node,
                        .serial = meta.serial,
                        .start = 0,
                        .end = meta.node.data.size.rows,
                    });

                    meta_consumed += meta.cell_map.items.len;
                    continue;
                }

                // We found it
                const map = meta.cell_map.items[meta_i];
                result.bot_x = map.x;
                self.chunk_buf.appendAssumeCapacity(.{
                    .node = meta.node,
                    .serial = meta.serial,
                    .start = 0,
                    .end = @intCast(map.y + 1),
                });
                break;
            } else {
                // Precondition that the end index is within the data buffer.
                unreachable;
            }
        }

        // Our offset into the current meta block is the start index
        // minus the amount of data fully consumed. We then add one
        // to move one past the match so we don't repeat it.
        self.data_offset = start - tl.prune.data + 1;

        // If we went beyond our initial meta node we can prune.
        if (tl.prune.meta > 0) {
            // Deinit all our memory in the meta blocks prior to our
            // match.
            var meta_it = self.meta.iterator(.forward);
            var meta_consumed: usize = 0;
            for (0..tl.prune.meta) |_| {
                const meta: *Meta = meta_it.next().?;
                meta_consumed += meta.cell_map.items.len;
                meta.deinit(self.alloc);
            }
            if (comptime std.debug.runtime_safety) {
                assert(meta_it.idx == tl.prune.meta);
                assert(meta_it.next().?.node == self.chunk_buf.items(.node)[0]);
            }
            self.meta.deleteOldest(tl.prune.meta);

            // Delete all the data up to our current index.
            assert(tl.prune.data > 0);
            self.data.deleteOldest(tl.prune.data);
        }

        switch (self.direction) {
            .forward => {},
            .reverse => {
                const slice = self.chunk_buf.slice();
                const nodes = slice.items(.node);
                const starts = slice.items(.start);
                const ends = slice.items(.end);

                if (self.chunk_buf.len > 1) {
                    // Reverse all our chunks. This should be pretty obvious why.
                    std.mem.reverse(*PageList.List.Node, nodes);
                    std.mem.reverse(size.CellCountInt, starts);
                    std.mem.reverse(size.CellCountInt, ends);

                    // Now normally with forward traversal with multiple pages,
                    // the suffix of the first page and the prefix of the last
                    // page are used.
                    //
                    // For a reverse traversal, this is inverted (since the
                    // pages are in reverse order we get the suffix of the last
                    // page and the prefix of the first page). So we need to
                    // invert this.
                    //
                    // We DON'T need to do this for any middle pages because
                    // they always use the full page.
                    //
                    // This is a fixup that makes our start/end match the
                    // same logic as the loops above if they were in forward
                    // order.
                    assert(nodes.len >= 2);
                    starts[0] = ends[0] - 1;
                    ends[0] = nodes[0].data.size.rows;
                    ends[nodes.len - 1] = starts[nodes.len - 1] + 1;
                    starts[nodes.len - 1] = 0;
                } else {
                    // For a single chunk, the y values are in reverse order
                    // (start is the screen-end, end is the screen-start).
                    // Swap them to get proper top-to-bottom order.
                    const start_y = starts[0];
                    starts[0] = ends[0] - 1;
                    ends[0] = start_y + 1;
                }

                // X values also need to be reversed since the top/bottom
                // are swapped for the nodes.
                const top_x = result.top_x;
                result.top_x = result.bot_x;
                result.bot_x = top_x;
            },
        }

        // Copy over our MultiArrayList so it points to the proper memory.
        result.chunks = self.chunk_buf;
        return result;
    }

    /// Add a new node to the sliding window. This will always grow
    /// the sliding window; data isn't pruned until it is consumed
    /// via a search (via next()).
    ///
    /// Returns the number of bytes of content added to the sliding window.
    /// The total bytes will be larger since this omits metadata, but it is
    /// an accurate measure of the text content size added.
    pub fn append(
        self: *SlidingWindow,
        node: *PageList.List.Node,
    ) Allocator.Error!usize {
        // Initialize our metadata for the node.
        var meta: Meta = .{
            .node = node,
            .serial = node.serial,
            .cell_map = .empty,
        };
        errdefer meta.deinit(self.alloc);

        // This is suboptimal but we need to encode the page once to
        // temporary memory, and then copy it into our circular buffer.
        // In the future, we should benchmark and see if we can encode
        // directly into the circular buffer.
        var encoded: std.Io.Writer.Allocating = .init(self.alloc);
        defer encoded.deinit();

        // Encode the page into the buffer.
        const formatter: PageFormatter = formatter: {
            var formatter: PageFormatter = .init(&meta.node.data, .{
                .emit = .plain,
                .unwrap = true,
            });
            formatter.point_map = .{
                .alloc = self.alloc,
                .map = &meta.cell_map,
            };
            break :formatter formatter;
        };
        formatter.format(&encoded.writer) catch {
            // writer uses anyerror but the only realistic error on
            // an ArrayList is out of memory.
            return error.OutOfMemory;
        };
        assert(meta.cell_map.items.len == encoded.written().len);

        // If the node we're adding isn't soft-wrapped, we add the
        // trailing newline.
        const row = node.data.getRow(node.data.size.rows - 1);
        if (!row.wrap) {
            encoded.writer.writeByte('\n') catch return error.OutOfMemory;
            try meta.cell_map.append(
                self.alloc,
                meta.cell_map.getLastOrNull() orelse .{
                    .x = 0,
                    .y = 0,
                },
            );
        }

        // If our written data is empty, then there is nothing to
        // add to our data set.
        const written = encoded.written();
        if (written.len == 0) {
            self.assertIntegrity();
            return 0;
        }

        // Get our written data. If we're doing a reverse search then we
        // need to reverse all our encodings.
        switch (self.direction) {
            .forward => {},
            .reverse => {
                std.mem.reverse(u8, written);
                std.mem.reverse(point.Coordinate, meta.cell_map.items);
            },
        }

        // Ensure our buffers are big enough to store what we need.
        try self.data.ensureUnusedCapacity(self.alloc, written.len);
        try self.meta.ensureUnusedCapacity(self.alloc, 1);
        try self.chunk_buf.ensureTotalCapacity(self.alloc, self.meta.capacity());

        // Append our new node to the circular buffer.
        self.data.appendSliceAssumeCapacity(written);
        self.meta.appendAssumeCapacity(meta);

        self.assertIntegrity();
        return written.len;
    }

    /// Only for tests!
    fn testChangeNeedle(self: *SlidingWindow, new: []const u8) void {
        assert(new.len == self.needle.len);
        self.alloc.free(self.needle);
        self.needle = self.alloc.dupe(u8, new) catch unreachable;
    }

    fn assertIntegrity(self: *const SlidingWindow) void {
        if (comptime !std.debug.runtime_safety) return;

        // We don't run integrity checks on Valgrind because its soooooo slow,
        // Valgrind is our integrity checker, and we run these during unit
        // tests (non-Valgrind) anyways so we're verifying anyways.
        if (std.valgrind.runningOnValgrind() > 0) return;

        // Integrity check: verify our data matches our metadata exactly.
        var meta_it = self.meta.iterator(.forward);
        var data_len: usize = 0;
        while (meta_it.next()) |m| data_len += m.cell_map.items.len;
        assert(data_len == self.data.len());

        // Integrity check: verify our data offset is within bounds.
        assert(self.data.len() == 0 or self.data_offset < self.data.len());
    }
};

test "SlidingWindow empty on init" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "boo!");
    defer w.deinit();
    try testing.expectEqual(0, w.data.len());
    try testing.expectEqual(0, w.meta.len());
}

test "SlidingWindow single append" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "boo!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 22,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow single append case insensitive ASCII" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "Boo!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 22,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow single append single char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "b");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow single append no match" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "nope!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // No matches
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // Should still keep the page
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "boo!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should find two matches
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 79,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow two pages single char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "b");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should find two matches
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow two pages match across boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "hello, world");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("o, world!");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should find a match
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // We shouldn't prune because we don't have enough space
    try testing.expectEqual(2, w.meta.len());
}

test "SlidingWindow two pages no match across boundary with newline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "hello, world");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\no, world!");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should NOT find a match
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // We shouldn't prune because we don't have enough space
    try testing.expectEqual(2, w.meta.len());
}

test "SlidingWindow two pages no match across boundary with newline reverse" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "hello, world");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\no, world!");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    // Add both pages in reverse order
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);

    // Search should NOT find a match
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow two pages no match prunes first page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "nope!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should find nothing
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // We should've pruned our page because the second page
    // has enough text to contain our needle.
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages no match keeps both pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Imaginary needle for search. Doesn't match!
    var needle_list: std.ArrayList(u8) = .empty;
    defer needle_list.deinit(alloc);
    try needle_list.appendNTimes(alloc, 'x', first_page_rows * s.pages.cols);
    const needle: []const u8 = needle_list.items;

    var w: SlidingWindow = try .init(alloc, .forward, needle);
    defer w.deinit();

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node.next.?);

    // Search should find nothing
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // No pruning because both pages are needed to fit needle.
    try testing.expectEqual(2, w.meta.len());
}

test "SlidingWindow single append across circular buffer boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "abc");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("XXXXXXXXXXXXXXXXXXXboo!XXXXX");

    // We are trying to break a circular buffer boundary so the way we
    // do this is to duplicate the data then do a failing search. This
    // will cause the first page to be pruned. The next time we append we'll
    // put it in the middle of the circ buffer. We assert this so that if
    // our implementation changes our test will fail.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node);
    {
        // No wrap around yet
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len == 0);
    }

    // Search non-match, prunes page
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());

    // Change the needle, just needs to be the same length (not a real API)
    w.testChangeNeedle("boo");

    // Add new page, now wraps
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len > 0);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
}

test "SlidingWindow single append match on boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "abcd");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("o!XXXXXXXXXXXXXXXXXXXbo");

    // We need to surgically modify the last row to be soft-wrapped
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    node.data.getRow(node.data.size.rows - 1).wrap = true;

    // We are trying to break a circular buffer boundary so the way we
    // do this is to duplicate the data then do a failing search. This
    // will cause the first page to be pruned. The next time we append we'll
    // put it in the middle of the circ buffer. We assert this so that if
    // our implementation changes our test will fail.
    _ = try w.append(node);
    _ = try w.append(node);
    {
        // No wrap around yet
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len == 0);
    }

    // Search non-match, prunes page
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());

    // Change the needle, just needs to be the same length (not a real API)
    w.testChangeNeedle("boo!");

    // Add new page, now wraps
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len > 0);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
}

test "SlidingWindow single append reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "boo!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 22,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow single append no match reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "nope!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);

    // No matches
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // Should still keep the page
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "boo!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Add both pages in reverse order
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);

    // Search should find two matches (in reverse order)
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 79,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow two pages match across boundary reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "hello, world");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "hell"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("hell");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("o, world!");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);

    // Add both pages in reverse order
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);

    // Search should find a match
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // In reverse mode, the last appended meta (first original page) is large
    // enough to contain needle.len - 1 bytes, so pruning occurs
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages no match prunes first page reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "nope!");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Add both pages in reverse order
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);

    // Search should find nothing
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // We should've pruned our page because the second page
    // has enough text to contain our needle.
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages no match keeps both pages reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 1000 });
    defer s.deinit();

    // Fill up the first page. The final bytes in the first page
    // are "boo!"
    const first_page_rows = s.pages.pages.first.?.data.capacity.rows;
    for (0..first_page_rows - 1) |_| try s.testWriteString("\n");
    for (0..s.pages.cols - 4) |_| try s.testWriteString("x");
    try s.testWriteString("boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    try s.testWriteString("\n");
    try testing.expect(s.pages.pages.first != s.pages.pages.last);
    try s.testWriteString("hello. boo!");

    // Imaginary needle for search. Doesn't match!
    var needle_list: std.ArrayList(u8) = .empty;
    defer needle_list.deinit(alloc);
    try needle_list.appendNTimes(alloc, 'x', first_page_rows * s.pages.cols);
    const needle: []const u8 = needle_list.items;

    var w: SlidingWindow = try .init(alloc, .reverse, needle);
    defer w.deinit();

    // Add both pages in reverse order
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node.next.?);
    _ = try w.append(node);

    // Search should find nothing
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // No pruning because both pages are needed to fit needle.
    try testing.expectEqual(2, w.meta.len());
}

test "SlidingWindow single append across circular buffer boundary reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "abc");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("XXXXXXXXXXXXXXXXXXXboo!XXXXX");

    // We are trying to break a circular buffer boundary so the way we
    // do this is to duplicate the data then do a failing search. This
    // will cause the first page to be pruned. The next time we append we'll
    // put it in the middle of the circ buffer. We assert this so that if
    // our implementation changes our test will fail.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    _ = try w.append(node);
    _ = try w.append(node);
    {
        // No wrap around yet
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len == 0);
    }

    // Search non-match, prunes page
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());

    // Change the needle, just needs to be the same length (not a real API)
    // testChangeNeedle doesn't reverse, so pass reversed needle for reverse mode
    w.testChangeNeedle("oob");

    // Add new page, now wraps
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len > 0);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
}

test "SlidingWindow single append match on boundary reversed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "abcd");
    defer w.deinit();

    var s = try Screen.init(alloc, .{ .cols = 80, .rows = 24, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("o!XXXXXXXXXXXXXXXXXXXbo");

    // We need to surgically modify the last row to be soft-wrapped
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    node.data.getRow(node.data.size.rows - 1).wrap = true;

    // We are trying to break a circular buffer boundary so the way we
    // do this is to duplicate the data then do a failing search. This
    // will cause the first page to be pruned. The next time we append we'll
    // put it in the middle of the circ buffer. We assert this so that if
    // our implementation changes our test will fail.
    _ = try w.append(node);
    _ = try w.append(node);
    {
        // No wrap around yet
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len == 0);
    }

    // Search non-match, prunes page
    try testing.expect(w.next() == null);
    try testing.expectEqual(1, w.meta.len());

    // Change the needle, just needs to be the same length (not a real API)
    // testChangeNeedle doesn't reverse, so pass reversed needle for reverse mode
    w.testChangeNeedle("!oob");

    // Add new page, now wraps
    _ = try w.append(node);
    {
        const slices = w.data.getPtrSlice(0, w.data.len());
        try testing.expect(slices[0].len > 0);
        try testing.expect(slices[1].len > 0);
    }
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end).?);
    }
    try testing.expect(w.next() == null);
}

test "SlidingWindow single append soft wrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "boo!");
    defer w.deinit();

    var t: Terminal = try .init(alloc, .{ .cols = 4, .rows = 5 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("A\r\nxxboo!\r\nC");

    // We want to test single-page cases.
    const screen = t.screens.active;
    try testing.expect(screen.pages.pages.first == screen.pages.pages.last);
    const node: *PageList.List.Node = screen.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 2,
            .y = 1,
        } }, screen.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 2,
        } }, screen.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

test "SlidingWindow single append reversed soft wrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .reverse, "boo!");
    defer w.deinit();

    var t: Terminal = try .init(alloc, .{ .cols = 4, .rows = 5 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    try s.nextSlice("A\r\nxxboo!\r\nC");

    // We want to test single-page cases.
    const screen = t.screens.active;
    try testing.expect(screen.pages.pages.first == screen.pages.pages.last);
    const node: *PageList.List.Node = screen.pages.pages.first.?;
    _ = try w.append(node);

    // We should be able to find two matches.
    {
        const h = w.next().?;
        const sel = h.untracked();
        try testing.expectEqual(point.Point{ .active = .{
            .x = 2,
            .y = 1,
        } }, screen.pages.pointFromPin(.active, sel.start));
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 2,
        } }, screen.pages.pointFromPin(.active, sel.end));
    }
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);
}

// This tests a real bug that occurred where a whitespace-only page
// that encodes to zero bytes would crash.
test "SlidingWindow append whitespace only node" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w: SlidingWindow = try .init(alloc, .forward, "x");
    defer w.deinit();

    var s = try Screen.init(alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 0,
    });
    defer s.deinit();

    // By setting the empty page to wrap we get a zero-byte page.
    // This is invasive but its otherwise hard to reproduce naturally
    // without creating a slow test.
    const node: *PageList.List.Node = s.pages.pages.first.?;
    const last_row = node.data.getRow(node.data.size.rows - 1);
    last_row.wrap = true;

    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    _ = try w.append(node);

    // No matches expected
    try testing.expect(w.next() == null);
}
