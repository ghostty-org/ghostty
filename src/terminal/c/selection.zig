const grid_ref = @import("grid_ref.zig");
const Selection = @import("../Selection.zig");

/// C: GhosttySelection
pub const CSelection = extern struct {
    size: usize = @sizeOf(CSelection),
    start: grid_ref.CGridRef,
    end: grid_ref.CGridRef,
    rectangle: bool = false,

    pub fn toZig(self: CSelection) ?Selection {
        const start_pin = self.start.toPin() orelse return null;
        const end_pin = self.end.toPin() orelse return null;
        return Selection.init(start_pin, end_pin, self.rectangle);
    }
};
