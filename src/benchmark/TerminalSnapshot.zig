//! Benchmarks the terminal binary snapshot codecs (`terminal/snapshot`).
//!
//! Encoding and decoding a snapshot are the hot paths for terminal
//! persistence and handoff, so both directions are measured against the
//! same terminal state.
//!
//! ## Input
//!
//! `--data` names a pre-generated VT byte stream (for example from
//! `ghostty-gen ascii`). The stream is fed to a terminal of the requested
//! dimensions during setup, outside the timed region. The resulting screen
//! and scrollback contents are what each step encodes or decodes.
//!
//! ## Modes
//!
//! * `noop` performs no codec work and establishes loop overhead.
//! * `encode` encodes one complete snapshot per loop into a reusable
//!   buffer. Buffer growth happens on the first iteration only.
//! * `decode` restores one complete snapshot per loop from bytes prepared
//!   during setup. The restored terminal is destroyed inside the step, so
//!   this measures the complete restore lifecycle.
//! * `decode-ready` restores only the renderable prefix per loop using the
//!   incremental decoder and stops at READY, skipping history. Compared
//!   against `decode`, this is the time-to-interactive win of applying
//!   history off the critical path.
//! * `report` encodes once and prints total and per-record-tag sizes. It
//!   is for inspecting the wire shape, not timing comparisons.
//!
//! ## Examples
//!
//! Build benchmarks in ReleaseFast mode:
//!
//!     zig build -Demit-bench -Doptimize=ReleaseFast -Demit-macos-app=false
//!
//! Generate a deterministic corpus, then measure both directions:
//!
//!     ghostty-gen ascii | head -c 1000000 > /tmp/ascii.vt
//!     hyperfine --warmup 3 \
//!       'ghostty-bench +terminal-snapshot --mode=encode --loops=20 --data=/tmp/ascii.vt' \
//!       'ghostty-bench +terminal-snapshot --mode=decode --loops=20 --data=/tmp/ascii.vt'
const TerminalSnapshot = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const snapshot = terminalpkg.snapshot;
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const Terminal = terminalpkg.Terminal;
const global = @import("../global.zig");

const log = std.log.scoped(.@"terminal-snapshot-bench");

alloc: Allocator,
opts: Options,
terminal: ?Terminal = null,

/// Reused across encode steps so buffer growth is a one-time setup cost.
encoded: std.Io.Writer.Allocating,

pub const Options = struct {
    /// Set by the shared CLI parser for string option ownership.
    _arena: ?std.heap.ArenaAllocator = null,

    /// Select the operation performed inside the timed benchmark step.
    mode: Mode = .encode,

    /// Number of codec operations per benchmark step. Increase this when
    /// the state is too small for stable `hyperfine` measurements.
    loops: u32 = 1,

    /// The size of the terminal. This affects wrapping, page sizes, and
    /// the amount of state per encoded page.
    @"terminal-rows": u16 = 24,
    @"terminal-cols": u16 = 80,

    /// Pre-generated VT stream fed to the terminal during setup. `-` reads
    /// stdin, although a regular file is recommended so identical state can
    /// be reused across runs. When unset, the terminal is empty.
    data: ?[]const u8 = null,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};

pub const Mode = enum {
    /// Establish the benchmark loop overhead.
    noop,

    /// Encode one complete snapshot per loop.
    encode,

    /// Restore one complete snapshot per loop, including its teardown.
    decode,

    /// Restore one renderable READY prefix per loop, including teardown.
    @"decode-ready",

    /// Print encoded sizes by record tag. Not a timing benchmark.
    report,
};

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*TerminalSnapshot {
    const ptr = try alloc.create(TerminalSnapshot);
    errdefer alloc.destroy(ptr);
    ptr.* = .{
        .alloc = alloc,
        .opts = opts,
        .encoded = .init(alloc),
    };
    return ptr;
}

pub fn destroy(self: *TerminalSnapshot, alloc: Allocator) void {
    if (self.terminal) |*t| t.deinit(self.alloc);
    self.encoded.deinit();
    alloc.destroy(self);
}

pub fn benchmark(self: *TerminalSnapshot) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .encode => stepEncode,
            .decode => stepDecode,
            .@"decode-ready" => stepDecodeReady,
            .report => stepReport,
        },
        .setupFn = setup,
        .teardownFn = teardown,
    });
}

/// Build the terminal state every mode shares and, for decode mode, the
/// encoded snapshot it restores. All of this is outside the timed region.
fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalSnapshot = @ptrCast(@alignCast(ptr));
    self.setupImpl() catch |err| {
        log.warn("failed to prepare snapshot benchmark err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn setupImpl(self: *TerminalSnapshot) !void {
    if (self.terminal) |*t| t.deinit(self.alloc);
    self.terminal = null;
    self.terminal = try Terminal.init(global.io(), self.alloc, .{
        .cols = self.opts.@"terminal-cols",
        .rows = self.opts.@"terminal-rows",
        .max_scrollback_bytes = null,
        .max_scrollback_lines = null,
    });
    const terminal = &self.terminal.?;

    // Feed the input corpus through the standard VT stream.
    if (try options.dataFile(self.opts.data)) |data_f| {
        defer data_f.close(global.io());

        var stream = terminal.vtStream();
        defer stream.deinit();

        var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
        var f_reader = data_f.reader(global.io(), &read_buf);
        const r = &f_reader.interface;

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try r.readSliceShort(&buf);
            if (n == 0) break; // EOF reached
            stream.nextSlice(buf[0..n]);
        }
    }

    // Decode restores the same bytes every step. Encode mode also uses
    // this buffer, in which case this is its one-time growth.
    self.encoded.shrinkRetainingCapacity(0);
    try snapshot.encode(
        self.alloc,
        &self.encoded.writer,
        terminal,
        .{ .continuation = .ground },
    );
}

fn teardown(ptr: *anyopaque) void {
    const self: *TerminalSnapshot = @ptrCast(@alignCast(ptr));
    if (self.terminal) |*t| t.deinit(self.alloc);
    self.terminal = null;
    self.encoded.shrinkRetainingCapacity(0);
}

fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalSnapshot = @ptrCast(@alignCast(ptr));
    for (0..self.opts.loops) |_| {
        std.mem.doNotOptimizeAway(self.encoded.written());
    }
}

fn stepEncode(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalSnapshot = @ptrCast(@alignCast(ptr));
    const terminal = &self.terminal.?;
    for (0..self.opts.loops) |_| {
        self.encoded.shrinkRetainingCapacity(0);
        snapshot.encode(
            self.alloc,
            &self.encoded.writer,
            terminal,
            .{ .continuation = .ground },
        ) catch |err| {
            log.warn("snapshot encoding failed err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(self.encoded.written());
    }
}

fn stepDecode(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalSnapshot = @ptrCast(@alignCast(ptr));
    const bytes = self.encoded.written();
    for (0..self.opts.loops) |_| {
        var reader: std.Io.Reader = .fixed(bytes);
        var decoded = snapshot.decode(
            self.alloc,
            global.io(),
            &reader,
            .{ .max_continuation_bytes = 1024 * 1024 },
        ) catch |err| {
            log.warn("snapshot decoding failed err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(&decoded);
        decoded.deinit(self.alloc);
    }
}

/// The renderable-prefix half of decode: everything through READY, leaving
/// all history unread. The gap between this and `stepDecode` is the latency
/// class the incremental decoder removes from time-to-interactive.
fn stepDecodeReady(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalSnapshot = @ptrCast(@alignCast(ptr));
    const bytes = self.encoded.written();
    for (0..self.opts.loops) |_| {
        var reader: std.Io.Reader = .fixed(bytes);
        var decoder: snapshot.Decoder = .init(&reader);
        var decoded = decoder.ready(
            self.alloc,
            global.io(),
            .{ .max_continuation_bytes = 1024 * 1024 },
        ) catch |err| {
            log.warn("snapshot READY decoding failed err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(&decoded);
        decoded.deinit(self.alloc);
    }
}

/// Print the encoded size grouped by record tag. This shares the encoder
/// with encode mode but deliberately makes no timing claims.
fn stepReport(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalSnapshot = @ptrCast(@alignCast(ptr));
    const bytes = self.encoded.written();

    var payload_totals = std.enums.EnumArray(
        snapshot.record.Tag,
        u64,
    ).initFill(0);
    var record_counts = std.enums.EnumArray(
        snapshot.record.Tag,
        u64,
    ).initFill(0);
    var record_total: u64 = 0;

    var offset: usize = snapshot.envelope.encoded_len;
    while (offset + snapshot.record.Header.len <= bytes.len) {
        const tag_raw = std.mem.readInt(u16, bytes[offset..][0..2], .little);
        const payload_len = std.mem.readInt(
            u32,
            bytes[offset + 2 ..][0..4],
            .little,
        );
        const tag = std.enums.fromInt(snapshot.record.Tag, tag_raw) orelse {
            log.warn("unknown record tag {}", .{tag_raw});
            return error.BenchmarkFailed;
        };
        payload_totals.getPtr(tag).* += payload_len;
        record_counts.getPtr(tag).* += 1;
        record_total += 1;
        offset += snapshot.record.Header.len + payload_len;
    }

    var it = payload_totals.iterator();
    while (it.next()) |entry| {
        std.debug.print("terminal-snapshot tag={s} records={d} payload={d}\n", .{
            @tagName(entry.key),
            record_counts.get(entry.key),
            entry.value.*,
        });
    }
    std.debug.print(
        "terminal-snapshot total records={d} framing={d} encoded={d}\n",
        .{
            record_total,
            record_total * snapshot.record.Header.len +
                snapshot.envelope.encoded_len,
            bytes.len,
        },
    );
}

test TerminalSnapshot {
    const testing = std.testing;
    const impl: *TerminalSnapshot = try .create(testing.allocator, .{});
    defer impl.destroy(testing.allocator);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}

test "TerminalSnapshot decode round trip" {
    const testing = std.testing;
    const impl: *TerminalSnapshot = try .create(testing.allocator, .{
        .mode = .decode,
        .@"terminal-rows" = 4,
        .@"terminal-cols" = 8,
    });
    defer impl.destroy(testing.allocator);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}

test "TerminalSnapshot decode READY prefix" {
    const testing = std.testing;
    const impl: *TerminalSnapshot = try .create(testing.allocator, .{
        .mode = .@"decode-ready",
        .@"terminal-rows" = 4,
        .@"terminal-cols" = 8,
    });
    defer impl.destroy(testing.allocator);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
