//! Generates lines where every character is inside an OSC 8 hyperlink:
//!
//!   ESC ] 8 ; ; https://example.com/0 ESC \ TdKN ESC ] 8 ; ; ESC \ CR LF
//!
//! The terminal stores each link separately, even when URIs repeat, so
//! this input stresses hyperlink storage far more than
//! `styled --osc8-rate`, which only links some runs of text.
//!
//! It writes until its output closes, so pipe it through `head -c`.
//!
//! Examples:
//!
//!   # Short lines with one URI, the hardest case
//!   ghostty-gen +hyperlink --seed=42 --line-min=4 --line-max=4 \
//!     | head -c 8388608 > links.vt
//!
//!   # Full-width lines across 1000 URIs
//!   ghostty-gen +hyperlink --seed=42 --uris=1000 \
//!     --line-min=120 --line-max=120 | head -c 8388608 > links-wide.vt
const Hyperlink = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Seed to use for deterministic generation. If unset, a time-based
    /// seed is used by the generic synthetic CLI.
    seed: ?u64 = null,

    /// How many distinct URIs to use (`https://example.com/0`, `/1`, ...).
    /// Each line picks one at random. Must be at least 1.
    uris: u32 = 1,

    /// Characters per line, chosen at random from this inclusive range.
    /// `line-min` must be at least 1.
    @"line-min": usize = 40,
    @"line-max": usize = 80,
};

opts: Options,

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*Hyperlink {
    if (opts.uris == 0) return error.InvalidValue;
    if (opts.@"line-min" == 0) return error.InvalidValue;

    const ptr = try alloc.create(Hyperlink);
    errdefer alloc.destroy(ptr);
    ptr.* = .{ .opts = opts };
    return ptr;
}

pub fn destroy(self: *Hyperlink, alloc: Allocator) void {
    alloc.destroy(self);
}

pub fn run(self: *Hyperlink, writer: *std.Io.Writer, rand: std.Random) !void {
    var prng: ?std.Random.DefaultPrng = null;
    var gen_rand = rand;
    if (self.opts.seed) |seed| {
        prng = std.Random.DefaultPrng.init(seed);
        gen_rand = prng.?.random();
    }

    while (true) {
        self.writeLine(writer, gen_rand) catch |err| {
            const Error = error{ WriteFailed, BrokenPipe } || @TypeOf(err);
            switch (@as(Error, err)) {
                error.BrokenPipe => return, // stdout closed
                error.WriteFailed => return, // fixed buffer full
            }
        };
    }
}

fn writeLine(
    self: *Hyperlink,
    writer: *std.Io.Writer,
    rand: std.Random,
) std.Io.Writer.Error!void {
    const line_min = self.opts.@"line-min";
    const line_max = @max(line_min, self.opts.@"line-max");
    const line_len = rand.intRangeAtMostBiased(usize, line_min, line_max);

    try writer.print(
        "\x1b]8;;https://example.com/{d}\x1b\\",
        .{rand.uintLessThan(u32, self.opts.uris)},
    );
    for (0..line_len) |_| {
        try writer.writeByte(rand.intRangeAtMostBiased(u8, 0x21, 0x7E));
    }
    try writer.writeAll("\x1b]8;;\x1b\\\r\n");
}

test Hyperlink {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *Hyperlink = try .create(alloc, .{
        .seed = 1,
        .uris = 3,
        .@"line-min" = 4,
        .@"line-max" = 8,
    });
    defer impl.destroy(alloc);

    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();

    var buf: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try impl.run(&writer, rand);
    const output = writer.buffered();

    // Every complete line is exactly one link wrapping all of its text,
    // with one of the configured URIs.
    var lines = std.mem.splitSequence(u8, output, "\r\n");
    var count: usize = 0;
    var seen: [3]bool = @splat(false);
    while (lines.next()) |line| {
        // The fixed buffer fills up partway through a line, so skip
        // that last incomplete line.
        if (lines.peek() == null) break;
        count += 1;

        const open = "\x1b]8;;https://example.com/";
        const close = "\x1b]8;;\x1b\\";
        try testing.expect(std.mem.startsWith(u8, line, open));
        try testing.expect(std.mem.endsWith(u8, line, close));

        const rest = line[open.len .. line.len - close.len];
        const st = std.mem.indexOf(u8, rest, "\x1b\\").?;
        const uri = try std.fmt.parseInt(usize, rest[0..st], 10);
        try testing.expect(uri < seen.len);
        seen[uri] = true;

        const text = rest[st + 2 ..];
        try testing.expect(text.len >= 4 and text.len <= 8);
        for (text) |c| try testing.expect(c >= 0x21 and c <= 0x7E);
    }
    try testing.expect(count > 100);
    for (seen) |s| try testing.expect(s);
}

test "Hyperlink invalid options" {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expectError(error.InvalidValue, Hyperlink.create(alloc, .{ .uris = 0 }));
    try testing.expectError(error.InvalidValue, Hyperlink.create(alloc, .{ .@"line-min" = 0 }));
}
