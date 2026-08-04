//! Generates styled terminal content: lines of printable text
//! interspersed with SGR sequences, optional multi-byte UTF-8
//! codepoints, combining marks (multi-codepoint graphemes), and
//! OSC 8 hyperlinks.
//!
//! This exists primarily to build corpora for benchmarking code that
//! consumes terminal *contents* (e.g. the terminal formatter used for
//! clipboard copy and dumps), where we want workloads with controlled
//! amounts of styling and Unicode rather than raw random bytes.
//!
//! Examples:
//!
//!   # Plain ASCII lines (equivalent to `ascii` with lines)
//!   ghostty-gen styled --seed=42
//!
//!   # Heavily styled ASCII
//!   ghostty-gen styled --seed=42 --style-rate=0.8
//!
//!   # Unicode-heavy, no styling
//!   ghostty-gen styled --seed=42 --weight-two=1 --weight-three=1 \
//!     --weight-four=0.5 --grapheme-rate=0.1
//!
//!   # Mixed: styles, Unicode, and hyperlinks
//!   ghostty-gen styled --seed=42 --style-rate=0.3 --weight-two=0.5 \
//!     --weight-three=0.25 --weight-four=0.1 --grapheme-rate=0.05 \
//!     --osc8-rate=0.1
const Styled = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Seed to use for deterministic generation. If unset, a time-based
    /// seed is used by the generic synthetic CLI.
    seed: ?u64 = null,

    /// Emit lines whose printable length (in characters, not columns)
    /// is uniformly distributed in `[line-min, line-max]`. Each line is
    /// terminated by CR LF.
    @"line-min": usize = 40,
    @"line-max": usize = 80,

    /// Probability that a style change (SGR sequence) is emitted at
    /// each run boundary. Zero (default) produces unstyled output.
    @"style-rate": f64 = 0.0,

    /// The length in characters of a "run": a sequence of characters
    /// that share styling. Style/hyperlink changes only happen on run
    /// boundaries.
    @"run-min": usize = 4,
    @"run-max": usize = 16,

    /// Relative weights for choosing the UTF-8 encoding length of each
    /// generated character. Unlike the raw `utf8` generator, characters
    /// are drawn from curated printable ranges so the output never
    /// contains control characters:
    ///
    ///   one:   printable ASCII (with occasional spaces)
    ///   two:   Latin-1 Supplement / Latin Extended (narrow)
    ///   three: Hiragana/Katakana and CJK ideographs (wide)
    ///   four:  emoji (wide)
    @"weight-one": f64 = 1.0,
    @"weight-two": f64 = 0.0,
    @"weight-three": f64 = 0.0,
    @"weight-four": f64 = 0.0,

    /// Probability that a generated character is followed by a
    /// combining diacritical mark, producing a multi-codepoint
    /// grapheme cluster.
    @"grapheme-rate": f64 = 0.0,

    /// Probability that an OSC 8 hyperlink is toggled (opened or
    /// closed) at each run boundary.
    @"osc8-rate": f64 = 0.0,
};

opts: Options,

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*Styled {
    for ([_]f64{
        opts.@"style-rate",
        opts.@"grapheme-rate",
        opts.@"osc8-rate",
    }) |rate| {
        if (rate < 0 or rate > 1) return error.InvalidValue;
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

    if (opts.@"line-min" == 0) return error.InvalidValue;
    if (opts.@"run-min" == 0) return error.InvalidValue;

    const ptr = try alloc.create(Styled);
    errdefer alloc.destroy(ptr);
    ptr.* = .{ .opts = opts };
    return ptr;
}

pub fn destroy(self: *Styled, alloc: Allocator) void {
    alloc.destroy(self);
}

pub fn run(self: *Styled, writer: *std.Io.Writer, rand: std.Random) !void {
    var prng: ?std.Random.DefaultPrng = null;
    var gen_rand = rand;
    if (self.opts.seed) |seed| {
        prng = std.Random.DefaultPrng.init(seed);
        gen_rand = prng.?.random();
    }

    var state: State = .{};
    while (true) {
        self.writeLine(writer, gen_rand, &state) catch |err| {
            const Error = error{ WriteFailed, BrokenPipe } || @TypeOf(err);
            switch (@as(Error, err)) {
                error.BrokenPipe => return, // stdout closed
                error.WriteFailed => return, // fixed buffer full
            }
        };
    }
}

const State = struct {
    /// True when a non-default SGR style is currently active.
    styled: bool = false,

    /// True when an OSC 8 hyperlink is currently open.
    link: bool = false,
};

fn writeLine(
    self: *Styled,
    writer: *std.Io.Writer,
    rand: std.Random,
    state: *State,
) std.Io.Writer.Error!void {
    const line_min = self.opts.@"line-min";
    const line_max = @max(line_min, self.opts.@"line-max");
    const run_min = self.opts.@"run-min";
    const run_max = @max(run_min, self.opts.@"run-max");

    const line_len = rand.intRangeAtMostBiased(usize, line_min, line_max);
    var remaining = line_len;
    while (remaining > 0) {
        if (self.opts.@"style-rate" > 0 and
            rand.float(f64) < self.opts.@"style-rate")
        {
            try self.writeSgr(writer, rand, state);
        }

        if (self.opts.@"osc8-rate" > 0 and
            rand.float(f64) < self.opts.@"osc8-rate")
        {
            try self.toggleLink(writer, rand, state);
        }

        const run_len = @min(
            remaining,
            rand.intRangeAtMostBiased(usize, run_min, run_max),
        );
        for (0..run_len) |_| try self.writeChar(writer, rand);
        remaining -= run_len;
    }

    // Close any open styling/hyperlink so state never bleeds across
    // lines. This mirrors what well-behaved programs do.
    if (state.styled) {
        try writer.writeAll("\x1b[0m");
        state.styled = false;
    }
    if (state.link) {
        try writer.writeAll("\x1b]8;;\x1b\\");
        state.link = false;
    }

    try writer.writeAll("\r\n");
}

fn writeChar(
    self: *Styled,
    writer: *std.Io.Writer,
    rand: std.Random,
) std.Io.Writer.Error!void {
    const weights = [_]f64{
        self.opts.@"weight-one",
        self.opts.@"weight-two",
        self.opts.@"weight-three",
        self.opts.@"weight-four",
    };

    const cp: u21 = switch (rand.weightedIndex(f64, &weights)) {
        // Printable ASCII with occasional word-ish spacing.
        0 => if (rand.float(f64) < 0.15)
            ' '
        else
            rand.intRangeAtMostBiased(u21, 0x21, 0x7E),

        // Latin-1 Supplement and Latin Extended-A/B (narrow).
        1 => rand.intRangeAtMostBiased(u21, 0xC0, 0x24F),

        // Kana or CJK ideographs (wide).
        2 => if (rand.boolean())
            rand.intRangeAtMostBiased(u21, 0x3041, 0x30FE)
        else
            rand.intRangeAtMostBiased(u21, 0x4E00, 0x9FFF),

        // Emoji (wide).
        3 => rand.intRangeAtMostBiased(u21, 0x1F600, 0x1F64F),

        else => unreachable,
    };

    try writer.print("{u}", .{cp});

    // Optionally follow with a combining diacritical mark to form a
    // multi-codepoint grapheme cluster.
    if (self.opts.@"grapheme-rate" > 0 and
        rand.float(f64) < self.opts.@"grapheme-rate")
    {
        const mark = rand.intRangeAtMostBiased(u21, 0x300, 0x36F);
        try writer.print("{u}", .{mark});
    }
}

fn writeSgr(
    self: *Styled,
    writer: *std.Io.Writer,
    rand: std.Random,
    state: *State,
) std.Io.Writer.Error!void {
    _ = self;

    switch (rand.uintLessThan(u8, 8)) {
        // Reset.
        0 => {
            try writer.writeAll("\x1b[0m");
            state.styled = false;
            return;
        },

        // 16-color foreground.
        1 => {
            const base: u8 = if (rand.boolean()) 30 else 90;
            try writer.print("\x1b[{d}m", .{base + rand.uintLessThan(u8, 8)});
        },

        // 16-color background.
        2 => {
            const base: u8 = if (rand.boolean()) 40 else 100;
            try writer.print("\x1b[{d}m", .{base + rand.uintLessThan(u8, 8)});
        },

        // 256-color foreground/background.
        3 => try writer.print("\x1b[38;5;{d}m", .{rand.int(u8)}),
        4 => try writer.print("\x1b[48;5;{d}m", .{rand.int(u8)}),

        // RGB foreground/background. Components are quantized so the
        // number of unique styles stays bounded (6^3 per channel pair)
        // rather than pathologically unique per cell.
        5, 6 => |kind| {
            const layer: u8 = if (kind == 5) 38 else 48;
            try writer.print("\x1b[{d};2;{d};{d};{d}m", .{
                layer,
                rand.uintLessThan(u8, 6) * 51,
                rand.uintLessThan(u8, 6) * 51,
                rand.uintLessThan(u8, 6) * 51,
            });
        },

        // Attributes: bold, italic, underline, inverse, strikethrough.
        7 => {
            const attrs = [_]u8{ 1, 3, 4, 7, 9 };
            try writer.print("\x1b[{d}m", .{
                attrs[rand.uintLessThan(usize, attrs.len)],
            });
        },

        else => unreachable,
    }

    state.styled = true;
}

fn toggleLink(
    self: *Styled,
    writer: *std.Io.Writer,
    rand: std.Random,
    state: *State,
) std.Io.Writer.Error!void {
    _ = self;

    if (state.link) {
        try writer.writeAll("\x1b]8;;\x1b\\");
        state.link = false;
        return;
    }

    try writer.print(
        "\x1b]8;;http://example.com/{d}\x1b\\",
        .{rand.uintLessThan(u16, 1024)},
    );
    state.link = true;
}

test Styled {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *Styled = try .create(alloc, .{ .seed = 1 });
    defer impl.destroy(alloc);

    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();

    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try impl.run(&writer, rand);
    const output = writer.buffered();
    try testing.expect(output.len > 0);

    // Default options: plain printable ASCII lines only.
    for (output) |byte| {
        try testing.expect(byte == '\r' or byte == '\n' or
            (byte >= 0x20 and byte < 0x7F));
    }
}

test "Styled styled output" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *Styled = try .create(alloc, .{
        .seed = 1,
        .@"style-rate" = 0.5,
        .@"osc8-rate" = 0.2,
    });
    defer impl.destroy(alloc);

    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();

    var buf: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try impl.run(&writer, rand);
    const output = writer.buffered();

    // Must contain SGR and OSC 8 sequences.
    try testing.expect(std.mem.indexOf(u8, output, "\x1b[") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\x1b]8;;") != null);
}

test "Styled unicode output" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *Styled = try .create(alloc, .{
        .seed = 1,
        .@"weight-two" = 1.0,
        .@"weight-three" = 1.0,
        .@"weight-four" = 1.0,
        .@"grapheme-rate" = 0.25,
    });
    defer impl.destroy(alloc);

    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();

    var buf: [16384]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try impl.run(&writer, rand);
    const output = writer.buffered();

    // No escapes, valid UTF-8 (modulo a possibly truncated tail from
    // the fixed buffer filling up mid-sequence).
    try testing.expect(std.mem.indexOfScalar(u8, output, 0x1B) == null);
    var end = output.len;
    while (end > 0 and output[end - 1] & 0xC0 == 0x80) end -= 1;
    if (end > 0 and output[end - 1] >= 0xC0) end -= 1;
    try testing.expect(std.unicode.utf8ValidateSlice(output[0..end]));
}

test "Styled invalid options" {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expectError(error.InvalidValue, Styled.create(alloc, .{
        .@"style-rate" = 1.5,
    }));
    try testing.expectError(error.InvalidValue, Styled.create(alloc, .{
        .@"weight-one" = 0,
    }));
    try testing.expectError(error.InvalidValue, Styled.create(alloc, .{
        .@"line-min" = 0,
    }));
}
