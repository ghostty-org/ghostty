const level = @import("../core/level.zig");
const types = @import("../core/types.zig");
const joining = @import("joining.zig");

/// Apply shaping: mirroring (L4) and Arabic presentation forms.
/// TODO: Phase 2 — full implementation pending.
pub fn shape(
    _: []u21,
    _: []const level.BidiLevel,
    _: ?[]const joining.ArabicProp,
    _: types.ShapeFlags,
) error{NotImplemented}!void {
    return error.NotImplemented;
}
