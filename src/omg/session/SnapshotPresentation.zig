const std = @import("std");
const terminal = @import("../../terminal/main.zig");

/// Retire view-owned handles while preserving the reader's scroll position.
pub fn prepare(previous: *terminal.Terminal, replacement: *terminal.Terminal) void {
    // The daemon owns OSC overrides; theme defaults belong to this viewer.
    // Its headless VT has no App configuration and must not reset it to black.
    replacement.colors.background.default = previous.colors.background.default;
    replacement.colors.foreground.default = previous.colors.foreground.default;
    replacement.colors.cursor.default = previous.colors.cursor.default;
    replacement.colors.palette.changeDefault(previous.colors.palette.original);
    replacement.flags.dirty.palette = true;
    for ([_]terminal.ScreenSet.Key{ .primary, .alternate }) |key| {
        replacement.screens.generations.put(key, previous.screens.generation(key) +% 1);
    }
    if (comptime terminal.options.kitty_graphics) {
        replacement.screens.active.kitty_images.dirty = true;
    }
    replacement.flags.search_viewport_dirty = true;
    // Secure input belongs to the local view; termios metadata updates it via
    // balanced surface messages after the snapshot is installed.
    replacement.flags.password_input = previous.flags.password_input;
    if (previous.screens.active_key == replacement.screens.active_key and
        !previous.screens.active.viewportIsBottom())
    {
        const old = previous.screens.active.pages.scrollbar();
        const fresh = replacement.screens.active.pages.scrollbar();
        replacement.scrollViewport(.{ .row = @min(old.offset, fresh.total -| fresh.len) });
    }
}

test "session snapshot replacement retires selection pins and preserves history position" {
    const alloc = std.testing.allocator;
    var previous: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer previous.deinit(alloc);
    var replacement: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer replacement.deinit(alloc);
    var old_stream = previous.vtStream();
    defer old_stream.deinit();
    var new_stream = replacement.vtStream();
    defer new_stream.deinit();
    old_stream.nextSlice("one\r\ntwo\r\nthree\r\nfour\r\nfive");
    new_stream.nextSlice("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix");
    previous.scrollViewport(.top);
    previous.flags.password_input = true;
    prepare(&previous, &replacement);
    try std.testing.expectEqual(@as(usize, 0), replacement.screens.active.pages.scrollbar().offset);
    try std.testing.expectEqual(previous.screens.generation(.primary) + 1, replacement.screens.generation(.primary));
    try std.testing.expectEqual(previous.screens.generation(.alternate) + 1, replacement.screens.generation(.alternate));
    try std.testing.expect(replacement.flags.search_viewport_dirty);
    try std.testing.expect(replacement.flags.password_input);
}

test "session snapshot presentation keeps viewer theme defaults and snapshot color overrides" {
    const alloc = std.testing.allocator;
    var previous: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer previous.deinit(alloc);
    var replacement: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer replacement.deinit(alloc);
    const background: terminal.color.RGB = .{ .r = 32, .g = 34, .b = 48 };
    const foreground: terminal.color.RGB = .{ .r = 220, .g = 223, .b = 244 };
    const cursor: terminal.color.RGB = .{ .r = 245, .g = 190, .b = 80 };
    previous.colors.background.default = background;
    previous.colors.foreground.default = foreground;
    previous.colors.cursor.default = cursor;
    var palette = terminal.color.default;
    palette[1] = .{ .r = 181, .g = 45, .b = 58 };
    previous.colors.palette.changeDefault(palette);
    // The program reset its old background and changed a palette entry while
    // this viewer was disconnected. Only the snapshot owns those overrides.
    previous.colors.background.set(.{ .r = 1, .g = 2, .b = 3 });
    previous.colors.palette.set(1, .{ .r = 4, .g = 5, .b = 6 });
    const program_color: terminal.color.RGB = .{ .r = 7, .g = 8, .b = 9 };
    replacement.colors.palette.set(2, program_color);
    prepare(&previous, &replacement);

    var rendered: terminal.RenderState = .empty;
    defer rendered.deinit(alloc);
    try rendered.update(alloc, &replacement);
    try std.testing.expectEqual(background, rendered.colors.background);
    try std.testing.expectEqual(foreground, rendered.colors.foreground);
    try std.testing.expectEqual(@as(?terminal.color.RGB, cursor), rendered.colors.cursor);
    try std.testing.expectEqual(palette[1], rendered.colors.palette[1]);
    try std.testing.expectEqual(program_color, rendered.colors.palette[2]);
    replacement.colors.palette.reset(2);
    try std.testing.expectEqual(palette[2], replacement.colors.palette.current[2]);
}

test "session snapshot presentation preserves explicit program background over viewer theme" {
    const alloc = std.testing.allocator;
    var previous: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer previous.deinit(alloc);
    var replacement: terminal.Terminal = try .init(std.testing.io, alloc, .{ .cols = 10, .rows = 3 });
    defer replacement.deinit(alloc);
    const theme: terminal.color.RGB = .{ .r = 32, .g = 34, .b = 48 };
    const program: terminal.color.RGB = .{ .r = 50, .g = 60, .b = 70 };
    previous.colors.background.default = theme;
    replacement.colors.background.set(program);
    prepare(&previous, &replacement);
    try std.testing.expectEqual(program, replacement.colors.background.get().?);
    replacement.colors.background.reset();
    try std.testing.expectEqual(@as(?terminal.color.RGB, theme), replacement.colors.background.get());
}
