//! This benchmark tests the performance of building the accessibility
//! text snapshot of a viewport (`a11y.text.build`).
//!
//! This matters because the GTK apprt walks the viewport on every
//! rendered frame while an AT client (Orca) is attached, and it does so
//! while holding `renderer_state.mutex`, so like `ScreenClone` this is
//! a lock holder that directly impacts IO throughput.
//!
//! The two modes that matter mirror the two real per-frame paths:
//! `probe` is `A11y.probeChanged`, which every rendered frame pays, and
//! `text` is `A11y.refreshCache`, which only a frame that actually changed
//! pays.
//!
//! What this does NOT measure: the AT-SPI D-Bus traffic that follows a
//! change, which needs a live GTK app and bus. The numbers here are a
//! floor on the real per-frame cost, not the whole of it.
const A11yText = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const a11y = @import("../a11y/main.zig");
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const Terminal = terminalpkg.Terminal;
const global = @import("../global.zig");

const log = std.log.scoped(.@"a11y-text-bench");

opts: Options,
alloc: Allocator,
terminal: Terminal,
/// Retained scratch + reference snapshot for `probe` mode, mirroring
/// `probe_buf` and `last_snapshot` on the GTK surface a11y state.
probe_buf: std.Io.Writer.Allocating,
probe_snapshot: std.Io.Writer.Allocating,
/// Per-codepoint cell widths, mirroring `cached_widths`. Only the
/// `text` mode fills this, because only `A11y.refreshCache` asks for it.
widths: std.Io.Writer.Allocating,

pub const Options = struct {
    /// The type of snapshot work to perform.
    mode: Mode = .text,

    /// Multiplier on the number of iterations each step runs. This is
    /// useful to make a benchmark run long enough for profiling.
    loops: u32 = 1,

    /// The size of the terminal. The snapshot walk is proportional to
    /// the viewport cell count, so this is the primary scaling knob.
    @"terminal-rows": u16 = 80,
    @"terminal-cols": u16 = 120,

    /// The data to read as a filepath. If this is "-" then we will read
    /// stdin. If this is unset, we synthesize a viewport containing
    /// styled text and wide characters. The time to read this is not
    /// part of the benchmark.
    data: ?[]const u8 = null,
};

pub const Mode = enum {
    /// Baseline: iterate the same viewport rows without building
    /// anything. Isolates iteration overhead from the snapshot work.
    noop,

    /// The per-frame change probe: text into a retained scratch buffer,
    /// then a memcmp against the previous snapshot. No allocation, no
    /// widths. This is what an *unchanged* frame costs once the change
    /// gate is in place, and it is the number that matters most, because most
    /// frames don't change.
    probe,

    /// The full rebuild: the viewport walk with cell widths recorded,
    /// plus the NUL-terminated dup that gets cached. This is what a
    /// frame that actually changed costs.
    text,
};

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*A11yText {
    const ptr = try alloc.create(A11yText);
    errdefer alloc.destroy(ptr);

    ptr.* = .{
        .opts = opts,
        .alloc = alloc,
        .terminal = try .init(global.io(), alloc, .{
            .rows = opts.@"terminal-rows",
            .cols = opts.@"terminal-cols",
        }),
        .probe_buf = .init(alloc),
        .probe_snapshot = .init(alloc),
        .widths = .init(alloc),
    };

    return ptr;
}

pub fn destroy(self: *A11yText, alloc: Allocator) void {
    self.probe_buf.deinit();
    self.probe_snapshot.deinit();
    self.widths.deinit();
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}

pub fn benchmark(self: *A11yText) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .probe => stepProbe,
            .text => stepText,
        },
        .setupFn = setup,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *A11yText = @ptrCast(@alignCast(ptr));

    // Always reset our terminal state
    self.terminal.fullReset();

    const data_f: ?std.Io.File = options.dataFile(
        self.opts.data,
    ) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    };

    if (data_f) |f| {
        defer f.close(global.io());

        var stream = self.terminal.vtStream();
        defer stream.deinit();

        var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
        var f_reader = f.reader(global.io(), &read_buf);
        const r = &f_reader.interface;

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = r.readSliceShort(&buf) catch {
                log.warn("error reading data file err={?}", .{f_reader.err});
                return error.BenchmarkFailed;
            };
            if (n == 0) break; // EOF reached
            stream.nextSlice(buf[0..n]);
        }
    } else {
        // No data file: synthesize a viewport that exercises every branch
        // of the walk: a styled run, double-width cells, an interior
        // blank gap and trailing blanks.
        var s = self.terminal.vtStream();
        defer s.deinit();
        for (0..self.terminal.rows) |i| {
            if (i > 0) s.nextSlice("\r\n");
            s.nextSlice("\x1b[38;2;200;100;50mstyled\x1b[0m plain ");
            s.nextSlice("日本語 wide   gap");
        }
    }

    // Reference snapshot for `probe` mode, built out here so the timed
    // loop measures only the probe itself.
    self.probe_snapshot.clearRetainingCapacity();
    _ = a11y.text.build(
        &self.probe_snapshot.writer,
        self.terminal.screens.active,
        .{},
    ) catch |err| {
        log.warn("error building probe snapshot err={}", .{err});
        return error.BenchmarkFailed;
    };
}

/// Iterations per step. The walk is proportional to the viewport cell
/// count, so this is far lower than the cheap per-call benchmarks.
fn iterations(self: *const A11yText) u64 {
    return 100 * @as(u64, self.opts.loops);
}

fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    const self: *A11yText = @ptrCast(@alignCast(ptr));

    for (0..iterations(self)) |_| {
        const screen: *terminalpkg.Screen = self.terminal.screens.active;
        const pages = &screen.pages;
        const tl_pin = pages.getTopLeft(.viewport);
        var row_it = tl_pin.rowIterator(.right_down, null);
        var row_idx: usize = 0;
        while (row_idx < pages.rows) : (row_idx += 1) {
            const pin = row_it.next() orelse continue;
            const cells = pin.cells(.all);
            std.mem.doNotOptimizeAway(cells.len);
        }
    }
}

/// Models `A11y.probeChanged`: retained scratch buffer, text only, then the
/// memcmp against the last notified snapshot. This is the gate that lets
/// an unchanged frame skip the rebuild entirely.
fn stepProbe(ptr: *anyopaque) Benchmark.Error!void {
    const self: *A11yText = @ptrCast(@alignCast(ptr));

    for (0..iterations(self)) |_| {
        self.probe_buf.clearRetainingCapacity();

        const result = a11y.text.build(
            &self.probe_buf.writer,
            self.terminal.screens.active,
            .{},
        ) catch |err| {
            log.warn("error probing a11y text err={}", .{err});
            return error.BenchmarkFailed;
        };

        const changed = !std.mem.eql(
            u8,
            self.probe_snapshot.written(),
            self.probe_buf.written(),
        );

        std.mem.doNotOptimizeAway(changed);
        std.mem.doNotOptimizeAway(result.cp_count);
    }
}

/// Mirrors what `A11y.refreshCache` does on a frame that changed: a fresh
/// buffer, the viewport walk with widths recorded, and the final
/// NUL-terminated dup that gets cached. The allocation churn is
/// intentional: the real path pays it too.
fn stepText(ptr: *anyopaque) Benchmark.Error!void {
    const self: *A11yText = @ptrCast(@alignCast(ptr));

    for (0..iterations(self)) |_| {
        var buffer: std.Io.Writer.Allocating = .init(self.alloc);
        defer buffer.deinit();
        self.widths.clearRetainingCapacity();

        const result = a11y.text.build(
            &buffer.writer,
            self.terminal.screens.active,
            .{ .widths = &self.widths.writer },
        ) catch |err| {
            log.warn("error building a11y text err={}", .{err});
            return error.BenchmarkFailed;
        };

        const text = self.alloc.dupeZ(u8, buffer.written()) catch |err| {
            log.warn("error duplicating a11y text err={}", .{err});
            return error.BenchmarkFailed;
        };
        defer self.alloc.free(text);

        std.mem.doNotOptimizeAway(result.cp_count);
        std.mem.doNotOptimizeAway(text.len);
        std.mem.doNotOptimizeAway(self.widths.written().len);
    }
}
