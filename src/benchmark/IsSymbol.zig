//! This benchmark tests the throughput of grapheme break calculation.
//! This is a common operation in terminal character printing for terminals
//! that support grapheme clustering.
const IsSymbol = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const UTF8Decoder = @import("../terminal/UTF8Decoder.zig");
const uucode = @import("uucode");
const symbols_table = @import("../unicode/symbols_table.zig").table;

const log = std.log.scoped(.@"is-symbol-bench");

opts: Options,

/// The file, opened in the setup function.
data_f: ?std.fs.File = null,

pub const Options = struct {
    /// Which test to run.
    mode: Mode = .uucode,

    /// The data to read as a filepath. If this is "-" then
    /// we will read stdin. If this is unset, then we will
    /// do nothing (benchmark is a noop). It'd be more unixy to
    /// use stdin by default but I find that a hanging CLI command
    /// with no interaction is a bit annoying.
    data: ?[]const u8 = null,
};

pub const Mode = enum {
    /// uucode implementation
    uucode,

    /// Ghostty's table-based approach.
    table,
};

/// Create a new terminal stream handler for the given arguments.
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*IsSymbol {
    const ptr = try alloc.create(IsSymbol);
    errdefer alloc.destroy(ptr);
    ptr.* = .{ .opts = opts };
    return ptr;
}

pub fn destroy(self: *IsSymbol, alloc: Allocator) void {
    alloc.destroy(self);
}

pub fn benchmark(self: *IsSymbol) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .uucode => stepUucode,
            .table => stepTable,
        },
        .setupFn = setup,
        .teardownFn = teardown,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *IsSymbol = @ptrCast(@alignCast(ptr));

    // Open our data file to prepare for reading. We can do more
    // validation here eventually.
    assert(self.data_f == null);
    self.data_f = options.dataFile(self.opts.data) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn teardown(ptr: *anyopaque) void {
    const self: *IsSymbol = @ptrCast(@alignCast(ptr));
    if (self.data_f) |f| {
        f.close();
        self.data_f = null;
    }
}

fn stepUucode(ptr: *anyopaque) Benchmark.Error!void {
    const self: *IsSymbol = @ptrCast(@alignCast(ptr));

    const f = self.data_f orelse return;
    var r = std.io.bufferedReader(f.reader());
    var d: UTF8Decoder = .{};
    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    while (true) {
        const n = r.read(&buf) catch |err| {
            log.warn("error reading data file err={}", .{err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; // EOF reached

        for (buf[0..n]) |c| {
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp| {
                std.mem.doNotOptimizeAway(uucode.get(.is_symbol, cp));
            }
        }
    }
}

fn stepTable(ptr: *anyopaque) Benchmark.Error!void {
    const self: *IsSymbol = @ptrCast(@alignCast(ptr));

    const f = self.data_f orelse return;
    var r = std.io.bufferedReader(f.reader());
    var d: UTF8Decoder = .{};
    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    while (true) {
        const n = r.read(&buf) catch |err| {
            log.warn("error reading data file err={}", .{err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; // EOF reached

        for (buf[0..n]) |c| {
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp| {
                std.mem.doNotOptimizeAway(symbols_table.get(cp));
            }
        }
    }
}

test IsSymbol {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *IsSymbol = try .create(alloc, .{});
    defer impl.destroy(alloc);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
