const builtin = @import("builtin");
const HwyTargets = @import("../targets.zig").Targets;
const linux = @import("linux.zig");

pub fn detect() i64 {
    var t: HwyTargets = .{};

    if (comptime builtin.os.tag != .linux) return @bitCast(t);

    const AT_HWCAP: usize = 16;
    const hwcap = linux.getauxval(AT_HWCAP);

    // From Linux arch/s390/include/asm/elf.h
    const HWCAP_VX: usize = 1 << 11;
    const HWCAP_VXE: usize = 1 << 13; // z14
    const HWCAP_VXE2: usize = 1 << 15; // z15

    if (hwcap & HWCAP_VX != 0) {
        if (hwcap & HWCAP_VXE != 0) {
            t.z14 = true;

            if (hwcap & HWCAP_VXE2 != 0) {
                t.z15 = true;
            }
        }
    }

    return @bitCast(t);
}
