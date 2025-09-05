const Ascii = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const synthetic = @import("../main.zig");

const log = std.log.scoped(.@"terminal-stream-bench");

pub const Options = struct {};

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

pub fn run(self: *Ascii, writer: *std.Io.Writer, rand: std.Random) !void {
    _ = self;

    var gen: synthetic.Bytes = .{
        .rand = rand,
        .alphabet = synthetic.Bytes.Alphabet.ascii,
    };

    var buf: [1024]u8 = undefined;
    while (true) {
        const data = try gen.next(&buf);
        writer.writeAll(data) catch |err| {
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
