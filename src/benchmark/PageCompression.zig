//! Benchmarks raw LZ4 compression and decompression on page-sized byte
//! buffers.
//!
//! This benchmark is intentionally independent of terminal page ownership and
//! lifecycle. It treats its input as opaque bytes and calls only the standalone
//! LZ4 block codec. In particular, it does not compress pages owned by a live
//! terminal or measure the scheduling and state transitions used by automatic
//! scrollback compression.
//!
//! ## Input
//!
//! `--data` names a pre-generated raw byte corpus. The corpus is divided into
//! `--page-size` byte chunks, with a final short chunk retained when the file
//! size is not an exact multiple. The default page size is 400 KiB, matching a
//! standard terminal page in ReleaseFast builds on the current target.
//!
//! A raw dump of actual page backing memory is the most representative input:
//! it includes cells, rows, styles, graphemes, hyperlinks, allocator metadata,
//! and unused capacity exactly as the codec would see them. Keep such corpora
//! outside the repository and reuse the same file when comparing branches.
//! Arbitrary files are accepted too, but their compression ratios should not be
//! interpreted as terminal scrollback ratios.
//!
//! ## Modes
//!
//! * `noop` walks the input chunks without invoking the codec. This measures the
//!   benchmark loop's minimum overhead.
//! * `compress` compresses every input chunk into a reusable output buffer.
//! * `store` additionally copies each useful result into an exact-sized
//!   allocation. It retains the most recent `--retained-pages` blocks so that
//!   allocation, eviction, and allocator reuse resemble bounded scrollback.
//! * `decompress` prepares compressed blocks during setup, then decompresses
//!   every block into a reusable output buffer.
//! * `report` compresses each chunk once and prints raw and encoded sizes. It is
//!   for inspecting ratios, not timing comparisons.
//!
//! Dataset loading, output allocation, and preparation of blocks for
//! decompression happen in `setup` and are outside `Benchmark`'s timed region.
//! The `compress` and `decompress` steps perform no allocation. `store`
//! deliberately performs encoded-block allocations and frees inside the timed
//! step; only its reusable workspace and ring metadata are prepared in setup.
//! `hyperfine` still measures full process lifetime, so use `--loops` to
//! amortize setup and teardown when comparing small corpora.
//!
//! ## Examples
//!
//! Build benchmarks in ReleaseFast mode:
//!
//!     zig build -Demit-bench -Doptimize=ReleaseFast -Demit-macos-app=false
//!
//! Inspect the compression ratio of a page corpus:
//!
//!     ghostty-bench +page-compression --mode=report --data=/tmp/pages.raw
//!
//! Measure the cost of exact encoded storage relative to the codec alone:
//!
//!     hyperfine --warmup 3 \
//!       'ghostty-bench +page-compression --mode=compress --loops=100 --data=/tmp/pages.raw' \
//!       'ghostty-bench +page-compression --mode=store --loops=100 --data=/tmp/pages.raw'
const PageCompression = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const compress = @import("../terminal/compress.zig");
const CompressedPage = compress.Page;
const lz4 = compress.lz4;
const compat_file = @import("../lib/compat/file.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.@"page-compression-bench");

/// Prevent a malformed or accidentally enormous corpus from consuming
/// unbounded memory during benchmark setup.
const max_data_size = 64 * 1024 * 1024;

alloc: Allocator,
opts: Options,

/// Complete contents of the input corpus. Individual pages are slices into
/// this allocation, so it remains alive until teardown.
data: []u8 = &.{},

/// Compressed blocks prepared during setup for `decompress` mode.
encoded: std.ArrayList(Encoded) = .empty,

/// Exact encoded allocations retained by `store` mode. Null entries have not
/// been reached yet; once full, `stored_next` identifies the oldest block.
stored: []?[]u8 = &.{},
stored_next: usize = 0,

/// Reused by compression and report modes. Its length is the compression
/// bound of the largest input chunk.
compression_output: []u8 = &.{},

/// Reused by decompression mode. Its length is at least one input chunk.
decompression_output: []u8 = &.{},

/// Fixed 16 KiB scratch table required by the compressor.
table: lz4.HashTable = undefined,

pub const Options = struct {
    /// Set by the shared CLI parser for string option ownership.
    _arena: ?std.heap.ArenaAllocator = null,

    /// Select the operation performed inside the timed benchmark step.
    mode: Mode = .compress,

    /// Repeat the complete corpus this many times per benchmark step. Increase
    /// this when the corpus is too small for stable `hyperfine` measurements.
    loops: u32 = 1,

    /// Number of bytes treated as one independent LZ4 block. Real page dumps
    /// should use the exact backing-memory size of the pages being measured.
    @"page-size": usize = 400 * 1024,

    /// Number of exact encoded allocations retained by `store` mode before
    /// the oldest allocation is freed and replaced. The default approximates
    /// a 10 MB scrollback composed of standard 400 KiB terminal pages.
    @"retained-pages": usize = 25,

    /// Pre-generated input corpus. `-` reads stdin, although a regular file is
    /// recommended so identical bytes can be reused across benchmark runs.
    /// When unset, all modes are no-ops.
    data: ?[]const u8 = null,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};

pub const Mode = enum {
    /// Walk page boundaries and establish the benchmark loop overhead.
    noop,

    /// Compress each raw page into a reusable compression-bound buffer.
    compress,

    /// Compress and retain exact-sized encoded blocks in a bounded ring.
    store,

    /// Decompress blocks prepared before the timed region.
    decompress,

    /// Print per-page and aggregate encoded sizes. Not a timing benchmark.
    report,
};

const Encoded = struct {
    /// Exact compressed block bytes.
    bytes: []u8,

    /// Exact output length expected by the raw block decoder.
    raw_len: usize,
};

/// Allocate benchmark state. Input data is intentionally loaded later by
/// `setup` so construction is cheap and follows the other benchmarks.
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*PageCompression {
    const ptr = try alloc.create(PageCompression);
    ptr.* = .{
        .alloc = alloc,
        .opts = opts,
    };
    return ptr;
}

/// Release allocations retained across benchmark steps.
pub fn destroy(self: *PageCompression, alloc: Allocator) void {
    self.clearPreparedData();
    alloc.destroy(self);
}

/// Select one operation for the benchmark harness to time.
pub fn benchmark(self: *PageCompression) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .compress => stepCompress,
            .store => stepStore,
            .decompress => stepDecompress,
            .report => stepReport,
        },
        .setupFn = setup,
        .teardownFn = teardown,
    });
}

/// Load and partition the input corpus. For decompression mode this also
/// creates the encoded blocks, keeping compression outside the timed region.
fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *PageCompression = @ptrCast(@alignCast(ptr));
    assert(self.data.len == 0);
    assert(self.encoded.items.len == 0);

    self.setupData() catch |err| {
        log.warn("failed to prepare page compression benchmark err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn setupData(self: *PageCompression) !void {
    if (self.opts.loops == 0) return error.InvalidLoops;
    if (self.opts.@"page-size" == 0) return error.InvalidPageSize;
    if (self.opts.mode == .store and self.opts.@"retained-pages" == 0)
        return error.InvalidRetainedPages;

    const data_file = try options.dataFile(self.opts.data) orelse return;
    defer data_file.close(global.io());

    self.data = try compat_file.readToEndAlloc(data_file, self.alloc, max_data_size);
    errdefer {
        self.alloc.free(self.data);
        self.data = &.{};
    }
    if (self.data.len == 0) return;
    if (self.opts.mode == .noop) return;

    const largest_page = @min(self.opts.@"page-size", self.data.len);
    self.compression_output = try self.alloc.alloc(
        u8,
        try lz4.compressBound(largest_page),
    );
    errdefer {
        self.alloc.free(self.compression_output);
        self.compression_output = &.{};
    }

    if (self.opts.mode == .store) try self.prepareStored();
    if (self.opts.mode == .decompress) try self.prepareEncoded();
}

/// Allocate only the ring metadata for `store` mode. The encoded blocks which
/// populate it are intentionally allocated by the timed benchmark step.
fn prepareStored(self: *PageCompression) !void {
    self.stored = try self.alloc.alloc(?[]u8, self.opts.@"retained-pages");
    @memset(self.stored, null);
    self.stored_next = 0;
}

/// Precompress every input page and verify one decode before benchmarking.
/// This catches corpus or codec problems before the timer starts.
fn prepareEncoded(self: *PageCompression) !void {
    self.decompression_output = try self.alloc.alloc(
        u8,
        @min(self.opts.@"page-size", self.data.len),
    );
    errdefer {
        self.alloc.free(self.decompression_output);
        self.decompression_output = &.{};
    }

    var it = self.pages();
    while (it.next()) |page| {
        const encoded_len = try lz4.compress(
            page,
            self.compression_output,
            &self.table,
        );
        const encoded = try self.alloc.dupe(
            u8,
            self.compression_output[0..encoded_len],
        );
        self.encoded.append(self.alloc, .{
            .bytes = encoded,
            .raw_len = page.len,
        }) catch |err| {
            self.alloc.free(encoded);
            return err;
        };
    }

    var page_it = self.pages();
    for (self.encoded.items) |block| {
        const page = page_it.next().?;
        const output = self.decompression_output[0..block.raw_len];
        _ = try lz4.decompress(block.bytes, output);
        if (!std.mem.eql(u8, page, output)) return error.RoundTripMismatch;
    }
}

/// Release everything created by setup. This is shared by teardown and
/// destroy so errors and direct unit-test use remain leak-free.
fn clearPreparedData(self: *PageCompression) void {
    for (self.encoded.items) |block| self.alloc.free(block.bytes);
    self.encoded.deinit(self.alloc);
    self.encoded = .empty;

    for (self.stored) |block| if (block) |bytes| self.alloc.free(bytes);
    if (self.stored.len > 0) self.alloc.free(self.stored);
    self.stored = &.{};
    self.stored_next = 0;

    if (self.compression_output.len > 0)
        self.alloc.free(self.compression_output);
    self.compression_output = &.{};

    if (self.decompression_output.len > 0)
        self.alloc.free(self.decompression_output);
    self.decompression_output = &.{};

    if (self.data.len > 0) self.alloc.free(self.data);
    self.data = &.{};
}

fn teardown(ptr: *anyopaque) void {
    const self: *PageCompression = @ptrCast(@alignCast(ptr));
    self.clearPreparedData();
}

/// Baseline mode: traverse exactly the same page boundaries as compression
/// without invoking the codec.
fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    const self: *PageCompression = @ptrCast(@alignCast(ptr));
    for (0..self.opts.loops) |_| {
        var it = self.pages();
        while (it.next()) |page| std.mem.doNotOptimizeAway(page);
    }
}

/// Compress all pages into one reusable output buffer. Only the returned
/// encoded length is consumed because retaining output pages would measure
/// allocation and ownership rather than codec throughput.
fn stepCompress(ptr: *anyopaque) Benchmark.Error!void {
    const self: *PageCompression = @ptrCast(@alignCast(ptr));
    for (0..self.opts.loops) |_| {
        var it = self.pages();
        while (it.next()) |page| {
            const encoded_len = lz4.compress(
                page,
                self.compression_output,
                &self.table,
            ) catch |err| {
                log.warn("page compression failed err={}", .{err});
                return error.BenchmarkFailed;
            };
            std.mem.doNotOptimizeAway(encoded_len);
        }
    }
}

/// Compress pages and retain their exact encoded allocations in a bounded
/// ring. This models the part of `compress.Page.init` which differs from the
/// allocation-free codec benchmark: copying the result, allocating its
/// persistent storage, and freeing an old block when scrollback is full.
fn stepStore(ptr: *anyopaque) Benchmark.Error!void {
    const self: *PageCompression = @ptrCast(@alignCast(ptr));
    if (self.data.len == 0) return;
    assert(self.stored.len > 0);

    for (0..self.opts.loops) |_| {
        var it = self.pages();
        while (it.next()) |page| {
            const output_len = CompressedPage.requiredScratch(page.len) catch |err| {
                log.warn("failed to size stored page output err={}", .{err});
                return error.BenchmarkFailed;
            };
            if (output_len == 0) continue;

            const encoded_len = lz4.compress(
                page,
                self.compression_output[0..output_len],
                &self.table,
            ) catch |err| switch (err) {
                // This is the same profitability outcome as
                // compress.Page.init: a block which exceeds the useful output
                // limit remains resident and consumes no encoded allocation.
                error.OutputTooSmall => continue,
                error.InputTooLarge => {
                    log.warn("stored page compression failed err={}", .{err});
                    return error.BenchmarkFailed;
                },
            };

            const encoded = self.alloc.dupe(
                u8,
                self.compression_output[0..encoded_len],
            ) catch |err| {
                log.warn("stored page allocation failed err={}", .{err});
                return error.BenchmarkFailed;
            };

            const slot = &self.stored[self.stored_next];
            if (slot.*) |previous| self.alloc.free(previous);
            slot.* = encoded;
            self.stored_next = (self.stored_next + 1) % self.stored.len;
            std.mem.doNotOptimizeAway(encoded);
        }
    }
}

/// Decompress blocks prepared by setup. The output allocation is reused so
/// this measures only decoding and the required memory writes.
fn stepDecompress(ptr: *anyopaque) Benchmark.Error!void {
    const self: *PageCompression = @ptrCast(@alignCast(ptr));
    for (0..self.opts.loops) |_| {
        for (self.encoded.items) |block| {
            const output = self.decompression_output[0..block.raw_len];
            _ = lz4.decompress(block.bytes, output) catch |err| {
                log.warn("page decompression failed err={}", .{err});
                return error.BenchmarkFailed;
            };
            std.mem.doNotOptimizeAway(output);
        }
    }
}

/// Print size information for evaluating compression ratio. This shares the
/// input and codec paths with compression mode but deliberately makes no
/// timing claims.
fn stepReport(ptr: *anyopaque) Benchmark.Error!void {
    const self: *PageCompression = @ptrCast(@alignCast(ptr));
    if (self.data.len == 0) return;

    var page_index: usize = 0;
    var raw_total: usize = 0;
    var encoded_total: usize = 0;
    var it = self.pages();
    while (it.next()) |page| : (page_index += 1) {
        const encoded_len = lz4.compress(
            page,
            self.compression_output,
            &self.table,
        ) catch |err| {
            log.warn("page compression report failed err={}", .{err});
            return error.BenchmarkFailed;
        };
        raw_total += page.len;
        encoded_total += encoded_len;
        std.debug.print(
            "page-compression page={d} raw={d} encoded={d} ratio={d:.2}%\n",
            .{ page_index, page.len, encoded_len, percentage(encoded_len, page.len) },
        );
    }

    std.debug.print(
        "page-compression total pages={d} raw={d} encoded={d} ratio={d:.2}% " ++
            "workspace={d} output_bound={d}\n",
        .{
            page_index,
            raw_total,
            encoded_total,
            percentage(encoded_total, raw_total),
            @sizeOf(lz4.HashTable),
            self.compression_output.len,
        },
    );
}

/// Iterate fixed-size page chunks without allocating an index table.
fn pages(self: *const PageCompression) PageIterator {
    return .{
        .data = self.data,
        .page_size = self.opts.@"page-size",
    };
}

const PageIterator = struct {
    data: []const u8,
    page_size: usize,
    offset: usize = 0,

    fn next(self: *PageIterator) ?[]const u8 {
        if (self.offset >= self.data.len) return null;
        const len = @min(self.page_size, self.data.len - self.offset);
        const end = self.offset + len;
        defer self.offset = end;
        return self.data[self.offset..end];
    }
};

fn percentage(part: usize, whole: usize) f64 {
    if (whole == 0) return 0;
    return @as(f64, @floatFromInt(part)) * 100 /
        @as(f64, @floatFromInt(whole));
}

test PageCompression {
    const testing = std.testing;
    const impl: *PageCompression = try .create(testing.allocator, .{});
    defer impl.destroy(testing.allocator);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}

test "PageCompression store retains exact encoded allocations" {
    const testing = std.testing;
    const page_size = 1024;
    const impl: *PageCompression = try .create(testing.allocator, .{
        .mode = .store,
        .@"page-size" = page_size,
        .@"retained-pages" = 2,
    });
    defer impl.destroy(testing.allocator);

    impl.data = try testing.allocator.alloc(u8, 3 * page_size);
    @memset(impl.data, 0);
    impl.compression_output = try testing.allocator.alloc(
        u8,
        try lz4.compressBound(page_size),
    );
    try impl.prepareStored();

    try stepStore(impl);
    try testing.expectEqual(@as(usize, 1), impl.stored_next);
    for (impl.stored) |block| {
        const encoded = block.?;
        try testing.expect(encoded.len < page_size);

        var decoded: [page_size]u8 = undefined;
        _ = try lz4.decompress(encoded, &decoded);
        try testing.expect(std.mem.allEqual(u8, &decoded, 0));
    }
}
