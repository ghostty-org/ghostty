const builtin = @import("builtin");
const HwyTargets = @import("../targets.zig").Targets;
const linux = @import("linux.zig");

pub fn detect() i64 {
    var t: HwyTargets = .{};

    if (comptime builtin.os.tag != .linux) return @bitCast(t);

    const AT_HWCAP: usize = 16;
    const hwcap = linux.getauxval(AT_HWCAP);

    // From Linux arch/loongarch/include/uapi/asm/hwcap.h
    const HWCAP_LSX: usize = 1 << 4;
    const HWCAP_LASX: usize = 1 << 5;

    if (hwcap & HWCAP_LSX != 0) {
        t.lsx = true;

        if (hwcap & HWCAP_LASX != 0) {
            t.lasx = true;
        }
    }

    return @bitCast(t);
}
