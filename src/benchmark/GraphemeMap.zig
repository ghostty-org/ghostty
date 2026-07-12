//! Benchmark grapheme storage on a page: the bitmap allocator that holds
//! multi-codepoint grapheme data plus the cell -> codepoints offset hash map.
//!
//! The `churn` mode models emoji-heavy terminal output that repeatedly
//! overwrites cells on a page whose grapheme allocator is close to full:
//! every overwritten cell frees its chunks and map entry, then allocates
//! and inserts again. This is the per-cell cost of printing a grapheme
//! over an existing one, and is sensitive to both allocator scan cost and
//! map probe/hash cost.
const GraphemeMap = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const pagepkg = @import("../terminal/page.zig");
const Benchmark = @import("Benchmark.zig");

const log = std.log.scoped(.@"grapheme-map-bench");

opts: Options,
page: terminal.Page,
entry_count: usize,
cps: []const u21,

pub const Options = struct {
    /// Requested grapheme working-set size in cells. Must be a power of
    /// two and at least 16.
    entries: u16 = 4096,

    /// Number of extra codepoints attached to each cell. Each chunk of
    /// grapheme storage holds 4 codepoints, so values above 4 exercise
    /// multi-chunk allocations.
    cps: u8 = 1,

    /// Percentage of the entries populated before the timed operation.
    /// Values above 100 are treated as 100.
    @"load-percent": u8 = 100,

    /// Number of complete passes over the populated cells per step.
    loops: u16 = 1,

    /// Operation to perform in the timed region.
    mode: Mode = .churn,
};

pub const Mode = enum {
    /// Look up the grapheme data for every populated cell.
    lookup,

    /// Clear and re-append the grapheme data for every populated cell.
    churn,
};

pub fn create(alloc: Allocator, opts: Options) !*GraphemeMap {
    if (opts.entries < 16 or !std.math.isPowerOfTwo(opts.entries)) {
        log.err("entries must be a power of two greater than or equal to 16", .{});
        return error.InvalidEntries;
    }
    if (opts.cps < 1) {
        log.err("cps must be at least 1", .{});
        return error.InvalidCps;
    }

    const ptr = try alloc.create(GraphemeMap);
    errdefer alloc.destroy(ptr);

    const cps = try alloc.alloc(u21, opts.cps);
    errdefer alloc.free(cps);
    for (cps, 0..) |*cp, i| cp.* = @intCast(0x1F600 + i);

    // Size the allocator to exactly fit the working set so that at 100%
    // load we exercise a full allocator, the worst case for chunk searches.
    const chunks_per_entry = std.math.divCeil(
        usize,
        @as(usize, opts.cps) * @sizeOf(u21),
        pagepkg.grapheme_chunk,
    ) catch unreachable;
    var page = try terminal.Page.init(.{
        .cols = opts.entries,
        .rows = 1,
        .grapheme_bytes = @intCast(
            opts.entries * chunks_per_entry * pagepkg.grapheme_chunk,
        ),
    });
    errdefer page.deinit();

    const load = @min(opts.@"load-percent", 100);
    const entry_count = @max(
        1,
        @divFloor(@as(usize, opts.entries) * load, 100),
    );
    for (0..entry_count) |x| {
        const rac = page.getRowAndCell(x, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'A' },
        };
        try page.setGraphemes(rac.row, rac.cell, cps);
    }

    ptr.* = .{
        .opts = opts,
        .page = page,
        .entry_count = entry_count,
        .cps = cps,
    };
    return ptr;
}

pub fn destroy(self: *GraphemeMap, alloc: Allocator) void {
    self.page.deinit();
    alloc.free(self.cps);
    alloc.destroy(self);
}

pub fn benchmark(self: *GraphemeMap) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .lookup => stepLookup,
            .churn => stepChurn,
        },
    });
}

fn stepLookup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *GraphemeMap = @ptrCast(@alignCast(ptr));

    for (0..self.opts.loops) |_| {
        for (0..self.entry_count) |x| {
            const cell = self.page.getRowAndCell(x, 0).cell;
            const data = self.page.lookupGrapheme(cell) orelse
                return error.BenchmarkFailed;
            std.mem.doNotOptimizeAway(data);
        }
    }
}

fn stepChurn(ptr: *anyopaque) Benchmark.Error!void {
    const self: *GraphemeMap = @ptrCast(@alignCast(ptr));

    for (0..self.opts.loops) |_| {
        for (0..self.entry_count) |x| {
            const rac = self.page.getRowAndCell(x, 0);
            self.page.clearGrapheme(rac.cell);
            self.page.setGraphemes(rac.row, rac.cell, self.cps) catch
                return error.BenchmarkFailed;
        }
    }
}

test GraphemeMap {
    const alloc = std.testing.allocator;

    inline for (.{ Mode.lookup, Mode.churn }) |mode| {
        const impl = try GraphemeMap.create(alloc, .{
            .entries = 64,
            .cps = 5,
            .mode = mode,
        });
        defer impl.destroy(alloc);

        const bench = impl.benchmark();
        _ = try bench.run(.once);
    }
}
