//! Differential and property tests for the LZ4 block codec.
//!
//! Every generated input must compress into a block which:
//!
//!   1. fits within `compressBound`,
//!   2. is structurally valid LZ4 with the stricter guarantees our
//!      compressor documents (final five bytes are literals, matches start
//!      at least twelve bytes before the end), verified by an independent
//!      walker which shares no code with the codec,
//!   3. decompresses to exactly the original bytes, and
//!   4. is rejected when decompressed into a buffer of the wrong size.
//!
//! Valid blocks are additionally mutated (bit flips, splices, truncations)
//! and fed to the decompressor, which must fail cleanly or succeed, but
//! never read or write out of bounds. The unit-test build enables runtime
//! safety, so any out-of-bounds slice access fails the test.
//!
//! The light suite below runs as a normal unit test and finishes quickly.
//! The exhaustive suite multiplies the same properties across far more
//! sizes, periods, seeds, and mutations; it is slow and therefore skipped
//! unless the environment variable `GHOSTTY_LZ4_SLOW` is set:
//!
//!     GHOSTTY_LZ4_SLOW=1 zig build test -Dtest-filter="lz4 differential"
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const lz4 = @import("lz4.zig");

/// Number of trailing block bytes which must be literals, mirroring the
/// documented guarantee of the compressor. Kept as an independent constant
/// so a codec regression cannot silently weaken the check.
const last_literals = 5;

/// A match may not begin in the final twelve bytes. See `last_literals`.
const match_find_limit = 12;

/// Sizes around every encoding boundary: token nibble limits (14/15),
/// minimum match and find limits (4/12), length-extension steps (15 + 255k),
/// and power-of-two neighborhoods.
const boundary_sizes = [_]usize{
    0,   1,    2,    3,    4,    5,    6,   7,
    8,   9,    11,   12,   13,   14,   15,  16,
    17,  18,   19,   20,   31,   32,   33,  63,
    64,  65,   254,  255,  256,  269,  270, 271,
    272, 1023, 1024, 4095, 4096, 4097,
};

/// Input generators exercising distinct codec behaviors. Every generator is
/// deterministic for a given random state.
const Generator = enum {
    /// Uniform random bytes; largely incompressible.
    random_bytes,

    /// Runs of one repeated byte with random lengths; period-one matches.
    runs,

    /// One repeating pattern; exercises a fixed match period end to end.
    periodic,

    /// Eight-byte records with random small payloads and zero padding, with
    /// some records repeated; resembles terminal cell memory.
    cells,

    /// Dictionary words with separators; text-like literal/match mix.
    words,

    /// Mostly zeros with scattered random bytes; long matches with isolated
    /// literals.
    sparse,

    /// Random segments of all other generators; exercises transitions.
    mixed,

    fn fill(gen: Generator, random: std.Random, buf: []u8) void {
        switch (gen) {
            .random_bytes => random.bytes(buf),

            .runs => {
                var i: usize = 0;
                while (i < buf.len) {
                    const run = @min(
                        random.intRangeAtMost(usize, 1, 300),
                        buf.len - i,
                    );
                    @memset(buf[i..][0..run], random.int(u8));
                    i += run;
                }
            },

            .periodic => fillPeriodic(
                random,
                buf,
                random.intRangeAtMost(usize, 1, 40),
            ),

            .cells => {
                var i: usize = 0;
                while (i + 8 <= buf.len) : (i += 8) {
                    const cell = buf[i..][0..8];
                    if (i >= 8 and random.boolean()) {
                        // Repeat one of the last 256 records.
                        const back = 8 * random.intRangeAtMost(
                            usize,
                            1,
                            @min(i / 8, 256),
                        );
                        cell.* = buf[i - back ..][0..8].*;
                    } else {
                        @memset(cell, 0);
                        cell[0] = ' ' + random.uintLessThan(u8, 95);
                        cell[1] = random.uintLessThan(u8, 4);
                    }
                }
                random.bytes(buf[i..]);
            },

            .words => {
                const words = [_][]const u8{
                    "the",   "terminal", "page",   "compress",
                    "row",   "cell",     "style",  "zig",
                    "lz4",   "block",    "offset", "match",
                    "a",     "of",       "and",    "literal",
                    "0x00",  "0xFF",     "    ",   "\r\n",
                    "-----", "=",        "pub fn", "const",
                };
                var i: usize = 0;
                while (i < buf.len) {
                    const word = words[random.uintLessThan(usize, words.len)];
                    const n = @min(word.len, buf.len - i);
                    @memcpy(buf[i..][0..n], word[0..n]);
                    i += n;
                    if (i < buf.len) {
                        buf[i] = if (random.boolean()) ' ' else '\n';
                        i += 1;
                    }
                }
            },

            .sparse => {
                @memset(buf, 0);
                if (buf.len == 0) return;
                for (0..buf.len / 32 + 1) |_| {
                    const at = random.uintLessThan(usize, buf.len);
                    buf[at] = random.int(u8);
                }
            },

            .mixed => {
                var i: usize = 0;
                while (i < buf.len) {
                    const segment = @min(
                        random.intRangeAtMost(usize, 1, 2048),
                        buf.len - i,
                    );
                    const sub = random.enumValue(Generator);
                    if (sub != .mixed) sub.fill(random, buf[i..][0..segment]);
                    i += segment;
                }
            },
        }
    }
};

/// Fill `buf` with one repeating pattern of the given period.
fn fillPeriodic(random: std.Random, buf: []u8, period: usize) void {
    if (buf.len == 0) return;
    const head = @min(period, buf.len);
    random.bytes(buf[0..head]);
    for (head..buf.len) |i| buf[i] = buf[i - period];
}

/// Reusable buffers sized for the largest input a suite generates.
const Workspace = struct {
    input: []u8,
    encoded: []u8,
    decoded: []u8,
    table: *lz4.HashTable,

    fn init(alloc: Allocator, max_input: usize) !Workspace {
        const input = try alloc.alloc(u8, max_input);
        errdefer alloc.free(input);
        const encoded = try alloc.alloc(u8, try lz4.compressBound(max_input));
        errdefer alloc.free(encoded);
        // One extra byte so wrong-size decompression can be tested above
        // the exact length as well as below it.
        const decoded = try alloc.alloc(u8, max_input + 1);
        errdefer alloc.free(decoded);
        const table = try alloc.create(lz4.HashTable);
        return .{
            .input = input,
            .encoded = encoded,
            .decoded = decoded,
            .table = table,
        };
    }

    fn deinit(ws: *Workspace, alloc: Allocator) void {
        alloc.free(ws.input);
        alloc.free(ws.encoded);
        alloc.free(ws.decoded);
        alloc.destroy(ws.table);
        ws.* = undefined;
    }
};

/// Compress one input and verify every property promised by the codec.
/// Returns the encoded length so callers can reuse the encoded block.
fn expectCodecProperties(ws: *Workspace, input: []const u8) !usize {
    const encoded_len = try lz4.compress(input, ws.encoded, ws.table);
    try testing.expect(encoded_len <= try lz4.compressBound(input.len));
    const encoded = ws.encoded[0..encoded_len];

    try expectValidBlock(encoded, input.len);

    // Exact-size decompression must reproduce the input bit for bit. The
    // output is poisoned first so unwritten bytes cannot pass as correct.
    const output = ws.decoded[0..input.len];
    @memset(output, 0xAA);
    try testing.expectEqual(input.len, try lz4.decompress(encoded, output));
    try testing.expectEqualSlices(u8, input, output);

    // The exact-size contract must reject both smaller and larger buffers.
    if (input.len > 0) {
        try testing.expectError(
            error.OutputTooSmall,
            lz4.decompress(encoded, ws.decoded[0 .. input.len - 1]),
        );
    }
    try testing.expectError(
        error.OutputSizeMismatch,
        lz4.decompress(encoded, ws.decoded[0 .. input.len + 1]),
    );

    return encoded_len;
}

/// Structurally validate one encoded block against the LZ4 block format and
/// the stricter guarantees documented by our compressor. This deliberately
/// reimplements the format rather than reusing codec internals.
fn expectValidBlock(encoded: []const u8, raw_len: usize) !void {
    var ip: usize = 0;
    var op: usize = 0;
    var last_match_end: usize = 0;

    while (true) {
        // Every sequence, including the final one, starts with a token.
        try testing.expect(ip < encoded.len);
        const token = encoded[ip];
        ip += 1;

        var literal_len: usize = token >> 4;
        if (literal_len == 15) literal_len += try readExtension(encoded, &ip);
        try testing.expect(encoded.len - ip >= literal_len);
        ip += literal_len;
        op += literal_len;

        // The final sequence contains only literals and ends the block.
        if (ip == encoded.len) {
            try testing.expectEqual(raw_len, op);
            if (last_match_end > 0)
                try testing.expect(raw_len - last_match_end >= last_literals);
            return;
        }

        try testing.expect(encoded.len - ip >= 2);
        const offset = std.mem.readInt(u16, encoded[ip..][0..2], .little);
        ip += 2;
        try testing.expect(offset >= 1);
        try testing.expect(offset <= op);

        // Our compressor starts matches at least `match_find_limit` bytes
        // before the end and never lets one run into the final literals.
        try testing.expect(op + match_find_limit <= raw_len);
        var match_len: usize = (token & 0x0F) + 4;
        if (token & 0x0F == 15) match_len += try readExtension(encoded, &ip);
        op += match_len;
        try testing.expect(op + last_literals <= raw_len);
        last_match_end = op;
    }
}

/// Read one length extension: bytes of 255 accumulate until a terminator
/// below 255, which is included in the sum.
fn readExtension(encoded: []const u8, ip: *usize) !usize {
    var total: usize = 0;
    while (true) {
        try testing.expect(ip.* < encoded.len);
        const value = encoded[ip.*];
        ip.* += 1;
        total += value;
        if (value != 255) return total;
    }
}

/// Decode deterministic corruptions of a valid block. Any result is
/// acceptable except memory unsafety, which the safety-checked test build
/// turns into a failure. Mutations may still form a valid block, so output
/// contents are intentionally not asserted.
fn expectMutationSafety(
    ws: *Workspace,
    random: std.Random,
    encoded_len: usize,
    raw_len: usize,
    mutations: usize,
) !void {
    const original = try testing.allocator.dupe(u8, ws.encoded[0..encoded_len]);
    defer testing.allocator.free(original);

    for (0..mutations) |_| {
        const block = ws.encoded[0..encoded_len];
        @memcpy(block, original);

        switch (random.uintLessThan(u8, 4)) {
            // Flip up to eight random bits.
            0 => for (0..random.intRangeAtMost(usize, 1, 8)) |_| {
                const at = random.uintLessThan(usize, block.len);
                block[at] ^= @as(u8, 1) << random.int(u3);
            },
            // Overwrite one random byte. Token and length bytes are the
            // most interesting targets and small blocks are mostly tokens.
            1 => block[random.uintLessThan(usize, block.len)] =
                random.int(u8),
            // Splice random garbage over a random span.
            2 => {
                const at = random.uintLessThan(usize, block.len);
                const span = @min(
                    random.intRangeAtMost(usize, 1, 16),
                    block.len - at,
                );
                random.bytes(block[at..][0..span]);
            },
            // Decode a random prefix of the intact block.
            else => {},
        }

        const len = if (random.boolean())
            random.uintAtMost(usize, block.len)
        else
            block.len;
        _ = lz4.decompress(block[0..len], ws.decoded[0..raw_len]) catch {};
    }
}

/// Workload knobs shared by the light and exhaustive suites.
const Budget = struct {
    /// Upper bound and step of the contiguous small-size sweep applied to
    /// every generator.
    sweep_max: usize,
    sweep_step: usize,

    /// Number and maximum size of random-parameter inputs.
    random_inputs: usize,
    random_max: usize,

    /// Explicit match periods checked with `fillPeriodic`.
    periods: []const usize,
    period_len: usize,

    /// Number of corrupted decode attempts per mutation base block.
    mutations: usize,

    fn maxInput(budget: Budget) usize {
        return @max(
            budget.random_max,
            @max(budget.period_len, boundary_sizes[boundary_sizes.len - 1]),
        );
    }
};

const light_budget: Budget = .{
    .sweep_max = 96,
    .sweep_step = 1,
    .random_inputs = 24,
    .random_max = 32 * 1024,
    // One period per copy strategy: byte propagation (3), pattern words
    // (1/2/4/8), word strides (9), wide strides (17), plus the 64 KiB
    // window edge cases.
    .periods = &.{ 1, 2, 3, 4, 8, 9, 17, 65534, 65535, 65536, 65537 },
    .period_len = 160 * 1024,
    .mutations = 64,
};

const exhaustive_budget: Budget = .{
    .sweep_max = 2048,
    .sweep_step = 1,
    .random_inputs = 512,
    .random_max = 512 * 1024,
    .periods = &.{
        1,     2,     3,    4,     5,     6,     7,     8,
        9,     10,    11,   12,    13,    14,    15,    16,
        17,    18,    19,   23,    24,    31,    32,    33,
        48,    63,    64,   65,    127,   128,   255,   256,
        257,   4095,  4096, 32768, 65533, 65534, 65535, 65536,
        65537, 65538,
    },
    .period_len = 320 * 1024,
    .mutations = 4096,
};

fn runSuite(budget: Budget, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var ws: Workspace = try .init(testing.allocator, budget.maxInput());
    defer ws.deinit(testing.allocator);

    // Every generator across every boundary size and the small-size sweep.
    // Small inputs hit the literal-only format edges: below the minimum
    // match sizes, around nibble limits, and around extension steps.
    inline for (@typeInfo(Generator).@"enum".fields) |field| {
        const gen: Generator = @enumFromInt(field.value);

        for (boundary_sizes) |size| {
            const input = ws.input[0..size];
            gen.fill(random, input);
            _ = try expectCodecProperties(&ws, input);
        }

        var size: usize = 0;
        while (size <= budget.sweep_max) : (size += budget.sweep_step) {
            const input = ws.input[0..size];
            gen.fill(random, input);
            _ = try expectCodecProperties(&ws, input);
        }
    }

    // Random generator and size pairs, biased toward interesting sizes by
    // squaring so both tiny and large inputs appear.
    for (0..budget.random_inputs) |_| {
        const gen = random.enumValue(Generator);
        const scale = random.float(f64);
        const size: usize = @intFromFloat(
            scale * scale * @as(f64, @floatFromInt(budget.random_max)),
        );
        const input = ws.input[0..size];
        gen.fill(random, input);
        const encoded_len = try expectCodecProperties(&ws, input);

        // Reuse a handful of these encodings as corruption bases.
        try expectMutationSafety(
            &ws,
            random,
            encoded_len,
            input.len,
            budget.mutations / budget.random_inputs + 1,
        );
    }

    // Directed match periods, including the 64 KiB window edge where the
    // compressor's 16-bit position arithmetic wraps.
    for (budget.periods) |period| {
        const input = ws.input[0..budget.period_len];
        fillPeriodic(random, input, period);
        _ = try expectCodecProperties(&ws, input);
    }

    // Dedicated corruption run over a text-like block, plus an exhaustive
    // truncation sweep: every prefix of a valid block must decode cleanly
    // or fail cleanly.
    {
        const input = ws.input[0..@min(16 * 1024, budget.random_max)];
        Generator.words.fill(random, input);
        const encoded_len = try expectCodecProperties(&ws, input);
        try expectMutationSafety(
            &ws,
            random,
            encoded_len,
            input.len,
            budget.mutations,
        );

        for (0..encoded_len) |prefix| {
            _ = lz4.decompress(
                ws.encoded[0..prefix],
                ws.decoded[0..input.len],
            ) catch {};
        }
    }
}

test "lz4 differential light" {
    try runSuite(light_budget, 0x4C5A_3403);
}

test "lz4 differential exhaustive" {
    // Slow. Enable explicitly, ideally together with a test filter:
    //   GHOSTTY_LZ4_SLOW=1 zig build test -Dtest-filter="lz4 differential"
    if (!std.process.hasEnvVarConstant("GHOSTTY_LZ4_SLOW"))
        return error.SkipZigTest;

    // Several independent seeds; the suite is deterministic per seed.
    for (0..4) |seed| try runSuite(exhaustive_budget, 0x4C5A_4000 + seed);
}
