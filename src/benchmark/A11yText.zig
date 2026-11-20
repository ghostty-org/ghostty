//! This benchmark tests the performance of building the accessibility
//! text snapshot of a viewport (`a11y.text.build`).
//!
//! This matters because the GTK apprt builds it once for every rendered
//! frame while an AT client (Orca) is attached, and it does so while
//! holding `renderer_state.mutex`, so like `ScreenClone` this is a lock
//! holder that directly impacts IO throughput.
//!
//! `text` is the per-frame path: the snapshot is built into a retained
//! scratch snapshot, text, widths and caret, then compared against the
//! cached one.
//!
//! What this does NOT measure: the AT-SPI D-Bus traffic that follows a
//! change, which needs a live GTK app and bus. The numbers here are a
//! floor on the real per-frame cost, not the whole of it.
const A11yText = @This();

const std = @import("std");
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
/// Retained scratch snapshot, mirroring the GTK surface a11y state.
scratch: a11y.text.Snapshot = .{},
/// The snapshot the scratch one is compared against, mirroring the
/// cache an unchanged frame is checked against.
cached: a11y.text.Snapshot = .{},

pub const Options = struct {
    /// The type of snapshot work to perform.
    mode: Mode = .text,

    /// Multiplier on the number of iterations each step runs. This is
    /// useful to make a benchmark run long enough for profiling.
    loops: u32 = 1,

    /// The size of the terminal. The snapshot is proportional to the
    /// viewport cell count, so this is the primary scaling knob.
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

    /// The per-frame work: build the snapshot, widths and caret
    /// included, into a retained scratch snapshot and compare it against
    /// the cached one. Once the change check is in place this is what
    /// every frame costs, changed or not.
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
    };

    return ptr;
}

pub fn destroy(self: *A11yText, alloc: Allocator) void {
    self.scratch.deinit(alloc);
    self.cached.deinit(alloc);
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}

pub fn benchmark(self: *A11yText) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
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
        // No data file: synthesize a viewport that exercises every kind
        // of cell the snapshot handles: a styled run, double-width
        // cells, an interior blank gap and trailing blanks.
        var s = self.terminal.vtStream();
        defer s.deinit();
        for (0..self.terminal.rows) |i| {
            if (i > 0) s.nextSlice("\r\n");
            s.nextSlice("\x1b[38;2;200;100;50mstyled\x1b[0m plain ");
            s.nextSlice("日本語 wide   gap");
        }
    }

    // The cached snapshot to compare against, built out here so the
    // timed loop measures only the per-frame work.
    a11y.text.build(
        self.alloc,
        &self.cached,
        self.terminal.screens.active,
    ) catch |err| {
        log.warn("error building cached snapshot err={}", .{err});
        return error.BenchmarkFailed;
    };
}

/// Iterations per step. The snapshot is proportional to the viewport
/// cell count, so this is far lower than the cheap per-call benchmarks.
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

/// Mirrors what the GTK surface does once per rendered frame: build into
/// the retained scratch snapshot, then compare it with the cache.
fn stepText(ptr: *anyopaque) Benchmark.Error!void {
    const self: *A11yText = @ptrCast(@alignCast(ptr));

    for (0..iterations(self)) |_| {
        a11y.text.build(
            self.alloc,
            &self.scratch,
            self.terminal.screens.active,
        ) catch |err| {
            log.warn("error building a11y text err={}", .{err});
            return error.BenchmarkFailed;
        };

        const changed = !self.scratch.eql(&self.cached);
        std.mem.doNotOptimizeAway(changed);
        std.mem.doNotOptimizeAway(self.scratch.widths.items.len);
    }
}
