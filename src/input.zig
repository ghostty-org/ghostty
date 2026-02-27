const std = @import("std");
const builtin = @import("builtin");

const config = @import("input/config.zig");
const mouse = @import("input/mouse.zig");
const key = @import("input/key.zig");
const key_mods = @import("input/key_mods.zig");
const keyboard = @import("input/keyboard.zig");

pub const command = @import("input/command.zig");
pub const function_keys = @import("input/function_keys.zig");
pub const keycodes = @import("input/keycodes.zig");
pub const key_encode = @import("input/key_encode.zig");
pub const kitty = @import("input/kitty.zig");
pub const paste = @import("input/paste.zig");

pub const ctrlOrSuper = key.ctrlOrSuper;
pub const Action = key.Action;
pub const Binding = @import("input/Binding.zig");
pub const Command = command.Command;
pub const Link = @import("input/Link.zig");
pub const Key = key.Key;
pub const KeyboardLayout = keyboard.Layout;
pub const KeyEvent = key.KeyEvent;
pub const KeyRemapSet = key_mods.RemapSet;
pub const InspectorMode = Binding.Action.InspectorMode;
pub const Mods = key_mods.Mods;
pub const MouseButton = mouse.Button;
pub const MouseButtonState = mouse.ButtonState;
pub const MousePressureStage = mouse.PressureStage;
pub const OptionAsAlt = config.OptionAsAlt;
pub const ScrollMods = mouse.ScrollMods;
pub const SplitFocusDirection = Binding.Action.SplitFocusDirection;
pub const SplitResizeDirection = Binding.Action.SplitResizeDirection;
pub const Trigger = Binding.Trigger;

// Keymap is only available on macOS right now. We could implement it
// in theory for XKB too on Linux but we don't need it right now.
pub const Keymap = switch (builtin.os.tag) {
    .macos => @import("input/KeymapDarwin.zig"),
    else => @import("input/KeymapNoop.zig"),
};

test {
    std.testing.refAllDecls(@This());
}
