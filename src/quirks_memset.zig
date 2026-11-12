//! Provides a fast `memset` that replaces compiler_rt's version on
//! every target except Darwin, x86_64, and binaries that link glibc
//! dynamically. Those use glibc's `memset`, `memcpy` and `memmove`,
//! which this file also arranges (see `Glibc` below).
//!
//! Zig 0.17.0's compiler_rt memset (ziglang/zig#35754) is no longer a
//! byte-at-a-time loop, but on aarch64 it is still slower than this
//! one. There it writes 16 bytes per loop iteration using ordinary
//! integer registers, and it never uses `dc zva`, the instruction that
//! zeroes a whole cache line at once. Compared to this file it is:
//!
//! - 1.5x to 2x slower for fills from 192 bytes to 32 KiB.
//! - About 4x slower for zero fills of 1 MiB or more.
//!
//! ## When to delete this file
//!
//! Delete it once compiler_rt's memset catches up. To check, build
//! `ghostty-bench` on Linux twice, once as-is and once with the
//! `@export` below removed, then compare the two with hyperfine. Use
//! arm64, since x86_64 no longer uses this file (see "Why x86_64 is
//! excluded" below). For both builds, set `Glibc.enabled` to false,
//! otherwise glibc's memset is used and ours is not part of either
//! build:
//!
//! ```
//! zig build -Demit-bench -Dapp-runtime=none -Doptimize=fast -p with
//! # Remove the export, then:
//! zig build -Demit-bench -Dapp-runtime=none -Doptimize=fast -p without
//!
//! hyperfine -N --warmup 3 \
//!   'with/bin/ghostty-bench +terminal-stream --data=ascii.txt' \
//!   'without/bin/ghostty-bench +terminal-stream --data=ascii.txt'
//! hyperfine -N --warmup 3 \
//!   'with/bin/ghostty-bench +terminal-resize' \
//!   'without/bin/ghostty-bench +terminal-resize'
//! ```
//!
//! Here `ascii.txt` is any large file of plain ASCII text (100 MB or
//! more works well). If both comparisons are within run-to-run noise,
//! the file is safe to delete.
//!
//! ## Background
//!
//! Zig 0.16.0 turned off LLVM's loop auto-vectorization. compiler_rt's
//! memset relied on it, so it became a byte-at-a-time loop and made
//! `+terminal-stream` 2.8x slower on ASCII. This file was the fix. It
//! is vectorized by hand with `@Vector`, so it does not depend on the
//! compiler to vectorize it.
//!
//! compiler_rt's `memset` is a weak symbol. Exporting our own `memset`
//! from an artifact root therefore takes its place for everything
//! linked into that executable or library.
//!
//! ## Why x86_64 is excluded
//!
//! On x86_64, compiler_rt's memset is as fast as this one for aligned
//! fills and much faster for unaligned ones. Both use the same vector
//! width (16-byte SSE2 stores at `-Dcpu=baseline`, 32-byte AVX2 stores
//! on newer CPUs). The difference is alignment: compiler_rt aligns its
//! loop to the vector size and LLVM unrolls it eight times, while this
//! file never aligns, so an unaligned destination makes every store in
//! its loop unaligned. On a Ryzen 7 5800X (Zen 3) with Zig 0.17.0,
//! for fills of 192 bytes to 1 MiB, compiler_rt is:
//!
//! - Within 5% of this file when the destination is vector aligned.
//! - 1.5x to 2.3x faster when it is only 8-byte aligned.
//! - 1.8x to 3.5x faster when it is 3 bytes past alignment.
//! - 2.5x faster for random sizes from 640 to 2,400 bytes at random
//!   offsets.
//!
//! End to end, `ghostty-bench` measures within 1.2% either way on
//! every workload, for both `-Dcpu=baseline` and native (AVX2) builds,
//! except ASCII with `--scrollback-max-bytes=0` at baseline, where
//! this file is 3% faster.
//!
//! ## Why Darwin is excluded
//!
//! On Darwin the override does not help, and it breaks programs that
//! link our static archives.
//!
//! - **It doesn't help.** Every Darwin binary links libSystem, Apple's
//!   C library, which has its own fast memset. Without this file, our
//!   executables, our dylibs, and programs that link our static
//!   archives all use it. (For the archives, `libsystem_override.sh`
//!   hides compiler_rt's copy so that libSystem's is used.)
//!   `ghostty-bench` measures within 2% of ours on Apple silicon.
//! - **It breaks static archives.** Zig writes our weak, hidden export
//!   to Mach-O as an ordinary symbol and drops the weak flag. An app
//!   that links `libghostty-vt.a` then gets our memset for its entire
//!   binary, and an app that defines its own memset fails to link:
//!
//!   ```
//!   duplicate symbol '_memset' in:
//!       app.o
//!       libghostty-vt.a(ghostty-vt-static_zcu.o)
//!   ```
//!
//! ## Why glibc is excluded
//!
//! glibc's memset is at least as fast as this one, so executables and
//! shared libraries that link glibc dynamically use it instead. On
//! Linux arm64 (Apple M4, glibc 2.41), `ghostty-bench` with glibc's
//! memset is 10% faster on ASCII with `--scrollback-max-bytes=0`, and
//! no workload is slower.
//!
//! Zig doesn't do this by itself, though. `Glibc` below explains why
//! and does it for `memset`, `memcpy` and `memmove`.
//!
//! Static archives and objects can't do this, because their consumer
//! does the final link. They keep this memset on glibc targets too.
//!
//! Other mem functions deliberately not overridden:
//!
//! - memcpy/memmove: compiler_rt's implementations are manually
//!   vectorized upstream ("memcpyFast") and remain fast. (Where glibc
//!   is available we still prefer its versions, see above.)
//! - memcmp/bcmp/strlen: these were also scalar in 0.16, but they
//!   never showed up in our profiles.
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
    // When we have Glibc available with the proper version, we prefer that
    // because their implementation is fantastic.
    if (Glibc.enabled) asm (Glibc.assembly());

    // Strong linkage when we control the final link (executables,
    // shared libraries), weak otherwise.
    const linkage: std.lang.GlobalLinkage = switch (builtin.output_mode) {
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
    //   4. Darwin always links libSystem, whose memset is already as
    //      fast as ours (within 2%). On Mach-O, Zig also drops the
    //      weak flag from our export, which breaks apps that link our
    //      static archives. See "Why Darwin is excluded" above.
    //   5. On x86_64, compiler_rt's memset is as fast as ours for
    //      aligned fills and up to 3.5x faster for unaligned ones,
    //      because it aligns its loop and we don't. See "Why x86_64
    //      is excluded" above.
    //   6. Where we can forward to glibc's memset we do that instead,
    //      because it is at least as fast as ours. See "Why glibc is
    //      excluded" above.
    const enabled =
        std.simd.suggestVectorLength(u8) != null and
        builtin.target.ofmt != .c and
        !(linkage == .weak and builtin.target.ofmt == .coff) and
        !builtin.target.os.tag.isDarwin() and
        builtin.target.cpu.arch != .x86_64 and
        !Glibc.enabled;

    if (enabled) @export(&memset, .{
        .name = "memset",
        .linkage = linkage,

        // Hidden so that shared library builds (libghostty,
        // libghostty-vt) use this internally without exporting it to
        // their host applications. It does not help static archives.
        // Their objects are linked straight into the host's binary,
        // so the host's own memset calls bind to this one too.
        .visibility = .hidden,
    });
}

/// Makes `memset`, `memcpy` and `memmove` use glibc's implementations
/// in executables and shared libraries that link glibc dynamically.
///
/// ## Why
///
/// Zig links compiler_rt into an executable or shared library as a
/// static archive holding one object. That object defines weak, hidden
/// copies of `memset`, `memcpy`, `memmove`, `memcmp`, `bcmp` and
/// `strlen` next to the compiler builtins (128-bit division, ...). As
/// soon as one builtin is needed the whole object is linked, and a
/// definition inside the binary always beats one in a shared library,
/// weak or not. Every call in the binary then goes to compiler_rt's
/// copy and glibc's is never used.
///
/// glibc's are faster. It picks an implementation at runtime for the
/// CPU it is running on (AVX2, `rep stosb`, `dc zva`, ...), while
/// compiler_rt's is fixed at compile time, which at `-Dcpu=baseline`
/// on x86_64 means SSE2. With `ghostty-bench` on Zig 0.17.0, compared
/// to compiler_rt's `memcpy` and `memmove` plus the best `memset` we
/// had (this file's on aarch64, compiler_rt's on x86_64):
///
/// - Linux aarch64 (Apple M4, glibc 2.41): ASCII with
///   `--scrollback-max-bytes=0` is 23% faster and `+terminal-resize`
///   is 10% faster.
/// - x86_64 at `-Dcpu=baseline` (Ryzen 7 5800X, glibc 2.42): ASCII is
///   6% to 10% faster, erase with scroll-clear and resize are 4%
///   faster.
/// - x86_64 built for the native CPU (AVX2): no difference.
///
/// Nothing measured slower that I could find.
///
/// ## How
///
/// We define our own strong `memset` (etc.) so that compiler_rt's weak
/// copy loses, and make it a single jump to glibc's.
///
/// The versions are the ones glibc currently exports as the default,
/// which for all but one are also the oldest that exist for the
/// architecture. The exception is x86_64 `memcpy`. Its older
/// `memcpy@GLIBC_2.2.5` only exists for binaries linked against glibc
/// older than 2.14 (2011), and it is a fixed SSE2 routine without the
/// runtime CPU selection, so binding it would defeat the purpose.
///
/// ## When to delete this
///
/// Delete it once compiler_rt stops defining these functions when libc
/// is linked. To check, set `enabled` to false, build `ghostty-bench`
/// for x86_64 Linux, and look at its symbols:
///
/// ```
/// zig build -Demit-bench -Dapp-runtime=none -Doptimize=fast
/// readelf --dyn-syms -W zig-out/bin/ghostty-bench | grep -E ' (memset|memcpy|memmove)@'
/// ```
///
/// If all three are listed as `UND`, glibc's are used without our help.
const Glibc = struct {
    const Versions = struct {
        /// The glibc version our target must be at least for all of
        /// the symbol versions below to exist.
        min: std.SemanticVersion,
        memset: []const u8,
        memcpy: []const u8,
        memmove: []const u8,
    };

    /// The symbol version of each function per architecture. Check with
    /// `readelf --dyn-syms -W libc.so.6 | grep -E ' (memset|memcpy|memmove)@@'`
    /// on a machine of that architecture (`@@` marks the default
    /// version).
    const versions: ?Versions = switch (builtin.target.cpu.arch) {
        .x86_64 => .{
            .min = .{ .major = 2, .minor = 14, .patch = 0 },
            .memset = "GLIBC_2.2.5",
            .memcpy = "GLIBC_2.14",
            .memmove = "GLIBC_2.2.5",
        },
        .aarch64 => .{
            .min = .{ .major = 2, .minor = 17, .patch = 0 },
            .memset = "GLIBC_2.17",
            .memcpy = "GLIBC_2.17",
            .memmove = "GLIBC_2.17",
        },
        else => null,
    };

    /// Whether the functions are forwarded to glibc for this artifact.
    const enabled = enabled: {
        // We can only forward when we control the final link, and only
        // when that link is against a shared glibc.
        if (!builtin.link_libc or
            !builtin.target.isGnuLibC() or
            builtin.link_mode != .dynamic) break :enabled false;
        switch (builtin.output_mode) {
            .Exe, .Lib => {},
            .Obj => break :enabled false,
        }

        const v = versions orelse break :enabled false;
        const glibc = builtin.target.os.versionRange().gnuLibCVersion() orelse
            break :enabled false;
        break :enabled glibc.order(v.min) != .lt;
    };

    /// Assembly defining all three functions. Only valid if `enabled`.
    fn assembly() []const u8 {
        const v = versions.?;
        return forward("memset", v.memset) ++
            forward("memcpy", v.memcpy) ++
            forward("memmove", v.memmove);
    }

    /// Assembly defining `name` as a jump to glibc's `name@ver`.
    fn forward(comptime name: []const u8, comptime ver: []const u8) []const u8 {
        // Notes on the assembly:
        //
        //   - `.symver` can't be applied to a symbol we also define,
        //     so the versioned reference goes through an alias.
        //   - Hidden so that shared library builds (libghostty,
        //     libghostty-vt) don't export these to their host
        //     applications.
        return std.fmt.comptimePrint(
            \\.symver ghostty_glibc_{[name]s}, {[name]s}@{[ver]s}
            \\.pushsection .text.{[name]s}, "ax", %progbits
            \\.globl {[name]s}
            \\.hidden {[name]s}
            \\.type {[name]s}, %function
            \\{[name]s}:
            \\  {[jump]s} ghostty_glibc_{[name]s}{[plt]s}
            \\.size {[name]s}, .-{[name]s}
            \\.popsection
            \\
        , .{
            .name = name,
            .ver = ver,
            .jump = switch (builtin.target.cpu.arch) {
                .x86_64 => "jmp",
                .aarch64 => "b",
                else => unreachable,
            },
            .plt = switch (builtin.target.cpu.arch) {
                .x86_64 => "@PLT",
                else => "",
            },
        });
    }
};

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
const zva_enabled = builtin.target.cpu.arch == .aarch64 and
    builtin.target.os.tag != .freestanding;

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
