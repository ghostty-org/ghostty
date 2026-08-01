//! Provides a fast `memset` symbol that overrides the slow scalar
//! implementation provided by Zig 0.16's compiler_rt.
//!
//! Consider deleting when upstream ships an optimized compiler_rt
//! memset (tracked by ziglang/zig#32091, maybe fixed at
//! ziglang/zig#35754). To verify it is safe to delete, check that
//! the disassembly of `memset` in a ReleaseFast binary is vectorized
//! (or at least not a byte-at-a-time loop).
//!
//! ## Background
//!
//! Zig 0.16.0 globally disabled LLVM loop auto-vectorization to work
//! around an LLVM 21 miscompilation (llvm/llvm-project#186922, see
//! the 0.16.0 release notes). compiler_rt's memset is a naive
//! byte-at-a-time loop that relied entirely on auto-vectorization,
//! so it now compiles to a scalar loop roughly 24x slower than what
//! Zig 0.15 produced.
//!
//! In benchmarks this made `ghostty-bench +terminal-stream` 2.8x slower on
//! ASCII input (memset was 63% of all executed instructions!).
//!
//! Because compiler_rt's symbol is weak, exporting a strong `memset`
//! from our own code transparently overrides it everywhere. The
//! implementation below is manually vectorized with `@Vector`, which
//! does not depend on the disabled loop vectorizer.
//!
//! Other mem functions deliberately not overridden:
//!
//! - memcpy/memmove: compiler_rt's implementations are manually
//!   vectorized upstream ("memcpyFast") and remain fast.
//! - memcmp/bcmp/strlen: also scalar in 0.16, but they never showed
//!   up in our profiles.
//!
//! This file has no effect unless it is referenced from an artifact
//! root (e.g. `comptime { _ = @import("quirks_memset.zig"); }`).
//! It must NOT be imported from shared code, otherwise downstream
//! consumers of our Zig modules would get this export injected into
//! their binaries.
//!
//! ## References
//!
//! I referenced the musl asm + c memset implementation (MIT licensed).
//! The primary thing I took away from that is the dc zva trick for
//! aarch64. The remainder is fairly obvious memset work.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    // Strong linkage when we control the final link (executables,
    // shared libraries), weak otherwise.
    const linkage: std.builtin.GlobalLinkage = switch (builtin.output_mode) {
        .Exe => .strong,
        .Lib => switch (builtin.link_mode) {
            .dynamic => .strong,
            .static => .weak,
        },
        .Obj => .weak,
    };

    // Whether the override is emitted:
    //
    //   1. On targets without SIMD we disable, since compiler_rt's
    //      scalar operations are going to be just as good.
    //   2. The C object format target uses strong linkage which
    //      conflits with ours and errors.
    //   3. Weak COFF builds fatally error because MSVC's linker
    //      errors when two identical linked symbols exist. MSVC has
    //      CRT which links so we don't need this there anyways.
    const enabled =
        std.simd.suggestVectorLength(u8) != null and
        builtin.object_format != .c and
        !(linkage == .weak and builtin.object_format == .coff);

    if (enabled) @export(&memset, .{
        .name = "memset",
        .linkage = linkage,

        // Hidden so that shared library builds (libghostty,
        // libghostty-vt) resolve this internally without exporting
        // it to their host applications.
        .visibility = .hidden,
    });
}

/// Bytes stored per loop iteration. Twice the native vector size so
/// each iteration issues two vector stores (e.g. `stp q0, q0` on
/// aarch64). Capped at 128 both because the small path below relies
/// on len < 128 once the loop is skipped, and because wider single
/// iterations stop paying off anyway (e.g. on scalable-vector
/// targets that suggest very large lengths).
const vec_bytes = @min(128, 2 * (std.simd.suggestVectorLength(u8) orelse 8));

/// Whether the `dc zva` fast path for large zero fills is available.
/// `dc zva` zeroes a whole cacheline per instruction without moving data
/// through the store pipeline. Based on musl.
const zva_enabled = builtin.cpu.arch == .aarch64 and
    builtin.os.tag != .freestanding;

/// Only use `dc zva` at or above this many bytes. Below this our
/// plain vector loop measures faster. Empirically mesaured.
const zva_threshold = 16384;

/// Matches the C memset ABI.
fn memset(dest: ?[*]u8, c: c_int, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);

    if (len == 0) return dest;
    const d = dest.?;

    // Only the low byte of `c` is used. The C ABI allows a "int"
    // as the c parameter but this behavior of just grabbing the
    // low byte seems consistent across implementations.
    const byte: u8 = @truncate(@as(c_uint, @bitCast(c)));

    // Large path: full-width vector stores.
    if (len >= vec_bytes) {
        // Very large zero fills: zero whole cachelines with `dc zva`
        // instead. Only implemented for the (universal in practice)
        // 64-byte block size; anything else falls through to the
        // vector loop.
        if (comptime zva_enabled) {
            if (len >= zva_threshold and byte == 0) zva: {
                if (zvaSize() != 64) break :zva;
                const splat64: @Vector(64, u8) = @splat(0);

                // Head: one unaligned store covering every byte up
                // to the first 64-aligned address (and usually a bit
                // beyond it; the overlap is fine).
                const addr = @intFromPtr(d);
                const aligned = std.mem.alignForward(usize, addr, 64);
                d[0..64].* = splat64;

                // Zero whole aligned cachelines while at least one
                // full line remains in range. `dc zva` requires the
                // WHOLE line to be inside the buffer: it always
                // zeroes all 64 bytes.
                var p: [*]u8 = @ptrFromInt(aligned);
                const end_addr = addr + len;
                while (@intFromPtr(p) + 64 <= end_addr) : (p += 64) {
                    asm volatile ("dc zva, %[ptr]"
                        :
                        : [ptr] "r" (p),
                        : .{ .memory = true });
                }

                // Tail: overlapping unaligned store anchored to the
                // end of the buffer, covering whatever the line loop
                // could not. len >= zva_threshold >= 64 so this
                // cannot underflow.
                d[len - 64 ..][0..64].* = splat64;
                return dest;
            }
        }

        const splat: @Vector(vec_bytes, u8) = @splat(byte);

        // Fill [0, N) where N is len rounded down to a multiple of
        // vec_bytes.
        var i: usize = 0;
        while (i + vec_bytes <= len) : (i += vec_bytes) {
            d[i..][0..vec_bytes].* = splat;

            // This empty asm statement prevents LLVM's
            // LoopIdiomRecognize pass from replacing this loop with
            // a call to memset, which would be infinite recursion
            // since we ARE memset. compiler_rt is protected from
            // this by being built with -fno-builtin; Ghostty is not.
            asm volatile ("" ::: .{ .memory = true });
        }

        // Fill the remaining [N, len) tail, if any, with one more
        // full-width store anchored to the END of the buffer. It
        // overlaps up to vec_bytes-1 bytes that the loop already
        // wrote, which is fine (same value), and cannot underflow
        // because len >= vec_bytes in this path.
        if (i != len) d[len - vec_bytes ..][0..vec_bytes].* = splat;
        return dest;
    }

    // Small path (len < vec_bytes): pairs of narrower stores, one
    // anchored to the start of the buffer and one to the end.
    //
    // The invariant for each branch below: a store of width w at
    // [0..w] plus a store at [len-w..len] covers every byte exactly
    // when w <= len <= 2*w. Smaller lens are handled by a later
    // branch; larger lens by an earlier one.

    comptime std.debug.assert(vec_bytes <= 128);
    if (comptime vec_bytes > 64) {
        if (len >= 64) {
            // 64 <= len < vec_bytes <= 128 (asserted above): one
            // pair of 64-byte stores covers len <= 128. Only emitted
            // when vec_bytes > 64 (e.g. AVX-512), otherwise the
            // vector loop above already handled these lengths.
            const splat64: @Vector(64, u8) = @splat(byte);
            d[0..64].* = splat64;
            d[len - 64 ..][0..64].* = splat64;
            return dest;
        }
    }
    if (len >= 16) {
        // 16 <= len < @min(vec_bytes, 64), so at most 63. One pair
        // of 16-byte stores covers len <= 32. For 32 < len < 64, a
        // second pair extends the covered prefix to [0..32] and the
        // covered suffix to [len-32..len], which meet or overlap in
        // the middle.
        const splat16: @Vector(16, u8) = @splat(byte);
        d[0..16].* = splat16;
        d[len - 16 ..][0..16].* = splat16;
        if (len > 32) {
            d[16..32].* = splat16;
            d[len - 32 ..][0..16].* = splat16;
        }
        return dest;
    }
    if (len >= 8) {
        // 8 <= len <= 15: one 8-byte pair (covers len <= 16).
        const splat8: @Vector(8, u8) = @splat(byte);
        d[0..8].* = splat8;
        d[len - 8 ..][0..8].* = splat8;
        return dest;
    }
    if (len >= 4) {
        // 4 <= len <= 7: one 4-byte pair (covers len <= 8).
        const splat4: @Vector(4, u8) = @splat(byte);
        d[0..4].* = splat4;
        d[len - 4 ..][0..4].* = splat4;
        return dest;
    }

    // 1 <= len <= 3: too short for the pair trick; write bytes one
    // at a time. The asm statement again keeps LoopIdiomRecognize
    // from turning this into a recursive memset call; LLVM will do
    // that even for a loop this short because the trip count is not
    // statically known.
    var i: usize = 0;
    while (i < len) : (i += 1) {
        d[i] = byte;
        asm volatile ("" ::: .{ .memory = true });
    }
    return dest;
}

/// Cached `dc zva` block size: 0 = not yet queried, 1 = unavailable
/// or prohibited, otherwise the block size in bytes. Racing threads
/// store the same value so the memory ordering is irrelevant.
var zva_size: std.atomic.Value(usize) = .init(0);

fn zvaSize() usize {
    const cached = zva_size.load(.monotonic);
    if (cached != 0) return cached;
    const dczid = asm ("mrs %[out], dczid_el0"
        : [out] "=r" (-> u64),
    );
    // Bit 4 (DZP) prohibits DC ZVA; bits 0-3 are log2 of the block
    // size in 4-byte words.
    const size: usize = if (dczid & 0x10 != 0)
        1
    else
        @as(usize, 4) << @intCast(dczid & 0xF);
    zva_size.store(size, .monotonic);
    return size;
}

test memset {
    const testing = std.testing;

    // A buffer larger than anything the small/vector paths special
    // case, with room for offset (alignment) variations. Guard bytes
    // around the fill region must remain untouched.
    var buf: [4 * vec_bytes + 33]u8 = undefined;
    for (0..vec_bytes + 1) |offset| {
        for (0..buf.len - offset) |len| {
            for ([_]u8{ 0x00, 0x5C, 0xFF }) |c| {
                @memset(&buf, 0xAA);
                const region = buf[offset..][0..len];
                const ret = memset(region.ptr, c, len);
                try testing.expectEqual(region.ptr, ret.?);
                for (buf[0..offset]) |b| try testing.expectEqual(0xAA, b);
                for (region) |b| try testing.expectEqual(c, b);
                for (buf[offset + len ..]) |b| try testing.expectEqual(0xAA, b);
            }
        }
    }

    // Zero length must not touch memory and must tolerate null.
    try testing.expectEqual(null, memset(null, 0x11, 0));
    var one: [1]u8 = .{0xAA};
    _ = memset(&one, 0x11, 0);
    try testing.expectEqual(0xAA, one[0]);
}

test "memset truncates C int fill value" {
    const testing = std.testing;

    var buf: [4]u8 = undefined;
    _ = memset(&buf, -1, buf.len);
    for (buf) |b| try testing.expectEqual(0xFF, b);

    _ = memset(&buf, 0x1234, buf.len);
    for (buf) |b| try testing.expectEqual(0x34, b);
}

test "memset large zero fills (dc zva path)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Sizes at and around the ZVA threshold, with a guard byte on
    // each side and every offset within a cacheline so the head and
    // tail alignment handling is fully exercised.
    const buf = try alloc.alloc(u8, 2 * zva_threshold + 66);
    defer alloc.free(buf);

    for ([_]usize{
        zva_threshold - 1,
        zva_threshold,
        zva_threshold + 63,
        2 * zva_threshold,
    }) |len| {
        for (0..65) |offset| {
            @memset(buf, 0xAA);
            const region = buf[1 + offset ..][0..len];
            _ = memset(region.ptr, 0x00, len);
            for (buf[0 .. 1 + offset]) |b| try testing.expectEqual(0xAA, b);
            for (region) |b| try testing.expectEqual(0x00, b);
            for (buf[1 + offset + len ..]) |b| try testing.expectEqual(0xAA, b);
        }
    }

    // Nonzero fills of ZVA-eligible sizes must not take the ZVA path
    // (it can only write zeroes).
    @memset(buf, 0xAA);
    _ = memset(buf.ptr + 1, 0x5C, zva_threshold);
    try testing.expectEqual(0xAA, buf[0]);
    for (buf[1 .. 1 + zva_threshold]) |b| try testing.expectEqual(0x5C, b);
    try testing.expectEqual(0xAA, buf[1 + zva_threshold]);
}
