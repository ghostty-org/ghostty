pub const widgets = @import("widgets.zig");
pub const Inspector = @import("Inspector.zig");

pub const KeyEvent = widgets.key.Event;

test {
    @import("std").testing.refAllDecls(@This());
}
