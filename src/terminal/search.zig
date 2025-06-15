//! Search functionality for the terminal.
//!
//! At the time of writing this comment, this is a **work in progress**.
//!
//! Search at the time of writing is implemented using a simple
//! boyer-moore-horspool algorithm. The suboptimal part of the implementation
//! is that we need to encode each terminal page into a text buffer in order
//! to apply BMH to it. This is because the terminal page is not laid out
//! in a flat text form.
//!
//! To minimize memory usage, we use a sliding window to search for the
//! needle. The sliding window only keeps the minimum amount of page data
//! in memory to search for a needle (i.e. `needle.len - 1` bytes of overlap
//! between terminal pages).
//!
//! Future work:
//!
//!   - PageListSearch on a PageList concurrently with another thread
//!   - Handle pruned pages in a PageList to ensure we don't keep references
//!   - Repeat search a changing active area of the screen
//!   - Reverse search so that more recent matches are found first
//!

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const CircBuf = @import("../datastruct/main.zig").CircBuf;
const terminal = @import("main.zig");
const point = terminal.point;
const Page = terminal.Page;
const PageList = terminal.PageList;
const Pin = PageList.Pin;
const Selection = terminal.Selection;
const Screen = terminal.Screen;

/// Searches for a term in a PageList structure.
///
/// At the time of writing, this does not support searching a pagelist
/// simultaneously as its being used by another thread. This will be resolved
/// in the future.
pub const PageListSearch = struct {
    /// The list we're searching.
    list: *PageList,

    /// The sliding window of page contents and nodes to search.
    window: SlidingWindow,

    /// Initialize the page list search.
    ///
    /// The needle is not copied and must be kept alive for the duration
    /// of the search operation.
    pub fn init(
        alloc: Allocator,
        list: *PageList,
        needle: []const u8,
    ) Allocator.Error!PageListSearch {
        var window = try SlidingWindow.init(alloc, needle);
        errdefer window.deinit(alloc);

        return .{
            .list = list,
            .window = window,
        };
    }

    pub fn deinit(self: *PageListSearch, alloc: Allocator) void {
        self.window.deinit(alloc);
    }

    /// Find the next match for the needle in the pagelist. This returns
    /// null when there are no more matches.
    pub fn next(
        self: *PageListSearch,
        alloc: Allocator,
    ) Allocator.Error!?Selection {
        // Try to search for the needle in the window. If we find a match
        // then we can return that and we're done.
        if (self.window.next()) |sel| return sel;

        // Get our next node. If we have a value in our window then we
        // can determine the next node. If we don't, we've never setup the
        // window so we use our first node.
        var node_: ?*PageList.List.Node = if (self.window.meta.last()) |meta|
            meta.node.next
        else
            self.list.pages.first;

        // Add one pagelist node at a time, look for matches, and repeat
        // until we find a match or we reach the end of the pagelist.
        // This append then next pattern limits memory usage of the window.
        while (node_) |node| : (node_ = node.next) {
            try self.window.append(alloc, node);
            if (self.window.next()) |sel| return sel;
        }

        // We've reached the end of the pagelist, no matches.
        return null;
    }
};

/// Searches page nodes via a sliding window. The sliding window maintains
/// the invariant that data isn't pruned until (1) we've searched it and
/// (2) we've accounted for overlaps across pages to fit the needle.
///
/// The sliding window is first initialized empty. Pages are then appended
/// in the order to search them. If you're doing a reverse search then the
/// pages should be appended in reverse order and the needle should be
/// reversed.
///
/// All appends grow the window. The window is only pruned when a searc
/// is done (positive or negative match) via `next()`.
///
/// To avoid unnecessary memory growth, the recommended usage is to
/// call `next()` until it returns null and then `append` the next page
/// and repeat the process. This will always maintain the minimum
/// required memory to search for the needle.
const SlidingWindow = struct {
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

    /// The needle we're searching for. Does not own the memory.
    needle: []const u8,

    /// A buffer to store the overlap search data. This is used to search
    /// overlaps between pages where the match starts on one page and
    /// ends on another. The length is always `needle.len * 2`.
    overlap_buf: []u8,

    const DataBuf = CircBuf(u8, 0);
    const MetaBuf = CircBuf(Meta, undefined);
    const Meta = struct {
        node: *PageList.List.Node,
        cell_map: Page.CellMap,

        pub fn deinit(self: *Meta) void {
            self.cell_map.deinit();
        }
    };

    pub fn init(
        alloc: Allocator,
        needle: []const u8,
    ) Allocator.Error!SlidingWindow {
        var data = try DataBuf.init(alloc, 0);
        errdefer data.deinit(alloc);

        var meta = try MetaBuf.init(alloc, 0);
        errdefer meta.deinit(alloc);

        const overlap_buf = try alloc.alloc(u8, needle.len * 2);
        errdefer alloc.free(overlap_buf);

        return .{
            .data = data,
            .meta = meta,
            .needle = needle,
            .overlap_buf = overlap_buf,
        };
    }

    pub fn deinit(self: *SlidingWindow, alloc: Allocator) void {
        alloc.free(self.overlap_buf);
        self.data.deinit(alloc);

        var meta_it = self.meta.iterator(.forward);
        while (meta_it.next()) |meta| meta.deinit();
        self.meta.deinit(alloc);
    }

    /// Clear all data but retain allocated capacity.
    pub fn clearAndRetainCapacity(self: *SlidingWindow) void {
        var meta_it = self.meta.iterator(.forward);
        while (meta_it.next()) |meta| meta.deinit();
        self.meta.clear();
        self.data.clear();
        self.data_offset = 0;
    }

    /// Search the window for the next occurrence of the needle. As
    /// the window moves, the window will prune itself while maintaining
    /// the invariant that the window is always big enough to contain
    /// the needle.
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
            return self.selection(idx, self.needle.len);
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
            return self.selection(slices[0].len + idx, self.needle.len);
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
                meta.deinit();
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
            for (0..meta_count) |_| meta_it.next().?.deinit();
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
        return .init(tl, br, false);
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
                .y = map.y,
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
    pub fn append(
        self: *SlidingWindow,
        alloc: Allocator,
        node: *PageList.List.Node,
    ) Allocator.Error!void {
        // Initialize our metadata for the node.
        var meta: Meta = .{
            .node = node,
            .cell_map = .init(alloc),
        };
        errdefer meta.deinit();

        // This is suboptimal but we need to encode the page once to
        // temporary memory, and then copy it into our circular buffer.
        // In the future, we should benchmark and see if we can encode
        // directly into the circular buffer.
        var encoded: std.ArrayListUnmanaged(u8) = .{};
        defer encoded.deinit(alloc);

        // Encode the page into the buffer.
        const page: *const Page = &meta.node.data;
        _ = page.encodeUtf8(
            encoded.writer(alloc),
            .{ .cell_map = &meta.cell_map },
        ) catch {
            // writer uses anyerror but the only realistic error on
            // an ArrayList is out of memory.
            return error.OutOfMemory;
        };
        assert(meta.cell_map.items.len == encoded.items.len);

        // Ensure our buffers are big enough to store what we need.
        try self.data.ensureUnusedCapacity(alloc, encoded.items.len);
        try self.meta.ensureUnusedCapacity(alloc, 1);

        // Append our new node to the circular buffer.
        try self.data.appendSlice(encoded.items);
        try self.meta.append(meta);

        self.assertIntegrity();
    }

    fn assertIntegrity(self: *const SlidingWindow) void {
        if (comptime !std.debug.runtime_safety) return;

        // Integrity check: verify our data matches our metadata exactly.
        var meta_it = self.meta.iterator(.forward);
        var data_len: usize = 0;
        while (meta_it.next()) |m| data_len += m.cell_map.items.len;
        assert(data_len == self.data.len());

        // Integrity check: verify our data offset is within bounds.
        assert(self.data_offset < self.data.len());
    }
};

test "PageListSearch single page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 0);
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");
    try testing.expect(s.pages.pages.first == s.pages.pages.last);

    var search = try PageListSearch.init(alloc, &s.pages, "boo!");
    defer search.deinit(alloc);

    // We should be able to find two matches.
    {
        const sel = (try search.next(alloc)).?;
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
        const sel = (try search.next(alloc)).?;
        try testing.expectEqual(point.Point{ .active = .{
            .x = 19,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.start()).?);
        try testing.expectEqual(point.Point{ .active = .{
            .x = 22,
            .y = 0,
        } }, s.pages.pointFromPin(.active, sel.end()).?);
    }
    try testing.expect((try search.next(alloc)) == null);
    try testing.expect((try search.next(alloc)) == null);
}

test "SlidingWindow empty on init" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w = try SlidingWindow.init(alloc, "boo!");
    defer w.deinit(alloc);
    try testing.expectEqual(0, w.data.len());
    try testing.expectEqual(0, w.meta.len());
}

test "SlidingWindow single append" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w = try SlidingWindow.init(alloc, "boo!");
    defer w.deinit(alloc);

    var s = try Screen.init(alloc, 80, 24, 0);
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    try w.append(alloc, node);

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

    var w = try SlidingWindow.init(alloc, "nope!");
    defer w.deinit(alloc);

    var s = try Screen.init(alloc, 80, 24, 0);
    defer s.deinit();
    try s.testWriteString("hello. boo! hello. boo!");

    // We want to test single-page cases.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    try w.append(alloc, node);

    // No matches
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // Should still keep the page
    try testing.expectEqual(1, w.meta.len());
}

test "SlidingWindow two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w = try SlidingWindow.init(alloc, "boo!");
    defer w.deinit(alloc);

    var s = try Screen.init(alloc, 80, 24, 1000);
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
    try w.append(alloc, node);
    try w.append(alloc, node.next.?);

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

    var w = try SlidingWindow.init(alloc, "hello, world");
    defer w.deinit(alloc);

    var s = try Screen.init(alloc, 80, 24, 1000);
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
    try w.append(alloc, node);
    try w.append(alloc, node.next.?);

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

test "SlidingWindow two pages no match prunes first page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w = try SlidingWindow.init(alloc, "nope!");
    defer w.deinit(alloc);

    var s = try Screen.init(alloc, 80, 24, 1000);
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
    try w.append(alloc, node);
    try w.append(alloc, node.next.?);

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

    var s = try Screen.init(alloc, 80, 24, 1000);
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
    var needle_list = std.ArrayList(u8).init(alloc);
    defer needle_list.deinit();
    try needle_list.appendNTimes('x', first_page_rows * s.pages.cols);
    const needle: []const u8 = needle_list.items;

    var w = try SlidingWindow.init(alloc, needle);
    defer w.deinit(alloc);

    // Add both pages
    const node: *PageList.List.Node = s.pages.pages.first.?;
    try w.append(alloc, node);
    try w.append(alloc, node.next.?);

    // Search should find nothing
    try testing.expect(w.next() == null);
    try testing.expect(w.next() == null);

    // No pruning because both pages are needed to fit needle.
    try testing.expectEqual(2, w.meta.len());
}

test "SlidingWindow single append across circular buffer boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var w = try SlidingWindow.init(alloc, "abc");
    defer w.deinit(alloc);

    var s = try Screen.init(alloc, 80, 24, 0);
    defer s.deinit();
    try s.testWriteString("XXXXXXXXXXXXXXXXXXXboo!XXXXX");

    // We are trying to break a circular buffer boundary so the way we
    // do this is to duplicate the data then do a failing search. This
    // will cause the first page to be pruned. The next time we append we'll
    // put it in the middle of the circ buffer. We assert this so that if
    // our implementation changes our test will fail.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    try w.append(alloc, node);
    try w.append(alloc, node);
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
    w.needle = "boo";

    // Add new page, now wraps
    try w.append(alloc, node);
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

    var w = try SlidingWindow.init(alloc, "abcd");
    defer w.deinit(alloc);

    var s = try Screen.init(alloc, 80, 24, 0);
    defer s.deinit();
    try s.testWriteString("o!XXXXXXXXXXXXXXXXXXXbo");

    // We are trying to break a circular buffer boundary so the way we
    // do this is to duplicate the data then do a failing search. This
    // will cause the first page to be pruned. The next time we append we'll
    // put it in the middle of the circ buffer. We assert this so that if
    // our implementation changes our test will fail.
    try testing.expect(s.pages.pages.first == s.pages.pages.last);
    const node: *PageList.List.Node = s.pages.pages.first.?;
    try w.append(alloc, node);
    try w.append(alloc, node);
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
    w.needle = "boo!";

    // Add new page, now wraps
    try w.append(alloc, node);
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
