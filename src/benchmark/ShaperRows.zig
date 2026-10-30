//! This benchmark tests turning terminal rows into text runs and shaping
//! them, which the renderer does for every dirty row on every frame. The
//! renderer caches shaped runs but not run iteration, so `runs` measures
//! the per-frame cost a cache can't hide.
const ShaperRows = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const global = @import("../global.zig");
const font = @import("../font/main.zig");
const terminalpkg = @import("../terminal/main.zig");
const Terminal = terminalpkg.Terminal;

const log = std.log.scoped(.@"shaper-rows-bench");

/// Latin first, then an Arabic-script face, so RTL input is shaped by a
/// real font instead of a fallback.
const faces = [_][:0]const u8{ font.embedded.inconsolata, font.embedded.arabic };

alloc: Allocator,
opts: Options,
lib: font.Library,
grid: *font.SharedGrid,
shaper: font.Shaper,
terminal: Terminal,
state: terminalpkg.RenderState = .empty,

pub const Options = struct {
    mode: Mode = .shape,

    /// Every row of the screen is processed on each iteration.
    @"terminal-rows": u16 = 80,
    @"terminal-cols": u16 = 120,

    /// Passes over the screen, each roughly one full-screen frame rebuild.
    iterations: u32 = 200,

    /// File written to the terminal during the untimed setup. "-" is stdin.
    data: ?[]const u8 = null,
};

pub const Mode = enum {
    /// Split rows into runs only.
    runs,

    /// Also shape every run.
    shape,
};

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*ShaperRows {
    var lib = try font.Library.init(alloc);
    errdefer lib.deinit();

    var c = font.Collection.init();
    c.load_options = .{ .library = lib };
    for (faces) |face| {
        _ = try c.add(alloc, try .init(
            lib,
            face,
            .{ .size = .{ .points = 12 } },
        ), .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        });
    }

    const grid = try alloc.create(font.SharedGrid);
    errdefer alloc.destroy(grid);
    grid.* = try .init(alloc, .{ .collection = c });
    errdefer grid.deinit(alloc);

    var shaper = try font.Shaper.init(alloc, .{});
    errdefer shaper.deinit();

    const ptr = try alloc.create(ShaperRows);
    errdefer alloc.destroy(ptr);
    ptr.* = .{
        .alloc = alloc,
        .opts = opts,
        .lib = lib,
        .grid = grid,
        .shaper = shaper,
        .terminal = try .init(global.io(), alloc, .{
            .rows = opts.@"terminal-rows",
            .cols = opts.@"terminal-cols",
        }),
    };

    return ptr;
}

pub fn destroy(self: *ShaperRows, alloc: Allocator) void {
    self.state.deinit(alloc);
    self.terminal.deinit(alloc);
    self.shaper.deinit();
    self.grid.deinit(alloc);
    alloc.destroy(self.grid);
    self.lib.deinit();
    alloc.destroy(self);
}

pub fn benchmark(self: *ShaperRows) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            inline else => |mode| step(mode),
        },
        .setupFn = setup,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ShaperRows = @ptrCast(@alignCast(ptr));

    self.terminal.fullReset();

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
        if (n == 0) break;
        stream.nextSlice(buf[0..n]);
    }

    self.state.update(self.alloc, &self.terminal) catch |err| {
        log.warn("error updating render state err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn step(comptime mode: Mode) *const fn (*anyopaque) Benchmark.Error!void {
    return struct {
        fn run(ptr: *anyopaque) Benchmark.Error!void {
            const self: *ShaperRows = @ptrCast(@alignCast(ptr));
            self.processRows(mode) catch |err| {
                log.warn("error processing rows mode={} err={}", .{ mode, err });
                return error.BenchmarkFailed;
            };
        }
    }.run;
}

fn processRows(self: *ShaperRows, comptime mode: Mode) !void {
    const rows = self.state.row_data.items(.cells);
    for (0..self.opts.iterations) |_| {
        for (rows) |cells| {
            var it = self.shaper.runIterator(.{
                .grid = self.grid,
                .cells = cells.slice(),
            });
            while (try it.next(self.alloc)) |run| switch (mode) {
                .runs => std.mem.doNotOptimizeAway(run),
                .shape => std.mem.doNotOptimizeAway(try self.shaper.shape(run)),
            };
        }
    }
}

test ShaperRows {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *ShaperRows = try .create(alloc, .{});
    defer impl.destroy(alloc);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
