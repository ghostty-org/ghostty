//! CRC32C with hardware acceleration.
//!
//! The Zig standard library implementation processes one byte per table
//! lookup (as of Zig 0.16), which is more than an order of magnitude slower
//! than the dedicated CRC32C instructions available on aarch64 (CRC
//! extension) and x86_64 (SSE4.2). This module selects the best backend at
//! compile time.
//!
//! Targets without a dedicated instruction, such as WebAssembly, use a
//! custom implementation that is faster than Zig's stdlib.
//!
//! The resulting value is identical across all backends: this is the
//! iSCSI CRC32C parameter set (reflected, initial and final XOR
//! `0xFFFFFFFF`), matching `std.hash.crc.Crc32Iscsi`.

const std = @import("std");
const builtin = @import("builtin");

const Backend = enum {
    aarch64_crc,
    x86_64_sse42,
    software,
};

const backend: Backend = backend: {
    switch (builtin.cpu.arch) {
        .aarch64,
        .aarch64_be,
        => if (std.Target.aarch64.featureSetHas(
            builtin.cpu.features,
            .crc,
        )) break :backend .aarch64_crc,

        // The self-hosted x86_64 backend cannot encode the CRC32
        // instruction forms used below, so that combination falls back to
        // the portable implementation.
        .x86_64 => if (builtin.zig_backend == .stage2_llvm and
            std.Target.x86.featureSetHas(
                builtin.cpu.features,
                .sse4_2,
            )) break :backend .x86_64_sse42,

        else => {},
    }
    break :backend .software;
};

/// Streaming CRC32C with the same interface shape as `std.hash.crc` types.
pub const Crc32c = struct {
    crc: u32,

    pub fn init() Crc32c {
        return .{ .crc = 0xFFFF_FFFF };
    }

    pub fn update(self: *Crc32c, bytes: []const u8) void {
        self.crc = switch (comptime backend) {
            .aarch64_crc, .x86_64_sse42 => updateHardware(self.crc, bytes),
            .software => Software.update(self.crc, bytes),
        };
    }

    pub fn final(self: Crc32c) u32 {
        return self.crc ^ 0xFFFF_FFFF;
    }

    pub fn hash(bytes: []const u8) u32 {
        var c: Crc32c = .init();
        c.update(bytes);
        return c.final();
    }
};

/// One update pass using the dedicated CRC32C instructions. Both supported
/// architectures handle unaligned loads efficiently, so the loop reads
/// little-endian words directly from the input.
fn updateHardware(initial: u32, bytes: []const u8) u32 {
    var crc = initial;
    var remaining = bytes;

    while (remaining.len >= 8) : (remaining = remaining[8..]) {
        crc = step(u64, crc, std.mem.readInt(
            u64,
            remaining[0..8],
            .little,
        ));
    }
    if (remaining.len >= 4) {
        crc = step(u32, crc, std.mem.readInt(
            u32,
            remaining[0..4],
            .little,
        ));
        remaining = remaining[4..];
    }
    for (remaining) |byte| crc = step(u8, crc, byte);
    return crc;
}

/// One CRC32C instruction folding `value` into the running CRC.
inline fn step(comptime T: type, crc: u32, value: T) u32 {
    return switch (comptime backend) {
        .aarch64_crc => switch (T) {
            u8 => asm ("crc32cb %[out:w], %[crc:w], %[value:w]"
                : [out] "=r" (-> u32),
                : [crc] "r" (crc),
                  [value] "r" (value),
            ),
            u32 => asm ("crc32cw %[out:w], %[crc:w], %[value:w]"
                : [out] "=r" (-> u32),
                : [crc] "r" (crc),
                  [value] "r" (value),
            ),
            u64 => asm ("crc32cx %[out:w], %[crc:w], %[value:x]"
                : [out] "=r" (-> u32),
                : [crc] "r" (crc),
                  [value] "r" (value),
            ),
            else => comptime unreachable,
        },

        .x86_64_sse42 => switch (T) {
            u8 => asm ("crc32b %[value], %[out]"
                : [out] "=r" (-> u32),
                : [value] "r" (value),
                  [crc_in] "0" (crc),
            ),
            u32 => asm ("crc32l %[value], %[out]"
                : [out] "=r" (-> u32),
                : [value] "r" (value),
                  [crc_in] "0" (crc),
            ),
            u64 => @truncate(asm ("crc32q %[value], %[out]"
                : [out] "=r" (-> u64),
                : [value] "r" (value),
                  [crc_in] "0" (@as(u64, crc)),
            )),
            else => comptime unreachable,
        },

        .software => comptime unreachable,
    };
}

/// The portable software backend, used by targets without a dedicated
/// CRC32C instruction.
const Software = struct {
    /// The reflected CRC32C (Castagnoli) polynomial.
    const reflected_poly: u32 = 0x82F63B78;

    /// Number of slicing tables, which is also the bytes folded per
    /// iteration.
    const slices = 16;

    /// Inputs below this length use the single-stream pass: the
    /// stream-combine matrix work would not pay for itself.
    const multi_stream_threshold = 4096;

    /// Slicing tables: `tables[i][b]` is the CRC of byte `b` followed by
    /// `i` zero bytes. Table zero is the classic one-byte-per-step table;
    /// the higher tables let one iteration fold a whole block with
    /// independent lookups instead of a byte-by-byte dependency chain.
    const tables: [slices][256]u32 = tables: {
        @setEvalBranchQuota(200_000);
        var result: [slices][256]u32 = undefined;
        for (0..256) |n| {
            var crc: u32 = n;
            for (0..8) |_| {
                crc = (crc >> 1) ^ (reflected_poly * (crc & 1));
            }
            result[0][n] = crc;
        }
        for (1..slices) |i| {
            for (0..256) |n| {
                const prev = result[i - 1][n];
                result[i][n] = (prev >> 8) ^ result[0][prev & 0xFF];
            }
        }
        break :tables result;
    };

    fn update(initial: u32, bytes: []const u8) u32 {
        if (bytes.len >= multi_stream_threshold) return updateMulti(
            initial,
            bytes,
        );

        return updateSingle(initial, bytes);
    }

    /// One single-stream update pass using slicing.
    fn updateSingle(initial: u32, bytes: []const u8) u32 {
        const t = &tables;
        var crc = initial;
        var i: usize = 0;
        while (i + slices <= bytes.len) : (i += slices) {
            crc = foldChunk(bytes, i, crc);
        }
        for (bytes[i..]) |byte| {
            crc = (crc >> 8) ^ t[0][(crc ^ byte) & 0xFF];
        }
        return crc;
    }

    /// One update pass as three independent interleaved streams. Faster
    /// for large enough inputs.
    fn updateMulti(initial: u32, bytes: []const u8) u32 {
        // Both leading parts are block multiples so the interleaved loop
        // needs no tail handling; the third part absorbs the remainder.
        const part = (bytes.len / 3) & ~@as(usize, slices - 1);
        const p0 = bytes[0..part];
        const p1 = bytes[part..][0..part];
        const p2 = bytes[2 * part ..];

        var s0 = initial;
        var s1: u32 = 0;
        var s2: u32 = 0;
        var i: usize = 0;
        while (i + slices <= part) : (i += slices) {
            s0 = foldChunk(p0, i, s0);
            s1 = foldChunk(p1, i, s1);
            s2 = foldChunk(p2, i, s2);
        }
        s2 = updateSingle(s2, p2[part..]);

        const s01 = s1 ^ zeroShift(s0, p1.len);
        return s2 ^ zeroShift(s01, p2.len);
    }

    /// Fold one aligned block through the per-position slicing tables.
    /// The running CRC must already be XORed into the block's first word.
    inline fn foldBlock(comptime len: usize, words: *const [len / 4]u32) u32 {
        const t = &tables;
        var crc: u32 = 0;
        inline for (0..len / 4) |w| {
            const word = words[w];
            const base = len - 1 - w * 4;
            crc ^= t[base][word & 0xFF] ^
                t[base - 1][(word >> 8) & 0xFF] ^
                t[base - 2][(word >> 16) & 0xFF] ^
                t[base - 3][word >> 24];
        }
        return crc;
    }

    /// Fold the block starting at `offset`, chaining the running CRC state.
    inline fn foldChunk(bytes: []const u8, offset: usize, crc: u32) u32 {
        var words: [slices / 4]u32 = undefined;
        inline for (&words, 0..) |*word, w| {
            word.* = std.mem.readInt(
                u32,
                bytes[offset + w * 4 ..][0..4],
                .little,
            );
        }
        words[0] ^= crc;
        return foldBlock(slices, &words);
    }

    /// Advance a CRC state as if `len` zero bytes had been processed.
    fn zeroShift(state: u32, len: usize) u32 {
        var s = state;
        var remaining = len;
        var k: usize = 0;
        while (remaining != 0) : ({
            remaining >>= 1;
            k += 1;
        }) {
            if (remaining & 1 != 0) {
                const mat = &zero_shift_matrices[k / 2];
                s = matTimesVec(mat, s);
                if (k % 2 != 0) s = matTimesVec(mat, s);
            }
        }
        return s;
    }

    /// Multiply the GF(2) matrix by a CRC state column vector.
    inline fn matTimesVec(mat: *const [32]u32, vec: u32) u32 {
        var sum: u32 = 0;
        var v = vec;
        var i: usize = 0;
        while (v != 0) : ({
            v >>= 1;
            i += 1;
        }) {
            if (v & 1 != 0) sum ^= mat[i];
        }
        return sum;
    }

    const zero_shift_matrices: [32][32]u32 = matrices: {
        @setEvalBranchQuota(500_000);
        var matrices: [32][32]u32 = undefined;
        var previous: [32]u32 = undefined;
        for (0..32) |i| {
            const unit: u32 = 1 << i;
            previous[i] = (unit >> 8) ^ tables[0][unit & 0xFF];
        }
        matrices[0] = previous;
        for (1..64) |k| {
            var squared: [32]u32 = undefined;
            for (0..32) |i| {
                squared[i] = matTimesVec(&previous, previous[i]);
            }
            previous = squared;
            if (k % 2 == 0) matrices[k / 2] = squared;
        }
        break :matrices matrices;
    };
};

/// The standard-library implementation of the same parameter set. This is
/// the reference the tests compare against.
const Reference = std.hash.crc.Crc32Iscsi;

test "software slicing matches the standard library" {
    // The selected backend may be hardware, so cover the sliced software
    // path directly: every length around the sixteen-byte boundary, several
    // alignments, and continuation across arbitrary split points.
    var bytes: [512 + 19]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x511C);
    prng.random().bytes(&bytes);

    for (0..64 + 1) |len| {
        for (0..4) |offset| {
            const input = bytes[offset..][0..len];
            var reference: Reference = .{ .crc = 0xFFFF_FFFF };
            reference.update(input);
            try std.testing.expectEqual(
                reference.crc,
                Software.update(0xFFFF_FFFF, input),
            );
        }
    }

    const long = bytes[0..512];
    var reference: Reference = .{ .crc = 0xFFFF_FFFF };
    reference.update(long);
    for ([_]usize{ 0, 1, 15, 16, 17, 100, 511, 512 }) |split| {
        const first = Software.update(0xFFFF_FFFF, long[0..split]);
        try std.testing.expectEqual(
            reference.crc,
            Software.update(first, long[split..]),
        );
    }
}

test "software multi-stream matches the standard library" {
    // Lengths around and far above the interleaving threshold, plus odd
    // remainders, so all three streams and both combine steps are covered.
    var bytes: [96 * 1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x3517_1A3B);
    prng.random().bytes(&bytes);

    for ([_]usize{
        Software.multi_stream_threshold - 1,
        Software.multi_stream_threshold,
        Software.multi_stream_threshold + 1,
        Software.multi_stream_threshold + 97,
        12 * 1024,
        64 * 1024 + 31,
        bytes.len,
    }) |len| {
        const input = bytes[0..len];
        var reference: Reference = .{ .crc = 0xFFFF_FFFF };
        reference.update(input);
        try std.testing.expectEqual(
            reference.crc,
            Software.update(0xFFFF_FFFF, input),
        );

        // Continuation across a split inside the multi-stream range.
        const first = Software.update(0xFFFF_FFFF, input[0 .. len / 2]);
        try std.testing.expectEqual(
            reference.crc,
            Software.update(first, input[len / 2 ..]),
        );
    }
}

test "matches the check value" {
    // The catalog check value for CRC-32/ISCSI.
    try std.testing.expectEqual(
        @as(u32, 0xE3069283),
        Crc32c.hash("123456789"),
    );
}

test "matches the standard library at every length and split" {
    var bytes: [259]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xC5C32C);
    prng.random().bytes(&bytes);

    for (0..bytes.len + 1) |len| {
        const input = bytes[0..len];
        try std.testing.expectEqual(
            Reference.hash(input),
            Crc32c.hash(input),
        );

        // Streaming across arbitrary split points must not change the
        // result: word batching may not leak state between updates.
        var split: Crc32c = .init();
        split.update(input[0 .. len / 3]);
        split.update(input[len / 3 .. len - len / 3]);
        split.update(input[len - len / 3 ..]);
        try std.testing.expectEqual(Reference.hash(input), split.final());
    }
}

test "matches the standard library at every alignment" {
    var bytes: [64 + 16]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xA11C);
    prng.random().bytes(&bytes);

    for (0..16) |offset| {
        const input = bytes[offset..][0..64];
        try std.testing.expectEqual(
            Reference.hash(input),
            Crc32c.hash(input),
        );
    }
}
