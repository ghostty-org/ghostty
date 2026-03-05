/// Returns true for Arabic combining marks used by the RTL shaper fallback.
///
/// This is intentionally scoped to Arabic marks to avoid regressing other
/// scripts with different mark emission behavior (e.g. Chakma/Bengali).
pub fn isArabicCombiningMark(cp: u32) bool {
    return switch (cp) {
        0x0610...0x061A,
        0x064B...0x065F,
        0x0670,
        0x06D6...0x06ED,
        => true,
        else => false,
    };
}
