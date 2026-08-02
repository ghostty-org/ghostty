const Bidi = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const synthetic = @import("../main.zig");

pub const Options = struct {
    /// Seed to use for deterministic generation. If unset, a time-based
    /// seed is used by the generic synthetic CLI.
    ///
    /// Always set this when generating a corpus for benchmarking, so the
    /// same bytes can be regenerated to compare revisions.
    seed: ?u64 = null,

    /// The script mix to generate. See `Profile` in `synthetic/Bidi.zig`.
    profile: synthetic.Bidi.Profile = .ascii,

    /// Wrap generated text at this many columns.
    cols: u16 = 120,
};

opts: Options,

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*Bidi {
    if (opts.cols == 0) return error.InvalidValue;

    const ptr = try alloc.create(Bidi);
    errdefer alloc.destroy(ptr);
    ptr.* = .{ .opts = opts };
    return ptr;
}

pub fn destroy(self: *Bidi, alloc: Allocator) void {
    alloc.destroy(self);
}

pub fn run(self: *Bidi, writer: *std.Io.Writer, rand: std.Random) !void {
    var prng: ?std.Random.DefaultPrng = null;
    var gen_rand = rand;
    if (self.opts.seed) |seed| {
        prng = std.Random.DefaultPrng.init(seed);
        gen_rand = prng.?.random();
    }

    var gen: synthetic.Bidi = .{
        .rand = gen_rand,
        .profile = self.opts.profile,
        .cols = self.opts.cols,
    };

    while (true) {
        gen.next(writer, 1024) catch |err| {
            const Error = error{ WriteFailed, BrokenPipe } || @TypeOf(err);
            switch (@as(Error, err)) {
                error.BrokenPipe => return, // stdout closed
                error.WriteFailed => return, // fixed buffer full
            }
        };
    }
}

test Bidi {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *Bidi = try .create(alloc, .{ .seed = 1, .profile = .mixed });
    defer impl.destroy(alloc);

    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();

    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try impl.run(&writer, rand);
    try testing.expectEqual(@as(usize, 1024), writer.buffered().len);
}

test "Bidi: rejects zero columns" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testing.expectError(error.InvalidValue, Bidi.create(alloc, .{ .cols = 0 }));
}
