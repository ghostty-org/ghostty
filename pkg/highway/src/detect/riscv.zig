const builtin = @import("builtin");
const HwyTargets = @import("../targets.zig").Targets;
const linux = @import("linux.zig");

pub fn detect() i64 {
    var t: HwyTargets = .{};

    if (comptime builtin.os.tag != .linux) return @bitCast(t);

    const AT_HWCAP: usize = 16;
    const hwcap = linux.getauxval(AT_HWCAP);

    // ISA extension bit for 'V' (vector).
    // Letter-based bits: bit position = letter - 'A'.
    const HWCAP_V: usize = 1 << ('V' - 'A');

    if (hwcap & HWCAP_V != 0) {
        t.rvv = true;
    }

    return @bitCast(t);
}
