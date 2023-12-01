const std = @import("std");
const builtin = @import("builtin");

pub usingnamespace @import("input/mouse.zig");
pub usingnamespace @import("input/key.zig");
pub const function_keys = @import("input/function_keys.zig");
pub const keycodes = @import("input/keycodes.zig");
pub const kitty = @import("input/kitty.zig");
pub const Binding = @import("input/Binding.zig");
pub const Link = @import("input/Link.zig");
pub const KeyEncoder = @import("input/KeyEncoder.zig");
pub const InspectorMode = Binding.Action.InspectorMode;
pub const SplitDirection = Binding.Action.SplitDirection;
pub const SplitFocusDirection = Binding.Action.SplitFocusDirection;
pub const SplitResizeDirection = Binding.Action.SplitResizeDirection;

// Keymap is only available on macOS right now. We could implement it
// in theory for XKB too on Linux but we don't need it right now.
pub const Keymap = switch (builtin.os.tag) {
    .macos => @import("input/KeymapDarwin.zig"),
    else => struct {},
};

test {
    std.testing.refAllDecls(@This());
}
