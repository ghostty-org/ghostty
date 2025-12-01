//! Types and functions related to tmux protocols.

const control = @import("tmux/control.zig");
pub const ControlParser = control.Parser;
pub const ControlNotification = control.Notification;

test {
    @import("std").testing.refAllDecls(@This());
}
