//! Benchmark hyperlink cell-map lookups and remove/insert churn.
//!
//! Hyperlink cells are stored in a fixed-capacity, open-addressed hash map.
//! The `churn` mode models terminal output that repeatedly replaces cells in
//! a page whose hyperlink map is already close to full. This is particularly
//! useful for catching probe-length cliffs at high load factors.
const HyperlinkMap = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const hyperlink = @import("../terminal/hyperlink.zig");
const Benchmark = @import("Benchmark.zig");

const log = std.log.scoped(.@"hyperlink-map-bench");

opts: Options,
page: terminal.Page,
link_id: hyperlink.Id,
entry_count: usize,

pub const Options = struct {
    /// Requested hyperlink working-set size. Must be a power of two and at
    /// least 16. The map may reserve additional probe headroom.
    entries: u16 = 4096,

    /// Percentage of the map populated before the timed operation.
    /// Values above 100 are treated as 100.
    @"load-percent": u8 = 100,

    /// Number of complete passes over the populated cells per step.
    loops: u16 = 1,

    /// Operation to perform in the timed region.
    mode: Mode = .churn,
};

pub const Mode = enum {
    /// Look up every populated hyperlink cell.
    lookup,

    /// Remove and reinsert every populated hyperlink cell.
    churn,
};

pub fn create(alloc: Allocator, opts: Options) !*HyperlinkMap {
    if (opts.entries < 16 or !std.math.isPowerOfTwo(opts.entries)) {
        log.err("entries must be a power of two greater than or equal to 16", .{});
        return error.InvalidEntries;
    }

    const ptr = try alloc.create(HyperlinkMap);
    errdefer alloc.destroy(ptr);

    // The page requests one map slot per `hyperlink_cell_multiplier` set
    // entries. Keep this relationship explicit so `entries` is the working
    // set size under test regardless of the map's reserved probe headroom.
    const set_entries = opts.entries / 16;
    var page = try terminal.Page.init(.{
        .cols = opts.entries,
        .rows = 1,
        .hyperlink_bytes = @intCast(
            @as(usize, set_entries) * @sizeOf(hyperlink.Set.Item),
        ),
    });
    errdefer page.deinit();

    if (page.hyperlinkCapacity() < opts.entries) {
        log.err("insufficient map capacity expected_at_least={} actual={}", .{
            opts.entries,
            page.hyperlinkCapacity(),
        });
        return error.UnexpectedCapacity;
    }

    const link_id = try page.insertHyperlink(.{
        .id = .{ .implicit = 1 },
        .uri = "https://example.com/benchmark",
    });

    const load = @min(opts.@"load-percent", 100);
    const entry_count = @max(
        1,
        @divFloor(@as(usize, opts.entries) * load, 100),
    );
    for (0..entry_count) |x| {
        const rac = page.getRowAndCell(x, 0);
        page.hyperlink_set.use(page.memory, link_id);
        try page.setHyperlink(rac.row, rac.cell, link_id);
    }

    ptr.* = .{
        .opts = opts,
        .page = page,
        .link_id = link_id,
        .entry_count = entry_count,
    };
    return ptr;
}

pub fn destroy(self: *HyperlinkMap, alloc: Allocator) void {
    self.page.deinit();
    alloc.destroy(self);
}

pub fn benchmark(self: *HyperlinkMap) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .lookup => stepLookup,
            .churn => stepChurn,
        },
    });
}

fn stepLookup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *HyperlinkMap = @ptrCast(@alignCast(ptr));

    for (0..self.opts.loops) |_| {
        for (0..self.entry_count) |x| {
            const cell = self.page.getRowAndCell(x, 0).cell;
            const id = self.page.lookupHyperlink(cell) orelse
                return error.BenchmarkFailed;
            std.mem.doNotOptimizeAway(id);
        }
    }
}

fn stepChurn(ptr: *anyopaque) Benchmark.Error!void {
    const self: *HyperlinkMap = @ptrCast(@alignCast(ptr));

    for (0..self.opts.loops) |_| {
        for (0..self.entry_count) |x| {
            const rac = self.page.getRowAndCell(x, 0);
            self.page.clearHyperlink(rac.cell);
            self.page.hyperlink_set.use(self.page.memory, self.link_id);
            self.page.setHyperlink(rac.row, rac.cell, self.link_id) catch
                return error.BenchmarkFailed;
        }
    }
}

test HyperlinkMap {
    const alloc = std.testing.allocator;

    inline for (.{ Mode.lookup, Mode.churn }) |mode| {
        const impl = try HyperlinkMap.create(alloc, .{
            .entries = 64,
            .mode = mode,
        });
        defer impl.destroy(alloc);

        const bench = impl.benchmark();
        _ = try bench.run(.once);
    }
}
