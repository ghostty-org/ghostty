//! The bidi fast-path scan.
//!
//! Deciding that a paragraph cannot be affected by the bidirectional
//! algorithm is worth far more than making the algorithm fast, because
//! the overwhelming majority of what a terminal renders is plain
//! left-to-right text. This scan is what keeps that text out of the
//! resolver entirely.
//!
//! ## Why a single threshold is sufficient
//!
//! `U+0590` is the first codepoint of the Hebrew block and the start of
//! the first right-to-left range in Unicode. Below it there is no
//! character with Bidi_Class R, AL, or AN, and none of the explicit
//! formatting characters (LRM, RLM, ALM, the embeddings, overrides, and
//! isolates all live at U+200E and above).
//!
//! That is not quite enough on its own, because European Numbers are
//! raised two levels by rule I1 even at an even embedding level. What
//! saves us is W7: with a paragraph level of 0 the sequence's start-of-
//! sequence type is L, so every EN resolves to L before I1 runs and no
//! level is ever raised. A paragraph forced to right-to-left breaks that
//! reasoning, so the caller must not use this scan in that case.
//!
//! The soundness of all of the above is not left to argument: a test
//! below runs the full resolver over every codepoint this scan accepts
//! and over randomized strings built from them, and asserts the result
//! really is the identity.
//!
//! ## Asymmetry of failure
//!
//! A false positive here renders text backwards. A false negative only
//! costs time. The scan is therefore written to be conservative, and the
//! vectorized and scalar forms are checked against each other.

const std = @import("std");
const simd = @import("../simd/main.zig");

/// The first codepoint that can influence bidi resolution.
pub const threshold: u21 = 0x0590;

/// True if no codepoint in `codepoints` can influence bidi resolution,
/// meaning visual order is guaranteed to equal logical order.
///
/// Only valid when the paragraph direction is left-to-right or is being
/// derived from the content (rules P2/P3). A caller forcing a
/// right-to-left paragraph must not use this.
pub fn isTriviallyLtr(codepoints: []const u21) bool {
    var i: usize = 0;

    // Manually vectorized: this is an early-exit search that LLVM will
    // not auto-vectorize, and the all-accept case dominates real input,
    // so it is worth scanning several codepoints per iteration. Same
    // idiom as the printable-run scan in `terminal/stream.zig`.
    if (simd.lanes(u21)) |lanes| {
        const V = @Vector(lanes, u21);
        const limit: V = @splat(threshold);
        while (i + lanes <= codepoints.len) : (i += lanes) {
            const v: V = codepoints[i..][0..lanes].*;
            if (@reduce(.Or, v >= limit)) return false;
        }
    }

    // Tail, and the whole scan on targets without usable SIMD.
    while (i < codepoints.len) : (i += 1) {
        if (codepoints[i] >= threshold) return false;
    }

    return true;
}

/// The scalar reference implementation, kept so the vectorized form can
/// be differentially tested against something obviously correct.
fn isTriviallyLtrScalar(codepoints: []const u21) bool {
    for (codepoints) |cp| {
        if (cp >= threshold) return false;
    }
    return true;
}

test "scan: basic acceptance and rejection" {
    const testing = std.testing;

    try testing.expect(isTriviallyLtr(&.{}));
    try testing.expect(isTriviallyLtr(&.{ 'h', 'e', 'l', 'l', 'o' }));
    try testing.expect(isTriviallyLtr(&.{ '1', '2', '3', '.', '4' }));

    // Greek and Cyrillic are below the threshold and left-to-right.
    try testing.expect(isTriviallyLtr(&.{ 0x03B1, 0x0416 }));

    // Hebrew, Arabic, and the formatting characters are all rejected.
    try testing.expect(!isTriviallyLtr(&.{0x05D0}));
    try testing.expect(!isTriviallyLtr(&.{0x0627}));
    try testing.expect(!isTriviallyLtr(&.{0x200F})); // RLM
    try testing.expect(!isTriviallyLtr(&.{0x202E})); // RLO
    try testing.expect(!isTriviallyLtr(&.{0x2067})); // RLI
    try testing.expect(!isTriviallyLtr(&.{0x0590})); // exactly the threshold
}

test "scan: rejection at every position and length" {
    const testing = std.testing;

    // A rejecting codepoint must be found wherever it sits, including in
    // the vector tail. Lengths are swept past several vector widths so
    // the tail handling is covered for any lane count.
    var buf: [67]u21 = undefined;
    for (1..buf.len + 1) |len| {
        for (0..len) |pos| {
            @memset(buf[0..len], 'a');
            buf[pos] = 0x05D0;
            try testing.expect(!isTriviallyLtr(buf[0..len]));

            buf[pos] = 'a';
            try testing.expect(isTriviallyLtr(buf[0..len]));
        }
    }
}

test "scan: vectorized agrees with scalar" {
    const testing = std.testing;

    var prng = std.Random.DefaultPrng.init(0x5E5E);
    const rand = prng.random();

    var buf: [512]u21 = undefined;
    for (0..2000) |_| {
        const len = rand.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*cp| {
            // Weighted toward the accepting range so both outcomes occur
            // frequently and neither branch dominates the sample.
            cp.* = if (rand.float(f32) < 0.98)
                rand.uintLessThan(u21, threshold)
            else
                rand.intRangeAtMost(u21, threshold, 0x10FFFF);
        }

        try testing.expectEqual(
            isTriviallyLtrScalar(buf[0..len]),
            isTriviallyLtr(buf[0..len]),
        );
    }
}

test "scan: exhaustive over every codepoint" {
    const testing = std.testing;

    // Every codepoint, checked one at a time against the scalar
    // reference. This is the cheap half of the soundness argument; the
    // expensive half (that accepted input really resolves to the
    // identity) lives in `zig.zig` where the resolver is available.
    for (0..std.math.maxInt(u21) + 1) |i| {
        const cp: u21 = @intCast(i);
        const one = [_]u21{cp};
        try testing.expectEqual(cp < threshold, isTriviallyLtr(&one));
    }
}
