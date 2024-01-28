const std = @import("std");
const builtin = @import("builtin");

/// Possible instruction set architectures for SIMD operations. These are
/// coarse grained and are targeted specifically so we can detect exactly
/// what is available to us in Ghostty.
pub const ISA = enum {
    scalar,
    neon,
    avx2,

    /// Detect the available ISA at runtime. This will use comptime information
    /// as well to minimize the number of runtime checks.
    pub fn detect() ISA {
        return switch (builtin.cpu.arch) {
            // Neon is mandatory on aarch64. No runtime checks necessary.
            .aarch64 => .neon,
            .x86_64 => detectX86(),
            else => .scalar,
        };
    }

    fn detectX86() ISA {
        // NOTE: this is just some boilerplate to detect AVX2. We
        // can probably support earlier forms of SIMD such as plain
        // SSE, and we can definitely take advtange of later forms. This
        // is just some boilerplate to ONLY detect AVX2 right now.

        // If we support less than 7 for the maximum leaf level then we
        // don't support any AVX instructions.
        var leaf = X86.cpuid(0, 0);
        if (leaf.eax < 7) return .scalar;

        // If we don't have xsave or avx, then we don't support anything.
        leaf = X86.cpuid(1, 0);
        const has_xsave = hasBit(leaf.ecx, 27);
        const has_avx = hasBit(leaf.ecx, 28);
        if (!has_xsave or !has_avx) return .scalar;

        // We require AVX save state in order to use AVX instructions.
        const xcr0_eax = X86.getXCR0(); // requires xsave+avx
        const has_avx_save = hasMask(xcr0_eax, X86.XCR0_XMM | X86.XCR0_YMM);
        if (!has_avx_save) return .scalar;

        // Check for AVX2.
        leaf = X86.cpuid(7, 0);
        const has_avx2 = hasBit(leaf.ebx, 5);
        if (has_avx2) return .avx2;

        return .scalar;
    }
};

/// Constants and functions related to x86 and x86_64. Reference for this
/// can be found in the Intel Architectures Software Developer's Manual,
/// mostly around the cpuid instruction.
const X86 = struct {
    const XCR0_XMM = 0x02;
    const XCR0_YMM = 0x04;
    const XCR0_MASKREG = 0x20;
    const XCR0_ZMM0_15 = 0x40;
    const XCR0_ZMM16_31 = 0x80;

    const CpuidLeaf = packed struct {
        eax: u32,
        ebx: u32,
        ecx: u32,
        edx: u32,
    };

    /// Wrapper around x86 and x86_64 `cpuid` in order to gather processor
    /// and feature information. This is explicitly and specifically only
    /// for x86 and x86_64.
    fn cpuid(leaf_id: u32, subid: u32) CpuidLeaf {
        var eax: u32 = undefined;
        var ebx: u32 = undefined;
        var ecx: u32 = undefined;
        var edx: u32 = undefined;

        asm volatile ("cpuid"
            : [_] "={eax}" (eax),
              [_] "={ebx}" (ebx),
              [_] "={ecx}" (ecx),
              [_] "={edx}" (edx),
            : [_] "{eax}" (leaf_id),
              [_] "{ecx}" (subid),
        );

        return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
    }

    // Read control register 0 (XCR0). Used to detect features such as AVX.
    fn getXCR0() u32 {
        return asm volatile (
            \\ xor %%ecx, %%ecx
            \\ xgetbv
            : [_] "={eax}" (-> u32),
            :
            : "edx", "ecx"
        );
    }
};

/// Check if a bit is set at the given offset
inline fn hasBit(input: u32, offset: u5) bool {
    return (input >> offset) & 1 != 0;
}

/// Checks if a mask exactly matches the input
inline fn hasMask(input: u32, mask: u32) bool {
    return (input & mask) == mask;
}
