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
const global = @import("../global.zig");

const log = std.log.scoped(.@"terminal-stream-bench");

opts: Options,
terminal: Terminal,

pub const Options = struct {
    /// The type of codepoint width calculation to use.
    mode: Mode = .clone,

    /// Multiplier on the number of iterations each step runs. This is
    /// useful to make a benchmark run long enough for profiling.
    loops: u32 = 1,

    /// The size of the terminal. This affects benchmarking when
    /// dealing with soft line wrapping and the memory impact
    /// of page sizes.
    @"terminal-rows": u16 = 80,
    @"terminal-cols": u16 = 120,

    /// The cell size in pixels. Kitty graphics images need a cell size
    /// to be sized, so without one the Kitty modes have nothing to do.
    @"cell-width": u32 = 10,
    @"cell-height": u32 = 20,

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

    /// Like render, but only the portion of the render state update
    /// that requires holding a terminal lock (beginUpdate). The
    /// deferred work (endUpdate) is excluded since it happens outside
    /// of any locks.
    @"render-locked",

    /// RenderState update with no changes to the terminal. This is
    /// the common case for a renderer that is redrawing frames (e.g.
    /// cursor blink, mouse movement) without terminal changes.
    @"render-clean",

    /// RenderState update where a single row is dirty. This models the
    /// common case of a shell prompt or TUI updating a small portion
    /// of the screen between frames.
    @"render-partial",

    /// Like render-partial, and then reads every Kitty graphics image
    /// placement found through placeholder cells, as a renderer does
    /// each frame (see `RenderState.imagePlacementIterator`). Use it with
    /// data that shows images with placeholder cells.
    @"render-partial-kitty",

    /// Like render-partial-kitty, but the images are Kitty graphics
    /// images placed at cells on the screen instead of placeholder
    /// cells. `bench_fixed_count` of them are spread over the active
    /// area. This models a program updating a small part of the screen
    /// while images it placed earlier stay where they are.
    @"render-partial-kitty-fixed",

    /// RenderState update after scrolling the viewport by one row.
    /// This is the per-frame cost of user-driven scrolling through
    /// scrollback (e.g. a trackpad fling), which today changes the
    /// viewport pin and forces a full rebuild.
    @"render-scroll",

    /// Like render-scroll, and then reads every image placement, as
    /// render-partial-kitty does. The screen holds as many images placed
    /// at cells as render-partial-kitty-fixed, spread over the
    /// scrollback that the viewport scrolls through. Some are usually
    /// visible, and every one moves each frame. This models scrolling
    /// back through output that contains images.
    @"render-scroll-kitty-fixed",

    /// RenderState update after scrolling the viewport by half a
    /// screen. This models paging (page up/down, wheel ticks with
    /// large multipliers) rather than smooth scrolling.
    @"render-scroll-page",

    /// RenderState update after one new line of output is written
    /// while the viewport follows the active area. This models a
    /// program streaming output. Each frame the viewport pin moves
    /// down one row.
    @"render-output",

    /// The render-scroll, render-output, and render-clean modes with
    /// overscan (`RenderState.overscan_request`) of 4 rows above and 1
    /// below. This models a renderer that captures extra rows so it can
    /// draw partially visible rows while smooth scrolling.
    @"render-scroll-overscan",
    @"render-output-overscan",
    @"render-clean-overscan",
};

/// The overscan request used by the overscan modes.
const bench_overscan: terminalpkg.RenderState.Overscan = .{ .above = 4, .below = 1 };

/// The overscan request for the given mode.
fn overscanRequest(mode: Mode) terminalpkg.RenderState.Overscan {
    return switch (mode) {
        .@"render-scroll-overscan",
        .@"render-output-overscan",
        .@"render-clean-overscan",
        => bench_overscan,
        else => .{},
    };
}

/// The number of Kitty graphics images placed at cells in the
/// `*-kitty-fixed` modes, and the size of each one in cells.
const bench_fixed_count = 8;
const bench_fixed_cols = 6;
const bench_fixed_rows = 4;

/// Number of scrollback lines written during setup so that the scroll
/// modes have room to move in both directions.
const scroll_setup_lines = 4000;

/// Direction changes for the scroll modes, in iterations.
const scroll_reverse_interval = 2000;
const scroll_page_reverse_interval = 40;

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*ScreenClone {
    const ptr = try alloc.create(ScreenClone);
    errdefer alloc.destroy(ptr);

    var terminal_opts: Terminal.Options = .{
        .rows = opts.@"terminal-rows",
        .cols = opts.@"terminal-cols",
    };

    // The scroll modes need real scrollback to move through. The
    // default limit is small enough that the setup lines would be
    // pruned immediately.
    switch (opts.mode) {
        .@"render-scroll",
        .@"render-scroll-kitty-fixed",
        .@"render-scroll-page",
        .@"render-scroll-overscan",
        => terminal_opts.max_scrollback_bytes = 256 * 1024 * 1024,
        else => {},
    }

    ptr.* = .{
        .opts = opts,
        .terminal = try .init(global.io(), alloc, terminal_opts),
    };
    ptr.terminal.width_px = @as(u32, opts.@"terminal-cols") * opts.@"cell-width";
    ptr.terminal.height_px = @as(u32, opts.@"terminal-rows") * opts.@"cell-height";

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
            .@"render-locked" => stepRenderLocked,
            .@"render-clean",
            .@"render-clean-overscan",
            => stepRenderClean,
            .@"render-partial" => stepRenderPartial,
            .@"render-partial-kitty",
            .@"render-partial-kitty-fixed",
            => stepRenderPartialKitty,
            .@"render-scroll",
            .@"render-scroll-overscan",
            => stepRenderScroll,
            .@"render-scroll-kitty-fixed" => stepRenderScrollKitty,
            .@"render-scroll-page" => stepRenderScrollPage,
            .@"render-output",
            .@"render-output-overscan",
            => stepRenderOutput,
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
    s.nextSlice("\x1b[48;2;20;40;60m");

    // The scroll modes need scrollback above the screen so the
    // viewport has somewhere to go.
    switch (self.opts.mode) {
        .@"render-scroll",
        .@"render-scroll-kitty-fixed",
        .@"render-scroll-page",
        .@"render-scroll-overscan",
        => for (0..scroll_setup_lines) |_| s.nextSlice("hello\r\n"),
        else => {},
    }

    for (0..self.terminal.rows - 1) |_| s.nextSlice("hello\r\n");
    s.nextSlice("hello");

    // Kitty graphics images placed at cells, spread over the rows that
    // the mode shows. That is the active area, or the scrollback that
    // the scroll mode moves through.
    switch (self.opts.mode) {
        .@"render-partial-kitty-fixed" => self.addFixedPlacements(
            self.terminal.rows,
        ) catch |err| {
            log.warn("error adding kitty placements err={}", .{err});
            return error.BenchmarkFailed;
        },
        .@"render-scroll-kitty-fixed" => self.addFixedPlacements(
            self.terminal.rows + scroll_reverse_interval,
        ) catch |err| {
            log.warn("error adding kitty placements err={}", .{err});
            return error.BenchmarkFailed;
        },
        else => {},
    }

    // Setup our terminal state
    const data_f: std.Io.File = (options.dataFile(
        self.opts.data,
    ) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    }) orelse return;

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

/// Add one Kitty graphics image and place it at `bench_fixed_count`
/// cells, spread evenly over the last `span` rows of the screen. The
/// columns vary so that the images don't all line up.
fn addFixedPlacements(self: *ScreenClone, span: usize) !void {
    const screen = self.terminal.screens.active;
    const alloc = screen.alloc;
    const io = global.io();
    const storage = &screen.kitty_images;

    const width = 16;
    const height = 16;
    const pixels = try alloc.alloc(u8, width * height * 4);
    @memset(pixels, 0x80);
    try storage.addImage(io, alloc, screen, .{
        .id = 1,
        .width = width,
        .height = height,
        .format = .rgba,
        .data = .{ .complete = pixels },
    });

    const bottom = screen.pages.getBottomRight(.screen).?;
    const step = span / bench_fixed_count;
    for (0..bench_fixed_count) |i| {
        var p = bottom.up(span - 1 - i * step) orelse return error.OutOfRows;
        p.x = @intCast((i * 13) % (self.terminal.cols - bench_fixed_cols));
        const pin = try screen.pages.trackPin(p);
        try storage.addPlacement(io, alloc, screen, 1, @intCast(i + 1), .{
            .location = .{ .pin = pin },
            .columns = bench_fixed_cols,
            .rows = bench_fixed_rows,
        });
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
            s.io,
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
    for (0..50_000 * @as(u64, self.opts.loops)) |_| {
        // Forces a full rebuild because it thinks our screen changed
        state.screen = .alternate;
        state.update(alloc, &self.terminal) catch |err| {
            log.warn("error cloning screen err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(&state);

        // Note: we purposely do not free memory because we don't want
        // to benchmark that. We'll free when the benchmark exits.
    }
}

fn stepRenderLocked(ptr: *anyopaque) Benchmark.Error!void {
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
    for (0..50_000 * @as(u64, self.opts.loops)) |_| {
        // Forces a full rebuild because it thinks our screen changed
        state.screen = .alternate;
        state.beginUpdate(alloc, &self.terminal) catch |err| {
            log.warn("error cloning screen err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(&state);

        // Note: we purposely do not free memory because we don't want
        // to benchmark that. We'll free when the benchmark exits.
    }
}

fn stepRenderClean(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));

    // Initial update so that subsequent updates are clean (nothing
    // dirty, no rebuilds).
    const alloc = self.terminal.screens.active.alloc;
    var state: terminalpkg.RenderState = .empty;
    state.overscan_request = overscanRequest(self.opts.mode);
    state.update(alloc, &self.terminal) catch |err| {
        log.warn("error cloning screen err={}", .{err});
        return error.BenchmarkFailed;
    };

    // We loop because its so fast that a single benchmark run doesn't
    // properly capture our speeds.
    for (0..3_000_000 * @as(u64, self.opts.loops)) |_| {
        state.update(alloc, &self.terminal) catch |err| {
            log.warn("error cloning screen err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(&state);
    }
}

fn stepRenderPartial(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));

    // Initial update so that subsequent updates are incremental.
    const alloc = self.terminal.screens.active.alloc;
    var state: terminalpkg.RenderState = .empty;
    state.update(alloc, &self.terminal) catch |err| {
        log.warn("error cloning screen err={}", .{err});
        return error.BenchmarkFailed;
    };

    // Grab a pin roughly in the middle of the active area that we
    // dirty on every iteration to simulate a small screen update.
    const pages = &self.terminal.screens.active.pages;
    const pin = pages.pin(.{ .active = .{
        .x = 0,
        .y = self.terminal.rows / 2,
    } }).?;

    // We loop because its so fast that a single benchmark run doesn't
    // properly capture our speeds.
    for (0..2_000_000 * @as(u64, self.opts.loops)) |_| {
        // Mark a single row dirty. `update` clears this so each
        // iteration rebuilds exactly one row.
        pin.markDirty();
        state.update(alloc, &self.terminal) catch |err| {
            log.warn("error cloning screen err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(&state);
    }
}

fn stepRenderPartialKitty(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));

    const alloc = self.terminal.screens.active.alloc;
    var state: terminalpkg.RenderState = .empty;
    state.update(alloc, &self.terminal) catch |err| {
        log.warn("error cloning screen err={}", .{err});
        return error.BenchmarkFailed;
    };

    const pages = &self.terminal.screens.active.pages;
    const pin = pages.pin(.{ .active = .{
        .x = 0,
        .y = self.terminal.rows / 2,
    } }).?;

    for (0..200_000 * @as(u64, self.opts.loops)) |_| {
        pin.markDirty();
        state.update(alloc, &self.terminal) catch |err| {
            log.warn("error cloning screen err={}", .{err});
            return error.BenchmarkFailed;
        };

        var it = state.imagePlacementIterator();
        while (it.next()) |p| std.mem.doNotOptimizeAway(p);
    }
}

fn stepRenderScroll(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));
    try renderScrollLoop(self, 1, scroll_reverse_interval);
}

fn stepRenderScrollKitty(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));

    const alloc = self.terminal.screens.active.alloc;
    var state: terminalpkg.RenderState = .empty;
    state.update(alloc, &self.terminal) catch |err| {
        log.warn("error cloning screen err={}", .{err});
        return error.BenchmarkFailed;
    };

    var dir: isize = 1;
    for (0..50_000 * @as(u64, self.opts.loops)) |i| {
        if (i % scroll_reverse_interval == 0) dir = -dir;
        self.terminal.scrollViewport(.{ .delta = dir });
        state.update(alloc, &self.terminal) catch |err| {
            log.warn("error cloning screen err={}", .{err});
            return error.BenchmarkFailed;
        };

        var it = state.imagePlacementIterator();
        while (it.next()) |p| std.mem.doNotOptimizeAway(p);
    }
}

fn stepRenderScrollPage(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));
    try renderScrollLoop(
        self,
        @intCast(@max(1, self.terminal.rows / 2)),
        scroll_page_reverse_interval,
    );
}

/// Scroll the viewport by `step` rows per iteration, reversing
/// direction every `interval` iterations, and update the render state
/// after each scroll. The viewport starts at the bottom, so the first
/// stretch scrolls up into scrollback.
fn renderScrollLoop(
    self: *ScreenClone,
    step: isize,
    interval: usize,
) Benchmark.Error!void {
    const alloc = self.terminal.screens.active.alloc;
    var state: terminalpkg.RenderState = .empty;
    state.overscan_request = overscanRequest(self.opts.mode);
    state.update(alloc, &self.terminal) catch |err| {
        log.warn("error cloning screen err={}", .{err});
        return error.BenchmarkFailed;
    };

    var dir: isize = 1;
    for (0..50_000 * @as(u64, self.opts.loops)) |i| {
        if (i % interval == 0) dir = -dir;
        self.terminal.scrollViewport(.{ .delta = dir * step });
        state.update(alloc, &self.terminal) catch |err| {
            log.warn("error cloning screen err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(&state);
    }
}

fn stepRenderOutput(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ScreenClone = @ptrCast(@alignCast(ptr));

    const alloc = self.terminal.screens.active.alloc;
    var state: terminalpkg.RenderState = .empty;
    state.overscan_request = overscanRequest(self.opts.mode);
    state.update(alloc, &self.terminal) catch |err| {
        log.warn("error cloning screen err={}", .{err});
        return error.BenchmarkFailed;
    };

    // Make sure the viewport follows the active area so each line
    // written moves the viewport.
    self.terminal.scrollViewport(.bottom);

    var stream = self.terminal.vtStream();
    defer stream.deinit();
    for (0..50_000 * @as(u64, self.opts.loops)) |_| {
        stream.nextSlice("hello\r\n");
        state.update(alloc, &self.terminal) catch |err| {
            log.warn("error cloning screen err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(&state);
    }
}
