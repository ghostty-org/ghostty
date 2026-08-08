//! CRC32C with hardware acceleration.
//!
//! The Zig standard library implementation processes one byte per table
//! lookup (as of Zig 0.16), which is more than an order of magnitude slower
//! than the dedicated CRC32C instructions available on aarch64 (CRC
//! extension) and x86_64 (SSE4.2). This module selects the best backend at
//! compile time and falls back to the standard library elsewhere, including
//! WebAssembly.
//!
//! The resulting value is identical across all backends: this is the
//! iSCSI CRC32C parameter set (reflected, initial and final XOR
//! `0xFFFFFFFF`), matching `std.hash.crc.Crc32Iscsi`.

const std = @import("std");
const builtin = @import("builtin");

/// The standard-library implementation of the same parameter set. This is
/// both the portable fallback and the reference the tests compare against.
const Software = std.hash.crc.Crc32Iscsi;

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
            .software => software: {
                var crc: Software = .{ .crc = self.crc };
                crc.update(bytes);
                break :software crc.crc;
            },
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
            Software.hash(input),
            Crc32c.hash(input),
        );

        // Streaming across arbitrary split points must not change the
        // result: word batching may not leak state between updates.
        var split: Crc32c = .init();
        split.update(input[0 .. len / 3]);
        split.update(input[len / 3 .. len - len / 3]);
        split.update(input[len - len / 3 ..]);
        try std.testing.expectEqual(Software.hash(input), split.final());
    }
}

test "matches the standard library at every alignment" {
    var bytes: [64 + 16]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xA11C);
    prng.random().bytes(&bytes);

    for (0..16) |offset| {
        const input = bytes[offset..][0..64];
        try std.testing.expectEqual(
            Software.hash(input),
            Crc32c.hash(input),
        );
    }
}
