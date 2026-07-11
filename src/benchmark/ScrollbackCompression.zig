//! Benchmarks cold-history compression and restoration on pages owned by a
//! live terminal.
//!
//! Unlike `page-compression`, which measures the standalone codec against raw
//! byte chunks, this benchmark first parses a VT corpus into a real `Terminal`.
//! Its timed operations therefore include the PageList state transition,
//! exact-sized encoded allocation, retained-mapping reclamation, and transparent
//! restoration through `PageList.Node.page`.
//!
//! ## Input
//!
//! `--data` names a pre-generated VT byte stream. Parsing happens during setup
//! and is not part of the benchmark's timed region. Use the same saved corpus,
//! terminal dimensions, and scrollback limit when comparing revisions. In
//! particular, do not pipe a generator into this benchmark: generation and
//! pipe scheduling add noise which can overwhelm the operation being measured.
//!
//! The benchmark always operates on the primary screen's PageList. This keeps
//! the result focused on scrollback even if malformed or incomplete input
//! leaves the terminal in its alternate screen at end of file. `--max-scrollback`
//! is expressed in bytes and defaults to 10 MB.
//!
//! ## Modes
//!
//! * `noop` parses the corpus but performs no timed PageList operation. This is
//!   the common process and setup baseline for the other modes.
//! * `compress` times one complete `compress` invocation.
//! * `incremental` reaches the same final representation through
//!   `compress(.drain)`. It drains the candidate-bounded steps and final
//!   no-work verification pass in the timed region, making cursor and repeated
//!   traversal overhead directly comparable with `compress`.
//! * `restore` compresses cold history during setup, outside the timed region,
//!   then visits every fully historical node through `Node.page`. That public
//!   content-access boundary transparently restores compressed nodes.
//! * `report` performs one compression pass and prints compressed page count,
//!   encoded ratio, and estimated resident-byte savings. It is intended for
//!   inspecting a corpus rather than timing comparisons.
//!
//! A fully historical page is a node strictly before the node containing the
//! top of the active area. The boundary node is deliberately excluded because
//! it can contain both history and active rows. Pages intersecting the current
//! viewport are also excluded so visible contents remain resident. Normal
//! terminal execution compresses eligible pages incrementally after activity
//! becomes idle. The benchmark invokes PageList operations directly so its
//! timed regions exclude the production scheduler's idle delay and
//! renderer-thread coordination.
//!
//! ## Examples
//!
//! Build the benchmark in ReleaseFast mode:
//!
//!     zig build -Demit-bench -Doptimize=ReleaseFast -Demit-macos-app=false
//!
//! Inspect the memory reduction for a saved VT corpus:
//!
//!     ghostty-bench +scrollback-compression --mode=report \
//!       --data=/tmp/scrollback.vt --terminal-cols=120 --terminal-rows=80
//!
//! Compare PageList compression and restoration cost. Setup still contributes
//! to full process time, so use a sufficiently large corpus and compare against
//! `noop` with identical arguments:
//!
//!     hyperfine --warmup 3 \
//!       'ghostty-bench +scrollback-compression --mode=noop --data=/tmp/scrollback.vt' \
//!       'ghostty-bench +scrollback-compression --mode=compress --data=/tmp/scrollback.vt' \
//!       'ghostty-bench +scrollback-compression --mode=incremental --data=/tmp/scrollback.vt' \
//!       'ghostty-bench +scrollback-compression --mode=restore --data=/tmp/scrollback.vt'
const ScrollbackCompression = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const PageList = terminalpkg.PageList;
const Terminal = terminalpkg.Terminal;

const log = std.log.scoped(.@"scrollback-compression-bench");

opts: Options,
terminal: Terminal,

pub const Options = struct {
    /// Set by the shared CLI parser so the `data` string remains valid for the
    /// lifetime of the benchmark implementation.
    _arena: ?std.heap.ArenaAllocator = null,

    /// Select the PageList operation performed inside the timed benchmark.
    mode: Mode = .compress,

    /// Dimensions used to construct the terminal which consumes the corpus.
    /// These affect wrapping and therefore the number and contents of pages.
    @"terminal-rows": u16 = 80,
    @"terminal-cols": u16 = 120,

    /// Maximum primary-screen scrollback allocation in bytes. PageList rounds
    /// this as required by its page allocation policy.
    @"max-scrollback": usize = 10_000_000,

    /// Pre-generated VT corpus. `-` reads stdin, although a regular file is
    /// strongly recommended so comparisons can reuse identical input bytes.
    /// When unset, every mode operates on the initial empty terminal.
    data: ?[]const u8 = null,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};

pub const Mode = enum {
    /// Establish process and setup overhead without a PageList operation.
    noop,

    /// Compress every eligible fully historical page once.
    compress,

    /// Compress every eligible page through bounded resumable steps.
    incremental,

    /// Restore pages compressed outside the timed region.
    restore,

    /// Compress once and print aggregate memory statistics.
    report,
};

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*ScrollbackCompression {
    const ptr = try alloc.create(ScrollbackCompression);
    errdefer alloc.destroy(ptr);

    ptr.* = .{
        .opts = opts,
        .terminal = try .init(alloc, .{
            .rows = opts.@"terminal-rows",
            .cols = opts.@"terminal-cols",
            .max_scrollback = opts.@"max-scrollback",
        }),
    };
    return ptr;
}

pub fn destroy(self: *ScrollbackCompression, alloc: Allocator) void {
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}

pub fn benchmark(self: *ScrollbackCompression) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .compress => stepCompress,
            .incremental => stepIncremental,
            .restore => stepRestore,
            .report => stepReport,
        },
        .setupFn = setup,
    });
}

/// Reset the terminal and consume the complete VT corpus before timing starts.
/// Restore mode also prepares its compressed representation here so its timed
/// step contains decoding and mapping writes, but not encoding.
fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScrollbackCompression = @ptrCast(@alignCast(ptr));
    self.terminal.fullReset();

    self.loadCorpus() catch |err| {
        log.warn("failed to prepare scrollback compression benchmark err={}", .{err});
        return error.BenchmarkFailed;
    };

    if (self.opts.mode == .restore) {
        _ = self.pages().compress(.full);
    }
}

/// Feed the corpus in the same 64 KiB chunks used by the real IO thread and
/// terminal-stream benchmark. Parser and file IO costs remain in setup.
fn loadCorpus(self: *ScrollbackCompression) !void {
    const data_file = try options.dataFile(self.opts.data) orelse return;
    defer data_file.close();

    var stream = self.terminal.vtStream();
    defer stream.deinit();

    var read_buf: [64 * 1024]u8 align(std.atomic.cache_line) = undefined;
    var file_reader = data_file.reader(&read_buf);
    const reader = &file_reader.interface;

    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&buf) catch
            return file_reader.err orelse error.ReadFailed;
        if (n == 0) return;
        stream.nextSlice(buf[0..n]);
    }
}

/// Return the primary screen because it is the terminal screen which owns
/// scrollback. A corpus ending in the alternate screen must not turn this into
/// an alternate-screen allocation benchmark.
fn pages(self: *ScrollbackCompression) *PageList {
    return &self.terminal.screens.get(.primary).?.pages;
}

fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScrollbackCompression = @ptrCast(@alignCast(ptr));
    std.mem.doNotOptimizeAway(&self.terminal);
}

fn stepCompress(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScrollbackCompression = @ptrCast(@alignCast(ptr));
    _ = self.pages().compress(.full);
    std.mem.doNotOptimizeAway(&self.terminal);
}

fn stepIncremental(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScrollbackCompression = @ptrCast(@alignCast(ptr));
    _ = self.pages().compress(.drain);
    std.mem.doNotOptimizeAway(&self.terminal);
}

fn stepRestore(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScrollbackCompression = @ptrCast(@alignCast(ptr));
    std.mem.doNotOptimizeAway(self.visitColdPages());
}

/// Visit all nodes which were eligible for the setup compression pass.
///
/// `page` is intentionally used instead of inspecting the union payload so the
/// benchmark follows the same transparent restoration boundary as consumers.
/// Compressible nodes restore here; resident candidates which failed the
/// opportunistic pass are harmlessly visited through the same boundary.
fn visitColdPages(self: *ScrollbackCompression) usize {
    const page_list = self.pages();
    const active_node = page_list.getTopLeft(.active).node;
    var visited: usize = 0;
    var node_ = page_list.pages.first;
    while (node_) |node| : (node_ = node.next) {
        if (node == active_node) break;
        std.mem.doNotOptimizeAway(node.page());
        visited += 1;
    }
    return visited;
}

fn stepReport(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScrollbackCompression = @ptrCast(@alignCast(ptr));
    _ = self.pages().compress(.full);
    const memory = self.pages().memoryStats();

    std.debug.print(
        "scrollback-compression compressed={d} raw={d} " ++
            "encoded={d} ratio={d:.2}% savings={d}\n",
        .{
            memory.compressed_pages,
            memory.decommitted_raw_bytes,
            memory.encoded_bytes,
            percentage(
                memory.encoded_bytes,
                memory.decommitted_raw_bytes,
            ),
            memory.estimatedSavings(),
        },
    );
}

fn percentage(part: usize, whole: usize) f64 {
    if (whole == 0) return 0;
    return @as(f64, @floatFromInt(part)) * 100 /
        @as(f64, @floatFromInt(whole));
}

test ScrollbackCompression {
    const testing = std.testing;
    const impl: *ScrollbackCompression = try .create(testing.allocator, .{});
    defer impl.destroy(testing.allocator);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}

test "ScrollbackCompression restores cold terminal pages" {
    const testing = std.testing;
    const impl: *ScrollbackCompression = try .create(testing.allocator, .{
        .mode = .restore,
        .@"terminal-rows" = 4,
        // Standard-width pages hold 215 rows. Keeping that row capacity here
        // makes this test corpus small while still producing cold history.
        .@"terminal-cols" = 215,
        .@"max-scrollback" = 1_000_000,
    });
    defer impl.destroy(testing.allocator);

    var stream = impl.terminal.vtStream();
    defer stream.deinit();
    for (0..256) |_| stream.nextSlice("aaaa\r\n");

    _ = impl.pages().compress(.full);
    const compressed = impl.pages().memoryStats();
    try testing.expect(compressed.compressed_pages > 0);
    try testing.expect(impl.visitColdPages() >= compressed.compressed_pages);

    // Restored historical pages are resident and therefore eligible for a
    // later explicit pass. This also verifies that the benchmark traversal
    // went through Node.page rather than merely inspecting page metadata.
    _ = impl.pages().compress(.full);
    const recompressed = impl.pages().memoryStats();
    try testing.expectEqual(
        compressed.compressed_pages,
        recompressed.compressed_pages,
    );
}

test "ScrollbackCompression drains incremental compression steps" {
    const testing = std.testing;
    const impl: *ScrollbackCompression = try .create(testing.allocator, .{
        .mode = .incremental,
        .@"terminal-rows" = 4,
        .@"terminal-cols" = 215,
        .@"max-scrollback" = 1_000_000,
    });
    defer impl.destroy(testing.allocator);

    var stream = impl.terminal.vtStream();
    defer stream.deinit();
    for (0..256) |_| stream.nextSlice("aaaa\r\n");

    _ = impl.pages().compress(.drain);
    const incremental = impl.pages().memoryStats();
    try testing.expect(incremental.compressed_pages > 0);

    // Restore the same pages and compare against the monolithic operation.
    // Both paths should produce the same final storage representation.
    _ = impl.visitColdPages();
    _ = impl.pages().compress(.full);
    const monolithic = impl.pages().memoryStats();
    try testing.expectEqual(monolithic, incremental);
}
