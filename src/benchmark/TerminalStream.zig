//! This benchmark tests the performance of the terminal stream
//! handler from input to terminal state update. This is useful to
//! test general throughput of VT parsing and handling.
//!
//! Note that the handler used for this benchmark isn't the full
//! terminal handler, since that requires a significant amount of
//! state. This is a simplified version that only handles specific
//! terminal operations like printing characters. We should expand
//! this to include more operations to improve the accuracy of the
//! benchmark.
//!
//! It is a fairly broad benchmark that can be used to determine
//! if we need to optimize something more specific (e.g. the parser).
const TerminalStream = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const Terminal = terminalpkg.Terminal;
const Stream = terminalpkg.Stream(*Handler);

const log = std.log.scoped(.@"terminal-stream-bench");

opts: Options,
terminal: Terminal,
handler: Handler,
stream: Stream,

/// The file, opened in the setup function.
data_f: ?std.fs.File = null,

pub const Options = struct {
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
    data: ?[]const u8 = null,
};

/// Create a new terminal stream handler for the given arguments.
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*TerminalStream {
    const ptr = try alloc.create(TerminalStream);
    errdefer alloc.destroy(ptr);

    ptr.* = .{
        .opts = opts,
        .terminal = try .init(alloc, .{
            .rows = opts.@"terminal-rows",
            .cols = opts.@"terminal-cols",
        }),
        .handler = .{ .t = &ptr.terminal },
        .stream = .init(&ptr.handler),
    };

    return ptr;
}

pub fn destroy(self: *TerminalStream, alloc: Allocator) void {
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}

pub fn benchmark(self: *TerminalStream) Benchmark {
    return .init(self, .{
        .stepFn = step,
        .setupFn = setup,
        .teardownFn = teardown,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalStream = @ptrCast(@alignCast(ptr));

    // Always reset our terminal state
    self.terminal.fullReset();

    // Open our data file to prepare for reading. We can do more
    // validation here eventually.
    assert(self.data_f == null);
    self.data_f = options.dataFile(self.opts.data) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn teardown(ptr: *anyopaque) void {
    const self: *TerminalStream = @ptrCast(@alignCast(ptr));
    if (self.data_f) |f| {
        f.close();
        self.data_f = null;
    }
}

fn step(ptr: *anyopaque) Benchmark.Error!void {
    const self: *TerminalStream = @ptrCast(@alignCast(ptr));

    // Get our buffered reader so we're not predominantly
    // waiting on file IO. It'd be better to move this fully into
    // memory. If we're IO bound though that should show up on
    // the benchmark results and... I know writing this that we
    // aren't currently IO bound.
    const f = self.data_f orelse return;
    var r = std.io.bufferedReader(f.reader());

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = r.read(&buf) catch |err| {
            log.warn("error reading data file err={}", .{err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; // EOF reached
        const chunk = buf[0..n];
        self.stream.nextSlice(chunk) catch |err| {
            log.warn("error processing data file chunk err={}", .{err});
            return error.BenchmarkFailed;
        };
    }
}

/// Implements the handler interface for the terminal.Stream.
/// We should expand this to include more operations to make
/// our benchmark more realistic.
const Handler = struct {
    t: *Terminal,

    pub fn print(self: *Handler, cp: u21) !void {
        try self.t.print(cp);
    }
};

test TerminalStream {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *TerminalStream = try .create(alloc, .{});
    defer impl.destroy(alloc);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
