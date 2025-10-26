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

fn checkKvAlphabet(c: u8) bool {
    return switch (c) {
        std.ascii.control_code.esc, std.ascii.control_code.bel, ';', '=' => false,
        else => std.ascii.isPrint(c),
    };
}

/// The alphabet for random bytes in OSC key/value pairs (omitting 0x1B,
/// 0x07, ';', '=').
pub const kv_alphabet = Bytes.generateAlphabet(checkKvAlphabet);

fn checkOscAlphabet(c: u8) bool {
    return switch (c) {
        std.ascii.control_code.esc, std.ascii.control_code.bel => false,
        else => true,
    };
}

/// The alphabet for random bytes in OSCs (omitting 0x1B and 0x07).
pub const osc_alphabet = Bytes.generateAlphabet(checkOscAlphabet);

pub fn generator(self: *Osc) Generator {
    return .init(self, next);
}

const osc = std.fmt.comptimePrint("{c}]", .{std.ascii.control_code.esc});
const st = std.fmt.comptimePrint("{c}", .{std.ascii.control_code.bel});

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
pub fn next(self: *Osc, writer: *std.Io.Writer, max_len: usize) Generator.Error!void {
    assert(max_len >= 3);
    try writer.writeAll(osc);
    try self.nextUnwrapped(writer, max_len - (osc.len + st.len));
    try writer.writeAll(st);
}

fn nextUnwrapped(self: *Osc, writer: *std.Io.Writer, max_len: usize) Generator.Error!void {
    return switch (self.chooseValidity()) {
        .valid => valid: {
            const Indexer = @TypeOf(self.p_valid_kind).Indexer;
            const idx = self.rand.weightedIndex(f64, &self.p_valid_kind.values);
            break :valid try self.nextUnwrappedValidExact(
                writer,
                Indexer.keyForIndex(idx),
                max_len,
            );
        },

        .invalid => invalid: {
            const Indexer = @TypeOf(self.p_invalid_kind).Indexer;
            const idx = self.rand.weightedIndex(f64, &self.p_invalid_kind.values);
            break :invalid try self.nextUnwrappedInvalidExact(
                writer,
                Indexer.keyForIndex(idx),
                max_len,
            );
        },
    };
}

fn nextUnwrappedValidExact(self: *const Osc, writer: *std.Io.Writer, k: ValidKind, max_len: usize) Generator.Error!void {
    switch (k) {
        .change_window_title => change_window_title: {
            if (max_len < 3) break :change_window_title;
            try writer.print("0;{f}", .{self.bytes().atMost(max_len - 3)}); // Set window title
        },

        .prompt_start => prompt_start: {
            if (max_len < 4) break :prompt_start;
            var remaining = max_len;

            try writer.writeAll("133;A"); // Start prompt
            remaining -= 4;

            // aid
            if (self.rand.boolean()) aid: {
                if (remaining < 6) break :aid;
                try writer.writeAll(";aid=");
                remaining -= 5;
                remaining -= try self.bytes().newAlphabet(kv_alphabet).atMost(@min(16, remaining)).write(writer);
            }

            // redraw
            if (self.rand.boolean()) redraw: {
                if (remaining < 9) break :redraw;
                try writer.writeAll(";redraw=");
                if (self.rand.boolean()) {
                    try writer.writeAll("1");
                } else {
                    try writer.writeAll("0");
                }
                remaining -= 9;
            }
        },

        .prompt_end => prompt_end: {
            if (max_len < 4) break :prompt_end;
            try writer.writeAll("133;B"); // End prompt
        },
    }
}

fn nextUnwrappedInvalidExact(
    self: *const Osc,
    writer: *std.Io.Writer,
    k: InvalidKind,
    max_len: usize,
) Generator.Error!void {
    switch (k) {
        .random => {
            try self.bytes().atMost(max_len).format(writer);
        },

        .good_prefix => {
            try writer.print("133;{f}", .{self.bytes().atMost(max_len - 4)});
        },
    }
}

fn bytes(self: *const Osc) Bytes {
    return .{
        .rand = self.rand,
        .alphabet = osc_alphabet,
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
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(test_seed);
    var buf: [256]u8 = undefined;
    {
        var v: Osc = .{
            .rand = prng.random(),
        };
        const gen = v.generator();
        for (0..50) |_| {
            var writer: std.Io.Writer = .fixed(&buf);
            try gen.next(&writer, buf.len);
            const result = writer.buffered();
            try testing.expect(result.len > 0);
        }
    }
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
        var writer: std.Io.Writer = .fixed(&buf);
        try gen.next(&writer, buf.len);
        const seq = writer.buffered();
        var parser: terminal.osc.Parser = .init(null);
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
        var writer: std.Io.Writer = .fixed(&buf);
        try gen.next(&writer, buf.len);
        const seq = writer.buffered();
        var parser: terminal.osc.Parser = .init(null);
        for (seq[2 .. seq.len - 1]) |c| parser.next(c);
        try testing.expect(parser.end(null) == null);
    }
}
