const level = @import("../core/level.zig");

pub const ArabicProp = u8;

/// Apply Arabic joining algorithm (Rules R1-R7).
/// TODO: Phase 2 — full implementation pending.
pub fn joinArabic(
    _: []const @import("../data/unicode.zig").BidiClass,
    _: []const level.BidiLevel,
    _: []ArabicProp,
) error{NotImplemented}!void {
    return error.NotImplemented;
}
