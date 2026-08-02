//! This benchmark measures the throughput of bidi resolution over a
//! corpus, one line at a time.
//!
//! The number that matters most here is the `ascii` corpus. Bidi support
//! must not measurably slow down plain left-to-right output, which is the
//! overwhelming majority of what a terminal renders, so the `resolve` mode
//! on an ASCII corpus is the regression gate for the whole feature. The
//! `decode` mode isolates the UTF-8 decoding cost so the resolver's own
//! contribution can be read off the difference rather than guessed at.
//!
//! Generate corpora with `ghostty-gen bidi --profile=<profile> --seed=<n>`
//! and reuse the exact same file across revisions. See
//! `src/benchmark/AGENTS.md`.
const BidiResolve = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const bidi = @import("../bidi/main.zig");
const UTF8Decoder = @import("../terminal/UTF8Decoder.zig");
const global = @import("../global.zig");

const log = std.log.scoped(.@"bidi-resolve-bench");

/// The maximum corpus size we will read into memory.
const max_corpus_size = 1 * 1024 * 1024 * 1024;

opts: Options,

/// The allocator used for the resolver and line buffer.
alloc: Allocator,

/// The corpus, read fully into memory during setup.
///
/// This is read up front rather than streamed per step so that a step can
/// be run repeatedly, which `--duration` requires: a step that consumed a
/// file handle would read nothing after its first invocation and report an
/// enormous iteration count. It also keeps file I/O out of the measurement.
data: []const u8 = &.{},

/// The resolver under test. Created in setup so its buffers are warm for
/// the whole run rather than being reallocated per step.
resolver: bidi.Resolver = .empty,

/// Codepoints of the line currently being accumulated.
line: std.ArrayList(u21) = .empty,

pub const Options = struct {
    /// The type of work to perform.
    mode: Mode = .decode,

    /// The data to read as a filepath. If this is "-" then we will read
    /// stdin. If this is unset, then we will do nothing (benchmark is a
    /// noop).
    data: ?[]const u8 = null,
};

pub const Mode = enum {
    /// Decode UTF-8 and split into lines, but resolve nothing. This is
    /// the baseline: subtract it from `resolve` to get the resolver cost.
    decode,

    /// Decode and run each line through the bidi resolver.
    resolve,
};

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*BidiResolve {
    const ptr = try alloc.create(BidiResolve);
    errdefer alloc.destroy(ptr);
    ptr.* = .{ .opts = opts, .alloc = alloc };
    return ptr;
}

pub fn destroy(self: *BidiResolve, alloc: Allocator) void {
    alloc.destroy(self);
}

pub fn benchmark(self: *BidiResolve) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .decode => stepDecode,
            .resolve => stepResolve,
        },
        .setupFn = setup,
        .teardownFn = teardown,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *BidiResolve = @ptrCast(@alignCast(ptr));

    assert(self.data.len == 0);
    const f = options.dataFile(self.opts.data) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    } orelse return;
    defer f.close(global.io());

    var read_buf: [4096]u8 = undefined;
    var f_reader = f.reader(global.io(), &read_buf);
    self.data = f_reader.interface.allocRemaining(
        self.alloc,
        .limited(max_corpus_size),
    ) catch |err| {
        log.warn("error reading data file err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn teardown(ptr: *anyopaque) void {
    const self: *BidiResolve = @ptrCast(@alignCast(ptr));
    if (self.data.len > 0) {
        self.alloc.free(self.data);
        self.data = &.{};
    }
    self.line.deinit(self.alloc);
    self.line = .empty;
    self.resolver.deinit(self.alloc);
    self.resolver = .empty;
}

fn stepDecode(ptr: *anyopaque) Benchmark.Error!void {
    const self: *BidiResolve = @ptrCast(@alignCast(ptr));
    try self.run(false);
}

fn stepResolve(ptr: *anyopaque) Benchmark.Error!void {
    const self: *BidiResolve = @ptrCast(@alignCast(ptr));
    try self.run(true);
}

fn run(self: *BidiResolve, comptime do_resolve: bool) Benchmark.Error!void {
    self.line.clearRetainingCapacity();

    var d: UTF8Decoder = .{};
    for (self.data) |c| {
        const cp_, const consumed = d.next(c);
        assert(consumed);
        const cp = cp_ orelse continue;

        if (cp != '\n') {
            // Rows are bounded by the terminal width in practice; the
            // resolver's index type is a u16 so we cap defensively.
            if (self.line.items.len < std.math.maxInt(u16)) {
                self.line.append(self.alloc, cp) catch {
                    log.warn("out of memory buffering line", .{});
                    return error.BenchmarkFailed;
                };
            }
            continue;
        }

        try self.flush(do_resolve);
    }

    // Trailing line without a newline.
    try self.flush(do_resolve);
}

fn flush(self: *BidiResolve, comptime do_resolve: bool) Benchmark.Error!void {
    if (self.line.items.len == 0) return;

    if (do_resolve) {
        const result = self.resolver.resolve(
            self.alloc,
            self.line.items,
            .{},
        ) catch {
            log.warn("out of memory resolving line", .{});
            return error.BenchmarkFailed;
        };

        // Consume the result so the resolve can't be optimized away.
        std.mem.doNotOptimizeAway(result.identity);
        std.mem.doNotOptimizeAway(result.runs.len);
    } else {
        std.mem.doNotOptimizeAway(self.line.items.len);
    }

    self.line.clearRetainingCapacity();
}

test BidiResolve {
    const testing = std.testing;
    const alloc = testing.allocator;

    inline for (&.{ Mode.decode, Mode.resolve }) |mode| {
        const impl: *BidiResolve = try .create(alloc, .{ .mode = mode });
        defer impl.destroy(alloc);

        const bench = impl.benchmark();
        _ = try bench.run(.once);
    }
}
