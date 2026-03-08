/// Returns true for Arabic combining marks used by the RTL shaper fallback.
///
/// Scoped to Arabic marks to avoid regressing other scripts with different
/// mark emission behavior (e.g. Chakma/Bengali). Uses explicit ranges because
/// script/general_category are not yet exposed as runtime uucode fields.
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
