const HwyTargets = @import("../targets.zig").Targets;

pub fn detect(t: *HwyTargets) i64 {
    // All Apple Silicon has AES.
    t.neon = true;

    // Every Apple chip from A11 (2017) onward has FP16 + DotProd.
    // BF16 arrived with M2 / A15 (ARM_BLIZZARD_AVALANCHE, 2022).
    // We probe hw.optional.arm.FEAT_BF16 to be precise.
    const has_bf16 = darwinSysctlBool("hw.optional.arm.FEAT_BF16");
    if (has_bf16) {
        t.neon_bf16 = true;
    }

    // Apple Silicon does not support SVE.
    return @bitCast(t.*);
}

fn darwinSysctlBool(comptime name: [:0]const u8) bool {
    var value: c_int = 0;
    var len: usize = @sizeOf(c_int);
    const rc = sysctlbyname(name.ptr, &value, &len, null, 0);
    return rc == 0 and value != 0;
}

// We can rely on libc for macOS because libsystem is always available.
extern "c" fn sysctlbyname(
    name: [*:0]const u8,
    oldp: ?*anyopaque,
    oldlenp: ?*usize,
    newp: ?*const anyopaque,
    newlen: usize,
) c_int;
