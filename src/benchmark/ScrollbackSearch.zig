//! Benchmarks searching a terminal's primary screen, including all of its
//! scrollback. Like the search thread, it calls `ScreenSearch.tick` until the
//! search needs more history and then `feed`, which the thread calls with the
//! terminal lock held.
//!
//! ## Input
//!
//! `--data` names a pre-generated VT byte stream. Parsing happens during setup
//! and is not part of the benchmark's timed region. Use the same saved corpus,
//! terminal dimensions, and scrollback limit when comparing revisions.
//!
//! `--compress` compresses cold scrollback during setup. Every search then
//! decodes those pages, as it does in a terminal whose idle history has been
//! compressed.
//!
//! ## Modes
//!
//! * `noop` parses the corpus but searches nothing. This is the process and
//!   setup baseline for the other modes.
//! * `typing` searches for every prefix of `--needle` in turn, starting a new
//!   search for each one, as the search thread does when the needle changes
//!   while a user types.
//! * `report` runs `typing` and prints the timings of each prefix's search,
//!   including the longest single history `feed`. It is intended for
//!   inspecting a corpus rather than timing comparisons.
//!
//! ## Examples
//!
//!     ghostty-bench +scrollback-search --mode=report --data=/tmp/log.vt
//!
//!     hyperfine --warmup 3 \
//!       'ghostty-bench +scrollback-search --mode=noop --data=/tmp/log.vt' \
//!       'ghostty-bench +scrollback-search --mode=typing --data=/tmp/log.vt'
const ScrollbackSearch = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const Terminal = terminalpkg.Terminal;
const Screen = terminalpkg.Screen;
const ScreenSearch = terminalpkg.search.Screen;
const global = @import("../global.zig");

const log = std.log.scoped(.@"scrollback-search-bench");

alloc: Allocator,
opts: Options,
terminal: Terminal,

pub const Options = struct {
    /// Set by the shared CLI parser so string options remain valid for the
    /// lifetime of the benchmark implementation.
    _arena: ?std.heap.ArenaAllocator = null,

    /// Select the search performed inside the timed benchmark.
    mode: Mode = .typing,

    /// Every prefix of this is searched in turn.
    needle: []const u8 = "error",

    /// Compress cold scrollback during setup.
    compress: bool = false,

    /// Dimensions used to construct the terminal which consumes the corpus.
    @"terminal-rows": u16 = 80,
    @"terminal-cols": u16 = 120,

    /// Maximum primary-screen scrollback allocation in bytes. The default
    /// matches the `scrollback-limit-bytes` config default.
    @"max-scrollback": usize = 50_000_000,

    /// Pre-generated VT corpus. `-` reads stdin, although a regular file is
    /// strongly recommended so comparisons can reuse identical input bytes.
    data: ?[]const u8 = null,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};

pub const Mode = enum {
    /// Establish process and setup overhead without searching.
    noop,

    /// Search for every prefix of the needle, one fresh search each.
    typing,

    /// Like typing, but print per-prefix timings.
    report,
};

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*ScrollbackSearch {
    const ptr = try alloc.create(ScrollbackSearch);
    errdefer alloc.destroy(ptr);

    ptr.* = .{
        .alloc = alloc,
        .opts = opts,
        .terminal = try .init(global.io(), alloc, .{
            .rows = opts.@"terminal-rows",
            .cols = opts.@"terminal-cols",
            .max_scrollback_bytes = opts.@"max-scrollback",
        }),
    };
    return ptr;
}

pub fn destroy(self: *ScrollbackSearch, alloc: Allocator) void {
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}

pub fn benchmark(self: *ScrollbackSearch) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .typing => stepTyping,
            .report => stepReport,
        },
        .setupFn = setup,
    });
}

/// Reset the terminal and consume the complete VT corpus before timing starts.
fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScrollbackSearch = @ptrCast(@alignCast(ptr));
    self.terminal.fullReset();

    self.loadCorpus() catch |err| {
        log.warn("failed to prepare scrollback search benchmark err={}", .{err});
        return error.BenchmarkFailed;
    };

    if (self.opts.compress and
        self.screen().pages.compress(.full) == .unsupported)
    {
        log.warn("scrollback compression is unsupported on this target", .{});
        return error.BenchmarkFailed;
    }
}

/// Feed the corpus in the same 64 KiB chunks used by the real IO thread.
fn loadCorpus(self: *ScrollbackSearch) !void {
    const data_file = try options.dataFile(self.opts.data) orelse return;
    defer data_file.close(global.io());

    var stream = self.terminal.vtStream();
    defer stream.deinit();

    var read_buf: [64 * 1024]u8 align(std.atomic.cache_line) = undefined;
    var file_reader = data_file.reader(global.io(), &read_buf);
    const reader = &file_reader.interface;

    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&buf) catch
            return file_reader.err orelse error.ReadFailed;
        if (n == 0) return;
        stream.nextSlice(buf[0..n]);
    }
}

/// Always search the primary screen because it owns the scrollback.
fn screen(self: *ScrollbackSearch) *Screen {
    return self.terminal.screens.get(.primary).?;
}

const Stats = struct {
    matches: usize = 0,
    total_ns: u64 = 0,
    feed_ns: u64 = 0,
    max_feed_ns: u64 = 0,
    feeds: usize = 0,
};

/// Run one complete search for `report`. This is `ScreenSearch.searchAll`
/// with each feed timed.
fn search(self: *ScrollbackSearch, needle: []const u8) !Stats {
    var stats: Stats = .{};
    const start = now();

    var s: ScreenSearch = try .init(self.alloc, self.screen(), needle);
    defer s.deinit();

    while (true) {
        s.tick() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SearchComplete => break,
            error.FeedRequired => {
                const feed_start = now();
                try s.feed();
                const ns = elapsed(feed_start);
                stats.feed_ns += ns;
                stats.max_feed_ns = @max(stats.max_feed_ns, ns);
                stats.feeds += 1;
            },
        };
    }

    stats.matches = s.matchesLen();
    stats.total_ns = elapsed(start);
    return stats;
}

fn now() std.Io.Timestamp {
    return .now(global.io(), .awake);
}

fn elapsed(start: std.Io.Timestamp) u64 {
    return @intCast(start.durationTo(now()).nanoseconds);
}

fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScrollbackSearch = @ptrCast(@alignCast(ptr));
    std.mem.doNotOptimizeAway(&self.terminal);
}

fn stepTyping(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScrollbackSearch = @ptrCast(@alignCast(ptr));
    for (1..self.opts.needle.len + 1) |len| {
        var s = ScreenSearch.init(
            self.alloc,
            self.screen(),
            self.opts.needle[0..len],
        ) catch return error.BenchmarkFailed;
        defer s.deinit();
        s.searchAll() catch return error.BenchmarkFailed;
        std.mem.doNotOptimizeAway(s.matchesLen());
    }
}

fn stepReport(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScrollbackSearch = @ptrCast(@alignCast(ptr));
    for (1..self.opts.needle.len + 1) |len| {
        const needle = self.opts.needle[0..len];
        const stats = self.search(needle) catch return error.BenchmarkFailed;
        std.debug.print(
            "scrollback-search needle=\"{s}\" matches={d} total_us={d} " ++
                "feed_us={d} feeds={d} max_feed_us={d}\n",
            .{
                needle,
                stats.matches,
                stats.total_ns / std.time.ns_per_us,
                stats.feed_ns / std.time.ns_per_us,
                stats.feeds,
                stats.max_feed_ns / std.time.ns_per_us,
            },
        );
    }
}

test ScrollbackSearch {
    const testing = std.testing;
    const impl: *ScrollbackSearch = try .create(testing.allocator, .{});
    defer impl.destroy(testing.allocator);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}

test "ScrollbackSearch finds matches in scrollback" {
    const testing = std.testing;
    const impl: *ScrollbackSearch = try .create(testing.allocator, .{
        .@"terminal-rows" = 4,
        .@"terminal-cols" = 40,
        .@"max-scrollback" = 1_000_000,
    });
    defer impl.destroy(testing.allocator);

    var stream = impl.terminal.vtStream();
    defer stream.deinit();
    for (0..1000) |_| stream.nextSlice("an error here\r\n");

    const stats = try impl.search("error");
    try testing.expectEqual(1000, stats.matches);
    try testing.expect(stats.feeds > 0);
}
