/// SurfaceMouse represents mouse helper functionality for the core surface.
///
/// It's currently small in scope; its purpose is to isolate mouse logic that
/// has gotten a bit complex (e.g. pointer shape handling for key events), but
/// the intention is to grow it later so that we can better test said logic).
const SurfaceMouse = @This();

const std = @import("std");
const builtin = @import("builtin");
const input = @import("input.zig");
const terminal = @import("terminal/main.zig");
const MouseShape = terminal.MouseShape;

/// For processing key events; the key that was physically pressed on the
/// keyboard.
physical_key: input.Key,

/// The mouse event tracking mode, if any.
mouse_event: terminal.MouseEvent,

/// The current terminal's mouse shape.
mouse_shape: MouseShape,

/// The last mods state when the last mouse button (whatever it was) was
/// pressed or release.
mods: input.Mods,

/// True if the mouse position is currently over a link.
over_link: bool,

/// True if the mouse pointer is currently hidden.
hidden: bool,

/// Translates key state to mouse shape, called during key events. This mainly
/// handles overrides on key presses depending on whether or not we are in
/// mouse tracking mode, however it is also responsible for resetting cursor
/// state on any particular key releases.
///
/// null is returned when the mouse shape does not need changing.
pub fn keyToMouseShape(self: SurfaceMouse) ?MouseShape {
    // Filter for appropriate key events
    if (!eligibleMouseShapeKeyEvent(self.physical_key)) return null;

    // Exceptions: link hover or hidden state overrides any other shape
    // processing and does not change state.
    //
    // TODO: As we unravel mouse state, we can fix this to be more explicit.
    if (self.over_link or self.hidden) {
        return null;
    }

    // Handle possible overrides depending on mouse tracking state.
    switch (self.mouse_event != .none) {
        true => {
            // In mouse tracking mode
            if (isMouseModeOverrideState(self.mods) and isRectangleSelectState(self.mods)) {
                // Crosshair (rectangle select), only set if we are also
                // overriding (e.g. shift+ctrl+alt)
                return .crosshair;
            } else if (isMouseModeOverrideState(self.mods)) {
                // Normal override state
                return .text;
            }
        },

        false => {
            // Default terminal mode
            if (isRectangleSelectState(self.mods)) {
                // Crosshair (rectangle select)
                return .crosshair;
            } else if (isMouseModeOverrideState(self.mods)) {
                // Shift shows an I-beam so selection is obvious even when
                // the application cursor is not text (OSC 22). Release
                // restores mouse_shape below.
                return .text;
            }
        },
    }

    // No overrides means we just revert back to the stored terminal mouse
    // shape. Note that this may be different than what has been currently sent
    // to the apprt, so this will force the reset.
    return self.mouse_shape;
}

fn eligibleMouseShapeKeyEvent(physical_key: input.Key) bool {
    return physical_key.ctrlOrSuper() or
        physical_key.leftOrRightShift() or
        physical_key.leftOrRightAlt();
}

fn isMouseModeOverrideState(mods: input.Mods) bool {
    return mods.shift;
}

/// Returns true if our modifiers put us in a state where dragging
/// should cause a rectangle select.
pub fn isRectangleSelectState(mods: input.Mods) bool {
    return if (comptime builtin.target.os.tag.isDarwin())
        mods.alt
    else
        mods.ctrlOrSuper() and mods.alt;
}

test "keyToMouseShape" {
    const testing = std.testing;

    {
        // No specific key pressed
        const m: SurfaceMouse = .{
            .physical_key = .unidentified,
            .mouse_event = .none,
            .mouse_shape = .progress,
            .mods = .{},
            .over_link = false,
            .hidden = false,
        };

        const got = m.keyToMouseShape();
        try testing.expect(got == null);
    }

    {
        // Over a link. NOTE: This tests that we don't touch the inbound state,
        // not necessarily if we're over a link.
        const m: SurfaceMouse = .{
            .physical_key = .shift_left,
            .mouse_event = .none,
            .mouse_shape = .progress,
            .mods = .{},
            .over_link = true,
            .hidden = false,
        };

        const got = m.keyToMouseShape();
        try testing.expect(got == null);
    }

    {
        // Mouse is currently hidden
        const m: SurfaceMouse = .{
            .physical_key = .shift_left,
            .mouse_event = .none,
            .mouse_shape = .progress,
            .mods = .{},
            .over_link = true,
            .hidden = true,
        };

        const got = m.keyToMouseShape();
        try testing.expect(got == null);
    }

    {
        // default, no mods (mouse tracking)
        const m: SurfaceMouse = .{
            .physical_key = .shift_left,
            .mouse_event = .x10,
            .mouse_shape = .default,
            .mods = .{},
            .over_link = false,
            .hidden = false,
        };

        const want: MouseShape = .default;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }

    {
        // default -> crosshair (mouse tracking)
        const m: SurfaceMouse = .{
            .physical_key = .alt_left,
            .mouse_event = .x10,
            .mouse_shape = .default,
            .mods = .{ .ctrl = true, .super = true, .alt = true, .shift = true },
            .over_link = false,
            .hidden = false,
        };

        const want: MouseShape = .crosshair;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }

    {
        // default -> text (mouse tracking)
        const m: SurfaceMouse = .{
            .physical_key = .shift_left,
            .mouse_event = .x10,
            .mouse_shape = .default,
            .mods = .{ .shift = true },
            .over_link = false,
            .hidden = false,
        };

        const want: MouseShape = .text;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }

    {
        // crosshair -> text (mouse tracking)
        const m: SurfaceMouse = .{
            .physical_key = .alt_left,
            .mouse_event = .x10,
            .mouse_shape = .crosshair,
            .mods = .{ .shift = true },
            .over_link = false,
            .hidden = false,
        };

        const want: MouseShape = .text;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }

    {
        // no override restores the application shape (mouse tracking)
        const m: SurfaceMouse = .{
            .physical_key = .alt_left,
            .mouse_event = .x10,
            .mouse_shape = .crosshair,
            .mods = .{},
            .over_link = false,
            .hidden = false,
        };

        const want: MouseShape = .crosshair;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }

    {
        // text -> crosshair (mouse tracking)
        const m: SurfaceMouse = .{
            .physical_key = .alt_left,
            .mouse_event = .x10,
            .mouse_shape = .text,
            .mods = .{ .ctrl = true, .super = true, .alt = true, .shift = true },
            .over_link = false,
            .hidden = false,
        };

        const want: MouseShape = .crosshair;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }

    {
        // text, no mods (no mouse tracking)
        const m: SurfaceMouse = .{
            .physical_key = .shift_left,
            .mouse_event = .none,
            .mouse_shape = .text,
            .mods = .{},
            .over_link = false,
            .hidden = false,
        };

        const want: MouseShape = .text;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }

    {
        // text -> crosshair (no mouse tracking)
        const m: SurfaceMouse = .{
            .physical_key = .alt_left,
            .mouse_event = .none,
            .mouse_shape = .text,
            .mods = .{ .ctrl = true, .super = true, .alt = true },
            .over_link = false,
            .hidden = false,
        };

        const want: MouseShape = .crosshair;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }

    {
        // no override restores the application shape (no mouse tracking)
        const m: SurfaceMouse = .{
            .physical_key = .alt_left,
            .mouse_event = .none,
            .mouse_shape = .crosshair,
            .mods = .{},
            .over_link = false,
            .hidden = false,
        };

        const want: MouseShape = .crosshair;
        const got = m.keyToMouseShape();
        try testing.expect(want == got);
    }
}
