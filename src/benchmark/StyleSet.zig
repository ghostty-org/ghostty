//! Benchmark style-set lookup and dead-entry rebuilds.
//!
//! Terminal cells store stable style IDs, so ordinary printing and rendering
//! do not hash styles. Hash-table work is concentrated in actual SGR state
//! changes and rebuilding styles after cell references are cleared. The two
//! modes below isolate those workloads.
const StyleSet = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../terminal/main.zig");
const style = @import("../terminal/style.zig");
const Benchmark = @import("Benchmark.zig");

const log = std.log.scoped(.@"style-set-bench");

opts: Options,
page: terminal.Page,
values: []style.Style,
ids: []style.Id,
cursor: u24 = 0x100000,

pub const Options = struct {
    /// Number of distinct styles in the working set.
    entries: u16 = 128,

    /// Number of complete passes over the working set per step.
    loops: u32 = 1,

    /// Operation to perform in the timed region.
    mode: Mode = .lookup,
};

pub const Mode = enum {
    /// Add styles that are already live, then release the added reference.
    lookup,

    /// Rebuild a working set whose previous entries are all dead, then clear
    /// all of its references again.
    churn,

    /// Keep the set nearly full while repeatedly adding and releasing unique
    /// styles. This exercises dense deletion without the all-dead reset.
    replace,
};

fn styleFor(n: u24) style.Style {
    return .{ .fg_color = .{ .rgb = .{
        .r = @truncate(n),
        .g = @truncate(n >> 8),
        .b = @truncate(n >> 16),
    } } };
}

pub fn create(alloc: Allocator, opts: Options) !*StyleSet {
    if (opts.entries == 0 or opts.entries > style.Set.max_count) {
        log.err("entries must be between 1 and {}", .{style.Set.max_count});
        return error.InvalidEntries;
    }
    if (opts.mode == .replace and opts.entries < 2) {
        log.err("replace mode requires at least 2 entries", .{});
        return error.InvalidEntries;
    }

    const ptr = try alloc.create(StyleSet);
    errdefer alloc.destroy(ptr);

    var page = try terminal.Page.init(.{
        .cols = 1,
        .rows = 1,
        .styles = @intCast(style.Set.capacityForCount(opts.entries)),
    });
    errdefer page.deinit();

    const values = try alloc.alloc(style.Style, opts.entries);
    errdefer alloc.free(values);

    const ids = try alloc.alloc(style.Id, opts.entries);
    errdefer alloc.free(ids);

    for (values, 0..) |*value, i| {
        value.* = styleFor(@intCast(i + 1));
    }

    switch (opts.mode) {
        .lookup, .churn => {
            for (values, ids) |value, *id| {
                id.* = try page.styles.add(page.memory, value);
            }
            if (opts.mode == .churn) {
                for (ids) |id| page.styles.release(page.memory, id);
            }
        },
        .replace => {
            // Leave one slot for the unique style added by stepReplace while
            // keeping the table dense enough to exercise deletion backshifts.
            for (
                values[0 .. values.len - 1],
                ids[0 .. ids.len - 1],
            ) |value, *id| {
                id.* = try page.styles.add(page.memory, value);
            }
        },
    }

    ptr.* = .{
        .opts = opts,
        .page = page,
        .values = values,
        .ids = ids,
    };
    return ptr;
}

pub fn destroy(self: *StyleSet, alloc: Allocator) void {
    self.page.deinit();
    alloc.free(self.ids);
    alloc.free(self.values);
    alloc.destroy(self);
}

pub fn benchmark(self: *StyleSet) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .lookup => stepLookup,
            .churn => stepChurn,
            .replace => stepReplace,
        },
    });
}

fn stepReplace(ptr: *anyopaque) Benchmark.Error!void {
    const self: *StyleSet = @ptrCast(@alignCast(ptr));

    for (0..self.opts.loops) |_| {
        for (self.values) |_| {
            const id = self.page.styles.add(
                self.page.memory,
                styleFor(self.cursor),
            ) catch return error.BenchmarkFailed;
            std.mem.doNotOptimizeAway(id);
            self.page.styles.release(self.page.memory, id);
            self.cursor +%= 1;
        }
    }
}

fn stepLookup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *StyleSet = @ptrCast(@alignCast(ptr));

    for (0..self.opts.loops) |_| {
        for (self.values) |value| {
            const id = self.page.styles.add(self.page.memory, value) catch
                return error.BenchmarkFailed;
            std.mem.doNotOptimizeAway(id);
            self.page.styles.release(self.page.memory, id);
        }
    }
}

fn stepChurn(ptr: *anyopaque) Benchmark.Error!void {
    const self: *StyleSet = @ptrCast(@alignCast(ptr));

    for (0..self.opts.loops) |_| {
        for (self.values, self.ids) |value, *id| {
            id.* = self.page.styles.add(self.page.memory, value) catch
                return error.BenchmarkFailed;
        }
        for (self.ids) |id| self.page.styles.release(self.page.memory, id);
    }
}

test StyleSet {
    const alloc = std.testing.allocator;

    inline for (.{ Mode.lookup, Mode.churn, Mode.replace }) |mode| {
        const impl = try StyleSet.create(alloc, .{
            .entries = 64,
            .mode = mode,
        });
        defer impl.destroy(alloc);

        const bench = impl.benchmark();
        _ = try bench.run(.once);
    }
}
