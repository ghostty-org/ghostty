/// Returns true for Arabic vowel/sign marks used by the RTL shaper fallback.
///
/// In Arabic RTL runs, shapers can report a mark before the base glyph that
/// owns the cell. We only apply that fallback to Arabic marks because other
/// scripts have different mark ordering rules, and using the same fallback for
/// every zero-width mark moves some Bengali/Chakma marks to the wrong x
/// position. Uses explicit ranges because script/general_category are not yet
/// exposed as runtime uucode fields.
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
