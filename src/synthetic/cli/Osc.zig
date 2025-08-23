const Osc = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const synthetic = @import("../main.zig");

const log = std.log.scoped(.@"terminal-stream-bench");

pub const Options = struct {
    /// Probability of generating a valid value.
    @"p-valid": f64 = 0.5,
};

opts: Options,

/// Create a new terminal stream handler for the given arguments.
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*Osc {
    const ptr = try alloc.create(Osc);
    errdefer alloc.destroy(ptr);
    ptr.* = .{ .opts = opts };
    return ptr;
}

pub fn destroy(self: *Osc, alloc: Allocator) void {
    alloc.destroy(self);
}

pub fn run(self: *Osc, writer: anytype, rand: std.Random) !void {
    var gen: synthetic.Osc = .{
        .rand = rand,
        .p_valid = self.opts.@"p-valid",
    };

    var buf: [1024]u8 = undefined;
    while (true) {
        const data = try gen.next(&buf);
        writer.writeAll(data) catch |err| {
            const Error = error{ NoSpaceLeft, BrokenPipe } || @TypeOf(err);
            switch (@as(Error, err)) {
                error.BrokenPipe => return, // stdout closed
                error.NoSpaceLeft => return, // fixed buffer full
                else => return err,
            }
        };
    }
}

test Osc {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *Osc = try .create(alloc, .{});
    defer impl.destroy(alloc);

    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try impl.run(writer, rand);
}
