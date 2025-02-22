//! A noop implementation of the keymap interface so that the embedded
//! library can compile on non-macOS platforms.
const KeymapNoop = @This();

const Mods = @import("key.zig").Mods;

pub const State = struct {};
pub const Translation = struct {
    text: []const u8 = "",
    composing: bool = false,
    mods: Mods = .{},
};

pub fn init() !KeymapNoop {
    return .{};
}

pub fn deinit(self: *const KeymapNoop) void {
    _ = self;
}

pub fn reload(self: *KeymapNoop) !void {
    _ = self;
}

pub fn translate(
    self: *const KeymapNoop,
    out: []u8,
    state: *State,
    code: u16,
    mods: Mods,
) !Translation {
    _ = self;
    _ = out;
    _ = state;
    _ = code;
    _ = mods;
    return .{ .text = "", .composing = false };
}
