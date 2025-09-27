//! Benchmark core terminal search throughput by scanning a synthetic
//! scrollback with a configurable match density.
const TerminalSearch = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const terminalpkg = @import("../terminal/main.zig");
const Screen = terminalpkg.Screen;
const PageListSearch = @import("../terminal/search.zig").PageListSearch;

const log = std.log.scoped(.@"terminal-search-bench");

opts: Options,
alloc: Allocator,
screen: Screen,
needle: []const u8,
generated_bytes: usize,
bytes_scanned: usize = 0,
iterations: usize = 0,

row_buf: []u8,

pub const Options = struct {
    /// Active rows for the terminal.
    rows: u16 = 24,

    /// Active cols for the terminal.
    cols: u16 = 80,

    /// Optional benchmark duration; if null the benchmark runs exactly once.
    @"duration-ns": ?u64 = null,

    /// How many pages of scrollback to synthesize. Each page is roughly
    /// `rows` rows.
    @"history-pages": usize = 256,

    /// Number of matches per page. Zero means no matches are inserted.
    @"hits-per-page": usize = 1,

    /// The needle to search for.
    needle: []const u8 = "ghost",

    /// Seed for deterministic data generation.
    seed: u64 = 0x41c6_6e57_f00d_beef,

    /// When true, emit throughput information after the benchmark runs.
    report: bool = false,
};

pub fn create(alloc: Allocator, opts: Options) !*TerminalSearch {
    if (opts.needle.len == 0) return error.EmptyNeedle;

    const ptr = try alloc.create(TerminalSearch);
    errdefer alloc.destroy(ptr);

    var screen = try Screen.init(alloc, opts.cols, opts.rows, opts.@"history-pages" * opts.rows);
    errdefer screen.deinit();

    const buf = try alloc.alloc(u8, opts.cols + 1);
    errdefer alloc.free(buf);

    ptr.* = .{
        .opts = opts,
        .alloc = alloc,
        .screen = screen,
        .needle = opts.needle,
        .generated_bytes = 0,
        .row_buf = buf,
    };

    try ptr.populate();

    return ptr;
}

pub fn destroy(self: *TerminalSearch, alloc: Allocator) void {
    alloc.free(self.row_buf);
    self.screen.deinit();
    alloc.destroy(self);
}

pub fn benchmark(self: *TerminalSearch) Benchmark {
    return .init(self, .{ .stepFn = step, .setupFn = setup });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalSearch = @ptrCast(@alignCast(ptr));
    self.bytes_scanned = 0;
    self.iterations = 0;
}

fn step(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalSearch = @ptrCast(@alignCast(ptr));

    var search = PageListSearch.init(self.alloc, &self.screen.pages, self.needle) catch |err| {
        log.err("init failed err={}", .{err});
        return error.BenchmarkFailed;
    };
    defer search.deinit(self.alloc);

    while (true) {
        const result = search.next(self.alloc) catch |err| {
            log.err("next failed err={}", .{err});
            return error.BenchmarkFailed;
        };
        if (result == null) break;
    }

    self.bytes_scanned += self.generated_bytes;
    self.iterations += 1;
}

fn populate(self: *TerminalSearch) !void {
    var prng = std.Random.DefaultPrng.init(self.opts.seed);
    const rand = prng.random();

    const rows_per_page: usize = self.opts.rows;
    const total_rows = self.opts.@"history-pages" * rows_per_page;

    const cols = self.opts.cols;

    const hits_per_page = self.opts.@"hits-per-page";
    const needle = self.needle;

    var rows_written: usize = 0;
    var hits_in_current_page: usize = 0;
    const hit_spacing = if (hits_per_page == 0)
        0
    else
        @max(1, (rows_per_page + hits_per_page - 1) / hits_per_page);
    var next_hit_row_in_page: ?usize = if (hits_per_page == 0)
        null
    else
        @min(hit_spacing - 1, rows_per_page - 1);

    while (rows_written < total_rows) : (rows_written += 1) {
        const row_in_page = rows_written % rows_per_page;

        // Reset the per-page counter when we cross a page boundary.
        if (row_in_page == 0) {
            hits_in_current_page = 0;
            next_hit_row_in_page = if (hits_per_page == 0)
                null
            else
                @min(hit_spacing - 1, rows_per_page - 1);
        }

        var row_slice = self.row_buf[0..cols];
        for (row_slice) |*ch| {
            ch.* = randomPrintable(&rand);
        }

        if (hits_per_page != 0 and
            hits_in_current_page < hits_per_page and
            needle.len <= cols)
        {
            if (next_hit_row_in_page) |target_row| {
                if (row_in_page >= target_row) {
                const max_start = cols - needle.len;
                const start_col = rand.intRangeAtMost(usize, 0, max_start);
                @memcpy(
                    row_slice[start_col .. start_col + needle.len],
                    needle,
                );
                hits_in_current_page += 1;

                next_hit_row_in_page = if (hits_in_current_page < hits_per_page) blk: {
                    const next_row = row_in_page + hit_spacing;
                    break :blk @min(next_row, rows_per_page - 1);
                } else null;
                }
            }
        }

        self.row_buf[cols] = '\n';

        self.screen.testWriteString(self.row_buf[0 .. cols + 1]) catch |err| {
            log.err("failed to write synthetic row err={}", .{err});
            return err;
        };

        self.generated_bytes += cols + 1;
    }
}

fn randomPrintable(rand: anytype) u8 {
    // Use ASCII letters/numbers to keep data simple.
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    return alphabet[rand.intRangeLessThan(usize, 0, alphabet.len)];
}

pub fn report(self: *TerminalSearch, result: Benchmark.RunResult) void {
    const total_bytes = self.bytes_scanned;
    const seconds = if (result.duration == 0)
        0.0
    else
        @as(f64, @floatFromInt(result.duration)) / 1_000_000_000.0;
    const megabytes = @as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0);
    const mbps = if (seconds == 0) 0.0 else megabytes / seconds;

    std.debug.print(
        "iterations={d} bytes={d} duration={d}ns (~{d:.3}s) throughput={d:.2} MB/s\n",
        .{ result.iterations, total_bytes, result.duration, seconds, mbps },
    );
}

pub const Error = error{EmptyNeedle};

comptime {
    std.testing.refAllDecls(@This());
}

test "TerminalSearch benchmark init" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var bench = try TerminalSearch.create(alloc, .{});
    defer bench.destroy(alloc);

    const b = bench.benchmark();
    _ = try b.run(.once);
}
