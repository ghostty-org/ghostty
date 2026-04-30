const builtin = @import("builtin");
const HwyTargets = @import("../targets.zig").Targets;

const CpuidResult = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf),
          [_] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

inline fn bit(val: u32, comptime pos: u5) bool {
    return (val >> pos) & 1 != 0;
}

pub fn detect() i64 {
    var t: HwyTargets = .{};

    // x86_64 always has SSE2.
    if (comptime builtin.cpu.arch == .x86_64) {
        t.sse2 = true;
    }

    const leaf0 = cpuid(0, 0);
    const max_leaf = leaf0.eax;
    if (max_leaf < 1) return @bitCast(t);

    const leaf1 = cpuid(1, 0);

    // -- SSE2 on 32-bit x86 -------------------------------------------------
    if (comptime builtin.cpu.arch == .x86) {
        if (bit(leaf1.edx, 25) and bit(leaf1.edx, 26)) {
            t.sse2 = true;
        }
    }

    // -- SSSE3 ---------------------------------------------------------------
    if (bit(leaf1.ecx, 0) and // SSE3
        bit(leaf1.ecx, 9)) // SSSE3
    {
        t.ssse3 = true;
    }

    // -- SSE4 ----------------------------------------------------------------
    if (bit(leaf1.ecx, 19) and // SSE4.1
        bit(leaf1.ecx, 20) and // SSE4.2
        bit(leaf1.ecx, 1) and // PCLMUL
        bit(leaf1.ecx, 25)) // AES
    {
        t.sse4 = true;
    }

    // Check XSAVE / AVX OS support before enabling any AVX-dependent target.
    const has_xsave = bit(leaf1.ecx, 27);
    const has_avx_bit = bit(leaf1.ecx, 28);
    const xcr0: u32 = if (has_xsave and has_avx_bit) asm volatile ("xgetbv"
        : [_] "={eax}" (-> u32),
        : [_] "{ecx}" (@as(u32, 0)),
        : .{ .edx = true }) else 0;
    const has_avx_save = (xcr0 & 0x6) == 0x6; // SSE + AVX state

    // Darwin lazily saves AVX-512 context on first use.
    const has_avx512_save = if (comptime builtin.os.tag.isDarwin())
        true
    else
        (xcr0 & 0xE0) == 0xE0; // opmask + zmm_hi256 + hi16_zmm

    // -- AVX2 ----------------------------------------------------------------
    if (has_avx_save and max_leaf >= 7) {
        const leaf7 = cpuid(7, 0);

        if (bit(leaf7.ebx, 5) and // AVX2
            bit(leaf1.ecx, 12) and // FMA
            bit(leaf1.ecx, 29)) // F16C
        {
            // Also need LZCNT (extended leaf), BMI, BMI2.
            const leaf_ext = cpuid(0x80000001, 0);
            if (bit(leaf_ext.ecx, 5) and // LZCNT
                bit(leaf7.ebx, 3) and // BMI
                bit(leaf7.ebx, 8)) // BMI2
            {
                t.avx2 = true;
            }
        }

        // -- AVX-512 ---------------------------------------------------------
        if (has_avx512_save) {
            if (bit(leaf7.ebx, 16) and // AVX512F
                bit(leaf7.ebx, 31) and // AVX512VL
                bit(leaf7.ebx, 17) and // AVX512DQ
                bit(leaf7.ebx, 30) and // AVX512BW
                bit(leaf7.ebx, 28)) // AVX512CD
            {
                t.avx3 = true;
            }

            if (bit(leaf7.ecx, 11) and // AVX512VNNI
                bit(leaf7.ecx, 10) and // VPCLMULQDQ (AVX save ok)
                bit(leaf7.ecx, 1) and // AVX512VBMI
                bit(leaf7.ecx, 6) and // AVX512VBMI2
                bit(leaf7.ecx, 9) and // VAES (AVX save ok)
                bit(leaf7.ecx, 14) and // AVX512VPOPCNTDQ
                bit(leaf7.ecx, 12) and // AVX512BITALG
                bit(leaf7.ecx, 8)) // GFNI
            {
                t.avx3_dl = true;
            }

            // AVX512BF16 is in leaf 7 sub-1.
            if (t.avx3_dl and leaf7.eax >= 1) {
                const leaf7_1 = cpuid(7, 1);
                if (bit(leaf7_1.eax, 5)) { // AVX512BF16
                    if (isAMD()) {
                        t.avx3_zen4 = true;
                    }
                }

                if (bit(leaf7.edx, 23) and // AVX512FP16
                    bit(leaf7_1.eax, 5)) // AVX512BF16
                {
                    t.avx3_spr = true;
                }
            } else if (bit(leaf7.edx, 23)) { // AVX512FP16 without sub-leaf
                // Can't check BF16 without sub-leaf support, skip avx3_spr.
            }
        }

        // -- AVX10 -----------------------------------------------------------
        if (max_leaf >= 7 and cpuid(7, 0).eax >= 1) {
            const leaf7_1 = cpuid(7, 1);
            if (bit(leaf7_1.edx, 19)) { // AVX10.1-256
                if (max_leaf >= 0x24) {
                    const leaf24 = cpuid(0x24, 0);
                    if (bit(leaf24.ebx, 18)) { // AVX10.1-512
                        t.avx3_spr = true;
                        t.avx3_dl = true;
                        t.avx3 = true;
                    }
                }

                // AVX10.2 detection would require a leaf we can't
                // reliably check yet; leave for future.
            }
        }
    }

    return @bitCast(t);
}

fn isAMD() bool {
    const leaf0 = cpuid(0, 0);
    // "Auth" "enti" "cAMD"
    return leaf0.ebx == 0x68747541 and
        leaf0.ecx == 0x444d4163 and
        leaf0.edx == 0x69746e65;
}
