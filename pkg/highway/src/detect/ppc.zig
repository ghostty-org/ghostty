const builtin = @import("builtin");
const HwyTargets = @import("../targets.zig").Targets;
const linux = @import("linux.zig");

pub fn detect() i64 {
    var t: HwyTargets = .{};

    if (comptime builtin.os.tag != .linux) return @bitCast(t);

    const AT_HWCAP: usize = 16;
    const AT_HWCAP2: usize = 26;
    const hwcap = linux.getauxval(AT_HWCAP);
    const hwcap2 = linux.getauxval(AT_HWCAP2);

    // From Linux arch/powerpc/include/uapi/asm/cputable.h
    const PPC_FEATURE_HAS_ALTIVEC: usize = 0x10000000;
    const PPC_FEATURE_HAS_VSX: usize = 0x00000080;
    const PPC_FEATURE2_ARCH_2_07: usize = 0x80000000; // POWER8
    const PPC_FEATURE2_VEC_CRYPTO: usize = 0x02000000;
    const PPC_FEATURE2_ARCH_3_00: usize = 0x00800000; // POWER9
    const PPC_FEATURE2_ARCH_3_1: usize = 0x00040000; // POWER10
    const PPC_FEATURE2_MMA: usize = 0x00020000;

    if (hwcap & PPC_FEATURE_HAS_ALTIVEC != 0 and
        hwcap & PPC_FEATURE_HAS_VSX != 0 and
        hwcap2 & PPC_FEATURE2_ARCH_2_07 != 0 and
        hwcap2 & PPC_FEATURE2_VEC_CRYPTO != 0)
    {
        t.ppc8 = true;

        if (hwcap2 & PPC_FEATURE2_ARCH_3_00 != 0) {
            t.ppc9 = true;

            if (hwcap2 & PPC_FEATURE2_ARCH_3_1 != 0 and
                hwcap2 & PPC_FEATURE2_MMA != 0)
            {
                t.ppc10 = true;
            }
        }
    }

    return @bitCast(t);
}
