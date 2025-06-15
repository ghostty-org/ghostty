const std = @import("std");
const terminal = @import("../terminal/main.zig");
const State = @import("State.zig");

/// Available cursor styles for drawing that renderers must support.
/// This is a superset of terminal cursor styles since the renderer supports
/// some additional cursor states such as the hollow block.
pub const Style = enum {
    // Typical cursor input styles
    block,
    block_hollow,
    bar,
    underline,

    // Special cursor styles
    lock,

    /// Create a cursor style from the terminal style request.
    pub fn fromTerminal(term: terminal.CursorStyle) ?Style {
        return switch (term) {
            .bar => .bar,
            .block => .block,
            .block_hollow => .block_hollow,
            .underline => .underline,
        };
    }
};

/// Returns the cursor style to use for the current render state or null
/// if a cursor should not be rendered at all.
pub fn style(
    state: *State,
    focused: bool,
    blink_visible: bool,
) ?Style {
    // Note the order of conditionals below is important. It represents
    // a priority system of how we determine what state overrides cursor
    // visibility and style.

    // The cursor is only at the bottom of the viewport. If we aren't
    // at the bottom, we never render the cursor. The cursor x/y is by
    // viewport so if we are above the viewport, we'll end up rendering
    // the cursor in some random part of the screen.
    if (!state.terminal.screen.viewportIsBottom()) return null;

    // If we are in preedit, then we always show the block cursor. We do
    // this even if the cursor is explicitly not visible because it shows
    // an important editing state to the user.
    if (state.preedit != null) return .block;

    // If the cursor is explicitly not visible by terminal mode, we don't render.
    if (!state.terminal.modes.get(.cursor_visible)) return null;

    // If we're not focused, our cursor is always visible so that
    // we can show the hollow box.
    if (!focused) return .block_hollow;

    // If the cursor is blinking and our blink state is not visible,
    // then we don't show the cursor.
    if (state.terminal.modes.get(.cursor_blinking) and !blink_visible) {
        return null;
    }

    // Otherwise, we use whatever style the terminal wants.
    return .fromTerminal(state.terminal.screen.cursor.cursor_style);
}

test "cursor: default uses configured style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screen.cursor.cursor_style = .bar;
    term.modes.set(.cursor_blinking, true);

    var state: State = .{
        .mutex = undefined,
        .terminal = &term,
        .preedit = null,
    };

    try testing.expect(style(&state, true, true) == .bar);
    try testing.expect(style(&state, false, true) == .block_hollow);
    try testing.expect(style(&state, false, false) == .block_hollow);
    try testing.expect(style(&state, true, false) == null);
}

test "cursor: blinking disabled" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screen.cursor.cursor_style = .bar;
    term.modes.set(.cursor_blinking, false);

    var state: State = .{
        .mutex = undefined,
        .terminal = &term,
        .preedit = null,
    };

    try testing.expect(style(&state, true, true) == .bar);
    try testing.expect(style(&state, true, false) == .bar);
    try testing.expect(style(&state, false, true) == .block_hollow);
    try testing.expect(style(&state, false, false) == .block_hollow);
}

test "cursor: explicitly not visible" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    term.screen.cursor.cursor_style = .bar;
    term.modes.set(.cursor_visible, false);
    term.modes.set(.cursor_blinking, false);

    var state: State = .{
        .mutex = undefined,
        .terminal = &term,
        .preedit = null,
    };

    try testing.expect(style(&state, true, true) == null);
    try testing.expect(style(&state, true, false) == null);
    try testing.expect(style(&state, false, true) == null);
    try testing.expect(style(&state, false, false) == null);
}

test "cursor: always block with preedit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var term = try terminal.Terminal.init(alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);

    var state: State = .{
        .mutex = undefined,
        .terminal = &term,
        .preedit = .{},
    };

    // In any bool state
    try testing.expect(style(&state, false, false) == .block);
    try testing.expect(style(&state, true, false) == .block);
    try testing.expect(style(&state, true, true) == .block);
    try testing.expect(style(&state, false, true) == .block);

    // If we're scrolled though, then we don't show the cursor.
    for (0..100) |_| try term.index();
    try term.scrollViewport(.{ .top = {} });

    // In any bool state
    try testing.expect(style(&state, false, false) == null);
    try testing.expect(style(&state, true, false) == null);
    try testing.expect(style(&state, true, true) == null);
    try testing.expect(style(&state, false, true) == null);
}
