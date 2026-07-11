//! This benchmark tests the throughput of APC sequence parsing
//! through the terminal stream: VT state machine dispatch, APC
//! protocol identification, and the protocol command parsers
//! (e.g. Kitty graphics). Completed commands are parsed and then
//! discarded; command execution (image decoding, storage) is not
//! included so this isolates the parsing path.
const ApcParser = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");

const log = std.log.scoped(.@"apc-parser-bench");

opts: Options,
stream: Stream,

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

const Stream = terminalpkg.Stream(Handler);

/// A stream handler that only processes APC actions, parsing and
/// immediately discarding completed commands.
const Handler = struct {
    alloc: Allocator,
    apc: terminalpkg.apc.Handler = .{},

    pub fn deinit(self: *Handler) void {
        self.apc.deinit();
    }

    pub fn vt(
        self: *Handler,
        comptime action: Stream.Action.Tag,
        value: Stream.Action.Value(action),
    ) void {
        switch (action) {
            .apc_start => self.apc.start(),
            .apc_put => self.apc.feed(self.alloc, value),
            .apc_put_slice => self.apc.feedSlice(self.alloc, value.bytes),
            .apc_end => if (self.apc.end()) |cmd| {
                var c = cmd;
                std.mem.doNotOptimizeAway(&c);
                c.deinit(self.alloc);
            },
            else => {},
        }
    }
};

/// Create a new APC parser benchmark for the given arguments.
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*ApcParser {
    const ptr = try alloc.create(ApcParser);
    errdefer alloc.destroy(ptr);
    ptr.* = .{
        .opts = opts,
        .stream = .init(.{ .alloc = alloc }),
    };
    return ptr;
}

pub fn destroy(self: *ApcParser, alloc: Allocator) void {
    self.stream.deinit();
    alloc.destroy(self);
}

pub fn benchmark(self: *ApcParser) Benchmark {
    return .init(self, .{
        .stepFn = step,
        .setupFn = setup,
        .teardownFn = teardown,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ApcParser = @ptrCast(@alignCast(ptr));

    // Open our data file to prepare for reading. We can do more
    // validation here eventually.
    assert(self.data_f == null);
    self.data_f = options.dataFile(self.opts.data) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn teardown(ptr: *anyopaque) void {
    const self: *ApcParser = @ptrCast(@alignCast(ptr));
    if (self.data_f) |f| {
        f.close();
        self.data_f = null;
    }
}

fn step(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ApcParser = @ptrCast(@alignCast(ptr));

    const f = self.data_f orelse return;

    var read_buf: [64 * 1024]u8 align(std.atomic.cache_line) = undefined;
    var f_reader = f.reader(&read_buf);
    const r = &f_reader.interface;

    // This buffer size matches the read buffer size used by the
    // real IO thread (see termio Exec.zig buffer_capacity) so that
    // the benchmark exercises the stream with realistic chunk sizes.
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = r.readSliceShort(&buf) catch {
            log.warn("error reading data file err={?}", .{f_reader.err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; // EOF reached
        self.stream.nextSlice(buf[0..n]);
    }
}

test ApcParser {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *ApcParser = try .create(alloc, .{});
    defer impl.destroy(alloc);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
