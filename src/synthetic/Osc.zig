/// Generates random terminal OSC requests.
const Osc = @This();

const std = @import("std");
const assert = std.debug.assert;
const Generator = @import("Generator.zig");
const Bytes = @import("Bytes.zig");

/// Valid OSC request kinds that can be generated.
pub const ValidKind = enum {
    change_window_title,
    prompt_start,
    prompt_end,
};

/// Invalid OSC request kinds that can be generated.
pub const InvalidKind = enum {
    /// Literally random bytes. Might even be valid, but probably not.
    random,

    /// A good prefix, but ultimately invalid format.
    good_prefix,
};

/// Random number generator.
rand: std.Random,

/// Probability of a valid OSC sequence being generated.
p_valid: f64 = 1.0,

/// Probabilities of specific valid or invalid OSC request kinds.
/// The probabilities are weighted relative to each other, so they
/// can sum greater than 1.0. A kind of weight 1.0 and a kind of
/// weight 2.0 will have a 2:1 chance of the latter being selected.
p_valid_kind: std.enums.EnumArray(ValidKind, f64) = .initFill(1.0),
p_invalid_kind: std.enums.EnumArray(InvalidKind, f64) = .initFill(1.0),

/// The alphabet for random bytes (omitting 0x1B and 0x07).
const bytes_alphabet: []const u8 = alphabet: {
    var alphabet: [256]u8 = undefined;
    for (0..alphabet.len) |i| {
        if (i == 0x1B or i == 0x07) {
            alphabet[i] = @intCast(i + 1);
        } else {
            alphabet[i] = @intCast(i);
        }
    }
    const result = alphabet;
    break :alphabet &result;
};

pub fn generator(self: *Osc) Generator {
    return .init(self, next);
}

/// Get the next OSC request in bytes. The generated OSC request will
/// have the prefix `ESC ]` and the terminator `BEL` (0x07).
///
/// This will generate both valid and invalid OSC requests (based on
/// the `p_valid` probability value). Invalid requests still have the
/// prefix and terminator, but the content in between is not a valid
/// OSC request.
///
/// The buffer must be at least 3 bytes long to accommodate the
/// prefix and terminator.
pub fn next(self: *Osc, buf: []u8) Generator.Error![]const u8 {
    if (buf.len < 3) return error.NoSpaceLeft;
    const unwrapped = try self.nextUnwrapped(buf[2 .. buf.len - 1]);
    buf[0] = 0x1B; // ESC
    buf[1] = ']';
    buf[unwrapped.len + 2] = 0x07; // BEL
    return buf[0 .. unwrapped.len + 3];
}

fn nextUnwrapped(self: *Osc, buf: []u8) Generator.Error![]const u8 {
    return switch (self.chooseValidity()) {
        .valid => valid: {
            const Indexer = @TypeOf(self.p_valid_kind).Indexer;
            const idx = self.rand.weightedIndex(f64, &self.p_valid_kind.values);
            break :valid try self.nextUnwrappedValidExact(
                buf,
                Indexer.keyForIndex(idx),
            );
        },

        .invalid => invalid: {
            const Indexer = @TypeOf(self.p_invalid_kind).Indexer;
            const idx = self.rand.weightedIndex(f64, &self.p_invalid_kind.values);
            break :invalid try self.nextUnwrappedInvalidExact(
                buf,
                Indexer.keyForIndex(idx),
            );
        },
    };
}

fn nextUnwrappedValidExact(self: *const Osc, buf: []u8, k: ValidKind) Generator.Error![]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    switch (k) {
        .change_window_title => {
            try fbs.writer().writeAll("0;"); // Set window title
            var bytes_gen = self.bytes();
            const title = try bytes_gen.next(fbs.buffer[fbs.pos..]);
            try fbs.seekBy(@intCast(title.len));
        },

        .prompt_start => {
            try fbs.writer().writeAll("133;A"); // Start prompt

            // aid
            if (self.rand.boolean()) {
                var bytes_gen = self.bytes();
                bytes_gen.max_len = 16;
                try fbs.writer().writeAll(";aid=");
                const aid = try bytes_gen.next(fbs.buffer[fbs.pos..]);
                try fbs.seekBy(@intCast(aid.len));
            }

            // redraw
            if (self.rand.boolean()) {
                try fbs.writer().writeAll(";redraw=");
                if (self.rand.boolean()) {
                    try fbs.writer().writeAll("1");
                } else {
                    try fbs.writer().writeAll("0");
                }
            }
        },

        .prompt_end => try fbs.writer().writeAll("133;B"), // End prompt
    }

    return fbs.getWritten();
}

fn nextUnwrappedInvalidExact(
    self: *const Osc,
    buf: []u8,
    k: InvalidKind,
) Generator.Error![]const u8 {
    switch (k) {
        .random => {
            var bytes_gen = self.bytes();
            return try bytes_gen.next(buf);
        },

        .good_prefix => {
            var fbs = std.io.fixedBufferStream(buf);
            try fbs.writer().writeAll("133;");
            var bytes_gen = self.bytes();
            const data = try bytes_gen.next(fbs.buffer[fbs.pos..]);
            try fbs.seekBy(@intCast(data.len));
            return fbs.getWritten();
        },
    }
}

fn bytes(self: *const Osc) Bytes {
    return .{
        .rand = self.rand,
        .alphabet = bytes_alphabet,
    };
}

/// Choose whether to generate a valid or invalid OSC request based
/// on the validity probability.
fn chooseValidity(self: *const Osc) Validity {
    return if (self.rand.float(f64) > self.p_valid)
        .invalid
    else
        .valid;
}

const Validity = enum { valid, invalid };

/// A fixed seed we can use for our tests to avoid flakes.
const test_seed = 0xC0FFEEEEEEEEEEEE;

test "OSC generator" {
    var prng = std.Random.DefaultPrng.init(test_seed);
    var buf: [4096]u8 = undefined;
    var v: Osc = .{ .rand = prng.random() };
    const gen = v.generator();
    for (0..50) |_| _ = try gen.next(&buf);
}

test "OSC generator valid" {
    const testing = std.testing;
    const terminal = @import("../terminal/main.zig");

    var prng = std.Random.DefaultPrng.init(test_seed);
    var buf: [256]u8 = undefined;
    var gen: Osc = .{
        .rand = prng.random(),
        .p_valid = 1.0,
    };
    for (0..50) |_| {
        const seq = try gen.next(&buf);
        var parser: terminal.osc.Parser = .{};
        for (seq[2 .. seq.len - 1]) |c| parser.next(c);
        try testing.expect(parser.end(null) != null);
    }
}

test "OSC generator invalid" {
    const testing = std.testing;
    const terminal = @import("../terminal/main.zig");

    var prng = std.Random.DefaultPrng.init(test_seed);
    var buf: [256]u8 = undefined;
    var gen: Osc = .{
        .rand = prng.random(),
        .p_valid = 0.0,
    };
    for (0..50) |_| {
        const seq = try gen.next(&buf);
        var parser: terminal.osc.Parser = .{};
        for (seq[2 .. seq.len - 1]) |c| parser.next(c);
        try testing.expect(parser.end(null) == null);
    }
}
