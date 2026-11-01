const std = @import("std");
const terminal = @import("../../terminal/main.zig");

/// Retire view-owned handles while preserving the reader's scroll position.
pub fn prepare(previous: *terminal.Terminal, replacement: *terminal.Terminal) void {
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
