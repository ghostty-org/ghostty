//! This benchmark tests the performance of Terminal.resize, with a
//! primary focus on column resizes that reflow soft-wrapped text.
//! Resize happens on the IO thread while holding the terminal lock,
//! so a slow resize directly translates into dropped input and a
//! frozen-feeling UI while the user drags the window edge (which
//! produces a rapid stream of resizes).
//!
//! The terminal is populated once during setup (synthetic fill and/or
//! a data file replayed through the VT stream) and then each step
//! ping-pongs the terminal between two sizes. A full cycle returns the
//! terminal to its original dimensions so the state reaches a steady
//! state after the first cycle and every iteration performs
//! equivalent work.
const TerminalResize = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const Terminal = terminalpkg.Terminal;
const global = @import("../global.zig");

const log = std.log.scoped(.@"terminal-resize-bench");

opts: Options,
alloc: Allocator,
terminal: Terminal,

pub const Options = struct {
    /// The resize pattern to benchmark. See Mode.
    mode: Mode = .cols,

    /// Multiplier on the number of resize cycles each step runs. This
    /// is useful to make a benchmark run long enough for profiling.
    loops: u32 = 1,

    /// The initial size of the terminal. This is also the size that
    /// every resize cycle returns to.
    @"terminal-rows": u16 = 80,
    @"terminal-cols": u16 = 120,

    /// The dimensions to resize to for the cols/rows/both modes. If
    /// unset, they default to half of the respective terminal
    /// dimension, which forces every soft-wrapped line to rewrap.
    @"resize-cols": ?u16 = null,
    @"resize-rows": ?u16 = null,

    /// The number of synthetic lines written to the terminal during
    /// setup. The content is deterministic: a mix of short lines,
    /// soft-wrapped long lines, blank lines, styled cells, and wide
    /// characters, since all of these hit different reflow paths.
    /// Set to 0 to only use `data`.
    @"fill-lines": u32 = 10_000,

    /// The maximum scrollback size in bytes. Defaults to the Ghostty
    /// application default. Reflow cost scales with the amount of
    /// scrollback, not just the visible screen.
    @"scrollback-bytes": usize = 50_000_000,

    /// The data to read as a filepath. If this is "-" then
    /// we will read stdin. If this is unset, only the synthetic fill
    /// is used. The data is streamed into the terminal during setup
    /// (not part of the benchmark) to build the screen contents that
    /// get resized.
    data: ?[]const u8 = null,
};

pub const Mode = enum {
    /// Resize to the current dimensions. This measures the early-exit
    /// path (mode updates, pixel geometry) and acts as a baseline.
    noop,

    /// Alternate the column count between `terminal-cols` and
    /// `resize-cols`. With wraparound enabled (the default), this
    /// reflows text in both directions: shrinking wraps long lines
    /// and growing unwraps them. This is the primary reflow benchmark.
    cols,

    /// Like `cols`, but with wraparound mode disabled so the resize
    /// does not reflow. Useful as a baseline to isolate the cost of
    /// reflow itself from the rest of the resize.
    @"cols-no-reflow",

    /// Alternate the row count between `terminal-rows` and
    /// `resize-rows`. Column count is unchanged so no text reflows;
    /// this measures growing/trimming rows against scrollback.
    rows,

    /// Alternate both dimensions at once, like a diagonal window drag.
    both,
};

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*TerminalResize {
    const ptr = try alloc.create(TerminalResize);
    errdefer alloc.destroy(ptr);

    ptr.* = .{
        .opts = opts,
        .alloc = alloc,
        .terminal = try .init(global.io(), alloc, .{
            .rows = opts.@"terminal-rows",
            .cols = opts.@"terminal-cols",
            .max_scrollback_bytes = opts.@"scrollback-bytes",
        }),
    };

    return ptr;
}

pub fn destroy(self: *TerminalResize, alloc: Allocator) void {
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}

pub fn benchmark(self: *TerminalResize) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .cols, .@"cols-no-reflow" => stepCols,
            .rows => stepRows,
            .both => stepBoth,
        },
        .setupFn = setup,
    });
}

/// The column count used by the cols/both modes.
fn targetCols(self: *const TerminalResize) u16 {
    return self.opts.@"resize-cols" orelse
        @max(1, self.opts.@"terminal-cols" / 2);
}

/// The row count used by the rows/both modes.
fn targetRows(self: *const TerminalResize) u16 {
    return self.opts.@"resize-rows" orelse
        @max(1, self.opts.@"terminal-rows" / 2);
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalResize = @ptrCast(@alignCast(ptr));

    // Always reset our terminal state. Note this doesn't resize, but
    // create initializes (and steps return) the terminal to the
    // requested dimensions so we're always at terminal-rows/cols here.
    self.terminal.fullReset();
    assert(self.terminal.cols == self.opts.@"terminal-cols");
    assert(self.terminal.rows == self.opts.@"terminal-rows");

    // Fill with synthetic content first, then replay the data file on
    // top if given. Both go through the VT stream so soft wraps,
    // styles, etc. are all set exactly as they would be in a real
    // session.
    self.fill();
    try self.replayData();

    // Reflow only happens when wraparound mode is set (it is by
    // default). We only disable it after filling so the fill itself
    // still soft-wraps identically in every mode.
    if (self.opts.mode == .@"cols-no-reflow") {
        self.terminal.modes.set(.wraparound, false);
    }
}

/// Write deterministic synthetic content to the terminal. The goal is
/// content that is representative of a real session so that reflow
/// touches its interesting paths: soft-wrapped lines (must rewrap),
/// short lines (copied as-is), blank lines, styled cells (styles must
/// be moved across pages), and wide characters (can't be split at the
/// wrap column).
fn fill(self: *TerminalResize) void {
    if (self.opts.@"fill-lines" == 0) return;

    var s = self.terminal.vtStream();
    defer s.deinit();

    var prng: std.Random.DefaultPrng = .init(0xB3);
    const rand = prng.random();

    const cols: usize = self.terminal.cols;
    var line_buf: [8192]u8 = undefined;

    for (0..self.opts.@"fill-lines") |i| {
        // Periodically toggle a background style so reflow has to
        // carry styled cells into new pages.
        if (i % 64 == 0) s.nextSlice("\x1b[48;2;20;40;60m");
        if (i % 64 == 32) s.nextSlice("\x1b[m");

        // A small portion of lines are blank.
        if (i % 16 == 15) {
            s.nextSlice("\r\n");
            continue;
        }

        // Line lengths between ~25% and ~250% of the terminal width
        // so we get a mix of short lines and soft-wrapped lines.
        const min = @max(1, cols / 4);
        const max = @min(line_buf.len, cols * 5 / 2);
        const len = min + rand.uintLessThan(usize, max - min);

        var j: usize = 0;
        while (j < len) {
            // Sprinkle wide characters into every 8th line.
            if (i % 8 == 7 and j % 16 == 8 and j + 3 <= len) {
                line_buf[j..][0..3].* = "漢".*;
                j += 3;
                continue;
            }

            // Words of ASCII separated by spaces.
            line_buf[j] = if (j % 8 == 7)
                ' '
            else
                rand.intRangeAtMost(u8, 'a', 'z');
            j += 1;
        }

        s.nextSlice(line_buf[0..len]);
        s.nextSlice("\r\n");
    }
}

/// Stream the data file (if any) into the terminal.
fn replayData(self: *TerminalResize) Benchmark.Error!void {
    const data_f: std.Io.File = (options.dataFile(
        self.opts.data,
    ) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    }) orelse return;
    defer data_f.close(global.io());

    var stream = self.terminal.vtStream();
    defer stream.deinit();

    var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var f_reader = data_f.reader(global.io(), &read_buf);
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
}

fn resizeTerminal(
    self: *TerminalResize,
    cols: u16,
    rows: u16,
) Benchmark.Error!void {
    self.terminal.resize(self.alloc, .{
        .cols = cols,
        .rows = rows,
        // Realistic cell pixel geometry: real apprt resizes always
        // carry it, and it exercises the pixel dimension updates.
        .cell_size_px = .{ .width = 10, .height = 20 },
    }) catch |err| {
        log.warn("error resizing terminal err={}", .{err});
        return error.BenchmarkFailed;
    };
    std.mem.doNotOptimizeAway(&self.terminal);
}

fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalResize = @ptrCast(@alignCast(ptr));

    const cols = self.opts.@"terminal-cols";
    const rows = self.opts.@"terminal-rows";

    // We loop because it's so fast (a few ns) that a single resize
    // doesn't properly capture our speeds.
    for (0..50_000_000 * @as(u64, self.opts.loops)) |_| {
        try self.resizeTerminal(cols, rows);
    }
}

fn stepCols(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalResize = @ptrCast(@alignCast(ptr));

    const cols = self.opts.@"terminal-cols";
    const rows = self.opts.@"terminal-rows";
    const target = self.targetCols();

    // Per-cycle cost differs by orders of magnitude between the two
    // modes (a reflow resize walks the entire scrollback; a non-reflow
    // resize doesn't), so pick a cycle count that makes each run long
    // enough to measure well above process startup and setup cost.
    const cycles: u64 = switch (self.opts.mode) {
        .cols => 25,
        .@"cols-no-reflow" => 1_500,
        else => unreachable,
    };

    // Each cycle shrinks (rewrapping long lines) and grows back
    // (unwrapping them), ending at the original size.
    for (0..cycles * @as(u64, self.opts.loops)) |_| {
        try self.resizeTerminal(target, rows);
        try self.resizeTerminal(cols, rows);
    }
}

fn stepRows(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalResize = @ptrCast(@alignCast(ptr));

    const cols = self.opts.@"terminal-cols";
    const rows = self.opts.@"terminal-rows";
    const target = self.targetRows();

    // Row-only resizes don't reflow so they're much cheaper (tens of
    // ns); loop a lot more so the measurement isn't dominated by
    // process overhead.
    for (0..2_500_000 * @as(u64, self.opts.loops)) |_| {
        try self.resizeTerminal(cols, target);
        try self.resizeTerminal(cols, rows);
    }
}

fn stepBoth(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalResize = @ptrCast(@alignCast(ptr));

    const cols = self.opts.@"terminal-cols";
    const rows = self.opts.@"terminal-rows";
    const target_cols = self.targetCols();
    const target_rows = self.targetRows();

    for (0..25 * @as(u64, self.opts.loops)) |_| {
        try self.resizeTerminal(target_cols, target_rows);
        try self.resizeTerminal(cols, rows);
    }
}

test TerminalResize {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Small dimensions and fill so this is fast in debug builds while
    // still exercising real reflow in both directions.
    const impl: *TerminalResize = try .create(alloc, .{
        .mode = .cols,
        .@"terminal-rows" = 10,
        .@"terminal-cols" = 20,
        .@"fill-lines" = 50,
    });
    defer impl.destroy(alloc);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
