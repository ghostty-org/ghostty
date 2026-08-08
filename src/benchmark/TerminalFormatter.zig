//! Benchmarks the terminal formatter (`terminal/formatter.zig`).
//!
//! The formatter is the hot path for clipboard copy (plain/VT/HTML),
//! `write_screen_file`, `selectionString`, terminal search window
//! encoding, and the libghostty-vt formatter C API. This benchmark
//! measures formatting terminal contents that were built during setup
//! (outside the timed region) from a pre-generated VT stream.
//!
//! ## Input
//!
//! `--data` names a pre-generated VT byte stream (for example from
//! `ghostty-gen styled`). The stream is fed to a terminal of the
//! requested dimensions with unlimited scrollback during setup. The
//! resulting screen contents (scrollback included) are what each step
//! formats.
//!
//! ## Modes
//!
//! * `noop` performs no formatting and establishes loop/setup overhead.
//!   Subtract this from `format` timings when using hyperfine.
//! * `format` formats the configured region once per loop into a
//!   reusable buffer. Buffer growth happens on the first iteration only.
//! * `report` formats once and prints content/output sizes. It is for
//!   computing throughput (cells/s, bytes/s), not timing comparisons.
//!
//! ## Examples
//!
//! Build benchmarks in ReleaseFast mode:
//!
//!     zig build -Demit-bench -Doptimize=ReleaseFast -Demit-macos-app=false
//!
//! Generate a deterministic corpus, then measure:
//!
//!     ghostty-gen styled --seed=42 | head -c 640000 > /tmp/plain.vt
//!     hyperfine --warmup 3 \
//!       'ghostty-bench +terminal-formatter --mode=noop --data=/tmp/plain.vt' \
//!       'ghostty-bench +terminal-formatter --emit=plain --loops=50 --data=/tmp/plain.vt' \
//!       'ghostty-bench +terminal-formatter --emit=vt --loops=50 --data=/tmp/plain.vt'
const TerminalFormatter = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const formatterpkg = terminalpkg.formatter;
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const Terminal = terminalpkg.Terminal;
const Selection = terminalpkg.Selection;
const global = @import("../global.zig");

const log = std.log.scoped(.@"terminal-formatter-bench");

alloc: Allocator,
opts: Options,
terminal: ?Terminal = null,

/// Reused across steps so buffer growth is a one-time setup cost.
output: std.Io.Writer.Allocating,

/// Reused pin map storage for `--pin-map=true`.
pins: formatterpkg.PinMap.Map = .empty,

pub const Options = struct {
    /// Set by the shared CLI parser for string option ownership.
    _arena: ?std.heap.ArenaAllocator = null,

    /// Select the operation performed inside the timed benchmark step.
    mode: Mode = .format,

    /// The output format to emit.
    emit: Emit = .vt,

    /// The region of the screen to format.
    region: Region = .screen,

    /// Unwrap soft-wrapped lines.
    unwrap: bool = false,

    /// Track the source pin of every emitted byte. This exercises the
    /// (documented as expensive) pin_map path used by selectionString
    /// and search.
    @"pin-map": bool = false,

    /// Number of format operations per benchmark step. Increase this
    /// when the content is too small for stable hyperfine measurements.
    loops: u32 = 25,

    /// The size of the terminal. This affects wrapping and page sizes.
    @"terminal-rows": u16 = 24,
    @"terminal-cols": u16 = 80,

    /// Pre-generated VT stream fed to the terminal during setup. `-`
    /// reads stdin, although a regular file is recommended so identical
    /// state can be reused across runs. When unset, the terminal is
    /// empty.
    data: ?[]const u8 = null,

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};

pub const Mode = enum {
    /// Establish the benchmark loop and setup overhead.
    noop,

    /// Format the configured region once per loop.
    format,

    /// Print content and output sizes. Not a timing benchmark.
    report,

    /// Semantic verification, not a timing benchmark: format the
    /// terminal (must be `--emit=vt`), feed the output into a fresh
    /// terminal of the same dimensions, format that, and verify the
    /// two outputs converge to identical bytes. This proves the VT
    /// output faithfully reconstructs the terminal content even when
    /// the exact byte encoding changes.
    roundtrip,
};

pub const Emit = enum {
    plain,
    vt,
    html,

    fn format(self: Emit) formatterpkg.Format {
        return switch (self) {
            .plain => .plain,
            .vt => .vt,
            .html => .html,
        };
    }
};

pub const Region = enum {
    /// Everything: scrollback and active screen.
    screen,

    /// Only the active screen (bottom rows).
    active,

    /// Only the scrollback.
    history,
};

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*TerminalFormatter {
    const ptr = try alloc.create(TerminalFormatter);
    errdefer alloc.destroy(ptr);
    ptr.* = .{
        .alloc = alloc,
        .opts = opts,
        .output = .init(alloc),
    };
    return ptr;
}

pub fn destroy(self: *TerminalFormatter, alloc: Allocator) void {
    if (self.terminal) |*t| t.deinit(self.alloc);
    self.output.deinit();
    self.pins.deinit(self.alloc);
    alloc.destroy(self);
}

pub fn benchmark(self: *TerminalFormatter) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .format => stepFormat,
            .report => stepReport,
            .roundtrip => stepRoundtrip,
        },
        .setupFn = setup,
        .teardownFn = teardown,
    });
}

/// Build the terminal state every mode shares. All of this is outside
/// the timed region for `Benchmark`, but is included in whole-process
/// timings, hence the `noop` mode.
fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalFormatter = @ptrCast(@alignCast(ptr));
    self.setupImpl() catch |err| {
        log.warn("failed to prepare formatter benchmark err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn setupImpl(self: *TerminalFormatter) !void {
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
}

fn teardown(ptr: *anyopaque) void {
    const self: *TerminalFormatter = @ptrCast(@alignCast(ptr));
    if (self.terminal) |*t| t.deinit(self.alloc);
    self.terminal = null;
    self.output.shrinkRetainingCapacity(0);
    self.pins.clearRetainingCapacity();
}

/// Build the screen formatter matching our options. This mirrors how
/// Surface clipboard copy and write_screen_file construct formatters.
fn formatter(self: *TerminalFormatter) ?formatterpkg.ScreenFormatter {
    const screen = self.terminal.?.screens.active;

    var f: formatterpkg.ScreenFormatter = .init(screen, .{
        .emit = self.opts.emit.format(),
        .unwrap = self.opts.unwrap,
    });

    f.content = switch (self.opts.region) {
        .screen => .{ .selection = null },

        inline .active, .history => |region| content: {
            const tag: terminalpkg.point.Tag = switch (region) {
                .active => .active,
                .history => .history,
                .screen => unreachable,
            };
            const tl = screen.pages.getTopLeft(tag);
            const br = screen.pages.getBottomRight(tag) orelse return null;
            break :content .{ .selection = Selection.init(tl, br, false) };
        },
    };

    return f;
}

fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalFormatter = @ptrCast(@alignCast(ptr));
    for (0..self.opts.loops) |_| {
        std.mem.doNotOptimizeAway(self.output.written());
    }
}

fn stepFormat(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalFormatter = @ptrCast(@alignCast(ptr));
    for (0..self.opts.loops) |_| {
        self.output.shrinkRetainingCapacity(0);

        var f = self.formatter() orelse continue;
        if (self.opts.@"pin-map") {
            self.pins.clearRetainingCapacity();
            f.pin_map = .{ .alloc = self.alloc, .map = &self.pins };
        }

        f.format(&self.output.writer) catch |err| {
            log.warn("formatting failed err={}", .{err});
            return error.BenchmarkFailed;
        };
        std.mem.doNotOptimizeAway(self.output.written());
    }
}

/// Print the content dimensions and emitted output size. This shares
/// the formatting code with format mode but deliberately makes no
/// timing claims. Use it to compute cells/s and bytes/s from timings.
fn stepReport(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalFormatter = @ptrCast(@alignCast(ptr));

    self.output.shrinkRetainingCapacity(0);
    if (self.formatter()) |f_init| {
        var f = f_init;
        if (self.opts.@"pin-map") {
            self.pins.clearRetainingCapacity();
            f.pin_map = .{ .alloc = self.alloc, .map = &self.pins };
        }
        f.format(&self.output.writer) catch |err| {
            log.warn("formatting failed err={}", .{err});
            return error.BenchmarkFailed;
        };
    }

    // Count the total pages and rows in the pagelist.
    const screen = self.terminal.?.screens.active;
    var pages: usize = 0;
    var rows: usize = 0;
    {
        var node = screen.pages.pages.first;
        while (node) |n| : (node = n.next) {
            pages += 1;
            rows += n.page().size.rows;
        }
    }

    // Hash the output (and the pin coordinates, which are stable across
    // runs unlike the node pointers) so different implementations can be
    // checked for identical output.
    const out_hash = std.hash.Wyhash.hash(0, self.output.written());
    var pin_hasher = std.hash.Wyhash.init(0);
    for (self.pins.points.items) |coord| {
        const x: u16 = coord.x;
        const y: u16 = @intCast(coord.y);
        pin_hasher.update(std.mem.asBytes(&x));
        pin_hasher.update(std.mem.asBytes(&y));
    }

    std.debug.print(
        "terminal-formatter emit={s} region={s} pages={d} rows={d} " ++
            "cols={d} cells={d} out_bytes={d} pin_bytes={d} " ++
            "out_hash={x} pin_hash={x}\n",
        .{
            @tagName(self.opts.emit),
            @tagName(self.opts.region),
            pages,
            rows,
            self.opts.@"terminal-cols",
            rows * self.opts.@"terminal-cols",
            self.output.written().len,
            self.pins.count(),
            out_hash,
            pin_hasher.final(),
        },
    );

    // Pin map storage details on a separate line so the main report
    // line remains comparable across implementations.
    if (self.opts.@"pin-map") {
        std.debug.print(
            "terminal-formatter-pins points={d} nodes={d}\n",
            .{ self.pins.points.items.len, self.pins.nodes.items.len },
        );
    }
}

fn stepRoundtrip(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalFormatter = @ptrCast(@alignCast(ptr));
    self.stepRoundtripImpl() catch |err| {
        log.warn("roundtrip failed err={}", .{err});
        return error.BenchmarkFailed;
    };
}

/// Format the terminal, replay the output into a fresh terminal of the
/// same dimensions, format that, and require both outputs to be
/// identical. This verifies that the emitted VT sequences faithfully
/// reconstruct the terminal contents (text, styles, wrapping) without
/// requiring any specific byte encoding of the first output.
fn stepRoundtripImpl(self: *TerminalFormatter) !void {
    // Format the original terminal.
    self.output.shrinkRetainingCapacity(0);
    if (self.formatter()) |f_init| {
        var f = f_init;
        try f.format(&self.output.writer);
    }
    const first = self.output.written();

    // Replay into a fresh terminal.
    var t2 = try Terminal.init(global.io(), self.alloc, .{
        .cols = self.opts.@"terminal-cols",
        .rows = self.opts.@"terminal-rows",
        .max_scrollback_bytes = null,
        .max_scrollback_lines = null,
    });
    defer t2.deinit(self.alloc);
    {
        var stream = t2.vtStream();
        defer stream.deinit();
        stream.nextSlice(first);
    }

    // Format the replayed terminal identically.
    var out2: std.Io.Writer.Allocating = .init(self.alloc);
    defer out2.deinit();
    var f2: formatterpkg.ScreenFormatter = .init(t2.screens.active, .{
        .emit = self.opts.emit.format(),
        .unwrap = self.opts.unwrap,
    });
    try f2.format(&out2.writer);
    const second = out2.written();

    const equal = std.mem.eql(u8, first, second);
    std.debug.print(
        "terminal-formatter roundtrip emit={s} bytes={d} replay_bytes={d} equal={}\n",
        .{ @tagName(self.opts.emit), first.len, second.len, equal },
    );

    if (!equal) {
        // Find the first differing offset to ease debugging.
        const n = @min(first.len, second.len);
        var i: usize = 0;
        while (i < n and first[i] == second[i]) i += 1;
        std.debug.print(
            "terminal-formatter roundtrip mismatch offset={d} " ++
                "first={f} second={f}\n",
            .{
                i,
                std.zig.fmtString(first[i -| 32..@min(first.len, i + 32)]),
                std.zig.fmtString(second[i -| 32..@min(second.len, i + 32)]),
            },
        );
        return error.RoundtripMismatch;
    }
}

test TerminalFormatter {
    const testing = std.testing;
    const impl: *TerminalFormatter = try .create(testing.allocator, .{});
    defer impl.destroy(testing.allocator);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}

test "TerminalFormatter roundtrip" {
    const testing = std.testing;
    const impl: *TerminalFormatter = try .create(testing.allocator, .{
        .mode = .roundtrip,
        .@"terminal-rows" = 4,
        .@"terminal-cols" = 8,
    });
    defer impl.destroy(testing.allocator);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}

test "TerminalFormatter formats all emit formats and regions" {
    const testing = std.testing;

    inline for (.{ Emit.plain, Emit.vt, Emit.html }) |emit| {
        inline for (.{ Region.screen, Region.active, Region.history }) |region| {
            const impl: *TerminalFormatter = try .create(testing.allocator, .{
                .emit = emit,
                .region = region,
                .loops = 1,
                .@"terminal-rows" = 4,
                .@"terminal-cols" = 8,
            });
            defer impl.destroy(testing.allocator);

            const bench = impl.benchmark();
            _ = try bench.run(.once);
        }
    }
}

test "TerminalFormatter pin map" {
    const testing = std.testing;
    const impl: *TerminalFormatter = try .create(testing.allocator, .{
        .@"pin-map" = true,
        .loops = 1,
        .@"terminal-rows" = 4,
        .@"terminal-cols" = 8,
    });
    defer impl.destroy(testing.allocator);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
