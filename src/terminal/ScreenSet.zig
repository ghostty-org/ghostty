/// A ScreenSet holds multiple terminal screens. This is initially created
/// to handle simple primary vs alternate screens, but could be extended
/// in the future to handle N screens.
///
/// One of the goals of this is to allow lazy initialization of screens
/// as needed. The primary screen is always initialized, but the alternate
/// screen may not be until first used.
const ScreenSet = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Screen = @import("Screen.zig");

/// The possible keys for screens in the screen set.
pub const Key = enum(u1) {
    primary,
    alternate,
};

/// The key value of the currently active screen. Useful for simple
/// comparisons, e.g. "is this screen the primary screen".
active_key: Key,

/// The active screen pointer.
active: *Screen,

/// All screens that are initialized.
all: std.EnumMap(Key, *Screen),

pub fn init(
    alloc: Allocator,
    opts: Screen.Options,
) !ScreenSet {
    // We need to initialize our initial primary screen
    const screen = try alloc.create(Screen);
    errdefer alloc.destroy(screen);
    screen.* = try .init(alloc, opts);
    return .{
        .active_key = .primary,
        .active = screen,
        .all = .init(.{ .primary = screen }),
    };
}

pub fn deinit(self: *ScreenSet, alloc: Allocator) void {
    // Destroy all initialized screens
    var it = self.all.iterator();
    while (it.next()) |entry| {
        entry.value.*.deinit();
        alloc.destroy(entry.value.*);
    }
}

/// Get the screen for the given key, if it is initialized.
pub fn get(self: *const ScreenSet, key: Key) ?*Screen {
    return self.all.get(key);
}

/// Get the screen for the given key, initializing it if necessary.
pub fn getInit(
    self: *ScreenSet,
    alloc: Allocator,
    key: Key,
    opts: Screen.Options,
) !*Screen {
    if (self.get(key)) |screen| return screen;
    const screen = try alloc.create(Screen);
    errdefer alloc.destroy(screen);
    screen.* = try .init(alloc, opts);
    self.all.put(key, screen);
    return screen;
}

/// Remove a key from the set. The primary screen cannot be removed (asserted).
pub fn remove(
    self: *ScreenSet,
    alloc: Allocator,
    key: Key,
) void {
    assert(key != .primary);
    if (self.all.fetchRemove(key)) |screen| {
        screen.deinit();
        alloc.destroy(screen);
    }
}

/// Switch the active screen to the given key. Requires that the
/// screen is initialized.
pub fn switchTo(self: *ScreenSet, key: Key) void {
    self.active_key = key;
    self.active = self.all.get(key).?;
}

test ScreenSet {
    const alloc = testing.allocator;
    var set: ScreenSet = try .init(alloc, .default);
    defer set.deinit(alloc);
    try testing.expectEqual(.primary, set.active_key);

    // Initialize a secondary screen
    _ = try set.getInit(alloc, .alternate, .default);
    set.switchTo(.alternate);
    try testing.expectEqual(.alternate, set.active_key);
}
