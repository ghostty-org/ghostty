pub const XCR0_XMM = 0x02;
pub const XCR0_YMM = 0x04;
pub const XCR0_MASKREG = 0x20;
pub const XCR0_ZMM0_15 = 0x40;
pub const XCR0_ZMM16_31 = 0x80;

pub const CpuidLeaf = packed struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

/// Wrapper around x86 and x86_64 `cpuid` in order to gather processor
/// and feature information. This is explicitly and specifically only
/// for x86 and x86_64.
pub fn cpuid(leaf_id: u32, subid: u32) CpuidLeaf {
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
pub fn getXCR0() u32 {
    return asm volatile (
        \\ xor %%ecx, %%ecx
        \\ xgetbv
        : [_] "={eax}" (-> u32),
        :
        : "edx", "ecx"
    );
}
