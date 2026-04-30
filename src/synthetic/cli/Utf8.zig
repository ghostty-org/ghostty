const Utf8 = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const synthetic = @import("../main.zig");

pub const Options = struct {
    /// Seed to use for deterministic generation. If unset, a time-based
    /// seed is used by the generic synthetic CLI.
    seed: ?u64 = null,

    /// Relative weight for choosing 1-byte UTF-8 sequences.
    @"weight-one": f64 = 1.0,

    /// Relative weight for choosing 2-byte UTF-8 sequences.
    @"weight-two": f64 = 1.0,

    /// Relative weight for choosing 3-byte UTF-8 sequences.
    @"weight-three": f64 = 1.0,

    /// Relative weight for choosing 4-byte UTF-8 sequences.
    @"weight-four": f64 = 1.0,

    /// Restrict ASCII codepoints to printable characters.
    @"ascii-printable-only": bool = false,

    /// Probability that an emitted sequence is malformed UTF-8.
    @"invalid-rate": f64 = 0.0,
};

opts: Options,

/// Create a new terminal stream handler for the given arguments.
pub fn create(
    alloc: Allocator,
    opts: Options,
) !*Utf8 {
    if (opts.@"invalid-rate" < 0 or opts.@"invalid-rate" > 1) {
        return error.InvalidValue;
    }

    const weights = [_]f64{
        opts.@"weight-one",
        opts.@"weight-two",
        opts.@"weight-three",
        opts.@"weight-four",
    };
    var weight_sum: f64 = 0;
    for (weights) |weight| {
        if (weight < 0) return error.InvalidValue;
        weight_sum += weight;
    }
    if (weight_sum <= 0) return error.InvalidValue;

    const ptr = try alloc.create(Utf8);
    errdefer alloc.destroy(ptr);
    ptr.* = .{ .opts = opts };
    return ptr;
}

pub fn destroy(self: *Utf8, alloc: Allocator) void {
    alloc.destroy(self);
}

pub fn run(self: *Utf8, writer: *std.Io.Writer, rand: std.Random) !void {
    var prng: ?std.Random.DefaultPrng = null;
    var gen_rand = rand;
    if (self.opts.seed) |seed| {
        prng = std.Random.DefaultPrng.init(seed);
        gen_rand = prng.?.random();
    }

    var gen: synthetic.Utf8 = .{
        .rand = gen_rand,
        .ascii_printable_only = self.opts.@"ascii-printable-only",
        .invalid_rate = self.opts.@"invalid-rate",
    };
    gen.p_length.set(.one, self.opts.@"weight-one");
    gen.p_length.set(.two, self.opts.@"weight-two");
    gen.p_length.set(.three, self.opts.@"weight-three");
    gen.p_length.set(.four, self.opts.@"weight-four");

    while (true) {
        gen.next(writer, 1024) catch |err| {
            const Error = error{ WriteFailed, BrokenPipe } || @TypeOf(err);
            switch (@as(Error, err)) {
                error.BrokenPipe => return, // stdout closed
                error.WriteFailed => return, // fixed buffer full
                else => return err,
            }
        };
    }
}

test Utf8 {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *Utf8 = try .create(alloc, .{
        .seed = 1,
    });
    defer impl.destroy(alloc);

    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();

    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try impl.run(&writer, rand);
    try testing.expectEqual(@as(usize, 1024), writer.buffered().len);
}
