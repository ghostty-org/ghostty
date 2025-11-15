const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const CircBuf = @import("../../datastruct/main.zig").CircBuf;
const terminal = @import("../main.zig");
const point = terminal.point;
const PageList = terminal.PageList;
const Pin = PageList.Pin;
const Selection = terminal.Selection;
const Screen = terminal.Screen;
const PageFormatter = @import("../formatter.zig").PageFormatter;

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
            .needle = needle,
            .direction = direction,
            .overlap_buf = overlap_buf,
        };
    }

    pub fn deinit(self: *SlidingWindow) void {
        self.alloc.free(self.overlap_buf);
        self.alloc.free(self.needle);
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
    /// It may seem wasteful to return a full selection, since the needle
    /// length is known it seems like we can get away with just returning
    /// the start index. However, returning a full selection will give us
    /// more flexibility in the future (e.g. if we want to support regex
    /// searches or other more complex searches). It does cost us some memory,
    /// but searches are expected to be relatively rare compared to normal
    /// operations and can eat up some extra memory temporarily.
    pub fn next(self: *SlidingWindow) ?Selection {
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
        if (std.mem.indexOf(u8, slices[0], self.needle)) |idx| {
            return self.selection(
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
            const idx = std.mem.indexOf(
                u8,
                self.overlap_buf[0..overlap_len],
                self.needle,
            ) orelse break :overlap;

            // We found a match in the overlap buffer. We need to map the
            // index back to the data buffer in order to get our selection.
            return self.selection(
                slices[0].len - prefix.len + idx,
                self.needle.len,
            );
        }

        // Search the last slice for the needle.
        if (std.mem.indexOf(u8, slices[1], self.needle)) |idx| {
            return self.selection(
                slices[0].len + idx,
                self.needle.len,
            );
        }

        // No match. We keep `needle.len - 1` bytes available to
        // handle the future overlap case.
        var meta_it = self.meta.iterator(.reverse);
        prune: {
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

    /// Return a selection for the given start and length into the data
    /// buffer and also prune the data/meta buffers if possible up to
    /// this start index.
    ///
    /// The start index is assumed to be relative to the offset. i.e.
    /// index zero is actually at `self.data[self.data_offset]`. The
    /// selection will account for the offset.
    fn selection(
        self: *SlidingWindow,
        start_offset: usize,
        len: usize,
    ) Selection {
        const start = start_offset + self.data_offset;
        assert(start < self.data.len());
        assert(start + len <= self.data.len());

        // meta_consumed is the number of bytes we've consumed in the
        // data buffer up to and NOT including the meta where we've
        // found our pin. This is important because it tells us the
        // amount of data we can safely deleted from self.data since
        // we can't partially delete a meta block's data. (The partial
        // amount is represented by self.data_offset).
        var meta_it = self.meta.iterator(.forward);
        var meta_consumed: usize = 0;
        const tl: Pin = pin(&meta_it, &meta_consumed, start);

        // Store the information required to prune later. We store this
        // now because we only want to prune up to our START so we can
        // find overlapping matches.
        const tl_meta_idx = meta_it.idx - 1;
        const tl_meta_consumed = meta_consumed;

        // We have to seek back so that we reinspect our current
        // iterator value again in case the start and end are in the
        // same segment.
        meta_it.seekBy(-1);
        const br: Pin = pin(&meta_it, &meta_consumed, start + len - 1);
        assert(meta_it.idx >= 1);

        // Our offset into the current meta block is the start index
        // minus the amount of data fully consumed. We then add one
        // to move one past the match so we don't repeat it.
        self.data_offset = start - tl_meta_consumed + 1;

        // meta_it.idx is br's meta index plus one (because the iterator
        // moves one past the end; we call next() one last time). So
        // we compare against one to check that the meta that we matched
        // in has prior meta blocks we can prune.
        if (tl_meta_idx > 0) {
            // Deinit all our memory in the meta blocks prior to our
            // match.
            const meta_count = tl_meta_idx;
            meta_it.reset();
            for (0..meta_count) |_| meta_it.next().?.deinit(self.alloc);
            if (comptime std.debug.runtime_safety) {
                assert(meta_it.idx == meta_count);
                assert(meta_it.next().?.node == tl.node);
            }
            self.meta.deleteOldest(meta_count);

            // Delete all the data up to our current index.
            assert(tl_meta_consumed > 0);
            self.data.deleteOldest(tl_meta_consumed);
        }

        self.assertIntegrity();
        return switch (self.direction) {
            .forward => .init(tl, br, false),
            .reverse => .init(br, tl, false),
        };
    }

    /// Convert a data index into a pin.
    ///
    /// The iterator and offset are both expected to be passed by
    /// pointer so that the pin can be efficiently called for multiple
    /// indexes (in order). See selection() for an example.
    ///
    /// Precondition: the index must be within the data buffer.
    fn pin(
        it: *MetaBuf.Iterator,
        offset: *usize,
        idx: usize,
    ) Pin {
        while (it.next()) |meta| {
            // meta_i is the index we expect to find the match in the
            // cell map within this meta if it contains it.
            const meta_i = idx - offset.*;
            if (meta_i >= meta.cell_map.items.len) {
                // This meta doesn't contain the match. This means we
                // can also prune this set of data because we only look
                // forward.
                offset.* += meta.cell_map.items.len;
                continue;
            }

            // We found the meta that contains the start of the match.
            const map = meta.cell_map.items[meta_i];
            return .{
                .node = meta.node,
                .y = @intCast(map.y),
                .x = map.x,
            };
        }

        // Unreachable because it is a precondition that the index is
        // within the data buffer.
        unreachable;
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
            var formatter: PageFormatter = .init(&meta.node.data, .plain);
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

        // Get our written data. If we're doing a reverse search then we
        // need to reverse all our encodings.
        const written = encoded.written();
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

        // Append our new node to the circular buffer.
        try self.data.appendSlice(written);
        try self.meta.append(meta);

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
        assert(self.data_offset < self.data.len());
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
        const sel = w.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        const sel = w.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 22,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
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
        const sel = w.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 79,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        const sel = w.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
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
        const sel = w.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
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
        const sel = w.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
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
        const sel = w.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
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
        const sel = w.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 22,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        const sel = w.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
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
        const sel = w.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 10,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    {
        const sel = w.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 79,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
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
        const sel = w.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 76,
            .y = 22,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 7,
            .y = 23,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
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
        const sel = w.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
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
        const sel = w.next().?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 21,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    try testing.expect(w.next() == null);
}
