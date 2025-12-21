const Osc = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const synthetic = @import("../main.zig");

const log = std.log.scoped(.@"terminal-stream-bench");

pub const Options = struct {
    /// Probability of generating a valid value.
    @"p-valid": f64 = 0.5,

    style: enum {
        /// Write all OSC data, including ESC ] and ST for end-to-end tests
        streaming,
        /// Only write data, prefixed with a length, used for testing just the
        /// OSC parser.
        parser,
    } = .streaming,
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

pub fn run(self: *Osc, writer: *std.Io.Writer, rand: std.Random) !void {
    var gen: synthetic.Osc = .{
        .rand = rand,
        .p_valid = self.opts.@"p-valid",
    };

    var buf: [1024]u8 = undefined;
    while (true) {
        var fixed: std.Io.Writer = .fixed(&buf);
        try gen.next(&fixed, buf.len);
        const data = fixed.buffered();
        switch (self.opts.style) {
            .streaming => {
                writer.writeAll(data) catch |err| switch (err) {
                    error.WriteFailed => return,
                };
            },
            .parser => {
                writer.writeInt(usize, data.len - 3, .little) catch |err| switch (err) {
                    error.WriteFailed => return,
                };
                writer.writeAll(data[2 .. data.len - 1]) catch |err| switch (err) {
                    error.WriteFailed => return,
                };
            },
        }
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
    var writer: std.Io.Writer = .fixed(&buf);
    try impl.run(&writer, rand);
}
