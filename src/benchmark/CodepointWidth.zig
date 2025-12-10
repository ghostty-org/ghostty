//! This benchmark tests the throughput of codepoint width calculation.
//! This is a common operation in terminal character printing and the
//! motivating factor to write this benchmark was discovering that our
//! codepoint width function was 30% of the runtime of every character
//! print.
const CodepointWidth = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const UTF8Decoder = @import("../terminal/UTF8Decoder.zig");
const simd = @import("../simd/main.zig");
const table = @import("../unicode/main.zig").table;

const log = std.log.scoped(.@"terminal-stream-bench");

opts: Options,

/// The file, opened in the setup function.
data_f: ?std.fs.File = null,

pub const Options = struct {
    /// The type of codepoint width calculation to use.
    mode: Mode = .noop,

    /// The data to read as a filepath. If this is "-" then
    /// we will read stdin. If this is unset, then we will
    /// do nothing (benchmark is a noop). It'd be more unixy to
    /// use stdin by default but I find that a hanging CLI command
    /// with no interaction is a bit annoying.
    data: ?[]const u8 = null,
};

pub const Mode = enum {
    /// The baseline mode copies the data from the fd into a buffer. This
    /// is used to show the minimal overhead of reading the fd into memory
    /// and establishes a baseline for the other modes.
    noop,

    /// libc wcwidth
    wcwidth,

    /// Our SIMD implementation.
    simd,

    /// Test our lookup table implementation.
    table,
};

/// Create a new terminal stream handler for the given arguments.
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*CodepointWidth {
    const ptr = try alloc.create(CodepointWidth);
    errdefer alloc.destroy(ptr);
    ptr.* = .{ .opts = opts };
    return ptr;
}

pub fn destroy(self: *CodepointWidth, alloc: Allocator) void {
    alloc.destroy(self);
}

pub fn benchmark(self: *CodepointWidth) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .noop => stepNoop,
            .wcwidth => stepWcwidth,
            .table => stepTable,
            .simd => stepSimd,
        },
        .setupFn = setup,
        .teardownFn = teardown,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *CodepointWidth = @ptrCast(@alignCast(ptr));

    // Open our data file to prepare for reading. We can do more
    // validation here eventually.
    assert(self.data_f == null);
    self.data_f = options.dataFile(self.opts.data) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn teardown(ptr: *anyopaque) void {
    const self: *CodepointWidth = @ptrCast(@alignCast(ptr));
    if (self.data_f) |f| {
        f.close();
        self.data_f = null;
    }
}

fn stepNoop(ptr: *anyopaque) Benchmark.Error!void {
    _ = ptr;
}

extern "c" fn wcwidth(c: u32) c_int;

fn stepWcwidth(ptr: *anyopaque) Benchmark.Error!void {
    const self: *CodepointWidth = @ptrCast(@alignCast(ptr));

    const f = self.data_f orelse return;
    var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var f_reader = f.reader(&read_buf);
    var r = &f_reader.interface;

    var d: UTF8Decoder = .{};
    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    while (true) {
        const n = r.readSliceShort(&buf) catch {
            log.warn("error reading data file err={?}", .{f_reader.err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; // EOF reached

        for (buf[0..n]) |c| {
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp| {
                std.mem.doNotOptimizeAway(wcwidth(cp));
            }
        }
    }
}

fn stepTable(ptr: *anyopaque) Benchmark.Error!void {
    const self: *CodepointWidth = @ptrCast(@alignCast(ptr));

    const f = self.data_f orelse return;
    var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var f_reader = f.reader(&read_buf);
    var r = &f_reader.interface;

    var d: UTF8Decoder = .{};
    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    while (true) {
        const n = r.readSliceShort(&buf) catch {
            log.warn("error reading data file err={?}", .{f_reader.err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; // EOF reached

        for (buf[0..n]) |c| {
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp| {
                // This is the same trick we do in terminal.zig so we
                // keep it here.
                std.mem.doNotOptimizeAway(if (cp <= 0xFF)
                    1
                else
                    table.get(@intCast(cp)).width);
            }
        }
    }
}

fn stepSimd(ptr: *anyopaque) Benchmark.Error!void {
    const self: *CodepointWidth = @ptrCast(@alignCast(ptr));

    const f = self.data_f orelse return;
    var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var f_reader = f.reader(&read_buf);
    var r = &f_reader.interface;

    var d: UTF8Decoder = .{};
    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    while (true) {
        const n = r.readSliceShort(&buf) catch {
            log.warn("error reading data file err={?}", .{f_reader.err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; // EOF reached

        for (buf[0..n]) |c| {
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp| {
                std.mem.doNotOptimizeAway(simd.codepointWidth(cp));
            }
        }
    }
}

test CodepointWidth {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *CodepointWidth = try .create(alloc, .{});
    defer impl.destroy(alloc);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
