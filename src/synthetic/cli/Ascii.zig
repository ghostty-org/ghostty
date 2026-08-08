const Ascii = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Bytes = @import("../Bytes.zig");

const log = std.log.scoped(.@"terminal-stream-bench");

pub const Options = struct {
    /// When nonzero, emit lines whose printable length is uniformly
    /// distributed in `[line-min, line-max]`, each terminated by CR LF.
    /// When zero (the default), emit an unbroken stream of printable
    /// bytes that relies on terminal wrapping.
    @"line-min": usize = 0,
    @"line-max": usize = 0,
};

fn checkAsciiAlphabet(c: u8) bool {
    return switch (c) {
        ' ' => false,
        else => std.ascii.isPrint(c),
    };
}

pub const ascii = Bytes.generateAlphabet(checkAsciiAlphabet);

opts: Options,

/// Create a new terminal stream handler for the given arguments.
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*Ascii {
    const ptr = try alloc.create(Ascii);
    errdefer alloc.destroy(ptr);
    ptr.* = .{ .opts = opts };
    return ptr;
}

pub fn destroy(self: *Ascii, alloc: Allocator) void {
    alloc.destroy(self);
}

pub fn run(self: *Ascii, writer: *std.Io.Writer, rand: std.Random) !void {
    const line_max = @max(self.opts.@"line-min", self.opts.@"line-max");
    const lines = line_max > 0;
    var gen: Bytes = .{
        .rand = rand,
        .alphabet = ascii,
        .min_len = if (lines) @max(self.opts.@"line-min", 1) else 1024,
        .max_len = if (lines) line_max else 1024,
    };

    while (true) {
        writeChunk(&gen, writer, lines) catch |err| {
            const Error = error{ WriteFailed, BrokenPipe } || @TypeOf(err);
            switch (@as(Error, err)) {
                error.BrokenPipe => return, // stdout closed
                error.WriteFailed => return, // fixed buffer full
            }
        };
    }
}

fn writeChunk(
    gen: *const Bytes,
    writer: *std.Io.Writer,
    lines: bool,
) std.Io.Writer.Error!void {
    _ = try gen.write(writer);
    if (lines) try writer.writeAll("\r\n");
}

test Ascii {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *Ascii = try .create(alloc, .{});
    defer impl.destroy(alloc);

    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();

    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try impl.run(&writer, rand);
}

test "Ascii lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *Ascii = try .create(alloc, .{
        .@"line-min" = 5,
        .@"line-max" = 20,
    });
    defer impl.destroy(alloc);

    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();

    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try impl.run(&writer, rand);

    // Every emitted line respects the configured bounds.
    var it = std.mem.splitSequence(u8, writer.buffered(), "\r\n");
    while (it.next()) |line| {
        // The fixed buffer may end mid-line.
        if (it.rest().len == 0) break;
        try testing.expect(line.len >= 5);
        try testing.expect(line.len <= 20);
    }
}
