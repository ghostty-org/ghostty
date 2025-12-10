//! This benchmark tests the performance of the Screen.clone
//! function. This is useful because it is one of the primary lock
//! holders that impact IO performance when the renderer is active.
//! We do this very frequently.
const ScreenClone = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const Terminal = terminalpkg.Terminal;

const log = std.log.scoped(.@"terminal-stream-bench");

opts: Options,
terminal: Terminal,

pub const Options = struct {
    /// The type of codepoint width calculation to use.
    mode: Mode = .clone,

    /// The size of the terminal. This affects benchmarking when
    /// dealing with soft line wrapping and the memory impact
    /// of page sizes.
    @"terminal-rows": u16 = 80,
    @"terminal-cols": u16 = 120,

    /// The data to read as a filepath. If this is "-" then
    /// we will read stdin. If this is unset, then we will
    /// do nothing (benchmark is a noop). It'd be more unixy to
    /// use stdin by default but I find that a hanging CLI command
    /// with no interaction is a bit annoying.
    ///
    /// This will be used to initialize the terminal screen state before
    /// cloning. This data can switch to alt screen if it wants. The time
    /// to read this is not part of the benchmark.
    data: ?[]const u8 = null,
};

pub const Mode = enum {
    /// The baseline mode copies the screen by value.
    noop,

    /// Full clone
    clone,

    /// RenderState rather than a screen clone.
    render,
};

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*ScreenClone {
    const ptr = try alloc.create(ScreenClone);
    errdefer alloc.destroy(ptr);

    ptr.* = .{
        .opts = opts,
        .terminal = try .init(alloc, .{
            .rows = opts.@"terminal-rows",
            .cols = opts.@"terminal-cols",
        }),
    };

    return ptr;
}

pub fn destroy(self: *ScreenClone, alloc: Allocator) void {
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}

pub fn benchmark(self: *ScreenClone) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .clone => stepClone,
            .render => stepRender,
        },
        .setupFn = setup,
        .teardownFn = teardown,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));

    // Always reset our terminal state
    self.terminal.fullReset();

    // Force a style on every single row, which
    var s = self.terminal.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[48;2;20;40;60m") catch unreachable;
    for (0..self.terminal.rows - 1) |_| s.nextSlice("hello\r\n") catch unreachable;
    s.nextSlice("hello") catch unreachable;

    // Setup our terminal state
    const data_f: std.fs.File = (options.dataFile(
        self.opts.data,
    ) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    }) orelse return;

    var stream = self.terminal.vtStream();
    defer stream.deinit();

    var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var f_reader = data_f.reader(&read_buf);
    const r = &f_reader.interface;

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = r.readSliceShort(&buf) catch {
            log.warn("error reading data file err={?}", .{f_reader.err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; // EOF reached
        stream.nextSlice(buf[0..n]) catch |err| {
            log.warn("error processing data file chunk err={}", .{err});
            return error.BenchmarkFailed;
        };
    }
}

fn teardown(ptr: *anyopaque) void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));
    _ = self;
}

fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));

    // We loop because its so fast that a single benchmark run doesn't
    // properly capture our speeds.
    for (0..1000) |_| {
        const s: terminalpkg.Screen = self.terminal.screens.active.*;
        std.mem.doNotOptimizeAway(s);
    }
}

fn stepClone(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));

    // We loop because its so fast that a single benchmark run doesn't
    // properly capture our speeds.
    for (0..1000) |_| {
        const s: *terminalpkg.Screen = self.terminal.screens.active;
        const copy = s.clone(
            s.alloc,
            .{ .viewport = .{} },
            null,
        ) catch |err| {
            log.warn("error cloning screen err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(copy);

        // Note: we purposely do not free memory because we don't want
        // to benchmark that. We'll free when the benchmark exits.
    }
}

fn stepRender(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));

    // We do this once out of the loop because a significant slowdown
    // on the first run is allocation. After that first run, even with
    // a full rebuild, it is much faster. Let's ignore that first run
    // slowdown.
    const alloc = self.terminal.screens.active.alloc;
    var state: terminalpkg.RenderState = .empty;
    state.update(alloc, &self.terminal) catch |err| {
        log.warn("error cloning screen err={}", .{err});
        return error.BenchmarkFailed;
    };

    // We loop because its so fast that a single benchmark run doesn't
    // properly capture our speeds.
    for (0..1000) |_| {
        // Forces a full rebuild because it thinks our screen changed
        state.screen = .alternate;
        state.update(alloc, &self.terminal) catch |err| {
            log.warn("error cloning screen err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(state);

        // Note: we purposely do not free memory because we don't want
        // to benchmark that. We'll free when the benchmark exits.
    }
}
