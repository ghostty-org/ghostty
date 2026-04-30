const HwyTargets = @import("../targets.zig").Targets;
const linux = @import("linux.zig");

pub fn detect(t: *HwyTargets) i64 {
    // Linux exposes AArch64 features via getauxval(AT_HWCAP / AT_HWCAP2).
    const AT_HWCAP: usize = 16;
    const AT_HWCAP2: usize = 26;

    const hwcap = linux.getauxval(AT_HWCAP);
    const hwcap2 = linux.getauxval(AT_HWCAP2);

    // Bit positions from Linux UAPI asm/hwcap.h
    const HWCAP_AES: usize = 1 << 3;
    const HWCAP_FPHP: usize = 1 << 9; // FEAT_FP16
    const HWCAP_ASIMDDP: usize = 1 << 20; // DotProd
    const HWCAP_SVE: usize = 1 << 22;

    const HWCAP2_BF16: usize = 1 << 14;
    const HWCAP2_SVE2: usize = 1 << 1;
    const HWCAP2_SVEAES: usize = 1 << 2;

    if (hwcap & HWCAP_AES != 0) {
        t.neon = true;

        if (hwcap & HWCAP_FPHP != 0 and
            hwcap & HWCAP_ASIMDDP != 0 and
            hwcap2 & HWCAP2_BF16 != 0)
        {
            t.neon_bf16 = true;
        }
    }

    if (hwcap & HWCAP_SVE != 0) {
        const vec_bytes = sveVectorBytes();

        if (vec_bytes >= 32) {
            t.sve = true;
            if (vec_bytes == 32) {
                t.sve_256 = true;
            }
        }

        if (hwcap2 & HWCAP2_SVE2 != 0 and hwcap2 & HWCAP2_SVEAES != 0) {
            if (vec_bytes >= 32) {
                t.sve2 = true;
            } else if (vec_bytes == 16) {
                t.sve2_128 = true;
            }
        }
    }

    return @bitCast(t.*);
}

fn sveVectorBytes() usize {
    // PR_SVE_GET_VL returns the SVE vector length in the lower 16 bits.
    const PR_SVE_GET_VL: i32 = 51;
    const ret = linux.prctl(PR_SVE_GET_VL, 0, 0, 0, 0);
    const signed: isize = @bitCast(ret);
    if (signed >= 0) {
        return ret & 0xFFFF;
    }
    // prctl failed: assume 128-bit (NEON-width, conservative).
    return 16;
}
