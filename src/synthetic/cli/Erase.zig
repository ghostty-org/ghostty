//! Generates a stream that clears and redraws the screen over and over,
//! the way `clear`, `watch`, and simple full-screen programs do. Most of
//! the work a terminal does on this stream is erasing and moving the
//! cursor rather than printing text, which makes it a useful benchmark
//! input for those code paths.
//!
//! The stream is a series of iterations. A redraw iteration looks like
//! this, where each `<text>` is a short run of random printable ASCII
//! and `<row>;<col>` is a random cursor position:
//!
//! ```
//! ESC [ 2 J                       clear the screen
//! ESC [ H <text>                  print at the top left
//! ESC [ <row> ; <col> H <text>    print somewhere else
//! ESC [ 2 K                       clear that line
//! ESC [ <row> ; 1 H               go to the start of the line
//! ESC [ 31 m <text> ESC [ 0 m     print in red
//! CR LF
//! ```
//!
//! With `--erase-rate` below 1, some iterations are a plain line of text
//! instead, so you can control how often the screen is cleared.
//!
//! The stream never ends on its own. Pipe it through `head -c` to get a
//! fixed size, and use `--seed` so the same file can be made again.
//!
//! Examples:
//!
//!   # 8 MiB where every iteration clears the screen
//!   ghostty-gen +erase --seed=1 | head -c 8388608 > erase.vt
//!
//!   # Clear the screen on about one line in ten
//!   ghostty-gen +erase --seed=1 --erase-rate=0.1 | head -c 8388608 > erase.vt
//!
//!   # Spread cursor positions across a 120x80 terminal
//!   ghostty-gen +erase --seed=1 --rows=80 --cols=120 | head -c 8388608 > erase.vt
//!
//!   # Move the screen into scrollback before each clear (CSI 22 J)
//!   ghostty-gen +erase --seed=1 --scroll-clear | head -c 8388608 > erase.vt
const Erase = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bytes = @import("../Bytes.zig");
const Ascii = @import("Ascii.zig");

pub const Options = struct {
    /// Seed to use for deterministic generation. If unset, a time-based
    /// seed is used by the generic synthetic CLI.
    seed: ?u64 = null,

    /// The length of each text run, in characters. Lengths are picked
    /// at random between `text-min` and `text-max`, inclusive. Text is
    /// printable ASCII without spaces. `text-min` must be at least 1.
    /// If `text-max` is smaller than `text-min`, every run has length
    /// `text-min`.
    @"text-min": usize = 5,
    @"text-max": usize = 10,

    /// The chance, from 0 to 1, that an iteration clears and redraws the
    /// screen. Other iterations print one line of text. The default of 1
    /// clears the screen on every iteration.
    @"erase-rate": f64 = 1.0,

    /// Clear with `CSI 22 J` instead of `CSI 2 J`. `CSI 22 J` moves the
    /// screen contents into scrollback before clearing, so the stream
    /// also exercises scrollback growth.
    @"scroll-clear": bool = false,

    /// The range for random cursor positions. Rows are picked from 1 to
    /// `rows` and columns from 1 to `cols`. Set these to the terminal
    /// size you will replay the stream at, so the cursor can land
    /// anywhere on the screen. A terminal clamps positions past its edge
    /// to the last row or column.
    rows: u16 = 24,
    cols: u16 = 80,
};

opts: Options,

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*Erase {
    if (opts.@"text-min" == 0) return error.InvalidValue;
    if (opts.@"erase-rate" < 0 or opts.@"erase-rate" > 1) return error.InvalidValue;
    if (opts.rows == 0 or opts.cols == 0) return error.InvalidValue;

    const ptr = try alloc.create(Erase);
    errdefer alloc.destroy(ptr);
    ptr.* = .{ .opts = opts };
    return ptr;
}

pub fn destroy(self: *Erase, alloc: Allocator) void {
    alloc.destroy(self);
}

pub fn run(self: *Erase, writer: *std.Io.Writer, rand: std.Random) !void {
    var prng: ?std.Random.DefaultPrng = null;
    var gen_rand = rand;
    if (self.opts.seed) |seed| {
        prng = std.Random.DefaultPrng.init(seed);
        gen_rand = prng.?.random();
    }

    const text: Bytes = .{
        .rand = gen_rand,
        .alphabet = Ascii.ascii,
        .min_len = self.opts.@"text-min",
        .max_len = @max(self.opts.@"text-min", self.opts.@"text-max"),
    };

    while (true) {
        self.writeIteration(writer, gen_rand, &text) catch |err| {
            const Error = error{ WriteFailed, BrokenPipe } || @TypeOf(err);
            switch (@as(Error, err)) {
                error.BrokenPipe => return, // stdout closed
                error.WriteFailed => return, // fixed buffer full
            }
        };
    }
}

fn writeIteration(
    self: *Erase,
    writer: *std.Io.Writer,
    rand: std.Random,
    text: *const Bytes,
) std.Io.Writer.Error!void {
    if (rand.float(f64) >= self.opts.@"erase-rate") {
        _ = try text.write(writer);
        try writer.writeAll("\r\n");
        return;
    }

    const row = rand.intRangeAtMostBiased(u16, 1, self.opts.rows);
    const col = rand.intRangeAtMostBiased(u16, 1, self.opts.cols);

    try writer.writeAll(if (self.opts.@"scroll-clear")
        "\x1b[22J\x1b[H"
    else
        "\x1b[2J\x1b[H");
    _ = try text.write(writer);
    try writer.print("\x1b[{d};{d}H", .{ row, col });
    _ = try text.write(writer);
    try writer.print("\x1b[2K\x1b[{d};1H\x1b[31m", .{row});
    _ = try text.write(writer);
    try writer.writeAll("\x1b[0m\r\n");
}

test Erase {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *Erase = try .create(alloc, .{ .seed = 1 });
    defer impl.destroy(alloc);

    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();

    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try impl.run(&writer, rand);
    const output = writer.buffered();

    // Every iteration clears the screen and ends with CR LF, so the two
    // counts match. The last iteration may be cut off by the end of the
    // buffer, which can leave one more clear than line endings.
    try testing.expect(std.mem.startsWith(u8, output, "\x1b[2J\x1b[H"));
    const erases = std.mem.count(u8, output, "\x1b[2J");
    const lines = std.mem.count(u8, output, "\r\n");
    try testing.expect(erases > 1);
    try testing.expect(erases == lines or erases == lines + 1);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[22J") == null);
}

test "Erase scroll clear and erase rate" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *Erase = try .create(alloc, .{
        .seed = 1,
        .@"erase-rate" = 0.25,
        .@"scroll-clear" = true,
    });
    defer impl.destroy(alloc);

    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();

    var buf: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try impl.run(&writer, rand);
    const output = writer.buffered();

    // Clears use CSI 22 J, and plain lines appear between them.
    const erases = std.mem.count(u8, output, "\x1b[22J");
    const lines = std.mem.count(u8, output, "\r\n");
    try testing.expect(erases > 0);
    try testing.expect(erases < lines);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[2J") == null);
}

test "Erase invalid options" {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expectError(error.InvalidValue, Erase.create(alloc, .{
        .@"text-min" = 0,
    }));
    try testing.expectError(error.InvalidValue, Erase.create(alloc, .{
        .@"erase-rate" = 1.5,
    }));
    try testing.expectError(error.InvalidValue, Erase.create(alloc, .{
        .rows = 0,
    }));
}
