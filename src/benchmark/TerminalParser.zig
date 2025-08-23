//! This benchmark tests the throughput of the terminal escape code parser.
const TerminalParser = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");

const log = std.log.scoped(.@"terminal-stream-bench");

opts: Options,

/// The file, opened in the setup function.
data_f: ?std.fs.File = null,

pub const Options = struct {
    /// The data to read as a filepath. If this is "-" then
    /// we will read stdin. If this is unset, then we will
    /// do nothing (benchmark is a noop). It'd be more unixy to
    /// use stdin by default but I find that a hanging CLI command
    /// with no interaction is a bit annoying.
    data: ?[]const u8 = null,
};

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*TerminalParser {
    const ptr = try alloc.create(TerminalParser);
    errdefer alloc.destroy(ptr);
    ptr.* = .{ .opts = opts };
    return ptr;
}

pub fn destroy(self: *TerminalParser, alloc: Allocator) void {
    alloc.destroy(self);
}

pub fn benchmark(self: *TerminalParser) Benchmark {
    return .init(self, .{
        .stepFn = step,
        .setupFn = setup,
        .teardownFn = teardown,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalParser = @ptrCast(@alignCast(ptr));

    // Open our data file to prepare for reading. We can do more
    // validation here eventually.
    assert(self.data_f == null);
    self.data_f = options.dataFile(self.opts.data) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn teardown(ptr: *anyopaque) void {
    const self: *TerminalParser = @ptrCast(@alignCast(ptr));
    if (self.data_f) |f| {
        f.close();
        self.data_f = null;
    }
}

fn step(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalParser = @ptrCast(@alignCast(ptr));

    // Get our buffered reader so we're not predominantly
    // waiting on file IO. It'd be better to move this fully into
    // memory. If we're IO bound though that should show up on
    // the benchmark results and... I know writing this that we
    // aren't currently IO bound.
    const f = self.data_f orelse return;
    var r = std.io.bufferedReader(f.reader());

    var p: terminalpkg.Parser = .init();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = r.read(&buf) catch |err| {
            log.warn("error reading data file err={}", .{err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; // EOF reached
        for (buf[0..n]) |c| {
            const actions = p.next(c);
            //std.log.warn("actions={any}", .{actions});
            _ = actions;
        }
    }
}

test TerminalParser {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *TerminalParser = try .create(alloc, .{});
    defer impl.destroy(alloc);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
