const Ascii = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Bytes = @import("../Bytes.zig");

const log = std.log.scoped(.@"terminal-stream-bench");

pub const Options = struct {};

fn checkAsciiAlphabet(c: u8) bool {
    return switch (c) {
        ' ' => false,
        else => std.ascii.isPrint(c),
    };
}

pub const ascii = Bytes.generateAlphabet(checkAsciiAlphabet);

/// Create a new terminal stream handler for the given arguments.
pub fn create(
    alloc: Allocator,
    _: Options,
) !*Ascii {
    const ptr = try alloc.create(Ascii);
    errdefer alloc.destroy(ptr);
    return ptr;
}

pub fn destroy(self: *Ascii, alloc: Allocator) void {
    alloc.destroy(self);
}

pub fn run(_: *Ascii, writer: *std.Io.Writer, rand: std.Random) !void {
    var gen: Bytes = .{
        .rand = rand,
        .alphabet = ascii,
        .min_len = 1024,
        .max_len = 1024,
    };

    while (true) {
        _ = gen.write(writer) catch |err| {
            const Error = error{ WriteFailed, BrokenPipe } || @TypeOf(err);
            switch (@as(Error, err)) {
                error.BrokenPipe => return, // stdout closed
                error.WriteFailed => return, // fixed buffer full
                else => return err,
            }
        };
    }
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
