//! This benchmark tests the throughput of the VT stream. It has a few
//! modes in order to test different methods of stream processing. It
//! provides a "noop" mode to give us the `memcpy` speed.
//!
//! This will consume all of the available stdin, so you should run it
//! with `head` in a pipe to restrict. For example, to test ASCII input:
//!
//!   bench-stream --mode=gen-ascii | head -c 50M | bench-stream --mode=simd
//!

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ziglyph = @import("ziglyph");
const cli = @import("../cli.zig");
const terminal = @import("../terminal/main.zig");
const terminalnew = @import("../terminal/new/main.zig");

const Args = struct {
    mode: Mode = .noop,

    /// The PRNG seed used by the input generators.
    /// -1 uses a random seed (default)
    seed: i64 = -1,

    /// Process input with a real terminal. This will be MUCH slower than
    /// the other modes because it has to maintain terminal state but will
    /// help get more realistic numbers.
    terminal: Terminal = .none,
    @"terminal-rows": usize = 80,
    @"terminal-cols": usize = 120,

    /// The size for read buffers. Doesn't usually need to be changed. The
    /// main point is to make this runtime known so we can avoid compiler
    /// optimizations.
    @"buffer-size": usize = 4096,

    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    pub fn deinit(self: *Args) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    const Terminal = enum { none, old, new };
};

const Mode = enum {
    // Do nothing, just read from stdin into a stack-allocated buffer.
    // This is used to benchmark our base-case: it gives us our maximum
    // throughput on a basic read.
    noop,

    // These benchmark the throughput of the terminal stream parsing
    // with and without SIMD. The "simd" option will use whatever is best
    // for the running platform.
    //
    // Note that these run through the full VT parser but do not apply
    // the operations to terminal state, so there is no terminal state
    // overhead.
    scalar,
    simd,

    // Generate an infinite stream of random printable ASCII characters.
    @"gen-ascii",

    // Generate an infinite stream of random printable unicode characters.
    @"gen-utf8",

    // Generate an infinite stream of arbitrary random bytes.
    @"gen-rand",
};

pub const std_options: std.Options = .{
    .log_level = .debug,
};

pub fn main() !void {
    // We want to use the c allocator because it is much faster than GPA.
    const alloc = std.heap.c_allocator;

    // Parse our args
    var args: Args = .{};
    defer args.deinit();
    {
        var iter = try std.process.argsWithAllocator(alloc);
        defer iter.deinit();
        try cli.args.parse(Args, alloc, &args, &iter);
    }

    const reader = std.io.getStdIn().reader();
    const writer = std.io.getStdOut().writer();
    const buf = try alloc.alloc(u8, args.@"buffer-size");

    if (false) {
        const f = try std.fs.cwd().openFile("/tmp/ghostty_bench_data", .{});
        defer f.close();
        const r = f.reader();
        const TerminalStream = terminal.Stream(*NewTerminalHandler);
        var t = try terminalnew.Terminal.init(
            alloc,
            @intCast(args.@"terminal-cols"),
            @intCast(args.@"terminal-rows"),
        );
        var handler: NewTerminalHandler = .{ .t = &t };
        var stream: TerminalStream = .{ .handler = &handler };
        try benchSimd(r, &stream, buf);
        return;
    }

    const seed: u64 = if (args.seed >= 0) @bitCast(args.seed) else @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));

    // Handle the modes that do not depend on terminal state first.
    switch (args.mode) {
        .@"gen-ascii" => try genAscii(writer, seed),
        .@"gen-utf8" => try genUtf8(writer, seed),
        .@"gen-rand" => try genRand(writer, seed),
        .noop => try benchNoop(reader, buf),

        // Handle the ones that depend on terminal state next
        inline .scalar,
        .simd,
        => |tag| switch (args.terminal) {
            .old => {
                const TerminalStream = terminal.Stream(*TerminalHandler);
                var t = try terminal.Terminal.init(
                    alloc,
                    args.@"terminal-cols",
                    args.@"terminal-rows",
                );
                var handler: TerminalHandler = .{ .t = &t };
                var stream: TerminalStream = .{ .handler = &handler };
                switch (tag) {
                    .scalar => try benchScalar(reader, &stream, buf),
                    .simd => try benchSimd(reader, &stream, buf),
                    else => @compileError("missing case"),
                }
            },

            .new => {
                const TerminalStream = terminal.Stream(*NewTerminalHandler);
                var t = try terminalnew.Terminal.init(
                    alloc,
                    @intCast(args.@"terminal-cols"),
                    @intCast(args.@"terminal-rows"),
                );
                var handler: NewTerminalHandler = .{ .t = &t };
                var stream: TerminalStream = .{ .handler = &handler };
                switch (tag) {
                    .scalar => try benchScalar(reader, &stream, buf),
                    .simd => try benchSimd(reader, &stream, buf),
                    else => @compileError("missing case"),
                }
            },

            .none => {
                var stream: terminal.Stream(NoopHandler) = .{ .handler = .{} };
                switch (tag) {
                    .scalar => try benchScalar(reader, &stream, buf),
                    .simd => try benchSimd(reader, &stream, buf),
                    else => @compileError("missing case"),
                }
            },
        },
    }
}

/// Generates an infinite stream of random printable ASCII characters.
/// This has no control characters in it at all.
fn genAscii(writer: anytype, seed: u64) !void {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|;':\\\",./<>?`~";
    try genData(writer, alphabet, seed);
}

/// Generates an infinite stream of bytes from the given alphabet.
fn genData(writer: anytype, alphabet: []const u8, seed: u64) !void {
    var prng = std.rand.DefaultPrng.init(seed);
    const rnd = prng.random();
    var buf: [1024]u8 = undefined;
    while (true) {
        for (&buf) |*c| {
            const idx = rnd.uintLessThanBiased(usize, alphabet.len);
            c.* = alphabet[idx];
        }

        writer.writeAll(&buf) catch |err| switch (err) {
            error.BrokenPipe => return, // stdout closed
            else => return err,
        };
    }
}

fn genUtf8(writer: anytype, seed: u64) !void {
    var prng = std.rand.DefaultPrng.init(seed);
    const rnd = prng.random();
    var buf: [1024]u8 = undefined;
    while (true) {
        var i: usize = 0;
        while (i <= buf.len - 4) {
            const cp: u18 = while (true) {
                const cp = rnd.int(u18);
                if (ziglyph.isPrint(cp)) break cp;
            };

            i += try std.unicode.utf8Encode(cp, buf[i..]);
        }

        writer.writeAll(buf[0..i]) catch |err| switch (err) {
            error.BrokenPipe => return, // stdout closed
            else => return err,
        };
    }
}

fn genRand(writer: anytype, seed: u64) !void {
    var prng = std.rand.DefaultPrng.init(seed);
    const rnd = prng.random();
    var buf: [1024]u8 = undefined;
    while (true) {
        rnd.bytes(&buf);

        writer.writeAll(&buf) catch |err| switch (err) {
            error.BrokenPipe => return, // stdout closed
            else => return err,
        };
    }
}

noinline fn benchNoop(reader: anytype, buf: []u8) !void {
    var total: usize = 0;
    while (true) {
        const n = try reader.readAll(buf);
        if (n == 0) break;
        total += n;
    }

    std.log.info("total bytes len={}", .{total});
}

noinline fn benchScalar(
    reader: anytype,
    stream: anytype,
    buf: []u8,
) !void {
    while (true) {
        const n = try reader.read(buf);
        if (n == 0) break;

        // Using stream.next directly with a for loop applies a naive
        // scalar approach.
        for (buf[0..n]) |c| try stream.next(c);
    }
}

noinline fn benchSimd(
    reader: anytype,
    stream: anytype,
    buf: []u8,
) !void {
    while (true) {
        const n = try reader.read(buf);
        if (n == 0) break;
        try stream.nextSlice(buf[0..n]);
    }
}

const NoopHandler = struct {
    pub fn print(self: NoopHandler, cp: u21) !void {
        _ = self;
        _ = cp;
    }
};

const TerminalHandler = struct {
    t: *terminal.Terminal,

    pub fn print(self: *TerminalHandler, cp: u21) !void {
        try self.t.print(cp);
    }
};

const NewTerminalHandler = struct {
    t: *terminalnew.Terminal,

    pub fn print(self: *NewTerminalHandler, cp: u21) !void {
        try self.t.print(cp);
    }
};
