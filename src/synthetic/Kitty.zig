//! Generates random Kitty graphics protocol APC sequences.
//!
//! The payload is random base64, NOT a valid image: decoding it as
//! PNG will fail. This corpus is meant for benchmarking the stream,
//! APC, and Kitty command parsing paths, which never decode the
//! image data. It does not exercise successful image loading.
const Kitty = @This();

const std = @import("std");
const assert = std.debug.assert;
const Generator = @import("Generator.zig");
const Bytes = @import("Bytes.zig");

/// Random number generator.
rand: std.Random,

/// The base64 payload length for each generated command. This is
/// rounded down to a multiple of four so the payload is always valid
/// base64 without requiring padding. Kitty clients typically chunk
/// payloads at 4096 bytes.
data_len: usize = 4096,

fn checkBase64Alphabet(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '+', '/' => true,
        else => false,
    };
}

/// The base64 alphabet, without the padding character.
pub const base64_alphabet = Bytes.generateAlphabet(checkBase64Alphabet);

pub fn generator(self: *Kitty) Generator {
    return .init(self, next);
}

const prefix = "\x1b_G";
const st = "\x1b\\";

/// Get the next Kitty graphics APC sequence: a well-formed transmit
/// command with a random base64 payload (not a valid image; see the
/// module comment), including the APC prefix and the ST terminator.
pub fn next(
    self: *Kitty,
    writer: *std.Io.Writer,
    max_len: usize,
) Generator.Error!void {
    var control_buf: [64]u8 = undefined;
    const control = std.fmt.bufPrint(
        &control_buf,
        "a=t,f=100,i={d};",
        .{self.rand.intRangeAtMost(u32, 1, 1_000_000)},
    ) catch unreachable;

    const overhead = prefix.len + control.len + st.len;
    assert(max_len > overhead);

    const avail = @min(self.data_len, max_len - overhead);
    const payload_len = avail - (avail % 4);

    try writer.writeAll(prefix);
    try writer.writeAll(control);
    if (payload_len > 0) {
        const bytes: Bytes = .{
            .rand = self.rand,
            .alphabet = base64_alphabet,
            .min_len = payload_len,
            .max_len = payload_len,
        };
        _ = try bytes.write(writer);
    }
    try writer.writeAll(st);
}

test "kitty" {
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0);

    var buf: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var v: Kitty = .{ .rand = prng.random() };
    const gen = v.generator();
    try gen.next(&writer, buf.len);

    const data = writer.buffered();
    try testing.expect(std.mem.startsWith(u8, data, "\x1b_Ga=t,f=100,i="));
    try testing.expect(std.mem.endsWith(u8, data, "\x1b\\"));
}
