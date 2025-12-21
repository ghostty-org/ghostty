//! This benchmark tests the throughput of the OSC parser.
const OscParser = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const Parser = @import("../terminal/osc.zig").Parser;
const log = std.log.scoped(.@"osc-parser-bench");

opts: Options,

/// The file, opened in the setup function.
data_f: ?std.fs.File = null,

parser: Parser,

pub const Options = struct {
    /// The data to read as a filepath. If this is "-" then
    /// we will read stdin. If this is unset, then we will
    /// do nothing (benchmark is a noop). It'd be more unixy to
    /// use stdin by default but I find that a hanging CLI command
    /// with no interaction is a bit annoying.
    data: ?[]const u8 = null,
};

/// Create a new terminal stream handler for the given arguments.
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*OscParser {
    const ptr = try alloc.create(OscParser);
    errdefer alloc.destroy(ptr);
    ptr.* = .{
        .opts = opts,
        .data_f = null,
        .parser = .init(alloc),
    };
    return ptr;
}

pub fn destroy(self: *OscParser, alloc: Allocator) void {
    self.parser.deinit();
    alloc.destroy(self);
}

pub fn benchmark(self: *OscParser) Benchmark {
    return .init(self, .{
        .stepFn = step,
        .setupFn = setup,
        .teardownFn = teardown,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *OscParser = @ptrCast(@alignCast(ptr));

    // Open our data file to prepare for reading. We can do more
    // validation here eventually.
    assert(self.data_f == null);
    self.data_f = options.dataFile(self.opts.data) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    };
    self.parser.reset();
}

fn teardown(ptr: *anyopaque) void {
    const self: *OscParser = @ptrCast(@alignCast(ptr));
    if (self.data_f) |f| {
        f.close();
        self.data_f = null;
    }
}

fn step(ptr: *anyopaque) Benchmark.Error!void {
    const self: *OscParser = @ptrCast(@alignCast(ptr));

    const f = self.data_f orelse return;
    var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var r = f.reader(&read_buf);

    var osc_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    while (true) {
        r.interface.fill(@bitSizeOf(usize) / 8) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return error.BenchmarkFailed,
        };
        const len = r.interface.takeInt(usize, .little) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return error.BenchmarkFailed,
        };

        if (len > osc_buf.len) return error.BenchmarkFailed;

        r.interface.readSliceAll(osc_buf[0..len]) catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return error.BenchmarkFailed,
        };

        for (osc_buf[0..len]) |c| self.parser.next(c);
        _ = self.parser.end(std.ascii.control_code.bel);
        self.parser.reset();
    }
}

test OscParser {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *OscParser = try .create(alloc, .{});
    defer impl.destroy(alloc);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
